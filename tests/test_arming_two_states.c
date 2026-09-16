/* #1145(b): TWO EigsStates on two OS threads, NO spawn.
 *
 * `multithreaded` is a PER-STATE flag, so it is 0 on both threads here and
 * nothing widens the observer arming sets. Each `prev of <name>` compile runs
 * trace_arm_history_name (realloc of the process-global g_arm_names) and each
 * `<kw> is <name> when <n>` runs trace_arm_occurrences_name (realloc of
 * g_occ_names), while the OTHER state's assignments read the same arrays
 * through prev_record_assign -> arm_set_has / occ_set_has.
 *
 * src/state.c's eigs_process_thread_count() guard covers only the observer
 * gate's eager PRE-PASS; compile_node_inner (compiler.c) arms on the ordinary
 * path and was unguarded. Measured on the pre-fix tree (h1c_two_states.c, the
 * probe this file is the suite-resident form of):
 *   ThreadSanitizer 6/14/9 warnings in three runs, every one of them on
 *   g_arm_names/g_arm_count, including
 *     Read of size 8 ... arm_set_has src/trace.c:226 <- trace_arm_history_name
 *     src/trace.c:368 <- compile_node_inner src/compiler.c:3104
 *   and, in the issue's capture, heap-use-after-free: read in arm_set_has
 *   :217 <- prev_record_assign :536 against a realloc in
 *   trace_arm_history_name :356.
 *
 * WHAT THIS ASSERTS (mechanical-gates §131): conserved quantities only —
 * every eval returned a value, the number of answers equals the number of
 * evals, and every answer is the pinned one. Never an interleaving.
 * The scheduler window comes from the TEST side: a barrier releases both
 * threads into the arming loop at the same instant.
 *
 * Build: make arming-mt-test   (tests/test_tsan.sh builds it against the
 * TSan objects and requires zero src/trace.c reports.)
 */
#include "eigs_embed.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define ITERS 400

typedef struct {
    int id;
    int evals;        /* snippets submitted */
    int answers;      /* non-NULL results */
    int wrong;        /* results that were not the pinned value */
} Arg;

/* Start gate. NOT pthread_barrier_t: it is a POSIX OPTION that macOS never
 * implemented, and this file is built by the suite on the macos-latest lane
 * (PR #1172's first CI run: "two-state build: rc=2" there, green on Linux).
 * A mutex + condvar counter is the portable two-party barrier. */
static pthread_mutex_t g_gate_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_gate_cv = PTHREAD_COND_INITIALIZER;
static int             g_gate_arrived = 0;
static void gate_wait(int parties) {
    pthread_mutex_lock(&g_gate_mu);
    g_gate_arrived++;
    if (g_gate_arrived >= parties) pthread_cond_broadcast(&g_gate_cv);
    while (g_gate_arrived < parties) pthread_cond_wait(&g_gate_cv, &g_gate_mu);
    pthread_mutex_unlock(&g_gate_mu);
}

static void *worker(void *p) {
    Arg *a = (Arg *)p;
    char snippet[512];
    EigsState *st = eigs_open();
    if (!st) { fprintf(stderr, "eigs_open failed on thread %d\n", a->id); return NULL; }
    gate_wait(2);
    for (int i = 0; i < ITERS; i++) {
        /* A fresh name per iteration on each side: the arming sets only GROW
         * for a name they have not seen, so reusing names would stop the
         * realloc after the first pass and the probe would go quiet without
         * the defect being fixed (mechanical-gates §64). */
        snprintf(snippet, sizeof snippet,
                 "v%d_%d is 1.0\n"
                 "v%d_%d is 2.0\n"
                 "w%d_%d is 1\n"
                 "w%d_%d is 2\n"
                 "r is prev of v%d_%d\n"
                 "s is what is w%d_%d when 1\n"
                 "return r + s\n",
                 a->id, i, a->id, i, a->id, i, a->id, i, a->id, i, a->id, i);
        a->evals++;
        EigsValue *v = eigs_eval_string(snippet);
        if (!v) continue;
        a->answers++;
        /* prev of v = 1.0, and the FIRST occurrence of w is 1 -> 2.0. */
        if (eigs_value_type(v) != EIGS_TYPE_NUM || eigs_value_as_num(v) != 2.0)
            a->wrong++;
        eigs_value_release(v);
    }
    eigs_close(st);
    return NULL;
}

int main(void) {
    int pass = 0, fail = 0;
    Arg a = {0, 0, 0, 0}, b = {1, 0, 0, 0};
    pthread_t ta, tb;
    pthread_create(&ta, NULL, worker, &a);
    pthread_create(&tb, NULL, worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);

    Arg *arms[2] = { &a, &b };
    int examined = 0;
    for (int i = 0; i < 2; i++) {
        Arg *x = arms[i];
        examined++;
        if (x->evals == ITERS) {
            printf("  PASS: state %d submitted %d evals\n", x->id, x->evals);
            pass++;
        } else {
            printf("  FAIL: evals: state %d submitted %d, want %d\n", x->id, x->evals, ITERS);
            fail++;
        }
        if (x->answers == x->evals && x->answers > 0) {
            printf("  PASS: state %d answers == evals (%d)\n", x->id, x->answers);
            pass++;
        } else {
            printf("  FAIL: answers: state %d answered %d of %d\n", x->id, x->answers, x->evals);
            fail++;
        }
        if (x->wrong == 0) {
            printf("  PASS: state %d every temporal answer was 2.0\n", x->id);
            pass++;
        } else {
            printf("  FAIL: values: state %d had %d wrong temporal answer(s)\n", x->id, x->wrong);
            fail++;
        }
    }
    /* §121: "some state ran" is vacuous — the loop must have covered the
     * whole table, and the table must be non-empty. */
    if (examined == 2) {
        printf("  PASS: states examined == declared (2)\n");
        pass++;
    } else {
        printf("  FAIL: population: examined %d states, declared 2\n", examined);
        fail++;
    }
    printf("ARMING_TWO_STATES: %d passed, %d failed\n", pass, fail);
    return fail == 0 ? 0 : 1;
}
