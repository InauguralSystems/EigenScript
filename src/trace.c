/* ================================================================
 * EigenScript Trace — implementation (Phase 1 + 2).
 * ================================================================
 * Tape format (text, one record per line):
 *   V <format> <runtime-ver>    version header — always the first record
 *   B <stream> <lifetime> <state> <spawn-base> <origin>
 *                               host/causal correspondence metadata (v5)
 *   L <stream> <line>           source-line event
 *   A <stream> <name>=<value>   name-keyed assignment delta
 *   N <stream> <fn>=<value>     nondeterministic builtin return
 *   O <stream> cfg <dh_zero> <dh_small> <h_low> <window> <scale>
 *                               observer configuration in force (v3)
 *   O <stream> win <name> <n>   per-binding observer window override (v3)
 *
 * Value encoding:
 *   <num>          numeric (immediate, tracked, or heap VAL_NUM)
 *   null           VAL_NULL / immediate null slot
 *   true|false
 *   "<str…>"       heap string, content truncated at TRACE_STR_MAX
 *   <list:N>       heap list of length N (content in Phase 2.5)
 *   <dict:N>       heap dict of size N
 *   <fn>           heap function/builtin
 *   <buffer:N>     heap buffer of length N
 *   <heap>         other heap types (fallback)
 *
 * Phase 2 also dedupes adjacent identical L events that have no A/N
 * between them — the compiler emits per-statement LINEs and bare
 * repeats are pure noise. An A or N event resets the dirty bit so the
 * next L always fires after progress was made.
 */

#include "eigenscript.h"
#include "env_flag.h"
#include "trace.h"
#include "vm.h"   /* #539 v2: CallFrame/g_vm for scope-transition S records */

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Runtime version stamped into the tape header (#411). The Makefile
 * injects the real value; embed/freestanding builds without it share
 * "dev" — so version equality is necessary, not sufficient, and dev
 * builds are on their honor (documented in docs/TRACE.md). */
#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

#define TRACE_STR_MAX     60       /* truncate strings in `A` events */
#define TRACE_NONDET_MAX  65536    /* per-record cap for `N` events;
                                    * over-cap payloads emit a marker so
                                    * tape stays sized for visual debug */

int g_trace_enabled_storage = 0;
int g_replay_enabled_storage = 0;
int g_trace_obs_hist_storage = 0;
int g_trace_hist_storage = 0;
/* Calls without an attached state are limited to standalone tooling. Runtime
 * and linked native/AOT callers use their attached EigsThread field. */
static int g_trace_current_line_unattached = 0;
int *trace_current_line_addr(void) {
    return eigs_current ? &eigs_current->trace_current_line
                        : &g_trace_current_line_unattached;
}

/* ----- Phase 3.0a: prev-value table.
 *
 * Open-addressing hash table keyed by interned name pointer. Each entry
 * holds the slot most recently assigned to that name (`current`) and
 * the one immediately before it (`prev`). `prev of x` reads `prev`.
 *
 * Refcount discipline: stored heap/tracked slots are incref'd on store
 * and decref'd on displacement or shutdown. Immediate slots (number,
 * null, bool) are no-ops for slot_incref/decref, so the same code path
 * is correct for every Value shape.
 *
 * The table runs unconditionally — `prev of x` must work whether or
 * not EIGS_TRACE is set, because it's a language-level interrogative,
 * not a debug-tape feature. Per-assign cost is ~one cache line read +
 * a pointer-equality compare. */

/* ----- #827: the history is REACHABILITY-PRUNED, not append-only.
 *
 * Every backward query (`what/prev is x at L`, `state_at of L`) answers with
 * the LATEST assignment whose line stamp is <= L — a temporal-backward walk,
 * not "the greatest line <= L". That is the whole contract, and it makes most
 * recorded entries provably unreachable:
 *
 *   entry i is dead  <=>  exists j > i with line[j] <= line[i]
 *
 * because any L that admits i (line[i] <= L) also admits the later j, and j
 * wins for being later. The surviving entries are exactly the strict suffix
 * minima of the line sequence, so read left-to-right their lines are STRICTLY
 * INCREASING — and therefore the live history for one name can never exceed
 * the number of distinct source lines that assign it. Bounded by program TEXT,
 * independent of how long the program runs.
 *
 * Maintenance is one pop-while at append: a new entry stamped `line` kills
 * exactly the trailing live entries whose line is >= it. Nothing that could
 * ever have been an answer is dropped, so NO query changes its answer — the
 * two facts the raw array carried that pruning would otherwise lose are kept
 * explicitly:
 *
 *   - `prev of x at L` wants the value of the assignment immediately
 *     preceding (in EXECUTION order) the one that answers L. That predecessor
 *     is usually a pruned entry, so each live entry carries its own
 *     `prev_value` — captured at append time, exact regardless of pruning.
 *   - `when is x at L` wants the COUNT of assignments with line <= L, which
 *     depends on the pruned entries too. Counting is order-independent, so a
 *     per-name (line -> count) histogram carries it exactly. Its size is also
 *     bounded by the number of distinct assigning lines.
 *
 * The observer snapshot (`where/why/how is x at L`) rides inside the live
 * entry: it is patched onto the most recent entry by trace_record_obs, which
 * always targets a live one (the newest entry is always live).
 *
 * Because the live array is sorted by line, the backward walk is a binary
 * search — which replaced the old periodic line-floor segment index (that
 * index existed only to make scanning an unbounded array survivable). */
typedef struct {
    int      line;
    EigsSlot value;
    EigsSlot prev_value;      /* value of the immediately preceding assign */
    uint8_t  has_prev_value;
    /* Observer-state snapshot, captured only while g_trace_obs_hist is set.
     * obs_valid == 0 marks assigns whose slot had no observer state
     * (untracked immediates, e.g. writes inside `unobserved` blocks) and
     * every entry recorded before the flag flipped on mid-run (eval/REPL
     * compiling a historical observer query). */
    uint8_t  obs_valid;
    double   entropy;
    double   dH;
    double   last_entropy;
} HistoryEntry;

/* (line -> assignment count) histogram, kept sorted by line so `when is x
 * at L` is an exact sum over a bounded array. `count` is 64-bit: a hot loop
 * can genuinely assign one line more than 2^31 times. */
typedef struct {
    int       line;
    long long count;
} LineCount;

/* #868: one recorded assignment, addressable by ordinal. Carries the same
 * observer snapshot as HistoryEntry so `where/why/how is x when N` answers
 * from the occurrence rather than the line. No `prev_value` twin is needed —
 * unlike the pruned line history, the ring still HOLDS ordinal N-1, so
 * `prev of x when N` is just a second lookup. */
typedef struct {
    EigsSlot value;
    uint8_t  obs_valid;
    double   entropy;
    double   dH;
    double   last_entropy;
} OccEntry;

/* #739: the prev-table lives on EigsThread, not in a file static. It is keyed
 * by INTERNED NAME POINTER, and the intern table is itself per-thread
 * (`g_env_name_interns` -> `eigs_current->env_name_interns`), so two threads'
 * "x" were never the same key and a shared table could not have merged them
 * anyway — process-global storage bought nothing and cost ownership. The
 * entries hold slots allocated by their own thread, so per-thread is also the
 * only scope on which "release these" is a well-defined operation, and it needs
 * no lock: only the owning thread ever touches its table. The tape itself
 * (FILE*, sink, replay reader, enable flags) stays process-wide below — one
 * process, one tape — which is the distinction `trace_shutdown` got wrong. */
typedef struct TracePrevEntry {
    const char    *name;
    EigsSlot       prev;
    EigsSlot       current;
    uint8_t        has_current;
    uint8_t        has_prev;
    uint8_t        armed;       /* #827: this name is a compile-time target of
                                 * some temporal query (or the wildcard is on) */
    uint32_t       armed_gen;   /* g_arm_gen when `armed` was computed */
    HistoryEntry  *history;     /* live entries only — line-sorted (see above) */
    int            hist_count;
    int            hist_cap;
    LineCount     *lc;          /* (line -> count) histogram, sorted by line */
    int            lc_count;
    int            lc_cap;
    /* #868: occurrence ring — the last `trace_occ_window()` recorded assigns.
     * Allocated lazily on the first armed assign, so an unarmed name costs
     * one pointer of struct and nothing else. */
    OccEntry      *occ;
    int            occ_cap;     /* allocated slots (== window once allocated) */
    int            occ_count;   /* live slots, <= occ_cap */
    int            occ_head;    /* next write index (mod occ_cap) */
    long long      occ_total;   /* total recorded assigns = the newest ordinal */
    uint8_t        occ_armed;
    uint32_t       occ_armed_gen;
} PrevEntry;

/* ----- #827 (defect A): per-name arming.
 *
 * `g_trace_hist` is a whole-program flag, so a `prev of v` inside a function
 * that is never called used to switch on recording for EVERY name in the
 * program. The set of names a temporal query can ever reach is known at
 * compile time, though: `prev of x` and `<kw> is x at L` both compile to a
 * NAMED opcode carrying the identifier, and only those named forms consult
 * the history (the bare value form, OP_INTERROGATE, never does). So the
 * compiler arms the names it actually mentions, and an assignment to any
 * other name records nothing.
 *
 * Sound by construction: a name no temporal query names cannot be asked
 * about, so skipping it cannot change an answer. Two things force the
 * wildcard instead — `state_at` (queries every name) and a tape being open
 * (EIGS_TRACE / an embed sink) — plus anything that turns recording on
 * without naming a name (the REPL, `record_history of 1`).
 *
 * The set is process-global because it records compile-time facts, while the
 * table it filters is per-thread (#739). `g_arm_gen` bumps whenever the set
 * changes, so each PrevEntry caches its decision and rechecks only after a
 * mid-run arming (eval / REPL / a later `record_history`). */
static char   **g_arm_names = NULL;
static int      g_arm_count = 0;
static int      g_arm_cap   = 0;

/* ----- #1145: ONE leaf mutex over BOTH arming tiers' name arrays.
 *
 * The arrays are process-global (they record compile-time facts) and both
 * tiers grow by `realloc`, so a compile racing an assignment frees the array
 * the assignment is walking. Two shapes produce that, and they need DIFFERENT
 * predicates — which is why this guard has none and is simply always taken:
 *
 *   (a) ONE state, spawn: a worker compiling `what is q when 1` (eval /
 *       load_file / import) reallocs g_occ_names while other workers'
 *       assignments walk it (prev_record_assign -> occ_set_has). `spawn`
 *       widens only the HISTORY tier to the wildcard (trace_arm_history_all_mt,
 *       #827); the occurrence tier has no wildcard by design (#868 — a
 *       wildcard there would put a bounded ring on EVERY name), so no
 *       spawn-time escape can cover it.
 *   (b) TWO embed STATES, no spawn: `multithreaded` is a PER-STATE flag, so it
 *       is 0 on both, nothing widens anything, and one state's
 *       trace_arm_history_name reallocs while the other state's assignments
 *       read arm_set_has (heap-use-after-free, h1c_two_states.c / #915's
 *       ext_http shape). src/state.c's eigs_process_thread_count() guard
 *       covers only the observer gate's eager PRE-PASS; compile_node_inner
 *       (compiler.c) arms on the ordinary path and was unguarded.
 *
 * Cost: none on any hot path. Every reader is behind a per-PrevEntry
 * generation cache (e->armed_gen / e->occ_armed_gen), so an assignment calls
 * arm_set_has/occ_set_has once per name per ARMING GENERATION, not once per
 * assignment; the writers run at compile time. A conditional guard
 * (g_vm_multithreaded, or a thread count) would ALSO have a real window — the
 * reader decides not to lock, then a second thread attaches and arms — so the
 * unconditional take is both cheaper to reason about and strictly safer.
 *
 * LOCK ORDER: g_arm_mu is a LEAF. Nothing called while it is held may take
 * another lock (the bodies are strcmp / malloc / free only). trace_shutdown
 * takes it INSIDE g_tape_mu; because no path holds g_arm_mu across a tape
 * lock, that is not a cycle. Keep it that way. */
static pthread_mutex_t g_arm_mu = PTHREAD_MUTEX_INITIALIZER;
static __thread unsigned g_arm_suppress_depth = 0;
static inline void arm_lock(void)   { pthread_mutex_lock(&g_arm_mu); }
static inline void arm_unlock(void) { pthread_mutex_unlock(&g_arm_mu); }

/* ACQUIRE loads / RELEASE stores: prev_record_assign reads these before
 * tape_emit_begin (no lock). Shutdown writes them under g_tape_mu; a
 * plain int race was TSan-flaky on g_arm_gen / g_arm_all (#1142 r3). */
static int      g_arm_all_storage = 0;
static uint32_t g_arm_gen_storage = 1;
#define g_arm_all __atomic_load_n(&g_arm_all_storage, __ATOMIC_ACQUIRE)
#define arm_all_store(v) __atomic_store_n(&g_arm_all_storage, (v), __ATOMIC_RELEASE)
#define g_arm_gen __atomic_load_n(&g_arm_gen_storage, __ATOMIC_ACQUIRE)
static void arm_gen_bump(void) {
    __atomic_fetch_add(&g_arm_gen_storage, 1u, __ATOMIC_RELEASE);
}

/* Caller holds g_arm_mu. */
static int arm_set_has_locked(const char *name) {
    for (int i = 0; i < g_arm_count; i++)
        if (strcmp(g_arm_names[i], name) == 0) return 1;
    return 0;
}

static int arm_set_has(const char *name) {
    arm_lock();
    int r = arm_set_has_locked(name);
    arm_unlock();
    return r;
}

/* ----- #868: the occurrence-arming tier.
 *
 * Separate from g_arm_names on purpose. That set is widened to the wildcard by
 * `state_at`, by an open tape, and by `spawn` — all of which would then put a
 * bounded-but-real ring on EVERY name. None of them widens this one: a
 * compiled program gets a ring only for a name some `when`-qualified query
 * named at compile time, which is the only way it can ever be read back.
 *
 * The single wildcard (g_occ_all) belongs to the INTERACTIVE REPL alone, where
 * the assignments precede the query that would arm them — see
 * trace_arm_occurrences_all in trace.h. */
static char   **g_occ_names = NULL;
static int      g_occ_count = 0;
static int      g_occ_cap   = 0;
static int      g_occ_all_storage = 0;   /* interactive REPL only — see trace.h */
static uint32_t g_occ_gen_storage = 1;
#define g_occ_all __atomic_load_n(&g_occ_all_storage, __ATOMIC_ACQUIRE)
#define occ_all_store(v) __atomic_store_n(&g_occ_all_storage, (v), __ATOMIC_RELEASE)
#define g_occ_gen __atomic_load_n(&g_occ_gen_storage, __ATOMIC_ACQUIRE)
static void occ_gen_bump(void) {
    __atomic_fetch_add(&g_occ_gen_storage, 1u, __ATOMIC_RELEASE);
}
/* 0 = not yet resolved. #1145: memoised LAZILY on the first occurrence
 * record, which is a per-assignment path on EVERY thread — the plain
 * read-then-write was a data race between two embed states (TSan: read at
 * trace_occ_window <- occ_record <- prev_record_assign on T2 against the
 * write one line later on T1). ACQUIRE/RELEASE, and two racing resolvers
 * compute the SAME value from the same environment, so the duplicate work is
 * harmless and no lock is owed on this path. */
static int      g_occ_window_storage = 0;

int trace_occ_window(void) {
    int w = __atomic_load_n(&g_occ_window_storage, __ATOMIC_ACQUIRE);
    if (w) return w;
    w = TRACE_OCC_WINDOW_DEFAULT;
    const char *e = getenv("EIGS_OCC_WINDOW");
    if (e && *e) {
        char *end = NULL;
        long v = strtol(e, &end, 10);
        if (end && *end == '\0' && v >= 1) {
            if (v > TRACE_OCC_WINDOW_MAX) v = TRACE_OCC_WINDOW_MAX;
            w = (int)v;
        }
    }
    __atomic_store_n(&g_occ_window_storage, w, __ATOMIC_RELEASE);
    return w;
}

/* Caller holds g_arm_mu. */
static int occ_set_has_locked(const char *name) {
    if (g_occ_all) return 1;
    for (int i = 0; i < g_occ_count; i++)
        if (strcmp(g_occ_names[i], name) == 0) return 1;
    return 0;
}

static int occ_set_has(const char *name) {
    arm_lock();
    int r = occ_set_has_locked(name);
    arm_unlock();
    return r;
}

void trace_arm_occurrences_all(void) {
    if (g_arm_suppress_depth) return;
    if (g_occ_all) return;
    occ_all_store(1);
    occ_gen_bump();
    trace_arm_history_all();
}

void trace_arm_occurrences_name(const char *name) {
    if (g_arm_suppress_depth) return;
    if (!name || g_occ_all) return;
    /* The ring is fed from prev_record_assign, which only runs when the
     * line-history is armed for this name — so arm that too. */
    trace_arm_history_name(name);    /* takes and releases g_arm_mu itself */
    arm_lock();                      /* #1145: check + grow + append is ONE step */
    if (occ_set_has_locked(name)) { arm_unlock(); return; }
    if (g_occ_count >= g_occ_cap) {
        int nc = g_occ_cap ? g_occ_cap * 2 : 8;
        char **nn = realloc(g_occ_names, (size_t)nc * sizeof(char *));
        if (!nn) { arm_unlock(); return; }  /* OOM: this name gets no ring */
        g_occ_names = nn;
        g_occ_cap = nc;
    }
    size_t len = strlen(name) + 1;
    char *copy = malloc(len);
    if (!copy) { arm_unlock(); return; }
    memcpy(copy, name, len);
    g_occ_names[g_occ_count++] = copy;
    occ_gen_bump();
    arm_unlock();
}

/* Diagnostic compilers run on attached threads, so TLS gives them a private
 * side-effect barrier without holding g_arm_mu across the whole compilation.
 * Holding that leaf mutex would deadlock when the compiler calls an arming
 * function; restoring a snapshot afterward could instead erase a concurrent
 * compiler's legitimate process-global additions. */
void trace_arm_suppress_begin(void) { g_arm_suppress_depth++; }
void trace_arm_suppress_end(void) {
    if (g_arm_suppress_depth) g_arm_suppress_depth--;
}

void trace_arm_observer_history(void) {
    if (!g_arm_suppress_depth)
        trace_flag_store(g_trace_obs_hist_storage, 1);
}

void trace_arm_history_all_mt(void) {
    if (g_arm_all) return;
    arm_all_store(1);
    arm_gen_bump();
}

void trace_arm_history_all(void) {
    if (g_arm_suppress_depth) return;
    trace_flag_store(g_trace_hist_storage, 1);
    trace_arm_history_all_mt();
}

void trace_arm_history_name(const char *name) {
    if (g_arm_suppress_depth) return;
    trace_flag_store(g_trace_hist_storage, 1);
    if (!name || g_arm_all) return;
    arm_lock();                      /* #1145: check + grow + append is ONE step */
    if (arm_set_has_locked(name)) { arm_unlock(); return; }
    if (g_arm_count >= g_arm_cap) {
        int nc = g_arm_cap ? g_arm_cap * 2 : 8;
        char **nn = realloc(g_arm_names, (size_t)nc * sizeof(char *));
        /* OOM: never narrow. trace_arm_history_all takes no lock (flag
         * stores only), so calling it here cannot cycle on g_arm_mu. */
        if (!nn) { arm_unlock(); trace_arm_history_all(); return; }
        g_arm_names = nn;
        g_arm_cap = nc;
    }
    size_t len = strlen(name) + 1;
    char *copy = malloc(len);
    if (!copy) { arm_unlock(); trace_arm_history_all(); return; }
    memcpy(copy, name, len);
    g_arm_names[g_arm_count++] = copy;
    arm_gen_bump();
    arm_unlock();
}

void trace_history_disable(void) {
    trace_flag_store(g_trace_hist_storage, 0);
    trace_flag_store(g_trace_obs_hist_storage, 0);
}

/* g_prev_tab / g_prev_cap / g_prev_count are bridge macros onto EigsThread
 * (eigenscript.h), reached only with a thread attached. Every read path below
 * that can run during teardown or from atexit guards on `eigs_current` first. */

/* g_trace_current_line (per-thread, see trace.h) replaces the old static
 * line cache: OP_LINE stores it directly instead of paying a call. */

#define PREV_INIT_CAP 16
#define PREV_LOAD_NUM 3            /* grow when count*4 >= cap*3  (~75%) */
#define PREV_LOAD_DEN 4

static uint32_t prev_hash_ptr(const char *p) {
    /* Fibonacci hash of the pointer bits; interned strings already
     * provide identity, so this just spreads bits across the table. */
    uint64_t x = (uint64_t)(uintptr_t)p;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return (uint32_t)x;
}

static PrevEntry *prev_lookup_slot(PrevEntry *tab, int cap, const char *name) {
    uint32_t mask = (uint32_t)(cap - 1);
    uint32_t i = prev_hash_ptr(name) & mask;
    while (tab[i].name && tab[i].name != name) {
        i = (i + 1) & mask;
    }
    return &tab[i];
}

static void prev_grow(void) {
    int new_cap = g_prev_cap ? g_prev_cap * 2 : PREV_INIT_CAP;
    PrevEntry *nt = calloc((size_t)new_cap, sizeof(PrevEntry));
    if (!nt) return;
    for (int i = 0; i < g_prev_cap; i++) {
        PrevEntry *e = &g_prev_tab[i];
        if (!e->name) continue;
        PrevEntry *dst = prev_lookup_slot(nt, new_cap, e->name);
        *dst = *e;
    }
    free(g_prev_tab);
    g_prev_tab = nt;
    g_prev_cap = new_cap;
}

/* Bump the (line -> count) histogram for `when is x at L`. Sorted insert;
 * after the first few assigns this is a pure binary-search hit. */
static void lc_bump(PrevEntry *e, int line) {
    int lo = 0, hi = e->lc_count - 1;
    while (lo <= hi) {
        int mid = (int)(((unsigned)lo + (unsigned)hi) >> 1);
        if (e->lc[mid].line == line) { e->lc[mid].count++; return; }
        if (e->lc[mid].line < line) lo = mid + 1;
        else hi = mid - 1;
    }
    if (e->lc_count >= e->lc_cap) {
        int nc = e->lc_cap ? e->lc_cap * 2 : 8;
        LineCount *nl = realloc(e->lc, (size_t)nc * sizeof(LineCount));
        if (!nl) return;   /* `when at L` under-counts rather than aborting */
        e->lc = nl;
        e->lc_cap = nc;
    }
    memmove(&e->lc[lo + 1], &e->lc[lo],
            (size_t)(e->lc_count - lo) * sizeof(LineCount));
    e->lc[lo].line  = line;
    e->lc[lo].count = 1;
    e->lc_count++;
}

static void hist_drop(HistoryEntry *h) {
    slot_decref(h->value);
    if (h->has_prev_value) slot_decref(h->prev_value);
}

/* #868: append one recorded assignment to the ring, evicting the oldest once
 * the window is full. Called only for an occurrence-armed name.
 *
 * occ_total counts the assignment BEFORE the store can fail, on purpose. The
 * ordinal exists because the assignment happened; whether we managed to keep
 * its value is a storage question. Counting only what we stored would make an
 * unstorable ordinal read back as MISS — "that assignment never happened" —
 * which is exactly the confident wrong answer the MISS/EVICTED split exists to
 * prevent. Counted-but-absent reads as EVICTED and raises instead.
 *
 * The (occ_total - occ_count, occ_total] mapping survives this: entries are
 * appended in order, so whatever the ring does hold is always the newest
 * occ_count ordinals. */
static void occ_record(PrevEntry *e, EigsSlot value) {
    e->occ_total++;
    if (!e->occ) {
        int w = trace_occ_window();
        e->occ = calloc((size_t)w, sizeof(OccEntry));
        if (!e->occ) return;
        e->occ_cap = w;
    }
    if (e->occ_count == e->occ_cap) {
        /* Full: the slot about to be written holds the oldest retained
         * assignment. Drop its ref before overwriting. */
        slot_decref(e->occ[e->occ_head].value);
    } else {
        e->occ_count++;
    }
    OccEntry *o = &e->occ[e->occ_head];
    slot_incref(value);
    o->value = value;
    o->obs_valid = 0;      /* filled by trace_record_obs, as for HistoryEntry */
    e->occ_head = (e->occ_head + 1) % e->occ_cap;
}

/* Index of `ordinal` in the ring, or -1 if it is not retained. The ring holds
 * ordinals (occ_total - occ_count, occ_total] — newest at occ_head-1. */
static int occ_index_of(const PrevEntry *e, long long ordinal) {
    if (!e->occ || e->occ_count == 0) return -1;
    if (ordinal > e->occ_total) return -1;
    if (ordinal <= e->occ_total - e->occ_count) return -1;
    long long back = e->occ_total - ordinal;          /* 0 == newest */
    long long idx = (long long)e->occ_head - 1 - back;
    idx %= e->occ_cap;
    if (idx < 0) idx += e->occ_cap;
    return (int)idx;
}

static void prev_record_assign(const char *name, EigsSlot value, int filtered,
                               int source_line) {
    /* #1575: sandbox execution cannot read shared temporal history and must
     * not contribute to it. Stop before name promotion, table growth, slot
     * retention or metadata updates, regardless of producer/arming mode.
     * trace_assign_ex still emits the ordinary tape A record afterwards. */
    if (!eigs_current || g_sandbox_active || !name) return;
    /* #1072 (via #873): the history table is a HEAP structure that outlives
     * any arena window, so an arena-allocated value must be PROMOTED before
     * it is retained here -- exactly as OP_INDEX_SET / set_at / list_append
     * promote. Without it, EIGS_TRACE on test_arena_escape retained arena
     * slots in e->current / the occurrence ring / the line history,
     * arena_reset reclaimed them, and trace_thread_release's slot_decref at
     * shutdown freed reclaimed memory (SIGSEGV; the plain and replay runs
     * pass because nothing records). promote_if_arena returns a FRESH heap
     * ref when it promotes; every retain below takes its own ref, so that
     * extra one is dropped at the end. */
    int promoted = 0;
    if (slot_is_heap(value)) {
        Value *v = slot_as_ptr(value);
        Value *pv = promote_if_arena(v);
        if (pv != v) { value = slot_from_heap(pv); promoted = 1; }
    }
    /* The prev/history table keeps the descriptor's exact interned pointer
     * beyond sandbox_run. Re-home that one name to the ordinary thread
     * lifetime before the run scope is released; unused descriptor constants
     * still remain temporary and are reclaimed at the boundary. */
    env_intern_scope_retain(name);
    if (g_prev_count * PREV_LOAD_DEN >= g_prev_cap * PREV_LOAD_NUM) {
        prev_grow();
        if (!g_prev_tab) { if (promoted) slot_decref(value); return; }
    }
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, name);
    if (!e->name) {
        e->name = name;
        g_prev_count++;
    }
    /* #827 defect A: names no temporal query can name record nothing.
     * #830: only for a caller whose chunk the bytecode compiler scanned —
     * `filtered`. An unscanned producer (the AOT's aot_trace_assign, an
     * embedder, hand-assembled bytecode) never fed the armed-name set, so
     * applying it there drops assignments its own temporal reads then miss. */
    if (filtered) {
        if (__builtin_expect(e->armed_gen != g_arm_gen, 0)) {
            e->armed_gen = g_arm_gen;
            e->armed = (uint8_t)(g_arm_all || arm_set_has(name));
        }
        if (!e->armed) { if (promoted) slot_decref(value); return; }
    }

    if (e->has_current) {
        /* Shift current -> prev; drop the old prev. */
        if (e->has_prev) slot_decref(e->prev);
        e->prev = e->current;
        e->has_prev = 1;
    }
    slot_incref(value);
    e->current = value;
    e->has_current = 1;

    /* VM callers pass their per-thread current line. Other producers (AOT
     * and embedders) use the process-wide trace stamp. Keeping the VM line
     * explicit matters while spawn has the multithreaded gate raised: OP_LINE
     * deliberately does not write the shared stamp then (#297). */
    int line = source_line >= 0 ? source_line : trace_current_line_load();
    lc_bump(e, line);

    /* #868: the occurrence ring runs alongside the line history, not inside
     * it — the pruning below is what collapses a loop body, and the ring
     * exists precisely to survive that. Recompute the arming decision on the
     * same generation-cache pattern as e->armed. Unlike e->armed there is no
     * wildcard, so an unarmed name pays one compare. */
    if (__builtin_expect(e->occ_armed_gen != g_occ_gen, 0)) {
        e->occ_armed_gen = g_occ_gen;
        e->occ_armed = (uint8_t)occ_set_has(name);
    }
    if (e->occ_armed) occ_record(e, value);

    /* Reserve BEFORE pruning, so an allocation failure leaves the history
     * exactly as it was. Pruning first and then failing to append would
     * retire entries that are only unreachable once the new one exists —
     * turning an OOM into a stale (wrong) answer instead of an unchanged
     * one. Capacity reserved for the pre-prune count always covers the
     * post-prune count plus this entry, since pruning only shrinks. */
    if (e->hist_count >= e->hist_cap) {
        int new_cap = e->hist_cap ? e->hist_cap * 2 : 8;
        HistoryEntry *nh = realloc(e->history, (size_t)new_cap * sizeof(HistoryEntry));
        if (!nh) { if (promoted) slot_decref(value); return; }
        e->history = nh;
        e->hist_cap = new_cap;
    }

    /* #827 defect B: retire the entries this assignment makes unreachable —
     * every trailing live entry stamped at or after `line` (see the header
     * comment on HistoryEntry). This is what bounds the history. */
    while (e->hist_count > 0 && e->history[e->hist_count - 1].line >= line) {
        e->hist_count--;
        hist_drop(&e->history[e->hist_count]);
    }

    HistoryEntry *h = &e->history[e->hist_count++];
    slot_incref(value);
    h->line  = line;
    h->value = value;
    /* The execution-order predecessor — `prev of x at L`'s answer. The
     * current->prev shift above already put it in e->prev. */
    h->has_prev_value = e->has_prev;
    if (e->has_prev) {
        h->prev_value = e->prev;
        slot_incref(h->prev_value);
    }
    /* #262 Step E: observer state lives on the Env slot, not the Value —
     * leave the snapshot empty here; OBSERVE_NAME_POST fills it from the
     * fresh slot via trace_record_obs (runs after the SET that created this
     * entry), which is why the newest entry must stay live. */
    h->obs_valid = 0;
    if (promoted) slot_decref(value);
}

/* #262 Phase-3 D2: patch the observer snapshot for `name`'s most recent
 * history entry from the slot-model trajectory. Called by OBSERVE_NAME_POST
 * after the binding's slot is freshly updated, so `where/why/how is x at L`
 * sources entropy/dH from the Env slot rather than the (Step-E-doomed) Value
 * observer fields. The history entry and its parallel obs slot were created by
 * the preceding prev_record_assign — the SET runs before OBSERVE_NAME_POST —
 * so this overwrites a just-written (and, pre-flip, identical value-sourced)
 * entry, or fills the valid=0 entry left once observed numbers become
 * immediates. `name` must be the interned constant (pointer-keyed lookup).
 * Gated by g_trace_obs_hist at the call site. */
void trace_record_obs(const char *name, double entropy, double dH,
                      double last_entropy) {
    /* An ignored sandbox assignment must not overwrite an older host
     * assignment's observer snapshot, including its occurrence-ring twin. */
    if (!eigs_current || g_sandbox_active || !name || !g_prev_tab) return;
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, name);
    if (!e->name) return;
    /* #868: patch the newest ring entry too, so `where/why/how is x when N`
     * reads the same slot-sourced trajectory the `at` forms do. Independent of
     * hist_count — the ring can be armed and populated on an assignment whose
     * history entry was just pruned away. */
    if (e->occ && e->occ_count > 0) {
        int oi = e->occ_head == 0 ? e->occ_cap - 1 : e->occ_head - 1;
        OccEntry *o = &e->occ[oi];
        o->entropy = entropy;
        o->dH = dH;
        o->last_entropy = last_entropy;
        o->obs_valid = 1;
    }
    if (e->hist_count == 0) return;
    HistoryEntry *h = &e->history[e->hist_count - 1];
    h->entropy = entropy;
    h->dH = dH;
    h->last_entropy = last_entropy;
    h->obs_valid = 1;
}

int trace_query_prev(const char *interned_name, EigsSlot *out) {
    if (!eigs_current || !interned_name || !out || !g_prev_tab) return 0;
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, interned_name);
    if (!e->name || !e->has_prev) return 0;
    *out = e->prev;
    slot_incref(*out);
    return 1;
}

/* The latest live assignment stamped at or before `line`.
 *
 * The live array is sorted strictly increasing by line (#827 — see the
 * HistoryEntry header), and pruning removed only entries that no query could
 * reach, so the answer is the LAST entry with line <= L: one binary search.
 * This replaces the old periodic line-floor segment index, which existed to
 * make a backward scan over an unbounded append-only array survivable. */
static int find_hist_idx_at_or_before(PrevEntry *e, int line) {
    int lo = 0, hi = e->hist_count - 1, ans = -1;
    while (lo <= hi) {
        int mid = (int)(((unsigned)lo + (unsigned)hi) >> 1);
        if (e->history[mid].line <= line) { ans = mid; lo = mid + 1; }
        else hi = mid - 1;
    }
    return ans;
}

int trace_query_at(int kind, const char *interned_name, int line, EigsSlot *out) {
    if (!eigs_current || !interned_name || !out || !g_prev_tab) return 0;
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, interned_name);
    if (!e->name) return 0;

    if (kind == 1) {
        /* `who is x at L` — binding name is timeless. */
        Value *s = make_str(interned_name);
        *out = slot_from_value(s);
        return 1;
    }

    if (kind == 2) {
        /* `when is x at L` — count of assignments with line ≤ L. Summed
         * from the histogram, which counts pruned assignments too (#827). */
        long long count = 0;
        for (int i = 0; i < e->lc_count && e->lc[i].line <= line; i++)
            count += e->lc[i].count;
        *out = slot_from_num((double)count);
        return 1;
    }

    int idx = find_hist_idx_at_or_before(e, line);
    if (idx < 0) return 0;
    HistoryEntry *h = &e->history[idx];

    if (kind >= 3 && kind <= 5) {
        /* where/why/how — read the observer snapshot captured at that
         * assign. Mirrors the live INTERROGATE formulas. */
        if (!h->obs_valid) return 0;
        double r = (kind == 3) ? h->entropy
                 : (kind == 4) ? h->dH
                 : observer_settledness(h->dH);   /* #412: how = f(dH) */
        *out = slot_from_num(r);
        return 1;
    }

    if (kind == 0) {
        /* `what is x at L` — value at most recent assign ≤ L. */
        *out = h->value;
        slot_incref(*out);
        return 1;
    }

    if (kind == 6) {
        /* `prev of x at L` — value at the assign immediately preceding
         * the one that produced `x`'s state at L. Carried on the entry
         * because that predecessor is usually pruned (#827). */
        if (!h->has_prev_value) return 0;
        *out = h->prev_value;
        slot_incref(*out);
        return 1;
    }

    return 0;
}

int trace_query_when(int kind, const char *interned_name, long long ordinal,
                     EigsSlot *out, long long *total, long long *oldest) {
    if (total) *total = 0;
    if (oldest) *oldest = 0;
    if (!eigs_current || !interned_name || !out || !g_prev_tab)
        return TRACE_WHEN_MISS;
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, interned_name);
    if (!e->name) return TRACE_WHEN_MISS;

    if (total) *total = e->occ_total;
    if (oldest) *oldest = e->occ_count ? e->occ_total - e->occ_count + 1 : 0;

    /* `who is x when N` — the binding name is timeless, so it answers for any
     * ordinal that could have happened. */
    if (kind == 1) {
        if (ordinal < 1 || ordinal > e->occ_total) return TRACE_WHEN_MISS;
        Value *s = make_str(interned_name);
        *out = slot_from_value(s);
        return TRACE_WHEN_HIT;
    }

    /* `when is x when N` — the count of assignments up to the Nth is N. Also
     * answerable without the entry, so it too only needs the range check. */
    if (kind == 2) {
        if (ordinal < 1 || ordinal > e->occ_total) return TRACE_WHEN_MISS;
        *out = slot_from_num((double)ordinal);
        return TRACE_WHEN_HIT;
    }

    /* `prev of x when N` is `what is x when N-1` — the ring still holds the
     * predecessor, so unlike the pruned line history no per-entry prev_value
     * twin is needed. Ordinal 1 has no predecessor. */
    long long want = (kind == 6) ? ordinal - 1 : ordinal;
    if (kind == 6 && ordinal >= 1 && ordinal <= e->occ_total && want < 1)
        return TRACE_WHEN_MISS;
    if (want < 1 || want > e->occ_total) return TRACE_WHEN_MISS;

    int idx = occ_index_of(e, want);
    if (idx < 0) return TRACE_WHEN_EVICTED;
    OccEntry *o = &e->occ[idx];

    if (kind >= 3 && kind <= 5) {
        if (!o->obs_valid) return TRACE_WHEN_MISS;
        double r = (kind == 3) ? o->entropy
                 : (kind == 4) ? o->dH
                 : observer_settledness(o->dH);   /* #412: how = f(dH) */
        *out = slot_from_num(r);
        return TRACE_WHEN_HIT;
    }

    /* kind 0 (what) and kind 6 (prev, already shifted to N-1). */
    *out = o->value;
    slot_incref(*out);
    return TRACE_WHEN_HIT;
}

/* #736: the observed-loop machinery injects bindings of its own
 * (`__loop_exit__`, `__loop_iterations__` — vm.c) into the env the assignment
 * history folds over. They are implementation detail and must not surface in
 * a user-visible binding dump. The dunder form is the runtime's own
 * convention for these — lint.c pre-binds the same names for E003. */
int trace_name_is_internal(const char *n) {
    size_t len = n ? strlen(n) : 0;
    return (len > 4 && n[0] == '_' && n[1] == '_' &&
            n[len - 1] == '_' && n[len - 2] == '_') ? 1 : 0;
}

/* #1029: the prev table is bucketed by the interned name's ADDRESS, so a
 * bucket-order walk printed the keys in an ASLR-dependent order -- seven
 * orders in eight runs of one program, and a --trace tape did not pin it
 * (ordering is output, not a nondeterminism record), so EIGS_REPLAY
 * diverged from its own recording. Emit in NAME order: deterministic
 * across processes and independent of the table's layout. */
static int state_at_name_cmp(const void *a, const void *b) {
    const PrevEntry *ea = *(const PrevEntry *const *)a;
    const PrevEntry *eb = *(const PrevEntry *const *)b;
    return strcmp(ea->name, eb->name);
}

Value *trace_state_at(int line) {
    Value *out = make_dict(g_prev_count > 0 ? g_prev_count : 8);
    if (!out || !g_prev_tab) return out;
    PrevEntry **live = (PrevEntry **)malloc(sizeof(PrevEntry *) * (size_t)(g_prev_cap > 0 ? g_prev_cap : 1));
    if (!live) return out;
    int n = 0;
    for (int i = 0; i < g_prev_cap; i++) {
        PrevEntry *e = &g_prev_tab[i];
        if (!e->name || e->hist_count == 0) continue;
        if (trace_name_is_internal(e->name)) continue;
        if (find_hist_idx_at_or_before(e, line) < 0) continue;
        live[n++] = e;
    }
    qsort(live, (size_t)n, sizeof(PrevEntry *), state_at_name_cmp);
    for (int k = 0; k < n; k++) {
        PrevEntry *e = live[k];
        int idx = find_hist_idx_at_or_before(e, line);
        Value *v = slot_to_value(e->history[idx].value);
        dict_set(out, e->name, v);
        val_decref(v);
    }
    free(live);
    return out;
}

static FILE *g_trace_fp = NULL;
static int   g_trace_initialized = 0;

/* ----- Embed byte-sink seam (trace_set_sink).
 *
 * The freestanding profile has no filesystem, so EIGS_TRACE's fopen is
 * compiled out there — but the tape itself is just bytes. An embedder
 * (EigenOS M11: the machine journal) installs a sink callback and the
 * emit primitives below hand it complete record lines (newline
 * included). #1142 made that unconditional: the whole record is
 * formatted before the sink is called, so a record of ANY length
 * arrives in exactly ONE call — the old per-byte g_sink_buf[4096] and
 * its chunked oversized records are gone. Installing a sink enables recording exactly
 * like EIGS_TRACE does hosted; the two paths are independent sinks of
 * the same byte stream (in practice an embedder uses one or the
 * other). All emitters funnel through tp_putc/tp_puts/tp_printf. */
static void (*g_trace_sink)(const char *bytes, size_t len, void *ud) = NULL;
static void *g_trace_sink_ud = NULL;
/* #1142: the old per-byte sink line buffer is GONE — see the output-buffer
 * block below. `g_sink_buf[4096]` with its unsynchronised `g_sink_len`
 * index (the global-buffer-overflow the two-state sink probe hit) no
 * longer exists at all. */

/* #1142: one process-wide tape mutex. Taken ONCE per record, in
 * tape_emit_begin, and released in tape_emit_end — so a record (its
 * obs-cfg diff, its scope transition, its bytes, the line-stamp/scope
 * state update and the commit) is one atomic unit, and every piece of
 * shared decision state (the stream's line/scope/config caches and
 * g_tape_session) is read and
 * written under it. Never held across an EigenScript-level call or a
 * blocking builtin. The sink callback fires while the lock is held — do
 * not re-enter the runtime from it. */
static pthread_mutex_t g_tape_mu = PTHREAD_MUTEX_INITIALIZER;

static void tape_lock(void)   { pthread_mutex_lock(&g_tape_mu); }
static void tape_unlock(void) { pthread_mutex_unlock(&g_tape_mu); }
/* Named so the replay-take-unlocked mutant can nop just the take path. */
static void replay_take_lock(void)   { tape_lock(); }
static void replay_take_unlock(void) { tape_unlock(); }
static int  trace_out_active(void);

/* ----- Record staging and the tape output buffer.
 *
 * Round 2 emitted every record byte-by-byte through fputc() with the tape
 * mutex held. That was correct but cost +8..14% on a 615k-record
 * single-threaded tape (two blind critics, n=5): the new per-record mutex
 * on top of glibc's per-fputc stream work. Replacing fputc with one fwrite
 * per record did NOT pay for the mutex either — a small fwrite costs more
 * than the ~30 putc's it replaces (measured: still +6.8%).
 *
 * What works is to stop touching stdio per record at all. Records are
 * formatted DIRECTLY into one process-wide output buffer, in place, under
 * the tape mutex:
 *
 *   - the mutex is taken once in tape_emit_begin and released once in
 *     tape_emit_end, so a record (its obs-cfg diff, its scope transition,
 *     its bytes, the line-stamp/scope state update and the commit) is one
 *     atomic unit, and every stream's line/scope/config cache plus
 *     g_tape_session is read and written under it;
 *   - g_rec_at marks where the record being formatted starts, so
 *     tape_emit_end can hand the SINK exactly that record in one call —
 *     which is what killed the old g_sink_buf[4096] + unsynchronised
 *     g_sink_len (the global-buffer-overflow in the two-state sink probe);
 *   - the FILE sees one fwrite per ~32 KiB of tape instead of one stdio
 *     call per byte, which is where the mutex is paid for.
 *
 * Never held across an EigenScript-level call or a blocking builtin. The
 * sink callback fires while the lock is held — do not re-enter the runtime
 * from it. */
#define TAPE_OUT_INIT   (64 * 1024)
#define TAPE_OUT_FLUSH  (32 * 1024)
static char   *g_out     = NULL;
static size_t  g_out_cap = 0;
static size_t  g_out_len = 0;   /* bytes formatted but not yet fwritten */
static size_t  g_rec_at  = 0;   /* offset of the record being formatted */
static uint64_t g_tape_session = 0;
static uint64_t g_stream_next = 1;
static uint64_t g_attachment_next = 1;  /* process lifetime; never reset at V */
static uint64_t g_stream_opener_token = 0;
static uint64_t g_native_opener_token = 0;
/* TLS dies with the OS thread; a recycled pthread_t cannot inherit it. */
static __thread uint64_t g_native_session_token = 0;

/* Scalar/string-only descriptors outlive a detached parent when a child still
 * needs its causal origin. Refcounts and links are protected by g_tape_mu. */
typedef struct TraceStreamOrigin {
    unsigned refs;
    uint64_t token, state, spawn_next;
    struct TraceStreamOrigin *parent;
    uint64_t occurrence;
    char *key_hex;
    uint64_t record_session, record_id;
    int declared;
} TraceStreamOrigin;
typedef struct TraceSpawnBinding {
    TraceStreamOrigin *origin;
} TraceSpawnBinding;
typedef struct RecordingKey {
    char *hex;
    uint64_t token;
    struct RecordingKey *next;
} RecordingKey;
static RecordingKey *g_recording_keys;
static void replay_forget_origin_locked(uint64_t token);

static void origin_release_locked(TraceStreamOrigin *origin) {
    /* Iterative: a deep ordinary spawn ancestry must not consume C stack. */
    while (origin && --origin->refs == 0) {
        TraceStreamOrigin *parent = origin->parent;
        replay_forget_origin_locked(origin->token);
        free(origin->key_hex);
        free(origin);
        origin = parent;
    }
}

static TraceStreamOrigin *origin_current_locked(void) {
    if (!eigs_current) return NULL;
    TraceStreamOrigin *origin = eigs_current->trace_origin;
    if (!origin) {
        origin = xcalloc(1, sizeof(*origin));
        origin->refs = 1;
        origin->token = eigs_current->trace_attachment_token;
        origin->state = eigs_current->state->trace_state_token;
        eigs_current->trace_origin = origin;
    }
    return origin;
}

static void recording_keys_clear_locked(void) {
    while (g_recording_keys) {
        RecordingKey *next = g_recording_keys->next;
        free(g_recording_keys->hex);
        free(g_recording_keys);
        g_recording_keys = next;
    }
}

static int recording_key_available_locked(const char *hex, uint64_t token) {
    for (RecordingKey *key = g_recording_keys; key; key = key->next)
        if (key->token != token && strcmp(key->hex, hex) == 0) return 0;
    return 1;
}

static int recording_declare_locked(TraceStreamOrigin *origin);
static int replay_origin_claimed_locked(uint64_t token);
static int replay_key_available_locked(const char *hex, uint64_t token);
static int replay_bind_origin_locked(TraceStreamOrigin *origin);
static int replay_prepare_child_locked(TraceStreamOrigin *parent,
                                        TraceStreamOrigin *child);

/* Recording caches have the same owner as the ID consuming their records.
 * They never own a state/thread/VM pointer. A parked attachment keeps this
 * allocation; detach destroys it, and a session mismatch resets it lazily.
 * A session opened without an attachment has one session-owned native
 * binding, usable only by that unattached opener. */
typedef struct TraceRecordingBinding {
    uint64_t session;
    uint64_t id;
    int last_line;              /* -1: no L yet */
    int line_dirty;             /* an A/N since the previous L */
    uint32_t scope_serial;
    int scope_native;
    double obs_dh_zero, obs_dh_small, obs_h_low, obs_scale;
    int obs_window;
} TraceRecordingBinding;
static TraceRecordingBinding g_native_recording;
/* Valid only during one tape-locked emit window. */
static TraceRecordingBinding *g_emit_stream = NULL;

static uint64_t recording_token_locked(void) {
    /* Zero is the unattached sentinel. Never wrap into a prior lifetime. */
    if (g_attachment_next == UINT64_MAX) {
        fprintf(stderr, "trace: attachment identity space exhausted\n");
        abort();
    }
    return g_attachment_next++;
}

void trace_attachment_init(EigsThread *thread) {
    tape_lock();
    thread->trace_attachment_token = recording_token_locked();
    tape_unlock();
}

void trace_state_init(EigsState *state) {
    tape_lock();
    state->trace_state_token = recording_token_locked();
    tape_unlock();
}

void trace_attachment_destroy(EigsThread *thread) {
    tape_lock();
    free(thread->trace_recording);
    thread->trace_recording = NULL;
    origin_release_locked(thread->trace_origin);
    thread->trace_origin = NULL;
    thread->trace_attachment_token = 0;
    tape_unlock();
}

static void recording_binding_reset(TraceRecordingBinding *binding,
                                    uint64_t id) {
    memset(binding, 0, sizeof(*binding));
    binding->session = g_tape_session;
    binding->id = id;
    binding->last_line = -1;
    binding->obs_dh_zero = OBSERVER_DH_ZERO_DEFAULT;
    binding->obs_dh_small = OBSERVER_DH_SMALL_DEFAULT;
    binding->obs_h_low = OBSERVER_H_LOW_DEFAULT;
    binding->obs_scale = OBSERVER_SCALE_DEFAULT;
    binding->obs_window = OBSERVER_WINDOW_N;
}

/* Caller holds g_tape_mu. Allocation order is only recording identity;
 * it is not correspondence between recordings and replay executions. */
static TraceRecordingBinding *recording_binding_locked(void) {
    if (!eigs_current) {
        if (g_native_opener_token &&
            g_native_session_token == g_native_opener_token)
            return &g_native_recording;
        fprintf(stderr, "trace: recording producer must attach to a state\n");
        return NULL;
    }
    TraceRecordingBinding *binding = eigs_current->trace_recording;
    if (binding && binding->session == g_tape_session) return binding;
    TraceStreamOrigin *origin = origin_current_locked();
    if (!recording_declare_locked(origin)) return NULL;
    if (!binding) {
        binding = xcalloc(1, sizeof(*binding));
        eigs_current->trace_recording = binding;
    }
    recording_binding_reset(binding, origin->record_id);
    return binding;
}

/* #1142 round 5: read-only witness for the sink-only DROP two functions
 * below. Takes the lock so the read is not a torn one. See trace.h for why
 * this exists at all — the one line it witnesses is invisible to every
 * other oracle in the tree. */
size_t trace_out_capacity(void) {
    tape_lock();
    size_t c = g_out_cap;
    tape_unlock();
    return c;
}

/* Caller holds g_tape_mu. */
static void out_flush_locked(void) {
    if (g_out_len && g_trace_fp) fwrite(g_out, 1, g_out_len, g_trace_fp);
    g_out_len = 0;
}

/* Grow to hold `add` more bytes. Never flushes: the record being formatted
 * lives in this buffer and tape_emit_end still has to hand its slice to the
 * sink. Caller holds g_tape_mu. */
static void out_reserve(size_t add) {
    if (g_out_len + add <= g_out_cap) return;
    size_t nc = g_out_cap ? g_out_cap : TAPE_OUT_INIT;
    while (nc < g_out_len + add) nc *= 2;
    char *nb = realloc(g_out, nc);
    if (!nb) return;            /* record truncates; tape stays parseable */
    g_out = nb;
    g_out_cap = nc;
}

/* Begin/end a record. tape_emit_begin takes the tape mutex and re-checks
 * activity under it, so a concurrent shutdown (which stores g_trace_fp /
 * g_trace_sink under the same lock) cannot tear a record. */
static int tape_emit_begin(void) {
    /* ACQUIRE load; pairs with trace_enabled_store under the lock. Cheap
     * gate so a program with no tape never touches the mutex. */
    if (!g_trace_enabled) return 0;
    tape_lock();
    if (!trace_out_active()) {
        tape_unlock();
        return 0;
    }
    g_emit_stream = recording_binding_locked();
    if (!g_emit_stream) {
        tape_unlock();
        return 0;
    }
    g_rec_at = g_out_len;
    return 1;
}

/* Commit the staged record: the sink sees ONE complete newline-terminated
 * record per call, and the FILE's bytes stay buffered until TAPE_OUT_FLUSH.
 * Caller holds the lock; the sink-flush-outside-lock mutant moves this out
 * of the critical section.
 *
 * One emit window can stage SEVERAL records: a scope transition
 * (`S <fn> <depth> <serial>`) or an `O cfg` diff is formatted into the same
 * window as the A/N record that triggered it. eigs_embed.h and
 * docs/EMBEDDING.md promise the sink "ONE complete newline-terminated
 * record per call" — the shape the EigenOS M11 journal consumes, one call
 * one journal entry — so the hand-off SPLITS at every newline here, under
 * the lock. The byte stream over all calls is unchanged; only the call
 * boundaries are. (Handing the window over whole made 3 of 12 calls carry
 * two records on a single state, and 536-762 of ~3000 on two — a consumer
 * that treats a call as a record dropped every `A` that followed an `S`.)
 * A trailing fragment with no newline can only come from an out_reserve
 * OOM truncation; it is handed over as-is rather than dropped.
 *
 * The newline scan is a hand-rolled loop, not memchr: the sink IS the
 * freestanding tape path (EigenOS M11's journal), and `memchr` is not on
 * tools/freestanding_allowlist.txt nor implemented in
 * src/freestanding/mini_libc.c, so calling it here would fail
 * `make freestanding-check`. Record lengths are tens of bytes. */
static void sink_hand_off(const char *p, size_t left) {
    while (left) {
        size_t rec = 0;
        while (rec < left && p[rec] != '\n') rec++;
        if (rec < left) rec++;          /* the record owns its newline */
        g_trace_sink(p, rec, g_trace_sink_ud);
        p += rec;
        left -= rec;
    }
}

static void sink_flush(void) {
    size_t n = g_out_len - g_rec_at;
    if (g_trace_sink && n) sink_hand_off(g_out + g_rec_at, n);
    /* Sink-only (the freestanding profile, EigenOS M11's journal): nothing
     * will ever fwrite these bytes, and the sink already owns them, so the
     * staging area rewinds to where this record started. WITHOUT this line
     * g_out_len only ever grows and the tape output buffer grows WITH THE
     * TAPE — unbounded memory on the one profile that has no filesystem to
     * spill to (measured on the mutant: +14,092 KB of RSS over 14.3 MB of
     * sink bytes, against 136 KB on this tree). No tape check can see it:
     * every record is still well-formed and every byte still reaches the
     * sink. The witness is trace_out_capacity() — pinned by the
     * `sink-only-bounded` case in src/embed_concurrent.c, and killed by the
     * `sink-only-no-drop` mutant. */
    if (!g_trace_fp) g_out_len = g_rec_at;          /* sink-only: drop */
    else if (g_out_len >= TAPE_OUT_FLUSH) out_flush_locked();
}

static void tape_emit_end(void) {
    sink_flush();               /* commit-under-lock */
    g_emit_stream = NULL;
    tape_unlock();
}

static int trace_out_active(void) {
    return g_trace_fp != NULL || g_trace_sink != NULL;
}

static void tp_write(const char *s, size_t n) {
    if (!s || !n) return;
    if (g_out_len + n > g_out_cap) {
        out_reserve(n);
        if (g_out_len + n > g_out_cap) {
            if (g_out_cap <= g_out_len) return;
            n = g_out_cap - g_out_len;
        }
    }
    memcpy(g_out + g_out_len, s, n);
    g_out_len += n;
}

static void tp_putc(int c) {
    if (g_out_len >= g_out_cap) {
        out_reserve(1);
        if (g_out_len >= g_out_cap) return;
    }
    g_out[g_out_len++] = (char)c;
}

static void tp_puts(const char *s) { tp_write(s, strlen(s)); }

static void tp_printf(const char *fmt, ...) {
    char buf[128];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if (n >= (int)sizeof buf) n = (int)sizeof buf - 1;
    tp_write(buf, (size_t)n);
}

static int association_number(const char **text, uint64_t *out) {
    const char *p = *text;
    if (*p < '0' || *p > '9') return 0;
    uint64_t n = 0;
    do {
        unsigned digit = (unsigned)(*p++ - '0');
        if (n > (UINT64_MAX - digit) / 10) return 0;
        n = n * 10 + digit;
    } while (*p >= '0' && *p <= '9');
    if (n == UINT64_MAX || (*p && *p != ' ')) return 0;
    *out = n;
    *text = p;
    return 1;
}

static int association_hex(const char *text) {
    size_t n = 0;
    for (; text[n]; n++) {
        if (n == TRACE_STREAM_KEY_MAX * 2 ||
            !((text[n] >= '0' && text[n] <= '9') ||
              (text[n] >= 'a' && text[n] <= 'f'))) return 0;
    }
    return n > 0 && n % 2 == 0;
}

int trace_parse_association(const char *payload, TraceAssociation *out) {
    if (!payload || !out) return 0;
    memset(out, 0, sizeof(*out));
    const char *p = payload;
    if (!association_number(&p, &out->lifetime) || !out->lifetime || *p++ != ' ' ||
        !association_number(&p, &out->state) || *p++ != ' ' ||
        !association_number(&p, &out->spawn_base) || *p++ != ' ') return 0;
    if (strncmp(p, "root ", 5) == 0) {
        out->kind = 'r';
        p += 5;
        if (strcmp(p, "-") == 0) return 1;
        if (!association_hex(p)) return 0;
        out->key_hex = p;
        return 1;
    }
    if (strncmp(p, "host ", 5) == 0) {
        out->kind = 'h';
        p += 5;
        if (!out->state || !association_hex(p)) return 0;
        out->key_hex = p;
        return 1;
    }
    if (strncmp(p, "child ", 6) == 0) {
        out->kind = 'c';
        p += 6;
        return out->state && association_number(&p, &out->parent) && *p++ == ' ' &&
               association_number(&p, &out->occurrence) && out->occurrence && !*p;
    }
    out->kind = 'l';
    return out->state && strcmp(p, "local") == 0;
}

/* Declare undeclared ancestors first, without recursive C calls. Descriptors
 * may outlive their attachment, but contain only owned descriptors/scalars. */
static int recording_declare_locked(TraceStreamOrigin *origin) {
    TraceStreamOrigin **chain = NULL;
    size_t count = 0, capacity = 0;
    for (TraceStreamOrigin *p = origin; p; p = p->parent) {
        if (p->record_session == g_tape_session && p->declared) break;
        if (p->key_hex && !recording_key_available_locked(p->key_hex, p->token)) {
            fprintf(stderr, "trace: duplicate host stream key; refusing recording binding\n");
            free(chain);
            return 0;
        }
        if (count == capacity) {
            capacity = capacity ? capacity * 2 : 8;
            chain = xrealloc(chain, capacity * sizeof(*chain));
        }
        chain[count++] = p;
        if (p->token == g_stream_opener_token) break;
    }
    g_rec_at = g_out_len;
    while (count) {
        TraceStreamOrigin *p = chain[--count];
        uint64_t id = 0;
        if (p->token != g_stream_opener_token) {
            if (g_stream_next == UINT64_MAX) {
                fprintf(stderr, "trace: recording stream identity space exhausted\n");
                free(chain);
                sink_flush();
                return 0;
            }
            id = g_stream_next++;
        }
        p->record_session = g_tape_session;
        p->record_id = id;
        p->declared = 1;
        tp_printf("B %llu ", (unsigned long long)id);
        tp_printf("%llu ", (unsigned long long)p->token);
        tp_printf("%llu ", (unsigned long long)p->state);
        tp_printf("%llu ", (unsigned long long)p->spawn_next);
        if (p->token == g_stream_opener_token) {
            tp_puts("root ");
            tp_puts(p->key_hex ? p->key_hex : "-");
        } else if (p->parent) {
            tp_printf("child %llu ", (unsigned long long)p->parent->record_id);
            tp_printf("%llu", (unsigned long long)p->occurrence);
        } else if (p->key_hex) {
            tp_puts("host ");
            tp_puts(p->key_hex);
        } else {
            tp_puts("local");
        }
        tp_putc('\n');
        if (p->key_hex) {
            RecordingKey *key = xcalloc(1, sizeof(*key));
            key->hex = xstrdup(p->key_hex);
            key->token = p->token;
            key->next = g_recording_keys;
            g_recording_keys = key;
        }
    }
    free(chain);
    sink_flush();
    return 1;
}

int trace_bind_stream(const char *key) {
    if (!key || !*key || !eigs_current) return 0;
    if (eigs_current->vm && eigs_current->vm->execute_depth) return 0;
    size_t len = 0;
    while (len <= TRACE_STREAM_KEY_MAX && key[len]) len++;
    if (len > TRACE_STREAM_KEY_MAX) return 0;
    static const char hex[] = "0123456789abcdef";
    char *encoded = malloc(len * 2 + 1);
    if (!encoded) return 0;
    for (size_t i = 0; i < len; i++) {
        encoded[i * 2] = hex[(unsigned char)key[i] >> 4];
        encoded[i * 2 + 1] = hex[(unsigned char)key[i] & 15];
    }
    encoded[len * 2] = 0;
    tape_lock();
    TraceStreamOrigin *origin = origin_current_locked();
    int late = (origin->record_session == g_tape_session && origin->declared) ||
               replay_origin_claimed_locked(origin->token);
    int ok = !origin->parent && !origin->key_hex && !late &&
             (!trace_out_active() ||
              (recording_key_available_locked(encoded, origin->token) &&
               (origin->token == g_stream_opener_token || g_stream_next != UINT64_MAX))) &&
             replay_key_available_locked(encoded, origin->token);
    if (ok) {
        origin->key_hex = encoded;
        encoded = NULL;
        if (g_replay_enabled_storage) ok = replay_bind_origin_locked(origin);
        if (ok && trace_out_active()) ok = recording_declare_locked(origin);
        if (!ok) {
            encoded = origin->key_hex;
            origin->key_hex = NULL;
        }
    }
    tape_unlock();
    free(encoded);
    return ok;
}

int trace_spawn_prepare(TraceSpawnBinding **out) {
    if (!out || !eigs_current) return 0;
    *out = NULL;
    tape_lock();
    TraceStreamOrigin *parent = origin_current_locked();
    int ok = !trace_out_active() || recording_declare_locked(parent);
    if (parent->spawn_next == UINT64_MAX - 1) ok = 0;
    TraceSpawnBinding *ticket = NULL;
    if (ok) {
        ticket = xcalloc(1, sizeof(*ticket));
        TraceStreamOrigin *child = xcalloc(1, sizeof(*child));
        ticket->origin = child;
        child->refs = 1;
        child->token = recording_token_locked();
        child->state = parent->state;
        child->parent = parent;
        parent->refs++;
        child->occurrence = ++parent->spawn_next;
        ok = !g_replay_enabled_storage || replay_prepare_child_locked(parent, child);
        if (ok && trace_out_active()) ok = recording_declare_locked(child);
    }
    if (!ok && ticket) {
        origin_release_locked(ticket->origin);
        free(ticket);
        ticket = NULL;
    }
    tape_unlock();
    if (!ok) {
        rt_error(EK_IO, 0, "spawn: trace stream correspondence unavailable");
        return 0;
    }
    *out = ticket;
    return 1;
}

void trace_spawn_attach(TraceSpawnBinding *binding) {
    if (!binding || !eigs_current) return;
    tape_lock();
    origin_release_locked(eigs_current->trace_origin);
    eigs_current->trace_origin = binding->origin;
    binding->origin->refs++;
    eigs_current->trace_attachment_token = binding->origin->token;
    tape_unlock();
}

void trace_spawn_release(TraceSpawnBinding *binding) {
    if (!binding) return;
    tape_lock();
    origin_release_locked(binding->origin);
    tape_unlock();
    free(binding);
}

uint64_t trace_external_stream_acquire(void) {
    tape_lock();
    uint64_t id = trace_out_active() && g_stream_next != UINT64_MAX
                ? g_stream_next++ : UINT64_MAX;
    tape_unlock();
    return id;
}

static void emit_tag(const char *kind) {
    tp_puts(kind);
    tp_printf(" %llu ", (unsigned long long)g_emit_stream->id);
}

/* Stamp `S <fn> <depth> <serial>` when the innermost frame differs from the
 * one the last S record named (by frame-instance serial, so two invocations
 * of the same function never merge). Dedup mirrors the L-record discipline:
 * scope transitions only cost tape bytes where a record actually needs them.
 * Callers must already have checked trace_out_active().
 *
 * Every A/N record belongs to the frame/native context that produced it.
 * Every per-binding `O win` record belongs to the frame that
 * RESOLVED the name — and that frame may not have assigned anything yet, e.g.
 * when the call widens a parameter's window before the body writes it, so the
 * transition cannot be left to the next A. */
static void emit_scope_transition(void) {
    uint32_t *last = &g_emit_stream->scope_serial;
    int *native = &g_emit_stream->scope_native;
    if (!eigs_current || !eigs_current->vm || g_vm.frame_count == 0) {
        /* A producer can write through trace_assign after an interpreted
         * callback has returned (embedders and AOT code both do).  Without
         * an explicit transition, the reader leaves cur_scope on that
         * callback's last frame and files this module-level assignment as a
         * dead local.  Serial 0 is the reader's module scope; name it so the
         * transition remains visible and reviewable on the tape. */
        if (*native) return;
        *last = 0;
        *native = 1;
        emit_tag("S");
        tp_puts("<native> 0 0\n");
        return;
    }
    CallFrame *f = &g_vm.frames[g_vm.frame_count - 1];
    if (!*native && f->call_serial == *last) return;
    *last = f->call_serial;
    *native = 0;
    /* The name is variable-length: write it with tp_puts, never through
     * tp_printf's 128-byte staging, which truncated a name of 121+ chars
     * together with the record's newline and glued the next record on (#1157). */
    emit_tag("S");
    tp_puts((f->chunk && f->chunk->name) ? f->chunk->name : "?");
    tp_printf(" %d %u\n", g_vm.frame_count - 1, f->call_serial);
}

/* ---- #1044/#1045 follow-up: the observer CONFIGURATION on the tape.
 *
 * Every verdict the runtime prints (`report of x`, the predicates, the
 * `--step`/DAP trajectory labels) is a function of the A records AND of five
 * knobs — three thresholds, the window depth, the characteristic scale — plus
 * a per-binding window override. The tape carried the assignments and not the
 * knobs, so a stepped tape classified at the state defaults and printed a
 * verdict the live run never gave (the phugoid `oscillating` vs `diverging`
 * case, and the older `set_observer_thresholds` instance of the same class).
 *
 * Shape chosen: record the configuration AS AN EVENT at the point it takes
 * effect, so a mid-run change replays in the right order — not a
 * header/snapshot stamp, which would have had to refuse mid-run changes.
 *
 * The state-level scalars are emitted by DIFF rather than from the knob
 * builtins: obs_cfg_sync compares the state's live configuration against what
 * THIS STREAM last emitted and emits an `O cfg` record when they differ,
 * before the next L/A/N/O-win record. Sibling attachments share current
 * state knobs but each must announce them in its own stream. The per-binding
 * window override (`set_observer_window of ["x", n]`) lives on an Env slot,
 * not on the state, so it has no cheap diff and is emitted from its builtin
 * through trace_obs_window_binding.
 *
 * Cost when no tape is open: nothing (the recording entry points return on
 * g_trace_enabled). With a tape open: five compares per L/A/N/O-win record. */
/* Emit `O cfg` when the state's observer configuration has moved since
 * what THIS STREAM last emitted. Callers hold g_tape_mu and have checked
 * trace_out_active(). A default-config stream writes no configuration record. */
static void obs_cfg_sync(void) {
    if (!eigs_current || !eigs_current->state) return;
    EigsState *st = eigs_current->state;
    TraceRecordingBinding *binding = g_emit_stream;
    if (st->obs_dh_zero  == binding->obs_dh_zero  &&
        st->obs_dh_small == binding->obs_dh_small &&
        st->obs_h_low    == binding->obs_h_low    &&
        st->obs_scale    == binding->obs_scale    &&
        st->obs_window   == binding->obs_window) return;
    binding->obs_dh_zero  = st->obs_dh_zero;
    binding->obs_dh_small = st->obs_dh_small;
    binding->obs_h_low    = st->obs_h_low;
    binding->obs_scale    = st->obs_scale;
    binding->obs_window   = st->obs_window;
    /* One field per tp_printf: its staging buffer is 128 bytes and five
     * %.17g fields in one call could silently truncate the record. */
    emit_tag("O");
    tp_puts("cfg ");
    tp_printf("%.17g ", binding->obs_dh_zero);
    tp_printf("%.17g ", binding->obs_dh_small);
    tp_printf("%.17g ", binding->obs_h_low);
    tp_printf("%d ",    binding->obs_window);
    tp_printf("%.17g\n", binding->obs_scale);
}

/* `set_observer_window of ["x", n]` — the per-binding override, recorded at
 * the point of the call (n == 0 clears it back to the default). The name is
 * the one the call site resolved; a reader re-resolves it with the same
 * innermost-first scope walk it uses for every other binding. */
void trace_obs_window_binding(const char *name, int n) {
    if (!name || !tape_emit_begin()) return;
    obs_cfg_sync();
    emit_scope_transition();
    emit_tag("O");
    tp_puts("win ");
    tp_puts(name);
    tp_printf(" %d\n", n);
    tape_emit_end();
}

/* #411: stamp the version header. Called once per tape-open (EIGS_TRACE
 * fopen, sink install) — a journal appended across several installs
 * carries one V record per session; replay verifies each. */
static void emit_header(void) {
    /* Caller holds g_tape_mu; formats + commits like any other record. */
    g_rec_at = g_out_len;
    tp_printf("V %d %s\n", TRACE_FORMAT_VERSION, EIGENSCRIPT_VERSION);
    sink_flush();
    /* Every stream starts from the tape defaults at V, independently of
     * which sibling most recently announced the shared state's knobs. */
    if (g_tape_session == UINT64_MAX) {
        fprintf(stderr, "trace: recording session identity space exhausted\n");
        abort();
    }
    g_tape_session++;
    g_stream_next = 1;
    recording_keys_clear_locked();
    g_stream_opener_token = eigs_current ? eigs_current->trace_attachment_token : 0;
    g_native_opener_token = 0;
    if (!eigs_current) {
        g_native_session_token = recording_token_locked();
        g_native_opener_token = g_native_session_token;
    }
    recording_binding_reset(&g_native_recording, 0);
    if (eigs_current) {
        (void)recording_declare_locked(origin_current_locked());
    } else {
        g_rec_at = g_out_len;
        tp_printf("B 0 %llu 0 0 root -\n", (unsigned long long)g_native_opener_token);
        sink_flush();
    }
}

void trace_set_sink(void (*cb)(const char *, size_t, void *), void *ud) {
    tape_lock();
    if (cb) {
        g_trace_sink = cb;
        g_trace_sink_ud = ud;
        trace_enabled_store(1);
        trace_arm_history_all();   /* a tape records every name's assigns */
        emit_header();             /* commits the V record to the new sink */
    } else {
        /* Nothing can be pending: every record is handed to the sink whole
         * inside tape_emit_end, under this same lock. */
        g_rec_at = g_out_len;
        g_trace_sink = NULL;
        g_trace_sink_ud = NULL;
        if (!g_trace_fp) trace_enabled_store(0);
    }
    tape_unlock();
}

/* Forward decl — implementation below; called from trace_init. */
static void trace_replay_init(void);

void trace_init(void) {
    if (g_trace_initialized) return;
    g_trace_initialized = 1;

    /* g_trace_enabled now means "a tape is open" (it used to be set
     * unconditionally so the prev-table worked; that made every program
     * pay history-recording costs — see g_trace_hist in trace.h). The
     * compiler turns on g_trace_hist when the program actually contains
     * a temporal query; a tape implies full recording, so set both
     * below once the tape opens. */

    /* Phase 3 — if EIGS_REPLAY is set, open that tape for streaming reads.
     * Done first so trace_init can succeed even if EIGS_TRACE is unset. */
    trace_replay_init();

#if EIGENSCRIPT_FREESTANDING
    /* Tape files need a filesystem; EIGS_TRACE is a hosted tool. The
     * in-memory temporal machinery (g_trace_hist etc.) is unaffected. */
    return;
#else
    const char *path = getenv("EIGS_TRACE");
    if (!path || !*path) return;

    /* NB: bare fopen("w") here means the trace file's mode is 0666 & ~umask
     * — under a permissive umask it could land world-writable (CodeQL
     * cpp/world-writable-file-creation #101). Left as-is because the path
     * comes from the EIGS_TRACE env var, which already carries the accepted
     * cpp/path-injection alert #107 at this line; any rewrite that uses
     * open() instead of fopen() moves the sink line and CodeQL files a
     * "new" path-injection alert in addition to keeping #107 open. The
     * trace file is opt-in (env var off by default) and the surrounding
     * filesystem is operator-controlled, so the residual exposure is
     * limited. */
    g_trace_fp = fopen(path, "w");
    if (!g_trace_fp) {
        fprintf(stderr, "trace: cannot open EIGS_TRACE=%s: %s\n",
                path, strerror(errno));
        return;
    }
    setvbuf(g_trace_fp, NULL, _IOFBF, 64 * 1024);
    /* #1142: tape bytes are buffered in g_out now, NOT in the FILE's stdio
     * buffer, so stdio's own exit-time flush no longer covers a process that
     * exits without calling trace_shutdown. Without this, up to
     * TAPE_OUT_FLUSH bytes of the FILE tape are lost at exit — a regression
     * against the pre-#1142 fputc path. trace_shutdown is idempotent, so the
     * CLI's own call is unaffected.
     *
     * Round 5 correction — this registration is the CLI's, and ONLY the
     * CLI's. trace_init has exactly one caller in the tree (src/main.c:131);
     * no embed entry point calls it, so an embedder never reaches this line
     * and EIGS_TRACE opens no file for one. The earlier wording here said it
     * also covered "an embedder that leaks its state". It does not, and it
     * cannot.
     *
     * Nor does an embedder need it: the embed tape is the SINK
     * (trace_set_sink), and sink_flush hands each record over inside
     * tape_emit_end — under the lock, before the emitting call returns — so
     * a sink embedder has no buffered tail at all. Measured, not reasoned:
     * the `exit-tail` case in src/embed_concurrent.c forks two children that
     * run the same program through the same sink, one calling
     * eigs_close/eigs_trace_shutdown and one exiting straight out of
     * main(), and requires the two byte streams to be IDENTICAL. */
    atexit(trace_shutdown);
    tape_lock();
    trace_enabled_store(1);
    trace_arm_history_all();   /* a tape records every name's assigns */
    emit_header();
    tape_unlock();
#endif /* !EIGENSCRIPT_FREESTANDING */
}

/* ----- Phase 3: replay reader.
 *
 * Streams an existing tape (written by a prior EIGS_TRACE run) and serves
 * the N records to nondet builtins in order via trace_replay_take. L and
 * A records are skipped — the contract is that nondet outcomes appear in
 * the same order both runs, not that line numbers line up exactly. */

typedef struct ReplayAssociation {
    uint64_t id;
    TraceAssociation data;
    struct ReplayAssociation *next;
} ReplayAssociation;
typedef struct ReplayClaim {
    uint64_t token, state, id, spawn_next;
    uint64_t recorded_lifetime, session;
    int retired;
    struct ReplayClaim *next;
} ReplayClaim;
typedef struct ReplayPending {
    uint64_t stream_id;
    char *name, *value;
    struct ReplayPending *next;
} ReplayPending;

/* A source owns everything needed to resume it. Pending IDs are implicitly
 * keyed by (this context's generation, session, stream); a namespace advances
 * only after all its pending values have been consumed. Claims retain scalar
 * lifetime correspondence across V, never a live thread/state pointer. */
typedef struct ReplayContext {
    FILE *file;
    char *memory;
    size_t memory_len, memory_pos;
    char *line;
    size_t line_cap;
    int strict, eof, boundary, read_failed;
    uint64_t generation, session;
    uint64_t owner_token, owner_lifetime;
    ReplayAssociation *associations;
    ReplayClaim *claims;
    ReplayPending *pending;
} ReplayContext;
static ReplayContext *g_replay_file;
static ReplayContext *g_replay_memory;
static ReplayContext *g_replay_active;
static uint64_t g_replay_generation;
static __thread uint64_t g_native_replay_token;

static void replay_associations_clear(ReplayContext *ctx) {
    while (ctx->associations) {
        ReplayAssociation *next = ctx->associations->next;
        free((char *)ctx->associations->data.key_hex);
        free(ctx->associations);
        ctx->associations = next;
    }
}

static void replay_context_free(ReplayContext *ctx) {
    if (!ctx) return;
#if !EIGENSCRIPT_FREESTANDING
    if (ctx->file) fclose(ctx->file);
#endif
    free(ctx->memory);
    free(ctx->line);
    while (ctx->pending) {
        ReplayPending *next = ctx->pending->next;
        free(ctx->pending->name); free(ctx->pending->value);
        free(ctx->pending); ctx->pending = next;
    }
    replay_associations_clear(ctx);
    while (ctx->claims) {
        ReplayClaim *next = ctx->claims->next;
        free(ctx->claims);
        ctx->claims = next;
    }
    free(ctx);
}

static void replay_note_owner(ReplayContext *ctx) {
    if (g_replay_generation == UINT64_MAX) {
        fprintf(stderr, "trace: replay source identity space exhausted\n");
        abort();
    }
    ctx->generation = ++g_replay_generation;
    ctx->session = 1;
    if (eigs_current) ctx->owner_token = eigs_current->trace_attachment_token;
    else {
        /* One OS-thread lifetime, not one install: suspending a file for a
         * memory tape must not change that file owner's identity. */
        if (!g_native_replay_token) g_native_replay_token = recording_token_locked();
        ctx->owner_token = g_native_replay_token;
    }
}

static uint64_t replay_caller_token(void) {
    return eigs_current ? eigs_current->trace_attachment_token : g_native_replay_token;
}

static ReplayAssociation *replay_association_locked(ReplayContext *ctx, uint64_t id) {
    for (ReplayAssociation *row = ctx->associations; row; row = row->next)
        if (row->id == id) return row;
    return NULL;
}

static ReplayClaim *replay_claim_locked(ReplayContext *ctx, uint64_t token) {
    for (ReplayClaim *claim = ctx->claims; claim; claim = claim->next)
        if (claim->token == token) return claim;
    return NULL;
}

static void replay_forget_origin_locked(uint64_t token) {
    ReplayContext *contexts[2] = {g_replay_file, g_replay_memory};
    for (int i = 0; i < 2; i++) {
        ReplayContext *ctx = contexts[i];
        if (!ctx) continue;
        ReplayClaim **slot = &ctx->claims;
        while (*slot && (*slot)->token != token) slot = &(*slot)->next;
        if (*slot) {
            ReplayClaim *old = *slot;
            if (old->session == ctx->session) {
                /* Reserve this session's ID/key even after detach; a new
                 * attachment cannot steal a consumed stream's identity. */
                old->retired = 1;
            } else {
                *slot = old->next;
                free(old);
            }
        }
    }
}

static int replay_origin_claimed_locked(uint64_t token) {
    return (g_replay_file && replay_claim_locked(g_replay_file, token)) ||
           (g_replay_memory && replay_claim_locked(g_replay_memory, token));
}

static int replay_key_available_locked(const char *hex, uint64_t token) {
    ReplayContext *ctx = g_replay_active;
    if (!ctx) return 1;
    for (ReplayClaim *claim = ctx->claims; claim; claim = claim->next) {
        if (claim->session != ctx->session) continue;
        ReplayAssociation *row = replay_association_locked(ctx, claim->id);
        if (claim->token != token && row && row->data.key_hex &&
            strcmp(row->data.key_hex, hex) == 0) return 0;
    }
    return 1;
}

/* Consume `<kind> <uint64> ` and return the payload.  Signs, overflow,
 * missing digits and missing separators are malformed rather than aliases. */
static int replay_record_prefix(ReplayContext *ctx, char kind, uint64_t *id, char **payload) {
    char *p = ctx->line;
    if (p[0] != kind || p[1] != ' ') return 0;
    p += 2;
    if (*p < '0' || *p > '9') return -1;
    uint64_t n = 0;
    char *end = p;
    while (*end >= '0' && *end <= '9') {
        unsigned digit = (unsigned)(*end - '0');
        if (n > (UINT64_MAX - digit) / 10) return -1;
        n = n * 10 + digit;
        end++;
    }
    /* UINT64_MAX is the allocator's failure sentinel, not a stream id. */
    if (n == UINT64_MAX || *end != ' ') return -1;
    *id = n;
    *payload = end + 1;
    return **payload ? 1 : -1;
}

static void replay_malformed_id(ReplayContext *ctx) {
    fprintf(stderr, "trace: malformed v%d stream id in record '%s'; refusing to replay\n",
            TRACE_FORMAT_VERSION, ctx->line ? ctx->line : "");
#if EIGENSCRIPT_FREESTANDING
    abort();
#else
    _exit(3);
#endif
}

static void replay_malformed_value(const char *value) {
    fprintf(stderr, "trace: malformed v%d stream id or N value '%s'; refusing to replay\n",
            TRACE_FORMAT_VERSION, value ? value : "");
#if EIGENSCRIPT_FREESTANDING
    abort();
#else
    _exit(3);
#endif
}

/* #1637: THE return-kind table of every taped builtin -- each name that
 * records an N value (TRACE_NONDET_*, ARG_GUARD_TAPED/PRETAKE,
 * trace_nondet_value). A replayed value of a kind its builtin cannot return
 * (a hand-edited `file_exists=1`, a `random_normal=true`) would hand the
 * program a value no live run could produce, at exit 0; it is refused
 * instead. tools/tape_kinds_check.sh fails when a taped name is missing here
 * or a row names nothing taped. Names a host records through the embedding
 * API declare their kinds with eigs_trace_declare_kind; a name in neither
 * table is refused at replay. Bits are ValType (TK below). */
#define TK(t) (1u << (t))
#define TK_NUM_  TK(VAL_NUM)
#define TK_STR_  TK(VAL_STR)
#define TK_BOOL_ TK(VAL_BOOL)
#define TK_NULL_ TK(VAL_NULL)
#define TK_LIST_ TK(VAL_LIST)
#define TK_BUF_  TK(VAL_BUFFER)
static const struct { const char *name; unsigned kinds; } k_tape_kinds[] = {
    {"args",                 TK_LIST_},
    {"audio_capture_open",   TK_NUM_},
    {"audio_capture_read",   TK_BUF_ | TK_NULL_},
    {"audio_stream_queued",  TK_NUM_},
    {"clock_unix",           TK_NUM_},
    {"eigen_generate",       TK_LIST_ | TK_STR_},   /* str: the recorded over-length refusal */
    {"env_get",              TK_STR_},
    {"exe_path",             TK_STR_},
    {"file_exists",          TK_BOOL_},
    {"getcwd",               TK_STR_},
    {"gfx_read",             TK_LIST_ | TK_NULL_},
    {"http_post",            TK_STR_},
    {"http_request_body",    TK_STR_},
    {"http_request_headers", TK_STR_},
    {"http_session_id",      TK_STR_},
    {"is_dir",               TK_BOOL_},
    {"is_file",              TK_BOOL_},
    {"ls",                   TK_LIST_},
    {"mkdir",                TK_BOOL_},
    {"monotonic_ms",         TK_NUM_},
    {"monotonic_ns",         TK_NUM_},
    {"net_accept",           TK_NUM_ | TK_NULL_},
    {"net_dial",             TK_NUM_ | TK_NULL_},
    {"net_listen",           TK_NUM_ | TK_NULL_},
    {"net_port",             TK_NUM_ | TK_NULL_},
    {"net_recv",             TK_BUF_ | TK_NULL_},
    {"net_send",             TK_NUM_},
    {"random",               TK_NUM_},
    {"random_hex",           TK_STR_},
    {"random_int",           TK_NUM_},
    {"random_normal",        TK_LIST_ | TK_NULL_},
    {"read_bytes",           TK_LIST_ | TK_NULL_},
    {"read_bytes_buf",       TK_BUF_ | TK_NULL_ | TK_NUM_},  /* num: the recorded over-cap size */
    {"read_text",            TK_STR_},
    {"tensor_load",          TK_LIST_ | TK_NULL_},  /* the [rows, cols] over-cap verdict */
};

/* Host-declared kinds (eigs_trace_declare_kind). Small, append-only. */
static struct { char *name; unsigned kinds; } *g_host_kinds;
static int g_host_kinds_n, g_host_kinds_cap;
static pthread_mutex_t g_host_kinds_mu = PTHREAD_MUTEX_INITIALIZER;

static unsigned core_tape_kinds(const char *fn) {
    for (size_t i = 0; i < sizeof k_tape_kinds / sizeof k_tape_kinds[0]; i++)
        if (strcmp(fn, k_tape_kinds[i].name) == 0) return k_tape_kinds[i].kinds;
    return 0;
}

int trace_declare_kind(const char *name, unsigned kinds) {
    if (!name || !*name || !kinds || core_tape_kinds(name)) return 0;
    pthread_mutex_lock(&g_host_kinds_mu);
    for (int i = 0; i < g_host_kinds_n; i++)
        if (strcmp(g_host_kinds[i].name, name) == 0) {
            g_host_kinds[i].kinds = kinds;
            pthread_mutex_unlock(&g_host_kinds_mu);
            return 1;
        }
    if (g_host_kinds_n == g_host_kinds_cap) {
        int nc = g_host_kinds_cap ? g_host_kinds_cap * 2 : 8;
        void *nk = realloc(g_host_kinds, (size_t)nc * sizeof *g_host_kinds);
        if (!nk) { pthread_mutex_unlock(&g_host_kinds_mu); return 0; }
        g_host_kinds = nk; g_host_kinds_cap = nc;
    }
    g_host_kinds[g_host_kinds_n].name = xstrdup(name);
    g_host_kinds[g_host_kinds_n].kinds = kinds;
    g_host_kinds_n++;
    pthread_mutex_unlock(&g_host_kinds_mu);
    return 1;
}

static unsigned replay_expected_kinds(const char *fn) {
    if (!fn) return 0;
    unsigned k = core_tape_kinds(fn);
    if (k) return k;
    pthread_mutex_lock(&g_host_kinds_mu);
    for (int i = 0; i < g_host_kinds_n; i++)
        if (strcmp(g_host_kinds[i].name, fn) == 0) { k = g_host_kinds[i].kinds; break; }
    pthread_mutex_unlock(&g_host_kinds_mu);
    return k;
}

/* "a bool", "a list or null" */
static void kinds_text(unsigned kinds, char *buf, size_t n) {
    static const ValType order[] = {VAL_NUM, VAL_STR, VAL_BOOL, VAL_LIST, VAL_DICT,
                                    VAL_BUFFER, VAL_NULL};
    size_t used = 0; int first = 1;
    buf[0] = '\0';
    for (size_t i = 0; i < sizeof order / sizeof order[0]; i++) {
        if (!(kinds & TK(order[i]))) continue;
        int w = snprintf(buf + used, n - used, "%s%s", first ? "a " : " or ",
                         val_type_name(order[i]));
        if (w < 0 || (size_t)w >= n - used) break;
        used += (size_t)w; first = 0;
    }
}

static int replay_value_is_marker(const char *value) {
    return value && (value[0] == '<' || (unsigned char)value[0] == 0xE2);
}

int trace_replay_off_owner_thread(void) {
    tape_lock();
    int off = g_replay_active &&
              replay_caller_token() != g_replay_active->owner_token;
    tape_unlock();
    return off;
}

int trace_replay_refuse_off_owner(const char *fn) {
    (void)fn;
    return 0; /* Key/causal correspondence is resolved at TAKE, not by pthread. */
}

/* Context-local parser functions never borrow the active source's buffer. */
static int read_tape_line(ReplayContext *ctx);
static int replay_check_header(ReplayContext *ctx);
static int replay_vline_ok(ReplayContext *ctx);

int trace_set_replay_mem(const char *bytes, size_t len, int strict) {
    tape_lock();
    if (!bytes) {
        ReplayContext *old = g_replay_memory;
        g_replay_memory = NULL;
        g_replay_active = g_replay_file;
        replay_enabled_store(g_replay_active != NULL);
        replay_context_free(old);
        tape_unlock();
        return 1;
    }

    ReplayContext *candidate = calloc(1, sizeof(*candidate));
    if (!candidate) { tape_unlock(); return 0; }
    candidate->memory = malloc(len ? len : 1);
    if (!candidate->memory) {
        replay_context_free(candidate);
        tape_unlock();
        return 0;
    }
    memcpy(candidate->memory, bytes, len);
    candidate->memory_len = len;
    candidate->strict = strict;
    /* Validate all V headers using only candidate-owned cursor/parser state.
     * No active pointer, pending value, claim or strict flag changes on 0. */
    int ok = replay_check_header(candidate);
    size_t first_body = candidate->memory_pos;
    while (ok) {
        int n = read_tape_line(candidate);
        if (n < 0) { if (candidate->read_failed) ok = 0; break; }
        if (candidate->line[0] == 'V') ok = replay_vline_ok(candidate);
    }
    if (!ok) {
        replay_context_free(candidate);
        tape_unlock();
        return 0;
    }
    candidate->memory_pos = first_body;
    replay_note_owner(candidate);
    ReplayContext *old = g_replay_memory;
    g_replay_memory = candidate;
    g_replay_active = candidate;
    replay_enabled_store(1);
    replay_context_free(old);
    tape_unlock();
    return 1;
}

static void trace_replay_init(void) {
#if EIGENSCRIPT_FREESTANDING
    return;
#else
    const char *path = getenv("EIGS_REPLAY");
    if (!path || !*path) return;
    ReplayContext *ctx = xcalloc(1, sizeof(*ctx));
    ctx->file = fopen(path, "r");
    if (!ctx->file) {
        fprintf(stderr, "trace: cannot open EIGS_REPLAY=%s: %s\n", path, strerror(errno));
        replay_context_free(ctx);
        _exit(3);
    }
    ctx->strict = eigs_env_flag("EIGS_REPLAY_STRICT");
    if (!replay_check_header(ctx)) {
        replay_context_free(ctx);
        _exit(3);
    }
    tape_lock();
    replay_note_owner(ctx);
    g_replay_file = ctx;
    /* A prior explicit memory source keeps precedence, if present. */
    g_replay_active = g_replay_memory ? g_replay_memory : ctx;
    replay_enabled_store(1);
    tape_unlock();
#endif
}

static void replay_shutdown(void) {
    ReplayContext *file = g_replay_file, *memory = g_replay_memory;
    g_replay_active = g_replay_file = g_replay_memory = NULL;
    replay_enabled_store(0);
    replay_context_free(memory);
    replay_context_free(file);
}

/* getline without _GNU_SOURCE. Allocation/I/O failure is distinct from EOF;
 * a candidate install refuses and an active source reports failure. */
static int read_tape_line(ReplayContext *ctx) {
    if (ctx->read_failed) return -1;
    size_t len = 0;
    for (;;) {
        if (len + 2 > ctx->line_cap) {
            size_t nc = ctx->line_cap ? ctx->line_cap * 2 : 256;
            char *nb = realloc(ctx->line, nc);
            if (!nb) { ctx->read_failed = 1; return -1; }
            ctx->line = nb; ctx->line_cap = nc;
        }
        int c = EOF;
        if (ctx->memory) {
            if (ctx->memory_pos < ctx->memory_len)
                c = (unsigned char)ctx->memory[ctx->memory_pos++];
        }
#if !EIGENSCRIPT_FREESTANDING
        else if (ctx->file) {
            c = fgetc(ctx->file);
            if (c == EOF && ferror(ctx->file)) { ctx->read_failed = 1; return -1; }
        }
#endif
        if (c == EOF || c == '\n') {
            ctx->line[len] = '\0';
            return c == EOF && !len ? -1 : (int)len;
        }
        ctx->line[len++] = (char)c;
    }
}

/* #411: validate the V record in this context's parser buffer against this
 * binary. One rule, no migration path: format AND runtime version must
 * match exactly, else the tape is refused with the reason on stderr.
 * (The tape is plain text — a deliberate override is editing line 1.) */
static int replay_vline_ok(ReplayContext *ctx) {
    const char *p = ctx->line;
    if (p[0] != 'V' || p[1] != ' ') {
        if (p[0] == 'V') {
            /* A V-shaped line that isn't `V ` is a torn/corrupted header
             * (truncated journal write), not a missing one. */
            fprintf(stderr, "trace: malformed tape version header '%s'; "
                    "refusing to replay (docs/TRACE.md)\n", p);
            return 0;
        }
        fprintf(stderr, "trace: tape has no version header — recorded by a "
                "pre-versioning EigenScript or not a tape; refusing to "
                "replay (docs/TRACE.md)\n");
        return 0;
    }
    char *end = NULL;
    long fmt = strtol(p + 2, &end, 10);
    if (end == p + 2 || *end != ' ') {
        fprintf(stderr, "trace: malformed tape version header '%s'; "
                "refusing to replay (docs/TRACE.md)\n", p);
        return 0;
    }
    if (fmt != TRACE_FORMAT_VERSION) {
        fprintf(stderr, "trace: tape format v%ld, this binary reads v%d — "
                "refusing to replay; re-record on this version "
                "(docs/TRACE.md)\n", fmt, TRACE_FORMAT_VERSION);
        return 0;
    }
    const char *ver = end + 1;
    if (strcmp(ver, EIGENSCRIPT_VERSION) != 0) {
        fprintf(stderr, "trace: tape recorded on EigenScript %s, this binary "
                "is %s — refusing to replay; a tape is valid only for the "
                "version that recorded it (docs/TRACE.md)\n",
                ver, EIGENSCRIPT_VERSION);
        return 0;
    }
    return 1;
}

/* #411: the first record of a tape must be a matching V header. */
static int replay_check_header(ReplayContext *ctx) {
    if (read_tape_line(ctx) < 0) {
        fprintf(stderr, "trace: empty replay tape — refusing to replay "
                "(docs/TRACE.md)\n");
        return 0;
    }
    return replay_vline_ok(ctx);
}

/* Un-escape a tape-format quoted string in place. Reads the byte stream
 * starting at `*p` (which must point one past the opening quote), writes
 * the decoded bytes to `out` (max `out_cap-1` plus NUL), advances `*p`
 * past the closing quote. Returns the decoded length on success, -1 on
 * malformed input. Handles \", \\, \n, \r, \xNN; everything else literal. */
static int unescape_string(const char **p, char *out, int out_cap) {
    int n = 0;
    const char *s = *p;
    while (*s && *s != '"') {
        if (n + 1 >= out_cap) return -1;
        if (*s == '\\') {
            s++;
            switch (*s) {
                case '"':  out[n++] = '"';  s++; break;
                case '\\': out[n++] = '\\'; s++; break;
                case 'n':  out[n++] = '\n'; s++; break;
                case 'r':  out[n++] = '\r'; s++; break;
                case 'x': {
                    s++;
                    int hi = -1, lo = -1;
                    if (s[0]) hi = (s[0] >= '0' && s[0] <= '9') ? s[0] - '0'
                                  : (s[0] >= 'a' && s[0] <= 'f') ? s[0] - 'a' + 10
                                  : (s[0] >= 'A' && s[0] <= 'F') ? s[0] - 'A' + 10 : -1;
                    if (hi >= 0 && s[1]) lo = (s[1] >= '0' && s[1] <= '9') ? s[1] - '0'
                                  : (s[1] >= 'a' && s[1] <= 'f') ? s[1] - 'a' + 10
                                  : (s[1] >= 'A' && s[1] <= 'F') ? s[1] - 'A' + 10 : -1;
                    if (hi < 0 || lo < 0) return -1;
                    out[n++] = (char)((hi << 4) | lo);
                    s += 2;
                    break;
                }
                default: return -1;
            }
        } else {
            out[n++] = *s++;
        }
    }
    if (*s != '"') return -1;
    *p = s + 1;
    out[n] = '\0';
    return n;
}

/* Parse one value from the tape encoding. Cursor-style: advances `*p`
 * past the parsed value. Returns a Value with +1 refcount on success.
 *
 * Recognized shapes:
 *   null | true | false              immediates
 *   <num>                            strtod-parseable
 *   "<str>"                          escapes per unescape_string
 *   [v, v, …]                        list
 *   b[num, num, …]                   buffer (the leading 'b' disambiguates
 *                                    from a list of bare numbers)
 *   {"k": v, …}                      dict
 *
 * Markers like <fn>, <heap>, <list:N>, …<truncated…> are NOT replayable;
 * the caller falls back to live source in that case. */
static void skip_ws(const char **p) { while (**p == ' ') (*p)++; }

static int at_token_boundary(char c) {
    return c == '\0' || c == ' ' || c == ',' || c == ']' || c == '}' || c == ':';
}

static Value *parse_value_p(const char **p) {
    skip_ws(p);
    char c = **p;
    if (c == '\0') return NULL;

    if (strncmp(*p, "null", 4) == 0 && at_token_boundary((*p)[4])) {
        *p += 4; return make_null();
    }
    /* #1637 (format v6): true/false are the bool values. A v5 tape wrote
     * a predicate's answer as 1/0; it is refused by the version check, never
     * read as a number here. */
    if (strncmp(*p, "true", 4) == 0 && at_token_boundary((*p)[4])) {
        *p += 4; return make_bool(1);
    }
    if (strncmp(*p, "false", 5) == 0 && at_token_boundary((*p)[5])) {
        *p += 5; return make_bool(0);
    }

    if (c == '"') {
        const char *q = *p + 1;
        size_t cap = strlen(q) + 1;
        char *buf = malloc(cap);
        if (!buf) return NULL;
        int n = unescape_string(&q, buf, (int)cap);
        if (n < 0) { free(buf); return NULL; }
        Value *v = make_str(buf);
        free(buf);
        *p = q;
        return v;
    }

    if (c == 'b' && (*p)[1] == '[') {
        *p += 2;
        skip_ws(p);
        double *data = NULL;
        int count = 0, cap = 0;
        if (**p != ']') {
            for (;;) {
                skip_ws(p);
                char *end = NULL;
                double d = strtod(*p, &end);
                if (end == *p) { free(data); return NULL; }
                if (count >= cap) {
                    int nc = cap ? cap * 2 : 8;
                    double *nd = realloc(data, (size_t)nc * sizeof(double));
                    if (!nd) { free(data); return NULL; }
                    data = nd; cap = nc;
                }
                data[count++] = d;
                *p = end;
                skip_ws(p);
                if (**p == ',') { (*p)++; continue; }
                if (**p == ']') break;
                free(data); return NULL;
            }
        }
        (*p)++;
        Value *v = xcalloc(1, sizeof(Value));
        v->type = VAL_BUFFER;
        v->refcount = 1;
        v->data.buffer.count = count;
        v->data.buffer.data = xcalloc(count > 0 ? (size_t)count : 1, sizeof(double));
        if (count > 0) memcpy(v->data.buffer.data, data, (size_t)count * sizeof(double));
        free(data);
        return v;
    }

    if (c == '[') {
        (*p)++;
        skip_ws(p);
        Value *list = make_list(8);
        if (**p == ']') { (*p)++; return list; }
        for (;;) {
            Value *elem = parse_value_p(p);
            if (!elem) { val_decref(list); return NULL; }
            list_append(list, elem);
            val_decref(elem);
            skip_ws(p);
            if (**p == ',') { (*p)++; continue; }
            if (**p == ']') break;
            val_decref(list); return NULL;
        }
        (*p)++;
        return list;
    }

    if (c == '{') {
        (*p)++;
        skip_ws(p);
        Value *dict = make_dict(8);
        if (**p == '}') { (*p)++; return dict; }
        for (;;) {
            skip_ws(p);
            if (**p != '"') { val_decref(dict); return NULL; }
            const char *q = *p + 1;
            size_t kcap = strlen(q) + 1;
            char *kbuf = malloc(kcap);
            if (!kbuf) { val_decref(dict); return NULL; }
            int n = unescape_string(&q, kbuf, (int)kcap);
            if (n < 0) { free(kbuf); val_decref(dict); return NULL; }
            *p = q;
            skip_ws(p);
            if (**p != ':') { free(kbuf); val_decref(dict); return NULL; }
            (*p)++;
            Value *val = parse_value_p(p);
            if (!val) { free(kbuf); val_decref(dict); return NULL; }
            dict_set(dict, kbuf, val);
            val_decref(val);
            free(kbuf);
            skip_ws(p);
            if (**p == ',') { (*p)++; continue; }
            if (**p == '}') break;
            val_decref(dict); return NULL;
        }
        (*p)++;
        return dict;
    }

    /* <fn>, <heap>, <list:N>, <dict:N>, <buffer:N>, …<truncated…> —
     * not replayable. Caller falls back to live source. */
    if (c == '<' || (unsigned char)c == 0xE2) return NULL;

    char *end = NULL;
    double d = strtod(*p, &end);
    if (end == *p) return NULL;
    *p = end;
    return make_num(d);
}

static Value *parse_value(const char *s) {
    const char *p = s;
    skip_ws(&p);
    Value *v = parse_value_p(&p);
    if (!v) return NULL;
    skip_ws(&p);
    if (*p != '\0') { val_decref(v); return NULL; }
    return v;
}

static void replay_add_association_locked(ReplayContext *ctx, uint64_t id,
                                          const char *payload) {
    TraceAssociation parsed;
    if (!trace_parse_association(payload, &parsed) ||
        ((parsed.kind == 'r') != (id == 0)) || replay_association_locked(ctx, id))
        replay_malformed_id(ctx);
    for (ReplayAssociation *old = ctx->associations; old; old = old->next) {
        if (old->data.lifetime == parsed.lifetime ||
            (old->data.key_hex && parsed.key_hex &&
             strcmp(old->data.key_hex, parsed.key_hex) == 0))
            replay_malformed_id(ctx);
        if (parsed.kind == 'c' && old->data.kind == 'c' &&
            old->data.parent == parsed.parent &&
            old->data.occurrence == parsed.occurrence) replay_malformed_id(ctx);
    }
    if (parsed.kind == 'c') {
        ReplayAssociation *parent = replay_association_locked(ctx, parsed.parent);
        if (!parent || parent->id == id || parent->data.state != parsed.state)
            replay_malformed_id(ctx);
    }
    ReplayAssociation *row = xcalloc(1, sizeof(*row));
    row->id = id;
    row->data = parsed;
    if (parsed.key_hex) row->data.key_hex = xstrdup(parsed.key_hex);
    row->next = ctx->associations;
    ctx->associations = row;
    /* Remember the first opener even if it makes no TAKE before advance. */
    if (ctx->session == 1 && id == 0) ctx->owner_lifetime = parsed.lifetime;
}

/* Read one useful record without materializing another attachment's Value.
 * A validated V is retained as a boundary; only explicit advance clears it. */
static int replay_scan_locked(ReplayContext *ctx) {
    if (ctx->eof || ctx->boundary || ctx->read_failed) return 0;
    for (;;) {
        int len = read_tape_line(ctx);
        if (len < 0) { ctx->eof = !ctx->read_failed; return 0; }
        if (len && ctx->line[0] == 'V') {
            if (!replay_vline_ok(ctx)) {
#if EIGENSCRIPT_FREESTANDING
                abort();
#else
                _exit(3);
#endif
            }
            ctx->boundary = 1;
            return 0;
        }
        if (len < 2 || !strchr("BLASNO", ctx->line[0])) continue;
        uint64_t id = 0;
        char *payload = NULL;
        if (replay_record_prefix(ctx, ctx->line[0], &id, &payload) <= 0)
            replay_malformed_id(ctx);
        if (ctx->line[0] == 'B') {
            replay_add_association_locked(ctx, id, payload);
            return 1;
        }
        if (!replay_association_locked(ctx, id)) replay_malformed_id(ctx);
        if (ctx->line[0] != 'N') continue;
        char *eq = strchr(payload, '=');
        if (!eq || eq == payload) replay_malformed_id(ctx);
        *eq = 0;
        ReplayPending *pending = xcalloc(1, sizeof(*pending));
        pending->stream_id = id;
        pending->name = xstrdup(payload);
        pending->value = xstrdup(eq + 1);
        ReplayPending **tail = &ctx->pending;
        while (*tail) tail = &(*tail)->next;
        *tail = pending;
        return 1;
    }
}

static ReplayClaim *replay_claim_association_locked(ReplayContext *ctx,
                                                   uint64_t token, uint64_t state,
                                                   ReplayAssociation *row) {
    if (!row || !token || ((state == 0) != (row->data.state == 0))) return NULL;
    ReplayClaim *reuse = NULL;
    for (ReplayClaim *claim = ctx->claims; claim; claim = claim->next) {
        if (claim->token == token) {
            if (claim->retired) return NULL;
            if (claim->session == ctx->session)
                return claim->id == row->id ? claim : NULL;
            reuse = claim;
        }
        if (claim->session != ctx->session) continue;
        if (claim->id == row->id) return NULL;
        ReplayAssociation *old = replay_association_locked(ctx, claim->id);
        if ((claim->state == state) != (old->data.state == row->data.state))
            return NULL;
    }
    ReplayClaim *claim = reuse;
    if (!claim) {
        claim = xcalloc(1, sizeof(*claim));
        claim->next = ctx->claims;
        ctx->claims = claim;
    }
    claim->token = token;
    claim->state = state;
    claim->id = row->id;
    claim->spawn_next = row->data.spawn_base;
    claim->recorded_lifetime = row->data.lifetime;
    claim->session = ctx->session;
    return claim;
}

static ReplayClaim *replay_resolve_origin_locked(ReplayContext *ctx,
                                                TraceStreamOrigin *origin) {
    uint64_t token = origin ? origin->token : replay_caller_token();
    uint64_t state = origin ? origin->state : 0;
    ReplayClaim *claim = replay_claim_locked(ctx, token);
    if (claim && claim->session == ctx->session) return claim;
    int root = token && token == ctx->owner_token;
    uint64_t lifetime = claim ? claim->recorded_lifetime
                             : (root ? ctx->owner_lifetime : 0);
    if (!root && !lifetime && (!origin || !origin->key_hex)) return NULL;
    for (;;) {
        for (ReplayAssociation *row = ctx->associations; row; row = row->next) {
            int continuation = lifetime && row->data.lifetime == lifetime;
            int opener = root && ctx->session == 1 && row->id == 0;
            int keyed = origin && origin->key_hex && row->data.key_hex &&
                        (row->data.kind == 'h' || row->data.kind == 'r') &&
                        strcmp(row->data.key_hex, origin->key_hex) == 0;
            if (continuation || opener || keyed)
                return replay_claim_association_locked(ctx, token, state, row);
        }
        if (!replay_scan_locked(ctx)) return NULL;
    }
}

static int replay_bind_origin_locked(TraceStreamOrigin *origin) {
    return g_replay_active && replay_resolve_origin_locked(g_replay_active, origin) != NULL;
}

static int replay_prepare_child_locked(TraceStreamOrigin *parent,
                                       TraceStreamOrigin *child) {
    ReplayContext *ctx = g_replay_active;
    if (!ctx) return 0;
    ReplayClaim *p = replay_resolve_origin_locked(ctx, parent);
    if (!p || p->spawn_next == UINT64_MAX - 1) return 0;
    uint64_t occurrence = ++p->spawn_next;
    for (;;) {
        for (ReplayAssociation *row = ctx->associations; row; row = row->next) {
            if (row->data.kind == 'c' && row->data.parent == p->id &&
                row->data.occurrence == occurrence)
                return replay_claim_association_locked(ctx, child->token, child->state, row) != NULL;
        }
        if (!replay_scan_locked(ctx)) return 0;
    }
}

/* Host must park/join participating producers before calling. Reading another
 * thread's VM depth would itself be unsynchronized; only the caller's ordinary
 * VM/native boundary is mechanically checked here. No scheduler/exit change. */
int trace_replay_advance_session(void) {
    if (eigs_current && ((eigs_current->vm && eigs_current->vm->execute_depth) ||
                         eigs_current->native_call_depth)) return 0;
    tape_lock();
    ReplayContext *ctx = g_replay_active;
    if (!ctx) { tape_unlock(); return 0; }
    /* Pending means there is still an observable current-session outcome.
     * Read-ahead may create one for a sibling, but can never discard it. */
    while (!ctx->pending && replay_scan_locked(ctx)) {}
    if (ctx->pending || !ctx->boundary || ctx->read_failed || ctx->session == UINT64_MAX) {
        tape_unlock();
        return 0;
    }
    replay_associations_clear(ctx);
    ReplayClaim **slot = &ctx->claims;
    while (*slot) {
        ReplayClaim *claim = *slot;
        if (claim->retired) { *slot = claim->next; free(claim); }
        else slot = &claim->next;
    }
    ctx->session++;
    ctx->boundary = 0;
    ctx->eof = 0;
    /* Keep scalar lifetime claims for continuing attachments. Each is
     * re-associated lazily against this session's metadata before use. */
    tape_unlock();
    return 1;
}

int trace_replay_take(const char *fn, Value **out) {
    if (!out) return 0;
    replay_take_lock();
    ReplayContext *ctx = g_replay_active;
    if (!ctx) { replay_take_unlock(); return 0; }
    ReplayClaim *claim = replay_resolve_origin_locked(ctx, origin_current_locked());
    if (!claim) {
        replay_take_unlock();
        if (eigs_current) rt_error(EK_IO, 0, "%s: replay stream has no host/causal binding",
                                   fn ? fn : "nondet");
        else fprintf(stderr, "trace: replay producer has no host/causal binding\n");
        *out = make_null();
        return 1;
    }
    uint64_t wanted = claim->id;
    ReplayPending **slot;
    for (;;) {
        slot = &ctx->pending;
        while (*slot && (*slot)->stream_id != wanted) slot = &(*slot)->next;
        if (*slot || !replay_scan_locked(ctx)) break;
    }
    if (!*slot) {
        int read_failed = ctx->read_failed;
        replay_take_unlock();
        const char *reason = read_failed ? "cannot read its replay source"
                                        : "has no matching recorded N value";
        if (eigs_current)
            rt_error(EK_IO, 0, "%s: replay stream %llu %s", fn ? fn : "nondet",
                     (unsigned long long)wanted, reason);
        else fprintf(stderr, "trace: replay stream %llu %s\n",
                     (unsigned long long)wanted, reason);
        *out = make_null();
        return 1;
    }
    ReplayPending *hit = *slot;
    *slot = hit->next;
    if (fn && strcmp(hit->name, fn) != 0) {
        if (ctx->strict) {
            fprintf(stderr, "trace: replay name mismatch — tape has '%s', program called '%s' (EIGS_REPLAY_STRICT — aborting)\n", hit->name, fn);
#if EIGENSCRIPT_FREESTANDING
            abort();
#else
            _exit(3);
#endif
        }
        fprintf(stderr, "trace: replay name mismatch — expected '%s', got '%s' (using anyway)\n",
                fn, hit->name);
    }
    Value *v = parse_value(hit->value);
    int marker = replay_value_is_marker(hit->value);
    if (!v && !marker) replay_malformed_value(hit->value);
    {
        /* #1637: the record's kind must be one its builtin can return. */
        const char *who = fn ? fn : hit->name;
        unsigned want = replay_expected_kinds(who);
        if (!want || (v && !(want & TK(v->type)))) {
            char wtxt[96];
            kinds_text(want, wtxt, sizeof wtxt);
            if (!want)
                fprintf(stderr, "trace: tape format v%d record 'N %llu %s=%s': %s has no "
                        "declared return kind (a host name declares it with "
                        "eigs_trace_declare_kind); refusing to replay\n", TRACE_FORMAT_VERSION,
                        (unsigned long long)hit->stream_id, hit->name, hit->value, who);
            else
                fprintf(stderr, "trace: tape format v%d record 'N %llu %s=%s': %s returns %s, "
                        "the tape holds a %s; refusing to replay\n", TRACE_FORMAT_VERSION,
                        (unsigned long long)hit->stream_id, hit->name, hit->value,
                        who, wtxt, val_type_name(v->type));
#if EIGENSCRIPT_FREESTANDING
            abort();
#else
            _exit(3);
#endif
        }
    }
    free(hit->name); free(hit->value); free(hit);
    if (!v) { replay_take_unlock(); return 0; }
    *out = v;
    replay_take_unlock();
    return 1;
}

/* #739: release THIS THREAD's prev-table. Idempotent, and a no-op with no
 * thread attached (the atexit path runs detached). Must run while
 * `eigs_current` still points at the owning thread — the slots it drops are
 * that thread's, and their destructors read the bridge macros — which is why
 * eigs_thread_detach calls it beside the other Phase-5 destructors, and why
 * eigs_close calls trace_shutdown before the global env dies.
 *
 * This is the half that used to be fused into trace_shutdown, and the fusion
 * was the bug: every ext_http connection worker called trace_shutdown when it
 * finished a request, so one process-wide teardown ran per HTTP request —
 * closing the tape after the FIRST request (every later request's records
 * silently lost), unregistering an embedder's sink, and decref'ing prev-table
 * slots recorded by other, still-live threads. */
void trace_thread_release(void) {
    if (!eigs_current || !g_prev_tab) return;
    PrevEntry *tab = g_prev_tab;
    int cap = g_prev_cap;
    /* Clear the thread's view FIRST: a destructor reached from slot_decref
     * below must not find a half-freed table through the bridge macros. */
    g_prev_tab = NULL;
    g_prev_cap = 0;
    g_prev_count = 0;
    for (int i = 0; i < cap; i++) {
        PrevEntry *e = &tab[i];
        if (!e->name) continue;
        if (e->has_prev)    slot_decref(e->prev);
        if (e->has_current) slot_decref(e->current);
        for (int j = 0; j < e->hist_count; j++)
            hist_drop(&e->history[j]);
        /* #868: the ring holds a counted ref per live slot. Walk the LIVE
         * ordinals, not 0..occ_cap — an unfilled ring has zeroed slots, and
         * slot_decref on a zeroed slot is not the same as a no-op. */
        for (int j = 0; j < e->occ_count; j++) {
            int idx = occ_index_of(e, e->occ_total - j);
            if (idx >= 0) slot_decref(e->occ[idx].value);
        }
        free(e->history);
        free(e->lc);
        free(e->occ);
    }
    free(tab);
}

/* Process-wide teardown: the tape, the sink, the replay reader. One process,
 * one tape — so this belongs to whoever owns the process (main / eigs_close /
 * atexit), NEVER to a per-connection or per-task worker. A worker that wants
 * to clean up after itself wants trace_thread_release. */
void trace_shutdown(void) {
    /* #1142 round 2: the WHOLE teardown — sink/fp, enabled flags, replay
     * reader, arm-set free — runs under the tape mutex. The unlocked
     * fast path in tape_emit_begin is gone so a sibling cannot read
     * g_trace_sink while we store NULL. Arm names are only freed when
     * this is the last live state: an explicit eigs_trace_shutdown while
     * siblings remain must not free a set those siblings still compile
     * against. */
    tape_lock();
    out_flush_locked();         /* buffered tape bytes reach the FILE first */
#if !EIGENSCRIPT_FREESTANDING
    if (g_trace_fp) {
        fflush(g_trace_fp);
        fclose(g_trace_fp);
        g_trace_fp = NULL;
    }
#endif
    free(g_out);                /* the tape output buffer is tape-lifetime */
    g_out = NULL;
    g_out_cap = 0;
    g_out_len = 0;
    g_rec_at  = 0;
    g_trace_sink = NULL;        /* shutdown-clear-sink */
    g_trace_sink_ud = NULL;
    trace_enabled_store(0);
    recording_keys_clear_locked();
    replay_shutdown();
    /* Publish the wildcard BEFORE freeing names so an ACQUIRE of
     * g_arm_all == 1 skips arm_set_has (which would UAF). */
    arm_all_store(1);
    arm_gen_bump();
    if (eigs_process_state_count() <= 1) {
        /* #1145: g_arm_mu taken INSIDE g_tape_mu. No path holds g_arm_mu
         * across a tape lock, so this is an order, not a cycle. */
        arm_lock();
        for (int i = 0; i < g_arm_count; i++) free(g_arm_names[i]);
        free(g_arm_names);
        g_arm_names = NULL;
        g_arm_count = 0;
        g_arm_cap = 0;
        arm_unlock();
    }
    tape_unlock();              /* shutdown-unlock */

    trace_thread_release();
}

void trace_line(int line) {
    /* Replay correspondence comes from host/causal metadata, never LINE order. */
    if (!tape_emit_begin()) return;
    obs_cfg_sync();
    if (line == g_emit_stream->last_line && !g_emit_stream->line_dirty) {
        tape_emit_end();
        return;
    }
    emit_tag("L");
    tp_printf("%d\n", line);
    g_emit_stream->last_line = line;
    g_emit_stream->line_dirty = 0;
    tape_emit_end();
}

/* Strings get quoted + truncated. \, ", \n, \r escaped so the tape is
 * one event per text line. Truncation marker is a trailing '…' (UTF-8
 * ellipsis) inside the closing quote. */
static void write_string(const char *s) {
    if (!s) { tp_puts("\"\""); return; }
    tp_putc('"');
    int written = 0;
    for (const char *p = s; *p && written < TRACE_STR_MAX; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '"' || c == '\\') { tp_putc('\\'); tp_putc(c); written += 2; }
        else if (c == '\n')        { tp_puts("\\n"); written += 2; }
        else if (c == '\r')        { tp_puts("\\r"); written += 2; }
        else                       { tp_putc(c);    written += 1; }
    }
    if ((int)strlen(s) > TRACE_STR_MAX) tp_puts("…");
    tp_putc('"');
}

/* Format a heap or tracked Value*. Numeric heap values unwrap to their
 * number; collections show their size for at-a-glance scanning. */
static void write_value_ptr(Value *v) {
    if (!v) { tp_puts("null"); return; }
    switch (v->type) {
        case VAL_NUM:          tp_printf("%.17g", VAL_NUM_RAW(v)); break;
        case VAL_NULL:         tp_puts("null"); break;
        case VAL_STR:          write_string(v->data.str); break;
        case VAL_LIST:         tp_printf("<list:%d>", v->data.list.count); break;
        case VAL_DICT:         tp_printf("<dict:%d>", v->data.dict.count); break;
        case VAL_FN:           tp_puts("<fn>"); break;
        case VAL_BUILTIN:      tp_puts("<builtin>"); break;
        case VAL_BUFFER:       tp_printf("<buffer:%d>", v->data.buffer.count); break;
        case VAL_JSON_RAW:     tp_puts("<json>"); break;
        case VAL_TEXT_BUILDER: tp_puts("<text>"); break;
        case VAL_BOOL:         tp_puts(v->data.boolean ? "true" : "false"); break;
        /* No `default:` — -Werror=switch (Makefile CFLAGS) forces a new
         * ValType to choose its tape rendering here. */
    }
}

static void write_slot(EigsSlot s) {
    if (slot_is_num(s))  { tp_printf("%.17g", SLOT_NUM_RAW(s)); return; }
    if (slot_is_null(s)) { tp_puts("null"); return; }
    if (slot_is_bool(s)) { tp_puts(slot_as_bool(s) ? "true" : "false"); return; }
    if (slot_is_heap(s)) { write_value_ptr(slot_as_ptr(s)); return; }
    tp_puts("<unknown>");
}

static void trace_assign_ex(const char *name, EigsSlot value, int filtered,
                            int record_prev, int source_line) {
    /* Prev-map update runs regardless of EIGS_TRACE — `prev of x` is a
     * language feature, not a tape feature. The tape write below is
     * still gated on a tape (file or sink) being open. record_prev == 0 is
     * the #1063 slot case: a slot write whose name THIS chunk does not
     * interrogate still belongs on the tape (the DAP stepper stops on A
     * records; test_dap's breakpoint inside `double` is one) but must not
     * enter the name-keyed prev table, where a callee's same-named local
     * would rewrite the caller's `prev`. */
    if (record_prev) prev_record_assign(name, value, filtered, source_line);

    if (!tape_emit_begin()) return;
    obs_cfg_sync();
    if (!name) name = "?";
    /* #539 v2: scope-transition record. When the innermost frame differs
     * from the one the last S record named (by frame-instance serial, so
     * two invocations of the same function never merge), stamp
     *   S <fn> <depth> <serial>
     * before the A record. Dedup mirrors the L-record discipline: scope
     * transitions only cost tape bytes at call boundaries that actually
     * assign. Replay skips S like A; only the stepper folds them. */
    emit_scope_transition();
    emit_tag("A");
    tp_puts(name);
    tp_putc('=');
    write_slot(value);
    tp_putc('\n');
    g_emit_stream->line_dirty = 1;
    tape_emit_end();
}

/* #830: the public, producer-facing entry point — an explicit "record this
 * assignment" request, honoured unconditionally. Every producer that is not
 * the bytecode compiler (the AOT's emitted C, an embedder, a hand-assembled
 * chunk) reaches the history through here and needs no arming ritual it has
 * no way to perform. */
void trace_assign(const char *name, EigsSlot value) {
    trace_assign_ex(name, value, 0, 1, -1);
}

void trace_assign_at_line(const char *name, EigsSlot value, int line) {
    trace_assign_ex(name, value, 0, 1, line);
}

/* #1063: tape record only -- see trace_assign_ex. */
void trace_assign_tape_only(const char *name, EigsSlot value) {
    trace_assign_ex(name, value, 1, 0, -1);
}

/* The narrowed twin, for callers running a chunk the bytecode compiler
 * scanned (EigsChunk.compiler_scanned): #827's armed-name set is a valid
 * per-assign CPU filter exactly there, because that scan is what populated
 * it. Retention is bounded by the suffix-minima pruning either way — this is
 * an optimization, never a safety property. */
void trace_assign_filtered(const char *name, EigsSlot value) {
    trace_assign_ex(name, value, 1, 1, -1);
}

void trace_assign_filtered_at_line(const char *name, EigsSlot value, int line) {
    trace_assign_ex(name, value, 1, 1, line);
}

/* ----- Full-fidelity writer for nondet records.
 *
 * Recursive emission of lists/dicts; full string content; cap the whole
 * record at TRACE_NONDET_MAX bytes. The `budget` is decremented on every
 * byte written. When budget runs out, the rest of the record collapses
 * to a single "…<truncated:RESIDUAL>" marker so Phase 3 replay knows the
 * record cannot be used for full determinism. */

static void wf_putc(int c, int *budget) {
    if (*budget <= 0) return;
    tp_putc(c); (*budget)--;
}
static void wf_puts(const char *s, int *budget) {
    while (*s && *budget > 0) { tp_putc(*s++); (*budget)--; }
}
static void wf_printf(int *budget, const char *fmt, ...) {
    if (*budget <= 0) return;
    char buf[64];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n >= (int)sizeof(buf)) n = (int)sizeof(buf) - 1;
    if (n > *budget) n = *budget;
    tp_write(buf, (size_t)n);
    *budget -= n;
}

static void write_string_full(const char *s, int *budget) {
    wf_putc('"', budget);
    if (s) {
        for (const char *p = s; *p && *budget > 0; p++) {
            unsigned char c = (unsigned char)*p;
            if (c == '"' || c == '\\') { wf_putc('\\', budget); wf_putc(c, budget); }
            else if (c == '\n')        { wf_puts("\\n", budget); }
            else if (c == '\r')        { wf_puts("\\r", budget); }
            else if (c < 0x20)         { wf_printf(budget, "\\x%02x", c); }
            else                       { wf_putc(c, budget); }
        }
    }
    wf_putc('"', budget);
}

static void write_value_ptr_full(Value *v, int *budget) {
    if (*budget <= 0) return;
    if (!v) { wf_puts("null", budget); return; }
    switch (v->type) {
        case VAL_NUM:  wf_printf(budget, "%.17g", VAL_NUM_RAW(v)); break;
        case VAL_NULL: wf_puts("null", budget); break;
        case VAL_BOOL: wf_puts(v->data.boolean ? "true" : "false", budget); break;
        case VAL_STR:  write_string_full(v->data.str, budget); break;
        case VAL_LIST: {
            wf_putc('[', budget);
            int n = v->data.list.count;
            for (int i = 0; i < n && *budget > 0; i++) {
                if (i) wf_puts(", ", budget);
                write_value_ptr_full(v->data.list.items[i], budget);
            }
            wf_putc(']', budget);
            break;
        }
        case VAL_DICT: {
            wf_putc('{', budget);
            int n = v->data.dict.count;
            for (int i = 0; i < n && *budget > 0; i++) {
                if (i) wf_puts(", ", budget);
                write_string_full(v->data.dict.keys[i], budget);
                wf_puts(": ", budget);
                write_value_ptr_full(v->data.dict.vals[i], budget);
            }
            wf_putc('}', budget);
            break;
        }
        case VAL_BUFFER: {
            /* Leading 'b' disambiguates from VAL_LIST: both serialize the
             * bracketed numeric body, but only buffers are restored as
             * VAL_BUFFER on replay. */
            wf_putc('b', budget);
            wf_putc('[', budget);
            int n = v->data.buffer.count;
            for (int i = 0; i < n && *budget > 0; i++) {
                if (i) wf_puts(", ", budget);
                wf_printf(budget, "%.17g", v->data.buffer.data[i]);
            }
            wf_putc(']', budget);
            break;
        }
        case VAL_FN:       wf_puts("<fn>", budget); break;
        case VAL_BUILTIN:  wf_puts("<builtin>", budget); break;
        /* Opaque placeholders (byte-identical to the old `default:` output;
         * these have no replayable N-record encoding). Enumerated so that
         * -Werror=switch forces a new ValType to choose its encoding here. */
        case VAL_JSON_RAW:     wf_puts("<heap>", budget); break;
        case VAL_TEXT_BUILDER: wf_puts("<heap>", budget); break;
    }
}

void trace_nondet_value(const char *fn, Value *v) {
    if (!tape_emit_begin()) return;
    obs_cfg_sync();
    emit_scope_transition();
    if (!fn) fn = "?";
    emit_tag("N");
    tp_puts(fn);
    tp_putc('=');
    int budget = TRACE_NONDET_MAX;
    write_value_ptr_full(v, &budget);
    if (budget <= 0) tp_puts("…<truncated>");
    tp_putc('\n');
    g_emit_stream->line_dirty = 1;
    tape_emit_end();
}
