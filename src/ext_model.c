/*
 * EigenScript Model Extension — weight loader, inference, training, sanitization.
 * Compile with: -DEIGENSCRIPT_EXT_MODEL=1
 */

#include "eigenscript.h"
#include <pthread.h>

TransformerModel g_model = {0};

/* ================================================================
 * MODEL EXTENSION — weight loader, inference, training kernels
 * ================================================================ */

/* ---- JSON MODEL WEIGHT LOADER ---- */

static void json_skip_ws(const char **p) {
    while (**p == ' ' || **p == '\t' || **p == '\n' || **p == '\r') (*p)++;
}

static double json_parse_number(const char **p) {
    char *end;
    double val = strtod(*p, &end);
    *p = end;
    return val;
}

static void json_parse_string(const char **p, char *out, int max_len) {
    if (**p != '"') { out[0] = '\0'; return; }
    (*p)++;
    int i = 0;
    while (**p && **p != '"' && i < max_len - 1) {
        if (**p == '\\') { (*p)++; }
        out[i++] = **p;
        (*p)++;
    }
    out[i] = '\0';
    if (**p == '"') (*p)++;
}

static void json_skip_value(const char **p) {
    json_skip_ws(p);
    if (**p == '"') {
        (*p)++;
        while (**p && **p != '"') {
            if (**p == '\\') (*p)++;
            (*p)++;
        }
        if (**p == '"') (*p)++;
    } else if (**p == '{') {
        int depth = 1; (*p)++;
        while (**p && depth > 0) {
            if (**p == '{') depth++;
            else if (**p == '}') depth--;
            else if (**p == '"') { (*p)++; while (**p && **p != '"') { if (**p == '\\') (*p)++; (*p)++; } }
            (*p)++;
        }
    } else if (**p == '[') {
        int depth = 1; (*p)++;
        while (**p && depth > 0) {
            if (**p == '[') depth++;
            else if (**p == ']') depth--;
            else if (**p == '"') { (*p)++; while (**p && **p != '"') { if (**p == '\\') (*p)++; (*p)++; } }
            (*p)++;
        }
    } else if (**p == 't' || **p == 'f' || **p == 'n') {
        while (**p && **p != ',' && **p != '}' && **p != ']') (*p)++;
    } else {
        while (**p && **p != ',' && **p != '}' && **p != ']' && **p != ' ' && **p != '\n' && **p != '\r') (*p)++;
    }
}

static int json_parse_1d_array(const char **p, double *out, int len) {
    json_skip_ws(p);
    if (**p != '[') return -1;
    (*p)++;
    for (int i = 0; i < len; i++) {
        json_skip_ws(p);
        out[i] = json_parse_number(p);
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    json_skip_ws(p);
    if (**p == ']') (*p)++;
    return 0;
}

static int json_parse_2d_array(const char **p, double *out, int rows, int cols) {
    json_skip_ws(p);
    if (**p != '[') return -1;
    (*p)++;
    for (int r = 0; r < rows; r++) {
        json_skip_ws(p);
        json_parse_1d_array(p, out + r * cols, cols);
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    json_skip_ws(p);
    if (**p == ']') (*p)++;
    return 0;
}

static int json_parse_config(const char **p, ModelConfig *cfg) {
    json_skip_ws(p);
    if (**p != '{') return -1;
    (*p)++;
    while (**p && **p != '}') {
        json_skip_ws(p);
        char key[64];
        json_parse_string(p, key, sizeof(key));
        json_skip_ws(p);
        if (**p == ':') (*p)++;
        json_skip_ws(p);
        int val = (int)json_parse_number(p);
        if (strcmp(key, "vocab_size") == 0) cfg->vocab_size = val;
        else if (strcmp(key, "d_model") == 0) cfg->d_model = val;
        else if (strcmp(key, "n_heads") == 0) cfg->n_heads = val;
        else if (strcmp(key, "n_layers") == 0) cfg->n_layers = val;
        else if (strcmp(key, "d_ff") == 0) cfg->d_ff = val;
        else if (strcmp(key, "max_seq_len") == 0) cfg->max_seq_len = val;
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    if (**p == '}') (*p)++;
    return 0;
}

static int json_parse_layer(const char **p, TransformerLayer *layer, int d_model, int d_ff) {
    json_skip_ws(p);
    if (**p != '{') return -1;
    (*p)++;
    while (**p && **p != '}') {
        json_skip_ws(p);
        char key[64];
        json_parse_string(p, key, sizeof(key));
        json_skip_ws(p);
        if (**p == ':') (*p)++;
        json_skip_ws(p);

        if (strcmp(key, "w_q") == 0) {
            layer->w_q = calloc(d_model * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_q, d_model, d_model);
        } else if (strcmp(key, "w_k") == 0) {
            layer->w_k = calloc(d_model * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_k, d_model, d_model);
        } else if (strcmp(key, "w_v") == 0) {
            layer->w_v = calloc(d_model * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_v, d_model, d_model);
        } else if (strcmp(key, "w_o") == 0) {
            layer->w_o = calloc(d_model * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_o, d_model, d_model);
        } else if (strcmp(key, "w_ff1") == 0) {
            layer->w_ff1 = calloc(d_model * d_ff, sizeof(double));
            json_parse_2d_array(p, layer->w_ff1, d_model, d_ff);
        } else if (strcmp(key, "w_ff2") == 0) {
            layer->w_ff2 = calloc(d_ff * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_ff2, d_ff, d_model);
        } else if (strcmp(key, "ln1_gamma") == 0) {
            layer->ln1_gamma = calloc(d_model, sizeof(double));
            json_parse_1d_array(p, layer->ln1_gamma, d_model);
        } else if (strcmp(key, "ln1_beta") == 0) {
            layer->ln1_beta = calloc(d_model, sizeof(double));
            json_parse_1d_array(p, layer->ln1_beta, d_model);
        } else if (strcmp(key, "ln2_gamma") == 0) {
            layer->ln2_gamma = calloc(d_model, sizeof(double));
            json_parse_1d_array(p, layer->ln2_gamma, d_model);
        } else if (strcmp(key, "ln2_beta") == 0) {
            layer->ln2_beta = calloc(d_model, sizeof(double));
            json_parse_1d_array(p, layer->ln2_beta, d_model);
        } else {
            json_skip_value(p);
        }
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    if (**p == '}') (*p)++;
    return 0;
}

int load_model_weights(const char *path, TransformerModel *model) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open model file: %s\n", path); return -1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *data = malloc(size + 1);
    if (!data) { fclose(f); return -1; }
    size_t got = fread(data, 1, size, f);
    fclose(f);
    if ((long)got != size) { fprintf(stderr, "Short read on model file: got %zu of %ld bytes\n", got, size); free(data); return -1; }
    data[size] = '\0';

    printf("Model file loaded: %ld bytes\n", size);
    fflush(stdout);

    const char *p = data;
    json_skip_ws(&p);
    if (*p != '{') { free(data); return -1; }
    p++;

    while (*p && *p != '}') {
        json_skip_ws(&p);
        char key[64];
        json_parse_string(&p, key, sizeof(key));
        json_skip_ws(&p);
        if (*p == ':') p++;
        json_skip_ws(&p);

        if (strcmp(key, "config") == 0) {
            json_parse_config(&p, &model->config);
            printf("Config: vocab=%d d_model=%d n_heads=%d n_layers=%d d_ff=%d\n",
                model->config.vocab_size, model->config.d_model,
                model->config.n_heads, model->config.n_layers, model->config.d_ff);
            fflush(stdout);
        } else if (strcmp(key, "token_embeddings") == 0) {
            int vs = model->config.vocab_size;
            int dm = model->config.d_model;
            model->token_embeddings = calloc(vs * dm, sizeof(double));
            json_parse_2d_array(&p, model->token_embeddings, vs, dm);
        } else if (strcmp(key, "output_proj") == 0) {
            int dm = model->config.d_model;
            int vs = model->config.vocab_size;
            model->output_proj = calloc(dm * vs, sizeof(double));
            json_parse_2d_array(&p, model->output_proj, dm, vs);
        } else if (strcmp(key, "layers") == 0) {
            json_skip_ws(&p);
            if (*p == '[') {
                p++;
                for (int l = 0; l < model->config.n_layers && l < MAX_LAYERS; l++) {
                    json_skip_ws(&p);
                    json_parse_layer(&p, &model->layers[l], model->config.d_model, model->config.d_ff);
                    json_skip_ws(&p);
                    if (*p == ',') p++;
                }
                json_skip_ws(&p);
                if (*p == ']') p++;
            }
        } else {
            json_skip_value(&p);
        }
        json_skip_ws(&p);
        if (*p == ',') p++;
    }

    free(data);
    model->loaded = 1;
    printf("Model loaded successfully: %d layers, d_model=%d\n",
        model->config.n_layers, model->config.d_model);
    fflush(stdout);
    return 0;
}

/* ================================================================
 * NUMEIGS TENSOR KERNELS (STATICALLY INCLUDED)
 * ================================================================ */

#define NE_TILE_SIZE 32

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

static void ne_gelu_buf(double* data, int64_t size) {
    const double sqrt_2_over_pi = sqrt(2.0 / M_PI);
    for (int64_t i = 0; i < size; i++) {
        double x = data[i];
        data[i] = 0.5 * x * (1.0 + tanh(sqrt_2_over_pi * (x + 0.044715 * x * x * x)));
    }
}

static void ne_fused_attention_forward_buf(
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

static void ne_fused_ffn_forward_buf(
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

/* ================================================================
 * BACKWARD KERNELS (from NumEigs)
 * ================================================================ */

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

/* ================================================================
 * NATIVE INFERENCE PIPELINE
 * ================================================================ */

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

static void create_sinusoidal_pe(double *pe, int seq_len, int d_model) {
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

/* ================================================================
 * NATIVE TRAINING PIPELINE
 * ================================================================ */

int g_model_age = 0;
int g_training_samples = 0;

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

static int save_model_weights(const char *path, TransformerModel *model) {
    int vs = model->config.vocab_size;
    int dm = model->config.d_model;
    int df = model->config.d_ff;
    int nl = model->config.n_layers;

    for (int i = 0; i < vs * dm; i++) {
        if (isnan(model->token_embeddings[i]) || isinf(model->token_embeddings[i])) {
            fprintf(stderr, "[save-guard] NaN/Inf detected in weights - REFUSING to save corrupted model\n");
            return -1;
        }
    }
    for (int i = 0; i < dm * vs; i++) {
        if (isnan(model->output_proj[i]) || isinf(model->output_proj[i])) {
            fprintf(stderr, "[save-guard] NaN/Inf detected in output_proj - REFUSING to save corrupted model\n");
            return -1;
        }
    }

    FILE *f = fopen(path, "w");
    if (!f) return -1;

    fprintf(f, "{\n\"config\": {\"vocab_size\": %d, \"d_model\": %d, \"n_heads\": %d, \"n_layers\": %d, \"d_ff\": %d, \"max_seq_len\": %d},\n",
        vs, dm, model->config.n_heads, nl, df, model->config.max_seq_len);

    fprintf(f, "\"token_embeddings\": [\n");
    for (int i = 0; i < vs; i++) {
        fprintf(f, "[");
        for (int j = 0; j < dm; j++) {
            fprintf(f, "%.17g", model->token_embeddings[i * dm + j]);
            if (j < dm - 1) fprintf(f, ",");
        }
        fprintf(f, "]%s\n", i < vs - 1 ? "," : "");
    }
    fprintf(f, "],\n");

    fprintf(f, "\"output_proj\": [\n");
    for (int i = 0; i < dm; i++) {
        fprintf(f, "[");
        for (int j = 0; j < vs; j++) {
            fprintf(f, "%.17g", model->output_proj[i * vs + j]);
            if (j < vs - 1) fprintf(f, ",");
        }
        fprintf(f, "]%s\n", i < dm - 1 ? "," : "");
    }
    fprintf(f, "],\n");

    fprintf(f, "\"layers\": [\n");
    for (int l = 0; l < nl; l++) {
        TransformerLayer *layer = &model->layers[l];
        fprintf(f, "{\n");

        #define W2D(name, data, rows, cols) do { \
            fprintf(f, "\"%s\": [\n", name); \
            for (int _r = 0; _r < rows; _r++) { \
                fprintf(f, "["); \
                for (int _c = 0; _c < cols; _c++) { \
                    fprintf(f, "%.17g", data[_r * cols + _c]); \
                    if (_c < cols - 1) fprintf(f, ","); \
                } \
                fprintf(f, "]%s\n", _r < rows - 1 ? "," : ""); \
            } \
            fprintf(f, "]"); \
        } while(0)

        #define W1D(name, data, len) do { \
            fprintf(f, "\"%s\": [", name); \
            for (int _i = 0; _i < len; _i++) { \
                fprintf(f, "%.17g", data[_i]); \
                if (_i < len - 1) fprintf(f, ","); \
            } \
            fprintf(f, "]"); \
        } while(0)

        W2D("w_q", layer->w_q, dm, dm); fprintf(f, ",\n");
        W2D("w_k", layer->w_k, dm, dm); fprintf(f, ",\n");
        W2D("w_v", layer->w_v, dm, dm); fprintf(f, ",\n");
        W2D("w_o", layer->w_o, dm, dm); fprintf(f, ",\n");
        W2D("w_ff1", layer->w_ff1, dm, df); fprintf(f, ",\n");
        W2D("w_ff2", layer->w_ff2, df, dm); fprintf(f, ",\n");
        W1D("ln1_gamma", layer->ln1_gamma, dm); fprintf(f, ",\n");
        W1D("ln1_beta", layer->ln1_beta, dm); fprintf(f, ",\n");
        W1D("ln2_gamma", layer->ln2_gamma, dm); fprintf(f, ",\n");
        W1D("ln2_beta", layer->ln2_beta, dm); fprintf(f, "\n");

        #undef W2D
        #undef W1D

        fprintf(f, "}%s\n", l < nl - 1 ? "," : "");
    }
    fprintf(f, "]\n}\n");

    fclose(f);
    return 0;
}

/* Dead extract_json_string removed — replaced by json_path builtin */
/* Dead builtin_eigen_train removed — now in training.eigs via native_train_step_builtin */

/* DB block removed — now in ext_db.c (was line 2794) */

/* Dead builtin_model_save removed — now in training.eigs via model_save_weights */

Value* builtin_eigen_model_load(Value *arg) {
    const char *base_path = "";
    if (arg && arg->type == VAL_STR) base_path = arg->data.str;

    char live_path[512];
    const char *path = base_path;
    int base_len = strlen(base_path);
    if (base_len > 5 && strcmp(base_path + base_len - 5, ".json") == 0) {
        snprintf(live_path, sizeof(live_path), "%.*s_live.json", base_len - 5, base_path);
        FILE *f = fopen(live_path, "r");
        if (f) {
            fclose(f);
            path = live_path;
            fprintf(stderr, "[model-load] Found live weights: %s\n", live_path);
        } else {
            fprintf(stderr, "[model-load] No live weights, using locked baseline: %s\n", base_path);
        }
    }

    printf("Loading model from: %s\n", path);
    fflush(stdout);

    int result = load_model_weights(path, &g_model);

    if (result == 0) {
        char buf[1024];
        snprintf(buf, sizeof(buf),
            "{\"status\": \"loaded\", \"vocab_size\": %d, \"n_layers\": %d, \"d_model\": %d, \"d_ff\": %d, \"path\": \"%s\"}",
            g_model.config.vocab_size, g_model.config.n_layers, g_model.config.d_model, g_model.config.d_ff, path);
        return make_str(buf);
    } else {
        return make_str("{\"status\": \"error\", \"error\": \"Failed to load model weights\"}");
    }
}

static int g_conversation_count = 0;

static const char *g_common_words[] = {
    "i", "a", "am", "an", "as", "at", "be", "by", "do", "go", "he", "if",
    "in", "is", "it", "me", "my", "no", "of", "on", "or", "so", "to", "up",
    "us", "we", "the", "and", "for", "are", "but", "not", "you", "all", "any",
    "can", "had", "has", "her", "him", "his", "how", "its", "may", "new",
    "now", "old", "our", "out", "own", "say", "she", "too", "two", "use",
    "who", "why", "yes", "was", "did", "get", "got", "let", "put", "run",
    "set", "try", "way", "day", "man", "big", "see", "ask", "own",
    "hello", "hi", "hey", "thanks", "thank", "good", "well", "help", "know",
    "like", "just", "about", "doing", "great", "here", "name", "what", "your",
    "been", "come", "each", "find", "from", "gave", "have", "keep", "last",
    "long", "look", "made", "many", "more", "much", "must", "need", "only",
    "over", "said", "some", "take", "tell", "than", "that", "them", "then",
    "they", "this", "time", "very", "want", "were", "will", "with", "work",
    "year", "eigen", "sure", "feel", "fine", "glad", "happy", "real",
    "haha", "lol", "nice", "cool", "love", "best", "also", "back", "give",
    "goodbye", "bye", "morning", "evening", "night", "welcome", "sorry",
    "joke", "funny", "laugh", "smart", "learn", "chat", "talk", "answer",
    "question", "wonder", "today", "tomorrow", "yesterday", "life",
    "make", "most", "such", "used", "call", "first", "could", "would",
    "should", "being", "after", "other", "still", "thing", "think", "those",
    "where", "which", "while", "world", "right", "never", "every",
    "doing", "there", "their", "these", "might", "quite", "really",
    "please", "always", "people", "thanks", "don",
    "ai", "eigenscript", "observermodel", "observeranalyzer", "observe",
    "observation", "observations", "observer", "effect", "geometry", "geometric",
    "watch", "step", "result", "final", "measure", "changed",
    "track", "happen", "state", "output", "changes", "language",
    "finds", "models", "model", "mode", "strict", "endpoint", "holonomy",
    "temporal", "when", "things", "jon", "mcreynolds",
    "maker", "creator", "trained", "knowledge", "settled", "stable",
    "converged", "diverges", "drift", "identity", "native", "persist",
    "remain", "repetition", "self-observation", "myself", "nothing",
    "something", "else", "exist", "holds", "does", "change",
    "alexa", "siri", "chatgpt", NULL
};

static void sanitize_input(char *str) {
    int r = 0, w = 0;
    while (str[r]) {
        unsigned char c = (unsigned char)str[r];
        if (c >= 0x20 && c <= 0x7E) {
            str[w++] = str[r];
        }
        r++;
    }
    str[w] = '\0';
    int start = 0;
    while (str[start] == ' ') start++;
    if (start > 0) {
        int i = 0;
        while (str[start + i]) { str[i] = str[start + i]; i++; }
        str[i] = '\0';
        w = i;
    }
    while (w > 0 && str[w - 1] == ' ') str[--w] = '\0';
}

/* is_trained_prompt — extracted to prompts.eigs */

/* Deflection guard (check_deflection, is_self_prompt, is_content_prompt,
 * is_identity_token) — extracted to guards.eigs */

static int is_known_word(const char *word, int wlen) {
    char lower[64];
    if (wlen >= 64) return 0;
    for (int i = 0; i < wlen; i++) {
        lower[i] = (word[i] >= 'A' && word[i] <= 'Z') ? word[i] + 32 : word[i];
        if (lower[i] == '.' || lower[i] == ',' || lower[i] == '!' ||
            lower[i] == '?' || lower[i] == '\'' || lower[i] == '"') {
            wlen = i;
            break;
        }
    }
    lower[wlen] = '\0';
    if (wlen == 0) return 1;

    for (int i = 0; g_common_words[i]; i++) {
        if (strcmp(lower, g_common_words[i]) == 0) return 1;
    }
    return 0;
}

static int is_garble_response(const char *text) {
    if (!text || text[0] == '\0') return 1;
    int len = strlen(text);
    if (len < 2) return 1;

    int control = 0;
    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c < 0x20 && c != '\t' && c != '\n') control++;
    }
    if (control > 0) return 1;

    int alpha = 0;
    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) alpha++;
    }
    if (len > 0 && (alpha * 100 / len) < 40) return 1;

    int repeated = 0;
    for (int i = 1; i < len; i++) {
        if (text[i] == text[i-1] && text[i] != ' ') repeated++;
    }
    if (len > 4 && (repeated * 100 / len) > 40) return 1;

    int words = 0, known = 0, known_3plus = 0, unknown_count = 0;
    int in_word = 0;
    int word_start = 0;
    for (int i = 0; i <= len; i++) {
        if (i < len && text[i] != ' ' && text[i] != '\t' && text[i] != '\n') {
            if (!in_word) { in_word = 1; word_start = i; }
        } else {
            if (in_word) {
                int wlen = i - word_start;
                int plen = wlen;
                for (int j = 0; j < wlen; j++) {
                    char c = text[word_start + j];
                    if (c == '.' || c == ',' || c == '!' || c == '?') { plen = j; break; }
                }
                words++;
                if (is_known_word(text + word_start, wlen)) {
                    known++;
                    if (plen >= 3) known_3plus++;
                } else {
                    unknown_count++;
                }
                in_word = 0;
            }
        }
    }

    if (words == 0) return 1;
    if (words == 1 && known == 1) return 0;
    if (words == 1 && known == 0) return 1;

    if (words <= 4 && known_3plus == 0 && unknown_count > 0) return 1;

    if (words >= 2 && unknown_count > 0 && known_3plus < 2) return 1;

    int match_pct = (known * 100) / words;
    if (match_pct < 60) return 1;

    return 0;
}

/* Dead replay buffer removed — training now orchestrated by .eigs modules */

Value* eigs_json_parse_value(const char *s, int *pos);

Value* json_obj_get(Value *obj, const char *key) {
    if (!obj || obj->type != VAL_LIST) return NULL;
    for (int i = 0; i + 1 < obj->data.list.count; i += 2) {
        Value *k = obj->data.list.items[i];
        if (k && k->type == VAL_STR && strcmp(k->data.str, key) == 0) {
            return obj->data.list.items[i + 1];
        }
    }
    return NULL;
}

/* call_openai_fallback — extracted to chat.eigs (uses http_post + json_path) */

/* Dead monolithic eigen_hybrid_chat removed (264 lines) — now in chat.eigs */


Value* builtin_eigen_check_openai(Value *arg) {
    (void)arg;
    const char *key = getenv("AI_INTEGRATIONS_OPENAI_API_KEY");
    if (!key || !key[0]) key = getenv("OPENAI_API_KEY");
    if (key && key[0]) {
        fprintf(stderr, "OpenAI fallback: ENABLED (API key found)\n");
        return make_str("{\"available\": true}");
    }
    fprintf(stderr, "WARNING: OpenAI fallback DISABLED - no API key configured (set AI_INTEGRATIONS_OPENAI_API_KEY or OPENAI_API_KEY)\n");
    return make_str("{\"available\": false}");
}

/* Dead community_stats builtin removed — now in admin.eigs */


#if EIGENSCRIPT_EXT_MODEL && EIGENSCRIPT_EXT_DB
Value* builtin_eigen_export_corpus(Value *arg) {
    (void)arg;
    if (!g_db_conn) return make_str("{\"status\": \"error\", \"error\": \"Database not connected\"}");

    PGresult *res = PQexec(g_db_conn,
        "SELECT user_message, bot_response, inference_mode FROM conversations "
        "WHERE used_for_training = false AND bot_response != '' AND bot_response != 'I don''t know about that yet.' "
        "ORDER BY id ASC");

    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        char buf[512];
        snprintf(buf, sizeof(buf), "{\"status\": \"error\", \"error\": \"%s\"}", PQerrorMessage(g_db_conn));
        PQclear(res);
        return make_str(buf);
    }

    int nrows = PQntuples(res);
    if (nrows == 0) {
        PQclear(res);
        return make_str("{\"status\": \"ok\", \"exported\": 0, \"message\": \"No new conversations to export\"}");
    }

    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char filename[256];
    snprintf(filename, sizeof(filename), "../../corpus/community/export_%04d%02d%02d_%02d%02d%02d.json",
        t->tm_year + 1900, t->tm_mon + 1, t->tm_mday, t->tm_hour, t->tm_min, t->tm_sec);

    int buf_size = nrows * 1024 + 4096;
    if (buf_size < 65536) buf_size = 65536;
    char *json_buf = calloc(buf_size, 1);
    int pos = 0;
    pos += snprintf(json_buf + pos, buf_size - pos, "[\n");

    int native_count = 0, fallback_count = 0, exported = 0, skipped = 0;
    for (int i = 0; i < nrows; i++) {
        if (pos >= buf_size - 2048) { skipped = nrows - i; break; }
        const char *msg = PQgetvalue(res, i, 0);
        const char *resp = PQgetvalue(res, i, 1);
        const char *mode = PQgetvalue(res, i, 2);

        if (!msg || !resp || msg[0] == '\0' || resp[0] == '\0') continue;
        if (strlen(msg) < 2 || strlen(resp) < 2) continue;

        if (exported > 0) pos += snprintf(json_buf + pos, buf_size - pos, ",\n");

        char esc_msg[2048] = {0};
        int em = 0;
        for (int j = 0; msg[j] && em < 2040; j++) {
            if (msg[j] == '"') { esc_msg[em++] = '\\'; esc_msg[em++] = '"'; }
            else if (msg[j] == '\\') { esc_msg[em++] = '\\'; esc_msg[em++] = '\\'; }
            else if (msg[j] == '\n') { esc_msg[em++] = '\\'; esc_msg[em++] = 'n'; }
            else if (msg[j] == '\t') { esc_msg[em++] = '\\'; esc_msg[em++] = 't'; }
            else if ((unsigned char)msg[j] >= 0x20) esc_msg[em++] = msg[j];
        }

        char esc_resp[4096] = {0};
        int er = 0;
        for (int j = 0; resp[j] && er < 4088; j++) {
            if (resp[j] == '"') { esc_resp[er++] = '\\'; esc_resp[er++] = '"'; }
            else if (resp[j] == '\\') { esc_resp[er++] = '\\'; esc_resp[er++] = '\\'; }
            else if (resp[j] == '\n') { esc_resp[er++] = '\\'; esc_resp[er++] = 'n'; }
            else if (resp[j] == '\t') { esc_resp[er++] = '\\'; esc_resp[er++] = 't'; }
            else if ((unsigned char)resp[j] >= 0x20) esc_resp[er++] = resp[j];
        }

        pos += snprintf(json_buf + pos, buf_size - pos,
            "  {\"input\": \"%s\", \"target\": \"%s\", \"source\": \"%s\"}",
            esc_msg, esc_resp, mode);

        if (strcmp(mode, "native") == 0) native_count++;
        else fallback_count++;
        exported++;
    }
    pos += snprintf(json_buf + pos, buf_size - pos, "\n]\n");

    FILE *f = fopen(filename, "w");
    if (!f) {
        free(json_buf);
        PQclear(res);
        return make_str("{\"status\": \"error\", \"error\": \"Could not write export file\"}");
    }
    fputs(json_buf, f);
    fclose(f);
    free(json_buf);

    PGresult *upd = PQexec(g_db_conn,
        "UPDATE conversations SET used_for_training = true "
        "WHERE used_for_training = false AND bot_response != '' AND bot_response != 'I don''t know about that yet.'");
    if (upd) PQclear(upd);

    PQclear(res);

    const char *short_name = strrchr(filename, '/');
    if (short_name) short_name++; else short_name = filename;

    char result[1024];
    snprintf(result, sizeof(result),
        "{\"status\": \"ok\", \"exported\": %d, \"native\": %d, \"openai_fallback\": %d, \"skipped\": %d, \"filename\": \"%s\"}",
        exported, native_count, fallback_count, skipped, short_name);
    return make_str(result);
}

/* SHA256 moved to ext_db.c */

/* ================================================================
 * API Key Management
 * ================================================================ */

/* ensure_api_keys_table moved to ext_db.c */

/* Dead monolithic API key builtins removed — now in admin.eigs */
#endif /* EIGENSCRIPT_EXT_MODEL && EIGENSCRIPT_EXT_DB — export_corpus */

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

Value* builtin_eigen_sanitize(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    char *buf = strdup(arg->data.str);
    sanitize_input(buf);
    Value *result = make_str(buf);
    free(buf);
    return result;
}

Value* builtin_eigen_clean_response(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");

    char *clean = strdup(arg->data.str);
    int clen = strlen(clean);

    /* Trim at "User:" marker */
    char *user_marker = strstr(clean, "User:");
    if (user_marker) { *user_marker = '\0'; clen = strlen(clean); }

    /* Trim leading whitespace */
    char *start = clean;
    while (*start == ' ' || *start == '\t' || *start == '\n') start++;

    /* Trim trailing whitespace */
    clen = strlen(start);
    while (clen > 0 && (start[clen-1] == ' ' || start[clen-1] == '\n')) start[--clen] = '\0';

    /* Find last good sentence boundary (same logic as builtin_eigen_hybrid_chat lines 3636-3678) */
    int last_good = -1;
    for (int i = clen - 1; i > 5; i--) {
        if (start[i] == '.' || start[i] == '!' || start[i] == '?') {
            int prev_end = -1;
            for (int j = i - 1; j >= 0; j--) {
                if (start[j] == '.' || start[j] == '!' || start[j] == '?') { prev_end = j; break; }
            }
            int seg_len = i - prev_end;
            if (prev_end == -1) { last_good = i; break; }
            if (seg_len >= 10) {
                int seg_start = prev_end + 1;
                int word_count = 0, total_word_chars = 0, wl = 0;
                for (int k = seg_start; k <= i; k++) {
                    char ch = start[k];
                    if (ch == ' ' || ch == '.' || ch == '!' || ch == '?') {
                        if (wl > 0) { word_count++; total_word_chars += wl; wl = 0; }
                    } else { wl++; }
                }
                if (wl > 0) { word_count++; total_word_chars += wl; }
                double avg_wl = word_count > 0 ? (double)total_word_chars / word_count : 0;
                if (avg_wl >= 3.0) { last_good = i; break; }
            }
        }
    }
    if (last_good > 5 && last_good < clen - 1) {
        if (last_good + 1 >= 20) {
            start[last_good + 1] = '\0';
        }
    }

    Value *result = make_str(start);
    free(clean);
    return result;
}

Value* builtin_eigen_is_garble(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(1);
    return make_num(is_garble_response(arg->data.str) ? 1 : 0);
}

/* eigen_is_trained_prompt — extracted to prompts.eigs */

/* eigen_check_deflection_v2 — extracted to guards.eigs */

/* eigen_check_identity — extracted to guards.eigs */

/* eigen_openai_chat — extracted to chat.eigs (uses http_post + json_path) */

/* eigen_db_insert_conversation — extracted to chat.eigs (uses db_execute) */

Value* builtin_eigen_conversation_count(Value *arg) {
    (void)arg;
    return make_num(g_conversation_count);
}

/* eigen_extract_message — replaced by json_path in .eigs */
/* eigen_build_chat_response — extracted to chat.eigs */
/* eigen_extract_json_field — replaced by json_path in .eigs */

/* ================================================================
 * THIN TRAINING/MODEL BUILTINS — core platform capabilities
 * ================================================================ */

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

Value* builtin_model_save_weights(Value *arg) {
    /* Thin wrapper around save_model_weights().
     * Input: path (string)
     * Output: JSON status */
    if (!arg || arg->type != VAL_STR || arg->data.str[0] == '\0') {
        return make_str("{\"status\": \"error\", \"error\": \"requires path string\"}");
    }
    const char *path = arg->data.str;
    fprintf(stderr, "[model-save] Saving to: %s\n", path);

    int result = save_model_weights(path, &g_model);
    if (result == 0) {
        char buf[512];
        snprintf(buf, sizeof(buf),
            "{\"status\": \"saved\", \"path\": \"%s\", \"model_age\": %d, \"training_samples\": %d}",
            path, g_model_age, g_training_samples);
        return make_str(buf);
    }
    return make_str("{\"status\": \"error\", \"error\": \"Failed to save model\"}");
}

Value* builtin_model_load_weights(Value *arg) {
    /* Thin wrapper around load_model_weights().
     * Input: path (string) — checks for _live.json variant automatically
     * Output: JSON status with model config */
    if (!arg || arg->type != VAL_STR || arg->data.str[0] == '\0') {
        return make_str("{\"status\": \"error\", \"error\": \"requires path string\"}");
    }
    const char *base_path = arg->data.str;
    char live_path[512];
    const char *path = base_path;

    /* Check for _live.json variant */
    int base_len = strlen(base_path);
    if (base_len > 5 && strcmp(base_path + base_len - 5, ".json") == 0) {
        snprintf(live_path, sizeof(live_path), "%.*s_live.json", base_len - 5, base_path);
        FILE *f = fopen(live_path, "r");
        if (f) {
            fclose(f);
            path = live_path;
            fprintf(stderr, "[model-load] Found live weights: %s\n", live_path);
        } else {
            fprintf(stderr, "[model-load] No live weights, using: %s\n", base_path);
        }
    }

    fprintf(stderr, "[model-load] Loading from: %s\n", path);
    int result = load_model_weights(path, &g_model);
    if (result == 0) {
        char buf[1024];
        snprintf(buf, sizeof(buf),
            "{\"status\": \"loaded\", \"vocab_size\": %d, \"n_layers\": %d, \"d_model\": %d, \"d_ff\": %d, \"path\": \"%s\"}",
            g_model.config.vocab_size, g_model.config.n_layers, g_model.config.d_model, g_model.config.d_ff, path);
        return make_str(buf);
    }
    return make_str("{\"status\": \"error\", \"error\": \"Failed to load model weights\"}");
}

/* builtin_file_exists moved to core section (always available) */

/* ================================================================
 * THIN PLATFORM BUILTINS — model info
 * ================================================================ */

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

/* builtin_env_get moved to core section (always available) */


void register_model_builtins(Env *env) {
    /* ---- Model/inference extension ---- */
    env_set_local(env, "eigen_model_loaded", make_builtin(builtin_eigen_model_loaded));
    env_set_local(env, "eigen_generate", make_builtin(builtin_eigen_generate));
    env_set_local(env, "eigen_sanitize", make_builtin(builtin_eigen_sanitize));
    env_set_local(env, "eigen_clean_response", make_builtin(builtin_eigen_clean_response));
    env_set_local(env, "eigen_is_garble", make_builtin(builtin_eigen_is_garble));
    env_set_local(env, "eigen_conversation_count", make_builtin(builtin_eigen_conversation_count));
    env_set_local(env, "eigen_model_info", make_builtin(builtin_eigen_model_info));
    env_set_local(env, "native_train_step_builtin", make_builtin(builtin_native_train_step));
    env_set_local(env, "model_save_weights", make_builtin(builtin_model_save_weights));
    env_set_local(env, "model_load_weights", make_builtin(builtin_model_load_weights));
    env_set_local(env, "eigen_model_load", make_builtin(builtin_eigen_model_load));
    env_set_local(env, "eigen_check_openai", make_builtin(builtin_eigen_check_openai));
}
