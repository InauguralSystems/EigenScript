#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "eigs_embed.h"

typedef void (*Setter)(EigsState *, int);
typedef struct { const char *name, *src; int error; } Fourth;
static int failures, transitions, fourth_count;
static const char GUARD_SRC[] = "try:\n    abs of \"x\"\ncatch e:\n    -777\n";
static const char ARITH_SRC[] = "try:\n    1.0 / 0.0\ncatch e:\n    -777\n";

static EigsState *new_state(int kind) {
    return kind ? eigs_state_new() : eigs_open();
}
/* The position a property is in on the current state: 1 when the program
 * raises, 0 when it gives the quiet answer (0 for the guard program, inf for
 * the arithmetic one), -1 when it does neither. */
static int position(const char *src, int guard) {
    EigsValue *v = eigs_eval_string(src);
    int ok = v && !eigs_has_error();
    double n = ok ? eigs_value_as_num(v) : -9999;
    if (v) eigs_value_release(v);
    eigs_clear_error();
    if (!ok) return -1;
    if (n == -777) return 1;
    return (guard ? n == 0 : isinf(n)) ? 0 : -1;
}
static int probe(const char *src, int strict, int guard) {
    return position(src, guard) == strict;
}
/* One call on one fresh state: the state starts at (sg, sa), set there
 * through calls, then `setter(st, enabled)`; both properties are read back.
 * The kind says where the state is in its life when the calls are made:
 *   OPEN      from eigs_open: attached and initialised.
 *   NEW       from eigs_state_new: attached and initialised only after the
 *             call.
 *   ATTACHED  from eigs_state_new: the start is set before it is attached,
 *             and the call is made after eigs_thread_attach and before
 *             eigs_state_init_runtime.
 *   OTHER     as NEW, while another state is attached and initialised on the
 *             calling thread. That state is put, through calls on it, at the
 *             opposite of what the call writes; it is read back before the
 *             switch and must still be there (*kept).
 * Returns 0 when a state could not be made. */
enum { OPEN, NEW, ATTACHED, OTHER, KINDS };
static const char *const kind_names[KINDS] = {"open", "new", "attached", "other"};
static int cell(int kind, int sg, int sa, Setter setter, int enabled, int *g, int *a, int *kept) {
    EigsState *other = NULL, *st;
    int off = enabled == 0;
    *g = *a = -1; *kept = 1;
    if (kind == OTHER) {
        other = eigs_open();
        if (!other) return 0;
        eigs_state_set_strict(other, off);
    }
    st = new_state(kind);
    if (!st) return 0;
    eigs_state_set_strict(st, 0);
    eigs_state_set_strict_guards(st, sg);
    eigs_state_set_strict_arithmetic(st, sa);
    if (kind == ATTACHED && !eigs_thread_attach(st)) { eigs_state_destroy(st); return 0; }
    setter(st, enabled);
    if (kind == OTHER) {
        *kept = position(GUARD_SRC, 1) == off && position(ARITH_SRC, 0) == off;
        if (!eigs_thread_switch(st)) return 0;
    }
    if (kind == NEW && !eigs_thread_attach(st)) { eigs_state_destroy(st); return 0; }
    if (kind != OPEN && eigs_state_init_runtime(st)) return 0;
    *g = position(GUARD_SRC, 1);
    *a = position(ARITH_SRC, 0);
    eigs_close(st);
    if (other) {
        if (!eigs_thread_switch(other)) return 0;
        eigs_close(other);
    }
    return 1;
}
static void transition(const char *name, int fine, int sg, int sa,
                       Setter setter, int enabled, int wg, int wa) {
    int g, a, kept;
    if (!cell(fine ? NEW : OPEN, sg, sa, setter, enabled, &g, &a, &kept)) {
        printf("FAIL: %s state creation or initialization\n", name); failures++; return;
    }
    transitions++;
    if (g == wg && a == wa) printf("PASS: %s\n", name);
    else { printf("FAIL: %s want=%d,%d seen=%d,%d\n", name, wg, wa, g, a); failures++; }
}
/* Every cell, so that no combination is held only by which twelve were
 * chosen: each of the three calls, on each kind of state, from each of the
 * four start positions, with each of the values 0, 1, -1 and 2. The call's
 * own property takes the value's truth; the other property stays (the
 * existing call has no other); a state that was attached while the call was
 * made on another has not moved. One line for all of them; a wrong cell is
 * named. */
static void matrix(void) {
    static const int values[] = {0, 1, -1, 2};
    static const char *const calls[] = {"guards", "arithmetic", "both"};
    const Setter setters[] = {eigs_state_set_strict_guards, eigs_state_set_strict_arithmetic, eigs_state_set_strict};
    int cells = 0, wrong = 0;
    for (int c = 0; c < 3; c++)
        for (int kind = 0; kind < KINDS; kind++)
            for (int sg = 0; sg < 2; sg++)
                for (int sa = 0; sa < 2; sa++)
                    for (unsigned v = 0; v < sizeof values / sizeof values[0]; v++) {
                        int on = values[v] != 0, g, a, kept;
                        int wg = c == 1 ? sg : on, wa = c == 0 ? sa : on;
                        cells++;
                        if (!cell(kind, sg, sa, setters[c], values[v], &g, &a, &kept) || g != wg || a != wa || !kept) {
                            wrong++;
                            printf("FAIL: matrix %s %s start=%d,%d value=%d want=%d,%d seen=%d,%d%s\n",
                                   kind_names[kind], calls[c], sg, sa, values[v], wg, wa, g, a,
                                   kept ? "" : " and the attached state moved");
                        }
                    }
    failures += wrong;
    if (!wrong) printf("PASS: matrix of %d cells (3 calls, 4 kinds of state, 4 start positions, 4 values)\n", cells);
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
    int seen_g = position(GUARD_SRC, 1);
    int seen_a = position(ARITH_SRC, 0);
    if (seen_g == wg && seen_a == wa)
        printf("PASS: creation guards=%d arithmetic=%d\n", wg, wa);
    else { printf("FAIL: creation want=%d,%d seen=%d,%d\n", wg, wa, seen_g, seen_a); failures++; }
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
    eigs_state_set_strict(NULL, 1);
    transition("open guards 1->0 other=0",0,1,0,eigs_state_set_strict_guards,0,0,0);
    transition("new guards 0->1 other=0",1,0,0,eigs_state_set_strict_guards,-1,1,0);
    transition("new guards 1->0 other=1",1,1,1,eigs_state_set_strict_guards,0,0,1);
    transition("open guards 0->1 other=1",0,0,1,eigs_state_set_strict_guards,2,1,1);
    transition("open arithmetic 1->0 other=0",0,0,1,eigs_state_set_strict_arithmetic,0,0,0);
    transition("new arithmetic 0->1 other=0",1,0,0,eigs_state_set_strict_arithmetic,2,0,1);
    transition("new arithmetic 1->0 other=1",1,1,1,eigs_state_set_strict_arithmetic,0,1,0);
    transition("open arithmetic 0->1 other=1",0,1,0,eigs_state_set_strict_arithmetic,-1,1,1);
    transition("open both 01->00",0,0,1,eigs_state_set_strict,0,0,0);
    transition("new both 10->00",1,1,0,eigs_state_set_strict,0,0,0);
    transition("new both 01->11",1,0,1,eigs_state_set_strict,-1,1,1);
    transition("open both 10->11",0,1,0,eigs_state_set_strict,2,1,1);
    matrix();
    run_fourth();
    printf("embed-strict-calls: %s transitions=%d fourth=%d failures=%d\n",failures?"FAIL":"PASS",transitions,fourth_count,failures);
    return failures != 0;
}
