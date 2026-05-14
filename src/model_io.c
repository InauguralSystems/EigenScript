/*
 * EigenScript Model I/O — weight/config load-save.
 * JSON weight parser, model serialization, load/save builtins.
 */

#include "model_internal.h"

TransformerModel g_model = {0};

static void model_free_allocations(TransformerModel *model);

static Value* model_load_status_json(const char *path) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_fmt(&sb,
        "{\"status\": \"loaded\", \"vocab_size\": %d, \"n_layers\": %d, "
        "\"d_model\": %d, \"d_ff\": %d, \"path\": ",
        g_model.config.vocab_size, g_model.config.n_layers,
        g_model.config.d_model, g_model.config.d_ff);
    eigs_json_escape_string(&sb, path);
    strbuf_append_char(&sb, '}');
    Value *result = make_str(sb.data);
    strbuf_free(&sb);
    return result;
}

static Value* model_save_status_json(const char *path) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"status\": \"saved\", \"path\": ");
    eigs_json_escape_string(&sb, path);
    strbuf_append_fmt(&sb, ", \"model_age\": %d, \"training_samples\": %d}",
                      g_model_age, g_training_samples);
    Value *result = make_str(sb.data);
    strbuf_free(&sb);
    return result;
}

static Value* model_save_binary_status_json(const char *path) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"status\": \"saved\", \"format\": \"eigen\", \"path\": ");
    eigs_json_escape_string(&sb, path);
    strbuf_append_fmt(&sb,
        ", \"model_age\": %d, \"training_samples\": %d, \"has_observer\": %s}",
        g_model_age, g_training_samples,
        g_model.observer.data ? "true" : "false");
    Value *result = make_str(sb.data);
    strbuf_free(&sb);
    return result;
}

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

static int json_parse_1d_array(const char **p, float *out, int len) {
    json_skip_ws(p);
    if (**p != '[') return -1;
    (*p)++;
    for (int i = 0; i < len; i++) {
        json_skip_ws(p);
        if (**p == ']') break;
        out[i] = (float)json_parse_number(p);
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    json_skip_ws(p);
    if (**p == ']') (*p)++;
    return 0;
}

static int json_parse_2d_array(const char **p, float *out, int rows, int cols) {
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

static int model_config_valid(const ModelConfig *cfg, char *err, size_t err_len) {
    if (cfg->vocab_size <= 0 || cfg->vocab_size > VOCAB_SIZE) {
        snprintf(err, err_len, "vocab_size must be 1..%d", VOCAB_SIZE);
        return 0;
    }
    if (cfg->d_model <= 0 || cfg->d_model > MAX_D_MODEL) {
        snprintf(err, err_len, "d_model must be 1..%d", MAX_D_MODEL);
        return 0;
    }
    if (cfg->n_layers <= 0 || cfg->n_layers > MAX_LAYERS) {
        snprintf(err, err_len, "n_layers must be 1..%d", MAX_LAYERS);
        return 0;
    }
    if (cfg->d_ff <= 0 || cfg->d_ff > MAX_D_FF) {
        snprintf(err, err_len, "d_ff must be 1..%d", MAX_D_FF);
        return 0;
    }
    if (cfg->max_seq_len <= 0 || cfg->max_seq_len > MAX_SEQ_LEN) {
        snprintf(err, err_len, "max_seq_len must be 1..%d", MAX_SEQ_LEN);
        return 0;
    }
    return 1;
}

static int json_parse_config(const char **p, ModelConfig *cfg) {
    json_skip_ws(p);
    if (**p != '{') return -1;
    ModelConfig tmp = {0};
    (*p)++;
    while (**p && **p != '}') {
        json_skip_ws(p);
        char key[64];
        json_parse_string(p, key, sizeof(key));
        json_skip_ws(p);
        if (**p == ':') (*p)++;
        json_skip_ws(p);
        int val = (int)json_parse_number(p);
        if (val < 0) {
            fprintf(stderr, "model_load: rejecting out-of-range config %s=%d\n", key, val);
            return -1;
        }
        if (strcmp(key, "vocab_size") == 0) tmp.vocab_size = val;
        else if (strcmp(key, "d_model") == 0) tmp.d_model = val;
        else if (strcmp(key, "n_heads") == 0) { (void)val; /* legacy, ignored */ }
        else if (strcmp(key, "n_layers") == 0) tmp.n_layers = val;
        else if (strcmp(key, "d_ff") == 0) tmp.d_ff = val;
        else if (strcmp(key, "max_seq_len") == 0) tmp.max_seq_len = val;
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    if (**p == '}') (*p)++;
    char err[128];
    if (!model_config_valid(&tmp, err, sizeof(err))) {
        fprintf(stderr, "model_load: invalid config: %s\n", err);
        return -1;
    }
    *cfg = tmp;
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
            layer->w_q = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
            json_parse_2d_array(p, layer->w_q, d_model, d_model);
        } else if (strcmp(key, "w_k") == 0) {
            layer->w_k = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
            json_parse_2d_array(p, layer->w_k, d_model, d_model);
        } else if (strcmp(key, "w_v") == 0) {
            layer->w_v = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
            json_parse_2d_array(p, layer->w_v, d_model, d_model);
        } else if (strcmp(key, "w_o") == 0) {
            layer->w_o = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
            json_parse_2d_array(p, layer->w_o, d_model, d_model);
        } else if (strcmp(key, "w_ff1") == 0) {
            layer->w_ff1 = xcalloc_array(safe_size_mul(d_model, d_ff), sizeof(float));
            json_parse_2d_array(p, layer->w_ff1, d_model, d_ff);
        } else if (strcmp(key, "w_ff2") == 0) {
            layer->w_ff2 = xcalloc_array(safe_size_mul(d_ff, d_model), sizeof(float));
            json_parse_2d_array(p, layer->w_ff2, d_ff, d_model);
        } else if (strcmp(key, "ln1_gamma") == 0) {
            layer->ln1_gamma = xcalloc(d_model, sizeof(float));
            json_parse_1d_array(p, layer->ln1_gamma, d_model);
        } else if (strcmp(key, "ln1_beta") == 0) {
            layer->ln1_beta = xcalloc(d_model, sizeof(float));
            json_parse_1d_array(p, layer->ln1_beta, d_model);
        } else if (strcmp(key, "ln2_gamma") == 0) {
            layer->ln2_gamma = xcalloc(d_model, sizeof(float));
            json_parse_1d_array(p, layer->ln2_gamma, d_model);
        } else if (strcmp(key, "ln2_beta") == 0) {
            layer->ln2_beta = xcalloc(d_model, sizeof(float));
            json_parse_1d_array(p, layer->ln2_beta, d_model);
        } else {
            json_skip_value(p);
        }
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    if (**p == '}') (*p)++;

    /* Allocate ternary projections (populated by requantize_all_layers after load) */
    layer->w_q_tern = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
    layer->w_k_tern = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
    layer->w_v_tern = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
    layer->w_o_tern = xcalloc_array(safe_size_mul(d_model, d_model), sizeof(float));
    layer->w_ff1_tern = xcalloc_array(safe_size_mul(d_model, d_ff), sizeof(float));
    layer->w_ff2_tern = xcalloc_array(safe_size_mul(d_ff, d_model), sizeof(float));

    /* Allocate packed ternary buffers (2 bits per weight, 4 per byte) */
    int64_t n_m2 = (int64_t)d_model * d_model;
    int64_t n_mf = (int64_t)d_model * d_ff;
    int64_t n_fm = (int64_t)d_ff * d_model;
    layer->w_q_packed = xcalloc((n_m2 + 3) / 4, 1);
    layer->w_k_packed = xcalloc((n_m2 + 3) / 4, 1);
    layer->w_v_packed = xcalloc((n_m2 + 3) / 4, 1);
    layer->w_o_packed = xcalloc((n_m2 + 3) / 4, 1);
    layer->w_ff1_packed = xcalloc((n_mf + 3) / 4, 1);
    layer->w_ff2_packed = xcalloc((n_fm + 3) / 4, 1);

    return 0;
}

#define MODEL_FORMAT_VERSION 2

int load_model_weights(const char *path, TransformerModel *model) {
    /* Auto-detect format: .eigen starts with 'E', JSON starts with '{' */
    int fmt = detect_checkpoint_format(path);
    if (fmt == 'E') return load_model_eigen(path, model);

    #define MODEL_JSON_MAX_SIZE (256L * 1024 * 1024)  /* 256 MB cap for JSON models */

    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open model file: %s\n", path); return -1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0 || size > MODEL_JSON_MAX_SIZE) {
        fprintf(stderr, "Model file rejected: size %ld (max %ld)\n", size, MODEL_JSON_MAX_SIZE);
        fclose(f); return -1;
    }
    char *data = xmalloc(size + 1);
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

    int format_version = 0;
    model->weight_format = WEIGHT_FORMAT_TERNARY;  /* default for v2 models */
    while (*p && *p != '}') {
        json_skip_ws(&p);
        char key[64];
        json_parse_string(&p, key, sizeof(key));
        json_skip_ws(&p);
        if (*p == ':') p++;
        json_skip_ws(&p);

        if (strcmp(key, "format_version") == 0) {
            format_version = (int)json_parse_number(&p);
        } else if (strcmp(key, "weight_format") == 0) {
            char wf[64];
            json_parse_string(&p, wf, sizeof(wf));
            if (strcmp(wf, "fp32_dense") == 0) {
                model->weight_format = WEIGHT_FORMAT_FP32;
            } else {
                model->weight_format = WEIGHT_FORMAT_TERNARY;
            }
        } else if (strcmp(key, "config") == 0) {
            if (json_parse_config(&p, &model->config) != 0) {
                free(data);
                return -1;
            }
            printf("Config: vocab=%d d_model=%d n_layers=%d d_ff=%d\n",
                model->config.vocab_size, model->config.d_model,
                model->config.n_layers, model->config.d_ff);
            fflush(stdout);
        } else if (strcmp(key, "token_embeddings") == 0) {
            int vs = model->config.vocab_size;
            int dm = model->config.d_model;
            model->token_embeddings = xcalloc_array(safe_size_mul(vs, dm), sizeof(float));
            json_parse_2d_array(&p, model->token_embeddings, vs, dm);
        } else if (strcmp(key, "output_proj") == 0) {
            int dm = model->config.d_model;
            int vs = model->config.vocab_size;
            model->output_proj = xcalloc_array(safe_size_mul(dm, vs), sizeof(float));
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

    if (format_version != MODEL_FORMAT_VERSION) {
        fprintf(stderr,
            "Model format mismatch: file is version %d, runtime expects %d.\n"
            "  Version 0 models were byte-vocab; version 1 uses runtime token IDs.\n"
            "  Retrain or rebuild the checkpoint with the current runtime.\n",
            format_version, MODEL_FORMAT_VERSION);
        model->loaded = 0;
        return -1;
    }

    /* Project master FP32 weights to ternary for forward passes (if ternary format) */
    if (model->weight_format == WEIGHT_FORMAT_TERNARY) {
        requantize_all_layers(model);
    }

    model->loaded = 1;
    const char *wf_name = model->weight_format == WEIGHT_FORMAT_TERNARY
        ? "ternary-weight-only" : "fp32-dense";
    printf("Model loaded successfully: v%d (%s), %d layers, d_model=%d\n",
        format_version, wf_name, model->config.n_layers, model->config.d_model);
    fflush(stdout);
    return 0;
}

int save_model_weights(const char *path, TransformerModel *model) {
    int vs = model->config.vocab_size;
    int dm = model->config.d_model;
    int df = model->config.d_ff;
    int nl = model->config.n_layers;

    for (size_t i = 0; i < (size_t)vs * (size_t)dm; i++) {
        if (isnan(model->token_embeddings[i]) || isinf(model->token_embeddings[i])) {
            fprintf(stderr, "[save-guard] NaN/Inf detected in weights - REFUSING to save corrupted model\n");
            return -1;
        }
    }
    for (size_t i = 0; i < (size_t)dm * (size_t)vs; i++) {
        if (isnan(model->output_proj[i]) || isinf(model->output_proj[i])) {
            fprintf(stderr, "[save-guard] NaN/Inf detected in output_proj - REFUSING to save corrupted model\n");
            return -1;
        }
    }

    FILE *f = fopen(path, "w");
    if (!f) return -1;

    const char *wf_tag = model->weight_format == WEIGHT_FORMAT_TERNARY
        ? "ternary_weight_only" : "fp32_dense";
    fprintf(f, "{\n\"format_version\": %d,\n", MODEL_FORMAT_VERSION);
    fprintf(f, "\"weight_format\": \"%s\",\n", wf_tag);
    fprintf(f, "\"config\": {\"vocab_size\": %d, \"d_model\": %d, \"n_layers\": %d, \"d_ff\": %d, \"max_seq_len\": %d},\n",
        vs, dm, nl, df, model->config.max_seq_len);

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
        return model_load_status_json(path);
    } else {
        return make_str("{\"status\": \"error\", \"error\": \"Failed to load model weights\"}");
    }
}

Value* eigs_json_parse_value(const char *s, int *pos);

Value* json_obj_get(Value *obj, const char *key) {
    if (!obj) return NULL;
    if (obj->type == VAL_DICT) return dict_get(obj, key);
    if (obj->type != VAL_LIST) return NULL;
    for (int i = 0; i + 1 < obj->data.list.count; i += 2) {
        Value *k = obj->data.list.items[i];
        if (k && k->type == VAL_STR && strcmp(k->data.str, key) == 0) {
            return obj->data.list.items[i + 1];
        }
    }
    return NULL;
}

/* ================================================================
 * .eigen BINARY CHECKPOINT FORMAT
 *
 * Section-based binary format native to EigenScript's observer semantics.
 * Preserves observer state (entropy, dH, obs_age) per weight element.
 * ================================================================ */

/* Count total weight elements across all matrices in the model */
int model_total_weight_count(TransformerModel *model) {
    int vs = model->config.vocab_size;
    int dm = model->config.d_model;
    int df = model->config.d_ff;
    int nl = model->config.n_layers;
    char err[128];
    if (!model_config_valid(&model->config, err, sizeof(err))) return 0;

    size_t total = safe_size_mul((size_t)vs, (size_t)dm);       /* token_embeddings */
    total += safe_size_mul((size_t)dm, (size_t)vs);             /* output_proj */
    for (int l = 0; l < nl; l++) {
        total += 4 * safe_size_mul((size_t)dm, (size_t)dm);     /* w_q, w_k, w_v, w_o */
        total += safe_size_mul((size_t)dm, (size_t)df);
        total += safe_size_mul((size_t)df, (size_t)dm);
        total += 4 * (size_t)dm;                                /* ln1/ln2 gamma/beta */
    }
    if (total > (size_t)INT_MAX) return 0;
    return (int)total;
}

void observer_buffer_init(ObserverBuffer *obs, int total_elements) {
    if (total_elements <= 0) {
        obs->total_elements = 0;
        obs->data = NULL;
        return;
    }
    obs->total_elements = total_elements;
    obs->data = xcalloc_array(safe_size_mul((size_t)total_elements, 5), sizeof(double));
}

void observer_buffer_free(ObserverBuffer *obs) {
    if (obs->data) { free(obs->data); obs->data = NULL; }
    obs->total_elements = 0;
}

static void model_free_allocations(TransformerModel *model) {
    if (!model) return;
    free(model->token_embeddings);
    free(model->output_proj);
    for (int l = 0; l < MAX_LAYERS; l++) {
        TransformerLayer *layer = &model->layers[l];
        free(layer->w_q); free(layer->w_k); free(layer->w_v); free(layer->w_o);
        free(layer->w_ff1); free(layer->w_ff2);
        free(layer->w_q_tern); free(layer->w_k_tern); free(layer->w_v_tern); free(layer->w_o_tern);
        free(layer->w_ff1_tern); free(layer->w_ff2_tern);
        free(layer->w_q_packed); free(layer->w_k_packed); free(layer->w_v_packed); free(layer->w_o_packed);
        free(layer->w_ff1_packed); free(layer->w_ff2_packed);
        free(layer->ln1_gamma); free(layer->ln1_beta);
        free(layer->ln2_gamma); free(layer->ln2_beta);
    }
    observer_buffer_free(&model->observer);
    memset(model, 0, sizeof(*model));
}

/* Detect checkpoint format from first byte: 'E' for .eigen, '{' for JSON */
int detect_checkpoint_format(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    int ch = fgetc(f);
    fclose(f);
    return ch;
}

/* ---- .eigen Preamble (64 bytes) ---- */
typedef struct {
    char magic[6];          /* "EIGEN\n" */
    uint16_t format_version;
    uint32_t section_count;
    uint32_t weight_format;
    uint32_t flags;
    uint32_t model_age;
    uint32_t training_samples;
    char reserved[36];
} __attribute__((packed)) EigenPreamble;

/* ---- .eigen Section TOC entry (16 bytes) ---- */
typedef struct {
    uint32_t type;
    uint32_t flags;
    uint64_t offset;
} __attribute__((packed)) EigenSectionEntry;

#define EIGEN_MAX_SECTIONS 64

static int eigen_write_raw(FILE *f, const void *data, size_t size, size_t count) {
    if (count == 0) return 1;
    if (!data) return 0;
    return fwrite(data, size, count, f) == count;
}

static int eigen_write_floats(FILE *f, const float *data, size_t count) {
    return eigen_write_raw(f, data, sizeof(float), count);
}

static int eigen_read_raw(FILE *f, void *data, size_t size, size_t count) {
    if (count == 0) return 1;
    if (!data) return 0;
    return fread(data, size, count, f) == count;
}

static int eigen_file_size(FILE *f, long *size_out) {
    long cur = ftell(f);
    if (cur < 0) return 0;
    if (fseek(f, 0, SEEK_END) != 0) return 0;
    long size = ftell(f);
    if (size < 0) return 0;
    if (fseek(f, 0, SEEK_SET) != 0) return 0;
    *size_out = size;
    (void)cur;
    return 1;
}

static uint64_t eigen_section_end(EigenSectionEntry *toc, int index, int section_count, long file_size) {
    if (index + 1 < section_count) return toc[index + 1].offset;
    return (uint64_t)file_size;
}

static int eigen_read_section(FILE *f, void *data, size_t size, size_t count, uint64_t section_end) {
    size_t bytes = safe_size_mul(size, count);
    long pos = ftell(f);
    if (bytes == SIZE_MAX || pos < 0) return 0;
    if ((uint64_t)pos > section_end || bytes > section_end - (uint64_t)pos) return 0;
    return eigen_read_raw(f, data, size, count);
}

static int eigen_seek_section(FILE *f, uint64_t offset) {
    if (offset > (uint64_t)LONG_MAX) return 0;
    return fseek(f, (long)offset, SEEK_SET) == 0;
}

static int eigen_read_header(FILE *f, const char *path, EigenPreamble *preamble,
                             EigenSectionEntry **toc_out, long *file_size_out) {
    *toc_out = NULL;

    long file_size = 0;
    if (!eigen_file_size(f, &file_size)) {
        fprintf(stderr, "[eigen-load] Cannot stat checkpoint: %s\n", path);
        return -1;
    }
    if ((uint64_t)file_size < sizeof(EigenPreamble) + sizeof(EigenSectionEntry)) {
        fprintf(stderr, "[eigen-load] Checkpoint too small: %s\n", path);
        return -1;
    }
    if (!eigen_read_raw(f, preamble, sizeof(*preamble), 1)) {
        fprintf(stderr, "[eigen-load] Short preamble in %s\n", path);
        return -1;
    }
    if (memcmp(preamble->magic, EIGEN_MAGIC, EIGEN_MAGIC_LEN) != 0) {
        fprintf(stderr, "[eigen-load] Bad magic in %s\n", path);
        return -1;
    }
    if (preamble->format_version != EIGEN_FORMAT_VERSION) {
        fprintf(stderr, "[eigen-load] Version mismatch: file=%d, runtime=%d\n",
            preamble->format_version, EIGEN_FORMAT_VERSION);
        return -1;
    }
    if (preamble->section_count == 0 || preamble->section_count > EIGEN_MAX_SECTIONS) {
        fprintf(stderr, "[eigen-load] Invalid section count: %u\n", preamble->section_count);
        return -1;
    }
    if (preamble->weight_format != WEIGHT_FORMAT_FP32 &&
        preamble->weight_format != WEIGHT_FORMAT_TERNARY) {
        fprintf(stderr, "[eigen-load] Invalid weight format: %u\n", preamble->weight_format);
        return -1;
    }
    uint32_t allowed_flags = EIGEN_FLAG_HAS_OBSERVER |
                             EIGEN_FLAG_HAS_CORPUS_FP |
                             EIGEN_FLAG_HAS_HISTORY;
    if ((preamble->flags & ~allowed_flags) != 0) {
        fprintf(stderr, "[eigen-load] Unsupported flags: 0x%x\n", preamble->flags);
        return -1;
    }

    size_t toc_entries = (size_t)preamble->section_count + 1;
    size_t toc_bytes = safe_size_mul(toc_entries, sizeof(EigenSectionEntry));
    if (toc_bytes == SIZE_MAX ||
        (uint64_t)sizeof(EigenPreamble) + toc_bytes > (uint64_t)file_size) {
        fprintf(stderr, "[eigen-load] Truncated table of contents\n");
        return -1;
    }

    EigenSectionEntry *toc = xcalloc_array(toc_entries, sizeof(EigenSectionEntry));
    if (!eigen_read_raw(f, toc, sizeof(EigenSectionEntry), toc_entries)) {
        fprintf(stderr, "[eigen-load] Short table of contents\n");
        free(toc);
        return -1;
    }
    if (toc[preamble->section_count].type != EIGEN_SEC_SENTINEL) {
        fprintf(stderr, "[eigen-load] Missing TOC sentinel\n");
        free(toc);
        return -1;
    }

    uint64_t min_data_offset = (uint64_t)sizeof(EigenPreamble) + toc_bytes;
    uint64_t prev_offset = 0;
    for (uint32_t i = 0; i < preamble->section_count; i++) {
        uint64_t offset = toc[i].offset;
        if (offset < min_data_offset || offset >= (uint64_t)file_size) {
            fprintf(stderr, "[eigen-load] Invalid section offset: %llu\n",
                (unsigned long long)offset);
            free(toc);
            return -1;
        }
        if (i > 0 && offset <= prev_offset) {
            fprintf(stderr, "[eigen-load] Non-increasing section offset\n");
            free(toc);
            return -1;
        }
        prev_offset = offset;
    }

    *toc_out = toc;
    *file_size_out = file_size;
    return 0;
}

int save_model_eigen(const char *path, TransformerModel *model) {
    int vs = model->config.vocab_size;
    int dm = model->config.d_model;
    int df = model->config.d_ff;
    int nl = model->config.n_layers;
    char err[128];

    if (!model_config_valid(&model->config, err, sizeof(err))) {
        fprintf(stderr, "[eigen-save] Invalid model config: %s\n", err);
        return -1;
    }
    if (!model->token_embeddings || !model->output_proj) {
        fprintf(stderr, "[eigen-save] Missing required model arrays\n");
        return -1;
    }
    if (model->weight_format != WEIGHT_FORMAT_FP32 &&
        model->weight_format != WEIGHT_FORMAT_TERNARY) {
        fprintf(stderr, "[eigen-save] Invalid weight format: %d\n", model->weight_format);
        return -1;
    }

    /* NaN/Inf guard (same as JSON path) */
    for (int i = 0; i < vs * dm; i++) {
        if (isnan(model->token_embeddings[i]) || isinf(model->token_embeddings[i])) {
            fprintf(stderr, "[eigen-save] NaN/Inf in weights — REFUSING to save\n");
            return -1;
        }
    }
    for (int i = 0; i < dm * vs; i++) {
        if (isnan(model->output_proj[i]) || isinf(model->output_proj[i])) {
            fprintf(stderr, "[eigen-save] NaN/Inf in output_proj — REFUSING to save\n");
            return -1;
        }
    }

    FILE *f = fopen(path, "wb");
    if (!f) return -1;

    int has_observer = (model->observer.data != NULL && model->observer.total_elements > 0);
    int expected_observer = model_total_weight_count(model);
    if (has_observer && model->observer.total_elements != expected_observer) {
        fprintf(stderr, "[eigen-save] Observer buffer size mismatch\n");
        fclose(f);
        return -1;
    }

    /* Count sections: config + token_embed + output_proj + N layers + optional observer */
    int section_count = 3 + nl;
    if (has_observer) section_count++;
    EigenSectionEntry *toc = NULL;

    /* Write preamble (64 bytes) */
    EigenPreamble preamble;
    memset(&preamble, 0, sizeof(preamble));
    memcpy(preamble.magic, EIGEN_MAGIC, EIGEN_MAGIC_LEN);
    preamble.format_version = EIGEN_FORMAT_VERSION;
    preamble.section_count = section_count;
    preamble.weight_format = model->weight_format;
    preamble.flags = has_observer ? EIGEN_FLAG_HAS_OBSERVER : 0;
    preamble.model_age = g_model_age;
    preamble.training_samples = g_training_samples;
    if (!eigen_write_raw(f, &preamble, sizeof(preamble), 1)) goto fail;

    /* Reserve space for TOC (section_count + 1 sentinel entries) */
    int toc_entries = section_count + 1;
    long toc_start = ftell(f);
    toc = xcalloc(toc_entries, sizeof(EigenSectionEntry));
    if (!eigen_write_raw(f, toc, sizeof(EigenSectionEntry), (size_t)toc_entries)) {
        goto fail;
    }

    int sec_idx = 0;

    /* Section: Config (32 bytes) */
    toc[sec_idx].type = EIGEN_SEC_CONFIG;
    toc[sec_idx].flags = 0;
    toc[sec_idx].offset = ftell(f);
    sec_idx++;
    uint32_t config_data[8] = { vs, dm, nl, df, model->config.max_seq_len, 0, 0, 0 };
    if (!eigen_write_raw(f, config_data, sizeof(uint32_t), 8)) goto fail;

    /* Section: Token Embeddings */
    toc[sec_idx].type = EIGEN_SEC_TOKEN_EMBED;
    toc[sec_idx].flags = 0;
    toc[sec_idx].offset = ftell(f);
    sec_idx++;
    uint32_t embed_header[4] = { vs, dm, 0 /* fp32 */, 0 };
    if (!eigen_write_raw(f, embed_header, sizeof(uint32_t), 4)) goto fail;
    if (!eigen_write_floats(f, model->token_embeddings, (size_t)vs * (size_t)dm)) goto fail;

    /* Section: Output Projection */
    toc[sec_idx].type = EIGEN_SEC_OUTPUT_PROJ;
    toc[sec_idx].flags = 0;
    toc[sec_idx].offset = ftell(f);
    sec_idx++;
    uint32_t proj_header[4] = { dm, vs, 0, 0 };
    if (!eigen_write_raw(f, proj_header, sizeof(uint32_t), 4)) goto fail;
    if (!eigen_write_floats(f, model->output_proj, (size_t)dm * (size_t)vs)) goto fail;

    /* Sections: Layers */
    for (int l = 0; l < nl; l++) {
        TransformerLayer *layer = &model->layers[l];
        toc[sec_idx].type = EIGEN_SEC_LAYER;
        toc[sec_idx].flags = l;
        toc[sec_idx].offset = ftell(f);
        sec_idx++;

        uint32_t layer_header[2] = { l, model->weight_format };
        if (!eigen_write_raw(f, layer_header, sizeof(uint32_t), 2)) goto fail;

        /* Master fp32 weights */
        if (!eigen_write_floats(f, layer->w_q, (size_t)dm * (size_t)dm)) goto fail;
        if (!eigen_write_floats(f, layer->w_k, (size_t)dm * (size_t)dm)) goto fail;
        if (!eigen_write_floats(f, layer->w_v, (size_t)dm * (size_t)dm)) goto fail;
        if (!eigen_write_floats(f, layer->w_o, (size_t)dm * (size_t)dm)) goto fail;
        if (!eigen_write_floats(f, layer->w_ff1, (size_t)dm * (size_t)df)) goto fail;
        if (!eigen_write_floats(f, layer->w_ff2, (size_t)df * (size_t)dm)) goto fail;

        /* LayerNorm */
        if (!eigen_write_floats(f, layer->ln1_gamma, (size_t)dm)) goto fail;
        if (!eigen_write_floats(f, layer->ln1_beta, (size_t)dm)) goto fail;
        if (!eigen_write_floats(f, layer->ln2_gamma, (size_t)dm)) goto fail;
        if (!eigen_write_floats(f, layer->ln2_beta, (size_t)dm)) goto fail;

        /* Ternary cache */
        if (model->weight_format == WEIGHT_FORMAT_TERNARY) {
            float alphas[6] = {
                layer->w_q_alpha, layer->w_k_alpha, layer->w_v_alpha,
                layer->w_o_alpha, layer->w_ff1_alpha, layer->w_ff2_alpha
            };
            if (!eigen_write_raw(f, alphas, sizeof(float), 6)) goto fail;

            int64_t m2 = (int64_t)dm * dm;
            int64_t mf = (int64_t)dm * df;
            int64_t fm = (int64_t)df * dm;
            if (!eigen_write_raw(f, layer->w_q_packed, 1, (size_t)((m2 + 3) / 4))) goto fail;
            if (!eigen_write_raw(f, layer->w_k_packed, 1, (size_t)((m2 + 3) / 4))) goto fail;
            if (!eigen_write_raw(f, layer->w_v_packed, 1, (size_t)((m2 + 3) / 4))) goto fail;
            if (!eigen_write_raw(f, layer->w_o_packed, 1, (size_t)((m2 + 3) / 4))) goto fail;
            if (!eigen_write_raw(f, layer->w_ff1_packed, 1, (size_t)((mf + 3) / 4))) goto fail;
            if (!eigen_write_raw(f, layer->w_ff2_packed, 1, (size_t)((fm + 3) / 4))) goto fail;
        }
    }

    /* Section: Observer State */
    if (has_observer) {
        toc[sec_idx].type = EIGEN_SEC_OBSERVER;
        toc[sec_idx].flags = 0;
        toc[sec_idx].offset = ftell(f);
        sec_idx++;

        uint32_t obs_header[4] = { model->observer.total_elements, 5, 0, 0 };
        if (!eigen_write_raw(f, obs_header, sizeof(uint32_t), 4)) goto fail;
        if (!eigen_write_raw(f, model->observer.data, sizeof(double),
                (size_t)model->observer.total_elements * 5)) goto fail;
    }

    /* Sentinel */
    toc[sec_idx].type = EIGEN_SEC_SENTINEL;
    toc[sec_idx].flags = 0;
    toc[sec_idx].offset = 0;

    /* Rewrite TOC with correct offsets */
    if (fseek(f, toc_start, SEEK_SET) != 0) goto fail;
    if (!eigen_write_raw(f, toc, sizeof(EigenSectionEntry), (size_t)toc_entries)) goto fail;

    free(toc);
    if (fclose(f) != 0) return -1;

    fprintf(stderr, "[eigen-save] Saved .eigen checkpoint: %s (%d sections%s)\n",
        path, section_count, has_observer ? ", with observer" : "");
    return 0;

fail:
    free(toc);
    fclose(f);
    return -1;
}

int load_model_eigen(const char *path, TransformerModel *model) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open .eigen file: %s\n", path); return -1; }

    EigenPreamble preamble;
    EigenSectionEntry *toc = NULL;
    long file_size = 0;
    if (eigen_read_header(f, path, &preamble, &toc, &file_size) != 0) {
        fclose(f);
        return -1;
    }

    TransformerModel tmp = {0};
    tmp.weight_format = preamble.weight_format;

    int config_section = -1;
    for (uint32_t s = 0; s < preamble.section_count; s++) {
        if (toc[s].type == EIGEN_SEC_CONFIG) {
            config_section = (int)s;
            break;
        }
    }
    if (config_section < 0) goto fail;

    uint64_t config_end = eigen_section_end(toc, config_section, (int)preamble.section_count, file_size);
    if (!eigen_seek_section(f, toc[config_section].offset)) goto fail;
    uint32_t cfg[8];
    if (!eigen_read_section(f, cfg, sizeof(uint32_t), 8, config_end)) goto fail;

    tmp.config.vocab_size = (int)cfg[0];
    tmp.config.d_model = (int)cfg[1];
    tmp.config.n_layers = (int)cfg[2];
    tmp.config.d_ff = (int)cfg[3];
    tmp.config.max_seq_len = (int)cfg[4];
    char err[128];
    if (!model_config_valid(&tmp.config, err, sizeof(err))) {
        fprintf(stderr, "[eigen-load] Invalid config: %s\n", err);
        goto fail;
    }

    int vs = tmp.config.vocab_size;
    int dm = tmp.config.d_model;
    int nl = tmp.config.n_layers;
    int df = tmp.config.d_ff;
    int seen_token = 0;
    int seen_output = 0;
    int seen_observer = 0;
    int seen_layers[MAX_LAYERS] = {0};

    printf("Loading .eigen checkpoint: %s (%u sections)\n", path, preamble.section_count);
    printf("Config: vocab=%d d_model=%d n_layers=%d d_ff=%d\n", vs, dm, nl, df);
    fflush(stdout);

    for (uint32_t s = 0; s < preamble.section_count; s++) {
        uint64_t section_end = eigen_section_end(toc, (int)s, (int)preamble.section_count, file_size);
        if (!eigen_seek_section(f, toc[s].offset)) goto fail;

        switch (toc[s].type) {
        case EIGEN_SEC_CONFIG: {
            break;
        }
        case EIGEN_SEC_TOKEN_EMBED: {
            if (seen_token) goto fail;
            uint32_t hdr[4];
            if (!eigen_read_section(f, hdr, sizeof(uint32_t), 4, section_end)) goto fail;
            int rows = hdr[0], cols = hdr[1];
            if (rows != vs || cols != dm) goto fail;
            tmp.token_embeddings = xcalloc_array(safe_size_mul((size_t)rows, (size_t)cols), sizeof(float));
            if (!eigen_read_section(f, tmp.token_embeddings, sizeof(float),
                    (size_t)rows * (size_t)cols, section_end)) goto fail;
            seen_token = 1;
            break;
        }
        case EIGEN_SEC_OUTPUT_PROJ: {
            if (seen_output) goto fail;
            uint32_t hdr[4];
            if (!eigen_read_section(f, hdr, sizeof(uint32_t), 4, section_end)) goto fail;
            int rows = hdr[0], cols = hdr[1];
            if (rows != dm || cols != vs) goto fail;
            tmp.output_proj = xcalloc_array(safe_size_mul((size_t)rows, (size_t)cols), sizeof(float));
            if (!eigen_read_section(f, tmp.output_proj, sizeof(float),
                    (size_t)rows * (size_t)cols, section_end)) goto fail;
            seen_output = 1;
            break;
        }
        case EIGEN_SEC_LAYER: {
            if (toc[s].flags >= (uint32_t)nl) goto fail;
            int l = (int)toc[s].flags;
            if (seen_layers[l]) goto fail;
            TransformerLayer *layer = &tmp.layers[l];

            uint32_t lhdr[2];
            if (!eigen_read_section(f, lhdr, sizeof(uint32_t), 2, section_end)) goto fail;
            if (lhdr[0] != (uint32_t)l) goto fail;
            if (lhdr[1] != WEIGHT_FORMAT_FP32 && lhdr[1] != WEIGHT_FORMAT_TERNARY) goto fail;

            /* Allocate and read master fp32 weights */
            int64_t m2 = (int64_t)dm * dm;
            int64_t mf = (int64_t)dm * df;
            int64_t fm = (int64_t)df * dm;

            layer->w_q = xcalloc_array(safe_size_mul((size_t)dm, (size_t)dm), sizeof(float));
            layer->w_k = xcalloc_array(safe_size_mul((size_t)dm, (size_t)dm), sizeof(float));
            layer->w_v = xcalloc_array(safe_size_mul((size_t)dm, (size_t)dm), sizeof(float));
            layer->w_o = xcalloc_array(safe_size_mul((size_t)dm, (size_t)dm), sizeof(float));
            layer->w_ff1 = xcalloc_array(safe_size_mul((size_t)dm, (size_t)df), sizeof(float));
            layer->w_ff2 = xcalloc_array(safe_size_mul((size_t)df, (size_t)dm), sizeof(float));

            if (!eigen_read_section(f, layer->w_q, sizeof(float), (size_t)m2, section_end)) goto fail;
            if (!eigen_read_section(f, layer->w_k, sizeof(float), (size_t)m2, section_end)) goto fail;
            if (!eigen_read_section(f, layer->w_v, sizeof(float), (size_t)m2, section_end)) goto fail;
            if (!eigen_read_section(f, layer->w_o, sizeof(float), (size_t)m2, section_end)) goto fail;
            if (!eigen_read_section(f, layer->w_ff1, sizeof(float), (size_t)mf, section_end)) goto fail;
            if (!eigen_read_section(f, layer->w_ff2, sizeof(float), (size_t)fm, section_end)) goto fail;

            /* LayerNorm */
            layer->ln1_gamma = xcalloc(dm, sizeof(float));
            layer->ln1_beta = xcalloc(dm, sizeof(float));
            layer->ln2_gamma = xcalloc(dm, sizeof(float));
            layer->ln2_beta = xcalloc(dm, sizeof(float));
            if (!eigen_read_section(f, layer->ln1_gamma, sizeof(float), (size_t)dm, section_end)) goto fail;
            if (!eigen_read_section(f, layer->ln1_beta, sizeof(float), (size_t)dm, section_end)) goto fail;
            if (!eigen_read_section(f, layer->ln2_gamma, sizeof(float), (size_t)dm, section_end)) goto fail;
            if (!eigen_read_section(f, layer->ln2_beta, sizeof(float), (size_t)dm, section_end)) goto fail;

            /* Allocate ternary projections */
            layer->w_q_tern = xcalloc_array(safe_size_mul((size_t)dm, (size_t)dm), sizeof(float));
            layer->w_k_tern = xcalloc_array(safe_size_mul((size_t)dm, (size_t)dm), sizeof(float));
            layer->w_v_tern = xcalloc_array(safe_size_mul((size_t)dm, (size_t)dm), sizeof(float));
            layer->w_o_tern = xcalloc_array(safe_size_mul((size_t)dm, (size_t)dm), sizeof(float));
            layer->w_ff1_tern = xcalloc_array(safe_size_mul((size_t)dm, (size_t)df), sizeof(float));
            layer->w_ff2_tern = xcalloc_array(safe_size_mul((size_t)df, (size_t)dm), sizeof(float));

            /* Allocate packed buffers */
            layer->w_q_packed = xcalloc((m2 + 3) / 4, 1);
            layer->w_k_packed = xcalloc((m2 + 3) / 4, 1);
            layer->w_v_packed = xcalloc((m2 + 3) / 4, 1);
            layer->w_o_packed = xcalloc((m2 + 3) / 4, 1);
            layer->w_ff1_packed = xcalloc((mf + 3) / 4, 1);
            layer->w_ff2_packed = xcalloc((fm + 3) / 4, 1);

            /* Read ternary cache if present */
            if (lhdr[1] == WEIGHT_FORMAT_TERNARY) {
                float alphas[6];
                if (!eigen_read_section(f, alphas, sizeof(float), 6, section_end)) goto fail;
                layer->w_q_alpha = alphas[0];
                layer->w_k_alpha = alphas[1];
                layer->w_v_alpha = alphas[2];
                layer->w_o_alpha = alphas[3];
                layer->w_ff1_alpha = alphas[4];
                layer->w_ff2_alpha = alphas[5];

                if (!eigen_read_section(f, layer->w_q_packed, 1, (size_t)((m2 + 3) / 4), section_end)) goto fail;
                if (!eigen_read_section(f, layer->w_k_packed, 1, (size_t)((m2 + 3) / 4), section_end)) goto fail;
                if (!eigen_read_section(f, layer->w_v_packed, 1, (size_t)((m2 + 3) / 4), section_end)) goto fail;
                if (!eigen_read_section(f, layer->w_o_packed, 1, (size_t)((m2 + 3) / 4), section_end)) goto fail;
                if (!eigen_read_section(f, layer->w_ff1_packed, 1, (size_t)((mf + 3) / 4), section_end)) goto fail;
                if (!eigen_read_section(f, layer->w_ff2_packed, 1, (size_t)((fm + 3) / 4), section_end)) goto fail;
            }
            seen_layers[l] = 1;
            break;
        }
        case EIGEN_SEC_OBSERVER: {
            if (seen_observer) goto fail;
            uint32_t ohdr[4];
            if (!eigen_read_section(f, ohdr, sizeof(uint32_t), 4, section_end)) goto fail;
            int total = ohdr[0];
            int fields = ohdr[1];
            int expected = model_total_weight_count(&tmp);
            if (fields != 5 || total <= 0 || total != expected) goto fail;
            observer_buffer_init(&tmp.observer, total);
            if (!eigen_read_section(f, tmp.observer.data, sizeof(double), (size_t)total * 5, section_end)) goto fail;
            seen_observer = 1;
            fprintf(stderr, "[eigen-load] Restored observer state: %d elements\n", total);
            break;
        }
        default:
            /* Unknown section — skip */
            break;
        }
    }

    free(toc);
    fclose(f);
    toc = NULL;
    f = NULL;

    if (!seen_token || !seen_output) goto fail;
    for (int l = 0; l < nl; l++) {
        if (!seen_layers[l]) goto fail;
    }
    if ((preamble.flags & EIGEN_FLAG_HAS_OBSERVER) && !seen_observer) goto fail;
    if (!(preamble.flags & EIGEN_FLAG_HAS_OBSERVER) && seen_observer) goto fail;

    /* Re-quantize if ternary format (in case packed cache wasn't saved or master weights were updated) */
    if (tmp.weight_format == WEIGHT_FORMAT_TERNARY) {
        requantize_all_layers(&tmp);
    }

    tmp.loaded = 1;
    model_free_allocations(model);
    *model = tmp;
    g_model_age = preamble.model_age;
    g_training_samples = preamble.training_samples;

    const char *wf_name = model->weight_format == WEIGHT_FORMAT_TERNARY
        ? "ternary-weight-only" : "fp32-dense";
    printf("Model loaded successfully: .eigen v%d (%s), %d layers, d_model=%d\n",
        EIGEN_FORMAT_VERSION, wf_name, nl, dm);
    if (model->observer.data) {
        printf("Observer state: %d elements restored\n", model->observer.total_elements);
    }
    fflush(stdout);
    return 0;

fail:
    if (toc) free(toc);
    if (f) fclose(f);
    model_free_allocations(&tmp);
    return -1;
}

/* ---- .eigen builtins ---- */

Value* builtin_eigen_model_save_binary(Value *arg) {
    if (!arg || arg->type != VAL_STR || arg->data.str[0] == '\0') {
        return make_str("{\"status\": \"error\", \"error\": \"requires path string\"}");
    }
    if (!g_model.loaded) {
        return make_str("{\"status\": \"error\", \"error\": \"No model loaded\"}");
    }
    const char *path = arg->data.str;
    fprintf(stderr, "[eigen-save] Saving .eigen to: %s\n", path);

    int result = save_model_eigen(path, &g_model);
    if (result == 0) {
        return model_save_binary_status_json(path);
    }
    return make_str("{\"status\": \"error\", \"error\": \"Failed to save .eigen checkpoint\"}");
}

Value* builtin_eigen_checkpoint_info(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        return make_str("{\"status\": \"error\", \"error\": \"requires path string\"}");
    }
    const char *path = arg->data.str;
    int fmt = detect_checkpoint_format(path);
    if (fmt == 0) {
        return make_str("{\"status\": \"error\", \"error\": \"cannot open file\"}");
    }
    if (fmt != 'E') {
        return make_str("{\"status\": \"ok\", \"format\": \"json\"}");
    }

    FILE *f = fopen(path, "rb");
    if (!f) return make_str("{\"status\": \"error\"}");

    EigenPreamble preamble;
    EigenSectionEntry *toc = NULL;
    long file_size = 0;
    if (eigen_read_header(f, path, &preamble, &toc, &file_size) != 0) {
        fclose(f);
        return make_str("{\"status\": \"error\", \"error\": \"invalid eigen checkpoint\"}");
    }

    /* Find config section */
    int vs = 0, dm = 0, nl = 0, df = 0, ms = 0;
    for (int s = 0; s < (int)preamble.section_count; s++) {
        if (toc[s].type == EIGEN_SEC_CONFIG) {
            uint64_t section_end = eigen_section_end(toc, s, (int)preamble.section_count, file_size);
            if (!eigen_seek_section(f, toc[s].offset)) break;
            uint32_t cfg[8];
            if (!eigen_read_section(f, cfg, sizeof(uint32_t), 8, section_end)) break;
            vs = cfg[0]; dm = cfg[1]; nl = cfg[2]; df = cfg[3]; ms = cfg[4];
            break;
        }
    }
    free(toc);
    fclose(f);

    ModelConfig cfg = { vs, dm, nl, df, ms };
    char err[128];
    if (!model_config_valid(&cfg, err, sizeof(err))) {
        return make_str("{\"status\": \"error\", \"error\": \"invalid eigen config\"}");
    }

    char buf[1024];
    snprintf(buf, sizeof(buf),
        "{\"status\": \"ok\", \"format\": \"eigen\", \"version\": %d, "
        "\"sections\": %d, \"weight_format\": \"%s\", "
        "\"has_observer\": %s, "
        "\"model_age\": %d, \"training_samples\": %d, "
        "\"config\": {\"vocab_size\": %d, \"d_model\": %d, \"n_layers\": %d, \"d_ff\": %d, \"max_seq_len\": %d}}",
        preamble.format_version, preamble.section_count,
        preamble.weight_format == WEIGHT_FORMAT_TERNARY ? "ternary_weight_only" : "fp32_dense",
        (preamble.flags & EIGEN_FLAG_HAS_OBSERVER) ? "true" : "false",
        preamble.model_age, preamble.training_samples,
        vs, dm, nl, df, ms);
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
        return model_save_status_json(path);
    }
    return make_str("{\"status\": \"error\", \"error\": \"Failed to save model\"}");
}
