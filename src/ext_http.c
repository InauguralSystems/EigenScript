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
#include "fsutil.h"
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <dlfcn.h>
#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

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
/* The read loop's framing decision, including its terminating empty line.
 * -1 means it found no head. Borrowed bytes live until handle_request ends;
 * no parsing or allocation is done until a route asks for a header. */
static __thread int tls_request_head_end = -1;
static __thread const char *tls_session_id = NULL;
/* Set when serving a HEAD request — send_response writes the header but
 * skips the body. */
static __thread int tls_suppress_body = 0;
/* Init-responder writes: send() with MSG_DONTWAIT. A peer that is not
 * reading is abandoned (connection closed); the responder never blocks. */
static __thread int tls_write_nowait = 0;

/* Owned by handle_request's stack and accessed only on its answering thread.
 * No Value is retained across VM evaluation, and spawned threads start with
 * a NULL pointer. Cooperative tasks share the answering thread's response. */
typedef struct { char *name, *value; } RouteHeader;
/* headers is in the order each name was first set, which is the order they
 * are sent in. by_name is the same headers sorted by name without case:
 * by_name[k] is the index of the k-th. A name is then found by bisection, in
 * a call and when the response is written, however many names a program
 * sets; a new name is inserted at its place. */
typedef struct {
    int status;
    RouteHeader *headers;
    int *by_name;
    int header_count;
    int header_room;   /* entries that headers and by_name can hold */
    char **cookies;
    int cookie_count;
    size_t bytes;
} RouteResponse;
static __thread RouteResponse *tls_response = NULL;
#define HTTP_ROUTE_RESPONSE_MAX 65536u

static void route_response_clear(RouteResponse *r) {
    for (int i = 0; i < r->header_count; i++) {
        free(r->headers[i].name);
        free(r->headers[i].value);
    }
    for (int i = 0; i < r->cookie_count; i++) free(r->cookies[i]);
    free(r->headers);
    free(r->by_name);
    free(r->cookies);
    memset(r, 0, sizeof *r);
}

/* The index of the header called `name`, or -1. `where`, when given, receives
 * its place among the sorted names, or the place it would take there. */
static int route_header_find(const RouteResponse *r, const char *name, int *where) {
    int lo = 0, hi = r->header_count;
    while (lo < hi) {
        int mid = lo + (hi - lo) / 2;
        int found = r->by_name[mid];
        int c = strcasecmp(name, r->headers[found].name);
        if (c == 0) {
            if (where) *where = mid;
            return found;
        }
        if (c < 0) hi = mid;
        else lo = mid + 1;
    }
    if (where) *where = lo;
    return -1;
}

/* Orders the names of one call, to find two that differ only in case. */
static int route_name_cmp(const void *a, const void *b) {
    return strcasecmp(*(const char *const *)a, *(const char *const *)b);
}

static const char *route_header_value(const RouteResponse *r, const char *name,
                                      const char *fallback) {
    int i = r ? route_header_find(r, name, NULL) : -1;
    return i < 0 ? fallback : r->headers[i].value;
}

static Value *route_response_error(ErrKind kind, const char *message) {
    rt_error(kind, 0, "http_respond: %s", message);
    return make_null();
}

static int route_header_name_valid(const char *name) {
    size_t n = strlen(name);
    if (n < 1 || n > 64) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)name[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || strchr("!#$%&'*+-.^_`|~", c))) return 0;
    }
    return strcasecmp(name, "Content-Length") != 0 &&
           strcasecmp(name, "Transfer-Encoding") != 0 &&
           strcasecmp(name, "Connection") != 0 &&
           strcasecmp(name, "Set-Cookie") != 0;
}

static int route_header_value_valid(const char *value, size_t len) {
    if (len && (value[0] == ' ' || value[0] == '\t' ||
                value[len - 1] == ' ' || value[len - 1] == '\t')) return 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)value[i];
        if ((c < 32 && c != '\t') || c > 126) return 0;
    }
    return 1;
}

/* Validation and size accounting finish before any mutation. In particular a
 * late bad cookie, a duplicate name, or the byte limit cannot partially set
 * a status/header. Script text never reaches the wire without validation. */
/* http_respond of response — set this request's status, headers and cookies; return null. */
Value *builtin_http_respond(Value *arg) {
    if (!tls_response)
        return route_response_error(EK_VALUE, "no request is being answered");
    if (!arg || arg->type != VAL_DICT)
        return route_response_error(EK_TYPE, "response must be a dict");
    RouteResponse *r = tls_response;
    Value *headers = NULL, *cookies = NULL;
    int64_t status = r->status;
    for (int i = 0; i < arg->data.dict.count; i++) {
        const char *key = arg->data.dict.keys[i];
        EIGS_VIEW(view);
        Value *value = dict_value_get_view(arg, i, &view);
        if (strcmp(key, "status") == 0) {
            if (!eigs_int_arg_range(value, 200, 599, &status, "http_respond"))
                return make_null();
        } else if (strcmp(key, "headers") == 0) {
            if (value->type != VAL_DICT)
                return route_response_error(EK_TYPE, "headers must be a dict");
            headers = value;  /* heap container, not the numeric view */
        } else if (strcmp(key, "cookies") == 0) {
            if (value->type != VAL_LIST)
                return route_response_error(EK_TYPE, "cookies must be a list");
            cookies = value;
        } else return route_response_error(EK_VALUE, "unknown response key");
    }
    /* A name is looked up among the sorted names of what this request has
     * set, and this call's own names are sorted once to find two that differ
     * only in case, so neither one call with thousands of names nor thousands
     * of calls compare every pair. Replacements may shrink the state: all removals are
     * applied before the additions are checked, so a valid final size never
     * depends on dictionary order. */
    int hn = headers ? headers->data.dict.count : 0;
    const char **names = NULL;
    Value *refused = NULL;
    size_t bytes = r->bytes;
    if (hn) {
        names = xmalloc_array((size_t)hn, sizeof *names);
        for (int i = 0; i < hn; i++) {
            const char *name = headers->data.dict.keys[i];
            EIGS_VIEW(view);
            Value *value = dict_value_get_view(headers, i, &view);
            if (!route_header_name_valid(name))
                refused = route_response_error(EK_VALUE, "invalid or reserved header name");
            else if (value->type != VAL_STR)
                refused = route_response_error(EK_TYPE, "header value must be a string");
            else if (!route_header_value_valid(value->data.str, val_str_len(value)))
                refused = route_response_error(EK_VALUE, "invalid header value");
            if (refused) goto done;
            names[i] = name;
            int old = route_header_find(r, name, NULL);
            if (old >= 0)
                bytes -= strlen(r->headers[old].name) + strlen(r->headers[old].value) + 4;
        }
        qsort(names, (size_t)hn, sizeof *names, route_name_cmp);
        for (int i = 1; i < hn; i++)
            if (strcasecmp(names[i - 1], names[i]) == 0) {
                refused = route_response_error(EK_VALUE, "duplicate header name");
                goto done;
            }
        for (int i = 0; i < hn; i++) {
            EIGS_VIEW(view);
            Value *value = dict_value_get_view(headers, i, &view);
            size_t n = strlen(headers->data.dict.keys[i]) + 4;
            size_t v = val_str_len(value);
            if (v > HTTP_ROUTE_RESPONSE_MAX || n + v > HTTP_ROUTE_RESPONSE_MAX - bytes) {
                refused = route_response_error(EK_LIMIT, "response headers and cookies exceed 65536 bytes");
                goto done;
            }
            bytes += n + v;
        }
    }
    if (cookies) for (int i = 0; i < cookies->data.list.count; i++) {
        EIGS_VIEW(view);
        Value *value = list_get_view(cookies, i, &view);
        size_t n = value->type == VAL_STR ? val_str_len(value) : 0;
        if (value->type != VAL_STR)
            refused = route_response_error(EK_TYPE, "cookie must be a string");
        else if (!n || !route_header_value_valid(value->data.str, n))
            refused = route_response_error(EK_VALUE, "invalid cookie");
        else if (n > HTTP_ROUTE_RESPONSE_MAX || n + 14 > HTTP_ROUTE_RESPONSE_MAX - bytes)
            refused = route_response_error(EK_LIMIT, "response headers and cookies exceed 65536 bytes");
        if (refused) goto done;
        bytes += n + 14;  /* Set-Cookie: <value> CR LF */
    }
    /* No fallible language operation remains. Keep first-set name/order.
     * Room is made for every name of the call, new or not, so that no
     * insertion below can pass the end of an array whatever a search returns.
     * It at least doubles when it grows, so a route that sets its headers
     * one call at a time does not copy both arrays on every call. */
    if (r->header_count + hn > r->header_room) {
        int room = r->header_count + hn;
        if (room < 2 * r->header_room) room = 2 * r->header_room;
        r->headers = xrealloc_array(r->headers, (size_t)room, sizeof *r->headers);
        r->by_name = xrealloc_array(r->by_name, (size_t)room, sizeof *r->by_name);
        r->header_room = room;
    }
    for (int i = 0; i < hn; i++) {
        const char *name = headers->data.dict.keys[i];
        EIGS_VIEW(view);
        Value *value = dict_value_get_view(headers, i, &view);
        int where;
        int at = route_header_find(r, name, &where);
        if (at < 0) {
            /* A new name takes the next place in the order of sending, and
             * its own place among the sorted names. */
            at = r->header_count;
            memmove(r->by_name + where + 1, r->by_name + where,
                    (size_t)(at - where) * sizeof *r->by_name);
            r->by_name[where] = at;
            r->headers[at].name = xstrdup(name);
            r->headers[at].value = NULL;
            r->header_count++;
        }
        free(r->headers[at].value);
        r->headers[at].value = xstrdup(value->data.str);
    }
    if (cookies && cookies->data.list.count) {
        int count = cookies->data.list.count;
        r->cookies = xrealloc_array(r->cookies, (size_t)r->cookie_count + (size_t)count,
                                    sizeof *r->cookies);
        for (int i = 0; i < count; i++) {
            EIGS_VIEW(view);
            r->cookies[r->cookie_count++] = xstrdup(list_get_view(cookies, i, &view)->data.str);
        }
    }
    r->status = (int)status;
    r->bytes = bytes;
done:
    free(names);
    return refused ? refused : make_null();
}

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

/* Every lazily-initialised env-override cache above and below is a plain
 * global first written on whichever thread happens to ask first. Worker
 * connection threads and the init responder all ask, so under TSan each one
 * is a data race (#1137 — http_max_body was the reported instance; the class
 * is every such cache). Prime them ONCE on the main thread before any thread
 * is created: pthread_create is the happens-before edge, and afterwards every
 * reader sees an initialised value and never writes. */
static long shared_max_bytes(void);
static long http_max_head(void);
static void http_prime_config_caches(void) {
    (void)http_max_head();
    (void)http_max_conn_per_ip();
    (void)http_max_body();
    (void)http_max_body_total();
    (void)shared_max_bytes();
}

/* All response sites share this builder. `cache_cors` preserves the old
 * load-shed headers; OPTIONS has no Content-Type/Length. Extra fields are
 * runtime-owned literals (Retry-After), never caller text. Names this
 * function emits are refused by http_response_header so a registration
 * cannot duplicate a runtime line. */
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
    tls_write_nowait = 1;
    send_response_full(c->fd, live ? 200 : 503,
                       live ? "OK" : "Service Unavailable", "text/plain",
                       live ? "OK" : "Server initializing\n", live ? 2 : 20,
                       1, live ? "" : "Retry-After: 1\r\n");
    tls_write_nowait = 0;
    free(c->line);
    close(c->fd);
    c->line = NULL;
    c->fd = -1;
    tls_suppress_body = 0;
}

static void init_conn_open(Server *s, InitConn *c, int fd) {
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
     * the same wire image: 503, Retry-After, Content-Length 0, no body.
     * The write is non-blocking: a peer that is not reading is closed. */
    (void)s;
    tls_write_nowait = 1;
    tls_suppress_body = 1;
    send_response_full(fd, 503, "Service Unavailable", "text/plain",
                       "", 0, 1, "Retry-After: 1\r\n");
    tls_write_nowait = 0;
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

/* #1140: the route table and static roots are frozen once http_serve starts.
 * Workers read them lock-free, and a code route's worker points g_server at
 * the SPAWNING server, so a registration from a code route used to write the
 * live table (route_count++ with no fence, static configuration swapped under
 * readers). Refuse, the way http_response_header already does; every
 * lock-free read then sees immutable data. `serving` is only written under
 * response_mu, so it is read there too. */
static int http_config_frozen(const char *who) {
    pthread_mutex_lock(&g_server.response_mu);
    int serving = g_server.serving;
    pthread_mutex_unlock(&g_server.response_mu);
    if (serving)
        rt_error(EK_VALUE, 0, "%s: must register before http_serve (the route table "
                              "and static root are frozen while serving)", who);
    return serving;
}

static Value *http_route_register(Value *arg, int requires_auth) {
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
        if (route_slot_is_callable(list_get_view(arg, i, &(EigsView){{0}}))) {
            rt_error(EK_TYPE, 0, "http_route: %s must be a string, not a function",
                     i == 0 ? "method" : "path");
            return make_null();
        }
    }
    if (arg->data.list.count >= 4) {
        if (route_slot_is_callable(list_get_view(arg, 2, &(EigsView){{0}}))) {
            rt_error(EK_TYPE, 0, "http_route: kind must be a string, not a function "
                                 "(expected \"code\" or \"static\")");
            return make_null();
        }
        if (route_slot_is_callable(list_get_view(arg, 3, &(EigsView){{0}}))) {
            rt_error(EK_TYPE, 0, "http_route: the code form's source must be a string of "
                                 "EigenScript source, not a function — "
                                 "http_route of [method, path, \"code\", \"return 42\"]");
            return make_null();
        }
    } else if (route_slot_is_callable(list_get_view(arg, 2, &(EigsView){{0}}))) {
        rt_error(EK_TYPE, 0, "http_route: body must be a value, not a function — pass a "
                             "literal body (\"pong\"), or use the code form: "
                             "http_route of [method, path, \"code\", \"<source>\"]");
        return make_null();
    }

    Route *r = &g_server.routes[g_server.route_count];
    char *method_s = value_to_string(list_get_view(arg, 0, &(EigsView){{0}}));
    char *path_s = value_to_string(list_get_view(arg, 1, &(EigsView){{0}}));
    r->method = method_s;
    r->path = path_s;

    if (arg->data.list.count >= 4) {
        char *kind_s = value_to_string(list_get_view(arg, 2, &(EigsView){{0}}));
        char *payload_s = value_to_string(list_get_view(arg, 3, &(EigsView){{0}}));
        r->kind = kind_s;
        r->payload = payload_s;
    } else {
        Value *handler = list_get_view(arg, 2, &(EigsView){{0}});
        if (handler->type == VAL_STR) {
            r->kind = xstrdup("static");
            r->payload = xstrdup(handler->data.str);
        } else {
            r->kind = xstrdup("static");
            char *s = value_to_string(handler);
            r->payload = s;
        }
    }

    r->requires_auth = requires_auth;
    g_server.route_count++;
    return make_str("route registered");
}

Value* builtin_http_route(Value *arg) {
    STRICT_LIST_MAX(arg, 4, "http_route");
    if (http_config_frozen("http_route")) return make_null();
    return http_route_register(arg, 0);
}

Value* builtin_http_route_authed(Value *arg) {
    STRICT_LIST_MAX(arg, 4, "http_route_authed");
    if (http_config_frozen("http_route_authed")) return make_null();
    return http_route_register(arg, 1);
}

Value* builtin_http_static(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "http_static");
    if (http_config_frozen("http_static")) return make_null();
    if (arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    char *prefix = value_to_string(list_get_view(arg, 0, &(EigsView){{0}}));
    if (!prefix[0]) {
        free(prefix);
        rt_error(EK_VALUE, 0, "http_static: prefix must not be empty");
        return make_null();
    }
    if (prefix[0] != '/') {
        free(prefix);
        rt_error(EK_VALUE, 0, "http_static: prefix must begin with '/'");
        return make_null();
    }
    size_t prefix_len = strlen(prefix);
    while (prefix_len > 0 && prefix[prefix_len - 1] == '/')
        prefix[--prefix_len] = '\0';
    if (prefix_len == 0) {
        free(prefix);
        rt_error(EK_VALUE, 0, "http_static: prefix must name a path segment (not only slashes)");
        return make_null();
    }
    for (int i = 0; i < g_server.static_count; i++) {
        if (strcmp(g_server.static_roots[i].prefix, prefix) == 0) {
            rt_error(EK_VALUE, 0, "http_static: prefix already registered: %s", prefix);
            free(prefix);
            return make_null();
        }
    }
    if (g_server.static_count >= MAX_STATIC_PREFIXES) {
        free(prefix);
        rt_error(EK_LIMIT, 0, "http_static: prefix table full (max %d prefixes)", MAX_STATIC_PREFIXES);
        return make_null();
    }
    char *dir = value_to_string(list_get_view(arg, 1, &(EigsView){{0}}));
    StaticRoot *root = &g_server.static_roots[g_server.static_count];
    root->prefix = prefix;
    root->prefix_len = prefix_len;
    root->directory = dir;
    g_server.static_count++;
    return make_str("static registered");
}

/* Names send_response_full emits, plus Transfer-Encoding (owned, not currently
 * written). Registration of any of these would duplicate a runtime line. */
static int is_runtime_response_header_name(const char *name) {
    static const char *const names[] = {
        "Content-Length",
        "Content-Type",
        "Transfer-Encoding",
        "Connection",
        "Cache-Control",
        "Retry-After",
        "Allow",
        "Access-Control-Allow-Origin",
        "Access-Control-Allow-Methods",
        "Access-Control-Allow-Headers",
    };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        if (strcasecmp(name, names[i]) == 0) return 1;
    }
    return 0;
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
    Value *name = list_get_view(arg, 0, &(EigsView){{0}}), *value = list_get_view(arg, 1, &(EigsView){{0}});
    if (name->type != VAL_STR || value->type != VAL_STR)
        return response_header_error(EK_TYPE, "name and value must be strings");
    size_t nlen = val_str_len(name), vlen = val_str_len(value);
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
    if (is_runtime_response_header_name(name->data.str))
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
    if (__builtin_expect(g_replay_enabled, 0)) {
        rt_error(EK_IO, 0, "http_early_bind: not replayable under EIGS_REPLAY "
                 "(network boundary; see docs/TRACE.md)");
        return make_null();
    }
    EIGS_VIEW(port_view);
    const char *live_path = NULL;
    if (arg && arg->type == VAL_LIST) {
        if (arg->data.list.count != 2 || list_get_view(arg, 1, &(EigsView){{0}})->type != VAL_STR) {
            rt_error(EK_TYPE, 0, "http_early_bind requires [port, absolute liveness path string]");
            return make_null();
        }
        live_path = list_get_view(arg, 1, &(EigsView){{0}})->data.str;
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
        arg = list_get_view(arg, 0, &port_view);
    }
    if (arg && arg->type != VAL_NULL && !val_is_number(arg)) {
        rt_error(EK_TYPE, 0, "http_early_bind: port must be a number or null");
        return make_null();
    }
    int64_t port_value = 5000;
    if (arg && arg->type != VAL_NULL
        && !eigs_int_arg_range(arg, 0, 65535, &port_value, "http_early_bind")) return make_null();
    int port = (int)port_value;
    if (g_server.early_bind_fd >= 0 || g_server.serving || g_server.response_header_rejected) {
        rt_error(EK_VALUE, 0, "http_early_bind: server already bound/serving or http_response_header rejected");
        return make_null();
    }

    const char *env_port = getenv("PORT");
    char *port_end = NULL;
    errno = 0;
    long override = env_port ? strtol(env_port, &port_end, 10) : 0;
    if (env_port && port_end != env_port && override > 0) {
        if (errno == ERANGE || override > 65535) {
            rt_error(EK_VALUE, 0, "http_early_bind: PORT outside [0, 65535]");
            return make_null();
        }
        port = (int)override;
        printf("[deploy] PORT env=%s, binding port %d\n", env_port, port);
    } else {
        printf("[deploy] No PORT env, using default %d\n", port);
    }
    if (port < 0 || port > 65535) {
        rt_error(EK_VALUE, 0, "http_early_bind: port outside [0, 65535]");
        return make_null();
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
    http_prime_config_caches();
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
    int64_t port_value = 5000;
    if (arg && arg->type != VAL_NULL
        && !eigs_int_arg_range(arg, 0, 65535, &port_value, "http_serve")) return make_null();
    int port = (int)port_value;
    const char *env_port = getenv("PORT");
    char *port_end = NULL;
    errno = 0;
    long override = env_port ? strtol(env_port, &port_end, 10) : 0;
    if (env_port && port_end != env_port && override > 0) {
        if (errno == ERANGE || override > 65535) {
            rt_error(EK_VALUE, 0, "http_serve: PORT outside [0, 65535]");
            return make_null();
        }
        port = (int)override;
    }
    if (port < 0 || port > 65535) {
        rt_error(EK_VALUE, 0, "http_serve: port outside [0, 65535]");
        return make_null();
    }
    if (__builtin_expect(g_replay_enabled, 0)) {
        rt_error(EK_IO, 0, "http_serve: not replayable under EIGS_REPLAY "
                 "(server/static-file boundary; see docs/TRACE.md)");
        return make_null();
    }
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

/* Outbound client: one exchange behind both public builtins. This is the
 * public libcurl ABI, not its header: option numbers are stable enum values.
 * See docs/BUILTINS.md for the introduction releases and runtime dependency. */
typedef struct FetchSlist { char *data; struct FetchSlist *next; } FetchSlist;
static struct {
    void *lib;
    int init_error;
    int (*global_init)(long);
    void *(*easy_init)(void);
    void (*easy_cleanup)(void *);
    int (*easy_setopt)(void *, int, ...);
    int (*easy_perform)(void *);
    int (*easy_getinfo)(void *, int, ...);
    FetchSlist *(*slist_append)(FetchSlist *, const char *);
    void (*slist_free_all)(FetchSlist *);
} fetch_curl;
static pthread_once_t fetch_curl_once = PTHREAD_ONCE_INIT;
static pthread_once_t fetch_config_once = PTHREAD_ONCE_INIT;
static size_t fetch_body_limit = 16777216;
static char *fetch_ca_file, *fetch_ca_dir;

static void fetch_read_config(void) {
    const char *s = getenv("EIGS_HTTP_FETCH_MAX_BODY");
    if (s) {
        size_t n = strlen(s), v = 0;
        int ok = n >= 1 && n <= 10;
        for (size_t i = 0; ok && i < n; i++) {
            if (s[i] < '0' || s[i] > '9') ok = 0;
            else {
                unsigned digit = (unsigned)(s[i] - '0');
                if (v > (2147483647u - digit) / 10) ok = 0;
                else v = v * 10 + digit;
            }
        }
        if (ok && v) fetch_body_limit = v;
    }
    s = getenv("CURL_CA_BUNDLE");
    if (s && *s) fetch_ca_file = xstrdup(s);
    else {
        s = getenv("SSL_CERT_FILE");
        if (s && *s) fetch_ca_file = xstrdup(s);
        s = getenv("SSL_CERT_DIR");
        if (s && *s) fetch_ca_dir = xstrdup(s);
    }
}

static void fetch_load_curl(void) {
#ifdef __APPLE__
    const char *names[] = {"libcurl.4.dylib", "libcurl.dylib"};
#else
    const char *names[] = {"libcurl.so.4", "libcurl.so"};
#endif
    for (size_t i = 0; i < sizeof names / sizeof names[0] && !fetch_curl.lib; i++)
        fetch_curl.lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!fetch_curl.lib) return;
    int ok = 1;
#define FETCH_LOAD(member, symbol) do { \
    fetch_curl.member = dlsym(fetch_curl.lib, #symbol); \
    if (!fetch_curl.member) ok = 0; \
} while (0)
    FETCH_LOAD(global_init, curl_global_init);
    FETCH_LOAD(easy_init, curl_easy_init);
    FETCH_LOAD(easy_cleanup, curl_easy_cleanup);
    FETCH_LOAD(easy_setopt, curl_easy_setopt);
    FETCH_LOAD(easy_perform, curl_easy_perform);
    FETCH_LOAD(easy_getinfo, curl_easy_getinfo);
    FETCH_LOAD(slist_append, curl_slist_append);
    FETCH_LOAD(slist_free_all, curl_slist_free_all);
#undef FETCH_LOAD
    if (!ok) {
        dlclose(fetch_curl.lib);
        fetch_curl.lib = NULL;
        return;
    }
    /* CURL_GLOBAL_ALL = 3. Once includes global init: no other curl function
     * can run until this publishes the complete table and initialized state.
     * Retain for process lifetime; cleanup could race another state's call. */
    fetch_curl.init_error = fetch_curl.global_init(3L);
}

/* Stable public enum values, from curl 8.5.0's public curl.h. */
enum {
    FETCH_CURLOPT_WRITEDATA = 10001,
    FETCH_CURLOPT_URL = 10002,
    FETCH_CURLOPT_WRITEFUNCTION = 20011,
    FETCH_CURLOPT_POSTFIELDS = 10015,
    FETCH_CURLOPT_HTTPHEADER = 10023,
    FETCH_CURLOPT_HEADERDATA = 10029,
    FETCH_CURLOPT_CUSTOMREQUEST = 10036,
    FETCH_CURLOPT_NOBODY = 44,
    FETCH_CURLOPT_NETRC = 51,
    FETCH_CURLOPT_FOLLOWLOCATION = 52,
    FETCH_CURLOPT_POSTFIELDSIZE = 60,
    FETCH_CURLOPT_SSL_VERIFYPEER = 64,
    FETCH_CURLOPT_CAINFO = 10065,
    FETCH_CURLOPT_HEADERFUNCTION = 20079,
    FETCH_CURLOPT_SSL_VERIFYHOST = 81,
    FETCH_CURLOPT_HTTP_VERSION = 84,
    FETCH_CURLOPT_CAPATH = 10097,
    FETCH_CURLOPT_NOSIGNAL = 99,
    FETCH_CURLOPT_TIMEOUT_MS = 155,
    FETCH_CURLOPT_HTTP_CONTENT_DECODING = 158,
    FETCH_CURLOPT_PATH_AS_IS = 234,
    FETCH_CURLINFO_RESPONSE_CODE = 0x200002
};
#define FETCH_HEADER_LIMIT 65536u
/* The runtime's own limit on lines, below curl's 5000 (from 8.14.0), so that
 * the same answer decides the same way on every release. */
#define FETCH_HEADER_LINE_LIMIT 4096u

typedef struct {
    const char *name, *value;
    size_t name_len, value_len;
} FetchHeader;
typedef struct {
    const char *url, *method, *body;
    size_t url_len, body_len, authority_end;
    long timeout_ms;
    FetchHeader *headers;
    size_t header_count;
    int own_headers, post;
} FetchRequest;

static void fetch_request_clear(FetchRequest *r) {
    if (r->own_headers) {
        for (size_t i = 0; i < r->header_count; i++) {
            free((char *)r->headers[i].name);
            free((char *)r->headers[i].value);
        }
    }
    free(r->headers);
}

static int fetch_error(const char *fn, ErrKind kind, const char *rule) {
    rt_error(kind, 0, "%s: %s", fn, rule);
    return 0;
}
static unsigned char fetch_lower(unsigned char c) {
    return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
}
static int fetch_token(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || (c && strchr("!#$%&'*+-.^_`|~", c));
}
static int fetch_name_cmp(const void *a, const void *b) {
    const FetchHeader *ha = *(const FetchHeader *const *)a;
    const FetchHeader *hb = *(const FetchHeader *const *)b;
    return strcasecmp(ha->name, hb->name);
}
static int fetch_url_valid(FetchRequest *r, const char *fn) {
    size_t start = strncmp(r->url, "http://", 7) == 0 ? 7 :
                   strncmp(r->url, "https://", 8) == 0 ? 8 : 0;
    if (!start) return fetch_error(fn, EK_VALUE, "url must begin http:// or https://");
    for (size_t i = 0; i < r->url_len; i++) {
        unsigned char c = (unsigned char)r->url[i];
        if (c < 0x21 || c > 0x7e)
            return fetch_error(fn, EK_VALUE, "url must contain only visible ASCII");
    }
    size_t end = start;
    while (end < r->url_len && !strchr("/?#", r->url[end])) end++;
    if (end == start) return fetch_error(fn, EK_VALUE, "url authority must not be empty");
    for (size_t i = start; i < end; i++) {
        unsigned char c = (unsigned char)r->url[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || strchr(".-_:[]", c)))
            return fetch_error(fn, EK_VALUE, "url authority has a forbidden character");
    }
    r->authority_end = end;
    return 1;
}
static int fetch_headers_valid(FetchRequest *r, const char *fn) {
    size_t total = 0;
    for (size_t i = 0; i < r->header_count; i++) {
        FetchHeader *h = &r->headers[i];
        if (h->name_len < 1 || h->name_len > 64)
            return fetch_error(fn, EK_VALUE, "header name must be 1 to 64 token bytes");
        for (size_t j = 0; j < h->name_len; j++)
            if (!fetch_token((unsigned char)h->name[j]))
                return fetch_error(fn, EK_VALUE, "header name must contain only token bytes");
        if (!strcasecmp(h->name, "Content-Length") ||
            !strcasecmp(h->name, "Transfer-Encoding") || !strcasecmp(h->name, "Expect"))
            return fetch_error(fn, EK_VALUE, "Content-Length, Transfer-Encoding and Expect are reserved headers");
        /* The connection is the runtime's: one for each call, closed at its
         * end, and the Connection line written by the runtime. */
        if (!strcasecmp(h->name, "Connection") || !strcasecmp(h->name, "Keep-Alive") ||
            !strcasecmp(h->name, "Proxy-Connection") || !strcasecmp(h->name, "TE") ||
            !strcasecmp(h->name, "Upgrade"))
            return fetch_error(fn, EK_VALUE, "Connection, Keep-Alive, Proxy-Connection, TE and Upgrade are reserved headers: the connection is the runtime's");
        for (size_t j = 0; j < h->value_len; j++) {
            unsigned char c = (unsigned char)h->value[j];
            if (c != '\t' && (c < 0x20 || c > 0x7e))
                return fetch_error(fn, EK_VALUE, "header value must contain visible ASCII, space or tab");
        }
        if (h->value_len && (strchr(" \t", h->value[0]) ||
                            strchr(" \t", h->value[h->value_len - 1])))
            return fetch_error(fn, EK_VALUE, "header value must not begin or end with space or tab");
        /* Subtraction bounds both the sum and individual lengths. */
        size_t base = h->name_len + 4;
        if (base > FETCH_HEADER_LIMIT - total ||
            h->value_len > FETCH_HEADER_LIMIT - total - base)
            return fetch_error(fn, EK_LIMIT, "request headers are longer than 65536 bytes");
        total += base + h->value_len;
    }
    if (r->header_count > 1) {
        FetchHeader **sorted = xmalloc(r->header_count * sizeof *sorted);
        for (size_t i = 0; i < r->header_count; i++) sorted[i] = &r->headers[i];
        qsort(sorted, r->header_count, sizeof *sorted, fetch_name_cmp);
        int duplicate = 0;
        for (size_t i = 1; i < r->header_count; i++)
            if (!strcasecmp(sorted[i - 1]->name, sorted[i]->name)) { duplicate = 1; break; }
        free(sorted);
        if (duplicate) return fetch_error(fn, EK_VALUE, "header names must be unique ignoring case");
    }
    return 1;
}

static int fetch_request_dict(Value *arg, FetchRequest *r) {
    const char *fn = "http_fetch";
    if (!arg || arg->type != VAL_DICT) return fetch_error(fn, EK_TYPE, "request must be a dict");
    r->method = "GET"; r->body = ""; r->timeout_ms = 15000;
    DICT_FOR_EACH(arg, i) {
        const char *k = arg->data.dict.keys[i];
        EigsView view;
        Value *v = dict_value_get_view(arg, i, &view);
        if (!strcmp(k, "url") || !strcmp(k, "method") || !strcmp(k, "body")) {
            if (v->type != VAL_STR) return fetch_error(fn, EK_TYPE, "url, method and body must be strings");
            if (!strcmp(k, "url")) { r->url = v->data.str; r->url_len = val_str_len(v); }
            else if (!strcmp(k, "body")) { r->body = v->data.str; r->body_len = val_str_len(v); }
            else {
                r->method = v->data.str;
                /* Text cannot embed NUL; keep the length guard explicit here. */
                if (val_str_len(v) != strlen(r->method)) return fetch_error(fn, EK_VALUE, "invalid method");
            }
        } else if (!strcmp(k, "headers")) {
            if (v->type != VAL_DICT) return fetch_error(fn, EK_TYPE, "headers must be a dict");
            size_t n = (size_t)v->data.dict.count;
            r->headers = n ? xcalloc(n, sizeof *r->headers) : NULL;
            DICT_FOR_EACH(v, j) {
                EigsView hv;
                Value *value = dict_value_get_view(v, j, &hv);
                if (value->type != VAL_STR) return fetch_error(fn, EK_TYPE, "header value must be a string");
                const char *name = v->data.dict.keys[j];
                r->headers[r->header_count++] = (FetchHeader){name, value->data.str, strlen(name), val_str_len(value)};
            }
        } else if (!strcmp(k, "timeout")) {
            if (!val_is_number(v)) return fetch_error(fn, EK_TYPE, "timeout must be an int or a float");
            EigsNum n;
            if (!eigs_number_read(v, &n, "http_fetch")) return 0;
            double seconds = n.is_int ? (double)n.value.i64 : n.value.f64;
            if (!isfinite(seconds) || seconds < 0.001 || seconds > 300)
                return fetch_error(fn, EK_VALUE, "timeout must be finite and between 0.001 and 300 seconds");
            r->timeout_ms = (long)ceil(seconds * 1000.0);
        } else return fetch_error(fn, EK_VALUE, "unknown request key");
    }
    if (!r->url) return fetch_error(fn, EK_VALUE, "url is required");
    if (strcmp(r->method, "GET") && strcmp(r->method, "HEAD") &&
        strcmp(r->method, "POST") && strcmp(r->method, "PUT") &&
        strcmp(r->method, "PATCH") && strcmp(r->method, "DELETE"))
        return fetch_error(fn, EK_VALUE, "method must be GET, HEAD, POST, PUT, PATCH or DELETE");
    if ((!strcmp(r->method, "GET") || !strcmp(r->method, "HEAD")) && r->body_len)
        return fetch_error(fn, EK_VALUE, "GET and HEAD must have an empty body");
    return fetch_url_valid(r, fn) && fetch_headers_valid(r, fn);
}

/* Errors use a shape no success can have (a two-string list). Validate taped
 * payloads before interpreting them; replay never falls through to live I/O. */
static int fetch_replay(const char *fn, Value **out) {
    if (!__builtin_expect(g_replay_enabled, 0)) return 0;
    Value *v = NULL;
    int took = !strcmp(fn, "http_post") ? trace_replay_take("http_post", &v) :
                                         trace_replay_take("http_fetch", &v);
    if (!took) {
        if (!g_has_error) rt_error(EK_IO, 0, "%s: unservable replay record", fn);
        *out = make_null(); return 1;
    }
    if (v->type == VAL_LIST) {
        if (v->data.list.count == 2 && list_elem_type(v, 0) == VAL_STR && list_elem_type(v, 1) == VAL_STR) {
            const char *kind = list_get_ref(v, 0)->data.str;
            if (!strcmp(kind, "io") || !strcmp(kind, "limit")) {
                rt_error(!strcmp(kind, "io") ? EK_IO : EK_LIMIT, 0, "%s", list_get_ref(v, 1)->data.str);
                goto refused;
            }
        }
        rt_error(EK_IO, 0, "%s: invalid replay error record", fn);
        goto refused;
    }
    int valid = !strcmp(fn, "http_post") ? v->type == VAL_STR : v->type == VAL_DICT;
    if (valid && v->type == VAL_DICT) {
        EigsView sv, hv, bv;
        Value *s = dict_get_view(v, "status", &sv), *h = dict_get_view(v, "headers", &hv), *b = dict_get_view(v, "body", &bv);
        int64_t code;
        valid = v->data.dict.count == 3 && s && s->type == VAL_INT &&
                eigs_int_arg_range(s, 200, 999, &code, fn) && h && h->type == VAL_DICT && b && b->type == VAL_STR;
        if (valid) DICT_FOR_EACH(h, i) { if (dict_value_type(h, i) != VAL_STR) { valid = 0; break; } }
    }
    if (!valid) {
        if (!g_has_error) rt_error(EK_IO, 0, "%s: invalid replay answer record", fn);
        goto refused;
    }
    *out = v;
    return 1;
refused:
    val_decref(v);
    *out = make_null();
    return 1;
}
static Value *fetch_attempt_error(const char *fn, ErrKind kind, const char *suffix) {
    char message[256];
    snprintf(message, sizeof message, "%s: %s", fn, suffix);
    if (__builtin_expect(g_trace_enabled, 0)) {
        Value *v = make_list(2);
        list_append_owned(v, make_str(err_kind_name(kind)));
        list_append_owned(v, make_str(message));
        trace_nondet_value(fn, v);
        val_decref(v);
    }
    rt_error(kind, 0, "%s", message);
    return make_null();
}
static Value *fetch_curl_error(const char *fn, int code) {
    const char *message = NULL;
    switch (code) {
        case 6: message = "could not resolve the host (curl error 6)"; break;
        case 7: message = "could not connect (curl error 7)"; break;
        case 28: message = "timed out (curl error 28)"; break;
        case 18: case 52: case 56: message = "the answer ended early"; break;
        default: break;
    }
    char text[80];
    if (!message) { snprintf(text, sizeof text, "curl failed (curl error %d)", code); message = text; }
    return fetch_attempt_error(fn, EK_IO, message);
}

typedef struct {
    char *body, *headers;
    size_t body_len, body_room, header_len, header_bytes, header_lines;
    size_t exchange_lines; /* every header line of the exchange; never reset */
    int status, final_complete, limit;
    int mid_block; /* 0 when the next line opens a block: the first line, or one after an empty line */
    int said;      /* the status the block's status line says, or -1 when it says none */
    int unsaid;    /* the final block's status line did not say the library's status */
    void *easy;    /* the call's own handle, asked for the code at a block's empty line */
} FetchAnswer;

static size_t fetch_body_write(char *bytes, size_t size, size_t count, void *opaque) {
    FetchAnswer *a = opaque;
    if (size && count > SIZE_MAX / size) { a->limit = 2; return 0; }
    size_t n = size * count;
    if (n > fetch_body_limit - a->body_len) { a->limit = 2; return 0; }
    size_t needed = a->body_len + n + 1;
    if (needed > a->body_room) {
        size_t room = a->body_room ? a->body_room : 4096;
        while (room < needed) {
            if (room > (fetch_body_limit + 1) / 2) { room = fetch_body_limit + 1; break; }
            room *= 2;
        }
        a->body = xrealloc(a->body, room);
        a->body_room = room;
    }
    if (n) memcpy(a->body + a->body_len, bytes, n);
    a->body_len += n;
    a->body[a->body_len] = '\0';
    return n;
}
/* The status a status line says: the line begins with the bytes HTTP/, and
 * the first run of spaces or tabs in it is followed by three digits and no
 * fourth. -1 when the line says none. */
static int fetch_status_said(const char *bytes, size_t n) {
    if (n < 5 || memcmp(bytes, "HTTP/", 5)) return -1;
    size_t i = 5;
    while (i < n && bytes[i] != ' ' && bytes[i] != '\t') i++;
    while (i < n && (bytes[i] == ' ' || bytes[i] == '\t')) i++;
    if (i + 3 > n) return -1;
    for (size_t j = i; j < i + 3; j++) if (bytes[j] < '0' || bytes[j] > '9') return -1;
    if (i + 3 < n && bytes[i + 3] >= '0' && bytes[i + 3] <= '9') return -1;
    return (bytes[i] - '0') * 100 + (bytes[i + 1] - '0') * 10 + bytes[i + 2] - '0';
}
/* Which block is final is the library's: at the empty line that ends a block
 * it reports the block's status (0 for a proxy's answer to CONNECT). A block
 * at 200 or more is final, and the answer it starts is one only when its
 * status line said that same status. Up to then the first line of a block is
 * its status line; after the final block every line is a trailer line. */
static size_t fetch_header_write(char *bytes, size_t size, size_t count, void *opaque) {
    FetchAnswer *a = opaque;
    if (size && count > SIZE_MAX / size) { a->limit = 1; return 0; }
    size_t n = size * count;
    int empty = (n == 2 && bytes[0] == '\r' && bytes[1] == '\n') || (n == 1 && bytes[0] == '\n');
    if (!a->final_complete) {
        if (!a->mid_block) {
            a->mid_block = 1;
            a->header_len = 0; a->header_lines = 0;
            a->said = fetch_status_said(bytes, n);
            return n;
        }
        if (empty) {
            long code = 0;
            a->mid_block = 0;
            if (fetch_curl.easy_getinfo(a->easy, FETCH_CURLINFO_RESPONSE_CODE, &code) || code < 200) return n;
            a->final_complete = 1;
            if (code != a->said) { a->unsaid = 1; return 0; }
            return n;
        }
    } else if (empty) return n;
    if (n > FETCH_HEADER_LIMIT - a->header_bytes) { a->limit = 1; return 0; }
    if (a->exchange_lines >= FETCH_HEADER_LINE_LIMIT) { a->limit = 3; return 0; }
    a->header_bytes += n;
    a->exchange_lines++;
    if (!a->final_complete) {
        if (!a->headers) a->headers = xmalloc(FETCH_HEADER_LIMIT + 1);
        memcpy(a->headers + a->header_len, bytes, n);
        a->header_len += n;
        a->headers[a->header_len] = '\0';
        a->header_lines++;
    }
    return n;
}

typedef struct {
    char *name, *value;
    size_t length, joined;
    size_t next, last, group;
} FetchField;
/* Parse only the retained final header block. A hash index groups duplicates;
 * one allocation/copy per final value avoids rescanning/copied prefixes. */
static Value *fetch_answer_headers(FetchAnswer *a) {
    Value *dict = make_dict(0);
    if (!a->header_lines) return dict;
    FetchField *fields = xcalloc(a->header_lines, sizeof *fields);
    size_t room = 1;
    while (room < a->header_lines * 2) room *= 2;
    size_t *index = xcalloc(room, sizeof *index);
    size_t used = 0, pos = 0;
    while (pos < a->header_len) {
        char *line = a->headers + pos, *end = memchr(line, '\n', a->header_len - pos);
        if (!end) break;
        pos = (size_t)(end - a->headers) + 1;
        if (end > line && end[-1] == '\r') end--;
        char *colon = memchr(line, ':', (size_t)(end - line));
        if (!colon) continue; /* malformed lines remain the library's decision */
        uint32_t hash = 2166136261u;
        for (char *p = line; p < colon; p++) { *p = (char)fetch_lower((unsigned char)*p); hash = (hash ^ (unsigned char)*p) * 16777619u; }
        *colon = '\0';
        char *value = colon + 1;
        while (value < end && (*value == ' ' || *value == '\t')) value++;
        while (end > value && (end[-1] == ' ' || end[-1] == '\t')) end--;
        *end = '\0';
        size_t bucket = hash & (room - 1);
        while (index[bucket] && strcmp(fields[index[bucket] - 1].name, line)) bucket = (bucket + 1) & (room - 1);
        size_t i = used++, group = index[bucket] ? index[bucket] - 1 : i;
        fields[i] = (FetchField){line, value, (size_t)(end - value), (size_t)(end - value), SIZE_MAX, i, group};
        if (group == i) index[bucket] = i + 1;
        else {
            fields[fields[group].last].next = i;
            fields[group].last = i;
            fields[group].joined += 2 + fields[i].length;
        }
    }
    for (size_t i = 0; i < used; i++) if (fields[i].group == i) {
        char *value = xmalloc(fields[i].joined + 1), *p = value;
        for (size_t j = i; j != SIZE_MAX; j = fields[j].next) {
            if (j != i) { *p++ = ','; *p++ = ' '; }
            memcpy(p, fields[j].value, fields[j].length); p += fields[j].length;
        }
        *p = '\0';
        dict_set_owned(dict, fields[i].name, make_str_owned_len(value, fields[i].joined));
    }
    free(index);
    free(fields);
    return dict;
}

/* curl_slist_append traverses its argument. Create one library-owned node at
 * a time, and link at our tail; curl_slist_free_all remains its sole owner. */
static int fetch_line(FetchSlist **head, FetchSlist **tail, const char *line) {
    FetchSlist *node = fetch_curl.slist_append(NULL, line);
    if (!node) return 0;
    if (*tail) (*tail)->next = node;
    else *head = node;
    *tail = node;
    return 1;
}
static int fetch_header_line(FetchSlist **head, FetchSlist **tail, const FetchHeader *h) {
    char *line = xmalloc(h->name_len + h->value_len + 3);
    memcpy(line, h->name, h->name_len);
    size_t pos = h->name_len;
    /* name; is libcurl's documented spelling of an explicitly empty value. */
    line[pos++] = h->value_len ? ':' : ';';
    if (h->value_len) { line[pos++] = ' '; memcpy(line + pos, h->value, h->value_len); pos += h->value_len; }
    line[pos] = '\0';
    int ok = fetch_line(head, tail, line);
    free(line);
    return ok;
}

static Value *fetch_exchange(FetchRequest *r, const char *fn) {
    Value *replayed;
    if (fetch_replay(fn, &replayed)) return replayed;
    pthread_once(&fetch_curl_once, fetch_load_curl);
    if (!fetch_curl.lib) return fetch_attempt_error(fn, EK_IO, "could not load the curl library");
    if (fetch_curl.init_error) return fetch_curl_error(fn, fetch_curl.init_error);
    pthread_once(&fetch_config_once, fetch_read_config);
    void *easy = fetch_curl.easy_init();
    if (!easy) return fetch_curl_error(fn, 2); /* CURLE_FAILED_INIT */
    FetchAnswer a = {0};
    a.easy = easy;
    FetchSlist *head = NULL, *tail = NULL;
    int code = 0, host = -1, content_type = 0, user_agent = 0, accept = 0;
    for (size_t i = 0; i < r->header_count; i++) {
        if (!strcasecmp(r->headers[i].name, "Host")) host = (int)i;
        if (!strcasecmp(r->headers[i].name, "Content-Type")) content_type = 1;
        if (!strcasecmp(r->headers[i].name, "User-Agent")) user_agent = 1;
        if (!strcasecmp(r->headers[i].name, "Accept")) accept = 1;
    }
    if (!fetch_line(&head, &tail, "Expect:") ||
        (!content_type && !r->post && !fetch_line(&head, &tail, "Content-Type:"))) { code = 27; goto done; }
    /* Clear curl's generated Host first, then emit the caller's spelling.
     * All other generated fields are supplied in this list too, so they
     * cannot precede this Host in curl's earlier, generated-field block. */
    if (host >= 0 && (!fetch_line(&head, &tail, "Host:") || !fetch_header_line(&head, &tail, &r->headers[host]))) { code = 27; goto done; }
    for (size_t i = 0; i < r->header_count; i++)
        if ((int)i != host && !fetch_header_line(&head, &tail, &r->headers[i])) { code = 27; goto done; }
    if ((!user_agent && !fetch_line(&head, &tail, "User-Agent: EigenScript/" EIGENSCRIPT_VERSION)) ||
        (!accept && !fetch_line(&head, &tail, "Accept: */*")) ||
        (!content_type && r->post && !fetch_line(&head, &tail, "Content-Type: application/x-www-form-urlencoded"))) { code = 27; goto done; }
    if (!strcmp(r->method, "POST") || !strcmp(r->method, "PUT") ||
        !strcmp(r->method, "PATCH") || (!strcmp(r->method, "DELETE") && r->body_len)) {
        char length[64];
        snprintf(length, sizeof length, "Content-Length: %zu", r->body_len);
        if (!fetch_line(&head, &tail, length)) { code = 27; goto done; }
    }
    /* RFC 9112, 9.3: a client that keeps no connection sends close. From
     * curl 8.16.0 the library moves this line to the end of the request. */
    if (!fetch_line(&head, &tail, "Connection: close")) { code = 27; goto done; }
#define FETCH_SET(option, value) do { \
    code = fetch_curl.easy_setopt(easy, FETCH_CURLOPT_##option, (value)); \
    if (code) goto done; \
} while (0)
    FETCH_SET(URL, r->url);
    FETCH_SET(PATH_AS_IS, 1L);
    FETCH_SET(HTTP_VERSION, 2L); /* CURL_HTTP_VERSION_1_1 */
    FETCH_SET(NOSIGNAL, 1L);
    FETCH_SET(TIMEOUT_MS, r->timeout_ms);
    FETCH_SET(FOLLOWLOCATION, 0L);
    FETCH_SET(NETRC, 0L); /* CURL_NETRC_IGNORED */
    FETCH_SET(SSL_VERIFYPEER, 1L);
    FETCH_SET(SSL_VERIFYHOST, 2L);
    FETCH_SET(HTTP_CONTENT_DECODING, 0L);
    if (fetch_ca_file) FETCH_SET(CAINFO, fetch_ca_file);
    if (fetch_ca_dir) FETCH_SET(CAPATH, fetch_ca_dir);
    FETCH_SET(HTTPHEADER, head);
    FETCH_SET(WRITEFUNCTION, fetch_body_write);
    FETCH_SET(WRITEDATA, &a);
    FETCH_SET(HEADERFUNCTION, fetch_header_write);
    FETCH_SET(HEADERDATA, &a);
    if (!strcmp(r->method, "HEAD")) FETCH_SET(NOBODY, 1L);
    else if (!strcmp(r->method, "POST") || !strcmp(r->method, "PUT") || !strcmp(r->method, "PATCH") || r->body_len) {
        FETCH_SET(POSTFIELDSIZE, (long)r->body_len);
        FETCH_SET(POSTFIELDS, r->body);
    }
    FETCH_SET(CUSTOMREQUEST, r->method);
#undef FETCH_SET
    code = fetch_curl.easy_perform(easy);
    if (!code) {
        long status = 0;
        code = fetch_curl.easy_getinfo(easy, FETCH_CURLINFO_RESPONSE_CODE, &status);
        if (!code && a.final_complete) a.status = (int)status;
    }
done:
    fetch_curl.easy_cleanup(easy);
    fetch_curl.slist_free_all(head);
    Value *result;
    if (a.limit == 1) result = fetch_attempt_error(fn, EK_LIMIT, "the answer's headers are longer than 65536 bytes");
    else if (a.limit == 3) result = fetch_attempt_error(fn, EK_LIMIT, "the answer has more than 4096 header lines");
    else if (a.limit == 2) {
        char text[128];
        snprintf(text, sizeof text, "the answer's body is longer than %zu bytes (EIGS_HTTP_FETCH_MAX_BODY)", fetch_body_limit);
        result = fetch_attempt_error(fn, EK_LIMIT, text);
    } else if (a.unsaid) result = fetch_attempt_error(fn, EK_IO, "the answer ended early");
    else if (code) result = fetch_curl_error(fn, code);
    else if (!a.final_complete) result = fetch_attempt_error(fn, EK_IO, "the answer ended early");
    else if (a.body_len && memchr(a.body, '\0', a.body_len)) result = fetch_attempt_error(fn, EK_IO, "the answer holds a NUL byte, which text cannot carry");
    else {
        Value *body = a.body ? make_str_owned_len(a.body, a.body_len) : make_str("");
        a.body = NULL;
        if (r->post) result = body;
        else {
            result = make_dict(0);
            dict_set_owned(result, "status", make_int(a.status));
            dict_set_owned(result, "headers", fetch_answer_headers(&a));
            dict_set_owned(result, "body", body);
        }
        if (__builtin_expect(g_trace_enabled, 0)) trace_nondet_value(fn, result);
    }
    free(a.body);
    free(a.headers);
    return result;
}

/* http_fetch of request -> {status, headers, body}; one HTTP exchange. */
Value *builtin_http_fetch(Value *arg) {
    FetchRequest r = {0};
    int ok = fetch_request_dict(arg, &r);
    Value *out = ok ? fetch_exchange(&r, "http_fetch") : make_null();
    fetch_request_clear(&r);
    return out;
}

/* http_post of [url, headers, body] -> response body string; POST through http_fetch's exchange. */
Value *builtin_http_post(Value *arg) {
    STRICT_LIST_MAX(arg, 3, "http_post");
    /* These legacy defaults are decided first, before header/body validation. */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        TRACE_NONDET_TAKE("http_post");
        TRACE_NONDET_RECORD("http_post", make_str(""));
    }
    EigsView uv, hv, bv;
    Value *u = list_get_view(arg, 0, &uv), *h = list_get_view(arg, 1, &hv), *b = list_get_view(arg, 2, &bv);
    if (u->type != VAL_STR || !http_url_is_allowed(u->data.str)) {
        TRACE_NONDET_TAKE("http_post");
        TRACE_NONDET_RECORD("http_post", make_str(""));
    }
    if (h->type != VAL_STR || b->type != VAL_STR) {
        fetch_error("http_post", EK_TYPE, "headers and body must be strings");
        return make_null();
    }
    FetchRequest r = { .url = u->data.str, .url_len = val_str_len(u), .method = "POST",
        .body = b->data.str, .body_len = val_str_len(b), .timeout_ms = 15000, .post = 1, .own_headers = 1 };
    int pos = 0;
    Value *parsed = eigs_json_parse_complete(h->data.str, &pos);
    /* parse_complete releases its partial value on every raised error. */
    if (g_has_error) return make_null();
    if (parsed && parsed->type != VAL_DICT && parsed->type != VAL_LIST) {
        val_decref(parsed);
        fetch_error("http_post", EK_TYPE, "headers must be a JSON object or flat array");
        return make_null();
    }
    if (parsed && parsed->type == VAL_LIST && parsed->data.list.count % 2) {
        val_decref(parsed);
        fetch_error("http_post", EK_VALUE, "headers array must hold key/value pairs");
        return make_null();
    }
    if (parsed) {
        size_t n = parsed->type == VAL_DICT ? (size_t)parsed->data.dict.count : (size_t)parsed->data.list.count / 2;
        r.headers = n ? xcalloc(n, sizeof *r.headers) : NULL;
        for (size_t i = 0, j = 0; i < n; i++) {
            EigsView kv, vv;
            char *name, *value;
            if (parsed->type == VAL_DICT) {
                while (j < (size_t)parsed->data.dict.count && !parsed->data.dict.keys[j]) j++;
                name = xstrdup(parsed->data.dict.keys[j]);
                value = value_to_string(dict_value_get_view(parsed, (int)j++, &vv));
            } else {
                name = value_to_string(list_get_view(parsed, (int)(i * 2), &kv));
                value = value_to_string(list_get_view(parsed, (int)(i * 2 + 1), &vv));
            }
            http_strip_crlf(name); http_strip_crlf(value);
            r.headers[r.header_count++] = (FetchHeader){name, value, strlen(name), strlen(value)};
        }
        val_decref(parsed);
    }
    int ok = fetch_url_valid(&r, "http_post") && fetch_headers_valid(&r, "http_post");
    Value *out = ok ? fetch_exchange(&r, "http_post") : make_null();
    fetch_request_clear(&r);
    return out;
}

Value* builtin_http_request_headers(Value *arg) {
    (void)arg;
    if (tls_request_headers && tls_request_head_end >= 0)
        TRACE_NONDET_RET("http_request_headers",
                         make_str_len(tls_request_headers, (size_t)tls_request_head_end));
    if (tls_request_headers)
        TRACE_NONDET_RET("http_request_headers", make_str(tls_request_headers));
    TRACE_NONDET_RET("http_request_headers", make_str(""));
}

/* RFC 7230 token, with no reserved spellings. Explicit ASCII folding below
 * is independent of the process locale. NUL is not strchr's terminator. */
static int request_header_token(unsigned char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || (c && strchr("!#$%&'*+-.^_`|~", c));
}

static unsigned char request_header_lower(unsigned char c) {
    return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
}

Value *builtin_http_request_header(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "http_request_header: name must be a string");
        return make_null();
    }
    size_t n = val_str_len(arg);
    int valid = n >= 1 && n <= 64;
    for (size_t i = 0; valid && i < n; i++)
        valid = request_header_token((unsigned char)arg->data.str[i]);
    if (!valid) {
        rt_error(EK_VALUE, 0, "http_request_header: invalid header name");
        return make_null();
    }
    if (!tls_request_headers) {
        rt_error(EK_VALUE, 0, "http_request_header: no request is being answered");
        return make_null();
    }
    TRACE_NONDET_TAKE("http_request_header");
    Value *values = make_list(0);
    if (tls_request_head_end >= 0) {
        const char *p = tls_request_headers;
        const char *end = p + tls_request_head_end;
        int first = 1;
        while (p < end) {
            const char *line = p, *colon = NULL;
            /* Only CR LF ends a line. Both reads stay inside the framed
             * head, even for malformed lines and arbitrarily long names. */
            while (p + 1 < end && !(p[0] == '\r' && p[1] == '\n')) {
                if (*p == ':' && !colon) colon = p;
                p++;
            }
            const char *eol = p;
            p += 2;
            if (first) { first = 0; continue; }  /* never a field */
            if (eol == line) break;  /* the empty line; `end` is just past it: either stop alone would do */
            if (!colon || (size_t)(colon - line) != n) continue;
            size_t i = 0;
            while (i < n && request_header_lower((unsigned char)line[i]) ==
                            request_header_lower((unsigned char)arg->data.str[i])) i++;
            /* Equal to a validated token proves the WHOLE field name is a
             * token too. Invalid/continuation lines cannot match. */
            if (i != n) continue;
            const char *value = colon + 1;
            while (value < eol && (*value == ' ' || *value == '\t')) value++;
            while (eol > value && (eol[-1] == ' ' || eol[-1] == '\t')) eol--;
            list_append_owned(values, make_str_len(value, (size_t)(eol - value)));
        }
    }
    TRACE_NONDET_RECORD("http_request_header", values);
}

/* ================================================================
 * SHARED STORE
 *
 * In-process key/value store keyed by string, scoped to the main HTTP
 * Server. Each worker code route runs in its own EigsState (thread state dies
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
    STRICT_LIST_MAX(arg, 2, "shared_set");
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2,
              "shared_set", "[key, value]", make_null());
    Value *key_v = list_get_view(arg, 0, &(EigsView){{0}});
    Value *val = list_get_view(arg, 1, &(EigsView){{0}});
    ARG_GUARD(key_v->type != VAL_STR, "shared_set", "a string key", make_null());
    Server *s = eigs_http_active;
    if (!s) return make_null();

    /* NULL on every encoder refusal, including N13 non-finite numbers.
     * A cyclic or deeper-than-JSON_MAX_DEPTH value (#730) is also refused. A
     * handler storing a self-referential value used to segfault the server
     * here; reject the store instead. eigs_json_encode has already raised, so
     * the route sees a catchable error rather than a silent no-op. */
    char *json = eigs_json_encode(val);
    if (!json) return make_null();
    long new_json_len = (long)strlen(json);
    long key_len = (long)val_str_len(key_v);
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
 * value on success, null on bad args / over-cap / type mismatch. Ints add
 * exactly and int64 overflow raises without mutating the counter (A). */
Value* builtin_shared_incr(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "shared_incr");
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2,
              "shared_incr", "[key, delta]", make_null());
    Value *key_v = list_get_view(arg, 0, &(EigsView){{0}});
    Value *delta_v = list_get_view(arg, 1, &(EigsView){{0}});
    ARG_GUARD(key_v->type != VAL_STR, "shared_incr", "a string key", make_null());
    ARG_GUARD(!val_is_number(delta_v), "shared_incr", "a number delta", make_null());
    Server *s = eigs_http_active;
    if (!s) return make_null();

    EigsNum delta = eigs_number_arg(delta_v, __func__);
    if (g_has_error) return make_null();
    long cap = shared_max_bytes();

    pthread_mutex_lock(&s->shared_mu);
    int idx = shared_find(s, key_v->data.str);
    EigsNum cur = { .is_int = 1, .value = { .i64 = 0 } };
    if (idx >= 0) {
        int pos = 0;
        Value *parsed = eigs_json_parse_root(s->shared[idx].json, &pos);   /* #777 */
        /* Read the number out BEFORE dropping the ref — decref may free it —
         * and drop it on the mismatch path too, which is the one an early
         * return makes easy to miss. */
        int bad = (!parsed || !val_is_number(parsed));
        if (!bad) cur = eigs_number_arg(parsed, __func__);
        val_decref(parsed);
        if (bad || g_has_error) {
            pthread_mutex_unlock(&s->shared_mu);
            return make_null();
        }
    }
    Value *new_v;
    if (cur.is_int && delta.is_int) {
        int64_t new_val;
        if (__builtin_add_overflow(cur.value.i64, delta.value.i64, &new_val)) {
            pthread_mutex_unlock(&s->shared_mu);
            rt_error(EK_VALUE, 0, "shared_incr: integer overflow in '+'");
            return make_null();
        }
        new_v = make_int(new_val);
    } else {
        double cur_f = cur.is_int ? (double)cur.value.i64 : cur.value.f64;
        double delta_f = delta.is_int ? (double)delta.value.i64 : delta.value.f64;
        new_v = make_float(eigs_math_result(cur_f + delta_f));
    }
    if (g_has_error) {
        val_decref(new_v);
        pthread_mutex_unlock(&s->shared_mu);
        return make_null();
    }
    /* eigs_json_encode borrows new_v. Keep its owned ref for the return value
     * on success and release it on every refusal before leaving the lock. */
    char *new_json = eigs_json_encode(new_v);
    /* N13: the finite operands may have overflowed. Encoding must succeed
     * before any shared entry or byte accounting changes. */
    if (!new_json) {
        val_decref(new_v);
        pthread_mutex_unlock(&s->shared_mu);
        return make_null();
    }
    long new_json_len = (long)strlen(new_json);
    long key_len = (long)val_str_len(key_v);
    long old_bytes = (idx >= 0) ? (long)strlen(s->shared[idx].json) : 0;
    long delta_bytes = (idx >= 0) ? (new_json_len - old_bytes)
                                  : (key_len + new_json_len);
    if (s->shared_bytes + delta_bytes > cap) {
        pthread_mutex_unlock(&s->shared_mu);
        free(new_json);
        val_decref(new_v);
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
    return new_v;
}

Value* builtin_shared_get(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_STR, "shared_get", "a string key", make_null());
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
    ARG_GUARD(!arg || arg->type != VAL_STR, "shared_has", "a string key", make_bool(0));
    Server *s = eigs_http_active;
    if (!s) return make_bool(0);  /* fs:ANSWER 0 means "key not present" -- the same value line 739 returns when shared_find misses; with no active server there is no shared store, so nothing is present */
    pthread_mutex_lock(&s->shared_mu);
    int idx = shared_find(s, arg->data.str);
    pthread_mutex_unlock(&s->shared_mu);
    return make_bool(idx >= 0);
}

Value* builtin_shared_delete(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_STR, "shared_delete", "a string key", make_int(0));
    Server *s = eigs_http_active;
    if (!s) return make_int(0);  /* fs:ANSWER 0 means "nothing removed" -- the same value line 761 returns via `removed` when the key is absent */
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
    return make_int(removed);
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
    if (!s) return make_int(0);  /* fs:ANSWER 0 is the store's key count, the same quantity line 784 returns; with no active server the store is empty */
    pthread_mutex_lock(&s->shared_mu);
    int n = s->shared_count;
    pthread_mutex_unlock(&s->shared_mu);
    return make_int(n);
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
    /* Init-window writes use MSG_DONTWAIT so a full send buffer cannot stall
     * the single responder thread. Partial / EAGAIN is failure: the caller
     * closes. Serving-path writes stay blocking. */
    while (len) {
        ssize_t n = eigs_send_no_sigpipe(fd, data, len,
                                       tls_write_nowait ? MSG_DONTWAIT : 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        data += n;
        len -= (size_t)n;
    }
    return 1;
}

static void send_response_with(int fd, int status, const char *status_text,
                              const char *content_type, const char *body,
                              long body_len, int cache_cors, const char *extra,
                              const RouteResponse *response) {
    /* Size from actual fields, with 512 bytes for fixed literals, integer
     * formatting and the final NUL. No fixed header buffer: even sixteen
     * maximum-size custom fields plus an arbitrarily long CORS origin fit.
     * Copy the snapshot under the mutex; never hold a config lock over I/O. */
    pthread_mutex_lock(&g_server.response_mu);
    const char *origin = cache_cors ? g_server.cors_origin : NULL;
    size_t cap = 512 + strlen(status_text) + strlen(extra) +
                 (content_type ? strlen(content_type) : 0) +
                 (origin ? strlen(origin) : 0) + (response ? response->bytes : 0);
    for (int i = 0; i < g_server.response_header_count; i++) {
        ResponseHeader *h = &g_server.response_headers[i];
        cap += strlen(h->name) + strlen(h->value) + 4;
    }
    content_type = route_header_value(response, "Content-Type", content_type);
    if (response && (status == 204 || status == 304)) content_type = NULL;
    char *header = xmalloc(cap);
    size_t used = (size_t)snprintf(header, cap, "HTTP/1.1 %d %s\r\n", status, status_text);
    if (content_type)
        used += (size_t)snprintf(header + used, cap - used,
                                "Content-Type: %s\r\nContent-Length: %ld\r\n",
                                content_type, body_len);
    if (status == 204 && !response)
        used += (size_t)snprintf(header + used, cap - used, "Allow: GET, HEAD, OPTIONS\r\n");
    if (cache_cors)
        used += (size_t)snprintf(header + used, cap - used, "Cache-Control: %s\r\n",
                                route_header_value(response, "Cache-Control", "no-cache"));
    if (origin)
        used += (size_t)snprintf(header + used, cap - used,
                                "Access-Control-Allow-Origin: %s\r\n"
                                "Access-Control-Allow-Methods: %s\r\n"
                                "Access-Control-Allow-Headers: %s\r\n",
                                route_header_value(response, "Access-Control-Allow-Origin", origin),
                                route_header_value(response, "Access-Control-Allow-Methods",
                                    status == 204 && !response ? "GET, HEAD, OPTIONS" : "GET, POST, OPTIONS"),
                                route_header_value(response, "Access-Control-Allow-Headers", "Content-Type"));
    used += (size_t)snprintf(header + used, cap - used, "Connection: close\r\n%s", extra);
    for (int i = 0; i < g_server.response_header_count; i++) {
        ResponseHeader *h = &g_server.response_headers[i];
        used += (size_t)snprintf(header + used, cap - used, "%s: %s\r\n", h->name,
                                route_header_value(response, h->name, h->value));
    }
    if (response) {
        for (int i = 0; i < response->header_count; i++) {
            const RouteHeader *h = &response->headers[i];
            if (strcasecmp(h->name, "Content-Type") == 0 ||
                strcasecmp(h->name, "Cache-Control") == 0) continue;
            if (origin && (strcasecmp(h->name, "Access-Control-Allow-Origin") == 0 ||
                           strcasecmp(h->name, "Access-Control-Allow-Methods") == 0 ||
                           strcasecmp(h->name, "Access-Control-Allow-Headers") == 0)) continue;
            int registered = 0;
            for (int j = 0; j < g_server.response_header_count; j++)
                if (strcasecmp(h->name, g_server.response_headers[j].name) == 0) registered = 1;
            if (!registered)
                used += (size_t)snprintf(header + used, cap - used, "%s: %s\r\n", h->name, h->value);
        }
        for (int i = 0; i < response->cookie_count; i++)
            used += (size_t)snprintf(header + used, cap - used, "Set-Cookie: %s\r\n", response->cookies[i]);
    }
    used += (size_t)snprintf(header + used, cap - used, "\r\n");
    pthread_mutex_unlock(&g_server.response_mu);
    int sent = write_all(fd, header, used);
    free(header);
    if (sent && !tls_suppress_body && body && body_len > 0 &&
        !(response && (status == 204 || status == 304)))
        write_all(fd, body, (size_t)body_len);
}

static void send_response_full(int fd, int status, const char *status_text,
                               const char *content_type, const char *body,
                               long body_len, int cache_cors, const char *extra) {
    send_response_with(fd, status, status_text, content_type, body, body_len,
                       cache_cors, extra, NULL);
}

static const char *route_status_phrase(int status) {
    switch (status) {
        case 200: return "OK";
        case 201: return "Created";
        case 202: return "Accepted";
        case 204: return "No Content";
        case 301: return "Moved Permanently";
        case 302: return "Found";
        case 303: return "See Other";
        case 304: return "Not Modified";
        case 307: return "Temporary Redirect";
        case 308: return "Permanent Redirect";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 408: return "Request Timeout";
        case 409: return "Conflict";
        case 410: return "Gone";
        case 413: return "Payload Too Large";
        case 415: return "Unsupported Media Type";
        case 422: return "Unprocessable Content";
        case 429: return "Too Many Requests";
        case 431: return "Request Header Fields Too Large";
        case 500: return "Internal Server Error";
        case 502: return "Bad Gateway";
        case 503: return "Service Unavailable";
        case 504: return "Gateway Timeout";
        default: return "";
    }
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

/* ================================================================
 * THE DOOR (#2370): every request is read through llhttp
 *
 * One place reads a request. The loop in handle_request reads the socket and
 * hands each read to door_feed, which gives the bytes to llhttp (v9.4.4,
 * src/vendor/llhttp/, strict, no leniency flag) and keeps beside it the rules
 * of #2370 that are ours:
 *
 *  - the head's limit (EIGS_HTTP_MAX_HEAD, 65,536 by default), held against
 *    one count per request: every byte of the head from the first byte the
 *    client sent, and of a chunked body every byte but the first sixteen hex
 *    digits of a size line, the CR ending that line and the byte after it,
 *    the chunk data and the two bytes after it, and after the last size line
 *    a CR that begins a line and the byte after it. The byte that would make
 *    the count one more than the limit is never given to the parser (431);
 *  - the parser's error (400), and the opening of HTTP/2 (505);
 *  - at the LF that completes the head, once the parser has accepted it: the
 *    protocol's name (400), the version (505), Transfer-Encoding (501), and a
 *    Content-Length over the body's limit (413);
 *  - at the LF of each chunk size line, the sum of the sizes announced so
 *    far against the body's limit (413).
 *
 * The parser's callbacks say where the head ends, what the body is and when
 * the message is complete; each of those pauses the parser, so the place of
 * every event in the read is known (llhttp_get_error_pos). The server holds
 * the head (from the first byte of the method through the empty line) and the
 * body (the data the parser framed). The bytes of a chunked body that are not
 * data are read and dropped, and bytes after the request are never read as a
 * request.
 * ================================================================ */

#include "vendor/llhttp/llhttp.h"

#define HTTP_DEFAULT_MAX_HEAD 65536L
static long g_http_max_head = 0;

/* EIGS_HTTP_MAX_HEAD: one to nine decimal digits, not zero; any other value
 * leaves the default. */
static long http_max_head(void) {
    if (g_http_max_head != 0) return g_http_max_head;
    long v = HTTP_DEFAULT_MAX_HEAD;
    const char *env = getenv("EIGS_HTTP_MAX_HEAD");
    if (env) {
        size_t n = strlen(env);
        int digits = n >= 1 && n <= 9;
        for (size_t i = 0; digits && i < n; i++)
            digits = env[i] >= '0' && env[i] <= '9';
        if (digits) {
            long parsed = strtol(env, NULL, 10);
            if (parsed > 0) v = parsed;
        }
    }
    g_http_max_head = v;
    return v;
}

/* Where the next byte stands; this decides whether the count holds it. */
enum { DOOR_HEAD, DOOR_BODY, DOOR_SIZE, DOOR_DATA, DOOR_TRAILER };

typedef struct {
    unsigned digits;     /* hex digits so far at the start of a size line */
    int in_digits;       /* still in that run of digits */
    int skip_next;       /* the byte after a CR the count leaves out */
    int line_start;      /* a trailer line begins here */
} DoorPlace;

typedef struct {
    llhttp_t parser;
    llhttp_settings_t settings;
    int phase;
    DoorPlace place;
    uint64_t count, limit, max_body, chunk_sum;
    long max_total;
    long charged;                   /* bytes charged to g_http_body_in_flight */
    char *head; size_t head_len, head_room;
    char *body; size_t body_len, body_room;
    const char *copy_from;          /* first head byte in the bytes being fed */
    int head_started;
    size_t url_off, url_len; int url_seen;
    char protocol[5]; size_t protocol_len;
    char name[18]; size_t name_len;
    /* Transfer-Encoding, read as its bytes arrive: every line's value,
     * joined by commas, cut at the commas, trimmed of SP and HTAB. */
    int field_is_te, te_seen, te_elements, te_bad;
    unsigned te_match; int te_trail, te_elem_bad;
    int ev_head, ev_chunk, ev_data_end, over_body, over_budget, complete;
    const char *why;                /* the body of a refusal */
    int bytes_after;                /* the read held bytes after a complete request */
    int client_stopped;             /* the client closed its side (cause 9) */
} Door;

/* Grow one held buffer to fit `more` bytes, charging the growth to the
 * budget for what all connections hold at once. */
static int door_hold(Door *d, char **buf, size_t *len, size_t *room, const char *at, size_t more) {
    if (*len + more + 1 > *room) {
        size_t want = *room ? *room : 1024;
        while (want < *len + more + 1) want *= 2;
        long inc = (long)(want - *room);
        long in_flight = __atomic_add_fetch(&g_http_body_in_flight, inc, __ATOMIC_RELAXED);
        d->charged += inc;
        if (in_flight > d->max_total) { d->over_budget = 1; return -1; }
        *buf = xrealloc(*buf, want);
        *room = want;
    }
    memcpy(*buf + *len, at, more);
    *len += more;
    (*buf)[*len] = '\0';
    return 0;
}

static int door_lower(int c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; }

static size_t door_head_offset(Door *d, const char *at) {
    return d->head_len + (size_t)(at - d->copy_from);
}

static int door_on_method(llhttp_t *p, const char *at, size_t n) {
    Door *d = p->data;
    (void)n;
    if (!d->head_started) { d->head_started = 1; d->copy_from = at; }
    return 0;
}

static int door_on_url(llhttp_t *p, const char *at, size_t n) {
    Door *d = p->data;
    if (!d->url_seen) { d->url_seen = 1; d->url_off = door_head_offset(d, at); }
    d->url_len += n;
    return 0;
}

static int door_on_protocol(llhttp_t *p, const char *at, size_t n) {
    Door *d = p->data;
    for (size_t i = 0; i < n; i++, d->protocol_len++)
        if (d->protocol_len < sizeof d->protocol) d->protocol[d->protocol_len] = at[i];
    return 0;
}

static int door_on_header_field(llhttp_t *p, const char *at, size_t n) {
    Door *d = p->data;
    if (d->ev_head || d->phase != DOOR_HEAD) return 0;   /* a trailer field */
    for (size_t i = 0; i < n; i++, d->name_len++)
        if (d->name_len < sizeof d->name) d->name[d->name_len] = (char)door_lower((unsigned char)at[i]);
    return 0;
}

static void door_te_element_end(Door *d) {
    d->te_elements++;
    if (d->te_elem_bad || d->te_match != 7) d->te_bad = 1;
    d->te_match = 0; d->te_trail = 0; d->te_elem_bad = 0;
}

static int door_on_header_field_complete(llhttp_t *p) {
    Door *d = p->data;
    if (d->ev_head || d->phase != DOOR_HEAD) return 0;
    d->field_is_te = d->name_len == 17 && memcmp(d->name, "transfer-encoding", 17) == 0;
    d->name_len = 0;
    if (d->field_is_te) d->te_seen = 1;
    return 0;
}

static int door_on_header_value(llhttp_t *p, const char *at, size_t n) {
    Door *d = p->data;
    if (!d->field_is_te || d->ev_head || d->phase != DOOR_HEAD) return 0;
    for (size_t i = 0; i < n; i++) {
        int c = (unsigned char)at[i];
        if (c == ',') { door_te_element_end(d); continue; }
        if (c == ' ' || c == '\t') {
            if (d->te_match || d->te_elem_bad) d->te_trail = 1;
            continue;
        }
        if (d->te_trail || d->te_match >= 7 || door_lower(c) != "chunked"[d->te_match]) d->te_elem_bad = 1;
        else d->te_match++;
    }
    return 0;
}

static int door_on_header_value_complete(llhttp_t *p) {
    Door *d = p->data;
    if (d->field_is_te && !d->ev_head && d->phase == DOOR_HEAD) door_te_element_end(d);
    d->field_is_te = 0;
    return 0;
}

static int door_on_headers_complete(llhttp_t *p) {
    Door *d = p->data;
    d->ev_head = 1;
    return HPE_PAUSED;      /* causes 4 to 7 wait for the parser's own checks */
}

static int door_on_body(llhttp_t *p, const char *at, size_t n) {
    Door *d = p->data;
    return door_hold(d, &d->body, &d->body_len, &d->body_room, at, n) == 0 ? 0 : HPE_USER;
}

static int door_on_chunk_header(llhttp_t *p) {
    Door *d = p->data;
    /* Cause 8, at the LF that ends the size line: the size it announces. */
    if (p->content_length > d->max_body - d->chunk_sum) d->over_body = 1;
    else d->chunk_sum += p->content_length;
    d->ev_chunk = 1;
    return HPE_PAUSED;
}

static int door_on_chunk_complete(llhttp_t *p) {
    Door *d = p->data;
    if (d->phase == DOOR_TRAILER) return 0;    /* the message completes next */
    d->ev_data_end = 1;
    return HPE_PAUSED;
}

static int door_on_message_complete(llhttp_t *p) {
    Door *d = p->data;
    d->complete = 1;
    return HPE_PAUSED;
}

static void door_init(Door *d, uint64_t limit, uint64_t max_body, long max_total) {
    memset(d, 0, sizeof *d);
    llhttp_settings_init(&d->settings);
    d->settings.on_method = door_on_method;
    d->settings.on_url = door_on_url;
    d->settings.on_protocol = door_on_protocol;
    d->settings.on_header_field = door_on_header_field;
    d->settings.on_header_field_complete = door_on_header_field_complete;
    d->settings.on_header_value = door_on_header_value;
    d->settings.on_header_value_complete = door_on_header_value_complete;
    d->settings.on_headers_complete = door_on_headers_complete;
    d->settings.on_body = door_on_body;
    d->settings.on_chunk_header = door_on_chunk_header;
    d->settings.on_chunk_complete = door_on_chunk_complete;
    d->settings.on_message_complete = door_on_message_complete;
    llhttp_init(&d->parser, HTTP_REQUEST, &d->settings);
    d->parser.data = d;
    d->phase = DOOR_HEAD;
    d->limit = limit;
    d->max_body = max_body;
    d->max_total = max_total;
}

static int door_is_hex(int c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/* Does the count hold this byte? Advances `pl` past it. */
static int door_counts(int phase, DoorPlace *pl, int c) {
    switch (phase) {
    case DOOR_HEAD: return 1;
    case DOOR_SIZE:
        if (pl->skip_next) { pl->skip_next = 0; return 0; }
        if (c == '\r') { pl->skip_next = 1; return 0; }
        if (pl->in_digits && door_is_hex(c)) return pl->digits++ >= 16;
        pl->in_digits = 0;
        return 1;
    case DOOR_TRAILER:
        if (pl->skip_next) { pl->skip_next = 0; return 0; }
        if (pl->line_start && c == '\r') { pl->skip_next = 1; return 0; }
        pl->line_start = c == '\n';
        return 1;
    default: return 0;     /* DOOR_BODY, DOOR_DATA */
    }
}

/* Cause 2: the parser's own refusal. */
static int door_parser_error(Door *d, enum llhttp_errno err) {
    d->why = err == HPE_INVALID_CONTENT_LENGTH || err == HPE_UNEXPECTED_CONTENT_LENGTH
                 ? "Invalid Content-Length" : llhttp_get_error_reason(&d->parser);
    if (!d->why) d->why = "Bad Request";
    return 400;
}

/* What door_feed decided. 0: the request is not complete yet. */
#define DOOR_SERVE 1

/* Causes 4 to 7, at the LF that completes the head, after the parser has
 * accepted it. */
static int door_head_rules(Door *d) {
    if (d->protocol_len && !(d->protocol_len == 4 && memcmp(d->protocol, "HTTP", 4) == 0)) {
        d->why = "Invalid HTTP version";
        return 400;
    }
    if (!(d->parser.http_major == 1 && (d->parser.http_minor == 0 || d->parser.http_minor == 1))) {
        d->why = "HTTP version not supported";
        return 505;
    }
    if (d->te_seen && (d->te_elements != 1 || d->te_bad)) {
        d->why = "Transfer-Encoding not implemented";
        return 501;
    }
    if ((d->parser.flags & F_CONTENT_LENGTH) && d->parser.content_length > d->max_body) {
        d->why = "Payload too large";
        return 413;
    }
    return 0;
}

/* Give the bytes of one read to the parser. Returns 0 to read on, DOOR_SERVE
 * when the request is complete, or the status of a refusal. */
static int door_feed(Door *d, const char *buf, size_t n) {
    size_t pos = 0;
    while (pos < n) {
        /* Each byte adds at most one to the count, so `room` bytes cannot pass
         * the limit. With no room left, the next byte is looked at alone: if
         * the count holds it, it would pass the limit and is never given to
         * the parser (cause 1). The count itself is taken below, over the
         * bytes the parser took, once each. */
        size_t end = n;
        if (d->phase != DOOR_BODY && d->phase != DOOR_DATA) {
            uint64_t room = d->limit - d->count;
            if (room == 0) {
                DoorPlace pl = d->place;
                if (door_counts(d->phase, &pl, (unsigned char)buf[pos])) {
                    d->why = "Headers too large";
                    return 431;
                }
                end = pos + 1;
            } else if (room < (uint64_t)(n - pos)) {
                end = pos + (size_t)room;
            }
        }
        if (d->head_started) d->copy_from = buf + pos;
        enum llhttp_errno err = llhttp_execute(&d->parser, buf + pos, end - pos);
        if (d->over_budget) { d->why = "Server overloaded"; return 503; }
        size_t q = end;
        if (err == HPE_PAUSED) q = (size_t)(llhttp_get_error_pos(&d->parser) - buf);
        else if (err == HPE_PAUSED_H2_UPGRADE) { d->why = "HTTP version not supported"; return 505; }
        else if (err != HPE_OK) return door_parser_error(d, err);
        for (size_t i = pos; i < q; i++)
            d->count += (uint64_t)door_counts(d->phase, &d->place, (unsigned char)buf[i]);
        if (d->phase == DOOR_HEAD && d->head_started) {
            const char *from = d->copy_from;
            if (from < buf + q &&
                door_hold(d, &d->head, &d->head_len, &d->head_room, from, (size_t)(buf + q - from)) != 0)
            { d->why = "Server overloaded"; return 503; }
            d->copy_from = buf + q;
        }
        pos = q;
        if (err == HPE_PAUSED) {
            llhttp_resume(&d->parser);
            if (d->ev_head) {
                /* Run the parser's own checks at the end of the head first. */
                enum llhttp_errno after = llhttp_execute(&d->parser, buf + pos, 0);
                if (after != HPE_OK && after != HPE_PAUSED && after != HPE_PAUSED_UPGRADE)
                    return door_parser_error(d, after);
                int status = door_head_rules(d);
                if (status) return status;
                d->ev_head = 0;
                d->phase = (d->parser.flags & F_CHUNKED) ? DOOR_SIZE : DOOR_BODY;
                memset(&d->place, 0, sizeof d->place);
                d->place.in_digits = 1;
                if (after == HPE_PAUSED) llhttp_resume(&d->parser);
            }
            if (d->ev_chunk) {
                d->ev_chunk = 0;
                if (d->over_body) { d->why = "Payload too large"; return 413; }
                d->phase = d->parser.content_length > 0 ? DOOR_DATA : DOOR_TRAILER;
                memset(&d->place, 0, sizeof d->place);
                d->place.line_start = 1;
            }
            if (d->ev_data_end) {
                d->ev_data_end = 0;
                d->phase = DOOR_SIZE;
                memset(&d->place, 0, sizeof d->place);
                d->place.in_digits = 1;
            }
            if (d->complete) { d->bytes_after = pos < n; return DOOR_SERVE; }
            continue;
        }
        if (d->complete) { d->bytes_after = pos < n; return DOOR_SERVE; }
    }
    return 0;
}

static void door_free(Door *d) {
    __atomic_sub_fetch(&g_http_body_in_flight, d->charged, __ATOMIC_RELAXED);
    d->charged = 0;
    free(d->head);
    free(d->body);
    d->head = d->body = NULL;
}

/* After an answer: no more is written, and what the client still sends is
 * read and dropped for a short while, so closing does not reset a connection
 * whose answer the client has not read yet. Two bounds: 2 s, and the most
 * bytes one request can be on the wire under the limits (#2370: the head's
 * limit, plus twenty-one times the body's, plus 20), so a client that writes a
 * whole request before it reads (curl's uploads, tests/test_http_server.sh
 * HS12) still reads its refusal, and one that sends without end is cut off. It is needed only
 * when bytes the server will not read are still to come or already waiting:
 * after a refusal sent before the client stopped, or after a complete request
 * with bytes behind it. Called after the request's head and body are freed;
 * it holds only the read buffer. */
#define DOOR_LINGER_SEC   2.0
static int door_needs_linger(int fd, const Door *d, int verdict) {
    if (verdict < 0 || d->client_stopped) return 0;
    if (verdict != DOOR_SERVE || d->bytes_after) return 1;
    char c;
    ssize_t waiting = recv(fd, &c, 1, MSG_PEEK | MSG_DONTWAIT);
    return waiting > 0;
}

static void door_linger(int fd, char *buf, size_t room, uint64_t most) {
    shutdown(fd, SHUT_WR);
    double until = monotonic_now() + DOOR_LINGER_SEC;
    uint64_t drained = 0;
    while (drained < most) {
        double left = until - monotonic_now();
        if (left <= 0) break;
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int r = poll(&pfd, 1, (int)(left * 1000) + 1);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        ssize_t got = read(fd, buf, room);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        drained += (uint64_t)got;
    }
}

static const char *door_status_text(int status) {
    switch (status) {
    case 400: return "Bad Request";
    case 408: return "Request Timeout";
    case 413: return "Payload Too Large";
    case 431: return "Request Header Fields Too Large";
    case 501: return "Not Implemented";
    case 503: return "Service Unavailable";
    case 505: return "HTTP Version Not Supported";
    default: return "";
    }
}

/* Time limits: 10 s for the head from the first read (EIGS_HTTP_HEADER_TIMEOUT)
 * and a least rate looked at when bytes arrive (EIGS_HTTP_HEADER_MIN_RATE,
 * after a grace of 2 s); for the whole request 5 s without a byte and 30 s in
 * all. Each answers 408 once the client has sent a byte; a connection on which
 * nothing was sent is closed without an answer. */
#define HTTP_REQUEST_DEADLINE_SEC 30
#define HTTP_READ_TIMEOUT_SEC 5
#define HTTP_HEADER_DEADLINE_SEC 10
#define HTTP_HEADER_MIN_RATE     256   /* bytes/sec */
#define HTTP_HEADER_GRACE_SEC    2
#define HTTP_READ_ROOM 16384

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

/* Read one request through the door. Returns DOOR_SERVE, a refusal's status,
 * or -1 for a connection on which nothing was sent (no answer). */
static int door_read(int fd, Door *d, char *rbuf) {
    double start = monotonic_now();
    double total_deadline = start + HTTP_REQUEST_DEADLINE_SEC;
    double header_deadline = start + (double)http_header_deadline();
    long header_min_rate = http_header_min_rate();
    double last_byte = start;
    size_t received = 0;
    for (;;) {
        double now = monotonic_now();
        double wait = total_deadline - now;
        if (last_byte + HTTP_READ_TIMEOUT_SEC - now < wait) wait = last_byte + HTTP_READ_TIMEOUT_SEC - now;
        if (d->phase == DOOR_HEAD && header_deadline - now < wait) wait = header_deadline - now;
        if (wait <= 0) {
            d->why = d->phase == DOOR_HEAD && now >= header_deadline ? "Request header timeout" : "Request timeout";
            return received ? 408 : -1;
        }
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int r = poll(&pfd, 1, (int)(wait * 1000) + 1);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) { d->why = "Bad Request"; return received ? 400 : -1; }
        if (r == 0) continue;           /* the loop's top decides which limit passed */
        ssize_t got = read(fd, rbuf, HTTP_READ_ROOM);
        if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (got <= 0) {                 /* cause 9: the client stopped */
            d->client_stopped = got == 0;
            d->why = "Incomplete request";
            return received ? 400 : -1;
        }
        received += (size_t)got;
        last_byte = monotonic_now();
        int verdict = door_feed(d, rbuf, (size_t)got);
        if (verdict) return verdict;
        if (d->phase == DOOR_HEAD && header_min_rate > 0) {
            double elapsed = last_byte - start;
            if (elapsed > HTTP_HEADER_GRACE_SEC && (double)received < (double)header_min_rate * elapsed) {
                d->why = "Request header too slow";
                return 408;
            }
        }
    }
}

static void handle_request(int fd) {
    RouteResponse response = {0};
    tls_response = &response;
    tls_suppress_body = 0;
    Door door;
    door_init(&door, (uint64_t)http_max_head(), (uint64_t)http_max_body(), http_max_body_total());
    char *rbuf = xmalloc(HTTP_READ_ROOM);   /* charged apart: it outlives door_free */
    __atomic_add_fetch(&g_http_body_in_flight, (long)HTTP_READ_ROOM, __ATOMIC_RELAXED);
    char *path = NULL;
    char method[32] = {0};

    int verdict = door_read(fd, &door, rbuf);
    if (verdict < 0) goto done;               /* nothing was sent: no answer */
    if (verdict != DOOR_SERVE) {
        /* A refusal, before any route, auth source or static file. */
        const char *m = door.why ? door.why : door_status_text(verdict);
        send_response(fd, verdict, door_status_text(verdict), "text/plain", m, (long)strlen(m));
        goto done;
    }

    snprintf(method, sizeof method, "%s", llhttp_method_name((llhttp_method_t)door.parser.method));
    /* The route identity is the target's path; its `?...` is request data
     * (lib/http.eigs parse_query reads it from the head). */
    path = xmalloc(door.url_len + 1);
    memcpy(path, door.head + door.url_off, door.url_len);
    path[door.url_len] = '\0';
    char *qmark = strchr(path, '?');
    if (qmark) *qmark = '\0';

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
    tls_request_body = door.body ? door.body : "";
    tls_request_headers = door.head;
    tls_request_head_end = (int)door.head_len;

    const StaticRoot *static_root = NULL;
    for (int i = 0; i < g_server.static_count; i++) {
        const StaticRoot *root = &g_server.static_roots[i];
        size_t pfx_len = root->prefix_len;
        /* strncmp stops at NUL; the indexed read is reached only on a match. */
        if ((!static_root || pfx_len > static_root->prefix_len) &&
            strncmp(path, root->prefix, pfx_len) == 0 &&
            (path[pfx_len] == '/' || path[pfx_len] == '\0'))
            static_root = root;
    }
    if (static_root) {
        const char *rel = path + static_root->prefix_len;
        if (rel[0] == '/') rel++;
        if (rel[0] == '/') {
            send_response(fd, 403, "Forbidden", "text/plain", "Forbidden", 9);
            goto done;
        }

        char resolved_path[4096];
        int static_fd = -1;
        int open_status = open_static_file_confined(static_root->directory, rel,
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
    }

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
                    route_response_clear(&response);
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
                        Value *auth_fn = env_get_counted(g_global_env, "require_auth");
                        if (!auth_fn || (auth_fn->type != VAL_FN && auth_fn->type != VAL_BUILTIN)) {
                            if (auth_fn) val_decref(auth_fn);
                            send_response(fd, 500, "Internal Server Error", "application/json",
                                "{\"error\": \"require_auth not defined or not callable\"}", 53);
                            goto done;
                        }
                        val_decref(auth_fn);
                        auth_src = xstrdup("require_auth of null");
                    }
                    TokenList auth_tl = tokenize(auth_src);
                    ASTNode *auth_ast = parse(&auth_tl);
                    Env *auth_env = env_new(g_global_env);
                    EigsChunk *auth_chunk = compile_ast(auth_ast, auth_env, auth_src, "<embed>");
                    Value *auth_result = vm_execute(auth_chunk, auth_env);
                    route_response_clear(&response);
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
                route_response_clear(&response);
                TokenList tl = tokenize(r->payload);
                ASTNode *ast = parse(&tl);
                Env *req_env = env_new(g_global_env);
                EigsChunk *req_chunk = compile_ast(ast, req_env, r->payload, "<embed>");
                Value *result = vm_execute(req_chunk, req_env);
                chunk_free(req_chunk);
                if ((g_has_error && !g_exit_requested) || g_parse_errors) {
                    /* #1140: an uncaught error in the route source is a 500,
                     * not `200 null`. The body is generic: the error text can
                     * carry paths, connection details or interpolated values,
                     * and any caller (unauthenticated on http_route) would
                     * read it. The detail stays on the server's stderr. An
                     * `exit` in the route is an unwind, not an error, so it
                     * keeps its old answer. */
                    static const char body500[] = "{\"error\": \"internal error\"}";
                    route_response_clear(&response);
                    send_response(fd, 500, "Internal Server Error", "application/json",
                                  body500, (long)(sizeof body500 - 1));
                    env_decref(req_env);
                    free_tokenlist(&tl);
                    free_ast(ast);
                    if (result) val_decref(result);
                    goto done;
                }
                char *result_str = value_to_string(result);
                env_decref(req_env);

                const char *ct = "application/json";
                if (result_str[0] != '{' && result_str[0] != '[')
                    ct = "text/plain";
                int status = response.status ? response.status : 200;
                send_response_with(fd, status, route_status_phrase(status), ct,
                                   result_str, strlen(result_str), 1, "", &response);
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
    route_response_clear(&response);
    tls_response = NULL;
    tls_request_body = NULL;
    tls_request_headers = NULL;
    tls_request_head_end = -1;
    tls_session_id = NULL;
    tls_suppress_body = 0;
    /* Release what this request held (the door charged it as it grew), then
     * linger, holding only the read buffer, when the client may still send. */
    int linger = door_needs_linger(fd, &door, verdict);
    door_free(&door);
    if (linger) door_linger(fd, rbuf, HTTP_READ_ROOM, door.limit + 21 * door.max_body + 20);
    __atomic_sub_fetch(&g_http_body_in_flight, (long)HTTP_READ_ROOM, __ATOMIC_RELAXED);
    free(rbuf);
    free(path);
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

    Env *global = eigs_global_env_create();   /* + builtin layer (#1388) */

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
    /* A code route can unwind before it closes handles it opened. Drain them
     * while the worker's value world is still alive, matching eigs_close and
     * CLI teardown; otherwise each failed request can permanently leak its
     * store FILE (and eventually exhaust the server's descriptor limit). */
    handle_table_drain(worker);
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

static int http_socket_port(int fd, int fallback) {
    struct sockaddr_in addr;
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &len) == 0)
        return (int)ntohs(addr.sin_port);
    return fallback;
}

void http_serve_blocking(int port) {
    int server_fd;

    http_prime_config_caches();  /* before any worker thread exists (#1137) */

    if (g_server.early_bind_fd >= 0) {
        stop_init_responder(eigs_http_active);
        server_fd = g_server.early_bind_fd;
        port = http_socket_port(server_fd, port);
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

        port = http_socket_port(server_fd, port);
        printf("EigenScript HTTP server listening on 0.0.0.0:%d\n", port);
    }
    fflush(stdout);

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
            /* Accept-loop shed does not read the request, so HEAD and GET
             * must produce the same wire image: 503, Content-Length 0, no
             * body. cache_cors stays 0 (the historical serving-shed shape). */
            tls_suppress_body = 1;
            send_response_full(client_fd, 503, "Service Unavailable", "text/plain",
                               "", 0, 0, "");
            tls_suppress_body = 0;
            close(client_fd);
            continue;
        }

        /* Per-source-IP cap: one address may not hold all the global slots.
         * Shed with 503 before spending a worker on it. */
        uint32_t caddr = client_addr.sin_addr.s_addr;
        if (!ip_conn_acquire(caddr)) {
            tls_suppress_body = 1;
            send_response_full(client_fd, 503, "Service Unavailable", "text/plain",
                               "", 0, 0, "");
            tls_suppress_body = 0;
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
    for (int i = 0; i < s->static_count; i++) {
        free(s->static_roots[i].prefix);
        free(s->static_roots[i].directory);
    }
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

unsigned ext_http_live_handles(EigsState *st) {
    Server *s = st ? st->ext_http_server : NULL;
    return s && (s->early_bind_fd >= 0 || s->init_thread_active || s->serving)
        ? EIGS_LIVE_HTTP : 0;
}
