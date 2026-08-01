/*
 * EigenScript Network Extension — private header.
 * Included by ext_net.c, and by builtins.c (under EIGENSCRIPT_EXT_NET)
 * for the handle_table_drain teardown pass. Deliberately free of socket
 * headers: the drain pass only needs the fd.
 */

#ifndef EXT_NET_INTERNAL_H
#define EXT_NET_INTERNAL_H

#include "eigenscript.h"

/* One row per live socket, owned by the process handle table
 * (HANDLE_NET). Listeners and connections share the struct; `kind`
 * keeps net_accept off a connection and net_recv/net_send off a
 * listener. */
typedef enum { NET_SOCK_LISTENER, NET_SOCK_CONN } EigsNetSockKind;

typedef struct {
    int             fd;
    EigsNetSockKind kind;
} EigsNetSock;

void register_net_builtins(Env *env);

#endif
