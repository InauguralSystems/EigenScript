/*
 * EigenScript tensor builtins.
 * Extracted from builtins.c as part of the v0.8.0 reorganization.
 * All builtin_tensor_* functions plus their private helpers live here.
 * Registered via register_builtins in builtins.c.
 */

#include "eigenscript.h"
#include "vm.h"
#include "trace.h"

/* TRACE_NONDET_RET lives in trace.h. */

/* Forward decls for helpers shared with the allocation/observer machinery. */

/* Shared double-precision tensor kernels. These live in this always-compiled
 * translation unit so model-enabled and model-disabled builds execute the
 * same implementation. The tile size matches the model's float kernels but
 * stays local here so the core tensor builtins do not depend on model headers. */
#define NE_TENSOR_TILE_SIZE 32

void ne_softmax_buf(double *data, int64_t rows, int64_t cols) {
    for (int64_t i = 0; i < rows; i++) {
        double *row = data + i * cols;
        if (cols <= 0) continue;
        double max_val = row[0];
        for (int64_t j = 1; j < cols; j++) {
            if (row[j] > max_val) max_val = row[j];
        }
        double sum = 0.0;
        for (int64_t j = 0; j < cols; j++) {
            row[j] = exp(row[j] - max_val);
            sum += row[j];
        }
        /* With numerically stable max-subtract, at least one term is
         * exp(0)=1, so sum should always be >= 1. Guard anyway: on NaN
         * inputs max_val may itself be NaN and all terms underflow,
         * leaving sum=0. Fall back to a uniform distribution. */
        if (!(sum > 0.0)) {
            double u = 1.0 / (double)cols;
            for (int64_t j = 0; j < cols; j++) row[j] = u;
            continue;
        }
        for (int64_t j = 0; j < cols; j++) {
            row[j] /= sum;
        }
    }
}

/* #1131: each product must round to binary64 before accumulation. Fusing
 * the multiply-add changes finite rounding and turns inf + (-inf) into inf
 * when the second product would overflow, bypassing matmul's NaN guard.
 * Keep this policy at the shared kernels for every build/storage road and
 * all three transpose forms. GCC uses scoped optimization options; Clang's
 * contract pragma is scoped to each function body below. */
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC push_options
#pragma GCC optimize ("fp-contract=off")
#endif

void ne_matmul_buf(
    double *a, int64_t m, int64_t k,
    double *b, int64_t n,
    double *out
) {
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
    memset(out, 0, m * n * sizeof(double));
    for (int64_t i0 = 0; i0 < m; i0 += NE_TENSOR_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TENSOR_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < k; k0 += NE_TENSOR_TILE_SIZE) {
                int64_t i_end = i0 + NE_TENSOR_TILE_SIZE < m ? i0 + NE_TENSOR_TILE_SIZE : m;
                int64_t j_end = j0 + NE_TENSOR_TILE_SIZE < n ? j0 + NE_TENSOR_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TENSOR_TILE_SIZE < k ? k0 + NE_TENSOR_TILE_SIZE : k;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        double a_ik = a[i * k + kk];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * n + j] += a_ik * b[kk * n + j];
                        }
                    }
                }
            }
        }
    }
}

/* Transposed-operand kernels for the autograd vjp rules (#973): the two
 * matmul gradients are dA = dY.B^T and dB = A^T.dY, and materialising the
 * transpose costs a copy per backward step. Same i-k-j tiling as
 * ne_matmul_buf, so out[i][j] accumulates over kk in the same ascending
 * order — byte-identical to `matmul` of the explicitly transposed operand
 * (pinned by tests/test_autograd.eigs). model_train.c carries the f32
 * twins of these for the transformer; these are the f64 buffer path. */

/* out(k x n) = a^T . b  where a is (m x k), b is (m x n) */
void ne_matmul_at_buf(
    double *a, int64_t m, int64_t k,
    double *b, int64_t n,
    double *out
) {
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
    memset(out, 0, k * n * sizeof(double));
    for (int64_t i0 = 0; i0 < k; i0 += NE_TENSOR_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TENSOR_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < m; k0 += NE_TENSOR_TILE_SIZE) {
                int64_t i_end = i0 + NE_TENSOR_TILE_SIZE < k ? i0 + NE_TENSOR_TILE_SIZE : k;
                int64_t j_end = j0 + NE_TENSOR_TILE_SIZE < n ? j0 + NE_TENSOR_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TENSOR_TILE_SIZE < m ? k0 + NE_TENSOR_TILE_SIZE : m;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        double a_ki = a[kk * k + i];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * n + j] += a_ki * b[kk * n + j];
                        }
                    }
                }
            }
        }
    }
}

/* out(m x n) = a . b^T  where a is (m x k), b is (n x k) */
void ne_matmul_bt_buf(
    double *a, int64_t m, int64_t k,
    double *b, int64_t n,
    double *out
) {
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
    memset(out, 0, m * n * sizeof(double));
    for (int64_t i0 = 0; i0 < m; i0 += NE_TENSOR_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TENSOR_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < k; k0 += NE_TENSOR_TILE_SIZE) {
                int64_t i_end = i0 + NE_TENSOR_TILE_SIZE < m ? i0 + NE_TENSOR_TILE_SIZE : m;
                int64_t j_end = j0 + NE_TENSOR_TILE_SIZE < n ? j0 + NE_TENSOR_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TENSOR_TILE_SIZE < k ? k0 + NE_TENSOR_TILE_SIZE : k;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        double a_ik = a[i * k + kk];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * n + j] += a_ik * b[j * k + kk];
                        }
                    }
                }
            }
        }
    }
}

#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC pop_options
#endif

/* ---- flat-buffer tensors -------------------------------------------------
 * A VAL_BUFFER carries an optional 2-D shape (rows/cols; rows==0 => 1-D, length
 * = count). The tensor builtins gain a fast path that computes directly on the
 * flat double[] — no flatten/rebuild — eliminating F-OURO-15's flatten tax.
 * Same kernels (ne_matmul_buf i-k-j, num_guard elementwise) so the result is
 * byte-identical to the nested-list path. */
static void buf_dims(Value *v, int *r, int *c) {
    if (v->data.buffer.rows > 0) { *r = v->data.buffer.rows; *c = v->data.buffer.cols; }
    else { *r = 1; *c = v->data.buffer.count; }   /* 1-D treated as a row vector */
}
static Value* make_shaped_buffer(int rows, int cols) {
    /* 64-bit product: rows*cols in int overflowed to a tiny allocation while
     * the matmul kernel wrote rows*cols (int64) elements past it. Callers cap
     * the product (see builtin_tensor_matmul); clamp here too as defense. */
    int64_t count64 = (rows > 0) ? (int64_t)rows * cols : cols;
    int count = (count64 >= 0 && count64 <= 10000000) ? (int)count64 : 0;
    /* Sandbox chokepoint for the BUFFER class: the old "matmul output is
     * bounded by charged inputs" waiver was false — an OUTER product
     * amplifies two 3000-element inputs into a 9M-element (72 MB) output,
     * which graded "ran cleanly" under a 64 MiB budget and loop-aggregated
     * to the uncatchable x_oom abort through grade() (blind round,
     * 2026-08-17). Returns NULL on refusal (catchable EK_SANDBOX raised);
     * callers hand back make_null(). */
    if (!sandbox_charge((count > 0 ? (size_t)count : 1) * sizeof(double)))
        return NULL;
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = count;
    v->data.buffer.rows = (rows > 0) ? rows : 0;
    v->data.buffer.cols = (rows > 0) ? cols : 0;
    v->data.buffer.data = xcalloc(count > 0 ? (size_t)count : 1, sizeof(double));
    v->refcount = 1;
    return v;
}
static Value* make_buffer_like(Value *a) {   /* same count + shape as a */
    int n = a->data.buffer.count;
    /* Same chokepoint as make_shaped_buffer: no amplification here (output
     * = input size) but an uncharged aggregate across a loop. */
    if (!sandbox_charge((n > 0 ? (size_t)n : 1) * sizeof(double)))
        return NULL;
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = n;
    v->data.buffer.rows = a->data.buffer.rows;
    v->data.buffer.cols = a->data.buffer.cols;
    v->data.buffer.data = xcalloc(n > 0 ? (size_t)n : 1, sizeof(double));
    v->refcount = 1;
    return v;
}


/* ====================================================================
 * TENSOR SUBSTRATE BUILTINS
 * Expose tensor operations so the .eigs standard library can run natively.
 * Tensors are represented as nested VAL_LIST of VAL_NUM (1D or 2D).
 * ==================================================================== */

/* --- Tensor helper: detect dimensions --- */
static int tensor_dims(Value *v, int *rows, int *cols) {
    /* #1093: a VAL_BUFFER is a flat numeric tensor — shaped (rows>0) reads as
     * a rows x cols 2-D tensor, unshaped as a 1-D row vector. Same reading
     * buf_dims uses, so the buffer fast paths and this generic path agree. */
    if (v && v->type == VAL_BUFFER) {
        if (v->data.buffer.count == 0) return 0;
        if (v->data.buffer.rows > 0) {
            *rows = v->data.buffer.rows; *cols = v->data.buffer.cols; return 2;
        }
        *rows = 1; *cols = v->data.buffer.count; return 1;
    }
    if (!v || v->type != VAL_LIST || v->data.list.count == 0) return 0;
    Value *first = list_get_borrow(v, 0);
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

/* --- Tensor helper: flatten nested list to double* (caller must free) ---
 * #1416 callers (kept explicit so strict_differential can enumerate them):
 * matmul (two operands), matmul_at (two), matmul_bt (two), softmax,
 * log_softmax, relu, leaky_relu, and tensor_save. */
static double* tensor_to_flat(Value *v, int *rows, int *cols,
                              const char *who) {
    int ndim = tensor_dims(v, rows, cols);
    /* Historically every non-number slot became 0.0 below. Strict mode is
     * the default, so reject that lossy conversion before allocating; the
     * explicit EIGS_STRICT=0 path deliberately retains the old stand-in.
     * Check even when the first element or row gives no usable shape. */
    /* #1637: a bool element is refused in every strict mode. */
#define FLAT_BAD(e) ((e)->type != VAL_NUM && (g_strict || (e)->type == VAL_BOOL))
    if (v && v->type == VAL_LIST) {
        int bad = 0;
        if (ndim == 1) {
            for (int i = 0; i < v->data.list.count; i++)
                if (FLAT_BAD(list_get_borrow(v, i))) { bad = 1; break; }
        } else {
            for (int r = 0; r < v->data.list.count && !bad; r++) {
                Value *row = list_get_borrow(v, r);
                if (row->type != VAL_LIST) { bad = g_strict || row->type == VAL_BOOL; if (bad) break; continue; }
                for (int c = 0; c < row->data.list.count; c++)
                    if (FLAT_BAD(list_get_borrow(row, c))) { bad = 1; break; }
            }
        }
#undef FLAT_BAD
        if (bad) {
            rt_error(EK_TYPE, 0, "%s: expected a tensor containing only numbers", who);
            return NULL;
        }
    }
    if (ndim == 0 || *rows <= 0 || *cols <= 0) return NULL;
    size_t total = safe_size_mul((size_t)*rows, (size_t)*cols);
    if (total > 10000000) {
        fprintf(stderr, "Error: tensor too large (%d x %d)\n", *rows, *cols);
        return NULL;
    }
    double *out = xcalloc_array(total, sizeof(double));
    if (v->type == VAL_BUFFER) {          /* #1093: already flat */
        memcpy(out, v->data.buffer.data, total * sizeof(double));
        return out;
    }
    if (ndim == 1) {
        for (int i = 0; i < *cols; i++)
            out[i] = (list_get_borrow(v, i)->type == VAL_NUM) ? eigs_num_arg(list_get_borrow(v, i), __func__) : 0.0;
    } else {
        for (int r = 0; r < *rows; r++) {
            Value *row = list_get_borrow(v, r);
            int rc = (row->type == VAL_LIST) ? row->data.list.count : 0;
            for (int c = 0; c < *cols && c < rc; c++)
                out[r * (*cols) + c] = (list_get_borrow(row, c)->type == VAL_NUM) ? eigs_num_arg(list_get_borrow(row, c), __func__) : 0.0;
        }
    }
    return out;
}

/* --- Tensor helper: flat double* to 2D nested list --- */
static Value* flat_to_tensor_2d(double *data, int rows, int cols) {
    Value *outer = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *row = make_list(cols);
        for (int c = 0; c < cols; c++) {
            Value *item = make_num(data[r * cols + c]);
            if (g_has_error) {
                val_decref(item); val_decref(row); val_decref(outer);
                return make_null();
            }
            list_append_owned(row, item);
        }
        list_append_owned(outer, row);
    }
    return outer;
}

/* --- Tensor helper: flat double* to 1D list --- */
static Value* flat_to_tensor_1d(double *data, int len) {
    Value *out = make_list(len);
    for (int i = 0; i < len; i++) {
        Value *item = make_num(data[i]);
        if (g_has_error) {
            val_decref(item); val_decref(out);
            return make_null();
        }
        list_append_owned(out, item);
    }
    return out;
}

/* --- Tensor helper (#1093): rebuild a shape-preserving result in the SAME
 * container the input arrived in. A buffer input yields a buffer (1-D stays
 * 1-D, shaped stays shaped); anything else yields the nested-list tensor the
 * builtins have always produced. Returns NULL only when the sandbox refuses
 * the buffer allocation (callers hand back make_null). --- */
static Value* flat_to_like(Value *src, double *data, int rows, int cols) {
    if (src && src->type == VAL_BUFFER) {
        Value *out = (src->data.buffer.rows > 0) ? make_shaped_buffer(rows, cols)
                                                 : make_shaped_buffer(0, cols);
        if (!out) return NULL;
        int n = out->data.buffer.count;
        if (n > rows * cols) n = rows * cols;
        memcpy(out->data.buffer.data, data, (size_t)n * sizeof(double));
        return out;
    }
    return (rows == 1) ? flat_to_tensor_1d(data, cols)
                       : flat_to_tensor_2d(data, rows, cols);
}

/* --- Tensor helper: count total elements recursively --- */
static int tensor_total(Value *v) {
    if (!v) return 0;
    if (v->type == VAL_NUM) return 1;
    /* #1637: arithmetic on a bool raises. Other non-number elements keep
     * their old (counted-as-absent) reading; a bool is the one that used to
     * BE a number, so letting it vanish from `sum of [a < b, ...]` would turn
     * a count into a silent 0. Raised in every strict mode (#1637). */
    if (v->type == VAL_BOOL && !g_has_error)
        rt_error(EK_TYPE, 0, "cannot use a bool as a number (branch on it: `if b:`)");
    if (v->type == VAL_BUFFER) return v->data.buffer.count;   /* #1093 */
    if (v->type != VAL_LIST) return 0;
    int total = 0;
    for (int i = 0; i < v->data.list.count; i++)
        total += tensor_total(list_get_borrow(v, i));
    return total;
}

/* --- Reduction helper: flatten any depth, normalizing scalar buffer reads.
 * Return failure at the first raised read; callers own and free the workspace. */
static int tensor_flatten_recursive(Value *v, double *out, int *idx) {
    if (!v) return 1;
    if (v->type == VAL_NUM) { out[(*idx)++] = eigs_num_arg(v, __func__); return 1; }
    if (v->type == VAL_BUFFER) {                              /* #1093 */
        for (int i = 0; i < v->data.buffer.count; i++) {
            double x = buffer_read_num(v, i);
            if (g_has_error) return 0;
            out[(*idx)++] = x;
        }
        return 1;
    }
    if (v->type != VAL_LIST) return 1;
    for (int i = 0; i < v->data.list.count; i++)
        if (!tensor_flatten_recursive(list_get_borrow(v, i), out, idx)) return 0;
    return 1;
}

/* ---- Element-wise binary op on two tensors (or scalar broadcast) ---- */
typedef double (*BinOpFn)(double, double);
static double op_add(double a, double b) { return num_guard(a + b); }
static double op_sub(double a, double b) { return num_guard(a - b); }
static double op_mul(double a, double b) { return num_guard(a * b); }
/* #971: the elementwise zero-denominator stand-in. The `/` operator raises
 * on a zero divisor in both modes; this helper answered 0 instead (the
 * IEEE result would be inf or NaN, so the 0 is a pre-collapse). Default
 * unchanged; under strict it is the same undefined operation and raises. */
static double op_div(double a, double b) {
    if (b == 0.0) { STRICT_DOMAIN(1, "divide", "division by zero"); return 0.0; }
    return num_guard(a / b);
}
/* #971: pow(negative, non-integer) is NaN — the one arithmetic builtin whose
 * finite inputs reach a NaN. Named so the strict raise says `pow`. */
static double op_pow(double a, double b) { return num_guard_named(pow(a, b), "pow"); }

/* #1093: materialise a buffer as the nested-list tensor of the same shape, so
 * a MIXED buffer/list pair falls back to the list path (and yields a list). */
static Value* buf_as_tensor_list(Value *b) {
    if (b->data.buffer.rows > 0)
        return flat_to_tensor_2d(b->data.buffer.data,
                                 b->data.buffer.rows, b->data.buffer.cols);
    return flat_to_tensor_1d(b->data.buffer.data, b->data.buffer.count);
}

/* #1093: elementwise over two buffers. The broadcast cases and their
 * precedence mirror the nested-list branch below (a row vector matching cols
 * wins over one matching rows), so a shaped buffer and the equivalent nested
 * list produce byte-identical numbers. */
static Value* buf_elementwise(Value *a, Value *b, BinOpFn fn) {
    double *ad = a->data.buffer.data, *bd = b->data.buffer.data;
    int an = a->data.buffer.count, bn = b->data.buffer.count;
    int a_mat = a->data.buffer.rows > 0, b_mat = b->data.buffer.rows > 0;

    if (a_mat && !b_mat) {
        int rows = a->data.buffer.rows, cols = a->data.buffer.cols;
        if ((int64_t)rows * cols > 10000000) return make_null();
        if (bn == cols || bn == rows) {
            Value *out = make_shaped_buffer(rows, cols);
            if (!out) return make_null();
            for (int r = 0; r < rows; r++)
                for (int c = 0; c < cols; c++)
                    out->data.buffer.data[r * cols + c] =
                        fn(ad[r * cols + c], (bn == cols) ? bd[c] : bd[r]);
            return out;
        }
    }
    if (!a_mat && b_mat) {
        int rows = b->data.buffer.rows, cols = b->data.buffer.cols;
        if ((int64_t)rows * cols > 10000000) return make_null();
        if (an == cols || an == rows) {
            Value *out = make_shaped_buffer(rows, cols);
            if (!out) return make_null();
            for (int r = 0; r < rows; r++)
                for (int c = 0; c < cols; c++)
                    out->data.buffer.data[r * cols + c] =
                        fn((an == cols) ? ad[c] : ad[r], bd[r * cols + c]);
            return out;
        }
    }
    if (an == bn) {                      /* same length: keep a's shape */
        Value *out = make_buffer_like(a);
        if (!out) return make_null();
        for (int i = 0; i < an; i++) out->data.buffer.data[i] = fn(ad[i], bd[i]);
        return out;
    }
    /* Mismatched lengths truncate to the shorter operand, as the list path does. */
    int n = an < bn ? an : bn;
    Value *out = make_shaped_buffer(0, n);
    if (!out) return make_null();
    for (int i = 0; i < n; i++) out->data.buffer.data[i] = fn(ad[i], bd[i]);
    return out;
}

static Value* buf_scalar_elementwise(Value *buf, double sc, BinOpFn fn, int buf_left) {
    Value *out = make_buffer_like(buf);
    if (!out) return make_null();
    for (int i = 0; i < buf->data.buffer.count; i++)
        out->data.buffer.data[i] = buf_left ? fn(buf->data.buffer.data[i], sc)
                                            : fn(sc, buf->data.buffer.data[i]);
    return out;
}

static Value* tensor_elementwise(Value *a, Value *b, BinOpFn fn) {
    /* Shared by add/subtract/multiply/divide/pow (and by its own recursion on
     * nested elements), so the guard names that surface rather than one call.
     * `arg` is what the guard macros test for a bool (#1637): either operand. */
    Value *arg = (a && a->type == VAL_BOOL) ? a : b;
    ARG_GUARD(!a || !b, "add/subtract/multiply/divide/pow",
              "two tensor operands", make_num(0.0));

    /* scalar op scalar */
    if (a->type == VAL_NUM && b->type == VAL_NUM)
        return make_num(fn(eigs_num_arg(a, __func__), eigs_num_arg(b, __func__)));

    /* #1093 buffers are flat numeric tensors. Buffer-only operands compute on
     * the flat doubles and return a buffer; a buffer MIXED with a list is
     * materialised as a list first, so the result follows the list container
     * (the rule: a buffer out iff every tensor operand was a buffer). */
    if (a->type == VAL_BUFFER && b->type == VAL_BUFFER)
        return buf_elementwise(a, b, fn);
    if (a->type == VAL_BUFFER && b->type == VAL_NUM)
        return buf_scalar_elementwise(a, eigs_num_arg(b, __func__), fn, 1);
    if (a->type == VAL_NUM && b->type == VAL_BUFFER)
        return buf_scalar_elementwise(b, eigs_num_arg(a, __func__), fn, 0);
    if (a->type == VAL_BUFFER && b->type == VAL_LIST) {
        Value *al = buf_as_tensor_list(a);
        if (g_has_error) { val_decref(al); return make_null(); }
        Value *res = tensor_elementwise(al, b, fn);
        val_decref(al);
        return res;
    }
    if (a->type == VAL_LIST && b->type == VAL_BUFFER) {
        Value *bl = buf_as_tensor_list(b);
        if (g_has_error) { val_decref(bl); return make_null(); }
        Value *res = tensor_elementwise(a, bl, fn);
        val_decref(bl);
        return res;
    }

    /* scalar broadcast to list */
    if (a->type == VAL_NUM && b->type == VAL_LIST) {
        Value *out = make_list(b->data.list.count);
        for (int i = 0; i < b->data.list.count; i++) {
            Value *item = tensor_elementwise(a, list_get_borrow(b, i), fn);
            if (g_has_error) {
                val_decref(item); val_decref(out); return make_null();
            }
            list_append_owned(out, item);
        }
        return out;
    }
    if (a->type == VAL_LIST && b->type == VAL_NUM) {
        Value *out = make_list(a->data.list.count);
        for (int i = 0; i < a->data.list.count; i++) {
            Value *item = tensor_elementwise(list_get_borrow(a, i), b, fn);
            if (g_has_error) {
                val_decref(item); val_decref(out); return make_null();
            }
            list_append_owned(out, item);
        }
        return out;
    }

    /* Matrix/vector broadcasting:
     *   matrix(rows x cols) op vector(cols) -> vector applied to every row
     *   matrix(rows x cols) op vector(rows) -> scalar per row
     * Row-vector bias takes priority for square matrices, matching neural
     * layer convention: add of [batch @ weights, bias]. */
    if (a->type == VAL_LIST && b->type == VAL_LIST) {
        int a_is_matrix = a->data.list.count > 0 && list_get_borrow(a, 0)->type == VAL_LIST;
        int b_is_matrix = b->data.list.count > 0 && list_get_borrow(b, 0)->type == VAL_LIST;

        if (a_is_matrix && !b_is_matrix) {
            int rows = a->data.list.count;
            int cols = list_get_borrow(a, 0)->data.list.count;
            if (b->data.list.count == cols) {
                Value *out = make_list(rows);
                for (int i = 0; i < rows; i++) {
                    Value *row = tensor_elementwise(list_get_borrow(a, i), b, fn);
                    if (g_has_error) {
                        val_decref(row); val_decref(out); return make_null();
                    }
                    list_append(out, row);
                    val_decref(row);
                }
                return out;
            }
            if (b->data.list.count == rows) {
                Value *out = make_list(rows);
                for (int i = 0; i < rows; i++) {
                    Value *row = tensor_elementwise(list_get_borrow(a, i), list_get_borrow(b, i), fn);
                    if (g_has_error) {
                        val_decref(row); val_decref(out); return make_null();
                    }
                    list_append(out, row);
                    val_decref(row);
                }
                return out;
            }
        }

        if (!a_is_matrix && b_is_matrix) {
            int rows = b->data.list.count;
            int cols = list_get_borrow(b, 0)->data.list.count;
            if (a->data.list.count == cols) {
                Value *out = make_list(rows);
                for (int i = 0; i < rows; i++) {
                    Value *row = tensor_elementwise(a, list_get_borrow(b, i), fn);
                    if (g_has_error) {
                        val_decref(row); val_decref(out); return make_null();
                    }
                    list_append(out, row);
                    val_decref(row);
                }
                return out;
            }
            if (a->data.list.count == rows) {
                Value *out = make_list(rows);
                for (int i = 0; i < rows; i++) {
                    Value *row = tensor_elementwise(list_get_borrow(a, i), list_get_borrow(b, i), fn);
                    if (g_has_error) {
                        val_decref(row); val_decref(out); return make_null();
                    }
                    list_append(out, row);
                    val_decref(row);
                }
                return out;
            }
        }

        /* list op list (element-wise, matching shapes) */
        int n = a->data.list.count < b->data.list.count ? a->data.list.count : b->data.list.count;
        Value *out = make_list(n);
        for (int i = 0; i < n; i++) {
            Value *item = tensor_elementwise(list_get_borrow(a, i), list_get_borrow(b, i), fn);
            if (g_has_error) {
                val_decref(item); val_decref(out); return make_null();
            }
            list_append_owned(out, item);
        }
        return out;
    }
    /* Every NUM/LIST combination exits above, so reaching here means an
     * operand is neither a number, a list nor a buffer — a string, a dict, a
     * function. That is the wrong-type case, and 0.0 was indistinguishable
     * from a real elementwise result. */
    ARG_GUARD(1, "add/subtract/multiply/divide/pow",
              "numbers, lists or buffers as operands", make_num(0.0));
}

/* ==== BUILTIN: add ==== */
Value* builtin_tensor_add(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "add");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    /* #1093: the buffer fast path moved into tensor_elementwise, so all five
     * elementwise builtins share one implementation. #973 arrived with a
     * second one (`buffer_elementwise`, called ahead of this); reconciled at
     * integration by keeping THIS one — a builtin must not have two buffer
     * paths, and this is the one whose shape rules are the list path's,
     * container for container. */
    return tensor_elementwise(list_get_borrow(arg, 0), list_get_borrow(arg, 1), op_add);
}

/* ==== BUILTIN: subtract ==== */
Value* builtin_tensor_subtract(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "subtract");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(list_get_borrow(arg, 0), list_get_borrow(arg, 1), op_sub);
}

/* ==== BUILTIN: multiply ==== */
Value* builtin_tensor_multiply(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "multiply");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(list_get_borrow(arg, 0), list_get_borrow(arg, 1), op_mul);
}

/* ==== BUILTIN: divide ==== */
Value* builtin_tensor_divide(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "divide");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(list_get_borrow(arg, 0), list_get_borrow(arg, 1), op_div);
}

/* ==== BUILTIN: pow ==== */
Value* builtin_tensor_pow(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "pow");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(list_get_borrow(arg, 0), list_get_borrow(arg, 1), op_pow);
}

/* ---- Element-wise unary op ---- */
typedef double (*UnaryOpFn)(double);
static Value* tensor_unary(Value *v, UnaryOpFn fn) {
    Value *arg = v;   /* what the guard macros test for a bool (#1637) */
    if (v->type == VAL_NUM) return make_num(fn(eigs_num_arg(v, __func__)));
    /* #1093: a buffer is a flat numeric tensor — same kernel, buffer out. */
    if (v->type == VAL_BUFFER) {
        Value *out = make_buffer_like(v);
        if (!out) return make_null();
        for (int i = 0; i < v->data.buffer.count; i++)
            out->data.buffer.data[i] = fn(v->data.buffer.data[i]);
        return out;
    }
    if (v->type == VAL_LIST) {
        Value *out = make_list(v->data.list.count);
        for (int i = 0; i < v->data.list.count; i++)
            list_append_owned(out, tensor_unary(list_get_borrow(v, i), fn));
        return out;
    }
    /* Both handled types exit above, so `v` is neither a number nor a
     * list — `sqrt of "hello"` was 0, the exact laundering #971 names. Shared
     * by sqrt/exp/log/negative and by its own recursion, so the guard names
     * that surface rather than one call. */
    ARG_GUARD(1, "sqrt/exp/log/negative", "a number, a list or a buffer",
              make_num(0.0));
}

/* #865: `sqrt of -1` returns 0, which is indistinguishable from `sqrt of 0`.
 * Like the log clamp below, the substituted value stays and the invalid bit
 * records that the argument was out of domain. */
static double op_sqrt(double x) {
    if (x < 0) {
        if (g_strict) { rt_error(EK_VALUE, 0, "sqrt: argument out of domain (negative)"); return 0.0; }
        g_math_flags |= EIGS_MATH_INVALID; return 0.0;
    }
    return sqrt(x);
}
static double op_exp(double x) { return num_guard(exp(x)); }
/* #865: `log of 0` returns log(1e-10) = -23.025850929940457, an undocumented
 * substitution that is neither of the two clamps the Numbers promise covers.
 * The value stays (kernels depend on it), but the invalid bit now says the
 * argument was out of domain and the answer is a stand-in.
 * #1041: the stand-in applies ONLY to non-positive (or NaN) input. The old
 * test `!(x > 1e-10)` also swallowed every POSITIVE input below 1e-10 --
 * log of 1e-15 answered ln(1e-10) with no flag, a silent plateau that a
 * log-domain decay fit rode to a confidently wrong answer (phugoid G3).
 * ln of any positive double is finite (ln(5e-324) = -744.44), so there is
 * nothing to guard there. */
static double op_log_safe(double x) {
    if (!(x > 0.0)) {
        if (g_strict) { rt_error(EK_VALUE, 0, "log: argument out of domain (must be > 0)"); return 0.0; }
        g_math_flags |= EIGS_MATH_INVALID; return num_guard(log(1e-10));
    }
    return num_guard(log(x));
}
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
    STRICT_LIST_MAX(arg, 2, "matmul");
    /* #512: invalid shapes/types raise instead of returning a silent null —
     * a null in a numeric pipeline (training, games) is hard to spot.
     * type_mismatch for non-matrix operands, value for incompatible shapes,
     * limit for an oversized result. */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "matmul requires [A, B]");
        return make_null();
    }
    Value *a = list_get_borrow(arg, 0);
    Value *b = list_get_borrow(arg, 1);
    /* flat-buffer fast path: compute in place, no flatten/rebuild */
    if (a->type == VAL_BUFFER && b->type == VAL_BUFFER) {
        int ar, ac, br, bc;
        buf_dims(a, &ar, &ac); buf_dims(b, &br, &bc);
        if (ac != br) {
            rt_error(EK_VALUE, 0, "matmul: incompatible shapes "
                     "(%dx%d · %dx%d)", ar, ac, br, bc);
            return make_null();
        }
        /* Reject an oversized result before the kernel writes ar*bc doubles —
         * ar*bc overflowed int into a tiny allocation, then OOB heap writes. */
        if ((int64_t)ar * bc > 10000000) {
            rt_error(EK_LIMIT, 0, "matmul: result too large (%dx%d)", ar, bc);
            return make_null();
        }
        /* a 1-D left operand yields a 1-D result (mirrors flat_to_tensor_1d) */
        Value *res = (a->data.buffer.rows == 0) ? make_shaped_buffer(0, bc)
                                                : make_shaped_buffer(ar, bc);
        if (!res) return make_null();
        ne_matmul_buf(a->data.buffer.data, ar, ac, b->data.buffer.data, bc, res->data.buffer.data);
        /* #971/#1131: inf - inf leaves a raw NaN. Strict mode raises here;
         * non-strict mode keeps a canonical NaN in the backing work area on
         * both x86 and ARM. #1417 guards every scalar read separately, so
         * this stored sentinel reads as 0 and sets invalid, not as null.
         * Finite results and infinities remain untouched in storage. */
        for (int i = 0; i < res->data.buffer.count; i++) {
            if (res->data.buffer.data[i] != res->data.buffer.data[i]) {
                if (g_strict) {
                    STRICT_DOMAIN(1, "matmul",
                                  "result is not a number (NaN has no defined value)");
                    break;
                }
                res->data.buffer.data[i] = SLOT_NUM_RAW(slot_null());
            }
        }
        return res;
    }
    int ar, ac, br, bc;
    double *af = tensor_to_flat(a, &ar, &ac, "matmul");
    double *bf = tensor_to_flat(b, &br, &bc, "matmul");
    if (!af || !bf) {
        free(af); free(bf);
        if (!g_has_error)
            rt_error(EK_TYPE, 0, "matmul: expected matrices (got %s, %s)",
                     val_type_name(a->type), val_type_name(b->type));
        return make_null();
    }
    if (ac != br) {
        free(af); free(bf);
        rt_error(EK_VALUE, 0, "matmul: incompatible shapes "
                 "(%dx%d · %dx%d)", ar, ac, br, bc);
        return make_null();
    }
    if ((int64_t)ar * bc > 10000000) {
        free(af); free(bf);
        rt_error(EK_LIMIT, 0, "matmul: result too large (%dx%d)", ar, bc);
        return make_null();
    }
    double *out = xcalloc((size_t)ar * bc, sizeof(double));
    ne_matmul_buf(af, ar, ac, bf, bc, out);
    /* #971: same NaN collapse as the buffer path, so the strict raise names
     * matmul instead of the bare num_guard backstop inside make_num. */
    for (int64_t i = 0; i < (int64_t)ar * bc; i++) {
        if (out[i] != out[i]) out[i] = num_guard_named(out[i], "matmul");
        if (g_has_error) { free(af); free(bf); free(out); return make_null(); }
    }
    Value *result;
    if (ar == 1)
        result = flat_to_tensor_1d(out, bc);
    else
        result = flat_to_tensor_2d(out, ar, bc);
    free(af); free(bf); free(out);
    return result;
}

/* ---- transposed-operand matmuls (#973) -------------------------------------
 * Shared argument discipline with `matmul` (#512): raise on non-matrix
 * operands (type), incompatible shapes (value), oversized results (limit).
 * Buffers compute on the flat data; nested lists go through the same flat
 * kernels, so both forms agree byte-for-byte with `matmul` of the
 * explicitly transposed operand. */

/* matmul_at of [a, b] → aᵀ·b: a is (m x k), b is (m x n), result (k x n).
 * The weight gradient dW = Xᵀ·dY of a linear layer, without materialising Xᵀ. */
Value* builtin_tensor_matmul_at(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "matmul_at");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "matmul_at requires [A, B]");
        return make_null();
    }
    Value *a = list_get_borrow(arg, 0);
    Value *b = list_get_borrow(arg, 1);
    if (a->type == VAL_BUFFER && b->type == VAL_BUFFER) {
        int ar, ac, br, bc;
        buf_dims(a, &ar, &ac); buf_dims(b, &br, &bc);
        if (ar != br) {
            rt_error(EK_VALUE, 0, "matmul_at: incompatible shapes "
                     "(%dx%d transposed · %dx%d)", ar, ac, br, bc);
            return make_null();
        }
        if ((int64_t)ac * bc > 10000000) {
            rt_error(EK_LIMIT, 0, "matmul_at: result too large (%dx%d)", ac, bc);
            return make_null();
        }
        /* The result is aᵀ·b = (k x n): always 2-D, since k is the column
         * count of `a` (its length when 1-D) — the shape of a weight matrix. */
        Value *res = make_shaped_buffer(ac, bc);
        if (!res) return make_null();
        ne_matmul_at_buf(a->data.buffer.data, ar, ac, b->data.buffer.data, bc, res->data.buffer.data);
        return res;
    }
    int ar, ac, br, bc;
    double *af = tensor_to_flat(a, &ar, &ac, "matmul_at");
    double *bf = tensor_to_flat(b, &br, &bc, "matmul_at");
    if (!af || !bf) {
        free(af); free(bf);
        if (!g_has_error)
            rt_error(EK_TYPE, 0, "matmul_at: expected matrices (got %s, %s)",
                     val_type_name(a->type), val_type_name(b->type));
        return make_null();
    }
    if (ar != br) {
        free(af); free(bf);
        rt_error(EK_VALUE, 0, "matmul_at: incompatible shapes "
                 "(%dx%d transposed · %dx%d)", ar, ac, br, bc);
        return make_null();
    }
    if ((int64_t)ac * bc > 10000000) {
        free(af); free(bf);
        rt_error(EK_LIMIT, 0, "matmul_at: result too large (%dx%d)", ac, bc);
        return make_null();
    }
    double *out = xcalloc((size_t)ac * bc, sizeof(double));
    ne_matmul_at_buf(af, ar, ac, bf, bc, out);
    Value *result = flat_to_tensor_2d(out, ac, bc);
    free(af); free(bf); free(out);
    return result;
}

/* matmul_bt of [a, b] → a·bᵀ: a is (m x k), b is (n x k), result (m x n).
 * The input gradient dX = dY·Wᵀ of a linear layer, without materialising Wᵀ.
 * Like `matmul`, a 1-D left operand is a row vector and yields a 1-D result. */
Value* builtin_tensor_matmul_bt(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "matmul_bt");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "matmul_bt requires [A, B]");
        return make_null();
    }
    Value *a = list_get_borrow(arg, 0);
    Value *b = list_get_borrow(arg, 1);
    if (a->type == VAL_BUFFER && b->type == VAL_BUFFER) {
        int ar, ac, br, bc;
        buf_dims(a, &ar, &ac); buf_dims(b, &br, &bc);
        if (ac != bc) {
            rt_error(EK_VALUE, 0, "matmul_bt: incompatible shapes "
                     "(%dx%d · %dx%d transposed)", ar, ac, br, bc);
            return make_null();
        }
        if ((int64_t)ar * br > 10000000) {
            rt_error(EK_LIMIT, 0, "matmul_bt: result too large (%dx%d)", ar, br);
            return make_null();
        }
        Value *res = (a->data.buffer.rows == 0) ? make_shaped_buffer(0, br)
                                                : make_shaped_buffer(ar, br);
        if (!res) return make_null();
        ne_matmul_bt_buf(a->data.buffer.data, ar, ac, b->data.buffer.data, br, res->data.buffer.data);
        return res;
    }
    int ar, ac, br, bc;
    double *af = tensor_to_flat(a, &ar, &ac, "matmul_bt");
    double *bf = tensor_to_flat(b, &br, &bc, "matmul_bt");
    if (!af || !bf) {
        free(af); free(bf);
        if (!g_has_error)
            rt_error(EK_TYPE, 0, "matmul_bt: expected matrices (got %s, %s)",
                     val_type_name(a->type), val_type_name(b->type));
        return make_null();
    }
    if (ac != bc) {
        free(af); free(bf);
        rt_error(EK_VALUE, 0, "matmul_bt: incompatible shapes "
                 "(%dx%d · %dx%d transposed)", ar, ac, br, bc);
        return make_null();
    }
    if ((int64_t)ar * br > 10000000) {
        free(af); free(bf);
        rt_error(EK_LIMIT, 0, "matmul_bt: result too large (%dx%d)", ar, br);
        return make_null();
    }
    double *out = xcalloc((size_t)ar * br, sizeof(double));
    ne_matmul_bt_buf(af, ar, ac, bf, br, out);
    Value *result = (ar == 1) ? flat_to_tensor_1d(out, br) : flat_to_tensor_2d(out, ar, br);
    free(af); free(bf); free(out);
    return result;
}

/* scatter_add of [dst, indices, values] → dst, accumulated IN PLACE (#973).
 * The gradient of `gather`. Two forms, keyed on dst's shape:
 *   dst [rows x cols] (shaped): dst[i][indices[i]] += values[i]  (per row)
 *   dst 1-D (unshaped):        dst[indices[j]]    += values[j]  (flat)
 * `indices` is a list or buffer of integers; `values` a buffer, a list of
 * numbers, or one number broadcast to every index. Repeated indices
 * accumulate. An out-of-range index RAISES (index_range) — a dropped
 * gradient is a silent wrong number — and so does a length mismatch
 * (value): indices/values counts must be equal, and the per-row form needs
 * one index per row. Wrong types raise (type). */
Value* builtin_tensor_scatter_add(Value *arg) {
    STRICT_LIST_MAX(arg, 3, "scatter_add");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "scatter_add requires [dst, indices, values]");
        return make_null();
    }
    Value *dst = list_get_borrow(arg, 0);
    Value *indices = list_get_borrow(arg, 1);
    Value *values = list_get_borrow(arg, 2);
    if (dst->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "scatter_add: dst must be a buffer, got %s", val_type_name(dst->type));
        return make_null();
    }
    if (indices->type != VAL_LIST && indices->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "scatter_add: indices must be a list or buffer, got %s", val_type_name(indices->type));
        return make_null();
    }
    if (values->type != VAL_LIST && values->type != VAL_BUFFER && values->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "scatter_add: values must be a buffer, a list of numbers, or a number, got %s", val_type_name(values->type));
        return make_null();
    }
    int ni = (indices->type == VAL_LIST) ? indices->data.list.count : indices->data.buffer.count;
    int nv = (values->type == VAL_LIST) ? values->data.list.count
           : (values->type == VAL_BUFFER) ? values->data.buffer.count : ni;
    /* Lengths must line up exactly. Truncating to the shorter side would drop
     * gradient entries with no diagnostic — the same silent-wrong-number that
     * makes an out-of-range index raise below (#973). A scalar `values` is the
     * one broadcast form, and it is explicit. */
    if (nv != ni) {
        rt_error(EK_VALUE, 0, "scatter_add: %d indices but %d values", ni, nv);
        return make_null();
    }
    int n = ni;
    int per_row = dst->data.buffer.rows > 0;
    int rows = per_row ? dst->data.buffer.rows : 0;
    int cols = per_row ? dst->data.buffer.cols : 0;
    if (per_row && rows != n) {
        rt_error(EK_VALUE, 0, "scatter_add: dst has %d rows but %d indices", rows, n);
        return make_null();
    }
    double *d = dst->data.buffer.data;
    /* Two passes: validate every index and value first, then accumulate —
     * so a raise leaves dst untouched instead of half-updated. */
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < n; i++) {
            double di, v;
            if (indices->type == VAL_LIST) {
                Value *iv = list_get_borrow(indices, i);
                if (iv->type != VAL_NUM) {
                    rt_error(EK_TYPE, 0, "scatter_add: index %d is %s (expected a number)", i, val_type_name(iv->type));
                    return make_null();
                }
                di = eigs_num_arg(iv, __func__);
            } else {
                /* #1417: an index is a scalar read too.  Guard before the
                 * double-to-int conversion: casting a stored NaN is undefined
                 * behavior, and must follow the same strict/lenient rule as
                 * [] and the buffer accessors. */
                di = buffer_read_num(indices, i);
                if (g_has_error) return make_null();
            }
            if (values->type == VAL_LIST) {
                Value *vv = list_get_borrow(values, i);
                if (vv->type != VAL_NUM) {
                    rt_error(EK_TYPE, 0, "scatter_add: value %d is %s (expected a number)", i, val_type_name(vv->type));
                    return make_null();
                }
                v = eigs_num_arg(vv, __func__);
            } else if (values->type == VAL_BUFFER) {
                v = values->data.buffer.data[i];
            } else {
                v = eigs_num_arg(values, __func__);
            }
            /* Check the double before converting it to int.  In particular,
             * an out-of-range floating-to-integer conversion is undefined C
             * behavior, and indices can come from sandboxed bytecode. */
            int index_limit = per_row ? cols : dst->data.buffer.count;
            int valid_index = isfinite(di) && di >= 0.0 && di < (double)index_limit;
            int idx = 0;
            if (valid_index) {
                /* The range check makes this conversion representable.  Check
                 * both directions instead of calling trunc(), which is not
                 * part of the freestanding runtime's mini-libm surface. */
                idx = (int)di;
                valid_index = di >= (double)idx && di <= (double)idx;
            }
            if (!valid_index) {
                if (per_row) {
                    rt_error(EK_INDEX, 0, "scatter_add: column index %.17g out of range for row %d (cols %d)",
                             di, i, cols);
                } else {
                    rt_error(EK_INDEX, 0, "scatter_add: index %.17g out of range (length %d)",
                             di, index_limit);
                }
                return make_null();
            }
            if (per_row) {
                if (pass) {
                    int64_t at = (int64_t)i * cols + idx;
                    d[at] = num_guard(d[at] + v);
                }
            } else {
                if (pass) d[idx] = num_guard(d[idx] + v);
            }
        }
    }
    return dst;   /* borrowed, like copy_into — the VM's borrow scan compensates */
}

/* ==== BUILTIN: softmax ==== */
Value* builtin_tensor_softmax(Value *arg) {
    BOOL_REFUSE(arg, "softmax");
    /* #632: softmax of a single element normalizes to 1.0. */
    if (arg && arg->type == VAL_NUM) return make_num(1.0);
    /* flat-buffer fast path (#973): row-wise on the shape, 1-D is one row;
     * same ne_softmax_buf kernel as the list path, so byte-identical. */
    if (arg && arg->type == VAL_BUFFER) {
        Value *res = make_buffer_like(arg);
        if (!res) return make_null();
        int br, bc;
        buf_dims(arg, &br, &bc);
        memcpy(res->data.buffer.data, arg->data.buffer.data, (size_t)arg->data.buffer.count * sizeof(double));
        ne_softmax_buf(res->data.buffer.data, br, bc);
        return res;
    }
    int rows, cols;
    double *flat = tensor_to_flat(arg, &rows, &cols, "softmax");
    if (!flat) return make_null();
    ne_softmax_buf(flat, rows, cols);
    Value *result = flat_to_like(arg, flat, rows, cols);   /* #1093 */
    free(flat);
    return result ? result : make_null();
}

/* ==== BUILTIN: log_softmax ==== */
Value* builtin_tensor_log_softmax(Value *arg) {
    BOOL_REFUSE(arg, "log_softmax");
    /* Accept: log_softmax of tensor  OR  log_softmax of [tensor, dim].
     * #973: the [tensor, dim] form is recognised only as exactly [list, num].
     * The old test ("first element is a list") was satisfied by EVERY 2-D
     * tensor, so `log_softmax of [[1, 2], [3, 4]]` silently answered for row
     * 0 alone (a 1-D result of 2) — caught by the buffer/list differential
     * in tests/test_tensor_buffer_ops.eigs. A 2-D tensor's second element is
     * a row (a list), never a number, so the two forms no longer collide. */
    Value *tensor = arg;
    if (arg && arg->type == VAL_LIST && arg->data.list.count == 2 &&
        list_get_borrow(arg, 0)->type == VAL_LIST &&
        list_get_borrow(arg, 1)->type == VAL_NUM)
        tensor = list_get_borrow(arg, 0);   /* [tensor, dim] form */
    /* #632: log(softmax(scalar)) = log(1) = 0. */
    /* fs:ANSWER softmax of a single element is 1 and log(1) is 0, so 0.0 is
     * the arithmetic result for a scalar argument — a NUMBER is a valid
     * argument here, which is what makes this not a type guard (#632). */
    if (tensor && tensor->type == VAL_NUM) return make_num(0.0);
    /* flat-buffer fast path (#973): same kernel + the same #865 clamp. */
    if (tensor && tensor->type == VAL_BUFFER) {
        Value *res = make_buffer_like(tensor);
        if (!res) return make_null();
        int br, bc;
        buf_dims(tensor, &br, &bc);
        double *d = res->data.buffer.data;
        memcpy(d, tensor->data.buffer.data, (size_t)tensor->data.buffer.count * sizeof(double));
        ne_softmax_buf(d, br, bc);
        for (int i = 0; i < tensor->data.buffer.count; i++) {
            if (!(d[i] > 0.0)) g_math_flags |= EIGS_MATH_INVALID;
            d[i] = log(d[i] > 0.0 ? d[i] : 1e-10);
        }
        return res;
    }
    int rows, cols;
    double *flat = tensor_to_flat(tensor, &rows, &cols, "log_softmax");
    if (!flat) return make_null();
    ne_softmax_buf(flat, rows, cols);
    for (int i = 0; i < rows * cols; i++) {
        if (!(flat[i] > 0.0)) g_math_flags |= EIGS_MATH_INVALID;   /* #865 / #1041 */
        flat[i] = log(flat[i] > 0.0 ? flat[i] : 1e-10);
    }
    Value *result = flat_to_like(tensor, flat, rows, cols);   /* #1093 */
    free(flat);
    return result ? result : make_null();
}

/* ==== BUILTIN: relu ==== */
/* relu of tensor → element-wise max(0, x). Works on 1D or 2D. */
Value* builtin_tensor_relu(Value *arg) {
    BOOL_REFUSE(arg, "relu");
    /* #632: a scalar is the degenerate element-wise case, like sqrt/exp/log. */
    if (arg && arg->type == VAL_NUM) {
        double x = eigs_num_arg(arg, __func__);
        return make_num(x < 0.0 ? 0.0 : x);
    }
    /* #1093: buffers go through the same flatten path and come back as
     * buffers via flat_to_like — one implementation, not two. */
    int rows, cols;
    double *flat = tensor_to_flat(arg, &rows, &cols, "relu");
    if (!flat) return make_null();
    for (int i = 0; i < rows * cols; i++)
        if (flat[i] < 0.0) flat[i] = 0.0;
    Value *result = flat_to_like(arg, flat, rows, cols);
    free(flat);
    return result ? result : make_null();
}

/* ==== BUILTIN: leaky_relu ==== */
/* leaky_relu of tensor → element-wise max(0.01*x, x). Works on 1D or 2D. */
Value* builtin_tensor_leaky_relu(Value *arg) {
    BOOL_REFUSE(arg, "leaky_relu");
    /* #632: scalar is the degenerate element-wise case. */
    if (arg && arg->type == VAL_NUM) {
        double x = eigs_num_arg(arg, __func__);
        return make_num(x < 0.0 ? 0.01 * x : x);
    }
    /* flat-buffer fast path (#973), the twin of relu's. */
    if (arg && arg->type == VAL_BUFFER) {
        Value *res = make_buffer_like(arg);
        if (!res) return make_null();
        for (int i = 0; i < arg->data.buffer.count; i++) {
            double x = arg->data.buffer.data[i];
            res->data.buffer.data[i] = (x < 0.0) ? 0.01 * x : x;
        }
        return res;
    }
    int rows, cols;
    double *flat = tensor_to_flat(arg, &rows, &cols, "leaky_relu");
    if (!flat) return make_null();
    for (int i = 0; i < rows * cols; i++)
        if (flat[i] < 0.0) flat[i] *= 0.01;
    Value *result = flat_to_like(arg, flat, rows, cols);   /* #1093 */
    free(flat);
    return result ? result : make_null();
}

/* ==== BUILTIN: mean ==== */
Value* builtin_tensor_mean(Value *arg) {
    /* flat-buffer path (#973): the twin of sum's. An empty buffer averages
     * to 0.0 like an empty list (no 0/0). */
    if (arg && arg->type == VAL_BUFFER) {
        int n = arg->data.buffer.count;
        /* fs:EMPTY the mean over zero elements, as for `mean of []` below;
         * the division would be 0/0. A buffer is a valid argument, so this
         * is not a type guard and strict must not raise. */
        if (n == 0) return make_num(0.0);
        double s = 0.0;
        for (int i = 0; i < n; i++) {
            double x = buffer_read_num(arg, i);
            if (g_has_error) return make_null();
            s = num_guard(s + x);
        }
        return make_num(s / n);
    }
    /* Split from the empty case below. `tensor_total` answers 0 for an empty
     * list AND for any non-tensor — a string, a dict, a function — so one
     * `total == 0` line was carrying two opposite verdicts: `mean of []`
     * is the identity, `mean of "hello"` is a laundered type mistake. The
     * mixed line could not be classified honestly (a blind review caught it
     * tagged fs:EMPTY, which would have blessed the laundering permanently),
     * so the type half is hoisted out. Non-strict is byte-identical: both
     * halves still answer 0.0. Closes the main half of #1008. */
    ARG_GUARD(arg && arg->type != VAL_NUM && arg->type != VAL_LIST
              && arg->type != VAL_BUFFER,   /* #1093 */
              "mean", "a number, a list of numbers or a buffer", make_num(0.0));
    int total = tensor_total(arg);
    /* fs:EMPTY nothing to average, and the division below would be 0/0. The
     * non-tensor case is gone (guarded above), so this line now carries one
     * verdict only: `mean of []` is the empty mean and strict must not raise. */
    if (total == 0) return make_num(0.0);
    double *flat = xcalloc(total, sizeof(double));
    int idx = 0;
    if (!tensor_flatten_recursive(arg, flat, &idx)) {
        free(flat);
        return make_null();
    }
    double sum = 0.0;
    for (int i = 0; i < total; i++) sum += flat[i];
    free(flat);
    return make_num(sum / total);
}

/* ==== BUILTIN: sum ==== */
/* sum / norm are association-unspecified reductions (see docs/SPEC.md
 * "Reductions"): the summation order is not guaranteed, which lets an
 * optimizing backend reassociate across SIMD lanes. no-NaN/Inf preserved. */
Value* builtin_tensor_sum(Value *arg) {
    if (arg && arg->type == VAL_BUFFER) {
        int n = arg->data.buffer.count;
        double s = 0.0;
        for (int i = 0; i < n; i++) {
            double x = buffer_read_num(arg, i);
            if (g_has_error) return make_null();
            s = num_guard(s + x);
        }
        return make_num(s);
    }
    /* Split from the empty case below. `tensor_total` answers 0 for an empty
     * list AND for any non-tensor — a string, a dict, a function — so one
     * `total == 0` line was carrying two opposite verdicts: `sum of []`
     * is the identity, `sum of "hello"` is a laundered type mistake. The
     * mixed line could not be classified honestly (a blind review caught it
     * tagged fs:EMPTY, which would have blessed the laundering permanently),
     * so the type half is hoisted out. Non-strict is byte-identical: both
     * halves still answer 0.0. Closes the main half of #1008. */
    ARG_GUARD(arg && arg->type != VAL_NUM && arg->type != VAL_LIST
              && arg->type != VAL_BUFFER,   /* #1093 */
              "sum", "a number, a list of numbers or a buffer", make_num(0.0));
    int total = tensor_total(arg);
    /* fs:EMPTY 0.0 is the additive identity this loop would accumulate over
     * zero elements. The non-tensor case is guarded above, so `sum of []` is
     * the only reading left here. */
    if (total == 0) return make_num(0.0);
    double *flat = xcalloc(total, sizeof(double));
    int idx = 0;
    if (!tensor_flatten_recursive(arg, flat, &idx)) {
        free(flat);
        return make_null();
    }
    double sum = 0.0;
    for (int i = 0; i < total; i++) sum = num_guard(sum + flat[i]);
    free(flat);
    return make_num(sum);
}

/* norm of a → L2 (Euclidean) norm = sqrt(sum_i a[i]^2). Buffers and tensors. */
Value* builtin_tensor_norm(Value *arg) {
    if (arg && arg->type == VAL_BUFFER) {
        int n = arg->data.buffer.count;
        double s = 0.0;
        for (int i = 0; i < n; i++) {
            double x = buffer_read_num(arg, i);
            if (g_has_error) return make_null();
            s = num_guard(s + num_guard(x * x));
        }
        return make_num(num_guard(sqrt(s)));
    }
    /* Split from the empty case below. `tensor_total` answers 0 for an empty
     * list AND for any non-tensor — a string, a dict, a function — so one
     * `total == 0` line was carrying two opposite verdicts: `norm of []`
     * is the identity, `norm of "hello"` is a laundered type mistake. The
     * mixed line could not be classified honestly (a blind review caught it
     * tagged fs:EMPTY, which would have blessed the laundering permanently),
     * so the type half is hoisted out. Non-strict is byte-identical: both
     * halves still answer 0.0. Closes the main half of #1008. */
    ARG_GUARD(arg && arg->type != VAL_NUM && arg->type != VAL_LIST
              && arg->type != VAL_BUFFER,   /* #1093 */
              "norm", "a number, a list of numbers or a buffer", make_num(0.0));
    int total = tensor_total(arg);
    /* fs:EMPTY the L2 norm over zero elements is sqrt(0) = 0, exactly what the
     * loop below would produce. The non-tensor case is guarded above. */
    if (total == 0) return make_num(0.0);
    double *flat = xcalloc(total, sizeof(double));
    int idx = 0;
    if (!tensor_flatten_recursive(arg, flat, &idx)) {
        free(flat);
        return make_null();
    }
    double s = 0.0;
    for (int i = 0; i < total; i++) s = num_guard(s + num_guard(flat[i] * flat[i]));
    free(flat);
    return make_num(num_guard(sqrt(s)));
}

/* #292: bytes a list-of-fresh-numbers tensor of `n` elements costs — one Value
 * per number plus its slot pointer. Used to charge the sandbox budget. */
#define TENSOR_LIST_ELEM_BYTES (sizeof(Value) + sizeof(Value *))

/* ==== BUILTIN: zeros ==== */
/* zeros of n → a BUFFER of n zeros (#1093); zeros of [rows, cols] → 2D list */
Value* builtin_tensor_zeros(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "zeros");
    BOOL_REFUSE(arg, "zeros");
    if (!arg) return make_null();
    /* #1093 (breaking, documented): `zeros of n` is the FLAT numeric
     * container — a VAL_BUFFER of n doubles, not a list of n boxed numbers.
     * `zeros of [rows, cols]` below is unchanged and still builds the nested
     * list tensor. Consumers reach for `zeros` because it is the natural name
     * (dynamics' `x is zeros of n`, iLambdaAi's `b is zeros of (w * w)`), and
     * the list cost a Value per element on the VM and 12.4x on the AOT
     * (ouroboros#170). make_shaped_buffer carries the sandbox charge, which
     * is now 8 bytes/element instead of TENSOR_LIST_ELEM_BYTES. */
    if (arg->type == VAL_NUM) {
        int64_t n64 = (int64_t)eigs_num_arg(arg, __func__);
        if (n64 < 0) n64 = 0;
        if (n64 > 10000000) n64 = 10000000;  /* #292: cap like fill/buffer (was uncapped → x_oom/abort) */
        Value *out = make_shaped_buffer(0, (int)n64);
        return out ? out : make_null();
    }
    /* zeros of [rows, cols] → 2D */
    if (arg->type == VAL_LIST && arg->data.list.count >= 2
        && list_get_borrow(arg, 0)->type == VAL_NUM
        && list_get_borrow(arg, 1)->type == VAL_NUM) {
        int64_t rows64 = (int64_t)eigs_list_num(arg, 0, __func__);
        int64_t cols64 = (int64_t)eigs_list_num(arg, 1, __func__);
        if (rows64 < 0) rows64 = 0;
        if (cols64 < 0) cols64 = 0;
        /* #292: bound each dim before multiplying (no int64 overflow), then the
         * product — a clean make_null (sandbox: {ok:0}) instead of x_oom/abort. */
        if (rows64 > 10000000 || cols64 > 10000000) return make_null();
        int64_t total = rows64 * cols64;
        if (total > 10000000) return make_null();
        if (!sandbox_charge((size_t)total * TENSOR_LIST_ELEM_BYTES)) return make_null();
        int rows = (int)rows64, cols = (int)cols64;
        Value *outer = make_list(rows);
        for (int r = 0; r < rows; r++) {
            Value *row = make_list(cols);
            for (int c = 0; c < cols; c++) list_append_owned(row, make_num(0.0));
            list_append_owned(outer, row);
        }
        return outer;
    }
    return make_null();
}

/* ==== BUILTIN: zeros_like ==== */
/* zeros_like of t → zeros matching t's shape AND container (buffer→buffer) */
Value* builtin_tensor_zeros_like(Value *arg) {
    if (!arg) return make_null();
    /* fs:LITERAL a number is a valid argument and this IS the value being
     * constructed — the zero of the same shape, which for a scalar is 0.0.
     * It is the scalar leaf of the recursion below, not a guard. */
    if (arg->type == VAL_NUM) return make_num(0.0);
    if (arg->type == VAL_LIST) {
        Value *out = make_list(arg->data.list.count);
        for (int i = 0; i < arg->data.list.count; i++)
            list_append_owned(out, builtin_tensor_zeros_like(list_get_borrow(arg, i)));
        return out;
    }
    /* #1093: a buffer's zero is a zero BUFFER of the same shape, not the
     * scalar 0.0 the guard below used to hand back. */
    if (arg->type == VAL_BUFFER) {
        Value *out = make_buffer_like(arg);
        return out ? out : make_null();
    }
    /* Every shape zeros_like can mirror exits above, so `arg` is none of them
     * (a string, a dict, a function). */
    ARG_GUARD(1, "zeros_like", "a number, a list or a buffer", make_num(0.0));
}

/* #1093: an index vector is a flat numeric tensor, so it may be a list or a
 * buffer. A non-numeric list element reads as -1, the out-of-range sentinel
 * the index loops already skip on. */
static int flat_count(Value *v) {
    if (!v) return 0;
    if (v->type == VAL_LIST) return v->data.list.count;
    if (v->type == VAL_BUFFER) return v->data.buffer.count;
    return 0;
}
static int flat_is_vector(Value *v) {
    return v && (v->type == VAL_LIST || v->type == VAL_BUFFER);
}
static int flat_index_at(Value *v, int i) {
    if (v->type == VAL_LIST)
        return (list_get_borrow(v, i)->type == VAL_NUM)
             ? (int)eigs_num_arg(list_get_borrow(v, i), __func__) : -1;
    /* #1417: normalize before conversion, and let every caller propagate a
     * raised read before using its index or touching an output. Saturated
     * infinity is still outside the int domain and uses the existing invalid
     * index sentinel. Ordinary representable finite indices keep truncating. */
    double index = buffer_read_num(v, i);
    if (g_has_error) return -1;
    if (index < (double)INT_MIN || index > (double)INT_MAX) return -1;
    return (int)index;
}
/* #973: a non-numeric element of an index LIST has no index, and reporting it
 * as "index -1 out of range" would name the wrong fault. Buffers hold doubles,
 * so every element is a number by construction. */
static int flat_index_is_num(Value *v, int i) {
    return v->type != VAL_LIST || list_get_borrow(v, i)->type == VAL_NUM;
}

/* ==== BUILTIN: gather ==== */
/* gather of [tensor, indices, dim] -> select one element per row by index.
 *
 * An out-of-range index RAISES `index_range`, in EVERY form: list or buffer,
 * per-row vector of indices or a scalar index into a 1-D tensor.
 *
 * Reconciled at integration (#973 vs #1093). #1093 folded an out-of-range
 * index on the new buffer path to 0.0 because the list path did; #973 raised
 * on it, because "a 0 in a Q-value or a log-prob is indistinguishable from a
 * real 0". Both cannot be true of one builtin, and the answer must not depend
 * on the container — #1093's whole contract is that a buffer is accepted
 * WHEREVER a flat numeric list is, so one logical input has one answer.
 * Settled on the raise, and the list path moves with it:
 *   - there is no element at an out-of-range index, so 0.0 is a stand-in for
 *     a rejected input, which is the fail-soft class #971/#975 are removing;
 *   - `gather`'s own dual `scatter_add` (#973) raises on exactly this index,
 *     so folding here would make the forward pass quiet and the backward pass
 *     loud for the same bad index;
 *   - the `[]` operator and `matmul`'s #512 discipline already raise.
 * A per-row raise is unconditional, not strict-gated, for the same reason
 * matmul's shape refusal is: it reports an argument that has no answer, not
 * a documented soft answer.
 *
 * What did NOT move, so the two containers still agree: a tensor that is not
 * a matrix in the per-row form (a 1-D buffer, or a list row that is not a
 * list) still answers 0.0 for that row, as it always has — that is the
 * wrong-SHAPE reading, a separate class from the index, and converting it is
 * its own change (recorded as a residual on the integration commit). A short
 * index vector still truncates to the row count. */
Value* builtin_tensor_gather(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "gather");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *tensor = list_get_borrow(arg, 0);
    Value *indices = list_get_borrow(arg, 1);
    /* #1093 + #973: a buffer tensor. A shaped (2-D) buffer with one index per
     * row selects one element per row and yields a buffer; an unshaped (1-D)
     * buffer with a scalar index yields that element. */
    if (tensor->type == VAL_BUFFER) {
        if (indices->type == VAL_NUM && tensor->data.buffer.rows == 0) {
            int idx = (int)eigs_num_arg(indices, __func__);
            if (idx < 0 || idx >= tensor->data.buffer.count) {
                rt_error(EK_INDEX, 0, "gather: index %d out of range (length %d)",
                         idx, tensor->data.buffer.count);
                return make_null();
            }
            return make_num(buffer_read_num(tensor, idx));
        } else if (flat_is_vector(indices)) {
            int shaped = tensor->data.buffer.rows > 0;
            int rows = shaped ? tensor->data.buffer.rows : tensor->data.buffer.count;
            int cols = shaped ? tensor->data.buffer.cols : 0;
            int icount = flat_count(indices);
            int n = rows < icount ? rows : icount;
            Value *out = make_shaped_buffer(0, n);
            if (!out) return make_null();
            for (int i = 0; i < n; i++) {
                if (!shaped) { out->data.buffer.data[i] = 0.0; continue; }
                if (!flat_index_is_num(indices, i)) {
                    val_decref(out);
                    rt_error(EK_TYPE, 0, "gather: index %d is %s (expected a number)",
                             i, val_type_name(list_get_borrow(indices, i)->type));
                    return make_null();
                }
                int idx = flat_index_at(indices, i);
                if (g_has_error) { val_decref(out); return make_null(); }
                if (idx < 0 || idx >= cols) {
                    val_decref(out);
                    rt_error(EK_INDEX, 0,
                             "gather: column index %d out of range for row %d (cols %d)",
                             idx, i, cols);
                    return make_null();
                }
                out->data.buffer.data[i] = tensor->data.buffer.data[(int64_t)i * cols + idx];
            }
            return out;
        }
    }
    /* Simple case: 2D tensor, 1D indices → select one element per row */
    if (tensor->type == VAL_LIST && indices->type == VAL_LIST) {
        int n = tensor->data.list.count < indices->data.list.count
              ? tensor->data.list.count : indices->data.list.count;
        Value *out = make_list(n);
        for (int i = 0; i < n; i++) {
            Value *row = list_get_borrow(tensor, i);
            if (row->type != VAL_LIST) {   /* not a matrix row — shape, not index */
                /* #1637: a bool where a row belongs raises, in every mode. */
                if (row->type == VAL_BOOL) {
                    val_decref(out);
                    eigs_num_arg_slow(row, "gather");
                    return make_null();
                }
                list_append_owned(out, make_num(0.0));
                continue;
            }
            if (list_get_borrow(indices, i)->type != VAL_NUM) {
                val_decref(out);
                rt_error(EK_TYPE, 0, "gather: index %d is %s (expected a number)",
                         i, val_type_name(list_get_borrow(indices, i)->type));
                return make_null();
            }
            int idx = (int)eigs_num_arg(list_get_borrow(indices, i), __func__);
            if (idx < 0 || idx >= row->data.list.count) {
                val_decref(out);
                rt_error(EK_INDEX, 0,
                         "gather: column index %d out of range for row %d (cols %d)",
                         idx, i, row->data.list.count);
                return make_null();
            }
            /* #1637 round 4: the selected cell is read as a number -- a
             * bool there raised nothing and read as 0 (critic r3). */
            double cell = eigs_elem_num(list_get_borrow(row, idx), "gather");
            if (g_has_error) { val_decref(out); return make_null(); }
            list_append_owned(out, make_num(cell));
        }
        return out;
    }
    /* 1D tensor, scalar index */
    if (tensor->type == VAL_LIST && indices->type == VAL_NUM) {
        int idx = (int)eigs_num_arg(indices, __func__);
        if (idx < 0 || idx >= tensor->data.list.count) {
            rt_error(EK_INDEX, 0, "gather: index %d out of range (length %d)",
                     idx, tensor->data.list.count);
            return make_null();
        }
        double cell = eigs_elem_num(list_get_borrow(tensor, idx), "gather");   /* #1637 round 4 */
        if (g_has_error) return make_null();
        return make_num(cell);
    }
    /* The fs:TODO #971 left here is resolved by the raise above: the two
     * readings that shared this line are separated. Out-of-range no longer
     * falls through (it raises at its branch), so what is left is only the
     * GUARD reading — `tensor` is not a list or buffer, or `indices` is
     * neither a vector nor a number — and it converts to ARG_GUARD like every
     * other wrong-type case: a raise in strict mode (the default, #1361),
     * 0.0 under EIGS_STRICT=0. */
    ARG_GUARD(1, "gather", "a tensor and an index or index vector", make_num(0.0));
}

/* ==== Helper: call a user-defined EigenScript function from C ====
 *
 * Contract: `arg` is BORROWED (every caller — sort_by's list element, the
 * gradient helpers' `nul` — keeps its own ref), and the returned value is
 * OWNED by the caller. The VAL_FN path satisfies that naturally; the
 * VAL_BUILTIN path must run the borrow protocol with caller_owns_arg=0
 * (#720), or `sort_by of [xs, num]` frees every element of xs. */
Value* call_eigs_fn(Value *fn, Value *arg) {
    if (fn->type == VAL_BUILTIN) {
        /* free_val CONSUMES a reference. Our caller only lends us `arg`, so
         * hand the builtin one of our own making — otherwise it drops the
         * caller's, and `sort_by of [xs, free_val]` leaves xs pointing at
         * freed elements. `arg` is gone afterwards either way, so never
         * read it below (the VM sites guard the same way). */
        Value *result = eigs_call_builtin(fn->data.builtin, arg);
        if (!result) return make_null();
        vm_borrow_compensate(arg, result, 0, fn, NULL);
        return result;
    }
    if (fn->type != VAL_FN) return make_null();
    /* #989: over-arity here silently dropped the surplus — the same hole #974
     * closed at CASE(CALL) and jit_helper_call, left open on the third path
     * into a user function. `sort_by of [xs, key]` with a 2-param key and
     * 3-wide elements bound two and discarded the third without a diagnostic.
     * Same kind and same message as the VM sites, so a callback and a direct
     * call are indistinguishable to the program. The arity-1 re-collect
     * carve-out (param_count == 1 binds the whole list) is exempt, and
     * under-arity is unchanged. */
    if (fn->data.fn.param_count >= 2 && arg && arg->type == VAL_LIST &&
        arg->data.list.count > fn->data.fn.param_count) {
        rt_error(EK_VALUE, 0, "call passes %d arguments but the callee takes %d",
                 arg->data.list.count, fn->data.fn.param_count);
        return make_null();
    }
    Env *call_env = env_new(fn->data.fn.closure);
    int pc = fn->data.fn.param_count;
    if (pc > 1 && arg && arg->type == VAL_LIST) {
        int n = arg->data.list.count;
        for (int pi = 0; pi < pc && pi < n; pi++)
            env_set_local(call_env, fn->data.fn.params[pi], list_get_borrow(arg, pi));
        /* Under-arity null-fill, matching the VM. Leaving the tail unbound
         * is not the same thing: an unbound name resolves through the
         * CLOSURE, so a 2-param key over 1-wide elements could silently read
         * an outer variable of the same name instead of null. */
        for (int pi = n; pi < pc; pi++)
            env_set_local_owned(call_env, fn->data.fn.params[pi], make_null());
    } else if (pc == 1) {
        env_set_local(call_env, fn->data.fn.params[0], arg);
    } else if (pc > 1) {
        /* #989: a NON-LIST element reaching a 2+-param callee used to bind
         * NOTHING — every parameter read null, so `sort_by of [[3,1,2], keyfn]`
         * with a 2-param key gave every element key 0 and returned the list
         * UNSORTED, rc 0, no diagnostic. The oracle treats one scalar argument
         * as a 1-argument call: first slot takes it, the rest null-fill. */
        env_set_local(call_env, fn->data.fn.params[0], arg);
        for (int pi = 1; pi < pc; pi++)
            env_set_local_owned(call_env, fn->data.fn.params[pi], make_null());
    }
    /* param_count == 0: no params to bind */
    if (fn->data.fn.body_count == -1) {
        /* Bytecode function */
        EigsChunk *chunk = (EigsChunk *)fn->data.fn.body;
        /* #997: how many slots the callback actually supplied — a list
         * element spreads, anything else is a single argument, and a
         * 1-parameter callee re-collects into one slot. Without this the
         * frame claims every slot was supplied and the callee's defaults
         * never fire. */
        int supplied = 0;
        if (pc > 1 && arg && arg->type == VAL_LIST) {
            supplied = arg->data.list.count;
            if (supplied > pc) supplied = pc;
        } else if (pc >= 1 && arg) {
            supplied = 1;
        }
        Value *result = vm_execute_argc(chunk, call_env, supplied);
        env_decref(call_env);
        return result ? result : make_null();
    }
    /* AST-based function — should not happen after bytecode migration */
    env_decref(call_env);
    return make_null();
}

/* ==== BUILTIN: random_normal ==== */
/* random_normal of [rows, cols, scale] → 2D, or random_normal of [len, scale] → 1D */
Value* builtin_random_normal(Value *arg) {
    STRICT_LIST_MAX(arg, 3, "random_normal");
    BOOL_REFUSE(arg, "random_normal");   /* before the tape: a type error is not recorded */
    TRACE_NONDET_TAKE("random_normal");
    if (!arg || arg->type != VAL_LIST) TRACE_NONDET_RECORD("random_normal", make_null());
    /* #960: draw from the shared drand48 stream that `seed_random` pins, not
     * libc rand() (seeded only by main()'s srand(time(NULL)), so a
     * randn-initialised tensor was unreproducible from script). After the TAKE
     * above: a replayed call serves its record without touching the stream. */
    int argc = arg->data.list.count;
    if (argc == 3) {
        /* 2D: [rows, cols, scale] */
        int rows = (int)eigs_list_num(arg, 0, __func__);
        int cols = (int)eigs_list_num(arg, 1, __func__);
        double scale = eigs_list_num(arg, 2, __func__);
        Value *outer = make_list(rows);
        for (int r = 0; r < rows; r++) {
            Value *row = make_list(cols);
            for (int c = 0; c < cols; c++) {
                /* Box-Muller. 1 - drand48() lands in (0, 1]: drand48 can
                 * return exactly 0, and log(0) is an infinity. */
                double u1 = 1.0 - eigs_random_double();
                double u2 = eigs_random_double();
                double z = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
                list_append_owned(row, make_num(z * scale));
            }
            list_append_owned(outer, row);
        }
        TRACE_NONDET_RECORD("random_normal", outer);
    }
    if (argc == 2) {
        /* 1D: [len, scale] */
        int len = (int)eigs_list_num(arg, 0, __func__);
        double scale = eigs_list_num(arg, 1, __func__);
        Value *out = make_list(len);
        for (int i = 0; i < len; i++) {
            double u1 = 1.0 - eigs_random_double(); /* (0, 1] — see the 2D branch */
            double u2 = eigs_random_double();
            double z = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
            list_append_owned(out, make_num(z * scale));
        }
        TRACE_NONDET_RECORD("random_normal", out);
    }
    TRACE_NONDET_RECORD("random_normal", make_null());
}

/* ==== BUILTIN: shape ==== */
/* shape of tensor → [rows, cols] for 2D, [len] for 1D */
Value* builtin_tensor_shape(Value *arg) {
    if (!arg) return make_null();
    if (arg->type == VAL_NUM) {
        Value *out = make_list(0);
        return out; /* scalar: empty shape */
    }
    if (arg->type == VAL_BUFFER) {
        /* shaped buffer -> [rows, cols]; unshaped -> [count] */
        if (arg->data.buffer.rows > 0) {
            Value *out = make_list(2);
            list_append_owned(out, make_num(arg->data.buffer.rows));
            list_append_owned(out, make_num(arg->data.buffer.cols));
            return out;
        }
        Value *out = make_list(1);
        list_append_owned(out, make_num(arg->data.buffer.count));
        return out;
    }
    if (arg->type != VAL_LIST) return make_null();
    if (arg->data.list.count == 0) {
        Value *out = make_list(1);
        list_append_owned(out, make_num(0));
        return out;
    }
    Value *first = list_get_borrow(arg, 0);
    if (first->type == VAL_LIST) {
        /* 2D */
        Value *out = make_list(2);
        list_append_owned(out, make_num(arg->data.list.count));
        list_append_owned(out, make_num(first->data.list.count));
        return out;
    }
    /* 1D */
    Value *out = make_list(1);
    list_append_owned(out, make_num(arg->data.list.count));
    return out;
}

/* ==== BUILTIN: numerical_grad ==== */
static double numerical_loss(Value *loss_fn, Value *arg, const char *who,
                             int *loss_valid) {
    if (!*loss_valid) return 0.0;
    Value *loss = call_eigs_fn(loss_fn, arg);
    if (loss && loss->type == VAL_NUM) {
        double result = eigs_num_arg(loss, __func__);
        val_decref(loss);
        return result;
    }
    if (loss) val_decref(loss);
    if (g_strict) {
        if (!g_has_error)
            rt_error(EK_TYPE, 0, "%s: expected loss function to return a number", who);
        *loss_valid = 0;
    }
    return 0.0;
}

/* numerical_grad of [loss_fn, param, eps]
 * Computes central finite-difference gradient for every element of param.
 * loss_fn is a VAL_FN that takes null and returns a scalar loss.
 * param is a 1D or 2D tensor (VAL_LIST).
 * Returns gradient tensor matching param shape. */
/* #1637: the cells a numeric-gradient / SGD builtin reads (and, for the
 * numerical_grad family, writes in place) must be numbers. A bool cell used
 * to read as 0, and numerical_grad_rows/_cols then wrote the perturbed value
 * into it in place -- into the immortal true/false singleton. So every cell
 * and every row is checked up front, before anything is mutated, and ANY
 * non-number -- a bool, a string, or a null where a row or cell belongs --
 * raises a type error in EVERY strict mode, EIGS_STRICT=0 included (owner
 * decision, round 5: fail loud, the #975 direction; v0.44.0 skipped null
 * rows and read non-number cells as 0). Index lists get the same check, so
 * a bool index is refused, never skipped as "-1". */
static int tensor_cells_numeric(const Value *v, const char *who) {
    if (!v || v->type != VAL_LIST) return 1;
    for (int i = 0; i < v->data.list.count; i++) {
        const Value *e = list_get_borrow(v, i);
        if (e && e->type == VAL_LIST) {
            for (int c = 0; c < e->data.list.count; c++)
                if (!list_get_borrow(e, c) || list_get_borrow(e, c)->type != VAL_NUM) {
                    eigs_num_arg(list_get_borrow(e, c), who);
                    return 0;
                }
        } else if (!e || e->type != VAL_NUM) {
            eigs_num_arg(e, who);
            return 0;
        }
    }
    return 1;
}

Value* builtin_numerical_grad(Value *arg) {
    STRICT_LIST_MAX(arg, 3, "numerical_grad");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *loss_fn = list_get_borrow(arg, 0);
    Value *param = list_get_borrow(arg, 1);
    /* #1637: the optional eps: null keeps the default, a number sets it,
     * anything else (a bool) raises instead of silently meaning the default. */
    double eps = 0.001;
    eigs_opt_num(list_get_borrow(arg, 2), &eps, __func__);
    if (g_has_error) return make_null();
    if (!tensor_cells_numeric(param, "numerical_grad")) return make_null();
    if (eps <= 0) eps = 0.001;
    int loss_valid = 1;

    /* #1093: a buffer param is a flat numeric tensor — perturb the doubles in
     * place and return a gradient buffer of the same shape. */
    if (param->type == VAL_BUFFER) {
        Value *grad = make_buffer_like(param);
        if (!grad) return make_null();
        Value *bnul = make_null();
        for (int i = 0; i < param->data.buffer.count; i++) {
            double old_val = param->data.buffer.data[i];
            param->data.buffer.data[i] = old_val + eps;
            double loss_plus = numerical_loss(loss_fn, bnul, "numerical_grad", &loss_valid);
            param->data.buffer.data[i] = old_val - eps;
            double loss_minus = numerical_loss(loss_fn, bnul, "numerical_grad", &loss_valid);
            param->data.buffer.data[i] = old_val;
            grad->data.buffer.data[i] = (loss_plus - loss_minus) / (2.0 * eps);
        }
        val_decref(bnul);
        if (!loss_valid) { val_decref(grad); return make_null(); }
        return grad;
    }
    if (param->type != VAL_LIST) return make_null();
    Value *nul = make_null();   /* shared arg for loss_fn calls */

    /* Check if 1D or 2D */
    int is_2d = (param->data.list.count > 0 && list_get_borrow(param, 0)->type == VAL_LIST);

    if (!is_2d) {
        /* 1D param */
        int len = param->data.list.count;
        Value *grad = make_list(len);
        for (int i = 0; i < len; i++) {
            Value *orig = list_get_borrow(param, i);
            double old_val = eigs_num_arg(orig, __func__);
            val_incref(orig);   /* guard while displaced from its slot */
            Value *pp = make_num(old_val + eps);   /* birth ref doubles as slot ref */
            list_set_owned(param, i, pp);
            double lp = numerical_loss(loss_fn, nul, "numerical_grad", &loss_valid);
            Value *pm = make_num(old_val - eps);
            list_set_owned(param, i, pm);
            val_decref(pp);
            double lm = numerical_loss(loss_fn, nul, "numerical_grad", &loss_valid);
            list_set_owned(param, i, orig);
            val_decref(orig);   /* drop the guard */
            val_decref(pm);
            /* Central difference */
            list_append_owned(grad, make_num((lp - lm) / (2.0 * eps)));
        }
        val_decref(nul);
        if (!loss_valid) { val_decref(grad); return make_null(); }
        return grad;
    }

    /* 2D param */
    int rows = param->data.list.count;
    Value *grad = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *row = list_get_borrow(param, r);
        if (!row || row->type != VAL_LIST) { list_append_owned(grad, make_list(0)); continue; }
        int cols = row->data.list.count;
        Value *grad_row = make_list(cols);
        for (int c = 0; c < cols; c++) {
            Value *orig = list_get_borrow(row, c);
            double old_val = eigs_num_arg(orig, __func__);
            val_incref(orig);   /* guard while displaced from its slot */
            Value *pp = make_num(old_val + eps);   /* birth ref doubles as slot ref */
            list_set_owned(row, c, pp);
            double lp = numerical_loss(loss_fn, nul, "numerical_grad", &loss_valid);
            Value *pm = make_num(old_val - eps);
            list_set_owned(row, c, pm);
            val_decref(pp);
            double lm = numerical_loss(loss_fn, nul, "numerical_grad", &loss_valid);
            list_set_owned(row, c, orig);
            val_decref(orig);   /* drop the guard */
            val_decref(pm);
            list_append_owned(grad_row, make_num((lp - lm) / (2.0 * eps)));
        }
        list_append_owned(grad, grad_row);
    }
    val_decref(nul);
    if (!loss_valid) { val_decref(grad); return make_null(); }
    return grad;
}

/* ==== BUILTIN: sgd_update ==== */
/* sgd_update of [param, grad, lr] — in-place param = param - lr * grad */
Value* builtin_sgd_update(Value *arg) {
    STRICT_LIST_MAX(arg, 3, "sgd_update");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *param = list_get_borrow(arg, 0);
    Value *grad = list_get_borrow(arg, 1);
    /* #1637: the optional lr: null keeps the default, a number sets it,
     * anything else (a bool) raises instead of silently meaning the default. */
    double lr = 0.01;
    eigs_opt_num(list_get_borrow(arg, 2), &lr, __func__);
    if (g_has_error) return make_null();
    if (!tensor_cells_numeric(param, "sgd_update") || !tensor_cells_numeric(grad, "sgd_update")) return make_null();

    /* #1093: both operands flat buffers — update the doubles in place. */
    if (param->type == VAL_BUFFER && grad->type == VAL_BUFFER) {
        int len = param->data.buffer.count < grad->data.buffer.count
                ? param->data.buffer.count : grad->data.buffer.count;
        for (int i = 0; i < len; i++)
            param->data.buffer.data[i] -= lr * grad->data.buffer.data[i];
        return param;
    }
    if (param->type != VAL_LIST || grad->type != VAL_LIST) return param;

    int is_2d = (param->data.list.count > 0 && list_get_borrow(param, 0)->type == VAL_LIST);

    if (!is_2d) {
        /* 1D */
        int len = param->data.list.count < grad->data.list.count
                ? param->data.list.count : grad->data.list.count;
        for (int i = 0; i < len; i++) {
            Value *old = list_get_borrow(param, i);
            double pv = eigs_num_arg(old, __func__);
            double gv = eigs_num_arg(list_get_borrow(grad, i), __func__);
            list_set_owned(param, i, make_num(pv - lr * gv));
            val_decref(old);
        }
    } else {
        /* 2D */
        int rows = param->data.list.count < grad->data.list.count
                 ? param->data.list.count : grad->data.list.count;
        for (int r = 0; r < rows; r++) {
            Value *pr = list_get_borrow(param, r);
            Value *gr = list_get_borrow(grad, r);
            if (!pr || pr->type != VAL_LIST || !gr || gr->type != VAL_LIST) continue;
            int cols = pr->data.list.count < gr->data.list.count
                     ? pr->data.list.count : gr->data.list.count;
            for (int c = 0; c < cols; c++) {
                Value *old = list_get_borrow(pr, c);
                double pv = eigs_num_arg(old, __func__);
                double gv = eigs_num_arg(list_get_borrow(gr, c), __func__);
                list_set_owned(pr, c, make_num(pv - lr * gv));
                val_decref(old);
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
    STRICT_LIST_MAX(arg, 4, "numerical_grad_rows");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *loss_fn = list_get_borrow(arg, 0);
    Value *matrix = list_get_borrow(arg, 1);
    Value *row_indices = list_get_borrow(arg, 2);
    /* #1637: the optional eps: null keeps the default, a number sets it,
     * anything else (a bool) raises instead of silently meaning the default. */
    double eps = 0.001;
    eigs_opt_num(list_get_borrow(arg, 3), &eps, __func__);
    if (g_has_error) return make_null();
    if (!tensor_cells_numeric(matrix, "numerical_grad_rows") || !tensor_cells_numeric(row_indices, "numerical_grad_rows")) return make_null();
    if (eps <= 0) eps = 0.001;
    int loss_valid = 1;

    /* #1093: a shaped buffer is the flat 2-D matrix and the index vector may
     * be a list or a buffer. The gradient comes back in the same container,
     * zero for every row not named. */
    if (matrix->type == VAL_BUFFER && matrix->data.buffer.rows > 0
        && flat_is_vector(row_indices)) {
        int brows = matrix->data.buffer.rows, bcols = matrix->data.buffer.cols;
        Value *bgrad = make_buffer_like(matrix);
        if (!bgrad) return make_null();
        Value *bnul = make_null();
        int nidx = flat_count(row_indices);
        for (int ri = 0; ri < nidx; ri++) {
            int r = flat_index_at(row_indices, ri);
            if (g_has_error) {
                val_decref(bnul);
                val_decref(bgrad);
                return make_null();
            }
            if (r < 0 || r >= brows) continue;
            for (int c = 0; c < bcols; c++) {
                int64_t k = (int64_t)r * bcols + c;
                double old_val = matrix->data.buffer.data[k];
                matrix->data.buffer.data[k] = old_val + eps;
                double loss_plus = numerical_loss(loss_fn, bnul, "numerical_grad_rows", &loss_valid);
                matrix->data.buffer.data[k] = old_val - eps;
                double loss_minus = numerical_loss(loss_fn, bnul, "numerical_grad_rows", &loss_valid);
                matrix->data.buffer.data[k] = old_val;
                bgrad->data.buffer.data[k] = (loss_plus - loss_minus) / (2.0 * eps);
            }
        }
        val_decref(bnul);
        if (!loss_valid) { val_decref(bgrad); return make_null(); }
        return bgrad;
    }
    if (matrix->type != VAL_LIST || !flat_is_vector(row_indices)) return make_null();

    int rows = matrix->data.list.count;
    if (rows == 0 || list_get_borrow(matrix, 0)->type != VAL_LIST) return make_null();
    int cols = list_get_borrow(matrix, 0)->data.list.count;
    Value *nul = make_null();   /* shared arg for loss_fn calls */

    /* Build zero gradient matrix */
    Value *grad = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *grow = make_list(cols);
        for (int c = 0; c < cols; c++)
            list_append_owned(grow, make_num(0.0));
        list_append_owned(grad, grow);
    }

    /* Only compute gradients for specified rows */
    for (int ri = 0; ri < flat_count(row_indices); ri++) {
        int r = flat_index_at(row_indices, ri);
        if (g_has_error) {
            val_decref(nul);
            val_decref(grad);
            return make_null();
        }
        if (r < 0 || r >= rows) continue;

        Value *row = list_get_borrow(matrix, r);
        if (!row || row->type != VAL_LIST) continue;
        Value *grad_row = list_get_borrow(grad, r);

        for (int c = 0; c < cols && c < row->data.list.count; c++) {
            Value *cell = list_get_borrow(row, c);
            double old_val = eigs_num_arg(cell, __func__);
            VAL_NUM_RAW(cell) = old_val + eps;
            double loss_plus = numerical_loss(loss_fn, nul, "numerical_grad_rows", &loss_valid);
            VAL_NUM_RAW(cell) = old_val - eps;
            double loss_minus = numerical_loss(loss_fn, nul, "numerical_grad_rows", &loss_valid);
            VAL_NUM_RAW(cell) = old_val;
            /* gradient — release the zero placeholder this slot held */
            val_decref(list_get_borrow(grad_row, c));
            list_set_owned(grad_row, c, make_num((loss_plus - loss_minus) / (2.0 * eps)));
        }
    }
    val_decref(nul);
    if (!loss_valid) { val_decref(grad); return make_null(); }
    return grad;
}

/* ==== BUILTIN: sgd_update_rows ==== */
/* sgd_update_rows of [matrix, grad, row_indices, lr]
 * Updates only the specified rows of matrix in-place: row -= lr * grad_row */
Value* builtin_sgd_update_rows(Value *arg) {
    STRICT_LIST_MAX(arg, 4, "sgd_update_rows");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *matrix = list_get_borrow(arg, 0);
    Value *grad = list_get_borrow(arg, 1);
    Value *row_indices = list_get_borrow(arg, 2);
    /* #1637: the optional lr: null keeps the default, a number sets it,
     * anything else (a bool) raises instead of silently meaning the default. */
    double lr = 0.01;
    eigs_opt_num(list_get_borrow(arg, 3), &lr, __func__);
    if (g_has_error) return make_null();
    if (!tensor_cells_numeric(matrix, "sgd_update_rows") || !tensor_cells_numeric(grad, "sgd_update_rows") || !tensor_cells_numeric(row_indices, "sgd_update_rows")) return make_null();

    /* #1093: shaped-buffer matrix + shaped-buffer gradient, index vector as a
     * list or a buffer — update the named rows' doubles in place. */
    if (matrix->type == VAL_BUFFER && grad->type == VAL_BUFFER
        && matrix->data.buffer.rows > 0 && flat_is_vector(row_indices)) {
        int brows = matrix->data.buffer.rows, bcols = matrix->data.buffer.cols;
        if (grad->data.buffer.rows < brows) brows = grad->data.buffer.rows;
        if (grad->data.buffer.cols < bcols) bcols = grad->data.buffer.cols;
        int nidx = flat_count(row_indices);
        for (int ri = 0; ri < nidx; ri++) {
            int r = flat_index_at(row_indices, ri);
            if (g_has_error) return make_null();
            if (r < 0 || r >= brows) continue;
            for (int c = 0; c < bcols; c++)
                matrix->data.buffer.data[(int64_t)r * matrix->data.buffer.cols + c] -=
                    lr * grad->data.buffer.data[(int64_t)r * grad->data.buffer.cols + c];
        }
        return matrix;
    }
    if (matrix->type != VAL_LIST || grad->type != VAL_LIST || !flat_is_vector(row_indices))
        return matrix;

    for (int ri = 0; ri < flat_count(row_indices); ri++) {
        int r = flat_index_at(row_indices, ri);
        if (g_has_error) return make_null();
        if (r < 0 || r >= matrix->data.list.count || r >= grad->data.list.count) continue;

        Value *mrow = list_get_borrow(matrix, r);
        Value *grow = list_get_borrow(grad, r);
        if (!mrow || mrow->type != VAL_LIST || !grow || grow->type != VAL_LIST) continue;

        int cols = mrow->data.list.count < grow->data.list.count
                 ? mrow->data.list.count : grow->data.list.count;
        for (int c = 0; c < cols; c++) {
            Value *old = list_get_borrow(mrow, c);
            double pv = eigs_num_arg(old, __func__);
            double gv = eigs_num_arg(list_get_borrow(grow, c), __func__);
            list_set_owned(mrow, c, make_num(pv - lr * gv));
            val_decref(old);
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
    STRICT_LIST_MAX(arg, 4, "numerical_grad_cols");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *loss_fn = list_get_borrow(arg, 0);
    Value *matrix = list_get_borrow(arg, 1);
    Value *col_indices = list_get_borrow(arg, 2);
    /* #1637: the optional eps: null keeps the default, a number sets it,
     * anything else (a bool) raises instead of silently meaning the default. */
    double eps = 0.001;
    eigs_opt_num(list_get_borrow(arg, 3), &eps, __func__);
    if (g_has_error) return make_null();
    if (!tensor_cells_numeric(matrix, "numerical_grad_cols") || !tensor_cells_numeric(col_indices, "numerical_grad_cols")) return make_null();
    if (eps <= 0) eps = 0.001;
    int loss_valid = 1;

    /* #1093: shaped-buffer matrix, list-or-buffer index vector. */
    if (matrix->type == VAL_BUFFER && matrix->data.buffer.rows > 0
        && flat_is_vector(col_indices)) {
        int brows = matrix->data.buffer.rows, bcols = matrix->data.buffer.cols;
        Value *bgrad = make_buffer_like(matrix);
        if (!bgrad) return make_null();
        Value *bnul = make_null();
        int nidx = flat_count(col_indices);
        for (int ci = 0; ci < nidx; ci++) {
            int col = flat_index_at(col_indices, ci);
            if (g_has_error) {
                val_decref(bnul);
                val_decref(bgrad);
                return make_null();
            }
            if (col < 0 || col >= bcols) continue;
            for (int r = 0; r < brows; r++) {
                int64_t k = (int64_t)r * bcols + col;
                double old_val = matrix->data.buffer.data[k];
                matrix->data.buffer.data[k] = old_val + eps;
                double loss_plus = numerical_loss(loss_fn, bnul, "numerical_grad_cols", &loss_valid);
                matrix->data.buffer.data[k] = old_val - eps;
                double loss_minus = numerical_loss(loss_fn, bnul, "numerical_grad_cols", &loss_valid);
                matrix->data.buffer.data[k] = old_val;
                bgrad->data.buffer.data[k] = (loss_plus - loss_minus) / (2.0 * eps);
            }
        }
        val_decref(bnul);
        if (!loss_valid) { val_decref(bgrad); return make_null(); }
        return bgrad;
    }
    if (matrix->type != VAL_LIST || !flat_is_vector(col_indices)) return make_null();

    int rows = matrix->data.list.count;
    if (rows == 0 || list_get_borrow(matrix, 0)->type != VAL_LIST) return make_null();
    int cols = list_get_borrow(matrix, 0)->data.list.count;
    Value *nul = make_null();   /* shared arg for loss_fn calls */

    /* Build zero gradient matrix */
    Value *grad = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *grow = make_list(cols);
        for (int c = 0; c < cols; c++)
            list_append_owned(grow, make_num(0.0));
        list_append_owned(grad, grow);
    }

    /* Only compute gradients for specified columns, across all rows */
    for (int ci = 0; ci < flat_count(col_indices); ci++) {
        int col = flat_index_at(col_indices, ci);
        if (g_has_error) {
            val_decref(nul);
            val_decref(grad);
            return make_null();
        }
        if (col < 0 || col >= cols) continue;

        for (int r = 0; r < rows; r++) {
            Value *row = list_get_borrow(matrix, r);
            if (!row || row->type != VAL_LIST || col >= row->data.list.count) continue;

            Value *orig = list_get_borrow(row, col);
            double old_val = eigs_num_arg(orig, __func__);
            val_incref(orig);   /* guard while displaced from its slot */
            /* +eps */
            Value *pp = make_num(old_val + eps);   /* birth ref doubles as slot ref */
            list_set_owned(row, col, pp);
            double loss_plus = numerical_loss(loss_fn, nul, "numerical_grad_cols", &loss_valid);
            /* -eps */
            Value *pm = make_num(old_val - eps);
            list_set_owned(row, col, pm);
            val_decref(pp);
            double loss_minus = numerical_loss(loss_fn, nul, "numerical_grad_cols", &loss_valid);
            /* restore */
            list_set_owned(row, col, orig);
            val_decref(orig);   /* drop the guard */
            val_decref(pm);
            /* gradient — release the zero placeholder this slot held */
            val_decref(list_get_borrow(list_get_borrow(grad, r), col));
            list_set_owned(list_get_borrow(grad, r), col, make_num((loss_plus - loss_minus) / (2.0 * eps)));
        }
    }
    val_decref(nul);
    if (!loss_valid) { val_decref(grad); return make_null(); }
    return grad;
}

/* ==== BUILTIN: sgd_update_cols ==== */
/* sgd_update_cols of [matrix, grad, col_indices, lr]
 * Updates only the specified columns of matrix in-place: elem -= lr * grad_elem */
Value* builtin_sgd_update_cols(Value *arg) {
    STRICT_LIST_MAX(arg, 4, "sgd_update_cols");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *matrix = list_get_borrow(arg, 0);
    Value *grad = list_get_borrow(arg, 1);
    Value *col_indices = list_get_borrow(arg, 2);
    /* #1637: the optional lr: null keeps the default, a number sets it,
     * anything else (a bool) raises instead of silently meaning the default. */
    double lr = 0.01;
    eigs_opt_num(list_get_borrow(arg, 3), &lr, __func__);
    if (g_has_error) return make_null();
    if (!tensor_cells_numeric(matrix, "sgd_update_cols") || !tensor_cells_numeric(grad, "sgd_update_cols") || !tensor_cells_numeric(col_indices, "sgd_update_cols")) return make_null();

    /* #1093: shaped-buffer matrix + gradient, list-or-buffer index vector. */
    if (matrix->type == VAL_BUFFER && grad->type == VAL_BUFFER
        && matrix->data.buffer.rows > 0 && flat_is_vector(col_indices)) {
        int brows = matrix->data.buffer.rows;
        if (grad->data.buffer.rows < brows) brows = grad->data.buffer.rows;
        int nidx = flat_count(col_indices);
        for (int ci = 0; ci < nidx; ci++) {
            int col = flat_index_at(col_indices, ci);
            if (g_has_error) return make_null();
            if (col < 0 || col >= matrix->data.buffer.cols
                || col >= grad->data.buffer.cols) continue;
            for (int r = 0; r < brows; r++)
                matrix->data.buffer.data[(int64_t)r * matrix->data.buffer.cols + col] -=
                    lr * grad->data.buffer.data[(int64_t)r * grad->data.buffer.cols + col];
        }
        return matrix;
    }
    if (matrix->type != VAL_LIST || grad->type != VAL_LIST || !flat_is_vector(col_indices))
        return matrix;

    int rows = matrix->data.list.count < grad->data.list.count
             ? matrix->data.list.count : grad->data.list.count;

    for (int ci = 0; ci < flat_count(col_indices); ci++) {
        int col = flat_index_at(col_indices, ci);
        if (g_has_error) return make_null();
        if (col < 0) continue;

        for (int r = 0; r < rows; r++) {
            Value *mrow = list_get_borrow(matrix, r);
            Value *grow = list_get_borrow(grad, r);
            if (!mrow || mrow->type != VAL_LIST || col >= mrow->data.list.count) continue;
            if (!grow || grow->type != VAL_LIST || col >= grow->data.list.count) continue;

            Value *old = list_get_borrow(mrow, col);
            double pv = eigs_num_arg(old, __func__);
            double gv = eigs_num_arg(list_get_borrow(grow, col), __func__);
            list_set_owned(mrow, col, make_num(pv - lr * gv));
            val_decref(old);
        }
    }
    return matrix;
}
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_tensor_save(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "tensor_save");
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2,
              "tensor_save", "[tensor, path]", make_bool(0));
    Value *tensor = list_get_borrow(arg, 0);
    Value *path_val = list_get_borrow(arg, 1);
    ARG_GUARD(!tensor || (tensor->type != VAL_LIST && tensor->type != VAL_BUFFER)
              || !path_val || path_val->type != VAL_STR,   /* #1093 */
              "tensor_save", "[a list or buffer tensor, a string path]", make_bool(0));

    int rows, cols;
    int ndim = tensor_dims(tensor, &rows, &cols);
    /* tensor_dims answers 0 for an empty list or one whose first element is
     * neither a number nor a list — i.e. the argument is a list but not a 1D
     * or 2D tensor, which is a shape/type mistake in the tensor argument and
     * not an I/O failure (no file has been opened yet at this point). */
    ARG_GUARD(ndim == 0, "tensor_save", "a non-empty 1D or 2D tensor", make_bool(0));
    if ((int64_t)rows * (int64_t)cols > EIGS_TENSOR_MAX_ELEMENTS) {
        rt_error(EK_LIMIT, 0,
                 "tensor_save: '%s' has %lld elements, over the %d-element cap",
                 path_val->data.str, (long long)rows * cols,
                 EIGS_TENSOR_MAX_ELEMENTS);
        return make_bool(0);
    }

    /* Flatten before opening the file: a strict #1416 rejection must not
     * leave a partial file behind, and a direct C helper raise does not
     * unwind this builtin by itself. */
    double *flat = tensor_to_flat(tensor, &rows, &cols, "tensor_save");
    /* A 2-D tensor may legitimately have zero columns. tensor_to_flat has
     * still performed strict element validation above, but has no allocation
     * to return for that shape. Preserve the historical save format: write
     * its header and the empty data/observer sections. A NULL for any other
     * shape remains a conversion failure. */
    if (!flat && cols != 0) return make_bool(0);
    if (!flat && g_has_error) return make_bool(0);

    FILE *f = xfopen_write(path_val->data.str, "wb");
    /* fs:ANSWER both arguments were accepted by the guards above; a NULL FILE*
     * is xfopen_write failing, and 0 is this builtin's failure bit (the success
     * path ends in make_bool(1)). */
    if (!f) { free(flat); return make_bool(0); }

    uint32_t header[4] = { (uint32_t)ndim, (uint32_t)rows, (uint32_t)cols, 1 /* flags: has observer */ };
    fwrite(header, sizeof(uint32_t), 4, f);

    int total = rows * cols;

    /* Write numeric data */
    if (total > 0) fwrite(flat, sizeof(double), total, f);
    free(flat);

    /* #262 Step E: tensor elements are list items, not bindings, so they never
     * carry observer state under the slot model. Keep the on-disk format (5
     * observer doubles per element) for compatibility, but write zeros. */
    {
        double obs[5] = {0, 0, 0, 0, 0};
        int n = (ndim == 1) ? cols : rows * cols;
        for (int i = 0; i < n; i++) fwrite(obs, sizeof(double), 5, f);
    }

    fclose(f);
    return make_bool(1);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* #262 Step E: the on-disk observer block is read past (format compatibility)
 * but no longer applied — Values carry no observer state under the slot model. */
static void restore_observer_1d(Value *list, double *obs_data, int count) {
    (void)list; (void)obs_data; (void)count;
}

static void restore_observer_2d(Value *tensor, double *obs_data, int rows, int cols) {
    (void)tensor; (void)obs_data; (void)rows; (void)cols;
}

/* ==== BUILTIN: tensor_load ==== */
/* tensor_load of path — load 1D or 2D tensor from binary file.
 * Restores observer state if present in the file. */
#if !EIGENSCRIPT_FREESTANDING
static void tensor_load_limit_raise(const char *path, uint32_t rows,
                                    uint32_t cols) {
    uint64_t total = (uint64_t)rows * (uint64_t)cols;
    const char *dimension = rows > EIGS_TENSOR_MAX_ELEMENTS ? "rows" :
                            cols > EIGS_TENSOR_MAX_ELEMENTS ? "columns" :
                            "elements";
    unsigned long long offending = rows > EIGS_TENSOR_MAX_ELEMENTS ? rows :
                                   cols > EIGS_TENSOR_MAX_ELEMENTS ? cols : total;
    rt_error(EK_LIMIT, 0,
             "tensor_load: '%s' has %s=%llu, over the %d-element cap",
             path, dimension, offending, EIGS_TENSOR_MAX_ELEMENTS);
}

/* tensor_load predates the tape and successful tensors can be much larger
 * than an N record.  Record one small verdict for every valid call instead:
 * null means the live loader continues, while [rows, cols] reconstructs the
 * new filesystem-dependent over-cap raise without reopening the file. */
static void tensor_load_record_verdict(uint32_t rows, uint32_t cols) {
    if (!__builtin_expect(g_trace_enabled, 0)) return;
    Value *verdict;
    if (rows || cols) {
        verdict = make_list(2);
        list_append_owned(verdict, make_num((double)rows));
        list_append_owned(verdict, make_num((double)cols));
    } else verdict = make_null();
    trace_nondet_value("tensor_load", verdict);
    val_decref(verdict);
}

Value* builtin_tensor_load(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();

    int replayed_verdict = 0;
    if (__builtin_expect(g_replay_enabled, 0)) {
        Value *verdict;
        if (trace_replay_refuse_off_owner("tensor_load")) return make_null();
        if (trace_replay_take("tensor_load", &verdict)) {
            replayed_verdict = 1;
            if (verdict && verdict->type == VAL_LIST &&
                verdict->data.list.count == 2 &&
                list_get_borrow(verdict, 0)->type == VAL_NUM &&
                list_get_borrow(verdict, 1)->type == VAL_NUM) {
                uint32_t rows = (uint32_t)eigs_list_num(verdict, 0, __func__);
                uint32_t cols = (uint32_t)eigs_list_num(verdict, 1, __func__);
                val_decref(verdict);
                tensor_load_limit_raise(arg->data.str, rows, cols);
                return make_null();
            }
            val_decref(verdict);
        }
    }

    FILE *f = fopen(arg->data.str, "rb");
    if (!f) { tensor_load_record_verdict(0, 0); return make_null(); }

    /* Try new format (4-word header with flags) */
    uint32_t header[4];
    if (fread(header, sizeof(uint32_t), 4, f) != 4) {
        fclose(f); tensor_load_record_verdict(0, 0); return make_null();
    }

    uint32_t ndim_raw = header[0];
    uint32_t rows_raw = header[1];
    uint32_t cols_raw = header[2];
    uint32_t flags = header[3];

    /* Detect old format: flags would be a huge number if it's actually data */
    int has_observer = 0;
    if (flags <= 1) {
        has_observer = (flags & 1);
    } else {
        /* Old 3-word header — rewind and re-read */
        fseek(f, 0, SEEK_SET);
        uint32_t old_header[3];
        if (fread(old_header, sizeof(uint32_t), 3, f) != 3) {
            fclose(f); tensor_load_record_verdict(0, 0); return make_null();
        }
        ndim_raw = old_header[0];
        rows_raw = old_header[1];
        cols_raw = old_header[2];
        has_observer = 0;
    }

    if (ndim_raw != 1 && ndim_raw != 2) {
        fclose(f); tensor_load_record_verdict(0, 0); return make_null();
    }
    if (rows_raw == 0 || cols_raw == 0) {
        fclose(f); tensor_load_record_verdict(0, 0); return make_null();
    }

    uint64_t total64 = (uint64_t)rows_raw * (uint64_t)cols_raw;
    if (total64 > EIGS_TENSOR_MAX_ELEMENTS) {
        fclose(f);
        /* A recorded non-cap decision still uses the historical live payload
         * path. If that file has since grown beyond the cap, reject it with
         * the old null stand-in rather than inventing a new catch branch. */
        if (replayed_verdict) return make_null();
        tensor_load_record_verdict(rows_raw, cols_raw);
        tensor_load_limit_raise(arg->data.str, rows_raw, cols_raw);
        return make_null();
    }

    int ndim = (int)ndim_raw;
    int rows = (int)rows_raw;
    int cols = (int)cols_raw;
    int total = (int)total64;

    /* Read numeric data */
    double *data = xmalloc_array((size_t)total, sizeof(double));
    if (!data) {
        fclose(f); tensor_load_record_verdict(0, 0); return make_null();
    }
    if ((int)fread(data, sizeof(double), total, f) != total) {
        free(data); fclose(f); tensor_load_record_verdict(0, 0); return make_null();
    }
    /* #971: the file is untrusted bytes, so a NaN pattern is reachable
     * here. flat_to_tensor_* would collapse it through make_num anyway
     * (same 0 + EIGS_MATH_INVALID); guarding first lets the strict raise
     * name tensor_load. */
    for (int i = 0; i < total; i++) {
        if (data[i] != data[i]) data[i] = num_guard_named(data[i], "tensor_load");
        if (g_has_error) {
            free(data); fclose(f); tensor_load_record_verdict(0, 0);
            return make_null();
        }
    }

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

    if (g_has_error) {
        free(obs_data); val_decref(result); tensor_load_record_verdict(0, 0);
        return make_null();
    }

    /* Restore observer state */
    if (obs_data && result) {
        if (ndim == 1)
            restore_observer_1d(result, obs_data, total);
        else
            restore_observer_2d(result, obs_data, rows, cols);
        free(obs_data);
    }

    tensor_load_record_verdict(0, 0);
    return result;
}
#endif /* !EIGENSCRIPT_FREESTANDING */
