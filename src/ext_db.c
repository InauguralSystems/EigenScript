/*
 * EigenScript Database Extension
 * PostgreSQL client — connect, query, execute.
 */

#include "ext_db_internal.h"
#if EIGENSCRIPT_EXT_DB

PGconn *g_db_conn = NULL;

#define DB_MAX_PARAMS 16

static int db_build_query(Value *arg, const char **sql, int *nparams,
                          const char **params, char numbuf[DB_MAX_PARAMS][64]) {
    if (arg && arg->type == VAL_STR) {
        *sql = arg->data.str;
        *nparams = 0;
        return 1;
    }
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 1 ||
        arg->data.list.items[0]->type != VAL_STR) {
        return 0;
    }

    *sql = arg->data.list.items[0]->data.str;
    *nparams = arg->data.list.count - 1;
    /* #356: raise instead of silently dropping params 17+ (Postgres would
     * error confusingly at exec time — or worse, not at all) or coercing
     * non-scalar params to "" (the #316 class). */
    if (*nparams > DB_MAX_PARAMS) {
        runtime_error(0, "db: too many parameters (%d, max %d)",
                      *nparams, DB_MAX_PARAMS);
        return 0;
    }
    for (int i = 0; i < *nparams; i++) {
        Value *v = arg->data.list.items[i + 1];
        if (v && v->type == VAL_STR) {
            params[i] = v->data.str;
        } else if (v && v->type == VAL_NUM) {
            snprintf(numbuf[i], 64, "%g", v->data.num);
            params[i] = numbuf[i];
        } else {
            runtime_error(0, "db: parameter %d is not a string or number (got %s)",
                          i + 1, v ? val_type_name(v->type) : "null");
            return 0;
        }
    }
    return 1;
}

static PGresult* db_exec_from_arg(Value *arg) {
    const char *sql = "";
    const char *params[DB_MAX_PARAMS];
    char numbuf[DB_MAX_PARAMS][64];
    int nparams = 0;

    if (!db_build_query(arg, &sql, &nparams, params, numbuf)) return NULL;
    if (nparams == 0) return PQexec(g_db_conn, sql);
    return PQexecParams(g_db_conn, sql, nparams, NULL, params, NULL, NULL, 0);
}

Value* builtin_db_connect(Value *arg) {
    (void)arg;
    const char *url = getenv("DATABASE_URL");
    if (!url || !url[0]) {
        return make_str("{\"status\": \"no_database\", \"message\": \"DATABASE_URL not set\"}");
    }

    char conn_str[4096];
    if (strchr(url, '?')) {
        snprintf(conn_str, sizeof(conn_str), "%s&connect_timeout=3", url);
    } else {
        snprintf(conn_str, sizeof(conn_str), "%s?connect_timeout=3", url);
    }
    g_db_conn = PQconnectdb(conn_str);

    if (PQstatus(g_db_conn) != CONNECTION_OK) {
        strbuf sb;
        strbuf_init(&sb);
        strbuf_append(&sb, "{\"status\": \"error\", \"error\": ");
        eigs_json_escape_string(&sb, PQerrorMessage(g_db_conn));
        strbuf_append_char(&sb, '}');
        PQfinish(g_db_conn);
        g_db_conn = NULL;
        Value *result = make_str(sb.data);
        strbuf_free(&sb);
        return result;
    }

    return make_str("{\"status\": \"connected\", \"driver\": \"libpq\"}");
}

/* ---- DB query builtins ---- */
Value* builtin_db_query_value(Value *arg) {
    /* Run a SQL query and return the value from row 0 col 0 as a string.
     * Usage: db_query_value of "SELECT COUNT(*) FROM table"
     *    or: db_query_value of ["SELECT name FROM t WHERE id=$1", id]
     * Returns "" if no DB, query fails, or no rows. */
    if (!arg || (arg->type != VAL_STR && arg->type != VAL_LIST)) return make_str("");
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("");
    PGresult *res = db_exec_from_arg(arg);
    if (!res) return make_str("");
    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) == 0) {
        PQclear(res);
        return make_str("");
    }
    const char *val = PQgetvalue(res, 0, 0);
    Value *result = make_str(val ? val : "");
    PQclear(res);
    return result;
}

Value* builtin_db_execute(Value *arg) {
    /* Run a SQL command with optional params. Returns "ok" or "error".
     * Usage: db_execute of "INSERT INTO ..." (no params)
     *    or: db_execute of ["INSERT INTO t (a) VALUES ($1)", param1] */
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("no_db");
    PGresult *res = db_exec_from_arg(arg);
    if (!res) return make_str("error");

    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK || PQresultStatus(res) == PGRES_TUPLES_OK);
    PQclear(res);
    return make_str(ok ? "ok" : "error");
}

Value* builtin_db_query_json(Value *arg) {
    /* Run SQL and return all rows as a JSON array of objects.
     * Usage: db_query_json of "SELECT id, name FROM table"
     *    or: db_query_json of ["SELECT id, name FROM table WHERE id=$1", id]
     * Returns "[]" if no DB, error, or no rows. */
    if (!arg || (arg->type != VAL_STR && arg->type != VAL_LIST)) return make_str("[]");
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("[]");
    PGresult *res = db_exec_from_arg(arg);
    if (!res) return make_str("[]");
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        PQclear(res);
        return make_str("[]");
    }
    int nrows = PQntuples(res);
    int ncols = PQnfields(res);
    if (nrows == 0 || ncols == 0) { PQclear(res); return make_str("[]"); }

    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_char(&sb, '[');
    for (int r = 0; r < nrows; r++) {
        if (r > 0) strbuf_append(&sb, ", ");
        strbuf_append_char(&sb, '{');
        for (int c = 0; c < ncols; c++) {
            if (c > 0) strbuf_append(&sb, ", ");
            eigs_json_escape_string(&sb, PQfname(res, c));
            strbuf_append(&sb, ": ");
            eigs_json_escape_string(&sb, PQgetvalue(res, r, c));
        }
        strbuf_append_char(&sb, '}');
    }
    strbuf_append_char(&sb, ']');

    PQclear(res);
    Value *result = make_str(sb.data);
    strbuf_free(&sb);
    return result;
}

void register_db_builtins(Env *env) {
    env_set_local_owned(env, "db_connect", make_builtin(builtin_db_connect));
    env_set_local_owned(env, "db_query_value", make_builtin(builtin_db_query_value));
    env_set_local_owned(env, "db_execute", make_builtin(builtin_db_execute));
    env_set_local_owned(env, "db_query_json", make_builtin(builtin_db_query_json));
}

#endif /* EIGENSCRIPT_EXT_DB */
