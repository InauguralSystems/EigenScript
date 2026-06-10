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

/* ---- Thread-local VM instance ---- */
static __thread VM g_vm;
static __thread int g_vm_init = 0;

/* ---- Loop stall detection state ---- */
static __thread int g_loop_stall_count = 0;
static __thread int g_loop_iterations = 0;
static __thread const char *g_loop_exit_reason = "normal";

/* ---- External globals from eval.c / eigenscript.c ---- */
extern __thread Value *g_return_val;
extern __thread int g_returning;
extern __thread int g_breaking;
extern __thread int g_continuing;
extern __thread char g_error_msg[4096];
extern __thread int g_has_error;
extern __thread int g_try_depth;
extern __thread int g_unobserved_depth;
extern __thread Value *g_last_observer;
extern __thread Env *g_builtin_call_env;
extern __thread double g_obs_dh_zero;
extern __thread double g_obs_dh_small;
extern __thread double g_obs_h_low;

/* ---- Helpers from eigenscript.c ---- */
extern void val_incref(Value *v);
extern void val_decref(Value *v);
extern Value* make_num(double n);
extern Value* make_str(const char *s);
extern Value* make_null(void);
extern Value* make_list(int cap);
extern Value* make_dict(int cap);
extern Value* make_fn(const char *name, char **params, int param_count,
                       ASTNode **body, int body_count, Env *closure);
extern Value* make_builtin(Value* (*fn)(Value*));
extern void list_append(Value *list, Value *item);
extern void dict_set(Value *dict, const char *key, Value *val);
extern Value* dict_get(Value *dict, const char *key);
extern Env* env_new(Env *parent);
extern void env_free(Env *env);
extern void env_reserve_slots(Env *env, int total);
extern void env_set_local(Env *env, const char *name, Value *val);
extern void env_set_hashed(Env *env, const char *name, uint32_t h, Value *val);
extern void env_set_local_hashed(Env *env, const char *name, uint32_t h, Value *val);
extern Value* env_get_hashed(Env *env, const char *name, uint32_t h);
extern Value* env_get(Env *env, const char *name);
extern void runtime_error(int line, const char *fmt, ...);
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

/* ---- Dict field inline cache ---- */
#define DICT_CACHE_SIZE 128
#define DICT_CACHE_MASK (DICT_CACHE_SIZE - 1)

typedef struct {
    Value   *dict;      /* dict identity (pointer) */
    uint32_t hash;      /* field name hash */
    int      index;     /* slot index in dict arrays */
} DictCacheEntry;

static __thread DictCacheEntry g_dict_cache[DICT_CACHE_SIZE];

static inline Value *dict_get_cached(Value *dict, const char *key, uint32_t h) {
    int ci = (h ^ (uint32_t)(uintptr_t)dict) & DICT_CACHE_MASK;
    DictCacheEntry *ce = &g_dict_cache[ci];
    if (ce->dict == dict && ce->hash == h && ce->index < dict->data.dict.count) {
        const char *stored = dict->data.dict.keys[ce->index];
        if (stored == key || strcmp(stored, key) == 0)
            return dict->data.dict.vals[ce->index];
    }
    int idx = env_hash_find_dict(dict, key, h);
    if (idx >= 0) {
        ce->dict = dict; ce->hash = h; ce->index = idx;
        return dict->data.dict.vals[idx];
    }
    return NULL;
}

static inline void dict_set_cached(Value *dict, const char *key, uint32_t h, Value *val) {
    int ci = (h ^ (uint32_t)(uintptr_t)dict) & DICT_CACHE_MASK;
    DictCacheEntry *ce = &g_dict_cache[ci];
    if (ce->dict == dict && ce->hash == h && ce->index < dict->data.dict.count) {
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
    int ci = (h ^ (uint32_t)(uintptr_t)dict) & DICT_CACHE_MASK;
    DictCacheEntry *ce = &g_dict_cache[ci];
    if (ce->dict == dict && ce->hash == h && ce->index < dict->data.dict.count) {
        const char *stored = dict->data.dict.keys[ce->index];
        if (stored == key || strcmp(stored, key) == 0) {
            Value *existing = dict->data.dict.vals[ce->index];
            if (existing && existing->type == VAL_NUM &&
                existing->refcount == 1 && existing->obs_age == 0 &&
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
    if (!g_vm_init) {
        memset(&g_vm, 0, sizeof(g_vm));
        g_vm_init = 1;
    }
}

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
    if (v->type == VAL_NULL) return slot_null();
    if (v->type == VAL_NUM && v->obs_age > 0) return slot_from_tracked(v);
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
        runtime_error(0, "VM stack overflow");
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
        runtime_error(0, "VM stack overflow");
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
    Value *state = make_list(2);
    list_append(state, iterable);
    Value *idx = make_num(0);
    list_append(state, idx);
    val_decref(idx);
    return state;
}

/* ---- JIT inline-emit layout (Stage 3b) ----
 *
 * vm.c owns g_vm (static __thread), so it is the only TU that can
 * compute the TLS @tpoff for it. The JIT emitter reads this layout
 * once per process and uses it to emit native loads/stores against
 * g_vm fields without indirection through helper functions. */
#include <stddef.h>

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
        runtime_error(g_vm.current_line, "undefined variable '%s'", name);
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
                runtime_error(g_vm.current_line,
                    "buffer index %d out of range (length %d)",
                    i, target->data.buffer.count);
                vm_push_slot(slot_null());
            }
            return;
        }
        if (target->type == VAL_LIST) {
            if (i < target->data.list.count) {
                Value *item = target->data.list.items[i];
                if (item && item->type == VAL_NUM && item->obs_age == 0) {
                    vm_push_slot(slot_from_num(item->data.num));
                } else {
                    val_incref(item);
                    vm_push(item);
                }
            } else {
                runtime_error(g_vm.current_line,
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
                runtime_error(g_vm.current_line,
                    "string index %d out of range (length %d)",
                    i, len);
                vm_push_slot(slot_null());
            }
            return;
        }
        if (target->type != VAL_NULL) {
            runtime_error(g_vm.current_line,
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
            if (v->type == VAL_NUM && v->obs_age == 0) {
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
        runtime_error(g_vm.current_line,
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
                    if (v->type == VAL_NUM && v->obs_age == 0) {
                        vm_push_slot(slot_from_num(v->data.num));
                    } else {
                        val_incref(v);
                        vm_push(v);
                    }
                    return;
                }
            } else if (dict && dict->type != VAL_NULL) {
                const char *key = chunk->const_interns[name_idx];
                runtime_error(g_vm.current_line,
                    "cannot access field '%s' on %s",
                    key, val_type_name(dict->type));
            }
        } else {
            runtime_error(g_vm.current_line,
                "index %d out of range (list length %d)",
                i, target->data.list.count);
        }
    } else if (target && target->type != VAL_NULL) {
        runtime_error(g_vm.current_line,
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
            if (v->type == VAL_NUM && v->obs_age == 0) {
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
        runtime_error(g_vm.current_line,
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
        runtime_error(g_vm.current_line, "cannot set field '%s' on %s",
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
    if (g_unobserved_depth != 0) return;
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    EigsSlot s = g_vm.stack[g_vm.sp - 1];
    Value *v = NULL;
    if (slot_is_num(s)) {
        v = make_tracked_num(s.d);
        g_vm.stack[g_vm.sp - 1] = slot_from_tracked(v);
    } else if (slot_is_ptr(s)) {
        v = slot_as_ptr(s);
    }
    if (v) {
        const char *name = chunk->const_interns[name_idx];
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) {
            h = env_hash_name(name);
            if (chunk->const_hashes) chunk->const_hashes[name_idx] = h;
        }
        Value *prev = env_get_hashed(frame->env, name, h);
        if (prev && prev != v) {
            observer_ensure_fresh(prev);
            v->last_entropy = prev->last_entropy;
            v->entropy = prev->entropy;
            v->obs_age = prev->obs_age;
            v->dH = prev->dH;
            v->prev_dH = prev->prev_dH;
        }
        v->dirty = 1;
        g_last_observer = v;
    }
}

void jit_helper_observe_assign_local(int slot) {
    if (g_unobserved_depth != 0) return;
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    EigsSlot s = g_vm.stack[g_vm.sp - 1];
    Value *v = NULL;
    if (slot_is_num(s)) {
        v = make_tracked_num(s.d);
        g_vm.stack[g_vm.sp - 1] = slot_from_tracked(v);
    } else if (slot_is_ptr(s)) {
        v = slot_as_ptr(s);
    }
    if (v) {
        Env *e = frame->fn_env;
        Value *prev = NULL;
        if (e && slot < e->count) {
            EigsSlot ps = e->values[slot];
            if (slot_is_ptr(ps)) prev = slot_as_ptr(ps);
        }
        if (prev && prev != v) {
            observer_ensure_fresh(prev);
            v->last_entropy = prev->last_entropy;
            v->entropy = prev->entropy;
            v->obs_age = prev->obs_age;
            v->dH = prev->dH;
            v->prev_dH = prev->prev_dH;
        }
        v->dirty = 1;
        g_last_observer = v;
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
    if (idx_v->type == VAL_NUM && idx_v->refcount == 1 && !idx_v->arena &&
        idx_v->obs_age == 0) {
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
int jit_helper_loop_stall_check(void) {
    g_loop_iterations++;
    int should_exit = 0;
    if (g_unobserved_depth == 0) {
        Value *obs = g_last_observer;
        if (obs) observer_ensure_fresh(obs);
        if (obs && fabs(obs->dH) < g_obs_dh_zero && obs->entropy >= g_obs_h_low) {
            g_loop_stall_count++;
            if (g_loop_stall_count >= 100) {
                g_loop_exit_reason = "stalled";
                should_exit = 1;
            }
        } else {
            g_loop_stall_count = 0;
        }
    }
    if (g_loop_iterations >= 100000000) {
        g_loop_exit_reason = "limit";
        should_exit = 1;
    }
    CallFrame *frame = &g_vm.frames[g_vm.frame_count - 1];
    loop_iter_store(frame->env, (double)g_loop_iterations);
    if (should_exit) {
        Value *exit_val = make_str(g_loop_exit_reason);
        env_set_local(frame->env, "__loop_exit__", exit_val);
        val_decref(exit_val);
        g_loop_stall_count = 0;
        g_loop_iterations = 0;
        g_loop_exit_reason = "normal";
        return 1;
    }
    return 0;
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
            if (_ok && i >= 0 && i < target->data.buffer.count) {
                target->data.buffer.data[i] = (int)val_s.d;
            } else {
                if (!_ok) runtime_error(g_vm.current_line, "index must be an integer, got %g", idx_s.d);
                else runtime_error(g_vm.current_line, "buffer index %d out of range (length %d)",
                              i, target->data.buffer.count);
            }
            g_vm.sp -= 2;  /* keep val on TOS */
            g_vm.stack[g_vm.sp - 1] = val_s;
            slot_decref(idx_s);
            slot_decref(tgt_s);
            return;
        }
        if (target->type == VAL_LIST && slot_is_num(val_s)) {
            if (_ok && i >= 0 && i < target->data.list.count) {
                Value *existing = target->data.list.items[i];
                if (existing && existing->type == VAL_NUM &&
                    existing->refcount == 1 && existing->obs_age == 0 &&
                    !existing->arena) {
                    existing->data.num = val_s.d;
                } else {
                    val_decref(existing);
                    target->data.list.items[i] = make_num(val_s.d);
                }
            } else {
                if (!_ok) runtime_error(g_vm.current_line, "index must be an integer, got %g", idx_s.d);
                else runtime_error(g_vm.current_line, "index %d out of range (list length %d)",
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
            runtime_error(g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        } else if (i >= 0 && i < target->data.list.count) {
            val_incref(val);
            val_decref(target->data.list.items[i]);
            target->data.list.items[i] = val;
        } else {
            runtime_error(g_vm.current_line, "index %d out of range (list length %d)", i, target->data.list.count);
        }
    } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
        int i;
        if (!vm_index_is_int(idx->data.num, &i)) {
            runtime_error(g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        } else if (i >= 0 && i < target->data.buffer.count && val->type == VAL_NUM)
            target->data.buffer.data[i] = (int)val->data.num;
        else if (i < 0 || i >= target->data.buffer.count)
            runtime_error(g_vm.current_line, "buffer index %d out of range (length %d)", i, target->data.buffer.count);
    } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
        dict_set(target, idx->data.str, val);
    } else if (target->type != VAL_NULL) {
        runtime_error(g_vm.current_line, "cannot index %s for assignment", val_type_name(target->type));
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
            if (_ok && i >= 0 && i < target->data.list.count) {
                Value *r = target->data.list.items[i];
                if (r && r->type == VAL_NUM && r->obs_age == 0) {
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
                if (!_ok) runtime_error(g_vm.current_line, "index must be an integer, got %g", idx_s.d);
                else runtime_error(g_vm.current_line,
                    "index %d out of range (list length %d)",
                    i, target->data.list.count);
                slot_decref(tgt_s);
                vm_push_slot(slot_null());
            }
            return;
        }
        if (target->type == VAL_BUFFER) {
            if (_ok && i >= 0 && i < target->data.buffer.count) {
                double v = target->data.buffer.data[i];
                slot_decref(tgt_s);
                vm_push_slot(slot_from_num(v));
            } else {
                if (!_ok) runtime_error(g_vm.current_line, "index must be an integer, got %g", idx_s.d);
                else runtime_error(g_vm.current_line,
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
            runtime_error(g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        } else if (i >= 0 && i < target->data.list.count) {
            result = target->data.list.items[i];
            val_incref(result);
        } else {
            runtime_error(g_vm.current_line,
                "index %d out of range (list length %d)",
                i, target->data.list.count);
        }
    } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
        Value *v = dict_get(target, idx->data.str);
        if (v) { result = v; val_incref(result); }
    } else if (target->type == VAL_STR && idx->type == VAL_NUM) {
        int i;
        if (!vm_index_is_int(idx->data.num, &i)) {
            runtime_error(g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        } else if (i >= 0 && i < (int)strlen(target->data.str)) {
            char buf[2] = { target->data.str[i], 0 };
            result = make_str(buf);
        } else {
            runtime_error(g_vm.current_line,
                "string index %d out of range (length %d)",
                i, (int)strlen(target->data.str));
        }
    } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
        int i;
        if (!vm_index_is_int(idx->data.num, &i))
            runtime_error(g_vm.current_line, "index must be an integer, got %g", idx->data.num);
        else if (i >= 0 && i < target->data.buffer.count)
            result = make_num(target->data.buffer.data[i]);
        else
            runtime_error(g_vm.current_line,
                "buffer index %d out of range (length %d)",
                i, target->data.buffer.count);
    } else if (target->type != VAL_NULL) {
        runtime_error(g_vm.current_line,
            "cannot index %s", val_type_name(target->type));
    }
    val_decref(target); val_decref(idx);
    vm_push(result);
}

/* JIT Stage 4r: out-of-line helper for OP_CALL — builtin-only fast path.
 *
 * Mirrors the VAL_BUILTIN branch of CASE(CALL) (vm.c around line 1587).
 * Returns:
 *   0 — builtin called, args+fn consumed from g_vm.stack, result pushed.
 *       g_has_error may be set if the builtin failed; the caller's
 *       subsequent dispatch handles it (CHECK_ERROR / try-catch). State
 *       on the stack is still consistent (vm_push(result) ran with
 *       result = make_null() on failure).
 *   1 — fn at g_vm.stack[sp-1-argc] is not a builtin, or sp underflow.
 *       Helper has NOT touched the stack; caller should bail to the
 *       interpreter so it re-executes OP_CALL with full semantics.
 *
 * Helper reads and writes g_vm.sp directly; the JIT emitter syncs
 * %ecx → g_vm.sp before the call and reloads after. */
int jit_helper_call(int argc) {
    if (g_vm.sp < argc + 1) return 1;
    Value *fn_val = STK_AS_VAL(g_vm.sp - 1 - argc);
    if (fn_val->type != VAL_BUILTIN) return 1;

    Value *arg;
    if (argc == 1) {
        arg = STK_AS_VAL(g_vm.sp - 1);
        val_incref(arg);
    } else {
        arg = make_list(argc);
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
        /* Direct-borrow heuristic — see CASE(CALL) for rationale and the
         * !consumes_arg guard (free_val may have already freed arg). */
        if (arg && arg->type == VAL_LIST) {
            int n = arg->data.list.count;
            Value **items = arg->data.list.items;
            for (int i = 0; i < n; i++) {
                if (items[i] == result) { val_incref(result); break; }
            }
        }
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
    if (frame->owns_env) env_free(frame->env);
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
    if (frame->owns_env) env_free(frame->env);
    g_loop_stall_count = frame->saved_stall_count;
    g_loop_iterations  = frame->saved_loop_iter;
    /* Chunk ref deferred to vm_run's -1 handler (see jit_helper_return). */
    g_vm.frame_count--;
    g_vm.stack[g_vm.sp++] = slot_null();
}

void eigs_jit_get_layout(EigsJitLayout *out) {
#if defined(__x86_64__)
    /* The %fs:0 read materializes the thread pointer so the JIT can encode
     * TLS-relative offsets to g_vm/g_unobserved_depth. Only used on x86-64;
     * on other arches the JIT codegen path is compiled out entirely
     * (see `#if defined(__x86_64__)` in jit.c), so this function exists
     * only to satisfy the link — body collapses to a zero-fill. */
    void *tp;
    __asm__ __volatile__("mov %%fs:0, %0" : "=r"(tp));
    out->g_vm_tpoff               = (long)((char *)&g_vm - (char *)tp);
    out->g_unobserved_depth_tpoff = (long)((char *)&g_unobserved_depth - (char *)tp);
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
    out->g_dict_cache_tpoff  = (long)((char *)&g_dict_cache[0] - (char *)tp);
    out->sizeof_dcache_entry = (int)sizeof(DictCacheEntry);
    out->off_dcache_dict     = (int)offsetof(DictCacheEntry, dict);
    out->off_dcache_hash     = (int)offsetof(DictCacheEntry, hash);
    out->off_dcache_index    = (int)offsetof(DictCacheEntry, index);
    out->dcache_mask         = DICT_CACHE_MASK;
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

static Value *vm_run(EigsChunk *chunk, Env *env) {
    int base_frame = g_vm.frame_count; /* track entry point for re-entrant returns */
    /* Module-level slot promotion (Part B) AND nested entries from builtins
     * (e.g. call_eigs_fn, eval): if the chunk allocated slots past env->count
     * at compile time, reserve them now so OP_SET_LOCAL has a place to write.
     * Slot indices in bytecode are absolute env positions. */
    if (chunk->local_count > env->count) {
        env_reserve_slots(env, chunk->local_count);
    }
    CallFrame *frame = &g_vm.frames[g_vm.frame_count++];
    frame->chunk = chunk;
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
    chunk->exec_count++;
    jit_register_chunk(chunk);

    uint8_t *ip = frame->ip;
    int current_line = 0;

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
        [OP_BREAK] = &&lbl_BREAK, [OP_CONTINUE] = &&lbl_CONTINUE,
        [OP_TRY_BEGIN] = &&lbl_TRY_BEGIN, [OP_TRY_END] = &&lbl_TRY_END,
        [OP_OBSERVE_ASSIGN] = &&lbl_OBSERVE_ASSIGN,
        [OP_OBSERVE_ASSIGN_LOCAL] = &&lbl_OBSERVE_ASSIGN_LOCAL,
        [OP_INTERROGATE] = &&lbl_INTERROGATE, [OP_PREDICATE] = &&lbl_PREDICATE,
        [OP_UNOBSERVED_BEGIN] = &&lbl_UNOBSERVED_BEGIN,
        [OP_UNOBSERVED_END] = &&lbl_UNOBSERVED_END,
        [OP_LOOP_STALL_CHECK] = &&lbl_LOOP_STALL_CHECK,
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
    };
    #define CHECK_ERROR() do { \
        if (__builtin_expect(g_has_error, 0)) { \
            if (frame->try_count > 0) { \
                g_has_error = 0; \
                g_try_depth--; \
                frame->try_count--; \
                uint8_t *_catch_ip = frame->try_handlers[frame->try_count].catch_ip; \
                int _catch_bp = frame->try_handlers[frame->try_count].catch_bp; \
                frame->is_try = (frame->try_count > 0); \
                while (g_vm.sp > _catch_bp) val_decref(vm_pop()); \
                vm_push(make_str(g_error_msg)); \
                ip = _catch_ip; \
            } else if (!vm_handler_in_range(base_frame)) { \
                /* Uncaught: no try anywhere in this vm_run's frames. Stop \
                 * the dispatch loop instead of continuing with null (which \
                 * cascades — see stack-overflow). g_has_error stays set so \
                 * a re-entrant caller, or main, sees the failure. */ \
                goto vm_error_halt; \
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

    DISPATCH();

    /* ---- Constants ---- */

    CASE(CONST): {
        uint16_t idx = read_u16(ip); ip += 2;
        Value *v = chunk->constants[idx];
        /* Numeric constants without observer state ship as immediates —
         * skips an incref/decref pair on every push/pop. */
        if (v->type == VAL_NUM && v->obs_age == 0) {
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
            char *s = malloc(la + lb + 1);
            memcpy(s, a->data.str, la);
            memcpy(s + la, b->data.str, lb);
            s[la + lb] = 0;
            Value *r = make_str(s);
            free(s);
            vm_push(r);
        } else {
            /* Strict: + adds two numbers or concatenates two strings; it does
             * not coerce across types ("3" + 4 was a footgun). For mixed
             * concatenation use an f-string — f"{a}{b}" — or str of. */
            const char *ta = val_type_name(a->type), *tb = val_type_name(b->type);
            if ((a->type == VAL_STR) != (b->type == VAL_STR))
                runtime_error(current_line,
                    "cannot apply '+' to %s and %s (use an f-string or 'str of' to concatenate)",
                    ta, tb);
            else
                runtime_error(current_line, "cannot apply '+' to %s and %s", ta, tb);
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
            runtime_error(current_line, "cannot apply '%s' to %s and %s", \
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
            runtime_error(current_line, "cannot apply '/' to %s and %s",
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
                runtime_error(current_line, "cannot apply '%%' to %s and %s",
                    val_type_name(a->type), val_type_name(b->type));
            vm_push(make_num(0));
        }
        val_decref(a); val_decref(b);
        DISPATCH();
    }

#define INT_BINOP(NAME, OP, OPNAME) \
    CASE(NAME): { \
        EigsSlot _bs = g_vm.stack[g_vm.sp - 1]; \
        EigsSlot _as = g_vm.stack[g_vm.sp - 2]; \
        double _ad, _bd; \
        if (__builtin_expect(slot_as_double(_as, &_ad) & slot_as_double(_bs, &_bd), 1)) { \
            double _r = (double)((int64_t)_ad OP (int64_t)_bd); \
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
            runtime_error(current_line, "cannot apply '%s' to %s and %s", \
                OPNAME, _tna, _tnb); \
        } \
        g_vm.stack[g_vm.sp - 2] = slot_from_num(0.0); \
        g_vm.sp--; \
        DISPATCH(); \
    }

    INT_BINOP(BAND, &, "&")
    INT_BINOP(BOR, |, "|")
    INT_BINOP(BXOR, ^, "^")
    INT_BINOP(SHL, <<, "<<")
    INT_BINOP(SHR, >>, ">>")

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
        runtime_error(current_line, "cannot negate non-numeric");
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
            runtime_error(current_line, "cannot apply '~' to %s", _tn);
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
            runtime_error(current_line, "cannot compare %s and %s with '%s'", \
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
                if (slot_is_heap(ex_s) || slot_is_tracked(ex_s)) {
                    Value *existing = slot_as_ptr(ex_s);
                    if (existing && existing->type == VAL_NUM &&
                        existing->refcount == 1 &&
                        existing->obs_age == 0 && !existing->arena) {
                        existing->data.num = tos.d;
                        DISPATCH();
                    }
                }
            }
            slot_incref(tos);
            slot_decref(e->values[slot]);
            e->values[slot] = tos;
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
            runtime_error(current_line, "undefined variable '%s'", name);
            vm_push_slot(slot_null());
            DISPATCH();
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
            if (depth <= 1) {
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
        if (t2 == start) {
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
        if (target == start) {
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
        if (resolved == target) {
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
        /* Hotness signal: this is the back-edge of every while/for body.
         * Tracking iterations here lets jit_try_compile_chunk gate on
         * "chunk that loops a lot" in addition to "chunk that's called
         * a lot." Wraparound is benign — at threshold-trip granularity
         * the chunk gets JIT'd either way. */
        chunk->back_edge_count++;

        /* OSR trigger. For "called once, loops a lot" chunks (the gauntlet
         * top-level being the motivating case) exec_count stays at 1, so
         * the from-zero JIT gate never fires. Once back_edge_count crosses
         * the OSR threshold we attempt a compile starting at the current
         * loop header (the post-jump-back ip). If a thunk is ready and its
         * recorded entry offset matches our current ip, we hand off into
         * native: sync ip → frame->ip, run, then re-import the advance.
         *
         * Phase 4: the trigger only fires when jit_osr_state == 0. After
         * the first compile attempt the state pins to 1 (failed) or 2
         * (success) and the gate is closed forever for this chunk — so
         * a failed OSR cannot retry-storm on every back-edge, and a
         * successful OSR cannot be displaced by a colder loop entry.
         * The threshold default (5000) is set high enough that the
         * chunk-wide back_edge_count favors the actual hot loop over
         * any short setup loop preceding it. */
        static int s_osr_threshold = 0;
        if (s_osr_threshold == 0) s_osr_threshold = eigs_jit_get_osr_threshold();
        if (chunk->jit_osr_state == 0 &&
            chunk->back_edge_count >= (uint32_t)s_osr_threshold) {
            int target_offset = (int)(ip - chunk->code);
            jit_try_compile_chunk_osr(chunk, target_offset);
        }
        if (chunk->jit_osr_state == 2 && chunk->jit_osr_code &&
            chunk->jit_osr_entry_offset == (int)(ip - chunk->code)) {
            frame->ip = ip;
            ((JitChunkFn)chunk->jit_osr_code)();
            if (chunk->jit_osr_advance == -1) {
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
            frame->ip += chunk->jit_osr_advance;
            ip = frame->ip;
            current_line = g_vm.current_line;
        }
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
        /* Mark env as captured so it survives after this frame returns */
        frame->env->captured = 1;
        if (__builtin_expect(g_vm_multithreaded, 0))
            __atomic_add_fetch(&frame->env->env_refcount, 1, __ATOMIC_RELAXED);
        else
            frame->env->env_refcount++;
        Value *fn = make_fn(fn_chunk->name, params, fn_chunk->param_count,
                            NULL, 0, frame->env);
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
                arg = make_list(argc);
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
                /* Direct-borrow heuristic: if result is one of arg's
                 * top-level items (e.g., coalesce/append/dict_set return
                 * arg->data.list.items[0]), incref it so it survives the
                 * arg-decref below. Builtins returning a fresh allocation
                 * (range, make_*) do not match this scan, so no spurious
                 * +1 ref is added. Nested borrows (get_at: items[0][idx])
                 * must still incref locally — only direct children are
                 * scanned here.
                 *
                 * Guarded by !consumes_arg: a consuming builtin like
                 * free_val may have already freed arg, so reading arg
                 * here would be a use-after-free. */
                if (arg && arg->type == VAL_LIST) {
                    int n = arg->data.list.count;
                    Value **items = arg->data.list.items;
                    for (int i = 0; i < n; i++) {
                        if (items[i] == result) { val_incref(result); break; }
                    }
                }
            }
            if (!consumes_arg && result != arg) val_decref(arg);
            /* If result == arg, the arg's refcount transfers to the result */
            vm_push(result);

            /* Check for errors from builtins */
            CHECK_ERROR();
            DISPATCH();
        }

        if (fn_val->type == VAL_FN && fn_val->data.fn.body_count == -1) {
            /* Bytecode function — non-recursive call.
             * Push new frame and continue dispatch loop. */
            EigsChunk *fn_chunk = (EigsChunk *)fn_val->data.fn.body;
            Env *call_env = env_new(fn_val->data.fn.closure);

            int param_count = fn_val->data.fn.param_count;
            uint32_t *phashes = fn_val->data.fn.param_hashes;
            if (param_count > 1 && argc > 0) {
                int bound = param_count < (int)argc ? param_count : (int)argc;
                for (int i = 0; i < bound; i++) {
                    uint32_t ph = phashes ? phashes[i] : env_hash_name(fn_val->data.fn.params[i]);
                    env_bind_fresh_param_slot(call_env,
                        fn_val->data.fn.params[i], ph,
                        g_vm.stack[g_vm.sp - argc + i]);
                }
            } else if (param_count == 1) {
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

            /* Pre-allocate slots for non-captured locals (compiler-assigned slots
             * beyond param_count). OP_SET_LOCAL writes directly into these. */
            if (fn_chunk->local_count > param_count)
                env_reserve_slots(call_env, fn_chunk->local_count);

            /* Pop args + fn from stack (slot-direct; immediates never
             * round-trip through make_num + free_value). */
            for (int i = 0; i < argc; i++)
                slot_decref(g_vm.stack[--g_vm.sp]);
            slot_decref(g_vm.stack[--g_vm.sp]);

            /* Save current frame and push new one */
            frame->ip = ip;
            if (g_vm.frame_count >= VM_FRAMES_MAX) {
                runtime_error(current_line, "call stack overflow");
                env_free(call_env);
                vm_push(make_null());
                DISPATCH();
            }
            frame = &g_vm.frames[g_vm.frame_count++];
            frame->chunk = fn_chunk;
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
            g_loop_stall_count = 0;
            g_loop_iterations  = 0;
            fn_chunk->exec_count++;

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
            if (fn_chunk->jit_state == 0) jit_try_compile_chunk(fn_chunk);
            if (fn_chunk->jit_code) {
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
        runtime_error(current_line, "cannot call %s", val_type_name(fn_val->type));
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
        if (frame->owns_env) env_free(frame->env);
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
        if (frame->owns_env) env_free(frame->env);
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
            Value *k = STK_AS_VAL(base + i * 2);
            Value *v = STK_AS_VAL(base + i * 2 + 1);
            if (k->type != VAL_STR) {
                runtime_error(current_line, "dict key must be a string, got %s", val_type_name(k->type));
                continue;
            }
            dict_set(dict, k->data.str, v);
        }
        for (int i = 0; i < count * 2; i++)
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
                if (_ok && i >= 0 && i < target->data.list.count) {
                    Value *r = target->data.list.items[i];
                    if (r && r->type == VAL_NUM && r->obs_age == 0) {
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
                    if (!_ok) runtime_error(current_line, "index must be an integer, got %g", idx_s.d);
                    else runtime_error(current_line, "index %d out of range (list length %d)",
                                  i, target->data.list.count);
                    slot_decref(tgt_s);
                    vm_push_slot(slot_null());
                }
                DISPATCH();
            }
            if (target->type == VAL_BUFFER) {
                if (_ok && i >= 0 && i < target->data.buffer.count) {
                    double v = target->data.buffer.data[i];
                    slot_decref(tgt_s);
                    vm_push_slot(slot_from_num(v));
                } else {
                    if (!_ok) runtime_error(current_line, "index must be an integer, got %g", idx_s.d);
                    else runtime_error(current_line, "buffer index %d out of range (length %d)",
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
                runtime_error(current_line, "index must be an integer, got %g", idx->data.num);
            } else if (i >= 0 && i < target->data.list.count) {
                result = target->data.list.items[i];
                val_incref(result);
            } else {
                runtime_error(current_line, "index %d out of range (list length %d)", i, target->data.list.count);
            }
        } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
            Value *v = dict_get(target, idx->data.str);
            if (v) { result = v; val_incref(result); }
        } else if (target->type == VAL_STR && idx->type == VAL_NUM) {
            int i;
            if (!vm_index_is_int(idx->data.num, &i)) {
                runtime_error(current_line, "index must be an integer, got %g", idx->data.num);
            } else if (i >= 0 && i < (int)strlen(target->data.str)) {
                char buf[2] = { target->data.str[i], 0 };
                result = make_str(buf);
            } else {
                runtime_error(current_line, "string index %d out of range (length %d)", i, (int)strlen(target->data.str));
            }
        } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
            int i;
            if (!vm_index_is_int(idx->data.num, &i))
                runtime_error(current_line, "index must be an integer, got %g", idx->data.num);
            else if (i >= 0 && i < target->data.buffer.count)
                result = make_num(target->data.buffer.data[i]);
            else
                runtime_error(current_line, "buffer index %d out of range (length %d)", i, target->data.buffer.count);
        } else if (target->type != VAL_NULL) {
            runtime_error(current_line, "cannot index %s", val_type_name(target->type));
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
                if (_ok && i >= 0 && i < target->data.buffer.count) {
                    target->data.buffer.data[i] = (int)val_s.d;
                } else {
                    if (!_ok) runtime_error(current_line, "index must be an integer, got %g", idx_s.d);
                    else runtime_error(current_line, "buffer index %d out of range (length %d)",
                                  i, target->data.buffer.count);
                }
                g_vm.sp -= 2;  /* keep val on TOS */
                g_vm.stack[g_vm.sp - 1] = val_s;
                slot_decref(idx_s);
                slot_decref(tgt_s);
                DISPATCH();
            }
            if (target->type == VAL_LIST && slot_is_num(val_s)) {
                if (_ok && i >= 0 && i < target->data.list.count) {
                    Value *existing = target->data.list.items[i];
                    /* In-place mutate when slot is an exclusive untracked VAL_NUM. */
                    if (existing && existing->type == VAL_NUM &&
                        existing->refcount == 1 && existing->obs_age == 0 &&
                        !existing->arena) {
                        existing->data.num = val_s.d;
                    } else {
                        val_decref(existing);
                        target->data.list.items[i] = make_num(val_s.d);
                    }
                } else {
                    if (!_ok) runtime_error(current_line, "index must be an integer, got %g", idx_s.d);
                    else runtime_error(current_line, "index %d out of range (list length %d)",
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
                runtime_error(current_line, "index must be an integer, got %g", idx->data.num);
            } else if (i >= 0 && i < target->data.list.count) {
                val_incref(val);
                val_decref(target->data.list.items[i]);
                target->data.list.items[i] = val;
            } else {
                runtime_error(current_line, "index %d out of range (list length %d)", i, target->data.list.count);
            }
        } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
            int i;
            if (!vm_index_is_int(idx->data.num, &i)) {
                runtime_error(current_line, "index must be an integer, got %g", idx->data.num);
            } else if (i >= 0 && i < target->data.buffer.count && val->type == VAL_NUM)
                target->data.buffer.data[i] = (int)val->data.num;
            else if (i < 0 || i >= target->data.buffer.count)
                runtime_error(current_line, "buffer index %d out of range (length %d)", i, target->data.buffer.count);
        } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
            dict_set(target, idx->data.str, val);
        } else if (target->type != VAL_NULL) {
            runtime_error(current_line, "cannot index %s for assignment", val_type_name(target->type));
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
                if (v->type == VAL_NUM && v->obs_age == 0) {
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
            runtime_error(current_line, "cannot access field '%s' on %s",
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
        Value *val = vm_pop(); Value *target = vm_pop();
        if (target->type == VAL_DICT)
            dict_set_cached(target, key, h, val);
        else if (target->type != VAL_NULL)
            runtime_error(current_line, "cannot set field '%s' on %s",
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
                if (v->type == VAL_NUM && v->obs_age == 0) {
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
            runtime_error(current_line, "cannot access field '%s' on %s",
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
            runtime_error(current_line, "cannot set field '%s' on %s",
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
                    runtime_error(current_line, "buffer index %d out of range (length %d)",
                                  i, target->data.buffer.count);
                    vm_push_slot(slot_null());
                }
                DISPATCH();
            }
            if (target->type == VAL_LIST) {
                if (i < target->data.list.count) {
                    Value *item = target->data.list.items[i];
                    /* Plain VAL_NUM -> immediate; skip incref/decref pair. */
                    if (item && item->type == VAL_NUM && item->obs_age == 0) {
                        vm_push_slot(slot_from_num(item->data.num));
                    } else {
                        val_incref(item);
                        vm_push(item);
                    }
                } else {
                    runtime_error(current_line, "index %d out of range (list length %d)",
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
                    runtime_error(current_line, "string index %d out of range (length %d)",
                                  i, len);
                    vm_push_slot(slot_null());
                }
                DISPATCH();
            }
            if (target->type != VAL_NULL) {
                runtime_error(current_line, "cannot index %s", val_type_name(target->type));
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
                        if (v->type == VAL_NUM && v->obs_age == 0) {
                            vm_push_slot(slot_from_num(v->data.num));
                        } else {
                            val_incref(v);
                            vm_push(v);
                        }
                        DISPATCH();
                    }
                } else if (dict && dict->type != VAL_NULL) {
                    const char *key = chunk->const_interns[name_idx];
                    runtime_error(current_line, "cannot access field '%s' on %s",
                        key, val_type_name(dict->type));
                }
            } else {
                runtime_error(current_line, "index %d out of range (list length %d)",
                              i, target->data.list.count);
            }
        } else if (target && target->type != VAL_NULL) {
            runtime_error(current_line, "cannot index %s", val_type_name(target->type));
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
                    runtime_error(current_line, "cannot assign field '%s' on %s",
                        key, val_type_name(dict->type));
                }
            } else {
                runtime_error(current_line, "index %d out of range (list length %d)",
                              i, target->data.list.count);
            }
        } else if (target && target->type != VAL_NULL) {
            runtime_error(current_line, "cannot index %s for assignment",
                          val_type_name(target->type));
        }
        DISPATCH();
    }

    /* ---- Iteration ---- */

    CASE(ITER_SETUP): {
        Value *iterable = vm_pop();
        if (iterable && iterable->type != VAL_LIST && iterable->type != VAL_BUFFER) {
            runtime_error(current_line, "'for' requires a list or buffer, got %s",
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

        if (idx >= len) {
            ip += exit_offset;
        } else {
            Value *elem;
            if (iterable->type == VAL_BUFFER)
                elem = make_num(iterable->data.buffer.data[idx]);
            else {
                elem = iterable->data.list.items[idx];
                val_incref(elem);
            }
            /* Update index — mutate in place when the existing slot is
             * an exclusive plain VAL_NUM (avoids per-iter make_num/free). */
            Value *idx_v = state->data.list.items[1];
            if (NUM_REUSE(idx_v) && idx_v->obs_age == 0) {
                idx_v->data.num = (double)(idx + 1);
            } else {
                val_decref(idx_v);
                state->data.list.items[1] = make_num(idx + 1);
            }
            vm_push(elem);
        }
        DISPATCH();
    }

    CASE(LOOP_ENV_FRESH): {
        /* Create a child env for this loop iteration. */
        Env *parent = frame->env;
        Env *loop_env = env_new(parent);
        frame->env = loop_env;
        DISPATCH();
    }

    CASE(LOOP_ENV_END): {
        /* Restore the parent env after loop body. Free the loop env
         * unless it was captured by a closure. */
        Env *loop_env = frame->env;
        frame->env = loop_env->parent;
        env_free(loop_env);
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
        uint16_t name_idx = read_u16(ip); ip += 2;
        if (g_unobserved_depth == 0) {
            /* Promote an immediate TOS to a tracked heap Value so the
             * observer fields (entropy/dH/obs_age/dirty) live on the
             * same object that SET_NAME will store in env. Without this
             * promotion, each vm_peek of an immediate would materialize
             * a fresh make_num and the observer state would be lost. */
            EigsSlot s = g_vm.stack[g_vm.sp - 1];
            Value *v = NULL;
            if (slot_is_num(s)) {
                v = make_tracked_num(s.d);
                g_vm.stack[g_vm.sp - 1] = slot_from_tracked(v);
            } else if (slot_is_ptr(s)) {
                v = slot_as_ptr(s);
            }
            if (v) {
                const char *name = chunk->const_interns[name_idx];
                uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
                if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
                Value *prev = env_get_hashed(frame->env, name, h);
                if (prev && prev != v) {
                    observer_ensure_fresh(prev);
                    v->last_entropy = prev->last_entropy;
                    v->entropy = prev->entropy;
                    v->obs_age = prev->obs_age;
                    v->dH = prev->dH;
                    v->prev_dH = prev->prev_dH;
                }
                v->dirty = 1;
                g_last_observer = v;
            }
        }
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
            EigsSlot s = g_vm.stack[g_vm.sp - 1];
            Value *v = NULL;
            if (slot_is_num(s)) {
                v = make_tracked_num(s.d);
                g_vm.stack[g_vm.sp - 1] = slot_from_tracked(v);
            } else if (slot_is_ptr(s)) {
                v = slot_as_ptr(s);
            }
            if (v) {
                Env *e = frame->fn_env;
                Value *prev = NULL;
                if (e && (int)slot < e->count) {
                    EigsSlot ps = e->values[slot];
                    if (slot_is_ptr(ps)) prev = slot_as_ptr(ps);
                }
                if (prev && prev != v) {
                    observer_ensure_fresh(prev);
                    v->last_entropy = prev->last_entropy;
                    v->entropy = prev->entropy;
                    v->obs_age = prev->obs_age;
                    v->dH = prev->dH;
                    v->prev_dH = prev->prev_dH;
                }
                v->dirty = 1;
                g_last_observer = v;
            }
        }
        DISPATCH();
    }

    CASE(INTERROGATE): {
        uint16_t kind = read_u16(ip); ip += 2;
        Value *v = vm_pop();
        if (v) observer_ensure_fresh(v);
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
        case 2: /* when */ result = make_num(v ? v->obs_age : 0); break;
        case 3: /* where */ result = make_num(v ? v->entropy : 0); break;
        case 4: /* why */ result = make_num(v ? v->dH : 0); break;
        case 5: /* how */
            if (v && v->last_entropy > 0)
                result = make_num(1.0 - v->entropy / v->last_entropy);
            else result = make_num(1.0);
            break;
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

    CASE(PREDICATE): {
        uint16_t kind = read_u16(ip); ip += 2;
        Value *v = g_last_observer;
        if (v) observer_ensure_fresh(v);
        double dH = v ? v->dH : 0;
        double entropy = v ? v->entropy : 0;
        double prev_dH = v ? v->prev_dH : 0;
        int result = 0;
        switch (kind) {
        case 0: result = (fabs(dH) < g_obs_dh_zero && entropy < g_obs_h_low); break;
        case 1: result = (fabs(dH) < g_obs_dh_small && entropy >= g_obs_h_low &&
                          !(dH * prev_dH < 0 && fabs(dH) > g_obs_dh_zero)); break;
        case 2: result = (dH < -g_obs_dh_zero); break;
        case 3: result = (dH * prev_dH < 0 && fabs(dH) > g_obs_dh_zero); break;
        case 4: result = (dH > g_obs_dh_zero); break;
        case 5: result = (fabs(dH) < g_obs_dh_zero); break;
        }
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
            Value *obs = g_last_observer;
            if (obs) observer_ensure_fresh(obs);
            if (obs && fabs(obs->dH) < g_obs_dh_zero && obs->entropy >= g_obs_h_low) {
                g_loop_stall_count++;
                if (g_loop_stall_count >= 100) {
                    g_loop_exit_reason = "stalled";
                    should_exit = 1;
                }
            } else {
                g_loop_stall_count = 0;
            }
        }
        if (g_loop_iterations >= 100000000) {
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

    /* ---- Modules ---- */

    CASE(IMPORT): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *name = chunk->const_interns[idx];

        char request[4096];
        char path_buf[8192];
        snprintf(request, sizeof(request), "lib/%.1024s.eigs", name);

        extern int resolve_eigenscript_file(const char *name, char *out, size_t outlen);
        extern char *read_file_util(const char *path, long *size);
        extern __thread int g_parse_errors;
        extern __thread Env *g_load_env;
        extern Env *g_global_env;
        extern TokenList tokenize(const char *source);
        extern ASTNode *parse(TokenList *tl);
        extern void free_tokenlist(TokenList *tl);
        extern void free_ast(ASTNode *ast);

        if (!resolve_eigenscript_file(request, path_buf, sizeof(path_buf))) {
            runtime_error(current_line, "import: module '%s' not found", name);
            vm_push(make_null());
            DISPATCH();
        }

        long src_size = 0;
        char *source = read_file_util(path_buf, &src_size);
        if (!source) {
            runtime_error(current_line, "import: cannot read '%s'", name);
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
            free_tokenlist(&tl);
            free(source);
            runtime_error(current_line, "import: parse errors in '%s'", name);
            vm_push(make_null());
            DISPATCH();
        }
        g_parse_errors = saved_errors;

        Env *saved_load = g_load_env;
        g_load_env = mod_env;
        EigsChunk *mod_chunk = compile_ast(ast, mod_env);
        Value *mod_result = vm_execute(mod_chunk, mod_env);
        if (mod_result) val_decref(mod_result);
        chunk_free(mod_chunk);   /* creator ref; module fns hold their own */
        g_load_env = saved_load;
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);

        /* Collect module bindings into dict */
        /* mod_env has bindings from module execution */
        Value *mod_dict = make_dict(mod_env->count);
        for (int mi = 0; mi < mod_env->count; mi++) {
            if (mod_env->names[mi][0] == '_') continue;
            Value *mv = slot_to_value(mod_env->values[mi]);
            dict_set(mod_dict, mod_env->names[mi], mv);
            val_decref(mv);
        }
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
         * (17.8M calls per 500k DMG-shaped steps before this change). */
        g_trace_current_line = line;
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
            vm_push_slot(slot_null());
            DISPATCH();
        }
        slot_decref(key_s);

        if (!slot_is_ptr(table_s)) {
            slot_decref(arg_s); slot_decref(table_s);
            vm_push_slot(slot_null());
            DISPATCH();
        }

        Value *table = slot_as_ptr(table_s);
        int key;
        if (!vm_index_is_int(key_d, &key)) {
            slot_decref(arg_s); slot_decref(table_s);
            runtime_error(current_line,
                "dispatch key must be an integer, got %g", key_d);
            vm_push_slot(slot_null());
            DISPATCH();
        }

        if (table->type != VAL_LIST ||
            key < 0 || key >= table->data.list.count) {
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
                /* Direct-borrow heuristic — see CASE(CALL) for rationale.
                 * Must run before val_decref(arg) so the items array is
                 * still valid, and skipped when the builtin already
                 * consumed arg (free_val), since arg would be freed. */
                if (arg && arg->type == VAL_LIST) {
                    int n = arg->data.list.count;
                    Value **items = arg->data.list.items;
                    for (int i = 0; i < n; i++) {
                        if (items[i] == result) { val_incref(result); break; }
                    }
                }
            }
            if (!consumes_arg && result != arg) val_decref(arg);
            slot_decref(table_s);
            vm_push(result);
            CHECK_ERROR();
            DISPATCH();
        }

        if (fn && fn->type == VAL_FN && fn->data.fn.body_count == -1) {
            /* Bytecode function — push frame inline (no re-entry).
             * Bind the single param directly from the slot (no boxing). */
            EigsChunk *fn_chunk = (EigsChunk *)fn->data.fn.body;
            Env *call_env = env_new(fn->data.fn.closure);
            if (fn->data.fn.param_count > 0) {
                uint32_t ph = fn->data.fn.param_hashes ? fn->data.fn.param_hashes[0]
                                                       : env_hash_name(fn->data.fn.params[0]);
                vm_bind_fresh_param(call_env, 0,
                    fn->data.fn.params[0], ph, arg_s);
            } else {
                slot_decref(arg_s);
            }
            /* Pre-allocate slots for non-captured locals */
            if (fn_chunk->local_count > fn->data.fn.param_count)
                env_reserve_slots(call_env, fn_chunk->local_count);
            slot_decref(table_s);

            frame->ip = ip;
            if (g_vm.frame_count >= VM_FRAMES_MAX) {
                runtime_error(current_line, "call stack overflow");
                env_free(call_env);
                vm_push(make_null());
                DISPATCH();
            }
            frame = &g_vm.frames[g_vm.frame_count++];
            frame->chunk = fn_chunk;
            chunk_incref(fn_chunk);   /* frame's ref */
            frame->ip = fn_chunk->code;
            frame->bp = g_vm.sp;
            frame->env = call_env;
            frame->fn_env = call_env;
            frame->closure_val = fn;
            frame->owns_env = 1;
            frame->is_try = 0;
            frame->try_count = 0;
            fn_chunk->exec_count++;

            /* JIT hook (mirror of OP_CALL bytecode-fn path). */
            if (fn_chunk->jit_state == 0) jit_try_compile_chunk(fn_chunk);
            if (fn_chunk->jit_code) {
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
                frame->ip += fn_chunk->jit_advance;
                current_line = g_vm.current_line;
            }

            ip = frame->ip;
            chunk = fn_chunk;
            DISPATCH();
        }

        /* Not callable */
        slot_decref(arg_s); slot_decref(table_s);
        vm_push_slot(slot_null());
        DISPATCH();
    }

    CASE(WIDE): {
        /* Not yet implemented — placeholder */
        DISPATCH();
    }

#ifndef __GNUC__
    default:
        runtime_error(current_line, "unknown opcode %d", ip[-1]);
        vm_push(make_null());
        break;
    }} /* end switch / for */
#endif

    /* Should not reach here */
    chunk_decref(g_vm.frames[g_vm.frame_count - 1].chunk);
    g_vm.frame_count--;
    return make_null();

vm_error_halt:
    /* Uncaught runtime error: unwind every frame this vm_run owns
     * ([base_frame, frame_count)) the same way OP_RETURN does — drain the
     * frame's stack window, free its env if owned, restore the per-frame
     * loop-stall globals — then return null. g_has_error is left set on
     * purpose: the caller (re-entrant vm_run via CHECK_ERROR, or main via
     * its exit code) is responsible for reporting it. */
    while (g_vm.frame_count > base_frame) {
        CallFrame *f = &g_vm.frames[g_vm.frame_count - 1];
        while (g_vm.sp > f->bp) slot_decref(g_vm.stack[--g_vm.sp]);
        if (f->owns_env) env_free(f->env);
        g_loop_stall_count = f->saved_stall_count;
        g_loop_iterations  = f->saved_loop_iter;
        chunk_decref(f->chunk);   /* frame's ref */
        g_vm.frame_count--;
    }
    return make_null();
}

/* ---- Public API ---- */

Value *vm_execute(EigsChunk *chunk, Env *env) {
    vm_init();
    if (g_vm.global_env == NULL) {
        /* First call — initialize */
        g_vm.global_env = env;
    }
    /* Re-entrant safe: vm_run pushes/pops its own frame and cleans
     * the stack back to its base pointer on return. */
    return vm_run(chunk, env);
}
