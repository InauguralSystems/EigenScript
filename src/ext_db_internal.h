/*
 * EigenScript Database Extension — private header.
 * Only included by ext_db.c.
 */

#ifndef EXT_DB_INTERNAL_H
#define EXT_DB_INTERNAL_H

#include "eigenscript.h"
#include "ext_register.h"   /* register_db_builtins / ext_db_state_destroy (#744) */
#include <libpq-fe.h>

/* #739: per-STATE connection, reached through the attached thread — the same
 * shape ext_http's per-state Server uses. Defined here rather than in
 * eigenscript.h so libpq's types stay out of the core header. */
#define g_db_conn (*(PGconn **)&eigs_current->state->ext_db_conn)

#endif
