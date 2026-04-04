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

static int is_whitespace(int c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static int is_common_token(int c) {
    return c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u' ||
           c == 't' || c == 'h' || c == 'n' || c == 's' || c == 'r' ||
           c == '.' || c == ',' || c == '!' || c == '?' || c == '\'' || c == ':';
}

static char* generate_response(const char *prompt, TransformerModel *model, double temperature, int max_tokens) {
    /* temperature controls sampling: < 0.01 = greedy argmax, otherwise top-k sampling */
    int vocab_size = model->config.vocab_size;
    int max_seq_len = model->config.max_seq_len;

    int prompt_len = strlen(prompt);
    int *token_ids = calloc(max_seq_len * 4, sizeof(int));
    int num_tokens = prompt_len < max_seq_len ? prompt_len : max_seq_len;
    for (int i = 0; i < num_tokens; i++) {
        token_ids[i] = ((unsigned char)prompt[i]) % vocab_size;
    }

    int total_tokens = num_tokens;
    char *output = calloc(max_tokens + 1, 1);
    int output_len = 0;

    int *token_counts = calloc(vocab_size, sizeof(int));

    for (int step = 0; step < max_tokens; step++) {
        int ctx_start = total_tokens > max_seq_len ? total_tokens - max_seq_len : 0;
        int ctx_len = total_tokens - ctx_start;

        double *logits = calloc(vocab_size, sizeof(double));
        native_forward(token_ids + ctx_start, ctx_len, model, logits);

        for (int i = 0; i < vocab_size; i++) {
            if (token_counts[i] > 0) {
                if (is_whitespace(i)) {
                } else if (is_common_token(i)) {
                    logits[i] -= 0.1 * token_counts[i];
                } else {
                    logits[i] -= 0.3 * token_counts[i];
                }
            }
        }

        int next_token;
        if (temperature < 0.01) {
            /* Greedy argmax — preserves original behavior */
            next_token = 0;
            double best = logits[0];
            for (int i = 1; i < vocab_size; i++) {
                if (logits[i] > best) { best = logits[i]; next_token = i; }
            }
        } else {
            /* Temperature-scaled top-k sampling.
             * rand() seeded via srand(time(NULL)) in main — adequate for
             * generation diversity, not cryptographic quality. */

            /* Scale logits by temperature */
            for (int i = 0; i < vocab_size; i++)
                logits[i] /= temperature;

            /* Stable softmax */
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

            /* Top-k filter (k=40).
             * probs_sorted is sized to VOCAB_SIZE (256) which equals byte-vocab.
             * If vocab_size ever becomes dynamic/larger, this must be heap-allocated. */
            int top_k = 40;
            if (top_k > vocab_size) top_k = vocab_size;
            double probs_sorted[VOCAB_SIZE];
            memcpy(probs_sorted, logits, (size_t)vocab_size * sizeof(double));
            /* Partial sort: move top_k largest to front */
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

            /* Weighted random sample */
            double r = (double)rand() / (double)RAND_MAX;
            double cumsum = 0.0;
            next_token = vocab_size - 1; /* fallback to last token */
            for (int i = 0; i < vocab_size; i++) {
                cumsum += logits[i];
                if (cumsum >= r) { next_token = i; break; }
            }
        }
        free(logits);

        token_counts[next_token]++;

        if (total_tokens < max_seq_len * 4) {
            token_ids[total_tokens++] = next_token;
        }

        if (next_token > 0 && next_token < 128) {
            output[output_len++] = (char)next_token;
        }

        if (next_token == '\n' || next_token == 0) break;
        if (output_len > 3 && (output[output_len-1] == '.' || output[output_len-1] == '!' || output[output_len-1] == '?')) {
            int sent_count = 0;
            for (int si = 0; si < output_len; si++) {
                if (output[si] == '.' || output[si] == '!' || output[si] == '?') sent_count++;
            }
            if (sent_count >= 3) break;
            if (output_len <= 18) break;

            double *peek_logits = calloc(vocab_size, sizeof(double));
            int peek_ctx_start = total_tokens > max_seq_len ? total_tokens - max_seq_len : 0;
            int peek_ctx_len = total_tokens - peek_ctx_start;
            native_forward(token_ids + peek_ctx_start, peek_ctx_len, model, peek_logits);
            double peek_max = peek_logits[0];
            for (int i = 1; i < vocab_size; i++) if (peek_logits[i] > peek_max) peek_max = peek_logits[i];
            double peek_sum = 0.0;
            for (int i = 0; i < vocab_size; i++) { peek_logits[i] = exp(peek_logits[i] - peek_max); peek_sum += peek_logits[i]; }
            double space_prob = peek_logits[' '] / peek_sum;
            free(peek_logits);
            if (space_prob < 0.3) break;
        }
    }
    free(token_counts);

    output[output_len] = '\0';
    free(token_ids);
    return output;
}

int g_model_age = 0;
int g_training_samples = 0;

Value* builtin_eigen_model_loaded(Value *arg) {
    (void)arg;
    return make_num(g_model.loaded ? 1 : 0);
}

Value* builtin_eigen_generate(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        fprintf(stderr, "eigen_generate: requires [prompt, temperature, max_tokens]\n");
        return make_str("");
    }
    const char *prompt = "";
    double temperature = 0.1;
    int max_tokens = 80;

    if (arg->data.list.items[0]->type == VAL_STR) prompt = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_NUM) temperature = arg->data.list.items[1]->data.num;
    if (arg->data.list.items[2]->type == VAL_NUM) max_tokens = (int)arg->data.list.items[2]->data.num;

    if (!g_model.loaded) return make_str("");

    char *response = generate_response(prompt, &g_model, temperature, max_tokens);
    Value *result = make_str(response ? response : "");
    free(response);
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
