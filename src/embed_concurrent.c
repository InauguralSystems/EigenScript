/* #885 — the CONCURRENT half of the multi-state embedding promise.
 *
 * docs/EMBEDDING.md states, load-bearingly:
 *
 *     The runtime is multi-state. A single process can hold multiple
 *     EigsState instances concurrently; each one is independent.
 *
 * Nothing tested the *concurrently* half. `pthread_create` appeared nowhere in
 * src/embed_smoke.c or any tests/ shell script, and the one multi-state case that did
 * exist (embed_smoke.c "Multi-state switching on one thread") is explicitly
 * sequential — it covers SWITCHING, not INDEPENDENCE.
 *
 * WHY THIS IS A GATE AND NOT A DEMO. The promise holds today by construction:
 * nearly every `g_*` name is a macro onto `eigs_current->…`, so state that
 * looks global is per-state or per-thread. That is a good design and an
 * invisible one — a future counter added as a file-scope `static` instead of an
 * EigsState/EigsThread field looks correct in every single-threaded test in the
 * repo, and breaks one host reading another's thresholds, budget or error flag.
 * The failure mode is silent in every existing lane and arbitrarily bad in an
 * embedded host. So this file ends with a PLANTED FAULT that reintroduces
 * exactly that mistake and requires the checks above it to catch it: a gate
 * whose fault it has never caught is decoration.
 *
 * Build:  make embed-concurrent
 */
#include "eigs_embed.h"
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void check(int ok, const char *what) {
    if (ok) {
        printf("  PASS: %s\n", what);
    } else {
        printf("  FAIL: %s\n", what);
        failures++;
    }
}

/* Rounds are deliberately modest: these assertions fire on the RATIO of two
 * states' settings, not on how long they are held, so a long spin buys nothing
 * and costs CI time (mechanical-gates §34). Enough interleaving to lose a race
 * if one exists, not enough to matter to the suite's runtime. */
#define ROUNDS 200

/* ------------------------------------------------------------------ 1 */
/* Two states, one per OS thread, each setting a distinct observer threshold.
 * Each must read back its OWN. A shared global would make the later writer win
 * and both threads would read the same number. */

typedef struct {
    double  want;
    int     mismatches;
    int     started;
} ThreshArg;

static void *thresh_worker(void *p) {
    ThreshArg *a = (ThreshArg *)p;
    EigsState *st = eigs_open();
    if (!st) { a->mismatches = -1; return NULL; }
    a->started = 1;

    char src[160];
    snprintf(src, sizeof src,
             "set_observer_thresholds of [%.6f, 0.02, 0.3]", a->want);
    EigsValue *v = eigs_eval_string(src);
    if (v) eigs_value_release(v);

    for (int i = 0; i < ROUNDS; i++) {
        /* Re-assert each round, then read: a shared global loses this thread's
         * value to the other thread's write between the two. */
        EigsValue *sv = eigs_eval_string(src);
        if (sv) eigs_value_release(sv);
        EigsValue *got = eigs_eval_string("(get_observer_thresholds of null)[0]");
        if (!got) { a->mismatches++; continue; }
        double d = eigs_value_as_num(got);
        eigs_value_release(got);
        /* Exact-ish: the value round-trips through a double, so compare with a
         * tolerance far tighter than the gap between the two threads' settings
         * (0.001 vs 0.002) — a cross-talk failure moves it by 100x this. */
        if (d < a->want - 1e-9 || d > a->want + 1e-9) a->mismatches++;
    }
    eigs_close(st);
    return NULL;
}

static void test_observer_thresholds(void) {
    ThreshArg a = { 0.001, 0, 0 }, b = { 0.002, 0, 0 };
    pthread_t ta, tb;
    pthread_create(&ta, NULL, thresh_worker, &a);
    pthread_create(&tb, NULL, thresh_worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);

    /* Vacuity: a worker that never opened a state reports 0 mismatches and
     * would score as a pass having measured nothing. */
    check(a.started && b.started, "both threads opened their own EigsState");
    check(a.mismatches == 0 && b.mismatches == 0,
          "per-state observer thresholds do not cross threads");
    if (a.mismatches || b.mismatches)
        printf("        mismatches: A=%d B=%d over %d rounds each\n",
               a.mismatches, b.mismatches, ROUNDS);
}

/* ------------------------------------------------------------------ 2 */
/* Per-state GLOBAL ENVIRONMENTS. Two threads bind the same NAME to different
 * values; each must read back its own. This is the most direct reading of
 * "each one is independent" for an embedding host — two hosts in one process
 * using the same variable names — and it is what a shared global env breaks
 * first. (The issue suggested per-thread sandbox budgets here; `sandbox_run`
 * takes an ABI-stamped bytecode DESCRIPTOR rather than a source string and a
 * budget dict, so that row would test descriptor assembly as much as
 * isolation. Globals isolate the property under test.) */

typedef struct {
    double  want;
    int     mismatches;
    int     rounds_run;
} GlobalArg;

static void *global_worker(void *p) {
    GlobalArg *a = (GlobalArg *)p;
    EigsState *st = eigs_open();
    if (!st) { a->mismatches = -1; return NULL; }

    char src[96];
    snprintf(src, sizeof src, "shared_name is %.0f\nreturn shared_name", a->want);

    for (int i = 0; i < ROUNDS; i++) {
        EigsValue *v = eigs_eval_string(src);
        if (!v) { a->mismatches++; continue; }
        double d = eigs_value_as_num(v);
        eigs_value_release(v);
        a->rounds_run++;
        if (d != a->want) a->mismatches++;
    }
    eigs_close(st);
    return NULL;
}

static void test_global_isolation(void) {
    GlobalArg a = { 111, 0, 0 }, b = { 222, 0, 0 };
    pthread_t ta, tb;
    pthread_create(&ta, NULL, global_worker, &a);
    pthread_create(&tb, NULL, global_worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);

    check(a.rounds_run == ROUNDS && b.rounds_run == ROUNDS,
          "both global-isolation threads completed every round");
    check(a.mismatches == 0 && b.mismatches == 0,
          "the same global NAME holds a different value in each state");
    if (a.mismatches || b.mismatches)
        printf("        mismatches: A=%d B=%d over %d rounds each\n",
               a.mismatches, b.mismatches, ROUNDS);
}

/* ------------------------------------------------------------------ 3 */
/* An uncaught error in state A must leave state B's error flag clear. This is
 * the one a shared `has_error` breaks most visibly, and the one an embedded
 * host notices last: B's next eval reports a failure it never had. */

typedef struct {
    int raise;              /* 1 = this thread raises, 0 = stays clean */
    int saw_foreign_error;
    int rounds_run;
} ErrArg;

static void *err_worker(void *p) {
    ErrArg *a = (ErrArg *)p;
    EigsState *st = eigs_open();
    if (!st) { a->saw_foreign_error = -1; return NULL; }

    for (int i = 0; i < ROUNDS; i++) {
        if (a->raise) {
            EigsValue *v = eigs_eval_string("undefined_name_that_does_not_exist");
            if (v) eigs_value_release(v);
            /* This thread SHOULD be in error; that is its job. */
        } else {
            EigsValue *v = eigs_eval_string("1 + 1");
            if (v) eigs_value_release(v);
            if (eigs_has_error()) a->saw_foreign_error++;
        }
        a->rounds_run++;
    }
    eigs_close(st);
    return NULL;
}

static void test_error_isolation(void) {
    ErrArg raiser = { 1, 0, 0 }, quiet = { 0, 0, 0 };
    pthread_t ta, tb;
    pthread_create(&ta, NULL, err_worker, &raiser);
    pthread_create(&tb, NULL, err_worker, &quiet);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);

    check(quiet.rounds_run == ROUNDS && raiser.rounds_run == ROUNDS,
          "both error-isolation threads completed every round");
    check(quiet.saw_foreign_error == 0,
          "an uncaught error in one state leaves the other's flag clear");
    if (quiet.saw_foreign_error)
        printf("        the quiet thread saw %d foreign error(s) in %d rounds\n",
               quiet.saw_foreign_error, ROUNDS);
}

/* ------------------------------------------------------------------ 4 */
/* THE PLANTED FAULT.
 *
 * Everything above passes today, so on its own this file proves only that the
 * current tree is fine — not that these checks would NOTICE the regression they
 * exist for. So reproduce the exact mistake the design is vulnerable to: a
 * counter that SHOULD be per-state written as a file-scope `static`, shared by
 * every thread. Run the same two-thread shape over it and require the
 * cross-talk to be detected.
 *
 * This is a model of the bug, not an injection into the runtime: a gate must
 * not mutate what it checks (mechanical-gates §22), and there is no supported
 * way to make the real runtime regress at runtime. What it proves is that the
 * two-thread harness above — same thread count, same interleaving, same
 * comparison — is capable of catching a shared global at all. Without it, three
 * green rows are consistent with a harness that never races. */

static volatile double planted_shared_threshold;   /* the mistake, deliberately */

/* START BARRIER. Without one, this control is a race against pthread_create:
 * thread A can run ALL its rounds before B exists, giving zero overlap, zero
 * cross-talk, and a FAILED control on a healthy harness — which is exactly
 * what happened on a CI runner (PR #1034: `control: a shared global DOES
 * cross-talk` FAILed while all four isolation rows passed; the file is
 * identical on main, so the flake is the control's, not the branch's). The
 * barrier guarantees both threads are live before either's first round, which
 * is the interleaving premise the comment below already claims. */
static pthread_barrier_t planted_start;

typedef struct { double want; int mismatches; } PlantArg;

static void *planted_worker(void *p) {
    PlantArg *a = (PlantArg *)p;
    pthread_barrier_wait(&planted_start);
    for (int i = 0; i < ROUNDS; i++) {
        planted_shared_threshold = a->want;
        /* Give the other thread a window between write and read. Without one
         * the compiler and the scheduler can keep the pair adjacent and the
         * control reports NO cross-talk — which reads as "the harness does not
         * race" and would invalidate every row above it. `volatile` stops the
         * value being kept in a register; the yield supplies the interleaving. */
        sched_yield();
        double got = planted_shared_threshold;
        if (got < a->want - 1e-9 || got > a->want + 1e-9) a->mismatches++;
    }
    return NULL;
}

static void test_planted_fault_is_detectable(void) {
    PlantArg a = { 0.001, 0 }, b = { 0.002, 0 };
    pthread_t ta, tb;
    pthread_barrier_init(&planted_start, NULL, 2);
    pthread_create(&ta, NULL, planted_worker, &a);
    pthread_create(&tb, NULL, planted_worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&planted_start);

    /* The shared global MUST produce cross-talk. If it does not, the harness is
     * not interleaving and every green row above is uninformative. */
    check(a.mismatches + b.mismatches > 0,
          "control: a shared global DOES cross-talk under this harness");
    printf("        control cross-talk: A=%d B=%d over %d rounds each\n",
           a.mismatches, b.mismatches, ROUNDS);
}

int main(void) {
    printf("embed concurrent multi-state (#885)\n");
    test_observer_thresholds();
    test_global_isolation();
    test_error_isolation();
    test_planted_fault_is_detectable();

    if (failures) {
        printf("EMBED_CONCURRENT_FAIL: %d check(s) failed\n", failures);
        return 1;
    }
    printf("EMBED_CONCURRENT_OK\n");
    return 0;
}
