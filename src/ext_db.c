/*
 * EigenScript Database Extension
 * PostgreSQL client — connect, query, execute.
 */

#include "ext_db_internal.h"
#include "ext_names.h"
#if EIGENSCRIPT_EXT_DB


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
        /* #888: the callers used to turn this into "[]"/"" — the same value a
         * successful empty query returns. A malformed call is a program bug
         * and must not look like a result. */
        rt_error(EK_TYPE, 0, "db: expected [sql, params...] with a string SQL first element");
        return 0;
    }

    *sql = arg->data.list.items[0]->data.str;
    *nparams = arg->data.list.count - 1;
    /* #356: raise instead of silently dropping params 17+ (Postgres would
     * error confusingly at exec time — or worse, not at all) or coercing
     * non-scalar params to "" (the #316 class). */
    if (*nparams > DB_MAX_PARAMS) {
        rt_error(EK_LIMIT, 0, "db: too many parameters (%d, max %d)",
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
            rt_error(EK_TYPE, 0, "db: parameter %d is not a string or number (got %s)",
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

/* ---- #888: failures raise, they do not return a plausible success value ----
 *
 * Every DB failure used to be laundered into the same value the success path
 * returns for "no rows" ("[]" / "") — so a typo'd query, a dropped table, a
 * revoked permission and a genuinely empty table were one indistinguishable
 * outcome, and a reporting script kept printing "0 rows" forever after a
 * schema change. LANGUAGE_CONTRACT.md:50-58 says programs never "report
 * success on failure"; every other I/O surface in the runtime honors that.
 *
 * Kind is EK_IO ("the outside world failed") for both the connection and the
 * statement. Not EK_VALUE: libpq reports a syntax error, a permission denial,
 * a missing relation and a reset connection through one channel, so claiming
 * the runtime knows the failure was a bad argument would be a guess. No new
 * `db` kind either — DIAGNOSTICS.md's closed set classifies by the NATURE of
 * the failure, not by which subsystem raised it. Callers discriminate on the
 * message, which carries libpq's own text. */
static void db_raise_stmt(PGresult *res, const char *what) {
    const char *msg = NULL;
    if (res) msg = PQresultErrorMessage(res);
    if ((!msg || !msg[0]) && g_db_conn) msg = PQerrorMessage(g_db_conn);
    if (!msg) msg = "";
    /* libpq messages are multi-line ("ERROR: ...\nLINE 1: ...\n   ^\n"); the
     * first line carries the diagnosis and a caught error's `message` must
     * stay one line. */
    char buf[512];
    size_t n = 0;
    while (msg[n] && msg[n] != '\n' && n + 1 < sizeof(buf)) { buf[n] = msg[n]; n++; }
    while (n > 0 && (buf[n - 1] == ' ' || buf[n - 1] == '\r')) n--;
    buf[n] = '\0';
    rt_error(EK_IO, 0, "db: %s failed: %s", what, n ? buf : "no message from server");
}

/* Returns 0 (already raised) when there is no usable connection. */
static int db_require_conn(void) {
    if (g_db_conn && PQstatus(g_db_conn) == CONNECTION_OK) return 1;
    rt_error(EK_IO, 0, "db: not connected — call db_connect first%s",
             g_db_conn ? " (connection is bad)" : "");
    return 0;
}

/* ---- #887: SQL types survive the trip into EigenScript ----
 *
 * Every column used to be emitted with eigs_json_escape_string, i.e. as a
 * JSON string, because that is what libpq's text mode hands back. Three
 * silent consequences: SQL false arrived as "f" and "f" is a non-empty
 * string, so it is TRUTHY and `if row.is_admin:` passed for a non-admin;
 * NULL arrived as "" and was indistinguishable from an empty string; and
 * numbers compared lexicographically ('9' > '10').
 *
 * PostgreSQL type OIDs are pinned by the wire protocol and stable across
 * every server version, so they are spelled here rather than pulling in
 * server-side catalog headers that libpq does not ship. */
#define DB_OID_BOOL     16
#define DB_OID_INT8     20
#define DB_OID_INT2     21
#define DB_OID_INT4     23
#define DB_OID_OID      26
#define DB_OID_FLOAT4  700
#define DB_OID_FLOAT8  701
#define DB_OID_NUMERIC 1700

/* The largest integer a double represents exactly. A bigint past this cannot
 * round-trip through an EigenScript number. */
#define DB_EXACT_INT_MAX 9007199254740992LL

typedef enum { DBT_STR, DBT_NUM, DBT_BOOL } DbColType;

/* ONE classifier, shared by db_query_json and db_query_value, so the two
 * cannot drift on what a column's type is.
 *
 * The mapping is a function of the column's SQL type ALONE and never of the
 * row's value: a column that decodes as a number for row 1 and a string for
 * row 100 is a landmine (`row.n + 1` works until it doesn't), so "emit a
 * number when this particular value happens to fit" is deliberately not what
 * this does.
 *
 * NUMERIC stays a string on purpose. It is PostgreSQL's arbitrary-precision
 * decimal — the money type — and converting it to a binary double is lossy
 * by construction (0.1 is not a double; numeric(38,10) is not a double).
 * Silently rounding money is the exact defect class this issue is about, so
 * the digits are preserved and `SELECT amount::float8` is the one-token opt
 * in to a number. int8 does NOT get that treatment: count(*), sum(int) and
 * every serial key are int8, so leaving it a string would leave the filed
 * bug unfixed for the majority of real numeric queries — instead it emits a
 * number and RAISES on the values a double cannot represent (below). */
static DbColType db_classify(unsigned int oid) {
    switch (oid) {
        case DB_OID_BOOL:   return DBT_BOOL;
        case DB_OID_INT2:
        case DB_OID_INT4:
        case DB_OID_OID:
        case DB_OID_INT8:
        case DB_OID_FLOAT4:
        case DB_OID_FLOAT8: return DBT_NUM;
        default:            return DBT_STR;   /* numeric, text, date, json, ... */
    }
}

/* An exact-integer column whose value is past 2^53. Raising beats rounding:
 * the value genuinely has no representation as an EigenScript number, and a
 * silently rounded primary key is unrecoverable downstream. The message names
 * the column and the fix. Returns 0 and raises; 1 when representable. */
static int db_check_exact_int(unsigned int oid, const char *text, const char *colname) {
    if (oid != DB_OID_INT8 && oid != DB_OID_INT4 && oid != DB_OID_INT2 && oid != DB_OID_OID)
        return 1;
    /* strtoLL, not strtod: converting to a double FIRST rounds 9007199254740993
     * to exactly 2^53, so a strtod-based comparison cannot see the one thing
     * this check exists to detect. (It shipped that way to CI once — the live
     * postgres job is what caught it.) An out-of-int64 literal saturates at
     * LLONG_MAX, which is past the bound, so it still raises. */
    char *end = NULL;
    long long v = strtoll(text, &end, 10);
    if (end == text) return 1;            /* not a plain integer literal; leave it */
    if (v > DB_EXACT_INT_MAX || v < -DB_EXACT_INT_MAX) {
        rt_error(EK_VALUE, 0,
                 "db: column '%s' value %s exceeds the exact-integer range of a "
                 "number (2^53); select it as text (%s::text) to keep the digits",
                 colname ? colname : "?", text, colname ? colname : "col");
        return 0;
    }
    return 1;
}

/* Emit one column value as JSON. Returns 0 when it raised. */
static int db_emit_json_value(strbuf *sb, unsigned int oid, int isnull,
                              const char *text, const char *colname) {
    if (isnull) { strbuf_append(sb, "null"); return 1; }
    if (!text) text = "";
    switch (db_classify(oid)) {
        case DBT_BOOL:
            /* libpq text mode renders bool as exactly "t" or "f". */
            strbuf_append(sb, text[0] == 't' ? "true" : "false");
            return 1;
        case DBT_NUM:
            if (!db_check_exact_int(oid, text, colname)) return 0;
            /* float8/float4 can be NaN / Infinity / -Infinity, which JSON has
             * no literal for. Emitting them as `null` would collide with SQL
             * NULL — the very confusion this issue removes — so they stay
             * quoted: a caller doing arithmetic gets a loud type error rather
             * than a value that is silently the wrong thing. */
            if (text[0] == 'N' || text[0] == 'I' ||
                (text[0] == '-' && text[1] == 'I')) {
                eigs_json_escape_string(sb, text);
                return 1;
            }
            strbuf_append(sb, text);   /* libpq's decimal text is valid JSON */
            return 1;
        case DBT_STR:
            break;
    }
    eigs_json_escape_string(sb, text);
    return 1;
}

/* ---- DB query builtins ---- */
Value* builtin_db_query_value(Value *arg) {
    /* Run a SQL query and return row 0 col 0, typed by its SQL type (#887).
     * Usage: db_query_value of "SELECT COUNT(*) FROM table"
     *    or: db_query_value of ["SELECT name FROM t WHERE id=$1", id]
     * Returns null for SQL NULL and "" for no rows; raises on failure (#888). */
    if (!arg || (arg->type != VAL_STR && arg->type != VAL_LIST)) {
        rt_error(EK_TYPE, 0, "db_query_value expects a string or [sql, params...] (got %s)",
                 arg ? val_type_name(arg->type) : "null");
        return make_str("");  /* fs:STRICT the rt_error above is unconditional (not g_strict-gated), so the error latch is already armed and the VM raises; "" is the never-consumed soft value */
    }
    if (!db_require_conn()) return make_str("");  /* fs:STRICT db_require_conn raised EK_IO before returning 0 (ext_db.c:132) */
    PGresult *res = db_exec_from_arg(arg);
    if (!res) return make_str("");           /* db_build_query already raised */  /* fs:STRICT db_build_query already raised (ext_db.c:61 path); the latch is armed */
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        db_raise_stmt(res, "query");
        PQclear(res);
        return make_str("");  /* fs:STRICT db_raise_stmt raised EK_IO on the line above (ext_db.c:126) */
    }
    if (PQntuples(res) == 0 || PQnfields(res) == 0) { PQclear(res); return make_str(""); }  /* fs:ANSWER the header comment (line 256) documents "" for no rows; zero tuples/fields is a successful query with nothing to hand back, and nothing raised */
    /* NULL is not "" — the two used to be the same value here, so a caller
     * could not tell "no value" from "empty value" for any column type. */
    if (PQgetisnull(res, 0, 0)) { PQclear(res); return make_null(); }

    unsigned int oid = (unsigned int)PQftype(res, 0);
    const char *text = PQgetvalue(res, 0, 0);
    const char *colname = PQfname(res, 0);
    if (!text) text = "";
    Value *result = NULL;
    switch (db_classify(oid)) {
        case DBT_BOOL:
            result = make_num(text[0] == 't' ? 1 : 0);
            break;
        case DBT_NUM:
            if (!db_check_exact_int(oid, text, colname)) { PQclear(res); return make_str(""); }  /* fs:STRICT db_check_exact_int raised EK_VALUE for a past-2^53 integer (ext_db.c:211) */
            /* Same rule as the JSON emitter: float4/float8 can be NaN /
             * Infinity / -Infinity, and make_num's num_guard would turn
             * those into 0 and 1e308 — a silently wrong number. Hand back
             * the text so the caller sees what the column holds. */
            if (text[0] == 'N' || text[0] == 'I' ||
                (text[0] == '-' && text[1] == 'I')) {
                result = make_str(text);
                break;
            }
            result = make_num(strtod(text, NULL));
            break;
        case DBT_STR:
            result = make_str(text);
            break;
    }
    PQclear(res);
    return result;
}

Value* builtin_db_execute(Value *arg) {
    /* Run a SQL command with optional params. Returns "ok"; raises on failure.
     * Usage: db_execute of "INSERT INTO ..." (no params)
     *    or: db_execute of ["INSERT INTO t (a) VALUES ($1)", param1] */
    if (!arg || (arg->type != VAL_STR && arg->type != VAL_LIST)) {
        rt_error(EK_TYPE, 0, "db_execute expects a string or [sql, params...] (got %s)",
                 arg ? val_type_name(arg->type) : "null");
        return make_str("error");
    }
    if (!db_require_conn()) return make_str("error");
    PGresult *res = db_exec_from_arg(arg);
    if (!res) return make_str("error");      /* db_build_query already raised */

    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK || PQresultStatus(res) == PGRES_TUPLES_OK);
    if (!ok) db_raise_stmt(res, "execute");
    PQclear(res);
    return make_str(ok ? "ok" : "error");
}

Value* builtin_db_query_json(Value *arg) {
    /* Run SQL and return all rows as a JSON array of objects, each value
     * carrying its SQL type (#887).
     * Usage: db_query_json of "SELECT id, name FROM table"
     *    or: db_query_json of ["SELECT id, name FROM table WHERE id=$1", id]
     * Returns "[]" for a genuinely empty result; raises on failure (#888). */
    if (!arg || (arg->type != VAL_STR && arg->type != VAL_LIST)) {
        rt_error(EK_TYPE, 0, "db_query_json expects a string or [sql, params...] (got %s)",
                 arg ? val_type_name(arg->type) : "null");
        return make_str("[]");
    }
    if (!db_require_conn()) return make_str("[]");
    PGresult *res = db_exec_from_arg(arg);
    if (!res) return make_str("[]");         /* db_build_query already raised */
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        db_raise_stmt(res, "query");
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
            if (!db_emit_json_value(&sb, (unsigned int)PQftype(res, c),
                                    PQgetisnull(res, r, c), PQgetvalue(res, r, c),
                                    PQfname(res, c))) {
                strbuf_free(&sb);
                PQclear(res);
                return make_str("[]");
            }
        }
        strbuf_append_char(&sb, '}');
    }
    strbuf_append_char(&sb, ']');

    PQclear(res);
    Value *result = make_str(sb.data);
    strbuf_free(&sb);
    return result;
}

/* #739: close this state's connection at teardown. Nothing closed it before,
 * so every state that ever called db_connect leaked its PGconn. */
void ext_db_state_destroy(EigsState *st) {
    if (!st || !st->ext_db_conn) return;
    PQfinish((PGconn *)st->ext_db_conn);
    st->ext_db_conn = NULL;
}

void register_db_builtins(Env *env) {
    /* Expanded from ext_names.h — the shared name list the linter's E003
     * binding base also expands, so registration and name-resolution
     * cannot drift. Add a builtin there, not here. */
#define X(name, fn) env_set_local_owned(env, #name, make_builtin(fn));
    EIGS_DB_BUILTINS(X)
#undef X
}

#endif /* EIGENSCRIPT_EXT_DB */
