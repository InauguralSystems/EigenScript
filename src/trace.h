/* ================================================================
 * EigenScript Trace — Phase 1: line/assignment event recorder
 * ================================================================
 * Off by default. Enabled by setting EIGS_TRACE=<path> in the env.
 * Output is a text tape — name-keyed assignment deltas + line events —
 * intended to back temporal interrogatives (`what of x at line 42`,
 * `where of y`, etc.) in later phases.
 *
 * Hot-path cost when disabled: one predicted-not-taken branch on the
 * extern int g_trace_enabled at each hook site.
 */
#ifndef EIGENSCRIPT_TRACE_H
#define EIGENSCRIPT_TRACE_H

#include <stdint.h>

/* EigsSlot is fully defined in value_slot.h (which requires Value).
 * For the trace API surface we only need the union shape, so guard
 * with the same sentinel value_slot.h uses to avoid a re-typedef. */
#ifndef EIGENSCRIPT_EIGSSLOT_UNION_DEFINED
#define EIGENSCRIPT_EIGSSLOT_UNION_DEFINED
typedef union { double d; uint64_t u; } EigsSlot;
#endif

/* Tape format version (#411). Every tape's first line is a header record:
 *   V <format> <runtime-version>
 * Bump this integer on ANY change to the tape encoding — record kinds,
 * value serialization, escaping, truncation markers, the header itself.
 * Replay refuses a tape whose format or runtime version differs from the
 * running binary: version-and-reject, never migrate (docs/TRACE.md). */
#define TRACE_FORMAT_VERSION 2   /* v2 (#539): scope-transition S records */

/* 1 when EIGS_TRACE was set and a tape was successfully opened.
 * Hook sites in vm.c gate on this directly so the disabled case
 * costs one load + one branch. */
extern int g_trace_enabled;

/* 1 when assignment history must be recorded: set by the compiler when
 * it sees `prev of`, any `at <expr>` qualifier, or a reference to the
 * `state_at` builtin — and by trace_init when EIGS_TRACE opens a tape.
 * The per-assign history append (prev-table, line stamps, the tape's A
 * records) gates on this, so programs that never ask temporal questions
 * pay nothing per assign. Profiling the DMG-shaped dispatch workload
 * showed the always-on variant cost ~17.8M trace_line + 2.5M
 * trace_assign calls per 500k interpreted steps (~1/3 of runtime).
 *
 * #827: this flag alone is too coarse — it is whole-program, so a
 * `prev of v` inside a function nothing ever calls used to arm recording
 * for every name. Set it only through the two arming entry points below,
 * which also record WHICH names a temporal query can reach. Never write
 * `g_trace_hist = 1` directly: an armed flag with no armed name records
 * nothing. */
/* ATOMIC, relaxed — same idiom and same reason as the per-state obs flags in
 * eigenscript.h (round 17): a worker's sandbox_run/vm_run_bytecode reaches
 * chunk_arm_temporal, which stores these PROCESS globals while every other
 * thread reads them at per-assignment safepoints (CASE(SET_NAME), and
 * eigs_obs_gate_open's second operand — the branch made g_trace_obs_hist
 * load-bearing for the gate verdict). TSan: 2 warnings, 3/3, same repro shape
 * as the obs-flag race; the INSTANCE pre-exists on main (verified there, same
 * 2 warnings), but the flags became verdict-carrying here. The macros are
 * LOADS; writes must use trace_flag_store, so the write sites stay
 * enumerable by the compiler. The arm NAME SETS (g_arm_*, g_occ_*) are a
 * separate, wider surface — tracked on #1035, not fixed by flag atomics. */
extern int g_trace_hist_storage;
#define g_trace_hist __atomic_load_n(&g_trace_hist_storage, __ATOMIC_RELAXED)

/* #827: turn history recording on.
 *
 * trace_arm_history_name(n) — narrow: record only assignments to `n` (plus
 * any other armed name). Use when the query's target is a compile-time
 * identifier, which is every form that actually reads the history
 * (`prev of x`, `<kw> is x at L` — both compile to a NAMED opcode).
 *
 * trace_arm_history_all() — wildcard: record every name. Required by
 * `state_at` (it queries all names), by an open tape, and by anything that
 * turns recording on without naming a name (the REPL, `record_history of 1`).
 * Widening is always safe; narrowing after the fact is not, so the arming
 * set only ever grows within a session.
 *
 * trace_history_disable() — the `record_history of 0` opt-out; clears both
 * g_trace_hist and g_trace_obs_hist.
 *
 * trace_arm_history_all_mt() — widen to the wildcard WITHOUT enabling
 * recording. `spawn` calls this as its last single-threaded act: the armed-name
 * set is process-global and the compiler grows it, so a worker running
 * eval/load_file would realloc it under another worker reading it (a UAF, not
 * a torn read). After widening, the filter reads only two ints and the name
 * array is never touched again. A program with no temporal query must not
 * start recording just because it made a thread, hence the separate entry
 * point. The narrowing is a per-assign CPU optimization for the
 * single-threaded long-running programs #827 was about; the history is
 * bounded either way. */
/* #915: compile-time arming state, saved/restored around the observer gate's
 * eager pre-pass so that merely SCANNING a module cannot arm the parent's
 * history channel. See the definition for the executed consequence. */
typedef struct {
    int      trace_hist, obs_hist;
    int      arm_all, arm_count;
    int      occ_all, occ_count;
} TraceArmState;
void trace_arm_snapshot(TraceArmState *out);
void trace_arm_restore(const TraceArmState *in);

void trace_arm_history_all(void);
void trace_arm_history_all_mt(void);
void trace_arm_history_name(const char *name);
void trace_history_disable(void);

/* #868: arm the OCCURRENCE RING for `name` — a third, strictly narrower tier
 * than the two above.
 *
 * The line-keyed history (#827) retains only the strict suffix minima of the
 * line sequence, so a loop body that assigns one name N times keeps exactly ONE
 * live entry: every iteration but the last is unaddressable. That pruning is
 * what bounds the history by program TEXT, and it is not negotiable — so
 * per-iteration addressing needs its own storage with its own bound.
 *
 * The ring keeps the last `trace_occ_window()` recorded assignments to an armed
 * name, addressable by 1-based ordinal. Bounded by WINDOW * armed names, so it
 * cannot reintroduce #827's unbounded growth.
 *
 * Armed ONLY by a `when`-qualified query naming a compile-time identifier.
 * Deliberately NOT armed by `state_at`, by an open tape, or by the `at` forms:
 * all of those are line-keyed and answer fine from the pruned history, and
 * arming them would put a ring on every name in the program — exactly the
 * whole-program over-arming #827 was filed about. */
void trace_arm_occurrences_name(const char *name);

/* Wildcard occurrence arming — ring every name. INTERACTIVE REPL ONLY.
 *
 * The REPL compiles line by line, so `x is 1` is already compiled and run
 * before the later `what is x when 1` can arm anything: without this, every
 * `when` query in a session answers null for assignments made on earlier
 * lines. `repl_interactive` has the same problem for the line history and
 * solves it the same way (trace_arm_history_all).
 *
 * Deliberately not reachable from a script: a compiled program knows its
 * `when` targets at compile time, so it never needs the wildcard, and giving
 * it one would put a ring on every binding — the over-arming #827 fixed. The
 * piped/non-interactive path does not call this either (byte-identical output
 * is its contract). */
void trace_arm_occurrences_all(void);

/* Retained-window size, in assignments per armed name. Defaults to
 * TRACE_OCC_WINDOW_DEFAULT; overridden by EIGS_OCC_WINDOW (clamped). Read once
 * per process on first use. */
int trace_occ_window(void);
#define TRACE_OCC_WINDOW_DEFAULT 256
#define TRACE_OCC_WINDOW_MAX     (1 << 20)

/* Source line currently being executed. Written by OP_LINE (a plain global
 * store — cheaper than a call; the JIT also stamps it via a flat-address
 * write, so it can't be __thread), read by trace_assign to stamp history
 * entries and by the tape writer. #297: the interpreter write is gated off
 * under MT (history/replay is single-threaded; the per-thread g_vm.current_line
 * carries the error line), so it isn't raced by parallel workers. */
extern int g_trace_current_line;

/* 1 when the compiler has seen a `where`/`why`/`how ... at <line>`
 * interrogative anywhere in the program. Gates observer-state capture
 * in the assignment history: stamping entropy/dH per assign forces
 * observer_ensure_fresh (defeating the lazy-entropy optimization), so
 * programs that never ask historical observer questions pay nothing.
 * Set during compile, before execution; code compiled later (eval,
 * load_file, REPL lines) enables capture from that point on. */
extern int g_trace_obs_hist_storage;
#define g_trace_obs_hist __atomic_load_n(&g_trace_obs_hist_storage, __ATOMIC_RELAXED)
#define trace_flag_store(storage, v) __atomic_store_n(&(storage), (v), __ATOMIC_RELAXED)

/* Called once from main() during startup. Reads EIGS_TRACE; if set,
 * opens the path for writing and flips g_trace_enabled. Safe to call
 * multiple times — second and later calls no-op. */
void trace_init(void);

/* Called at process exit to flush and close the tape. PROCESS-WIDE: it closes
 * the one tape, drops the embed sink, and shuts down the replay reader. A
 * per-connection or per-task worker must NOT call this — see #739, where every
 * ext_http worker did and the tape died after the first request. */
void trace_shutdown(void);

/* #739: release the CURRENT thread's prev-table (`prev of x` / `at` /
 * `state_at` history) without touching the process tape. Idempotent; a no-op
 * with no thread attached. Called by eigs_thread_detach for every thread, and
 * by trace_shutdown for the process owner's own thread (which must run before
 * the global env dies — the slots it drops can reach the env). */
void trace_thread_release(void);

/* ---- Embed tape seam (the freestanding tape path; see eigs_embed.h).
 * trace_set_sink installs a byte sink for tape records and enables
 * recording — the sink receives complete record lines (newline
 * included; an oversized record arrives in ordered chunks). NULL
 * uninstalls and stops recording (unless EIGS_TRACE also opened a
 * file). trace_set_replay_mem installs a whole tape as the replay
 * source (bytes are COPIED in); NULL clears it. Returns 0 on OOM. */
#include <stddef.h>
void trace_set_sink(void (*cb)(const char *bytes, size_t len, void *ud),
                    void *ud);
int  trace_set_replay_mem(const char *bytes, size_t len, int strict);

/* Record a source-line event. Emitted by OP_LINE. */
void trace_line(int line);

/* Record a name-keyed assignment. The slot is captured by value
 * (NaN-boxed union, POD), so this is safe to call from any opcode
 * handler immediately before or after the store. Phase 1 records
 * numbers verbatim; non-numerics get a type marker only.
 *
 * #830: this is the PRODUCER-FACING entry point and it records
 * unconditionally. The bytecode compiler is not the only producer of
 * EigenScript programs — the AOT (sibling `ouroboros` repo) emits C that
 * calls this directly, an embedder can, and `vm_run_bytecode` /
 * `sandbox_run` assemble chunks the compiler never saw. None of them can
 * populate #827's armed-name set, so none of them may be filtered by it:
 * doing that made every `prev of` / `at`-qualified read on those paths
 * return null in v0.35.1 — a silent wrong answer. A new producer gets
 * correct temporal reads by calling this and nothing else.
 *
 * trace_assign_filtered() is the narrowed twin, valid ONLY for a caller
 * running a chunk with EigsChunk.compiler_scanned set: there the compiler's
 * source scan is what armed the names, so skipping the rest is sound.
 * Retention is bounded by the pruning in either case (#827 defect B), so
 * the filter is a per-assign CPU optimization and never a safety property.
 * When in doubt, call trace_assign. */
void trace_assign(const char *name, EigsSlot value);
void trace_assign_filtered(const char *name, EigsSlot value);
/* #1063: A record on the tape, NO prev-table entry -- for a slot write whose
 * name the owning chunk does not interrogate (EigsChunk.local_traced). */
void trace_assign_tape_only(const char *name, EigsSlot value);

/* #262 Phase-3 D2: overwrite the observer snapshot of `name`'s most recent
 * history entry with slot-sourced entropy/dH/last_entropy. Called from
 * OBSERVE_NAME_POST under g_trace_obs_hist so `where/why/how is x at L` reads
 * the Env slot, decoupling the temporal feature from the Value observer
 * fields. `name` must be the interned constant. */
void trace_record_obs(const char *name, double entropy, double dH,
                      double last_entropy);

/* Forward decl; Value is fully defined in eigenscript.h. */
struct Value;

/* Record a nondeterministic builtin return value (random*, time, env_get,
 * etc.). The order of these records on the tape is the replay-determinism
 * substrate: on Phase 3 replay, each nondet call returns the recorded
 * value instead of re-invoking the underlying source. */
void trace_nondet_value(const char *fn, struct Value *v);

/* Phase 3.0a — `prev of x` query.
 *
 * Returns 1 and fills *out when the name has had at least two distinct
 * assignments recorded. Returns 0 when the name is unknown or has only
 * ever been assigned once. The map is fed by trace_assign and lives
 * independently of g_trace_enabled — `prev` is a language-level
 * interrogative, not a debug-tape feature.
 *
 * `name` must be the process-global interned pointer (matches what the
 * chunk's const_interns slot holds for the same identifier). */
int trace_query_prev(const char *interned_name, EigsSlot *out);

/* Phase 3.1 — `<kw> is x at <line>` and `prev of x at <line>`.
 *
 * Walks the per-name history (line, value) backward and returns the
 * value last bound to `name` at or before `line`. Returns 1 + fills
 * *out on hit, 0 on miss.
 *
 * TEMPORAL-BACKWARD, not line-keyed: assign at line 12, then at line 5,
 * then query at L=15 — the answer is the line-5 value, because it is the
 * most recent assignment whose line is <= 15. A line-keyed map would
 * wrongly answer with the line-12 value. #827's pruning preserves this
 * exactly (see the HistoryEntry comment in trace.c).
 *
 * `kind` mirrors the interrogative encoding:
 *   0 (what), 6 (prev)  → return historical slot
 *   2 (when)             → return assignment count up to that line (as immediate num)
 *   1 (who)              → return binding name (string)
 *   3/4/5 (where/why/how)→ observer snapshot captured at that assign
 *                          (requires g_trace_obs_hist; miss returns 0)
 */
int trace_query_at(int kind, const char *interned_name, int line, EigsSlot *out);

/* #868 — `<kw> is x when <N>`: the state at the Nth RECORDED assignment to
 * `name`, ordinals 1-based and ascending in execution order.
 *
 * The ordinal space is the history's own recorded-assignment counter, NOT
 * `env->assign_counts` (what the unqualified `when is x` reports). The two
 * disagree by the number of assignments made inside `unobserved:` blocks —
 * see #908; this form indexes what was actually recorded, because that is the
 * only counter that can address a stored entry.
 *
 * `kind` mirrors trace_query_at, resolved against the occurrence instead of a
 * line: 0 (what) the value; 6 (prev) the value at ordinal N-1; 2 (when) N
 * itself; 1 (who) the binding name; 3/4/5 (where/why/how) the observer snapshot
 * captured at that assignment.
 *
 * Return value distinguishes the two ways to miss, because conflating them is
 * a wrong answer: an ordinal that aged out of the window is a fact the runtime
 * HAD and dropped, and must not read as "never happened".
 *   TRACE_WHEN_HIT     — *out filled (caller owns the ref)
 *   TRACE_WHEN_MISS    — N < 1, or N > total: that assignment has not happened
 *   TRACE_WHEN_EVICTED — 1 <= N <= total but older than the retained window
 * On MISS/EVICTED, *total and *oldest report the recorded count and the oldest
 * still-retained ordinal (oldest is 0 when nothing is retained) so the caller
 * can raise a message that says which it was. */
#define TRACE_WHEN_HIT      1
#define TRACE_WHEN_MISS     0
#define TRACE_WHEN_EVICTED (-1)
int trace_query_when(int kind, const char *interned_name, long long ordinal,
                     EigsSlot *out, long long *total, long long *oldest);

/* Phase 4 — `state_at(line)` whole-program backward query.
 *
 * Walks every name tracked by the prev-table and returns the value each
 * one held at or before `line`. Names that hadn't been assigned by then
 * are omitted. Result is a fresh VAL_DICT owned by the caller; returns
 * NULL only on allocation failure.
 *
 * Cost is O(N · log D) where N = distinct names and D = the number of
 * distinct source lines that assign a given name: #827 prunes each name's
 * history down to the entries a backward query can actually reach, leaving
 * a line-sorted array that binary-searches. D is a property of the program
 * TEXT, so neither the cost nor the memory grows with how long the program
 * runs — a loop that reassigns one name a billion times keeps one entry. */
struct Value *trace_state_at(int line);

/* #736: 1 for a runtime-internal binding name (the `__name__` form the
 * observed-loop machinery injects) — filtered out of user-visible dumps. */
int trace_name_is_internal(const char *name);

/* Phase 3 — replay.
 *
 * When EIGS_REPLAY=<path> is set at startup, the named tape is opened
 * read-only and g_replay_enabled flips on. Hook sites in nondet builtins
 * call trace_replay_take(fn, &out): if the next N record on the tape can
 * be parsed into a Value, *out is set (caller owns the ref) and the
 * function returns 1 — the builtin then short-circuits to that recorded
 * value instead of invoking its underlying nondet source.
 *
 * Name mismatches are logged to stderr but the recorded value is used
 * anyway (Phase 3.0 lenient policy — strict ordering is the contract,
 * names are for human-readable debug). Set EIGS_REPLAY_STRICT=1 to make
 * a mismatch fatal instead: the process reports the divergence and exits
 * with status 3, for harnesses that want tape/program drift loud. EOF or
 * unparseable records return 0 and the builtin falls back to its normal
 * source. */
extern int g_replay_enabled;
int trace_replay_take(const char *fn, struct Value **out);

/* Centralized nondet-return macro for builtins.
 *
 * Expansion order:
 *   1. If replay is active and the next N record produces a value,
 *      return it (skip the real source entirely).
 *   2. Otherwise evaluate the source expression once.
 *   3. If tracing is enabled, record the produced value on the tape.
 *   4. Return.
 *
 * Hot-path cost when both disabled: two predicted-not-taken loads + branches.
 * Each call site must have `Value` defined (i.e. include eigenscript.h
 * before trace.h). */
#define TRACE_NONDET_RET(name, expr) do {                            \
    Value *_tr_v;                                                    \
    if (__builtin_expect(g_replay_enabled, 0) &&                     \
        trace_replay_take((name), &_tr_v))                           \
        return _tr_v;                                                \
    _tr_v = (expr);                                                  \
    if (__builtin_expect(g_trace_enabled, 0))                        \
        trace_nondet_value((name), _tr_v);                           \
    return _tr_v;                                                    \
} while (0)

/* Early-take / record-only pair, for builtins whose live path does real
 * work (file reads, network requests, bulk value construction) before
 * the return value exists. TRACE_NONDET_RET alone is wrong there: under
 * replay the live work still runs — wasted I/O, real side effects, and
 * an abandoned (leaked) live value.
 *
 * Usage: TRACE_NONDET_TAKE(name) as the function's first statement,
 * then TRACE_NONDET_RECORD(name, expr) at every return. TAKE consumes
 * this call's N record and short-circuits; RECORD never takes, so the
 * record cannot be consumed twice. Exactly one record per call either
 * way, preserving the strict-ordering contract. */
#define TRACE_NONDET_TAKE(name) do {                                 \
    Value *_tr_take;                                                 \
    if (__builtin_expect(g_replay_enabled, 0) &&                     \
        trace_replay_take((name), &_tr_take))                        \
        return _tr_take;                                             \
} while (0)

#define TRACE_NONDET_RECORD(name, expr) do {                         \
    Value *_tr_v = (expr);                                           \
    if (__builtin_expect(g_trace_enabled, 0))                        \
        trace_nondet_value((name), _tr_v);                           \
    return _tr_v;                                                    \
} while (0)

#endif /* EIGENSCRIPT_TRACE_H */
