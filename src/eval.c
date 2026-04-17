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
extern int g_try_depth;



static double compute_entropy(Value *v) {
    if (!v) return 0.0;
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
                sum += compute_entropy(v->data.list.items[i]);
            }
            return sum / v->data.list.count + log2(v->data.list.count + 1);
        }
        case VAL_DICT: {
            if (v->data.dict.count == 0) return 0.0;
            double sum = 0.0;
            for (int i = 0; i < v->data.dict.count; i++) {
                sum += compute_entropy(v->data.dict.vals[i]);
            }
            return sum / v->data.dict.count + log2(v->data.dict.count + 1);
        }
        case VAL_FN: return 1.0;
        case VAL_BUILTIN: return 0.0;
        case VAL_JSON_RAW: return 0.0;
    }
    return 0.0;
}

static void update_observer(Value *v) {
    if (!v) return;
    double new_entropy = compute_entropy(v);
    v->prev_dH = v->dH;
    v->dH = new_entropy - v->last_entropy;
    v->entropy = new_entropy;
    v->last_entropy = new_entropy;
    v->obs_age++;
}


/* Recursion-depth guard. Each user-visible recursion level typically
 * consumes 3-6 eval_node frames (wrapper + _impl + sub-expressions).
 * Cap at 500 to leave several MB of headroom below the default 8MB
 * linux stack. The goal is to surface runaway recursion as a catchable
 * runtime error rather than a SIGSEGV. */
#define EIGS_MAX_EVAL_DEPTH 500
static int g_eval_depth = 0;

/* Unobserved-block depth. Nonzero means assignments inside this region
 * skip update_observer and attempt in-place numeric mutation. The
 * observer's existing entropy/dH/obs_age on touched Values goes stale —
 * by design. User declared they won't interrogate. */
int g_unobserved_depth = 0;

static Value* eval_node_impl(ASTNode *node, Env *env);

/* Purely-numeric RHS fast path used by the unobserved fast mutation
 * path. Computes a side-effect-free arithmetic tree into *out without
 * allocating any intermediate Values. Returns 1 on success, 0 on bail. */
static int eval_num_fast(ASTNode *node, Env *env, double *out) {
    if (!node) return 0;
    switch (node->type) {
        case AST_NUM:
            *out = node->data.num;
            return 1;
        case AST_IDENT: {
            Value *v = env_get(env, node->data.ident.name);
            if (!v || v->type != VAL_NUM) return 0;
            *out = v->data.num;
            return 1;
        }
        case AST_DOT: {
            if (node->data.dot.target->type != AST_IDENT &&
                node->data.dot.target->type != AST_DOT &&
                node->data.dot.target->type != AST_INDEX) return 0;
            Value *target = eval_node(node->data.dot.target, env);
            if (!target || target->type != VAL_DICT) return 0;
            Value *v = dict_get(target, node->data.dot.key);
            if (!v || v->type != VAL_NUM) return 0;
            *out = v->data.num;
            return 1;
        }
        case AST_INDEX: {
            if (node->data.index.target->type != AST_IDENT &&
                node->data.index.target->type != AST_DOT &&
                node->data.index.target->type != AST_INDEX) return 0;
            Value *target = eval_node(node->data.index.target, env);
            if (!target || target->type != VAL_LIST) return 0;
            double idx_d;
            if (!eval_num_fast(node->data.index.index, env, &idx_d)) return 0;
            int i = (int)idx_d;
            if (i < 0 || i >= target->data.list.count) return 0;
            Value *v = target->data.list.items[i];
            if (!v || v->type != VAL_NUM) return 0;
            *out = v->data.num;
            return 1;
        }
        case AST_UNARY: {
            if (strcmp(node->data.unary.op, "-") != 0) return 0;
            double x;
            if (!eval_num_fast(node->data.unary.operand, env, &x)) return 0;
            *out = -x;
            return 1;
        }
        case AST_BINOP: {
            const char *op = node->data.binop.op;
            if (op[1] != '\0') return 0;
            if (op[0] != '+' && op[0] != '-' && op[0] != '*' &&
                op[0] != '/' && op[0] != '%') return 0;
            double l, r;
            if (!eval_num_fast(node->data.binop.left, env, &l)) return 0;
            if (!eval_num_fast(node->data.binop.right, env, &r)) return 0;
            switch (op[0]) {
                case '+': *out = l + r; return 1;
                case '-': *out = l - r; return 1;
                case '*': *out = l * r; return 1;
                case '/': if (r == 0) return 0; *out = l / r; return 1;
                case '%': if (r == 0) return 0; *out = fmod(l, r); return 1;
            }
            return 0;
        }
        default:
            return 0;
    }
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
        Value *v = env_get(env, node->data.ident.name);
        if (!v) {
            runtime_error(node->line, "undefined variable '%s'", node->data.ident.name);
            return make_null();
        }
        return v;
    }

    case AST_ASSIGN: {
        /* Inside 'unobserved' blocks: try to mutate existing NUM slot in
         * place, skip update_observer and __observer__ tracking. */
        if (g_unobserved_depth > 0) {
            Value *old = env_get(env, node->data.assign.name);
            if (old && old->type == VAL_NUM && !old->arena) {
                double result;
                if (eval_num_fast(node->data.assign.expr, env, &result)) {
                    old->data.num = result;
                    return old;
                }
            }
            Value *val = eval_node(node->data.assign.expr, env);
            env_set(env, node->data.assign.name, val);
            return val;
        }
        Value *val = eval_node(node->data.assign.expr, env);
        Value *old = env_get(env, node->data.assign.name);
        if (old) {
            val->last_entropy = old->entropy;
            val->obs_age = old->obs_age;
            val->dH = old->dH;
        }
        update_observer(val);
        env_set(env, node->data.assign.name, val);
        env_set(env, "__observer__", val);
        return val;
    }

    case AST_BINOP: {
        const char *op = node->data.binop.op;

        if (strcmp(op, "and") == 0) {
            Value *left = eval_node(node->data.binop.left, env);
            if (!is_truthy(left)) return make_num(0);
            Value *right = eval_node(node->data.binop.right, env);
            return make_num(is_truthy(right) ? 1 : 0);
        }
        if (strcmp(op, "or") == 0) {
            Value *left = eval_node(node->data.binop.left, env);
            if (is_truthy(left)) return make_num(1);
            Value *right = eval_node(node->data.binop.right, env);
            return make_num(is_truthy(right) ? 1 : 0);
        }

        Value *left = eval_node(node->data.binop.left, env);
        Value *right = eval_node(node->data.binop.right, env);

        if (strcmp(op, "+") == 0) {
            if (left->type == VAL_STR || right->type == VAL_STR) {
                char *ls = value_to_string(left);
                char *rs = value_to_string(right);
                size_t llen = strlen(ls), rlen = strlen(rs);
                char *result = xmalloc(llen + rlen + 1);
                memcpy(result, ls, llen);
                memcpy(result + llen, rs, rlen + 1);
                Value *v = make_str(result);
                free(ls); free(rs); free(result);
                return v;
            }
            if (left->type == VAL_NUM && right->type == VAL_NUM)
                return make_num(left->data.num + right->data.num);
        }
        if (strcmp(op, "-") == 0 && left->type == VAL_NUM && right->type == VAL_NUM)
            return make_num(left->data.num - right->data.num);
        if (strcmp(op, "*") == 0 && left->type == VAL_NUM && right->type == VAL_NUM)
            return make_num(left->data.num * right->data.num);
        if (strcmp(op, "/") == 0 && left->type == VAL_NUM && right->type == VAL_NUM) {
            if (right->data.num == 0) {
                fprintf(stderr, "Warning line %d: division by zero\n", node->line);
                return make_num(0);
            }
            return make_num(left->data.num / right->data.num);
        }
        if (strcmp(op, "%") == 0 && left->type == VAL_NUM && right->type == VAL_NUM) {
            if (right->data.num == 0) {
                fprintf(stderr, "Warning line %d: division by zero\n", node->line);
                return make_num(0);
            }
            return make_num(fmod(left->data.num, right->data.num));
        }

        if (strcmp(op, "=") == 0) {
            if (left->type == VAL_NUM && right->type == VAL_NUM)
                return make_num(left->data.num == right->data.num ? 1 : 0);
            if (left->type == VAL_STR && right->type == VAL_STR)
                return make_num(strcmp(left->data.str, right->data.str) == 0 ? 1 : 0);
            if (left->type == VAL_NULL && right->type == VAL_NULL)
                return make_num(1);
            return make_num(0);
        }
        if (strcmp(op, "!=") == 0) {
            if (left->type == VAL_NUM && right->type == VAL_NUM)
                return make_num(left->data.num != right->data.num ? 1 : 0);
            if (left->type == VAL_STR && right->type == VAL_STR)
                return make_num(strcmp(left->data.str, right->data.str) != 0 ? 1 : 0);
            if (left->type == VAL_NULL && right->type == VAL_NULL)
                return make_num(0);
            return make_num(1);
        }

        if (left->type == VAL_NUM && right->type == VAL_NUM) {
            if (strcmp(op, "<") == 0) return make_num(left->data.num < right->data.num ? 1 : 0);
            if (strcmp(op, ">") == 0) return make_num(left->data.num > right->data.num ? 1 : 0);
            if (strcmp(op, "<=") == 0) return make_num(left->data.num <= right->data.num ? 1 : 0);
            if (strcmp(op, ">=") == 0) return make_num(left->data.num >= right->data.num ? 1 : 0);
        }

        runtime_error(node->line, "cannot apply '%s' to %s and %s",
                op, val_type_name(left->type), val_type_name(right->type));
        return make_null();
    }

    case AST_UNARY: {
        Value *operand = eval_node(node->data.unary.operand, env);
        if (strcmp(node->data.unary.op, "-") == 0) {
            if (operand->type == VAL_NUM)
                return make_num(-operand->data.num);
            runtime_error(node->line, "cannot negate %s", val_type_name(operand->type));
            return make_null();
        }
        if (strcmp(node->data.unary.op, "not") == 0) {
            return make_num(is_truthy(operand) ? 0 : 1);
        }
        return make_null();
    }

    case AST_RELATION: {
        Value *right_val = eval_node(node->data.relation.right, env);
        Value *left_val = eval_node(node->data.relation.left, env);

        if (left_val->type == VAL_BUILTIN) {
            Value *result = left_val->data.builtin(right_val);
            update_observer(result);
            env_set(env, "__observer__", result);
            return result;
        }

        if (left_val->type == VAL_FN) {
            Env *call_env = env_new(left_val->data.fn.closure);
            if (left_val->data.fn.param_count > 1 && right_val && right_val->type == VAL_LIST) {
                /* Multi-param: unpack list into named params */
                for (int pi = 0; pi < left_val->data.fn.param_count && pi < right_val->data.list.count; pi++)
                    env_set_local(call_env, left_val->data.fn.params[pi], right_val->data.list.items[pi]);
            } else {
                /* Single param: bind to param name (default "n" for classic style) */
                env_set_local(call_env, left_val->data.fn.params[0], right_val);
            }

            g_returning = 0;
            g_return_val = NULL;

            Value *result = make_null();
            for (int i = 0; i < left_val->data.fn.body_count; i++) {
                result = eval_node(left_val->data.fn.body[i], call_env);
                if (g_returning) {
                    g_returning = 0;
                    update_observer(g_return_val);
                    env_set(env, "__observer__", g_return_val);
                    env_free(call_env);
                    return g_return_val ? g_return_val : make_null();
                }
            }
            update_observer(result);
            env_set(env, "__observer__", result);
            env_free(call_env);
            return result;
        }

        runtime_error(node->line, "cannot call %s (not a function)",
                val_type_name(left_val->type));
        return make_null();
    }

    case AST_IF: {
        Value *cond = eval_node(node->data.cond.cond, env);
        if (is_truthy(cond)) {
            return eval_block(node->data.cond.if_body, node->data.cond.if_count, env);
        } else if (node->data.cond.else_body) {
            return eval_block(node->data.cond.else_body, node->data.cond.else_count, env);
        }
        return make_null();
    }

    case AST_LOOP: {
        Value *result = make_null();
        int max_iter = 1000000;
        int stall_count = 0;
        int iterations = 0;
        const char *exit_reason = "normal";
        while (max_iter-- > 0) {
            Value *cond = eval_node(node->data.loop.cond, env);
            if (!is_truthy(cond)) break;
            iterations++;
            result = eval_block(node->data.loop.body, node->data.loop.body_count, env);
            if (g_returning) return result;
            if (g_breaking) { g_breaking = 0; break; }
            if (g_continuing) { g_continuing = 0; }
            Value *obs = env_get(env, "__observer__");
            if (obs && fabs(obs->dH) < 0.001 && obs->entropy >= 0.1) {
                stall_count++;
                if (stall_count >= 100) {
                    exit_reason = "stalled";
                    break;
                }
            } else {
                stall_count = 0;
            }
        }
        if (max_iter <= 0) exit_reason = "limit";
        env_set(env, "__loop_exit__", make_str(exit_reason));
        env_set(env, "__loop_iterations__", make_num(iterations));
        return result;
    }

    case AST_FOR: {
        Value *iter = eval_node(node->data.forloop.iter, env);
        if (!iter || iter->type != VAL_LIST) {
            runtime_error(node->line, "'for' requires a list, got %s",
                    iter ? val_type_name(iter->type) : "null");
            return make_null();
        }
        Value *result = make_null();
        for (int i = 0; i < iter->data.list.count; i++) {
            Env *loop_env = env_new(env);
            env_set_local(loop_env, node->data.forloop.var, iter->data.list.items[i]);
            result = eval_block(node->data.forloop.body, node->data.forloop.body_count, loop_env);
            if (g_returning) { env_free(loop_env); return result; }
            if (g_breaking) { g_breaking = 0; env_free(loop_env); break; }
            if (g_continuing) { g_continuing = 0; }
            env_free(loop_env);
        }
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
        env->captured = 1;
        return fn;
    }

    case AST_MATCH: {
        Value *val = eval_node(node->data.match.expr, env);
        for (int i = 0; i < node->data.match.case_count; i++) {
            ASTNode *pattern = node->data.match.patterns[i];
            if (!pattern) {
                /* Wildcard _ — always matches */
                return eval_block(node->data.match.bodies[i], node->data.match.body_counts[i], env);
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
                return eval_block(node->data.match.bodies[i], node->data.match.body_counts[i], env);
            }
        }
        return make_null(); /* no match */
    }

    case AST_DOT_ASSIGN: {
        Value *target = eval_node(node->data.dot_assign.target, env);
        if (target->type != VAL_DICT) {
            runtime_error(node->line, "cannot assign .%s on %s", node->data.dot_assign.key, val_type_name(target->type));
            return make_null();
        }
        if (g_unobserved_depth > 0) {
            Value *old = dict_get(target, node->data.dot_assign.key);
            if (old && old->type == VAL_NUM && !old->arena) {
                double result;
                if (eval_num_fast(node->data.dot_assign.expr, env, &result)) {
                    old->data.num = result;
                    return old;
                }
            }
            Value *val = eval_node(node->data.dot_assign.expr, env);
            dict_set(target, node->data.dot_assign.key, val);
            return val;
        }
        Value *val = eval_node(node->data.dot_assign.expr, env);
        dict_set(target, node->data.dot_assign.key, val);
        return val;
    }

    case AST_IMPORT: {
        /* import math → loads lib/math.eigs into a dict namespace */
        const char *name = node->data.import.module_name;
        char path[4096];

        /* Try: lib/NAME.eigs relative to cwd, then script dir */
        snprintf(path, sizeof(path), "lib/%.1024s.eigs", name);
        if (access(path, F_OK) != 0) {
            snprintf(path, sizeof(path), "%.2048s/lib/%.1024s.eigs", g_script_dir, name);
            if (access(path, F_OK) != 0) {
                snprintf(path, sizeof(path), "%.2048s/../lib/%.1024s.eigs", g_script_dir, name);
                if (access(path, F_OK) != 0) {
                    runtime_error(node->line, "import: module '%s' not found", name);
                    return make_null();
                }
            }
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
        eval_node(ast, mod_env);
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

        env_set(env, name, mod_dict);
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
        env_set_local(env, node->data.func.name, fn);
        return fn;
    }

    case AST_RETURN: {
        Value *val = eval_node(node->data.ret.expr, env);
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
            if (g_has_error) break;
        }
        g_try_depth--;
        if (g_has_error) {
            /* Error occurred — run catch body with error bound */
            g_has_error = 0;
            Env *catch_env = env_new(env);
            env_set_local(catch_env, node->data.trycatch.err_name, make_str(g_error_msg));
            g_error_msg[0] = '\0';
            result = make_null();
            for (int i = 0; i < node->data.trycatch.catch_count; i++) {
                result = eval_node(node->data.trycatch.catch_body[i], catch_env);
                if (g_returning) { env_free(catch_env); return result; }
            }
            env_free(catch_env);
        }
        return result;
    }

    case AST_LIST: {
        Value *list = make_list(node->data.list.count);
        for (int i = 0; i < node->data.list.count; i++) {
            list_append(list, eval_node(node->data.list.elems[i], env));
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
        }
        return d;
    }

    case AST_DOT: {
        Value *target = eval_node(node->data.dot.target, env);
        if (target->type == VAL_DICT) {
            Value *val = dict_get(target, node->data.dot.key);
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
            return val ? val : make_null();
        }
        if (target->type == VAL_LIST && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.list.count)
                return target->data.list.items[i];
            runtime_error(node->line, "index %d out of range (length %d)", i, target->data.list.count);
            return make_null();
        }
        if (target->type == VAL_STR && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            int len = strlen(target->data.str);
            if (i >= 0 && i < len) {
                char buf[2] = {target->data.str[i], '\0'};
                return make_str(buf);
            }
            runtime_error(node->line, "index %d out of range (length %d)", i, len);
            return make_null();
        }
        runtime_error(node->line, "cannot index %s", val_type_name(target->type));
        return make_null();
    }

    case AST_LISTCOMP: {
        Value *iter = eval_node(node->data.listcomp.iter, env);
        if (iter->type != VAL_LIST) return make_list(0);
        Value *result = make_list(iter->data.list.count);
        for (int i = 0; i < iter->data.list.count; i++) {
            Env *loop_env = env_new(env);
            env_set_local(loop_env, node->data.listcomp.var, iter->data.list.items[i]);
            if (node->data.listcomp.filter) {
                Value *cond = eval_node(node->data.listcomp.filter, loop_env);
                if (!is_truthy(cond)) {
                    env_free(loop_env);
                    continue;
                }
            }
            Value *val = eval_node(node->data.listcomp.expr, loop_env);
            list_append(result, val);
            env_free(loop_env);
        }
        return result;
    }

    case AST_PROGRAM: {
        Value *result = make_null();
        for (int i = 0; i < node->data.program.count; i++) {
            result = eval_node(node->data.program.stmts[i], env);
            if (g_returning) return result;
        }
        return result;
    }

    case AST_BLOCK: {
        return eval_block(node->data.block.stmts, node->data.block.count, env);
    }

    case AST_UNOBSERVED: {
        g_unobserved_depth++;
        Value *result = eval_block(node->data.block.stmts, node->data.block.count, env);
        g_unobserved_depth--;
        return result;
    }

    case AST_INTERROGATE: {
        Value *target = eval_node(node->data.interrogate.expr, env);
        switch (node->data.interrogate.kind) {
            case 0:
                if (target->type == VAL_NUM) return make_num(target->data.num);
                if (target->type == VAL_STR) return make_num((double)strlen(target->data.str));
                if (target->type == VAL_LIST) return make_num((double)target->data.list.count);
                return make_num(0.0);
            case 1:
                if (node->data.interrogate.expr->type == AST_IDENT)
                    return make_str(node->data.interrogate.expr->data.ident.name);
                if (target->type == VAL_NUM) return make_str("number");
                if (target->type == VAL_STR) return make_str("string");
                if (target->type == VAL_LIST) return make_str("list");
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
        Value *last = env_get(env, "__observer__");
        double h = last ? last->entropy : 0.0;
        double dh = last ? last->dH : 0.0;
        switch (node->data.predicate.kind) {
            case 0:
                return make_num((fabs(dh) < 0.001 && h < 0.1) ? 1.0 : 0.0);
            case 1:
                return make_num((fabs(dh) < 0.01 && h >= 0.1 && !(last && last->prev_dH != 0.0 && dh * last->prev_dH < 0 && fabs(dh) > 0.001)) ? 1.0 : 0.0);
            case 2:
                return make_num((dh < -0.001) ? 1.0 : 0.0);
            case 3:
                return make_num((last && dh * last->prev_dH < 0 && fabs(dh) > 0.001) ? 1.0 : 0.0);
            case 4:
                return make_num((dh > 0.001) ? 1.0 : 0.0);
            case 5:
                return make_num((fabs(dh) < 0.001) ? 1.0 : 0.0);
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
    }
    return result;
}

