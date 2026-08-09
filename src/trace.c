/* ================================================================
 * EigenScript Trace — implementation (Phase 1 + 2).
 * ================================================================
 * Tape format (text, one record per line):
 *   V <format> <runtime-ver>    version header — always the first record
 *   L <line>                    source-line event
 *   A <name>=<value>            name-keyed assignment delta
 *   N <fn>=<value>              nondeterministic builtin return
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

int g_trace_enabled = 0;
int g_replay_enabled = 0;
int g_trace_obs_hist = 0;
int g_trace_hist = 0;
int g_trace_current_line = 0;

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
static int      g_arm_all   = 0;
static uint32_t g_arm_gen   = 1;

static int arm_set_has(const char *name) {
    for (int i = 0; i < g_arm_count; i++)
        if (strcmp(g_arm_names[i], name) == 0) return 1;
    return 0;
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
static int      g_occ_all   = 0;   /* interactive REPL only — see trace.h */
static uint32_t g_occ_gen   = 1;
static int      g_occ_window = 0;   /* 0 = not yet resolved */

int trace_occ_window(void) {
    if (g_occ_window) return g_occ_window;
    g_occ_window = TRACE_OCC_WINDOW_DEFAULT;
    const char *e = getenv("EIGS_OCC_WINDOW");
    if (e && *e) {
        char *end = NULL;
        long v = strtol(e, &end, 10);
        if (end && *end == '\0' && v >= 1) {
            if (v > TRACE_OCC_WINDOW_MAX) v = TRACE_OCC_WINDOW_MAX;
            g_occ_window = (int)v;
        }
    }
    return g_occ_window;
}

static int occ_set_has(const char *name) {
    if (g_occ_all) return 1;
    for (int i = 0; i < g_occ_count; i++)
        if (strcmp(g_occ_names[i], name) == 0) return 1;
    return 0;
}

void trace_arm_occurrences_all(void) {
    if (g_occ_all) return;
    g_occ_all = 1;
    g_occ_gen++;
    trace_arm_history_all();
}

void trace_arm_occurrences_name(const char *name) {
    if (!name || g_occ_all) return;
    /* The ring is fed from prev_record_assign, which only runs when the
     * line-history is armed for this name — so arm that too. */
    trace_arm_history_name(name);
    if (occ_set_has(name)) return;
    if (g_occ_count >= g_occ_cap) {
        int nc = g_occ_cap ? g_occ_cap * 2 : 8;
        char **nn = realloc(g_occ_names, (size_t)nc * sizeof(char *));
        if (!nn) return;         /* OOM: this name simply gets no ring */
        g_occ_names = nn;
        g_occ_cap = nc;
    }
    size_t len = strlen(name) + 1;
    char *copy = malloc(len);
    if (!copy) return;
    memcpy(copy, name, len);
    g_occ_names[g_occ_count++] = copy;
    g_occ_gen++;
}

/* Widen to the wildcard WITHOUT enabling recording. Separate from
 * trace_arm_history_all because `spawn` calls it: a program with no temporal
 * query must not start recording just because it made a thread. */
void trace_arm_history_all_mt(void) {
    if (g_arm_all) return;
    g_arm_all = 1;
    g_arm_gen++;
}

void trace_arm_history_all(void) {
    g_trace_hist = 1;
    trace_arm_history_all_mt();
}

void trace_arm_history_name(const char *name) {
    g_trace_hist = 1;
    if (!name || g_arm_all) return;
    if (arm_set_has(name)) return;
    if (g_arm_count >= g_arm_cap) {
        int nc = g_arm_cap ? g_arm_cap * 2 : 8;
        char **nn = realloc(g_arm_names, (size_t)nc * sizeof(char *));
        if (!nn) { trace_arm_history_all(); return; }  /* OOM: never narrow */
        g_arm_names = nn;
        g_arm_cap = nc;
    }
    size_t len = strlen(name) + 1;
    char *copy = malloc(len);
    if (!copy) { trace_arm_history_all(); return; }    /* OOM: never narrow */
    memcpy(copy, name, len);
    g_arm_names[g_arm_count++] = copy;
    g_arm_gen++;
}

void trace_history_disable(void) {
    g_trace_hist = 0;
    g_trace_obs_hist = 0;
}

/* g_prev_tab / g_prev_cap / g_prev_count are bridge macros onto EigsThread
 * (eigenscript.h), reached only with a thread attached. Every read path below
 * that can run during teardown or from atexit guards on `eigs_current` first. */

/* g_trace_current_line (exported, see trace.h) replaces the old static
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

static void prev_record_assign(const char *name, EigsSlot value, int filtered) {
    if (!eigs_current || !name) return;
    if (g_prev_count * PREV_LOAD_DEN >= g_prev_cap * PREV_LOAD_NUM) {
        prev_grow();
        if (!g_prev_tab) return;
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
        if (!e->armed) return;
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

    /* Stamp with the current VM line as cached by trace_line. */
    int line = g_trace_current_line;
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
        if (!nh) return;
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
    if (!eigs_current || !name || !g_prev_tab) return;
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

Value *trace_state_at(int line) {
    Value *out = make_dict(g_prev_count > 0 ? g_prev_count : 8);
    if (!out || !g_prev_tab) return out;
    for (int i = 0; i < g_prev_cap; i++) {
        PrevEntry *e = &g_prev_tab[i];
        if (!e->name || e->hist_count == 0) continue;
        if (trace_name_is_internal(e->name)) continue;
        int idx = find_hist_idx_at_or_before(e, line);
        if (idx < 0) continue;
        Value *v = slot_to_value(e->history[idx].value);
        dict_set(out, e->name, v);
        val_decref(v);
    }
    return out;
}

static FILE *g_trace_fp = NULL;
static int   g_trace_initialized = 0;

/* Line dedupe state. g_last_line < 0 means "no line written yet, always
 * emit". g_line_dirty == 1 means an A or N event landed since the last
 * L, so the next L is meaningful even if numerically identical. */
static int g_last_line  = -1;
static int g_line_dirty = 0;

/* ----- Embed byte-sink seam (trace_set_sink).
 *
 * The freestanding profile has no filesystem, so EIGS_TRACE's fopen is
 * compiled out there — but the tape itself is just bytes. An embedder
 * (EigenOS M11: the machine journal) installs a sink callback and the
 * emit primitives below hand it complete record lines (newline
 * included); a record longer than the staging buffer arrives in
 * chunks, still in order. Installing a sink enables recording exactly
 * like EIGS_TRACE does hosted; the two paths are independent sinks of
 * the same byte stream (in practice an embedder uses one or the
 * other). All emitters funnel through tp_putc/tp_puts/tp_printf. */
static void (*g_trace_sink)(const char *bytes, size_t len, void *ud) = NULL;
static void *g_trace_sink_ud = NULL;
#define TRACE_SINK_LINEBUF 4096
static char   g_sink_buf[TRACE_SINK_LINEBUF];
static size_t g_sink_len = 0;

static void sink_flush(void) {
    if (g_trace_sink && g_sink_len) {
        g_trace_sink(g_sink_buf, g_sink_len, g_trace_sink_ud);
        g_sink_len = 0;
    }
}

static int trace_out_active(void) {
    return g_trace_fp != NULL || g_trace_sink != NULL;
}

static void tp_putc(int c) {
    if (g_trace_sink) {
        g_sink_buf[g_sink_len++] = (char)c;
        if (g_sink_len == TRACE_SINK_LINEBUF || c == '\n') sink_flush();
    }
    if (g_trace_fp) fputc(c, g_trace_fp);
}

static void tp_write(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) tp_putc(s[i]);
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

/* #539 v2: scope-transition dedup state. The last frame-instance serial
 * an S record was emitted for; 0 = none yet (serials start at 1). Reset
 * at every tape open so each session's first A record is preceded by its
 * scope. */
static uint32_t g_last_scope_serial = 0;

/* #411: stamp the version header. Called once per tape-open (EIGS_TRACE
 * fopen, sink install) — a journal appended across several installs
 * carries one V record per session; replay verifies each. */
static void emit_header(void) {
    tp_printf("V %d %s\n", TRACE_FORMAT_VERSION, EIGENSCRIPT_VERSION);
    g_last_scope_serial = 0;
}

void trace_set_sink(void (*cb)(const char *, size_t, void *), void *ud) {
    if (cb) {
        g_trace_sink = cb;
        g_trace_sink_ud = ud;
        g_sink_len = 0;
        g_last_line = -1;
        g_line_dirty = 0;
        g_trace_enabled = 1;
        trace_arm_history_all();   /* a tape records every name's assigns */
        emit_header();
    } else {
        sink_flush();
        g_trace_sink = NULL;
        g_trace_sink_ud = NULL;
        if (!g_trace_fp) g_trace_enabled = 0;
    }
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
    g_trace_enabled = 1;
    trace_arm_history_all();   /* a tape records every name's assigns */
    emit_header();
#endif /* !EIGENSCRIPT_FREESTANDING */
}

/* ----- Phase 3: replay reader.
 *
 * Streams an existing tape (written by a prior EIGS_TRACE run) and serves
 * the N records to nondet builtins in order via trace_replay_take. L and
 * A records are skipped — the contract is that nondet outcomes appear in
 * the same order both runs, not that line numbers line up exactly. */

static FILE *g_replay_fp = NULL;
static char *g_replay_line = NULL;     /* growable read buffer */
static size_t g_replay_cap = 0;
static int   g_replay_strict = 0;      /* EIGS_REPLAY_STRICT=1: mismatch is fatal */

/* Embed replay source (trace_set_replay_mem): the whole tape as bytes,
 * copied in (the embedder's buffer may go away). The freestanding
 * counterpart of EIGS_REPLAY — EigenOS M11 reads the journal from its
 * store and hands it here. */
static char  *g_replay_mem = NULL;
static size_t g_replay_mem_len = 0;
static size_t g_replay_mem_pos = 0;

/* #411: consume and verify the tape's V header(s). Defined below
 * read_tape_line; prints the refusal reason on failure. */
static int read_tape_line(void);
static int replay_check_header(void);
static int replay_vline_ok(void);

int trace_set_replay_mem(const char *bytes, size_t len, int strict) {
    if (!bytes) {
        free(g_replay_mem);
        g_replay_mem = NULL;
        g_replay_mem_len = 0;
        g_replay_mem_pos = 0;
        if (!g_replay_fp) g_replay_enabled = 0;
        return 1;
    }

    char *nm = malloc(len > 0 ? len : 1);
    if (!nm) return 0;   /* prior replay state untouched */
    memcpy(nm, bytes, len);

    /* Stage the new tape and validate EVERY session header up front (#411):
     * the first line must be a matching V record, and so must the header of
     * each appended session (a journal written across several sink installs).
     * Deferring a later header to the take loop would turn a refusable
     * install into a mid-eval abort of the host process — the return-0
     * contract exists so the embedder gets to handle refusal. */
    char  *om = g_replay_mem;
    size_t ol = g_replay_mem_len, op = g_replay_mem_pos;
    int    os = g_replay_strict, oe = g_replay_enabled;
    g_replay_mem = nm;
    g_replay_mem_len = len;
    g_replay_mem_pos = 0;
    g_replay_strict = strict;
    int ok = replay_check_header();
    while (ok) {
        if (read_tape_line() < 0) break;
        /* Any V-shaped line is a session header (or a torn one) —
         * replay_vline_ok refuses the malformed shapes loudly. */
        if (g_replay_line[0] == 'V') ok = replay_vline_ok();
    }
    if (!ok) {
        /* Version-and-reject (#411), atomically: the refused tape is
         * discarded and the PREVIOUS replay state — tape, strict mode,
         * enablement — survives untouched, never a half-armed replay. */
        free(nm);
        g_replay_mem = om;
        g_replay_mem_len = ol;
        g_replay_mem_pos = op;
        g_replay_strict = os;
        g_replay_enabled = oe;
        return 0;
    }
    free(om);
    g_replay_mem_pos = 0;
    g_replay_enabled = 1;
    return 1;
}

static void trace_replay_init(void) {
#if EIGENSCRIPT_FREESTANDING
    return;   /* tape files need a filesystem; replay is a hosted tool */
#else
    const char *path = getenv("EIGS_REPLAY");
    if (!path || !*path) return;
    g_replay_fp = fopen(path, "r");
    if (!g_replay_fp) {
        fprintf(stderr, "trace: cannot open EIGS_REPLAY=%s: %s\n",
                path, strerror(errno));
        /* Fatal, like every other way of not honoring the requested
         * replay (#411): a warn-and-run-live here is the same silent
         * divergence a mismatched header would be — worse, it's the
         * most common operator error (typo'd/deleted tape path). */
        _exit(3);
    }
    const char *strict = getenv("EIGS_REPLAY_STRICT");
    g_replay_strict = (strict && strict[0] && strcmp(strict, "0") != 0);
    if (!replay_check_header()) {
        /* Version-and-reject (#411): falling back to a live run would be
         * the exact silent divergence the header exists to prevent — the
         * user asked for a replay, so a tape this binary can't honor is
         * fatal. Same _exit rationale as the strict divergence abort. */
        _exit(3);
    }
    g_replay_enabled = 1;
#endif /* !EIGENSCRIPT_FREESTANDING */
}

static void replay_shutdown(void) {
#if !EIGENSCRIPT_FREESTANDING
    if (g_replay_fp) { fclose(g_replay_fp); g_replay_fp = NULL; }
#endif
    free(g_replay_line); g_replay_line = NULL; g_replay_cap = 0;
    free(g_replay_mem);  g_replay_mem = NULL;
    g_replay_mem_len = 0; g_replay_mem_pos = 0;
    g_replay_enabled = 0;
}

/* getline that does not need _GNU_SOURCE — keeps a growable buffer in the
 * file-static slot, reads up to and including the next newline (or EOF).
 * Returns the length (newline NOT included, NUL-terminated) or -1 at EOF. */
static int read_tape_line(void) {
    if (g_replay_mem) {
        /* serve the next newline-terminated line from the memory tape */
        if (g_replay_mem_pos >= g_replay_mem_len) return -1;
        if (g_replay_cap < 256) {
            g_replay_cap = 256;
            g_replay_line = realloc(g_replay_line, g_replay_cap);
            if (!g_replay_line) { g_replay_cap = 0; return -1; }
        }
        size_t len = 0;
        while (g_replay_mem_pos < g_replay_mem_len) {
            char c = g_replay_mem[g_replay_mem_pos++];
            if (c == '\n') break;
            if (len + 2 > g_replay_cap) {
                size_t nc = g_replay_cap * 2;
                char *nb = realloc(g_replay_line, nc);
                if (!nb) return -1;
                g_replay_line = nb; g_replay_cap = nc;
            }
            g_replay_line[len++] = c;
        }
        g_replay_line[len] = '\0';
        return (int)len;
    }
    if (!g_replay_fp) return -1;
    if (g_replay_cap < 256) {
        g_replay_cap = 256;
        g_replay_line = realloc(g_replay_line, g_replay_cap);
        if (!g_replay_line) { g_replay_cap = 0; return -1; }
    }
    size_t len = 0;
    int c;
    while ((c = fgetc(g_replay_fp)) != EOF) {
        if (len + 2 > g_replay_cap) {
            size_t nc = g_replay_cap * 2;
            char *nb = realloc(g_replay_line, nc);
            if (!nb) return -1;
            g_replay_line = nb; g_replay_cap = nc;
        }
        if (c == '\n') break;
        g_replay_line[len++] = (char)c;
    }
    if (c == EOF && len == 0) return -1;
    g_replay_line[len] = '\0';
    return (int)len;
}

/* #411: validate the V record sitting in g_replay_line against this
 * binary. One rule, no migration path: format AND runtime version must
 * match exactly, else the tape is refused with the reason on stderr.
 * (The tape is plain text — a deliberate override is editing line 1.) */
static int replay_vline_ok(void) {
    const char *p = g_replay_line;
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
static int replay_check_header(void) {
    if (read_tape_line() < 0) {
        fprintf(stderr, "trace: empty replay tape — refusing to replay "
                "(docs/TRACE.md)\n");
        return 0;
    }
    return replay_vline_ok();
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
    if (strncmp(*p, "true", 4) == 0 && at_token_boundary((*p)[4])) {
        *p += 4; return make_num(1.0);
    }
    if (strncmp(*p, "false", 5) == 0 && at_token_boundary((*p)[5])) {
        *p += 5; return make_num(0.0);
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

int trace_replay_take(const char *fn, Value **out) {
    if ((!g_replay_fp && !g_replay_mem) || !out) return 0;
    for (;;) {
        int len = read_tape_line();
        if (len < 0) {
            /* Tape exhausted — turn off replay so future calls skip the
             * read overhead, and let the builtin run normally. */
            replay_shutdown();
            return 0;
        }
        if (len >= 1 && g_replay_line[0] == 'V') {
            /* Mid-stream header: a concatenated tape (journal appended
             * across sessions/sink installs). Every session's header must
             * match this binary — a mismatch OR a torn/malformed V line is
             * always fatal, strict or not (#411): continuing would splice
             * another version's (or an unverifiable) session's records
             * into this replay. Memory tapes were fully pre-scanned at
             * install, so this fires only for EIGS_REPLAY files. */
            if (!replay_vline_ok()) {
#if EIGENSCRIPT_FREESTANDING
                abort();
#else
                _exit(3);
#endif
            }
            continue;
        }
        if (len < 2 || g_replay_line[0] != 'N' || g_replay_line[1] != ' ')
            continue;  /* skip L, A, blanks, anything else */

        char *p = g_replay_line + 2;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = '\0';
        const char *rec_name = p;
        const char *rec_val  = eq + 1;

        if (fn && strcmp(rec_name, fn) != 0) {
            if (g_replay_strict) {
                fprintf(stderr, "trace: replay name mismatch — tape has '%s', "
                        "program called '%s' (EIGS_REPLAY_STRICT — aborting)\n",
                        rec_name, fn);
                /* _exit, not exit: an abort must not run atexit teardown
                 * (half-executed program state) and keeps the status
                 * deterministic under sanitizers, whose leak checker
                 * would otherwise override the code at forced exits.
                 * Freestanding has no _exit; abort() is a HAL root
                 * (halt) and a strict mismatch on bare metal is a
                 * panic by any name. */
#if EIGENSCRIPT_FREESTANDING
                abort();
#else
                _exit(3);
#endif
            }
            fprintf(stderr, "trace: replay name mismatch — expected '%s', got '%s' (using anyway)\n",
                    fn, rec_name);
        }
        Value *v = parse_value(rec_val);
        if (!v) return 0;   /* unparseable — fall through to live source */
        *out = v;
        return 1;
    }
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
#if !EIGENSCRIPT_FREESTANDING
    if (g_trace_fp) {
        fflush(g_trace_fp);
        fclose(g_trace_fp);
        g_trace_fp = NULL;
    }
#endif
    sink_flush();
    g_trace_sink = NULL;
    g_trace_sink_ud = NULL;
    g_trace_enabled = 0;

    trace_thread_release();

    /* #827: drop the compile-time armed-name set and fall back to the
     * wildcard. Widening, never narrowing — a state opened after a
     * process-wide teardown must not inherit a narrowing whose compile-time
     * evidence has been freed. (Recording still needs g_trace_hist.) */
    for (int i = 0; i < g_arm_count; i++) free(g_arm_names[i]);
    free(g_arm_names);
    g_arm_names = NULL;
    g_arm_count = 0;
    g_arm_cap = 0;
    g_arm_all = 1;
    g_arm_gen++;

    replay_shutdown();
}

void trace_line(int line) {
    /* OP_LINE stores g_trace_current_line directly; this function is
     * only called when a tape is open (g_trace_enabled). */
    if (!trace_out_active()) return;
    if (line == g_last_line && !g_line_dirty) return;
    tp_printf("L %d\n", line);
    g_last_line  = line;
    g_line_dirty = 0;
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
        case VAL_NUM:          tp_printf("%.17g", v->data.num); break;
        case VAL_NULL:         tp_puts("null"); break;
        case VAL_STR:          write_string(v->data.str); break;
        case VAL_LIST:         tp_printf("<list:%d>", v->data.list.count); break;
        case VAL_DICT:         tp_printf("<dict:%d>", v->data.dict.count); break;
        case VAL_FN:           tp_puts("<fn>"); break;
        case VAL_BUILTIN:      tp_puts("<builtin>"); break;
        case VAL_BUFFER:       tp_printf("<buffer:%d>", v->data.buffer.count); break;
        case VAL_JSON_RAW:     tp_puts("<json>"); break;
        case VAL_TEXT_BUILDER: tp_puts("<text>"); break;
        /* No `default:` — -Werror=switch (Makefile CFLAGS) forces a new
         * ValType to choose its tape rendering here. */
    }
}

static void write_slot(EigsSlot s) {
    if (slot_is_num(s))  { tp_printf("%.17g", s.d); return; }
    if (slot_is_null(s)) { tp_puts("null"); return; }
    if (slot_is_bool(s)) { tp_puts(slot_as_bool(s) ? "true" : "false"); return; }
    if (slot_is_heap(s)) { write_value_ptr(slot_as_ptr(s)); return; }
    tp_puts("<unknown>");
}

static void trace_assign_ex(const char *name, EigsSlot value, int filtered) {
    /* Prev-map update runs regardless of EIGS_TRACE — `prev of x` is a
     * language feature, not a tape feature. The tape write below is
     * still gated on a tape (file or sink) being open. */
    prev_record_assign(name, value, filtered);

    if (!trace_out_active()) return;
    if (!name) name = "?";
    /* #539 v2: scope-transition record. When the innermost frame differs
     * from the one the last S record named (by frame-instance serial, so
     * two invocations of the same function never merge), stamp
     *   S <fn> <depth> <serial>
     * before the A record. Dedup mirrors the L-record discipline: scope
     * transitions only cost tape bytes at call boundaries that actually
     * assign. Replay skips S like A; only the stepper folds them. */
    if (eigs_current && eigs_current->vm && g_vm.frame_count > 0) {
        CallFrame *f = &g_vm.frames[g_vm.frame_count - 1];
        if (f->call_serial != g_last_scope_serial) {
            g_last_scope_serial = f->call_serial;
            tp_printf("S %s %d %u\n",
                      (f->chunk && f->chunk->name) ? f->chunk->name : "?",
                      g_vm.frame_count - 1, f->call_serial);
        }
    }
    tp_puts("A ");
    tp_puts(name);
    tp_putc('=');
    write_slot(value);
    tp_putc('\n');
    g_line_dirty = 1;
}

/* #830: the public, producer-facing entry point — an explicit "record this
 * assignment" request, honoured unconditionally. Every producer that is not
 * the bytecode compiler (the AOT's emitted C, an embedder, a hand-assembled
 * chunk) reaches the history through here and needs no arming ritual it has
 * no way to perform. */
void trace_assign(const char *name, EigsSlot value) {
    trace_assign_ex(name, value, 0);
}

/* The narrowed twin, for callers running a chunk the bytecode compiler
 * scanned (EigsChunk.compiler_scanned): #827's armed-name set is a valid
 * per-assign CPU filter exactly there, because that scan is what populated
 * it. Retention is bounded by the suffix-minima pruning either way — this is
 * an optimization, never a safety property. */
void trace_assign_filtered(const char *name, EigsSlot value) {
    trace_assign_ex(name, value, 1);
}

/* ----- Full-fidelity writer for nondet records.
 *
 * Recursive emission of lists/dicts; full string content; cap the whole
 * record at TRACE_NONDET_MAX bytes. The `budget` is decremented on every
 * byte written. When budget runs out, the rest of the record collapses
 * to a single "…<truncated:RESIDUAL>" marker so Phase 3 replay knows the
 * record cannot be used for full determinism. */

static void wf_putc(int c, int *budget) {
    if (*budget <= 0 || !trace_out_active()) return;
    tp_putc(c); (*budget)--;
}
static void wf_puts(const char *s, int *budget) {
    if (!trace_out_active()) return;
    while (*s && *budget > 0) { tp_putc(*s++); (*budget)--; }
}
static void wf_printf(int *budget, const char *fmt, ...) {
    if (*budget <= 0 || !trace_out_active()) return;
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
        case VAL_NUM:  wf_printf(budget, "%.17g", v->data.num); break;
        case VAL_NULL: wf_puts("null", budget); break;
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
    if (!trace_out_active()) return;
    if (!fn) fn = "?";
    tp_puts("N ");
    tp_puts(fn);
    tp_putc('=');
    int budget = TRACE_NONDET_MAX;
    write_value_ptr_full(v, &budget);
    if (budget <= 0) tp_puts("…<truncated>");
    tp_putc('\n');
    g_line_dirty = 1;
}
