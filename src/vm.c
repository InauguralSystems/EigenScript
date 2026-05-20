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

/* ---- VM helpers ---- */

static void vm_init(void) {
    if (!g_vm_init) {
        memset(&g_vm, 0, sizeof(g_vm));
        g_vm_init = 1;
    }
}

static inline void vm_push(Value *v) {
    if (g_vm.sp >= VM_STACK_MAX) {
        runtime_error(0, "VM stack overflow");
        return;
    }
    g_vm.stack[g_vm.sp++] = v;
}

static inline Value *vm_pop(void) {
    if (g_vm.sp <= 0) {
        runtime_error(0, "VM stack underflow");
        return make_null();
    }
    return g_vm.stack[--g_vm.sp];
}

static inline Value *vm_peek(int distance) {
    return g_vm.stack[g_vm.sp - 1 - distance];
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
    CallFrame *frame = &g_vm.frames[g_vm.frame_count++];
    frame->chunk = chunk;
    frame->ip = chunk->code;
    frame->bp = g_vm.sp;
    frame->env = env;
    frame->closure_val = NULL;
    frame->is_try = 0;
    frame->catch_ip = NULL;
    frame->catch_bp = 0;

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
        [OP_POP] = &&lbl_POP, [OP_DUP] = &&lbl_DUP,
        [OP_CLOSURE] = &&lbl_CLOSURE, [OP_CALL] = &&lbl_CALL,
        [OP_RETURN] = &&lbl_RETURN, [OP_RETURN_NULL] = &&lbl_RETURN_NULL,
        [OP_LIST] = &&lbl_LIST, [OP_DICT] = &&lbl_DICT,
        [OP_INDEX_GET] = &&lbl_INDEX_GET, [OP_INDEX_SET] = &&lbl_INDEX_SET,
        [OP_DOT_GET] = &&lbl_DOT_GET, [OP_DOT_SET] = &&lbl_DOT_SET,
        [OP_ITER_SETUP] = &&lbl_ITER_SETUP, [OP_ITER_NEXT] = &&lbl_ITER_NEXT,
        [OP_BREAK] = &&lbl_BREAK, [OP_CONTINUE] = &&lbl_CONTINUE,
        [OP_TRY_BEGIN] = &&lbl_TRY_BEGIN, [OP_TRY_END] = &&lbl_TRY_END,
        [OP_OBSERVE_ASSIGN] = &&lbl_OBSERVE_ASSIGN,
        [OP_INTERROGATE] = &&lbl_INTERROGATE, [OP_PREDICATE] = &&lbl_PREDICATE,
        [OP_UNOBSERVED_BEGIN] = &&lbl_UNOBSERVED_BEGIN,
        [OP_UNOBSERVED_END] = &&lbl_UNOBSERVED_END,
        [OP_IMPORT] = &&lbl_IMPORT, [OP_MATCH] = &&lbl_MATCH,
        [OP_LISTCOMP_BEGIN] = &&lbl_LISTCOMP_BEGIN,
        [OP_LISTCOMP_APPEND] = &&lbl_LISTCOMP_APPEND,
        [OP_LINE] = &&lbl_LINE, [OP_WIDE] = &&lbl_WIDE,
    };
    #define CHECK_ERROR() do { \
        if (g_has_error && frame->is_try && frame->catch_ip) { \
            g_has_error = 0; \
            g_try_depth--; \
            frame->is_try = 0; \
            while (g_vm.sp > frame->catch_bp) val_decref(vm_pop()); \
            vm_push(make_str(g_error_msg)); \
            ip = frame->catch_ip; \
            frame->catch_ip = NULL; \
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
        val_incref(v);
        vm_push(v);
        DISPATCH();
    }

    CASE(NULL): {
        vm_push(make_null());
        DISPATCH();
    }

    CASE(NUM_ZERO): {
        vm_push(make_num(0.0));
        DISPATCH();
    }

    CASE(NUM_ONE): {
        vm_push(make_num(1.0));
        DISPATCH();
    }

    /* ---- Arithmetic ---- */

    CASE(ADD): {
        Value *b = vm_pop(); Value *a = vm_pop();
        if (a->type == VAL_NUM && b->type == VAL_NUM) {
            vm_push(make_num(num_guard(a->data.num + b->data.num)));
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
        } else {
            vm_push(make_null());
        }
        val_decref(a); val_decref(b);
        DISPATCH();
    }

#define NUM_BINOP(NAME, OP) \
    CASE(NAME): { \
        Value *b = vm_pop(); Value *a = vm_pop(); \
        if (a->type == VAL_NUM && b->type == VAL_NUM) \
            vm_push(make_num(num_guard(a->data.num OP b->data.num))); \
        else vm_push(make_num(0)); \
        val_decref(a); val_decref(b); \
        DISPATCH(); \
    }

    NUM_BINOP(SUB, -)
    NUM_BINOP(MUL, *)

    CASE(DIV): {
        Value *b = vm_pop(); Value *a = vm_pop();
        if (a->type == VAL_NUM && b->type == VAL_NUM) {
            if (b->data.num == 0.0) {
                runtime_error(current_line, "division by zero");
                vm_push(make_num(0));
            } else {
                vm_push(make_num(num_guard(a->data.num / b->data.num)));
            }
        } else vm_push(make_num(0));
        val_decref(a); val_decref(b);
        DISPATCH();
    }

    CASE(MOD): {
        Value *b = vm_pop(); Value *a = vm_pop();
        if (a->type == VAL_NUM && b->type == VAL_NUM && b->data.num != 0.0)
            vm_push(make_num(num_guard(fmod(a->data.num, b->data.num))));
        else vm_push(make_num(0));
        val_decref(a); val_decref(b);
        DISPATCH();
    }

#define INT_BINOP(NAME, OP) \
    CASE(NAME): { \
        Value *b = vm_pop(); Value *a = vm_pop(); \
        if (a->type == VAL_NUM && b->type == VAL_NUM) \
            vm_push(make_num((double)((int64_t)a->data.num OP (int64_t)b->data.num))); \
        else vm_push(make_num(0)); \
        val_decref(a); val_decref(b); \
        DISPATCH(); \
    }

    INT_BINOP(BAND, &)
    INT_BINOP(BOR, |)
    INT_BINOP(BXOR, ^)
    INT_BINOP(SHL, <<)
    INT_BINOP(SHR, >>)

    /* ---- Unary ---- */

    CASE(NEG): {
        Value *v = vm_pop();
        if (v->type == VAL_NUM) vm_push(make_num(-v->data.num));
        else vm_push(make_num(0));
        val_decref(v);
        DISPATCH();
    }

    CASE(NOT): {
        Value *v = vm_pop();
        vm_push(make_num(is_truthy(v) ? 0.0 : 1.0));
        val_decref(v);
        DISPATCH();
    }

    CASE(BNOT): {
        Value *v = vm_pop();
        if (v->type == VAL_NUM)
            vm_push(make_num((double)(~(int64_t)v->data.num)));
        else vm_push(make_num(0));
        val_decref(v);
        DISPATCH();
    }

    /* ---- Comparison ---- */

    CASE(EQ): {
        Value *b = vm_pop(); Value *a = vm_pop();
        int eq = 0;
        if (a->type == VAL_NUM && b->type == VAL_NUM) eq = a->data.num == b->data.num;
        else if (a->type == VAL_STR && b->type == VAL_STR) eq = strcmp(a->data.str, b->data.str) == 0;
        else if (a->type == VAL_NULL && b->type == VAL_NULL) eq = 1;
        else eq = (a == b);
        vm_push(make_num(eq ? 1.0 : 0.0));
        val_decref(a); val_decref(b);
        DISPATCH();
    }

    CASE(NE): {
        Value *b = vm_pop(); Value *a = vm_pop();
        int eq = 0;
        if (a->type == VAL_NUM && b->type == VAL_NUM) eq = a->data.num == b->data.num;
        else if (a->type == VAL_STR && b->type == VAL_STR) eq = strcmp(a->data.str, b->data.str) == 0;
        else if (a->type == VAL_NULL && b->type == VAL_NULL) eq = 1;
        else eq = (a == b);
        vm_push(make_num(eq ? 0.0 : 1.0));
        val_decref(a); val_decref(b);
        DISPATCH();
    }

#define NUM_CMP(NAME, OP) \
    CASE(NAME): { \
        Value *b = vm_pop(); Value *a = vm_pop(); \
        if (a->type == VAL_NUM && b->type == VAL_NUM) \
            vm_push(make_num(a->data.num OP b->data.num ? 1.0 : 0.0)); \
        else vm_push(make_num(0)); \
        val_decref(a); val_decref(b); \
        DISPATCH(); \
    }

    NUM_CMP(LT, <)
    NUM_CMP(GT, >)
    NUM_CMP(LE, <=)
    NUM_CMP(GE, >=)

    /* ---- Variables ---- */

    CASE(GET_LOCAL): {
        uint16_t slot = read_u16(ip); ip += 2;
        int abs_slot = frame->bp + slot;
        if (abs_slot < g_vm.sp) {
            Value *v = g_vm.stack[abs_slot];
            val_incref(v);
            vm_push(v);
        } else {
            vm_push(make_null());
        }
        DISPATCH();
    }

    CASE(SET_LOCAL): {
        uint16_t slot = read_u16(ip); ip += 2;
        int abs_slot = frame->bp + slot;
        Value *v = vm_peek(0);
        val_incref(v);
        /* Ensure slot exists */
        while (abs_slot >= g_vm.sp)
            vm_push(make_null());
        val_decref(g_vm.stack[abs_slot]);
        g_vm.stack[abs_slot] = v;
        DISPATCH();
    }

    CASE(GET_NAME): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *name = chunk->constants[idx]->data.str;
        uint32_t h = env_hash_name(name);
        Value *v = env_get_hashed(frame->env, name, h);
        if (!v) {
            runtime_error(current_line, "undefined variable '%s'", name);
            v = make_null();
        } else {
            val_incref(v);
        }
        vm_push(v);
        DISPATCH();
    }

    CASE(SET_NAME): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *name = chunk->constants[idx]->data.str;
        uint32_t h = env_hash_name(name);
        Value *v = vm_peek(0);
        env_set_hashed(frame->env, name, h, v);
        DISPATCH();
    }

    CASE(SET_NAME_LOCAL): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *name = chunk->constants[idx]->data.str;
        uint32_t h = env_hash_name(name);
        Value *v = vm_peek(0);
        env_set_local_hashed(frame->env, name, h, v);
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
        Value *v = vm_pop();
        if (!is_truthy(v)) ip += offset;
        val_decref(v);
        DISPATCH();
    }

    CASE(JUMP_IF_TRUE): {
        uint16_t offset = read_u16(ip); ip += 2;
        Value *v = vm_pop();
        if (is_truthy(v)) ip += offset;
        val_decref(v);
        DISPATCH();
    }

    CASE(JUMP_IF_FALSE_PEEK): {
        uint16_t offset = read_u16(ip); ip += 2;
        if (!is_truthy(vm_peek(0))) ip += offset;
        DISPATCH();
    }

    CASE(JUMP_IF_TRUE_PEEK): {
        uint16_t offset = read_u16(ip); ip += 2;
        if (is_truthy(vm_peek(0))) ip += offset;
        DISPATCH();
    }

    /* ---- Stack ---- */

    CASE(POP): {
        Value *v = vm_pop();
        val_decref(v);
        DISPATCH();
    }

    CASE(DUP): {
        Value *v = vm_peek(0);
        val_incref(v);
        vm_push(v);
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
        Value *fn_val = g_vm.stack[g_vm.sp - 1 - argc];

        if (fn_val->type == VAL_BUILTIN) {
            /* Pack args into a list for the builtin */
            Value *arg;
            if (argc == 1) {
                arg = g_vm.stack[g_vm.sp - 1];
                val_incref(arg);
            } else {
                arg = make_list(argc);
                for (int i = 0; i < argc; i++) {
                    list_append(arg, g_vm.stack[g_vm.sp - argc + i]);
                }
            }
            /* Pop args + fn from stack */
            for (int i = 0; i < argc; i++)
                val_decref(vm_pop());
            val_decref(vm_pop()); /* fn */

            Env *saved = g_builtin_call_env;
            g_builtin_call_env = frame->env;
            Value *result = fn_val->data.builtin(arg);
            g_builtin_call_env = saved;

            val_decref(arg);
            if (!result) result = make_null();
            else val_incref(result);
            vm_push(result);

            /* Check for errors */
            if (g_has_error && frame->is_try && frame->catch_ip) {
                g_has_error = 0;
                g_try_depth--;
                frame->is_try = 0;
                /* Restore stack to try entry point */
                while (g_vm.sp > frame->catch_bp)
                    val_decref(vm_pop());
                /* Push error message for catch block */
                vm_push(make_str(g_error_msg));
                ip = frame->catch_ip;
                frame->catch_ip = NULL;
            }
            DISPATCH();
        }

        if (fn_val->type == VAL_FN) {
            /* Save current frame state */
            frame->ip = ip;

            if (fn_val->data.fn.body_count == -1) {
                /* Bytecode function */
                EigsChunk *fn_chunk = (EigsChunk *)fn_val->data.fn.body;
                Env *call_env = env_new(fn_val->data.fn.closure);

                /* Bind parameters into the Env AND set up stack locals.
                 * The function body uses OP_GET_NAME for now (dynamic lookup).
                 * TODO: optimize to stack-based locals once the basic path works. */
                int param_count = fn_val->data.fn.param_count;
                if (param_count > 1 && argc > 0) {
                    int bound = param_count < (int)argc ? param_count : (int)argc;
                    for (int i = 0; i < bound; i++)
                        env_set_local(call_env, fn_val->data.fn.params[i],
                                      g_vm.stack[g_vm.sp - argc + i]);
                } else if (param_count == 1) {
                    if (argc == 1) {
                        env_set_local(call_env, fn_val->data.fn.params[0],
                                      g_vm.stack[g_vm.sp - 1]);
                    } else {
                        Value *arg_list = make_list(argc);
                        for (int i = 0; i < argc; i++)
                            list_append(arg_list, g_vm.stack[g_vm.sp - argc + i]);
                        env_set_local(call_env, fn_val->data.fn.params[0], arg_list);
                        val_decref(arg_list);
                    }
                }

                /* Pop args + fn from stack */
                for (int i = 0; i < argc; i++)
                    val_decref(vm_pop());
                val_decref(vm_pop());

                Value *result = vm_run(fn_chunk, call_env);
                env_free(call_env);
                if (!result) result = make_null();
                vm_push(result);
            } else {
                /* AST-based function — use existing eval path */
                /* This handles the transition period */
                extern Value* eval_block(ASTNode **stmts, int count, Env *env);
                Env *call_env = env_new(fn_val->data.fn.closure);

                if (fn_val->data.fn.param_count > 1 && argc > 0) {
                    int bound = fn_val->data.fn.param_count;
                    if (bound > argc) bound = argc;
                    for (int i = 0; i < bound; i++)
                        env_set_local(call_env, fn_val->data.fn.params[i],
                                      g_vm.stack[g_vm.sp - argc + i]);
                } else if (fn_val->data.fn.param_count == 1) {
                    if (argc == 1) {
                        env_set_local(call_env, fn_val->data.fn.params[0],
                                      g_vm.stack[g_vm.sp - 1]);
                    } else {
                        Value *arg_list = make_list(argc);
                        for (int i = 0; i < argc; i++)
                            list_append(arg_list, g_vm.stack[g_vm.sp - argc + i]);
                        env_set_local(call_env, fn_val->data.fn.params[0], arg_list);
                        val_decref(arg_list);
                    }
                }

                for (int i = 0; i < argc; i++)
                    val_decref(vm_pop());
                val_decref(vm_pop());

                g_returning = 0;
                g_return_val = NULL;
                Value *result = eval_block(fn_val->data.fn.body,
                                           fn_val->data.fn.body_count, call_env);
                if (g_returning) {
                    g_returning = 0;
                    result = g_return_val ? g_return_val : make_null();
                }
                env_free(call_env);
                if (!result) result = make_null();
                else val_incref(result);
                vm_push(result);
            }

            /* Restore frame */
            frame = &g_vm.frames[g_vm.frame_count - 1];
            ip = frame->ip;
            chunk = frame->chunk;
            DISPATCH();
        }

        /* Not callable */
        runtime_error(current_line, "attempt to call non-function value");
        for (int i = 0; i < argc; i++) val_decref(vm_pop());
        val_decref(vm_pop());
        vm_push(make_null());
        DISPATCH();
    }

    CASE(RETURN): {
        Value *result = vm_pop();
        /* Clean up stack back to frame base */
        while (g_vm.sp > frame->bp) {
            val_decref(vm_pop());
        }
        g_vm.frame_count--;
        return result;
    }

    CASE(RETURN_NULL): {
        while (g_vm.sp > frame->bp)
            val_decref(vm_pop());
        g_vm.frame_count--;
        return make_null();
    }

    /* ---- Data structures ---- */

    CASE(LIST): {
        uint16_t count = read_u16(ip); ip += 2;
        Value *list = make_list(count);
        for (int i = count - 1; i >= 0; i--) {
            /* Items are on stack in order, bottom = first element */
            Value *item = g_vm.stack[g_vm.sp - count + i];
            list_append(list, item);
        }
        /* Fix order — we appended in reverse stack order, need forward */
        /* Actually stack has first element deepest, so we need: */
        Value *list2 = make_list(count);
        for (int i = 0; i < count; i++) {
            list_append(list2, g_vm.stack[g_vm.sp - count + i]);
        }
        val_decref(list);
        for (int i = 0; i < count; i++)
            val_decref(vm_pop());
        vm_push(list2);
        DISPATCH();
    }

    CASE(DICT): {
        uint16_t count = read_u16(ip); ip += 2;
        Value *dict = make_dict(count);
        /* Stack: key0, val0, key1, val1, ... (bottom to top) */
        int base = g_vm.sp - count * 2;
        for (int i = 0; i < count; i++) {
            Value *k = g_vm.stack[base + i * 2];
            Value *v = g_vm.stack[base + i * 2 + 1];
            const char *key_str = (k->type == VAL_STR) ? k->data.str : "?";
            dict_set(dict, key_str, v);
        }
        for (int i = 0; i < count * 2; i++)
            val_decref(vm_pop());
        vm_push(dict);
        DISPATCH();
    }

    CASE(INDEX_GET): {
        Value *idx = vm_pop(); Value *target = vm_pop();
        Value *result = make_null();
        if (target->type == VAL_LIST && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.list.count) {
                result = target->data.list.items[i];
                val_incref(result);
            } else {
                runtime_error(current_line, "index %d out of bounds (list length %d)", i, target->data.list.count);
            }
        } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
            Value *v = dict_get(target, idx->data.str);
            if (v) { result = v; val_incref(result); }
        } else if (target->type == VAL_STR && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < (int)strlen(target->data.str)) {
                char buf[2] = { target->data.str[i], 0 };
                result = make_str(buf);
            }
        } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.buffer.count)
                result = make_num(target->data.buffer.data[i]);
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
            }
        } else if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.buffer.count && val->type == VAL_NUM)
                target->data.buffer.data[i] = (int)val->data.num;
        } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
            dict_set(target, idx->data.str, val);
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
        Value *target = vm_pop();
        Value *result = make_null();
        if (target->type == VAL_DICT) {
            Value *v = dict_get(target, key);
            if (v) { result = v; val_incref(result); }
        }
        val_decref(target);
        vm_push(result);
        DISPATCH();
    }

    CASE(DOT_SET): {
        uint16_t idx = read_u16(ip); ip += 2;
        const char *key = chunk->constants[idx]->data.str;
        Value *val = vm_pop(); Value *target = vm_pop();
        if (target->type == VAL_DICT)
            dict_set(target, key, val);
        val_decref(target);
        val_incref(val);
        vm_push(val);
        val_decref(val);
        DISPATCH();
    }

    /* ---- Iteration ---- */

    CASE(ITER_SETUP): {
        Value *iterable = vm_pop();
        Value *state = make_iter_state(iterable);
        val_decref(iterable);
        vm_push(state);
        DISPATCH();
    }

    CASE(ITER_NEXT): {
        uint16_t exit_offset = read_u16(ip); ip += 2;
        Value *state = vm_peek(0);
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
            /* Update index */
            val_decref(state->data.list.items[1]);
            state->data.list.items[1] = make_num(idx + 1);
            vm_push(elem);
        }
        DISPATCH();
    }

    CASE(BREAK): {
        g_breaking = 1;
        /* The compiler emits BREAK as a JUMP to the loop exit */
        /* This case should not be reached in normal flow */
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
        /* Save error handler: catch target IP and stack depth */
        frame->is_try = 1;
        frame->catch_ip = ip + catch_offset;
        frame->catch_bp = g_vm.sp;
        DISPATCH();
    }

    CASE(TRY_END): {
        g_try_depth--;
        frame->is_try = 0;
        frame->catch_ip = NULL;
        DISPATCH();
    }

    /* ---- Observer ---- */

    CASE(OBSERVE_ASSIGN): {
        /* uint16_t name_idx = */ read_u16(ip); ip += 2;
        Value *v = vm_peek(0);
        if (g_unobserved_depth == 0 && v) {
            v->dirty = 1;
            g_last_observer = v;
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
        case 1: /* who */
            if (v) result = make_str(
                v->type == VAL_NUM ? "num" :
                v->type == VAL_STR ? "str" :
                v->type == VAL_LIST ? "list" :
                v->type == VAL_DICT ? "dict" :
                v->type == VAL_FN ? "fn" :
                v->type == VAL_BUILTIN ? "builtin" :
                v->type == VAL_BUFFER ? "buffer" : "unknown");
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
            dict_set(mod_dict, mod_env->names[mi], mod_env->values[mi]);
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
        /* The accumulator list is below the iterator state on the stack.
         * Find it by scanning down. For now, use a simple approach. */
        /* Walk stack to find the list accumulator */
        for (int i = g_vm.sp - 1; i >= 0; i--) {
            if (g_vm.stack[i] && g_vm.stack[i]->type == VAL_LIST &&
                g_vm.stack[i] != item) {
                list_append(g_vm.stack[i], item);
                break;
            }
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
