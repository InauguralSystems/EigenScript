/*
 * EigenScript HTTP Extension — private header.
 * Only included by ext_http.c and main.c.
 */

#ifndef EXT_HTTP_INTERNAL_H
#define EXT_HTTP_INTERNAL_H

#include "eigenscript.h"
#include "vm.h"

#define MAX_ROUTES 256

typedef struct {
    char *method;
    char *path;
    char *kind;
    char *payload;
    int requires_auth;
} Route;

struct EigsHttpServer {
    Route routes[MAX_ROUTES];
    int route_count;
    char *static_prefix;
    char *static_dir;
    Env *global_env;
    int early_bind_fd;
    char *cors_origin;  /* NULL = no CORS headers, "*" = wildcard */
};
typedef struct EigsHttpServer Server;

/* Per-thread pointer at the active state's server. register_http_builtins
 * sets it on the main thread; http_conn_thread inherits the parent's
 * pointer via its ConnArg so worker threads (which don't attach to an
 * EigsThread) can still access route config without TLS bridge macros.
 * Two co-located states each get their own Server; their main threads
 * and worker pools see only their own. */
extern __thread Server *eigs_http_active;
#define g_server (*eigs_http_active)

void register_http_builtins(Env *env);
void http_serve_blocking(int port);
/* Called from eigs_state_destroy. Frees route allocations + the Server
 * struct itself and nils state->ext_http_server. No-op when the state
 * never had a Server (script never imported http). */
void ext_http_state_destroy(EigsState *st);

#endif
