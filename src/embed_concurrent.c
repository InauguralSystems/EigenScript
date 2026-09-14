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
#include <unistd.h>

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
    /* #1142 contract (src/eigs_embed.h, docs/EMBEDDING.md): the sink gets
     * ONE complete newline-terminated record per call. `calls` counts the
     * hand-offs, `multi_rec` the calls carrying more than one record (a
     * newline before the last byte), `unterminated` the calls that do not
     * end in a newline. A consumer that maps one call to one journal entry
     * (EigenOS M11) silently drops every record after the first otherwise. */
    long calls, multi_rec, unterminated;
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

/* #1142: the sink callback must fire UNDER the tape mutex. That is a
 * structural property, so make it directly observable instead of hoping a
 * ~100 ns scheduler window tears: two sink callbacks can NEVER be
 * concurrent if the flush is inside the critical section. Each gated
 * callback publishes "I am inside the callback" and spins up to
 * CB_GATE_US for the sibling to publish the same.
 *
 *   - flush under the lock (correct): the sibling cannot reach its
 *     callback at all while we are in ours, so every gated call times out
 *     and cb_overlap stays 0 — deterministically, on any schedule;
 *   - flush outside the lock (mutant sink-flush-outside-lock): both
 *     siblings reach their callbacks inside the window and each sees the
 *     other, so cb_overlap > 0 — deterministically, on any schedule.
 *
 * Only the first callback of each round per thread is gated, so the
 * correct build pays the timeout 2 x SINK_ROUNDS times, not once per
 * record. test_cb_overlap_detector is the arming control. */
#define CB_GATE_US 2000
static _Atomic int  cb_gate_on = 0;
static _Atomic int  cb_in0 = 0, cb_in1 = 0;
static _Atomic long cb_overlap = 0;
static _Atomic long cb_gated = 0;
static __thread int cb_slot = -1;
static __thread int cb_gate_pending = 0;

static void cb_gate(void) {
    if (!atomic_load(&cb_gate_on) || cb_slot < 0 || !cb_gate_pending) return;
    cb_gate_pending = 0;
    _Atomic int *me    = cb_slot == 0 ? &cb_in0 : &cb_in1;
    _Atomic int *other = cb_slot == 0 ? &cb_in1 : &cb_in0;
    atomic_fetch_add(&cb_gated, 1);
    atomic_store(me, 1);
    /* Hold the flag raised for the WHOLE window and never break early: the
     * thread that spots its sibling first would otherwise clear its own
     * flag before the sibling looked, and the overlap would be seen by one
     * side only (measured: overlap=1 of 2 on the arming control). */
    int seen = 0;
    for (int i = 0; i < CB_GATE_US / 50; i++) {
        if (atomic_load(other)) seen = 1;
        usleep(50);
    }
    if (seen) atomic_fetch_add(&cb_overlap, 1);
    atomic_store(me, 0);
}

static void sinkbuf_cb(const char *b, size_t n, void *ud) {
    SinkBuf *s = (SinkBuf *)ud;
    cb_gate();
    pthread_mutex_lock(&s->mu);
    s->calls++;
    if (n == 0 || b[n - 1] != '\n') s->unterminated++;
    else if (memchr(b, '\n', n - 1) != NULL) s->multi_rec++;
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

/* A record kind letter glued onto the tail of another record's value:
 * `A x=1A y=2`, `N random=0.5N monotonic_ns=17`, `V 3 0.43.0A x=1`. The
 * signature is <non-space><A|N><space><name><'='>. Deliberately over-broad
 * (a string value whose CONTENT reads "…A x=1" is called malformed):
 * erring toward malformed turns a check RED, never silently green. */
static int tape_glued(const char *v) {
    for (const char *p = v + 1; p[0] && p[1]; p++) {
        if ((*p != 'A' && *p != 'N') || p[-1] == ' ' || p[1] != ' ') continue;
        const char *q = p + 2, *e = q;
        while (*e && *e != ' ' && *e != '=') e++;
        if (*e == '=' && e > q) return 1;
    }
    return 0;
}

/* An A/N value is exactly one of: a fully quoted string (may hold spaces),
 * a bracketed list/buffer, a braced dict, or a single space-free token. */
static int tape_value_ok(const char *v) {
    size_t n = strlen(v);
    if (!n) return 0;
    if (tape_glued(v)) return 0;
    if (v[0] == '"' && n >= 2 && v[n - 1] == '"') {
        for (size_t i = 1; i + 1 < n; i++) {
            if (v[i] == '\\') { i++; continue; }
            if (v[i] == '"') return 0;      /* two glued strings */
        }
        return 1;
    }
    if (v[n - 1] == ']' && (v[0] == '[' || (v[0] == 'b' && v[1] == '['))) return 1;
    if (v[0] == '{' && v[n - 1] == '}') return 1;
    return strchr(v, ' ') == NULL;
}

static int tape_fields(const char *p) {
    int fields = 0;
    while (*p) {
        while (*p == ' ') p++;
        if (!*p) break;
        fields++;
        while (*p && *p != ' ') p++;
    }
    return fields;
}

/* Grammar from docs/TRACE.md. Every pattern is anchored to the WHOLE line
 * and describes EXACTLY one record; two records glued by a tear are
 * malformed. Returns 1 if the line is a well-formed record. */
static int tape_line_ok(const char *line) {
    if (!line || !line[0]) return 0;
    if (line[0] == 'V' && line[1] == ' ')       /* V <format> <version> */
        return tape_fields(line + 2) == 2 && !tape_glued(line);
    if (line[0] == 'L' && line[1] == ' ') {
        const char *p = line + 2;
        if (!*p) return 0;
        while (*p) { if (*p < '0' || *p > '9') return 0; p++; }
        return 1;
    }
    if (line[0] == 'S' && line[1] == ' ')       /* S <fn> <depth> <serial> */
        return tape_fields(line + 2) == 3 && !tape_glued(line);
    if ((line[0] == 'A' || line[0] == 'N') && line[1] == ' ') {
        const char *p = line + 2, *eq = p;
        while (*eq && *eq != '=' && *eq != ' ') eq++;
        if (*eq != '=' || eq == p) return 0;
        return tape_value_ok(eq + 1);
    }
    if (strncmp(line, "O cfg ", 6) == 0)
        /* five fields: three floats, window int, scale float */
        return tape_fields(line + 6) == 5;
    if (strncmp(line, "O win ", 6) == 0)
        return tape_fields(line + 6) == 2 && !tape_glued(line);
    return 0;
}

typedef struct {
    int lines, well, malformed, nrec, ocfg, srec;
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
            if (line[0] == 'S' && line[1] == ' ') t.srec++;
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
    int id;
} SinkArg;

static pthread_barrier_t sink_start, sink_round;
static void *sink_worker(void *p) {
    SinkArg *a = (SinkArg *)p;
    cb_slot = a->id;
    EigsState *st = eigs_open();
    if (!st) { a->err = -1; return NULL; }
    /* Distinct thresholds per state, and one mid-run change below: each
     * change makes the NEXT record's emit window stage an `O cfg` in front
     * of its `A`. Together with the function call in `src` (which stages an
     * `S <fn> <depth> <serial>` in front of the callee's first `A`), the
     * run exercises both multi-record windows the one-record-per-call
     * contract has to split. */
    {
        EigsValue *v = eigs_eval_string(a->id == 0
            ? "set_observer_thresholds of [0.002, 0.03, 0.4]"
            : "set_observer_thresholds of [0.003, 0.04, 0.5]");
        if (v) eigs_value_release(v);
    }
    pthread_barrier_wait(&sink_start);
    const char *src = a->id == 0
        ? "define fa(k) as:\n    qa is random of []\n    return qa\n"
          "sa is env_get of \"CONC_LONG\"\nr is fa of [1]\nreturn r"
        : "define fb(k) as:\n    qb is random of []\n    return qb\n"
          "sb is env_get of \"CONC_LONG\"\nr is fb of [1]\nreturn r";
    for (int i = 0; i < SINK_ROUNDS; i++) {
        pthread_barrier_wait(&sink_round);
        if (i == SINK_ROUNDS / 2) {
            EigsValue *c = eigs_eval_string(a->id == 0
                ? "set_observer_thresholds of [0.004, 0.05, 0.6]"
                : "set_observer_thresholds of [0.005, 0.06, 0.7]");
            if (c) eigs_value_release(c);
        }
        cb_gate_pending = 1;
        EigsValue *v = eigs_eval_string(src);
        if (v) { a->ok++; eigs_value_release(v); } else a->err++;
    }
    eigs_close(st);
    return NULL;
}

/* Arming control for cb_gate: with nothing serializing them, two threads
 * that enter the gate together DO see each other. A detector that can only
 * ever report 0 would pass the sink case vacuously. */
static pthread_barrier_t cb_ctl_bar;
static void *cb_gate_ctl(void *p) {
    cb_slot = (int)(long)p;
    cb_gate_pending = 1;
    pthread_barrier_wait(&cb_ctl_bar);
    cb_gate();
    return NULL;
}

static void test_cb_overlap_detector(void) {
    atomic_store(&cb_overlap, 0);
    atomic_store(&cb_gated, 0);
    atomic_store(&cb_gate_on, 1);
    pthread_barrier_init(&cb_ctl_bar, NULL, 2);
    pthread_t t0, t1;
    pthread_create(&t0, NULL, cb_gate_ctl, (void *)0L);
    pthread_create(&t1, NULL, cb_gate_ctl, (void *)1L);
    pthread_join(t0, NULL);
    pthread_join(t1, NULL);
    pthread_barrier_destroy(&cb_ctl_bar);
    atomic_store(&cb_gate_on, 0);
    check(atomic_load(&cb_gated) == 2 && atomic_load(&cb_overlap) == 2,
          "control: the sink-callback overlap detector fires when two "
          "unserialized threads rendezvous");
    printf("        cb-detector control: gated=%ld overlap=%ld\n",
           (long)atomic_load(&cb_gated), (long)atomic_load(&cb_overlap));
    atomic_store(&cb_overlap, 0);
    atomic_store(&cb_gated, 0);
}

/* Count A-record switches between two prefixes. Serial A-then-B is 1
 * switch; real overlap is ≥2 (A→B→A or B→A→B). */
static int tape_a_switches(const char *buf, size_t len,
                           const char *pa, const char *pb) {
    int last = 0, sw = 0;
    size_t i = 0;
    while (i < len) {
        size_t start = i;
        while (i < len && buf[i] != '\n') i++;
        if (i > start && buf[start] == 'A' && buf[start + 1] == ' ') {
            if (strncmp(buf + start, pa, strlen(pa)) == 0) {
                if (last == 2) sw++;
                last = 1;
            } else if (strncmp(buf + start, pb, strlen(pb)) == 0) {
                if (last == 1) sw++;
                last = 2;
            }
        }
        if (i < len && buf[i] == '\n') i++;
    }
    return sw;
}

static void test_two_state_sink(void) {
    char longv[801];
    memset(longv, 'x', 800); longv[800] = 0;
    setenv("CONC_LONG", longv, 1);

    SinkBuf sb;
    sinkbuf_init(&sb);
    eigs_set_trace_sink(sinkbuf_cb, &sb);

    SinkArg a = {0, 0, 0}, b = {0, 0, 1};
    pthread_barrier_init(&sink_start, NULL, 2);
    pthread_barrier_init(&sink_round, NULL, 2);
    atomic_store(&cb_overlap, 0);
    atomic_store(&cb_gated, 0);
    atomic_store(&cb_gate_on, 1);
    pthread_t ta, tb;
    pthread_create(&ta, NULL, sink_worker, &a);
    pthread_create(&tb, NULL, sink_worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    atomic_store(&cb_gate_on, 0);
    pthread_barrier_destroy(&sink_start);
    pthread_barrier_destroy(&sink_round);

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
    /* #1142 contract: ONE complete newline-terminated record per call.
     * Witnesses that the run actually contains the two multi-record emit
     * windows first — an `S` in front of a callee's `A`, and an `O cfg` in
     * front of the first `A` after each of the two threshold changes —
     * otherwise "one record per call" would hold vacuously. */
    check(p.srec > 0, "sink: the run contains scope transitions (S records)");
    check(p.ocfg == 4,
          "sink: the run contains 4 config changes (2 states x 2 changes)");
    check(sb.calls > 0, "sink: the sink callback fired (calls > 0)");
    check(sb.multi_rec == 0,
          "sink: no call carries more than one record");
    check(sb.unterminated == 0,
          "sink: every call ends with a newline");
    check(sb.calls == (long)p.lines,
          "sink: exactly one sink call per tape record");
    /* Control: the same accounting run over a hand-made two-record hand-off
     * MUST come back multi_rec=1 — the counter is armed, not always 0. */
    {
        SinkBuf ctl;
        sinkbuf_init(&ctl);
        sinkbuf_cb("S fa 1 7\nA qa=1\n", 16, &ctl);
        check(ctl.calls == 1 && ctl.multi_rec == 1,
              "control: a two-record hand-off is counted as multi_rec");
        sinkbuf_free(&ctl);
    }
    /* #1142: the flush runs UNDER the tape mutex, so two sink callbacks can
     * never overlap. cb_gate makes that observable on every schedule (the
     * arming control is test_cb_overlap_detector). */
    check(atomic_load(&cb_gated) == SINK_ROUNDS * 2,
          "sink: the overlap detector ran once per round per thread");
    check(atomic_load(&cb_overlap) == 0,
          "sink: sink callbacks never overlap (the flush is under the lock)");
    printf("        sink: calls=%ld multi_rec=%ld unterminated=%ld S=%d "
           "O_cfg=%d\n", sb.calls, sb.multi_rec, sb.unterminated,
           p.srec, p.ocfg);
    printf("        sink: cb_gated=%ld cb_overlap=%ld\n",
           (long)atomic_load(&cb_gated), (long)atomic_load(&cb_overlap));
    {
        /* The kill for sink-flush-outside-lock only exists where the two
         * states' records actually overlap. A run where they never
         * interleave is INCONCLUSIVE, not a pass — name it and go red. */
        int sw = tape_a_switches(sb.buf, sb.len, "A sa=", "A sb=");
        check(sw >= 2, "sink: interleaving observed (no interleaving observed "
                       "= inconclusive run, not a pass)");
        printf("        sink: interleave switches=%d\n", sw);
    }
    /* Control: the anchored grammar calls two glued records malformed. */
    check(!tape_line_ok("A x=1A y=2"),
          "control: glued A records are malformed");
    check(!tape_line_ok("N random=0.5N monotonic_ns=17"),
          "control: glued N records are malformed");
    check(tape_line_ok("A s=\"a b c\"") && tape_line_ok("N f=[1, 2, 3]"),
          "control: a quoted string and a list value stay well-formed");
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

static pthread_barrier_t ocfg_start, ocfg_round;
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
    const char *src = a->id == 0
        ? "oa is 1.0\noa is 2.0\nreturn oa"
        : "ob is 1.0\nob is 2.0\nreturn ob";
    for (int i = 0; i < 50; i++) {
        pthread_barrier_wait(&ocfg_round);
        EigsValue *v = eigs_eval_string(src);
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
    pthread_barrier_init(&ocfg_round, NULL, 2);
    OcfgArg a = {0, 0}, b = {1, 0};
    pthread_t ta, tb;
    pthread_create(&ta, NULL, ocfg_worker, &a);
    pthread_create(&tb, NULL, ocfg_worker, &b);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&ocfg_start);
    pthread_barrier_destroy(&ocfg_round);
    eigs_set_trace_sink(NULL, NULL);

    TapeParse p = parse_tape_buf(sb.buf, sb.len);
    check(a.ok == 50 && b.ok == 50, "O cfg: both states completed every eval");
    check(p.lines > 0, "O cfg: parser examined lines > 0");
    check(p.malformed == 0, "O cfg: no torn records");
    check(p.ocfg == 2, "O cfg per state: exactly one first-record emit per state");
    /* The `O cfg` is staged in the same emit window as the `A` that
     * triggered it, so this case is the config-change half of the
     * one-record-per-call contract. */
    check(sb.calls > 0 && sb.multi_rec == 0 && sb.unterminated == 0,
          "O cfg: one complete newline-terminated record per sink call");
    check(sb.calls == (long)p.lines,
          "O cfg: exactly one sink call per tape record");
    printf("        O cfg: calls=%ld multi_rec=%ld unterminated=%ld lines=%d\n",
           sb.calls, sb.multi_rec, sb.unterminated, p.lines);
    {
        int sw = tape_a_switches(sb.buf, sb.len, "A oa=", "A ob=");
        check(sw >= 2, "O cfg: interleaving observed (no interleaving observed "
                       "= inconclusive run, not a pass)");
        printf("        O cfg: interleave switches=%d\n", sw);
    }
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

typedef struct {
    int started;
    int takes;
    double v[TAKE_N];
} TakeArg;
static pthread_barrier_t take_start, take_round;
static EigsState *take_st = NULL;

/* The take path is drained in ROUNDS, each opened by a barrier both
 * consumers must reach. Inside a round each takes TAKE_PER_ROUND records
 * with NO synchronisation between the two, so their accesses to the
 * replay reader's position are unordered by construction.
 *
 * Why not a free-running loop: with one, run 4 of 10 of the
 * replay-take-unlocked mutant came back `A=400 B=0` — one consumer drained
 * the whole tape before the other was ever scheduled, so there was nothing
 * for TSan to order against and the mutant SURVIVED. A kill that depends on
 * the scheduler is not a kill. The barrier BLOCKS until both consumers are
 * in the same unsynchronised window; the rounds are sized so the two of
 * them consume the tape exactly. */
#define TAKE_PER_ROUND 2
#define TAKE_ROUNDS    (TAKE_N / (2 * TAKE_PER_ROUND))

static void take_drain(TakeArg *a) {
    for (int r = 0; r < TAKE_ROUNDS; r++) {
        pthread_barrier_wait(&take_round);
        for (int k = 0; k < TAKE_PER_ROUND; k++) {
            EigsValue *v = NULL;
            if (!eigs_replay_take("random", &v)) continue;
            if (a->takes < TAKE_N) {
                a->v[a->takes] = v ? eigs_value_as_num(v) : -1.0;
                a->takes++;
            }
            if (v) eigs_value_release(v);
        }
    }
    /* Anything the rounds left (a torn take can lose a record) */
    for (;;) {
        EigsValue *v = NULL;
        if (!eigs_replay_take("random", &v)) break;
        if (a->takes < TAKE_N) {
            a->v[a->takes] = v ? eigs_value_as_num(v) : -1.0;
            a->takes++;
        }
        if (v) eigs_value_release(v);
    }
}

static void *take_worker(void *p) {
    TakeArg *a = (TakeArg *)p;
    if (!eigs_thread_attach(take_st)) return NULL;
    pthread_barrier_wait(&take_start);
    a->started = 1;
    take_drain(a);
    eigs_thread_detach();
    return NULL;
}

static void test_replay_take_serialized(void) {
    /* Distinct N values so the union is a multiset, not a scheduling split.
     * Any A/B split including 0/400 is valid; duplicates or a missing i
     * mean the take path tore. */
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
    size_t tlen = hlen + (size_t)TAKE_N * 32;
    char *tape = malloc(tlen + 1);
    if (!tape) { sinkbuf_free(&hdr); return; }
    memcpy(tape, hdr.buf, hlen);
    size_t off = hlen;
    for (int i = 1; i <= TAKE_N; i++) {
        int n = snprintf(tape + off, tlen - off + 1, "N random=%d\n", i);
        if (n < 0) break;
        off += (size_t)n;
    }
    tlen = off;
    tape[tlen] = '\0';
    sinkbuf_free(&hdr);

    take_st = eigs_open();
    check(take_st != NULL, "replay-take: opener state opened");
    check(eigs_set_replay_tape(tape, tlen, 0) != 0, "replay-take: tape installed");

    TakeArg a = {0}, b = {0};
    pthread_barrier_init(&take_start, NULL, 2);
    pthread_barrier_init(&take_round, NULL, 2);
    pthread_t tb;
    pthread_create(&tb, NULL, take_worker, &b);
    pthread_barrier_wait(&take_start);
    a.started = 1;
    take_drain(&a);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&take_start);
    pthread_barrier_destroy(&take_round);

    int seen[TAKE_N + 1];
    memset(seen, 0, sizeof seen);
    int bad = 0;
    for (int i = 0; i < a.takes; i++) {
        int k = (int)a.v[i];
        if (k < 1 || k > TAKE_N || a.v[i] != (double)k) { bad++; continue; }
        seen[k]++;
    }
    for (int i = 0; i < b.takes; i++) {
        int k = (int)b.v[i];
        if (k < 1 || k > TAKE_N || b.v[i] != (double)k) { bad++; continue; }
        seen[k]++;
    }
    int missing = 0, dup = 0;
    for (int i = 1; i <= TAKE_N; i++) {
        if (seen[i] == 0) missing++;
        if (seen[i] > 1) dup++;
    }
    check(a.started && b.started, "replay take serialized: both consumers ran");
    check(a.takes + b.takes == TAKE_N && missing == 0 && dup == 0 && bad == 0,
          "replay take serialized: union equals the tape multiset");
    printf("        replay-take: A=%d B=%d total=%d (want %d) missing=%d dup=%d bad=%d\n",
           a.takes, b.takes, a.takes + b.takes, TAKE_N, missing, dup, bad);

    eigs_close(take_st);
    take_st = NULL;
    eigs_trace_shutdown();
    free(tape);
}

/* ------------------------------------------------------------------ 9 */
/* #1142: a state that did not open the tape must RAISE on eigs_replay_take. */

static pthread_barrier_t owner_bar;
static char *owner_tape_bytes;
static size_t owner_tape_len;

static void *owner_install_worker(void *p) {
    (void)p;
    EigsState *st = eigs_open();
    if (!st) return NULL;
    eigs_set_replay_tape(owner_tape_bytes, owner_tape_len, 0);
    pthread_barrier_wait(&owner_bar);
    pthread_barrier_wait(&owner_bar);
    eigs_close(st);
    return NULL;
}

static void *owner_taker_worker(void *p) {
    int *raised = (int *)p;
    EigsState *st = eigs_open();
    if (!st) return NULL;
    pthread_barrier_wait(&owner_bar);
    EigsValue *v = NULL;
    int got = eigs_replay_take("random", &v);
    if (v) eigs_value_release(v);
    const char *msg = eigs_last_error_message();
    *raised = (got && eigs_has_error() && msg
               && strstr(msg, "not replayable under EIGS_REPLAY") != NULL);
    eigs_close(st);
    pthread_barrier_wait(&owner_bar);
    return NULL;
}

static void test_owner_state_raises(void) {
    SinkBuf hdr;
    sinkbuf_init(&hdr);
    EigsState *prep = eigs_open();
    eigs_set_trace_sink(sinkbuf_cb, &hdr);
    EigsValue *pv = eigs_eval_string("1");
    if (pv) eigs_value_release(pv);
    eigs_set_trace_sink(NULL, NULL);
    eigs_close(prep);
    char *nl = hdr.buf ? strchr(hdr.buf, '\n') : NULL;
    check(nl != NULL, "owner-state: captured a V header");
    if (!nl) { sinkbuf_free(&hdr); return; }
    size_t hlen = (size_t)(nl - hdr.buf + 1);
    owner_tape_len = hlen + 16;
    owner_tape_bytes = malloc(owner_tape_len + 1);
    memcpy(owner_tape_bytes, hdr.buf, hlen);
    memcpy(owner_tape_bytes + hlen, "N random=1\n", 11);
    owner_tape_len = hlen + 11;
    owner_tape_bytes[owner_tape_len] = '\0';
    sinkbuf_free(&hdr);

    int raised = 0;
    pthread_barrier_init(&owner_bar, NULL, 2);
    pthread_t ta, tb;
    pthread_create(&ta, NULL, owner_install_worker, NULL);
    pthread_create(&tb, NULL, owner_taker_worker, &raised);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&owner_bar);
    check(raised, "owner-state: non-opener take raises");
    eigs_trace_shutdown();
    free(owner_tape_bytes);
    owner_tape_bytes = NULL;
}

/* ------------------------------------------------------------------ 10 */
/* #1142: process owner shuts the tape while a sibling still records. */

static pthread_barrier_t shut_go, shut_mid;
static _Atomic int shut_phase;
static _Atomic long shut_p2_bytes;
static SinkBuf shut_sb;

static void shut_sink_cb(const char *b, size_t n, void *ud) {
    sinkbuf_cb(b, n, ud);
    if (atomic_load(&shut_phase) == 2)
        atomic_fetch_add(&shut_p2_bytes, (long)n);
}

static void *shut_owner(void *p) {
    (void)p;
    EigsState *st = eigs_open();
    if (!st) return NULL;
    pthread_barrier_wait(&shut_go);
    for (int i = 0; i < 20; i++) {
        EigsValue *v = eigs_eval_string("r is random of []\nreturn r");
        if (v) eigs_value_release(v);
    }
    eigs_trace_shutdown();
    atomic_store(&shut_phase, 2);
    pthread_barrier_wait(&shut_mid);
    eigs_close(st);
    return NULL;
}

static void *shut_sib(void *p) {
    int *p2ok = (int *)p;
    EigsState *st = eigs_open();
    if (!st) return NULL;
    pthread_barrier_wait(&shut_go);
    for (int i = 0; i < 20; i++) {
        EigsValue *v = eigs_eval_string("r is random of []\nreturn r");
        if (v) eigs_value_release(v);
    }
    pthread_barrier_wait(&shut_mid);
    for (int i = 0; i < 20; i++) {
        EigsValue *v = eigs_eval_string("r is random of []\nreturn r");
        if (v) { (*p2ok)++; eigs_value_release(v); }
    }
    eigs_close(st);
    return NULL;
}

static void test_shutdown_while_sibling(void) {
    atomic_store(&shut_phase, 1);
    atomic_store(&shut_p2_bytes, 0);
    sinkbuf_init(&shut_sb);
    eigs_set_trace_sink(shut_sink_cb, &shut_sb);
    pthread_barrier_init(&shut_go, NULL, 2);
    pthread_barrier_init(&shut_mid, NULL, 2);
    int p2ok = 0;
    pthread_t ta, tb;
    pthread_create(&ta, NULL, shut_owner, NULL);
    pthread_create(&tb, NULL, shut_sib, &p2ok);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&shut_go);
    pthread_barrier_destroy(&shut_mid);

    check(p2ok == 20, "shutdown-while-sibling: sibling evals after shutdown");
    check(atomic_load(&shut_p2_bytes) == 0,
          "shutdown-while-sibling: sibling records after shutdown are zero");
    check(!(atomic_load(&shut_p2_bytes) > 0 && p2ok == 20),
          "control: leftover sibling bytes would fail the shutdown check");
    printf("        shutdown-while-sibling: p2_ok=%d p2_bytes=%ld\n",
           p2ok, (long)atomic_load(&shut_p2_bytes));
    sinkbuf_free(&shut_sb);
}

/* ------------------------------------------------------------------ 11 */
/* #1143 r3: two states closing at once must not leave the tape open. */

static pthread_barrier_t cc_bar;
static void *cc_worker(void *p) {
    (void)p;
    EigsState *st = eigs_open();
    if (!st) return NULL;
    EigsValue *v = eigs_eval_string("r is 1.0\nreturn r");
    if (v) eigs_value_release(v);
    pthread_barrier_wait(&cc_bar);
    eigs_close(st);
    return NULL;
}

static void test_concurrent_close(void) {
    SinkBuf sb;
    sinkbuf_init(&sb);
    eigs_set_trace_sink(sinkbuf_cb, &sb);
    pthread_barrier_init(&cc_bar, NULL, 2);
    pthread_t ta, tb;
    pthread_create(&ta, NULL, cc_worker, NULL);
    pthread_create(&tb, NULL, cc_worker, NULL);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    pthread_barrier_destroy(&cc_bar);

    size_t after = sb.len;
    check(after > 0, "concurrent-close: the tape was open and recording "
                     "before the two closes");
    EigsState *c = eigs_open();
    check(c != NULL, "concurrent-close: third state opened");
    /* Count the evals: "zero recorded bytes" is vacuous if the third state
     * never actually ran anything. */
    int p3ok = 0;
    for (int i = 0; i < 20; i++) {
        EigsValue *v = eigs_eval_string("z is 1.0\nreturn z");
        if (v) { p3ok++; eigs_value_release(v); }
    }
    if (c) eigs_close(c);
    check(p3ok == 20, "concurrent-close: third state completed every eval");
    check(sb.len == after, "concurrent-close: third state records zero bytes");
    check(!(sb.len > after && p3ok == 20),
          "control: leftover third-state bytes would fail the close check");
    printf("        concurrent-close: after=%zu third_ok=%d third_delta=%ld\n",
           after, p3ok, (long)(sb.len - after));
    eigs_set_trace_sink(NULL, NULL);
    sinkbuf_free(&sb);
}

int main(void) {
    printf("embed concurrent multi-state (#885/#1142/#1143)\n");
    /* EMBED_CONCURRENT_ONLY: the TSan mutant oracle runs just the take
     * case with halt_on_error=1 so a data race exits instead of hanging
     * in an unlocked take that never reaches EOF. */
    const char *only = getenv("EMBED_CONCURRENT_ONLY");
    if (only && strcmp(only, "replay-take") == 0) {
        /* The mutation train's replay-take-unlocked kill is a SANITIZER
         * report, and a sanitizer report is probabilistic: with a single
         * pass the mutant survived 6 of 20 isolated runs on this box even
         * with the barrier-forced overlap in take_drain. A kill that
         * depends on luck is not a kill, so the ONLY-mode the train uses
         * repeats the whole case; the first report halts the process
         * (halt_on_error=1), so a clean build pays for all eight. */
        for (int i = 0; i < 8; i++) test_replay_take_serialized();
    } else if (only && strcmp(only, "shutdown") == 0) {
        test_shutdown_while_sibling();
    } else if (only && strcmp(only, "owner-state") == 0) {
        test_owner_state_raises();
    } else if (only && strcmp(only, "close") == 0) {
        test_concurrent_close();
    } else {
        test_observer_thresholds();
        test_global_isolation();
        test_error_isolation();
        test_planted_fault_is_detectable();
        test_cb_overlap_detector();
        test_two_state_sink();
        test_ocfg_per_state();
        test_close_while_other_runs();
        test_replay_take_serialized();
        test_owner_state_raises();
        test_shutdown_while_sibling();
        test_concurrent_close();
    }

    if (failures) {
        printf("EMBED_CONCURRENT_FAIL: %d check(s) failed\n", failures);
        return 1;
    }
    printf("EMBED_CONCURRENT_OK\n");
    return 0;
}
