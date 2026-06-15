/*
 * EigenScript HTTP Extension
 * HTTP server, route registration, request handling.
 * Compiled only when EIGENSCRIPT_EXT_HTTP=1.
 */

#include "ext_http_internal.h"
#include "state.h"
#include "trace.h"
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

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
static volatile int g_init_complete = 0;
static pthread_t g_health_tid;
static int g_health_thread_active = 0;

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

void* health_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    printf("[health-thread] Started on fd=%d, pid=%d\n", fd, getpid());
    fflush(stdout);
    int req_count = 0;
    while (!g_init_complete) {
        struct sockaddr_in client;
        socklen_t len = sizeof(client);
        int conn = accept(fd, (struct sockaddr*)&client, &len);
        if (conn < 0) {
            printf("[health-thread] accept() failed: errno=%d\n", errno);
            fflush(stdout);
            break;
        }
        if (g_init_complete) { close(conn); break; }
        struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        char buf[1024];
        recv(conn, buf, sizeof(buf), 0);
        const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\n\r\nOK";
        send(conn, resp, strlen(resp), 0);
        close(conn);
        req_count++;
        printf("[health-thread] Served health check #%d\n", req_count);
        fflush(stdout);
    }
    printf("[health-thread] Exiting after %d requests\n", req_count);
    fflush(stdout);
    return NULL;
}

/* ================================================================
 * HTTP BUILTINS
 * ================================================================ */

Value* builtin_http_route(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();

    if (g_server.route_count >= MAX_ROUTES) return make_null();

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

Value* builtin_http_early_bind(Value *arg) {
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
    if (listen(server_fd, 128) < 0) {
        perror("listen"); close(server_fd); return make_str("error");
    }

    g_server.early_bind_fd = server_fd;
    printf("Port %d bound (early bind for health check)\n", port);
    fflush(stdout);

    if (pthread_create(&g_health_tid, NULL, health_thread, (void*)(intptr_t)server_fd) == 0) {
        g_health_thread_active = 1;
        printf("Health thread started for early responses\n");
    } else {
        perror("pthread_create");
        printf("Warning: health thread failed, continuing without early responses\n");
    }
    fflush(stdout);

    return make_str("bound");
}

Value* builtin_http_serve(Value *arg) {
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
    Value *hdr_obj = eigs_json_parse_value(headers_json, &jpos);
    if (hdr_obj && hdr_obj->type == VAL_LIST) {
        for (int i = 0; i + 1 < hdr_obj->data.list.count && hdr_count < 32 && argc < 90; i += 2) {
            char *hk = value_to_string(hdr_obj->data.list.items[i]);
            char *hv = value_to_string(hdr_obj->data.list.items[i + 1]);
            snprintf(header_bufs[hdr_count], sizeof(header_bufs[0]), "%s: %s", hk, hv);
            free(hk); free(hv);
            argv[argc++] = "-H";
            argv[argc++] = header_bufs[hdr_count];
            hdr_count++;
        }
    }

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

    char *json = eigs_json_encode(val);
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
    Value *v = eigs_json_parse_value(json_copy, &pos);
    free(json_copy);
    return v ? v : make_null();
}

Value* builtin_shared_has(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    Server *s = eigs_http_active;
    if (!s) return make_num(0);
    pthread_mutex_lock(&s->shared_mu);
    int idx = shared_find(s, arg->data.str);
    pthread_mutex_unlock(&s->shared_mu);
    return make_num(idx >= 0 ? 1 : 0);
}

Value* builtin_shared_delete(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    Server *s = eigs_http_active;
    if (!s) return make_num(0);
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
    if (!s) return make_num(0);
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

static void send_response(int fd, int status, const char *status_text,
                          const char *content_type, const char *body, long body_len) {
    char header[8192];
    int hlen;
    if (g_server.cors_origin) {
        hlen = snprintf(header, sizeof(header),
            "HTTP/1.1 %d %s\r\n"
            "Content-Type: %s\r\n"
            "Content-Length: %ld\r\n"
            "Cache-Control: no-cache\r\n"
            "Access-Control-Allow-Origin: %s\r\n"
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            "Access-Control-Allow-Headers: Content-Type\r\n"
            "Connection: close\r\n"
            "\r\n",
            status, status_text, content_type, body_len, g_server.cors_origin);
    } else {
        hlen = snprintf(header, sizeof(header),
            "HTTP/1.1 %d %s\r\n"
            "Content-Type: %s\r\n"
            "Content-Length: %ld\r\n"
            "Cache-Control: no-cache\r\n"
            "Connection: close\r\n"
            "\r\n",
            status, status_text, content_type, body_len);
    }

    if (write(fd, header, hlen) <= 0) return;
    /* HEAD requests want headers but no body. Caller flips tls_suppress_body
     * before invoking send_response so existing call sites need no change. */
    if (tls_suppress_body) return;
    if (body && body_len > 0) {
        long sent = 0;
        while (sent < body_len) {
            long n = write(fd, body + sent, body_len - sent);
            if (n <= 0) break;
            sent += n;
        }
    }
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

static double monotonic_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void handle_request(int fd) {
    /* Per-read timeout (backstop for fully idle sockets) */
    struct timeval tv = { .tv_sec = HTTP_READ_TIMEOUT_SEC, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    double deadline = monotonic_now() + HTTP_REQUEST_DEADLINE_SEC;

    long max_body = http_max_body();
    size_t cap = 8192;
    char *reqbuf = xmalloc(cap);
    int total = 0;
    int header_end = -1;

    for (;;) {
        /* Enforce total request deadline */
        if (monotonic_now() >= deadline) {
            free(reqbuf); close(fd); return;
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
                    free(reqbuf); close(fd); return;
                }
                break;
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
            char *cl = strcasestr(reqbuf, "Content-Length:");
            reqbuf[header_end] = saved;
            if (cl) {
                /* atoi silently accepts negative and non-numeric input; a
                 * negative Content-Length would make body_received trivially
                 * >= content_length and exit the read loop mid-body. Parse
                 * with strtol and reject anything outside [0, max_body]. */
                char *clend = NULL;
                long content_length = strtol(cl + 15, &clend, 10);
                if (clend == cl + 15 || content_length < 0 || content_length > max_body) {
                    /* Malformed or oversized Content-Length — answer 400 so
                     * the client sees a real error instead of hanging until
                     * the per-connection deadline. */
                    const char *m = "Invalid Content-Length";
                    send_response(fd, 400, "Bad Request", "text/plain",
                                  m, (long)strlen(m));
                    free(reqbuf); close(fd); return;
                }
                int body_received = total - header_end;
                if (body_received >= content_length) break;
            } else {
                break;
            }
        }
    }

    if (total == 0) { free(reqbuf); close(fd); return; }
    reqbuf[total] = '\0';

    char method[16] = {0}, path[2048] = {0}, version[16] = {0};
    if (sscanf(reqbuf, "%15s %2047s %15s", method, path, version) != 3) {
        send_response(fd, 400, "Bad Request", "text/plain", "Invalid request line", 20);
        free(reqbuf); close(fd); return;
    }

    /* Validate HTTP version: must start with "HTTP/" followed by digit. The
     * previous code accepted anything (e.g. "HTTP/junk") because sscanf only
     * checks length. Strict here keeps downgrade/parser games out. */
    if (strncmp(version, "HTTP/", 5) != 0 ||
        !isdigit((unsigned char)version[5])) {
        send_response(fd, 400, "Bad Request", "text/plain", "Invalid HTTP version", 20);
        free(reqbuf); close(fd); return;
    }

    char *body = NULL;
    if (header_end > 0 && header_end < total) {
        body = reqbuf + header_end;
    }

    if (strcmp(method, "OPTIONS") == 0) {
        /* Proper preflight: advertise the methods this server handles and
         * mirror CORS headers when configured. 204 No Content is the more
         * RFC-correct reply for an empty-body preflight. */
        char hbuf[512];
        int hl;
        if (g_server.cors_origin) {
            hl = snprintf(hbuf, sizeof(hbuf),
                "HTTP/1.1 204 No Content\r\n"
                "Allow: GET, HEAD, OPTIONS\r\n"
                "Access-Control-Allow-Origin: %s\r\n"
                "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
                "Access-Control-Allow-Headers: Content-Type\r\n"
                "Cache-Control: no-cache\r\n"
                "Connection: close\r\n"
                "\r\n", g_server.cors_origin);
        } else {
            hl = snprintf(hbuf, sizeof(hbuf),
                "HTTP/1.1 204 No Content\r\n"
                "Allow: GET, HEAD, OPTIONS\r\n"
                "Cache-Control: no-cache\r\n"
                "Connection: close\r\n"
                "\r\n");
        }
        ssize_t bw = write(fd, hbuf, hl);
        (void)bw;
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
                 * Route-level auth: require_auth is looked up in the worker
                 * env too. http_route_authed users need require_auth to be
                 * either self-contained in the route source or accessible
                 * through a shared-state primitive (not yet built); until
                 * then, authed routes 500 with "require_auth not defined". */
                if (r->requires_auth) {
                    Value *auth_fn = env_get(g_global_env, "require_auth");
                    if (!auth_fn || (auth_fn->type != VAL_FN && auth_fn->type != VAL_BUILTIN)) {
                        send_response(fd, 500, "Internal Server Error", "application/json",
                            "{\"error\": \"require_auth not defined or not callable\"}", 53);
                        goto done;
                    }
                    TokenList auth_tl = tokenize("require_auth of null");
                    ASTNode *auth_ast = parse(&auth_tl);
                    Env *auth_env = env_new(g_global_env);
                    EigsChunk *auth_chunk = compile_ast(auth_ast, auth_env);
                    Value *auth_result = vm_execute(auth_chunk, auth_env);
                    chunk_free(auth_chunk);
                    env_decref(auth_env);
                    char *auth_str = value_to_string(auth_result);
                    if (auth_str[0] != '\0') {
                        send_response(fd, 401, "Unauthorized", "application/json",
                                      auth_str, strlen(auth_str));
                        free(auth_str);
                        free_tokenlist(&auth_tl);
                        goto done;
                    }
                    free(auth_str);
                    free_tokenlist(&auth_tl);
                }
                TokenList tl = tokenize(r->payload);
                ASTNode *ast = parse(&tl);
                Env *req_env = env_new(g_global_env);
                EigsChunk *req_chunk = compile_ast(ast, req_env);
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
} ConnArg;

static void *http_conn_thread(void *arg) {
    ConnArg *ca = arg;
    int fd = ca->fd;
    Server *main_server = ca->server;
    free(ca);

    EigsState *worker = eigs_state_new();
    if (!worker) goto drop;
    if (!eigs_thread_attach(worker)) {
        eigs_state_destroy(worker);
        goto drop;
    }

    Env *global = env_new(NULL);
    register_builtins(global);
    register_store_builtins(global);
    g_global_env = global;

    /* register_http_builtins allocated a scratch Server on the worker
     * state (so http_route/http_serve called inside a code route don't
     * crash) and pointed eigs_http_active at it. Re-point at the spawning
     * Server so handle_request reads the main route table. */
    eigs_http_active = main_server;

    handle_request(fd);
    fd = -1;  /* handle_request closed it */

    trace_shutdown();
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
    return NULL;
}

void http_serve_blocking(int port) {
    int server_fd;

    if (g_server.early_bind_fd > 0) {
        g_init_complete = 1;
        if (g_health_thread_active) {
            int wake = socket(AF_INET, SOCK_STREAM, 0);
            if (wake >= 0) {
                struct sockaddr_in lo;
                memset(&lo, 0, sizeof(lo));
                lo.sin_family = AF_INET;
                lo.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                lo.sin_port = htons(port);
                connect(wake, (struct sockaddr*)&lo, sizeof(lo));
                close(wake);
            }
            pthread_join(g_health_tid, NULL);
            g_health_thread_active = 0;
            printf("Health thread stopped, main server taking over\n");
        }
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

        if (listen(server_fd, 128) < 0) {
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
            const char *busy =
                "HTTP/1.1 503 Service Unavailable\r\n"
                "Content-Type: text/plain\r\n"
                "Content-Length: 11\r\n"
                "Connection: close\r\n"
                "\r\n"
                "Overloaded\n";
            ssize_t bw = write(client_fd, busy, strlen(busy));
            (void)bw;
            close(client_fd);
            continue;
        }

        ConnArg *ca = xmalloc(sizeof(*ca));
        ca->fd = client_fd;
        ca->server = eigs_http_active;
        pthread_t tid;
        __atomic_add_fetch(&g_conn_count, 1, __ATOMIC_RELAXED);
        if (pthread_create(&tid, &worker_attr, http_conn_thread, ca) != 0) {
            __atomic_sub_fetch(&g_conn_count, 1, __ATOMIC_RELAXED);
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
        free(g_server.cors_origin);
        g_server.cors_origin = NULL;
        return make_str("cors disabled");
    }
    if (arg->type != VAL_STR) return make_null();
    free(g_server.cors_origin);
    /* Strip CR/LF to prevent header injection */
    const char *raw = arg->data.str;
    size_t len = strlen(raw);
    char *clean = xmalloc(len + 1);
    size_t j = 0;
    for (size_t i = 0; i < len; i++) {
        if (raw[i] != '\r' && raw[i] != '\n')
            clean[j++] = raw[i];
    }
    clean[j] = '\0';
    g_server.cors_origin = clean;
    return make_str(clean);
}

/* Per-request builtins only: read the current request's body / session /
 * headers, send an outbound http_post, and the shared-store API used to
 * communicate across worker code routes. No Server allocation, no
 * eigs_http_active wiring. Safe to call on a fresh worker state. */
void register_http_request_builtins(Env *env) {
    env_set_local_owned(env, "http_request_body", make_builtin(builtin_http_request_body));
    env_set_local_owned(env, "http_session_id", make_builtin(builtin_http_session_id));
    env_set_local_owned(env, "http_post", make_builtin(builtin_http_post));
    env_set_local_owned(env, "http_request_headers", make_builtin(builtin_http_request_headers));
    env_set_local_owned(env, "shared_set", make_builtin(builtin_shared_set));
    env_set_local_owned(env, "shared_get", make_builtin(builtin_shared_get));
    env_set_local_owned(env, "shared_has", make_builtin(builtin_shared_has));
    env_set_local_owned(env, "shared_delete", make_builtin(builtin_shared_delete));
    env_set_local_owned(env, "shared_keys", make_builtin(builtin_shared_keys));
    env_set_local_owned(env, "shared_size", make_builtin(builtin_shared_size));
    env_set_local_owned(env, "shared_clear", make_builtin(builtin_shared_clear));
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
    }
    eigs_http_active = st->ext_http_server;
    g_server.global_env = env;

    env_set_local_owned(env, "http_route", make_builtin(builtin_http_route));
    env_set_local_owned(env, "http_route_authed", make_builtin(builtin_http_route_authed));
    env_set_local_owned(env, "http_static", make_builtin(builtin_http_static));
    env_set_local_owned(env, "http_early_bind", make_builtin(builtin_http_early_bind));
    env_set_local_owned(env, "http_serve", make_builtin(builtin_http_serve));
    env_set_local_owned(env, "http_cors", make_builtin(builtin_http_cors));
    register_http_request_builtins(env);
}

void ext_http_state_destroy(EigsState *st) {
    if (!st) return;
    Server *s = st->ext_http_server;
    if (!s) return;
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
     * before this runs. early_bind_fd is the listening socket; closed by
     * http_serve_blocking on shutdown (or process exit). */
    free(s);
    st->ext_http_server = NULL;
    /* Clear the main thread's active pointer if it pointed here. Worker
     * threads die before the state does (http_serve returns or process
     * exits), so theirs is already gone. */
    if (eigs_http_active == s) eigs_http_active = NULL;
}
