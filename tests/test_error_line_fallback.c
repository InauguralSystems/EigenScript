/* #1082: a builtin's line-0 raise with no live VM frame reports the trace
 * stamp, not 0. A native (AOT) binary calls the linked builtins directly:
 * there is no interpreter frame, but g_trace_current_line is stamped per
 * statement. Before the fix rt_error resolved line 0 through the VM's live
 * line and printed "Error line 0: ..."; the AOT's own helpers, which pass
 * the stamp, printed the right line -- two different lines for one
 * program. This test raises from outside any frame with the stamp set and
 * requires the recorded message to carry it; then, with the stamp cleared,
 * requires 0 (no invented line).
 *
 * #1434: the same binary drives interpreted code from C, as the AOT does with
 * an eval-defined sort_by key. The callee's OP_LINEs moved the trace stamp,
 * and nothing restored it when vm_execute returned to C, so sort_by's own
 * raise, a later line-0 raise and a later store all used the key's line.
 * The suite runs this file under the JIT, EIGS_JIT_OFF=1 and forced OSR. */
#include <stdio.h>
#include <string.h>

#include "eigs_embed.h"
#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "trace.h"

extern Value *builtin_sort_by(Value *arg);
extern Value *builtin_sandbox_run(Value *arg);

static int fail = 0;
static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) fail = 1;
}

typedef struct {
    EigsState *state;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int phase;
} LineRaceProbe;

static void *line_race_worker(void *opaque) {
    LineRaceProbe *p = opaque;
    if (!eigs_thread_attach(p->state)) return NULL;
    pthread_mutex_lock(&p->mutex);
    while (p->phase < 1) pthread_cond_wait(&p->cond, &p->mutex);
    /* Deterministically stand in for the tight OP_LINE loop from #1435: the
     * main thread has stamped its raise site before this worker stamps 99. */
    g_trace_current_line = 99;
    p->phase = 2;
    pthread_cond_broadcast(&p->cond);
    while (p->phase < 3) pthread_cond_wait(&p->cond, &p->mutex);
    pthread_mutex_unlock(&p->mutex);
    eigs_thread_detach();
    return NULL;
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) { printf("FAIL: eigs_open\n"); return 1; }
    trace_init();                         /* EIGS_TRACE, as a native binary opens it */
    g_try_depth = 1;                      /* record only, as the AOT runs */

    /* #1435: a native caller has no VM frame, so its line-0 raise falls back
     * to this stamp. A worker stamping its own statements must not replace it. */
    LineRaceProbe probe = {st, PTHREAD_MUTEX_INITIALIZER,
                           PTHREAD_COND_INITIALIZER, 0};
    pthread_t worker;
    int worker_started = pthread_create(&worker, NULL, line_race_worker, &probe) == 0;
    check(worker_started,
          "#1435 starts the competing line-stamp worker");
    if (worker_started) {
        g_trace_current_line = 1435;
        pthread_mutex_lock(&probe.mutex);
        probe.phase = 1;
        pthread_cond_broadcast(&probe.cond);
        while (probe.phase < 2) pthread_cond_wait(&probe.cond, &probe.mutex);
        pthread_mutex_unlock(&probe.mutex);
        g_has_error = 0;
        rt_error(EK_VALUE, 0, "two-thread line probe");
        check(g_error_line == 1435,
              "#1435 a worker cannot replace the main thread's fallback line");
        pthread_mutex_lock(&probe.mutex);
        probe.phase = 3;
        pthread_cond_broadcast(&probe.cond);
        pthread_mutex_unlock(&probe.mutex);
        pthread_join(worker, NULL);
    }
    pthread_cond_destroy(&probe.cond);
    pthread_mutex_destroy(&probe.mutex);

    g_trace_current_line = 42;
    g_has_error = 0;
    rt_error(EK_VALUE, 0, "probe %d", 1);
    check(strncmp(g_error_msg, "Error line 42: probe 1", 22) == 0,
          "line-0 raise outside any frame reports the trace stamp (42)");
    check(vm_current_line() == 42, "vm_current_line answers the stamp with no live frame");

    g_has_error = 0;
    g_trace_current_line = 0;
    rt_error(EK_VALUE, 0, "probe %d", 2);
    check(strncmp(g_error_msg, "Error line 0: probe 2", 21) == 0,
          "with the stamp clear the line stays 0 (nothing invented)");

    g_has_error = 0;
    rt_error(EK_VALUE, 7, "probe %d", 3);
    check(strncmp(g_error_msg, "Error line 7: probe 3", 21) == 0,
          "an explicit line is untouched");

    /* #1434. ekey's lines are 1-9; its loop gives forced OSR a target and
     * 6001 calls make it hot for the JIT. The last element returns a string,
     * so sort_by raises after its final callback. */
    EigsValue *defs = eigs_eval_string(
        "define ekey(x) as:\n    y is 0\n    i is 0\n    loop while i < 3:\n"
        "        y is y + x\n        i is i + 1\n    if x < 0:\n"
        "        return \"s\"\n    return y\n");
    if (defs) eigs_value_release(defs);
    Value *ekey = eigs_get_global("ekey");
    check(ekey && ekey->type == VAL_FN, "#1434 eval defined the key");
    if (!ekey) return 1;
    Value *good = make_list(6001), *bad = make_list(6001);
    for (int i = 0; i < 6001; i++) {
        list_append_owned(good, make_num(6001 - i));
        list_append_owned(bad, make_num(i < 6000 ? 6001 - i : -1));
    }
    Value *args_good = make_list(2), *args_bad = make_list(2);
    list_append(args_good, good); list_append(args_good, ekey);
    list_append(args_bad, bad);   list_append(args_bad, ekey);

    g_has_error = 0;
    g_trace_current_line = 50;
    Value *r = builtin_sort_by(args_bad);
    if (r) val_decref(r);
    check(g_has_error && g_error_line == 50 &&
          strncmp(g_error_msg, "Error line 50: sort_by: key function", 36) == 0,
          "#1434 sort_by raising after an eval-defined key reports the call's stamp (50)");

    g_has_error = 0;
    g_trace_current_line = 60;
    r = builtin_sort_by(args_good);
    if (r) val_decref(r);
    check(!g_has_error && g_trace_current_line == 60,
          "#1434 the stamp is back on the call's line after the callbacks return (60)");
    rt_error(EK_VALUE, 0, "probe %d", 4);
    check(strncmp(g_error_msg, "Error line 60: probe 4", 22) == 0,
          "#1434 a later line-0 raise reports the call's stamp (60)");

    /* A store after the call is filed under the stamp: at the key's line it
     * retired the line-70 entry, so `at 75` answered the later value. */
    static const char *const NM = "errline_1434";
    EigsSlot sl, out;
    g_has_error = 0;   /* a pending error halts the callback before it runs */
    g_trace_current_line = 70; sl.d = 1.0; trace_assign(NM, sl);
    g_trace_current_line = 80;
    r = builtin_sort_by(args_good);
    check(!g_has_error && r && r->type == VAL_LIST && r->data.list.count == 6001,
          "#1434 the history row's sort_by ran its callbacks");
    if (r) val_decref(r);
    sl.d = 2.0; trace_assign(NM, sl);
    trace_line(95);   /* a stop right after the store, for [0b]'s `--step` query */
    check(trace_query_at(0, NM, 75, &out) && out.d == 1.0 &&
          trace_query_at(0, NM, 85, &out) && out.d == 2.0,
          "#1434 a store after the callbacks is filed under the call's stamp");
    /* The line live history filed the second store under, for [0b] to compare
     * with the tape stepper's `t` row over the same run's EIGS_TRACE tape. */
    int filed = 0;
    for (int ln = 1; ln <= 100 && !filed; ln++)
        if (trace_query_at(0, NM, ln, &out) && out.d == 2.0) filed = ln;
    printf("LIVE: %s=2 line %d\n", NM, filed);

    g_has_error = 0;
    g_trace_current_line = 90;
    EigsValue *ev = eigs_eval_string("p is 1\nq is p + 1\n");
    if (ev) eigs_value_release(ev);
    rt_error(EK_VALUE, 0, "probe %d", 5);
    check(strncmp(g_error_msg, "Error line 90: probe 5", 22) == 0,
          "#1434 a raise after eigs_eval_string reports the stamp it entered with (90)");
    /* A callback that ERROR-HALTS: sandbox_run's chunk stamps line 77, then
     * 1 / 0; sandbox_run swallows the error. Opcodes: LINE 68, NUM_ONE 3,
     * NUM_ZERO 2, DIV 7, RETURN 40 (src/vm.h enum order). */
    static const int HALT77[] = {68, 77, 0, 0, 0, 3, 2, 7, 40};
    Value *code = make_list(9), *desc = make_list(3), *sb_args = make_list(2);
    for (int i = 0; i < 9; i++) list_append_owned(code, make_num(HALT77[i]));
    list_append_owned(desc, make_num(1));
    list_append_owned(desc, code);
    list_append_owned(desc, make_list(0));
    list_append_owned(sb_args, desc);
    list_append_owned(sb_args, make_num(100));
    g_has_error = 0;
    g_trace_current_line = 100;
    r = builtin_sandbox_run(sb_args);
    if (r) val_decref(r);
    rt_error(EK_VALUE, 0, "probe %d", 6);
    check(strncmp(g_error_msg, "Error line 100: probe 6", 23) == 0,
          "#1434 a raise after an error-halted callback reports the call's stamp (100)");
    val_decref(sb_args);
    val_decref(args_good); val_decref(args_bad); val_decref(good); val_decref(bad);
    val_decref(ekey);

    /* The OUTERMOST vm_execute runs the task scheduler after vm_run, so an
     * unjoined task's lines run there; the stamp is restored after it, not
     * before (a restore before the scheduler reported the task's line 4). */
    g_has_error = 0;
    g_trace_current_line = 110;
    ev = eigs_eval_string("define tf(x) as:\n    y is x\n    w is y + 1\n    return w\n"
                          "t is task_spawn of [tf, 1]\n");
    if (ev) eigs_value_release(ev);
    rt_error(EK_VALUE, 0, "probe %d", 7);
    check(strncmp(g_error_msg, "Error line 110: probe 7", 23) == 0,
          "#1434 a raise after an eval whose task ran in the scheduler reports the stamp (110)");
    trace_shutdown();
    return fail;
}
