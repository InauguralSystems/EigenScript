/* #1060: a NATIVE function registered with a name has the observable
 * identity of a user function -- `type of` answers "fn", printing and
 * `str of` show `<fn NAME>` -- while a plain builtin keeps "builtin" /
 * `<builtin>`. C-level because only a linked runtime (the AOT, which
 * compiles user functions to C and boxes them for value use) can make one;
 * the VM itself never does. Build: `make nativefn-test`. */
#include <stdio.h>
#include <string.h>
#include "eigs_embed.h"
#include "eigenscript.h"

static int fail = 0;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) fail = 1;
}
static Value *probe_add1(Value *a) {
    double d = (a && a->type == VAL_NUM) ? a->data.num : 0.0;
    return make_num(d + 1);
}
static Value *probe_plain(Value *a) { (void)a; return make_num(0); }

static char *eval_str(const char *src) {
    Value *v = eigs_eval_string(src);
    char *s = v ? value_to_string(v) : xstrdup("<null>");
    if (v) val_decref(v);
    return s;
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) { printf("FAIL: eigs_open\n"); return 1; }
    eigs_set_global("g", make_native_fn(probe_add1, "g"));
    eigs_set_global("b", make_builtin(probe_plain));

    char *s;
    s = eval_str("type of g");
    check(strcmp(s, "fn") == 0, "type of a named native fn is \"fn\""); free(s);
    s = eval_str("str of g");
    check(strcmp(s, "<fn g>") == 0, "str of a named native fn is <fn g>"); free(s);
    s = eval_str("g of 41");
    check(strcmp(s, "42") == 0, "a named native fn still calls through (g of 41 = 42)"); free(s);
    s = eval_str("type of b");
    check(strcmp(s, "builtin") == 0, "a plain builtin still reports \"builtin\""); free(s);
    s = eval_str("str of b");
    check(strcmp(s, "<builtin>") == 0, "a plain builtin still prints <builtin>"); free(s);
    check(strcmp(eigs_native_fn_name(probe_add1), "g") == 0, "the registry answers the name by pointer");
    check(eigs_native_fn_name(probe_plain) == NULL, "an unregistered pointer has no name");
    {
        Value *ng = make_native_fn(probe_add1, "g");
        Value *pb = make_builtin(probe_plain);
        check(compute_entropy(ng) == 1.0, "a named native fn has VAL_FN's entropy (1.0, ouroboros#193)");
        check(compute_entropy(pb) == 0.0, "a plain builtin keeps entropy 0.0");
        val_decref(ng); val_decref(pb);
    }
    Value *again = make_native_fn(probe_add1, "g_again");
    check(strcmp(eigs_native_fn_name(probe_add1), "g") == 0, "re-registering a pointer keeps the first name");
    val_decref(again);
    eigs_close(st);
    return fail;
}
