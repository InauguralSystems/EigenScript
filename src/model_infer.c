/*
 * EigenScript Model Inference — shared kernels, forward pass, generation.
 * Defines ne_softmax_buf, ne_matmul_buf (public), forward kernels, generate_response.
 */

#include "model_internal.h"

void ne_softmax_buf(double* data, int64_t rows, int64_t cols) {
    for (int64_t i = 0; i < rows; i++) {
        double* row = data + i * cols;
        double max_val = row[0];
        for (int64_t j = 1; j < cols; j++) {
            if (row[j] > max_val) max_val = row[j];
        }
        double sum = 0.0;
        for (int64_t j = 0; j < cols; j++) {
            row[j] = exp(row[j] - max_val);
            sum += row[j];
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

void ne_gelu_buf(double* data, int64_t size) {
    const double sqrt_2_over_pi = sqrt(2.0 / M_PI);
    for (int64_t i = 0; i < size; i++) {
        double x = data[i];
        data[i] = 0.5 * x * (1.0 + tanh(sqrt_2_over_pi * (x + 0.044715 * x * x * x)));
    }
}

void ne_fused_attention_forward_buf(
    double* x, int64_t seq_len, int64_t d_model,
    double* wq, double* wk, double* wv, double* wo,
    double* out,
    double* attn_probs_out
) {
    int64_t sd = seq_len * d_model;
    int64_t ss = seq_len * seq_len;

    double* Q = (double*)calloc(sd, sizeof(double));
    double* K = (double*)calloc(sd, sizeof(double));
    double* V = (double*)calloc(sd, sizeof(double));
    double* scores = (double*)calloc(ss, sizeof(double));
    double* context = (double*)calloc(sd, sizeof(double));

    ne_matmul_buf(x, seq_len, d_model, wq, d_model, Q);
    ne_matmul_buf(x, seq_len, d_model, wk, d_model, K);
    ne_matmul_buf(x, seq_len, d_model, wv, d_model, V);

    double* Kt = (double*)calloc(sd, sizeof(double));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < d_model; j++) {
            Kt[j * seq_len + i] = K[i * d_model + j];
        }
    }
    ne_matmul_buf(Q, seq_len, d_model, Kt, seq_len, scores);
    free(Kt);

    double scale = 1.0 / sqrt((double)d_model);
    double neg_inf = -1.0 / 0.0;
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < seq_len; j++) {
            scores[i * seq_len + j] *= scale;
            if (j > i) {
                scores[i * seq_len + j] = neg_inf;
            }
        }
    }

    ne_softmax_buf(scores, seq_len, seq_len);

    memcpy(attn_probs_out, scores, ss * sizeof(double));

    ne_matmul_buf(scores, seq_len, seq_len, V, d_model, context);

    ne_matmul_buf(context, seq_len, d_model, wo, d_model, out);

    free(Q);
    free(K);
    free(V);
    free(scores);
    free(context);
}

void ne_fused_ffn_forward_buf(
    double* x, int64_t seq_len, int64_t d_model,
    double* w1, int64_t d_ff,
    double* w2,
    int32_t use_gelu,
    double* out,
    double* pre_act_out
) {
    int64_t sf = seq_len * d_ff;

    double* hidden = (double*)calloc(sf, sizeof(double));

    ne_matmul_buf(x, seq_len, d_model, w1, d_ff, hidden);

    memcpy(pre_act_out, hidden, sf * sizeof(double));

    if (use_gelu) {
        ne_gelu_buf(hidden, sf);
    }

    ne_matmul_buf(hidden, seq_len, d_ff, w2, d_model, out);

    free(hidden);
}

static void layer_norm(double *x, int64_t d, double *gamma, double *beta, double eps, double *out) {
    double mean = 0.0;
    for (int64_t i = 0; i < d; i++) mean += x[i];
    mean /= d;
    double var = 0.0;
    for (int64_t i = 0; i < d; i++) { double diff = x[i] - mean; var += diff * diff; }
    var /= d;
    double std_val = sqrt(var + eps);
    for (int64_t i = 0; i < d; i++) out[i] = (x[i] - mean) / std_val * gamma[i] + beta[i];
}

void create_sinusoidal_pe(double *pe, int seq_len, int d_model) {
    for (int pos = 0; pos < seq_len; pos++) {
        for (int i = 0; i < d_model; i += 2) {
            double div_term = exp((double)i * -(log(10000.0) / d_model));
            pe[pos * d_model + i] = sin((double)pos * div_term);
            if (i + 1 < d_model) pe[pos * d_model + i + 1] = cos((double)pos * div_term);
        }
    }
}

static void native_forward(int *token_ids, int seq_len, TransformerModel *model, double *logits_out) {
    int d_model = model->config.d_model;
    int d_ff = model->config.d_ff;

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

    for (int l = 0; l < model->config.n_layers; l++) {
        TransformerLayer *layer = &model->layers[l];

        double *norm1 = calloc(seq_len * d_model, sizeof(double));
        for (int i = 0; i < seq_len; i++) {
            layer_norm(x + i * d_model, d_model, layer->ln1_gamma, layer->ln1_beta, 1e-6, norm1 + i * d_model);
        }

        double *attn_out = calloc(seq_len * d_model, sizeof(double));
        double *attn_probs = calloc(seq_len * seq_len, sizeof(double));
        ne_fused_attention_forward_buf(norm1, seq_len, d_model,
            layer->w_q, layer->w_k, layer->w_v, layer->w_o,
            attn_out, attn_probs);
        free(norm1);
        free(attn_probs);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += attn_out[i];
        free(attn_out);

        double *norm2 = calloc(seq_len * d_model, sizeof(double));
        for (int i = 0; i < seq_len; i++) {
            layer_norm(x + i * d_model, d_model, layer->ln2_gamma, layer->ln2_beta, 1e-6, norm2 + i * d_model);
        }

        double *ffn_out = calloc(seq_len * d_model, sizeof(double));
        double *pre_act = calloc(seq_len * d_ff, sizeof(double));
        ne_fused_ffn_forward_buf(norm2, seq_len, d_model,
            layer->w_ff1, d_ff, layer->w_ff2,
            1, ffn_out, pre_act);
        free(norm2);
        free(pre_act);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += ffn_out[i];
        free(ffn_out);
    }

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

static int* generate_response(int *prompt_ids, int prompt_len, TransformerModel *model, double temperature, int max_tokens, int *out_len) {
    /* temperature controls sampling: < 0.01 = greedy argmax, otherwise top-k sampling
     * Returns a caller-owned int array of generated token IDs. Caller must free. */
    int vocab_size = model->config.vocab_size;
    int max_seq_len = model->config.max_seq_len;

    int *token_ids = calloc(max_seq_len * 4, sizeof(int));
    int num_tokens = prompt_len < max_seq_len ? prompt_len : max_seq_len;
    for (int i = 0; i < num_tokens; i++) {
        int tid = prompt_ids[i];
        if (tid < 0) tid = 0;
        if (tid >= vocab_size) tid = vocab_size - 1;
        token_ids[i] = tid;
    }

    int total_tokens = num_tokens;
    int *output_ids = calloc(max_tokens, sizeof(int));
    int output_count = 0;

    for (int step = 0; step < max_tokens; step++) {
        int ctx_start = total_tokens > max_seq_len ? total_tokens - max_seq_len : 0;
        int ctx_len = total_tokens - ctx_start;

        double *logits = calloc(vocab_size, sizeof(double));
        native_forward(token_ids + ctx_start, ctx_len, model, logits);

        int next_token;
        if (temperature < 0.01) {
            /* Greedy argmax */
            next_token = 0;
            double best = logits[0];
            for (int i = 1; i < vocab_size; i++) {
                if (logits[i] > best) { best = logits[i]; next_token = i; }
            }
        } else {
            /* Temperature-scaled top-k sampling */
            for (int i = 0; i < vocab_size; i++)
                logits[i] /= temperature;

            double max_l = logits[0];
            for (int i = 1; i < vocab_size; i++)
                if (logits[i] > max_l) max_l = logits[i];
            double sum = 0.0;
            for (int i = 0; i < vocab_size; i++) {
                logits[i] = exp(logits[i] - max_l);
                sum += logits[i];
            }
            for (int i = 0; i < vocab_size; i++)
                logits[i] /= sum;

            int top_k = 40;
            if (top_k > vocab_size) top_k = vocab_size;
            double probs_sorted[VOCAB_SIZE];
            memcpy(probs_sorted, logits, (size_t)vocab_size * sizeof(double));
            for (int j = 0; j < top_k; j++) {
                int max_idx = j;
                for (int i = j + 1; i < vocab_size; i++)
                    if (probs_sorted[i] > probs_sorted[max_idx]) max_idx = i;
                double tmp = probs_sorted[j];
                probs_sorted[j] = probs_sorted[max_idx];
                probs_sorted[max_idx] = tmp;
            }
            double threshold = probs_sorted[top_k - 1];
            double filtered_sum = 0.0;
            for (int i = 0; i < vocab_size; i++) {
                if (logits[i] < threshold) logits[i] = 0.0;
                filtered_sum += logits[i];
            }
            if (filtered_sum > 0.0) {
                for (int i = 0; i < vocab_size; i++)
                    logits[i] /= filtered_sum;
            }

            double r = (double)rand() / (double)RAND_MAX;
            double cumsum = 0.0;
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
    if (arg->data.list.items[1]->type == VAL_NUM) temperature = arg->data.list.items[1]->data.num;
    if (arg->data.list.items[2]->type == VAL_NUM) max_tokens = (int)arg->data.list.items[2]->data.num;

    if (!g_model.loaded) return make_list(0);

    int prompt_len = prompt_list->data.list.count;
    int *prompt_ids = calloc(prompt_len > 0 ? prompt_len : 1, sizeof(int));
    for (int i = 0; i < prompt_len; i++) {
        Value *v = prompt_list->data.list.items[i];
        prompt_ids[i] = (v->type == VAL_NUM) ? (int)v->data.num : 0;
    }

    int out_len = 0;
    int *output_ids = generate_response(prompt_ids, prompt_len, &g_model, temperature, max_tokens, &out_len);
    free(prompt_ids);

    Value *result = make_list(out_len);
    for (int i = 0; i < out_len; i++) {
        list_append(result, make_num((double)output_ids[i]));
    }
    free(output_ids);
    return result;
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
