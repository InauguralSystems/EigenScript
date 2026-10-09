/*
 * EigsState / EigsThread — interpreter and per-thread execution context.
 *
 * Part of the multi-state refactor (see docs/EMBEDDING.md once Phase 10
 * lands):
 *
 *   - EigsState:  one per interpreter instance. Will own the global
 *                 env, script/exe dirs, observer thresholds, module
 *                 cache, handle table, ext singletons. Currently holds
 *                 only the attached-threads registry.
 *   - EigsThread: one per OS thread that has entered a state. Owns the
 *                 error/return/control-flow state
 *                 (Phase 3). Will grow to own the VM, observer-current
 *                 pointer, JIT caches, allocator freelists.
 *
 * EigsThread is transparent (struct definition in eigenscript.h) so the
 * legacy `g_returning`, `g_error_msg`, ... identifiers can be
 * macros that expand to `eigs_current->field` — same single-indirection
 * cost as the original `__thread X g_X` direct access. EigsState stays
 * opaque to internal TUs.
 *
 * Re-attach on the same OS thread is explicitly forbidden; nested
 * states need a save/restore stack (Phase 10 work).
 */
#ifndef EIGENSCRIPT_STATE_H
#define EIGENSCRIPT_STATE_H

/* EigsThread is declared in eigenscript.h (transparent struct); we
 * only need EigsState here. */
typedef struct EigsState EigsState;

/* Construct a fresh interpreter state. The state owns no per-thread
 * resources; the caller must attach an OS thread to make it usable. */
EigsState *eigs_state_new(void);

/* Tear down a state. All attached threads must detach first; remaining
 * attachments are reported to stderr (leak indicator). Safe on NULL. */
void eigs_state_destroy(EigsState *st);

/* Attach the calling OS thread to `st`. Allocates the EigsThread, links it into st, and sets eigs_current. Returns
 * NULL on re-attach or NULL st. */
EigsThread *eigs_thread_attach(EigsState *st);

/* Detach the calling OS thread. Unlinks from the owning state, frees the EigsThread, and clears eigs_current. No-op if
 * not attached. */
void eigs_thread_detach(void);

/* Return the state the calling thread is attached to, or NULL. Used
 * by spawn() to inherit the parent's state into the worker thread. */
EigsState *eigs_current_state(void);

#endif /* EIGENSCRIPT_STATE_H */
