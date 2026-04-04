/*
 * EigenScript HTTP Extension — private header.
 * Only included by ext_http.c and main.c.
 */

#ifndef EXT_HTTP_INTERNAL_H
#define EXT_HTTP_INTERNAL_H

#include "eigenscript.h"

#define MAX_ROUTES 256

typedef struct {
    char *method;
    char *path;
    char *kind;
    char *payload;
    int requires_auth;
} Route;

typedef struct {
    Route routes[MAX_ROUTES];
    int route_count;
    char *static_prefix;
    char *static_dir;
    Env *global_env;
    char *request_body;
    char *session_id;
    char *request_headers;
    int early_bind_fd;
} Server;

extern Server g_server;

void register_http_builtins(Env *env);
void http_serve_blocking(int port);

#endif
