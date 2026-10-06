/* #1637: db parameter binding, without a PostgreSQL server. Includes
 * src/ext_db.c so the static db_build_query is the function under test, and
 * links the server-db variant's other objects. A bool parameter must bind as
 * SQL boolean text with the boolean type OID; strings and numbers keep the
 * server-inferred type (OID 0); an unsupported type still raises. */
#include "../src/ext_db.c"
#include "eigs_embed.h"
#include <stdio.h>
#include <string.h>

static int passed, failed;
static void check(int ok, const char *name) {
    if (ok) passed++; else failed++;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) return 2;
    Value *arg = make_list(5);
    list_append_owned(arg, make_str("update t set a = $1, b = $2, c = $3, d = $4"));
    list_append(arg, make_bool(1));
    list_append_owned(arg, make_num(3));
    list_append_owned(arg, make_str("s"));
    list_append(arg, make_bool(0));
    const char *sql = NULL; const char *params[DB_MAX_PARAMS];
    char numbuf[DB_MAX_PARAMS][64]; unsigned int types[DB_MAX_PARAMS];
    int n = -1;
    int ok = db_build_query(arg, &sql, &n, params, numbuf, types);
    check(ok && n == 4, "four parameters built");
    check(ok && strcmp(params[0], "true") == 0 && types[0] == 16, "true binds as SQL boolean 'true' (OID 16)");
    check(ok && strcmp(params[1], "3") == 0 && types[1] == 0, "a number keeps the inferred type");
    check(ok && strcmp(params[2], "s") == 0 && types[2] == 0, "a string keeps the inferred type");
    check(ok && strcmp(params[3], "false") == 0 && types[3] == 16, "false binds as SQL boolean 'false' (OID 16)");
    check(DB_PARAM_OID_BOOL == DB_OID_BOOL, "the parameter OID is the column classifier's boolean OID");
    val_decref(arg);
    Value *bad = make_list(2);
    list_append_owned(bad, make_str("select $1"));
    list_append_owned(bad, make_dict(1));
    check(!db_build_query(bad, &sql, &n, params, numbuf, types) && eigs_has_error(),
          "a dict parameter still raises");
    eigs_clear_error();
    val_decref(bad);
    eigs_close(st);
    printf("db params: %d passed, %d failed (7 declared)\n", passed, failed);
    return failed || passed != 7;
}
