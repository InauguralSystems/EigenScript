/*
 * EigenScript HTTP Extension
 * HTTP server, route registration, request handling.
 * Compiled only when EIGENSCRIPT_EXT_HTTP=1.
 */

/* Must precede every include: exposes the strcasestr() prototype from
 * <string.h>. Without it strcasestr is implicitly declared as returning int,
 * so its 64-bit char* return is truncated to 32 bits and sign-extended — a
 * corrupted pointer that segfaults the server on any request carrying a
 * Content-Length header (a malformed `Content-Length: -1` was the repro). */
#define _GNU_SOURCE

#include "ext_http_internal.h"
#include "ext_names.h"
#include "state.h"
#include "trace.h"
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>

/* Phase 2.75 — HTTP nondet capture.
 *
 * Both incoming request state (request_body, session_id, request_headers)
 * and outgoing response data (http_post) are nondeterministic from the
 * script's perspective. The TRACE_NONDET_RET wrapper (defined in trace.h)
 * records each return value on the tape as an `N` record and, during
 * Phase 3 replay, serves the recorded value back. */

/* ================================================================
 * HTTP GLOBALS
 * ================================================================ */

/* Per-thread pointer at the active state's server. Definition for the
 * extern in ext_http_internal.h. Set by register_http_builtins on the
 * main thread; http_conn_thread inherits the parent's pointer at spawn
 * so worker threads (which don't attach an EigsThread) can still read
 * route/static/CORS config. */
__thread Server *eigs_http_active = NULL;

/* Per-request state. Lives in TLS so concurrent connection threads do not
 * trample each other; each handler thread sets these once at the top of
 * handle_request and reads them via the http_request_* builtins. */
static __thread const char *tls_request_body = NULL;
static __thread const char *tls_request_headers = NULL;
static __thread const char *tls_session_id = NULL;
/* Set when serving a HEAD request — send_response writes the header but
 * skips the body. */
static __thread int tls_suppress_body = 0;

/* Concurrent connection cap. Each accepted connection runs in a detached
 * pthread; once g_conn_count reaches the cap we shed load with a 503. */
#define HTTP_MAX_CONCURRENT_CONNS 256
static volatile int g_conn_count = 0;

/* Per-source-IP concurrent-connection cap. HTTP_MAX_CONCURRENT_CONNS is a
 * single global counter, so one source can hold every worker slot with cheap
 * slow connections (a slow-loris) and shut out every other client — verified
 * live: 256 partial-header connections from one address deny all service. This
 * bounds how many of the global slots any single source IP may hold at once, so
 * an attacker must source from many addresses to exhaust the pool. Default 48
 * (well above a browser's ~6 parallel connections, far below the global cap);
 * override via EIGS_HTTP_MAX_CONN_PER_IP, 0 = disabled.
 *
 * ASSUMES the runtime sees real client IPs. Behind a reverse proxy every
 * connection carries the PROXY's address, so this cap would throttle the proxy
 * to N and break everyone — deploy behind a proxy means set this to 0 and do
 * the per-IP limiting at the proxy (which is the recommended posture for a
 * directly-exposed thread-per-connection server anyway). */
#define HTTP_DEFAULT_MAX_CONN_PER_IP 48
static long g_http_max_conn_per_ip = -1;   /* -1 = uninitialised */

static long http_max_conn_per_ip(void) {
    if (g_http_max_conn_per_ip >= 0) return g_http_max_conn_per_ip;
    const char *env = getenv("EIGS_HTTP_MAX_CONN_PER_IP");
    if (env && *env) {
        char *end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && v >= 0) { g_http_max_conn_per_ip = v; return v; }
    }
    g_http_max_conn_per_ip = HTTP_DEFAULT_MAX_CONN_PER_IP;
    return g_http_max_conn_per_ip;
}

/* Live per-IP connection counts. At most HTTP_MAX_CONCURRENT_CONNS distinct
 * sources can be active at once (one slot each, minimum), so a fixed array
 * sized to the global cap can always hold every active source. Linear scan is
 * fine at accept rate. Guarded by its own mutex — the accept loop acquires, the
 * worker releases on exit. */
typedef struct { uint32_t addr; int count; } IpConnSlot;
static IpConnSlot g_ip_conns[HTTP_MAX_CONCURRENT_CONNS];
static int g_ip_conns_len = 0;
static pthread_mutex_t g_ip_conns_mu = PTHREAD_MUTEX_INITIALIZER;

/* Reserve a slot for `addr`. Returns 1 if the source is under the per-IP cap
 * (and increments its count), 0 if already at the cap. cap==0 disables the
 * check. Fails OPEN if the table is somehow full (cannot happen: distinct
 * active IPs <= the global cap, which gates this call). */
static int ip_conn_acquire(uint32_t addr) {
    long cap = http_max_conn_per_ip();
    if (cap == 0) return 1;
    pthread_mutex_lock(&g_ip_conns_mu);
    int free_idx = -1;
    for (int i = 0; i < g_ip_conns_len; i++) {
        if (g_ip_conns[i].count == 0) { if (free_idx < 0) free_idx = i; continue; }
        if (g_ip_conns[i].addr == addr) {
            if (g_ip_conns[i].count >= cap) {
                pthread_mutex_unlock(&g_ip_conns_mu);
                return 0;
            }
            g_ip_conns[i].count++;
            pthread_mutex_unlock(&g_ip_conns_mu);
            return 1;
        }
    }
    if (free_idx < 0 && g_ip_conns_len < HTTP_MAX_CONCURRENT_CONNS)
        free_idx = g_ip_conns_len++;
    if (free_idx >= 0) {
        g_ip_conns[free_idx].addr = addr;
        g_ip_conns[free_idx].count = 1;
    }
    pthread_mutex_unlock(&g_ip_conns_mu);
    return 1;
}

static void ip_conn_release(uint32_t addr) {
    if (http_max_conn_per_ip() == 0) return;
    pthread_mutex_lock(&g_ip_conns_mu);
    for (int i = 0; i < g_ip_conns_len; i++) {
        if (g_ip_conns[i].count > 0 && g_ip_conns[i].addr == addr) {
            g_ip_conns[i].count--;
            break;
        }
    }
    pthread_mutex_unlock(&g_ip_conns_mu);
}

/* Maximum allowed request body in bytes. Default 16 MiB; override via
 * EIGS_HTTP_MAX_BODY env var. Initialised lazily on first request. */
#define EIGS_HTTP_DEFAULT_MAX_BODY (16L * 1024L * 1024L)
static long g_http_max_body = 0;

static long http_max_body(void) {
    if (g_http_max_body != 0) return g_http_max_body;
    const char *env = getenv("EIGS_HTTP_MAX_BODY");
    if (env && *env) {
        char *end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && v > 0) { g_http_max_body = v; return v; }
    }
    g_http_max_body = EIGS_HTTP_DEFAULT_MAX_BODY;
    return g_http_max_body;
}

/* AGGREGATE request-body budget across ALL in-flight connections. The
 * per-request cap (http_max_body) and the per-listener connection cap
 * (HTTP_MAX_CONCURRENT_CONNS) are each bounded, but their PRODUCT is not:
 * 256 conns x 16 MiB each = ~4 GiB held at once, enough to OOM a modest host
 * even though no single request or connection misbehaves. g_http_body_in_flight
 * tracks the bytes currently buffered for request reads summed over every
 * connection; when a connection's buffer growth would push the total past this
 * budget the connection is shed with 503. Default 128 MiB; override via
 * EIGS_HTTP_MAX_BODY_TOTAL. */
#define EIGS_HTTP_DEFAULT_MAX_BODY_TOTAL (128L * 1024L * 1024L)
static long g_http_max_body_total = 0;
static long g_http_body_in_flight = 0;   /* atomic; sum of accounted buffers */

static long http_max_body_total(void) {
    if (g_http_max_body_total != 0) return g_http_max_body_total;
    const char *env = getenv("EIGS_HTTP_MAX_BODY_TOTAL");
    if (env && *env) {
        char *end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && v > 0) { g_http_max_body_total = v; return v; }
    }
    g_http_max_body_total = EIGS_HTTP_DEFAULT_MAX_BODY_TOTAL;
    return g_http_max_body_total;
}

/* All response sites share this builder. `cache_cors` preserves the old
 * load-shed headers; OPTIONS has no Content-Type/Length. Extra fields are
 * runtime-owned literals (currently Retry-After), never caller text. */
static void send_response_full(int fd, int status, const char *status_text,
                               const char *content_type, const char *body,
                               long body_len, int cache_cors, const char *extra);
static double monotonic_now(void);

static void stop_init_responder(Server *s) {
    __atomic_store_n(&s->init_stop, 1, __ATOMIC_RELEASE);
    if (s->init_thread_active) {
        pthread_join(s->init_tid, NULL);
        s->init_thread_active = 0;
    }
}

/* Startup is liveness-only: ordinary requests receive a retryable 503.
 * Capacity is HTTP_MAX_CONCURRENT_CONNS — the same number the serving
 * accept loop sheds at. The listener is always polled; at capacity a
 * newcomer is accepted and answered with the init 503 immediately, never
 * queued behind stallers. Each in-flight client keeps a 1s read budget so
 * a fragmented request line can still complete; a client that never sends
 * a complete request line is answered 503 at that deadline. Handoff and
 * destruction stop accepting, then reply to every already-accepted fd. */
#define HTTP_INIT_MAX_CLIENTS HTTP_MAX_CONCURRENT_CONNS
#define HTTP_INIT_CLIENT_SEC  1.0

typedef struct {
    int fd;
    char *line;
    size_t used;
    size_t cap;
    double deadline;
} InitConn;

static void init_conn_reply(Server *s, InitConn *c, int complete) {
    char empty[] = "";
    char *line = c->line ? c->line : empty;
    char *method = line, *path = strchr(line, ' '), *version = NULL;
    if (path) { *path++ = '\0'; version = strchr(path, ' '); }
    if (version) *version++ = '\0';
    tls_suppress_body = strcmp(method, "HEAD") == 0;
    int live = complete && path && version && s->liveness_path &&
        (strcmp(method, "GET") == 0 || tls_suppress_body) &&
        strcmp(path, s->liveness_path) == 0 &&
        (strncmp(version, "HTTP/1.1\r\n", 10) == 0 ||
         strncmp(version, "HTTP/1.0\r\n", 10) == 0);
    send_response_full(c->fd, live ? 200 : 503,
                       live ? "OK" : "Service Unavailable", "text/plain",
                       live ? "OK" : "Server initializing\n", live ? 2 : 20,
                       1, live ? "" : "Retry-After: 1\r\n");
    free(c->line);
    close(c->fd);
    c->line = NULL;
    c->fd = -1;
    tls_suppress_body = 0;
}

static void init_conn_open(Server *s, InitConn *c, int fd) {
    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    size_t line_cap = s->liveness_path ? strlen(s->liveness_path) + 128 : 8192;
    if (line_cap < 8192) line_cap = 8192;
    c->fd = fd;
    c->line = xmalloc(line_cap);
    c->used = 0;
    c->cap = line_cap;
    c->deadline = monotonic_now() + HTTP_INIT_CLIENT_SEC;
    c->line[0] = '\0';
}

/* 1 = request line complete or buffer full (reply), -1 = peer gone (reply),
 * 0 = keep waiting. */
static int init_conn_read(InitConn *c) {
    if (c->used + 1 >= c->cap) return 1;
    ssize_t n = recv(c->fd, c->line + c->used, c->cap - 1 - c->used, 0);
    if (n <= 0) return -1;
    c->used += (size_t)n;
    c->line[c->used] = '\0';
    return strstr(c->line, "\r\n") ? 1 : 0;
}

static void init_conn_shed(Server *s, int fd) {
    /* Capacity shed does not read the request, so HEAD and GET must produce
     * the same wire image: 503, Retry-After, Content-Length 0, no body. */
    (void)s;
    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    tls_suppress_body = 1;
    send_response_full(fd, 503, "Service Unavailable", "text/plain",
                       "", 0, 1, "Retry-After: 1\r\n");
    tls_suppress_body = 0;
    close(fd);
}

static void *init_responder(void *arg) {
    Server *s = arg;
    eigs_http_active = s;
    InitConn *clients = xmalloc_array((size_t)HTTP_INIT_MAX_CLIENTS, sizeof(InitConn));
    struct pollfd *pfds = xmalloc_array((size_t)HTTP_INIT_MAX_CLIENTS + 1, sizeof(struct pollfd));
    int n = 0;
    for (;;) {
        if (__atomic_load_n(&s->init_stop, __ATOMIC_ACQUIRE)) {
            /* Shutdown ends accepting only. Every already-accepted fd still
             * gets an honest startup response; none is silently dropped. */
            for (int i = 0; i < n; i++) {
                int complete = clients[i].line && strstr(clients[i].line, "\r\n") != NULL;
                init_conn_reply(s, &clients[i], complete);
            }
            break;
        }
        int np = 0;
        pfds[np].fd = s->early_bind_fd;
        pfds[np].events = POLLIN;
        int li = np++;
        for (int i = 0; i < n; i++) {
            pfds[np].fd = clients[i].fd;
            pfds[np].events = POLLIN;
            np++;
        }
        int pr = poll(pfds, (nfds_t)np, 50);
        if (__atomic_load_n(&s->init_stop, __ATOMIC_ACQUIRE)) continue;
        int base = li + 1;
        double now = monotonic_now();
        for (int i = n - 1; i >= 0; i--) {
            int complete = 0, dead = 0;
            if (pr > 0 && (pfds[base + i].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))) {
                int r = init_conn_read(&clients[i]);
                if (r < 0) dead = 1;
                else if (r > 0) complete = 1;
            }
            if (complete || dead || now >= clients[i].deadline) {
                init_conn_reply(s, &clients[i], complete);
                clients[i] = clients[n - 1];
                n--;
            }
        }
        if (pr > 0 && li >= 0 && (pfds[li].revents & POLLIN)) {
            int conn = accept(s->early_bind_fd, NULL, NULL);
            if (conn >= 0) {
                if (n < HTTP_INIT_MAX_CLIENTS) {
                    init_conn_open(s, &clients[n], conn);
                    n++;
                } else {
                    init_conn_shed(s, conn);
                }
            }
        }
    }
    free(clients);
    free(pfds);
    eigs_http_active = NULL;
    return NULL;
}

/* ================================================================
 * HTTP BUILTINS
 * ================================================================ */

/* #877: no route slot takes a callback. Every slot — method, path, kind,
 * body/source — is stringified into the route table, and VAL_FN/VAL_BUILTIN
 * are the only value types with no sensible rendering: they produce the debug
 * reprs `<fn name>` / `<builtin>`. Dicts, lists, numbers, buffers and
 * text-builders all stringify to something a client can use, so this is the
 * whole of the class. The trap is foreseeable from the signature alone —
 * `handler` means "callback" in every mainstream framework, while here it is
 * a literal body — and the failure is silent AND remote-visible: a live
 * endpoint answers 200 with `<fn hello>` and nothing is logged. */
static int route_slot_is_callable(const Value *v) {
    return v && (v->type == VAL_FN || v->type == VAL_BUILTIN);
}

Value* builtin_http_route(Value *arg) {
    /* #356: registration failures must raise — the return value is never
     * checked, so a silent make_null() means the route just never exists. */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "http_route requires [method, path, body...] (3+ elements)");
        return make_null();
    }
    if (g_server.route_count >= MAX_ROUTES) {
        rt_error(EK_LIMIT, 0, "http_route: route table full (max %d routes)", MAX_ROUTES);
        return make_null();
    }

    /* #877: reject callables BEFORE anything is allocated or stored. rt_error
     * sets the error flag and returns rather than unwinding, so raising after
     * the value_to_string calls below would strand method/path in a route slot
     * that route_count never reaches — a leak on the error path. Registration
     * time is also the right moment: the error lands on the line the author
     * wrote, before the socket is listening, instead of on a client request. */
    for (int i = 0; i < 2; i++) {
        if (route_slot_is_callable(arg->data.list.items[i])) {
            rt_error(EK_TYPE, 0, "http_route: %s must be a string, not a function",
                     i == 0 ? "method" : "path");
            return make_null();
        }
    }
    if (arg->data.list.count >= 4) {
        if (route_slot_is_callable(arg->data.list.items[2])) {
            rt_error(EK_TYPE, 0, "http_route: kind must be a string, not a function "
                                 "(expected \"code\" or \"static\")");
            return make_null();
        }
        if (route_slot_is_callable(arg->data.list.items[3])) {
            rt_error(EK_TYPE, 0, "http_route: the code form's source must be a string of "
                                 "EigenScript source, not a function — "
                                 "http_route of [method, path, \"code\", \"return 42\"]");
            return make_null();
        }
    } else if (route_slot_is_callable(arg->data.list.items[2])) {
        rt_error(EK_TYPE, 0, "http_route: body must be a value, not a function — pass a "
                             "literal body (\"pong\"), or use the code form: "
                             "http_route of [method, path, \"code\", \"<source>\"]");
        return make_null();
    }

    Route *r = &g_server.routes[g_server.route_count];
    char *method_s = value_to_string(arg->data.list.items[0]);
    char *path_s = value_to_string(arg->data.list.items[1]);
    r->method = method_s;
    r->path = path_s;

    if (arg->data.list.count >= 4) {
        char *kind_s = value_to_string(arg->data.list.items[2]);
        char *payload_s = value_to_string(arg->data.list.items[3]);
        r->kind = kind_s;
        r->payload = payload_s;
    } else {
        Value *handler = arg->data.list.items[2];
        if (handler->type == VAL_STR) {
            r->kind = xstrdup("static");
            r->payload = xstrdup(handler->data.str);
        } else {
            r->kind = xstrdup("static");
            char *s = value_to_string(handler);
            r->payload = s;
        }
    }

    g_server.route_count++;
    return make_str("route registered");
}

Value* builtin_http_route_authed(Value *arg) {
    Value *result = builtin_http_route(arg);
    if (result && result->type == VAL_STR && strcmp(result->data.str, "route registered") == 0) {
        g_server.routes[g_server.route_count - 1].requires_auth = 1;
    }
    return result;
}

Value* builtin_http_static(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    char *prefix = value_to_string(arg->data.list.items[0]);
    char *dir = value_to_string(arg->data.list.items[1]);
    g_server.static_prefix = prefix;
    g_server.static_dir = dir;
    return make_str("static registered");
}

/* Deterministic script configuration: no tape records or external reads. */
static Value *response_header_error(ErrKind kind, const char *rule) {
    pthread_mutex_lock(&g_server.response_mu);
    g_server.response_header_rejected = 1;
    pthread_mutex_unlock(&g_server.response_mu);
    rt_error(kind, 0, "http_response_header: %s", rule);
    return make_null();
}

Value* builtin_http_response_header(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count != 2)
        return response_header_error(EK_TYPE, "requires [name, value] (exactly two strings)");
    Value *name = arg->data.list.items[0], *value = arg->data.list.items[1];
    if (name->type != VAL_STR || value->type != VAL_STR)
        return response_header_error(EK_TYPE, "name and value must be strings");
    size_t nlen = strlen(name->data.str), vlen = strlen(value->data.str);
    if (nlen < 1 || nlen > HTTP_RESPONSE_NAME_MAX)
        return response_header_error(EK_VALUE, "name must be 1..64 bytes (RFC 7230 token)");
    for (size_t i = 0; i < nlen; i++) {
        unsigned char c = (unsigned char)name->data.str[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || strchr("!#$%&'*+-.^_`|~", c)))
            return response_header_error(EK_VALUE, "name must be an RFC 7230 token");
    }
    if (vlen > HTTP_RESPONSE_VALUE_MAX)
        return response_header_error(EK_VALUE, "value must be 0..1024 bytes");
    for (size_t i = 0; i < vlen; i++) {
        unsigned char c = (unsigned char)value->data.str[i];
        if ((c < 32 && c != '\t') || c > 126)
            return response_header_error(EK_VALUE, "value requires visible ASCII, space or tab; no CR/LF/NUL");
    }
    /* EigenScript strings cannot contain NUL (chr/json/parser reject it). */
    if (strcasecmp(name->data.str, "Content-Length") == 0 ||
        strcasecmp(name->data.str, "Content-Type") == 0 ||
        strcasecmp(name->data.str, "Transfer-Encoding") == 0 ||
        strcasecmp(name->data.str, "Connection") == 0)
        return response_header_error(EK_VALUE, "runtime-owned header name is refused");
    pthread_mutex_lock(&g_server.response_mu);
    if (g_server.serving) {
        pthread_mutex_unlock(&g_server.response_mu);
        return response_header_error(EK_VALUE, "must register before http_serve");
    }
    int slot = 0;
    while (slot < g_server.response_header_count &&
           strcasecmp(name->data.str, g_server.response_headers[slot].name) != 0) slot++;
    if (slot == HTTP_RESPONSE_HEADER_MAX) {
        pthread_mutex_unlock(&g_server.response_mu);
        return response_header_error(EK_LIMIT, "at most 16 headers may be registered");
    }
    ResponseHeader *h = &g_server.response_headers[slot];
    memcpy(h->name, name->data.str, nlen + 1);
    memcpy(h->value, value->data.str, vlen + 1);
    if (slot == g_server.response_header_count) g_server.response_header_count++;
    pthread_mutex_unlock(&g_server.response_mu);
    return make_str("response header registered");
}

Value* builtin_http_early_bind(Value *arg) {
    const char *live_path = NULL;
    if (arg && arg->type == VAL_LIST) {
        if (arg->data.list.count != 2 || arg->data.list.items[1]->type != VAL_STR) {
            rt_error(EK_TYPE, 0, "http_early_bind requires [port, absolute liveness path string]");
            return make_null();
        }
        live_path = arg->data.list.items[1]->data.str;
        if (live_path[0] != '/') {
            rt_error(EK_VALUE, 0, "http_early_bind: liveness path must be absolute (start with /; no whitespace/CR/LF/NUL)");
            return make_null();
        }
        for (const unsigned char *p = (const unsigned char *)live_path; *p; p++) {
            if (*p <= 32 || *p == 127) {
                rt_error(EK_VALUE, 0, "http_early_bind: absolute liveness path cannot contain whitespace/CR/LF/NUL");
                return make_null();
            }
        }
        arg = arg->data.list.items[0];
    }
    if (arg && arg->type != VAL_NULL && arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "http_early_bind: port must be a number or null");
        return make_null();
    }
    if (g_server.early_bind_fd >= 0 || g_server.serving || g_server.response_header_rejected) {
        rt_error(EK_VALUE, 0, "http_early_bind: server already bound/serving or http_response_header rejected");
        return make_null();
    }
    int port = 5000;
    if (arg && arg->type == VAL_NUM) port = (int)arg->data.num;
    const char *env_port = getenv("PORT");
    if (env_port && atoi(env_port) > 0) {
        port = atoi(env_port);
        printf("[deploy] PORT env=%s, binding port %d\n", env_port, port);
    } else {
        printf("[deploy] No PORT env, using default %d\n", port);
    }
    char cwd[512];
    if (getcwd(cwd, sizeof(cwd))) {
        printf("[deploy] cwd=%s\n", cwd);
    }
    fflush(stdout);

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return make_str("error"); }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(server_fd); return make_str("error");
    }
    if (listen(server_fd, HTTP_MAX_CONCURRENT_CONNS) < 0) {
        perror("listen"); close(server_fd); return make_str("error");
    }

    g_server.early_bind_fd = server_fd;
    g_server.liveness_path = live_path ? xstrdup(live_path) : NULL;
    __atomic_store_n(&g_server.init_stop, 0, __ATOMIC_RELEASE);
    signal(SIGPIPE, SIG_IGN);
    if (pthread_create(&g_server.init_tid, NULL, init_responder, eigs_http_active) != 0) {
        close(server_fd);
        g_server.early_bind_fd = -1;
        free(g_server.liveness_path);
        g_server.liveness_path = NULL;
        rt_error(EK_IO, 0, "http_early_bind: could not start init responder");
        return make_null();
    }
    g_server.init_thread_active = 1;
    printf("Port %d bound (startup requests receive 503; optional liveness only)\n", port);
    fflush(stdout);

    return make_str("bound");
}

Value* builtin_http_serve(Value *arg) {
    pthread_mutex_lock(&g_server.response_mu);
    int rejected = g_server.response_header_rejected;
    if (!rejected) g_server.serving = 1;
    pthread_mutex_unlock(&g_server.response_mu);
    if (rejected) {
        stop_init_responder(eigs_http_active);
        if (g_server.early_bind_fd >= 0) close(g_server.early_bind_fd);
        g_server.early_bind_fd = -1;
        rt_error(EK_VALUE, 0, "http_response_header: rejected configuration; http_serve cannot start");
        return make_null();
    }
    int port = 5000;
    if (arg && arg->type == VAL_NUM) port = (int)arg->data.num;
    const char *env_port = getenv("PORT");
    if (env_port && atoi(env_port) > 0) {
        port = atoi(env_port);
    }
    printf("Starting HTTP server on port %d...\n", port);
    fflush(stdout);
    http_serve_blocking(port);
    return make_null();
}

Value* builtin_http_request_body(Value *arg) {
    (void)arg;
    if (tls_request_body)
        TRACE_NONDET_RET("http_request_body", make_str(tls_request_body));
    TRACE_NONDET_RET("http_request_body", make_str("{}"));
}

Value* builtin_http_session_id(Value *arg) {
    (void)arg;
    if (tls_session_id)
        TRACE_NONDET_RET("http_session_id", make_str(tls_session_id));
    TRACE_NONDET_RET("http_session_id", make_str("anonymous"));
}


/* Remove CR and LF in place. A CR or LF inside a header name or value ends the
 * header early on the wire, so whatever follows is read by the peer as further
 * headers (or as the start of the body) — header injection. Callers that build
 * a header from script-supplied text must run both halves through this. */
static void http_strip_crlf(char *s) {
    if (!s) return;
    char *w = s;
    for (const char *r = s; *r; r++) {
        if (*r != '\r' && *r != '\n') *w++ = *r;
    }
    *w = '\0';
}

static int http_url_is_allowed(const char *url) {
    if (!url || !url[0] || url[0] == '-') return 0;
    return strncmp(url, "http://", 7) == 0 || strncmp(url, "https://", 8) == 0;
}

Value* builtin_http_post(Value *arg) {
    TRACE_NONDET_TAKE("http_post");
    /* http_post of [url, headers_json, body_string] -> response body string
     * Uses fork/execvp to invoke curl — no shell involved, no injection risk. */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3)
        TRACE_NONDET_RECORD("http_post", make_str(""));
    const char *url = "", *headers_json = "", *body = "";
    if (arg->data.list.items[0]->type == VAL_STR) url = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) headers_json = arg->data.list.items[1]->data.str;
    if (arg->data.list.items[2]->type == VAL_STR) body = arg->data.list.items[2]->data.str;
    if (!http_url_is_allowed(url)) TRACE_NONDET_RECORD("http_post", make_str(""));

    /* Write body to temp file */
    char req_path[] = "/tmp/eigen_http_XXXXXX";
    int req_fd = mkstemp(req_path);
    if (req_fd < 0) TRACE_NONDET_RECORD("http_post", make_str(""));
    FILE *reqf = fdopen(req_fd, "w");
    if (!reqf) { close(req_fd); unlink(req_path); TRACE_NONDET_RECORD("http_post", make_str("")); }
    fprintf(reqf, "%s", body);
    fclose(reqf);

    /* Build argv array for curl — no shell interpolation */
    /* Max 96 args: curl -s --max-time 15 --proto ... [-H "k: v"]... -d @file -- url */
    char *argv[96];
    int argc = 0;
    argv[argc++] = "curl";
    argv[argc++] = "-s";
    argv[argc++] = "--max-time";
    argv[argc++] = "15";
    argv[argc++] = "--proto";
    argv[argc++] = "=http,https";
    argv[argc++] = "--proto-redir";
    argv[argc++] = "=http,https";

    /* Parse headers JSON and add -H flags */
    char header_bufs[32][256]; /* up to 32 headers */
    int hdr_count = 0;
    int jpos = 0;
    Value *hdr_obj = eigs_json_parse_root(headers_json, &jpos);   /* #777 */
    /* #755: a JSON OBJECT is the shape a caller reaches for first, and it used
     * to send NO headers at all — this tested only VAL_LIST, while
     * eigs_json_parse_object returns a VAL_DICT, so the loop never ran and the
     * request went out bare with no error and a normal-looking response. An
     * Authorization header silently not sent is the worst version of that. Both
     * shapes are accepted now: object (natural) and flat alternating array
     * (what already worked). Anything else that PARSED is a caller mistake, not
     * a no-header request — it says so instead of dropping the headers. */
    if (hdr_obj && hdr_obj->type == VAL_DICT) {
        for (int i = 0; i < hdr_obj->data.dict.count && hdr_count < 32 && argc < 90; i++) {
            char *hk = xstrdup(hdr_obj->data.dict.keys[i]);
            char *hv = value_to_string(hdr_obj->data.dict.vals[i]);
            http_strip_crlf(hk);
            http_strip_crlf(hv);
            snprintf(header_bufs[hdr_count], sizeof(header_bufs[0]), "%s: %s", hk, hv);
            free(hk); free(hv);
            argv[argc++] = "-H";
            argv[argc++] = header_bufs[hdr_count];
            hdr_count++;
        }
    } else if (hdr_obj && hdr_obj->type == VAL_LIST) {
        for (int i = 0; i + 1 < hdr_obj->data.list.count && hdr_count < 32 && argc < 90; i += 2) {
            char *hk = value_to_string(hdr_obj->data.list.items[i]);
            char *hv = value_to_string(hdr_obj->data.list.items[i + 1]);
            /* Both halves reach curl's -H verbatim, so a CR/LF in either injects
             * extra headers into the outbound request. Script-controlled and so
             * not a vulnerability on its own under SECURITY.md's threat model,
             * but a `code` route that forwards a client-supplied header value
             * into an http_post makes it one. */
            http_strip_crlf(hk);
            http_strip_crlf(hv);
            snprintf(header_bufs[hdr_count], sizeof(header_bufs[0]), "%s: %s", hk, hv);
            free(hk); free(hv);
            argv[argc++] = "-H";
            argv[argc++] = header_bufs[hdr_count];
            hdr_count++;
        }
    } else if (hdr_obj && hdr_obj->type != VAL_NULL) {
        /* Parsed, but neither shape — e.g. a bare string or number. Silently
         * sending nothing is the #755 failure mode; say so. An unparseable
         * headers argument (including "") still means "no headers", which is
         * the documented idiom. */
        rt_error(EK_TYPE, 0,
                 "http_post: headers must be a JSON object or a flat "
                 "[key, value, ...] array (got %s)",
                 val_type_name(hdr_obj->type));
        val_decref(hdr_obj);
        unlink(req_path);
        TRACE_NONDET_RECORD("http_post", make_str(""));
    }
    /* Released here rather than at the end of the function: the pipe/fork
     * failure paths below return through TRACE_NONDET_RECORD, and hdr_obj is
     * not used past this point. */
    val_decref(hdr_obj);

    char data_arg[512];
    snprintf(data_arg, sizeof(data_arg), "@%s", req_path);
    argv[argc++] = "-d";
    argv[argc++] = data_arg;
    argv[argc++] = "--";
    argv[argc++] = (char *)url;
    argv[argc] = NULL;

    /* Fork and exec curl, capture stdout via pipe */
    int pipefd[2];
    if (pipe(pipefd) < 0) { unlink(req_path); TRACE_NONDET_RECORD("http_post", make_str("")); }

    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); unlink(req_path); TRACE_NONDET_RECORD("http_post", make_str("")); }

    if (pid == 0) {
        /* Child: redirect stdout to pipe, close stderr */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }
        execvp("curl", argv);
        _exit(127);
    }

    /* Parent: read response from pipe */
    close(pipefd[1]);
    char buf[16384] = {0};
    int total = 0;
    while (total < 16383) {
        int n = read(pipefd[0], buf + total, 16383 - total);
        if (n <= 0) break;
        total += n;
    }
    buf[total] = '\0';
    close(pipefd[0]);

    int status;
    waitpid(pid, &status, 0);
    unlink(req_path);

    TRACE_NONDET_RECORD("http_post", make_str(buf));
}

Value* builtin_http_request_headers(Value *arg) {
    (void)arg;
    if (tls_request_headers)
        TRACE_NONDET_RET("http_request_headers", make_str(tls_request_headers));
    TRACE_NONDET_RET("http_request_headers", make_str(""));
}

/* ================================================================
 * SHARED STORE
 *
 * In-process key/value store keyed by string, scoped to the main HTTP
 * Server. Each worker code route runs in its own EigsState (arenas die
 * with the worker), so values are JSON-serialized on set and re-parsed
 * on get — there's no live cross-state Value* pointer. pthread_mutex
 * guards every operation. Functions/builtins encode as "null", matching
 * json_encode semantics; don't try to share callable values.
 *
 * Size cap: total key + json bytes are bounded by EIGS_HTTP_SHARED_MAX_BYTES
 * (default 64 MiB). shared_set rejects writes that would exceed the cap
 * and returns null without mutating storage.
 * ================================================================ */

#define EIGS_HTTP_SHARED_DEFAULT_MAX_BYTES (64L * 1024L * 1024L)
static long g_shared_max_bytes = 0;

static long shared_max_bytes(void) {
    if (g_shared_max_bytes != 0) return g_shared_max_bytes;
    const char *env = getenv("EIGS_HTTP_SHARED_MAX_BYTES");
    if (env && *env) {
        char *end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && v > 0) { g_shared_max_bytes = v; return v; }
    }
    g_shared_max_bytes = EIGS_HTTP_SHARED_DEFAULT_MAX_BYTES;
    return g_shared_max_bytes;
}

static int shared_find(Server *s, const char *key) {
    for (int i = 0; i < s->shared_count; i++) {
        if (strcmp(s->shared[i].key, key) == 0) return i;
    }
    return -1;
}

Value* builtin_shared_set(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *key_v = arg->data.list.items[0];
    Value *val = arg->data.list.items[1];
    if (key_v->type != VAL_STR) return make_null();
    Server *s = eigs_http_active;
    if (!s) return make_null();

    /* NULL when the value is cyclic or deeper than JSON_MAX_DEPTH (#730). A
     * handler storing a self-referential value used to segfault the server
     * here; reject the store instead. eigs_json_encode has already raised, so
     * the route sees a catchable error rather than a silent no-op. */
    char *json = eigs_json_encode(val);
    if (!json) return make_null();
    long new_json_len = (long)strlen(json);
    long key_len = (long)strlen(key_v->data.str);
    long cap = shared_max_bytes();

    pthread_mutex_lock(&s->shared_mu);
    int idx = shared_find(s, key_v->data.str);
    long old_bytes = (idx >= 0) ? (long)strlen(s->shared[idx].json) : 0;
    long delta = (idx >= 0) ? (new_json_len - old_bytes)
                            : (key_len + new_json_len);
    if (s->shared_bytes + delta > cap) {
        pthread_mutex_unlock(&s->shared_mu);
        free(json);
        return make_null();  /* over cap — reject without mutating */
    }
    if (idx >= 0) {
        free(s->shared[idx].json);
        s->shared[idx].json = json;
    } else {
        if (s->shared_count == s->shared_cap) {
            int new_cap = s->shared_cap ? s->shared_cap * 2 : 16;
            s->shared = xrealloc_array(s->shared, new_cap, sizeof(SharedEntry));
            s->shared_cap = new_cap;
        }
        s->shared[s->shared_count].key = xstrdup(key_v->data.str);
        s->shared[s->shared_count].json = json;
        s->shared_count++;
    }
    s->shared_bytes += delta;
    pthread_mutex_unlock(&s->shared_mu);
    return make_null();
}

/* Single-lock RMW for numeric counters/gauges. Missing key is treated
 * as 0 (so the first incr inserts the key with `delta` as its value);
 * an existing non-numeric value is a usage error, returns null without
 * mutating. Subject to the same byte cap as shared_set. Returns the new
 * value on success, null on bad args / over-cap / type mismatch. */
Value* builtin_shared_incr(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *key_v = arg->data.list.items[0];
    Value *delta_v = arg->data.list.items[1];
    if (key_v->type != VAL_STR || delta_v->type != VAL_NUM) return make_null();
    Server *s = eigs_http_active;
    if (!s) return make_null();

    double delta = delta_v->data.num;
    long cap = shared_max_bytes();

    pthread_mutex_lock(&s->shared_mu);
    int idx = shared_find(s, key_v->data.str);
    double cur = 0;
    if (idx >= 0) {
        int pos = 0;
        Value *parsed = eigs_json_parse_root(s->shared[idx].json, &pos);   /* #777 */
        /* Read the number out BEFORE dropping the ref — decref may free it —
         * and drop it on the mismatch path too, which is the one an early
         * return makes easy to miss. */
        int bad = (!parsed || parsed->type != VAL_NUM);
        if (!bad) cur = parsed->data.num;
        val_decref(parsed);
        if (bad) {
            pthread_mutex_unlock(&s->shared_mu);
            return make_null();
        }
    }
    double new_val = cur + delta;
    /* eigs_json_encode borrows its argument, so the Value handed to it is
     * ours to release. */
    Value *new_v = make_num(new_val);
    char *new_json = eigs_json_encode(new_v);
    val_decref(new_v);
    /* A number can't exceed the depth bound, but don't leave a bare strlen on
     * a documented-nullable return. */
    if (!new_json) { pthread_mutex_unlock(&s->shared_mu); return make_null(); }
    long new_json_len = (long)strlen(new_json);
    long key_len = (long)strlen(key_v->data.str);
    long old_bytes = (idx >= 0) ? (long)strlen(s->shared[idx].json) : 0;
    long delta_bytes = (idx >= 0) ? (new_json_len - old_bytes)
                                  : (key_len + new_json_len);
    if (s->shared_bytes + delta_bytes > cap) {
        pthread_mutex_unlock(&s->shared_mu);
        free(new_json);
        return make_null();
    }
    if (idx >= 0) {
        free(s->shared[idx].json);
        s->shared[idx].json = new_json;
    } else {
        if (s->shared_count == s->shared_cap) {
            int new_cap = s->shared_cap ? s->shared_cap * 2 : 16;
            s->shared = xrealloc_array(s->shared, new_cap, sizeof(SharedEntry));
            s->shared_cap = new_cap;
        }
        s->shared[s->shared_count].key = xstrdup(key_v->data.str);
        s->shared[s->shared_count].json = new_json;
        s->shared_count++;
    }
    s->shared_bytes += delta_bytes;
    pthread_mutex_unlock(&s->shared_mu);
    return make_num(new_val);
}

Value* builtin_shared_get(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();
    Server *s = eigs_http_active;
    if (!s) return make_null();
    pthread_mutex_lock(&s->shared_mu);
    int idx = shared_find(s, arg->data.str);
    char *json_copy = (idx >= 0) ? xstrdup(s->shared[idx].json) : NULL;
    pthread_mutex_unlock(&s->shared_mu);
    if (!json_copy) return make_null();
    int pos = 0;
    Value *v = eigs_json_parse_root(json_copy, &pos);   /* #777 */
    free(json_copy);
    return v ? v : make_null();
}

Value* builtin_shared_has(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);  /* fs:TODO #971 guards a non-string key; deferred: ext_http is a variant-only build (make http) */
    Server *s = eigs_http_active;
    if (!s) return make_num(0);  /* fs:ANSWER 0 means "key not present" -- the same value line 739 returns when shared_find misses; with no active server there is no shared store, so nothing is present */
    pthread_mutex_lock(&s->shared_mu);
    int idx = shared_find(s, arg->data.str);
    pthread_mutex_unlock(&s->shared_mu);
    return make_num(idx >= 0 ? 1 : 0);
}

Value* builtin_shared_delete(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);  /* fs:TODO #971 guards a non-string key; deferred: variant-only build */
    Server *s = eigs_http_active;
    if (!s) return make_num(0);  /* fs:ANSWER 0 means "nothing removed" -- the same value line 761 returns via `removed` when the key is absent */
    pthread_mutex_lock(&s->shared_mu);
    int idx = shared_find(s, arg->data.str);
    int removed = 0;
    if (idx >= 0) {
        s->shared_bytes -= (long)strlen(s->shared[idx].key);
        s->shared_bytes -= (long)strlen(s->shared[idx].json);
        free(s->shared[idx].key);
        free(s->shared[idx].json);
        for (int i = idx + 1; i < s->shared_count; i++) {
            s->shared[i - 1] = s->shared[i];
        }
        s->shared_count--;
        removed = 1;
    }
    pthread_mutex_unlock(&s->shared_mu);
    return make_num(removed);
}

Value* builtin_shared_keys(Value *arg) {
    (void)arg;
    Server *s = eigs_http_active;
    Value *list = make_list(8);
    if (!s) return list;
    pthread_mutex_lock(&s->shared_mu);
    for (int i = 0; i < s->shared_count; i++) {
        list_append_owned(list, make_str(s->shared[i].key));
    }
    pthread_mutex_unlock(&s->shared_mu);
    return list;
}

Value* builtin_shared_size(Value *arg) {
    (void)arg;
    Server *s = eigs_http_active;
    if (!s) return make_num(0);  /* fs:ANSWER 0 is the store's key count, the same quantity line 784 returns; with no active server the store is empty */
    pthread_mutex_lock(&s->shared_mu);
    int n = s->shared_count;
    pthread_mutex_unlock(&s->shared_mu);
    return make_num(n);
}

Value* builtin_shared_clear(Value *arg) {
    (void)arg;
    Server *s = eigs_http_active;
    if (!s) return make_null();
    pthread_mutex_lock(&s->shared_mu);
    for (int i = 0; i < s->shared_count; i++) {
        free(s->shared[i].key);
        free(s->shared[i].json);
    }
    s->shared_count = 0;
    s->shared_bytes = 0;
    pthread_mutex_unlock(&s->shared_mu);
    return make_null();
}

/* ================================================================
 * HTTP SERVER UTILITIES
 * ================================================================ */

static const char* get_content_type(const char *path) {
    const char *ext = strrchr(path, '.');
    if (!ext) return "application/octet-stream";
    if (strcmp(ext, ".html") == 0) return "text/html; charset=utf-8";
    if (strcmp(ext, ".css") == 0) return "text/css; charset=utf-8";
    if (strcmp(ext, ".js") == 0) return "application/javascript; charset=utf-8";
    if (strcmp(ext, ".mjs") == 0) return "application/javascript; charset=utf-8";
    if (strcmp(ext, ".json") == 0) return "application/json; charset=utf-8";
    if (strcmp(ext, ".wasm") == 0) return "application/wasm";
    if (strcmp(ext, ".png") == 0) return "image/png";
    if (strcmp(ext, ".jpg") == 0 || strcmp(ext, ".jpeg") == 0) return "image/jpeg";
    if (strcmp(ext, ".gif") == 0) return "image/gif";
    if (strcmp(ext, ".svg") == 0) return "image/svg+xml";
    if (strcmp(ext, ".ico") == 0) return "image/x-icon";
    if (strcmp(ext, ".woff") == 0) return "font/woff";
    if (strcmp(ext, ".woff2") == 0) return "font/woff2";
    if (strcmp(ext, ".ttf") == 0) return "font/ttf";
    if (strcmp(ext, ".map") == 0) return "application/json";
    return "application/octet-stream";
}

static int write_all(int fd, const char *data, size_t len) {
    while (len) {
        ssize_t n = write(fd, data, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        data += n;
        len -= (size_t)n;
    }
    return 1;
}

static void send_response_full(int fd, int status, const char *status_text,
                               const char *content_type, const char *body,
                               long body_len, int cache_cors, const char *extra) {
    /* Size from actual fields, with 512 bytes for fixed literals, integer
     * formatting and the final NUL. No fixed header buffer: even sixteen
     * maximum-size custom fields plus an arbitrarily long CORS origin fit.
     * Copy the snapshot under the mutex; never hold a config lock over I/O. */
    pthread_mutex_lock(&g_server.response_mu);
    const char *origin = cache_cors ? g_server.cors_origin : NULL;
    size_t cap = 512 + strlen(status_text) + strlen(extra) +
                 (content_type ? strlen(content_type) : 0) +
                 (origin ? strlen(origin) : 0);
    for (int i = 0; i < g_server.response_header_count; i++) {
        ResponseHeader *h = &g_server.response_headers[i];
        cap += strlen(h->name) + strlen(h->value) + 4;
    }
    char *header = xmalloc(cap);
    size_t used = (size_t)snprintf(header, cap, "HTTP/1.1 %d %s\r\n", status, status_text);
    if (content_type)
        used += (size_t)snprintf(header + used, cap - used,
                                "Content-Type: %s\r\nContent-Length: %ld\r\n",
                                content_type, body_len);
    if (status == 204)
        used += (size_t)snprintf(header + used, cap - used, "Allow: GET, HEAD, OPTIONS\r\n");
    if (cache_cors)
        used += (size_t)snprintf(header + used, cap - used, "Cache-Control: no-cache\r\n");
    if (origin)
        used += (size_t)snprintf(header + used, cap - used,
                                "Access-Control-Allow-Origin: %s\r\n"
                                "Access-Control-Allow-Methods: %s\r\n"
                                "Access-Control-Allow-Headers: Content-Type\r\n",
                                origin, status == 204 ? "GET, HEAD, OPTIONS" : "GET, POST, OPTIONS");
    used += (size_t)snprintf(header + used, cap - used, "Connection: close\r\n%s", extra);
    for (int i = 0; i < g_server.response_header_count; i++) {
        ResponseHeader *h = &g_server.response_headers[i];
        used += (size_t)snprintf(header + used, cap - used, "%s: %s\r\n", h->name, h->value);
    }
    used += (size_t)snprintf(header + used, cap - used, "\r\n");
    pthread_mutex_unlock(&g_server.response_mu);
    int sent = write_all(fd, header, used);
    free(header);
    if (sent && !tls_suppress_body && body && body_len > 0)
        write_all(fd, body, (size_t)body_len);
}

static void send_response(int fd, int status, const char *status_text,
                          const char *content_type, const char *body, long body_len) {
    send_response_full(fd, status, status_text, content_type, body, body_len, 1, "");
}

static void send_404(int fd, const char *path) {
    /* Path is deliberately omitted from the response body: it is attacker-
     * controlled and was previously interpolated into JSON unescaped. The
     * server still logs the miss via send_file. */
    (void)path;
    const char *body = "{\"error\": \"not_found\"}";
    send_response(fd, 404, "Not Found", "application/json", body, (long)strlen(body));
}

#define HTTP_MAX_STATIC_SIZE (64 * 1024 * 1024)  /* 64 MB cap for static files */

static void send_open_file(int fd, int file_fd, const char *filepath) {
    struct stat st;
    if (fstat(file_fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        send_404(fd, filepath);
        return;
    }
    if (st.st_size < 0 || st.st_size > HTTP_MAX_STATIC_SIZE) {
        send_response(fd, 413, "Payload Too Large", "text/plain", "File too large", 14);
        return;
    }
    if (lseek(file_fd, 0, SEEK_SET) < 0) {
        send_404(fd, filepath);
        return;
    }

    size_t size = (size_t)st.st_size;
    char *data = xmalloc(size + 1);
    size_t total = 0;
    while (total < size) {
        ssize_t n = read(file_fd, data + total, size - total);
        if (n <= 0) {
            free(data);
            send_404(fd, filepath);
            return;
        }
        total += (size_t)n;
    }
    data[size] = '\0';
    send_response(fd, 200, "OK", get_content_type(filepath), data, (long)size);
    free(data);
}

static void send_file(int fd, const char *filepath) {
    int file_fd = open(filepath, O_RDONLY | O_CLOEXEC);
    if (file_fd < 0) {
        char cwd[512];
        if (getcwd(cwd, sizeof(cwd))) {
            printf("[send_file] FAIL: '%s' not found (cwd=%s)\n", filepath, cwd);
        } else {
            printf("[send_file] FAIL: '%s' not found (cwd unknown)\n", filepath);
        }
        fflush(stdout);
        send_404(fd, filepath);
        return;
    }
    send_open_file(fd, file_fd, filepath);
    close(file_fd);
}

static int path_is_under_root(const char *path, const char *root) {
    size_t root_len = strlen(root);
    return strncmp(path, root, root_len) == 0 &&
           (path[root_len] == '/' || path[root_len] == '\0');
}

static int open_static_file_confined(const char *static_dir, const char *rel,
                                     char *resolved_path, size_t resolved_cap,
                                     int *out_fd) {
    char filepath[4096];
    snprintf(filepath, sizeof(filepath), "%s/%s", static_dir, rel);

    char *real_root = realpath(static_dir, NULL);
    if (!real_root) return 0;

    int file_fd = open(filepath, O_RDONLY | O_CLOEXEC);
    if (file_fd < 0) {
        free(real_root);
        return 0;
    }

    char fd_link[64];
    snprintf(fd_link, sizeof(fd_link), "/proc/self/fd/%d", file_fd);
    ssize_t n = readlink(fd_link, resolved_path, resolved_cap - 1);
    if (n < 0 || (size_t)n >= resolved_cap) {
        close(file_fd);
        free(real_root);
        return -1;
    }
    resolved_path[n] = '\0';

    int confined = path_is_under_root(resolved_path, real_root);
    free(real_root);
    if (!confined) {
        close(file_fd);
        return -1;
    }

    *out_fd = file_fd;
    return 1;
}

static void generate_session_id(char *buf, int len) {
    unsigned char raw[16];
    FILE *urand = fopen("/dev/urandom", "rb");
    if (urand && fread(raw, 1, 16, urand) == 16) {
        fclose(urand);
        int pos = snprintf(buf, len, "sess_");
        for (int i = 0; i < 16 && pos + 2 < len; i++)
            pos += snprintf(buf + pos, len - pos, "%02x", raw[i]);
        return;
    }
    if (urand) fclose(urand);
    snprintf(buf, len, "sess_%lx_%ld", (unsigned long)time(NULL), (long)getpid());
}

/* Per-connection total deadline: 30 seconds for entire request (header + body).
 * Uses monotonic clock — not reset by progress, so slow-trickle attacks are bounded.
 * SO_RCVTIMEO is set to 5s as a per-read backstop (prevents blocking on a fully idle socket). */
#define HTTP_REQUEST_DEADLINE_SEC 30
#define HTTP_READ_TIMEOUT_SEC 5

/* Header-phase controls (slow-loris). The client has nothing to compute before
 * sending its request headers, so a slow HEADER phase is a slow-loris, not a
 * slow upload — it gets a tighter budget than the 30s total-request deadline
 * (which must accommodate a legitimately large body). Two independent bounds,
 * both applied only until the "\r\n\r\n" terminator is seen:
 *
 *   - a hard header deadline (default 10s), and
 *   - a minimum sustained byte rate (Apache mod_reqtimeout's MinRate): after a
 *     short grace period the connection must have averaged at least this many
 *     bytes/sec toward its headers. A fixed deadline alone lets a ~1 byte/sec
 *     trickle hold a worker for the FULL deadline; the rate floor drops it in
 *     one read cycle (~grace+timeout) instead. A real client sends its whole
 *     header block in one packet and exits the header phase before either bound
 *     is ever evaluated.
 *
 * Both overridable (EIGS_HTTP_HEADER_TIMEOUT / EIGS_HTTP_HEADER_MIN_RATE);
 * min-rate 0 disables the rate floor (the hard deadline still applies). */
#define HTTP_HEADER_DEADLINE_SEC 10
#define HTTP_HEADER_MIN_RATE     256   /* bytes/sec */
#define HTTP_HEADER_GRACE_SEC    2

static long http_header_deadline(void) {
    const char *env = getenv("EIGS_HTTP_HEADER_TIMEOUT");
    if (env && *env) {
        char *end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && v > 0) return v;
    }
    return HTTP_HEADER_DEADLINE_SEC;
}

static long http_header_min_rate(void) {
    const char *env = getenv("EIGS_HTTP_HEADER_MIN_RATE");
    if (env && *env) {
        char *end = NULL;
        long v = strtol(env, &end, 10);
        if (end != env && v >= 0) return v;
    }
    return HTTP_HEADER_MIN_RATE;
}

static double monotonic_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Find the request's Content-Length by walking the header block LINE BY LINE.
 *
 * The previous strcasestr() over the whole block took the first match anywhere,
 * so a decoy anywhere earlier framed the body: inside another header's VALUE
 * (`X-Note: Content-Length: 0`), as a suffix of another header's NAME
 * (`X-Content-Length: 0`), or in the request target
 * (`POST /x?q=Content-Length:0`). The server then framed the body at the decoy's
 * length and broke out of the read loop, dispatching a `code` route with an
 * empty or partial body — and let a client hide an oversized real length behind
 * a small fake one, dodging the `> max_body` 400.
 *
 * Matching only at a line start, with the colon required immediately after the
 * name (RFC 7230 forbids whitespace there), closes all three. The request line
 * is skipped outright rather than relying on it never starting with the name.
 *
 * Returns 1 and sets *out_len when present, 0 when absent, -1 when malformed —
 * unparseable, trailing garbage, or two Content-Length headers that disagree
 * (previously the first silently won).
 *
 * `block` is NUL-terminated at the end of the header block, terminator included.
 */
static int http_find_content_length(const char *block, long *out_len) {
    const char *p = strstr(block, "\r\n");
    if (!p) return 0;                       /* request line only, no headers */
    p += 2;

    int found = 0;
    long value = 0;

    while (*p) {
        if (p[0] == '\r' && p[1] == '\n') break;      /* blank line: block ends */
        const char *eol = strstr(p, "\r\n");
        size_t linelen = eol ? (size_t)(eol - p) : strlen(p);

        if (linelen > 14 && strncasecmp(p, "Content-Length", 14) == 0 && p[14] == ':') {
            const char *v = p + 15;
            while (*v == ' ' || *v == '\t') v++;
            char *end = NULL;
            long n = strtol(v, &end, 10);
            if (end == v) return -1;                  /* no digits at all */
            while (*end == ' ' || *end == '\t') end++;
            if (end != p + linelen) return -1;        /* trailing garbage */
            if (found && n != value) return -1;       /* conflicting duplicates */
            found = 1;
            value = n;
        }

        if (!eol) break;
        p = eol + 2;
    }

    if (found) *out_len = value;
    return found;
}

static void handle_request(int fd) {
    /* Per-read timeout (backstop for fully idle sockets) */
    struct timeval tv = { .tv_sec = HTTP_READ_TIMEOUT_SEC, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    double start = monotonic_now();
    double total_deadline  = start + HTTP_REQUEST_DEADLINE_SEC;
    double header_deadline = start + (double)http_header_deadline();
    long   header_min_rate = http_header_min_rate();

    long max_body = http_max_body();
    long max_body_total = http_max_body_total();
    size_t cap = 8192;
    char *reqbuf = xmalloc(cap);
    /* Bytes this connection has charged to the global in-flight budget; mirrors
     * `cap` exactly so the decrement at `cleanup` is always balanced. */
    long body_accounted = (long)cap;
    __atomic_add_fetch(&g_http_body_in_flight, body_accounted, __ATOMIC_RELAXED);
    int total = 0;
    int header_end = -1;

    for (;;) {
        double now = monotonic_now();
        /* Enforce total request deadline */
        if (now >= total_deadline) {
            goto done;
        }
        /* Header-phase bounds (slow-loris): only while the header terminator
         * has not been seen. A legitimate client clears this in one read. */
        if (header_end < 0) {
            if (now >= header_deadline) {
                const char *m = "Request header timeout";
                send_response(fd, 408, "Request Timeout", "text/plain",
                              m, (long)strlen(m));
                goto done;
            }
            double elapsed = now - start;
            if (header_min_rate > 0 && elapsed > HTTP_HEADER_GRACE_SEC &&
                (double)total < (double)header_min_rate * elapsed) {
                /* Below the minimum header byte-rate after the grace period —
                 * a trickle. Drop it now instead of letting it hold a worker
                 * slot until the total deadline. */
                const char *m = "Request header too slow";
                send_response(fd, 408, "Request Timeout", "text/plain",
                              m, (long)strlen(m));
                goto done;
            }
        }
        /* Grow when less than 4KB headroom, subject to max_body + 64KB header slack. */
        if ((size_t)total + 4096 >= cap) {
            size_t new_cap = cap * 2;
            size_t hard_cap = (size_t)max_body + 65536;
            if (new_cap > hard_cap) new_cap = hard_cap;
            if (new_cap == cap) {
                /* Already at ceiling. If we still have not seen the header
                 * terminator, the headers themselves exceeded our budget —
                 * answer 431 instead of letting sscanf parse a truncated
                 * prefix as a "valid" request. */
                if (header_end < 0) {
                    const char *m = "Headers too large";
                    send_response(fd, 431, "Request Header Fields Too Large",
                                  "text/plain", m, (long)strlen(m));
                    goto done;
                }
                break;
            }
            /* Aggregate-body budget: charge the growth to the global counter
             * BEFORE allocating. If the total in-flight across all connections
             * would exceed the budget, shed THIS connection with 503 rather
             * than let conns x per-conn-cap exhaust host memory. */
            long inc = (long)new_cap - body_accounted;
            long in_flight = __atomic_add_fetch(&g_http_body_in_flight, inc,
                                                __ATOMIC_RELAXED);
            body_accounted = (long)new_cap;
            if (in_flight > max_body_total) {
                const char *m = "Server overloaded";
                send_response(fd, 503, "Service Unavailable", "text/plain",
                              m, (long)strlen(m));
                goto done;
            }
            reqbuf = xrealloc_array(reqbuf, new_cap, 1);
            cap = new_cap;
        }
        int n = read(fd, reqbuf + total, cap - 1 - total);
        if (n <= 0) break;
        total += n;
        reqbuf[total] = '\0';

        char *hend = strstr(reqbuf, "\r\n\r\n");
        if (hend) {
            header_end = (int)(hend - reqbuf) + 4;

            /* Search only within headers (before \r\n\r\n), not in body */
            char saved = reqbuf[header_end];
            reqbuf[header_end] = '\0';
            long content_length = 0;
            int cl = http_find_content_length(reqbuf, &content_length);
            reqbuf[header_end] = saved;
            if (cl != 0) {
                /* strtol rather than atoi, which silently accepts negative and
                 * non-numeric input; a negative Content-Length would make
                 * body_received trivially >= content_length and exit the read
                 * loop mid-body. Reject anything outside [0, max_body], and any
                 * header the line parser flagged as malformed. */
                if (cl < 0 || content_length < 0 || content_length > max_body) {
                    /* Malformed or oversized Content-Length — answer 400 so
                     * the client sees a real error instead of hanging until
                     * the per-connection deadline. */
                    const char *m = "Invalid Content-Length";
                    send_response(fd, 400, "Bad Request", "text/plain",
                                  m, (long)strlen(m));
                    goto done;
                }
                int body_received = total - header_end;
                if (body_received >= content_length) break;
            } else {
                break;
            }
        }
    }

    if (total == 0) { goto done; }
    reqbuf[total] = '\0';

    char method[16] = {0}, path[2048] = {0}, version[16] = {0};
    if (sscanf(reqbuf, "%15s %2047s %15s", method, path, version) != 3) {
        send_response(fd, 400, "Bad Request", "text/plain", "Invalid request line", 20);
        goto done;
    }

    /* Validate HTTP version: must start with "HTTP/" followed by digit. The
     * previous code accepted anything (e.g. "HTTP/junk") because sscanf only
     * checks length. Strict here keeps downgrade/parser games out. */
    if (strncmp(version, "HTTP/", 5) != 0 ||
        !isdigit((unsigned char)version[5])) {
        send_response(fd, 400, "Bad Request", "text/plain", "Invalid HTTP version", 20);
        goto done;
    }

    /* Split off any query string: the request target's `?...` is request data,
     * not part of the route identity (a route on /ping must match /ping?x=1).
     * Route and static matching below use the path component only. The raw
     * request line stays intact in reqbuf (http_request_headers), so a script
     * can still read the query string from there (lib/http.eigs parse_query). */
    char *qmark = strchr(path, '?');
    if (qmark) *qmark = '\0';

    char *body = NULL;
    if (header_end > 0 && header_end < total) {
        body = reqbuf + header_end;
    }

    if (strcmp(method, "OPTIONS") == 0) {
        /* Proper preflight: advertise the methods this server handles and
         * mirror CORS headers when configured. 204 No Content is the more
         * RFC-correct reply for an empty-body preflight. */
        send_response_full(fd, 204, "No Content", NULL, NULL, 0, 1, "");
        goto done;
    }

    /* HEAD: route as if it were GET, but suppress the body in send_response. */
    int is_head = (strcmp(method, "HEAD") == 0);
    if (is_head) {
        memcpy(method, "GET", 4);
        tls_suppress_body = 1;
    }

    char sess_id[64];
    generate_session_id(sess_id, sizeof(sess_id));
    tls_session_id = sess_id;
    tls_request_body = body ? body : "";
    tls_request_headers = reqbuf;

    if (g_server.static_prefix) {
        size_t pfx_len = strlen(g_server.static_prefix);
        /* Match prefix only at a path-segment boundary (followed by '/' or end of string) */
        if (strncmp(path, g_server.static_prefix, pfx_len) == 0 &&
            (path[pfx_len] == '/' || path[pfx_len] == '\0')) {
        const char *rel = path + strlen(g_server.static_prefix);
        if (rel[0] == '/') rel++;
        if (rel[0] == '/') {
            send_response(fd, 403, "Forbidden", "text/plain", "Forbidden", 9);
            goto done;
        }

        char resolved_path[4096];
        int static_fd = -1;
        int open_status = open_static_file_confined(g_server.static_dir, rel,
                                                    resolved_path, sizeof(resolved_path),
                                                    &static_fd);
        if (open_status == 0) {
            send_404(fd, path);
            goto done;
        }
        if (open_status < 0) {
            send_response(fd, 403, "Forbidden", "text/plain", "Forbidden", 9);
            goto done;
        }
        send_open_file(fd, static_fd, resolved_path);
        close(static_fd);
        goto done;
    }}

    for (int i = 0; i < g_server.route_count; i++) {
        Route *r = &g_server.routes[i];
        if (strcmp(r->method, method) == 0 && strcmp(r->path, path) == 0) {
            if (strcmp(r->kind, "file") == 0) {
                send_file(fd, r->payload);
            } else if (strcmp(r->kind, "code") == 0) {
                /* Code routes evaluate against the worker state's global env
                 * (g_global_env), not the spawning state's. The worker was
                 * spun up in http_conn_thread with a fresh stdlib but no
                 * startup-defined globals — concurrent requests don't race
                 * on script state and mutations don't leak across requests.
                 *
                 * Route-level auth: the auth source is either a string
                 * stashed at shared_get("require_auth") — the cross-worker
                 * config path startup scripts use — or, as a legacy
                 * fallback, a require_auth fn defined in the worker env
                 * (only populated by future host setup; the default
                 * worker env never has it). Empty result = allow; any
                 * non-empty value_to_string output becomes the 401 body. */
                if (r->requires_auth) {
                    char *auth_src = NULL;
                    Server *srv = eigs_http_active;
                    if (srv) {
                        pthread_mutex_lock(&srv->shared_mu);
                        int idx = shared_find(srv, "require_auth");
                        if (idx >= 0) {
                            int jpos = 0;
                            Value *parsed = eigs_json_parse_root(srv->shared[idx].json, &jpos);   /* #777 */
                            if (parsed && parsed->type == VAL_STR) {
                                auth_src = xstrdup(parsed->data.str);
                            }
                            val_decref(parsed);
                        }
                        pthread_mutex_unlock(&srv->shared_mu);
                    }
                    if (!auth_src) {
                        Value *auth_fn = env_get(g_global_env, "require_auth");
                        if (!auth_fn || (auth_fn->type != VAL_FN && auth_fn->type != VAL_BUILTIN)) {
                            send_response(fd, 500, "Internal Server Error", "application/json",
                                "{\"error\": \"require_auth not defined or not callable\"}", 53);
                            goto done;
                        }
                        auth_src = xstrdup("require_auth of null");
                    }
                    TokenList auth_tl = tokenize(auth_src);
                    ASTNode *auth_ast = parse(&auth_tl);
                    Env *auth_env = env_new(g_global_env);
                    EigsChunk *auth_chunk = compile_ast(auth_ast, auth_env, auth_src);
                    Value *auth_result = vm_execute(auth_chunk, auth_env);
                    chunk_free(auth_chunk);
                    env_decref(auth_env);
                    char *auth_str = value_to_string(auth_result);
                    free_tokenlist(&auth_tl);
                    free(auth_src);
                    free_ast(auth_ast);  /* compile_ast does not own it */
                    if (auth_result) val_decref(auth_result);  /* vm_execute returns an owned ref */
                    if (auth_str[0] != '\0') {
                        send_response(fd, 401, "Unauthorized", "application/json",
                                      auth_str, strlen(auth_str));
                        free(auth_str);
                        goto done;
                    }
                    free(auth_str);
                }
                TokenList tl = tokenize(r->payload);
                ASTNode *ast = parse(&tl);
                Env *req_env = env_new(g_global_env);
                EigsChunk *req_chunk = compile_ast(ast, req_env, r->payload);
                Value *result = vm_execute(req_chunk, req_env);
                chunk_free(req_chunk);
                char *result_str = value_to_string(result);
                env_decref(req_env);

                const char *ct = "application/json";
                if (result_str[0] != '{' && result_str[0] != '[')
                    ct = "text/plain";
                send_response(fd, 200, "OK", ct, result_str, strlen(result_str));
                free(result_str);
                free_tokenlist(&tl);
                free_ast(ast);  /* compile_ast does not own it */
                if (result) val_decref(result);  /* vm_execute returns an owned ref */
            } else {
                const char *ct = "application/json";
                if (r->payload[0] != '{' && r->payload[0] != '[')
                    ct = "text/plain";
                send_response(fd, 200, "OK", ct, r->payload, strlen(r->payload));
            }
            goto done;
        }
    }

    send_404(fd, path);
done:
    tls_request_body = NULL;
    tls_request_headers = NULL;
    tls_session_id = NULL;
    tls_suppress_body = 0;
    /* Release this connection's share of the aggregate in-flight body budget.
     * Every exit path funnels through here, so the charge made during the read
     * loop is always balanced (body_accounted mirrors the final `cap`). */
    __atomic_sub_fetch(&g_http_body_in_flight, body_accounted, __ATOMIC_RELAXED);
    free(reqbuf);
    close(fd);
}

/* Detached worker thread: owns the client fd, runs the request, decrements
 * the live-connection counter on exit. The accept loop hands ownership of
 * the malloc'd ConnArg and never touches it again.
 *
 * Per-worker isolation: each connection gets a fresh EigsState with stdlib
 * + per-request HTTP builtins registered. `code` routes (kind="code")
 * evaluate against the worker state's env, so concurrent requests don't
 * race on script globals and one request's mutations never leak into the
 * next. `eigs_http_active` is then pointed at the spawning state's Server
 * so route-table lookups in handle_request still hit the main routes that
 * the startup script registered. */
typedef struct {
    int fd;
    Server *server;
    uint32_t client_addr;   /* for the per-IP connection cap release */
} ConnArg;

static void *http_conn_thread(void *arg) {
    ConnArg *ca = arg;
    int fd = ca->fd;
    Server *main_server = ca->server;
    uint32_t client_addr = ca->client_addr;
    free(ca);

    EigsState *worker = eigs_state_new();
    if (!worker) goto drop;
    if (!eigs_thread_attach(worker)) {
        eigs_state_destroy(worker);
        goto drop;
    }

    Env *global = env_new(NULL);
    register_builtins(global);   /* one seam: store/gfx ride inside (#742) */
    g_global_env = global;

    /* register_http_builtins allocated a scratch Server on the worker
     * state (so http_route/http_serve called inside a code route don't
     * crash) and pointed eigs_http_active at it. Re-point at the spawning
     * Server so handle_request reads the main route table. */
    eigs_http_active = main_server;

    handle_request(fd);
    fd = -1;  /* handle_request closed it */

    /* #739: NO trace_shutdown() here. This worker owns one connection, not the
     * process — calling it closed the process tape after the FIRST request
     * (every later request's records silently lost), dropped an embedder's
     * trace sink, and decref'd prev-table slots recorded by other still-live
     * threads. This thread's own prev-table is released by eigs_thread_detach
     * below, beside the other per-thread destructors. */
    gc_collect_at_exit(global);
    env_decref(global);
    g_global_env = NULL;
    eigs_thread_detach();
    eigs_state_destroy(worker);
    goto done;

drop:
    if (fd >= 0) close(fd);
done:
    __atomic_sub_fetch(&g_conn_count, 1, __ATOMIC_RELAXED);
    ip_conn_release(client_addr);
    return NULL;
}

void http_serve_blocking(int port) {
    int server_fd;

    if (g_server.early_bind_fd >= 0) {
        stop_init_responder(eigs_http_active);
        server_fd = g_server.early_bind_fd;
        printf("EigenScript HTTP server accepting on pre-bound 0.0.0.0:%d\n", port);
    } else {
        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd < 0) {
            perror("socket");
            return;
        }

        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(port);

        if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            perror("bind");
            close(server_fd);
            return;
        }

        if (listen(server_fd, HTTP_MAX_CONCURRENT_CONNS) < 0) {
            perror("listen");
            close(server_fd);
            return;
        }

        printf("EigenScript HTTP server listening on 0.0.0.0:%d\n", port);
    }
    fflush(stdout);

    signal(SIGPIPE, SIG_IGN);

    pthread_attr_t worker_attr;
    pthread_attr_init(&worker_attr);
    pthread_attr_setdetachstate(&worker_attr, PTHREAD_CREATE_DETACHED);
    /* Keep default stack size — VM TLS sits off-stack so workers are not
     * stack-heavy, and shrinking the default tripped EINVAL on glibc here. */

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr*)&client_addr, &client_len);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }

        struct timeval tv;
        tv.tv_sec = 10;
        tv.tv_usec = 0;
        setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        /* Load-shed: when over the connection cap, send 503 and move on so
         * one slow client cannot stall the whole listener. */
        int cur = __atomic_load_n(&g_conn_count, __ATOMIC_RELAXED);
        if (cur >= HTTP_MAX_CONCURRENT_CONNS) {
            send_response_full(client_fd, 503, "Service Unavailable", "text/plain",
                               "Overloaded\n", 11, 0, "");
            close(client_fd);
            continue;
        }

        /* Per-source-IP cap: one address may not hold all the global slots.
         * Shed with 503 before spending a worker on it. */
        uint32_t caddr = client_addr.sin_addr.s_addr;
        if (!ip_conn_acquire(caddr)) {
            send_response_full(client_fd, 503, "Service Unavailable", "text/plain",
                               "Too many connections\n", 21, 0, "");
            close(client_fd);
            continue;
        }

        ConnArg *ca = xmalloc(sizeof(*ca));
        ca->fd = client_fd;
        ca->server = eigs_http_active;
        ca->client_addr = caddr;
        pthread_t tid;
        __atomic_add_fetch(&g_conn_count, 1, __ATOMIC_RELAXED);
        if (pthread_create(&tid, &worker_attr, http_conn_thread, ca) != 0) {
            __atomic_sub_fetch(&g_conn_count, 1, __ATOMIC_RELAXED);
            ip_conn_release(caddr);
            free(ca);
            close(client_fd);
        }
    }
}



/* ================================================================
 * HTTP BUILTIN REGISTRATION
 * ================================================================ */

/* http_cors of origin — configure CORS. Pass "*" for wildcard, null to disable. */
static Value* builtin_http_cors(Value *arg) {
    if (!arg || arg->type == VAL_NULL) {
        pthread_mutex_lock(&g_server.response_mu);
        free(g_server.cors_origin);
        g_server.cors_origin = NULL;
        pthread_mutex_unlock(&g_server.response_mu);
        return make_str("cors disabled");
    }
    if (arg->type != VAL_STR) return make_null();
    /* Strip CR/LF to prevent header injection */
    char *clean = xstrdup(arg->data.str);
    http_strip_crlf(clean);
    pthread_mutex_lock(&g_server.response_mu);
    free(g_server.cors_origin);
    g_server.cors_origin = clean;
    pthread_mutex_unlock(&g_server.response_mu);
    return make_str(clean);
}

/* Per-request builtins only: read the current request's body / session /
 * headers, send an outbound http_post, and the shared-store API used to
 * communicate across worker code routes. No Server allocation, no
 * eigs_http_active wiring. Safe to call on a fresh worker state. */
void register_http_request_builtins(Env *env) {
    /* Expanded from ext_names.h — the shared name list the linter's E003
     * binding base also expands, so registration and name-resolution
     * cannot drift. Add a builtin there, not here. */
#define X(name, fn) env_set_local_owned(env, #name, make_builtin(fn));
    EIGS_HTTP_REQUEST_BUILTINS(X)
#undef X
}

void register_http_builtins(Env *env) {
    /* Lazily allocate the per-state Server on first registration and wire
     * the active-pointer TLS for this thread. Idempotent: a second call
     * (e.g. REPL re-registering after a reset) reuses the existing Server
     * but resets the env binding to whatever the caller just built. */
    EigsState *st = eigs_current->state;
    if (!st->ext_http_server) {
        st->ext_http_server = xcalloc(1, sizeof(Server));
        pthread_mutex_init(&st->ext_http_server->shared_mu, NULL);
        pthread_mutex_init(&st->ext_http_server->response_mu, NULL);
        st->ext_http_server->early_bind_fd = -1;
    }
    eigs_http_active = st->ext_http_server;
    g_server.global_env = env;

#define X(name, fn) env_set_local_owned(env, #name, make_builtin(fn));
    EIGS_HTTP_BUILTINS(X)
#undef X
    register_http_request_builtins(env);
}

void ext_http_state_destroy(EigsState *st) {
    if (!st) return;
    Server *s = st->ext_http_server;
    if (!s) return;
    stop_init_responder(s);
    if (s->early_bind_fd >= 0) close(s->early_bind_fd);
    free(s->liveness_path);
    pthread_mutex_destroy(&s->response_mu);
    for (int i = 0; i < s->route_count; i++) {
        free(s->routes[i].method);
        free(s->routes[i].path);
        free(s->routes[i].kind);
        free(s->routes[i].payload);
    }
    free(s->static_prefix);
    free(s->static_dir);
    free(s->cors_origin);
    for (int i = 0; i < s->shared_count; i++) {
        free(s->shared[i].key);
        free(s->shared[i].json);
    }
    free(s->shared);
    pthread_mutex_destroy(&s->shared_mu);
    /* global_env is aliased, not owned — env teardown happens in eigs_close
     * before this runs. The init responder is joined before any config is
     * freed, even when the script exits without ever calling http_serve. */
    free(s);
    st->ext_http_server = NULL;
    /* Clear the main thread's active pointer if it pointed here. Worker
     * threads die before the state does (http_serve returns or process
     * exits), so theirs is already gone. */
    if (eigs_http_active == s) eigs_http_active = NULL;
}
