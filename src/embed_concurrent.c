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
/* #1142 round 5: trace_out_capacity() — the witness for the sink-only drop
 * in src/trace.c's sink_flush. It is an internal accessor, not an embedding
 * API, so it comes from the internal header rather than eigs_embed.h. */
#include "trace.h"
#include <pthread.h>
#include <stdatomic.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

static int failures = 0;
static int checks_run = 0;

static void check(int ok, const char *what) {
    checks_run++;
    if (ok) {
        printf("  PASS: %s\n", what);
    } else {
        printf("  FAIL: %s\n", what);
        failures++;
    }
}

/* mechanical-gates §121: every enumeration pins `examined == len(table) > 0`.
 * This binary's table is the case list at the bottom of main(), and nothing
 * else pins it: delete a case from that list and its checks go with it, the
 * remaining ones all pass, and the run still prints EMBED_CONCURRENT_OK.
 * (Round 4 shipped with exactly that hole; it is the reason the sink and
 * take cases each carry their own population count.) So the FULL run pins
 * the number of checks that actually ran. Adding or removing a check is then
 * a deliberate edit of this constant — never a silent shrink. The
 * EMBED_CONCURRENT_ONLY modes run one case on purpose and are exempt.
 *
 * If this row goes red, find the case that stopped running BEFORE touching
 * the number: bumping a population pin to clear its own red is how a gate
 * launders the loss it exists to report (mechanical-gates §4, §106). The
 * number only ever moves for a check you just wrote. */
#define EC_EXPECTED_CHECKS 83

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

/* ------------------------------------------------------------------ 12 */
/* #1142 round 5, item 4 — the `atexit(trace_shutdown)` promise, measured.
 *
 * src/trace.c registers that handler inside trace_init, and trace_init has
 * exactly ONE caller in the tree: src/main.c. An embedder never reaches it,
 * so the registration is the CLI's and EIGS_TRACE opens no FILE tape for an
 * embedded host at all. The question the comment used to answer wrongly is
 * therefore: can an EMBEDDER lose a buffered tail by exiting without
 * eigs_close / eigs_trace_shutdown?
 *
 * It cannot, because sink_flush hands every record over inside
 * tape_emit_end — under the tape lock, before the emitting call returns —
 * so a sink embedder has no tail. This case MEASURES that instead of
 * asserting it: two forked children run the identical program through the
 * identical sink, one tearing down properly and one falling out of main(),
 * and their byte streams must be identical.
 *
 * Runs FIRST, before any thread is created: fork() in a process with live
 * sibling threads can inherit a held lock. */

#define TAIL_PROG \
    "i is 0\n" \
    "loop while i < 40:\n" \
    "    q is i * 2\n" \
    "    r is q + 1\n" \
    "    i is i + 1\n" \
    "return i\n"

static int tail_fd = -1;

static void tail_sink_cb(const char *b, size_t n, void *ud) {
    (void)ud;
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(tail_fd, b + off, n - off);
        if (w <= 0) return;
        off += (size_t)w;
    }
}

/* Child: emit TAIL_PROG through a pipe-backed sink. close_first == 1 tears
 * the state and the tape down the documented way; 0 falls straight out of
 * main() the way a host that forgot to (or could not) clean up does. */
static void tail_child(int fd, int close_first) {
    tail_fd = fd;
    EigsState *st = eigs_open();
    if (!st) _exit(2);
    eigs_set_trace_sink(tail_sink_cb, NULL);
    EigsValue *v = eigs_eval_string(TAIL_PROG);
    if (v) eigs_value_release(v);
    if (close_first) {
        eigs_close(st);
        eigs_trace_shutdown();
    }
    exit(0);            /* deliberately exit(), not _exit() */
}

/* Run one child and read its whole stream. Returns the byte count, or -1. */
static long tail_run(int close_first, char **out) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    fflush(stdout);     /* the child inherits this buffer and exit()s */
    pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); return -1; }
    if (pid == 0) {
        close(fds[0]);
        tail_child(fds[1], close_first);
        _exit(3);       /* unreachable */
    }
    close(fds[1]);
    size_t cap = 65536, len = 0;
    char *buf = malloc(cap);
    if (!buf) { close(fds[0]); return -1; }
    for (;;) {
        if (len + 4096 > cap) {
            char *nb = realloc(buf, cap * 2);
            if (!nb) break;
            buf = nb; cap *= 2;
        }
        ssize_t r = read(fds[0], buf + len, 4096);
        if (r <= 0) break;
        len += (size_t)r;
    }
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) { free(buf); return -2; }
    *out = buf;
    return (long)len;
}

/* The comparator the case asserts on, so the control below can drive the
 * REAL one instead of a re-implementation of it (mechanical-gates §99). */
static int tail_streams_identical(const char *a, long na,
                                  const char *b, long nb) {
    return na == nb && na > 0 && memcmp(a, b, (size_t)na) == 0;
}

static void test_exit_tail_not_lost(void) {
    char *closed = NULL, *leaked = NULL;
    long nc = tail_run(1, &closed);
    long nl = tail_run(0, &leaked);
    check(nc > 0, "exit-tail: the closing child's sink received bytes");
    check(nl > 0, "exit-tail: the exiting child's sink received bytes");
    if (nc > 0 && nl > 0) {
        /* The population: a run that emitted three records would satisfy
         * "identical" while measuring nothing about a tail. */
        TapeParse p = parse_tape_buf(closed, (size_t)nc);
        check(p.lines >= 100 && p.malformed == 0,
              "exit-tail: the measured program emits a real tape "
              "(>=100 well-formed records)");
        check(tail_streams_identical(closed, nc, leaked, nl),
              "exit-tail: a sink embedder that exits without eigs_close "
              "loses NOTHING (byte-identical streams)");
        printf("        exit-tail: closed=%ld bytes leaked=%ld bytes "
               "records=%d malformed=%d\n", nc, nl, p.lines, p.malformed);
        /* Control: the SAME comparator, fed a stream one byte short, must
         * say "different" — otherwise the row above is an equality that
         * cannot fail (mechanical-gates §101). */
        check(!tail_streams_identical(closed, nc, closed, nc - 1),
              "control: the identity comparator rejects a stream one byte "
              "short");
    }
    free(closed);
    free(leaked);
}

/* ------------------------------------------------------------------ 13 */
/* #1142 round 5, item 2 — the sink-only DROP has a witness.
 *
 * src/trace.c's sink_flush ends a sink-only record with
 * `if (!g_trace_fp) g_out_len = g_rec_at;`. That one line is what keeps a
 * freestanding sink-only embedder (EigenOS M11's journal — no filesystem,
 * nothing to spill to) from growing its staging buffer WITH THE TAPE.
 * Deleting it survives every other oracle in this tree: each record is
 * still whole, each byte still reaches the sink, the tape still replays.
 * Only the memory moves (critic measurement: +14,092 KB of RSS over 14.3 MB
 * of sink bytes, against 136 KB on this tree).
 *
 * So the witness is the buffer itself, through trace_out_capacity().
 *
 * ORDERING: this case must run before any other tape record in the process,
 * because its arming control is `capacity == 0 before, > 0 after`. If some
 * earlier case opened a tape the first row goes red — honestly, and naming
 * the reason. (trace_shutdown frees the buffer and resets the capacity to 0,
 * so "0" really does mean "no tape has been open".) */

#define SOB_VAL_BYTES 30000
#define SOB_ITERS     400
#define SOB_TARGET    (10u * 1024u * 1024u)

typedef struct { unsigned long bytes; long calls; size_t max_rec; } SobSink;

static void sob_cb(const char *b, size_t n, void *ud) {
    SobSink *s = (SobSink *)ud;
    (void)b;
    s->bytes += n;
    s->calls++;
    if (n > s->max_rec) s->max_rec = n;
}

static void test_sink_only_buffer_bounded(void) {
    char *big = malloc(SOB_VAL_BYTES + 1);
    if (!big) { check(0, "sink-only-bounded: allocation"); return; }
    memset(big, 'x', SOB_VAL_BYTES);
    big[SOB_VAL_BYTES] = '\0';
    setenv("CONC_SINK_BIG", big, 1);

    size_t cap0 = trace_out_capacity();
    check(cap0 == 0,
          "sink-only-bounded: no tape buffer exists before the first record "
          "(this case runs before every other tape case)");

    SobSink s;
    memset(&s, 0, sizeof s);
    EigsState *st = eigs_open();
    check(st != NULL, "sink-only-bounded: state opened");
    eigs_set_trace_sink(sob_cb, &s);

    /* Warm-up: ONE iteration, which stages the largest record shape the
     * loop below will ever stage (a ~30 KB `N env_get=` record). After this
     * the capacity is whatever that shape needs, and the claim under test is
     * that 10 MB more of the same changes it by zero. */
    {
        EigsValue *v = eigs_eval_string(
            "w is env_get of \"CONC_SINK_BIG\"\nreturn 1");
        if (v) eigs_value_release(v);
    }
    size_t cap1 = trace_out_capacity();
    unsigned long warm_bytes = s.bytes;
    /* Arming control (mechanical-gates §101): the instrument MOVES. A
     * capacity reader stuck at a constant would pass the bound below having
     * measured nothing. */
    check(cap1 > cap0 && cap1 > 0,
          "control: the capacity accessor moves when a record is staged "
          "(0 -> cap)");

    char src[256];
    snprintf(src, sizeof src,
             "i is 0\n"
             "loop while i < %d:\n"
             "    s is env_get of \"CONC_SINK_BIG\"\n"
             "    i is i + 1\n"
             "return i\n", SOB_ITERS);
    EigsValue *v = eigs_eval_string(src);
    int ran = v && (int)eigs_value_as_num(v) == SOB_ITERS;
    if (v) eigs_value_release(v);
    size_t cap2 = trace_out_capacity();

    eigs_set_trace_sink(NULL, NULL);
    if (st) eigs_close(st);

    check(ran, "sink-only-bounded: the emitting program completed every "
               "iteration");
    /* Population pin (§121): the bound is a claim about >= 10 MB of tape.
     * A run that emitted 3 KB would satisfy `cap2 == cap1` for free. */
    check(s.bytes - warm_bytes >= SOB_TARGET,
          "sink-only-bounded: the run pushed >= 10 MB of sink bytes");
    check(s.calls > 0 && s.max_rec >= SOB_VAL_BYTES,
          "sink-only-bounded: the stream really carries ~30 KB records");
    check(cap2 == cap1,
          "sink-only-bounded: the tape staging buffer does not grow with "
          "the tape (sink-only records are dropped after hand-off)");
    printf("        sink-only-bounded: cap0=%zu cap1=%zu cap2=%zu "
           "sink_bytes=%lu calls=%ld max_rec=%zu\n",
           cap0, cap1, cap2, s.bytes, s.calls, s.max_rec);

    unsetenv("CONC_SINK_BIG");
    free(big);
}

/* ------------------------------------------------------------------ 14 */
/* #1142 round 5, item 3 — trace_set_sink emits the V header UNDER the tape
 * lock, and a sibling state recording at the same time cannot get between
 * the sink becoming visible and the header reaching it.
 *
 * Both halves are structural on the correct build, so both are measured
 * structurally rather than by hoping a window tears:
 *
 *   - `pre_v == 0`: the sink pointer and its ud are published in the same
 *     critical section that commits the V record, so the FIRST call a fresh
 *     sink context ever receives is its own header. Each round installs a
 *     FRESH context, so this is not diluted by the previous install's
 *     stream.
 *   - `hdr_overlap == 0`: the header callback fires with the tape mutex
 *     held, so while it is running the sibling cannot be inside a callback
 *     of its own. The header callback holds a bounded window and watches for
 *     the sibling's flag; on the mutant (header emitted after tape_unlock)
 *     the sibling is free to record throughout that window and is seen.
 *
 * test_hdr_overlap_detector is the arming control for the second. */

#define HDR_ROUNDS 24
#define HDR_WIN_US 2000
#define HDR_SIB_US 300

typedef struct {
    long calls, v_calls, non_v, pre_v, malformed;
    int  first_is_v;
    pthread_mutex_t mu;
} HdrCtx;

static HdrCtx hdr_ctx[HDR_ROUNDS + 1];
static _Atomic int  hdr_gate_on = 0;
static _Atomic int  hdr_sib_in = 0;
static _Atomic int  hdr_sib_run = 1;
static _Atomic long hdr_gated = 0, hdr_overlap = 0, hdr_sib_evals = 0;
static __thread int hdr_is_installer = 0;
static __thread int hdr_sib_pending = 0;

static void hdr_count(HdrCtx *c, const char *b, size_t n, int is_v) {
    pthread_mutex_lock(&c->mu);
    c->calls++;
    if (is_v) {
        if (c->calls == 1) c->first_is_v = 1;
        c->v_calls++;
    } else {
        c->non_v++;
        if (c->v_calls == 0) c->pre_v++;
    }
    if (n == 0 || b[n - 1] != '\n') c->malformed++;
    else {
        char line[8192];
        size_t m = n - 1;
        if (m >= sizeof line) m = sizeof line - 1;
        memcpy(line, b, m);
        line[m] = '\0';
        if (!tape_line_ok(line)) c->malformed++;
    }
    pthread_mutex_unlock(&c->mu);
}

static void hdr_cb(const char *b, size_t n, void *ud) {
    HdrCtx *c = (HdrCtx *)ud;
    int is_v = (n >= 2 && b[0] == 'V' && b[1] == ' ');
    if (atomic_load(&hdr_gate_on)) {
        if (hdr_is_installer) {
            if (is_v) {
                atomic_fetch_add(&hdr_gated, 1);
                int seen = 0;
                for (int i = 0; i < HDR_WIN_US / 50; i++) {
                    if (atomic_load(&hdr_sib_in)) seen = 1;
                    usleep(50);
                }
                if (seen) atomic_fetch_add(&hdr_overlap, 1);
            }
        } else if (hdr_sib_pending) {
            /* One gated callback per sibling eval: the sibling has to be
             * inside a callback for a MEASURABLE fraction of the header's
             * window, not for every record it writes. */
            hdr_sib_pending = 0;
            atomic_store(&hdr_sib_in, 1);
            for (int i = 0; i < HDR_SIB_US / 50; i++) usleep(50);
            atomic_store(&hdr_sib_in, 0);
        }
    }
    hdr_count(c, b, n, is_v);
}

static void *hdr_sib_worker(void *p) {
    (void)p;
    EigsState *st = eigs_open();
    if (!st) return NULL;
    while (atomic_load(&hdr_sib_run)) {
        hdr_sib_pending = 1;
        EigsValue *v = eigs_eval_string("hs is 1\nreturn hs");
        if (v) { eigs_value_release(v); atomic_fetch_add(&hdr_sib_evals, 1); }
    }
    eigs_close(st);
    return NULL;
}

/* Arming control: with nothing serializing them, a thread inside the
 * sibling window IS seen by the header watcher. */
static void *hdr_ctl_holder(void *p) {
    (void)p;
    atomic_store(&hdr_sib_in, 1);
    for (int i = 0; i < HDR_WIN_US / 50; i++) usleep(50);
    atomic_store(&hdr_sib_in, 0);
    return NULL;
}

static void test_hdr_overlap_detector(void) {
    atomic_store(&hdr_gated, 0);
    atomic_store(&hdr_overlap, 0);
    atomic_store(&hdr_sib_in, 0);
    pthread_t h;
    pthread_create(&h, NULL, hdr_ctl_holder, NULL);
    /* Drive the header watcher's own code by hand, with the tape nowhere in
     * the picture: this is the operation the correct build serializes and
     * the mutant does not. */
    atomic_fetch_add(&hdr_gated, 1);
    int seen = 0;
    for (int i = 0; i < HDR_WIN_US / 50; i++) {
        if (atomic_load(&hdr_sib_in)) seen = 1;
        usleep(50);
    }
    if (seen) atomic_fetch_add(&hdr_overlap, 1);
    pthread_join(h, NULL);
    check(atomic_load(&hdr_gated) == 1 && atomic_load(&hdr_overlap) == 1,
          "control: the header-overlap detector fires when an unserialized "
          "thread records inside the window");
    printf("        hdr-detector control: gated=%ld overlap=%ld\n",
           (long)atomic_load(&hdr_gated), (long)atomic_load(&hdr_overlap));
    atomic_store(&hdr_gated, 0);
    atomic_store(&hdr_overlap, 0);
}

static void test_set_sink_header_atomic(void) {
    for (int i = 0; i <= HDR_ROUNDS; i++) {
        memset(&hdr_ctx[i], 0, sizeof hdr_ctx[i]);
        pthread_mutex_init(&hdr_ctx[i].mu, NULL);
    }
    hdr_is_installer = 1;
    atomic_store(&hdr_gate_on, 0);
    atomic_store(&hdr_gated, 0);
    atomic_store(&hdr_overlap, 0);
    atomic_store(&hdr_sib_evals, 0);
    atomic_store(&hdr_sib_run, 1);

    /* Round 0 installs with no sibling running; the gate is off for it. */
    eigs_set_trace_sink(hdr_cb, &hdr_ctx[0]);
    pthread_t sib;
    pthread_create(&sib, NULL, hdr_sib_worker, NULL);
    /* Wait for the sibling to be actually recording before arming. */
    for (int i = 0; i < 2000 && atomic_load(&hdr_sib_evals) < 2; i++)
        usleep(500);
    int sib_live = atomic_load(&hdr_sib_evals) >= 2;
    atomic_store(&hdr_gate_on, 1);

    for (int r = 1; r <= HDR_ROUNDS; r++) {
        eigs_set_trace_sink(hdr_cb, &hdr_ctx[r]);
        usleep(1000);       /* let the sibling stream into this context */
    }

    atomic_store(&hdr_gate_on, 0);
    atomic_store(&hdr_sib_run, 0);
    pthread_join(sib, NULL);
    eigs_set_trace_sink(NULL, NULL);

    long tot_calls = 0, tot_non_v = 0, bad_v = 0, bad_pre = 0, bad_first = 0,
         mal = 0;
    for (int r = 1; r <= HDR_ROUNDS; r++) {
        tot_calls += hdr_ctx[r].calls;
        tot_non_v += hdr_ctx[r].non_v;
        if (hdr_ctx[r].v_calls != 1) bad_v++;
        if (hdr_ctx[r].pre_v != 0) bad_pre++;
        if (!hdr_ctx[r].first_is_v) bad_first++;
        mal += hdr_ctx[r].malformed;
    }

    check(sib_live, "set-sink-header: the sibling state was recording before "
                    "the gate armed");
    /* §121: every round must have been examined. */
    check(tot_calls > 0 && atomic_load(&hdr_gated) == HDR_ROUNDS,
          "set-sink-header: every install emitted exactly one gated header "
          "(examined == rounds)");
    check(bad_v == 0,
          "set-sink-header: each install's sink sees exactly one V record");
    check(bad_first == 0 && bad_pre == 0,
          "set-sink-header: the header is the FIRST record a freshly "
          "installed sink receives (no sibling record precedes it)");
    check(mal == 0, "set-sink-header: every collected line is well-formed");
    /* Non-vacuity: the sibling really did write into these contexts, so
     * "no record precedes the header" is a fact about a contended tape and
     * not about an idle one. */
    check(tot_non_v >= HDR_ROUNDS,
          "set-sink-header: the sibling streamed records into the installed "
          "sinks (>= 1 per round)");
    check(atomic_load(&hdr_overlap) == 0,
          "set-sink-header: no sibling record overlaps the header emission "
          "(the header is emitted under the tape lock)");
    printf("        set-sink-header: rounds=%d gated=%ld overlap=%ld "
           "calls=%ld non_v=%ld sib_evals=%ld malformed=%ld\n",
           HDR_ROUNDS, (long)atomic_load(&hdr_gated),
           (long)atomic_load(&hdr_overlap), tot_calls, tot_non_v,
           (long)atomic_load(&hdr_sib_evals), mal);
    /* Control: the pre_v accounting arms — a non-V record delivered before
     * any header IS counted. */
    {
        HdrCtx ctl;
        memset(&ctl, 0, sizeof ctl);
        pthread_mutex_init(&ctl.mu, NULL);
        hdr_count(&ctl, "A x=1\n", 6, 0);
        check(ctl.pre_v == 1 && ctl.first_is_v == 0,
              "control: a record delivered before the header is counted as "
              "pre_v");
        pthread_mutex_destroy(&ctl.mu);
    }
    hdr_is_installer = 0;
    for (int i = 0; i <= HDR_ROUNDS; i++) pthread_mutex_destroy(&hdr_ctx[i].mu);
}

/* ------------------------------------------------------------------ 15 */
/* #1142 round 5, item 1 — eigs_replay_take runs UNDER the tape lock, gated
 * structurally.
 *
 * Until this round the `replay-take-unlocked` mutant was killed by a
 * ThreadSanitizer report, and a sanitizer report is a probabilistic kill: a
 * critic measured it surviving 1 of 10 train runs. The property itself is
 * not probabilistic — the take holds the same mutex the emit path holds —
 * so measure the property.
 *
 * The sink callback fires with the tape lock held. So: one thread emits a
 * record whose callback BLOCKS for a bounded window; the other thread waits
 * to observe that the callback has been entered and then attempts a take.
 *
 *   - take under the lock (correct): the take CANNOT complete until the
 *     callback returns and tape_emit_end unlocks, so the callback flag is
 *     always already down when the take returns. 0 overlaps, on any
 *     schedule, deterministically.
 *   - take unlocked (mutant): the take completes in microseconds, deep
 *     inside a 2 ms window, so the flag is still up. Overlaps on every
 *     attempt.
 *
 * The take latency is printed, never asserted: a wall-clock budget is a
 * claim about the machine, not about the mechanism (mechanical-gates §120).
 * The ORDER of the two events is the witness. */

#define TL_ROUNDS  80
#define TL_WIN_US  2000
#define TL_TAPE_N  200

static _Atomic int  tl_gate_on = 0;
static _Atomic int  tl_cb_in = 0;
static _Atomic long tl_cb_fired = 0, tl_gated = 0, tl_overlap = 0,
                    tl_served = 0, tl_missed = 0;
static __thread int tl_is_emitter = 0;
static __thread int tl_cb_pending = 0;
static pthread_barrier_t tl_round;
static _Atomic long tl_lat_us_total = 0;

static void tl_hold_window(void) {
    atomic_store(&tl_cb_in, 1);
    for (int i = 0; i < TL_WIN_US / 50; i++) usleep(50);
    atomic_store(&tl_cb_in, 0);
}

static void tl_sink_cb(const char *b, size_t n, void *ud) {
    (void)b; (void)n; (void)ud;
    if (!atomic_load(&tl_gate_on) || !tl_is_emitter || !tl_cb_pending) return;
    tl_cb_pending = 0;
    atomic_fetch_add(&tl_cb_fired, 1);
    tl_hold_window();
}

static void *tl_emitter(void *p) {
    (void)p;
    tl_is_emitter = 1;
    EigsState *st = eigs_open();
    if (!st) return NULL;
    for (int r = 0; r < TL_ROUNDS; r++) {
        pthread_barrier_wait(&tl_round);
        tl_cb_pending = 1;
        EigsValue *v = eigs_eval_string("tx is 1\nreturn tx");
        if (v) eigs_value_release(v);
    }
    eigs_close(st);
    return NULL;
}

/* One gated attempt. Waits (bounded) for the emitter to be inside its
 * callback, then takes and reports whether the callback was STILL inside
 * when the take returned. */
static void tl_attempt(void) {
    int saw = 0;
    for (int i = 0; i < 200000 && !saw; i++) {
        if (atomic_load(&tl_cb_in)) saw = 1;
        else usleep(10);
    }
    if (!saw) { atomic_fetch_add(&tl_missed, 1); return; }
    atomic_fetch_add(&tl_gated, 1);
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    EigsValue *v = NULL;
    int got = eigs_replay_take("random", &v);
    int still = atomic_load(&tl_cb_in);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (still) atomic_fetch_add(&tl_overlap, 1);
    if (got) {
        atomic_fetch_add(&tl_served, 1);
        if (v) eigs_value_release(v);
    }
    atomic_fetch_add(&tl_lat_us_total,
                     (long)((t1.tv_sec - t0.tv_sec) * 1000000L
                            + (t1.tv_nsec - t0.tv_nsec) / 1000L));
}

/* Arming control: the same counters, the same flag, and an operation known
 * NOT to be serialized against the window. If this reads 0 the detector
 * cannot report an overlap at all and the case below is decoration. */
static void *tl_ctl_holder(void *p) { (void)p; tl_hold_window(); return NULL; }

static void test_take_overlap_detector(void) {
    atomic_store(&tl_gated, 0);
    atomic_store(&tl_overlap, 0);
    atomic_store(&tl_cb_in, 0);
    pthread_t h;
    pthread_create(&h, NULL, tl_ctl_holder, NULL);
    int saw = 0;
    for (int i = 0; i < 200000 && !saw; i++) {
        if (atomic_load(&tl_cb_in)) saw = 1;
        else usleep(10);
    }
    if (saw) {
        atomic_fetch_add(&tl_gated, 1);
        sched_yield();                     /* takes no tape mutex */
        if (atomic_load(&tl_cb_in)) atomic_fetch_add(&tl_overlap, 1);
    }
    pthread_join(h, NULL);
    check(atomic_load(&tl_gated) == 1 && atomic_load(&tl_overlap) == 1,
          "control: the take-overlap detector fires for an operation that "
          "does NOT take the tape mutex");
    printf("        take-detector control: gated=%ld overlap=%ld\n",
           (long)atomic_load(&tl_gated), (long)atomic_load(&tl_overlap));
    atomic_store(&tl_gated, 0);
    atomic_store(&tl_overlap, 0);
}

static void test_replay_take_under_lock(void) {
    /* A tape this binary will accept: capture its own V header first. */
    SinkBuf hdr;
    sinkbuf_init(&hdr);
    EigsState *prep = eigs_open();
    eigs_set_trace_sink(sinkbuf_cb, &hdr);
    EigsValue *pv = eigs_eval_string("1");
    if (pv) eigs_value_release(pv);
    eigs_set_trace_sink(NULL, NULL);
    if (prep) eigs_close(prep);
    char *nl = hdr.buf ? strchr(hdr.buf, '\n') : NULL;
    check(nl != NULL, "replay-take-lock: captured a V header");
    if (!nl) { sinkbuf_free(&hdr); return; }
    size_t hlen = (size_t)(nl - hdr.buf + 1);
    size_t tcap = hlen + (size_t)TL_TAPE_N * 32;
    char *tape = malloc(tcap + 1);
    if (!tape) { sinkbuf_free(&hdr); return; }
    memcpy(tape, hdr.buf, hlen);
    size_t off = hlen;
    for (int i = 1; i <= TL_TAPE_N; i++)
        off += (size_t)snprintf(tape + off, tcap - off + 1, "N random=%d\n", i);
    tape[off] = '\0';
    sinkbuf_free(&hdr);

    atomic_store(&tl_cb_fired, 0);
    atomic_store(&tl_gated, 0);
    atomic_store(&tl_overlap, 0);
    atomic_store(&tl_served, 0);
    atomic_store(&tl_missed, 0);
    atomic_store(&tl_lat_us_total, 0);
    atomic_store(&tl_cb_in, 0);

    EigsState *owner = eigs_open();
    check(owner != NULL, "replay-take-lock: owner state opened");
    check(eigs_set_replay_tape(tape, off, 0) != 0,
          "replay-take-lock: tape installed");
    eigs_set_trace_sink(tl_sink_cb, NULL);

    pthread_barrier_init(&tl_round, NULL, 2);
    atomic_store(&tl_gate_on, 1);
    pthread_t em;
    pthread_create(&em, NULL, tl_emitter, NULL);
    for (int r = 0; r < TL_ROUNDS; r++) {
        pthread_barrier_wait(&tl_round);
        tl_attempt();
    }
    pthread_join(em, NULL);
    atomic_store(&tl_gate_on, 0);
    pthread_barrier_destroy(&tl_round);
    eigs_set_trace_sink(NULL, NULL);

    long gated = atomic_load(&tl_gated), served = atomic_load(&tl_served);
    /* §121 population pins: every round produced a gated attempt, and every
     * attempt was served a record. A take that returned 0 immediately, or a
     * round where the emitter never entered its callback, would make the
     * overlap count 0 for reasons that have nothing to do with the lock. */
    check(atomic_load(&tl_cb_fired) == TL_ROUNDS && atomic_load(&tl_missed) == 0,
          "replay-take-lock: the emitter entered its sink callback in every "
          "round (examined == rounds)");
    check(gated == TL_ROUNDS,
          "replay-take-lock: every round produced a gated take attempt");
    check(served == TL_ROUNDS,
          "replay-take-lock: every gated take was served a tape record");
    check(atomic_load(&tl_overlap) == 0,
          "replay-take-lock: no take completes while a sink callback is "
          "running (the take holds the tape mutex)");
    printf("        replay-take-lock: rounds=%d cb_fired=%ld gated=%ld "
           "served=%ld overlap=%ld missed=%ld mean_take_us=%ld\n",
           TL_ROUNDS, (long)atomic_load(&tl_cb_fired), gated, served,
           (long)atomic_load(&tl_overlap), (long)atomic_load(&tl_missed),
           gated ? (long)atomic_load(&tl_lat_us_total) / gated : -1L);

    if (owner) eigs_close(owner);
    eigs_trace_shutdown();
    free(tape);
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
    } else if (only && strcmp(only, "sink-only") == 0) {
        test_sink_only_buffer_bounded();
    } else {
        /* ORDER IS LOAD-BEARING at the top. test_exit_tail_not_lost forks,
         * so it runs before any thread exists; test_sink_only_buffer_bounded
         * reads the tape staging buffer's capacity BEFORE any tape has been
         * open (its arming control is 0 -> nonzero), so it runs before any
         * case that installs a sink. */
        test_exit_tail_not_lost();
        test_sink_only_buffer_bounded();
        test_observer_thresholds();
        test_global_isolation();
        test_error_isolation();
        test_planted_fault_is_detectable();
        test_cb_overlap_detector();
        test_two_state_sink();
        test_ocfg_per_state();
        test_hdr_overlap_detector();
        test_set_sink_header_atomic();
        test_close_while_other_runs();
        test_replay_take_serialized();
        test_take_overlap_detector();
        test_replay_take_under_lock();
        test_owner_state_raises();
        test_shutdown_while_sibling();
        test_concurrent_close();
        if (checks_run != EC_EXPECTED_CHECKS) {
            printf("  FAIL: check population: %d checks ran, expected %d "
                   "(a case was added, removed, or returned early — update "
                   "EC_EXPECTED_CHECKS deliberately)\n",
                   checks_run, EC_EXPECTED_CHECKS);
            failures++;
        } else {
            printf("  PASS: check population: %d checks ran (== "
                   "EC_EXPECTED_CHECKS)\n", checks_run);
        }
    }

    if (failures) {
        printf("EMBED_CONCURRENT_FAIL: %d check(s) failed\n", failures);
        return 1;
    }
    printf("EMBED_CONCURRENT_OK\n");
    return 0;
}
