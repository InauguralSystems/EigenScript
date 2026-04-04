/*
 * EigenScript Database Extension — private header.
 * Only included by ext_db.c.
 */

#ifndef EXT_DB_INTERNAL_H
#define EXT_DB_INTERNAL_H

#include "eigenscript.h"
#include <libpq-fe.h>

extern PGconn *g_db_conn;

void register_db_builtins(Env *env);

#endif
