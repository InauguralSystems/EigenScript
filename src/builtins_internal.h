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

/* builtins_host.c (#741) — every builtin needing a real OS underneath.
 * Whole-TU gated: under EIGENSCRIPT_FREESTANDING this registers nothing. */
void register_host_builtins(Env *env);

/* builtins.c — shared with builtins_host.c's subprocess builtins: the #148
 * "fail loudly under EIGS_REPLAY" boundary check (channels use it too). */
int replay_blocks(const char *fn);

/* builtins.c — shared with builtins_host.c: the process argv snapshot
 * (exe_path's argv[0] fallback) and the "is this name the language's?"
 * predicate (build_corpus skips registered builtins). */
extern int g_argc;
extern char **g_argv;
int eigs_is_registered_builtin(const char *name);

#endif /* EIGENSCRIPT_BUILTINS_INTERNAL_H */
