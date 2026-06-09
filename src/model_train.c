/*
 * EigenScript Model Training — backward pass, training step, registration.
 * Uses forward kernels from model_infer.c via model_internal.h.
 */

#include "model_internal.h"

/* ================================================================
 * TERNARY QUANTIZATION — BitNet b1.58 weight-only (Option A)
 *
 * Per-matrix scale alpha = mean(|w|). Threshold = alpha / 2.
 * Values project to {-alpha, 0, +alpha}, stored as float.
 * Existing matmul kernels work unchanged on the result.
 * ================================================================ */

void quantize_ternary(float *dst, float *src, int64_t n, float *out_alpha) {
    if (n <= 0) { if (out_alpha) *out_alpha = 0.0f; return; }
    float abs_sum = 0.0f;
    for (int64_t i = 0; i < n; i++) {
        float a = src[i];
        abs_sum += (a < 0.0f) ? -a : a;
    }
    float alpha = abs_sum / (float)n;
    float threshold = alpha * 0.5f;
    for (int64_t i = 0; i < n; i++) {
        float w = src[i];
        float aw = (w < 0.0f) ? -w : w;
        if (aw <= threshold) {
            dst[i] = 0.0f;
        } else if (w > 0.0f) {
            dst[i] = alpha;
        } else {
            dst[i] = -alpha;
        }
    }
    if (out_alpha) *out_alpha = alpha;
}

/* Pack ternary floats (in {-alpha, 0, +alpha}) into 2-bit codes.
 * Encoding: 00 = zero, 01 = +alpha, 11 = -alpha.
 * dst size = ceil(n / 4) bytes. Packed little-endian within byte. */
void pack_ternary(uint8_t *dst, float *src_tern, float alpha, int64_t n) {
    int64_t bytes = (n + 3) / 4;
    memset(dst, 0, bytes);
    float threshold = alpha * 0.5f;
    for (int64_t i = 0; i < n; i++) {
        float w = src_tern[i];
        uint8_t code = 0;
        if (w > threshold) code = 1;        /* +alpha → 01 */
        else if (w < -threshold) code = 3;  /* -alpha → 11 */
        /* zero → 00 (already zeroed) */
        dst[i / 4] |= code << ((i % 4) * 2);
    }
}

void requantize_all_layers(TransformerModel *model) {
    int d_model = model->config.d_model;
    int d_ff = model->config.d_ff;
    int64_t m2 = (int64_t)d_model * d_model;
    int64_t mf = (int64_t)d_model * d_ff;
    int64_t fm = (int64_t)d_ff * d_model;
    for (int l = 0; l < model->config.n_layers; l++) {
        TransformerLayer *layer = &model->layers[l];
        quantize_ternary(layer->w_q_tern, layer->w_q, m2, &layer->w_q_alpha);
        quantize_ternary(layer->w_k_tern, layer->w_k, m2, &layer->w_k_alpha);
        quantize_ternary(layer->w_v_tern, layer->w_v, m2, &layer->w_v_alpha);
        quantize_ternary(layer->w_o_tern, layer->w_o, m2, &layer->w_o_alpha);
        quantize_ternary(layer->w_ff1_tern, layer->w_ff1, mf, &layer->w_ff1_alpha);
        quantize_ternary(layer->w_ff2_tern, layer->w_ff2, fm, &layer->w_ff2_alpha);
        /* Pack for forward-pass kernels */
        if (layer->w_q_packed) pack_ternary(layer->w_q_packed, layer->w_q_tern, layer->w_q_alpha, m2);
        if (layer->w_k_packed) pack_ternary(layer->w_k_packed, layer->w_k_tern, layer->w_k_alpha, m2);
        if (layer->w_v_packed) pack_ternary(layer->w_v_packed, layer->w_v_tern, layer->w_v_alpha, m2);
        if (layer->w_o_packed) pack_ternary(layer->w_o_packed, layer->w_o_tern, layer->w_o_alpha, m2);
        if (layer->w_ff1_packed) pack_ternary(layer->w_ff1_packed, layer->w_ff1_tern, layer->w_ff1_alpha, mf);
        if (layer->w_ff2_packed) pack_ternary(layer->w_ff2_packed, layer->w_ff2_tern, layer->w_ff2_alpha, fm);
    }
}

static void ne_matmul_at_buf(
    float* a, int64_t m, int64_t k,
    float* b, int64_t n,
    float* out
) {
    memset(out, 0, k * n * sizeof(float));
    for (int64_t i0 = 0; i0 < k; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < m; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < k ? i0 + NE_TILE_SIZE : k;
                int64_t j_end = j0 + NE_TILE_SIZE < n ? j0 + NE_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TILE_SIZE < m ? k0 + NE_TILE_SIZE : m;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        float a_ki = a[kk * k + i];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * n + j] += a_ki * b[kk * n + j];
                        }
                    }
                }
            }
        }
    }
}

static void ne_matmul_bt_buf(
    float* a, int64_t m, int64_t k,
    float* b, int64_t n,
    float* out
) {
    memset(out, 0, m * k * sizeof(float));
    for (int64_t i0 = 0; i0 < m; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < k; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < n; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < m ? i0 + NE_TILE_SIZE : m;
                int64_t j_end = j0 + NE_TILE_SIZE < k ? j0 + NE_TILE_SIZE : k;
                int64_t k_end = k0 + NE_TILE_SIZE < n ? k0 + NE_TILE_SIZE : n;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        float a_ik = a[i * n + kk];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * k + j] += a_ik * b[j * n + kk];
                        }
                    }
                }
            }
        }
    }
}

static void ne_fused_attention_backward_buf(
    float* d_attn_out, int64_t seq_len, int64_t d_model,
    float* x,
    float* wq, float* wk, float* wv, float* wo,
    float* attn_probs,
    float* d_wq, float* d_wk, float* d_wv, float* d_wo,
    float* d_x
) {
    int64_t sd = seq_len * d_model;
    int64_t dd = d_model * d_model;
    int64_t ss = seq_len * seq_len;
    (void)dd;

    float* Q = (float*)xcalloc(sd, sizeof(float));
    float* K = (float*)xcalloc(sd, sizeof(float));
    float* V = (float*)xcalloc(sd, sizeof(float));
    float* context = (float*)xcalloc(sd, sizeof(float));

    ne_matmul_buf_f(x, seq_len, d_model, wq, d_model, Q);
    ne_matmul_buf_f(x, seq_len, d_model, wk, d_model, K);
    ne_matmul_buf_f(x, seq_len, d_model, wv, d_model, V);
    ne_matmul_buf_f(attn_probs, seq_len, seq_len, V, d_model, context);

    float* d_context = (float*)xcalloc(sd, sizeof(float));
    ne_matmul_bt_buf(d_attn_out, seq_len, d_model, wo, d_model, d_context);

    ne_matmul_at_buf(context, seq_len, d_model, d_attn_out, d_model, d_wo);

    float* d_V = (float*)xcalloc(sd, sizeof(float));
    ne_matmul_at_buf(attn_probs, seq_len, seq_len, d_context, d_model, d_V);

    float* d_probs = (float*)xcalloc(ss, sizeof(float));
    float* Vt = (float*)xcalloc(sd, sizeof(float));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < d_model; j++) {
            Vt[j * seq_len + i] = V[i * d_model + j];
        }
    }
    ne_matmul_buf_f(d_context, seq_len, d_model, Vt, seq_len, d_probs);
    free(Vt);

    ne_matmul_at_buf(x, seq_len, d_model, d_V, d_model, d_wv);

    float* d_scores = (float*)xcalloc(ss, sizeof(float));
    for (int64_t i = 0; i < seq_len; i++) {
        float s = 0.0f;
        for (int64_t j = 0; j < seq_len; j++) {
            s += attn_probs[i * seq_len + j] * d_probs[i * seq_len + j];
        }
        for (int64_t j = 0; j < seq_len; j++) {
            d_scores[i * seq_len + j] = attn_probs[i * seq_len + j] * (d_probs[i * seq_len + j] - s);
        }
    }

    float scale = 1.0f / sqrtf((float)d_model);

    float* d_Q = (float*)xcalloc(sd, sizeof(float));
    ne_matmul_buf_f(d_scores, seq_len, seq_len, K, d_model, d_Q);
    for (int64_t i = 0; i < sd; i++) d_Q[i] *= scale;

    float* d_K = (float*)xcalloc(sd, sizeof(float));
    float* d_scores_t = (float*)xcalloc(ss, sizeof(float));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < seq_len; j++) {
            d_scores_t[j * seq_len + i] = d_scores[i * seq_len + j];
        }
    }
    ne_matmul_buf_f(d_scores_t, seq_len, seq_len, Q, d_model, d_K);
    for (int64_t i = 0; i < sd; i++) d_K[i] *= scale;
    free(d_scores_t);

    ne_matmul_at_buf(x, seq_len, d_model, d_Q, d_model, d_wq);
    ne_matmul_at_buf(x, seq_len, d_model, d_K, d_model, d_wk);

    memset(d_x, 0, sd * sizeof(float));
    float* temp = (float*)xcalloc(sd, sizeof(float));

    ne_matmul_bt_buf(d_Q, seq_len, d_model, wq, d_model, temp);
    for (int64_t i = 0; i < sd; i++) d_x[i] += temp[i];

    memset(temp, 0, sd * sizeof(float));
    ne_matmul_bt_buf(d_K, seq_len, d_model, wk, d_model, temp);
    for (int64_t i = 0; i < sd; i++) d_x[i] += temp[i];

    memset(temp, 0, sd * sizeof(float));
    ne_matmul_bt_buf(d_V, seq_len, d_model, wv, d_model, temp);
    for (int64_t i = 0; i < sd; i++) d_x[i] += temp[i];

    free(temp);
    free(Q); free(K); free(V); free(context);
    free(d_context); free(d_V); free(d_probs);
    free(d_scores); free(d_Q); free(d_K);
}

static void ne_fused_ffn_backward_buf(
    float* d_out, int64_t seq_len, int64_t d_model,
    float* x,
    float* w1, int64_t d_ff,
    float* w2,
    float* pre_act,
    float* d_w1, float* d_w2, float* d_x
) {
    int64_t sf = seq_len * d_ff;
    const float sqrt_2_over_pi = sqrtf(2.0f / M_PI);
    const float sqrt_2pi = sqrtf(2.0f * M_PI);

    float* gelu_out = (float*)xcalloc(sf, sizeof(float));
    memcpy(gelu_out, pre_act, sf * sizeof(float));
    ne_gelu_buf_f(gelu_out, sf);

    float* d_gelu = (float*)xcalloc(sf, sizeof(float));
    ne_matmul_bt_buf(d_out, seq_len, d_ff, w2, d_model, d_gelu);

    ne_matmul_at_buf(gelu_out, seq_len, d_ff, d_out, d_model, d_w2);

    float* d_hidden = (float*)xcalloc(sf, sizeof(float));
    for (int64_t i = 0; i < sf; i++) {
        float h = pre_act[i];
        float cdf = 0.5f * (1.0f + tanhf(sqrt_2_over_pi * (h + 0.044715f * h * h * h)));
        float pdf = expf(-0.5f * h * h) / sqrt_2pi;
        float gelu_grad = cdf + h * pdf;
        d_hidden[i] = d_gelu[i] * gelu_grad;
    }

    ne_matmul_at_buf(x, seq_len, d_model, d_hidden, d_ff, d_w1);
    ne_matmul_bt_buf(d_hidden, seq_len, d_model, w1, d_ff, d_x);

    free(gelu_out); free(d_gelu); free(d_hidden);
}

static void layer_norm_backward(float *d_out, float *x_norm, float *gamma, float std_val, int d_model,
                                 float *d_x, float *d_gamma, float *d_beta) {
    float *d_x_norm_vec = xcalloc(d_model, sizeof(float));
    for (int j = 0; j < d_model; j++) {
        d_gamma[j] += d_out[j] * x_norm[j];
        d_beta[j] += d_out[j];
        d_x_norm_vec[j] = d_out[j] * gamma[j];
    }
    float mean_d = 0.0f, mean_xd = 0.0f;
    for (int j = 0; j < d_model; j++) {
        mean_d += d_x_norm_vec[j];
        mean_xd += d_x_norm_vec[j] * x_norm[j];
    }
    mean_d /= d_model;
    mean_xd /= d_model;
    for (int j = 0; j < d_model; j++) {
        d_x[j] = (d_x_norm_vec[j] - mean_d - x_norm[j] * mean_xd) / std_val;
    }
    free(d_x_norm_vec);
}

static float cross_entropy_loss(float *logits, int target_id, int vocab_size, float *probs_out) {
    float max_l = logits[0];
    for (int i = 1; i < vocab_size; i++) if (logits[i] > max_l) max_l = logits[i];
    float sum = 0.0f;
    for (int i = 0; i < vocab_size; i++) { probs_out[i] = expf(logits[i] - max_l); sum += probs_out[i]; }
    /* Guard against NaN/underflow propagating through training. */
    if (!(sum > 0.0f)) {
        float u = 1.0f / (float)vocab_size;
        for (int i = 0; i < vocab_size; i++) probs_out[i] = u;
    } else {
        for (int i = 0; i < vocab_size; i++) probs_out[i] /= sum;
    }
    float tp = probs_out[target_id];
    if (tp < 1e-10f) tp = 1e-10f;
    return -logf(tp);
}

static void native_forward_with_cache(int *token_ids, int seq_len, TransformerModel *model, float *logits_out, TrainingCache *cache) {
    int d_model = model->config.d_model;
    int d_ff = model->config.d_ff;
    int n_layers = model->config.n_layers;

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

    cache->seq_len = seq_len;
    int use_tern = (model->weight_format == WEIGHT_FORMAT_TERNARY);

    for (int l = 0; l < n_layers; l++) {
        TransformerLayer *layer = &model->layers[l];
        int lsd = l * seq_len * d_model;
        int lss = l * seq_len * seq_len;
        int lsf = l * seq_len * d_ff;
        int ls = l * seq_len;
        float *wq = use_tern ? layer->w_q_tern : layer->w_q;
        float *wk = use_tern ? layer->w_k_tern : layer->w_k;
        float *wv = use_tern ? layer->w_v_tern : layer->w_v;
        float *wo = use_tern ? layer->w_o_tern : layer->w_o;
        float *wff1 = use_tern ? layer->w_ff1_tern : layer->w_ff1;
        float *wff2 = use_tern ? layer->w_ff2_tern : layer->w_ff2;

        memcpy(cache->layer_inputs + lsd, x, seq_len * d_model * sizeof(float));

        float *norm1 = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
        for (int i = 0; i < seq_len; i++) {
            float *xi = x + i * d_model;
            float *out = norm1 + i * d_model;
            float mean = 0.0f;
            for (int j = 0; j < d_model; j++) mean += xi[j];
            mean /= d_model;
            float var = 0.0f;
            for (int j = 0; j < d_model; j++) { float d = xi[j] - mean; var += d * d; }
            var /= d_model;
            float std_val = sqrtf(var + 1e-5f);
            for (int j = 0; j < d_model; j++) {
                float xn = (xi[j] - mean) / std_val;
                cache->ln1_x_norm[lsd + i * d_model + j] = xn;
                out[j] = layer->ln1_gamma[j] * xn + layer->ln1_beta[j];
            }
            cache->ln1_std[ls + i] = std_val;
        }
        memcpy(cache->norm1_outputs + lsd, norm1, seq_len * d_model * sizeof(float));

        float *attn_out = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
        if (use_tern) {
            ne_fused_attention_forward_buf_packed_f(norm1, seq_len, d_model,
                layer->w_q_packed, layer->w_q_alpha,
                layer->w_k_packed, layer->w_k_alpha,
                layer->w_v_packed, layer->w_v_alpha,
                layer->w_o_packed, layer->w_o_alpha,
                attn_out, cache->attn_probs + lss);
        } else {
            ne_fused_attention_forward_buf_f(norm1, seq_len, d_model,
                wq, wk, wv, wo,
                attn_out, cache->attn_probs + lss);
        }
        free(norm1);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += attn_out[i];
        free(attn_out);

        memcpy(cache->post_attn_x + lsd, x, seq_len * d_model * sizeof(float));

        float *norm2 = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
        for (int i = 0; i < seq_len; i++) {
            float *xi = x + i * d_model;
            float *out = norm2 + i * d_model;
            float mean = 0.0f;
            for (int j = 0; j < d_model; j++) mean += xi[j];
            mean /= d_model;
            float var = 0.0f;
            for (int j = 0; j < d_model; j++) { float d = xi[j] - mean; var += d * d; }
            var /= d_model;
            float std_val = sqrtf(var + 1e-5f);
            for (int j = 0; j < d_model; j++) {
                float xn = (xi[j] - mean) / std_val;
                cache->ln2_x_norm[lsd + i * d_model + j] = xn;
                out[j] = layer->ln2_gamma[j] * xn + layer->ln2_beta[j];
            }
            cache->ln2_std[ls + i] = std_val;
        }
        memcpy(cache->norm2_outputs + lsd, norm2, seq_len * d_model * sizeof(float));

        float *ffn_out = xcalloc_array(safe_size_mul(seq_len, d_model), sizeof(float));
        if (use_tern) {
            ne_fused_ffn_forward_buf_packed_f(norm2, seq_len, d_model,
                layer->w_ff1_packed, layer->w_ff1_alpha, d_ff,
                layer->w_ff2_packed, layer->w_ff2_alpha,
                1, ffn_out, cache->ffn_pre_act + lsf);
        } else {
            ne_fused_ffn_forward_buf_f(norm2, seq_len, d_model,
                wff1, d_ff, wff2,
                1, ffn_out, cache->ffn_pre_act + lsf);
        }
        free(norm2);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += ffn_out[i];
        free(ffn_out);
    }

    memcpy(cache->final_x, x, seq_len * d_model * sizeof(float));

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

/* ---- Observer-driven learning rate scaling ----
 * Reads the observer buffer to classify each weight matrix and returns
 * a per-matrix scale factor for the gradient update.
 *
 * Same logic as the trigram path's block scheduling:
 *   converged  → scale 0.0 (skip update entirely)
 *   stable     → scale 0.5 (maintenance updates)
 *   improving  → scale 1.0 (keep going)
 *   oscillating → scale 0.3 (dampen to stop sign-flipping)
 *   diverging  → scale 0.1 (nearly halt, something is wrong)
 *   cold/new   → scale 1.0 (no history, full rate)
 *
 * Classification uses per-matrix aggregates of the 5 observer fields:
 *   mean |dH|, mean entropy, mean obs_age, oscillation fraction
 */

/* Thresholds — read from the script-mutable globals (defined in eigenscript.c,
 * settable via set_observer_thresholds). Same defaults as builtins.c uses for
 * the observer_state predicate, so script-side classification and internal
 * training-time scaling stay aligned. */
extern __thread double g_obs_dh_zero;
extern __thread double g_obs_dh_small;
extern __thread double g_obs_h_low;
#define OBS_DH_ZERO  g_obs_dh_zero
#define OBS_DH_SMALL g_obs_dh_small
#define OBS_H_LOW    g_obs_h_low

static float observer_matrix_scale(double *obs, int start, int count) {
    if (!obs || count <= 0) return 1.0f;  /* no observer data → full rate */

    double sum_abs_dH = 0.0, sum_entropy = 0.0, sum_age = 0.0;
    int osc_count = 0;

    for (int i = 0; i < count; i++) {
        double *o = obs + (start + i) * 5;
        double entropy = o[0];
        double dH = o[1];
        double prev_dH = o[4];
        double age = o[3];

        sum_entropy += entropy;
        sum_abs_dH += fabs(dH);
        sum_age += age;

        /* Oscillation: sign flip with significant magnitude */
        if (prev_dH * dH < 0.0 && fabs(dH) > OBS_DH_ZERO) osc_count++;
    }

    double mean_abs_dH = sum_abs_dH / count;
    double mean_entropy = sum_entropy / count;
    double mean_age = sum_age / count;
    double osc_frac = (double)osc_count / count;

    /* Cold start — not enough history */
    if (mean_age < 2.0) return 1.0f;

    /* "Converged" used to return 0.0f here, freezing the matrix. That created
     * a self-reinforcing trap: a matrix with tiny weight deltas produced tiny
     * entropy → flagged converged → scale=0 → weights stopped → entropy stayed
     * at 0 → permanently frozen. Empirically (EIGS_TRAIN_DUMP) it tripped on
     * every matrix within ~50 steps from random init. A truly converged
     * matrix's gradient is already small; multiplying by zero is harmful and
     * the right pass-through is full rate. */

    /* Oscillating: more than 30% of elements flipping sign */
    if (osc_frac > 0.3)
        return 0.3f;

    /* Diverging: entropy increasing significantly */
    if (mean_abs_dH > OBS_DH_SMALL && mean_entropy > OBS_H_LOW) {
        /* Check if dH is positive on average (increasing entropy) */
        double sum_dH = 0.0;
        for (int i = 0; i < count; i++) sum_dH += obs[(start + i) * 5 + 1];
        if (sum_dH / count > OBS_DH_SMALL)
            return 0.1f;
    }

    /* Stable: small changes, moderate entropy */
    if (mean_abs_dH < OBS_DH_SMALL)
        return 0.5f;

    /* Improving: still changing, not oscillating — full rate */
    return 1.0f;
}

/* Compute per-matrix observer scales for the whole model.
 * Returns array of scale factors: [token_emb, output_proj, L0_wq, L0_wk, ..., LN_ln2b]
 * Caller frees. Returns NULL if no observer data. */
static float* compute_observer_scales(TransformerModel *model) {
    if (!model->observer.data || model->observer.total_elements <= 0)
        return NULL;

    int vs = model->config.vocab_size;
    int dm = model->config.d_model;
    int df = model->config.d_ff;
    int nl = model->config.n_layers;
    double *obs = model->observer.data;

    /* 2 global matrices + 10 per layer (w_q,w_k,w_v,w_o,w_ff1,w_ff2,ln1g,ln1b,ln2g,ln2b) */
    int n_matrices = 2 + nl * 10;
    float *scales = xcalloc(n_matrices, sizeof(float));
    int idx = 0;
    int obs_offset = 0;

    /* Token embeddings */
    scales[idx++] = observer_matrix_scale(obs, obs_offset, vs * dm);
    obs_offset += vs * dm;

    /* Output projection */
    scales[idx++] = observer_matrix_scale(obs, obs_offset, dm * vs);
    obs_offset += dm * vs;

    /* Per-layer */
    for (int l = 0; l < nl; l++) {
        int sizes[10] = { dm*dm, dm*dm, dm*dm, dm*dm, dm*df, df*dm, dm, dm, dm, dm };
        for (int m = 0; m < 10; m++) {
            scales[idx++] = observer_matrix_scale(obs, obs_offset, sizes[m]);
            obs_offset += sizes[m];
        }
    }

    return scales;
}

/* ---- Observer tracking for .eigen checkpoint persistence ----
 * After each training step, update the observer buffer with per-element
 * entropy deltas computed from the weight changes. This makes the observer
 * state available for .eigen save. */
static void update_model_observer(TransformerModel *model, float *old_token_emb, float *old_output_proj,
                                   float **old_wq, float **old_wk, float **old_wv, float **old_wo,
                                   float **old_ff1, float **old_ff2) {
    int total = model_total_weight_count(model);
    if (!model->observer.data || model->observer.total_elements != total) {
        observer_buffer_free(&model->observer);
        observer_buffer_init(&model->observer, total);
    }

    double *obs = model->observer.data;
    int idx = 0;
    int vs = model->config.vocab_size;
    int dm = model->config.d_model;
    int df = model->config.d_ff;
    int nl = model->config.n_layers;

    /* Token embeddings */
    for (int i = 0; i < vs * dm; i++, idx++) {
        double *o = obs + idx * 5;
        double delta = fabs((double)(model->token_embeddings[i] - old_token_emb[i]));
        double new_ent = (delta > 1e-15) ? -delta * log(delta) : 0.0;
        o[4] = o[1];                 /* prev_dH */
        o[1] = new_ent - o[2];      /* dH = new_entropy - last_entropy */
        o[2] = o[0];                 /* last_entropy = old entropy */
        o[0] = new_ent;              /* entropy */
        o[3] += 1.0;                 /* obs_age++ */
    }

    /* Output projection */
    for (int i = 0; i < dm * vs; i++, idx++) {
        double *o = obs + idx * 5;
        double delta = fabs((double)(model->output_proj[i] - old_output_proj[i]));
        double new_ent = (delta > 1e-15) ? -delta * log(delta) : 0.0;
        o[4] = o[1]; o[1] = new_ent - o[2]; o[2] = o[0]; o[0] = new_ent; o[3] += 1.0;
    }

    /* Per-layer weights */
    for (int l = 0; l < nl; l++) {
        TransformerLayer *layer = &model->layers[l];
        float *olds[6] = { old_wq[l], old_wk[l], old_wv[l], old_wo[l], old_ff1[l], old_ff2[l] };
        float *news[6] = { layer->w_q, layer->w_k, layer->w_v, layer->w_o, layer->w_ff1, layer->w_ff2 };
        int sizes[6] = { dm*dm, dm*dm, dm*dm, dm*dm, dm*df, df*dm };
        for (int m = 0; m < 6; m++) {
            for (int i = 0; i < sizes[m]; i++, idx++) {
                double *o = obs + idx * 5;
                double delta = fabs((double)(news[m][i] - olds[m][i]));
                double new_ent = (delta > 1e-15) ? -delta * log(delta) : 0.0;
                o[4] = o[1]; o[1] = new_ent - o[2]; o[2] = o[0]; o[0] = new_ent; o[3] += 1.0;
            }
        }
        /* LayerNorm — just increment obs_age so they stay in sync */
        for (int i = 0; i < 4 * dm; i++, idx++) {
            double *o = obs + idx * 5;
            o[3] += 1.0;
        }
    }
}

/* ================================================================
 * Per-step training diagnostic CSV (EIGS_TRAIN_DUMP=path).
 *
 * Records per-matrix gradient L2, observer scale, and applied weight
 * delta L2 once per native_train_step call. The delta is computable
 * directly from grad_L2 because the SGD step is w -= scale*s*g, so
 * ||delta||_2 = scale*s*||g||_2 — no weight snapshots required.
 * ================================================================ */
static FILE *g_train_dump_fp = NULL;
static int   g_train_dump_init = 0;
static int   g_train_dump_inhibit = 0;

/* Per-class loss dump (EIGS_CLASS_LOSS_DUMP=path) — bucketed CE loss per step
 * by target-token class. Used to diagnose whether rare-class tokens (DEDENT)
 * are being unlearned by mass-weighted cross-entropy. Class IDs are hardcoded
 * to match data/identifier_vocab.json under top_n=256:
 *   NEWLINE=79, INDENT=80, DEDENT=81, IDENT_FB=2, FIRST_IDENT_ID=83.
 * If the vocab build changes these IDs, update CLS_* below. */
#define CLS_ID_NEWLINE       79
#define CLS_ID_INDENT        80
#define CLS_ID_DEDENT        81
#define CLS_ID_IDENT_FB       2
#define CLS_FIRST_IDENT_ID   83
#define CLS_N                 6  /* NL, IND, DED, FB, ext_ident, other */
static FILE *g_class_loss_fp = NULL;
static int   g_class_loss_init = 0;
static int   g_class_loss_inhibit = 0;

/* Per-step depth-bucketed loss for DEDENT targets. Tests the hypothesis that
 * the model fails on DEDENT because it can't track indent depth across the
 * 31-token context window. If shallow-depth DEDENTs (d=1) have low loss but
 * deep-depth (d>=4) have high loss, depth-tracking is the bottleneck.
 * EIGS_DEPTH_LOSS_DUMP=path. */
#define DEPTH_BUCKETS 5  /* 0, 1, 2, 3, 4+ */
static FILE *g_depth_loss_fp = NULL;
static int   g_depth_loss_init = 0;
static int   g_depth_loss_inhibit = 0;

static int classify_target(int tid) {
    if (tid == CLS_ID_NEWLINE)  return 0;
    if (tid == CLS_ID_INDENT)   return 1;
    if (tid == CLS_ID_DEDENT)   return 2;
    if (tid == CLS_ID_IDENT_FB) return 3;
    if (tid >= CLS_FIRST_IDENT_ID) return 4;
    return 5;
}

static void class_loss_open_if_needed(void) {
    if (g_class_loss_init || g_class_loss_inhibit) return;
    const char *path = getenv("EIGS_CLASS_LOSS_DUMP");
    if (!path || !*path) { g_class_loss_inhibit = 1; return; }
    g_class_loss_fp = fopen(path, "w");
    if (!g_class_loss_fp) {
        fprintf(stderr, "[class-loss-dump] failed to open %s\n", path);
        g_class_loss_inhibit = 1;
        return;
    }
    g_class_loss_init = 1;
    fprintf(g_class_loss_fp,
        "step,nl_n,nl_loss,ind_n,ind_loss,ded_n,ded_loss,fb_n,fb_loss,ext_n,ext_loss,oth_n,oth_loss\n");
    fflush(g_class_loss_fp);
}

static void depth_loss_open_if_needed(void) {
    if (g_depth_loss_init || g_depth_loss_inhibit) return;
    const char *path = getenv("EIGS_DEPTH_LOSS_DUMP");
    if (!path || !*path) { g_depth_loss_inhibit = 1; return; }
    g_depth_loss_fp = fopen(path, "w");
    if (!g_depth_loss_fp) {
        fprintf(stderr, "[depth-loss-dump] failed to open %s\n", path);
        g_depth_loss_inhibit = 1;
        return;
    }
    g_depth_loss_init = 1;
    fprintf(g_depth_loss_fp,
        "step,d0_n,d0_loss,d1_n,d1_loss,d2_n,d2_loss,d3_n,d3_loss,d4plus_n,d4plus_loss\n");
    fflush(g_depth_loss_fp);
}

/* Per-class loss/gradient weight for DEDENT targets. EIGS_DEDENT_LOSS_WEIGHT.
 * Default 1.0. Scales both the reported loss and dL/dlogits identically — the
 * gradient stays consistent with the (weighted) objective. Tests whether the
 * frequency-suppression we measured (DEDENT loss 6.73 > uniform 5.83) is fixable
 * by counteracting DEDENT's mass-weight handicap. */
static float dedent_loss_weight(void) {
    static int   inited = 0;
    static float w = 1.0f;
    if (!inited) {
        const char *s = getenv("EIGS_DEDENT_LOSS_WEIGHT");
        if (s && *s) {
            float v = (float)atof(s);
            if (v > 0.0f) w = v;
        }
        inited = 1;
    }
    return w;
}

static float l2_norm_f(const float *a, int64_t n) {
    double s = 0.0;
    for (int64_t i = 0; i < n; i++) s += (double)a[i] * (double)a[i];
    return (float)sqrt(s);
}

static void train_dump_open_if_needed(TransformerModel *model) {
    if (g_train_dump_init || g_train_dump_inhibit) return;
    const char *path = getenv("EIGS_TRAIN_DUMP");
    if (!path || !*path) { g_train_dump_inhibit = 1; return; }
    g_train_dump_fp = fopen(path, "w");
    if (!g_train_dump_fp) {
        fprintf(stderr, "[train-dump] failed to open %s\n", path);
        g_train_dump_inhibit = 1;
        return;
    }
    g_train_dump_init = 1;
    int nl = model->config.n_layers;
    const char *layer_keys[] = {"wq","wk","wv","wo","ff1","ff2","ln1g","ln1b","ln2g","ln2b"};
    fprintf(g_train_dump_fp, "step,loss,effective_lr,final_entropy_nats");
    fprintf(g_train_dump_fp, ",g_tok_emb,g_out_proj");
    for (int l = 0; l < nl; l++)
        for (int k = 0; k < 10; k++) fprintf(g_train_dump_fp, ",g_%s_L%d", layer_keys[k], l);
    fprintf(g_train_dump_fp, ",s_tok_emb,s_out_proj");
    for (int l = 0; l < nl; l++)
        for (int k = 0; k < 10; k++) fprintf(g_train_dump_fp, ",s_%s_L%d", layer_keys[k], l);
    fprintf(g_train_dump_fp, ",d_tok_emb,d_out_proj");
    for (int l = 0; l < nl; l++)
        for (int k = 0; k < 10; k++) fprintf(g_train_dump_fp, ",d_%s_L%d", layer_keys[k], l);
    fprintf(g_train_dump_fp, "\n");
    fflush(g_train_dump_fp);
}

static int native_train_step(int *input_ids, int input_len, int *output_ids, int output_len, float learning_rate, float *loss_out, int *tokens_trained_out) {
    if (!g_model.loaded) return -1;

    int vocab_size = g_model.config.vocab_size;
    int d_model = g_model.config.d_model;
    int d_ff = g_model.config.d_ff;
    int n_layers = g_model.config.n_layers;
    int max_seq_len = g_model.config.max_seq_len;

    float effective_lr = learning_rate / logf((float)g_model_age + M_E);

    int full_len = input_len + output_len;
    if (full_len < 2) return -1;

    int *token_ids = xcalloc(full_len, sizeof(int));
    for (int i = 0; i < input_len; i++) {
        int tid = input_ids[i];
        if (tid < 0) tid = 0;
        if (tid >= vocab_size) tid = vocab_size - 1;
        token_ids[i] = tid;
    }
    for (int i = 0; i < output_len; i++) {
        int tid = output_ids[i];
        if (tid < 0) tid = 0;
        if (tid >= vocab_size) tid = vocab_size - 1;
        token_ids[input_len + i] = tid;
    }

    float *grad_token_emb = xcalloc_array(safe_size_mul(vocab_size, d_model), sizeof(float));
    float *grad_output_proj = xcalloc_array(safe_size_mul(d_model, vocab_size), sizeof(float));

    float **lg_wq = xcalloc(n_layers, sizeof(float*));
    float **lg_wk = xcalloc(n_layers, sizeof(float*));
    float **lg_wv = xcalloc(n_layers, sizeof(float*));
    float **lg_wo = xcalloc(n_layers, sizeof(float*));
    float **lg_ff1 = xcalloc(n_layers, sizeof(float*));
    float **lg_ff2 = xcalloc(n_layers, sizeof(float*));
    float **lg_ln1g = xcalloc(n_layers, sizeof(float*));
    float **lg_ln1b = xcalloc(n_layers, sizeof(float*));
    float **lg_ln2g = xcalloc(n_layers, sizeof(float*));
    float **lg_ln2b = xcalloc(n_layers, sizeof(float*));
    for (int l = 0; l < n_layers; l++) {
        lg_wq[l] = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
        lg_wk[l] = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
        lg_wv[l] = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
        lg_wo[l] = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
        lg_ff1[l] = xcalloc_array(safe_size_mul(d_model, d_ff), sizeof(float));
        lg_ff2[l] = xcalloc_array(safe_size_mul(d_ff, d_model), sizeof(float));
        lg_ln1g[l] = xcalloc(d_model, sizeof(float));
        lg_ln1b[l] = xcalloc(d_model, sizeof(float));
        lg_ln2g[l] = xcalloc(d_model, sizeof(float));
        lg_ln2b[l] = xcalloc(d_model, sizeof(float));
    }

    float total_loss = 0.0f;
    int num_tokens = 0;
    float final_step_entropy = 0.0f;
    /* Per-class loss accumulators (reset per train step). See classify_target. */
    double cls_loss_sum[CLS_N] = {0};
    int    cls_count[CLS_N]    = {0};
    /* DEDENT loss bucketed by indent depth observed in the window so far.
     * Tests the depth-tracking-bottleneck hypothesis. */
    double ded_depth_loss[DEPTH_BUCKETS] = {0};
    int    ded_depth_count[DEPTH_BUCKETS] = {0};
    int    depth_at_predict = 0;

    int use_tern = (g_model.weight_format == WEIGHT_FORMAT_TERNARY);

    int max_ctx = max_seq_len < full_len ? max_seq_len : full_len;
    TrainingCache cache;
    cache.layer_inputs = xcalloc_array(safe_size_mul(safe_size_mul(n_layers, max_ctx), d_model), sizeof(float));
    cache.norm1_outputs = xcalloc_array(safe_size_mul(safe_size_mul(n_layers, max_ctx), d_model), sizeof(float));
    cache.norm2_outputs = xcalloc_array(safe_size_mul(safe_size_mul(n_layers, max_ctx), d_model), sizeof(float));
    cache.attn_probs = xcalloc_array(safe_size_mul(safe_size_mul(n_layers, max_ctx), max_ctx), sizeof(float));
    cache.ffn_pre_act = xcalloc_array(safe_size_mul(safe_size_mul(n_layers, max_ctx), d_ff), sizeof(float));
    cache.post_attn_x = xcalloc_array(safe_size_mul(safe_size_mul(n_layers, max_ctx), d_model), sizeof(float));
    cache.final_x = xcalloc_array(safe_size_mul(max_ctx, d_model), sizeof(float));
    cache.ln1_x_norm = xcalloc_array(safe_size_mul(safe_size_mul(n_layers, max_ctx), d_model), sizeof(float));
    cache.ln1_std = xcalloc_array(safe_size_mul(n_layers, max_ctx), sizeof(float));
    cache.ln2_x_norm = xcalloc_array(safe_size_mul(safe_size_mul(n_layers, max_ctx), d_model), sizeof(float));
    cache.ln2_std = xcalloc_array(safe_size_mul(n_layers, max_ctx), sizeof(float));

    for (int t = 0; t < full_len - 1; t++) {
        int ctx_len = t + 1;
        if (ctx_len > max_seq_len) ctx_len = max_seq_len;
        int ctx_start = (t + 1) - ctx_len;
        int target_id = token_ids[t + 1];

        memset(cache.layer_inputs, 0, n_layers * ctx_len * d_model * sizeof(float));
        memset(cache.norm1_outputs, 0, n_layers * ctx_len * d_model * sizeof(float));
        memset(cache.norm2_outputs, 0, n_layers * ctx_len * d_model * sizeof(float));
        memset(cache.attn_probs, 0, n_layers * ctx_len * ctx_len * sizeof(float));
        memset(cache.ffn_pre_act, 0, n_layers * ctx_len * d_ff * sizeof(float));
        memset(cache.post_attn_x, 0, n_layers * ctx_len * d_model * sizeof(float));
        memset(cache.ln1_x_norm, 0, n_layers * ctx_len * d_model * sizeof(float));
        memset(cache.ln1_std, 0, n_layers * ctx_len * sizeof(float));
        memset(cache.ln2_x_norm, 0, n_layers * ctx_len * d_model * sizeof(float));
        memset(cache.ln2_std, 0, n_layers * ctx_len * sizeof(float));

        float *logits = xcalloc(vocab_size, sizeof(float));
        native_forward_with_cache(token_ids + ctx_start, ctx_len, &g_model, logits, &cache);

        float *probs = xcalloc(vocab_size, sizeof(float));
        float loss = cross_entropy_loss(logits, target_id, vocab_size, probs);
        float loss_w = (target_id == CLS_ID_DEDENT) ? dedent_loss_weight() : 1.0f;
        loss *= loss_w;
        total_loss += loss;
        num_tokens++;
        {
            int cls = classify_target(target_id);
            cls_loss_sum[cls] += (double)loss;
            cls_count[cls]    += 1;
            /* Update depth based on the token we just incorporated into context.
             * The model's context for predicting token_ids[t+1] is token_ids[0..t],
             * so we account for token_ids[t] BEFORE bucketing the target's loss.
             * (For t=0, depth_at_predict=0 still — first input wasn't IND/DED yet
             * unless it happens to be one, handled below.) */
            if (t >= 0 && token_ids[t] == CLS_ID_INDENT) depth_at_predict++;
            else if (t >= 0 && token_ids[t] == CLS_ID_DEDENT) depth_at_predict--;
            if (target_id == CLS_ID_DEDENT) {
                int d = depth_at_predict;
                if (d < 0) d = 0;
                if (d >= DEPTH_BUCKETS) d = DEPTH_BUCKETS - 1;
                ded_depth_loss[d]  += (double)loss;
                ded_depth_count[d] += 1;
            }
        }
        free(logits);

        /* Capture last-step entropy for the diagnostic dump — head-collapse signal */
        if (t == full_len - 2) {
            double ent = 0.0;
            for (int j = 0; j < vocab_size; j++) {
                float p = probs[j];
                if (p > 1e-12f) ent -= (double)p * log((double)p);
            }
            final_step_entropy = (float)ent;
        }

        float *d_logits = xcalloc(vocab_size, sizeof(float));
        memcpy(d_logits, probs, vocab_size * sizeof(float));
        d_logits[target_id] -= 1.0f;
        if (loss_w != 1.0f) {
            for (int j = 0; j < vocab_size; j++) d_logits[j] *= loss_w;
        }
        free(probs);

        float *last_hidden = cache.final_x + (ctx_len - 1) * d_model;
        for (int k = 0; k < d_model; k++) {
            for (int j = 0; j < vocab_size; j++) {
                grad_output_proj[k * vocab_size + j] += last_hidden[k] * d_logits[j];
            }
        }

        float *d_x = xcalloc_array(safe_size_mul(ctx_len, d_model), sizeof(float));
        for (int k = 0; k < d_model; k++) {
            float sum = 0.0f;
            for (int j = 0; j < vocab_size; j++) {
                sum += g_model.output_proj[k * vocab_size + j] * d_logits[j];
            }
            d_x[(ctx_len - 1) * d_model + k] = sum;
        }
        free(d_logits);

        for (int l = n_layers - 1; l >= 0; l--) {
            TransformerLayer *layer = &g_model.layers[l];
            int lsd = l * ctx_len * d_model;
            int lss = l * ctx_len * ctx_len;
            int lsf = l * ctx_len * d_ff;
            int ls = l * ctx_len;

            float *d_ffn_w1 = xcalloc_array(safe_size_mul(d_model, d_ff), sizeof(float));
            float *d_ffn_w2 = xcalloc_array(safe_size_mul(d_ff, d_model), sizeof(float));
            float *d_norm2_out = xcalloc_array(safe_size_mul(ctx_len, d_model), sizeof(float));
            float *bw_wff1 = use_tern ? layer->w_ff1_tern : layer->w_ff1;
            float *bw_wff2 = use_tern ? layer->w_ff2_tern : layer->w_ff2;
            ne_fused_ffn_backward_buf(d_x, ctx_len, d_model,
                cache.norm2_outputs + lsd, bw_wff1, d_ff, bw_wff2,
                cache.ffn_pre_act + lsf, d_ffn_w1, d_ffn_w2, d_norm2_out);
            for (int i = 0; i < d_model * d_ff; i++) lg_ff1[l][i] += d_ffn_w1[i];
            for (int i = 0; i < d_ff * d_model; i++) lg_ff2[l][i] += d_ffn_w2[i];
            free(d_ffn_w1); free(d_ffn_w2);

            float *d_post_attn = xcalloc_array(safe_size_mul(ctx_len, d_model), sizeof(float));
            for (int i = 0; i < ctx_len; i++) {
                float d_ln_x[MAX_D_MODEL] = {0};
                layer_norm_backward(d_norm2_out + i * d_model,
                    cache.ln2_x_norm + lsd + i * d_model,
                    layer->ln2_gamma, cache.ln2_std[ls + i], d_model,
                    d_ln_x, lg_ln2g[l], lg_ln2b[l]);
                for (int j = 0; j < d_model; j++)
                    d_post_attn[i * d_model + j] = d_x[i * d_model + j] + d_ln_x[j];
            }
            free(d_norm2_out);

            float *d_attn_wq = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
            float *d_attn_wk = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
            float *d_attn_wv = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
            float *d_attn_wo = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
            float *d_norm1_out = xcalloc_array(safe_size_mul(ctx_len, d_model), sizeof(float));
            float *bw_wq = use_tern ? layer->w_q_tern : layer->w_q;
            float *bw_wk = use_tern ? layer->w_k_tern : layer->w_k;
            float *bw_wv = use_tern ? layer->w_v_tern : layer->w_v;
            float *bw_wo = use_tern ? layer->w_o_tern : layer->w_o;
            ne_fused_attention_backward_buf(d_post_attn, ctx_len, d_model,
                cache.norm1_outputs + lsd,
                bw_wq, bw_wk, bw_wv, bw_wo,
                cache.attn_probs + lss,
                d_attn_wq, d_attn_wk, d_attn_wv, d_attn_wo, d_norm1_out);
            for (int i = 0; i < d_model * d_model; i++) {
                lg_wq[l][i] += d_attn_wq[i];
                lg_wk[l][i] += d_attn_wk[i];
                lg_wv[l][i] += d_attn_wv[i];
                lg_wo[l][i] += d_attn_wo[i];
            }
            free(d_attn_wq); free(d_attn_wk); free(d_attn_wv); free(d_attn_wo);

            float *d_pre_attn = xcalloc_array(safe_size_mul(ctx_len, d_model), sizeof(float));
            for (int i = 0; i < ctx_len; i++) {
                float d_ln_x[MAX_D_MODEL] = {0};
                layer_norm_backward(d_norm1_out + i * d_model,
                    cache.ln1_x_norm + lsd + i * d_model,
                    layer->ln1_gamma, cache.ln1_std[ls + i], d_model,
                    d_ln_x, lg_ln1g[l], lg_ln1b[l]);
                for (int j = 0; j < d_model; j++)
                    d_pre_attn[i * d_model + j] = d_post_attn[i * d_model + j] + d_ln_x[j];
            }
            free(d_post_attn); free(d_norm1_out);

            memcpy(d_x, d_pre_attn, ctx_len * d_model * sizeof(float));
            free(d_pre_attn);
        }

        for (int i = 0; i < ctx_len; i++) {
            int tok = token_ids[ctx_start + i];
            if (tok >= 0 && tok < vocab_size) {
                for (int j = 0; j < d_model; j++)
                    grad_token_emb[tok * d_model + j] += d_x[i * d_model + j];
            }
        }
        free(d_x);
    }

    float avg_loss = num_tokens > 0 ? total_loss / num_tokens : 0.0f;

    if (isnan(avg_loss) || isinf(avg_loss)) {
        fprintf(stderr, "[train-guard] NaN/Inf loss detected (%.4f) - SKIPPING weight update to prevent corruption\n", avg_loss);
        *loss_out = 0.0f;
        *tokens_trained_out = 0;
        free(token_ids); free(grad_token_emb); free(grad_output_proj);
        for (int l = 0; l < n_layers; l++) {
            free(lg_wq[l]); free(lg_wk[l]); free(lg_wv[l]); free(lg_wo[l]);
            free(lg_ff1[l]); free(lg_ff2[l]);
            free(lg_ln1g[l]); free(lg_ln1b[l]); free(lg_ln2g[l]); free(lg_ln2b[l]);
        }
        free(lg_wq); free(lg_wk); free(lg_wv); free(lg_wo);
        free(lg_ff1); free(lg_ff2);
        free(lg_ln1g); free(lg_ln1b); free(lg_ln2g); free(lg_ln2b);
        free(cache.layer_inputs); free(cache.norm1_outputs); free(cache.norm2_outputs);
        free(cache.attn_probs); free(cache.ffn_pre_act); free(cache.post_attn_x);
        free(cache.final_x);
        free(cache.ln1_x_norm); free(cache.ln1_std);
        free(cache.ln2_x_norm); free(cache.ln2_std);
        return -1;
    }

    int has_nan_grad = 0;
    for (int i = 0; i < d_model * vocab_size && !has_nan_grad; i++)
        if (isnan(grad_output_proj[i]) || isinf(grad_output_proj[i])) has_nan_grad = 1;
    for (int i = 0; i < vocab_size * d_model && !has_nan_grad; i++)
        if (isnan(grad_token_emb[i]) || isinf(grad_token_emb[i])) has_nan_grad = 1;

    if (has_nan_grad) {
        fprintf(stderr, "[train-guard] NaN/Inf gradient detected - SKIPPING weight update\n");
        *loss_out = 0.0f;
        *tokens_trained_out = 0;
        free(token_ids); free(grad_token_emb); free(grad_output_proj);
        for (int l = 0; l < n_layers; l++) {
            free(lg_wq[l]); free(lg_wk[l]); free(lg_wv[l]); free(lg_wo[l]);
            free(lg_ff1[l]); free(lg_ff2[l]);
            free(lg_ln1g[l]); free(lg_ln1b[l]); free(lg_ln2g[l]); free(lg_ln2b[l]);
        }
        free(lg_wq); free(lg_wk); free(lg_wv); free(lg_wo);
        free(lg_ff1); free(lg_ff2);
        free(lg_ln1g); free(lg_ln1b); free(lg_ln2g); free(lg_ln2b);
        free(cache.layer_inputs); free(cache.norm1_outputs); free(cache.norm2_outputs);
        free(cache.attn_probs); free(cache.ffn_pre_act); free(cache.post_attn_x);
        free(cache.final_x);
        free(cache.ln1_x_norm); free(cache.ln1_std);
        free(cache.ln2_x_norm); free(cache.ln2_std);
        return -1;
    }

    /* Snapshot weights before update for observer tracking */
    float *old_token_emb = xmalloc_array(safe_size_mul(vocab_size, d_model), sizeof(float));
    float *old_output_proj = xmalloc_array(safe_size_mul(d_model, vocab_size), sizeof(float));
    memcpy(old_token_emb, g_model.token_embeddings, vocab_size * d_model * sizeof(float));
    memcpy(old_output_proj, g_model.output_proj, d_model * vocab_size * sizeof(float));

    float **old_wq = xcalloc(n_layers, sizeof(float*));
    float **old_wk = xcalloc(n_layers, sizeof(float*));
    float **old_wv = xcalloc(n_layers, sizeof(float*));
    float **old_wo = xcalloc(n_layers, sizeof(float*));
    float **old_ff1 = xcalloc(n_layers, sizeof(float*));
    float **old_ff2 = xcalloc(n_layers, sizeof(float*));
    for (int l = 0; l < n_layers; l++) {
        TransformerLayer *layer = &g_model.layers[l];
        old_wq[l] = xmalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
        old_wk[l] = xmalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
        old_wv[l] = xmalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
        old_wo[l] = xmalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
        old_ff1[l] = xmalloc_array(safe_size_mul(d_model, d_ff), sizeof(float));
        old_ff2[l] = xmalloc_array(safe_size_mul(d_ff, d_model), sizeof(float));
        memcpy(old_wq[l], layer->w_q, d_model * d_model * sizeof(float));
        memcpy(old_wk[l], layer->w_k, d_model * d_model * sizeof(float));
        memcpy(old_wv[l], layer->w_v, d_model * d_model * sizeof(float));
        memcpy(old_wo[l], layer->w_o, d_model * d_model * sizeof(float));
        memcpy(old_ff1[l], layer->w_ff1, d_model * d_ff * sizeof(float));
        memcpy(old_ff2[l], layer->w_ff2, d_ff * d_model * sizeof(float));
    }

    /* Consult observer state for per-matrix learning rate scaling */
    float *obs_scales = compute_observer_scales(&g_model);
    float emb_scale = obs_scales ? obs_scales[0] : 1.0f;
    float proj_scale = obs_scales ? obs_scales[1] : 1.0f;

    for (int i = 0; i < d_model * vocab_size; i++)
        g_model.output_proj[i] -= effective_lr * proj_scale * grad_output_proj[i];
    for (int i = 0; i < vocab_size * d_model; i++)
        g_model.token_embeddings[i] -= effective_lr * emb_scale * grad_token_emb[i];

    /* Body matrices learn at 0.1× the head rate. This damp acts as a
     * regularizer: removing it (tested empirically, 1 epoch at vocab=339)
     * accelerates body movement 7-10× but destabilizes the head/body
     * co-adaptation when training continues from a damp-trained checkpoint.
     * Eval metrics regressed (LAST_POS_ACC 58→51%, PARSE_RATE 20→0%, INDENT
     * 4→0) despite training loss continuing to descend. */
    float scale = effective_lr * 0.1f;
    for (int l = 0; l < n_layers; l++) {
        TransformerLayer *layer = &g_model.layers[l];
        /* Observer scales: index 2 + l*10 + {0=wq,1=wk,2=wv,3=wo,4=ff1,5=ff2,6=ln1g,7=ln1b,8=ln2g,9=ln2b} */
        int si = 2 + l * 10;
        float sq = obs_scales ? obs_scales[si + 0] : 1.0f;
        float sk = obs_scales ? obs_scales[si + 1] : 1.0f;
        float sv = obs_scales ? obs_scales[si + 2] : 1.0f;
        float so = obs_scales ? obs_scales[si + 3] : 1.0f;
        float sf1 = obs_scales ? obs_scales[si + 4] : 1.0f;
        float sf2 = obs_scales ? obs_scales[si + 5] : 1.0f;
        float sln1g = obs_scales ? obs_scales[si + 6] : 1.0f;
        float sln1b = obs_scales ? obs_scales[si + 7] : 1.0f;
        float sln2g = obs_scales ? obs_scales[si + 8] : 1.0f;
        float sln2b = obs_scales ? obs_scales[si + 9] : 1.0f;

        for (int i = 0; i < d_model * d_model; i++) {
            layer->w_q[i] -= scale * sq * lg_wq[l][i];
            layer->w_k[i] -= scale * sk * lg_wk[l][i];
            layer->w_v[i] -= scale * sv * lg_wv[l][i];
            layer->w_o[i] -= scale * so * lg_wo[l][i];
        }
        for (int i = 0; i < d_model * d_ff; i++) layer->w_ff1[i] -= scale * sf1 * lg_ff1[l][i];
        for (int i = 0; i < d_ff * d_model; i++) layer->w_ff2[i] -= scale * sf2 * lg_ff2[l][i];
        for (int i = 0; i < d_model; i++) {
            layer->ln1_gamma[i] -= scale * sln1g * lg_ln1g[l][i];
            layer->ln1_beta[i] -= scale * sln1b * lg_ln1b[l][i];
            layer->ln2_gamma[i] -= scale * sln2g * lg_ln2g[l][i];
            layer->ln2_beta[i] -= scale * sln2b * lg_ln2b[l][i];
        }
    }

    /* ---- Per-step diagnostic dump (EIGS_TRAIN_DUMP) ----
     * Applied delta L2 = (per-matrix LR factor) * ||grad||_2, where the
     * head matrices use effective_lr * emb/proj_scale and body matrices
     * use scale = effective_lr * 0.1 * per-matrix obs_scale. */
    train_dump_open_if_needed(&g_model);
    if (g_train_dump_fp) {
        float g_emb = l2_norm_f(grad_token_emb, (int64_t)vocab_size * d_model);
        float g_op  = l2_norm_f(grad_output_proj, (int64_t)d_model * vocab_size);
        fprintf(g_train_dump_fp, "%d,%.6f,%.8f,%.6f", g_training_samples, avg_loss, effective_lr, final_step_entropy);
        /* Gradient L2 columns */
        fprintf(g_train_dump_fp, ",%.6e,%.6e", g_emb, g_op);
        for (int l = 0; l < n_layers; l++) {
            fprintf(g_train_dump_fp,
                ",%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e",
                l2_norm_f(lg_wq[l], (int64_t)d_model * d_model),
                l2_norm_f(lg_wk[l], (int64_t)d_model * d_model),
                l2_norm_f(lg_wv[l], (int64_t)d_model * d_model),
                l2_norm_f(lg_wo[l], (int64_t)d_model * d_model),
                l2_norm_f(lg_ff1[l], (int64_t)d_model * d_ff),
                l2_norm_f(lg_ff2[l], (int64_t)d_ff * d_model),
                l2_norm_f(lg_ln1g[l], d_model),
                l2_norm_f(lg_ln1b[l], d_model),
                l2_norm_f(lg_ln2g[l], d_model),
                l2_norm_f(lg_ln2b[l], d_model));
        }
        /* Observer scale columns */
        fprintf(g_train_dump_fp, ",%.4f,%.4f", emb_scale, proj_scale);
        for (int l = 0; l < n_layers; l++) {
            int si = 2 + l * 10;
            for (int k = 0; k < 10; k++) {
                float s = obs_scales ? obs_scales[si + k] : 1.0f;
                fprintf(g_train_dump_fp, ",%.4f", s);
            }
        }
        /* Applied delta L2 columns = LR_factor * grad_L2 */
        float d_emb = effective_lr * emb_scale * g_emb;
        float d_op  = effective_lr * proj_scale * g_op;
        fprintf(g_train_dump_fp, ",%.6e,%.6e", d_emb, d_op);
        for (int l = 0; l < n_layers; l++) {
            int si = 2 + l * 10;
            float sq   = obs_scales ? obs_scales[si + 0] : 1.0f;
            float sk_  = obs_scales ? obs_scales[si + 1] : 1.0f;
            float sv   = obs_scales ? obs_scales[si + 2] : 1.0f;
            float so   = obs_scales ? obs_scales[si + 3] : 1.0f;
            float sf1  = obs_scales ? obs_scales[si + 4] : 1.0f;
            float sf2  = obs_scales ? obs_scales[si + 5] : 1.0f;
            float sln1g= obs_scales ? obs_scales[si + 6] : 1.0f;
            float sln1b= obs_scales ? obs_scales[si + 7] : 1.0f;
            float sln2g= obs_scales ? obs_scales[si + 8] : 1.0f;
            float sln2b= obs_scales ? obs_scales[si + 9] : 1.0f;
            fprintf(g_train_dump_fp,
                ",%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e,%.6e",
                scale * sq   * l2_norm_f(lg_wq[l], (int64_t)d_model * d_model),
                scale * sk_  * l2_norm_f(lg_wk[l], (int64_t)d_model * d_model),
                scale * sv   * l2_norm_f(lg_wv[l], (int64_t)d_model * d_model),
                scale * so   * l2_norm_f(lg_wo[l], (int64_t)d_model * d_model),
                scale * sf1  * l2_norm_f(lg_ff1[l], (int64_t)d_model * d_ff),
                scale * sf2  * l2_norm_f(lg_ff2[l], (int64_t)d_ff * d_model),
                scale * sln1g* l2_norm_f(lg_ln1g[l], d_model),
                scale * sln1b* l2_norm_f(lg_ln1b[l], d_model),
                scale * sln2g* l2_norm_f(lg_ln2g[l], d_model),
                scale * sln2b* l2_norm_f(lg_ln2b[l], d_model));
        }
        fprintf(g_train_dump_fp, "\n");
        fflush(g_train_dump_fp);
    }

    /* ---- Per-class CE-loss dump (EIGS_CLASS_LOSS_DUMP) ----
     * One row per training step: count + sum-of-loss in each target-token
     * bucket. Post-process: mean = loss_sum / count when count > 0. */
    class_loss_open_if_needed();
    if (g_class_loss_fp) {
        fprintf(g_class_loss_fp, "%d", g_training_samples);
        for (int c = 0; c < CLS_N; c++)
            fprintf(g_class_loss_fp, ",%d,%.6f", cls_count[c], cls_loss_sum[c]);
        fprintf(g_class_loss_fp, "\n");
        fflush(g_class_loss_fp);
    }

    /* ---- Per-depth DEDENT-loss dump (EIGS_DEPTH_LOSS_DUMP) ----
     * Buckets DEDENT-target CE loss by indent depth at predict-time.
     * If loss rises with depth, the model can't track deep nesting. */
    depth_loss_open_if_needed();
    if (g_depth_loss_fp) {
        fprintf(g_depth_loss_fp, "%d", g_training_samples);
        for (int d = 0; d < DEPTH_BUCKETS; d++)
            fprintf(g_depth_loss_fp, ",%d,%.6f", ded_depth_count[d], ded_depth_loss[d]);
        fprintf(g_depth_loss_fp, "\n");
        fflush(g_depth_loss_fp);
    }

    free(obs_scales);

    /* Update observer state from weight deltas */
    update_model_observer(&g_model, old_token_emb, old_output_proj,
                          old_wq, old_wk, old_wv, old_wo, old_ff1, old_ff2);

    /* Free snapshots */
    free(old_token_emb); free(old_output_proj);
    for (int l = 0; l < n_layers; l++) {
        free(old_wq[l]); free(old_wk[l]); free(old_wv[l]);
        free(old_wo[l]); free(old_ff1[l]); free(old_ff2[l]);
    }
    free(old_wq); free(old_wk); free(old_wv); free(old_wo); free(old_ff1); free(old_ff2);

    /* Re-quantize master weights → ternary copies for next forward pass (if ternary format) */
    if (g_model.weight_format == WEIGHT_FORMAT_TERNARY) {
        requantize_all_layers(&g_model);
    }

    g_model_age += num_tokens;
    g_training_samples++;

    *loss_out = avg_loss;
    *tokens_trained_out = num_tokens;

    free(token_ids); free(grad_token_emb); free(grad_output_proj);
    for (int l = 0; l < n_layers; l++) {
        free(lg_wq[l]); free(lg_wk[l]); free(lg_wv[l]); free(lg_wo[l]);
        free(lg_ff1[l]); free(lg_ff2[l]);
        free(lg_ln1g[l]); free(lg_ln1b[l]); free(lg_ln2g[l]); free(lg_ln2b[l]);
    }
    free(lg_wq); free(lg_wk); free(lg_wv); free(lg_wo);
    free(lg_ff1); free(lg_ff2);
    free(lg_ln1g); free(lg_ln1b); free(lg_ln2g); free(lg_ln2b);
    free(cache.layer_inputs); free(cache.norm1_outputs); free(cache.norm2_outputs);
    free(cache.attn_probs); free(cache.ffn_pre_act); free(cache.post_attn_x);
    free(cache.final_x);
    free(cache.ln1_x_norm); free(cache.ln1_std);
    free(cache.ln2_x_norm); free(cache.ln2_std);

    return 0;
}

Value* builtin_native_train_step(Value *arg) {
    /* Thin wrapper around native_train_step().
     * Input: [input_ids_list, output_ids_list, learning_rate]
     * Output: JSON string with status, loss, tokens, model_age, training_samples */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        return make_str("{\"status\": \"error\", \"error\": \"requires [input_ids, output_ids, lr]\"}");
    }
    if (!g_model.loaded) {
        return make_str("{\"status\": \"error\", \"error\": \"Model not loaded\"}");
    }

    Value *in_list = arg->data.list.items[0];
    Value *out_list = arg->data.list.items[1];
    if (in_list->type != VAL_LIST || out_list->type != VAL_LIST) {
        return make_str("{\"status\": \"error\", \"error\": \"input_ids and output_ids must be lists\"}");
    }

    float lr = 0.001f;
    if (arg->data.list.items[2]->type == VAL_NUM) lr = arg->data.list.items[2]->data.num;
    else if (arg->data.list.items[2]->type == VAL_STR) lr = strtod(arg->data.list.items[2]->data.str, NULL);
    if (lr <= 0 || lr > 1) lr = 0.001f;

    int input_len = in_list->data.list.count;
    int output_len = out_list->data.list.count;
    int *input_ids = xcalloc(input_len > 0 ? input_len : 1, sizeof(int));
    int *output_ids = xcalloc(output_len > 0 ? output_len : 1, sizeof(int));
    for (int i = 0; i < input_len; i++) {
        Value *v = in_list->data.list.items[i];
        input_ids[i] = (v->type == VAL_NUM) ? (int)v->data.num : 0;
    }
    for (int i = 0; i < output_len; i++) {
        Value *v = out_list->data.list.items[i];
        output_ids[i] = (v->type == VAL_NUM) ? (int)v->data.num : 0;
    }

    float loss = 0.0f;
    int tokens_trained = 0;
    int result = native_train_step(input_ids, input_len, output_ids, output_len, lr, &loss, &tokens_trained);
    free(input_ids);
    free(output_ids);

    char buf[512];
    if (result == 0) {
        float effective_lr = lr / logf((float)g_model_age + M_E);
        snprintf(buf, sizeof(buf),
            "{\"status\": \"trained\", \"loss\": %.6f, \"tokens_trained\": %d, "
            "\"model_age\": %d, \"training_samples\": %d, \"effective_lr\": %.6f, \"engine\": \"eigenscript\"}",
            loss, tokens_trained, g_model_age, g_training_samples, effective_lr);
    } else {
        snprintf(buf, sizeof(buf), "{\"status\": \"error\", \"error\": \"Training step failed\"}");
    }
    return make_str(buf);
}

void register_model_builtins(Env *env) {
    env_set_local(env, "eigen_model_loaded", make_builtin(builtin_eigen_model_loaded));
    env_set_local(env, "eigen_generate", make_builtin(builtin_eigen_generate));
    env_set_local(env, "eigen_model_info", make_builtin(builtin_eigen_model_info));
    env_set_local(env, "native_train_step_builtin", make_builtin(builtin_native_train_step));
    env_set_local(env, "model_save_weights", make_builtin(builtin_model_save_weights));
    env_set_local(env, "eigen_model_load", make_builtin(builtin_eigen_model_load));
    env_set_local(env, "model_load_weights", make_builtin(builtin_eigen_model_load));
    env_set_local(env, "eigen_model_save_binary", make_builtin(builtin_eigen_model_save_binary));
    env_set_local(env, "eigen_checkpoint_info", make_builtin(builtin_eigen_checkpoint_info));
}
