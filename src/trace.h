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
 * trace_assign calls per 500k interpreted steps (~1/3 of runtime). */
extern int g_trace_hist;

/* Source line currently being executed. Written directly by OP_LINE
 * (an unconditional global store — cheaper than a call), read by
 * trace_assign to stamp history entries and by the tape writer. */
extern int g_trace_current_line;

/* 1 when the compiler has seen a `where`/`why`/`how ... at <line>`
 * interrogative anywhere in the program. Gates observer-state capture
 * in the assignment history: stamping entropy/dH per assign forces
 * observer_ensure_fresh (defeating the lazy-entropy optimization), so
 * programs that never ask historical observer questions pay nothing.
 * Set during compile, before execution; code compiled later (eval,
 * load_file, REPL lines) enables capture from that point on. */
extern int g_trace_obs_hist;

/* Called once from main() during startup. Reads EIGS_TRACE; if set,
 * opens the path for writing and flips g_trace_enabled. Safe to call
 * multiple times — second and later calls no-op. */
void trace_init(void);

/* Called at process exit to flush and close the tape. */
void trace_shutdown(void);

/* Record a source-line event. Emitted by OP_LINE. */
void trace_line(int line);

/* Record a name-keyed assignment. The slot is captured by value
 * (NaN-boxed union, POD), so this is safe to call from any opcode
 * handler immediately before or after the store. Phase 1 records
 * numbers verbatim; non-numerics get a type marker only. */
void trace_assign(const char *name, EigsSlot value);

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
 * `kind` mirrors the interrogative encoding:
 *   0 (what), 6 (prev)  → return historical slot
 *   2 (when)             → return assignment count up to that line (as immediate num)
 *   1 (who)              → return binding name (string)
 *   3/4/5 (where/why/how)→ observer snapshot captured at that assign
 *                          (requires g_trace_obs_hist; miss returns 0)
 */
int trace_query_at(int kind, const char *interned_name, int line, EigsSlot *out);

/* Phase 4 — `state_at(line)` whole-program backward query.
 *
 * Walks every name tracked by the prev-table and returns the value each
 * one held at or before `line`. Names that hadn't been assigned by then
 * are omitted. Result is a fresh VAL_DICT owned by the caller; returns
 * NULL only on allocation failure.
 *
 * Cost is O(N · (H/64 + 64)) where N = distinct names and H = avg history
 * depth: each name's backward walk consults a periodic line-floor index
 * (min line stamp per 64-entry segment) that skips whole segments which
 * cannot contain a hit, then scans at most one segment linearly. Histories
 * dominated by loop re-assigns — the debugger-scrub worst case — skip in
 * O(H/64). If the index allocation ever fails the name falls back to the
 * plain O(H) backward scan. */
struct Value *trace_state_at(int line);

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
