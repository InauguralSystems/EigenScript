/*
 * EigenScript Model I/O — weight/config load-save.
 * JSON weight parser, model serialization, load/save builtins.
 */

#include "model_internal.h"

TransformerModel g_model = {0};

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
        else if (strcmp(key, "n_heads") == 0) { (void)val; /* legacy, ignored */ }
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
            printf("Config: vocab=%d d_model=%d n_layers=%d d_ff=%d\n",
                model->config.vocab_size, model->config.d_model,
                model->config.n_layers, model->config.d_ff);
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

int save_model_weights(const char *path, TransformerModel *model) {
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

    fprintf(f, "{\n\"config\": {\"vocab_size\": %d, \"d_model\": %d, \"n_layers\": %d, \"d_ff\": %d, \"max_seq_len\": %d},\n",
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
        char buf[1024];
        snprintf(buf, sizeof(buf),
            "{\"status\": \"loaded\", \"vocab_size\": %d, \"n_layers\": %d, \"d_model\": %d, \"d_ff\": %d, \"path\": \"%s\"}",
            g_model.config.vocab_size, g_model.config.n_layers, g_model.config.d_model, g_model.config.d_ff, path);
        return make_str(buf);
    } else {
        return make_str("{\"status\": \"error\", \"error\": \"Failed to load model weights\"}");
    }
}

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
