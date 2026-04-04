/*
 * EigenScript Model Training — backward pass, training step, registration.
 * Uses forward kernels from model_infer.c via model_internal.h.
 */

#include "model_internal.h"

static void ne_matmul_at_buf(
    double* a, int64_t m, int64_t k,
    double* b, int64_t n,
    double* out
) {
    memset(out, 0, k * n * sizeof(double));
    for (int64_t i0 = 0; i0 < k; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < m; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < k ? i0 + NE_TILE_SIZE : k;
                int64_t j_end = j0 + NE_TILE_SIZE < n ? j0 + NE_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TILE_SIZE < m ? k0 + NE_TILE_SIZE : m;
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

static void ne_matmul_bt_buf(
    double* a, int64_t m, int64_t k,
    double* b, int64_t n,
    double* out
) {
    memset(out, 0, m * k * sizeof(double));
    for (int64_t i0 = 0; i0 < m; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < k; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < n; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < m ? i0 + NE_TILE_SIZE : m;
                int64_t j_end = j0 + NE_TILE_SIZE < k ? j0 + NE_TILE_SIZE : k;
                int64_t k_end = k0 + NE_TILE_SIZE < n ? k0 + NE_TILE_SIZE : n;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        double a_ik = a[i * n + kk];
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
    double* d_attn_out, int64_t seq_len, int64_t d_model,
    double* x,
    double* wq, double* wk, double* wv, double* wo,
    double* attn_probs,
    double* d_wq, double* d_wk, double* d_wv, double* d_wo,
    double* d_x
) {
    int64_t sd = seq_len * d_model;
    int64_t dd = d_model * d_model;
    int64_t ss = seq_len * seq_len;
    (void)dd;

    double* Q = (double*)calloc(sd, sizeof(double));
    double* K = (double*)calloc(sd, sizeof(double));
    double* V = (double*)calloc(sd, sizeof(double));
    double* context = (double*)calloc(sd, sizeof(double));

    ne_matmul_buf(x, seq_len, d_model, wq, d_model, Q);
    ne_matmul_buf(x, seq_len, d_model, wk, d_model, K);
    ne_matmul_buf(x, seq_len, d_model, wv, d_model, V);
    ne_matmul_buf(attn_probs, seq_len, seq_len, V, d_model, context);

    double* d_context = (double*)calloc(sd, sizeof(double));
    ne_matmul_bt_buf(d_attn_out, seq_len, d_model, wo, d_model, d_context);

    ne_matmul_at_buf(context, seq_len, d_model, d_attn_out, d_model, d_wo);

    double* d_V = (double*)calloc(sd, sizeof(double));
    ne_matmul_at_buf(attn_probs, seq_len, seq_len, d_context, d_model, d_V);

    double* d_probs = (double*)calloc(ss, sizeof(double));
    double* Vt = (double*)calloc(sd, sizeof(double));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < d_model; j++) {
            Vt[j * seq_len + i] = V[i * d_model + j];
        }
    }
    ne_matmul_buf(d_context, seq_len, d_model, Vt, seq_len, d_probs);
    free(Vt);

    ne_matmul_at_buf(x, seq_len, d_model, d_V, d_model, d_wv);

    double* d_scores = (double*)calloc(ss, sizeof(double));
    for (int64_t i = 0; i < seq_len; i++) {
        double s = 0.0;
        for (int64_t j = 0; j < seq_len; j++) {
            s += attn_probs[i * seq_len + j] * d_probs[i * seq_len + j];
        }
        for (int64_t j = 0; j < seq_len; j++) {
            d_scores[i * seq_len + j] = attn_probs[i * seq_len + j] * (d_probs[i * seq_len + j] - s);
        }
    }

    double scale = 1.0 / sqrt((double)d_model);

    double* d_Q = (double*)calloc(sd, sizeof(double));
    ne_matmul_buf(d_scores, seq_len, seq_len, K, d_model, d_Q);
    for (int64_t i = 0; i < sd; i++) d_Q[i] *= scale;

    double* d_K = (double*)calloc(sd, sizeof(double));
    double* d_scores_t = (double*)calloc(ss, sizeof(double));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < seq_len; j++) {
            d_scores_t[j * seq_len + i] = d_scores[i * seq_len + j];
        }
    }
    ne_matmul_buf(d_scores_t, seq_len, seq_len, Q, d_model, d_K);
    for (int64_t i = 0; i < sd; i++) d_K[i] *= scale;
    free(d_scores_t);

    ne_matmul_at_buf(x, seq_len, d_model, d_Q, d_model, d_wq);
    ne_matmul_at_buf(x, seq_len, d_model, d_K, d_model, d_wk);

    memset(d_x, 0, sd * sizeof(double));
    double* temp = (double*)calloc(sd, sizeof(double));

    ne_matmul_bt_buf(d_Q, seq_len, d_model, wq, d_model, temp);
    for (int64_t i = 0; i < sd; i++) d_x[i] += temp[i];

    memset(temp, 0, sd * sizeof(double));
    ne_matmul_bt_buf(d_K, seq_len, d_model, wk, d_model, temp);
    for (int64_t i = 0; i < sd; i++) d_x[i] += temp[i];

    memset(temp, 0, sd * sizeof(double));
    ne_matmul_bt_buf(d_V, seq_len, d_model, wv, d_model, temp);
    for (int64_t i = 0; i < sd; i++) d_x[i] += temp[i];

    free(temp);
    free(Q); free(K); free(V); free(context);
    free(d_context); free(d_V); free(d_probs);
    free(d_scores); free(d_Q); free(d_K);
}

static void ne_fused_ffn_backward_buf(
    double* d_out, int64_t seq_len, int64_t d_model,
    double* x,
    double* w1, int64_t d_ff,
    double* w2,
    double* pre_act,
    double* d_w1, double* d_w2, double* d_x
) {
    int64_t sf = seq_len * d_ff;
    const double sqrt_2_over_pi = sqrt(2.0 / M_PI);
    const double sqrt_2pi = sqrt(2.0 * M_PI);

    double* gelu_out = (double*)calloc(sf, sizeof(double));
    memcpy(gelu_out, pre_act, sf * sizeof(double));
    ne_gelu_buf(gelu_out, sf);

    double* d_gelu = (double*)calloc(sf, sizeof(double));
    ne_matmul_bt_buf(d_out, seq_len, d_ff, w2, d_model, d_gelu);

    ne_matmul_at_buf(gelu_out, seq_len, d_ff, d_out, d_model, d_w2);

    double* d_hidden = (double*)calloc(sf, sizeof(double));
    for (int64_t i = 0; i < sf; i++) {
        double h = pre_act[i];
        double cdf = 0.5 * (1.0 + tanh(sqrt_2_over_pi * (h + 0.044715 * h * h * h)));
        double pdf = exp(-0.5 * h * h) / sqrt_2pi;
        double gelu_grad = cdf + h * pdf;
        d_hidden[i] = d_gelu[i] * gelu_grad;
    }

    ne_matmul_at_buf(x, seq_len, d_model, d_hidden, d_ff, d_w1);
    ne_matmul_bt_buf(d_hidden, seq_len, d_model, w1, d_ff, d_x);

    free(gelu_out); free(d_gelu); free(d_hidden);
}

static void layer_norm_backward(double *d_out, double *x_norm, double *gamma, double std_val, int d_model,
                                 double *d_x, double *d_gamma, double *d_beta) {
    double *d_x_norm_vec = calloc(d_model, sizeof(double));
    for (int j = 0; j < d_model; j++) {
        d_gamma[j] += d_out[j] * x_norm[j];
        d_beta[j] += d_out[j];
        d_x_norm_vec[j] = d_out[j] * gamma[j];
    }
    double mean_d = 0.0, mean_xd = 0.0;
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

static double cross_entropy_loss(double *logits, int target_id, int vocab_size, double *probs_out) {
    double max_l = logits[0];
    for (int i = 1; i < vocab_size; i++) if (logits[i] > max_l) max_l = logits[i];
    double sum = 0.0;
    for (int i = 0; i < vocab_size; i++) { probs_out[i] = exp(logits[i] - max_l); sum += probs_out[i]; }
    for (int i = 0; i < vocab_size; i++) probs_out[i] /= sum;
    double tp = probs_out[target_id];
    if (tp < 1e-10) tp = 1e-10;
    return -log(tp);
}

static void native_forward_with_cache(int *token_ids, int seq_len, TransformerModel *model, double *logits_out, TrainingCache *cache) {
    int d_model = model->config.d_model;
    int d_ff = model->config.d_ff;
    int n_layers = model->config.n_layers;

    double *x = calloc(seq_len * d_model, sizeof(double));
    for (int i = 0; i < seq_len; i++) {
        int tid = token_ids[i];
        if (tid < 0) tid = 0;
        if (tid >= model->config.vocab_size) tid = model->config.vocab_size - 1;
        memcpy(x + i * d_model, model->token_embeddings + tid * d_model, d_model * sizeof(double));
    }

    double *pe = calloc(seq_len * d_model, sizeof(double));
    create_sinusoidal_pe(pe, seq_len, d_model);
    for (int i = 0; i < seq_len * d_model; i++) x[i] += pe[i];
    free(pe);

    cache->seq_len = seq_len;

    for (int l = 0; l < n_layers; l++) {
        TransformerLayer *layer = &model->layers[l];
        int lsd = l * seq_len * d_model;
        int lss = l * seq_len * seq_len;
        int lsf = l * seq_len * d_ff;
        int ls = l * seq_len;

        memcpy(cache->layer_inputs + lsd, x, seq_len * d_model * sizeof(double));

        double *norm1 = calloc(seq_len * d_model, sizeof(double));
        for (int i = 0; i < seq_len; i++) {
            double *xi = x + i * d_model;
            double *out = norm1 + i * d_model;
            double mean = 0.0;
            for (int j = 0; j < d_model; j++) mean += xi[j];
            mean /= d_model;
            double var = 0.0;
            for (int j = 0; j < d_model; j++) { double d = xi[j] - mean; var += d * d; }
            var /= d_model;
            double std_val = sqrt(var + 1e-5);
            for (int j = 0; j < d_model; j++) {
                double xn = (xi[j] - mean) / std_val;
                cache->ln1_x_norm[lsd + i * d_model + j] = xn;
                out[j] = layer->ln1_gamma[j] * xn + layer->ln1_beta[j];
            }
            cache->ln1_std[ls + i] = std_val;
        }
        memcpy(cache->norm1_outputs + lsd, norm1, seq_len * d_model * sizeof(double));

        double *attn_out = calloc(seq_len * d_model, sizeof(double));
        ne_fused_attention_forward_buf(norm1, seq_len, d_model,
            layer->w_q, layer->w_k, layer->w_v, layer->w_o,
            attn_out, cache->attn_probs + lss);
        free(norm1);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += attn_out[i];
        free(attn_out);

        memcpy(cache->post_attn_x + lsd, x, seq_len * d_model * sizeof(double));

        double *norm2 = calloc(seq_len * d_model, sizeof(double));
        for (int i = 0; i < seq_len; i++) {
            double *xi = x + i * d_model;
            double *out = norm2 + i * d_model;
            double mean = 0.0;
            for (int j = 0; j < d_model; j++) mean += xi[j];
            mean /= d_model;
            double var = 0.0;
            for (int j = 0; j < d_model; j++) { double d = xi[j] - mean; var += d * d; }
            var /= d_model;
            double std_val = sqrt(var + 1e-5);
            for (int j = 0; j < d_model; j++) {
                double xn = (xi[j] - mean) / std_val;
                cache->ln2_x_norm[lsd + i * d_model + j] = xn;
                out[j] = layer->ln2_gamma[j] * xn + layer->ln2_beta[j];
            }
            cache->ln2_std[ls + i] = std_val;
        }
        memcpy(cache->norm2_outputs + lsd, norm2, seq_len * d_model * sizeof(double));

        double *ffn_out = calloc(seq_len * d_model, sizeof(double));
        ne_fused_ffn_forward_buf(norm2, seq_len, d_model,
            layer->w_ff1, d_ff, layer->w_ff2,
            1, ffn_out, cache->ffn_pre_act + lsf);
        free(norm2);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += ffn_out[i];
        free(ffn_out);
    }

    memcpy(cache->final_x, x, seq_len * d_model * sizeof(double));

    double *last_hidden = x + (seq_len - 1) * d_model;
    for (int j = 0; j < model->config.vocab_size; j++) {
        double sum = 0.0;
        for (int k = 0; k < d_model; k++) {
            sum += last_hidden[k] * model->output_proj[k * model->config.vocab_size + j];
        }
        logits_out[j] = sum;
    }
    free(x);
}

static void sanitize_training_text(const char *src, char *dst, int max_len) {
    int di = 0;
    for (int i = 0; src[i] && di < max_len - 1; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c < 32 && c != '\n' && c != '\t') continue;
        if (c == 127) continue;
        if (c == '\'' || c == '\x60') { dst[di++] = ' '; continue; }
        if (c == '"') { dst[di++] = ' '; continue; }
        if (c == '\\') { dst[di++] = ' '; continue; }
        if (c >= 128) { dst[di++] = ' '; continue; }
        dst[di++] = (char)c;
    }
    dst[di] = '\0';
}

static int native_train_step(const char *input_text, const char *output_text, double learning_rate, double *loss_out, int *tokens_trained_out) {
    if (!g_model.loaded) return -1;

    int vocab_size = g_model.config.vocab_size;
    int d_model = g_model.config.d_model;
    int d_ff = g_model.config.d_ff;
    int n_layers = g_model.config.n_layers;
    int max_seq_len = g_model.config.max_seq_len;

    double effective_lr = learning_rate / log((double)g_model_age + M_E);

    char *clean_input = calloc(strlen(input_text) + 1, 1);
    char *clean_output = calloc(strlen(output_text) + 1, 1);
    sanitize_training_text(input_text, clean_input, strlen(input_text) + 1);
    sanitize_training_text(output_text, clean_output, strlen(output_text) + 1);

    int input_len = strlen(clean_input);
    int output_len = strlen(clean_output);
    int full_len = input_len + output_len;
    int *token_ids = calloc(full_len, sizeof(int));
    for (int i = 0; i < input_len; i++) token_ids[i] = ((unsigned char)clean_input[i]) % vocab_size;
    for (int i = 0; i < output_len; i++) token_ids[input_len + i] = ((unsigned char)clean_output[i]) % vocab_size;
    free(clean_input);
    free(clean_output);

    if (full_len < 2) { free(token_ids); return -1; }

    double *grad_token_emb = calloc(vocab_size * d_model, sizeof(double));
    double *grad_output_proj = calloc(d_model * vocab_size, sizeof(double));

    double **lg_wq = calloc(n_layers, sizeof(double*));
    double **lg_wk = calloc(n_layers, sizeof(double*));
    double **lg_wv = calloc(n_layers, sizeof(double*));
    double **lg_wo = calloc(n_layers, sizeof(double*));
    double **lg_ff1 = calloc(n_layers, sizeof(double*));
    double **lg_ff2 = calloc(n_layers, sizeof(double*));
    double **lg_ln1g = calloc(n_layers, sizeof(double*));
    double **lg_ln1b = calloc(n_layers, sizeof(double*));
    double **lg_ln2g = calloc(n_layers, sizeof(double*));
    double **lg_ln2b = calloc(n_layers, sizeof(double*));
    for (int l = 0; l < n_layers; l++) {
        lg_wq[l] = calloc(d_model * d_model, sizeof(double));
        lg_wk[l] = calloc(d_model * d_model, sizeof(double));
        lg_wv[l] = calloc(d_model * d_model, sizeof(double));
        lg_wo[l] = calloc(d_model * d_model, sizeof(double));
        lg_ff1[l] = calloc(d_model * d_ff, sizeof(double));
        lg_ff2[l] = calloc(d_ff * d_model, sizeof(double));
        lg_ln1g[l] = calloc(d_model, sizeof(double));
        lg_ln1b[l] = calloc(d_model, sizeof(double));
        lg_ln2g[l] = calloc(d_model, sizeof(double));
        lg_ln2b[l] = calloc(d_model, sizeof(double));
    }

    double total_loss = 0.0;
    int num_tokens = 0;

    int max_ctx = max_seq_len < full_len ? max_seq_len : full_len;
    TrainingCache cache;
    cache.layer_inputs = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.norm1_outputs = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.norm2_outputs = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.attn_probs = calloc(n_layers * max_ctx * max_ctx, sizeof(double));
    cache.ffn_pre_act = calloc(n_layers * max_ctx * d_ff, sizeof(double));
    cache.post_attn_x = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.final_x = calloc(max_ctx * d_model, sizeof(double));
    cache.ln1_x_norm = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.ln1_std = calloc(n_layers * max_ctx, sizeof(double));
    cache.ln2_x_norm = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.ln2_std = calloc(n_layers * max_ctx, sizeof(double));

    for (int t = 0; t < full_len - 1; t++) {
        int ctx_len = t + 1;
        if (ctx_len > max_seq_len) ctx_len = max_seq_len;
        int ctx_start = (t + 1) - ctx_len;
        int target_id = token_ids[t + 1];

        memset(cache.layer_inputs, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.norm1_outputs, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.norm2_outputs, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.attn_probs, 0, n_layers * ctx_len * ctx_len * sizeof(double));
        memset(cache.ffn_pre_act, 0, n_layers * ctx_len * d_ff * sizeof(double));
        memset(cache.post_attn_x, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.ln1_x_norm, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.ln1_std, 0, n_layers * ctx_len * sizeof(double));
        memset(cache.ln2_x_norm, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.ln2_std, 0, n_layers * ctx_len * sizeof(double));

        double *logits = calloc(vocab_size, sizeof(double));
        native_forward_with_cache(token_ids + ctx_start, ctx_len, &g_model, logits, &cache);

        double *probs = calloc(vocab_size, sizeof(double));
        double loss = cross_entropy_loss(logits, target_id, vocab_size, probs);
        total_loss += loss;
        num_tokens++;
        free(logits);

        double *d_logits = calloc(vocab_size, sizeof(double));
        memcpy(d_logits, probs, vocab_size * sizeof(double));
        d_logits[target_id] -= 1.0;
        free(probs);

        double *last_hidden = cache.final_x + (ctx_len - 1) * d_model;
        for (int k = 0; k < d_model; k++) {
            for (int j = 0; j < vocab_size; j++) {
                grad_output_proj[k * vocab_size + j] += last_hidden[k] * d_logits[j];
            }
        }

        double *d_x = calloc(ctx_len * d_model, sizeof(double));
        for (int k = 0; k < d_model; k++) {
            double sum = 0.0;
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

            double *d_ffn_w1 = calloc(d_model * d_ff, sizeof(double));
            double *d_ffn_w2 = calloc(d_ff * d_model, sizeof(double));
            double *d_norm2_out = calloc(ctx_len * d_model, sizeof(double));
            ne_fused_ffn_backward_buf(d_x, ctx_len, d_model,
                cache.norm2_outputs + lsd, layer->w_ff1, d_ff, layer->w_ff2,
                cache.ffn_pre_act + lsf, d_ffn_w1, d_ffn_w2, d_norm2_out);
            for (int i = 0; i < d_model * d_ff; i++) lg_ff1[l][i] += d_ffn_w1[i];
            for (int i = 0; i < d_ff * d_model; i++) lg_ff2[l][i] += d_ffn_w2[i];
            free(d_ffn_w1); free(d_ffn_w2);

            double *d_post_attn = calloc(ctx_len * d_model, sizeof(double));
            for (int i = 0; i < ctx_len; i++) {
                double d_ln_x[MAX_D_MODEL] = {0};
                layer_norm_backward(d_norm2_out + i * d_model,
                    cache.ln2_x_norm + lsd + i * d_model,
                    layer->ln2_gamma, cache.ln2_std[ls + i], d_model,
                    d_ln_x, lg_ln2g[l], lg_ln2b[l]);
                for (int j = 0; j < d_model; j++)
                    d_post_attn[i * d_model + j] = d_x[i * d_model + j] + d_ln_x[j];
            }
            free(d_norm2_out);

            double *d_attn_wq = calloc(d_model * d_model, sizeof(double));
            double *d_attn_wk = calloc(d_model * d_model, sizeof(double));
            double *d_attn_wv = calloc(d_model * d_model, sizeof(double));
            double *d_attn_wo = calloc(d_model * d_model, sizeof(double));
            double *d_norm1_out = calloc(ctx_len * d_model, sizeof(double));
            ne_fused_attention_backward_buf(d_post_attn, ctx_len, d_model,
                cache.norm1_outputs + lsd,
                layer->w_q, layer->w_k, layer->w_v, layer->w_o,
                cache.attn_probs + lss,
                d_attn_wq, d_attn_wk, d_attn_wv, d_attn_wo, d_norm1_out);
            for (int i = 0; i < d_model * d_model; i++) {
                lg_wq[l][i] += d_attn_wq[i];
                lg_wk[l][i] += d_attn_wk[i];
                lg_wv[l][i] += d_attn_wv[i];
                lg_wo[l][i] += d_attn_wo[i];
            }
            free(d_attn_wq); free(d_attn_wk); free(d_attn_wv); free(d_attn_wo);

            double *d_pre_attn = calloc(ctx_len * d_model, sizeof(double));
            for (int i = 0; i < ctx_len; i++) {
                double d_ln_x[MAX_D_MODEL] = {0};
                layer_norm_backward(d_norm1_out + i * d_model,
                    cache.ln1_x_norm + lsd + i * d_model,
                    layer->ln1_gamma, cache.ln1_std[ls + i], d_model,
                    d_ln_x, lg_ln1g[l], lg_ln1b[l]);
                for (int j = 0; j < d_model; j++)
                    d_pre_attn[i * d_model + j] = d_post_attn[i * d_model + j] + d_ln_x[j];
            }
            free(d_post_attn); free(d_norm1_out);

            memcpy(d_x, d_pre_attn, ctx_len * d_model * sizeof(double));
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

    double avg_loss = num_tokens > 0 ? total_loss / num_tokens : 0.0;

    if (isnan(avg_loss) || isinf(avg_loss)) {
        fprintf(stderr, "[train-guard] NaN/Inf loss detected (%.4f) - SKIPPING weight update to prevent corruption\n", avg_loss);
        *loss_out = 0.0;
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
        *loss_out = 0.0;
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

    for (int i = 0; i < d_model * vocab_size; i++)
        g_model.output_proj[i] -= effective_lr * grad_output_proj[i];
    for (int i = 0; i < vocab_size * d_model; i++)
        g_model.token_embeddings[i] -= effective_lr * grad_token_emb[i];

    double scale = effective_lr * 0.1;
    for (int l = 0; l < n_layers; l++) {
        TransformerLayer *layer = &g_model.layers[l];
        for (int i = 0; i < d_model * d_model; i++) {
            layer->w_q[i] -= scale * lg_wq[l][i];
            layer->w_k[i] -= scale * lg_wk[l][i];
            layer->w_v[i] -= scale * lg_wv[l][i];
            layer->w_o[i] -= scale * lg_wo[l][i];
        }
        for (int i = 0; i < d_model * d_ff; i++) layer->w_ff1[i] -= scale * lg_ff1[l][i];
        for (int i = 0; i < d_ff * d_model; i++) layer->w_ff2[i] -= scale * lg_ff2[l][i];
        for (int i = 0; i < d_model; i++) {
            layer->ln1_gamma[i] -= scale * lg_ln1g[l][i];
            layer->ln1_beta[i] -= scale * lg_ln1b[l][i];
            layer->ln2_gamma[i] -= scale * lg_ln2g[l][i];
            layer->ln2_beta[i] -= scale * lg_ln2b[l][i];
        }
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
     * Input: [input_text, output_text, learning_rate]
     * Output: JSON string with status, loss, tokens, model_age, training_samples */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        return make_str("{\"status\": \"error\", \"error\": \"requires [input, output, lr]\"}");
    }
    if (!g_model.loaded) {
        return make_str("{\"status\": \"error\", \"error\": \"Model not loaded\"}");
    }

    const char *input = "";
    const char *output = "";
    double lr = 0.001;

    if (arg->data.list.items[0]->type == VAL_STR) input = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) output = arg->data.list.items[1]->data.str;
    if (arg->data.list.items[2]->type == VAL_NUM) lr = arg->data.list.items[2]->data.num;
    else if (arg->data.list.items[2]->type == VAL_STR) lr = strtod(arg->data.list.items[2]->data.str, NULL);

    if (lr <= 0 || lr > 1) lr = 0.001;

    double loss = 0.0;
    int tokens_trained = 0;
    int result = native_train_step(input, output, lr, &loss, &tokens_trained);

    char buf[512];
    if (result == 0) {
        double effective_lr = lr / log((double)g_model_age + M_E);
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
}
