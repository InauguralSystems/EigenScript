#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "eigs_embed.h"

typedef void (*Setter)(EigsState *, int);
typedef struct { const char *name, *src; int error; } Fourth;
static int failures, transitions, fourth_count;

static EigsState *new_state(int fine) {
    return fine ? eigs_state_new() : eigs_open();
}
static int probe(const char *src, int strict, int guard) {
    EigsValue *v = eigs_eval_string(src);
    int ok = v && !eigs_has_error();
    double n = ok ? eigs_value_as_num(v) : -9999;
    if (v) eigs_value_release(v);
    eigs_clear_error();
    return ok && (strict ? n == -777 : (guard ? n == 0 : isinf(n)));
}
static void transition(const char *name, int fine, int sg, int sa,
                       Setter setter, int enabled, int wg, int wa) {
    EigsState *st = new_state(fine);
    if (!st) { printf("FAIL: %s state creation\n", name); failures++; return; }
    eigs_state_set_strict(st, 0);
    eigs_state_set_strict_guards(st, sg);
    eigs_state_set_strict_arithmetic(st, sa);
    setter(st, enabled);
    if (fine && (!eigs_thread_attach(st) || eigs_state_init_runtime(st))) {
        printf("FAIL: %s runtime initialization\n", name); failures++;
        eigs_state_destroy(st); return;
    }
    int g = probe("try:\n    abs of \"x\"\ncatch e:\n    -777\n", wg, 1);
    int a = probe("try:\n    1.0 / 0.0\ncatch e:\n    -777\n", wa, 0);
    transitions++;
    if (g && a) printf("PASS: %s\n", name);
    else { printf("FAIL: %s want=%d,%d seen=%d,%d\n", name,wg,wa,g,a); failures++; }
    eigs_close(st);
}
static const Fourth fourth_cases[] = {
 {"abs-string","abs of \"x\"",0},{"floor-string","floor of \"x\"",0},
 {"ceil-string","ceil of \"x\"",0},{"round-string","round of \"x\"",0},
 {"sin-string","sin of \"x\"",0},{"cos-string","cos of \"x\"",0},
 {"sqrt-string","sqrt of \"x\"",0},{"tan-string","tan of \"x\"",0},
 {"num-invalid","num of \"abc\"",1},{"max-string","max of \"x\"",0},
 {"sqrt-negative","sqrt of -1",1},{"divide-zero","1.0 / 0.0",1},
 {"multiply-overflow","1e308 * 10.0",1},{"sum-overflow","sum of [1e308, 1e308]",1},
 {"norm-overflow","norm of [1e308, 1e308]",1},{"exp-overflow","exp of 1000",1},
 {"log-negative","log of -1",1},{"asin-domain","asin of 2",1},
 {"acos-domain","acos of 2",1},{"buffer-nan-read","buf_get of [b, 0]",1}
};
static void run_fourth(void) {
    for (unsigned i=0; i < sizeof fourth_cases / sizeof fourth_cases[0]; i++) {
        EigsState *st=eigs_open(); if (!st) { failures++; return; }
        eigs_state_set_strict_guards(st,0); eigs_state_set_strict_arithmetic(st,1);
        if (i==19) { EigsValue *b=eigs_value_new_buffer(1); eigs_value_buffer_set(b,0,NAN); eigs_set_global("b",b); eigs_value_release(b); }
        EigsValue *v=eigs_eval_string(fourth_cases[i].src);
        int seen=eigs_has_error()!=0;
        if (seen != fourth_cases[i].error) { printf("FAIL: fourth %s want-error=%d seen=%d\n",fourth_cases[i].name,fourth_cases[i].error,seen); failures++; }
        fourth_count++; if(v)eigs_value_release(v); eigs_clear_error(); eigs_close(st);
    }
}
/* A state with no call made on it has the position its environment gives:
 * EIGS_STRICT unset or empty: guards 1, arithmetic 0; "0": both 0; any other
 * value: both 1. The suite runs this program in each of the three. */
static void creation(void) {
    const char *e = getenv("EIGS_STRICT");
    int set = e && e[0], off = set && e[0] == '0' && e[1] == 0;
    int wg = set ? !off : 1, wa = set ? !off : 0;
    EigsState *st = eigs_open();
    if (!st) { printf("FAIL: creation state\n"); failures++; return; }
    int g = probe("try:\n    abs of \"x\"\ncatch e:\n    -777\n", wg, 1);
    int a = probe("try:\n    1.0 / 0.0\ncatch e:\n    -777\n", wa, 0);
    if (g && a) printf("PASS: creation guards=%d arithmetic=%d\n", wg, wa);
    else { printf("FAIL: creation want=%d,%d seen=%d,%d\n", wg, wa, g, a); failures++; }
    eigs_close(st);
}
/* Two states alive together: a call on one does not move the other, and no
 * call writes the process environment. */
static void two_states(void) {
    const char *before = getenv("EIGS_STRICT");
    EigsState *a = eigs_state_new(), *b = eigs_state_new();
    if (!a || !b) { printf("FAIL: two states creation\n"); failures++; return; }
    eigs_state_set_strict(a, 0);
    eigs_state_set_strict(b, 0);
    eigs_state_set_strict_guards(a, 1);
    eigs_state_set_strict_arithmetic(b, 1);
    const char *after = getenv("EIGS_STRICT");
    int env_same = (before == after) || (before && after && !strcmp(before, after));
    int ok = env_same;
    if (!eigs_thread_attach(a) || eigs_state_init_runtime(a)) ok = 0;
    else {
        ok = ok && probe("try:\n    abs of \"x\"\ncatch e:\n    -777\n", 1, 1)
                && probe("try:\n    1.0 / 0.0\ncatch e:\n    -777\n", 0, 0);
    }
    eigs_close(a);
    if (!eigs_thread_attach(b) || eigs_state_init_runtime(b)) ok = 0;
    else {
        ok = ok && probe("try:\n    abs of \"x\"\ncatch e:\n    -777\n", 0, 1)
                && probe("try:\n    1.0 / 0.0\ncatch e:\n    -777\n", 1, 0);
    }
    eigs_close(b);
    if (ok) printf("PASS: two states keep their own positions\n");
    else { printf("FAIL: two states keep their own positions\n"); failures++; }
}
int main(void) {
    creation();
    two_states();
    eigs_state_set_strict_guards(NULL, -1);
    eigs_state_set_strict_arithmetic(NULL, 2);
    transition("guards 1->0 other=0",0,1,0,eigs_state_set_strict_guards,0,0,0);
    transition("guards 0->1 other=0",0,0,0,eigs_state_set_strict_guards,-1,1,0);
    transition("arithmetic 1->0 other=0",0,0,1,eigs_state_set_strict_arithmetic,0,0,0);
    transition("arithmetic 0->1 other=0",0,0,0,eigs_state_set_strict_arithmetic,2,0,1);
    transition("guards 1->0 other=1",0,1,1,eigs_state_set_strict_guards,0,0,1);
    transition("guards 0->1 other=1",0,0,1,eigs_state_set_strict_guards,1,1,1);
    transition("arithmetic 1->0 other=1",1,1,1,eigs_state_set_strict_arithmetic,0,1,0);
    transition("arithmetic 0->1 other=1",1,1,0,eigs_state_set_strict_arithmetic,1,1,1);
    transition("both 01->00",1,0,1,eigs_state_set_strict,0,0,0);
    transition("both 10->00",1,1,0,eigs_state_set_strict,0,0,0);
    transition("both 01->11",1,0,1,eigs_state_set_strict,-1,1,1);
    transition("both 10->11",1,1,0,eigs_state_set_strict,2,1,1);
    run_fourth();
    printf("embed-strict-calls: %s transitions=%d fourth=%d failures=%d\n",failures?"FAIL":"PASS",transitions,fourth_count,failures);
    return failures != 0;
}
