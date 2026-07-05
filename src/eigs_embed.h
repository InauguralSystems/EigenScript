/*
 * eigs_embed.h — public embedding API for EigenScript (Phase 10).
 *
 * The minimal surface a C/C++ host needs to embed the runtime:
 *
 *   - lifecycle (open/close, or finer-grained state_new/thread_attach)
 *   - eval source strings / files
 *   - read + write global bindings
 *   - construct, inspect, and release values
 *   - register C functions callable from EigenScript
 *
 * Multi-state (Phases 1-9) means the host can keep several interpreters
 * alive concurrently; eigs_thread_attach binds the calling OS thread to
 * one of them. All API calls operate on the attached state implicitly via
 * the eigs_current TLS pointer — pass NULL/no state argument to value or
 * eval calls and they target whichever state the calling thread is on.
 *
 * Ownership: every API that returns an EigsValue* returns a counted ref
 * the caller owns and must release with eigs_value_release. APIs that
 * accept an EigsValue* either store it (consuming the caller's ref) or
 * leave the caller's ref untouched — the comment on each prototype says
 * which.
 */
#ifndef EIGS_EMBED_H
#define EIGS_EMBED_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EigsState  EigsState;
typedef struct EigsThread EigsThread;
/* EigsValue is the internal `Value` — kept opaque for embedders, so the
 * field layout can change without breaking the API. */
typedef struct Value      EigsValue;

/* ---- Lifecycle ---------------------------------------------------- */

/* One-shot: state_new + thread_attach + register builtins. Returns NULL on
 * failure (already attached, OOM). The returned state must be closed with
 * eigs_close from the same OS thread. */
EigsState  *eigs_open(void);
void        eigs_close(EigsState *st);

/* Finer-grained lifecycle for hosts that need to attach multiple threads
 * to the same state, or build the state in stages. */
EigsState  *eigs_state_new(void);
void        eigs_state_destroy(EigsState *st);
EigsThread *eigs_thread_attach(EigsState *st);

/* Single-thread multi-state switching: park the calling thread's current
 * attachment (nothing is torn down) and activate its attachment to `st`,
 * creating one on first use. Returns the (possibly new) EigsThread, or
 * NULL on failure. After a switch, eigs_eval_string / globals / values
 * operate on `st`. Rules: (1) a value belongs to the state that created
 * it — never carry EigsValue pointers across a switch; copy numbers out.
 * (2) eigs_close(st) must be called while attached to st (switch first)
 * and leaves the thread detached — switch to another state afterwards.
 * This is the cooperative-scheduler seam (EigenOS M9: task = state). */
EigsThread *eigs_thread_switch(EigsState *st);
void        eigs_thread_detach(void);
/* Set up the global env + register stdlib builtins on the calling thread's
 * state. Idempotent: returns 0 if already initialized. -1 if not attached. */
int         eigs_state_init_runtime(EigsState *st);

/* ---- Eval --------------------------------------------------------- */

/* Tokenize, parse, compile, and execute `src` in the attached state's
 * global env. Returns the script's last expression value (a counted ref
 * the caller must release) or NULL on parse/runtime error — call
 * eigs_last_error_message() for details. */
EigsValue *eigs_eval_string(const char *src);
/* Read `path` and eval its contents. Sets script_dir for `import`/
 * `load_file` resolution to the file's directory. */
EigsValue *eigs_eval_file(const char *path);

/* ---- Errors ------------------------------------------------------- */

/* Error message from the most recent eval/runtime failure on this thread,
 * or NULL when no error is pending. The returned pointer is owned by the
 * thread state — copy it if you need to keep it past the next API call. */
const char *eigs_last_error_message(void);
int         eigs_has_error(void);
void        eigs_clear_error(void);

/* ---- Globals ------------------------------------------------------ */

/* Bind `val` into the global env under `name`. The store retains its own
 * reference; the caller's ref on `val` is left untouched (release it if
 * the value was freshly constructed). */
void        eigs_set_global(const char *name, EigsValue *val);
/* Look up `name` in the global env. Returns a counted ref (caller releases)
 * or NULL if not bound. */
EigsValue  *eigs_get_global(const char *name);

/* ---- Values ------------------------------------------------------- */

typedef enum {
    EIGS_TYPE_NULL = 0,
    EIGS_TYPE_NUM,
    EIGS_TYPE_STR,
    EIGS_TYPE_LIST,
    EIGS_TYPE_DICT,
    EIGS_TYPE_FN,
    EIGS_TYPE_BUFFER,
    EIGS_TYPE_OTHER
} EigsValueType;

EigsValue     *eigs_value_new_num(double n);
EigsValue     *eigs_value_new_string(const char *s);
EigsValue     *eigs_value_new_null(void);
EigsValue     *eigs_value_new_list(int capacity);
EigsValue     *eigs_value_new_dict(int capacity);
void           eigs_value_retain(EigsValue *v);
void           eigs_value_release(EigsValue *v);

EigsValueType  eigs_value_type(EigsValue *v);
double         eigs_value_as_num(EigsValue *v);     /* 0.0 if not num */
const char    *eigs_value_as_string(EigsValue *v);  /* NULL if not str; borrowed */

int            eigs_value_list_len(EigsValue *v);
EigsValue     *eigs_value_list_get(EigsValue *v, int i);   /* counted ref */
/* Appends `item` to `v`. The list retains its own ref; the caller's ref on
 * `item` is left untouched. */
void           eigs_value_list_append(EigsValue *v, EigsValue *item);

/* Counted ref on hit; NULL on miss or wrong type. */
EigsValue     *eigs_value_dict_get(EigsValue *v, const char *k);
/* Same ownership semantics as list_append. */
void           eigs_value_dict_set(EigsValue *v, const char *k, EigsValue *val);

/* ---- Buffers -------------------------------------------------------
 * The script-side `buffer of n` value: a flat mutable array of nums,
 * NUL-safe end to end — the natural carrier for binary data across the
 * host boundary (a bytes-in-a-string round trip is not; strings are
 * C-terminated). Elements are doubles, same as in-language; a host
 * moving raw bytes stores 0..255 per element. Script sees the same
 * object through buf_get/buf_set/len — no copy at the boundary. */
EigsValue     *eigs_value_new_buffer(int count);   /* zeroed, 1-D (unshaped) */
int            eigs_value_buffer_len(EigsValue *v);          /* 0 if not a buffer */
double         eigs_value_buffer_get(EigsValue *v, int i);   /* 0.0 out of range */
void           eigs_value_buffer_set(EigsValue *v, int i, double x); /* OOB: no-op */

/* ---- Trace tape (record + replay) ----------------------------------
 * The runtime's replay tape (hosted: EIGS_TRACE / EIGS_REPLAY files),
 * reachable without a filesystem. Install a sink and every tape record
 * (V/L/A/N lines) streams to it as bytes — the sink receives complete
 * newline-terminated lines (an oversized record arrives in ordered
 * chunks). Installing a sink ENABLES recording — the first bytes are the
 * version header (`V <format> <runtime>`, #411); a journal appended
 * across several installs carries one header per session. Passing NULL
 * stops recording. The sink fires from inside evaluation — do not
 * re-enter the runtime from it; buffer the bytes and act between evals.
 *
 * eigs_set_replay_tape hands the whole tape back as the replay source
 * (bytes are copied; NULL clears). Returns 0 on OOM or when the tape is
 * REFUSED: a tape whose version header is missing or does not match this
 * runtime (format and version both) is never installed — version-and-
 * reject, no migration (#411, docs/TRACE.md; reason goes to stderr).
 * Store tape bytes verbatim: strip the header and replay refuses the
 * journal. While replay is active, nondet builtins return the tape's
 * recorded N values in order instead of consulting their live sources.
 * `strict` makes a tape/program name mismatch fatal instead of
 * logged-and-tolerated.
 *
 * Host builtins participate through the take/record pair — the same
 * contract the runtime's own nondet builtins use:
 *
 *   EigsValue *my_sensor(EigsValue *arg) {
 *       EigsValue *v;
 *       if (eigs_replay_take("my_sensor", &v)) return v;   // from tape
 *       v = eigs_value_new_num(read_hw());
 *       eigs_trace_record_nondet("my_sensor", v);          // onto tape
 *       return v;
 *   }
 */
typedef void (*EigsTraceSink)(const char *bytes, size_t len, void *ud);
void eigs_set_trace_sink(EigsTraceSink cb, void *ud);
int  eigs_set_replay_tape(const char *bytes, size_t len, int strict);
int  eigs_replay_take(const char *name, EigsValue **out);   /* 1 = served */
void eigs_trace_record_nondet(const char *name, EigsValue *v);

/* ---- Async abort -----------------------------------------------------
 * Register a flag the host may set from an interrupt/signal context (a
 * ctrl-c handler, a timeout timer, an OS keyboard IRQ). The interpreter
 * polls it on every loop back-edge; when set, the running eval raises an
 * ordinary runtime error ("aborted") and the flag is CONSUMED — one set
 * aborts exactly one eval, and the state stays usable for the next eval.
 * The host side is async-signal-safe by construction: setting the flag is
 * a plain store into the host's own int (register it once; pass NULL to
 * unregister). Process-global, not per-state: the semantic is "abort
 * whatever is evaluating."
 *
 * Two documented caveats:
 *  - The error is catchable like any runtime error — a `try` around the
 *    loop observes it (set the flag again if the program keeps looping).
 *  - Loops running as JIT/OSR native code do not poll; the abort lands at
 *    the next interpreted back-edge. Embedders needing hard timeouts run
 *    with EIGS_JIT_OFF=1; the freestanding profile compiles the JIT out,
 *    so coverage there is total. */
void eigs_set_abort_flag(volatile int *flag);

/* ---- FFI ---------------------------------------------------------- */

/* Host function signature mirrors the internal BuiltinFn: `arg` is the
 * raw single argument when the script called with one arg, a VAL_LIST of
 * args for multi-arg calls, or NULL for zero-arg calls. The returned
 * value's ref is adopted by the runtime — return a fresh make_*-style
 * EigsValue and don't release it yourself. */
typedef EigsValue *(*EigsHostFn)(EigsValue *arg);
void eigs_register_function(const char *name, EigsHostFn fn);

/* ---- Source provider (the module seam) ------------------------------
 *
 * `import name` consults the registered provider FIRST, in every build
 * profile; the filesystem chain is the fallback (hosted) or absent
 * (freestanding — where the provider is the ONLY module source, e.g.
 * EigenOS's ROM bundle of stdlib + programs baked into the kernel
 * image). Return the module's source text for `name` ("math", not
 * "lib/math.eigs"), or NULL if the provider doesn't carry it. The
 * returned pointer must stay valid for the duration of the import call
 * (the runtime copies it immediately); static/arena-backed strings are
 * ideal. Provider-served modules are cached like file modules — a
 * second `import name` binds the same module dict. Pass fn=NULL to
 * unregister. */
typedef const char *(*EigsSourceProvider)(const char *name, void *userdata);
void eigs_set_source_provider(EigsSourceProvider fn, void *userdata);

#ifdef __cplusplus
}
#endif

#endif /* EIGS_EMBED_H */
