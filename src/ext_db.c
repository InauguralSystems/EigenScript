/*
 * EigenScript Database Extension
 * PostgreSQL client — connect, query, execute.
 */

#include "ext_db_internal.h"
#if EIGENSCRIPT_EXT_DB

PGconn *g_db_conn = NULL;

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
        char buf[1024];
        snprintf(buf, sizeof(buf), "{\"status\": \"error\", \"error\": \"%s\"}", PQerrorMessage(g_db_conn));
        PQfinish(g_db_conn);
        g_db_conn = NULL;
        return make_str(buf);
    }

    return make_str("{\"status\": \"connected\", \"driver\": \"libpq\"}");
}

/* ---- DB query builtins ---- */
Value* builtin_db_query_value(Value *arg) {
    /* Run a SQL query and return the value from row 0 col 0 as a string.
     * Usage: db_query_value of "SELECT COUNT(*) FROM table"
     * Returns "" if no DB, query fails, or no rows. */
    if (!arg || arg->type != VAL_STR) return make_str("");
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("");
    PGresult *res = PQexec(g_db_conn, arg->data.str);
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
    PGresult *res = NULL;

    if (arg && arg->type == VAL_STR) {
        res = PQexec(g_db_conn, arg->data.str);
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        const char *sql = "";
        if (arg->data.list.items[0]->type == VAL_STR) sql = arg->data.list.items[0]->data.str;
        int nparams = arg->data.list.count - 1;
        if (nparams == 0) {
            res = PQexec(g_db_conn, sql);
        } else {
            const char *params[16];
            char numbuf[16][64];
            if (nparams > 16) nparams = 16;
            for (int i = 0; i < nparams; i++) {
                Value *v = arg->data.list.items[i + 1];
                if (v->type == VAL_STR) {
                    params[i] = v->data.str;
                } else if (v->type == VAL_NUM) {
                    snprintf(numbuf[i], sizeof(numbuf[i]), "%g", v->data.num);
                    params[i] = numbuf[i];
                } else {
                    params[i] = "";
                }
            }
            res = PQexecParams(g_db_conn, sql, nparams, NULL, params, NULL, NULL, 0);
        }
    } else {
        return make_str("error");
    }

    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK || PQresultStatus(res) == PGRES_TUPLES_OK);
    PQclear(res);
    return make_str(ok ? "ok" : "error");
}

Value* builtin_db_query_json(Value *arg) {
    /* Run SQL and return all rows as a JSON array of objects.
     * Usage: db_query_json of "SELECT id, name FROM table"
     * Returns "[]" if no DB, error, or no rows. */
    if (!arg || arg->type != VAL_STR) return make_str("[]");
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("[]");
    PGresult *res = PQexec(g_db_conn, arg->data.str);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        PQclear(res);
        return make_str("[]");
    }
    int nrows = PQntuples(res);
    int ncols = PQnfields(res);
    if (nrows == 0 || ncols == 0) { PQclear(res); return make_str("[]"); }

    int buf_size = nrows * ncols * 256 + 256;
    if (buf_size > 1048576) buf_size = 1048576;
    char *buf = xcalloc(buf_size, 1);
    int pos = 0;
    pos += snprintf(buf + pos, buf_size - pos, "[");
    for (int r = 0; r < nrows && pos < buf_size - 512; r++) {
        if (r > 0) pos += snprintf(buf + pos, buf_size - pos, ", ");
        pos += snprintf(buf + pos, buf_size - pos, "{");
        for (int c = 0; c < ncols && pos < buf_size - 256; c++) {
            if (c > 0) pos += snprintf(buf + pos, buf_size - pos, ", ");
            const char *colname = PQfname(res, c);
            const char *val = PQgetvalue(res, r, c);
            /* Escape value for JSON */
            char escaped[512];
            int ei = 0;
            for (int i = 0; val[i] && ei < 500; i++) {
                if (val[i] == '"') { escaped[ei++] = '\\'; escaped[ei++] = '"'; }
                else if (val[i] == '\\') { escaped[ei++] = '\\'; escaped[ei++] = '\\'; }
                else if (val[i] == '\n') { escaped[ei++] = '\\'; escaped[ei++] = 'n'; }
                else escaped[ei++] = val[i];
            }
            escaped[ei] = '\0';
            pos += snprintf(buf + pos, buf_size - pos, "\"%s\": \"%s\"", colname, escaped);
        }
        pos += snprintf(buf + pos, buf_size - pos, "}");
    }
    pos += snprintf(buf + pos, buf_size - pos, "]");

    PQclear(res);
    Value *result = make_str(buf);
    free(buf);
    return result;
}

void register_db_builtins(Env *env) {
    env_set_local(env, "db_connect", make_builtin(builtin_db_connect));
    env_set_local(env, "db_query_value", make_builtin(builtin_db_query_value));
    env_set_local(env, "db_execute", make_builtin(builtin_db_execute));
    env_set_local(env, "db_query_json", make_builtin(builtin_db_query_json));
}

#endif /* EIGENSCRIPT_EXT_DB */
