/*
 * EigenScript tensor builtins.
 * Extracted from builtins.c as part of the v0.8.0 reorganization.
 * All builtin_tensor_* functions plus their private helpers live here.
 * Registered via register_builtins in builtins.c.
 */

#include "eigenscript.h"

/* Forward decls for helpers shared with the arena/observer machinery. */
Value* make_num_permanent(double n);

/* Stdlib fallbacks for tensor math kernels. When MODEL extension is
 * enabled the non-static versions from model_infer.c take over via the
 * public prototypes in eigenscript.h. */
#if !(EIGENSCRIPT_EXT_MODEL)
static void ne_softmax_buf(double* data, int64_t rows, int64_t cols) {
    for (int64_t r = 0; r < rows; r++) {
        double *row = data + r * cols;
        double max_val = row[0];
        for (int64_t c = 1; c < cols; c++)
            if (row[c] > max_val) max_val = row[c];
        double sum = 0.0;
        for (int64_t c = 0; c < cols; c++) {
            row[c] = exp(row[c] - max_val);
            sum += row[c];
        }
        for (int64_t c = 0; c < cols; c++)
            row[c] /= sum;
    }
}

static void ne_matmul_buf(
    double *a, int64_t a_rows, int64_t a_cols,
    double *b, int64_t b_cols, double *out
) {
    memset(out, 0, a_rows * b_cols * sizeof(double));
    for (int64_t i = 0; i < a_rows; i++)
        for (int64_t k = 0; k < a_cols; k++)
            for (int64_t j = 0; j < b_cols; j++)
                out[i * b_cols + j] += a[i * a_cols + k] * b[k * b_cols + j];
}
#endif


/* ====================================================================
 * TENSOR SUBSTRATE BUILTINS
 * Expose tensor operations so the .eigs standard library can run natively.
 * Tensors are represented as nested VAL_LIST of VAL_NUM (1D or 2D).
 * ==================================================================== */

/* --- Tensor helper: detect dimensions --- */
static int tensor_dims(Value *v, int *rows, int *cols) {
    if (!v || v->type != VAL_LIST || v->data.list.count == 0) return 0;
    Value *first = v->data.list.items[0];
    if (first->type == VAL_NUM) {
        /* 1D tensor */
        *rows = 1;
        *cols = v->data.list.count;
        return 1;
    }
    if (first->type == VAL_LIST) {
        /* 2D tensor */
        *rows = v->data.list.count;
        *cols = first->data.list.count;
        return 2;
    }
    return 0;
}

/* --- Tensor helper: flatten nested list to double* (caller must free) --- */
static double* tensor_to_flat(Value *v, int *rows, int *cols) {
    int ndim = tensor_dims(v, rows, cols);
    if (ndim == 0) return NULL;
    int total = (*rows) * (*cols);
    double *out = xcalloc(total, sizeof(double));
    if (ndim == 1) {
        for (int i = 0; i < *cols; i++)
            out[i] = (v->data.list.items[i]->type == VAL_NUM) ? v->data.list.items[i]->data.num : 0.0;
    } else {
        for (int r = 0; r < *rows; r++) {
            Value *row = v->data.list.items[r];
            int rc = (row->type == VAL_LIST) ? row->data.list.count : 0;
            for (int c = 0; c < *cols && c < rc; c++)
                out[r * (*cols) + c] = (row->data.list.items[c]->type == VAL_NUM) ? row->data.list.items[c]->data.num : 0.0;
        }
    }
    return out;
}

/* --- Tensor helper: flat double* to 2D nested list --- */
static Value* flat_to_tensor_2d(double *data, int rows, int cols) {
    Value *outer = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *row = make_list(cols);
        for (int c = 0; c < cols; c++)
            list_append(row, make_num(data[r * cols + c]));
        list_append(outer, row);
    }
    return outer;
}

/* --- Tensor helper: flat double* to 1D list --- */
static Value* flat_to_tensor_1d(double *data, int len) {
    Value *out = make_list(len);
    for (int i = 0; i < len; i++)
        list_append(out, make_num(data[i]));
    return out;
}

/* --- Tensor helper: count total elements recursively --- */
static int tensor_total(Value *v) {
    if (!v) return 0;
    if (v->type == VAL_NUM) return 1;
    if (v->type != VAL_LIST) return 0;
    int total = 0;
    for (int i = 0; i < v->data.list.count; i++)
        total += tensor_total(v->data.list.items[i]);
    return total;
}

/* --- Tensor helper: flatten any depth to flat array --- */
static void tensor_flatten_recursive(Value *v, double *out, int *idx) {
    if (!v) return;
    if (v->type == VAL_NUM) { out[(*idx)++] = v->data.num; return; }
    if (v->type != VAL_LIST) return;
    for (int i = 0; i < v->data.list.count; i++)
        tensor_flatten_recursive(v->data.list.items[i], out, idx);
}

/* ---- Element-wise binary op on two tensors (or scalar broadcast) ---- */
typedef double (*BinOpFn)(double, double);
static double op_add(double a, double b) { return a + b; }
static double op_sub(double a, double b) { return a - b; }
static double op_mul(double a, double b) { return a * b; }
static double op_div(double a, double b) { return (b == 0.0) ? 0.0 : a / b; }
static double op_pow(double a, double b) { return pow(a, b); }

static Value* tensor_elementwise(Value *a, Value *b, BinOpFn fn) {
    /* scalar op scalar */
    if (a->type == VAL_NUM && b->type == VAL_NUM)
        return make_num(fn(a->data.num, b->data.num));

    /* scalar broadcast to list */
    if (a->type == VAL_NUM && b->type == VAL_LIST) {
        Value *out = make_list(b->data.list.count);
        for (int i = 0; i < b->data.list.count; i++)
            list_append(out, tensor_elementwise(a, b->data.list.items[i], fn));
        return out;
    }
    if (a->type == VAL_LIST && b->type == VAL_NUM) {
        Value *out = make_list(a->data.list.count);
        for (int i = 0; i < a->data.list.count; i++)
            list_append(out, tensor_elementwise(a->data.list.items[i], b, fn));
        return out;
    }

    /* list op list (element-wise, matching shapes) */
    if (a->type == VAL_LIST && b->type == VAL_LIST) {
        int n = a->data.list.count < b->data.list.count ? a->data.list.count : b->data.list.count;
        Value *out = make_list(n);
        for (int i = 0; i < n; i++)
            list_append(out, tensor_elementwise(a->data.list.items[i], b->data.list.items[i], fn));
        return out;
    }
    return make_num(0.0);
}

/* ==== BUILTIN: add ==== */
Value* builtin_tensor_add(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_add);
}

/* ==== BUILTIN: subtract ==== */
Value* builtin_tensor_subtract(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_sub);
}

/* ==== BUILTIN: multiply ==== */
Value* builtin_tensor_multiply(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_mul);
}

/* ==== BUILTIN: divide ==== */
Value* builtin_tensor_divide(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_div);
}

/* ==== BUILTIN: pow ==== */
Value* builtin_tensor_pow(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_pow);
}

/* ---- Element-wise unary op ---- */
typedef double (*UnaryOpFn)(double);
static Value* tensor_unary(Value *v, UnaryOpFn fn) {
    if (v->type == VAL_NUM) return make_num(fn(v->data.num));
    if (v->type == VAL_LIST) {
        Value *out = make_list(v->data.list.count);
        for (int i = 0; i < v->data.list.count; i++)
            list_append(out, tensor_unary(v->data.list.items[i], fn));
        return out;
    }
    return make_num(0.0);
}

static double op_sqrt(double x) { return sqrt(x); }
static double op_exp(double x) { return exp(x); }
static double op_log_safe(double x) { return log(x > 1e-10 ? x : 1e-10); }
static double op_neg(double x) { return -x; }

/* ==== BUILTIN: sqrt ==== */
Value* builtin_tensor_sqrt(Value *arg) { return tensor_unary(arg, op_sqrt); }

/* ==== BUILTIN: exp ==== */
Value* builtin_tensor_exp(Value *arg) { return tensor_unary(arg, op_exp); }

/* ==== BUILTIN: log ==== */
Value* builtin_tensor_log(Value *arg) { return tensor_unary(arg, op_log_safe); }

/* ==== BUILTIN: negative ==== */
Value* builtin_tensor_negative(Value *arg) { return tensor_unary(arg, op_neg); }

/* ==== BUILTIN: matmul ==== */
Value* builtin_tensor_matmul(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    int ar, ac, br, bc;
    double *af = tensor_to_flat(a, &ar, &ac);
    double *bf = tensor_to_flat(b, &br, &bc);
    if (!af || !bf || ac != br) { free(af); free(bf); return make_null(); }
    double *out = xcalloc(ar * bc, sizeof(double));
    ne_matmul_buf(af, ar, ac, bf, bc, out);
    Value *result;
    if (ar == 1)
        result = flat_to_tensor_1d(out, bc);
    else
        result = flat_to_tensor_2d(out, ar, bc);
    free(af); free(bf); free(out);
    return result;
}

/* ==== BUILTIN: softmax ==== */
Value* builtin_tensor_softmax(Value *arg) {
    int rows, cols;
    double *flat = tensor_to_flat(arg, &rows, &cols);
    if (!flat) return make_null();
    ne_softmax_buf(flat, rows, cols);
    Value *result;
    if (rows == 1)
        result = flat_to_tensor_1d(flat, cols);
    else
        result = flat_to_tensor_2d(flat, rows, cols);
    free(flat);
    return result;
}

/* ==== BUILTIN: log_softmax ==== */
Value* builtin_tensor_log_softmax(Value *arg) {
    /* Accept: log_softmax of tensor  OR  log_softmax of [tensor, dim] */
    Value *tensor = arg;
    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        Value *first = arg->data.list.items[0];
        if (first->type == VAL_LIST) tensor = first; /* [tensor, dim] form */
    }
    int rows, cols;
    double *flat = tensor_to_flat(tensor, &rows, &cols);
    if (!flat) return make_null();
    ne_softmax_buf(flat, rows, cols);
    for (int i = 0; i < rows * cols; i++)
        flat[i] = log(flat[i] > 1e-10 ? flat[i] : 1e-10);
    Value *result;
    if (rows == 1)
        result = flat_to_tensor_1d(flat, cols);
    else
        result = flat_to_tensor_2d(flat, rows, cols);
    free(flat);
    return result;
}

/* ==== BUILTIN: relu ==== */
/* relu of tensor → element-wise max(0, x). Works on 1D or 2D. */
Value* builtin_tensor_relu(Value *arg) {
    int rows, cols;
    double *flat = tensor_to_flat(arg, &rows, &cols);
    if (!flat) return make_null();
    for (int i = 0; i < rows * cols; i++)
        if (flat[i] < 0.0) flat[i] = 0.0;
    Value *result;
    if (rows == 1)
        result = flat_to_tensor_1d(flat, cols);
    else
        result = flat_to_tensor_2d(flat, rows, cols);
    free(flat);
    return result;
}

/* ==== BUILTIN: leaky_relu ==== */
/* leaky_relu of tensor → element-wise max(0.01*x, x). Works on 1D or 2D. */
Value* builtin_tensor_leaky_relu(Value *arg) {
    int rows, cols;
    double *flat = tensor_to_flat(arg, &rows, &cols);
    if (!flat) return make_null();
    for (int i = 0; i < rows * cols; i++)
        if (flat[i] < 0.0) flat[i] *= 0.01;
    Value *result;
    if (rows == 1)
        result = flat_to_tensor_1d(flat, cols);
    else
        result = flat_to_tensor_2d(flat, rows, cols);
    free(flat);
    return result;
}

/* ==== BUILTIN: mean ==== */
Value* builtin_tensor_mean(Value *arg) {
    int total = tensor_total(arg);
    if (total == 0) return make_num(0.0);
    double *flat = xcalloc(total, sizeof(double));
    int idx = 0;
    tensor_flatten_recursive(arg, flat, &idx);
    double sum = 0.0;
    for (int i = 0; i < total; i++) sum += flat[i];
    free(flat);
    return make_num(sum / total);
}

/* ==== BUILTIN: sum ==== */
Value* builtin_tensor_sum(Value *arg) {
    int total = tensor_total(arg);
    if (total == 0) return make_num(0.0);
    double *flat = xcalloc(total, sizeof(double));
    int idx = 0;
    tensor_flatten_recursive(arg, flat, &idx);
    double sum = 0.0;
    for (int i = 0; i < total; i++) sum += flat[i];
    free(flat);
    return make_num(sum);
}

/* ==== BUILTIN: zeros ==== */
Value* builtin_tensor_zeros(Value *arg) {
    if (!arg) return make_null();
    /* zeros of n → 1D list of n zeros */
    if (arg->type == VAL_NUM) {
        int n = (int)arg->data.num;
        Value *out = make_list(n);
        for (int i = 0; i < n; i++) list_append(out, make_num(0.0));
        return out;
    }
    /* zeros of [rows, cols] → 2D */
    if (arg->type == VAL_LIST && arg->data.list.count >= 2
        && arg->data.list.items[0]->type == VAL_NUM
        && arg->data.list.items[1]->type == VAL_NUM) {
        int rows = (int)arg->data.list.items[0]->data.num;
        int cols = (int)arg->data.list.items[1]->data.num;
        Value *outer = make_list(rows);
        for (int r = 0; r < rows; r++) {
            Value *row = make_list(cols);
            for (int c = 0; c < cols; c++) list_append(row, make_num(0.0));
            list_append(outer, row);
        }
        return outer;
    }
    return make_null();
}

/* ==== BUILTIN: zeros_like ==== */
Value* builtin_tensor_zeros_like(Value *arg) {
    if (!arg) return make_null();
    if (arg->type == VAL_NUM) return make_num(0.0);
    if (arg->type == VAL_LIST) {
        Value *out = make_list(arg->data.list.count);
        for (int i = 0; i < arg->data.list.count; i++)
            list_append(out, builtin_tensor_zeros_like(arg->data.list.items[i]));
        return out;
    }
    return make_num(0.0);
}

/* ==== BUILTIN: gather ==== */
/* gather of [tensor, indices, dim] → select elements at indices along last dim */
Value* builtin_tensor_gather(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *tensor = arg->data.list.items[0];
    Value *indices = arg->data.list.items[1];
    /* Simple case: 2D tensor, 1D indices → select one element per row */
    if (tensor->type == VAL_LIST && indices->type == VAL_LIST) {
        int n = tensor->data.list.count < indices->data.list.count
              ? tensor->data.list.count : indices->data.list.count;
        Value *out = make_list(n);
        for (int i = 0; i < n; i++) {
            Value *row = tensor->data.list.items[i];
            int idx = 0;
            if (indices->data.list.items[i]->type == VAL_NUM)
                idx = (int)indices->data.list.items[i]->data.num;
            if (row->type == VAL_LIST && idx >= 0 && idx < row->data.list.count)
                list_append(out, make_num(row->data.list.items[idx]->type == VAL_NUM
                    ? row->data.list.items[idx]->data.num : 0.0));
            else
                list_append(out, make_num(0.0));
        }
        return out;
    }
    /* 1D tensor, scalar index */
    if (tensor->type == VAL_LIST && indices->type == VAL_NUM) {
        int idx = (int)indices->data.num;
        if (idx >= 0 && idx < tensor->data.list.count)
            return make_num(tensor->data.list.items[idx]->type == VAL_NUM
                ? tensor->data.list.items[idx]->data.num : 0.0);
    }
    return make_num(0.0);
}

/* ==== Helper: call a user-defined EigenScript function from C ==== */
static Value* call_eigs_fn(Value *fn, Value *arg) {
    if (fn->type == VAL_BUILTIN) return fn->data.builtin(arg);
    if (fn->type != VAL_FN) return make_null();
    Env *call_env = env_new(fn->data.fn.closure);
    if (fn->data.fn.param_count > 1 && arg && arg->type == VAL_LIST) {
        for (int pi = 0; pi < fn->data.fn.param_count && pi < arg->data.list.count; pi++)
            env_set_local(call_env, fn->data.fn.params[pi], arg->data.list.items[pi]);
    } else {
        env_set_local(call_env, fn->data.fn.params[0], arg);
    }
    g_returning = 0;
    g_return_val = NULL;
    Value *result = make_null();
    for (int i = 0; i < fn->data.fn.body_count; i++) {
        result = eval_node(fn->data.fn.body[i], call_env);
        if (g_returning) {
            g_returning = 0;
            env_free(call_env);
            return g_return_val ? g_return_val : make_null();
        }
    }
    env_free(call_env);
    return result;
}

/* ==== BUILTIN: random_normal ==== */
/* random_normal of [rows, cols, scale] → 2D, or random_normal of [len, scale] → 1D */
Value* builtin_random_normal(Value *arg) {
    if (!arg || arg->type != VAL_LIST) return make_null();
    int argc = arg->data.list.count;
    if (argc == 3) {
        /* 2D: [rows, cols, scale] */
        int rows = (int)arg->data.list.items[0]->data.num;
        int cols = (int)arg->data.list.items[1]->data.num;
        double scale = arg->data.list.items[2]->data.num;
        Value *outer = make_list(rows);
        for (int r = 0; r < rows; r++) {
            Value *row = make_list(cols);
            for (int c = 0; c < cols; c++) {
                /* Box-Muller transform for normal distribution */
                double u1 = ((double)rand() + 1.0) / ((double)RAND_MAX + 1.0);
                double u2 = ((double)rand() + 1.0) / ((double)RAND_MAX + 1.0);
                double z = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
                list_append(row, make_num(z * scale));
            }
            list_append(outer, row);
        }
        return outer;
    }
    if (argc == 2) {
        /* 1D: [len, scale] */
        int len = (int)arg->data.list.items[0]->data.num;
        double scale = arg->data.list.items[1]->data.num;
        Value *out = make_list(len);
        for (int i = 0; i < len; i++) {
            double u1 = ((double)rand() + 1.0) / ((double)RAND_MAX + 1.0);
            double u2 = ((double)rand() + 1.0) / ((double)RAND_MAX + 1.0);
            double z = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
            list_append(out, make_num(z * scale));
        }
        return out;
    }
    return make_null();
}

/* ==== BUILTIN: shape ==== */
/* shape of tensor → [rows, cols] for 2D, [len] for 1D */
Value* builtin_tensor_shape(Value *arg) {
    if (!arg) return make_null();
    if (arg->type == VAL_NUM) {
        Value *out = make_list(0);
        return out; /* scalar: empty shape */
    }
    if (arg->type != VAL_LIST) return make_null();
    if (arg->data.list.count == 0) {
        Value *out = make_list(1);
        list_append(out, make_num(0));
        return out;
    }
    Value *first = arg->data.list.items[0];
    if (first->type == VAL_LIST) {
        /* 2D */
        Value *out = make_list(2);
        list_append(out, make_num(arg->data.list.count));
        list_append(out, make_num(first->data.list.count));
        return out;
    }
    /* 1D */
    Value *out = make_list(1);
    list_append(out, make_num(arg->data.list.count));
    return out;
}

/* ==== BUILTIN: numerical_grad ==== */
/* numerical_grad of [loss_fn, param, eps]
 * Computes central finite-difference gradient for every element of param.
 * loss_fn is a VAL_FN that takes null and returns a scalar loss.
 * param is a 1D or 2D tensor (VAL_LIST).
 * Returns gradient tensor matching param shape. */
Value* builtin_numerical_grad(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *loss_fn = arg->data.list.items[0];
    Value *param = arg->data.list.items[1];
    double eps = (arg->data.list.items[2]->type == VAL_NUM) ? arg->data.list.items[2]->data.num : 0.001;
    if (eps <= 0) eps = 0.001;

    if (param->type != VAL_LIST) return make_null();

    /* Check if 1D or 2D */
    int is_2d = (param->data.list.count > 0 && param->data.list.items[0]->type == VAL_LIST);

    if (!is_2d) {
        /* 1D param */
        int len = param->data.list.count;
        Value *grad = make_list(len);
        for (int i = 0; i < len; i++) {
            Value *orig = param->data.list.items[i];
            double old_val = (orig->type == VAL_NUM) ? orig->data.num : 0.0;
            /* Perturb +eps */
            Value *pp = make_num_permanent(old_val + eps);
            param->data.list.items[i] = pp;
            Value *loss_plus = call_eigs_fn(loss_fn, make_null());
            double lp = (loss_plus && loss_plus->type == VAL_NUM) ? loss_plus->data.num : 0.0;
            /* Perturb -eps */
            Value *pm = make_num_permanent(old_val - eps);
            param->data.list.items[i] = pm;
            Value *loss_minus = call_eigs_fn(loss_fn, make_null());
            double lm = (loss_minus && loss_minus->type == VAL_NUM) ? loss_minus->data.num : 0.0;
            /* Restore original Value pointer (preserves observer state) */
            param->data.list.items[i] = orig;
            free(pp);
            free(pm);
            /* Central difference */
            list_append(grad, make_num((lp - lm) / (2.0 * eps)));
        }
        return grad;
    }

    /* 2D param */
    int rows = param->data.list.count;
    Value *grad = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *row = param->data.list.items[r];
        if (!row || row->type != VAL_LIST) { list_append(grad, make_list(0)); continue; }
        int cols = row->data.list.count;
        Value *grad_row = make_list(cols);
        for (int c = 0; c < cols; c++) {
            Value *orig = row->data.list.items[c];
            double old_val = (orig->type == VAL_NUM) ? orig->data.num : 0.0;
            /* Perturb +eps */
            Value *pp = make_num_permanent(old_val + eps);
            row->data.list.items[c] = pp;
            Value *loss_plus = call_eigs_fn(loss_fn, make_null());
            double lp = (loss_plus && loss_plus->type == VAL_NUM) ? loss_plus->data.num : 0.0;
            /* Perturb -eps */
            Value *pm = make_num_permanent(old_val - eps);
            row->data.list.items[c] = pm;
            Value *loss_minus = call_eigs_fn(loss_fn, make_null());
            double lm = (loss_minus && loss_minus->type == VAL_NUM) ? loss_minus->data.num : 0.0;
            /* Restore original Value pointer (preserves observer state) */
            row->data.list.items[c] = orig;
            free(pp);
            free(pm);
            list_append(grad_row, make_num((lp - lm) / (2.0 * eps)));
        }
        list_append(grad, grad_row);
    }
    return grad;
}

/* ==== BUILTIN: sgd_update ==== */
/* sgd_update of [param, grad, lr] — in-place param = param - lr * grad */
Value* builtin_sgd_update(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *param = arg->data.list.items[0];
    Value *grad = arg->data.list.items[1];
    double lr = (arg->data.list.items[2]->type == VAL_NUM) ? arg->data.list.items[2]->data.num : 0.01;

    if (param->type != VAL_LIST || grad->type != VAL_LIST) return param;

    int is_2d = (param->data.list.count > 0 && param->data.list.items[0]->type == VAL_LIST);

    if (!is_2d) {
        /* 1D */
        int len = param->data.list.count < grad->data.list.count
                ? param->data.list.count : grad->data.list.count;
        for (int i = 0; i < len; i++) {
            Value *old = param->data.list.items[i];
            double pv = (old->type == VAL_NUM) ? old->data.num : 0.0;
            double gv = (grad->data.list.items[i]->type == VAL_NUM) ? grad->data.list.items[i]->data.num : 0.0;
            param->data.list.items[i] = make_num_permanent(pv - lr * gv);
            free_weight_val(old);
        }
    } else {
        /* 2D */
        int rows = param->data.list.count < grad->data.list.count
                 ? param->data.list.count : grad->data.list.count;
        for (int r = 0; r < rows; r++) {
            Value *pr = param->data.list.items[r];
            Value *gr = grad->data.list.items[r];
            if (!pr || pr->type != VAL_LIST || !gr || gr->type != VAL_LIST) continue;
            int cols = pr->data.list.count < gr->data.list.count
                     ? pr->data.list.count : gr->data.list.count;
            for (int c = 0; c < cols; c++) {
                Value *old = pr->data.list.items[c];
                double pv = (old->type == VAL_NUM) ? old->data.num : 0.0;
                double gv = (gr->data.list.items[c]->type == VAL_NUM) ? gr->data.list.items[c]->data.num : 0.0;
                pr->data.list.items[c] = make_num_permanent(pv - lr * gv);
                free_weight_val(old);
            }
        }
    }
    return param;
}

/* ==== BUILTIN: numerical_grad_rows ==== */
/* numerical_grad_rows of [loss_fn, matrix, row_indices, eps]
 * Computes numerical gradient only for the specified rows of a 2D matrix.
 * row_indices is a 1D list of integer row indices (pre-deduplicated by caller).
 * Returns a gradient matrix of the same shape, with zero rows for untouched rows. */
Value* builtin_numerical_grad_rows(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *loss_fn = arg->data.list.items[0];
    Value *matrix = arg->data.list.items[1];
    Value *row_indices = arg->data.list.items[2];
    double eps = (arg->data.list.items[3]->type == VAL_NUM) ? arg->data.list.items[3]->data.num : 0.001;
    if (eps <= 0) eps = 0.001;

    if (matrix->type != VAL_LIST || row_indices->type != VAL_LIST) return make_null();

    int rows = matrix->data.list.count;
    if (rows == 0 || matrix->data.list.items[0]->type != VAL_LIST) return make_null();
    int cols = matrix->data.list.items[0]->data.list.count;

    /* Build zero gradient matrix */
    Value *grad = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *grow = make_list(cols);
        for (int c = 0; c < cols; c++)
            list_append(grow, make_num(0.0));
        list_append(grad, grow);
    }

    /* Only compute gradients for specified rows */
    for (int ri = 0; ri < row_indices->data.list.count; ri++) {
        int r = (row_indices->data.list.items[ri]->type == VAL_NUM)
              ? (int)row_indices->data.list.items[ri]->data.num : -1;
        if (r < 0 || r >= rows) continue;

        Value *row = matrix->data.list.items[r];
        if (!row || row->type != VAL_LIST) continue;
        Value *grad_row = grad->data.list.items[r];

        for (int c = 0; c < cols && c < row->data.list.count; c++) {
            Value *orig = row->data.list.items[c];
            double old_val = (orig->type == VAL_NUM) ? orig->data.num : 0.0;
            /* +eps */
            Value *perturb_plus = make_num_permanent(old_val + eps);
            row->data.list.items[c] = perturb_plus;
            Value *lp = call_eigs_fn(loss_fn, make_null());
            double loss_plus = (lp && lp->type == VAL_NUM) ? lp->data.num : 0.0;
            /* -eps */
            Value *perturb_minus = make_num_permanent(old_val - eps);
            row->data.list.items[c] = perturb_minus;
            Value *lm = call_eigs_fn(loss_fn, make_null());
            double loss_minus = (lm && lm->type == VAL_NUM) ? lm->data.num : 0.0;
            /* restore original Value pointer (preserves observer state) */
            row->data.list.items[c] = orig;
            free(perturb_plus);
            free(perturb_minus);
            /* gradient */
            grad_row->data.list.items[c] = make_num((loss_plus - loss_minus) / (2.0 * eps));
        }
    }
    return grad;
}

/* ==== BUILTIN: sgd_update_rows ==== */
/* sgd_update_rows of [matrix, grad, row_indices, lr]
 * Updates only the specified rows of matrix in-place: row -= lr * grad_row */
Value* builtin_sgd_update_rows(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *matrix = arg->data.list.items[0];
    Value *grad = arg->data.list.items[1];
    Value *row_indices = arg->data.list.items[2];
    double lr = (arg->data.list.items[3]->type == VAL_NUM) ? arg->data.list.items[3]->data.num : 0.01;

    if (matrix->type != VAL_LIST || grad->type != VAL_LIST || row_indices->type != VAL_LIST)
        return matrix;

    for (int ri = 0; ri < row_indices->data.list.count; ri++) {
        int r = (row_indices->data.list.items[ri]->type == VAL_NUM)
              ? (int)row_indices->data.list.items[ri]->data.num : -1;
        if (r < 0 || r >= matrix->data.list.count || r >= grad->data.list.count) continue;

        Value *mrow = matrix->data.list.items[r];
        Value *grow = grad->data.list.items[r];
        if (!mrow || mrow->type != VAL_LIST || !grow || grow->type != VAL_LIST) continue;

        int cols = mrow->data.list.count < grow->data.list.count
                 ? mrow->data.list.count : grow->data.list.count;
        for (int c = 0; c < cols; c++) {
            Value *old = mrow->data.list.items[c];
            double pv = (old->type == VAL_NUM) ? old->data.num : 0.0;
            double gv = (grow->data.list.items[c]->type == VAL_NUM) ? grow->data.list.items[c]->data.num : 0.0;
            mrow->data.list.items[c] = make_num_permanent(pv - lr * gv);
            free_weight_val(old);
        }
    }
    return matrix;
}

/* ==== BUILTIN: numerical_grad_cols ==== */
/* numerical_grad_cols of [loss_fn, matrix, col_indices, eps]
 * Computes numerical gradient only for the specified columns of a 2D matrix.
 * col_indices is a 1D list of integer column indices.
 * Returns a gradient matrix of the same shape, with zero columns for untouched cols. */
Value* builtin_numerical_grad_cols(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *loss_fn = arg->data.list.items[0];
    Value *matrix = arg->data.list.items[1];
    Value *col_indices = arg->data.list.items[2];
    double eps = (arg->data.list.items[3]->type == VAL_NUM) ? arg->data.list.items[3]->data.num : 0.001;
    if (eps <= 0) eps = 0.001;

    if (matrix->type != VAL_LIST || col_indices->type != VAL_LIST) return make_null();

    int rows = matrix->data.list.count;
    if (rows == 0 || matrix->data.list.items[0]->type != VAL_LIST) return make_null();
    int cols = matrix->data.list.items[0]->data.list.count;

    /* Build zero gradient matrix */
    Value *grad = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *grow = make_list(cols);
        for (int c = 0; c < cols; c++)
            list_append(grow, make_num(0.0));
        list_append(grad, grow);
    }

    /* Only compute gradients for specified columns, across all rows */
    for (int ci = 0; ci < col_indices->data.list.count; ci++) {
        int col = (col_indices->data.list.items[ci]->type == VAL_NUM)
                ? (int)col_indices->data.list.items[ci]->data.num : -1;
        if (col < 0 || col >= cols) continue;

        for (int r = 0; r < rows; r++) {
            Value *row = matrix->data.list.items[r];
            if (!row || row->type != VAL_LIST || col >= row->data.list.count) continue;

            Value *orig = row->data.list.items[col];
            double old_val = (orig->type == VAL_NUM) ? orig->data.num : 0.0;
            /* +eps */
            Value *perturb_plus = make_num_permanent(old_val + eps);
            row->data.list.items[col] = perturb_plus;
            Value *lp = call_eigs_fn(loss_fn, make_null());
            double loss_plus = (lp && lp->type == VAL_NUM) ? lp->data.num : 0.0;
            /* -eps */
            Value *perturb_minus = make_num_permanent(old_val - eps);
            row->data.list.items[col] = perturb_minus;
            Value *lm = call_eigs_fn(loss_fn, make_null());
            double loss_minus = (lm && lm->type == VAL_NUM) ? lm->data.num : 0.0;
            /* restore original Value pointer (preserves observer state) */
            row->data.list.items[col] = orig;
            free(perturb_plus);
            free(perturb_minus);
            /* gradient */
            grad->data.list.items[r]->data.list.items[col] = make_num((loss_plus - loss_minus) / (2.0 * eps));
        }
    }
    return grad;
}

/* ==== BUILTIN: sgd_update_cols ==== */
/* sgd_update_cols of [matrix, grad, col_indices, lr]
 * Updates only the specified columns of matrix in-place: elem -= lr * grad_elem */
Value* builtin_sgd_update_cols(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *matrix = arg->data.list.items[0];
    Value *grad = arg->data.list.items[1];
    Value *col_indices = arg->data.list.items[2];
    double lr = (arg->data.list.items[3]->type == VAL_NUM) ? arg->data.list.items[3]->data.num : 0.01;

    if (matrix->type != VAL_LIST || grad->type != VAL_LIST || col_indices->type != VAL_LIST)
        return matrix;

    int rows = matrix->data.list.count < grad->data.list.count
             ? matrix->data.list.count : grad->data.list.count;

    for (int ci = 0; ci < col_indices->data.list.count; ci++) {
        int col = (col_indices->data.list.items[ci]->type == VAL_NUM)
                ? (int)col_indices->data.list.items[ci]->data.num : -1;
        if (col < 0) continue;

        for (int r = 0; r < rows; r++) {
            Value *mrow = matrix->data.list.items[r];
            Value *grow = grad->data.list.items[r];
            if (!mrow || mrow->type != VAL_LIST || col >= mrow->data.list.count) continue;
            if (!grow || grow->type != VAL_LIST || col >= grow->data.list.count) continue;

            Value *old = mrow->data.list.items[col];
            double pv = (old->type == VAL_NUM) ? old->data.num : 0.0;
            double gv = (grow->data.list.items[col]->type == VAL_NUM) ? grow->data.list.items[col]->data.num : 0.0;
            mrow->data.list.items[col] = make_num_permanent(pv - lr * gv);
            free_weight_val(old);
        }
    }
    return matrix;
}
Value* builtin_tensor_save(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *tensor = arg->data.list.items[0];
    Value *path_val = arg->data.list.items[1];
    if (!tensor || tensor->type != VAL_LIST || !path_val || path_val->type != VAL_STR)
        return make_num(0);

    int rows, cols;
    int ndim = tensor_dims(tensor, &rows, &cols);
    if (ndim == 0) return make_num(0);

    FILE *f = fopen(path_val->data.str, "wb");
    if (!f) return make_num(0);

    uint32_t header[4] = { (uint32_t)ndim, (uint32_t)rows, (uint32_t)cols, 1 /* flags: has observer */ };
    fwrite(header, sizeof(uint32_t), 4, f);

    int total = rows * cols;

    /* Write numeric data */
    double *flat = tensor_to_flat(tensor, &rows, &cols);
    if (flat) {
        fwrite(flat, sizeof(double), total, f);
        free(flat);
    }

    /* Write observer state for each element.
     * Save last_entropy offset so that the first observation after load
     * reproduces the correct dH. update_observer computes:
     *   dH = new_entropy - last_entropy
     * After load, the first observation recomputes entropy (same value).
     * To get the saved dH back: set last_entropy = entropy - dH. */
    if (ndim == 1) {
        for (int i = 0; i < cols; i++) {
            Value *v = tensor->data.list.items[i];
            double obs[5] = { v->entropy, v->dH, v->entropy - v->dH, (double)v->obs_age, v->prev_dH };
            fwrite(obs, sizeof(double), 5, f);
        }
    } else {
        for (int r = 0; r < rows; r++) {
            Value *row = tensor->data.list.items[r];
            int rc = (row && row->type == VAL_LIST) ? row->data.list.count : 0;
            for (int c = 0; c < cols; c++) {
                if (c < rc) {
                    Value *v = row->data.list.items[c];
                    double obs[5] = { v->entropy, v->dH, v->entropy - v->dH, (double)v->obs_age, v->prev_dH };
                    fwrite(obs, sizeof(double), 5, f);
                } else {
                    double obs[5] = {0, 0, 0, 0, 0};
                    fwrite(obs, sizeof(double), 5, f);
                }
            }
        }
    }

    fclose(f);
    return make_num(1);
}

/* Helper: restore observer state on a flat list of Values */
static void restore_observer_1d(Value *list, double *obs_data, int count) {
    for (int i = 0; i < count && i < list->data.list.count; i++) {
        Value *v = list->data.list.items[i];
        v->entropy = obs_data[i * 5 + 0];
        v->dH = obs_data[i * 5 + 1];
        v->last_entropy = obs_data[i * 5 + 2];
        v->obs_age = (int)obs_data[i * 5 + 3];
        v->prev_dH = obs_data[i * 5 + 4];
    }
}

static void restore_observer_2d(Value *tensor, double *obs_data, int rows, int cols) {
    for (int r = 0; r < rows && r < tensor->data.list.count; r++) {
        Value *row = tensor->data.list.items[r];
        if (!row || row->type != VAL_LIST) continue;
        for (int c = 0; c < cols && c < row->data.list.count; c++) {
            int idx = r * cols + c;
            Value *v = row->data.list.items[c];
            v->entropy = obs_data[idx * 5 + 0];
            v->dH = obs_data[idx * 5 + 1];
            v->last_entropy = obs_data[idx * 5 + 2];
            v->obs_age = (int)obs_data[idx * 5 + 3];
            v->prev_dH = obs_data[idx * 5 + 4];
        }
    }
}

/* ==== BUILTIN: tensor_load ==== */
/* tensor_load of path — load 1D or 2D tensor from binary file.
 * Restores observer state if present in the file. */
Value* builtin_tensor_load(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();

    FILE *f = fopen(arg->data.str, "rb");
    if (!f) return make_null();

    /* Try new format (4-word header with flags) */
    uint32_t header[4];
    if (fread(header, sizeof(uint32_t), 4, f) != 4) { fclose(f); return make_null(); }

    int ndim = (int)header[0];
    int rows = (int)header[1];
    int cols = (int)header[2];
    uint32_t flags = header[3];

    /* Detect old format: flags would be a huge number if it's actually data */
    int has_observer = 0;
    if (flags <= 1) {
        has_observer = (flags & 1);
    } else {
        /* Old 3-word header — rewind and re-read */
        fseek(f, 0, SEEK_SET);
        uint32_t old_header[3];
        if (fread(old_header, sizeof(uint32_t), 3, f) != 3) { fclose(f); return make_null(); }
        ndim = (int)old_header[0];
        rows = (int)old_header[1];
        cols = (int)old_header[2];
        has_observer = 0;
    }

    if (rows <= 0 || cols <= 0 || rows > 100000 || cols > 100000) { fclose(f); return make_null(); }

    /* Guard against int overflow: rows*cols may exceed INT_MAX under the 100k cap. */
    if ((size_t)rows * (size_t)cols > (size_t)INT_MAX) { fclose(f); return make_null(); }
    int total = rows * cols;

    /* Read numeric data */
    double *data = xmalloc_array((size_t)total, sizeof(double));
    if (!data) { fclose(f); return make_null(); }
    if ((int)fread(data, sizeof(double), total, f) != total) { free(data); fclose(f); return make_null(); }

    /* Read observer state if present */
    double *obs_data = NULL;
    if (has_observer) {
        obs_data = xmalloc_array(safe_size_mul((size_t)total, 5), sizeof(double));
        if (obs_data) {
            if ((int)fread(obs_data, sizeof(double), total * 5, f) != total * 5) {
                free(obs_data);
                obs_data = NULL;
            }
        }
    }

    fclose(f);

    /* Build tensor */
    Value *result;
    if (ndim == 1)
        result = flat_to_tensor_1d(data, cols);
    else
        result = flat_to_tensor_2d(data, rows, cols);
    free(data);

    /* Restore observer state */
    if (obs_data && result) {
        if (ndim == 1)
            restore_observer_1d(result, obs_data, total);
        else
            restore_observer_2d(result, obs_data, rows, cols);
        free(obs_data);
    }

    return result;
}

