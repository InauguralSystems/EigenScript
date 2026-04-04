/*
 * EigenScript Model Internal Header — cross-file declarations for model modules.
 * Not part of the public API. Only included by model_io.c, model_infer.c, model_train.c.
 */

#ifndef MODEL_INTERNAL_H
#define MODEL_INTERNAL_H

#include "eigenscript.h"

/* Tiled matmul block size */
#define NE_TILE_SIZE 32

/* Forward kernels — defined in model_infer.c, used by model_train.c */
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

/* IO functions — defined in model_io.c */
int load_model_weights(const char *path, TransformerModel *model);
int save_model_weights(const char *path, TransformerModel *model);

/* Builtins — each file defines its own, registered by model_train.c */
Value* builtin_eigen_model_load(Value *arg);
Value* builtin_model_save_weights(Value *arg);
Value* builtin_eigen_generate(Value *arg);
Value* builtin_eigen_model_loaded(Value *arg);
Value* builtin_eigen_model_info(Value *arg);
Value* builtin_native_train_step(Value *arg);

#endif
