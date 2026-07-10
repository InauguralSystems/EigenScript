/* ================================================================
 * EigenScript Bytecode VM — execution loop
 * ================================================================
 * Stack-based VM with computed-goto dispatch (GCC/Clang).
 * Falls back to switch dispatch on other compilers.
 */

#include "eigenscript.h"
#include "vm.h"
#include "jit.h"
#include "trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* #262 slot-keyed observer shadow. Off unless EIGS_OBS_SHADOW is set;
 * -1 = not yet probed. When on, every observe site records the binding's
 * trajectory on its env slot (keyed by env+index, independent of the Value
 * object) and the bare predicates read that slot. The per-Value path stays
 * authoritative; a no-op when the flag is unset. The last-observed-slot
 * tracker (g_last_obs_slot_env/idx) lives on EigsThread (eigenscript.h). */
Value* builtin_report(Value *arg);
Value* builtin_observe(Value *arg);

/* #262 Phase-3 D: read the last-observed trajectory (dH, entropy) for the
 * observer loop-stall check. Prefers the slot model (the default); falls back
 * to the global last-observer Value when the slot isn't populated (e.g. a
 * the last-observed binding's slot). Shared by the interpreter
 * CASE(LOOP_STALL_CHECK) and jit_helper_loop_stall_check so the two can never
 * disagree on loop classification (the same lockstep invariant the opcode
 * encoding enforces). Returns 1 if (*dH, *ent) were filled. */
static inline int obs_stall_trajectory(double *dH, double *ent) {
    if (g_last_obs_slot_env &&
        g_last_obs_slot_idx >= 0 &&
        g_last_obs_slot_idx < g_last_obs_slot_env->obs_cap &&
        g_last_obs_slot_env->obs[g_last_obs_slot_idx].used) {
        const ObserverSlot *s = &g_last_obs_slot_env->obs[g_last_obs_slot_idx];
        *dH = s->dH; *ent = s->entropy;
        return 1;
    }
    return 0;
}
void vm_obs_slot_dropped(Env *e) {
    if (g_last_obs_slot_env == e) { g_last_obs_slot_env = NULL; g_last_obs_slot_idx = -1; }
}

/* Classify an observer slot's trajectory by predicate kind (0..5), matching the
 * bare OP_PREDICATE dispatch. Shared by the named OP_PREDICATE_SLOT/NAME ops,
 * which read a SPECIFIC binding's slot instead of the global last-observed one. */
static int vm_slot_predicate(const ObserverSlot *s, uint16_t kind) {
    switch (kind) {
    case 0: return observer_slot_converged(s);
    case 1: return observer_slot_stable(s);
    case 2: return observer_slot_improving(s);
    case 3: return observer_slot_oscillating(s);
    case 4: return observer_slot_diverging(s);
    case 5: return observer_slot_equilibrium(s);
    }
    return 0;
}

/* Phase 5: VM execution state (g_vm), loop-stall accounting
 * (g_loop_stall_count, g_loop_iterations, g_loop_exit_reason),
 * control-flow / error-state globals (g_return_val, g_returning,
 * g_breaking, g_continuing, g_error_msg, g_error_value, g_has_error,
 * g_try_depth), and observer state (g_unobserved_depth, g_last_observer,
 * g_builtin_call_env, g_obs_dh_zero/small/h_low) are EigsThread/EigsState
 * fields; the g_* identifiers are macros in eigenscript.h. No extern
 * decls needed here. */

/* ---- Helpers from eigenscript.c ---- */
extern void val_incref(Value *v);
extern void val_decref(Value *v);
extern Value* make_num(double n);
extern Value* make_str(const char *s);
extern Value* make_null(void);
extern Value* make_list(int cap);
extern Value* make_dict(int cap);
extern Value* make_fn(const char *name, char **params, int param_count,
                       Env *closure);
extern Value* make_builtin(Value* (*fn)(Value*));
extern void list_append(Value *list, Value *item);
extern void dict_set(Value *dict, const char *key, Value *val);
extern Value* dict_get(Value *dict, const char *key);
extern Env* env_new(Env *parent);
extern void env_incref(Env *env);
extern void env_decref(Env *env);
extern void env_mark_captured(Env *env);
extern void env_reserve_slots(Env *env, int total);
extern void env_set_local(Env *env, const char *name, Value *val);
extern void env_set_hashed(Env *env, const char *name, uint32_t h, Value *val);
extern void env_set_local_hashed(Env *env, const char *name, uint32_t h, Value *val);
extern Value* env_get_hashed(Env *env, const char *name, uint32_t h);
extern Value* env_get(Env *env, const char *name);
extern double num_guard(double x);
extern Value* promote_if_arena(Value *v);
/* Observer helper — declared in eval.c, needs to be exposed for VM.
 * For now, call the eval.c version via a non-static wrapper. */
extern void observer_ensure_fresh(Value *v);
extern Value* builtin_free_val(Value *arg);
extern const char* val_type_name(ValType t);
extern Value* dict_get_hashed(Value *dict, const char *key, uint32_t h);
extern void dict_set_hashed(Value *dict, const char *key, uint32_t h, Value *val);
extern int env_hash_find_dict(Value *dict, const char *key, uint32_t h);
extern int env_get_assign_count(Env *env, const char *name, uint32_t h);
extern void env_hash_insert(EnvHash *ht, uint32_t h, int idx);

/* Inline fast-path for binding a single param into a fresh call env.
 * Caller guarantees `env->count == slot_idx` and `env->capacity > slot_idx`
 * (true for fresh envs from env_new — capacity is ENV_INIT_CAP = 16).
 * Skips capacity check, env_hash_find, env_hash_rebuild. */
static inline void vm_bind_fresh_param(Env *env, int slot_idx,
                                       const char *interned, uint32_t h,
                                       EigsSlot s) {
    env->names[slot_idx] = (char *)interned;
    EigsSlot stored = s;
    if (__builtin_expect(slot_is_ptr(s), 0)) {
        Value *v = slot_as_ptr(s);
        if (__builtin_expect(v && v->arena, 0)) {
            Value *promoted = promote_if_arena(v);
            if (promoted && promoted != v) {
                stored = slot_from_value(promoted);
                goto _bind_store;
            }
        }
    }
    slot_incref(s);
_bind_store:
    env->values[slot_idx] = stored;
    if (env->assign_counts) env->assign_counts[slot_idx] = 1;
    env->count = slot_idx + 1;
    env->binding_version++;
    env_hash_insert(&env->hash, h, slot_idx);
}

/* ---- Stage 5i: per-chunk call-env recycling ----
 *
 * Post-5h profile: with everything else native or cached, the top
 * remaining DMG cost was the per-call env round-trip — env_new, one
 * env_hash_insert per param, binding_version++, env_reserve_slots, and
 * env_decref, once per handler call. A function chunk's env layout is
 * fixed (same param names → same slots → same hashes), so a dead call
 * env can be parked on the chunk and the next call rebinds the param
 * slots in place: no allocation, no hash work, no version bump — which
 * also keeps every EnvIC aimed at the env valid across calls.
 *
 * Park requirements (vm_park_call_env):
 *   - single-threaded (chunks are shared across spawn threads);
 *   - frame->env == frame->fn_env (never park a loop-scope child);
 *   - not captured by a closure, env_refcount == 1 (exactly the
 *     frame's own ref — that ref transfers to the chunk);
 *   - count == max(param_count, local_count): a binding created
 *     mid-call (e.g. SET_NAME_LOCAL of a new name, __loop_exit__)
 *     must NOT resolve in the next invocation, and an underfed call
 *     (argc < param_count) leaves params unhashed — both park-reject.
 * Parked slots are dropped to slot_null (no value pinning) with
 * assign_counts zeroed; param names/hash/binding_version survive.
 * The parked env keeps its owned parent ref, so the callee's closure
 * env stays pinned (at most one extra retention per chunk) and the
 * take-side parent compare can never see a recycled pointer.
 *
 * Take requirements (at the call sites): cache occupied, parent
 * matches the callee's closure env, and the call fully binds the
 * params (argc >= param_count, or param_count <= 1 where the single
 * slot is always bound). */
static inline void env_rebind_param_slot(Env *env, int slot, EigsSlot s) {
    /* Parked slot holds slot_null — no decref of the old value. Same
     * incref/arena-promotion contract as env_bind_fresh_param_slot. */
    EigsSlot stored = s;
    if (__builtin_expect(slot_is_ptr(s), 0)) {
        Value *v = slot_as_ptr(s);
        if (__builtin_expect(v && v->arena, 0)) {
            Value *promoted = promote_if_arena(v);
            if (promoted && promoted != v) {
                stored = slot_from_value(promoted);
                goto _rebind_store;
            }
        }
    }
    slot_incref(s);
_rebind_store:
    env->values[slot] = stored;
    if (env->assign_counts) env->assign_counts[slot] = 1;
}

static inline int vm_park_call_env(EigsChunk *chunk, Env *env) {
    if (g_vm_multithreaded) return 0;
    if (chunk->env_cache) return 0;          /* taken (recursion) */
    /* refcount must be exactly the frame's own ref — anything more means
     * a closure, a surviving child env, or a C caller still holds it. */
    if (env->captured || env->env_refcount != 1) return 0;
    int expected = chunk->local_count > chunk->param_count
                 ? chunk->local_count : chunk->param_count;
    if (env->count != expected) return 0;
    /* Every param must be name-bound, or the recycled env would
     * resolve params by slot but not by name. A single-arg OP_DISPATCH
     * to a multi-param fn binds only param 0 (slots 1+ come from
     * env_reserve_slots, nameless) — reject those. */
    for (int i = 0; i < chunk->param_count; i++)
        if (!env->names[i]) return 0;
    for (int i = 0; i < env->count; i++) {
        slot_decref(env->values[i]);
        env->values[i] = slot_null();
        if (env->assign_counts) env->assign_counts[i] = 0;
    }
    /* Observer state (entropy/dH per slot) is part of binding identity: a
     * recycled env must start the next invocation with a fresh trajectory,
     * or a windowed predicate (converged/stable/...) on an observed local
     * reads the PREVIOUS call's history. Resetting slot values alone leaves
     * env->obs intact — the silent drift this clears. */
    observer_slot_reset(env);
    chunk->env_cache = env;
    return 1;
}

/* Take side, shared by CASE(CALL), jit_helper_call, and CASE(DISPATCH).
 * Returns the recycled env (param slots null, ready for
 * env_rebind_param_slot) or NULL → caller runs the fresh env_new path. */
static inline Env *vm_take_call_env(EigsChunk *fn_chunk, Env *closure,
                                    int param_count, int argc) {
    Env *e = fn_chunk->env_cache;
    if (e && !g_vm_multithreaded && e->parent == closure &&
        (param_count <= 1 || argc >= param_count)) {
        fn_chunk->env_cache = NULL;
        return e;
    }
    return NULL;
}

/* ---- Dict field inline cache ----
 *
 * Stage 5h: 2-way set-associative (64 sets × 2 ways = the same 128
 * entries). Direct mapping had a pathological mode the DMG register
 * file hit dead-on: two hot keys on the SAME dict whose hashes collide
 * mod the set count evict each other on every access ("pc"/"cycles"
 * alternated, costing a full hash walk twice per emulated step). Ways
 * are adjacent entries; insertion shifts way0 → way1 and writes the
 * new entry to way... way1 → way0 order below keeps the most recent
 * insert in way1 and its predecessor in way0, so an alternating pair
 * settles with one key per way and both hit. The JIT's inline probe
 * (emit_dict_cache_probe) checks both ways with no swapping, so a
 * settled pair stays settled. */
#define DICT_CACHE_SETS 64
#define DICT_CACHE_SET_MASK (DICT_CACHE_SETS - 1)
#define DICT_CACHE_WAYS 2

typedef struct {
    Value   *dict;      /* dict identity (pointer) */
    uint32_t hash;      /* field name hash */
    int      index;     /* slot index in dict arrays */
} DictCacheEntry;

static __thread DictCacheEntry g_dict_cache[DICT_CACHE_SETS * DICT_CACHE_WAYS];

/* Probe both ways of the set for (dict, hash). Returns the matching
 * entry or NULL. No MRU swapping — see the header comment. */
static inline DictCacheEntry *dict_cache_probe(Value *dict, uint32_t h) {
    int set = ((int)(h ^ (uint32_t)(uintptr_t)dict) & DICT_CACHE_SET_MASK)
              * DICT_CACHE_WAYS;
    DictCacheEntry *ce = &g_dict_cache[set];
    if (ce[0].dict == dict && ce[0].hash == h) return &ce[0];
    if (ce[1].dict == dict && ce[1].hash == h) return &ce[1];
    return NULL;
}

static inline void dict_cache_insert(Value *dict, uint32_t h, int idx) {
    int set = ((int)(h ^ (uint32_t)(uintptr_t)dict) & DICT_CACHE_SET_MASK)
              * DICT_CACHE_WAYS;
    DictCacheEntry *ce = &g_dict_cache[set];
    ce[0] = ce[1];               /* previous insert survives in way0 */
    ce[1].dict = dict; ce[1].hash = h; ce[1].index = idx;
}

static inline Value *dict_get_cached(Value *dict, const char *key, uint32_t h) {
    DictCacheEntry *ce = dict_cache_probe(dict, h);
    if (ce && ce->index < dict->data.dict.count) {
        const char *stored = dict->data.dict.keys[ce->index];
        if (stored == key || strcmp(stored, key) == 0)
            return dict->data.dict.vals[ce->index];
    }
    int idx = env_hash_find_dict(dict, key, h);
    if (idx >= 0) {
        dict_cache_insert(dict, h, idx);
        return dict->data.dict.vals[idx];
    }
    return NULL;
}

static inline void dict_set_cached(Value *dict, const char *key, uint32_t h, Value *val) {
    DictCacheEntry *ce = dict_cache_probe(dict, h);
    if (ce && ce->index < dict->data.dict.count) {
        const char *stored = dict->data.dict.keys[ce->index];
        if (stored == key || strcmp(stored, key) == 0) {
            /* Cache hit — update in place */
            Value *promoted = promote_if_arena(val);
            if (promoted != val) {
                val_decref(dict->data.dict.vals[ce->index]);
                dict->data.dict.vals[ce->index] = promoted;
            } else {
                val_incref(val);
                val_decref(dict->data.dict.vals[ce->index]);
                dict->data.dict.vals[ce->index] = val;
            }
            return;
        }
    }
    /* Cache miss — full set (populates hash table, cache stays stale until next get) */
    dict_set_hashed(dict, key, h, val);
}

/* Slot-aware dict set: for the DMG register-write hot path. If the dict
 * cache hits and the existing slot is an exclusive untracked VAL_NUM,
 * mutate data.num in place — no allocation, no refcount churn. Returns
 * 1 if the in-place fast path fired; 0 means the caller must materialize
 * and call dict_set_cached. */
static inline int dict_set_cached_immediate(Value *dict, const char *key, uint32_t h, double num) {
    DictCacheEntry *ce = dict_cache_probe(dict, h);
    if (ce && ce->index < dict->data.dict.count) {
        const char *stored = dict->data.dict.keys[ce->index];
        if (stored == key || strcmp(stored, key) == 0) {
            Value *existing = dict->data.dict.vals[ce->index];
            if (existing && existing->type == VAL_NUM &&
                existing->refcount == 1 &&
                !existing->arena) {
                existing->data.num = num;
                return 1;
            }
        }
    }
    return 0;
}

/* Local-slot target lift: for LOCAL_DOT and LOCAL_IDX superinstructions
 * whose targets must be heap values (list/dict/etc). If the slot holds
 * an immediate, materialize it into a heap Value and stash it back in
 * the env so the next access sees a stable pointer (and so legacy
 * type-name error reporting works — "cannot index num"). Returns NULL
 * for null / out-of-range, otherwise a Value* the env owns a ref to. */
static inline Value *vm_local_lift(Env *e, uint16_t slot) {
    if ((int)slot >= e->count) return NULL;
    EigsSlot s = e->values[slot];
    if (slot_is_ptr(s)) return slot_as_ptr(s);
    if (slot_is_null(s)) return NULL;
    Value *v = slot_to_value(s);
    e->values[slot] = slot_from_heap(v);
    return v;
}

/* ---- VM helpers ---- */

static void vm_init(void) {
    if (eigs_current->vm == NULL) {
        eigs_current->vm = xcalloc(1, sizeof(VM));
        eigs_current->vm->owner = eigs_current;
        eigs_current->loop_exit_reason = "normal";
    }
}

void vm_thread_destroy(EigsThread *th) {
    if (th && th->vm) {
        free(th->vm);
        th->vm = NULL;
    }
}

/* Phase 9: defined after g_loop_iter_cache below. */
void vm_thread_reset_caches(void);

/* ---- Bridge helpers (Phase B-1) ----
 *
 * The stack stores EigsSlot, but during the Phase B rollout most
 * opcodes still expect to work with Value*. slot_bridge_wrap takes a
 * Value* and produces a slot that NEVER emits an immediate — the
 * pointer is always preserved. slot_bridge_unwrap is the inverse: it
 * always returns the underlying Value*, materializing a fresh one only
 * if an opcode that's already been migrated pushed a true immediate.
 *
 * These are local to vm.c because they're a transient pattern, not
 * part of the slot encoding contract. As opcodes are rewritten in
 * subsequent Phase B sub-steps, the unwrap helpers shrink toward
 * disuse. */
static inline EigsSlot slot_bridge_wrap(Value *v) {
    if (!v) return slot_null();
    if (v->type == VAL_NULL) {
        /* Caller passes an owned ref. Slot-encoded null drops the pointer,
         * so heap VAL_NULL (rare but possible — see promote_if_arena) must
         * be decref'd here. Singleton/arena nulls no-op the decref. */
        val_decref(v);
        return slot_null();
    }
    /* #262 Step E: nums never carry observer state → never TAG_TRACKED. */
    return slot_from_heap(v);
}

extern Value g_null_singleton_external_decl;  /* not used; doc only */

static inline Value *slot_bridge_unwrap(EigsSlot s) {
    if (slot_is_num(s)) {
        /* Materialize immediate -> fresh Value. Caller owns one ref. */
        return make_num(s.d);
    }
    if (slot_is_null(s)) {
        return make_null();
    }
    if (slot_is_bool(s)) {
        return make_num(slot_as_bool(s) ? 1.0 : 0.0);
    }
    /* Heap or tracked: just unwrap the pointer (ref already in slot). */
    return slot_as_ptr(s);
}

static inline void vm_push(Value *v) {
    if (g_vm.sp >= VM_STACK_MAX) {
        rt_error(EK_LIMIT, 0, "VM stack overflow");
        return;
    }
    g_vm.stack[g_vm.sp++] = slot_bridge_wrap(v);
}

static inline Value *vm_pop(void) {
    if (g_vm.sp <= 0) {
        /* Stack underflow — return null silently.
         * This can happen from POP between statements where a statement
         * didn't push a value (e.g., some control flow paths). */
        return make_null();
    }
    return slot_bridge_unwrap(g_vm.stack[--g_vm.sp]);
}

/* Lift a stack slot: if it holds an immediate (number / null / bool),
 * materialize a heap Value with refcount=1 AND overwrite the slot so the
 * lifted Value becomes the slot's owned reference. Heap/tracked slots
 * are returned as-is.
 *
 * This is the critical primitive that lets immediates flow safely:
 * peek-then-store sequences that previously double-allocated (one fresh
 * Value per peek) now share a single heap Value held by the slot. The
 * slot's eventual pop / decref releases the only reference. */
static inline Value *vm_slot_lift(int idx) {
    EigsSlot s = g_vm.stack[idx];
    if (slot_is_ptr(s)) return slot_as_ptr(s);
    Value *v;
    if (slot_is_num(s))       v = make_num(s.d);
    else if (slot_is_null(s)) v = make_null();
    else if (slot_is_bool(s)) v = make_num(slot_as_bool(s) ? 1.0 : 0.0);
    else                      v = make_null();
    g_vm.stack[idx] = slot_from_heap(v);
    return v;
}

static inline Value *vm_peek(int distance) {
    return vm_slot_lift(g_vm.sp - 1 - distance);
}

/* Direct-stack-access bridge macros. Most opcodes still touch the
 * stack as if it were a Value*[]; STK_AS_VAL routes through
 * vm_slot_lift so any immediate is materialized into the slot itself
 * (not freshly allocated per access). STK_PUT_VAL overwrites the slot
 * with a freshly wrapped Value*. */
#define STK_AS_VAL(i)       vm_slot_lift((i))
#define STK_PUT_VAL(i, v)   (g_vm.stack[i] = slot_bridge_wrap(v))

/* Raw slot push: bypasses slot_bridge_wrap, used by opcodes that emit
 * immediates directly (post-arith, post-cmp, NEG/NOT/BNOT, DUP, etc.). */
static inline void vm_push_slot(EigsSlot s) {
    if (g_vm.sp >= VM_STACK_MAX) {
        rt_error(EK_LIMIT, 0, "VM stack overflow");
        return;
    }
    g_vm.stack[g_vm.sp++] = s;
}

/* Slot-aware truthiness — covers immediate num, null, bool, and falls
 * back to is_truthy() for heap/tracked. */
static inline int slot_truthy(EigsSlot s) {
    if (slot_is_num(s)) return s.d != 0.0;
    if (slot_is_null(s)) return 0;
    if (slot_is_bool(s)) return slot_as_bool(s);
    return is_truthy(slot_as_ptr(s));
}

/* Pull a double out of a slot if it represents a number. Covers both
 * immediate doubles and heap/tracked VAL_NUMs (which still appear from
 * env loads and from the constant pool until B-3 flips those). */
static inline int slot_as_double(EigsSlot s, double *out) {
    if (slot_is_num(s)) { *out = s.d; return 1; }
    if (slot_is_ptr(s)) {
        Value *v = slot_as_ptr(s);
        if (v->type == VAL_NUM) { *out = v->data.num; return 1; }
    }
    return 0;
}

static inline uint16_t read_u16(uint8_t *ip) {
    return ip[0] | (ip[1] << 8);
}

/* is_truthy declared in eigenscript.h */

/* Iterator state: stored as a list [iterable, index] */
static Value *make_iter_state(Value *iterable) {
    Value *state = make_list(3);
    list_append(state, iterable);
    Value *idx = make_num(0);
    list_append(state, idx);
    val_decref(idx);
    /* #491: snapshot the length at loop entry (items[2]). ITER_NEXT bounds
     * the iteration by min(snapshot, live length), so appending to the
     * iterable in the body can no longer extend the loop (it used to read
     * the live count every step — an unbounded loop / OOM), while a shrink
     * (remove) still stops at the live length instead of reading a freed
     * slot. `for` over a list mutated in its body is thus well-defined:
     * exactly the indices 0..N-1 that existed at entry, read live. */
    int snap = 0;
    if (iterable && iterable->type == VAL_LIST)        snap = iterable->data.list.count;
    else if (iterable && iterable->type == VAL_BUFFER) snap = iterable->data.buffer.count;
    Value *slen = make_num((double)snap);
    list_append(state, slen);
    val_decref(slen);
    return state;
}

/* ---- JIT inline-emit layout (Stage 3b) ----
 *
 * vm.c owns g_vm (static __thread), so it is the only TU that can
 * compute the TLS @tpoff for it. The JIT emitter reads this layout
 * once per process and uses it to emit native loads/stores against
 * g_vm fields without indirection through helper functions. */
#include <stddef.h>

/* Sandbox loop-iteration cap. 0 = use the default 100,000,000 (normal runs are
 * unaffected); builtin_sandbox_run sets a low value to bound untrusted generated
 * code, then restores it. Read by the LOOP_CAP/STALL checks (interp + JIT
 * helpers). A plain process global: sandbox_run is synchronous. */
int g_sandbox_loop_max = 0;

/* Async abort seam (eigs_set_abort_flag): the embedder registers a flag it
 * may set from an interrupt/signal context; the interpreter polls it on
 * every loop back-edge and raises an ordinary runtime error ("aborted")
 * when set, consuming the flag. Deliberately PROCESS-global, not per-state:
 * the semantic is "abort whatever is evaluating" (a ctrl-c / timeout), and
 * the setter side must stay async-signal/IRQ-safe — a plain store into the
 * embedder's own int, no TLS deref, no runtime call. The runtime only ever
 * READS the embedder's flag (and clears it when honoring). The caveat
 * documented in eigs_embed.h: the error is an ordinary catchable runtime
 * error — a `try` around the loop can observe it (the flag can simply be
 * set again).
 *
 * #410: the pointer is NEVER NULL — unregistered points at a static
 * always-zero int (eigs_set_abort_flag maps NULL back to it). That turns
 * the poll into a single unconditional deref on both tiers, which is what
 * lets the JIT poll it too: the loop stencil emits the same
 * movabs/deref/cmpl at every back-edge and bails to the interpreter AT the
 * JUMP_BACK when set (the interpreter re-runs the back-edge, consumes the
 * flag, and raises through the normal error path — no error machinery in
 * native code). Unregistered costs one predicted-not-taken load+test per
 * back-edge, same as before. */
volatile int g_vm_abort_never = 0;
volatile int *g_vm_abort_flag = &g_vm_abort_never;

/* #292: sandbox allocation budget. The loop-iteration cap bounds VM back-edges
 * but NOT memory — an allowlisted allocator (zeros/fill/buffer/range/...) can
 * exhaust RAM in one capped-but-large call, or aggregate across a loop, and the
 * resulting x_oom -> abort() is uncatchable by sandbox_run's g_has_error path.
 * The size-controlled allocators call sandbox_charge() before allocating: while
 * a budgeted sandbox_run is active, a charge that would exceed the budget raises
 * a catchable runtime_error (sandbox_run then returns {ok:0}) instead of letting
 * the allocation reach abort(). Cumulative over the run (snippets are short, so
 * cumulative ~= peak); generous default, overridable via sandbox_run's max_bytes
 * arg. No-op outside a budgeted sandbox (active=0), so normal runs pay nothing.
 * Plain process globals: sandbox_run is synchronous and single-threaded.
 *
 * Charged at: zeros, fill, buffer, range, concat — the size-controlled list/
 * tensor allocators (the issue's vectors). NOT yet charged: zeros_like (mirrors
 * an already-charged input), matmul output (per-call capped at 10M elems; its
 * inputs are charged), and the text_builder growth path — all bounded by the
 * loop-iteration cap × per-op size, not the byte budget. Extending the budget to
 * them is a one-line sandbox_charge() at each; left out to match #292's scope. */
int    g_sandbox_active     = 0;
size_t g_sandbox_bytes_used = 0;
size_t g_sandbox_byte_max   = 0;   /* 0 = no budget */

int sandbox_charge(size_t bytes) {
    if (!g_sandbox_active || g_sandbox_byte_max == 0) return 1;
    /* Overflow-safe: g_sandbox_bytes_used <= g_sandbox_byte_max is an invariant
     * (we never commit a charge that breaks it), so the subtraction can't wrap. */
    if (bytes > g_sandbox_byte_max - g_sandbox_bytes_used) {
        rt_error(EK_SANDBOX, 0, "sandbox memory budget exceeded (used %zu + %zu > %zu bytes)",
                      g_sandbox_bytes_used, bytes, g_sandbox_byte_max);
        return 0;
    }
    g_sandbox_bytes_used += bytes;
    return 1;
}

/* JIT Stage 4k: out-of-line helper for OP_GET_NAME.
 *
 * Mirrors CASE(GET_NAME) below exactly — IC fast path then chain-walk
 * slow path with IC populate. Lives in vm.c so it can reach static
 * `g_vm` and the inline `vm_push_slot`. The JIT emits a 6-instruction
 * call site (sp sync + arg setup + aligned call + sp reload) instead
 * of trying to emit ~80 bytes of IC-walk-and-incref inline. The IC
 * itself still does its job — the helper just front-ends it. */
void jit_helper_get_name(EigsChunk *chunk, int idx) {
    EnvIC *ic = &chunk->env_ic[idx];
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *start = frame->env;
    if (__builtin_expect(ic->starting_env == start &&
                         ic->starting_ver == start->binding_version, 1)) {
        Env *target = ic->walk_depth ? start->parent : start;
        if (__builtin_expect(target && target->binding_version == ic->target_ver, 1)) {
            EigsSlot s = target->values[ic->slot_idx];
            slot_incref(s);
            vm_push_slot(s);
            return;
        }
    }
    const char *name = chunk->const_interns[idx];
    uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
    if (h == 0) {
        h = env_hash_name(name);
        if (chunk->const_hashes) chunk->const_hashes[idx] = h;
    }
    int slot_idx, depth;
    Env *target = env_resolve_chain(start, name, h, &slot_idx, &depth);
    if (!target) {
        rt_error(EK_UNDEFINED_NAME, g_vm.current_line, "undefined variable '%s'", name);
        vm_push_slot(slot_null());
        return;
    }
    if (depth <= 1) {
        ic->starting_env = start;
        ic->starting_ver = start->binding_version;
        ic->target_ver   = target->binding_version;
        ic->slot_idx     = slot_idx;
        ic->walk_depth   = (uint8_t)depth;
    }
    EigsSlot s = target->values[slot_idx];
    slot_incref(s);
    vm_push_slot(s);
}

/* JIT Stage 4x: out-of-line helpers for the SET name family. These are
 * the interpreter cases verbatim (trace hook, EnvIC fast path, resolve/
 * create slow path) against g_vm state. None of them touch the value
 * stack — the assigned value stays on TOS for the following OP_POP —
 * and none can raise, so the emitter needs no bail or flag handling.
 * These were the wall between per-fragment thunks and whole-loop
 * native coverage: every `x is ...` statement at module scope or on a
 * captured/interrogated name runs one. */
void jit_helper_set_name(EigsChunk *chunk, int idx) {
    if (__builtin_expect(g_trace_hist, 0)) {
        trace_assign(chunk->const_interns[idx], g_vm.stack[g_vm.sp - 1]);
    }
    EnvIC *ic = &chunk->env_ic[idx];
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *start = frame->env;
    EigsSlot s = g_vm.stack[g_vm.sp - 1];
    if (__builtin_expect(ic->starting_env == start &&
                         ic->starting_ver == start->binding_version, 1)) {
        Env *target = ic->walk_depth ? start->parent : start;
        if (__builtin_expect(target && target->binding_version == ic->target_ver, 1)) {
            env_store_slot(target, ic->slot_idx, s);
            if (target->assign_counts && g_unobserved_depth == 0)
                target->assign_counts[ic->slot_idx]++;
            return;
        }
    }
    const char *name = chunk->const_interns[idx];
    uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
    if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
    int slot_idx, depth;
    Env *target = env_resolve_chain(start, name, h, &slot_idx, &depth);
    if (target) {
        env_store_slot(target, slot_idx, s);
        if (target->assign_counts && g_unobserved_depth == 0)
            target->assign_counts[slot_idx]++;
        if (depth <= 1) {
            ic->starting_env = start;
            ic->starting_ver = start->binding_version;
            ic->target_ver   = target->binding_version;
            ic->slot_idx     = slot_idx;
            ic->walk_depth   = (uint8_t)depth;
        }
        return;
    }
    env_set_local_pre_interned_slot(start, name, h, s);
    Env *t2 = env_resolve_chain(start, name, h, &slot_idx, &depth);
    if (t2 == start) {
        ic->starting_env = start;
        ic->starting_ver = start->binding_version;
        ic->target_ver   = start->binding_version;
        ic->slot_idx     = slot_idx;
        ic->walk_depth   = 0;
    }
}

void jit_helper_set_name_local(EigsChunk *chunk, int idx) {
    if (__builtin_expect(g_trace_hist, 0)) {
        trace_assign(chunk->const_interns[idx], g_vm.stack[g_vm.sp - 1]);
    }
    EnvIC *ic = &chunk->env_ic[idx];
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *start = frame->env;
    EigsSlot s = g_vm.stack[g_vm.sp - 1];
    if (__builtin_expect(ic->starting_env == start &&
                         ic->starting_ver == start->binding_version &&
                         ic->walk_depth == 0 &&
                         ic->target_ver == start->binding_version, 1)) {
        env_store_slot(start, ic->slot_idx, s);
        if (start->assign_counts && g_unobserved_depth == 0)
            start->assign_counts[ic->slot_idx]++;
        return;
    }
    const char *name = chunk->const_interns[idx];
    uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
    if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
    env_set_local_pre_interned_slot(start, name, h, s);
    int slot_idx, depth;
    Env *target = env_resolve_chain(start, name, h, &slot_idx, &depth);
    if (target == start) {
        ic->starting_env = start;
        ic->starting_ver = start->binding_version;
        ic->target_ver   = start->binding_version;
        ic->slot_idx     = slot_idx;
        ic->walk_depth   = 0;
    }
}

void jit_helper_set_fn_name_local(EigsChunk *chunk, int idx) {
    if (__builtin_expect(g_trace_hist, 0)) {
        trace_assign(chunk->const_interns[idx], g_vm.stack[g_vm.sp - 1]);
    }
    EnvIC *ic = &chunk->env_ic[idx];
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *target = frame->fn_env;
    EigsSlot s = g_vm.stack[g_vm.sp - 1];
    if (__builtin_expect(ic->starting_env == target &&
                         ic->starting_ver == target->binding_version &&
                         ic->walk_depth == 0 &&
                         ic->target_ver == target->binding_version, 1)) {
        env_store_slot(target, ic->slot_idx, s);
        if (target->assign_counts && g_unobserved_depth == 0)
            target->assign_counts[ic->slot_idx]++;
        return;
    }
    const char *name = chunk->const_interns[idx];
    uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
    if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
    env_set_local_pre_interned_slot(target, name, h, s);
    int slot_idx, depth;
    Env *resolved = env_resolve_chain(target, name, h, &slot_idx, &depth);
    if (resolved == target) {
        ic->starting_env = target;
        ic->starting_ver = target->binding_version;
        ic->target_ver   = target->binding_version;
        ic->slot_idx     = slot_idx;
        ic->walk_depth   = 0;
    }
}

/* JIT Stage 4l: out-of-line helper for OP_LOCAL_IDX_GET.
 *
 * Mirrors CASE(LOCAL_IDX_GET) below — buffer / list / string indexing
 * with the same error semantics so try/catch behavior is preserved.
 * No chunk pointer required (unlike GET_NAME): the slot is enough to
 * reach fn_env via g_vm.frames[]. */
void jit_helper_local_idx_get(int slot, int idx) {
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *e = frame->fn_env;
    Value *target = vm_local_lift(e, (uint16_t)slot);
    if (target) {
        int i = idx;
        if (target->type == VAL_BUFFER) {
            if (i < target->data.buffer.count) {
                vm_push_slot(slot_from_num(target->data.buffer.data[i]));
            } else {
                rt_error(EK_INDEX, g_vm.current_line,
                    "buffer index %d out of range (length %d)",
                    i, target->data.buffer.count);
                vm_push_slot(slot_null());
            }
            return;
        }
        if (target->type == VAL_LIST) {
            if (i < target->data.list.count) {
                Value *item = target->data.list.items[i];
                if (item && item->type == VAL_NUM) {
                    vm_push_slot(slot_from_num(item->data.num));
                } else {
                    val_incref(item);
                    vm_push(item);
                }
            } else {
                rt_error(EK_INDEX, g_vm.current_line,
                    "index %d out of range (list length %d)",
                    i, target->data.list.count);
                vm_push_slot(slot_null());
            }
            return;
        }
        if (target->type == VAL_STR) {
            int len = (int)strlen(target->data.str);
            if (i < len) {
                char buf[2] = { target->data.str[i], 0 };
                vm_push(make_str(buf));
            } else {
                rt_error(EK_INDEX, g_vm.current_line,
                    "string index %d out of range (length %d)",
                    i, len);
                vm_push_slot(slot_null());
            }
            return;
        }
        if (target->type != VAL_NULL) {
            rt_error(EK_TYPE, g_vm.current_line,
                "cannot index %s", val_type_name(target->type));
        }
    }
    vm_push_slot(slot_null());
}

/* JIT Stage 4m: out-of-line helper for OP_LOCAL_DOT_GET.
 *
 * Mirrors CASE(LOCAL_DOT_GET) — looks up local[slot], dict-gets the
 * named field, pushes via immediate-num peephole when possible. Needs
 * chunk for const_interns / const_hashes (same as GET_NAME). */
void jit_helper_local_dot_get(EigsChunk *chunk, int slot, int name_idx) {
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *e = frame->fn_env;
    Value *target = vm_local_lift(e, (uint16_t)slot);
    if (target && target->type == VAL_DICT) {
        const char *key = chunk->const_interns[name_idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) {
            h = env_hash_name(key);
            if (chunk->const_hashes) chunk->const_hashes[name_idx] = h;
        }
        Value *v = dict_get_cached(target, key, h);
        if (v) {
            if (v->type == VAL_NUM) {
                vm_push_slot(slot_from_num(v->data.num));
            } else {
                val_incref(v);
                vm_push(v);
            }
        } else {
            vm_push_slot(slot_null());
        }
        return;
    }
    if (target && target->type != VAL_NULL) {
        const char *key = chunk->const_interns[name_idx];
        rt_error(EK_TYPE, g_vm.current_line,
            "cannot access field '%s' on %s",
            key, val_type_name(target->type));
    }
    vm_push_slot(slot_null());
}

/* JIT Stage 4v: out-of-line helper for OP_LOCAL_IDX_DOT_GET — the #1
 * DMG bailout at 48% of stops, dominating reads of ctx[0].a, ctx[1].pc,
 * etc. on every CPU step. Mirrors CASE(LOCAL_IDX_DOT_GET) in vm.c:
 * push one slot, no sp args needed (helper reads frame from g_vm).
 *
 * On any non-VAL_LIST target or out-of-range index, pushes slot_null()
 * (after runtime_error for the type errors) to match interpreter
 * semantics. The JIT site does not need to sync/reload sp around the
 * call — helper drives g_vm.sp directly via vm_push_*. */
void jit_helper_local_idx_dot_get(EigsChunk *chunk, int slot,
                                  int list_idx, int name_idx) {
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *e = frame->fn_env;
    Value *target = vm_local_lift(e, (uint16_t)slot);
    int i = list_idx;
    if (target && target->type == VAL_LIST) {
        if (i < target->data.list.count) {
            Value *dict = target->data.list.items[i];
            if (dict && dict->type == VAL_DICT) {
                const char *key = chunk->const_interns[name_idx];
                uint32_t h = chunk->const_hashes
                                ? chunk->const_hashes[name_idx] : 0;
                if (h == 0) {
                    h = env_hash_name(key);
                    if (chunk->const_hashes)
                        chunk->const_hashes[name_idx] = h;
                }
                Value *v = dict_get_cached(dict, key, h);
                if (v) {
                    if (v->type == VAL_NUM) {
                        vm_push_slot(slot_from_num(v->data.num));
                    } else {
                        val_incref(v);
                        vm_push(v);
                    }
                    return;
                }
            } else if (dict && dict->type != VAL_NULL) {
                const char *key = chunk->const_interns[name_idx];
                rt_error(EK_TYPE, g_vm.current_line,
                    "cannot access field '%s' on %s",
                    key, val_type_name(dict->type));
            }
        } else {
            rt_error(EK_INDEX, g_vm.current_line,
                "index %d out of range (list length %d)",
                i, target->data.list.count);
        }
    } else if (target && target->type != VAL_NULL) {
        rt_error(EK_TYPE, g_vm.current_line,
            "cannot index %s", val_type_name(target->type));
    }
    vm_push_slot(slot_null());
}

/* JIT Stage 4q-f: out-of-line helper for OP_DOT_GET.
 *
 * Mirrors CASE(DOT_GET): pops target from g_vm.stack (sp -= 1),
 * pushes target.name (sp += 1) — net sp change zero. Reads chunk for
 * const_interns / const_hashes (lazy hash fill matches the
 * interpreter). The JIT site must sync %ecx → g_vm.sp before the call
 * and reload after; sp is unchanged on return but reload keeps the
 * cache honest in case the helper internals ever change. */
/* Stage 5g: out-of-line helper for OP_DOT_SET. Mirrors CASE(DOT_SET):
 * pops value and target, dict-sets the field, pushes the value back
 * (net sp -1). Non-dict targets raise via runtime_error and the
 * dispatch loop's CHECK_ERROR picks it up after the thunk returns.
 * This was the last unsupported op in bench_dmg_shape's main loop
 * (`ctx.cycles is ...` / `ctx.pc is ...` on a GET_NAME'd dict). */
void jit_helper_dot_set(EigsChunk *chunk, int name_idx) {
    const char *key = chunk->const_interns[name_idx];
    uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
    if (h == 0) {
        h = env_hash_name(key);
        if (chunk->const_hashes) chunk->const_hashes[name_idx] = h;
    }
    /* Slot fast path (mirrors CASE(LOCAL_DOT_SET)): an immediate-num
     * write into an exclusive untracked num field mutates in place —
     * no make_num, no refcount churn. Was 2 make_num + 1.5 free_value
     * per DMG step via the vm_pop materialization below. */
    EigsSlot val_s = g_vm.stack[g_vm.sp - 1];
    EigsSlot tgt_s = g_vm.stack[g_vm.sp - 2];
    if (slot_is_num(val_s) && slot_is_ptr(tgt_s)) {
        Value *target = slot_as_ptr(tgt_s);
        if (target->type == VAL_DICT &&
            dict_set_cached_immediate(target, key, h, val_s.d)) {
            /* Same net stack effect as the slow path: pop val + target,
             * push val (val is immediate — no refcount sides). */
            g_vm.sp -= 1;
            g_vm.stack[g_vm.sp - 1] = val_s;
            slot_decref(tgt_s);
            return;
        }
    }
    Value *val = vm_pop(); Value *target = vm_pop();
    if (target->type == VAL_DICT)
        dict_set_cached(target, key, h, val);
    else if (target->type != VAL_NULL)
        rt_error(EK_TYPE, g_vm.current_line, "cannot set field '%s' on %s",
            key, val_type_name(target->type));
    val_decref(target);
    val_incref(val);
    vm_push(val);
    val_decref(val);
}

void jit_helper_dot_get(EigsChunk *chunk, int name_idx) {
    const char *key = chunk->const_interns[name_idx];
    uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
    if (h == 0) {
        h = env_hash_name(key);
        if (chunk->const_hashes) chunk->const_hashes[name_idx] = h;
    }
    Value *target = vm_pop();
    if (target->type == VAL_DICT) {
        Value *v = dict_get_cached(target, key, h);
        if (v) {
            if (v->type == VAL_NUM) {
                double n = v->data.num;
                val_decref(target);
                vm_push_slot(slot_from_num(n));
                return;
            }
            val_incref(v);
            val_decref(target);
            vm_push(v);
            return;
        }
    } else if (target->type != VAL_NULL) {
        rt_error(EK_TYPE, g_vm.current_line,
            "cannot access field '%s' on %s",
            key, val_type_name(target->type));
    }
    val_decref(target);
    vm_push_slot(slot_null());
}

/* JIT Stage 4q-d: out-of-line helper for OP_LOCAL_DOT_SET.
 *
 * Mirrors CASE(LOCAL_DOT_SET): local[slot].name = TOS, with TOS
 * remaining on the stack (the next OP_POP clears it). The immediate-
 * num fast path uses dict_set_cached_immediate to skip materialization.
 *
 * Helper reads g_vm.stack[g_vm.sp - 1] but does NOT change sp — the
 * JIT emitter must sync %ecx → g_vm.sp before the call but does not
 * need to reload after. */
void jit_helper_local_dot_set(EigsChunk *chunk, int slot, int name_idx) {
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *e = frame->fn_env;
    Value *target = vm_local_lift(e, (uint16_t)slot);
    if (target && target->type == VAL_DICT) {
        const char *key = chunk->const_interns[name_idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) {
            h = env_hash_name(key);
            if (chunk->const_hashes) chunk->const_hashes[name_idx] = h;
        }
        EigsSlot tos = g_vm.stack[g_vm.sp - 1];
        if (slot_is_num(tos) &&
            dict_set_cached_immediate(target, key, h, tos.d)) {
            return;
        }
        Value *val = vm_slot_lift(g_vm.sp - 1);
        dict_set_cached(target, key, h, val);
        return;
    }
    if (target && target->type != VAL_NULL) {
        const char *key = chunk->const_interns[name_idx];
        rt_error(EK_TYPE, g_vm.current_line, "cannot set field '%s' on %s",
            key, val_type_name(target->type));
    }
}

/* JIT Stage 4o: out-of-line helpers for OP_OBSERVE_ASSIGN /
 * OP_OBSERVE_ASSIGN_LOCAL. Both mirror their CASE bodies below: read
 * (and possibly promote) g_vm.stack[g_vm.sp - 1], wire observer history
 * from the prior binding, set g_last_observer.
 *
 * Helpers do not push or pop — sp count is unchanged across the call.
 * They DO mutate the top slot when promoting an immediate-num to a
 * tracked Value, so the JIT emitter must sync %ecx → g_vm.sp before
 * the call (the helper reads g_vm.stack[g_vm.sp - 1]). After return
 * the JIT scanner sets last_push_immediate = 0 to mark the slot as
 * possibly-pointer for subsequent peepholes.
 *
 * No runtime_error paths — these helpers never set g_vm.had_error. */
void jit_helper_observe_assign(EigsChunk *chunk, int name_idx) {
    /* #262 Phase-3/E — slot model: a name binding is observed by the
     * OBSERVE_NAME_POST that runs after its SET (when the slot is live), so this
     * pre-SET name hook does nothing. Kept as a no-op because the JIT emitter
     * still emits a call for OP_OBSERVE_ASSIGN. */
    (void)chunk; (void)name_idx;
}

void jit_helper_observe_assign_local(int slot) {
    if (g_unobserved_depth != 0) return;
    /* #262 Phase-3/E — slot model: observe the persistent (fn_env, slot)
     * trajectory directly from TOS. No promotion, no Value-side state, no window
     * migration (the slot persists across assigns). */
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    EigsSlot s = g_vm.stack[g_vm.sp - 1];
    Env *e = frame->fn_env;
    if (slot_is_num(s)) {
        observer_slot_update_num(e, slot, s.d);
        g_last_obs_slot_env = e; g_last_obs_slot_idx = slot;
    } else if (slot_is_ptr(s)) {
        observer_slot_update(e, slot, slot_as_ptr(s));
        g_last_obs_slot_env = e; g_last_obs_slot_idx = slot;
    }
}

/* #262 Phase-3 C.2: JIT helpers for the slot-keyed observer ops, so observer
 * loops still JIT-compile under the default slot model. Mirror the interpreter
 * CASE bodies. Stack contract matches the OBSERVE_ASSIGN helpers: the emitter
 * syncs %ecx->g_vm.sp before the call and reloads after, so a helper that
 * vm_push()es a result is reflected in the reloaded sp cache. */

/* OP_REPORT_SLOT [slot] — pushes the band string for a local binding. A local
 * slot always exists in the frame, so no chunk and no error path. */
void jit_helper_report_slot(int slot) {
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *e = frame->fn_env;
    Value *result;
    if (e && slot < e->obs_cap && e->obs[slot].used) {
        result = make_str(observer_slot_report(&e->obs[slot]));
    } else {
        result = make_str("equilibrium");  /* unobserved binding — no trajectory */
    }
    vm_push(result);
}

/* OP_OBSERVE_NAME_POST [name_idx] — observe a name binding's slot from TOS
 * after its SET. Peeks TOS; no stack change. Mirrors CASE(OBSERVE_NAME_POST). */
void jit_helper_observe_name_post(EigsChunk *chunk, int name_idx) {
    if (g_unobserved_depth != 0) return;
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    EigsSlot s = g_vm.stack[g_vm.sp - 1];
    /* #262 Phase-3 D: TOS may be an immediate num (the default path no longer
     * promotes observed names to tracked Values) or a heap value — observe the
     * slot from whichever. Skip null/bool. */
    if (!slot_is_num(s) && !slot_is_ptr(s)) return;
    const char *name = chunk->const_interns[name_idx];
    uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
    if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
    int oidx = -1, odepth = 0;
    Env *oe = env_resolve_chain(frame->env, name, h, &oidx, &odepth);
    if (oe && oidx >= 0) {
        if (slot_is_num(s)) observer_slot_update_num(oe, oidx, s.d);
        else observer_slot_update(oe, oidx, slot_as_ptr(s));
        g_last_obs_slot_env = oe;
        g_last_obs_slot_idx = oidx;
        /* #262 Phase-3 D2: slot-source the temporal snapshot — mirror of the
         * interpreter CASE(OBSERVE_NAME_POST). */
        if (__builtin_expect(g_trace_obs_hist, 0)) {
            const ObserverSlot *os = &oe->obs[oidx];
            trace_record_obs(name, os->entropy, os->dH, os->last_entropy);
        }
    }
}

/* JIT Stage 4q-a: out-of-line helper for OP_ITER_NEXT.
 *
 * Mirrors CASE(ITER_NEXT) in vm_run, but without ip mutation — returns
 * 1 if the iterator is exhausted (no element pushed), 0 if it pushed
 * the next element. The JIT-emitted call site reads the return value
 * and emits the conditional forward jump to the loop exit target.
 *
 * NOTE: NUM_REUSE check inlined here (the macro is defined further
 * down in this TU). */
int jit_helper_iter_next(void) {
    EigsSlot state_slot = g_vm.stack[g_vm.sp - 1];
    if (!slot_is_ptr(state_slot)) return 1;
    Value *state = slot_as_ptr(state_slot);
    if (!state || state->type != VAL_LIST || state->data.list.count < 2)
        return 1;
    Value *iterable = state->data.list.items[0];
    if (!iterable) return 1;
    Value *idx_v = state->data.list.items[1];
    if (!idx_v || idx_v->type != VAL_NUM) return 1;
    int idx = (int)idx_v->data.num;
    int len = 0;
    if (iterable->type == VAL_LIST)        len = iterable->data.list.count;
    else if (iterable->type == VAL_BUFFER) len = iterable->data.buffer.count;
    else                                   return 1;
    /* #491: cap by the entry-time snapshot (items[2]) — see make_iter_state.
     * Mirrors CASE(ITER_NEXT). */
    if (state->data.list.count >= 3) {
        Value *snap_v = state->data.list.items[2];
        if (snap_v && snap_v->type == VAL_NUM) {
            int snap = (int)snap_v->data.num;
            if (snap < len) len = snap;
        }
    }
    if (idx >= len) return 1;
    Value *elem;
    if (iterable->type == VAL_BUFFER) {
        elem = make_num(iterable->data.buffer.data[idx]);
    } else {
        elem = iterable->data.list.items[idx];
        val_incref(elem);
    }
    /* In-place idx bump when the slot is an exclusive plain VAL_NUM
     * (matches the interpreter's NUM_REUSE fast path). */
    if (idx_v->type == VAL_NUM && idx_v->refcount == 1 && !idx_v->arena) {
        idx_v->data.num = (double)(idx + 1);
    } else {
        val_decref(idx_v);
        state->data.list.items[1] = make_num(idx + 1);
    }
    vm_push(elem);
    return 0;
}

/* Integer-valued test for a subscript index: an exact integer (2.0) returns 1
 * and is written to *out; a fractional value (2.5) — or one from float drift
 * (2.9999998) — returns 0 so the caller can raise "index must be an integer"
 * instead of silently truncating. Pure predicate, no side effects: the raise
 * lives at the handling site so a target the fast path doesn't own (string,
 * dict) falls through to the slow path and is diagnosed exactly once. The
 * (double)(int) round-trip is the test — it reuses the cast every index site
 * already performs and is pure SSE2, deliberately avoiding floor()/roundsd
 * (SSE4.1, absent on the Merom target). Negatives pass here and fail the usual
 * >= 0 range check downstream, unchanged. */
static inline int vm_index_is_int(double d, int *out) {
    int i = (int)d;
    if ((double)i != d) return 0;
    *out = i;
    return 1;
}

/* 0.13.0: resolve negative index against len, then bounds-check.
 * On success, *i is rewritten to the absolute position; on failure
 * *i is left at the original value so error messages report what
 * the user wrote (a[-5] on len 3 says "-5 out of range", not "-2").
 * Negative resolution happens before the bounds check, matching
 * LANGUAGE_CONTRACT.md. */
static inline int vm_index_resolve(int *i, int len) {
    int r = (*i < 0) ? *i + len : *i;
    if (r < 0 || r >= len) return 0;
    *i = r;
    return 1;
}

/* ---- #366: frameless leaf-accessor calls ----
 *
 * A chunk flagged leaf_accessor (chunk_scan_leaf_accessor, chunk.c) is a
 * single pure expression over its params. An exactly-fed call can run it
 * here against the caller's stack: params ARE the arg slots, so there is
 * no env to take/rebind/park, no frame push, no chunk refcount traffic,
 * and no dispatch in/out of the callee — the measured ~200ns/call CALL
 * round-trip drops to the expression itself.
 *
 * Contract: returns 1 with args+fn popped and the result pushed (exactly
 * the generic call's stack effect), or 0 having touched NOTHING — any
 * type surprise, missing field chain, or out-of-range index bails so the
 * generic path re-executes with full semantics (identical runtime_error
 * text, lines, and null-push behavior). Every whitelisted op is side-
 * effect-free, which is what makes the bail-anytime contract sound.
 *
 * Mini-stack slots are BORROWS (no incref) — args stay live on the VM
 * stack until success, and no op here can free or mutate anything. The
 * result is increfed BEFORE the arg pops so a value borrowed from a
 * temporary argument survives (same reason as CASE(CALL)'s direct-
 * borrow heuristic). Mirrors CASE(LOCAL_DOT_GET)/CASE(INDEX_GET)/
 * ARITH_FAST semantics exactly — divergence here is a silent-wrong bug. */
static int vm_leaf_accessor_exec(EigsChunk *c, int argc) {
    EigsSlot mini[8];
    int msp = 0;
    const EigsSlot *args = &g_vm.stack[g_vm.sp - argc];
    uint8_t *ip = c->code;
    for (;;) {
        switch (*ip++) {
        case OP_LINE:
            ip += 2;
            break;
        case OP_CONST: {
            uint16_t idx = read_u16(ip); ip += 2;
            /* Scanner guarantees VAL_NUM. */
            mini[msp++] = slot_from_num(c->constants[idx]->data.num);
            break;
        }
        case OP_NUM_ZERO:
            mini[msp++] = slot_from_num(0.0);
            break;
        case OP_NUM_ONE:
            mini[msp++] = slot_from_num(1.0);
            break;
        case OP_GET_LOCAL: {
            uint16_t slot = read_u16(ip); ip += 2;
            mini[msp++] = args[slot];       /* borrow */
            break;
        }
        case OP_LOCAL_DOT_GET: {
            uint16_t slot = read_u16(ip); ip += 2;
            uint16_t name_idx = read_u16(ip); ip += 2;
            EigsSlot ts = args[slot];
            if (!slot_is_ptr(ts)) return 0;
            Value *target = slot_as_ptr(ts);
            if (!target || target->type != VAL_DICT) return 0;
            const char *key = c->const_interns[name_idx];
            uint32_t h = c->const_hashes[name_idx];
            if (h == 0) {
                h = env_hash_name(key);
                c->const_hashes[name_idx] = h;
            }
            Value *v = dict_get_cached(target, key, h);
            if (!v || v->type == VAL_NULL) {
                /* Missing field is null in the interpreter too. NOTE:
                 * slot_from_value would TAKE OWNERSHIP (decref) of a
                 * null/num input — these are borrows, so wrap by hand. */
                mini[msp++] = slot_null();
            } else if (v->type == VAL_NUM) {
                mini[msp++] = slot_from_num(v->data.num);
            } else {
                mini[msp++] = slot_from_heap(v);    /* borrow, no incref */
            }
            break;
        }
        case OP_INDEX_GET: {
            EigsSlot idx_s = mini[--msp];
            EigsSlot tgt_s = mini[--msp];
            double idx_d;
            /* slot_as_double: immediate OR boxed VAL_NUM index — a for-in
             * loop variable arrives as a heap num, same as ARITH_FAST. */
            if (!slot_as_double(idx_s, &idx_d) || !slot_is_ptr(tgt_s)) return 0;
            Value *target = slot_as_ptr(tgt_s);
            int i;
            if (!vm_index_is_int(idx_d, &i)) return 0;
            if (target->type == VAL_LIST) {
                if (!vm_index_resolve(&i, target->data.list.count)) return 0;
                Value *r = target->data.list.items[i];
                if (!r) return 0;
                if (r->type == VAL_NUM)
                    mini[msp++] = slot_from_num(r->data.num);
                else if (r->type == VAL_NULL)
                    mini[msp++] = slot_null();
                else
                    mini[msp++] = slot_from_heap(r);    /* borrow, no incref */
            } else if (target->type == VAL_BUFFER) {
                if (!vm_index_resolve(&i, target->data.buffer.count)) return 0;
                mini[msp++] = slot_from_num(target->data.buffer.data[i]);
            } else {
                return 0;
            }
            break;
        }
        case OP_ADD: case OP_SUB: case OP_MUL: {
            double a, b;
            if (!slot_as_double(mini[msp - 2], &a) ||
                !slot_as_double(mini[msp - 1], &b))
                return 0;
            double r;
            switch (ip[-1]) {
            case OP_ADD: r = a + b; break;
            case OP_SUB: r = a - b; break;
            default:     r = a * b; break;
            }
            msp--;
            mini[msp - 1] = slot_from_num(num_guard(r));
            break;
        }
        case OP_RETURN: {
            EigsSlot res = mini[--msp];
            slot_incref(res);
            for (int i = 0; i < argc; i++)
                slot_decref(g_vm.stack[--g_vm.sp]);
            slot_decref(g_vm.stack[--g_vm.sp]);   /* fn */
            g_vm.stack[g_vm.sp++] = res;
            return 1;
        }
        default:
            /* Unreachable: the scanner admitted only the ops above. */
            return 0;
        }
    }
}

/* Stage 4q-c: out-of-line helper for OP_INDEX_GET.
 *
 * Mirrors CASE(INDEX_GET) below: pops the index and target slots
 * (both from g_vm.stack[sp-1] / sp-2), decrements g_vm.sp by 2,
 * computes the indexed value, pushes the result (or null on error
 * after calling runtime_error to match the interpreter's behavior).
 *
 * The JIT-emitted call site syncs %ecx → g_vm.sp before the call
 * (helper reads sp), then reloads %ecx ← g_vm.sp after (helper
 * mutates sp net -1). */
/* Stage 5c: cached writer for the per-iteration __loop_iterations__
 * update. env_set_local resolves the 19-char name (hash + table walk)
 * and round-trips through make_num/val_decref on EVERY iteration of
 * EVERY `loop while` — measured as the dominant cost of observed loops
 * once the loop body itself compiles to native code. Cache the resolved
 * slot per (env, binding_version); on a hit with an immediate-num slot
 * (always, after the first write) the store is a bare double overwrite
 * plus the same assign_counts bump env_set_local_hashed performs.
 * binding_version moves on new-binding adds (which can realloc values[])
 * and env recycles — exactly the events that could invalidate the index.
 * Semantics are unchanged: mid-loop reads of __loop_iterations__ see the
 * same value as before. */
typedef struct {
    Env     *env;
    uint32_t version;
    int      slot;
} LoopIterCache;
static __thread LoopIterCache g_loop_iter_cache;

/* Phase 9: zero the file-static __thread caches so a state reattach on
 * the same OS thread can't witness a prior state's dict/env pointers.
 * Called from eigs_thread_attach. The arrays stay __thread because the
 * JIT inlines dict_cache via %fs:0+tpoff and the interpreter inlines
 * loop_iter_cache on every iteration — moving onto EigsThread would
 * cost an extra deref in both paths. */
void vm_thread_reset_caches(void) {
    memset(g_dict_cache, 0, sizeof(g_dict_cache));
    memset(&g_loop_iter_cache, 0, sizeof(g_loop_iter_cache));
}

static void loop_iter_store(Env *env, double n) {
    LoopIterCache *c = &g_loop_iter_cache;
    if (c->env == env && c->version == env->binding_version &&
        slot_is_num(env->values[c->slot])) {
        env->values[c->slot].d = n;
        if (env->assign_counts && g_unobserved_depth == 0)
            env->assign_counts[c->slot]++;
        return;
    }
    Value *iter_val = make_num(n);
    env_set_local(env, "__loop_iterations__", iter_val);
    val_decref(iter_val);
    int slot_idx, depth;
    Env *target = env_resolve_chain(env, "__loop_iterations__",
                                    env_hash_name("__loop_iterations__"),
                                    &slot_idx, &depth);
    if (target == env && depth == 0) {
        c->env = env;
        c->version = env->binding_version;
        c->slot = slot_idx;
    }
}

/* Stage 4w: out-of-line helper for OP_LOOP_STALL_CHECK. Mirrors the
 * interpreter case minus the jump: returns 1 when the loop should exit
 * (observer stalled 100 iterations, or the absolute iteration cap) so
 * the emitter can conditional-jump to the exit target, ITER_NEXT-style.
 * This was the #1 thunk blocker after INDEX_SET: every observed while
 * loop carries one of these per iteration. */
/* Env-explicit cores: the observed-loop stall/cap step on a given env, with no
 * dependency on the VM frame stack — so the AOT (which has no VM frames) can run
 * the exact same observer-loop halting as the interpreter and JIT. Exported via
 * eigenscript.h. The jit_helper_* wrappers below feed them the current frame's
 * env, so interpreter, JIT, and AOT share one implementation (no drift). */
int eigs_loop_stall_step(Env *e) {
    g_loop_iterations++;
    int should_exit = 0;
    if (g_unobserved_depth == 0) {
        double dH, ent;
        if (obs_stall_trajectory(&dH, &ent)
            && fabs(dH) < g_obs_dh_zero && ent >= g_obs_h_low) {
            g_loop_stall_count++;
            if (g_loop_stall_count >= 100) {
                g_loop_exit_reason = "stalled";
                should_exit = 1;
            }
        } else {
            g_loop_stall_count = 0;
        }
    }
    if (g_loop_iterations >= (g_sandbox_loop_max ? g_sandbox_loop_max : 100000000)) {
        g_loop_exit_reason = "limit";
        should_exit = 1;
    }
    loop_iter_store(e, (double)g_loop_iterations);
    if (should_exit) {
        Value *exit_val = make_str(g_loop_exit_reason);
        env_set_local(e, "__loop_exit__", exit_val);
        val_decref(exit_val);
        g_loop_stall_count = 0;
        g_loop_iterations = 0;
        g_loop_exit_reason = "normal";
        return 1;
    }
    return 0;
}

int eigs_loop_cap_step(Env *e) {
    g_loop_iterations++;
    int should_exit = 0;
    if (g_loop_iterations >= (g_sandbox_loop_max ? g_sandbox_loop_max : 100000000)) {
        g_loop_exit_reason = "limit";
        should_exit = 1;
    }
    loop_iter_store(e, (double)g_loop_iterations);
    if (should_exit) {
        Value *exit_val = make_str(g_loop_exit_reason);
        env_set_local(e, "__loop_exit__", exit_val);
        val_decref(exit_val);
        g_loop_stall_count = 0;
        g_loop_iterations = 0;
        g_loop_exit_reason = "normal";
        return 1;
    }
    return 0;
}

/* Stage 4w out-of-line helpers for OP_LOOP_STALL_CHECK / OP_LOOP_CAP_CHECK:
 * the current frame's env fed to the shared cores above (the JIT emits a call
 * to one of these per observed-loop iteration). */
int jit_helper_loop_stall_check(void) {
    return eigs_loop_stall_step(g_vm.frames[g_vm.frame_count - 1].env);
}
int jit_helper_loop_cap_check(void) {
    return eigs_loop_cap_step(g_vm.frames[g_vm.frame_count - 1].env);
}

/* Stage 4v: out-of-line helper for OP_INDEX_SET. Pops 3 (val, idx,
 * target), pushes val back (net sp -2). Full opcode semantics including
 * the slot fast paths, so the emitter never bails; errors go through
 * runtime_error and are picked up by CHECK_ERROR after the thunk. The
 * EIGS_JIT_STOPS histogram on the DMG-shaped workload showed INDEX_SET
 * as the only remaining bailout opcode. */
void jit_helper_index_set(void) {
    EigsSlot val_s = g_vm.stack[g_vm.sp - 1];
    EigsSlot idx_s = g_vm.stack[g_vm.sp - 2];
    EigsSlot tgt_s = g_vm.stack[g_vm.sp - 3];
    if (slot_is_num(idx_s) && slot_is_ptr(tgt_s)) {
        Value *target = slot_as_ptr(tgt_s);
        int i, _ok = vm_index_is_int(idx_s.d, &i);
        if (target->type == VAL_BUFFER && slot_is_num(val_s)) {
            if (_ok && vm_index_resolve(&i, target->data.buffer.count)) {
                target->data.buffer.data[i] = val_s.d;
            } else {
                if (!_ok) rt_error(EK_VALUE, g_vm.current_line, "index must be an integer, got %g", idx_s.d);
                else rt_error(EK_INDEX, g_vm.current_line, "buffer index %d out of range (length %d)",
                              i, target->data.buffer.count);
            }
            g_vm.sp -= 2;  /* keep val on TOS */
            g_vm.stack[g_vm.sp - 1] = val_s;
            slot_decref(idx_s);
            slot_decref(tgt_s);
            return;
        }
        if (target->type == VAL_LIST && slot_is_num(val_s)) {
            if (_ok && vm_index_resolve(&i, target->data.list.count)) {
                Value *existing = target->data.list.items[i];
                if (existing && existing->type == VAL_NUM &&
                    existing->refcount == 1 &&
                    !existing->arena) {
                    existing->data.num = val_s.d;
                } else {
                    val_decref(existing);
                    target->data.list.items[i] = make_num(val_s.d);
                }
            } else {
                if (!_ok) rt_error(EK_VALUE, g_vm.current_line, "index must be an integer, got %g", idx_s.d);
                else rt_error(EK_INDEX, g_vm.current_line, "index %d out of range (list length %d)",
                              i, target->data.list.count);
            }
            g_vm.sp -= 2;
            g_vm.stack[g_vm.sp - 1] = val_s;
            slot_decref(idx_s);
            slot_decref(tgt_s);
            return;
        }
    }
    Value *val = vm_pop(); Value *idx = vm_pop(); Value *target = vm_pop();
    if (target->type == VAL_LIST && idx->type == VAL_NUM) {
        int i;
        if (!vm_index_is_int(idx->data.num, &i)) {
            rt_error(EK_VALUE, g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        } else if (vm_index_resolve(&i, target->data.list.count)) {
            val_incref(val);
            val_decref(target->data.list.items[i]);
            target->data.list.items[i] = val;
        } else {
            rt_error(EK_INDEX, g_vm.current_line, "index %d out of range (list length %d)", i, target->data.list.count);
        }
    } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
        int i;
        if (!vm_index_is_int(idx->data.num, &i)) {
            rt_error(EK_VALUE, g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        } else if (!vm_index_resolve(&i, target->data.buffer.count)) {
            rt_error(EK_INDEX, g_vm.current_line, "buffer index %d out of range (length %d)", i, target->data.buffer.count);
        } else if (val->type == VAL_NUM) {
            target->data.buffer.data[i] = val->data.num;
        }
    } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
        dict_set(target, idx->data.str, val);
    } else if (target->type != VAL_NULL) {
        rt_error(EK_TYPE, g_vm.current_line, "cannot index %s for assignment", val_type_name(target->type));
    }
    val_decref(target); val_decref(idx);
    vm_push(val);
}

void jit_helper_index_get(void) {
    EigsSlot idx_s = g_vm.stack[g_vm.sp - 1];
    EigsSlot tgt_s = g_vm.stack[g_vm.sp - 2];
    g_vm.sp -= 2;
    if (slot_is_num(idx_s) && slot_is_ptr(tgt_s)) {
        Value *target = slot_as_ptr(tgt_s);
        int i, _ok = vm_index_is_int(idx_s.d, &i);
        if (target->type == VAL_LIST) {
            if (_ok && vm_index_resolve(&i, target->data.list.count)) {
                Value *r = target->data.list.items[i];
                if (r && r->type == VAL_NUM) {
                    /* See CASE(INDEX_GET) for the use-after-free story —
                     * snapshot r->data.num before slot_decref(tgt_s)
                     * potentially frees r via the num freelist. */
                    double rv = r->data.num;
                    slot_decref(tgt_s);
                    vm_push_slot(slot_from_num(rv));
                } else {
                    val_incref(r);
                    slot_decref(tgt_s);
                    vm_push(r);
                }
            } else {
                if (!_ok) rt_error(EK_VALUE, g_vm.current_line, "index must be an integer, got %g", idx_s.d);
                else rt_error(EK_INDEX, g_vm.current_line,
                    "index %d out of range (list length %d)",
                    i, target->data.list.count);
                slot_decref(tgt_s);
                vm_push_slot(slot_null());
            }
            return;
        }
        if (target->type == VAL_BUFFER) {
            if (_ok && vm_index_resolve(&i, target->data.buffer.count)) {
                double v = target->data.buffer.data[i];
                slot_decref(tgt_s);
                vm_push_slot(slot_from_num(v));
            } else {
                if (!_ok) rt_error(EK_VALUE, g_vm.current_line, "index must be an integer, got %g", idx_s.d);
                else rt_error(EK_INDEX, g_vm.current_line,
                    "buffer index %d out of range (length %d)",
                    i, target->data.buffer.count);
                slot_decref(tgt_s);
                vm_push_slot(slot_null());
            }
            return;
        }
    }
    /* Slow path: materialize both via slot_to_value for unified handling. */
    Value *idx = slot_to_value(idx_s);
    slot_decref(idx_s);
    Value *target = slot_to_value(tgt_s);
    slot_decref(tgt_s);
    Value *result = make_null();
    if (target->type == VAL_LIST && idx->type == VAL_NUM) {
        int i;
        if (!vm_index_is_int(idx->data.num, &i)) {
            rt_error(EK_VALUE, g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        } else if (vm_index_resolve(&i, target->data.list.count)) {
            result = target->data.list.items[i];
            val_incref(result);
        } else {
            rt_error(EK_INDEX, g_vm.current_line,
                "index %d out of range (list length %d)",
                i, target->data.list.count);
        }
    } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
        Value *v = dict_get(target, idx->data.str);
        if (v) { result = v; val_incref(result); }
    } else if (target->type == VAL_STR && idx->type == VAL_NUM) {
        int i;
        if (!vm_index_is_int(idx->data.num, &i)) {
            rt_error(EK_VALUE, g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        } else if (vm_index_resolve(&i, (int)strlen(target->data.str))) {
            char buf[2] = { target->data.str[i], 0 };
            result = make_str(buf);
        } else {
            rt_error(EK_INDEX, g_vm.current_line,
                "string index %d out of range (length %d)",
                i, (int)strlen(target->data.str));
        }
    } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
        int i;
        if (!vm_index_is_int(idx->data.num, &i))
            rt_error(EK_VALUE, g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        else if (vm_index_resolve(&i, target->data.buffer.count))
            result = make_num(target->data.buffer.data[i]);
        else
            rt_error(EK_INDEX, g_vm.current_line,
                "buffer index %d out of range (length %d)",
                i, target->data.buffer.count);
    } else if (target->type != VAL_NULL) {
        rt_error(EK_TYPE, g_vm.current_line,
            "cannot index %s", val_type_name(target->type));
    }
    val_decref(target); val_decref(idx);
    vm_push(result);
}

/* Direct-borrow heuristic, shared by the three builtin call sites
 * (CASE(CALL), jit_helper_call, OP_DISPATCH): if a builtin's result is
 * one of arg's top-level items (coalesce/append/dict_set return
 * arg->data.list.items[0]), incref it so it survives the arg-decref
 * that follows. Builtins returning a fresh allocation never match, so
 * no spurious ref is added; nested borrows (get_at: items[0][idx])
 * must still incref locally — only direct children are scanned.
 *
 * #546: the scan is CAPPED. A borrowing builtin can only return a
 * child it actually read, and every builtin reads its argument vector
 * at small fixed indices (max arity in the registry is 7), so items
 * past the cap can never be the borrowed result. Without the cap, a
 * single-list-argument call (`len of xs`) scanned the user's entire
 * list after every call — O(len) per call, turning the idiomatic
 * `loop while i < (len of xs):` quadratic. Raise the cap if a builtin
 * with a larger argument vector that RETURNS one of its args is ever
 * added (the assert-ish comment in builtins.c's registry is the
 * reminder).
 */
#define VM_BORROW_SCAN_CAP 8
static inline void vm_borrow_scan(Value *arg, Value *result) {
    if (arg && arg->type == VAL_LIST) {
        int n = arg->data.list.count;
        if (n > VM_BORROW_SCAN_CAP) n = VM_BORROW_SCAN_CAP;
        Value **items = arg->data.list.items;
        for (int i = 0; i < n; i++) {
            if (items[i] == result) { val_incref(result); break; }
        }
    }
}

/* JIT Stage 4r/5f: out-of-line helper for OP_CALL.
 *
 * Mirrors the VAL_BUILTIN branch of CASE(CALL), plus (Stage 5f) a
 * native fast path for bytecode VAL_FN callees that already have a
 * compiled thunk: push the frame here and invoke the callee's thunk
 * directly, so a fully-native callee (RETURN sentinel) lets the
 * CALLER's thunk continue without ever touching the dispatch loop.
 * Returns:
 *   0 — call completed (builtin ran, or VAL_FN callee ran natively to
 *       its RETURN): args+fn consumed, result pushed, frame state
 *       exactly as after an interpreted call. Caller thunk continues.
 *   1 — not eligible (non-callable / uncompiled callee / frame or
 *       native-depth limit / sp underflow). Helper has NOT touched the
 *       stack; caller thunk bails with %r13d at the CALL's own offset
 *       so the interpreter re-executes OP_CALL with full semantics.
 *   2 — deep bail: the callee's thunk exited early (guard bail, or a
 *       nested deep bail, or a pending error). The callee's frame is
 *       still live with a consistent ip, and the CALLER frame's ip has
 *       been set to resume_off (the op after the CALL). The caller
 *       thunk must exit with the -2 advance sentinel so vm_run resyncs
 *       to whatever frame is now current and resumes interpreting.
 *
 * Helper reads and writes g_vm.sp directly; the JIT emitter syncs
 * %ecx → g_vm.sp before the call and reloads after. */

/* Stage 5f: each nested native call recurses the C stack (helper +
 * thunk frames), unlike the interpreter's flat frame array. Cap the
 * native depth; deeper recursion runs interpreted via return code 1. */
#define JIT_NATIVE_CALL_DEPTH_MAX 64
/* g_native_call_depth lives on EigsThread (Phase 8); bridge macro from
 * eigenscript.h. */

int jit_helper_call(EigsChunk *caller_chunk, int argc, int resume_off) {
    if (g_vm.sp < argc + 1) return 1;
    Value *fn_val = STK_AS_VAL(g_vm.sp - 1 - argc);
    if (fn_val->type != VAL_BUILTIN) {
        /* Stage 5f: bytecode-fn fast path. Only when the callee already
         * has a from-zero thunk — otherwise the interpreter's
         * CASE(CALL) runs (and does the exec_count accounting + lazy
         * compile that eventually unlocks this path). */
        if (fn_val->type != VAL_FN || fn_val->data.fn.body_count != -1)
            return 1;
        EigsChunk *fn_chunk = (EigsChunk *)fn_val->data.fn.body;
        /* #366: frameless leaf-accessor fast path — same contract as
         * return 0 (args+fn consumed, result pushed). Bail falls through
         * to the thunk path / interpreter re-execution. */
        if (fn_chunk->leaf_accessor && argc == fn_val->data.fn.param_count &&
            !g_trace_hist && vm_leaf_accessor_exec(fn_chunk, argc))
            return 0;
        if (fn_chunk->jit_state != 2 || !fn_chunk->jit_code) return 1;
        if (g_task_sched) return 1;   /* #533: task code runs interpreted */
        if (g_vm.frame_count >= VM_FRAMES_MAX) return 1;
        if (g_native_call_depth >= JIT_NATIVE_CALL_DEPTH_MAX) return 1;

        int caller_idx = g_vm.frame_count - 1;

        /* Frame push — CASE(CALL)'s VAL_FN path verbatim, including
         * the Stage 5i recycled-env fast path. */
        int param_count = fn_val->data.fn.param_count;
        Env *call_env = vm_take_call_env(fn_chunk,
                                         fn_val->data.fn.closure,
                                         param_count, argc);
        if (call_env) {
            if (param_count > 1) {
                for (int i = 0; i < param_count; i++)
                    env_rebind_param_slot(call_env, i,
                        g_vm.stack[g_vm.sp - argc + i]);
            } else if (param_count == 1) {
                if (argc == 1) {
                    env_rebind_param_slot(call_env, 0,
                        g_vm.stack[g_vm.sp - 1]);
                } else {
                    Value *arg_list = make_list(argc);
                    for (int i = 0; i < argc; i++)
                        list_append(arg_list, STK_AS_VAL(g_vm.sp - argc + i));
                    env_rebind_param_slot(call_env, 0,
                        slot_from_heap(arg_list));
                    val_decref(arg_list);
                }
            }
        } else {
        call_env = env_new(fn_val->data.fn.closure);
        uint32_t *phashes = fn_val->data.fn.param_hashes;
        int can_default = (fn_chunk->first_default < param_count) &&
                          (argc < param_count);
        if (param_count > 1 && argc > 0) {
            int bound = param_count < argc ? param_count : argc;
            for (int i = 0; i < bound; i++) {
                uint32_t ph = phashes ? phashes[i]
                                      : env_hash_name(fn_val->data.fn.params[i]);
                env_bind_fresh_param_slot(call_env,
                    fn_val->data.fn.params[i], ph,
                    g_vm.stack[g_vm.sp - argc + i]);
            }
        } else if (param_count == 1 && !can_default) {
            uint32_t ph = phashes ? phashes[0]
                                  : env_hash_name(fn_val->data.fn.params[0]);
            if (argc == 1) {
                vm_bind_fresh_param(call_env, 0,
                    fn_val->data.fn.params[0], ph,
                    g_vm.stack[g_vm.sp - 1]);
            } else {
                Value *arg_list = make_list(argc);
                for (int i = 0; i < argc; i++)
                    list_append(arg_list, STK_AS_VAL(g_vm.sp - argc + i));
                vm_bind_fresh_param(call_env, 0,
                    fn_val->data.fn.params[0], ph,
                    slot_from_heap(arg_list));
                val_decref(arg_list);
            }
        }
        if (can_default) {
            for (int i = argc; i < param_count; i++) {
                uint32_t ph = phashes ? phashes[i]
                                      : env_hash_name(fn_val->data.fn.params[i]);
                env_bind_fresh_param_slot(call_env,
                    fn_val->data.fn.params[i], ph, slot_null());
            }
        }
        if (fn_chunk->local_count > param_count)
            env_reserve_slots(call_env, fn_chunk->local_count);
        }
        for (int i = 0; i < argc; i++)
            slot_decref(g_vm.stack[--g_vm.sp]);
        slot_decref(g_vm.stack[--g_vm.sp]); /* fn */

        /* The caller frame's ip stays at the thunk's entry offset (the
         * jit_advance-relative contract); it is fixed to resume_off
         * only on the deep-bail paths, where the interpreter takes
         * over mid-thunk. */
        CallFrame *frame = &g_vm.frames[g_vm.frame_count++];
        frame->chunk = fn_chunk;
        frame->call_serial = ++g_call_serial_next;   /* #539 v2 */
        chunk_incref(fn_chunk);
        frame->ip = fn_chunk->code;
        frame->bp = g_vm.sp;
        frame->env = call_env;
        frame->fn_env = call_env;
        frame->closure_val = fn_val;
        frame->owns_env = 1;
        frame->is_try = 0;
        frame->try_count = 0;
        frame->saved_stall_count = g_loop_stall_count;
        frame->saved_loop_iter   = g_loop_iterations;
        frame->call_argc = argc;
        g_loop_stall_count = 0;
        g_loop_iterations  = 0;
        fn_chunk->exec_count++;

        g_native_call_depth++;
        ((JitChunkFn)fn_chunk->jit_code)();
        g_native_call_depth--;

        int adv = fn_chunk->jit_advance;
        if (adv == -1) {
            /* Callee ran to RETURN: its frame is popped (by
             * jit_helper_return) and the result is on the caller's
             * stack. Drop the popped frame's chunk ref — the same duty
             * vm_run's -1 handler performs when it invoked the thunk. */
            chunk_decref(fn_chunk);
            if (__builtin_expect(g_has_error, 0)) {
                /* Error pending from inside the callee: force a
                 * dispatch now so CHECK_ERROR unwinds promptly instead
                 * of after an arbitrary amount of native caller code.
                 * The call itself completed — resume past it. */
                g_vm.frames[caller_idx].ip = caller_chunk->code + resume_off;
                return 2;
            }
            return 0;
        }
        /* Callee bailed mid-prefix (adv >= 0: callee is the top frame;
         * advance its ip past the natively-run prefix) or deep-bailed
         * itself (adv == -2: a nested helper already left every deeper
         * frame's ip consistent). Either way the interpreter takes
         * over from the current top frame. */
        if (adv != -2)
            g_vm.frames[g_vm.frame_count - 1].ip += adv;
        g_vm.frames[caller_idx].ip = caller_chunk->code + resume_off;
        return 2;
    }

    Value *arg;
    if (argc == 1) {
        arg = STK_AS_VAL(g_vm.sp - 1);
        val_incref(arg);
    } else {
        /* Wrapper must be heap: val_decref(arg) below has to actually
         * release the list_append increfs on heap items, which an arena
         * list silently swallows. */
        arg = make_list_heap(argc);
        for (int i = 0; i < argc; i++) {
            list_append(arg, STK_AS_VAL(g_vm.sp - argc + i));
        }
    }
    for (int i = 0; i < argc; i++)
        slot_decref(g_vm.stack[--g_vm.sp]);
    slot_decref(g_vm.stack[--g_vm.sp]); /* fn */

    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    Env *saved = g_builtin_call_env;
    g_builtin_call_env = frame->env;
    int consumes_arg = (fn_val->data.builtin == builtin_free_val);
    Value *result = fn_val->data.builtin(arg);
    g_builtin_call_env = saved;

    if (!result) {
        result = make_null();
    } else if (!consumes_arg && result != arg) {
        /* Direct-borrow heuristic (capped, #546) — see vm_borrow_scan;
         * !consumes_arg guard: free_val may have already freed arg. */
        vm_borrow_scan(arg, result);
    }
    if (!consumes_arg && result != arg) val_decref(arg);
    vm_push(result);
    return 0;
}

/* JIT Stage 4s: out-of-line helper for OP_RETURN.
 *
 * Mirrors CASE(RETURN)'s non-top-level branch: pops result, drains the
 * frame's stack slice, frees env if owned, restores loop-stall globals,
 * decrements frame_count, and pushes the result onto the (now-current)
 * caller's stack. The JIT-emitted call site pre-sets %r13d = -1 so the
 * thunk's epilogue writes -1 into chunk->jit_advance; vm_run's post-thunk
 * code checks for that sentinel and resyncs frame/ip/chunk (or returns
 * the top-of-stack as a Value* when frame_count <= base_frame).
 *
 * The helper always succeeds (no bail return code) because there is no
 * "non-builtin"-style early exit for RETURN: every well-formed function
 * eventually hits one, and the data movement is unconditional. Top-level
 * detection (base_frame comparison) happens in vm_run because the helper
 * doesn't know base_frame.
 *
 * Try-catch state on the popped frame is silently dropped (matching the
 * interpreter — frame->try_count drops with the CallFrame). g_has_error
 * already propagated by any earlier helper is preserved; CHECK_ERROR
 * fires on the next interpreter DISPATCH if try_depth allows. */
void jit_helper_return(void) {
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    EigsSlot result_s;
    if (g_vm.sp > frame->bp) {
        result_s = g_vm.stack[--g_vm.sp];
    } else {
        result_s = slot_null();
    }
    while (g_vm.sp > frame->bp)
        slot_decref(g_vm.stack[--g_vm.sp]);
    if (frame->owns_env) {
        /* Stage 5i: park for recycling when eligible. */
        if (frame->env != frame->fn_env ||
            !vm_park_call_env(frame->chunk, frame->env))
            env_decref(frame->env);
    }
    g_loop_stall_count = frame->saved_stall_count;
    g_loop_iterations  = frame->saved_loop_iter;
    /* The frame's chunk ref is NOT dropped here: the thunk epilogue still
     * writes chunk->jit_advance after we return. vm_run's -1 sentinel
     * handler drops it. */
    g_vm.frame_count--;
    /* Push result onto whatever is now the current top frame's slice.
     * For a top-level return (frame_count became 0 or fell below
     * vm_run's base_frame), vm_run's post-thunk handler pops this off
     * and converts to Value*. */
    g_vm.stack[g_vm.sp++] = result_s;
}

/* JIT Stage 4t: out-of-line helper for OP_RETURN_NULL. Same shape as
 * jit_helper_return but never reads from the stack — always pushes
 * slot_null() onto the caller. Used by chunks whose final op is the
 * explicit-null return emitted by the compiler when a function falls
 * off the end with no explicit return value. Carries the same
 * jit_advance = -1 sentinel via the emitter's pre-set %r13d. */
void jit_helper_return_null(void) {
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    while (g_vm.sp > frame->bp)
        slot_decref(g_vm.stack[--g_vm.sp]);
    if (frame->owns_env) {
        /* Stage 5i: park for recycling when eligible. */
        if (frame->env != frame->fn_env ||
            !vm_park_call_env(frame->chunk, frame->env))
            env_decref(frame->env);
    }
    g_loop_stall_count = frame->saved_stall_count;
    g_loop_iterations  = frame->saved_loop_iter;
    /* Chunk ref deferred to vm_run's -1 handler (see jit_helper_return). */
    g_vm.frame_count--;
    g_vm.stack[g_vm.sp++] = slot_null();
}

/* Helper called by the JIT prologue on platforms where the JIT can't
 * encode TLS access directly — Darwin/Mach-O uses TLV descriptors
 * (per-variable callable thunks), not the fixed-offset %fs:tpoff that
 * Linux ELF uses. Returns the *value* of `eigs_current` (the
 * EigsThread* the calling thread is attached to), matching what the
 * Linux prologue gets from a single `mov %fs:tpoff, %rbx`. The C
 * compiler emits the platform-correct TLS sequence around the load.
 * Used on Darwin x86_64; Linux x86_64 keeps inlining the %fs read. */
void *eigs_jit_load_eigs_current(void) {
    return (void *)eigs_current;
}

void eigs_jit_get_layout(EigsJitLayout *out) {
#if EIGS_JIT_ENABLED
    out->off_thread_vm                = (int)offsetof(EigsThread, vm);
    out->off_thread_unobserved_depth  = (int)offsetof(EigsThread, unobserved_depth);
    out->off_vm_owner                 = (int)offsetof(VM, owner);
    out->off_sp              = (int)offsetof(VM, sp);
    out->off_stack           = (int)offsetof(VM, stack);
    out->off_frame_count     = (int)offsetof(VM, frame_count);
    out->off_frames          = (int)offsetof(VM, frames);
    out->off_current_line    = (int)offsetof(VM, current_line);
    out->off_callframe_ip    = (int)offsetof(CallFrame, ip);
    out->off_callframe_fn_env= (int)offsetof(CallFrame, fn_env);
    out->sizeof_callframe    = (int)sizeof(CallFrame);
    out->off_env_values      = (int)offsetof(Env, values);
    out->off_env_count       = (int)offsetof(Env, count);
    out->off_dcache_dict     = (int)offsetof(DictCacheEntry, dict);
    out->off_dcache_hash     = (int)offsetof(DictCacheEntry, hash);
    out->off_dcache_index    = (int)offsetof(DictCacheEntry, index);
    out->dcache_mask         = DICT_CACHE_SET_MASK;
#if defined(__APPLE__)
    /* Mach-O __thread access goes through TLV descriptor calls, not a
     * fixed %fs:tpoff offset. The JIT prologue reaches `eigs_current`
     * via `eigs_jit_load_eigs_current` instead of inline %fs read,
     * so the tpoffs aren't needed (and aren't meaningful). The
     * dict-cache inline probe is keyed on a separate TLS global with
     * no relationship to eigs_current; zeroing dcache_ways routes
     * LOCAL_DOT_GET/SET to the slow-path helper, so we don't have to
     * teach the inline probe how to find &g_dict_cache[0] on Mach-O.
     * Net: macOS x86_64 keeps the JIT for everything except the
     * dict-field inline cache. */
    out->eigs_current_tpoff  = 0;
    out->g_dict_cache_tpoff  = 0;
    out->sizeof_dcache_entry = 0;
    out->dcache_ways         = 0;
#else
    {
        void *tp;
        __asm__ __volatile__("mov %%fs:0, %0" : "=r"(tp));
        out->eigs_current_tpoff = (long)((char *)&eigs_current - (char *)tp);
        out->g_dict_cache_tpoff = (long)((char *)&g_dict_cache[0] - (char *)tp);
    }
    out->sizeof_dcache_entry = (int)sizeof(DictCacheEntry);
    out->dcache_ways         = DICT_CACHE_WAYS;
#endif
#else
    (void)out;
#endif
}

/* ---- Main execution loop ---- */

/* True if any frame in [base, top] still has an active try handler. Called
 * only from CHECK_ERROR's slow path (g_has_error already set), so the
 * linear scan is off the hot path. Used to decide whether an uncaught
 * runtime error has any catcher within *this* vm_run invocation; if not,
 * vm_run unwinds and returns with g_has_error still set so the C caller
 * (a re-entrant vm_run, or main) observes the failure. */
/* Catch-binding: if `throw` stashed a structured error value (dict,
 * list, string, ...), the catch variable binds that value — ownership
 * of the stash's ref transfers to the stack. Built-in runtime errors
 * bind a {kind, message, line} dict (#406): kind from the closed
 * ErrKind vocabulary, message without the "Error line N:" frame, line
 * 1-based. Built lazily here so the uncaught path never allocates. */
static Value *vm_take_error_value(void) {
    if (g_error_value) {
        Value *v = g_error_value;
        g_error_value = NULL;
        return v;
    }
    Value *d = make_dict(3);
    dict_set_owned(d, "kind", make_str(err_kind_name((ErrKind)g_error_kind)));
    dict_set_owned(d, "message", make_str(g_error_raw));
    dict_set_owned(d, "line", make_num((double)g_error_line));
    return d;
}

/* Live source line for error stamping — rt_error uses this when a raise
 * site (a builtin) has no line of its own. 0 when no VM is running. */
int vm_current_line(void) {
    if (!eigs_current || !eigs_current->vm) return 0;
    return g_vm.current_line;
}

/* Print the live call stack, innermost frame first. Called by
 * runtime_error/builtin_throw for *uncaught* errors (g_try_depth == 0)
 * so failures show where they happened, not just the innermost line.
 * Frame lines come from the per-offset line table at each frame's
 * saved ip; the innermost frame uses g_vm.current_line, which the
 * dispatch loop keeps fresh. */
void vm_print_stack_trace(FILE *out) {
    if (g_vm.frame_count <= 0) return;
    for (int i = g_vm.frame_count - 1; i >= 0; i--) {
        CallFrame *f = &g_vm.frames[i];
        const char *fname = (f->chunk && f->chunk->name) ? f->chunk->name : "?";
        int line = 0;
        if (i == g_vm.frame_count - 1) {
            line = g_vm.current_line;
        } else if (f->chunk && f->ip) {
            long off = f->ip - f->chunk->code;
            if (off > 0) off--;   /* ip points past the resume opcode */
            if (off >= 0 && off < f->chunk->lines_len)
                line = f->chunk->lines[off];
        }
        fprintf(out, "  at %s (line %d)\n", fname, line);
    }
}

/* #407 residual: print a deferred uncaught-error report (message, source
 * excerpt + column caret, stack trace). rt_error/builtin_throw set
 * g_error_print_pending instead of printing while the VM is mid-dispatch;
 * the dispatch loop's CHECK_ERROR calls this with the live ip, which
 * points one opcode past the failing instruction — so ip-1 lands inside
 * the failing instruction's bytes and cols[]/lines[] carry its position.
 * The lines[off] == g_error_line guard suppresses the caret whenever the
 * offset disagrees with the reported line (JIT-advanced ip, builtin line
 * restamps), so a caret only ever prints on the correct source line. */
static void vm_error_flush_pending(EigsChunk *chunk, const uint8_t *ip) {
    if (!g_error_print_pending) return;
    g_error_print_pending = 0;
    fprintf(stderr, "%s\n", g_error_msg);
    if (chunk && ip && chunk->cols && chunk->src && chunk->src->text) {
        long off = ip - chunk->code - 1;
        if (off >= 0 && off < chunk->lines_len &&
            chunk->lines[off] == g_error_line)
            eigs_print_caret_src(stderr, chunk->src->text,
                                 g_error_line, chunk->cols[off]);
    }
    vm_print_stack_trace(stderr);
}

static int vm_handler_in_range(int base) {
    for (int i = g_vm.frame_count - 1; i >= base; i--)
        if (g_vm.frames[i].try_count > 0) return 1;
    return 0;
}

/* Type name for a stack slot, for error diagnostics. Returns a static
 * string (safe to hold across a decref). */
static const char *slot_type_name(EigsSlot s) {
    if (slot_is_null(s)) return "none";
    if (slot_is_ptr(s)) { Value *v = slot_as_ptr(s); return v ? val_type_name(v->type) : "none"; }
    return "num"; /* immediate double / bool */
}

/* #408: forward decls — the copying-stack save/restore and the "who is
 * running" helper live with the scheduler below vm_execute; vm_run_ex's
 * resume/suspend paths call them. */
static void task_restore_slice(Task *t);
static void task_save_slice(Task *t);
static Task *task_current_running(void);
static void task_reap(Task *t);   /* #530 */
static void task_apply_join_result(Task *t);   /* fill a join placeholder on resume */
static void task_apply_recv_result(Task *t);   /* fill a recv placeholder on resume */

/* vm_run_ex: the shared VM dispatch body. `resume` != NULL means resume a
 * suspended #408 task — restore its copying-stack slice onto the (empty) VM
 * and continue from the innermost frame's saved ip, instead of pushing a
 * fresh base frame. vm_run() is the ordinary fresh-entry wrapper. */
static Value *vm_run_ex(EigsChunk *chunk, Env *env, Task *resume) {
    int base_frame;
    CallFrame *frame;
    uint8_t *ip;
    int current_line = 0;

    if (resume) {
        /* Resume: the scheduler only ever resumes a task at the outermost
         * level, so base_frame is 0. Restore frames+stack, then continue
         * from where task_yield/task_join left off (its placeholder result
         * already sits on the restored stack top). */
        base_frame = 0;
        task_restore_slice(resume);
        /* If this task was blocked in task_join / task_recv, fill the
         * placeholder on the stack top with the joinee's result (or re-raise
         * its error) / the delivered message. A task is blocked on at most one
         * of the two, so both are safe to run. */
        task_apply_join_result(resume);
        task_apply_recv_result(resume);
        frame = &g_vm.frames[g_vm.frame_count - 1];
        chunk = frame->chunk;
        ip = frame->ip;
        current_line = g_vm.current_line;
        goto vm_resume_dispatch;
    }

    base_frame = g_vm.frame_count; /* track entry point for re-entrant returns */
    /* Module-level slot promotion (Part B) AND nested entries from builtins
     * (e.g. call_eigs_fn, eval): if the chunk allocated slots past env->count
     * at compile time, reserve them now so OP_SET_LOCAL has a place to write.
     * Slot indices in bytecode are absolute env positions. */
    if (chunk->local_count > env->count) {
        env_reserve_slots(env, chunk->local_count);
    }
    frame = &g_vm.frames[g_vm.frame_count++];
    frame->chunk = chunk;
    frame->call_serial = ++g_call_serial_next;   /* #539 v2 */
    chunk_incref(chunk);   /* frame's ref — released when this frame pops */
    frame->ip = chunk->code;
    frame->bp = g_vm.sp;
    frame->env = env;
    frame->fn_env = env;
    frame->closure_val = NULL;
    frame->owns_env = 0;
    frame->is_try = 0;
    frame->try_count = 0;
    frame->saved_stall_count = g_loop_stall_count;
    frame->saved_loop_iter   = g_loop_iterations;
    /* Entry paths via vm_execute (thread_entry, call_eigs_fn, dispatch,
     * HTTP handlers, module-level) have already bound every param in
     * env before getting here. Mark all slots as caller-supplied so
     * OP_DEFAULT_PARAM doesn't re-fire defaults over them — and so a
     * stale value left by a prior frame at this depth can't clobber
     * explicit args. */
    frame->call_argc = chunk->param_count;
    /* #297: JIT hotness bookkeeping is shared per-chunk state and feeds JIT
     * compilation, which is gated off under MT (#296). Skip it while
     * multithreaded — pointless work, and the bare ++ / registry write race
     * with parallel workers running the same chunk. #408: also skip while a
     * cooperative task scheduler is active — task code runs interpreted so a
     * JIT thunk never runs mid-suspend (the "non-JIT suspending code" ruling,
     * coarsened for v1: V8 shipped un-optimized generators for years). */
    if (!g_vm_multithreaded && !g_task_sched) {
        chunk->exec_count++;
        jit_register_chunk(chunk);
    }

    ip = frame->ip;

#ifdef __GNUC__
    /* Computed goto dispatch table */
    static void *dispatch_table[OP_COUNT] = {
        [OP_CONST] = &&lbl_CONST, [OP_NULL] = &&lbl_NULL,
        [OP_NUM_ZERO] = &&lbl_NUM_ZERO, [OP_NUM_ONE] = &&lbl_NUM_ONE,
        [OP_ADD] = &&lbl_ADD, [OP_SUB] = &&lbl_SUB,
        [OP_MUL] = &&lbl_MUL, [OP_DIV] = &&lbl_DIV, [OP_MOD] = &&lbl_MOD,
        [OP_BAND] = &&lbl_BAND, [OP_BOR] = &&lbl_BOR, [OP_BXOR] = &&lbl_BXOR,
        [OP_SHL] = &&lbl_SHL, [OP_SHR] = &&lbl_SHR,
        [OP_NEG] = &&lbl_NEG, [OP_NOT] = &&lbl_NOT, [OP_BNOT] = &&lbl_BNOT,
        [OP_EQ] = &&lbl_EQ, [OP_NE] = &&lbl_NE,
        [OP_LT] = &&lbl_LT, [OP_GT] = &&lbl_GT,
        [OP_LE] = &&lbl_LE, [OP_GE] = &&lbl_GE,
        [OP_GET_LOCAL] = &&lbl_GET_LOCAL, [OP_SET_LOCAL] = &&lbl_SET_LOCAL,
        [OP_GET_NAME] = &&lbl_GET_NAME, [OP_SET_NAME] = &&lbl_SET_NAME,
        [OP_SET_NAME_LOCAL] = &&lbl_SET_NAME_LOCAL,
        [OP_SET_FN_NAME_LOCAL] = &&lbl_SET_FN_NAME_LOCAL,
        [OP_JUMP] = &&lbl_JUMP, [OP_JUMP_BACK] = &&lbl_JUMP_BACK,
        [OP_JUMP_IF_FALSE] = &&lbl_JUMP_IF_FALSE,
        [OP_JUMP_IF_TRUE] = &&lbl_JUMP_IF_TRUE,
        [OP_JUMP_IF_FALSE_PEEK] = &&lbl_JUMP_IF_FALSE_PEEK,
        [OP_JUMP_IF_TRUE_PEEK] = &&lbl_JUMP_IF_TRUE_PEEK,
        [OP_POP] = &&lbl_POP, [OP_DUP] = &&lbl_DUP, [OP_DUP2] = &&lbl_DUP2,
        [OP_CLOSURE] = &&lbl_CLOSURE, [OP_CALL] = &&lbl_CALL,
        [OP_RETURN] = &&lbl_RETURN, [OP_RETURN_NULL] = &&lbl_RETURN_NULL,
        [OP_LIST] = &&lbl_LIST, [OP_DICT] = &&lbl_DICT,
        [OP_INDEX_GET] = &&lbl_INDEX_GET, [OP_INDEX_SET] = &&lbl_INDEX_SET,
        [OP_DOT_GET] = &&lbl_DOT_GET, [OP_DOT_SET] = &&lbl_DOT_SET,
        [OP_ITER_SETUP] = &&lbl_ITER_SETUP, [OP_ITER_NEXT] = &&lbl_ITER_NEXT,
        [OP_LOOP_ENV_FRESH] = &&lbl_LOOP_ENV_FRESH,
        [OP_LOOP_ENV_END] = &&lbl_LOOP_ENV_END,
        [OP_LOOP_ENV_CLEAR] = &&lbl_LOOP_ENV_CLEAR,
        [OP_PREDICATE_SLOT] = &&lbl_PREDICATE_SLOT,
        [OP_PREDICATE_NAME] = &&lbl_PREDICATE_NAME,
        [OP_BREAK] = &&lbl_BREAK, [OP_CONTINUE] = &&lbl_CONTINUE,
        [OP_TRY_BEGIN] = &&lbl_TRY_BEGIN, [OP_TRY_END] = &&lbl_TRY_END,
        [OP_OBSERVE_ASSIGN] = &&lbl_OBSERVE_ASSIGN,
        [OP_OBSERVE_ASSIGN_LOCAL] = &&lbl_OBSERVE_ASSIGN_LOCAL,
        [OP_INTERROGATE] = &&lbl_INTERROGATE, [OP_PREDICATE] = &&lbl_PREDICATE,
        [OP_REPORT_SLOT] = &&lbl_REPORT_SLOT,
        [OP_REPORT_NAME] = &&lbl_REPORT_NAME,
        [OP_REPORT_VALUE_SLOT] = &&lbl_REPORT_VALUE_SLOT,
        [OP_REPORT_VALUE_NAME] = &&lbl_REPORT_VALUE_NAME,
        [OP_TRAJECTORY_SLOT] = &&lbl_TRAJECTORY_SLOT,
        [OP_TRAJECTORY_NAME] = &&lbl_TRAJECTORY_NAME,
        [OP_OBSERVE_VALUE_SLOT] = &&lbl_OBSERVE_VALUE_SLOT,
        [OP_OBSERVE_VALUE_NAME] = &&lbl_OBSERVE_VALUE_NAME,
        [OP_OBSERVE_NAME_POST] = &&lbl_OBSERVE_NAME_POST,
        [OP_UNOBSERVED_BEGIN] = &&lbl_UNOBSERVED_BEGIN,
        [OP_UNOBSERVED_END] = &&lbl_UNOBSERVED_END,
        [OP_LOOP_STALL_CHECK] = &&lbl_LOOP_STALL_CHECK,
        [OP_LOOP_CAP_CHECK] = &&lbl_LOOP_CAP_CHECK,
        [OP_IMPORT] = &&lbl_IMPORT, [OP_MATCH] = &&lbl_MATCH,
        [OP_LISTCOMP_BEGIN] = &&lbl_LISTCOMP_BEGIN,
        [OP_LISTCOMP_APPEND] = &&lbl_LISTCOMP_APPEND,
        [OP_LINE] = &&lbl_LINE, [OP_WIDE] = &&lbl_WIDE,
        [OP_DISPATCH] = &&lbl_DISPATCH,
        [OP_LOCAL_DOT_GET] = &&lbl_LOCAL_DOT_GET,
        [OP_LOCAL_DOT_SET] = &&lbl_LOCAL_DOT_SET,
        [OP_LOCAL_IDX_GET] = &&lbl_LOCAL_IDX_GET,
        [OP_LOCAL_IDX_DOT_GET] = &&lbl_LOCAL_IDX_DOT_GET,
        [OP_LOCAL_IDX_DOT_SET] = &&lbl_LOCAL_IDX_DOT_SET,
        [OP_INTERROGATE_NAMED] = &&lbl_INTERROGATE_NAMED,
        [OP_INTERROGATE_NAMED_AT] = &&lbl_INTERROGATE_NAMED_AT,
        [OP_DEFAULT_PARAM] = &&lbl_DEFAULT_PARAM,
        [OP_DESTRUCTURE_UNPACK] = &&lbl_DESTRUCTURE_UNPACK,
        [OP_SLICE_GET] = &&lbl_SLICE_GET,
    };
    #define CHECK_ERROR() do { \
        while (__builtin_expect(g_has_error, 0)) { \
            vm_error_flush_pending(chunk, ip);   /* #407: uncaught print + caret */ \
            if (frame->try_count > 0 && !g_exit_requested) { \
                g_has_error = 0; \
                g_try_depth--; \
                frame->try_count--; \
                uint8_t *_catch_ip = frame->try_handlers[frame->try_count].catch_ip; \
                int _catch_bp = frame->try_handlers[frame->try_count].catch_bp; \
                frame->is_try = (frame->try_count > 0); \
                while (g_vm.sp > _catch_bp) val_decref(vm_pop()); \
                vm_push(vm_take_error_value()); \
                ip = _catch_ip; \
            } else if (g_exit_requested || !vm_handler_in_range(base_frame)) { \
                /* Uncaught: no try anywhere in this vm_run's frames. Stop \
                 * the dispatch loop instead of continuing with null (which \
                 * cascades — see stack-overflow). g_has_error stays set so \
                 * a re-entrant caller, or main, sees the failure. */ \
                goto vm_error_halt; \
            } else { \
                /* #322: error set, no handler in THIS frame, but one exists in \
                 * an OUTER frame. The error must unwind to it — NOT keep running \
                 * this function's remaining statements. Pop this frame (mirror \
                 * vm_error_halt's per-frame drain: drain its stack window, free \
                 * an owned env, restore its loop-stall globals, drop its chunk \
                 * ref), restore the caller as the current frame, and loop to \
                 * re-check there (catch if the caller has a handler, else unwind \
                 * further). vm_handler_in_range being true guarantees a frame \
                 * below the top, so frame_count-1 stays >= base_frame. */ \
                while (g_vm.sp > frame->bp) slot_decref(g_vm.stack[--g_vm.sp]); \
                if (frame->owns_env) env_decref(frame->env); \
                g_loop_stall_count = frame->saved_stall_count; \
                g_loop_iterations  = frame->saved_loop_iter; \
                chunk_decref(frame->chunk); \
                g_vm.frame_count--; \
                frame = &g_vm.frames[g_vm.frame_count - 1]; \
                ip = frame->ip; \
                chunk = frame->chunk; \
            } \
        } \
    } while(0)
    #define DISPATCH() do { CHECK_ERROR(); goto *dispatch_table[*ip++]; } while(0)
    #define CASE(op) lbl_##op
#else
    /* Switch-based fallback */
    #define DISPATCH() break
    #define CASE(op) case op
    for (;;) { switch (*ip++) {
#endif

vm_resume_dispatch:   /* #408 resume lands here: ip/frame/chunk restored above */
    DISPATCH();

    /* ---- Constants ---- */

    CASE(CONST): {
        uint16_t idx = read_u16(ip); ip += 2;
        Value *v = chunk->constants[idx];
        /* Numeric constants without observer state ship as immediates —
         * skips an incref/decref pair on every push/pop. */
        if (v->type == VAL_NUM) {
            vm_push_slot(slot_from_num(v->data.num));
        } else {
            val_incref(v);
            vm_push(v);
        }
        DISPATCH();
    }

    CASE(NULL): {
        vm_push_slot(slot_null());
        DISPATCH();
    }

    CASE(NUM_ZERO): {
        vm_push_slot(slot_from_num(0.0));
        DISPATCH();
    }

    CASE(NUM_ONE): {
        vm_push_slot(slot_from_num(1.0));
        DISPATCH();
    }

    /* ---- Arithmetic ---- */

    /* NUM_REUSE — retained for slow-path fallbacks that allocate via
     * make_num then realize they could have mutated in place. The hot
     * arith fast path no longer needs it: immediate doubles have no
     * refcount and heap-num results are emitted as immediates. */
#define NUM_REUSE(v) ((v)->type == VAL_NUM && (v)->refcount == 1 && !(v)->arena)

    /* Stack-top fast path: read two slots, extract doubles from either
     * immediate or heap VAL_NUM form, compute. Result is wrapped as a
     * heap Value (via make_num or in-place NUM_REUSE). Immediates aren't
     * emitted until B-3 audits every vm_peek caller for immediate-safe
     * refcount handling. */
#define ARITH_FAST(OP) do { \
    EigsSlot _bs = g_vm.stack[g_vm.sp - 1]; \
    EigsSlot _as = g_vm.stack[g_vm.sp - 2]; \
    double _ad, _bd; \
    if (__builtin_expect(slot_as_double(_as, &_ad) & slot_as_double(_bs, &_bd), 1)) { \
        double _r = num_guard(_ad OP _bd); \
        if (slot_is_ptr(_as)) { \
            Value *_a = slot_as_ptr(_as); \
            if (NUM_REUSE(_a)) { \
                _a->data.num = _r; \
                slot_decref(_bs); \
                g_vm.sp--; \
                DISPATCH(); \
            } \
        } \
        if (slot_is_ptr(_bs)) { \
            Value *_b = slot_as_ptr(_bs); \
            if (NUM_REUSE(_b)) { \
                _b->data.num = _r; \
                g_vm.stack[g_vm.sp - 2] = _bs; \
                slot_decref(_as); \
                g_vm.sp--; \
                DISPATCH(); \
            } \
        } \
        slot_decref(_as); slot_decref(_bs); \
        g_vm.stack[g_vm.sp - 2] = slot_from_num(_r); \
        g_vm.sp--; \
        DISPATCH(); \
    } \
} while(0)

    CASE(ADD): {
        ARITH_FAST(+);
        /* Slow path: handles string concat etc */
        Value *b = vm_pop(); Value *a = vm_pop();
        if (a->type == VAL_NUM && b->type == VAL_NUM) {
            double r = num_guard(a->data.num + b->data.num);
            if (NUM_REUSE(a)) { a->data.num = r; vm_push(a); val_decref(b); DISPATCH(); }
            if (NUM_REUSE(b)) { b->data.num = r; vm_push(b); val_decref(a); DISPATCH(); }
            vm_push(make_num(r));
        } else if (a->type == VAL_STR && b->type == VAL_STR) {
            int la = strlen(a->data.str), lb = strlen(b->data.str);
            char *s = xmalloc((size_t)la + lb + 1);
            memcpy(s, a->data.str, la);
            memcpy(s + la, b->data.str, lb);
            s[la + lb] = 0;
            vm_push(make_str_owned(s));
        } else {
            /* Strict: + adds two numbers or concatenates two strings; it does
             * not coerce across types ("3" + 4 was a footgun). For mixed
             * concatenation use an f-string — f"{a}{b}" — or str of. */
            const char *ta = val_type_name(a->type), *tb = val_type_name(b->type);
            if ((a->type == VAL_STR) != (b->type == VAL_STR))
                rt_error(EK_TYPE, current_line,
                    "cannot apply '+' to %s and %s (use an f-string or 'str of' to concatenate)",
                    ta, tb);
            else
                rt_error(EK_TYPE, current_line, "cannot apply '+' to %s and %s", ta, tb);
            vm_push(make_null());
        }
        val_decref(a); val_decref(b);
        DISPATCH();
    }

#define NUM_BINOP(NAME, OP, OPNAME) \
    CASE(NAME): { \
        ARITH_FAST(OP); \
        Value *b = vm_pop(); Value *a = vm_pop(); \
        if (a->type == VAL_NUM && b->type == VAL_NUM) { \
            double r = num_guard(a->data.num OP b->data.num); \
            if (NUM_REUSE(a)) { a->data.num = r; vm_push(a); val_decref(b); DISPATCH(); } \
            if (NUM_REUSE(b)) { b->data.num = r; vm_push(b); val_decref(a); DISPATCH(); } \
            vm_push(make_num(r)); \
        } else { \
            rt_error(EK_TYPE, current_line, "cannot apply '%s' to %s and %s", \
                OPNAME, val_type_name(a->type), val_type_name(b->type)); \
            vm_push(make_num(0)); \
        } \
        val_decref(a); val_decref(b); \
        DISPATCH(); \
    }

    NUM_BINOP(SUB, -, "-")
    NUM_BINOP(MUL, *, "*")

    CASE(DIV): {
        Value *b = vm_pop(); Value *a = vm_pop();
        if (a->type == VAL_NUM && b->type == VAL_NUM) {
            if (b->data.num == 0.0) {
                fprintf(stderr, "Warning line %d: division by zero\n", current_line);
                vm_push(make_num(0));
            } else {
                double r = num_guard(a->data.num / b->data.num);
                if (NUM_REUSE(a)) { a->data.num = r; vm_push(a); val_decref(b); DISPATCH(); }
                if (NUM_REUSE(b)) { b->data.num = r; vm_push(b); val_decref(a); DISPATCH(); }
                vm_push(make_num(r));
            }
        } else {
            rt_error(EK_TYPE, current_line, "cannot apply '/' to %s and %s",
                val_type_name(a->type), val_type_name(b->type));
            vm_push(make_num(0));
        }
        val_decref(a); val_decref(b);
        DISPATCH();
    }

    CASE(MOD): {
        Value *b = vm_pop(); Value *a = vm_pop();
        if (a->type == VAL_NUM && b->type == VAL_NUM && b->data.num != 0.0) {
            double r = num_guard(fmod(a->data.num, b->data.num));
            if (NUM_REUSE(a)) { a->data.num = r; vm_push(a); val_decref(b); DISPATCH(); }
            if (NUM_REUSE(b)) { b->data.num = r; vm_push(b); val_decref(a); DISPATCH(); }
            vm_push(make_num(r));
        } else {
            if (!(a->type == VAL_NUM && b->type == VAL_NUM))
                rt_error(EK_TYPE, current_line, "cannot apply '%%' to %s and %s",
                    val_type_name(a->type), val_type_name(b->type));
            vm_push(make_num(0));
        }
        val_decref(a); val_decref(b);
        DISPATCH();
    }

/* RHS is the (possibly transformed) right operand expression. For `& | ^`
 * it is the plain int64 operand; for the shifts it is masked to [0,63] so a
 * large or negative shift count is defined (mod-64), never C UB — the same
 * `& 63` the bit_shl/bit_shr builtins apply, honoring the LANGUAGE_CONTRACT
 * "shifts are defined, not UB" promise. Without the mask, `1 << 64` on the
 * infix path is undefined behavior (UBSan trips; only untested counts hid it). */
#define INT_BINOP_R(NAME, OP, OPNAME, RHS) \
    CASE(NAME): { \
        EigsSlot _bs = g_vm.stack[g_vm.sp - 1]; \
        EigsSlot _as = g_vm.stack[g_vm.sp - 2]; \
        double _ad, _bd; \
        if (__builtin_expect(slot_as_double(_as, &_ad) & slot_as_double(_bs, &_bd), 1)) { \
            double _r = (double)((int64_t)_ad OP (RHS)); \
            if (slot_is_ptr(_as)) { \
                Value *_a = slot_as_ptr(_as); \
                if (NUM_REUSE(_a)) { _a->data.num = _r; slot_decref(_bs); g_vm.sp--; DISPATCH(); } \
            } \
            if (slot_is_ptr(_bs)) { \
                Value *_b = slot_as_ptr(_bs); \
                if (NUM_REUSE(_b)) { _b->data.num = _r; g_vm.stack[g_vm.sp - 2] = _bs; slot_decref(_as); g_vm.sp--; DISPATCH(); } \
            } \
            slot_decref(_as); slot_decref(_bs); \
            g_vm.stack[g_vm.sp - 2] = slot_from_num(_r); \
            g_vm.sp--; \
            DISPATCH(); \
        } \
        /* Mixed/non-numeric: error rather than silently returning 0, \
         * matching the arithmetic operators and the strict error model. \
         * Capture type names before decref (cf. NUM_CMP above). */ \
        { \
            const char *_tna = slot_type_name(_as), *_tnb = slot_type_name(_bs); \
            slot_decref(_as); slot_decref(_bs); \
            rt_error(EK_TYPE, current_line, "cannot apply '%s' to %s and %s", \
                OPNAME, _tna, _tnb); \
        } \
        g_vm.stack[g_vm.sp - 2] = slot_from_num(0.0); \
        g_vm.sp--; \
        DISPATCH(); \
    }

/* Non-shift bitwise ops: RHS is the plain int64 operand. */
#define INT_BINOP(NAME, OP, OPNAME) INT_BINOP_R(NAME, OP, OPNAME, (int64_t)_bd)

    INT_BINOP(BAND, &, "&")
    INT_BINOP(BOR, |, "|")
    INT_BINOP(BXOR, ^, "^")
    INT_BINOP_R(SHL, <<, "<<", ((int64_t)_bd & 63))
    INT_BINOP_R(SHR, >>, ">>", ((int64_t)_bd & 63))

    /* ---- Unary ---- */

    CASE(NEG): {
        EigsSlot s = g_vm.stack[g_vm.sp - 1];
        double d;
        if (__builtin_expect(slot_as_double(s, &d), 1)) {
            if (slot_is_ptr(s)) {
                Value *v = slot_as_ptr(s);
                if (NUM_REUSE(v)) { v->data.num = -d; DISPATCH(); }
            }
            slot_decref(s);
            g_vm.stack[g_vm.sp - 1] = slot_from_num(-d);
            DISPATCH();
        }
        rt_error(EK_TYPE, current_line, "cannot negate non-numeric");
        slot_decref(s);
        g_vm.stack[g_vm.sp - 1] = slot_from_num(0.0);
        DISPATCH();
    }

    CASE(NOT): {
        EigsSlot s = g_vm.stack[g_vm.sp - 1];
        int t = slot_truthy(s);
        slot_decref(s);
        g_vm.stack[g_vm.sp - 1] = slot_from_num(t ? 0.0 : 1.0);
        DISPATCH();
    }

    CASE(BNOT): {
        EigsSlot s = g_vm.stack[g_vm.sp - 1];
        double d;
        if (__builtin_expect(slot_as_double(s, &d), 1)) {
            double r = (double)(~(int64_t)d);
            if (slot_is_ptr(s)) {
                Value *v = slot_as_ptr(s);
                if (NUM_REUSE(v)) { v->data.num = r; DISPATCH(); }
            }
            slot_decref(s);
            g_vm.stack[g_vm.sp - 1] = slot_from_num(r);
            DISPATCH();
        }
        {
            const char *_tn = slot_type_name(s);
            slot_decref(s);
            rt_error(EK_TYPE, current_line, "cannot apply '~' to %s", _tn);
        }
        g_vm.stack[g_vm.sp - 1] = slot_from_num(0.0);
        DISPATCH();
    }

    /* ---- Comparison ---- */

    CASE(EQ): {
        EigsSlot _bs = g_vm.stack[g_vm.sp - 1];
        EigsSlot _as = g_vm.stack[g_vm.sp - 2];
        double _ad, _bd;
        if (__builtin_expect(slot_as_double(_as, &_ad) & slot_as_double(_bs, &_bd), 1)) {
            double _r = (_ad == _bd) ? 1.0 : 0.0;
            if (slot_is_ptr(_as)) {
                Value *_a = slot_as_ptr(_as);
                if (NUM_REUSE(_a)) { _a->data.num = _r; slot_decref(_bs); g_vm.sp--; DISPATCH(); }
            }
            if (slot_is_ptr(_bs)) {
                Value *_b = slot_as_ptr(_bs);
                if (NUM_REUSE(_b)) { _b->data.num = _r; g_vm.stack[g_vm.sp - 2] = _bs; slot_decref(_as); g_vm.sp--; DISPATCH(); }
            }
            slot_decref(_as); slot_decref(_bs);
            g_vm.stack[g_vm.sp - 2] = slot_from_num(_r);
            g_vm.sp--;
            DISPATCH();
        }
        Value *b = vm_pop(); Value *a = vm_pop();
        int eq = values_equal(a, b);
        vm_push(make_num(eq ? 1.0 : 0.0));
        val_decref(a); val_decref(b);
        DISPATCH();
    }

    CASE(NE): {
        EigsSlot _bs = g_vm.stack[g_vm.sp - 1];
        EigsSlot _as = g_vm.stack[g_vm.sp - 2];
        double _ad, _bd;
        if (__builtin_expect(slot_as_double(_as, &_ad) & slot_as_double(_bs, &_bd), 1)) {
            double _r = (_ad != _bd) ? 1.0 : 0.0;
            if (slot_is_ptr(_as)) {
                Value *_a = slot_as_ptr(_as);
                if (NUM_REUSE(_a)) { _a->data.num = _r; slot_decref(_bs); g_vm.sp--; DISPATCH(); }
            }
            if (slot_is_ptr(_bs)) {
                Value *_b = slot_as_ptr(_bs);
                if (NUM_REUSE(_b)) { _b->data.num = _r; g_vm.stack[g_vm.sp - 2] = _bs; slot_decref(_as); g_vm.sp--; DISPATCH(); }
            }
            slot_decref(_as); slot_decref(_bs);
            g_vm.stack[g_vm.sp - 2] = slot_from_num(_r);
            g_vm.sp--;
            DISPATCH();
        }
        Value *b = vm_pop(); Value *a = vm_pop();
        int eq = values_equal(a, b);
        vm_push(make_num(eq ? 0.0 : 1.0));
        val_decref(a); val_decref(b);
        DISPATCH();
    }

#define NUM_CMP(NAME, OP, OPNAME) \
    CASE(NAME): { \
        EigsSlot _bs = g_vm.stack[g_vm.sp - 1]; \
        EigsSlot _as = g_vm.stack[g_vm.sp - 2]; \
        double _ad, _bd; \
        if (__builtin_expect(slot_as_double(_as, &_ad) & slot_as_double(_bs, &_bd), 1)) { \
            double _r = (_ad OP _bd) ? 1.0 : 0.0; \
            if (slot_is_ptr(_as)) { \
                Value *_a = slot_as_ptr(_as); \
                if (NUM_REUSE(_a)) { _a->data.num = _r; slot_decref(_bs); g_vm.sp--; DISPATCH(); } \
            } \
            if (slot_is_ptr(_bs)) { \
                Value *_b = slot_as_ptr(_bs); \
                if (NUM_REUSE(_b)) { _b->data.num = _r; g_vm.stack[g_vm.sp - 2] = _bs; slot_decref(_as); g_vm.sp--; DISPATCH(); } \
            } \
            slot_decref(_as); slot_decref(_bs); \
            g_vm.stack[g_vm.sp - 2] = slot_from_num(_r); \
            g_vm.sp--; \
            DISPATCH(); \
        } \
        /* String lex-compare slow path: both operands VAL_STR → byte-wise strcmp. */ \
        if (slot_is_ptr(_as) && slot_is_ptr(_bs)) { \
            Value *_a = slot_as_ptr(_as), *_b = slot_as_ptr(_bs); \
            if (_a->type == VAL_STR && _b->type == VAL_STR) { \
                int _cmp = strcmp(_a->data.str ? _a->data.str : "", _b->data.str ? _b->data.str : ""); \
                double _r = (_cmp OP 0) ? 1.0 : 0.0; \
                slot_decref(_as); slot_decref(_bs); \
                g_vm.stack[g_vm.sp - 2] = slot_from_num(_r); \
                g_vm.sp--; \
                DISPATCH(); \
            } \
        } \
        /* Mixed/uncomparable types: error rather than silently returning \
         * false (e.g. "3" < 4 used to be 0). Capture type names before \
         * decref. ==/!= keep cross-type "not equal"; only ordering errors. */ \
        { \
            const char *_tna = slot_type_name(_as), *_tnb = slot_type_name(_bs); \
            slot_decref(_as); slot_decref(_bs); \
            rt_error(EK_TYPE, current_line, "cannot compare %s and %s with '%s'", \
                _tna, _tnb, OPNAME); \
        } \
        g_vm.stack[g_vm.sp - 2] = slot_from_num(0.0); \
        g_vm.sp--; \
        DISPATCH(); \
    }

    NUM_CMP(LT, <, "<")
    NUM_CMP(GT, >, ">")
    NUM_CMP(LE, <=, "<=")
    NUM_CMP(GE, >=, ">=")

    /* ---- Variables ---- */

    CASE(GET_LOCAL): {
        uint16_t slot = read_u16(ip); ip += 2;
        /* Read from the function's original env (not loop-fresh child).
         * Slot-direct: an immediate-num binding pushes immediate (no
         * allocation); a heap binding pushes by incref. */
        Env *e = frame->fn_env;
        if ((int)slot < e->count) {
            EigsSlot s = e->values[slot];
            slot_incref(s);
            vm_push_slot(s);
        } else {
            /* Out-of-range read -> null. This is LOAD-BEARING, not a bug
             * (#348 tried to make it an error and 18 call-semantics checks
             * failed): an underfed call to a defaults-free function binds
             * only argc slots, and reading a missing parameter resolves
             * HERE — this null IS the "missing parameters bind to null"
             * semantics (SPEC.md). Only SET is a hard error (below). */
            vm_push_slot(slot_null());
        }
        DISPATCH();
    }

    CASE(SET_LOCAL): {
        uint16_t slot = read_u16(ip); ip += 2;
        if (__builtin_expect(g_trace_hist, 0)) {
            const char *nm = (slot < (uint16_t)chunk->local_count && chunk->local_names)
                ? chunk->local_names[slot] : NULL;
            trace_assign(nm, g_vm.stack[g_vm.sp - 1]);
        }
        Env *e = frame->fn_env;
        if ((int)slot < e->count) {
            EigsSlot tos = g_vm.stack[g_vm.sp - 1];
            /* In-place mutation: writing an immediate into a slot that
             * already holds an exclusive non-observed VAL_NUM rewrites
             * the existing Value's data.num instead of swapping pointers. */
            if (slot_is_num(tos)) {
                EigsSlot ex_s = e->values[slot];
                if (slot_is_heap(ex_s)) {
                    Value *existing = slot_as_ptr(ex_s);
                    if (existing && existing->type == VAL_NUM &&
                        existing->refcount == 1 && !existing->arena) {
                        existing->data.num = tos.d;
                        DISPATCH();
                    }
                }
            }
            slot_incref(tos);
            slot_decref(e->values[slot]);
            e->values[slot] = tos;
        } else {
            /* #348: an out-of-range slot used to DROP the write silently
             * (the assigned variable simply never existed). Compiler-emitted
             * writes are always backed (body locals size the call env;
             * defaults-bearing chunks get their param slots reserved), so
             * this is hand-built bytecode (vm_run_bytecode descriptors) with
             * a bad or missing local_names table. Loud and catchable.
             * NOTE: the GET side above deliberately stays a silent null —
             * that path is the missing-parameter-reads-null semantics. */
            rt_error(EK_INTERNAL, current_line,
                          "SET_LOCAL slot %d out of range (env has %d slots)",
                          (int)slot, e->count);
        }
        DISPATCH();
    }

    CASE(GET_NAME): {
        uint16_t idx = read_u16(ip); ip += 2;
        EnvIC *ic = &chunk->env_ic[idx];
        Env *start = frame->env;
        /* IC fast path: same starting env, both starting and target env
         * binding_version unmoved since cache population. walk_depth ∈ {0,1}. */
        if (__builtin_expect(ic->starting_env == start &&
                             ic->starting_ver == start->binding_version, 1)) {
            Env *target = ic->walk_depth ? start->parent : start;
            if (__builtin_expect(target && target->binding_version == ic->target_ver, 1)) {
                EigsSlot s = target->values[ic->slot_idx];
                slot_incref(s);
                vm_push_slot(s);
                DISPATCH();
            }
        }
        /* Slow path: chain walk; populate IC if depth ≤ 1. */
        const char *name = chunk->const_interns[idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        int slot_idx, depth;
        Env *target = env_resolve_chain(start, name, h, &slot_idx, &depth);
        if (!target) {
            rt_error(EK_UNDEFINED_NAME, current_line, "undefined variable '%s'", name);
            vm_push_slot(slot_null());
            DISPATCH();
        }
        /* #297: the inline cache is shared per-chunk state; don't populate it
         * while multithreaded (parallel workers would race, and a torn write
         * risks a wrong cache hit when two threads share an env). The fast-path
         * read stays — it just misses under MT. Applies to every IC-write site
         * below too. */
        if (!g_vm_multithreaded && depth <= 1) {
            ic->starting_env = start;
            ic->starting_ver = start->binding_version;
            ic->target_ver   = target->binding_version;
            ic->slot_idx     = slot_idx;
            ic->walk_depth   = (uint8_t)depth;
        }
        EigsSlot s = target->values[slot_idx];
        slot_incref(s);
        vm_push_slot(s);
        DISPATCH();
    }

    CASE(SET_NAME): {
        uint16_t idx = read_u16(ip); ip += 2;
        if (__builtin_expect(g_trace_hist, 0)) {
            trace_assign(chunk->const_interns[idx], g_vm.stack[g_vm.sp - 1]);
        }
        EnvIC *ic = &chunk->env_ic[idx];
        Env *start = frame->env;
        EigsSlot s = g_vm.stack[g_vm.sp - 1];
        if (__builtin_expect(ic->starting_env == start &&
                             ic->starting_ver == start->binding_version, 1)) {
            Env *target = ic->walk_depth ? start->parent : start;
            if (__builtin_expect(target && target->binding_version == ic->target_ver, 1)) {
                env_store_slot(target, ic->slot_idx, s);
                if (target->assign_counts && g_unobserved_depth == 0)
                    target->assign_counts[ic->slot_idx]++;
                DISPATCH();
            }
        }
        const char *name = chunk->const_interns[idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        int slot_idx, depth;
        Env *target = env_resolve_chain(start, name, h, &slot_idx, &depth);
        if (target) {
            env_store_slot(target, slot_idx, s);
            if (target->assign_counts && g_unobserved_depth == 0)
                target->assign_counts[slot_idx]++;
            if (!g_vm_multithreaded && depth <= 1) {   /* #297: see above */
                ic->starting_env = start;
                ic->starting_ver = start->binding_version;
                ic->target_ver   = target->binding_version;
                ic->slot_idx     = slot_idx;
                ic->walk_depth   = (uint8_t)depth;
            }
            DISPATCH();
        }
        /* Not found anywhere — create in starting env, then populate IC. */
        env_set_local_pre_interned_slot(start, name, h, s);
        Env *t2 = env_resolve_chain(start, name, h, &slot_idx, &depth);
        if (!g_vm_multithreaded && t2 == start) {   /* #297: see above */
            ic->starting_env = start;
            ic->starting_ver = start->binding_version;
            ic->target_ver   = start->binding_version;
            ic->slot_idx     = slot_idx;
            ic->walk_depth   = 0;
        }
        DISPATCH();
    }

    CASE(SET_NAME_LOCAL): {
        uint16_t idx = read_u16(ip); ip += 2;
        if (__builtin_expect(g_trace_hist, 0)) {
            trace_assign(chunk->const_interns[idx], g_vm.stack[g_vm.sp - 1]);
        }
        EnvIC *ic = &chunk->env_ic[idx];
        Env *start = frame->env;
        EigsSlot s = g_vm.stack[g_vm.sp - 1];
        if (__builtin_expect(ic->starting_env == start &&
                             ic->starting_ver == start->binding_version &&
                             ic->walk_depth == 0 &&
                             ic->target_ver == start->binding_version, 1)) {
            env_store_slot(start, ic->slot_idx, s);
            if (start->assign_counts && g_unobserved_depth == 0)
                start->assign_counts[ic->slot_idx]++;
            DISPATCH();
        }
        const char *name = chunk->const_interns[idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        env_set_local_pre_interned_slot(start, name, h, s);
        int slot_idx, depth;
        Env *target = env_resolve_chain(start, name, h, &slot_idx, &depth);
        if (!g_vm_multithreaded && target == start) {   /* #297: see above */
            ic->starting_env = start;
            ic->starting_ver = start->binding_version;
            ic->target_ver   = start->binding_version;
            ic->slot_idx     = slot_idx;
            ic->walk_depth   = 0;
        }
        DISPATCH();
    }

    CASE(SET_FN_NAME_LOCAL): {
        /* Like SET_NAME_LOCAL but pins the write to frame->fn_env rather than
         * frame->env. The compiler emits this for interrogated/captured/
         * local_only names inside a function so that assignments from nested
         * loop or scope envs still update the function's binding (see #129b:
         * unobserved+for+interrogated accumulator otherwise wrote to the
         * per-iteration loop env and the outer binding never moved). */
        uint16_t idx = read_u16(ip); ip += 2;
        if (__builtin_expect(g_trace_hist, 0)) {
            trace_assign(chunk->const_interns[idx], g_vm.stack[g_vm.sp - 1]);
        }
        EnvIC *ic = &chunk->env_ic[idx];
        Env *target = frame->fn_env;
        EigsSlot s = g_vm.stack[g_vm.sp - 1];
        if (__builtin_expect(ic->starting_env == target &&
                             ic->starting_ver == target->binding_version &&
                             ic->walk_depth == 0 &&
                             ic->target_ver == target->binding_version, 1)) {
            env_store_slot(target, ic->slot_idx, s);
            if (target->assign_counts && g_unobserved_depth == 0)
                target->assign_counts[ic->slot_idx]++;
            DISPATCH();
        }
        const char *name = chunk->const_interns[idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        env_set_local_pre_interned_slot(target, name, h, s);
        int slot_idx, depth;
        Env *resolved = env_resolve_chain(target, name, h, &slot_idx, &depth);
        if (!g_vm_multithreaded && resolved == target) {   /* #297: see above */
            ic->starting_env = target;
            ic->starting_ver = target->binding_version;
            ic->target_ver   = target->binding_version;
            ic->slot_idx     = slot_idx;
            ic->walk_depth   = 0;
        }
        DISPATCH();
    }

    /* ---- Control flow ---- */

    CASE(JUMP): {
        uint16_t offset = read_u16(ip); ip += 2;
        ip += offset;
        DISPATCH();
    }

    CASE(JUMP_BACK): {
        uint16_t offset = read_u16(ip); ip += 2;
        ip -= offset;
        /* Async abort: poll the embedder's registered flag on the one
         * opcode every loop crosses. Consume the flag (edge, not level)
         * so the abort kills exactly one eval. #410: the pointer is
         * never NULL (sentinel when unregistered), so this is a single
         * deref — the same check the JIT emits at native back-edges. */
        if (__builtin_expect(*g_vm_abort_flag, 0)) {
            *g_vm_abort_flag = 0;
            rt_error(EK_INTERRUPT, current_line, "aborted");
            DISPATCH();
        }
        /* Hotness signal: this is the back-edge of every while/for body.
         * Tracking iterations here lets jit_try_compile_chunk gate on
         * "chunk that loops a lot" in addition to "chunk that's called
         * a lot." Wraparound is benign — at threshold-trip granularity
         * the chunk gets JIT'd either way. */
        /* #297: the back-edge hotness counter + OSR machinery is shared
         * per-chunk JIT state. Compilation is already gated off under MT
         * (#296); skip the counter and the OSR slot scan/execute too while
         * multithreaded so parallel workers running the same chunk don't race
         * on back_edge_count / jit_osr (they interpret hot loops instead).
         * #533: ALSO skip while a cooperative task scheduler is active — the
         * #408 ruling is that task code runs interpreted, but only the
         * fresh-entry gate enforced it. A task loop crossing the OSR
         * threshold was JIT'd MID-TASK, and jit_helper_call has no suspend
         * check: a blocking task_recv's placeholder null flowed on as the
         * received message and the leaked suspend flag fired at a random
         * later call site — state corruption after ~OSR-threshold
         * iterations (first seen as liferaft node tasks dying en masse). */
        if (!g_vm_multithreaded && !g_task_sched) {
        chunk->back_edge_count++;

        /* OSR trigger. For "called once, loops a lot" chunks (the gauntlet
         * top-level being the motivating case) exec_count stays at 1, so
         * the from-zero JIT gate never fires. Once back_edge_count crosses
         * the OSR threshold we attempt a compile starting at the current
         * loop header (the post-jump-back ip). If a thunk is ready for
         * this header, hand off into native: sync ip → frame->ip, run,
         * then re-import the advance.
         *
         * Stage 5g: one slot per loop header (JIT_OSR_SLOTS max), scanned
         * linearly. The old single slot let whichever loop crossed the
         * threshold FIRST own native execution forever — bench_dmg_shape's
         * 65k-iteration setup loop pinned it and the 500k-iteration main
         * loop ran interpreted for good. Failed offsets keep their slot
         * (state 1) so they cannot retry-storm; when all slots are taken,
         * additional loop headers simply stay interpreted. */
        static int s_osr_threshold = 0;
        if (s_osr_threshold == 0) s_osr_threshold = eigs_jit_get_osr_threshold();
        {
            int t_off = (int)(ip - chunk->code);
            int osr_hit = -1, osr_free = -1;
            for (int k = 0; k < JIT_OSR_SLOTS; k++) {
                uint8_t st = chunk->jit_osr[k].state;
                if (st == 0) { if (osr_free < 0) osr_free = k; continue; }
                if (chunk->jit_osr[k].entry_offset == t_off) {
                    osr_hit = (st == 2) ? k : -2;  /* -2: failed here before */
                    break;
                }
            }
            if (osr_hit == -1 && osr_free >= 0 &&
                chunk->back_edge_count >= (uint32_t)s_osr_threshold) {
                jit_try_compile_chunk_osr(chunk, t_off, osr_free);
                if (chunk->jit_osr[osr_free].state == 2)
                    osr_hit = osr_free;
            }
            if (osr_hit >= 0 && chunk->jit_osr[osr_hit].code) {
            frame->ip = ip;
            ((JitChunkFn)chunk->jit_osr[osr_hit].code)();
            if (chunk->jit_osr[osr_hit].advance == -1) {
                /* Stage 4s: OSR thunk hit OP_RETURN. Same shape as the
                 * OP_CALL hook: result already on caller's stack, frame
                 * popped. Resync, or return to C if below base_frame.
                 * The popped frame's chunk ref is ours to drop (deferred
                 * past the epilogue's jit_osr_advance write). */
                chunk_decref(chunk);
                if (g_vm.frame_count <= base_frame) {
                    EigsSlot result_s = g_vm.stack[--g_vm.sp];
                    if (slot_is_num(result_s))  return make_num(result_s.d);
                    if (slot_is_null(result_s)) return make_null();
                    if (slot_is_bool(result_s)) return make_num(slot_as_bool(result_s) ? 1.0 : 0.0);
                    return slot_as_ptr(result_s);
                }
                frame = &g_vm.frames[g_vm.frame_count - 1];
                ip = frame->ip;
                chunk = frame->chunk;
                current_line = g_vm.current_line;
                DISPATCH();
            }
            if (chunk->jit_osr[osr_hit].advance == -2) {
                /* Stage 5f deep bail: a native callee below this thunk
                 * bailed mid-prefix; jit_helper_call already left every
                 * frame's ip consistent (no decref — the frames are all
                 * live). Resync to the current top and interpret on. */
                frame = &g_vm.frames[g_vm.frame_count - 1];
                ip = frame->ip;
                chunk = frame->chunk;
                current_line = g_vm.current_line;
                DISPATCH();
            }
            frame->ip += chunk->jit_osr[osr_hit].advance;
            ip = frame->ip;
            current_line = g_vm.current_line;
            }
        }
        }   /* #297: end if (!g_vm_multithreaded) */
        DISPATCH();
    }

    CASE(JUMP_IF_FALSE): {
        uint16_t offset = read_u16(ip); ip += 2;
        EigsSlot s = g_vm.stack[--g_vm.sp];
        if (!slot_truthy(s)) ip += offset;
        slot_decref(s);
        DISPATCH();
    }

    CASE(JUMP_IF_TRUE): {
        uint16_t offset = read_u16(ip); ip += 2;
        EigsSlot s = g_vm.stack[--g_vm.sp];
        if (slot_truthy(s)) ip += offset;
        slot_decref(s);
        DISPATCH();
    }

    CASE(JUMP_IF_FALSE_PEEK): {
        uint16_t offset = read_u16(ip); ip += 2;
        if (!slot_truthy(g_vm.stack[g_vm.sp - 1])) ip += offset;
        DISPATCH();
    }

    CASE(JUMP_IF_TRUE_PEEK): {
        uint16_t offset = read_u16(ip); ip += 2;
        if (slot_truthy(g_vm.stack[g_vm.sp - 1])) ip += offset;
        DISPATCH();
    }

    /* ---- Stack ---- */

    CASE(POP): {
        slot_decref(g_vm.stack[--g_vm.sp]);
        DISPATCH();
    }

    CASE(DUP): {
        EigsSlot s = g_vm.stack[g_vm.sp - 1];
        slot_incref(s);
        vm_push_slot(s);
        DISPATCH();
    }

    CASE(DUP2): {
        EigsSlot a = g_vm.stack[g_vm.sp - 2];
        EigsSlot b = g_vm.stack[g_vm.sp - 1];
        slot_incref(a); slot_incref(b);
        vm_push_slot(a); vm_push_slot(b);
        DISPATCH();
    }

    /* ---- Functions ---- */

    CASE(CLOSURE): {
        uint16_t fn_idx = read_u16(ip); ip += 2;
        EigsChunk *fn_chunk = chunk->functions[fn_idx];
        /* Create a VAL_FN that holds the compiled chunk and captures current env */
        char **params = NULL;
        if (fn_chunk->param_count > 0) {
            params = xcalloc(fn_chunk->param_count, sizeof(char *));
            for (int i = 0; i < fn_chunk->param_count; i++)
                params[i] = strdup(fn_chunk->local_names ? fn_chunk->local_names[i] : "");
        }
        /* Mark env as captured (registers it with the cycle collector;
         * may trigger a collection — refcounts are consistent here).
         * The fn's ref on the env is taken inside make_fn — do NOT also
         * bump env_refcount here: that second, ownerless ref meant a
         * closure-defining call env could never drop to zero, leaking
         * the env and every heap binding in it on every call that
         * defined a closure. */
        env_mark_captured(frame->env);
        Value *fn = make_fn(fn_chunk->name, params, fn_chunk->param_count,
                            frame->env);
        chunk_incref(fn_chunk);   /* the VAL_FN's ref; dropped in free_val */
        /* make_fn interned its own copies — the temp array and its
         * strdups are ours to free, else every closure creation leaks
         * its param names. */
        if (params) {
            for (int i = 0; i < fn_chunk->param_count; i++)
                free(params[i]);
            free(params);
        }
        /* Store the chunk pointer in the fn — we repurpose body_count as a flag */
        fn->data.fn.body = (ASTNode **)fn_chunk; /* HACK: store chunk ptr */
        fn->data.fn.body_count = -1;             /* sentinel: -1 means bytecode fn */
        vm_push(fn);
        DISPATCH();
    }

    CASE(CALL): {
        uint16_t argc = read_u16(ip); ip += 2;
        if (g_vm.sp < (int)argc + 1) {
            vm_push(make_null());
            DISPATCH();
        }
        Value *fn_val = STK_AS_VAL(g_vm.sp - 1 - argc);

        if (fn_val->type == VAL_BUILTIN) {
            /* Pack args for the builtin.
             * argc=1: pass raw value (matches tree-walker single-arg behavior)
             * argc>1: pack into list (matches tree-walker multi-arg behavior) */
            Value *arg;
            if (argc == 1) {
                arg = STK_AS_VAL(g_vm.sp - 1);
                val_incref(arg);
            } else {
                /* Heap-forced: see jit_helper_call wrapper rationale. */
                arg = make_list_heap(argc);
                for (int i = 0; i < argc; i++) {
                    list_append(arg, STK_AS_VAL(g_vm.sp - argc + i));
                }
            }
            /* Pop args + fn from stack (slot-direct). */
            for (int i = 0; i < argc; i++)
                slot_decref(g_vm.stack[--g_vm.sp]);
            slot_decref(g_vm.stack[--g_vm.sp]); /* fn */

            Env *saved = g_builtin_call_env;
            g_builtin_call_env = frame->env;
            int consumes_arg = (fn_val->data.builtin == builtin_free_val);
            Value *result = fn_val->data.builtin(arg);
            g_builtin_call_env = saved;

            if (!result) {
                result = make_null();
            } else if (!consumes_arg && result != arg) {
                /* Direct-borrow heuristic (capped, #546) — see
                 * vm_borrow_scan for the full rationale. Guarded by
                 * !consumes_arg: a consuming builtin like free_val may
                 * have already freed arg, so reading arg here would be
                 * a use-after-free. */
                vm_borrow_scan(arg, result);
            }
            if (!consumes_arg && result != arg) val_decref(arg);
            /* If result == arg, the arg's refcount transfers to the result */
            vm_push(result);

            /* Check for errors from builtins */
            CHECK_ERROR();
            /* #408: a suspending builtin (task_yield/task_join) sets the
             * request flag and leaves its placeholder result on the stack.
             * Suspension is only legal at the outermost level (base_frame 0);
             * inside a nested evaluation (eval/comparator/import — base_frame
             * > 0) the C stack can't be captured, so raise instead. On a valid
             * suspend, ip already points past this CALL, so the saved frame
             * resumes with the placeholder on top. */
            if (__builtin_expect(g_task_suspend_request, 0)) {
                if (base_frame == 0) { frame->ip = ip; goto vm_suspend_halt; }
                g_task_suspend_request = 0;
                rt_error(EK_VALUE, current_line,
                         "cannot suspend (task_yield/task_join) inside a nested evaluation");
                CHECK_ERROR();
            }
            DISPATCH();
        }

        if (fn_val->type == VAL_FN && fn_val->data.fn.body_count == -1) {
            /* Bytecode function — non-recursive call.
             * Push new frame and continue dispatch loop. */
            EigsChunk *fn_chunk = (EigsChunk *)fn_val->data.fn.body;
            int param_count = fn_val->data.fn.param_count;
            /* #366: frameless leaf-accessor fast path. Bail (0) falls
             * through to the generic call with the stack untouched. */
            if (fn_chunk->leaf_accessor && (int)argc == param_count &&
                !g_trace_hist &&
                vm_leaf_accessor_exec(fn_chunk, (int)argc)) {
                DISPATCH();
            }
            /* Stage 5i: recycle the chunk's parked call env when the
             * shape matches; param slots rebind in place. */
            Env *call_env = vm_take_call_env(fn_chunk,
                                             fn_val->data.fn.closure,
                                             param_count, (int)argc);
            if (call_env) {
                if (param_count > 1) {
                    for (int i = 0; i < param_count; i++)
                        env_rebind_param_slot(call_env, i,
                            g_vm.stack[g_vm.sp - argc + i]);
                } else if (param_count == 1) {
                    if (argc == 1) {
                        env_rebind_param_slot(call_env, 0,
                            g_vm.stack[g_vm.sp - 1]);
                    } else {
                        Value *arg_list = make_list(argc);
                        for (int i = 0; i < argc; i++)
                            list_append(arg_list, STK_AS_VAL(g_vm.sp - argc + i));
                        env_rebind_param_slot(call_env, 0,
                            slot_from_heap(arg_list));
                        val_decref(arg_list);
                    }
                }
            } else {
            call_env = env_new(fn_val->data.fn.closure);

            uint32_t *phashes = fn_val->data.fn.param_hashes;
            /* When this chunk has trailing defaults and the caller is
             * underfed, bind null placeholders for every unsent slot
             * in [argc, param_count); OP_DEFAULT_PARAM later fills the
             * defaulted ones. Non-defaulted underfed slots stay null,
             * matching the no-default underfed semantics. */
            int can_default = (fn_chunk->first_default < param_count) &&
                              ((int)argc < param_count);
            if (param_count > 1 && argc > 0) {
                int bound = param_count < (int)argc ? param_count : (int)argc;
                for (int i = 0; i < bound; i++) {
                    uint32_t ph = phashes ? phashes[i] : env_hash_name(fn_val->data.fn.params[i]);
                    env_bind_fresh_param_slot(call_env,
                        fn_val->data.fn.params[i], ph,
                        g_vm.stack[g_vm.sp - argc + i]);
                }
            } else if (param_count == 1 && !can_default) {
                uint32_t ph = phashes ? phashes[0] : env_hash_name(fn_val->data.fn.params[0]);
                if (argc == 1) {
                    vm_bind_fresh_param(call_env, 0,
                        fn_val->data.fn.params[0], ph,
                        g_vm.stack[g_vm.sp - 1]);
                } else {
                    Value *arg_list = make_list(argc);
                    for (int i = 0; i < argc; i++)
                        list_append(arg_list, STK_AS_VAL(g_vm.sp - argc + i));
                    vm_bind_fresh_param(call_env, 0,
                        fn_val->data.fn.params[0], ph,
                        slot_from_heap(arg_list));
                    val_decref(arg_list);
                }
            }
            if (can_default) {
                for (int i = (int)argc; i < param_count; i++) {
                    uint32_t ph = phashes ? phashes[i]
                                          : env_hash_name(fn_val->data.fn.params[i]);
                    env_bind_fresh_param_slot(call_env,
                        fn_val->data.fn.params[i], ph, slot_null());
                }
            }

            /* Pre-allocate slots for non-captured locals (compiler-assigned slots
             * beyond param_count). OP_SET_LOCAL writes directly into these. */
            if (fn_chunk->local_count > param_count)
                env_reserve_slots(call_env, fn_chunk->local_count);
            }

            /* Pop args + fn from stack (slot-direct; immediates never
             * round-trip through make_num + free_value). */
            for (int i = 0; i < argc; i++)
                slot_decref(g_vm.stack[--g_vm.sp]);
            slot_decref(g_vm.stack[--g_vm.sp]);

            /* Save current frame and push new one */
            frame->ip = ip;
            if (g_vm.frame_count >= VM_FRAMES_MAX) {
                rt_error(EK_LIMIT, current_line, "call stack overflow");
                env_decref(call_env);
                vm_push(make_null());
                DISPATCH();
            }
            frame = &g_vm.frames[g_vm.frame_count++];
            frame->chunk = fn_chunk;
            frame->call_serial = ++g_call_serial_next;   /* #539 v2 */
            chunk_incref(fn_chunk);   /* frame's ref — the fn value popped
                                       * above may die mid-call */
            frame->ip = fn_chunk->code;
            frame->bp = g_vm.sp;
            frame->env = call_env;
            frame->fn_env = call_env;
            frame->closure_val = fn_val;
            frame->owns_env = 1; /* OP_CALL created this env, free on return */
            frame->is_try = 0;
            frame->try_count = 0;
            /* Scope loop-stall globals per call frame: a callee's loops must
             * not inherit caller's accumulated stall count, or a hot helper
             * (e.g. fmt_num's padding loop) called from a converging outer
             * loop will exit early once the global crosses the threshold. */
            frame->saved_stall_count = g_loop_stall_count;
            frame->saved_loop_iter   = g_loop_iterations;
            frame->call_argc = (int)argc;
            g_loop_stall_count = 0;
            g_loop_iterations  = 0;
            if (!g_vm_multithreaded) fn_chunk->exec_count++;   /* #297: shared, JIT-only */

            /* JIT hook: compile lazily, run native prefix if available.
             * Thunk runs side-effects on g_vm only; caller advances
             * frame->ip by chunk->jit_advance and mirrors current_line
             * into the register-local copy before resuming dispatch.
             *
             * Stage 4s: jit_advance == -1 is a sentinel meaning the
             * thunk executed an OP_RETURN — frame_count already
             * decremented inside the helper, result already pushed on
             * the caller's stack. Resync to the (now-current) caller
             * frame or, if we've fallen below base_frame, hand the
             * result back to C. */
            if (fn_chunk->jit_state == 0 && !g_task_sched) jit_try_compile_chunk(fn_chunk);
            /* #533: never enter a thunk while the task scheduler is active,
             * even one compiled before the first spawn — task code runs
             * interpreted (suspension points exist only in the interpreter
             * loop's builtin-call check). */
            if (fn_chunk->jit_code && !g_task_sched) {
                ((JitChunkFn)fn_chunk->jit_code)();
                if (fn_chunk->jit_advance == -1) {
                    /* jit_helper_return popped fn_chunk's frame but left
                     * its chunk ref to us — the thunk epilogue writes
                     * fn_chunk->jit_advance after the helper returns, so
                     * the helper itself must not free the chunk. */
                    chunk_decref(fn_chunk);
                    if (g_vm.frame_count <= base_frame) {
                        EigsSlot result_s = g_vm.stack[--g_vm.sp];
                        if (slot_is_num(result_s))  return make_num(result_s.d);
                        if (slot_is_null(result_s)) return make_null();
                        if (slot_is_bool(result_s)) return make_num(slot_as_bool(result_s) ? 1.0 : 0.0);
                        return slot_as_ptr(result_s);
                    }
                    frame = &g_vm.frames[g_vm.frame_count - 1];
                    ip = frame->ip;
                    chunk = frame->chunk;
                    current_line = g_vm.current_line;
                    DISPATCH();
                }
                if (fn_chunk->jit_advance == -2) {
                    /* Stage 5f deep bail — see the OSR site. All frame
                     * ips are consistent; resync to the current top. */
                    frame = &g_vm.frames[g_vm.frame_count - 1];
                    ip = frame->ip;
                    chunk = frame->chunk;
                    current_line = g_vm.current_line;
                    DISPATCH();
                }
                frame->ip += fn_chunk->jit_advance;
                current_line = g_vm.current_line;
            }

            /* Switch to new frame's bytecode */
            ip = frame->ip;
            chunk = fn_chunk;
            DISPATCH();
        }

        if (fn_val->type == VAL_FN) {
            /* AST-based function — should not happen */
            for (int i = 0; i < argc; i++) val_decref(vm_pop());
            val_decref(vm_pop());
            vm_push(make_null());
            DISPATCH();
        }

        /* Not callable */
        rt_error(EK_TYPE, current_line, "cannot call %s", val_type_name(fn_val->type));
        for (int i = 0; i < argc; i++) val_decref(vm_pop());
        val_decref(vm_pop());
        vm_push(make_null());
        DISPATCH();
    }

    CASE(RETURN): {
        /* Slot-native: avoid make_num/free_value round-trip when a callee
         * returns an immediate. Carry the result slot across the frame
         * switch directly. */
        EigsSlot result_s;
        if (g_vm.sp > frame->bp) {
            result_s = g_vm.stack[--g_vm.sp];
        } else {
            result_s = slot_null();
        }
        while (g_vm.sp > frame->bp)
            slot_decref(g_vm.stack[--g_vm.sp]);
        if (frame->owns_env) {
            /* Stage 5i: park for recycling when eligible (never a
             * loop-scope child env), else free as before. */
            if (frame->env != frame->fn_env ||
                !vm_park_call_env(frame->chunk, frame->env))
                env_decref(frame->env);
        }
        /* Restore loop-stall globals saved on entry (scoped per call frame). */
        g_loop_stall_count = frame->saved_stall_count;
        g_loop_iterations  = frame->saved_loop_iter;
        chunk_decref(frame->chunk);   /* frame's ref; this chunk's code is
                                       * not read again below */
        g_vm.frame_count--;
        if (g_vm.frame_count <= base_frame) {
            /* Return to C: transfer slot's owned ref into a Value*.
             * Immediate -> materialize; pointer -> reuse slot's ref. */
            if (slot_is_num(result_s))       return make_num(result_s.d);
            if (slot_is_null(result_s))      return make_null();
            if (slot_is_bool(result_s))      return make_num(slot_as_bool(result_s) ? 1.0 : 0.0);
            return slot_as_ptr(result_s);
        }
        frame = &g_vm.frames[g_vm.frame_count - 1];
        ip = frame->ip;
        chunk = frame->chunk;
        g_vm.stack[g_vm.sp++] = result_s;
        DISPATCH();
    }

    CASE(RETURN_NULL): {
        while (g_vm.sp > frame->bp)
            slot_decref(g_vm.stack[--g_vm.sp]);
        if (frame->owns_env) {
            /* Stage 5i: park for recycling when eligible (never a
             * loop-scope child env), else free as before. */
            if (frame->env != frame->fn_env ||
                !vm_park_call_env(frame->chunk, frame->env))
                env_decref(frame->env);
        }
        g_loop_stall_count = frame->saved_stall_count;
        g_loop_iterations  = frame->saved_loop_iter;
        chunk_decref(frame->chunk);   /* frame's ref */
        g_vm.frame_count--;
        if (g_vm.frame_count <= base_frame) return make_null();
        frame = &g_vm.frames[g_vm.frame_count - 1];
        ip = frame->ip;
        chunk = frame->chunk;
        g_vm.stack[g_vm.sp++] = slot_null();
        DISPATCH();
    }

    /* ---- Data structures ---- */

    CASE(LIST): {
        uint16_t count = read_u16(ip); ip += 2;
        int base = g_vm.sp - count;
        if (base < 0) base = 0;
        Value *list = make_list(count);
        for (int i = 0; i < count; i++) {
            if (base + i < g_vm.sp)
                list_append(list, STK_AS_VAL(base + i));
        }
        /* Pop the elements */
        for (int i = 0; i < count && g_vm.sp > base; i++)
            val_decref(vm_pop());
        vm_push(list);
        DISPATCH();
    }

    CASE(DICT): {
        uint16_t count = read_u16(ip); ip += 2;
        Value *dict = make_dict(count);
        /* Stack: key0, val0, key1, val1, ... (bottom to top) */
        int base = g_vm.sp - count * 2;
        if (base < 0) base = 0; /* guard against stack underflow */
        for (int i = 0; i < count; i++) {
            /* Only consume pairs actually live on the stack. An untrusted
             * (vm_run_bytecode / sandbox_run) chunk can claim a count larger
             * than the live stack; reading past sp is an OOB access (OP_LIST
             * guards the same way). Indices increase, so stop at the first gap. */
            if (base + i * 2 + 1 >= g_vm.sp) break;
            Value *k = STK_AS_VAL(base + i * 2);
            Value *v = STK_AS_VAL(base + i * 2 + 1);
            if (k->type != VAL_STR) {
                rt_error(EK_TYPE, current_line, "dict key must be a string, got %s", val_type_name(k->type));
                continue;
            }
            dict_set(dict, k->data.str, v);
        }
        for (int i = 0; i < count * 2 && g_vm.sp > base; i++)
            val_decref(vm_pop());
        vm_push(dict);
        DISPATCH();
    }

    CASE(INDEX_GET): {
        /* Slot-aware: an immediate-num index never materializes. */
        EigsSlot idx_s = g_vm.stack[g_vm.sp - 1];
        EigsSlot tgt_s = g_vm.stack[g_vm.sp - 2];
        g_vm.sp -= 2;
        if (slot_is_num(idx_s) && slot_is_ptr(tgt_s)) {
            Value *target = slot_as_ptr(tgt_s);
            int i, _ok = vm_index_is_int(idx_s.d, &i);
            if (target->type == VAL_LIST) {
                if (_ok && vm_index_resolve(&i, target->data.list.count)) {
                    Value *r = target->data.list.items[i];
                    if (r && r->type == VAL_NUM) {
                        /* Snapshot the double BEFORE decref'ing the list:
                         * if the stack slot was the sole owner, slot_decref
                         * frees the list and cascades into free_value(r),
                         * which memcpy's the num-freelist next pointer over
                         * r->data. Reading r->data.num after that yields
                         * freelist garbage (denormal pointer-as-double, or
                         * the prior head — often 0 — for the first freed
                         * item). Surfaced by `(call())[i]` inline in an
                         * arg list; bound-to-local form hides the bug by
                         * keeping refcount > 1. */
                        double rv = r->data.num;
                        slot_decref(tgt_s);
                        vm_push_slot(slot_from_num(rv));
                    } else {
                        val_incref(r);
                        slot_decref(tgt_s);
                        vm_push(r);
                    }
                } else {
                    if (!_ok) rt_error(EK_VALUE, current_line, "index must be an integer, got %g", idx_s.d);
                    else rt_error(EK_INDEX, current_line, "index %d out of range (list length %d)",
                                  i, target->data.list.count);
                    slot_decref(tgt_s);
                    vm_push_slot(slot_null());
                }
                DISPATCH();
            }
            if (target->type == VAL_BUFFER) {
                if (_ok && vm_index_resolve(&i, target->data.buffer.count)) {
                    double v = target->data.buffer.data[i];
                    slot_decref(tgt_s);
                    vm_push_slot(slot_from_num(v));
                } else {
                    if (!_ok) rt_error(EK_VALUE, current_line, "index must be an integer, got %g", idx_s.d);
                    else rt_error(EK_INDEX, current_line, "buffer index %d out of range (length %d)",
                                  i, target->data.buffer.count);
                    slot_decref(tgt_s);
                    vm_push_slot(slot_null());
                }
                DISPATCH();
            }
        }
        /* Slow path: materialize both via slot_to_value for unified handling. */
        Value *idx = slot_to_value(idx_s);
        slot_decref(idx_s);
        Value *target = slot_to_value(tgt_s);
        slot_decref(tgt_s);
        Value *result = make_null();
        if (target->type == VAL_LIST && idx->type == VAL_NUM) {
            int i;
            if (!vm_index_is_int(idx->data.num, &i)) {
                rt_error(EK_VALUE, current_line, "index must be an integer, got %g", idx->data.num);
            } else if (vm_index_resolve(&i, target->data.list.count)) {
                result = target->data.list.items[i];
                val_incref(result);
            } else {
                rt_error(EK_INDEX, current_line, "index %d out of range (list length %d)", i, target->data.list.count);
            }
        } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
            Value *v = dict_get(target, idx->data.str);
            if (v) { result = v; val_incref(result); }
        } else if (target->type == VAL_STR && idx->type == VAL_NUM) {
            int i;
            if (!vm_index_is_int(idx->data.num, &i)) {
                rt_error(EK_VALUE, current_line, "index must be an integer, got %g", idx->data.num);
            } else if (vm_index_resolve(&i, (int)strlen(target->data.str))) {
                char buf[2] = { target->data.str[i], 0 };
                result = make_str(buf);
            } else {
                rt_error(EK_INDEX, current_line, "string index %d out of range (length %d)", i, (int)strlen(target->data.str));
            }
        } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
            int i;
            if (!vm_index_is_int(idx->data.num, &i))
                rt_error(EK_VALUE, current_line, "index must be an integer, got %g", idx->data.num);
            else if (vm_index_resolve(&i, target->data.buffer.count))
                result = make_num(target->data.buffer.data[i]);
            else
                rt_error(EK_INDEX, current_line, "buffer index %d out of range (length %d)", i, target->data.buffer.count);
        } else if (target->type != VAL_NULL) {
            rt_error(EK_TYPE, current_line, "cannot index %s", val_type_name(target->type));
        }
        val_decref(target); val_decref(idx);
        vm_push(result);
        DISPATCH();
    }

    CASE(INDEX_SET): {
        /* Slot-aware fast paths: a buffer or list write of an immediate-num
         * value to an immediate-num index never materializes either side. */
        EigsSlot val_s = g_vm.stack[g_vm.sp - 1];
        EigsSlot idx_s = g_vm.stack[g_vm.sp - 2];
        EigsSlot tgt_s = g_vm.stack[g_vm.sp - 3];
        if (slot_is_num(idx_s) && slot_is_ptr(tgt_s)) {
            Value *target = slot_as_ptr(tgt_s);
            int i, _ok = vm_index_is_int(idx_s.d, &i);
            if (target->type == VAL_BUFFER && slot_is_num(val_s)) {
                if (_ok && vm_index_resolve(&i, target->data.buffer.count)) {
                    target->data.buffer.data[i] = val_s.d;
                } else {
                    if (!_ok) rt_error(EK_VALUE, current_line, "index must be an integer, got %g", idx_s.d);
                    else rt_error(EK_INDEX, current_line, "buffer index %d out of range (length %d)",
                                  i, target->data.buffer.count);
                }
                g_vm.sp -= 2;  /* keep val on TOS */
                g_vm.stack[g_vm.sp - 1] = val_s;
                slot_decref(idx_s);
                slot_decref(tgt_s);
                DISPATCH();
            }
            if (target->type == VAL_LIST && slot_is_num(val_s)) {
                if (_ok && vm_index_resolve(&i, target->data.list.count)) {
                    Value *existing = target->data.list.items[i];
                    /* In-place mutate when slot is an exclusive untracked VAL_NUM. */
                    if (existing && existing->type == VAL_NUM &&
                        existing->refcount == 1 &&
                        !existing->arena) {
                        existing->data.num = val_s.d;
                    } else {
                        val_decref(existing);
                        target->data.list.items[i] = make_num(val_s.d);
                    }
                } else {
                    if (!_ok) rt_error(EK_VALUE, current_line, "index must be an integer, got %g", idx_s.d);
                    else rt_error(EK_INDEX, current_line, "index %d out of range (list length %d)",
                                  i, target->data.list.count);
                }
                g_vm.sp -= 2;
                g_vm.stack[g_vm.sp - 1] = val_s;
                slot_decref(idx_s);
                slot_decref(tgt_s);
                DISPATCH();
            }
        }
        Value *val = vm_pop(); Value *idx = vm_pop(); Value *target = vm_pop();
        if (target->type == VAL_LIST && idx->type == VAL_NUM) {
            int i;
            if (!vm_index_is_int(idx->data.num, &i)) {
                rt_error(EK_VALUE, current_line, "index must be an integer, got %g", idx->data.num);
            } else if (vm_index_resolve(&i, target->data.list.count)) {
                val_incref(val);
                val_decref(target->data.list.items[i]);
                target->data.list.items[i] = val;
            } else {
                rt_error(EK_INDEX, current_line, "index %d out of range (list length %d)", i, target->data.list.count);
            }
        } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
            int i;
            if (!vm_index_is_int(idx->data.num, &i)) {
                rt_error(EK_VALUE, current_line, "index must be an integer, got %g", idx->data.num);
            } else if (!vm_index_resolve(&i, target->data.buffer.count)) {
                rt_error(EK_INDEX, current_line, "buffer index %d out of range (length %d)", i, target->data.buffer.count);
            } else if (val->type == VAL_NUM) {
                target->data.buffer.data[i] = val->data.num;
            }
        } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
            dict_set(target, idx->data.str, val);
        } else if (target->type != VAL_NULL) {
            rt_error(EK_TYPE, current_line, "cannot index %s for assignment", val_type_name(target->type));
        }
        val_decref(target); val_decref(idx);
        val_incref(val);
        vm_push(val);
        val_decref(val);
        DISPATCH();
    }

    CASE(DOT_GET): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *key = chunk->const_interns[idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(key); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        Value *target = vm_pop();
        if (target->type == VAL_DICT) {
            Value *v = dict_get_cached(target, key, h);
            if (v) {
                if (v->type == VAL_NUM) {
                    double n = v->data.num;
                    val_decref(target);
                    vm_push_slot(slot_from_num(n));
                    DISPATCH();
                }
                val_incref(v);
                val_decref(target);
                vm_push(v);
                DISPATCH();
            }
        } else if (target->type != VAL_NULL) {
            rt_error(EK_TYPE, current_line, "cannot access field '%s' on %s",
                key, val_type_name(target->type));
        }
        val_decref(target);
        vm_push_slot(slot_null());
        DISPATCH();
    }

    CASE(DOT_SET): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *key = chunk->const_interns[idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(key); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        /* Slot fast path — see jit_helper_dot_set (and LOCAL_DOT_SET):
         * immediate-num write into an exclusive untracked num field
         * mutates in place, skipping the vm_pop materialization. */
        {
            EigsSlot val_s = g_vm.stack[g_vm.sp - 1];
            EigsSlot tgt_s = g_vm.stack[g_vm.sp - 2];
            if (slot_is_num(val_s) && slot_is_ptr(tgt_s)) {
                Value *t = slot_as_ptr(tgt_s);
                if (t->type == VAL_DICT &&
                    dict_set_cached_immediate(t, key, h, val_s.d)) {
                    g_vm.sp -= 1;
                    g_vm.stack[g_vm.sp - 1] = val_s;
                    slot_decref(tgt_s);
                    DISPATCH();
                }
            }
        }
        Value *val = vm_pop(); Value *target = vm_pop();
        if (target->type == VAL_DICT)
            dict_set_cached(target, key, h, val);
        else if (target->type != VAL_NULL)
            rt_error(EK_TYPE, current_line, "cannot set field '%s' on %s",
                key, val_type_name(target->type));
        val_decref(target);
        val_incref(val);
        vm_push(val);
        val_decref(val);
        DISPATCH();
    }

    /* ---- Superinstructions ---- */

    CASE(LOCAL_DOT_GET): {
        /* Fused GET_LOCAL + DOT_GET: push local[slot].field */
        uint16_t slot = read_u16(ip); ip += 2;
        uint16_t name_idx = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        Value *target = vm_local_lift(e, slot);
        if (target && target->type == VAL_DICT) {
            const char *key = chunk->const_interns[name_idx];
            uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
            if (h == 0) { h = env_hash_name(key); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
            Value *v = dict_get_cached(target, key, h);
            if (v) {
                /* Hot DMG path: untracked VAL_NUM field -> push immediate,
                 * skipping the incref/decref pair on every register read. */
                if (v->type == VAL_NUM) {
                    vm_push_slot(slot_from_num(v->data.num));
                } else {
                    val_incref(v);
                    vm_push(v);
                }
            } else {
                vm_push_slot(slot_null());
            }
        } else if (target && target->type != VAL_NULL) {
            const char *key = chunk->const_interns[name_idx];
            rt_error(EK_TYPE, current_line, "cannot access field '%s' on %s",
                key, val_type_name(target->type));
            vm_push_slot(slot_null());
        } else {
            vm_push_slot(slot_null());
        }
        DISPATCH();
    }

    CASE(LOCAL_DOT_SET): {
        /* Fused GET_LOCAL + DOT_SET: local[slot].field = TOS (keep on stack) */
        uint16_t slot = read_u16(ip); ip += 2;
        uint16_t name_idx = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        Value *target = vm_local_lift(e, slot);
        if (target && target->type == VAL_DICT) {
            const char *key = chunk->const_interns[name_idx];
            uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
            if (h == 0) { h = env_hash_name(key); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
            EigsSlot tos = g_vm.stack[g_vm.sp - 1];
            if (slot_is_num(tos) &&
                dict_set_cached_immediate(target, key, h, tos.d)) {
                DISPATCH();
            }
            Value *val = vm_slot_lift(g_vm.sp - 1);
            dict_set_cached(target, key, h, val);
        } else if (target && target->type != VAL_NULL) {
            const char *key = chunk->const_interns[name_idx];
            rt_error(EK_TYPE, current_line, "cannot set field '%s' on %s",
                key, val_type_name(target->type));
        }
        DISPATCH();
    }

    CASE(LOCAL_IDX_GET): {
        /* Fused GET_LOCAL + CONST(int) + INDEX_GET: push local[slot][idx].
         * Error semantics must match unfused INDEX_GET (vm.c:916): out-of-range
         * and wrong-type indexing raise runtime errors so try/catch can trap them. */
        uint16_t slot = read_u16(ip); ip += 2;
        uint16_t idx = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        Value *target = vm_local_lift(e, slot);
        if (target) {
            int i = (int)idx;
            if (target->type == VAL_BUFFER) {
                /* DMG hot path: mem[addr] — emit immediate, skip make_num. */
                if (i < target->data.buffer.count) {
                    vm_push_slot(slot_from_num(target->data.buffer.data[i]));
                } else {
                    rt_error(EK_INDEX, current_line, "buffer index %d out of range (length %d)",
                                  i, target->data.buffer.count);
                    vm_push_slot(slot_null());
                }
                DISPATCH();
            }
            if (target->type == VAL_LIST) {
                if (i < target->data.list.count) {
                    Value *item = target->data.list.items[i];
                    /* Plain VAL_NUM -> immediate; skip incref/decref pair. */
                    if (item && item->type == VAL_NUM) {
                        vm_push_slot(slot_from_num(item->data.num));
                    } else {
                        val_incref(item);
                        vm_push(item);
                    }
                } else {
                    rt_error(EK_INDEX, current_line, "index %d out of range (list length %d)",
                                  i, target->data.list.count);
                    vm_push_slot(slot_null());
                }
                DISPATCH();
            }
            if (target->type == VAL_STR) {
                int len = (int)strlen(target->data.str);
                if (i < len) {
                    char buf[2] = { target->data.str[i], 0 };
                    vm_push(make_str(buf));
                } else {
                    rt_error(EK_INDEX, current_line, "string index %d out of range (length %d)",
                                  i, len);
                    vm_push_slot(slot_null());
                }
                DISPATCH();
            }
            if (target->type != VAL_NULL) {
                rt_error(EK_TYPE, current_line, "cannot index %s", val_type_name(target->type));
            }
        }
        vm_push_slot(slot_null());
        DISPATCH();
    }

    CASE(LOCAL_IDX_DOT_GET): {
        /* Fused local[idx].field — the DMG hot path (ctx[0].a, ctx[1].data, etc).
         * Error semantics match unfused INDEX_GET + DOT_GET path. */
        uint16_t slot = read_u16(ip); ip += 2;
        uint16_t list_idx = read_u16(ip); ip += 2;
        uint16_t name_idx = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        Value *target = vm_local_lift(e, slot);
        int i = (int)list_idx;
        if (target && target->type == VAL_LIST) {
            if (i < target->data.list.count) {
                Value *dict = target->data.list.items[i];
                if (dict && dict->type == VAL_DICT) {
                    const char *key = chunk->const_interns[name_idx];
                    uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
                    if (h == 0) { h = env_hash_name(key); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
                    Value *v = dict_get_cached(dict, key, h);
                    if (v) {
                        /* Hot DMG path: register dict[field] returning a
                         * plain VAL_NUM -> push immediate. */
                        if (v->type == VAL_NUM) {
                            vm_push_slot(slot_from_num(v->data.num));
                        } else {
                            val_incref(v);
                            vm_push(v);
                        }
                        DISPATCH();
                    }
                } else if (dict && dict->type != VAL_NULL) {
                    const char *key = chunk->const_interns[name_idx];
                    rt_error(EK_TYPE, current_line, "cannot access field '%s' on %s",
                        key, val_type_name(dict->type));
                }
            } else {
                rt_error(EK_INDEX, current_line, "index %d out of range (list length %d)",
                              i, target->data.list.count);
            }
        } else if (target && target->type != VAL_NULL) {
            rt_error(EK_TYPE, current_line, "cannot index %s", val_type_name(target->type));
        }
        vm_push_slot(slot_null());
        DISPATCH();
    }

    CASE(LOCAL_IDX_DOT_SET): {
        /* Fused local[idx].field = TOS — the DMG hot path (ctx[0].a is X).
         * Error semantics match unfused INDEX_SET + DOT_SET path. */
        uint16_t slot = read_u16(ip); ip += 2;
        uint16_t list_idx = read_u16(ip); ip += 2;
        uint16_t name_idx = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        Value *target = vm_local_lift(e, slot);
        int i = (int)list_idx;
        if (target && target->type == VAL_LIST) {
            if (i < target->data.list.count) {
                Value *dict = target->data.list.items[i];
                if (dict && dict->type == VAL_DICT) {
                    const char *key = chunk->const_interns[name_idx];
                    uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
                    if (h == 0) { h = env_hash_name(key); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
                    /* Immediate-num + exclusive-num-slot fast path:
                     * mutate the existing dict slot's data.num in place
                     * and leave the stack slot as an immediate (no lift). */
                    EigsSlot tos = g_vm.stack[g_vm.sp - 1];
                    if (slot_is_num(tos) &&
                        dict_set_cached_immediate(dict, key, h, tos.d)) {
                        DISPATCH();
                    }
                    Value *val = vm_slot_lift(g_vm.sp - 1);
                    dict_set_cached(dict, key, h, val);
                } else if (dict && dict->type != VAL_NULL) {
                    const char *key = chunk->const_interns[name_idx];
                    rt_error(EK_TYPE, current_line, "cannot assign field '%s' on %s",
                        key, val_type_name(dict->type));
                }
            } else {
                rt_error(EK_INDEX, current_line, "index %d out of range (list length %d)",
                              i, target->data.list.count);
            }
        } else if (target && target->type != VAL_NULL) {
            rt_error(EK_TYPE, current_line, "cannot index %s for assignment",
                          val_type_name(target->type));
        }
        DISPATCH();
    }

    /* ---- Iteration ---- */

    CASE(ITER_SETUP): {
        Value *iterable = vm_pop();
        if (iterable && iterable->type != VAL_LIST && iterable->type != VAL_BUFFER) {
            rt_error(EK_TYPE, current_line, "'for' requires a list or buffer, got %s",
                val_type_name(iterable->type));
        }
        Value *state = make_iter_state(iterable);
        val_decref(iterable);
        vm_push(state);
        DISPATCH();
    }

    CASE(ITER_NEXT): {
        uint16_t exit_offset = read_u16(ip); ip += 2;
        Value *state = vm_peek(0);
        if (!state || state->type != VAL_LIST || state->data.list.count < 2) {
            ip += exit_offset;
            DISPATCH();
        }
        Value *iterable = state->data.list.items[0];
        int idx = (int)state->data.list.items[1]->data.num;
        int len = 0;
        if (iterable->type == VAL_LIST) len = iterable->data.list.count;
        else if (iterable->type == VAL_BUFFER) len = iterable->data.buffer.count;
        /* #491: cap by the entry-time snapshot (items[2]) so a body that
         * appends can't extend the loop; min() with the live length keeps a
         * remove from reading past the end. See make_iter_state. */
        if (state->data.list.count >= 3 &&
            state->data.list.items[2]->type == VAL_NUM) {
            int snap = (int)state->data.list.items[2]->data.num;
            if (snap < len) len = snap;
        }

        if (idx >= len) {
            ip += exit_offset;
        } else {
            /* Update index — mutate in place when the existing slot is
             * an exclusive plain VAL_NUM (avoids per-iter make_num/free). */
            Value *idx_v = state->data.list.items[1];
            if (NUM_REUSE(idx_v)) {
                idx_v->data.num = (double)(idx + 1);
            } else {
                val_decref(idx_v);
                state->data.list.items[1] = make_num(idx + 1);
            }
            if (iterable->type == VAL_BUFFER) {
                /* Push number immediate directly — skip make_num + immediate-
                 * promote round-trip through vm_push. */
                vm_push_slot(slot_from_num(iterable->data.buffer.data[idx]));
            } else {
                Value *elem = iterable->data.list.items[idx];
                val_incref(elem);
                vm_push(elem);
            }
        }
        DISPATCH();
    }

    CASE(LOOP_ENV_FRESH): {
        /* Create a child env for this loop iteration. The frame's owned
         * ref moves to the child: env_new took a parent-link ref on the
         * current env, so dropping the frame's ref (when it owned one)
         * leaves the current env owned by the child. A borrowed env
         * (owns_env == 0 base frames) keeps its caller's ref untouched. */
        Env *parent = frame->env;
        Env *loop_env = env_new(parent);
        if (frame->owns_env) env_decref(parent);
        frame->env = loop_env;
        frame->owns_env = 1;
        DISPATCH();
    }

    CASE(LOOP_ENV_END): {
        /* Restore the parent env after loop body: re-take an owned ref
         * on the parent for the frame, then release the loop env (its
         * destructor drops the parent-link ref — net zero on the parent;
         * a captured loop env survives via its closures' refs). */
        Env *loop_env = frame->env;
        Env *parent = loop_env->parent;
        env_incref(parent);
        frame->env = parent;
        env_decref(loop_env);
        DISPATCH();
    }

    CASE(LOOP_ENV_CLEAR): {
        /* Persisted-loop-env optimization: the loop env was created ONCE (a
         * single LOOP_ENV_FRESH before the loop) and is reused across
         * iterations. Reset its bindings here at the top of each iteration so
         * the loop variable and any loop-locals are fresh — identical to the
         * fresh-per-iteration env they replace, but without the per-iteration
         * env_new/env_decref. Only emitted for loops whose body provably
         * creates no closure (the env is never captured, so refcount stays 1
         * and clearing is safe). */
        env_clear(frame->env);
        /* env_clear resets bindings but NOT the slot-keyed observer state
         * (Env::obs). A fresh-per-iteration env starts with none, so an
         * OBSERVED loop-local would otherwise carry its entropy/dH trajectory
         * across iterations and misreport report/observe/predicate. Reset it to
         * match fresh-env semantics; this also drops the VM's last-observed-slot
         * tracker (vm_obs_slot_dropped). Cheap no-op when no observer slots were
         * allocated (the common case). */
        observer_slot_reset(frame->env);
        DISPATCH();
    }

    CASE(BREAK): {
        g_breaking = 1;
        DISPATCH();
    }

    CASE(CONTINUE): {
        g_continuing = 1;
        DISPATCH();
    }

    /* ---- Error handling ---- */

    CASE(TRY_BEGIN): {
        uint16_t catch_offset = read_u16(ip); ip += 2;
        g_try_depth++;
        if (frame->try_count < 8) {
            frame->try_handlers[frame->try_count].catch_ip = ip + catch_offset;
            frame->try_handlers[frame->try_count].catch_bp = g_vm.sp;
            frame->try_count++;
        }
        frame->is_try = 1;
        DISPATCH();
    }

    CASE(TRY_END): {
        g_try_depth--;
        if (frame->try_count > 0) frame->try_count--;
        frame->is_try = (frame->try_count > 0);
        DISPATCH();
    }

    /* ---- Observer ---- */

    CASE(OBSERVE_ASSIGN): {
        /* #262 Phase-3/E — slot model: a name binding is observed by the
         * OBSERVE_NAME_POST emitted after the SET (when its slot is live), so
         * this pre-SET name hook does nothing. (The opcode is still emitted by
         * the compiler and ouroboros; kept as a no-op consumer.) */
        ip += 2;  /* skip name_idx */
        DISPATCH();
    }

    CASE(OBSERVE_ASSIGN_LOCAL): {
        /* Slot-path counterpart of OBSERVE_ASSIGN. The compiler emits this
         * when the upcoming SET writes to a local slot (SET_LOCAL) — the
         * prior binding lives in frame->fn_env->values[slot], not in any
         * env hash. Without this op, OBSERVE_ASSIGN's env walk misses the
         * prior value and observer history (entropy/dH) resets on every
         * write, so report/predicate misclassify a slot-bound variable
         * (#129). */
        uint16_t slot = read_u16(ip); ip += 2;
        if (g_unobserved_depth == 0) {
            /* #262 Phase-3/E — slot model: observe the binding's persistent
             * (fn_env, slot) ObserverSlot directly from TOS. No promotion (the
             * num stays immediate), no Value-side state, no window migration —
             * the slot persists across assignments, which is the #262 fix. */
            EigsSlot s = g_vm.stack[g_vm.sp - 1];
            Env *e = frame->fn_env;
            if (slot_is_num(s)) {
                observer_slot_update_num(e, (int)slot, s.d);
                g_last_obs_slot_env = e; g_last_obs_slot_idx = (int)slot;
            } else if (slot_is_ptr(s)) {
                observer_slot_update(e, (int)slot, slot_as_ptr(s));
                g_last_obs_slot_env = e; g_last_obs_slot_idx = (int)slot;
            }
        }
        DISPATCH();
    }

    CASE(REPORT_SLOT): {
        uint16_t slot = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        Value *result;
        if (e && (int)slot < e->obs_cap && e->obs[slot].used) {
            result = make_str(observer_slot_report(&e->obs[slot]));
        } else {
            result = make_str("equilibrium");  /* unobserved binding */
        }
        vm_push(result);
        DISPATCH();
    }

    CASE(REPORT_NAME): {
        /* #262 Phase-3 B: report of a non-local name — resolve its (env, slot)
         * and classify the slot, value-path fallback if the slot is empty.
         * Undefined name behaves like GET_NAME: raise + push null. */
        uint16_t name_idx = read_u16(ip); ip += 2;
        const char *name = chunk->const_interns[name_idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
        int oidx = -1, odepth = 0;
        Env *oe = env_resolve_chain(frame->env, name, h, &oidx, &odepth);
        if (!oe) {
            rt_error(EK_UNDEFINED_NAME, current_line, "undefined variable '%s'", name);
            vm_push_slot(slot_null());
            DISPATCH();
        }
        Value *result;
        if (oidx >= 0 && oidx < oe->obs_cap && oe->obs[oidx].used) {
            result = make_str(observer_slot_report(&oe->obs[oidx]));
        } else {
            result = make_str("equilibrium");  /* unobserved binding */
        }
        vm_push(result);
        DISPATCH();
    }

    CASE(REPORT_VALUE_SLOT): {
        /* #294 `report_value of <local>` — classify the VALUE trajectory of the
         * local's slot (not its entropy). observer_slot_report_value returns
         * "equilibrium" for an unobserved / non-numeric binding. */
        uint16_t slot = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        Value *result;
        if (e && (int)slot < e->obs_cap)
            result = make_str(observer_slot_report_value(&e->obs[slot]));
        else
            result = make_str("equilibrium");
        vm_push(result);
        DISPATCH();
    }

    CASE(REPORT_VALUE_NAME): {
        /* #294 report_value of a non-local name — resolve (env,slot), classify
         * its value trajectory. Undefined name raises like GET_NAME. */
        uint16_t name_idx = read_u16(ip); ip += 2;
        const char *name = chunk->const_interns[name_idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
        int oidx = -1, odepth = 0;
        Env *oe = env_resolve_chain(frame->env, name, h, &oidx, &odepth);
        if (!oe) {
            rt_error(EK_UNDEFINED_NAME, current_line, "undefined variable '%s'", name);
            vm_push_slot(slot_null());
            DISPATCH();
        }
        Value *result;
        if (oidx >= 0 && oidx < oe->obs_cap)
            result = make_str(observer_slot_report_value(&oe->obs[oidx]));
        else
            result = make_str("equilibrium");
        vm_push(result);
        DISPATCH();
    }

    CASE(TRAJECTORY_SLOT): {
        /* #421 `trajectory of <local>` — snapshot the local slot's observer
         * windows into a dict value that survives a call boundary. An
         * unobserved/out-of-range slot snapshots as an empty trajectory
         * (classifies "equilibrium", mirroring report_value's fallback). */
        uint16_t slot = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        const ObserverSlot *s = (e && (int)slot < e->obs_cap) ? &e->obs[slot] : NULL;
        vm_push(observer_slot_trajectory(s));
        DISPATCH();
    }

    CASE(TRAJECTORY_NAME): {
        /* #421 trajectory of a non-local name — resolve (env,slot), snapshot.
         * Undefined name raises like GET_NAME. */
        uint16_t name_idx = read_u16(ip); ip += 2;
        const char *name = chunk->const_interns[name_idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
        int oidx = -1, odepth = 0;
        Env *oe = env_resolve_chain(frame->env, name, h, &oidx, &odepth);
        if (!oe) {
            rt_error(EK_UNDEFINED_NAME, current_line, "undefined variable '%s'", name);
            vm_push_slot(slot_null());
            DISPATCH();
        }
        const ObserverSlot *s = (oidx >= 0 && oidx < oe->obs_cap) ? &oe->obs[oidx] : NULL;
        vm_push(observer_slot_trajectory(s));
        DISPATCH();
    }

    CASE(OBSERVE_VALUE_SLOT): {
        /* #262 Phase-3 D: `observe of <local>` → [status,entropy,dH,prev_dH]
         * from the local's slot trajectory; no-observation tuple if unpopulated. */
        uint16_t slot = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        if (e && (int)slot < e->obs_cap && e->obs[slot].used) {
            const ObserverSlot *s = &e->obs[slot];
            Value *list = make_list(4);
            list_append_owned(list, make_str(observer_slot_report(s)));
            list_append_owned(list, make_num(s->entropy));
            list_append_owned(list, make_num(s->dH));
            list_append_owned(list, make_num(s->prev_dH));
            vm_push(list);
        } else {
            vm_push(builtin_observe(NULL));
        }
        DISPATCH();
    }

    CASE(OBSERVE_VALUE_NAME): {
        /* #262 Phase-3 D: `observe of <name>` → slot trajectory of the resolved
         * binding; no-observation tuple otherwise. */
        uint16_t name_idx = read_u16(ip); ip += 2;
        const char *name = chunk->const_interns[name_idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
        int oidx = -1, odepth = 0;
        Env *oe = env_resolve_chain(frame->env, name, h, &oidx, &odepth);
        if (oe && oidx >= 0 && oidx < oe->obs_cap && oe->obs[oidx].used) {
            const ObserverSlot *s = &oe->obs[oidx];
            Value *list = make_list(4);
            list_append_owned(list, make_str(observer_slot_report(s)));
            list_append_owned(list, make_num(s->entropy));
            list_append_owned(list, make_num(s->dH));
            list_append_owned(list, make_num(s->prev_dH));
            vm_push(list);
        } else {
            vm_push(builtin_observe(NULL));
        }
        DISPATCH();
    }

    CASE(OBSERVE_NAME_POST): {
        /* #262 Phase-3 observe-at-SET: the binding now exists (its SET ran),
         * so resolve its owning env+slot and observe the slot from the value
         * still on TOS (SET peeked, didn't pop). Fixes the first-assignment
         * lag for name bindings. Emitted only under the compile-time flag. */
        uint16_t name_idx = read_u16(ip); ip += 2;
        if (g_unobserved_depth == 0) {
            EigsSlot s = g_vm.stack[g_vm.sp - 1];
            /* #262 Phase-3 D: TOS is now an immediate num for an observed name
             * (default path no longer promotes), or a heap value. Observe the
             * slot from whichever; skip null/bool. */
            if (slot_is_num(s) || slot_is_ptr(s)) {
                const char *name = chunk->const_interns[name_idx];
                uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
                if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
                int oidx = -1, odepth = 0;
                Env *oe = env_resolve_chain(frame->env, name, h, &oidx, &odepth);
                if (oe && oidx >= 0) {
                    if (slot_is_num(s)) observer_slot_update_num(oe, oidx, s.d);
                    else observer_slot_update(oe, oidx, slot_as_ptr(s));
                    g_last_obs_slot_env = oe;
                    g_last_obs_slot_idx = oidx;
                    /* #262 Phase-3 D2: slot-source the temporal snapshot for
                     * `where/why/how is name at L` (the binding's slot is now
                     * fresh; its history entry was created by the SET's
                     * trace_assign). */
                    if (__builtin_expect(g_trace_obs_hist, 0)) {
                        const ObserverSlot *os = &oe->obs[oidx];
                        trace_record_obs(name, os->entropy, os->dH, os->last_entropy);
                    }
                }
            }
        }
        DISPATCH();
    }

    CASE(INTERROGATE): {
        uint16_t kind = read_u16(ip); ip += 2;
        Value *v = vm_pop();
        Value *result = make_null();
        switch (kind) {
        case 0: /* what */
            if (v && v->type == VAL_NUM) { result = make_num(v->data.num); }
            else if (v && v->type == VAL_STR) { result = make_num(strlen(v->data.str)); }
            else if (v && v->type == VAL_LIST) { result = make_num(v->data.list.count); }
            else if (v && v->type == VAL_BUFFER) { result = make_num(v->data.buffer.count); }
            else { result = make_num(0); }
            break;
        case 1: /* who — returns descriptive type name */
            if (v) result = make_str(
                v->type == VAL_NUM ? "number" :
                v->type == VAL_STR ? "string" :
                v->type == VAL_LIST ? "list" :
                v->type == VAL_DICT ? "dict" :
                v->type == VAL_FN ? "function" :
                v->type == VAL_BUILTIN ? "builtin" :
                v->type == VAL_BUFFER ? "buffer" :
                v->type == VAL_NULL ? "none" : "unknown");
            break;
        /* #262 Step E: when/where/why/how on a value-based operand have no
         * slot trajectory (observer state is binding-keyed). where/why/how on a
         * bound ident go through INTERROGATE_NAMED; the bare value form reports
         * the no-observation defaults. */
        case 2: /* when */  result = make_num(0); break;
        case 3: /* where */ result = make_num(0); break;
        case 4: /* why */   result = make_num(0); break;
        case 5: /* how */   result = make_num(1.0); break;
        }
        val_decref(v);
        vm_push(result);
        DISPATCH();
    }

    CASE(INTERROGATE_NAMED): {
        uint16_t kind = read_u16(ip); ip += 2;
        uint16_t name_idx = read_u16(ip); ip += 2;
        Value *v = vm_pop();
        Value *result = make_null();
        const char *name = chunk->const_interns[name_idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
        switch (kind) {
        case 1: /* who — return binding name */
            result = make_str(name);
            break;
        case 2: /* when — return assignment count */
            result = make_num(env_get_assign_count(frame->env, name, h));
            break;
        case 6: { /* prev — value just before the most recent assignment */
            EigsSlot prev_slot;
            if (trace_query_prev(name, &prev_slot)) {
                val_decref(result);
                result = slot_to_value(prev_slot);
                slot_decref(prev_slot);
            }
            break;
        }
        case 3: case 4: case 5: {
            /* #262 Phase-3 A: where/why/how on a bound name read the binding's
             * SLOT trajectory (entropy / dH / settledness-of-dH, #412). Falls
             * back to the Value's observer fields if the slot isn't populated
             * yet, so the answer matches the value path. */
            int oidx = -1, odepth = 0;
            Env *oe = env_resolve_chain(frame->env, name, h, &oidx, &odepth);
            if (oe && oidx >= 0 && oidx < oe->obs_cap && oe->obs[oidx].used) {
                const ObserverSlot *s = &oe->obs[oidx];
                if (kind == 3)      result = make_num(s->entropy);
                else if (kind == 4) result = make_num(s->dH);
                else                result = make_num(observer_settledness(s->dH));
            } else {
                /* #262 Step E: unobserved binding — no trajectory. */
                result = make_num(kind == 5 ? 1.0 : 0.0);
            }
            break;
        }
        }
        val_decref(v);
        vm_push(result);
        DISPATCH();
    }

    CASE(INTERROGATE_NAMED_AT): {
        uint16_t kind = read_u16(ip); ip += 2;
        uint16_t name_idx = read_u16(ip); ip += 2;
        Value *line_v = vm_pop();
        int line = 0;
        if (line_v && line_v->type == VAL_NUM) line = (int)line_v->data.num;
        val_decref(line_v);
        Value *result = make_null();
        const char *name = chunk->const_interns[name_idx];
        EigsSlot at_slot;
        if (trace_query_at(kind, name, line, &at_slot)) {
            val_decref(result);
            result = slot_to_value(at_slot);
            slot_decref(at_slot);
        }
        vm_push(result);
        DISPATCH();
    }

    CASE(DEFAULT_PARAM): {
        /* [slot:16][skip_off:16] — if the caller supplied an explicit
         * arg for this slot (i.e. slot < frame->call_argc), skip the
         * inlined default expression; else fall through and let the
         * default run, ending with OP_SET_LOCAL <slot>; OP_POP. */
        uint16_t slot = read_u16(ip); ip += 2;
        uint16_t skip = read_u16(ip); ip += 2;
        if ((int)slot < frame->call_argc) ip += skip;
        DISPATCH();
    }

    CASE(DESTRUCTURE_UNPACK): {
        /* [n:16] — pop TOS list, verify it's a VAL_LIST of length n,
         * push its elements onto the stack in reverse so element 0
         * ends up at TOS for the N assignment ops the compiler
         * emits after this. Length mismatch raises. */
        uint16_t n = read_u16(ip); ip += 2;
        EigsSlot tgt_s = g_vm.stack[g_vm.sp - 1];
        g_vm.sp -= 1;
        if (!slot_is_ptr(tgt_s) || slot_as_ptr(tgt_s)->type != VAL_LIST) {
            rt_error(EK_TYPE, current_line,
                "destructuring requires a list, got %s",
                slot_is_ptr(tgt_s) ? val_type_name(slot_as_ptr(tgt_s)->type) : "number");
            slot_decref(tgt_s);
            for (int i = 0; i < n; i++) vm_push_slot(slot_null());
            DISPATCH();
        }
        Value *lst = slot_as_ptr(tgt_s);
        if (lst->data.list.count != n) {
            rt_error(EK_VALUE, current_line,
                "destructuring expected list of length %d, got %d",
                n, lst->data.list.count);
            slot_decref(tgt_s);
            for (int i = 0; i < n; i++) vm_push_slot(slot_null());
            DISPATCH();
        }
        /* Push elements in reverse: stack ends up [..., e[n-1], ..., e[1], e[0]]
         * so each SET op consumes elements in declaration order. Incref each
         * element so the list's release below doesn't free them prematurely. */
        for (int i = n - 1; i >= 0; i--) {
            Value *e = lst->data.list.items[i];
            val_incref(e);
            vm_push(e);
        }
        slot_decref(tgt_s);
        DISPATCH();
    }

    CASE(SLICE_GET): {
        /* 0.13.0 slicing: pop 3 (end, start, target); push slice of target.
         * Null in either bound means default (0 / len). Same negative
         * resolution rule as single indexing, then 0<=start<=end<=len
         * (note <= on the upper end — a[len:] is the empty slice, not an
         * error). */
        EigsSlot end_s   = g_vm.stack[g_vm.sp - 1];
        EigsSlot start_s = g_vm.stack[g_vm.sp - 2];
        EigsSlot tgt_s   = g_vm.stack[g_vm.sp - 3];
        g_vm.sp -= 3;

        if (!slot_is_ptr(tgt_s)) {
            rt_error(EK_TYPE, g_vm.current_line, "cannot slice number");
            slot_decref(start_s); slot_decref(end_s); slot_decref(tgt_s);
            vm_push_slot(slot_null());
            DISPATCH();
        }
        Value *target = slot_as_ptr(tgt_s);
        int len;
        switch (target->type) {
            case VAL_LIST:   len = target->data.list.count; break;
            case VAL_STR:    len = (int)strlen(target->data.str); break;
            case VAL_BUFFER: len = target->data.buffer.count; break;
            default:
                rt_error(EK_TYPE, g_vm.current_line, "cannot slice %s",
                              val_type_name(target->type));
                slot_decref(start_s); slot_decref(end_s); slot_decref(tgt_s);
                vm_push_slot(slot_null());
                DISPATCH();
        }

        /* Extract a slice bound from a slot: null → use default; immediate
         * num or VAL_NUM → must be an exact integer. Returns 1 on success
         * (with *out set), 0 on type error (after raising). */
        int start = 0, end = len;
        int bound_err = 0;

        #define READ_SLICE_BOUND(slot, defval, outvar)                        \
            do {                                                              \
                if (slot_is_num(slot)) {                                      \
                    if (!vm_index_is_int(slot.d, &(outvar))) {                \
                        rt_error(EK_VALUE, g_vm.current_line,                      \
                            "slice bound must be an integer, got %g", slot.d);\
                        bound_err = 1;                                        \
                    }                                                         \
                } else if (slot_is_ptr(slot)) {                               \
                    Value *bv = slot_as_ptr(slot);                            \
                    if (bv->type == VAL_NULL) {                               \
                        (outvar) = (defval);                                  \
                    } else if (bv->type == VAL_NUM) {                         \
                        if (!vm_index_is_int(bv->data.num, &(outvar))) {      \
                            rt_error(EK_VALUE, g_vm.current_line,                  \
                                "slice bound must be an integer, got %g",     \
                                bv->data.num);                                \
                            bound_err = 1;                                    \
                        }                                                     \
                    } else {                                                  \
                        rt_error(EK_VALUE, g_vm.current_line,                      \
                            "slice bound must be an integer or null, got %s", \
                            val_type_name(bv->type));                         \
                        bound_err = 1;                                        \
                    }                                                         \
                }                                                             \
            } while (0)

        READ_SLICE_BOUND(start_s, 0, start);
        if (!bound_err) READ_SLICE_BOUND(end_s, len, end);
        #undef READ_SLICE_BOUND

        if (bound_err) {
            slot_decref(start_s); slot_decref(end_s); slot_decref(tgt_s);
            vm_push_slot(slot_null());
            DISPATCH();
        }

        /* Resolve negatives against len, then bounds-check 0<=s<=e<=len. */
        int orig_start = start, orig_end = end;
        if (start < 0) start += len;
        if (end   < 0) end   += len;
        if (start < 0 || start > len || end < 0 || end > len || start > end) {
            rt_error(EK_INDEX, g_vm.current_line,
                "slice %d:%d out of range (length %d)",
                orig_start, orig_end, len);
            slot_decref(start_s); slot_decref(end_s); slot_decref(tgt_s);
            vm_push_slot(slot_null());
            DISPATCH();
        }

        int n = end - start;
        Value *result;
        if (target->type == VAL_LIST) {
            result = make_list(n);
            for (int i = 0; i < n; i++) {
                Value *e = target->data.list.items[start + i];
                val_incref(e);
                result->data.list.items[i] = e;
            }
            result->data.list.count = n;
        } else if (target->type == VAL_STR) {
            char *buf = xmalloc((size_t)n + 1);
            if (n > 0) memcpy(buf, target->data.str + start, (size_t)n);
            buf[n] = '\0';
            result = make_str_owned(buf);
        } else {
            /* VAL_BUFFER */
            result = xcalloc(1, sizeof(Value));
            result->type = VAL_BUFFER;
            result->data.buffer.count = n;
            result->data.buffer.data = xcalloc(n > 0 ? n : 1, sizeof(double));
            if (n > 0)
                memcpy(result->data.buffer.data,
                       target->data.buffer.data + start,
                       (size_t)n * sizeof(double));
            result->refcount = 1;
        }

        slot_decref(start_s); slot_decref(end_s); slot_decref(tgt_s);
        vm_push(result);  /* stack takes the constructor's refcount=1 */
        DISPATCH();
    }

    CASE(PREDICATE): {
        /* #262 Step E: bare predicate (converged/stable/...) reads the
         * last-observed binding's SLOT trajectory. With observer state living
         * only on the slot, an operand with no live slot has no trajectory →
         * the predicate is false. */
        uint16_t kind = read_u16(ip); ip += 2;
        int result = 0;
        if (g_last_obs_slot_idx >= 0 && g_last_obs_slot_env &&
            g_last_obs_slot_idx < g_last_obs_slot_env->obs_cap) {
            const ObserverSlot *s = &g_last_obs_slot_env->obs[g_last_obs_slot_idx];
            switch (kind) {
            case 0: result = observer_slot_converged(s);   break;
            case 1: result = observer_slot_stable(s);      break;
            case 2: result = observer_slot_improving(s);   break;
            case 3: result = observer_slot_oscillating(s); break;
            case 4: result = observer_slot_diverging(s);   break;
            case 5: result = observer_slot_equilibrium(s); break;
            }
        }
        vm_push(make_num(result ? 1.0 : 0.0));
        DISPATCH();
    }

    CASE(PREDICATE_SLOT): {
        /* `<predicate> of <local>` — classify the NAMED local's slot trajectory
         * (mirrors REPORT_SLOT), not the global last-observed alias the bare
         * OP_PREDICATE reads. An unobserved/empty slot is false. */
        uint16_t kind = read_u16(ip); ip += 2;
        uint16_t slot = read_u16(ip); ip += 2;
        Env *e = frame->fn_env;
        int result = 0;
        if (e && (int)slot < e->obs_cap && e->obs[slot].used)
            result = vm_slot_predicate(&e->obs[slot], kind);
        vm_push(make_num(result ? 1.0 : 0.0));
        DISPATCH();
    }

    CASE(PREDICATE_NAME): {
        /* `<predicate> of <name>` — resolve the binding's (env,slot) and classify
         * its slot (mirrors REPORT_NAME). Undefined name raises like GET_NAME. */
        uint16_t kind = read_u16(ip); ip += 2;
        uint16_t name_idx = read_u16(ip); ip += 2;
        const char *name = chunk->const_interns[name_idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
        int oidx = -1, odepth = 0;
        Env *oe = env_resolve_chain(frame->env, name, h, &oidx, &odepth);
        if (!oe) {
            rt_error(EK_UNDEFINED_NAME, current_line, "undefined variable '%s'", name);
            vm_push_slot(slot_null());
            DISPATCH();
        }
        int result = 0;
        if (oidx >= 0 && oidx < oe->obs_cap && oe->obs[oidx].used)
            result = vm_slot_predicate(&oe->obs[oidx], kind);
        vm_push(make_num(result ? 1.0 : 0.0));
        DISPATCH();
    }

    CASE(UNOBSERVED_BEGIN): {
        g_unobserved_depth++;
        DISPATCH();
    }

    CASE(UNOBSERVED_END): {
        g_unobserved_depth--;
        DISPATCH();
    }

    CASE(LOOP_STALL_CHECK): {
        uint16_t exit_offset = read_u16(ip); ip += 2;
        g_loop_iterations++;
        int should_exit = 0;
        if (g_unobserved_depth == 0) {
            double dH, ent;
            if (obs_stall_trajectory(&dH, &ent)
                && fabs(dH) < g_obs_dh_zero && ent >= g_obs_h_low) {
                g_loop_stall_count++;
                if (g_loop_stall_count >= 100) {
                    g_loop_exit_reason = "stalled";
                    should_exit = 1;
                }
            } else {
                g_loop_stall_count = 0;
            }
        }
        if (g_loop_iterations >= (g_sandbox_loop_max ? g_sandbox_loop_max : 100000000)) {
            g_loop_exit_reason = "limit";
            should_exit = 1;
        }
        /* Always expose iteration count */
        loop_iter_store(frame->env, (double)g_loop_iterations);
        if (should_exit) {
            Value *exit_val = make_str(g_loop_exit_reason);
            env_set_local(frame->env, "__loop_exit__", exit_val);
            val_decref(exit_val);
            g_loop_stall_count = 0;
            g_loop_iterations = 0;
            g_loop_exit_reason = "normal";
            ip += exit_offset;
        }
        DISPATCH();
    }

    CASE(LOOP_CAP_CHECK): {
        /* Plain-loop variant: the absolute iteration cap ONLY — NO observer
         * stall. The compiler emits this for loops whose condition is not
         * observer-based (no predicate), so a plain `loop while c:` terminates
         * on its own condition and is never auto-halted by the global observer.
         * Must stay byte-identical to LOOP_STALL_CHECK except the convergence
         * block; both engines key off the opcode, set at compile time, so the
         * interpreter and JIT can never disagree on the classification. */
        uint16_t exit_offset = read_u16(ip); ip += 2;
        g_loop_iterations++;
        int should_exit = 0;
        if (g_loop_iterations >= (g_sandbox_loop_max ? g_sandbox_loop_max : 100000000)) {
            g_loop_exit_reason = "limit";
            should_exit = 1;
        }
        loop_iter_store(frame->env, (double)g_loop_iterations);
        if (should_exit) {
            Value *exit_val = make_str(g_loop_exit_reason);
            env_set_local(frame->env, "__loop_exit__", exit_val);
            val_decref(exit_val);
            g_loop_stall_count = 0;
            g_loop_iterations = 0;
            g_loop_exit_reason = "normal";
            ip += exit_offset;
        }
        DISPATCH();
    }

    /* ---- Modules ---- */

    CASE(IMPORT): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *name = chunk->const_interns[idx];

        extern TokenList tokenize(const char *source);
        extern ASTNode *parse(TokenList *tl);
        extern void free_tokenlist(TokenList *tl);
        extern void free_ast(ASTNode *ast);

        /* Source acquisition. The embedder's source provider
         * (eigs_set_source_provider) is consulted FIRST in every
         * profile; the filesystem chain is the hosted fallback and does
         * not exist in the freestanding profile (there the provider —
         * e.g. EigenOS's ROM bundle — is the only module source). */
        char abs_path[8192];         /* module-cache key */
        char *source = NULL;

        const char *provided = eigs_source_lookup(name);
        if (provided) {
            /* Copy immediately: downstream owns + frees `source`, and
             * the provider's pointer is only guaranteed for this call.
             * Cache key uses a NUL-adjacent prefix no real path can
             * start with, so provider modules can't collide with files. */
            source = xstrdup(provided);
            snprintf(abs_path, sizeof(abs_path), "\x01provider:%.1024s", name);
            Value *cached_dict = NULL;
            if (eigs_module_cache_get(abs_path, &cached_dict)) {
                free(source);
                vm_push(cached_dict);
                DISPATCH();
            }
        }
#if EIGENSCRIPT_FREESTANDING
        if (!source) {
            /* Raise with the real cause: there is no filesystem here,
             * and the registered provider (if any) had no entry. */
            rt_error(EK_IO, current_line,
                "import: module '%s' not found — no filesystem in the "
                "freestanding profile (no source-provider entry)", name);
            vm_push(make_null());
            DISPATCH();
        }
#else
        if (!source) {
            char request[4096];
            char path_buf[8192];
            snprintf(request, sizeof(request), "lib/%.1024s.eigs", name);

            extern int resolve_eigenscript_file_from(const char *base, const char *name,
                                                      char *out, size_t outlen);
            extern char *read_file_util(const char *path, long *size);

            /* Per-file resolution base (Phase 0b): an `import` inside a
             * module anchors at *that* module's directory, not the main
             * script's. `g_import_resolve_dir` is empty at the main-script
             * level, in which case the chain falls back to g_script_dir. */
            const char *resolve_base = g_import_resolve_dir[0]
                                           ? g_import_resolve_dir
                                           : g_script_dir;

            if (!resolve_eigenscript_file_from(resolve_base, request,
                                                path_buf, sizeof(path_buf))) {
                /* Not a stdlib module — fall back to a user module:
                 * <name>.eigs resolved against the per-file resolve base
                 * (and the other standard locations the chain tries). */
                snprintf(request, sizeof(request), "%.1024s.eigs", name);
                if (!resolve_eigenscript_file_from(resolve_base, request,
                                                    path_buf, sizeof(path_buf))) {
                    rt_error(EK_IO, current_line, "import: module '%s' not found "
                                  "(tried lib/%s.eigs and %s.eigs)", name, name, name);
                    vm_push(make_null());
                    DISPATCH();
                }
            }

            /* Module cache: canonicalize to absolute path so two different
             * importers (different cwds, different relative paths) hash to
             * the same entry. A miss re-executes; a hit binds the same dict
             * (shared mutable state — by design, mirrors Python/JS). */
            if (!realpath(path_buf, abs_path)) {
                /* realpath shouldn't fail here (we just resolved + access'd
                 * the file) but fall back to the resolved path so the cache
                 * still functions when it does. */
                snprintf(abs_path, sizeof(abs_path), "%s", path_buf);
            }
            Value *cached_dict = NULL;
            if (eigs_module_cache_get(abs_path, &cached_dict)) {
                vm_push(cached_dict);
                DISPATCH();
            }

            long src_size = 0;
            source = read_file_util(path_buf, &src_size);
            if (!source) {
                rt_error(EK_IO, current_line, "import: cannot read '%s'", name);
                vm_push(make_null());
                DISPATCH();
            }
        }
#endif /* !EIGENSCRIPT_FREESTANDING */

        /* #496: circular-import guard. `abs_path` is a confirmed cache
         * miss here (both source branches above return on a hit), so if
         * it is already on the in-flight load stack this import re-enters
         * a module whose load hasn't finished — a cycle that would
         * otherwise recurse to a C-stack SIGSEGV. Raise a catchable error
         * instead. The enter/leave brackets vm_execute below, where any
         * nested import runs. */
        if (eigs_loading_active(abs_path)) {
            free(source);
            rt_error(EK_IO, current_line,
                "import: circular dependency — '%s' is already being loaded",
                name);
            vm_push(make_null());
            DISPATCH();
        }

        Env *mod_env = env_new(g_global_env);
        int saved_errors = g_parse_errors;
        g_parse_errors = 0;
        TokenList tl = tokenize(source);
        ASTNode *ast = parse(&tl);
        if (g_parse_errors > 0) {
            g_parse_errors = saved_errors;
            free_ast(ast);  /* partial tree from the failed module parse (cf. #214) */
            free_tokenlist(&tl);
            free(source);
            env_decref(mod_env);
            rt_error(EK_PARSE, current_line, "import: parse errors in '%s'", name);
            vm_push(make_null());
            DISPATCH();
        }
        /* Compile-stage diagnostics gate below (#337) — the counter stays
         * zeroed through compile_ast, mirroring eval/load_file. */

        Env *saved_load = g_load_env;
        g_load_env = mod_env;

        /* Anchor nested imports at this module's directory. dirname()
         * derived from the canonicalized abs_path so the per-module
         * resolve dir survives symlinks and `..` segments. */
        char saved_resolve_dir[sizeof(g_import_resolve_dir)];
        memcpy(saved_resolve_dir, g_import_resolve_dir, sizeof(saved_resolve_dir));
        const char *last_slash = strrchr(abs_path, '/');
        if (last_slash && last_slash != abs_path) {
            size_t dlen = (size_t)(last_slash - abs_path);
            if (dlen >= sizeof(g_import_resolve_dir))
                dlen = sizeof(g_import_resolve_dir) - 1;
            memcpy(g_import_resolve_dir, abs_path, dlen);
            g_import_resolve_dir[dlen] = '\0';
        } else if (last_slash == abs_path) {
            g_import_resolve_dir[0] = '/';
            g_import_resolve_dir[1] = '\0';
        } else {
            g_import_resolve_dir[0] = '\0';
        }

        int saved_boundary = g_compile_module_boundary;
        g_compile_module_boundary = 1;                   /* #373 */
        EigsChunk *mod_chunk = compile_ast(ast, mod_env, source);
        g_compile_module_boundary = saved_boundary;
        if (g_parse_errors > 0) {
            g_parse_errors = saved_errors;
            chunk_free(mod_chunk);
            g_load_env = saved_load;
            memcpy(g_import_resolve_dir, saved_resolve_dir, sizeof(saved_resolve_dir));
            free_ast(ast);
            free_tokenlist(&tl);
            free(source);
            env_decref(mod_env);
            rt_error(EK_PARSE, current_line, "import: compile errors in '%s'", name);
            vm_push(make_null());
            DISPATCH();
        }
        g_parse_errors = saved_errors;
        eigs_loading_enter(abs_path);            /* #496 */
        Value *mod_result = vm_execute(mod_chunk, mod_env);
        eigs_loading_leave(abs_path);            /* #496 */
        if (mod_result) val_decref(mod_result);
        chunk_free(mod_chunk);   /* creator ref; module fns hold their own */
        g_load_env = saved_load;
        memcpy(g_import_resolve_dir, saved_resolve_dir, sizeof(saved_resolve_dir));
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);

        /* Collect module bindings into dict */
        /* mod_env has bindings from module execution */
        Value *mod_dict = make_dict(mod_env->count);
        for (int mi = 0; mi < mod_env->count; mi++) {
            if (!mod_env->names[mi] || mod_env->names[mi][0] == '_') continue;
            Value *mv = slot_to_value(mod_env->values[mi]);
            dict_set(mod_dict, mod_env->names[mi], mv);
            val_decref(mv);
        }
        /* Cache before dropping the creator ref — the cache takes its
         * own ref on both dict and env, so the module env stays alive
         * (a fn-free module would otherwise be reclaimed immediately,
         * which is fine, but caching the env keeps observer-trace
         * identity stable across re-imports). */
        eigs_module_cache_put(abs_path, mod_dict, mod_env);
        env_decref(mod_env);
        vm_push(mod_dict);
        DISPATCH();
    }

    CASE(MATCH): {
        /* Match is compiled as a series of DUP+compare+jump by the compiler.
         * This opcode is not used in the current compiler output. */
        read_u16(ip); ip += 2;
        vm_push(make_null());
        DISPATCH();
    }

    CASE(LISTCOMP_BEGIN): {
        vm_push(make_list(8));
        DISPATCH();
    }

    CASE(LISTCOMP_APPEND): {
        Value *item = vm_pop();
        /* Stack: [..., accumulator, iter_state]. Accumulator is 2 below TOS. */
        if (g_vm.sp >= 2) {
            Value *accum = STK_AS_VAL(g_vm.sp - 2);
            if (accum && accum->type == VAL_LIST)
                list_append(accum, item);
        }
        val_decref(item);
        DISPATCH();
    }

    CASE(LINE): {
        uint16_t line = read_u16(ip); ip += 2;
        current_line = line;
        g_vm.current_line = line;
        /* History stamping needs the current line whether or not a tape
         * is open — a plain global store is far cheaper than the call
         * (17.8M calls per 500k DMG-shaped steps before this change).
         * #297: skip under MT — the global is shared, history/replay is a
         * single-threaded feature, and the error line is carried per-thread by
         * g_vm.current_line above. (The hot single-threaded path is unchanged:
         * one predicted branch on an already-cached flag.) */
        if (!g_vm_multithreaded) g_trace_current_line = line;
        if (__builtin_expect(g_trace_enabled, 0)) trace_line(line);
        DISPATCH();
    }

    CASE(DISPATCH): {
        /* Native dispatch: stack [table, key, arg] -> table[key](arg).
         * Key may be an immediate-num slot (literal key) or a boxed
         * VAL_NUM (key sourced from a fn return, arithmetic, variable
         * read — DMG's per-instruction `op` path). Table and arg are
         * heap pointers in practice (list + ctx). */
        EigsSlot arg_s   = g_vm.stack[g_vm.sp - 1];
        EigsSlot key_s   = g_vm.stack[g_vm.sp - 2];
        EigsSlot table_s = g_vm.stack[g_vm.sp - 3];
        g_vm.sp -= 3;

        double key_d;
        if (slot_is_num(key_s)) {
            key_d = key_s.d;
        } else if (slot_is_ptr(key_s) && slot_as_ptr(key_s)
                   && slot_as_ptr(key_s)->type == VAL_NUM) {
            key_d = slot_as_ptr(key_s)->data.num;
        } else {
            slot_decref(arg_s); slot_decref(key_s); slot_decref(table_s);
            rt_error(EK_TYPE, current_line, "dispatch: key must be a number");
            vm_push_slot(slot_null());
            DISPATCH();
        }
        slot_decref(key_s);

        if (!slot_is_ptr(table_s)) {
            slot_decref(arg_s); slot_decref(table_s);
            rt_error(EK_TYPE, current_line, "dispatch: table must be a list");
            vm_push_slot(slot_null());
            DISPATCH();
        }

        Value *table = slot_as_ptr(table_s);
        int key;
        if (!vm_index_is_int(key_d, &key)) {
            slot_decref(arg_s); slot_decref(table_s);
            rt_error(EK_VALUE, current_line,
                "dispatch key must be an integer, got %g", key_d);
            vm_push_slot(slot_null());
            DISPATCH();
        }

        if (table->type != VAL_LIST) {
            slot_decref(arg_s); slot_decref(table_s);
            rt_error(EK_TYPE, current_line, "dispatch: table must be a list");
            vm_push_slot(slot_null());
            DISPATCH();
        }
        /* Out-of-range key stays a silent null on BOTH implementations —
         * deliberate (sparse dispatch tables); see builtin_dispatch. */
        if (key < 0 || key >= table->data.list.count) {
            slot_decref(arg_s); slot_decref(table_s);
            vm_push_slot(slot_null());
            DISPATCH();
        }

        Value *fn = table->data.list.items[key];

        if (fn && fn->type == VAL_BUILTIN) {
            Value *arg = slot_to_value(arg_s);
            slot_decref(arg_s);
            Env *saved = g_builtin_call_env;
            g_builtin_call_env = frame->env;
            int consumes_arg = (fn->data.builtin == builtin_free_val);
            Value *result = fn->data.builtin(arg);
            g_builtin_call_env = saved;
            if (!result) {
                result = make_null();
            } else if (!consumes_arg && result != arg) {
                /* Direct-borrow heuristic (capped, #546) — see
                 * vm_borrow_scan. Must run before val_decref(arg) so
                 * the items array is still valid, and skipped when the
                 * builtin already consumed arg (free_val). */
                vm_borrow_scan(arg, result);
            }
            if (!consumes_arg && result != arg) val_decref(arg);
            slot_decref(table_s);
            vm_push(result);
            CHECK_ERROR();
            DISPATCH();
        }

        if (fn && fn->type == VAL_FN && fn->data.fn.body_count == -1) {
            /* Bytecode function — push frame inline (no re-entry).
             * Bind the single param directly from the slot (no boxing).
             * Stage 5i: single-arg dispatch, so only param_count <= 1
             * callees pass the take gate (fully-bound requirement). */
            EigsChunk *fn_chunk = (EigsChunk *)fn->data.fn.body;
            Env *call_env = vm_take_call_env(fn_chunk, fn->data.fn.closure,
                                             fn->data.fn.param_count, 1);
            if (call_env) {
                if (fn->data.fn.param_count > 0) {
                    env_rebind_param_slot(call_env, 0, arg_s);
                } else {
                    slot_decref(arg_s);
                }
            } else {
            call_env = env_new(fn->data.fn.closure);
            int dpc = fn->data.fn.param_count;
            if (dpc > 0) {
                uint32_t ph = fn->data.fn.param_hashes ? fn->data.fn.param_hashes[0]
                                                       : env_hash_name(fn->data.fn.params[0]);
                vm_bind_fresh_param(call_env, 0,
                    fn->data.fn.params[0], ph, arg_s);
            } else {
                slot_decref(arg_s);
            }
            /* DISPATCH always feeds argc=1; underfed tail slots
             * [1..param_count) get null placeholders, then
             * OP_DEFAULT_PARAM fills the defaulted ones. */
            if (dpc > 1 && fn_chunk->first_default < dpc) {
                uint32_t *phashes = fn->data.fn.param_hashes;
                for (int i = 1; i < dpc; i++) {
                    uint32_t ph = phashes ? phashes[i]
                                          : env_hash_name(fn->data.fn.params[i]);
                    env_bind_fresh_param_slot(call_env,
                        fn->data.fn.params[i], ph, slot_null());
                }
            }
            /* Pre-allocate slots for non-captured locals */
            if (fn_chunk->local_count > dpc)
                env_reserve_slots(call_env, fn_chunk->local_count);
            }
            slot_decref(table_s);

            frame->ip = ip;
            if (g_vm.frame_count >= VM_FRAMES_MAX) {
                rt_error(EK_LIMIT, current_line, "call stack overflow");
                env_decref(call_env);
                vm_push(make_null());
                DISPATCH();
            }
            frame = &g_vm.frames[g_vm.frame_count++];
            frame->chunk = fn_chunk;
            frame->call_serial = ++g_call_serial_next;   /* #539 v2 */
            chunk_incref(fn_chunk);   /* frame's ref */
            frame->ip = fn_chunk->code;
            frame->bp = g_vm.sp;
            frame->env = call_env;
            frame->fn_env = call_env;
            frame->closure_val = fn;
            frame->owns_env = 1;
            frame->is_try = 0;
            frame->try_count = 0;
            frame->call_argc = 1;
            fn_chunk->exec_count++;

            /* JIT hook (mirror of OP_CALL bytecode-fn path; #533 task gate). */
            if (fn_chunk->jit_state == 0 && !g_task_sched) jit_try_compile_chunk(fn_chunk);
            if (fn_chunk->jit_code && !g_task_sched) {
                ((JitChunkFn)fn_chunk->jit_code)();
                if (fn_chunk->jit_advance == -1) {
                    /* Stage 4s: OP_RETURN sentinel — see OP_CALL hook.
                     * Popped frame's chunk ref is ours to drop. */
                    chunk_decref(fn_chunk);
                    if (g_vm.frame_count <= base_frame) {
                        EigsSlot result_s = g_vm.stack[--g_vm.sp];
                        if (slot_is_num(result_s))  return make_num(result_s.d);
                        if (slot_is_null(result_s)) return make_null();
                        if (slot_is_bool(result_s)) return make_num(slot_as_bool(result_s) ? 1.0 : 0.0);
                        return slot_as_ptr(result_s);
                    }
                    frame = &g_vm.frames[g_vm.frame_count - 1];
                    ip = frame->ip;
                    chunk = frame->chunk;
                    current_line = g_vm.current_line;
                    DISPATCH();
                }
                if (fn_chunk->jit_advance == -2) {
                    /* Stage 5f deep bail — see the OSR site. */
                    frame = &g_vm.frames[g_vm.frame_count - 1];
                    ip = frame->ip;
                    chunk = frame->chunk;
                    current_line = g_vm.current_line;
                    DISPATCH();
                }
                frame->ip += fn_chunk->jit_advance;
                current_line = g_vm.current_line;
            }

            ip = frame->ip;
            chunk = fn_chunk;
            DISPATCH();
        }

        /* Null slot (a hole in the table) is a silent null, matching
         * builtin_dispatch. VAL_FN with an AST body also nulls there
         * (unreachable post-bytecode-migration, kept for parity). */
        if (!fn || fn->type == VAL_NULL || fn->type == VAL_FN) {
            slot_decref(arg_s); slot_decref(table_s);
            vm_push_slot(slot_null());
            DISPATCH();
        }

        /* Anything else in-range is a populated-with-non-function bug in
         * the program — raise like builtin_dispatch (#353). */
        slot_decref(arg_s); slot_decref(table_s);
        rt_error(EK_TYPE, current_line, "dispatch: slot %d is not a function", key);
        vm_push_slot(slot_null());
        DISPATCH();
    }

    CASE(WIDE): {
        /* Not yet implemented — placeholder */
        DISPATCH();
    }

#ifndef __GNUC__
    default:
        rt_error(EK_INTERNAL, current_line, "unknown opcode %d", ip[-1]);
        vm_push(make_null());
        break;
    }} /* end switch / for */
#endif

    /* Should not reach here */
    chunk_decref(g_vm.frames[g_vm.frame_count - 1].chunk);
    g_vm.frame_count--;
    return make_null();

vm_error_halt:
    vm_error_flush_pending(chunk, ip);   /* #407: belt — normally flushed by CHECK_ERROR */
    /* Uncaught runtime error: unwind every frame this vm_run owns
     * ([base_frame, frame_count)) the same way OP_RETURN does — drain the
     * frame's stack window, free its env if owned, restore the per-frame
     * loop-stall globals — then return null. g_has_error is left set on
     * purpose: the caller (re-entrant vm_run via CHECK_ERROR, or main via
     * its exit code) is responsible for reporting it. */
    while (g_vm.frame_count > base_frame) {
        CallFrame *f = &g_vm.frames[g_vm.frame_count - 1];
        while (g_vm.sp > f->bp) slot_decref(g_vm.stack[--g_vm.sp]);
        if (f->owns_env) env_decref(f->env);
        g_loop_stall_count = f->saved_stall_count;
        g_loop_iterations  = f->saved_loop_iter;
        chunk_decref(f->chunk);   /* frame's ref */
        g_vm.frame_count--;
    }
    return make_null();

vm_suspend_halt:
    /* #408 suspend: the OPPOSITE of vm_error_halt — do NOT drain the frames,
     * we are preserving them. Sync the live current_line, then hand the whole
     * live slice [0, frame_count)/[0, sp) to the copying-stack save-buffer and
     * retreat the VM to empty so the scheduler can run the next task at base 0.
     * Ownership moves with the memcpy'd bytes; g_task_suspend_request is
     * cleared by the save. Returns NULL — the scheduler distinguishes a
     * suspend from a real result via the task's state (TASK_SUSPENDED). */
    g_vm.current_line = current_line;
    task_save_slice(task_current_running());
    g_task_suspend_request = 0;
    return NULL;
}

/* Ordinary fresh-entry wrapper — the common path for every non-task call. */
static Value *vm_run(EigsChunk *chunk, Env *env) {
    return vm_run_ex(chunk, env, NULL);
}

/* ---- Public API ---- */

/* ===== #408 cooperative task scheduler ==================================
 * A trampoline just above the OUTERMOST vm_execute drives every task —
 * including task 0 (the main program) — so C-stack depth stays flat
 * (vm_execute → scheduler → one vm_run) no matter how often tasks ping-pong.
 * A task suspends by a builtin setting g_task_suspend_request; the CASE(CALL)
 * site saves its live stack+frame slice (the copying-stack model: memory =
 * live depth, not a full 1.28 MB VM per task) and returns here, which runs
 * the next ready task. Deterministic by construction — no tape records; the
 * interleaving is a pure function of program order.
 * ======================================================================== */

int g_task_suspend_request = 0;

#define TASK_READY_MAX HANDLE_TABLE_SIZE

typedef struct {
    int   ready[TASK_READY_MAX];  /* circular FIFO of runnable task ids (0=main) */
    int   rhead, rcount;
    int   current;                /* running task id; 0 = main */
    int   live;                   /* spawned tasks not yet DONE/DEAD */
    int   active;                 /* armed on first spawn */
    int   dead_letters;           /* inc 2: sends to finished/unknown tasks */
    int   detached_err_count;     /* #530: reaped detached tasks that died unobserved (#493 gate) */
    uint64_t spawn_counter;       /* #535: monotonically increasing; stamps Task.spawn_seq */
    double now;                   /* inc 3: virtual clock (logical, starts 0) */
    int   seeded;                 /* inc 4: 1 once task_sched_seed installs a seed */
    uint64_t rng_state;           /* inc 4: splitmix64 state for the seeded pick */
    Task  main_task;              /* task 0 — save-buffer only, never "started" */
} TaskScheduler;

static TaskScheduler *sched_get(void) { return (TaskScheduler *)g_task_sched; }

static TaskScheduler *sched_ensure(void) {
    TaskScheduler *s = sched_get();
    if (!s) {
        s = xcalloc(1, sizeof(TaskScheduler));
        s->main_task.id = 0;
        s->main_task.state = TASK_RUNNING;
        s->current = 0;
        g_task_sched = s;
    }
    return s;
}

void task_sched_thread_free(void) {
    TaskScheduler *s = sched_get();
    if (!s) return;
    Task *m = &s->main_task;
    /* #483: main is USUALLY run-to-completion here (empty slice). But a fatal
     * exit while main is still SUSPENDED — a `deadlock`, or main blocked on a
     * join/recv that never resolves — leaves a live saved slice whose counted
     * refs would otherwise leak: the base module frame owns a chunk ref (the
     * script chunk, see vm_run's frame push), and the operand stack owns value
     * refs. Release them, mirroring task_free's worker-slice teardown, before
     * freeing the arrays. (owns_env is 0 for the module frame — the global env
     * is dropped separately in main.c/eigs_close — so only chunk_decref here.) */
    if (m->saved_stack) {
        for (int i = 0; i < m->saved_stack_len; i++) slot_decref(m->saved_stack[i]);
        free(m->saved_stack);
    }
    if (m->saved_frames) {
        for (int i = 0; i < m->saved_frame_count; i++) {
            CallFrame *f = &m->saved_frames[i];
            if (f->owns_env && f->env) env_decref(f->env);
            if (f->chunk) chunk_decref(f->chunk);
        }
        free(m->saved_frames);
    }
    if (m->mbox) {
        for (int i = 0; i < m->mbox_count; i++)
            val_decref(m->mbox[(m->mbox_head + i) % m->mbox_cap]);
        free(m->mbox);
    }
    if (m->result) val_decref(m->result);
    if (m->error_value) val_decref(m->error_value);
    free(s);
    g_task_sched = NULL;
}

static Task *sched_lookup(TaskScheduler *s, int id) {
    if (id == 0) return &s->main_task;
    return (Task *)handle_lookup(id, HANDLE_TASK);
}

/* #493: does any worker still carry an uncaught-error death that no task_join
 * ever observed? Scanned once at process exit (before handle_table_drain frees
 * the tasks) so a fire-and-forget worker's death makes the process exit
 * non-zero instead of silently returning 0. */
int task_any_unobserved_error(void) {
    if (!g_task_sched) return 0;
    /* #530: reaped detached tasks that died unobserved are counted, not held. */
    if (((TaskScheduler *)g_task_sched)->detached_err_count > 0) return 1;
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        Task *t = (Task *)handle_lookup(i, HANDLE_TASK);
        if (t && t->err_unobserved) return 1;
    }
    return 0;
}

static Task *task_current_running(void) {
    TaskScheduler *s = sched_get();
    return s ? sched_lookup(s, s->current) : NULL;
}

static void sched_ready_push(TaskScheduler *s, int id) {
    if (s->rcount >= TASK_READY_MAX) return;   /* ids are table-bounded; can't overflow */
    s->ready[(s->rhead + s->rcount) % TASK_READY_MAX] = id;
    s->rcount++;
}

/* #530: drop tid's pending ready-queue entry. A task killed while READY (or
 * woken but not yet run) used to leave its entry behind; the trampoline
 * skips stale ids, but enough of them FILL the fixed queue and
 * sched_ready_push silently drops real wakeups — a spurious "deadlock".
 * A task has at most one entry (recv-wake is idempotent and a task must be
 * popped before it can re-enqueue), so one compacting pass suffices. */
static void sched_ready_remove(TaskScheduler *s, int tid) {
    int w = 0;
    for (int k = 0; k < s->rcount; k++) {
        int id = s->ready[(s->rhead + k) % TASK_READY_MAX];
        if (id != tid) {
            s->ready[(s->rhead + w) % TASK_READY_MAX] = id;
            w++;
        }
    }
    s->rcount = w;
}

/* Inc 4: splitmix64 — a deterministic, platform-independent integer PRNG for
 * the seeded scheduling strategy. Pure integer arithmetic (no float, no OS
 * entropy), so the pick sequence is a reproducible function of the installed
 * seed + program order — the seeded schedule replays byte-identically and
 * records no tape nondeterminism. */
static uint64_t sched_rng_next(TaskScheduler *s) {
    uint64_t z = (s->rng_state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

/* task_sched_seed: install a seed and switch the scheduler from FIFO
 * round-robin to a seeded pseudo-random pick of the next ready task. Ensures
 * the scheduler exists so the seed sticks even when set before the first
 * task_spawn. The interleaving stays deterministic — a DST varies the seed to
 * explore different interleavings, each fully reproducible. */
void task_sched_set_seed(double seed) {
    TaskScheduler *s = sched_ensure();
    s->rng_state = (uint64_t)(int64_t)seed;   /* integer seeds; fractions truncate */
    s->seeded = 1;
}

static int sched_ready_pop(TaskScheduler *s) {
    if (s->rcount == 0) return -1;
    if (!s->seeded || s->rcount == 1) {
        /* Default FIFO: O(1) head pop — the fast path, unchanged. */
        int id = s->ready[s->rhead];
        s->rhead = (s->rhead + 1) % TASK_READY_MAX;
        s->rcount--;
        return id;
    }
    /* Seeded strategy: pick a pseudo-random ready task, then compact the hole
     * by shifting the suffix down one (order-preserving among the rest). O(n)
     * in the ready count, which is tiny and only paid in DST/seeded mode. */
    int idx = (int)(sched_rng_next(s) % (uint64_t)s->rcount);
    int id  = s->ready[(s->rhead + idx) % TASK_READY_MAX];
    for (int k = idx; k < s->rcount - 1; k++) {
        s->ready[(s->rhead + k) % TASK_READY_MAX] =
            s->ready[(s->rhead + k + 1) % TASK_READY_MAX];
    }
    s->rcount--;
    return id;
}

/* Copying-stack save: memcpy the running task's live slice [0,fc)/[0,sp) into
 * its right-sized save-buffer, then retreat the VM to empty. Refs move WITH
 * the bytes (the saved slots/frames own the same counted refs that were on
 * the stack), so sp/frame_count just retreat — no incref/decref, no walk. */
static void task_save_slice(Task *t) {
    if (!t) return;
    int fc = g_vm.frame_count, sp = g_vm.sp;
    free(t->saved_frames);
    free(t->saved_stack);
    t->saved_frames = fc ? xmalloc(sizeof(CallFrame) * fc) : NULL;
    t->saved_stack  = sp ? xmalloc(sizeof(EigsSlot) * sp)  : NULL;
    if (fc) memcpy(t->saved_frames, g_vm.frames, sizeof(CallFrame) * fc);
    if (sp) memcpy(t->saved_stack,  g_vm.stack,  sizeof(EigsSlot) * sp);
    t->saved_frame_count  = fc;
    t->saved_stack_len    = sp;
    t->saved_current_line = g_vm.current_line;
    g_vm.frame_count = 0;
    g_vm.sp = 0;
    t->state = TASK_SUSPENDED;
}

/* Copying-stack restore: memcpy a suspended task's slice back onto the empty
 * VM. Symmetric with save — refs move back with the bytes. */
static void task_restore_slice(Task *t) {
    int fc = t->saved_frame_count, sp = t->saved_stack_len;
    if (fc) memcpy(g_vm.frames, t->saved_frames, sizeof(CallFrame) * fc);
    if (sp) memcpy(g_vm.stack,  t->saved_stack,  sizeof(EigsSlot) * sp);
    g_vm.frame_count  = fc;
    g_vm.sp           = sp;
    g_vm.current_line = t->saved_current_line;
    free(t->saved_frames); t->saved_frames = NULL;
    free(t->saved_stack);  t->saved_stack  = NULL;
    t->saved_frame_count = 0;
    t->saved_stack_len   = 0;
    t->state = TASK_RUNNING;
}

/* task_spawn (builtins.c) hands a freshly registered task here. */
void task_sched_on_spawn(int id) {
    TaskScheduler *s = sched_ensure();
    s->active = 1;
    s->live++;
    /* #535: stamp spawn order. Handle IDs come from a rotating cursor, so
     * they encode the process's WHOLE allocation history; any id-ordered
     * tie-break makes the interleaving history-dependent. Spawn order is a
     * pure function of the run. Main is 0 (spawn_counter starts at 1). */
    Task *t = sched_lookup(s, id);
    if (t) t->spawn_seq = ++s->spawn_counter;
    sched_ready_push(s, id);
}

/* task_yield: mark the current task for suspension; the trampoline re-enqueues
 * it at the tail (round-robin) after the save. */
void task_request_yield(void) { g_task_suspend_request = 1; }

/* task_join: block the current task on `target`. Returns 0 for a bad target
 * (main, self, or unknown) so the builtin can fall back; 1 to suspend. A
 * target that is already finished is handled in the builtin (returns its
 * result without suspending). */
int task_request_join(int target) {
    TaskScheduler *s = sched_get();
    if (!s || target == 0 || target == s->current) return 0;
    Task *tt = sched_lookup(s, target);
    if (!tt) return 0;
    Task *cur = sched_lookup(s, s->current);
    cur->join_target = target;
    g_task_suspend_request = 1;
    return 1;
}

/* ---- Inc 2: mailboxes -------------------------------------------------- */

/* Append msg (ownership transferred in) to task `tid`'s FIFO mailbox and wake
 * it if it is blocked in task_recv. Returns 1 if delivered, 0 if dropped
 * because the target is gone (finished/unknown) — send-to-dead is a silent
 * drop plus a dead-letter count (Akka dead-letters / Erlang cast), NOT an
 * error: an error path here would be a nondeterminism magnet. */
int task_deliver(int tid, Value *msg_owned) {
    TaskScheduler *s = sched_get();
    Task *t = s ? sched_lookup(s, tid) : NULL;
    if (!t || t->state == TASK_DONE || t->state == TASK_DEAD) {
        if (s) s->dead_letters++;
        return 0;
    }
    if (t->mbox_count >= t->mbox_cap) {
        int nc = t->mbox_cap ? t->mbox_cap * 2 : 8;
        Value **nb = xmalloc(sizeof(Value *) * nc);
        for (int i = 0; i < t->mbox_count; i++)
            nb[i] = t->mbox[(t->mbox_head + i) % t->mbox_cap];
        free(t->mbox);
        t->mbox = nb; t->mbox_cap = nc; t->mbox_head = 0;
    }
    t->mbox[(t->mbox_head + t->mbox_count) % t->mbox_cap] = msg_owned;
    t->mbox_count++;
    /* Wake a recv-blocked receiver on the FIRST message that arrives while it
     * waits on an empty mailbox (mbox_count just became 1). recv_blocked stays
     * set so the resume path (task_apply_recv_result) delivers this message and
     * clears it; the mbox_count==1 guard makes the enqueue idempotent — a
     * second send before the receiver resumes finds count>1 and does not
     * re-enqueue (which would put the task in the ready queue twice). */
    if (t->recv_blocked && t->state == TASK_SUSPENDED && t->mbox_count == 1)
        sched_ready_push(s, tid);
    return 1;
}

int task_mbox_has(void) {
    Task *t = task_current_running();
    return (t && t->mbox_count > 0) ? 1 : 0;
}

Value *task_mbox_pop(void) {
    Task *t = task_current_running();
    if (!t || t->mbox_count == 0) return make_null();
    Value *v = t->mbox[t->mbox_head];
    t->mbox_head = (t->mbox_head + 1) % t->mbox_cap;
    t->mbox_count--;
    return v;   /* owned ref transfers to caller */
}

void task_request_recv(void) {
    Task *t = task_current_running();
    if (t) t->recv_blocked = 1;
    g_task_suspend_request = 1;
}

/* ---- Inc 3: virtual time ---------------------------------------------- */

/* task_sleep: the current task becomes runnable again when the virtual clock
 * reaches now + ticks. The trampoline advances the clock only when nothing is
 * runnable (see sched_wake_sleepers), so time is a pure function of program
 * order + sleep durations — no tape records, no wall clock. A negative sleep
 * is clamped to 0 (a same-tick yield to everything currently ready). */
void task_request_sleep(double ticks) {
    TaskScheduler *s = sched_get();
    Task *t = task_current_running();
    if (!s || !t) return;
    double dt = ticks > 0 ? ticks : 0;
    t->wake_at = s->now + dt;
    t->sleeping = 1;
    g_task_suspend_request = 1;
}

double task_virtual_now(void) {
    TaskScheduler *s = sched_get();
    return s ? s->now : 0;
}

/* task_self (builtins.c): the running task's id, in the same integer space
 * task_spawn returns — 0 for the main task, including before any scheduler
 * exists. Pure scheduler state, so no tape participation. */
int task_current_id(void) {
    TaskScheduler *s = sched_get();
    return s ? s->current : 0;
}

/* When the ready queue is empty, advance the virtual clock to the earliest
 * sleeper's wake time and make every task due at (or before) that instant
 * runnable. Returns 1 if any sleeper was woken (the trampoline then loops),
 * 0 if there are no sleepers (genuine idle → done or deadlock). Ties at the
 * same wake_at are broken by ascending task id (main = 0 first), so the
 * interleaving stays deterministic. The clock only ever moves forward:
 * wake_at = now + dt >= now, so the min is never behind the current now. */
static int sched_wake_sleepers(TaskScheduler *s) {
    double best = 0; int have_best = 0;
    if (s->main_task.state == TASK_SUSPENDED && s->main_task.sleeping) {
        best = s->main_task.wake_at; have_best = 1;
    }
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        Task *t = (Task *)handle_lookup(i, HANDLE_TASK);
        if (t && t->state == TASK_SUSPENDED && t->sleeping &&
            (!have_best || t->wake_at < best)) {
            best = t->wake_at; have_best = 1;
        }
    }
    if (!have_best) return 0;
    s->now = best;
    /* Wake main first, then tasks in ascending SPAWN order (#535) — NOT id
     * order: ids come from a rotating next-fit cursor, so id order encodes
     * the process's whole allocation history and two identical seeded runs
     * in one process could interleave differently once slots recycle
     * (surfaced by liferaft's in-sweep fault verify failing to reproduce
     * standalone). Spawn order is a pure function of the run itself. */
    if (s->main_task.state == TASK_SUSPENDED && s->main_task.sleeping &&
        s->main_task.wake_at <= s->now) {
        s->main_task.sleeping = 0;
        sched_ready_push(s, 0);
    }
    for (;;) {
        Task *next = NULL;
        for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
            Task *t = (Task *)handle_lookup(i, HANDLE_TASK);
            if (t && t->state == TASK_SUSPENDED && t->sleeping && t->wake_at <= s->now &&
                (!next || t->spawn_seq < next->spawn_seq))
                next = t;
        }
        if (!next) break;
        next->sleeping = 0;
        sched_ready_push(s, next->id);
    }
    return 1;
}

/* Deterministic teardown of a task mid-run (task_kill): drop its mailbox and
 * saved slice, wake any joiner with an `interrupt` error, mark it DEAD. The
 * handle entry stays (task_alive → 0, joiners see DEAD); handle_table_drain
 * frees the struct at exit. Returns 0 for a bad/self/finished target. */
int task_do_kill(int tid) {
    TaskScheduler *s = sched_get();
    if (!s || tid == 0 || tid == s->current) return 0;
    Task *t = sched_lookup(s, tid);
    if (!t || t->state == TASK_DONE || t->state == TASK_DEAD) return 0;
    /* #530: a READY/woken victim holds a ready-queue entry — remove it so
     * dead ids can never fill the queue and starve real wakeups. */
    sched_ready_remove(s, tid);
    /* Drain the mailbox. */
    while (t->mbox_count > 0) {
        val_decref(t->mbox[t->mbox_head]);
        t->mbox_head = (t->mbox_head + 1) % t->mbox_cap;
        t->mbox_count--;
    }
    free(t->mbox); t->mbox = NULL; t->mbox_cap = 0; t->mbox_head = 0;
    /* Release the suspended slice's counted refs (mirror task_free's slice
     * teardown) so a killed suspended task doesn't leak. */
    if (t->saved_stack) {
        for (int i = 0; i < t->saved_stack_len; i++) slot_decref(t->saved_stack[i]);
        free(t->saved_stack); t->saved_stack = NULL; t->saved_stack_len = 0;
    }
    if (t->saved_frames) {
        for (int i = 0; i < t->saved_frame_count; i++) {
            CallFrame *f = &t->saved_frames[i];
            if (f->owns_env && f->env) env_decref(f->env);
            if (f->chunk) chunk_decref(f->chunk);
        }
        free(t->saved_frames); t->saved_frames = NULL; t->saved_frame_count = 0;
    }
    if (t->run_env) { env_decref(t->run_env); t->run_env = NULL; }
    t->has_error = 1;
    t->state = TASK_DEAD;
    s->live--;
    /* Wake joiners with an interrupt: on resume task_apply_join_result sees
     * has_error and re-raises. Give them an error payload. */
    if (!t->error_value) {
        Value *ev = make_dict(3);
        dict_set_owned(ev, "kind", make_str(err_kind_name(EK_INTERRUPT)));
        dict_set_owned(ev, "message", make_str("task was killed"));
        dict_set_owned(ev, "line", make_num(0));
        t->error_value = ev;
    }
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        Task *w = (Task *)handle_lookup(i, HANDLE_TASK);
        if (w && w->state == TASK_SUSPENDED && w->join_target == tid)
            sched_ready_push(s, w->id);
    }
    if (s->main_task.state == TASK_SUSPENDED && s->main_task.join_target == tid)
        sched_ready_push(s, 0);
    /* #530: kill of a detached task is an explicit discard — reap now. (Kill
     * is a deliberate teardown, never an uncaught error: no #493 counting.) */
    if (t->detached) task_reap(t);
    return 1;
}

/* On resuming a recv-blocked task, fill the placeholder the task_recv builtin
 * left on the stack top with the next mailbox message. */
static void task_apply_recv_result(Task *t) {
    /* Only a task that suspended INSIDE task_recv has a placeholder to fill.
     * A task resuming from a plain task_yield/task_join must NOT have its
     * mailbox drained here, even if a message arrived meanwhile. */
    if (!t->recv_blocked) return;
    t->recv_blocked = 0;
    if (g_vm.sp > 0) {
        slot_decref(g_vm.stack[g_vm.sp - 1]);
        Value *msg;
        if (t->mbox_count > 0) {
            msg = t->mbox[t->mbox_head];
            t->mbox_head = (t->mbox_head + 1) % t->mbox_cap;
            t->mbox_count--;
        } else {
            msg = make_null();   /* woken without a message (killed sender race) */
        }
        g_vm.stack[g_vm.sp - 1] = slot_from_heap(msg);
    }
}

/* Start a never-run spawned task: bind its deep-copied args into a fresh env
 * from the entry closure (the base frame borrows it — the Task owns run_env
 * across suspend/resume), then run at base 0 so it is suspendable. Mirrors
 * call_eigs_fn's param binding, but does not run to completion. */
static Value *task_start(Task *t) {
    Value *fn = t->entry_fn;
    if (fn->type == VAL_BUILTIN) {          /* builtins never suspend — run direct */
        Value *a = t->argc == 1 ? t->args[0] : make_null();
        return fn->data.builtin(a);
    }
    Env *call_env = env_new(fn->data.fn.closure);
    for (int i = 0; i < fn->data.fn.param_count && i < t->argc; i++)
        env_set_local(call_env, fn->data.fn.params[i], t->args[i]);
    t->run_env = call_env;                  /* Task owns it; base frame borrows */
    t->started = 1;
    EigsChunk *chunk = (EigsChunk *)fn->data.fn.body;
    return vm_run_ex(chunk, call_env, NULL);
}

/* Record a task that just finished (returned or errored) and wake any joiner
 * blocked on it. `r` is the value vm_run returned (NULL on suspend — not this
 * path). g_has_error distinguishes a normal end from an uncaught error. */
/* #530: release a task's handle slot and free the struct. Only for tasks
 * nobody will join (detached) — a reaped id reads as unknown afterwards
 * (task_alive 0, task_join null) and the slot is immediately reusable. */
static void task_reap(Task *t) {
    int id = t->id;
    task_free(t);
    handle_release(id);
}

/* #530: mark `tid` fire-and-forget. A detached task is reaped the moment it
 * finishes — or immediately here if it already has — so its handle slot
 * returns to the pool instead of holding the table until process exit. An
 * already-dead unobserved error moves to the scheduler-level counter so the
 * #493 exit gate survives the reap. The RUNNING task may detach itself.
 * Returns 1 on success, 0 for main (task 0) or an unknown id. */
int task_do_detach(int tid) {
    TaskScheduler *s = sched_get();
    if (!s || tid == 0) return 0;
    Task *t = sched_lookup(s, tid);
    if (!t) return 0;
    if (t->state == TASK_DONE || t->state == TASK_DEAD) {
        if (t->err_unobserved) s->detached_err_count++;
        task_reap(t);
        return 1;
    }
    t->detached = 1;
    return 1;
}

static void sched_finish(TaskScheduler *s, Task *t, Value *r) {
    /* A task that ended (returned OR died) while its per-thread arena is still
     * active — arena_mark with no matching arena_reset, e.g. the arena-suspend
     * guard raised inside the scope — must not leave the arena active: (1) its
     * error dict / result below outlive the task and cross to the joiner, so
     * they must be heap, not arena (a later arena_reset would dangle them); and
     * (2) the next task must start from a clean arena baseline. The suspend
     * guard guarantees a task never *yields* with the arena active, so the only
     * way it's active here is an ending task that leaked the scope. */
    g_arena.active = 0;
    if (g_has_error) {
        t->has_error = 1;
        t->error_value = vm_take_error_value();  /* the {kind,message,line} dict */
        g_has_error = 0;
        /* #493: a worker that dies of an uncaught error must fail the process
         * if nothing ever joins it. Main (task 0) already propagates its own
         * error via the trampoline's return, so only mark workers here; a
         * later task_join on this task clears the flag. */
        if (t->id != 0) t->err_unobserved = 1;
        if (r) val_decref(r);
        t->result = NULL;
    } else {
        t->result = r ? val_clone_for_send(r) : NULL;   /* share-nothing result */
        if (r) val_decref(r);
    }
    t->state = t->has_error ? TASK_DEAD : TASK_DONE;
    if (t->id != 0) s->live--;
    if (t->run_env) { env_decref(t->run_env); t->run_env = NULL; }
    /* Wake every task blocked on this one: enqueue it; on resume the join
     * builtin's placeholder gets overwritten with our result (or re-raise). */
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        Task *w = (Task *)handle_lookup(i, HANDLE_TASK);
        if (w && w->state == TASK_SUSPENDED && w->join_target == t->id)
            sched_ready_push(s, w->id);
    }
    if (s->main_task.state == TASK_SUSPENDED && s->main_task.join_target == t->id)
        sched_ready_push(s, 0);
    /* #530: a detached task's outcome is nobody's to consume — reap the slot
     * now so task-per-message workloads aren't bounded by lifetime spawns.
     * An uncaught death still fails the process: the #493 flag moves to the
     * scheduler counter before the slot frees (the trace already printed). */
    if (t->id != 0 && t->detached) {
        if (t->err_unobserved) s->detached_err_count++;
        task_reap(t);
    }
}

/* On resuming a task that was blocked in task_join, replace the placeholder
 * null the builtin left on the stack top with the joinee's result — or, if
 * the joinee died, re-raise its error in the joiner. Called from vm_run_ex's
 * resume path (after the stack is restored). */
static void task_apply_join_result(Task *t) {
    TaskScheduler *s = sched_get();
    if (!s || t->join_target == 0) return;
    Task *jt = sched_lookup(s, t->join_target);
    t->join_target = 0;
    if (!jt) return;
    if (jt->has_error) {
        jt->err_unobserved = 0;   /* #493: observed by this join (caught or not) */
        /* Re-raise: restore the error payload so the joiner's CHECK_ERROR
         * catches/propagates it as if the throw happened at the join. */
        if (jt->error_value) {
            g_error_value = jt->error_value;
            val_incref(g_error_value);
            g_error_kind = (int)EK_USER;
        }
        snprintf(g_error_msg, sizeof(g_error_msg), "joined task %d failed", jt->id);
        g_has_error = 1;
        return;
    }
    /* Overwrite TOS placeholder with the joinee's (already deep-copied) result. */
    if (g_vm.sp > 0) {
        slot_decref(g_vm.stack[g_vm.sp - 1]);
        Value *res = jt->result ? jt->result : make_null();
        val_incref(res);
        g_vm.stack[g_vm.sp - 1] = slot_from_heap(res);
    }
}

/* The trampoline. Entered from the outermost vm_execute once main (task 0)
 * has first suspended. Drives tasks round-robin until the ready queue drains,
 * then returns main's result. All-tasks-blocked = deadlock (loud, not a hang).
 * Task 0 finishing kills outstanding tasks (kill-outstanding ruling). */
static Value *scheduler_trampoline(TaskScheduler *s) {
    for (;;) {
        int id = sched_ready_pop(s);
        if (id < 0) {
            /* Nothing runnable now. Sleepers waiting on the virtual clock are
             * not a deadlock — advance time to the earliest wake and retry
             * before deciding anything is stuck. */
            if (sched_wake_sleepers(s)) continue;
            /* Genuinely nothing runnable. If main already finished, we're done.
             * If tasks remain live (blocked on joins that can't resolve), that's
             * a deadlock — raise it loudly rather than hang. */
            if (s->main_task.state == TASK_DONE || s->main_task.state == TASK_DEAD) {
                if (s->main_task.has_error) {
                    g_error_value = s->main_task.error_value;
                    s->main_task.error_value = NULL;
                    g_has_error = 1;
                    return make_null();
                }
                Value *r = s->main_task.result;
                s->main_task.result = NULL;
                return r ? r : make_null();
            }
            /* #509: deadlock is a normal runtime error, not a hang — make it
             * CATCHABLE. main is guaranteed SUSPENDED here (the DONE/DEAD case
             * returned above), blocked at a task_join/recv. Build the structured
             * error at main's blocked line (vm_take_error_value later lazily
             * turns g_error_kind/raw/line into a {kind,message,line} dict, so
             * e.kind == "deadlock"). We drive the print/handling ourselves and
             * do NOT go through rt_error's g_try_depth-gated print: g_try_depth
             * is a global, not part of a task's saved slice, so a suspended
             * worker's still-open try can leave it non-zero here. */
            Task *m = &s->main_task;
            int catchable = 0;
            for (int i = 0; i < m->saved_frame_count; i++)
                if (m->saved_frames[i].try_count > 0) { catchable = 1; break; }
            g_error_kind = (int)EK_DEADLOCK;
            g_error_line = m->saved_current_line;
            snprintf(g_error_raw, sizeof(g_error_raw),
                     "all tasks are blocked — deadlock");
            snprintf(g_error_msg, sizeof(g_error_msg),
                     "Error line %d: all tasks are blocked — deadlock", g_error_line);
            g_has_error = 1;
            eigs_clear_error_value();
            if (catchable) {
                /* Deliver at main's blocked site: clear the block reason so the
                 * resume doesn't fill a normal join/recv result, then re-enqueue
                 * main. The loop resumes it with g_has_error set → CHECK_ERROR
                 * unwinds to the handler (which reads e.kind == "deadlock"). */
                m->join_target = 0;
                m->recv_blocked = 0;
                m->sleeping = 0;
                sched_ready_push(s, 0);
                continue;
            }
            /* No handler in main → terminal: print loudly, exit non-zero. (No
             * stack trace: between tasks g_vm has no live frames.) */
            fprintf(stderr, "%s\n", g_error_msg);
            return make_null();
        }
        Task *t = sched_lookup(s, id);
        if (!t || t->state == TASK_DONE || t->state == TASK_DEAD) continue;
        s->current = id;

        Value *r;
        if (t->state == TASK_SUSPENDED) {
            /* Resume (the join placeholder, if any, is filled inside the
             * resume path via task_apply_join_result). */
            r = vm_run_ex(NULL, NULL, t);
        } else {
            r = task_start(t);   /* never-run task: bind args + run at base 0 */
        }

        if (t->state == TASK_SUSPENDED) {
            /* It suspended again. task_yield → re-enqueue; task_join → stay
             * blocked (woken by sched_finish); task_recv on an empty mailbox →
             * stay blocked (woken by task_deliver); task_sleep → stay blocked
             * (woken by sched_wake_sleepers when the clock reaches wake_at). */
            if (t->join_target == 0 && !t->recv_blocked && !t->sleeping)
                sched_ready_push(s, id);
        } else {
            sched_finish(s, t, r);
            /* kill-outstanding: main ending tears the rest down deterministically. */
            if (id == 0) break;
        }
    }
    /* main finished with tasks still outstanding → reap them (kill-outstanding). */
    if (s->main_task.has_error) {
        g_error_value = s->main_task.error_value;
        s->main_task.error_value = NULL;
        g_has_error = 1;
        return make_null();
    }
    Value *r = s->main_task.result;
    s->main_task.result = NULL;
    return r ? r : make_null();
}

Value *vm_execute(EigsChunk *chunk, Env *env) {
    vm_init();
    /* Only the OUTERMOST vm_execute drives the scheduler; a nested call
     * (eval/dispatch/import/comparator) runs to completion on the C stack and
     * may not suspend (enforced at CASE(CALL) via base_frame). frame_count==0
     * identifies the outermost. */
    int outermost = (g_vm.frame_count == 0);
    Value *r = vm_run(chunk, env);
    if (!outermost) return r;
    TaskScheduler *s = sched_get();
    if (!s || !s->active) return r;
    /* main (task 0) either finished (no task ever blocked) or suspended. If it
     * suspended, its slice is saved; drive the trampoline. If it finished but
     * tasks are still live, drive them too (kill-outstanding at main's end). */
    if (s->main_task.state == TASK_SUSPENDED) {
        /* main's first suspension happened in the initial vm_run, outside the
         * trampoline — enqueue it now so it resumes round-robin, UNLESS it
         * blocked on a join (sched_finish wakes it), a recv (task_deliver
         * wakes it), or a sleep (sched_wake_sleepers wakes it). Mirrors the
         * trampoline's re-enqueue guard. */
        if (s->main_task.join_target == 0 && !s->main_task.recv_blocked &&
            !s->main_task.sleeping)
            sched_ready_push(s, 0);
        return scheduler_trampoline(s);
    }
    /* main ran to completion without ever suspending. Record its result and,
     * if any spawned task is still runnable, drive them (kill-outstanding). */
    if (s->live > 0 && s->rcount > 0) {
        s->main_task.state = TASK_DONE;
        s->main_task.result = r ? val_clone_for_send(r) : NULL;
        if (r) val_decref(r);
        Value *mr = scheduler_trampoline(s);
        return mr;
    }
    return r;
}
