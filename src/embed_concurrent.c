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
#include <stdatomic.h>
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

typedef struct { double want; int mismatches; int rounds_run; } PlantArg;

/* The control must OBSERVE the race, not merely give it 200 chances. A fixed
 * round count is a bet on the scheduler: on a runner slot where one thread's
 * write-yield-read triple stays adjacent, 200 rounds can pass with zero
 * cross-talk (CI on 07a0ac3, 2026-09-06: `A=0 B=0 over 200 rounds each`, the
 * file identical on main; PR #1034 hit the same shape before the barrier was
 * added). So each worker runs at least ROUNDS rounds and then keeps racing
 * until BOTH sides have seen at least one mismatch or PLANT_BUDGET rounds have
 * elapsed. A harness that truly never interleaves still exhausts the budget
 * and FAILS the control — the property being checked is unchanged; only the
 * sample size adapts to the scheduler. */
#define PLANT_BUDGET 200000
static _Atomic int planted_seen;           /* number of workers that observed a mismatch */

static void *planted_worker(void *p) {
    PlantArg *a = (PlantArg *)p;
    int counted = 0;
    pthread_barrier_wait(&planted_start);
    for (int i = 0; i < PLANT_BUDGET; i++) {
        if (i >= ROUNDS && atomic_load(&planted_seen) >= 2) break;
        planted_shared_threshold = a->want;
        /* Give the other thread a window between write and read. Without one
         * the compiler and the scheduler can keep the pair adjacent and the
         * control reports NO cross-talk — which reads as "the harness does not
         * race" and would invalidate every row above it. `volatile` stops the
         * value being kept in a register; the yield supplies the interleaving. */
        sched_yield();
        double got = planted_shared_threshold;
        a->rounds_run++;
        if (got < a->want - 1e-9 || got > a->want + 1e-9) {
            a->mismatches++;
            if (!counted) { counted = 1; atomic_fetch_add(&planted_seen, 1); }
        }
    }
    return NULL;
}

static void test_planted_fault_is_detectable(void) {
    PlantArg a = { 0.001, 0, 0 }, b = { 0.002, 0, 0 };
    atomic_store(&planted_seen, 0);
    pthread_t ta, tb;
    pthread_barrier_init(&planted_start, NULL, 2);
    pthread_create(&ta, NULL, planted_worker, &a);
    pthread_create(&tb, NULL, planted_worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&planted_start);

    /* The shared global MUST produce cross-talk. If it does not, the harness is
     * not interleaving and every green row above is uninformative. */
    check(a.mismatches > 0 && b.mismatches > 0,
          "control: a shared global DOES cross-talk under this harness");
    printf("        control cross-talk: A=%d/%d B=%d/%d rounds (min %d, budget %d)\n",
           a.mismatches, a.rounds_run, b.mismatches, b.rounds_run, ROUNDS, PLANT_BUDGET);
}

/* ------------------------------------------------------------------ 5 */
/* #1142: two states, one process-wide sink. Records must be atomic (every
 * byte of the collected stream is a well-formed tape line) and sink_bytes
 * must equal the sum of those record lengths. A mutex-free tp_putc loses
 * bytes or overflows g_sink_buf. */

typedef struct {
    char *buf;
    size_t len, cap;
    pthread_mutex_t mu;
} SinkBuf;

static void sinkbuf_init(SinkBuf *s) {
    memset(s, 0, sizeof *s);
    pthread_mutex_init(&s->mu, NULL);
}
static void sinkbuf_free(SinkBuf *s) {
    free(s->buf);
    pthread_mutex_destroy(&s->mu);
}
static void sinkbuf_cb(const char *b, size_t n, void *ud) {
    SinkBuf *s = (SinkBuf *)ud;
    pthread_mutex_lock(&s->mu);
    if (s->len + n + 1 > s->cap) {
        size_t nc = s->cap ? s->cap * 2 : 8192;
        while (nc < s->len + n + 1) nc *= 2;
        char *nb = realloc(s->buf, nc);
        if (!nb) { pthread_mutex_unlock(&s->mu); return; }
        s->buf = nb; s->cap = nc;
    }
    memcpy(s->buf + s->len, b, n);
    s->len += n;
    s->buf[s->len] = '\0';
    pthread_mutex_unlock(&s->mu);
}

/* Grammar from docs/TRACE.md. Returns 1 if the line is a well-formed record. */
static int tape_line_ok(const char *line) {
    if (!line || !line[0]) return 0;
    if (line[0] == 'V' && line[1] == ' ') return 1;
    if (line[0] == 'L' && line[1] == ' ') {
        const char *p = line + 2;
        if (!*p) return 0;
        while (*p) { if (*p < '0' || *p > '9') return 0; p++; }
        return 1;
    }
    if (line[0] == 'S' && line[1] == ' ') return 1; /* S <fn> <depth> <serial> */
    if (line[0] == 'A' && line[1] == ' ') return strchr(line + 2, '=') != NULL;
    if (line[0] == 'N' && line[1] == ' ') return strchr(line + 2, '=') != NULL;
    if (strncmp(line, "O cfg ", 6) == 0) {
        /* five fields: three floats, window int, scale float */
        int fields = 0;
        const char *p = line + 6;
        while (*p) {
            while (*p == ' ') p++;
            if (!*p) break;
            fields++;
            while (*p && *p != ' ') p++;
        }
        return fields == 5;
    }
    if (strncmp(line, "O win ", 6) == 0) return 1;
    return 0;
}

typedef struct {
    int lines, well, malformed, nrec, ocfg;
    size_t parsed_bytes;
} TapeParse;

static TapeParse parse_tape_buf(const char *buf, size_t len) {
    TapeParse t;
    memset(&t, 0, sizeof t);
    size_t i = 0;
    while (i < len) {
        size_t start = i;
        while (i < len && buf[i] != '\n') i++;
        size_t n = i - start;
        char line[65536];
        if (n >= sizeof line) n = sizeof line - 1;
        memcpy(line, buf + start, n);
        line[n] = '\0';
        /* count the newline as part of the record when present */
        size_t rec = (i < len && buf[i] == '\n') ? (i - start + 1) : (i - start);
        if (n == 0 && i >= len) break;
        t.lines++;
        if (tape_line_ok(line)) {
            t.well++;
            t.parsed_bytes += rec;
            if (line[0] == 'N' && line[1] == ' ') t.nrec++;
            if (strncmp(line, "O cfg ", 6) == 0) t.ocfg++;
        } else {
            t.malformed++;
        }
        if (i < len && buf[i] == '\n') i++;
    }
    return t;
}

#define SINK_ROUNDS 40

typedef struct {
    int ok, err;
} SinkArg;

static pthread_barrier_t sink_start;
static void *sink_worker(void *p) {
    SinkArg *a = (SinkArg *)p;
    EigsState *st = eigs_open();
    if (!st) { a->err = -1; return NULL; }
    pthread_barrier_wait(&sink_start);
    for (int i = 0; i < SINK_ROUNDS; i++) {
        EigsValue *v = eigs_eval_string(
            "s is env_get of \"CONC_LONG\"\nr is random of []\nreturn r");
        if (v) { a->ok++; eigs_value_release(v); } else a->err++;
    }
    eigs_close(st);
    return NULL;
}

static void test_two_state_sink(void) {
    char longv[801];
    memset(longv, 'x', 800); longv[800] = 0;
    setenv("CONC_LONG", longv, 1);

    SinkBuf sb;
    sinkbuf_init(&sb);
    eigs_set_trace_sink(sinkbuf_cb, &sb);

    SinkArg a = {0, 0}, b = {0, 0};
    pthread_barrier_init(&sink_start, NULL, 2);
    pthread_t ta, tb;
    pthread_create(&ta, NULL, sink_worker, &a);
    pthread_create(&tb, NULL, sink_worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&sink_start);

    eigs_set_trace_sink(NULL, NULL);

    TapeParse p = parse_tape_buf(sb.buf, sb.len);
    check(a.ok == SINK_ROUNDS && b.ok == SINK_ROUNDS,
          "sink: both states completed every eval");
    check(p.lines > 0, "sink: parser examined lines > 0");
    check(p.malformed == 0, "sink: every collected line is well-formed");
    check(p.parsed_bytes == sb.len,
          "sink byte accounting: sink_bytes equals the sum of record lengths");
    check(p.nrec == SINK_ROUNDS * 2 * 2,
          "sink: N count equals 2 states x rounds x (env_get + random)");
    /* Control: a truncated stream MUST make the byte-sum check red. */
    if (sb.len > 8) {
        TapeParse trunc = parse_tape_buf(sb.buf, sb.len / 2);
        check(trunc.parsed_bytes != sb.len,
              "control: a truncated sink buffer fails the byte-sum equality");
    }
    printf("        sink: bytes=%zu lines=%d N=%d malformed=%d\n",
           sb.len, p.lines, p.nrec, p.malformed);
    sinkbuf_free(&sb);
    unsetenv("CONC_LONG");
}

/* ------------------------------------------------------------------ 6 */
/* #1142: O cfg is per-state last-emitted. Two states with different
 * thresholds emit exactly one O cfg each (first record), none torn. */

static pthread_barrier_t ocfg_start;
typedef struct { int id; int ok; } OcfgArg;
static void *ocfg_worker(void *p) {
    OcfgArg *a = (OcfgArg *)p;
    EigsState *st = eigs_open();
    if (!st) return NULL;
    if (a->id == 0) {
        EigsValue *v = eigs_eval_string("set_observer_thresholds of [0.002, 0.03, 0.4]");
        if (v) eigs_value_release(v);
    } else {
        EigsValue *v = eigs_eval_string("set_observer_thresholds of [0.003, 0.04, 0.5]");
        if (v) eigs_value_release(v);
    }
    pthread_barrier_wait(&ocfg_start);
    for (int i = 0; i < 50; i++) {
        EigsValue *v = eigs_eval_string("x is 1.0\nx is 2.0\nreturn x");
        if (v) { a->ok++; eigs_value_release(v); }
    }
    eigs_close(st);
    return NULL;
}

static void test_ocfg_per_state(void) {
    SinkBuf sb;
    sinkbuf_init(&sb);
    eigs_set_trace_sink(sinkbuf_cb, &sb);
    pthread_barrier_init(&ocfg_start, NULL, 2);
    OcfgArg a = {0, 0}, b = {1, 0};
    pthread_t ta, tb;
    pthread_create(&ta, NULL, ocfg_worker, &a);
    pthread_create(&tb, NULL, ocfg_worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&ocfg_start);
    eigs_set_trace_sink(NULL, NULL);

    TapeParse p = parse_tape_buf(sb.buf, sb.len);
    check(a.ok == 50 && b.ok == 50, "O cfg: both states completed every eval");
    check(p.lines > 0, "O cfg: parser examined lines > 0");
    check(p.malformed == 0, "O cfg: no torn records");
    check(p.ocfg == 2, "O cfg per state: exactly one first-record emit per state");
    /* Control: a torn O cfg line is rejected, so the well-formed count can
     * go red. */
    check(!tape_line_ok("O cfg 0.00.001 01 0.0.02"),
          "control: a torn O cfg line is not well-formed");
    printf("        O cfg: well=%d ocfg=%d malformed=%d\n",
           p.well, p.ocfg, p.malformed);
    sinkbuf_free(&sb);
}

/* ------------------------------------------------------------------ 7 */
/* #1143: eigs_close(A) must not shut the process tape while B is live. */

static _Atomic int close_phase = 1;
static _Atomic long close_phase2_bytes = 0;
static SinkBuf close_sb;
static pthread_barrier_t close_start, close_a_done;

static void close_sink_cb(const char *b, size_t n, void *ud) {
    sinkbuf_cb(b, n, ud);
    if (atomic_load(&close_phase) == 2)
        atomic_fetch_add(&close_phase2_bytes, (long)n);
}

typedef struct { int id; int p1_ok, p2_ok; } CloseArg;

static void *close_worker(void *p) {
    CloseArg *a = (CloseArg *)p;
    EigsState *st = eigs_open();
    if (!st) return NULL;
    pthread_barrier_wait(&close_start);
    for (int i = 0; i < 40; i++) {
        EigsValue *v = eigs_eval_string("r is random of []\nreturn r");
        if (v) { a->p1_ok++; eigs_value_release(v); }
    }
    if (a->id == 0) {
        eigs_close(st);
        atomic_store(&close_phase, 2);
        pthread_barrier_wait(&close_a_done);
        return NULL;
    }
    pthread_barrier_wait(&close_a_done);
    for (int i = 0; i < 30; i++) {
        EigsValue *v = eigs_eval_string("r is random of []\nreturn r");
        if (v) { a->p2_ok++; eigs_value_release(v); }
    }
    eigs_close(st);
    return NULL;
}

static void test_close_while_other_runs(void) {
    atomic_store(&close_phase, 1);
    atomic_store(&close_phase2_bytes, 0);
    sinkbuf_init(&close_sb);
    eigs_set_trace_sink(close_sink_cb, &close_sb);
    pthread_barrier_init(&close_start, NULL, 2);
    pthread_barrier_init(&close_a_done, NULL, 2);
    CloseArg a = {0, 0, 0}, b = {1, 0, 0};
    pthread_t ta, tb;
    pthread_create(&ta, NULL, close_worker, &a);
    pthread_create(&tb, NULL, close_worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&close_start);
    pthread_barrier_destroy(&close_a_done);
    eigs_set_trace_sink(NULL, NULL);

    check(a.p1_ok == 40 && b.p1_ok == 40, "close: both states completed phase 1");
    check(b.p2_ok == 30, "close: B completed phase 2 after A closed");
    check(atomic_load(&close_phase2_bytes) > 0,
          "close: does not shut tape while another state lives");
    /* Control: asserting phase-2 bytes == 0 is the close-always-shuts bug. */
    check(!(atomic_load(&close_phase2_bytes) == 0 && b.p2_ok == 30),
          "control: B evals with zero phase-2 bytes would fail the close check");
    printf("        close: phase2_bytes=%ld B_p2_ok=%d\n",
           (long)atomic_load(&close_phase2_bytes), b.p2_ok);
    sinkbuf_free(&close_sb);
}

/* ------------------------------------------------------------------ 8 */
/* #1142: two OS threads of the SAME owner state calling eigs_replay_take
 * concurrently. The tape mutex serializes them; without it, N records tear
 * or are double-consumed. Builtins on the second thread still fail-loud
 * (TRACE_NONDET_RET); this path is the embed take API. */

#define TAKE_N 400

typedef struct { int takes; } TakeArg;
static pthread_barrier_t take_start;
static EigsState *take_st = NULL;

static void *take_worker(void *p) {
    TakeArg *a = (TakeArg *)p;
    if (!eigs_thread_attach(take_st)) return NULL;
    pthread_barrier_wait(&take_start);
    for (;;) {
        EigsValue *v = NULL;
        if (!eigs_replay_take("random", &v)) break;
        a->takes++;
        if (v) eigs_value_release(v);
    }
    eigs_thread_detach();
    return NULL;
}

static void test_replay_take_serialized(void) {
    /* Build a tape: V header + TAKE_N `N random=0.5` records. Capture the
     * header from a one-shot sink so the version stamp matches this binary. */
    SinkBuf hdr;
    sinkbuf_init(&hdr);
    EigsState *prep = eigs_open();
    eigs_set_trace_sink(sinkbuf_cb, &hdr);
    EigsValue *pv = eigs_eval_string("1");
    if (pv) eigs_value_release(pv);
    eigs_set_trace_sink(NULL, NULL);
    eigs_close(prep);

    char *nl = hdr.buf ? strchr(hdr.buf, '\n') : NULL;
    check(nl != NULL, "replay-take: captured a V header");
    if (!nl) { sinkbuf_free(&hdr); return; }
    size_t hlen = (size_t)(nl - hdr.buf + 1);
    static const char nrec[] = "N random=0.5\n";
    size_t rec_sz = sizeof nrec - 1;
    size_t tlen = hlen + rec_sz * TAKE_N;
    char *tape = malloc(tlen + 1);
    memcpy(tape, hdr.buf, hlen);
    size_t off = hlen;
    for (int i = 0; i < TAKE_N; i++) {
        memcpy(tape + off, nrec, rec_sz);
        off += rec_sz;
    }
    tape[tlen] = '\0';
    sinkbuf_free(&hdr);

    take_st = eigs_state_new();
    eigs_thread_attach(take_st);
    eigs_state_init_runtime(take_st);
    check(eigs_set_replay_tape(tape, tlen, 0) != 0, "replay-take: tape installed");

    TakeArg a = {0}, b = {0};
    pthread_barrier_init(&take_start, NULL, 2);
    pthread_t tb;
    /* Thread A is already attached (this thread). Thread B attaches inside. */
    pthread_create(&tb, NULL, take_worker, &b);
    /* This thread also takes. take_worker on B will attach; we are attached. */
    pthread_barrier_wait(&take_start);
    for (;;) {
        EigsValue *v = NULL;
        if (!eigs_replay_take("random", &v)) break;
        a.takes++;
        if (v) eigs_value_release(v);
    }
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&take_start);

    int total = a.takes + b.takes;
    check(total == TAKE_N, "replay take serialized: exactly N records consumed");
    check(a.takes > 0 && b.takes > 0,
          "replay take serialized: both threads consumed some records");
    printf("        replay-take: A=%d B=%d total=%d (want %d)\n",
           a.takes, b.takes, total, TAKE_N);

    eigs_thread_detach();
    eigs_state_destroy(take_st);
    take_st = NULL;
    eigs_trace_shutdown();
    free(tape);
}

int main(void) {
    printf("embed concurrent multi-state (#885/#1142/#1143)\n");
    test_observer_thresholds();
    test_global_isolation();
    test_error_isolation();
    test_planted_fault_is_detectable();
    test_two_state_sink();
    test_ocfg_per_state();
    test_close_while_other_runs();
    test_replay_take_serialized();

    if (failures) {
        printf("EMBED_CONCURRENT_FAIL: %d check(s) failed\n", failures);
        return 1;
    }
    printf("EMBED_CONCURRENT_OK\n");
    return 0;
}
