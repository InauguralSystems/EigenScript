/*
 * Cross-TU prototypes for builtin_* functions split out of builtins.c.
 * Keeps register_builtins wire-up declarative without adding every
 * tensor prototype to the public eigenscript.h.
 */

#ifndef EIGENSCRIPT_BUILTINS_INTERNAL_H
#define EIGENSCRIPT_BUILTINS_INTERNAL_H

#include "eigenscript.h"

/* Tensor builtins — implemented in builtins_tensor.c */
Value* builtin_tensor_add(Value *arg);
Value* builtin_tensor_subtract(Value *arg);
Value* builtin_tensor_multiply(Value *arg);
Value* builtin_tensor_divide(Value *arg);
Value* builtin_tensor_pow(Value *arg);
Value* builtin_tensor_sqrt(Value *arg);
Value* builtin_tensor_exp(Value *arg);
Value* builtin_tensor_log(Value *arg);
Value* builtin_tensor_negative(Value *arg);
Value* builtin_tensor_matmul(Value *arg);
Value* builtin_tensor_softmax(Value *arg);
Value* builtin_tensor_log_softmax(Value *arg);
Value* builtin_tensor_matmul_at(Value *arg);
Value* builtin_tensor_matmul_bt(Value *arg);
Value* builtin_tensor_scatter_add(Value *arg);
Value* builtin_tensor_relu(Value *arg);
Value* builtin_tensor_leaky_relu(Value *arg);
Value* builtin_tensor_mean(Value *arg);
Value* builtin_tensor_sum(Value *arg);
Value* builtin_tensor_norm(Value *arg);
Value* builtin_tensor_zeros(Value *arg);
Value* builtin_tensor_zeros_like(Value *arg);
Value* builtin_tensor_gather(Value *arg);
Value* builtin_tensor_shape(Value *arg);
Value* builtin_random_normal(Value *arg);
Value* builtin_numerical_grad(Value *arg);
Value* builtin_sgd_update(Value *arg);
Value* builtin_numerical_grad_rows(Value *arg);
Value* builtin_sgd_update_rows(Value *arg);
Value* builtin_numerical_grad_cols(Value *arg);
Value* builtin_sgd_update_cols(Value *arg);
Value* builtin_tensor_save(Value *arg);
Value* builtin_tensor_load(Value *arg);

/* builtins_buf.c (#744) — numeric buffers, the vectorized buf_* kernels,
 * the PCM16LE codecs and the DEFLATE codecs. Registered by builtins.c's
 * register_builtins, which is why the prototypes belong here. */
Value* builtin_buffer(Value *arg);
Value* builtin_reshape(Value *arg);
Value* builtin_buf_len(Value *arg);
Value* builtin_buf_get(Value *arg);
Value* builtin_buf_set(Value *arg);
Value* builtin_buf_from_list(Value *arg);
Value* builtin_str_from_bytes(Value *arg);
Value* builtin_f64_to_bytes(Value *arg);
Value* builtin_f64_from_bytes(Value *arg);
Value* builtin_buf_copy(Value *arg);
Value* builtin_buf_mix(Value *arg);
Value* builtin_buf_scale_range(Value *arg);
Value* builtin_buf_fill(Value *arg);
Value* builtin_buf_peak(Value *arg);
Value* builtin_buf_dot(Value *arg);
Value* builtin_buf_from_pcm16le(Value *arg);
Value* builtin_buf_to_pcm16le(Value *arg);
Value* builtin_buf_deinterleave(Value *arg);
Value* builtin_buf_resample_linear(Value *arg);
Value* builtin_inflate(Value *arg);
Value* builtin_zlib_inflate(Value *arg);
Value* builtin_deflate(Value *arg);
Value* builtin_zlib_deflate(Value *arg);

/* builtins_host.c (#741) — every builtin needing a real OS underneath.
 * Whole-TU gated: under EIGENSCRIPT_FREESTANDING this registers nothing. */
void register_host_builtins(Env *env);

/* builtins.c — shared with builtins_host.c's subprocess builtins: the #148
 * "fail loudly under EIGS_REPLAY" boundary check (channels use it too). */
int replay_blocks(const char *fn);

/* builtins.c — the "is this name the language's?" predicate shared with
 * builtins_host.c (build_corpus skips registered builtins). */
int eigs_is_registered_builtin(const char *name);

#endif /* EIGENSCRIPT_BUILTINS_INTERNAL_H */
