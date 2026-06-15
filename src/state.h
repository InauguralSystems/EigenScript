/*
 * EigsState / EigsThread — interpreter and per-thread execution context.
 *
 * Phase 1 of the multi-state refactor (see docs/EMBEDDING.md once
 * Phase 10 lands). Introduces:
 *
 *   - EigsState:  one per interpreter instance. Will own the global
 *                 env, script/exe dirs, observer thresholds, module
 *                 cache, handle table, ext singletons. Empty in
 *                 Phase 1 except for the attached-threads registry.
 *   - EigsThread: one per OS thread that has entered a state. Owns
 *                 the arena (Phase 1), and will grow to own the VM,
 *                 error/return state, observer-current pointer, JIT
 *                 caches, allocator freelists.
 *
 * Code that still names legacy globals (`g_arena`, ...) sees them via
 * compat macros in eigenscript.h that redirect through `eigs_arena_ptr`
 * — a per-OS-thread pointer that caches `&eigs_current->arena`. Setting
 * the pointer at attach time gives the macro the same single-indirection
 * cost as the old `__thread Arena g_arena` direct access.
 *
 * Phase 1 explicitly forbids re-attach on the same OS thread (nested
 * states need a save/restore stack — Phase 10 work).
 */
#ifndef EIGENSCRIPT_STATE_H
#define EIGENSCRIPT_STATE_H

/* Arena and eigs_arena_ptr are declared in eigenscript.h — state.h
 * doesn't redeclare them because Arena uses an anonymous-struct
 * typedef that can't be forward-declared. TUs that need the bridge
 * already include eigenscript.h. */

typedef struct EigsState  EigsState;    /* opaque outside state.c */
typedef struct EigsThread EigsThread;   /* opaque outside state.c */

extern __thread EigsThread *eigs_current;

/* Construct a fresh interpreter state. The state owns no per-thread
 * resources; the caller must attach an OS thread to make it usable. */
EigsState *eigs_state_new(void);

/* Tear down a state. All attached threads must detach first; remaining
 * attachments are reported to stderr (leak indicator). Safe on NULL. */
void eigs_state_destroy(EigsState *st);

/* Attach the calling OS thread to `st`. Allocates the EigsThread,
 * runs arena_init on its arena, links into st, sets eigs_current /
 * eigs_arena_ptr. Returns NULL on re-attach or NULL st. */
EigsThread *eigs_thread_attach(EigsState *st);

/* Detach the calling OS thread. Runs arena_destroy, unlinks from the
 * owning state, frees the EigsThread, clears the TLS pointers. No-op
 * if not attached. */
void eigs_thread_detach(void);

/* Return the state the calling thread is attached to, or NULL. Used
 * by spawn() to inherit the parent's state into the worker thread. */
EigsState *eigs_current_state(void);

#endif /* EIGENSCRIPT_STATE_H */
