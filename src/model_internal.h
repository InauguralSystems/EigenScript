/*
 * EigenScript Model Internal Header — types and cross-file declarations.
 * Not part of the public API. Only included by model_io.c, model_infer.c, model_train.c.
 */

#ifndef MODEL_INTERNAL_H
#define MODEL_INTERNAL_H

#include "eigenscript.h"

/* ---- Model types ---- */

#define MAX_LAYERS 8
#define MAX_SEQ_LEN 128
#define VOCAB_SIZE 64
#define MAX_D_MODEL 128
#define MAX_D_FF 512

typedef struct {
    int vocab_size;
    int d_model;
    int n_layers;
    int d_ff;
    int max_seq_len;
} ModelConfig;

typedef struct {
    double *w_q;
    double *w_k;
    double *w_v;
    double *w_o;
    double *w_ff1;
    double *w_ff2;
    double *ln1_gamma;
    double *ln1_beta;
    double *ln2_gamma;
    double *ln2_beta;
} TransformerLayer;

typedef struct {
    ModelConfig config;
    double *token_embeddings;
    double *output_proj;
    TransformerLayer layers[MAX_LAYERS];
    int loaded;
} TransformerModel;

typedef struct {
    double *layer_inputs;
    double *norm1_outputs;
    double *norm2_outputs;
    double *attn_probs;
    double *ffn_pre_act;
    double *post_attn_x;
    double *final_x;
    double *ln1_x_norm;
    double *ln1_std;
    double *ln2_x_norm;
    double *ln2_std;
    int seq_len;
} TrainingCache;

/* ---- Model globals ---- */

extern TransformerModel g_model;
extern int g_model_age;
extern int g_training_samples;

/* ---- Tiled matmul block size ---- */

#define NE_TILE_SIZE 32

/* ---- Cross-file kernel declarations ---- */

/* Public kernels — defined in model_infer.c, also used by eigenscript.c tensor builtins */
void ne_softmax_buf(double *data, int64_t rows, int64_t cols);
void ne_matmul_buf(double *a, int64_t a_rows, int64_t a_cols,
                   double *b, int64_t b_cols, double *out);

/* Internal kernels — defined in model_infer.c, used by model_train.c */
void ne_gelu_buf(double *data, int64_t size);
void ne_fused_attention_forward_buf(
    double *x, int64_t seq_len, int64_t d_model,
    double *wq, double *wk, double *wv, double *wo,
    double *out, double *attn_probs_out);
void ne_fused_ffn_forward_buf(
    double *x, int64_t seq_len, int64_t d_model,
    double *w1, int64_t d_ff, double *w2,
    int32_t use_gelu, double *out, double *pre_act_out);
void create_sinusoidal_pe(double *pe, int seq_len, int d_model);

/* ---- IO functions — defined in model_io.c ---- */

int load_model_weights(const char *path, TransformerModel *model);
int save_model_weights(const char *path, TransformerModel *model);
Value* json_obj_get(Value *obj, const char *key);

/* ---- Registration ---- */

void register_model_builtins(Env *env);

/* ---- Builtins — each file defines its own, registered by model_train.c ---- */

Value* builtin_eigen_model_load(Value *arg);
Value* builtin_model_save_weights(Value *arg);
Value* builtin_eigen_generate(Value *arg);
Value* builtin_eigen_model_loaded(Value *arg);
Value* builtin_eigen_model_info(Value *arg);
Value* builtin_native_train_step(Value *arg);

#endif
