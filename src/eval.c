/*
 * EigenScript evaluator. Tree-walking interpreter over the AST,
 * plus the observer-entropy update that runs on every assignment.
 */

#include "eigenscript.h"

/* make_node is defined in parser.c; eval uses it once to build a
 * synthetic AST_RETURN node. */
ASTNode* make_node(ASTType type, int line);

/* Core diagnostics defined in eigenscript.c. */
void runtime_error(int line, const char *fmt, ...);
const char* val_type_name(ValType t);
extern __thread int g_try_depth;
Value* builtin_free_val(Value *arg);



static double compute_entropy_impl(Value *v, int depth) {
    if (!v || depth > 64) return 0.0;
    switch (v->type) {
        case VAL_NULL: return 0.0;
        case VAL_NUM: {
            double x = fabs(v->data.num);
            if (x == 0.0 || x == 1.0) return 0.0;
            double p = 1.0 / (1.0 + x);
            if (p <= 0.0 || p >= 1.0) return 0.0;
            return -(p * log2(p) + (1.0-p) * log2(1.0-p));
        }
        case VAL_STR: {
            if (!v->data.str || !v->data.str[0]) return 0.0;
            int freq[256] = {0};
            int len = 0;
            for (const char *c = v->data.str; *c; c++) {
                freq[(unsigned char)*c]++;
                len++;
            }
            if (len == 0) return 0.0;
            double h = 0.0;
            for (int i = 0; i < 256; i++) {
                if (freq[i] > 0) {
                    double p = (double)freq[i] / len;
                    h -= p * log2(p);
                }
            }
            return h;
        }
        case VAL_LIST: {
            if (v->data.list.count == 0) return 0.0;
            double sum = 0.0;
            for (int i = 0; i < v->data.list.count; i++) {
                sum += compute_entropy_impl(v->data.list.items[i], depth + 1);
            }
            return sum / v->data.list.count + log2(v->data.list.count + 1);
        }
        case VAL_DICT: {
            if (v->data.dict.count == 0) return 0.0;
            double sum = 0.0;
            for (int i = 0; i < v->data.dict.count; i++) {
                sum += compute_entropy_impl(v->data.dict.vals[i], depth + 1);
            }
            return sum / v->data.dict.count + log2(v->data.dict.count + 1);
        }
        case VAL_FN: return 1.0;
        case VAL_BUILTIN: return 0.0;
        case VAL_JSON_RAW: return 0.0;
        case VAL_BUFFER: return log2(v->data.buffer.count + 1);
    }
    return 0.0;
}

static double compute_entropy(Value *v) {
    return compute_entropy_impl(v, 0);
}

static void update_observer(Value *v) {
    if (!v) return;
    double new_entropy = compute_entropy(v);
    v->prev_dH = v->dH;
    v->dH = new_entropy - v->last_entropy;
    v->entropy = new_entropy;
    v->last_entropy = new_entropy;
    v->dirty = 0;
}

/* Lazily recompute entropy when a consumer reads observer state. */
static void ensure_observer_fresh(Value *v) {
    if (v && v->dirty) {
        update_observer(v);
    }
}

/* Non-static wrapper for builtins.c */
void observer_ensure_fresh(Value *v) {
    ensure_observer_fresh(v);
}

/* Mark a value as needing entropy recomputation. Copies tracking
 * state from the previous value at this binding (if any). */
static void mark_observer_dirty(Value *val, Value *old) {
    if (!val) return;
    if (old) {
        /* If the old value was never observed, compute its entropy now
         * so that dH tracking stays correct across assignment chains. */
        ensure_observer_fresh(old);
        val->last_entropy = old->entropy;
        val->obs_age = old->obs_age + 1;
        val->dH = old->dH;
        val->prev_dH = old->prev_dH;
        val->entropy = old->entropy;
        val->dirty = 1;
    } else {
        /* First assignment: compute entropy eagerly so subsequent
         * fast-path mutations have a correct last_entropy baseline. */
        update_observer(val);
        val->obs_age = 1;
    }
}

/* Recursion-depth guard. Each user-visible recursion level typically
 * consumes 3-6 eval_node frames (wrapper + _impl + sub-expressions).
 * Cap at 500 to leave several MB of headroom below the default 8MB
 * linux stack. The goal is to surface runaway recursion as a catchable
 * runtime error rather than a SIGSEGV. */
#define EIGS_MAX_EVAL_DEPTH 500
static __thread int g_eval_depth = 0;
__thread Value *g_last_observer = NULL;
__thread Env *g_builtin_call_env = NULL;

/* Unobserved-block depth. Nonzero means assignments inside this region
 * skip update_observer and attempt in-place numeric mutation. The
 * observer's existing entropy/dH/obs_age on touched Values goes stale —
 * by design. User declared they won't interrogate. */
__thread int g_unobserved_depth = 0;

/* Reusable scratch lists for 'f of [a, b, ...]' calls.  Avoids allocating
 * a fresh heap list on every call — the dominant source of memory growth
 * in tight loops (emulators, numeric kernels).  Uses a stack to handle
 * nested calls like assert_eq of [add of [3, 4], 7, "msg"]. */
#define SCRATCH_LIST_CAP 16
#define SCRATCH_STACK_DEPTH 32
static __thread struct {
    Value  val;
    Value *items[SCRATCH_LIST_CAP];
    Value  nums[SCRATCH_LIST_CAP];  /* scratch numeric Values for args */
} g_scratch_stack[SCRATCH_STACK_DEPTH];
static __thread int g_scratch_depth = 0;
static __thread int g_scratch_init = 0;

static Value *scratch_list_begin(void) {
    if (!g_scratch_init) {
        for (int i = 0; i < SCRATCH_STACK_DEPTH; i++) {
            g_scratch_stack[i].val.type = VAL_LIST;
            g_scratch_stack[i].val.refcount = 999;
            g_scratch_stack[i].val.arena = 0;
            g_scratch_stack[i].val.data.list.items = g_scratch_stack[i].items;
            g_scratch_stack[i].val.data.list.capacity = SCRATCH_LIST_CAP;
            for (int j = 0; j < SCRATCH_LIST_CAP; j++) {
                g_scratch_stack[i].nums[j].type = VAL_NUM;
                g_scratch_stack[i].nums[j].refcount = 999;
                g_scratch_stack[i].nums[j].arena = 0;
                g_scratch_stack[i].nums[j].data.num = 0;
            }
        }
        g_scratch_init = 1;
    }
    if (g_scratch_depth >= SCRATCH_STACK_DEPTH) return NULL; /* fall back to heap */
    int d = g_scratch_depth++;
    g_scratch_stack[d].val.data.list.count = 0;
    return &g_scratch_stack[d].val;
}
static void scratch_list_push(Value *scratch, Value *item) {
    if (scratch->data.list.count < SCRATCH_LIST_CAP)
        scratch->data.list.items[scratch->data.list.count++] = item;
}
static void scratch_list_end(void) {
    if (g_scratch_depth > 0) g_scratch_depth--;
}
static int scratch_num_index(Value *v, int depth) {
    if (!v || depth < 0 || depth >= SCRATCH_STACK_DEPTH) return -1;
    for (int i = 0; i < SCRATCH_LIST_CAP; i++) {
        if (v == &g_scratch_stack[depth].nums[i])
            return i;
    }
    return -1;
}
static Value *materialize_scratch_result(Value *result, int depth) {
    if (!result || depth < 0 || depth >= SCRATCH_STACK_DEPTH) return result;
    if (result == &g_scratch_stack[depth].val) {
        Value *heap_list = make_list(result->data.list.count);
        for (int i = 0; i < result->data.list.count; i++) {
            Value *item = result->data.list.items[i];
            int copied = 0;
            if (scratch_num_index(item, depth) >= 0) {
                item = make_num(item->data.num);
                copied = 1;
            }
            list_append(heap_list, item);
            if (copied) val_decref(item);
        }
        return heap_list;
    }
    if (scratch_num_index(result, depth) >= 0)
        return make_num(result->data.num);
    for (int i = 0; i < g_scratch_stack[depth].val.data.list.count; i++) {
        if (result == g_scratch_stack[depth].val.data.list.items[i]) {
            val_incref(result);
            return result;
        }
    }
    return result;
}

static int expr_result_is_owned(ASTNode *node) {
    if (!node) return 0;
    switch (node->type) {
        case AST_NUM:
        case AST_STR:
        case AST_BINOP:
        case AST_UNARY:
        case AST_RELATION:
        case AST_INDEX:
        case AST_LIST:
        case AST_DICT:
        case AST_LISTCOMP:
        case AST_LAMBDA:
        case AST_FUNC:
        case AST_IMPORT:
        case AST_IF:
        case AST_LOOP:
        case AST_FOR:
        case AST_MATCH:
        case AST_BLOCK:
        case AST_UNOBSERVED:
            return 1;
        default:
            return 0;
    }
}

int eval_result_is_owned(ASTNode *node) {
    return expr_result_is_owned(node);
}

static int list_contains_value(Value *list, Value *needle) {
    if (!list || list->type != VAL_LIST || !needle) return 0;
    for (int i = 0; i < list->data.list.count; i++) {
        if (list->data.list.items[i] == needle)
            return 1;
    }
    return 0;
}

static Value *own_builtin_result(Value *result, Value *arg, ASTNode *arg_expr) {
    if (!result) return result;
    if (result == arg) {
        if (!expr_result_is_owned(arg_expr))
            val_incref(result);
    } else if (list_contains_value(arg, result)) {
        val_incref(result);
    }
    return result;
}

static void env_set_eval_result(Env *env, const char *name, uint32_t name_hash, Value *val, ASTNode *expr, int local_only) {
    int release_temp = expr_result_is_owned(expr);
    if (local_only)
        env_set_local_hashed(env, name, name_hash, val);
    else
        env_set_hashed(env, name, name_hash, val);
    if (release_temp)
        val_decref(val);
}

static void release_eval_temp(ASTNode *expr, Value *val) {
    if (expr_result_is_owned(expr))
        val_decref(val);
}

static void own_block_result_if_needed(ASTNode **stmts, int count, Value *result) {
    if (count > 0 && !expr_result_is_owned(stmts[count - 1]))
        val_incref(result);
}

/* Observer classification thresholds — tunable via set_observer_thresholds.
 * Defaults are very precise. Advanced users studying slow convergence may
 * need to loosen these. Changing them affects how `report of`, `converged`,
 * `stable`, `improving`, `oscillating`, `diverging`, and `equilibrium`
 * classify variable trajectories.
 *
 *   dh_zero:  |dH| below this is "essentially zero change"  (default 0.001)
 *   dh_small: |dH| below this is "small change"              (default 0.01)
 *   h_low:    entropy below this means "low information"      (default 0.1)
 */
__thread double g_obs_dh_zero  = 0.001;
__thread double g_obs_dh_small = 0.01;
__thread double g_obs_h_low    = 0.1;

static Value* eval_node_impl(ASTNode *node, Env *env);

/* Purely-numeric RHS fast path used by the unobserved fast mutation
 * path. Computes a side-effect-free arithmetic tree into *out without
 * allocating any intermediate Values. Returns 1 on success, 0 on bail.
 * Shares the eval recursion counter so deeply-nested arithmetic bails
 * rather than overflowing the C stack. */
static int eval_num_fast(ASTNode *node, Env *env, double *out) {
    if (!node) return 0;
    if (g_eval_depth >= EIGS_MAX_EVAL_DEPTH) return 0;
    g_eval_depth++;
    int ok = 0;
    switch (node->type) {
        case AST_NUM:
            *out = num_guard(node->data.num);
            ok = 1;
            break;
        case AST_IDENT: {
            Value *v = env_get_hashed(env, node->data.ident.name, node->name_hash);
            if (v && v->type == VAL_NUM) { *out = v->data.num; ok = 1; }
            break;
        }
        case AST_DOT: {
            if (node->data.dot.target->type != AST_IDENT &&
                node->data.dot.target->type != AST_DOT &&
                node->data.dot.target->type != AST_INDEX) break;
            Value *target = eval_node(node->data.dot.target, env);
            if (target && target->type == VAL_DICT) {
                Value *v = dict_get_hashed(target, node->data.dot.key, node->name_hash);
                if (v && v->type == VAL_NUM) { *out = v->data.num; ok = 1; }
            }
            release_eval_temp(node->data.dot.target, target);
            break;
        }
        case AST_INDEX: {
            if (node->data.index.target->type != AST_IDENT &&
                node->data.index.target->type != AST_DOT &&
                node->data.index.target->type != AST_INDEX) break;
            Value *target = eval_node(node->data.index.target, env);
            if (!target) {
                release_eval_temp(node->data.index.target, target);
                break;
            }
            double idx_d;
            if (!eval_num_fast(node->data.index.index, env, &idx_d)) {
                release_eval_temp(node->data.index.target, target);
                break;
            }
            int i = (int)idx_d;
            if (target->type == VAL_LIST) {
                if (i < 0 || i >= target->data.list.count) {
                    release_eval_temp(node->data.index.target, target);
                    break;
                }
                Value *v = target->data.list.items[i];
                if (v && v->type == VAL_NUM) { *out = v->data.num; ok = 1; }
            } else if (target->type == VAL_BUFFER) {
                if (i < 0 || i >= target->data.buffer.count) {
                    release_eval_temp(node->data.index.target, target);
                    break;
                }
                *out = target->data.buffer.data[i];
                ok = 1;
            }
            release_eval_temp(node->data.index.target, target);
            break;
        }
        case AST_UNARY: {
            double x;
            if (!eval_num_fast(node->data.unary.operand, env, &x)) break;
            if (node->data.unary.op[0] == '-') { *out = num_guard(-x); ok = 1; }
            else if (node->data.unary.op[0] == '~') { *out = (double)(~(int64_t)x); ok = 1; }
            break;
        }
        case AST_BINOP: {
            const char *op = node->data.binop.op;
            double l, r;
            if (!eval_num_fast(node->data.binop.left, env, &l)) break;
            if (!eval_num_fast(node->data.binop.right, env, &r)) break;
            if (op[1] == '\0') {
                switch (op[0]) {
                    case '+': *out = num_guard(l + r); ok = 1; break;
                    case '-': *out = num_guard(l - r); ok = 1; break;
                    case '*': *out = num_guard(l * r); ok = 1; break;
                    case '/': if (r != 0) { *out = num_guard(l / r); ok = 1; } break;
                    case '%': if (r != 0) { *out = num_guard(fmod(l, r)); ok = 1; } break;
                    case '&': *out = (double)((int64_t)l & (int64_t)r); ok = 1; break;
                    case '|': *out = (double)((int64_t)l | (int64_t)r); ok = 1; break;
                    case '^': *out = (double)((int64_t)l ^ (int64_t)r); ok = 1; break;
                    case '<': *out = (l < r) ? 1.0 : 0.0; ok = 1; break;
                    case '>': *out = (l > r) ? 1.0 : 0.0; ok = 1; break;
                    case '=': *out = (l == r) ? 1.0 : 0.0; ok = 1; break;
                }
            } else if (op[0] == '<' && op[1] == '<') {
                int64_t shift = (int64_t)r;
                if (shift >= 0 && shift < 64) { *out = (double)((int64_t)l << shift); ok = 1; }
                else { *out = 0.0; ok = 1; }
            } else if (op[0] == '>' && op[1] == '>') {
                int64_t shift = (int64_t)r;
                if (shift >= 0 && shift < 64) { *out = (double)((uint64_t)(int64_t)l >> shift); ok = 1; }
                else { *out = 0.0; ok = 1; }
            } else if (op[0] == '<' && op[1] == '=') {
                *out = (l <= r) ? 1.0 : 0.0; ok = 1;
            } else if (op[0] == '>' && op[1] == '=') {
                *out = (l >= r) ? 1.0 : 0.0; ok = 1;
            } else if (op[0] == '!' && op[1] == '=') {
                *out = (l != r) ? 1.0 : 0.0; ok = 1;
            }
            break;
        }
        default:
            break;
    }
    g_eval_depth--;
    return ok;
}

Value* eval_node(ASTNode *node, Env *env) {
    if (!node) return make_null();
    if (g_eval_depth >= EIGS_MAX_EVAL_DEPTH) {
        runtime_error(node->line, "eval recursion too deep (limit %d)", EIGS_MAX_EVAL_DEPTH);
        return make_null();
    }
    g_eval_depth++;
    Value *result = eval_node_impl(node, env);
    g_eval_depth--;
    return result;
}

static Value* eval_node_impl(ASTNode *node, Env *env) {
    if (!node) return make_null();

    switch (node->type) {
    case AST_NUM:
        return make_num(node->data.num);

    case AST_STR:
        return make_str(node->data.str);

    case AST_NULL:
        return make_null();

    case AST_IDENT: {
        Value *v = env_get_hashed(env, node->data.ident.name, node->name_hash);
        if (!v) {
            runtime_error(node->line, "undefined variable '%s'", node->data.ident.name);
            return make_null();
        }
        return v;
    }

    case AST_ASSIGN: {
        /* Fast path: mutate existing NUM slot in-place when RHS is a
         * pure numeric expression.  Avoids make_num allocation entirely.
         * Inside unobserved blocks, also skip observer tracking. */
        int local_only = node->data.assign.local_only;
        Value *old = local_only
            ? env_get_local_hashed(env, node->data.assign.name, node->name_hash)
            : env_get_hashed(env, node->data.assign.name, node->name_hash);
        if (old && old->type == VAL_NUM && !old->arena && old->refcount <= 1) {
            double result;
            if (eval_num_fast(node->data.assign.expr, env, &result)) {
                if (g_unobserved_depth == 0) {
                    /* Eagerly update observer for in-place NUM mutation.
                     * compute_entropy for NUM is O(1) — a few FP ops. */
                    double prev_ent = old->last_entropy;
                    old->data.num = num_guard(result);
                    double new_ent = compute_entropy(old);
                    old->prev_dH = old->dH;
                    old->dH = new_ent - prev_ent;
                    old->entropy = new_ent;
                    old->last_entropy = new_ent;
                    old->obs_age++;
                    old->dirty = 0;
                    g_last_observer = old;
                } else {
                    old->data.num = num_guard(result);
                }
                return old;
            }
        }
        if (g_unobserved_depth > 0) {
            Value *val = eval_node(node->data.assign.expr, env);
            /* If the target already holds a NUM and the new value is also
             * a fresh NUM (refcount 1, not in any env), mutate in-place
             * and recycle the fresh value.  Catches function-call results
             * that eval_num_fast can't handle. */
            if (val && val->type == VAL_NUM && val->refcount == 1 && !val->arena
                && old && old->type == VAL_NUM && !old->arena && old->refcount <= 1) {
                old->data.num = val->data.num;
                recycle_intermediate(val);
                return old;
            }
            env_set_eval_result(env, node->data.assign.name, node->name_hash, val, node->data.assign.expr, local_only);
            return val;
        }
        Value *val = eval_node(node->data.assign.expr, env);
        old = local_only
            ? env_get_local_hashed(env, node->data.assign.name, node->name_hash)
            : env_get_hashed(env, node->data.assign.name, node->name_hash);
        mark_observer_dirty(val, old);
        env_set_eval_result(env, node->data.assign.name, node->name_hash, val, node->data.assign.expr, local_only);
        g_last_observer = val;
        return val;
    }

    case AST_BINOP: {
        const char *op = node->data.binop.op;

        if (strcmp(op, "and") == 0) {
            Value *left = eval_node(node->data.binop.left, env);
            if (!is_truthy(left)) {
                release_eval_temp(node->data.binop.left, left);
                return make_num(0);
            }
            release_eval_temp(node->data.binop.left, left);
            Value *right = eval_node(node->data.binop.right, env);
            int truthy = is_truthy(right);
            release_eval_temp(node->data.binop.right, right);
            return make_num(truthy ? 1 : 0);
        }
        if (strcmp(op, "or") == 0) {
            Value *left = eval_node(node->data.binop.left, env);
            if (is_truthy(left)) {
                release_eval_temp(node->data.binop.left, left);
                return make_num(1);
            }
            release_eval_temp(node->data.binop.left, left);
            Value *right = eval_node(node->data.binop.right, env);
            int truthy = is_truthy(right);
            release_eval_temp(node->data.binop.right, right);
            return make_num(truthy ? 1 : 0);
        }

        Value *left = eval_node(node->data.binop.left, env);
        Value *right = eval_node(node->data.binop.right, env);

        /* Fast path: both operands are NUM — switch dispatch */
        if (left->type == VAL_NUM && right->type == VAL_NUM) {
            double lv = left->data.num, rv = right->data.num;
            int64_t li = (int64_t)lv, ri = (int64_t)rv;
            release_eval_temp(node->data.binop.left, left);
            release_eval_temp(node->data.binop.right, right);

            if (op[1] == '\0') {
                switch (op[0]) {
                    case '+': return make_num(num_guard(lv + rv));
                    case '-': return make_num(num_guard(lv - rv));
                    case '*': return make_num(num_guard(lv * rv));
                    case '/':
                        if (rv == 0) { fprintf(stderr, "Warning line %d: division by zero\n", node->line); return make_num(0); }
                        return make_num(num_guard(lv / rv));
                    case '%':
                        if (rv == 0) { fprintf(stderr, "Warning line %d: division by zero\n", node->line); return make_num(0); }
                        return make_num(num_guard(fmod(lv, rv)));
                    case '&': return make_num((double)(li & ri));
                    case '|': return make_num((double)(li | ri));
                    case '^': return make_num((double)(li ^ ri));
                    case '=': return make_num(lv == rv ? 1 : 0);
                    case '<': return make_num(lv < rv ? 1 : 0);
                    case '>': return make_num(lv > rv ? 1 : 0);
                }
            }
            if (strcmp(op, "<<") == 0) return make_num((ri >= 0 && ri < 64) ? (double)(li << ri) : 0.0);
            if (strcmp(op, ">>") == 0) return make_num((ri >= 0 && ri < 64) ? (double)((uint64_t)li >> ri) : 0.0);
            if (strcmp(op, "<=") == 0) return make_num(lv <= rv ? 1 : 0);
            if (strcmp(op, ">=") == 0) return make_num(lv >= rv ? 1 : 0);
            if (strcmp(op, "!=") == 0) return make_num(lv != rv ? 1 : 0);

            runtime_error(node->line, "cannot apply '%s' to num and num", op);
            return make_null();
        }

        /* String concatenation */
        if (strcmp(op, "+") == 0 && (left->type == VAL_STR || right->type == VAL_STR)) {
            if (left->type == VAL_STR && right->type == VAL_STR) {
                const char *ls = left->data.str;
                const char *rs = right->data.str;
                size_t llen = strlen(ls), rlen = strlen(rs);
                char *buf = xmalloc(llen + rlen + 1);
                memcpy(buf, ls, llen);
                memcpy(buf + llen, rs, rlen + 1);
                release_eval_temp(node->data.binop.left, left);
                release_eval_temp(node->data.binop.right, right);
                return make_str_owned(buf);
            }
            char *ls = value_to_string(left);
            char *rs = value_to_string(right);
            size_t llen = strlen(ls), rlen = strlen(rs);
            char *buf = xmalloc(llen + rlen + 1);
            memcpy(buf, ls, llen);
            memcpy(buf + llen, rs, rlen + 1);
            free(ls); free(rs);
            release_eval_temp(node->data.binop.left, left);
            release_eval_temp(node->data.binop.right, right);
            return make_str_owned(buf);
        }

        /* Equality/inequality for non-numeric types */
        if (strcmp(op, "=") == 0) {
            int eq = 0;
            if (left->type == VAL_STR && right->type == VAL_STR)
                eq = strcmp(left->data.str, right->data.str) == 0;
            else if (left->type == VAL_NULL && right->type == VAL_NULL)
                eq = 1;
            release_eval_temp(node->data.binop.left, left);
            release_eval_temp(node->data.binop.right, right);
            return make_num(eq ? 1 : 0);
        }
        if (strcmp(op, "!=") == 0) {
            int ne = 1;
            if (left->type == VAL_STR && right->type == VAL_STR)
                ne = strcmp(left->data.str, right->data.str) != 0;
            else if (left->type == VAL_NULL && right->type == VAL_NULL)
                ne = 0;
            release_eval_temp(node->data.binop.left, left);
            release_eval_temp(node->data.binop.right, right);
            return make_num(ne ? 1 : 0);
        }

        runtime_error(node->line, "cannot apply '%s' to %s and %s",
                op, val_type_name(left->type), val_type_name(right->type));
        release_eval_temp(node->data.binop.left, left);
        release_eval_temp(node->data.binop.right, right);
        return make_null();
    }

    case AST_UNARY: {
        Value *operand = eval_node(node->data.unary.operand, env);
        if (strcmp(node->data.unary.op, "-") == 0) {
            if (operand->type == VAL_NUM) {
                double n = operand->data.num;
                release_eval_temp(node->data.unary.operand, operand);
                return make_num(-n);
            }
            runtime_error(node->line, "cannot negate %s", val_type_name(operand->type));
            release_eval_temp(node->data.unary.operand, operand);
            return make_null();
        }
        if (strcmp(node->data.unary.op, "not") == 0) {
            int truthy = is_truthy(operand);
            release_eval_temp(node->data.unary.operand, operand);
            return make_num(truthy ? 0 : 1);
        }
        if (strcmp(node->data.unary.op, "~") == 0) {
            if (operand->type == VAL_NUM) {
                double n = operand->data.num;
                release_eval_temp(node->data.unary.operand, operand);
                return make_num((double)(~(int64_t)n));
            }
            runtime_error(node->line, "cannot bitwise-not %s", val_type_name(operand->type));
            release_eval_temp(node->data.unary.operand, operand);
            return make_null();
        }
        release_eval_temp(node->data.unary.operand, operand);
        return make_null();
    }

    case AST_RELATION: {
        /* Fast path: when right side is a list literal (the common 'f of [a,b]'
         * pattern), use a reusable scratch list instead of heap-allocating.
         * This eliminates the dominant memory leak in tight loops. */
        ASTNode *rhs = node->data.relation.right;
        int use_scratch = (rhs->type == AST_LIST && rhs->data.list.count <= SCRATCH_LIST_CAP);
        int scratch_args_evaled = 0;
        Value *scratch_eval_items[SCRATCH_LIST_CAP] = {0};
        Value *right_val;
        Value *left_val = eval_node(node->data.relation.left, env);
        if (use_scratch) {
            right_val = scratch_list_begin();
            if (!right_val) { use_scratch = 0; right_val = eval_node(rhs, env); }
            else if (left_val->type == VAL_BUILTIN) {
                /* For builtins: try scratch nums for ALL-numeric arg lists.
                 * If all args are numeric, the builtin is a pure compute fn
                 * (bit ops, math, etc.) and won't store arg pointers.
                 * If any arg is non-numeric, fall back to eval_node for all
                 * to avoid aliasing in mutation builtins (dict_set, append). */
                int depth = g_scratch_depth - 1;
                int all_num = 1;
                for (int i = 0; i < rhs->data.list.count && all_num; i++) {
                    double d;
                    if (eval_num_fast(rhs->data.list.elems[i], env, &d)) {
                        g_scratch_stack[depth].nums[i].data.num = d;
                    } else {
                        all_num = 0;
                    }
                }
                if (all_num) {
                    for (int i = 0; i < rhs->data.list.count; i++)
                        scratch_list_push(right_val, &g_scratch_stack[depth].nums[i]);
                } else {
                    for (int i = 0; i < rhs->data.list.count; i++) {
                        Value *item = eval_node(rhs->data.list.elems[i], env);
                        scratch_eval_items[i] = item;
                        scratch_list_push(right_val, item);
                    }
                    scratch_args_evaled = 1;
                }
            } else {
                /* For user functions: use eval_node (scratch nums unsafe
                 * because env_set_local stores the pointer). */
                for (int i = 0; i < rhs->data.list.count; i++) {
                    Value *item = eval_node(rhs->data.list.elems[i], env);
                    scratch_eval_items[i] = item;
                    scratch_list_push(right_val, item);
                }
                scratch_args_evaled = 1;
            }
        } else {
            right_val = eval_node(rhs, env);
        }

        if (left_val->type == VAL_BUILTIN) {
            int scratch_depth = use_scratch ? g_scratch_depth - 1 : -1;
            int builtin_consumes_arg = (left_val->data.builtin == builtin_free_val);
            Env *saved_builtin_call_env = g_builtin_call_env;
            g_builtin_call_env = env;
            Value *result = left_val->data.builtin(right_val);
            g_builtin_call_env = saved_builtin_call_env;
            if (use_scratch)
                result = materialize_scratch_result(result, scratch_depth);
            else
                result = own_builtin_result(result, right_val, rhs);
            if (use_scratch && scratch_args_evaled) {
                for (int i = 0; i < rhs->data.list.count; i++)
                    release_eval_temp(rhs->data.list.elems[i], scratch_eval_items[i]);
            } else if (!use_scratch && result != right_val && !builtin_consumes_arg) {
                release_eval_temp(rhs, right_val);
            }
            if (use_scratch) scratch_list_end();
            if (result) result->dirty = 1;
            g_last_observer = result;
            return result;
        }

        if (left_val->type == VAL_FN) {
            Env *call_env = env_new(left_val->data.fn.closure);
            if (left_val->data.fn.param_count > 1 && right_val && right_val->type == VAL_LIST) {
                /* Multi-param: unpack list into named params */
                int bound = left_val->data.fn.param_count;
                if (bound > right_val->data.list.count)
                    bound = right_val->data.list.count;
                for (int pi = 0; pi < bound; pi++) {
                    env_set_local_hashed(call_env, left_val->data.fn.params[pi], left_val->data.fn.param_hashes[pi], right_val->data.list.items[pi]);
                    if (use_scratch)
                        release_eval_temp(rhs->data.list.elems[pi], scratch_eval_items[pi]);
                }
                if (use_scratch) {
                    for (int pi = bound; pi < right_val->data.list.count; pi++)
                        release_eval_temp(rhs->data.list.elems[pi], scratch_eval_items[pi]);
                }
                if (use_scratch) scratch_list_end();
                else release_eval_temp(rhs, right_val);
            } else {
                /* Single param: the list itself is the argument. It may escape
                 * through return, closure, or assignment, so materialize it
                 * instead of exposing reusable scratch storage. */
                if (use_scratch) {
                    Value *heap_list = make_list(right_val->data.list.count);
                    for (int i = 0; i < right_val->data.list.count; i++) {
                        list_append(heap_list, right_val->data.list.items[i]);
                        release_eval_temp(rhs->data.list.elems[i], scratch_eval_items[i]);
                    }
                    scratch_list_end();
                    right_val = heap_list;
                }
                env_set_local_hashed(call_env, left_val->data.fn.params[0], left_val->data.fn.param_hashes[0], right_val);
                if (!use_scratch)
                    release_eval_temp(rhs, right_val);
                else
                    val_decref(right_val);
            }

            g_returning = 0;
            g_return_val = NULL;

            Value *result = eval_block(left_val->data.fn.body, left_val->data.fn.body_count, call_env);
            if (g_returning) {
                g_returning = 0;
                if (g_return_val) g_return_val->dirty = 1;
                g_last_observer = g_return_val;
                env_free(call_env);
                return g_return_val ? g_return_val : make_null();
            }
            if (g_breaking || g_continuing) {
                g_breaking = 0;
                g_continuing = 0;
            }
            own_block_result_if_needed(left_val->data.fn.body, left_val->data.fn.body_count, result);
            if (result) result->dirty = 1;
            g_last_observer = result;
            env_free(call_env);
            return result;
        }

        if (use_scratch) scratch_list_end();
        runtime_error(node->line, "cannot call %s (not a function)",
                val_type_name(left_val->type));
        return make_null();
    }

    case AST_IF: {
        Value *cond = eval_node(node->data.cond.cond, env);
        int truthy = is_truthy(cond);
        release_eval_temp(node->data.cond.cond, cond);
        if (truthy) {
            Value *result = eval_block(node->data.cond.if_body, node->data.cond.if_count, env);
            if (!g_returning && !g_breaking && !g_continuing)
                own_block_result_if_needed(node->data.cond.if_body, node->data.cond.if_count, result);
            return result;
        } else if (node->data.cond.else_body) {
            Value *result = eval_block(node->data.cond.else_body, node->data.cond.else_count, env);
            if (!g_returning && !g_breaking && !g_continuing)
                own_block_result_if_needed(node->data.cond.else_body, node->data.cond.else_count, result);
            return result;
        }
        return make_null();
    }

    case AST_LOOP: {
        Value *result = make_null();
        ASTNode *last_body_stmt = node->data.loop.body_count > 0
                                  ? node->data.loop.body[node->data.loop.body_count - 1]
                                  : NULL;
        int have_body_result = 0;
        int max_iter = 100000000;
        int stall_count = 0;
        int iterations = 0;
        const char *exit_reason = "normal";
        while (max_iter-- > 0) {
            /* Fast path: numeric conditions avoid allocating a Value per iteration */
            double cond_num;
            if (eval_num_fast(node->data.loop.cond, env, &cond_num)) {
                if (cond_num == 0.0) break;
            } else {
                Value *cond = eval_node(node->data.loop.cond, env);
                int truthy = is_truthy(cond);
                release_eval_temp(node->data.loop.cond, cond);
                if (!truthy) break;
            }
            if (have_body_result) {
                release_eval_temp(last_body_stmt, result);
                result = make_null();
                have_body_result = 0;
            }
            iterations++;
            result = eval_block(node->data.loop.body, node->data.loop.body_count, env);
            if (g_returning) return result;
            have_body_result = 1;
            if (g_breaking) { g_breaking = 0; break; }
            if (g_continuing) { g_continuing = 0; }
            /* Skip observer stall check inside unobserved blocks —
             * observer state is stale there and the env_get scan is
             * expensive in scopes with many variables. */
            if (g_unobserved_depth == 0) {
                Value *obs = g_last_observer;
                ensure_observer_fresh(obs);
                if (obs && fabs(obs->dH) < g_obs_dh_zero && obs->entropy >= g_obs_h_low) {
                    stall_count++;
                    if (stall_count >= 100) {
                        exit_reason = "stalled";
                        break;
                    }
                } else {
                    stall_count = 0;
                }
            }
        }
        if (max_iter <= 0) exit_reason = "limit";
        Value *exit_val = make_str(exit_reason);
        env_set(env, "__loop_exit__", exit_val);
        val_decref(exit_val);
        Value *iter_val = make_num(iterations);
        env_set(env, "__loop_iterations__", iter_val);
        val_decref(iter_val);
        if (have_body_result)
            own_block_result_if_needed(node->data.loop.body, node->data.loop.body_count, result);
        return result;
    }

    case AST_FOR: {
        Value *iter = eval_node(node->data.forloop.iter, env);
        if (!iter || (iter->type != VAL_LIST && iter->type != VAL_BUFFER)) {
            runtime_error(node->line, "'for' requires a list or buffer, got %s",
                    iter ? val_type_name(iter->type) : "null");
            release_eval_temp(node->data.forloop.iter, iter);
            return make_null();
        }
        Value *result = make_null();
        ASTNode *last_body_stmt = node->data.forloop.body_count > 0
                                  ? node->data.forloop.body[node->data.forloop.body_count - 1]
                                  : NULL;
        int have_body_result = 0;
        int iter_count = (iter->type == VAL_BUFFER)
                         ? iter->data.buffer.count
                         : iter->data.list.count;
        Env *loop_env = env_new(env);
        for (int i = 0; i < iter_count; i++) {
            if (have_body_result) {
                release_eval_temp(last_body_stmt, result);
                result = make_null();
                have_body_result = 0;
            }
            if (loop_env->captured) {
                loop_env = env_new(env);
            } else if (i > 0) {
                env_clear(loop_env);
            }
            Value *elem = (iter->type == VAL_BUFFER)
                          ? make_num(iter->data.buffer.data[i])
                          : iter->data.list.items[i];
            env_set_local_hashed(loop_env, node->data.forloop.var, node->name_hash, elem);
            if (iter->type == VAL_BUFFER)
                val_decref(elem);
            result = eval_block(node->data.forloop.body, node->data.forloop.body_count, loop_env);
            if (g_returning) { env_free(loop_env); release_eval_temp(node->data.forloop.iter, iter); return result; }
            have_body_result = 1;
            if (g_breaking) { g_breaking = 0; break; }
            if (g_continuing) { g_continuing = 0; }
        }
        if (have_body_result)
            own_block_result_if_needed(node->data.forloop.body, node->data.forloop.body_count, result);
        env_free(loop_env);
        release_eval_temp(node->data.forloop.iter, iter);
        return result;
    }

    case AST_LAMBDA: {
        /* Create a return-wrapping AST node for the body expression */
        ASTNode *ret = make_node(AST_RETURN, node->line);
        ret->data.ret.expr = node->data.lambda.body;
        ASTNode **body = xmalloc(sizeof(ASTNode*));
        body[0] = ret;
        Value *fn = make_fn("", node->data.lambda.params,
                            node->data.lambda.param_count, body, 1, env);
        free(ret);
        free(body);
        env->captured = 1;
        return fn;
    }

    case AST_MATCH: {
        Value *val = eval_node(node->data.match.expr, env);
        for (int i = 0; i < node->data.match.case_count; i++) {
            ASTNode *pattern = node->data.match.patterns[i];
            if (!pattern) {
                /* Wildcard _ — always matches */
                Value *result = eval_block(node->data.match.bodies[i], node->data.match.body_counts[i], env);
                if (!g_returning && !g_breaking && !g_continuing)
                    own_block_result_if_needed(node->data.match.bodies[i], node->data.match.body_counts[i], result);
                release_eval_temp(node->data.match.expr, val);
                return result;
            }
            Value *pat_val = eval_node(pattern, env);
            /* Compare: numbers, strings, or null */
            int matches = 0;
            if (val->type == VAL_NUM && pat_val->type == VAL_NUM)
                matches = (val->data.num == pat_val->data.num);
            else if (val->type == VAL_STR && pat_val->type == VAL_STR)
                matches = (strcmp(val->data.str, pat_val->data.str) == 0);
            else if (val->type == VAL_NULL && pat_val->type == VAL_NULL)
                matches = 1;
            else if (val->type == pat_val->type)
                matches = (val == pat_val); /* identity for other types */
            if (matches) {
                release_eval_temp(pattern, pat_val);
                Value *result = eval_block(node->data.match.bodies[i], node->data.match.body_counts[i], env);
                if (!g_returning && !g_breaking && !g_continuing)
                    own_block_result_if_needed(node->data.match.bodies[i], node->data.match.body_counts[i], result);
                release_eval_temp(node->data.match.expr, val);
                return result;
            }
            release_eval_temp(pattern, pat_val);
        }
        release_eval_temp(node->data.match.expr, val);
        return make_null(); /* no match */
    }

    case AST_DOT_ASSIGN: {
        Value *target = eval_node(node->data.dot_assign.target, env);
        if (!target || target->type != VAL_DICT) {
            runtime_error(node->line, "cannot assign .%s on %s", node->data.dot_assign.key, target ? val_type_name(target->type) : "null");
            return make_null();
        }
        /* Fast path: mutate existing NUM dict value in-place */
        {
            Value *old = dict_get_hashed(target, node->data.dot_assign.key, node->name_hash);
            if (old && old->type == VAL_NUM && !old->arena && old->refcount <= 1) {
                double result;
                if (eval_num_fast(node->data.dot_assign.expr, env, &result)) {
                    old->data.num = num_guard(result);
                    return old;
                }
            }
        }
        Value *val = eval_node(node->data.dot_assign.expr, env);
        dict_set_hashed(target, node->data.dot_assign.key, node->name_hash, val);
        release_eval_temp(node->data.dot_assign.expr, val);
        return val;
    }

    case AST_INDEX_ASSIGN: {
        Value *target = eval_node(node->data.index_assign.target, env);
        if (!target) { runtime_error(node->line, "cannot index-assign on null"); return make_null(); }
        /* Fast path for buffer[idx] = numeric_expr — zero allocation */
        if (target->type == VAL_BUFFER) {
            double idx_d, val_d;
            if (eval_num_fast(node->data.index_assign.index, env, &idx_d) &&
                eval_num_fast(node->data.index_assign.expr, env, &val_d)) {
                int i = (int)idx_d;
                if (i >= 0 && i < target->data.buffer.count)
                    target->data.buffer.data[i] = val_d;
                else
                    runtime_error(node->line, "buffer index %d out of range (length %d)", i, target->data.buffer.count);
                return target;
            }
        }
        Value *idx = eval_node(node->data.index_assign.index, env);
        Value *val = eval_node(node->data.index_assign.expr, env);
        Value *ret = make_null();
        if (target->type == VAL_LIST) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.list.count) {
                val_incref(val);
                val_decref(target->data.list.items[i]);
                target->data.list.items[i] = val;
                ret = val;
            } else {
                runtime_error(node->line, "index %d out of range (list length %d)", i, target->data.list.count);
            }
        } else if (target->type == VAL_BUFFER) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.buffer.count) {
                target->data.buffer.data[i] = val->type == VAL_NUM ? val->data.num : 0.0;
                ret = target;
            } else {
                runtime_error(node->line, "buffer index %d out of range (length %d)", i, target->data.buffer.count);
            }
        } else if (target->type == VAL_DICT && idx->type == VAL_STR) {
            dict_set(target, idx->data.str, val);
            ret = val;
        } else {
            runtime_error(node->line, "cannot index-assign on %s", val_type_name(target->type));
        }
        release_eval_temp(node->data.index_assign.index, idx);
        release_eval_temp(node->data.index_assign.expr, val);
        return ret;
    }

    case AST_IMPORT: {
        /* import math → loads lib/math.eigs into a dict namespace */
        const char *name = node->data.import.module_name;
        char request[4096];
        char path[8192];

        snprintf(request, sizeof(request), "lib/%.1024s.eigs", name);
        if (!resolve_eigenscript_file(request, path, sizeof(path))) {
            runtime_error(node->line, "import: module '%s' not found", name);
            return make_null();
        }

        /* Load and execute in an isolated env (parent = global for builtins) */
        long src_size = 0;
        char *source = read_file_util(path, &src_size);
        if (!source) {
            runtime_error(node->line, "import: cannot read '%s'", path);
            return make_null();
        }

        Env *mod_env = env_new(g_global_env);
        int saved_errors = g_parse_errors;
        g_parse_errors = 0;
        TokenList tl = tokenize(source);
        ASTNode *ast = parse(&tl);
        if (g_parse_errors > 0) {
            runtime_error(node->line, "import: parse errors in '%s'", name);
            g_parse_errors = saved_errors;
            free_tokenlist(&tl);
            free(source);
            return make_null();
        }
        g_parse_errors = saved_errors;
        Env *saved_load_env = g_load_env;
        g_load_env = mod_env;
        Value *ignored = eval_node(ast, mod_env);
        g_load_env = saved_load_env;
        if (ast && ast->type == AST_PROGRAM && ast->data.program.count > 0)
            release_eval_temp(ast->data.program.stmts[ast->data.program.count - 1], ignored);
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);

        /* Collect module's own bindings into a dict.
         * mod_env is a child of env, so mod_env->names[] contains only
         * names that were set in the module (not inherited lookups). */
        Value *mod_dict = make_dict(mod_env->count);
        for (int i = 0; i < mod_env->count; i++) {
            if (mod_env->names[i][0] == '_') continue; /* skip private */
            dict_set(mod_dict, mod_env->names[i], mod_env->values[i]);
        }

        env_set_hashed(env, name, node->name_hash, mod_dict);
        return mod_dict;
    }

    case AST_BREAK:
        g_breaking = 1;
        return make_null();

    case AST_CONTINUE:
        g_continuing = 1;
        return make_null();

    case AST_FUNC: {
        Value *fn = make_fn(node->data.func.name, node->data.func.params,
                           node->data.func.param_count,
                           node->data.func.body, node->data.func.body_count, env);
        env->captured = 1;  /* This env is now a closure — do not free */
        env_set_local_hashed(env, node->data.func.name, node->name_hash, fn);
        return fn;
    }

    case AST_RETURN: {
        Value *val = eval_node(node->data.ret.expr, env);
        int owned = expr_result_is_owned(node->data.ret.expr);
        if (!owned)
            val_incref(val);
        g_returning = 1;
        g_return_val = val;
        return val;
    }

    case AST_TRY: {
        /* Clear error state and run try body */
        g_has_error = 0;
        g_error_msg[0] = '\0';
        g_try_depth++;
        Value *result = make_null();
        for (int i = 0; i < node->data.trycatch.try_count; i++) {
            result = eval_node(node->data.trycatch.try_body[i], env);
            if (g_returning) { g_try_depth--; return result; }
            if (g_breaking || g_continuing) { g_try_depth--; return result; }
            if (g_has_error) break;
        }
        g_try_depth--;
        if (g_has_error) {
            /* Error occurred — run catch body with error bound */
            g_has_error = 0;
            Env *catch_env = env_new(env);
            env_set_local_hashed(catch_env, node->data.trycatch.err_name, node->name_hash, make_str(g_error_msg));
            g_error_msg[0] = '\0';
            result = make_null();
            for (int i = 0; i < node->data.trycatch.catch_count; i++) {
                result = eval_node(node->data.trycatch.catch_body[i], catch_env);
                if (g_returning) { env_free(catch_env); return result; }
                if (g_breaking || g_continuing) { env_free(catch_env); return result; }
            }
            env_free(catch_env);
        }
        return result;
    }

    case AST_LIST: {
        Value *list = make_list(node->data.list.count);
        for (int i = 0; i < node->data.list.count; i++) {
            Value *item = eval_node(node->data.list.elems[i], env);
            list_append(list, item);
            release_eval_temp(node->data.list.elems[i], item);
        }
        return list;
    }

    case AST_DICT: {
        Value *d = make_dict(node->data.dict.count);
        for (int i = 0; i < node->data.dict.count; i++) {
            Value *key = eval_node(node->data.dict.keys[i], env);
            Value *val = eval_node(node->data.dict.vals[i], env);
            char *key_str = value_to_string(key);
            dict_set(d, key_str, val);
            free(key_str);
            release_eval_temp(node->data.dict.keys[i], key);
            release_eval_temp(node->data.dict.vals[i], val);
        }
        return d;
    }

    case AST_DOT: {
        Value *target = eval_node(node->data.dot.target, env);
        if (target->type == VAL_DICT) {
            Value *val = dict_get_hashed(target, node->data.dot.key, node->name_hash);
            return val ? val : make_null();
        }
        runtime_error(node->line, "cannot access .%s on %s", node->data.dot.key, val_type_name(target->type));
        return make_null();
    }

    case AST_INDEX: {
        Value *target = eval_node(node->data.index.target, env);
        Value *idx = eval_node(node->data.index.index, env);
        /* Dict indexing: d["key"] */
        if (target->type == VAL_DICT && idx->type == VAL_STR) {
            Value *val = dict_get(target, idx->data.str);
            if (val) val_incref(val);
            release_eval_temp(node->data.index.index, idx);
            release_eval_temp(node->data.index.target, target);
            return val ? val : make_null();
        }
        if (target->type == VAL_LIST && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            release_eval_temp(node->data.index.index, idx);
            if (i >= 0 && i < target->data.list.count) {
                Value *val = target->data.list.items[i];
                val_incref(val);
                release_eval_temp(node->data.index.target, target);
                return val;
            }
            release_eval_temp(node->data.index.target, target);
            runtime_error(node->line, "index %d out of range (length %d)", i, target->data.list.count);
            return make_null();
        }
        if (target->type == VAL_BUFFER && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            release_eval_temp(node->data.index.index, idx);
            if (i >= 0 && i < target->data.buffer.count) {
                double val = target->data.buffer.data[i];
                release_eval_temp(node->data.index.target, target);
                return make_num(val);
            }
            release_eval_temp(node->data.index.target, target);
            runtime_error(node->line, "buffer index %d out of range (length %d)", i, target->data.buffer.count);
            return make_null();
        }
        if (target->type == VAL_STR && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            int len = strlen(target->data.str);
            release_eval_temp(node->data.index.index, idx);
            if (i >= 0 && i < len) {
                char buf[2] = {target->data.str[i], '\0'};
                release_eval_temp(node->data.index.target, target);
                return make_str(buf);
            }
            release_eval_temp(node->data.index.target, target);
            runtime_error(node->line, "index %d out of range (length %d)", i, len);
            return make_null();
        }
        release_eval_temp(node->data.index.index, idx);
        release_eval_temp(node->data.index.target, target);
        runtime_error(node->line, "cannot index %s", val_type_name(target->type));
        return make_null();
    }

    case AST_LISTCOMP: {
        Value *iter = eval_node(node->data.listcomp.iter, env);
        if (!iter || (iter->type != VAL_LIST && iter->type != VAL_BUFFER)) {
            release_eval_temp(node->data.listcomp.iter, iter);
            return make_list(0);
        }
        int iter_count = (iter->type == VAL_BUFFER) ? iter->data.buffer.count : iter->data.list.count;
        Value *result = make_list(iter_count);
        Env *loop_env = env_new(env);
        for (int i = 0; i < iter_count; i++) {
            if (loop_env->captured) {
                loop_env = env_new(env);
            } else if (i > 0) {
                env_clear(loop_env);
            }
            Value *elem = (iter->type == VAL_BUFFER) ? make_num(iter->data.buffer.data[i]) : iter->data.list.items[i];
            env_set_local_hashed(loop_env, node->data.listcomp.var, node->name_hash, elem);
            if (iter->type == VAL_BUFFER)
                val_decref(elem);
            if (node->data.listcomp.filter) {
                Value *cond = eval_node(node->data.listcomp.filter, loop_env);
                int truthy = is_truthy(cond);
                release_eval_temp(node->data.listcomp.filter, cond);
                if (!truthy) continue;
            }
            Value *val = eval_node(node->data.listcomp.expr, loop_env);
            list_append(result, val);
            release_eval_temp(node->data.listcomp.expr, val);
        }
        env_free(loop_env);
        release_eval_temp(node->data.listcomp.iter, iter);
        return result;
    }

    case AST_PROGRAM: {
        Value *result = make_null();
        for (int i = 0; i < node->data.program.count; i++) {
            result = eval_node(node->data.program.stmts[i], env);
            if (g_returning) return result;
            if (i + 1 < node->data.program.count) {
                release_eval_temp(node->data.program.stmts[i], result);
                result = make_null();
            }
        }
        return result;
    }

    case AST_BLOCK: {
        Value *result = eval_block(node->data.block.stmts, node->data.block.count, env);
        if (!g_returning && !g_breaking && !g_continuing)
            own_block_result_if_needed(node->data.block.stmts, node->data.block.count, result);
        return result;
    }

    case AST_UNOBSERVED: {
        g_unobserved_depth++;
        Value *result = eval_block(node->data.block.stmts, node->data.block.count, env);
        g_unobserved_depth--;
        if (!g_returning && !g_breaking && !g_continuing)
            own_block_result_if_needed(node->data.block.stmts, node->data.block.count, result);
        return result;
    }

    case AST_INTERROGATE: {
        Value *target = eval_node(node->data.interrogate.expr, env);
        ensure_observer_fresh(target);
        switch (node->data.interrogate.kind) {
            case 0:
                if (target->type == VAL_NUM) return make_num(target->data.num);
                if (target->type == VAL_STR) return make_num((double)strlen(target->data.str));
                if (target->type == VAL_LIST) return make_num((double)target->data.list.count);
                if (target->type == VAL_BUFFER) return make_num((double)target->data.buffer.count);
                return make_num(0.0);
            case 1:
                if (node->data.interrogate.expr->type == AST_IDENT)
                    return make_str(node->data.interrogate.expr->data.ident.name);
                if (target->type == VAL_NUM) return make_str("number");
                if (target->type == VAL_STR) return make_str("string");
                if (target->type == VAL_LIST) return make_str("list");
                if (target->type == VAL_BUFFER) return make_str("buffer");
                return make_str("unknown");
            case 2:
                return make_num((double)target->obs_age);
            case 3:
                return make_num(target->entropy);
            case 4:
                return make_num(target->dH);
            case 5: {
                double initial = target->last_entropy > 0 ? target->last_entropy : 1.0;
                return make_num(target->entropy > 0 ? 1.0 - target->entropy / initial : 1.0);
            }
        }
        return make_num(0.0);
    }

    case AST_PREDICATE: {
        Value *last = g_last_observer;
        ensure_observer_fresh(last);
        double h = last ? last->entropy : 0.0;
        double dh = last ? last->dH : 0.0;
        switch (node->data.predicate.kind) {
            case 0: /* converged: dH~0 AND low entropy */
                return make_num((fabs(dh) < g_obs_dh_zero && h < g_obs_h_low) ? 1.0 : 0.0);
            case 1: /* stable: dH small, entropy not low, not oscillating */
                return make_num((fabs(dh) < g_obs_dh_small && h >= g_obs_h_low && !(last && last->prev_dH != 0.0 && dh * last->prev_dH < 0 && fabs(dh) > g_obs_dh_zero)) ? 1.0 : 0.0);
            case 2: /* improving: dH negative (entropy decreasing) */
                return make_num((dh < -g_obs_dh_zero) ? 1.0 : 0.0);
            case 3: /* oscillating: dH sign-flipping */
                return make_num((last && dh * last->prev_dH < 0 && fabs(dh) > g_obs_dh_zero) ? 1.0 : 0.0);
            case 4: /* diverging: dH positive (entropy increasing) */
                return make_num((dh > g_obs_dh_zero) ? 1.0 : 0.0);
            case 5: /* equilibrium: dH~0 (regardless of entropy level) */
                return make_num((fabs(dh) < g_obs_dh_zero) ? 1.0 : 0.0);
        }
        return make_num(0.0);
    }

    default:
        return make_null();
    }
}

Value* eval_block(ASTNode **stmts, int count, Env *env) {
    Value *result = make_null();
    for (int i = 0; i < count; i++) {
        result = eval_node(stmts[i], env);
        if (g_returning || g_breaking || g_continuing) return result;
        if (i + 1 < count) {
            release_eval_temp(stmts[i], result);
            result = make_null();
        }
    }
    return result;
}
