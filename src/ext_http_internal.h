/*
 * EigenScript HTTP Extension — private header.
 * Only included by ext_http.c and main.c.
 */

#ifndef EXT_HTTP_INTERNAL_H
#define EXT_HTTP_INTERNAL_H

#include "eigenscript.h"
#include "ext_register.h"   /* register_http_builtins / ext_http_state_destroy (#744) */
#include "vm.h"
#include <pthread.h>

#define MAX_ROUTES 256
#define HTTP_RESPONSE_HEADER_MAX 16
#define HTTP_RESPONSE_NAME_MAX 64
#define HTTP_RESPONSE_VALUE_MAX 1024

typedef struct {
    char name[HTTP_RESPONSE_NAME_MAX + 1];
    char value[HTTP_RESPONSE_VALUE_MAX + 1];
} ResponseHeader;

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
    pthread_t init_tid;
    int init_thread_active;     /* owner thread only; joined before destruction */
    int init_stop;              /* atomic: owner writes, startup thread reads */
    char *liveness_path;        /* immutable while the startup thread runs */
    char *cors_origin;  /* NULL = no CORS headers, "*" = wildcard */
    pthread_mutex_t response_mu; /* headers/CORS can change during early bind */
    ResponseHeader response_headers[HTTP_RESPONSE_HEADER_MAX];
    int response_header_count;
    int response_header_rejected; /* sticky: catching an error cannot start server */
    int serving;                 /* response_mu guards config freeze */

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

/* Subset for worker states: registers only the read-the-current-request
 * builtins (request_body / session_id / request_headers / http_post).
 * Skips the server-config builtins and does NOT allocate a Server, so
 * pooled per-connection states stay cheap. */
void register_http_request_builtins(Env *env);
void http_serve_blocking(int port);

#endif
