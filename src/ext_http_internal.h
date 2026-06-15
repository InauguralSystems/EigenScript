/*
 * EigenScript HTTP Extension — private header.
 * Only included by ext_http.c and main.c.
 */

#ifndef EXT_HTTP_INTERNAL_H
#define EXT_HTTP_INTERNAL_H

#include "eigenscript.h"
#include "vm.h"
#include <pthread.h>

#define MAX_ROUTES 256

typedef struct {
    char *method;
    char *path;
    char *kind;
    char *payload;
    int requires_auth;
} Route;

/* Shared-store entry: JSON-encoded value keyed by string. Storage is
 * heap-owned so it outlives any worker EigsState. */
typedef struct {
    char *key;
    char *json;
} SharedEntry;

struct EigsHttpServer {
    Route routes[MAX_ROUTES];
    int route_count;
    char *static_prefix;
    char *static_dir;
    Env *global_env;
    int early_bind_fd;
    char *cors_origin;  /* NULL = no CORS headers, "*" = wildcard */

    /* Cross-worker shared store: pthread_mutex-guarded JSON map. Read
     * and written by code routes via shared_set/get/has/delete/keys/
     * size/clear. Lives on the *main* Server; workers reach it through
     * eigs_http_active. */
    SharedEntry *shared;
    int shared_count;
    int shared_cap;
    long shared_bytes;          /* running sum of key + json string lengths */
    pthread_mutex_t shared_mu;
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
/* Subset for worker states: registers only the read-the-current-request
 * builtins (request_body / session_id / request_headers / http_post).
 * Skips the server-config builtins and does NOT allocate a Server, so
 * pooled per-connection states stay cheap. */
void register_http_request_builtins(Env *env);
void http_serve_blocking(int port);
/* Called from eigs_state_destroy. Frees route allocations + the Server
 * struct itself and nils state->ext_http_server. No-op when the state
 * never had a Server (script never imported http). */
void ext_http_state_destroy(EigsState *st);

#endif
