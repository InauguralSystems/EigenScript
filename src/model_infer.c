/*
 * EigenScript Model Inference — shared kernels, forward pass, generation.
 *
 * Public kernels (double precision) exported for EigenScript tensor builtins:
 *   ne_softmax_buf, ne_matmul_buf
 *
 * Float-precision model internals:
 *   ne_softmax_buf_f, ne_matmul_buf_f, ne_gelu_buf_f, attention, ffn, PE,
 *   layer_norm, native_forward, generate_response
 */

#include "model_internal.h"

/* ================================================================
 * PUBLIC KERNELS (double precision) — used by eigenscript.c tensor builtins
 * ================================================================ */

void ne_softmax_buf(double* data, int64_t rows, int64_t cols) {
    for (int64_t i = 0; i < rows; i++) {
        double* row = data + i * cols;
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

void ne_matmul_buf(
    double* a, int64_t m, int64_t k,
    double* b, int64_t n,
    double* out
) {
    memset(out, 0, m * n * sizeof(double));
    for (int64_t i0 = 0; i0 < m; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < k; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < m ? i0 + NE_TILE_SIZE : m;
                int64_t j_end = j0 + NE_TILE_SIZE < n ? j0 + NE_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TILE_SIZE < k ? k0 + NE_TILE_SIZE : k;
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

/* ================================================================
 * FLOAT KERNELS — model internal
 * ================================================================ */

void ne_softmax_buf_f(float* data, int64_t rows, int64_t cols) {
    for (int64_t i = 0; i < rows; i++) {
        float* row = data + i * cols;
        if (cols <= 0) continue;
        float max_val = row[0];
        for (int64_t j = 1; j < cols; j++) {
            if (row[j] > max_val) max_val = row[j];
        }
        float sum = 0.0f;
        for (int64_t j = 0; j < cols; j++) {
            row[j] = expf(row[j] - max_val);
            sum += row[j];
        }
        /* See ne_softmax_buf for the NaN-fallback rationale. */
        if (!(sum > 0.0f)) {
            float u = 1.0f / (float)cols;
            for (int64_t j = 0; j < cols; j++) row[j] = u;
            continue;
        }
        for (int64_t j = 0; j < cols; j++) {
            row[j] /= sum;
        }
    }
}

void ne_matmul_buf_f(
    float* a, int64_t m, int64_t k,
    float* b, int64_t n,
    float* out
) {
    memset(out, 0, m * n * sizeof(float));
    for (int64_t i0 = 0; i0 < m; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < k; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < m ? i0 + NE_TILE_SIZE : m;
                int64_t j_end = j0 + NE_TILE_SIZE < n ? j0 + NE_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TILE_SIZE < k ? k0 + NE_TILE_SIZE : k;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        float a_ik = a[i * k + kk];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * n + j] += a_ik * b[kk * n + j];
                        }
                    }
                }
            }
        }
    }
}

/* Packed ternary matmul: out[m,n] = x[m,k] @ W_packed[k,n]
 * W encoded as 2 bits per weight, 4 weights per byte (row-major, n-major within row).
 * code 00 = 0, 01 = +1, 11 = -1; scaled by alpha at the end.
 *
 * Optimization: unpack entire row of W once per k-iteration into a small
 * signed-int buffer on the stack, then use that for the inner n-loop.
 * This amortizes bit extraction over all m rows of x. */
void ne_matmul_buf_packed_f(
    float *x, int64_t m, int64_t k,
    uint8_t *w_packed, float alpha, int64_t n,
    float *out
) {
    memset(out, 0, m * n * sizeof(float));
    /* Temporary unpacked row — allocated from heap to handle large n.
     * Values in {-1, 0, +1}. */
    int8_t *w_row = xcalloc(n, 1);
    for (int64_t kk = 0; kk < k; kk++) {
        /* Unpack row kk of W once */
        int64_t row_base = kk * n;
        for (int64_t j = 0; j < n; j++) {
            int64_t idx = row_base + j;
            uint8_t code = (w_packed[idx >> 2] >> ((idx & 3) << 1)) & 3;
            w_row[j] = (code == 1) ? 1 : (code == 3) ? -1 : 0;
        }
        /* For each output row, apply w_row */
        for (int64_t i = 0; i < m; i++) {
            float a_ik = x[i * k + kk];
            if (a_ik == 0.0f) continue;
            float *out_row = out + i * n;
            for (int64_t j = 0; j < n; j++) {
                /* w_row[j] is -1, 0, or +1 — this multiply is effectively add/sub/skip
                 * but writing it as multiply lets the compiler vectorize. */
                out_row[j] += a_ik * (float)w_row[j];
            }
        }
    }
    free(w_row);
    /* Apply per-matrix scale once at the end */
    if (alpha != 1.0f) {
        int64_t total = m * n;
        for (int64_t i = 0; i < total; i++) out[i] *= alpha;
    }
}

void ne_fused_attention_forward_buf_packed_f(
    float *x, int64_t seq_len, int64_t d_model,
    uint8_t *wq_p, float wq_alpha,
    uint8_t *wk_p, float wk_alpha,
    uint8_t *wv_p, float wv_alpha,
    uint8_t *wo_p, float wo_alpha,
    float *out, float *attn_probs_out
) {
    int64_t sd = seq_len * d_model;
    int64_t ss = seq_len * seq_len;

    float *Q = xcalloc(sd, sizeof(float));
    float *K = xcalloc(sd, sizeof(float));
    float *V = xcalloc(sd, sizeof(float));
    float *scores = xcalloc(ss, sizeof(float));
    float *context = xcalloc(sd, sizeof(float));

    ne_matmul_buf_packed_f(x, seq_len, d_model, wq_p, wq_alpha, d_model, Q);
    ne_matmul_buf_packed_f(x, seq_len, d_model, wk_p, wk_alpha, d_model, K);
    ne_matmul_buf_packed_f(x, seq_len, d_model, wv_p, wv_alpha, d_model, V);

    float *Kt = xcalloc(sd, sizeof(float));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < d_model; j++) {
            Kt[j * seq_len + i] = K[i * d_model + j];
        }
    }
    ne_matmul_buf_f(Q, seq_len, d_model, Kt, seq_len, scores);
    free(Kt);

    float scale = 1.0f / sqrtf((float)d_model);
    float neg_inf = -1.0f / 0.0f;
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < seq_len; j++) {
            scores[i * seq_len + j] *= scale;
            if (j > i) scores[i * seq_len + j] = neg_inf;
        }
    }

    ne_softmax_buf_f(scores, seq_len, seq_len);
    memcpy(attn_probs_out, scores, ss * sizeof(float));

    ne_matmul_buf_f(scores, seq_len, seq_len, V, d_model, context);
    ne_matmul_buf_packed_f(context, seq_len, d_model, wo_p, wo_alpha, d_model, out);

    free(Q); free(K); free(V); free(scores); free(context);
}

void ne_fused_ffn_forward_buf_packed_f(
    float *x, int64_t seq_len, int64_t d_model,
    uint8_t *w1_p, float w1_alpha, int64_t d_ff,
    uint8_t *w2_p, float w2_alpha,
    int32_t use_gelu,
    float *out, float *pre_act_out
) {
    int64_t sf = seq_len * d_ff;
    float *hidden = xcalloc(sf, sizeof(float));

    ne_matmul_buf_packed_f(x, seq_len, d_model, w1_p, w1_alpha, d_ff, hidden);
    memcpy(pre_act_out, hidden, sf * sizeof(float));

    if (use_gelu) ne_gelu_buf_f(hidden, sf);

    ne_matmul_buf_packed_f(hidden, seq_len, d_ff, w2_p, w2_alpha, d_model, out);

    free(hidden);
}

void ne_gelu_buf_f(float* data, int64_t size) {
    const float sqrt_2_over_pi = sqrtf(2.0f / (float)M_PI);
    for (int64_t i = 0; i < size; i++) {
        float x = data[i];
        data[i] = 0.5f * x * (1.0f + tanhf(sqrt_2_over_pi * (x + 0.044715f * x * x * x)));
    }
}

void ne_fused_attention_forward_buf_f(
    float* x, int64_t seq_len, int64_t d_model,
    float* wq, float* wk, float* wv, float* wo,
    float* out,
    float* attn_probs_out
) {
    int64_t sd = seq_len * d_model;
    int64_t ss = seq_len * seq_len;

    float* Q = (float*)xcalloc(sd, sizeof(float));
    float* K = (float*)xcalloc(sd, sizeof(float));
    float* V = (float*)xcalloc(sd, sizeof(float));
    float* scores = (float*)xcalloc(ss, sizeof(float));
    float* context = (float*)xcalloc(sd, sizeof(float));

    ne_matmul_buf_f(x, seq_len, d_model, wq, d_model, Q);
    ne_matmul_buf_f(x, seq_len, d_model, wk, d_model, K);
    ne_matmul_buf_f(x, seq_len, d_model, wv, d_model, V);

    float* Kt = (float*)xcalloc(sd, sizeof(float));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < d_model; j++) {
            Kt[j * seq_len + i] = K[i * d_model + j];
        }
    }
    ne_matmul_buf_f(Q, seq_len, d_model, Kt, seq_len, scores);
    free(Kt);

    float scale = 1.0f / sqrtf((float)d_model);
    float neg_inf = -1.0f / 0.0f;
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < seq_len; j++) {
            scores[i * seq_len + j] *= scale;
            if (j > i) {
                scores[i * seq_len + j] = neg_inf;
            }
        }
    }

    ne_softmax_buf_f(scores, seq_len, seq_len);

    memcpy(attn_probs_out, scores, ss * sizeof(float));

    ne_matmul_buf_f(scores, seq_len, seq_len, V, d_model, context);

    ne_matmul_buf_f(context, seq_len, d_model, wo, d_model, out);

    free(Q);
    free(K);
    free(V);
    free(scores);
    free(context);
}

void ne_fused_ffn_forward_buf_f(
    float* x, int64_t seq_len, int64_t d_model,
    float* w1, int64_t d_ff,
    float* w2,
    int32_t use_gelu,
    float* out,
    float* pre_act_out
) {
    int64_t sf = seq_len * d_ff;

    float* hidden = (float*)xcalloc(sf, sizeof(float));

    ne_matmul_buf_f(x, seq_len, d_model, w1, d_ff, hidden);

    memcpy(pre_act_out, hidden, sf * sizeof(float));

    if (use_gelu) {
        ne_gelu_buf_f(hidden, sf);
    }

    ne_matmul_buf_f(hidden, seq_len, d_ff, w2, d_model, out);

    free(hidden);
}

static void layer_norm(float *x, int64_t d, float *gamma, float *beta, float eps, float *out) {
    float mean = 0.0f;
    for (int64_t i = 0; i < d; i++) mean += x[i];
    mean /= (float)d;
    float var = 0.0f;
    for (int64_t i = 0; i < d; i++) { float diff = x[i] - mean; var += diff * diff; }
    var /= (float)d;
    float std_val = sqrtf(var + eps);
    for (int64_t i = 0; i < d; i++) out[i] = (x[i] - mean) / std_val * gamma[i] + beta[i];
}

void create_sinusoidal_pe_f(float *pe, int seq_len, int d_model) {
    for (int pos = 0; pos < seq_len; pos++) {
        for (int i = 0; i < d_model; i += 2) {
            float div_term = expf((float)i * -(logf(10000.0f) / (float)d_model));
            pe[pos * d_model + i] = sinf((float)pos * div_term);
            if (i + 1 < d_model) pe[pos * d_model + i + 1] = cosf((float)pos * div_term);
        }
    }
}

static void native_forward(int *token_ids, int seq_len, TransformerModel *model, float *logits_out) {
    int d_model = model->config.d_model;
    int d_ff = model->config.d_ff;

    float *x = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
    for (int i = 0; i < seq_len; i++) {
        int tid = token_ids[i];
        if (tid < 0) tid = 0;
        if (tid >= model->config.vocab_size) tid = model->config.vocab_size - 1;
        memcpy(x + i * d_model, model->token_embeddings + tid * d_model, d_model * sizeof(float));
    }

    float *pe = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
    create_sinusoidal_pe_f(pe, seq_len, d_model);
    for (int i = 0; i < seq_len * d_model; i++) x[i] += pe[i];
    free(pe);

    int use_tern = (model->weight_format == WEIGHT_FORMAT_TERNARY);

    for (int l = 0; l < model->config.n_layers; l++) {
        TransformerLayer *layer = &model->layers[l];

        float *norm1 = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
        for (int i = 0; i < seq_len; i++) {
            layer_norm(x + i * d_model, d_model, layer->ln1_gamma, layer->ln1_beta, 1e-6f, norm1 + i * d_model);
        }

        float *attn_out = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
        float *attn_probs = xcalloc_array(safe_size_mul(seq_len, seq_len), sizeof(float));
        if (use_tern) {
            ne_fused_attention_forward_buf_packed_f(norm1, seq_len, d_model,
                layer->w_q_packed, layer->w_q_alpha,
                layer->w_k_packed, layer->w_k_alpha,
                layer->w_v_packed, layer->w_v_alpha,
                layer->w_o_packed, layer->w_o_alpha,
                attn_out, attn_probs);
        } else {
            ne_fused_attention_forward_buf_f(norm1, seq_len, d_model,
                layer->w_q, layer->w_k, layer->w_v, layer->w_o,
                attn_out, attn_probs);
        }
        free(norm1);
        free(attn_probs);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += attn_out[i];
        free(attn_out);

        float *norm2 = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
        for (int i = 0; i < seq_len; i++) {
            layer_norm(x + i * d_model, d_model, layer->ln2_gamma, layer->ln2_beta, 1e-6f, norm2 + i * d_model);
        }

        float *ffn_out = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
        float *pre_act = xcalloc_array(safe_size_mul(seq_len, d_ff), sizeof(float));
        if (use_tern) {
            ne_fused_ffn_forward_buf_packed_f(norm2, seq_len, d_model,
                layer->w_ff1_packed, layer->w_ff1_alpha, d_ff,
                layer->w_ff2_packed, layer->w_ff2_alpha,
                1, ffn_out, pre_act);
        } else {
            ne_fused_ffn_forward_buf_f(norm2, seq_len, d_model,
                layer->w_ff1, d_ff, layer->w_ff2, 1, ffn_out, pre_act);
        }
        free(norm2);
        free(pre_act);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += ffn_out[i];
        free(ffn_out);
    }

    float *last_hidden = x + (seq_len - 1) * d_model;
    for (int j = 0; j < model->config.vocab_size; j++) {
        float sum = 0.0f;
        for (int k = 0; k < d_model; k++) {
            sum += last_hidden[k] * model->output_proj[k * model->config.vocab_size + j];
        }
        logits_out[j] = sum;
    }

    free(x);
}

/* Descending order, NaN-safe: a NaN comparison yields 0 (treated equal) rather
 * than an inconsistent ordering, which qsort is allowed to fault on. */
static int cmp_prob_desc(const void *a, const void *b) {
    float fa = *(const float *)a, fb = *(const float *)b;
    return (fa < fb) - (fa > fb);
}

static int* generate_response(int *prompt_ids, int prompt_len, TransformerModel *model, double temperature, int max_tokens, double top_p, int *out_len) {
    /* temperature controls sampling: < 0.01 = greedy argmax, otherwise top-k sampling
     * Returns a caller-owned int array of generated token IDs. Caller must free. */
    int vocab_size = model->config.vocab_size;
    int max_seq_len = model->config.max_seq_len;

    int *token_ids = xcalloc_array(safe_size_mul(max_seq_len, 4), sizeof(int));
    int num_tokens = prompt_len < max_seq_len ? prompt_len : max_seq_len;
    for (int i = 0; i < num_tokens; i++) {
        int tid = prompt_ids[i];
        if (tid < 0) tid = 0;
        if (tid >= vocab_size) tid = vocab_size - 1;
        token_ids[i] = tid;
    }

    int total_tokens = num_tokens;
    int *output_ids = xcalloc(max_tokens, sizeof(int));
    int output_count = 0;

    float temp_f = (float)temperature;

    for (int step = 0; step < max_tokens; step++) {
        int ctx_start = total_tokens > max_seq_len ? total_tokens - max_seq_len : 0;
        int ctx_len = total_tokens - ctx_start;

        float *logits = xcalloc(vocab_size, sizeof(float));
        native_forward(token_ids + ctx_start, ctx_len, model, logits);

        int next_token;
        if (temp_f < 0.01f) {
            /* Greedy argmax */
            next_token = 0;
            float best = logits[0];
            for (int i = 1; i < vocab_size; i++) {
                if (logits[i] > best) { best = logits[i]; next_token = i; }
            }
        } else {
            /* Temperature-scaled top-k sampling */
            for (int i = 0; i < vocab_size; i++)
                logits[i] /= temp_f;

            float max_l = logits[0];
            for (int i = 1; i < vocab_size; i++)
                if (logits[i] > max_l) max_l = logits[i];
            float sum = 0.0f;
            for (int i = 0; i < vocab_size; i++) {
                logits[i] = expf(logits[i] - max_l);
                sum += logits[i];
            }
            /* Fallback to uniform on NaN/underflow (see ne_softmax_buf_f). */
            if (!(sum > 0.0f)) {
                float u = 1.0f / (float)vocab_size;
                for (int i = 0; i < vocab_size; i++) logits[i] = u;
            } else {
                for (int i = 0; i < vocab_size; i++) logits[i] /= sum;
            }

            /* Truncate the tail before sampling. Two policies:
             *
             * top-p (nucleus): keep the smallest set of tokens whose cumulative
             * probability reaches p. The candidate set ADAPTS to how confident
             * the model is -- narrow where the next token is nearly determined
             * (after `is`, or mid-keyword), wide where it genuinely branches.
             *
             * top-k: keep a fixed 40 regardless. That is the failure mode this
             * model actually hits: where the distribution is sharp, a fixed k
             * still admits 39 low-probability tokens and renormalises them up,
             * and where it is flat, k=40 truncates real choices. Generation
             * collapsed onto the single most frequent identifier (`b is b + 0`
             * repeated, 7 distinct identifiers in a whole sample) even at
             * held-out perplexity 5.07, i.e. with the model fitting fine.
             *
             * top_p <= 0 or >= 1 keeps the historical top-k path, so existing
             * callers and their recorded numbers are unchanged. */
            float probs_sorted[VOCAB_SIZE];
            float threshold;
            if (top_p > 0.0 && top_p < 1.0) {
                memcpy(probs_sorted, logits, (size_t)vocab_size * sizeof(float));
                qsort(probs_sorted, (size_t)vocab_size, sizeof(float), cmp_prob_desc);
                float cum = 0.0f;
                threshold = probs_sorted[0];
                for (int i = 0; i < vocab_size; i++) {
                    cum += probs_sorted[i];
                    if (cum >= (float)top_p) { threshold = probs_sorted[i]; break; }
                }
                /* Never empty the candidate set: if rounding leaves the cutoff
                 * above every probability, the argmax alone must survive. */
                if (threshold > probs_sorted[0]) threshold = probs_sorted[0];
            } else {
                int top_k = 40;
                if (top_k > vocab_size) top_k = vocab_size;
                memcpy(probs_sorted, logits, (size_t)vocab_size * sizeof(float));
                for (int j = 0; j < top_k; j++) {
                    int max_idx = j;
                    for (int i = j + 1; i < vocab_size; i++)
                        if (probs_sorted[i] > probs_sorted[max_idx]) max_idx = i;
                    float tmp = probs_sorted[j];
                    probs_sorted[j] = probs_sorted[max_idx];
                    probs_sorted[max_idx] = tmp;
                }
                threshold = probs_sorted[top_k - 1];
            }
            float filtered_sum = 0.0f;
            for (int i = 0; i < vocab_size; i++) {
                if (logits[i] < threshold) logits[i] = 0.0f;
                filtered_sum += logits[i];
            }
            if (filtered_sum > 0.0f) {
                for (int i = 0; i < vocab_size; i++)
                    logits[i] /= filtered_sum;
            }

            float r = (float)rand() / (float)RAND_MAX;
            float cumsum = 0.0f;
            next_token = vocab_size - 1;
            for (int i = 0; i < vocab_size; i++) {
                cumsum += logits[i];
                if (cumsum >= r) { next_token = i; break; }
            }
        }
        free(logits);

        if (total_tokens < max_seq_len * 4) {
            token_ids[total_tokens++] = next_token;
        }
        output_ids[output_count++] = next_token;
    }

    free(token_ids);
    *out_len = output_count;
    return output_ids;
}

int g_model_age = 0;
int g_training_samples = 0;

Value* builtin_eigen_model_loaded(Value *arg) {
    (void)arg;
    return make_num(g_model.loaded ? 1 : 0);
}

Value* builtin_eigen_generate(Value *arg) {
    /* Input: [prompt_ids_list, temperature, max_tokens]
     * Output: list of generated token IDs */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        fprintf(stderr, "eigen_generate: requires [prompt_ids, temperature, max_tokens]\n");
        return make_list(0);
    }
    Value *prompt_list = arg->data.list.items[0];
    if (prompt_list->type != VAL_LIST) {
        fprintf(stderr, "eigen_generate: prompt_ids must be a list\n");
        return make_list(0);
    }

    double temperature = 0.1;
    int max_tokens = 80;
    /* Optional 4th arg: top_p. Absent (or outside (0,1)) keeps the historical
     * fixed top-k=40 path, so every existing caller and recorded number is
     * unchanged -- decoding policy is opt-in, not a silent default flip. */
    double top_p = 0.0;
    if (arg->data.list.items[1]->type == VAL_NUM) temperature = arg->data.list.items[1]->data.num;
    if (arg->data.list.items[2]->type == VAL_NUM) max_tokens = (int)arg->data.list.items[2]->data.num;
    if (arg->data.list.count >= 4 && arg->data.list.items[3]->type == VAL_NUM)
        top_p = arg->data.list.items[3]->data.num;

    if (!g_model.loaded) return make_list(0);

    /* Validate prompt and token count */
    int prompt_len = prompt_list->data.list.count;
    if (prompt_len <= 0) {
        fprintf(stderr, "eigen_generate: prompt must be non-empty\n");
        return make_list(0);
    }
    #define EIGS_MAX_GENERATE_TOKENS 4096
    if (max_tokens <= 0 || max_tokens > EIGS_MAX_GENERATE_TOKENS) {
        if (max_tokens <= 0) {
            fprintf(stderr, "eigen_generate: max_tokens must be positive\n");
            return make_list(0);
        }
        max_tokens = EIGS_MAX_GENERATE_TOKENS;
    }

    int *prompt_ids = xcalloc(prompt_len, sizeof(int));
    for (int i = 0; i < prompt_len; i++) {
        Value *v = prompt_list->data.list.items[i];
        prompt_ids[i] = (v->type == VAL_NUM) ? (int)v->data.num : 0;
    }

    int out_len = 0;
    int *output_ids = generate_response(prompt_ids, prompt_len, &g_model, temperature, max_tokens, top_p, &out_len);
    free(prompt_ids);

    Value *result = make_list(out_len);
    for (int i = 0; i < out_len; i++) {
        list_append_owned(result, make_num((double)output_ids[i]));
    }
    free(output_ids);
    return result;
}

Value* builtin_eigen_eval_loss(Value *arg) {
    /* Input: [prompt_ids_list, target_id]
     * Output: cross-entropy of target_id given the prompt, in nats.
     *
     * Held-out loss is the selection metric a language model should be ranked
     * on, and this is the forward-only path that makes it computable. The task
     * metrics (parse rate) sample 300 generations; this scores one point per
     * WINDOW, so a few thousand windows give ~10x the samples on a continuous
     * scale instead of a binary one. That difference is not academic: a night
     * of A/B runs on the n=30 parse rate could not distinguish two arms whose
     * accuracy differed by 14 points, because a pass/fail metric at n=30 has a
     * 95% interval about 30 points wide.
     *
     * Forward only -- no backward, no weight update, no requantise, no observer
     * state, and g_model_age/g_training_samples are untouched, so scoring a
     * checkpoint never mutates it. */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        fprintf(stderr, "eigen_eval_loss: requires [prompt_ids, target_id]\n");
        return make_num(-1.0);
    }
    Value *prompt_list = arg->data.list.items[0];
    if (prompt_list->type != VAL_LIST) {
        fprintf(stderr, "eigen_eval_loss: prompt_ids must be a list\n");
        return make_num(-1.0);
    }
    if (arg->data.list.items[1]->type != VAL_NUM) {
        fprintf(stderr, "eigen_eval_loss: target_id must be a number\n");
        return make_num(-1.0);
    }
    int target_id = (int)arg->data.list.items[1]->data.num;

    if (!g_model.loaded) return make_num(-1.0);
    int vocab_size = g_model.config.vocab_size;
    if (target_id < 0 || target_id >= vocab_size) {
        fprintf(stderr, "eigen_eval_loss: target_id %d out of range [0,%d)\n", target_id, vocab_size);
        return make_num(-1.0);
    }

    int prompt_len = prompt_list->data.list.count;
    if (prompt_len <= 0) {
        fprintf(stderr, "eigen_eval_loss: prompt must be non-empty\n");
        return make_num(-1.0);
    }

    int *prompt_ids = xcalloc(prompt_len, sizeof(int));
    for (int i = 0; i < prompt_len; i++) {
        Value *v = prompt_list->data.list.items[i];
        int t = (v->type == VAL_NUM) ? (int)v->data.num : 0;
        if (t < 0 || t >= vocab_size) t = 0;
        prompt_ids[i] = t;
    }

    float *logits = xcalloc(vocab_size, sizeof(float));
    native_forward(prompt_ids, prompt_len, &g_model, logits);
    free(prompt_ids);

    /* Numerically stable log-softmax at the target: subtract the max before
     * exponentiating, or a large logit overflows float and returns inf/nan --
     * which would silently poison the mean over thousands of windows. */
    float maxl = logits[0];
    for (int j = 1; j < vocab_size; j++) if (logits[j] > maxl) maxl = logits[j];
    double sum = 0.0;
    for (int j = 0; j < vocab_size; j++) sum += exp((double)(logits[j] - maxl));
    double loss = -((double)(logits[target_id] - maxl) - log(sum));
    free(logits);

    if (isnan(loss) || isinf(loss)) return make_num(-1.0);
    return make_num(loss);
}

Value* builtin_eigen_model_info(Value *arg) {
    (void)arg;
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"model_loaded\": %s, \"vocab_size\": %d, \"d_model\": %d, \"n_layers\": %d, "
        "\"model_age\": %d, \"training_samples\": %d, \"inference_engine\": \"eigenscript\"}",
        g_model.loaded ? "true" : "false",
        g_model.config.vocab_size, g_model.config.d_model, g_model.config.n_layers,
        g_model_age, g_training_samples);
    return make_str(buf);
}
