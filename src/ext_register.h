/*
 * Extension entry points reachable from the CORE (#744).
 *
 * The core builtin registration seam (builtins.c) and state teardown
 * (state.c) call into every optional extension. They used to reach those
 * entry points through each extension's PRIVATE header — `ext_db_internal.h`
 * (which pulls <libpq-fe.h>, so the core TU could not compile in the `full`
 * variant without PostgreSQL headers on the include path), `model_internal.h`
 * (the whole transformer type set) and `ext_http_internal.h` (the Server
 * struct + pthread) — for a single function declaration each, and state.c
 * carried two hand-written `extern`s for the same reason. Those were the only
 * core -> ext include edges in the tree.
 *
 * This header is the seam instead: entry points only, no extension types, no
 * extension system headers. A private header stays private to its extension.
 *
 * Declarations are UNGUARDED and the call sites keep their `#if
 * EIGENSCRIPT_EXT_*` — the pattern `register_gfx_builtins` already used. A
 * declaration of a function that this variant does not compile is inert; the
 * guard that matters is the one on the call.
 */

#ifndef EXT_REGISTER_H
#define EXT_REGISTER_H

#include "eigenscript.h"

/* Registrars — called from register_builtins (builtins.c), the ONE env
 * composition seam (#742). */
void register_http_builtins(Env *env);   /* ext_http.c  */
void register_db_builtins(Env *env);     /* ext_db.c    */
void register_net_builtins(Env *env);    /* ext_net.c   */
void register_model_builtins(Env *env);  /* model_train.c */
void register_gfx_builtins(Env *env);    /* ext_gfx.c   */

/* Per-state teardown — called from eigs_state_destroy (state.c). Each is a
 * no-op for a state that never registered the extension's builtins. */
void ext_http_state_destroy(EigsState *st);   /* ext_http.c */
void ext_db_state_destroy(EigsState *st);     /* ext_db.c   */

#endif
