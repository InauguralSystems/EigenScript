/*
 * EigenScript Database Extension — private header.
 * Only included by ext_db.c.
 */

#ifndef EXT_DB_INTERNAL_H
#define EXT_DB_INTERNAL_H

#include "eigenscript.h"
#include <libpq-fe.h>

/* #739: per-STATE connection, reached through the attached thread — the same
 * shape ext_http's per-state Server uses. Defined here rather than in
 * eigenscript.h so libpq's types stay out of the core header. */
#define g_db_conn (*(PGconn **)&eigs_current->state->ext_db_conn)

void register_db_builtins(Env *env);

/* Closes this state's connection; called from eigs_state_destroy. */
void ext_db_state_destroy(EigsState *st);

#endif
