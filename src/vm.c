/* ================================================================
 * EigenScript Bytecode VM — execution loop
 * ================================================================
 * Stack-based VM with computed-goto dispatch (GCC/Clang).
 * Falls back to switch dispatch on other compilers.
 */

#include "eigenscript.h"
#include "vm.h"
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
        if (strcmp(dict->data.dict.keys[ce->index], key) == 0)
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
        if (strcmp(dict->data.dict.keys[ce->index], key) == 0) {
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
        if (strcmp(dict->data.dict.keys[ce->index], key) == 0) {
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

/* ---- Main execution loop ---- */

static Value *vm_run(EigsChunk *chunk, Env *env) {
    int base_frame = g_vm.frame_count; /* track entry point for re-entrant returns */
    /* Module-level slot promotion (Part B): if the module chunk allocated slots
     * past env->count at compile time, reserve them now so OP_SET_LOCAL has
     * a place to write. Slot indices in bytecode are absolute env positions. */
    if (base_frame == 0 && chunk->local_count > env->count) {
        env_reserve_slots(env, chunk->local_count);
    }
    CallFrame *frame = &g_vm.frames[g_vm.frame_count++];
    frame->chunk = chunk;
    frame->ip = chunk->code;
    frame->bp = g_vm.sp;
    frame->env = env;
    frame->fn_env = env;
    frame->closure_val = NULL;
    frame->owns_env = 0;
    frame->is_try = 0;
    frame->try_count = 0;

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
    };
    #define CHECK_ERROR() do { \
        if (g_has_error && frame->try_count > 0) { \
            g_has_error = 0; \
            g_try_depth--; \
            frame->try_count--; \
            uint8_t *_catch_ip = frame->try_handlers[frame->try_count].catch_ip; \
            int _catch_bp = frame->try_handlers[frame->try_count].catch_bp; \
            frame->is_try = (frame->try_count > 0); \
            while (g_vm.sp > _catch_bp) val_decref(vm_pop()); \
            vm_push(make_str(g_error_msg)); \
            ip = _catch_ip; \
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
        } else if (a->type == VAL_NUM && b->type == VAL_STR) {
            char buf[64]; snprintf(buf, sizeof(buf), "%.14g%s", a->data.num, b->data.str);
            vm_push(make_str(buf));
        } else if (a->type == VAL_STR && b->type == VAL_NUM) {
            char buf[64]; snprintf(buf, sizeof(buf), "%s%.14g", a->data.str, b->data.num);
            vm_push(make_str(buf));
        } else if (a->type == VAL_STR || b->type == VAL_STR) {
            /* String + non-string: convert non-string to string */
            extern char* value_to_string(Value *v);
            char *sa = (a->type == VAL_STR) ? strdup(a->data.str) : value_to_string(a);
            char *sb = (b->type == VAL_STR) ? strdup(b->data.str) : value_to_string(b);
            int la = strlen(sa), lb = strlen(sb);
            char *s = malloc(la + lb + 1);
            memcpy(s, sa, la); memcpy(s + la, sb, lb); s[la + lb] = 0;
            vm_push(make_str(s));
            free(sa); free(sb); free(s);
        } else {
            runtime_error(current_line, "cannot apply '+' to %s and %s",
                val_type_name(a->type), val_type_name(b->type));
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

#define INT_BINOP(NAME, OP) \
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
        slot_decref(_as); slot_decref(_bs); \
        g_vm.stack[g_vm.sp - 2] = slot_from_num(0.0); \
        g_vm.sp--; \
        DISPATCH(); \
    }

    INT_BINOP(BAND, &)
    INT_BINOP(BOR, |)
    INT_BINOP(BXOR, ^)
    INT_BINOP(SHL, <<)
    INT_BINOP(SHR, >>)

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
        slot_decref(s);
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
        int eq = 0;
        if (a->type == VAL_STR && b->type == VAL_STR) eq = strcmp(a->data.str, b->data.str) == 0;
        else if (a->type == VAL_NULL && b->type == VAL_NULL) eq = 1;
        else eq = (a == b);
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
        int eq = 0;
        if (a->type == VAL_STR && b->type == VAL_STR) eq = strcmp(a->data.str, b->data.str) == 0;
        else if (a->type == VAL_NULL && b->type == VAL_NULL) eq = 1;
        else eq = (a == b);
        vm_push(make_num(eq ? 0.0 : 1.0));
        val_decref(a); val_decref(b);
        DISPATCH();
    }

#define NUM_CMP(NAME, OP) \
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
        slot_decref(_as); slot_decref(_bs); \
        g_vm.stack[g_vm.sp - 2] = slot_from_num(0.0); \
        g_vm.sp--; \
        DISPATCH(); \
    }

    NUM_CMP(LT, <)
    NUM_CMP(GT, >)
    NUM_CMP(LE, <=)
    NUM_CMP(GE, >=)

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
        const char *name = chunk->constants[idx]->data.str;
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        int found = 0;
        EigsSlot s = env_get_hashed_slot(frame->env, name, h, &found);
        if (!found) {
            runtime_error(current_line, "undefined variable '%s'", name);
            vm_push_slot(slot_null());
        } else {
            slot_incref(s);
            vm_push_slot(s);
        }
        DISPATCH();
    }

    CASE(SET_NAME): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *name = chunk->constants[idx]->data.str;
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        EigsSlot s = g_vm.stack[g_vm.sp - 1];
        env_set_hashed_slot(frame->env, name, h, s);
        DISPATCH();
    }

    CASE(SET_NAME_LOCAL): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *name = chunk->constants[idx]->data.str;
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        EigsSlot s = g_vm.stack[g_vm.sp - 1];
        env_set_local_hashed_slot(frame->env, name, h, s);
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
        DISPATCH();
    }

    CASE(JUMP_IF_FALSE): {
        uint16_t offset = read_u16(ip); ip += 2;
        Value *v = STK_AS_VAL(--g_vm.sp);
        if (v->type == VAL_NUM) {
            if (v->data.num == 0.0) ip += offset;
            if (NUM_REUSE(v)) free_value(v); else val_decref(v);
        } else {
            if (!is_truthy(v)) ip += offset;
            val_decref(v);
        }
        DISPATCH();
    }

    CASE(JUMP_IF_TRUE): {
        uint16_t offset = read_u16(ip); ip += 2;
        Value *v = STK_AS_VAL(--g_vm.sp);
        if (v->type == VAL_NUM) {
            if (v->data.num != 0.0) ip += offset;
            if (NUM_REUSE(v)) free_value(v); else val_decref(v);
        } else {
            if (is_truthy(v)) ip += offset;
            val_decref(v);
        }
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
        Value *v = vm_peek(0);
        val_incref(v);
        vm_push(v);
        DISPATCH();
    }

    CASE(DUP2): {
        Value *b = vm_peek(0);
        Value *a = vm_peek(1);
        val_incref(a); val_incref(b);
        vm_push(a); vm_push(b);
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
        __atomic_add_fetch(&frame->env->env_refcount, 1, __ATOMIC_RELAXED);
        Value *fn = make_fn(fn_chunk->name, params, fn_chunk->param_count,
                            NULL, 0, frame->env);
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

            if (!result) result = make_null();
            else if (result != arg) val_incref(result);
            /* Decref arg *after* incref'ing result, in case the builtin
             * returns a borrowed pointer into arg (e.g., coalesce returns
             * a list item). Otherwise the arg-free cascades through list
             * items and frees result before the incref. */
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
                    uint32_t ph = phashes ? phashes[i] : 0;
                    env_set_local_hashed_slot(call_env,
                        fn_val->data.fn.params[i], ph,
                        g_vm.stack[g_vm.sp - argc + i]);
                }
            } else if (param_count == 1) {
                uint32_t ph = phashes ? phashes[0] : 0;
                if (argc == 1) {
                    env_set_local_hashed_slot(call_env,
                        fn_val->data.fn.params[0], ph,
                        g_vm.stack[g_vm.sp - 1]);
                } else {
                    Value *arg_list = make_list(argc);
                    for (int i = 0; i < argc; i++)
                        list_append(arg_list, STK_AS_VAL(g_vm.sp - argc + i));
                    env_set_local_hashed_slot(call_env,
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
            frame->ip = fn_chunk->code;
            frame->bp = g_vm.sp;
            frame->env = call_env;
            frame->fn_env = call_env;
            frame->closure_val = fn_val;
            frame->owns_env = 1; /* OP_CALL created this env, free on return */
            frame->is_try = 0;
            frame->try_count = 0;

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
        Value *result;
        if (g_vm.sp > frame->bp) {
            result = vm_pop();
        } else {
            result = make_null();
        }
        while (g_vm.sp > frame->bp)
            val_decref(vm_pop());
        if (frame->owns_env) env_free(frame->env);
        g_vm.frame_count--;
        /* Return to C if we've unwound past our entry point */
        if (g_vm.frame_count <= base_frame) return result;
        frame = &g_vm.frames[g_vm.frame_count - 1];
        ip = frame->ip;
        chunk = frame->chunk;
        vm_push(result);
        DISPATCH();
    }

    CASE(RETURN_NULL): {
        while (g_vm.sp > frame->bp)
            val_decref(vm_pop());
        if (frame->owns_env) env_free(frame->env);
        g_vm.frame_count--;
        if (g_vm.frame_count <= base_frame) return make_null();
        frame = &g_vm.frames[g_vm.frame_count - 1];
        ip = frame->ip;
        chunk = frame->chunk;
        vm_push(make_null());
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
            int i = (int)idx_s.d;
            if (target->type == VAL_LIST) {
                if (i >= 0 && i < target->data.list.count) {
                    Value *r = target->data.list.items[i];
                    val_incref(r);
                    slot_decref(tgt_s);
                    vm_push(r);
                } else {
                    runtime_error(current_line, "index %d out of range (list length %d)",
                                  i, target->data.list.count);
                    slot_decref(tgt_s);
                    vm_push_slot(slot_null());
                }
                DISPATCH();
            }
            if (target->type == VAL_BUFFER) {
                if (i >= 0 && i < target->data.buffer.count) {
                    double v = target->data.buffer.data[i];
                    slot_decref(tgt_s);
                    vm_push_slot(slot_from_num(v));
                } else {
                    runtime_error(current_line, "buffer index %d out of range (length %d)",
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
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.list.count) {
                result = target->data.list.items[i];
                val_incref(result);
            } else {
                runtime_error(current_line, "index %d out of range (list length %d)", i, target->data.list.count);
            }
        } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
            Value *v = dict_get(target, idx->data.str);
            if (v) { result = v; val_incref(result); }
        } else if (target->type == VAL_STR && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < (int)strlen(target->data.str)) {
                char buf[2] = { target->data.str[i], 0 };
                result = make_str(buf);
            } else {
                runtime_error(current_line, "string index %d out of range (length %d)", i, (int)strlen(target->data.str));
            }
        } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.buffer.count)
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
        Value *val = vm_pop(); Value *idx = vm_pop(); Value *target = vm_pop();
        if (target->type == VAL_LIST && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.list.count) {
                val_incref(val);
                val_decref(target->data.list.items[i]);
                target->data.list.items[i] = val;
            } else {
                runtime_error(current_line, "index %d out of range (list length %d)", i, target->data.list.count);
            }
        } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.buffer.count && val->type == VAL_NUM)
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
        const char *key = chunk->constants[idx]->data.str;
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[idx] : 0;
        if (h == 0) { h = env_hash_name(key); if (chunk->const_hashes) chunk->const_hashes[idx] = h; }
        Value *target = vm_pop();
        Value *result = make_null();
        if (target->type == VAL_DICT) {
            Value *v = dict_get_cached(target, key, h);
            if (v) { result = v; val_incref(result); }
        } else if (target->type != VAL_NULL) {
            runtime_error(current_line, "cannot access field '%s' on %s",
                key, val_type_name(target->type));
        }
        val_decref(target);
        vm_push(result);
        DISPATCH();
    }

    CASE(DOT_SET): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *key = chunk->constants[idx]->data.str;
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
            const char *key = chunk->constants[name_idx]->data.str;
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
            const char *key = chunk->constants[name_idx]->data.str;
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
            const char *key = chunk->constants[name_idx]->data.str;
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
            const char *key = chunk->constants[name_idx]->data.str;
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
                    const char *key = chunk->constants[name_idx]->data.str;
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
                    const char *key = chunk->constants[name_idx]->data.str;
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
                    const char *key = chunk->constants[name_idx]->data.str;
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
                    const char *key = chunk->constants[name_idx]->data.str;
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
                const char *name = chunk->constants[name_idx]->data.str;
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
        const char *name = chunk->constants[name_idx]->data.str;
        uint32_t h = chunk->const_hashes ? chunk->const_hashes[name_idx] : 0;
        if (h == 0) { h = env_hash_name(name); if (chunk->const_hashes) chunk->const_hashes[name_idx] = h; }
        switch (kind) {
        case 1: /* who — return binding name */
            result = make_str(name);
            break;
        case 2: /* when — return assignment count */
            result = make_num(env_get_assign_count(frame->env, name, h));
            break;
        }
        val_decref(v);
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
        {
            Value *iter_val = make_num(g_loop_iterations);
            env_set_local(frame->env, "__loop_iterations__", iter_val);
            val_decref(iter_val);
        }
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
        const char *name = chunk->constants[idx]->data.str;

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
        DISPATCH();
    }

    CASE(DISPATCH): {
        /* Native dispatch: pop arg, key, table; call table[key](arg) inline.
         * Replaces builtin_dispatch to avoid re-entrant vm_execute calls. */
        Value *arg = vm_pop();
        Value *key_val = vm_pop();
        Value *table = vm_pop();

        if (!table || table->type != VAL_LIST ||
            !key_val || key_val->type != VAL_NUM) {
            val_decref(arg); val_decref(key_val); val_decref(table);
            vm_push(make_null());
            DISPATCH();
        }

        int key = (int)key_val->data.num;
        val_decref(key_val);

        if (key < 0 || key >= table->data.list.count) {
            val_decref(arg); val_decref(table);
            vm_push(make_null());
            DISPATCH();
        }

        Value *fn = table->data.list.items[key];

        if (fn && fn->type == VAL_BUILTIN) {
            val_incref(arg);
            Env *saved = g_builtin_call_env;
            g_builtin_call_env = frame->env;
            Value *result = fn->data.builtin(arg);
            g_builtin_call_env = saved;
            if (result != arg) val_decref(arg);
            if (!result) result = make_null();
            else if (result != arg) val_incref(result);
            val_decref(table);
            vm_push(result);
            CHECK_ERROR();
            DISPATCH();
        }

        if (fn && fn->type == VAL_FN && fn->data.fn.body_count == -1) {
            /* Bytecode function — push frame inline (no re-entry) */
            EigsChunk *fn_chunk = (EigsChunk *)fn->data.fn.body;
            Env *call_env = env_new(fn->data.fn.closure);
            if (fn->data.fn.param_count > 0)
                env_set_local(call_env, fn->data.fn.params[0], arg);
            /* Pre-allocate slots for non-captured locals */
            if (fn_chunk->local_count > fn->data.fn.param_count)
                env_reserve_slots(call_env, fn_chunk->local_count);
            val_decref(arg);
            val_decref(table);

            frame->ip = ip;
            if (g_vm.frame_count >= VM_FRAMES_MAX) {
                runtime_error(current_line, "call stack overflow");
                env_free(call_env);
                vm_push(make_null());
                DISPATCH();
            }
            frame = &g_vm.frames[g_vm.frame_count++];
            frame->chunk = fn_chunk;
            frame->ip = fn_chunk->code;
            frame->bp = g_vm.sp;
            frame->env = call_env;
            frame->fn_env = call_env;
            frame->closure_val = fn;
            frame->owns_env = 1;
            frame->is_try = 0;
            frame->try_count = 0;

            ip = frame->ip;
            chunk = fn_chunk;
            DISPATCH();
        }

        /* Not callable */
        val_decref(arg); val_decref(table);
        vm_push(make_null());
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
    g_vm.frame_count--;
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
