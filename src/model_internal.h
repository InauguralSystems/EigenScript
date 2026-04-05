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
    /* Master FP32 weights — updated by backprop, saved to JSON */
    float *w_q;
    float *w_k;
    float *w_v;
    float *w_o;
    float *w_ff1;
    float *w_ff2;
    /* Ternary projections — refreshed from master after every update.
     * Values are in {-alpha, 0, +alpha} per matrix (BitNet b1.58 style).
     * Used for backward passes (gradient flow through straight-through estimator). */
    float *w_q_tern;
    float *w_k_tern;
    float *w_v_tern;
    float *w_o_tern;
    float *w_ff1_tern;
    float *w_ff2_tern;
    /* Packed ternary — 2 bits per weight (4 weights per byte).
     * Used for forward passes. Encoding: 00=zero, 01=+1, 11=-1, 10=unused.
     * alpha is the per-matrix scale: effective weight = code_sign * alpha. */
    uint8_t *w_q_packed;
    uint8_t *w_k_packed;
    uint8_t *w_v_packed;
    uint8_t *w_o_packed;
    uint8_t *w_ff1_packed;
    uint8_t *w_ff2_packed;
    float w_q_alpha;
    float w_k_alpha;
    float w_v_alpha;
    float w_o_alpha;
    float w_ff1_alpha;
    float w_ff2_alpha;
    /* LayerNorm params stay FP32, no ternary projection */
    float *ln1_gamma;
    float *ln1_beta;
    float *ln2_gamma;
    float *ln2_beta;
} TransformerLayer;

typedef struct {
    ModelConfig config;
    float *token_embeddings;
    float *output_proj;
    TransformerLayer layers[MAX_LAYERS];
    int loaded;
    /* Weight format: 0 = fp32_dense (use master directly),
     *                1 = ternary_weight_only (use _tern copies).
     * Set by load_model_weights from JSON "weight_format" field. */
    int weight_format;
} TransformerModel;

#define WEIGHT_FORMAT_FP32 0
#define WEIGHT_FORMAT_TERNARY 1

typedef struct {
    float *layer_inputs;
    float *norm1_outputs;
    float *norm2_outputs;
    float *attn_probs;
    float *ffn_pre_act;
    float *post_attn_x;
    float *final_x;
    float *ln1_x_norm;
    float *ln1_std;
    float *ln2_x_norm;
    float *ln2_std;
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

/* Internal float kernels — defined in model_infer.c, used by model_train.c */
void ne_softmax_buf_f(float *data, int64_t rows, int64_t cols);
void ne_matmul_buf_f(float *a, int64_t a_rows, int64_t a_cols,
                     float *b, int64_t b_cols, float *out);
void ne_gelu_buf_f(float *data, int64_t size);
void ne_fused_attention_forward_buf_f(
    float *x, int64_t seq_len, int64_t d_model,
    float *wq, float *wk, float *wv, float *wo,
    float *out, float *attn_probs_out);
void ne_fused_ffn_forward_buf_f(
    float *x, int64_t seq_len, int64_t d_model,
    float *w1, int64_t d_ff, float *w2,
    int32_t use_gelu, float *out, float *pre_act_out);
void create_sinusoidal_pe_f(float *pe, int seq_len, int d_model);

/* ---- Ternary quantization — defined in model_train.c ---- */

/* Project master FP32 weights to ternary {-alpha, 0, +alpha} stored as float.
 * alpha = mean(|w|), threshold = alpha/2. BitNet b1.58 style.
 * Returns alpha via out_alpha (may be NULL). */
void quantize_ternary(float *dst, float *src, int64_t n, float *out_alpha);

/* Pack ternary weights (in {-alpha, 0, +alpha} as floats) into 2-bit codes.
 * 4 weights per byte. Encoding: 00=zero, 01=+1, 11=-1. */
void pack_ternary(uint8_t *dst, float *src_tern, float alpha, int64_t n);

/* Quantize + pack all 6 dense matrices in all layers */
void requantize_all_layers(TransformerModel *model);

/* ---- Packed ternary forward kernels — defined in model_infer.c ---- */

/* Packed ternary matmul: out = x @ W where W is 2-bit ternary with scale alpha.
 * x: [m x k] float, w_packed: k*n ternary codes, out: [m x n] float */
void ne_matmul_buf_packed_f(
    float *x, int64_t m, int64_t k,
    uint8_t *w_packed, float alpha, int64_t n,
    float *out);

void ne_fused_attention_forward_buf_packed_f(
    float *x, int64_t seq_len, int64_t d_model,
    uint8_t *wq_p, float wq_alpha,
    uint8_t *wk_p, float wk_alpha,
    uint8_t *wv_p, float wv_alpha,
    uint8_t *wo_p, float wo_alpha,
    float *out, float *attn_probs_out);

void ne_fused_ffn_forward_buf_packed_f(
    float *x, int64_t seq_len, int64_t d_model,
    uint8_t *w1_p, float w1_alpha, int64_t d_ff,
    uint8_t *w2_p, float w2_alpha,
    int32_t use_gelu, float *out, float *pre_act_out);

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
