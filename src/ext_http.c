/*
 * EigenScript HTTP Extension
 * HTTP server, route registration, request handling.
 * Compiled only when EIGENSCRIPT_EXT_HTTP=1.
 */

#include "ext_http_internal.h"
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* ================================================================
 * HTTP GLOBALS
 * ================================================================ */

Server g_server = {0};
static volatile int g_init_complete = 0;
static pthread_t g_health_tid;
static int g_health_thread_active = 0;

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
            r->kind = strdup("static");
            r->payload = strdup(handler->data.str);
        } else {
            r->kind = strdup("static");
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
    if (g_server.request_body)
        return make_str(g_server.request_body);
    return make_str("{}");
}

Value* builtin_http_session_id(Value *arg) {
    (void)arg;
    if (g_server.session_id)
        return make_str(g_server.session_id);
    return make_str("anonymous");
}


Value* builtin_http_post(Value *arg) {
    /* http_post of [url, headers_json, body_string] -> response body string
     * Uses fork/execvp to invoke curl — no shell involved, no injection risk. */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_str("");
    const char *url = "", *headers_json = "", *body = "";
    if (arg->data.list.items[0]->type == VAL_STR) url = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) headers_json = arg->data.list.items[1]->data.str;
    if (arg->data.list.items[2]->type == VAL_STR) body = arg->data.list.items[2]->data.str;
    if (!url[0]) return make_str("");

    /* Write body to temp file */
    char req_path[] = "/tmp/eigen_http_XXXXXX";
    int req_fd = mkstemp(req_path);
    if (req_fd < 0) return make_str("");
    FILE *reqf = fdopen(req_fd, "w");
    if (!reqf) { close(req_fd); unlink(req_path); return make_str(""); }
    fprintf(reqf, "%s", body);
    fclose(reqf);

    /* Build argv array for curl — no shell interpolation */
    /* Max 64 args: curl -s --max-time 15 [-H "k: v"]... -d @file url */
    char *argv[64];
    int argc = 0;
    argv[argc++] = "curl";
    argv[argc++] = "-s";
    argv[argc++] = "--max-time";
    argv[argc++] = "15";

    /* Parse headers JSON and add -H flags */
    char header_bufs[32][256]; /* up to 32 headers */
    int hdr_count = 0;
    int jpos = 0;
    Value *hdr_obj = eigs_json_parse_value(headers_json, &jpos);
    if (hdr_obj && hdr_obj->type == VAL_LIST) {
        for (int i = 0; i + 1 < hdr_obj->data.list.count && hdr_count < 32 && argc < 60; i += 2) {
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
    argv[argc++] = (char *)url;
    argv[argc] = NULL;

    /* Fork and exec curl, capture stdout via pipe */
    int pipefd[2];
    if (pipe(pipefd) < 0) { unlink(req_path); return make_str(""); }

    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); unlink(req_path); return make_str(""); }

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

    return make_str(buf);
}

Value* builtin_http_request_headers(Value *arg) {
    (void)arg;
    if (g_server.request_headers)
        return make_str(g_server.request_headers);
    return make_str("");
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
    if (strcmp(ext, ".json") == 0) return "application/json; charset=utf-8";
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
    char header[MAX_HEADER];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %ld\r\n"
        "Cache-Control: no-cache\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        "Connection: close\r\n"
        "\r\n",
        status, status_text, content_type, body_len);

    if (write(fd, header, hlen) <= 0) return;
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
    char body[512];
    int blen = snprintf(body, sizeof(body),
        "{\"error\": \"not_found\", \"path\": \"%s\"}", path);
    send_response(fd, 404, "Not Found", "application/json", body, blen);
}

static void send_file(int fd, const char *filepath) {
    long size = 0;
    char *data = read_file_util(filepath, &size);
    if (!data) {
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
    send_response(fd, 200, "OK", get_content_type(filepath), data, size);
    free(data);
}

static void generate_session_id(char *buf, int len) {
    static int counter = 0;
    snprintf(buf, len, "sess_%lx_%d", (unsigned long)time(NULL), counter++);
}

static void handle_request(int fd) {
    char reqbuf[MAX_BODY + MAX_HEADER];
    int total = 0;
    int header_end = -1;

    while (total < (int)sizeof(reqbuf) - 1) {
        int n = read(fd, reqbuf + total, sizeof(reqbuf) - 1 - total);
        if (n <= 0) break;
        total += n;
        reqbuf[total] = '\0';

        char *hend = strstr(reqbuf, "\r\n\r\n");
        if (hend) {
            header_end = (int)(hend - reqbuf) + 4;

            char *cl = strcasestr(reqbuf, "Content-Length:");
            if (cl) {
                int content_length = atoi(cl + 15);
                int body_received = total - header_end;
                if (body_received >= content_length) break;
                if (content_length > MAX_BODY) break;
            } else {
                break;
            }
        }
    }

    if (total == 0) { close(fd); return; }
    reqbuf[total] = '\0';

    char method[16] = {0}, path[2048] = {0}, version[16] = {0};
    sscanf(reqbuf, "%15s %2047s %15s", method, path, version);

    char *body = NULL;
    if (header_end > 0 && header_end < total) {
        body = reqbuf + header_end;
    }

    if (strcmp(method, "OPTIONS") == 0) {
        send_response(fd, 200, "OK", "text/plain", "", 0);
        close(fd);
        return;
    }

    static char sess_id[64];
    generate_session_id(sess_id, sizeof(sess_id));
    g_server.session_id = sess_id;
    g_server.request_body = body ? body : "";
    g_server.request_headers = reqbuf;

    if (g_server.static_prefix && strncmp(path, g_server.static_prefix, strlen(g_server.static_prefix)) == 0) {
        char filepath[4096];
        const char *rel = path + strlen(g_server.static_prefix);
        if (rel[0] == '/') rel++;
        if (strstr(rel, "..") != NULL || rel[0] == '/') {
            send_response(fd, 403, "Forbidden", "text/plain", "Forbidden", 9);
            close(fd);
            return;
        }
        snprintf(filepath, sizeof(filepath), "%s/%s", g_server.static_dir, rel);
        send_file(fd, filepath);
        close(fd);
        return;
    }

    for (int i = 0; i < g_server.route_count; i++) {
        Route *r = &g_server.routes[i];
        if (strcmp(r->method, method) == 0 && strcmp(r->path, path) == 0) {
            if (strcmp(r->kind, "file") == 0) {
                send_file(fd, r->payload);
            } else if (strcmp(r->kind, "code") == 0) {
                /* Route-level auth: reject before running handler */
                if (r->requires_auth) {
                    Value *auth_fn = env_get(g_server.global_env, "require_auth");
                    if (!auth_fn || (auth_fn->type != VAL_FN && auth_fn->type != VAL_BUILTIN)) {
                        send_response(fd, 500, "Internal Server Error", "application/json",
                            "{\"error\": \"require_auth not defined or not callable\"}", 53);
                        close(fd);
                        return;
                    }
                    TokenList auth_tl = tokenize("require_auth of null");
                    ASTNode *auth_ast = parse(&auth_tl);
                    Value *auth_result = eval_node(auth_ast, g_server.global_env);
                    char *auth_str = value_to_string(auth_result);
                    if (auth_str[0] != '\0') {
                        send_response(fd, 401, "Unauthorized", "application/json",
                                      auth_str, strlen(auth_str));
                        free(auth_str);
                        close(fd);
                        return;
                    }
                    free(auth_str);
                }
                TokenList tl = tokenize(r->payload);
                ASTNode *ast = parse(&tl);
                Value *result = eval_node(ast, g_server.global_env);
                char *result_str = value_to_string(result);

                const char *ct = "application/json";
                if (result_str[0] != '{' && result_str[0] != '[')
                    ct = "text/plain";
                send_response(fd, 200, "OK", ct, result_str, strlen(result_str));
                free(result_str);
            } else {
                const char *ct = "application/json";
                if (r->payload[0] != '{' && r->payload[0] != '[')
                    ct = "text/plain";
                send_response(fd, 200, "OK", ct, r->payload, strlen(r->payload));
            }
            close(fd);
            return;
        }
    }

    send_404(fd, path);
    close(fd);
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

        handle_request(client_fd);
    }
}



/* ================================================================
 * HTTP BUILTIN REGISTRATION
 * ================================================================ */

void register_http_builtins(Env *env) {
    env_set_local(env, "http_route", make_builtin(builtin_http_route));
    env_set_local(env, "http_route_authed", make_builtin(builtin_http_route_authed));
    env_set_local(env, "http_static", make_builtin(builtin_http_static));
    env_set_local(env, "http_early_bind", make_builtin(builtin_http_early_bind));
    env_set_local(env, "http_serve", make_builtin(builtin_http_serve));
    env_set_local(env, "http_request_body", make_builtin(builtin_http_request_body));
    env_set_local(env, "http_session_id", make_builtin(builtin_http_session_id));
    env_set_local(env, "http_post", make_builtin(builtin_http_post));
    env_set_local(env, "http_request_headers", make_builtin(builtin_http_request_headers));
}
