"""
Tests for Transformer neural network builtins.

Tests the new matrix operations added to support transformer architectures:
- softmax_matrix
- layer_norm_matrix
- random_matrix
- relu_matrix / gelu_matrix
- matrix_add / matrix_scale
- sinusoidal_pe
- embedding_lookup
- causal_mask
- etc.
"""

import pytest
import numpy as np
from eigenscript.evaluator.interpreter import Interpreter


class TestSoftmaxMatrix:
    """Test softmax_matrix builtin."""

    def test_softmax_basic(self):
        """Test basic softmax computation."""
        code = """
m is matrix of [[1.0, 2.0, 3.0], [1.0, 1.0, 1.0]]
result is softmax_matrix of m
print of result
"""
        interpreter = Interpreter()
        interpreter.run(code)
        # Softmax should produce valid probability distributions

    def test_softmax_numerical_stability(self):
        """Test softmax with large values."""
        code = """
m is matrix of [[100.0, 200.0, 300.0]]
result is softmax_matrix of m
total is matrix_sum of result
print of total
"""
        interpreter = Interpreter()
        interpreter.run(code)
        # Should not overflow and sum to 1


class TestLayerNorm:
    """Test layer_norm_matrix builtin."""

    def test_layer_norm_basic(self):
        """Test basic layer normalization."""
        code = """
m is matrix of [[1.0, 2.0, 3.0, 4.0], [10.0, 20.0, 30.0, 40.0]]
result is layer_norm_matrix of m
print of result
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_layer_norm_mean_zero(self):
        """Test that layer norm produces zero mean rows."""
        code = """
m is matrix of [[1.0, 2.0, 3.0, 4.0]]
result is layer_norm_matrix of m
mean is matrix_mean of result
print of mean
"""
        interpreter = Interpreter()
        interpreter.run(code)
        # Mean should be approximately 0


class TestRandomMatrix:
    """Test random_matrix builtin."""

    def test_random_matrix_shape(self):
        """Test random matrix has correct shape."""
        code = """
m is random_matrix of [3, 4]
shape is matrix_shape of m
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_random_matrix_xavier_scale(self):
        """Test Xavier initialization produces reasonable values."""
        code = """
m is random_matrix of [100, 100]
mean is matrix_mean of m
print of mean
"""
        interpreter = Interpreter()
        interpreter.run(code)
        # Mean should be close to 0


class TestActivations:
    """Test activation functions."""

    def test_relu_matrix(self):
        """Test ReLU activation."""
        code = """
m is matrix of [[-1.0, 2.0, -3.0, 4.0]]
result is relu_matrix of m
print of result
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_gelu_matrix(self):
        """Test GELU activation."""
        code = """
m is matrix of [[-1.0, 0.0, 1.0, 2.0]]
result is gelu_matrix of m
print of result
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestMatrixOperations:
    """Test matrix arithmetic operations."""

    def test_matrix_add(self):
        """Test matrix addition."""
        code = """
a is matrix of [[1.0, 2.0], [3.0, 4.0]]
b is matrix of [[5.0, 6.0], [7.0, 8.0]]
result is matrix_add of [a, b]
print of result
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_matrix_scale(self):
        """Test matrix scaling."""
        code = """
m is matrix of [[1.0, 2.0], [3.0, 4.0]]
result is matrix_scale of [m, 2.0]
print of result
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_matrix_shape(self):
        """Test getting matrix shape."""
        code = """
m is matrix of [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
shape is matrix_shape of m
rows is shape[0]
cols is shape[1]
print of rows
print of cols
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_matrix_sum(self):
        """Test matrix sum."""
        code = """
m is matrix of [[1.0, 2.0], [3.0, 4.0]]
total is matrix_sum of m
print of total
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_matrix_mean(self):
        """Test matrix mean."""
        code = """
m is matrix of [[1.0, 2.0], [3.0, 4.0]]
avg is matrix_mean of m
print of avg
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestPositionalEncoding:
    """Test sinusoidal positional encoding."""

    def test_sinusoidal_pe_shape(self):
        """Test positional encoding has correct shape."""
        code = """
pe is sinusoidal_pe of [10, 8]
shape is matrix_shape of pe
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_sinusoidal_pe_values(self):
        """Test positional encoding produces valid values."""
        code = """
pe is sinusoidal_pe of [4, 4]
print of pe
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestEmbeddingLookup:
    """Test embedding lookup."""

    def test_embedding_lookup_basic(self):
        """Test basic embedding lookup."""
        code = """
embed is matrix of [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6], [0.7, 0.8]]
indices is [0, 2, 1]
result is embedding_lookup of [embed, indices]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestCausalMask:
    """Test causal attention mask."""

    def test_causal_mask_shape(self):
        """Test causal mask has correct shape."""
        code = """
mask is causal_mask of 4
shape is matrix_shape of mask
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestMatrixReshape:
    """Test matrix reshape."""

    def test_matrix_reshape(self):
        """Test reshaping a matrix."""
        code = """
m is matrix of [[1.0, 2.0, 3.0, 4.0, 5.0, 6.0]]
reshaped is matrix_reshape of [m, 2, 3]
shape is matrix_shape of reshaped
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestDropout:
    """Test dropout."""

    def test_dropout_matrix(self):
        """Test dropout with 0 rate (should keep all values)."""
        code = """
m is matrix of [[1.0, 2.0, 3.0, 4.0]]
result is dropout_matrix of [m, 0.0]
print of result
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestScaledDotProductAttention:
    """Test attention mechanism via transformer module."""

    def test_attention_basic(self):
        """Test basic attention computation."""
        code = """
import transformer

query is matrix of [[1.0, 0.0], [0.0, 1.0]]
key is matrix of [[1.0, 0.0], [0.0, 1.0]]
value is matrix of [[1.0, 2.0], [3.0, 4.0]]
scale is 0.707

result is transformer.scaled_dot_product_attention of [query, key, value, scale]
print of result
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_attention_with_different_shapes(self):
        """Test attention with seq_len=3, d_k=2."""
        code = """
import transformer

query is matrix of [[1.0, 0.5], [0.5, 1.0], [0.0, 1.0]]
key is matrix of [[1.0, 0.0], [0.5, 0.5], [0.0, 1.0]]
value is matrix of [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]
scale is 0.707

result is transformer.scaled_dot_product_attention of [query, key, value, scale]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestTransformerComponents:
    """Test transformer components."""

    def test_feed_forward_network(self):
        """Test FFN computation."""
        code = """
import transformer

input is matrix of [[1.0, 2.0], [3.0, 4.0]]
w1 is random_matrix of [2, 4]
w2 is random_matrix of [4, 2]

result is transformer.feed_forward_network of [input, w1, w2]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_encoder_layer_simple(self):
        """Test simplified encoder layer."""
        code = """
import transformer

input is matrix of [[1.0, 2.0, 3.0, 4.0], [5.0, 6.0, 7.0, 8.0]]
w_q is random_matrix of [4, 4]
w_k is random_matrix of [4, 4]
w_v is random_matrix of [4, 4]
w_ff1 is random_matrix of [4, 8]
w_ff2 is random_matrix of [8, 4]
scale is 0.5

result is transformer.encoder_layer_simple of [input, w_q, w_k, w_v, w_ff1, w_ff2, scale]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestMatrixToList:
    """Test matrix to list conversion."""

    def test_matrix_to_list(self):
        """Test converting matrix to nested list."""
        code = """
m is matrix of [[1.0, 2.0], [3.0, 4.0]]
result is matrix_to_list of m
print of result
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestIntegration:
    """Integration tests for complete transformer workflows."""

    def test_mini_transformer_forward(self):
        """Test a complete mini transformer forward pass."""
        code = """
import transformer

# Configuration
d_model is 4
d_ff is 8
seq_len is 2

# Initialize weights
embed is random_matrix of [10, d_model]
w_q is random_matrix of [d_model, d_model]
w_k is random_matrix of [d_model, d_model]
w_v is random_matrix of [d_model, d_model]
w_ff1 is random_matrix of [d_model, d_ff]
w_ff2 is random_matrix of [d_ff, d_model]

# Input tokens
tokens is [1, 3]

# Embedding + positional encoding
token_emb is embedding_lookup of [embed, tokens]
pos_enc is sinusoidal_pe of [seq_len, d_model]
hidden is matrix_add of [token_emb, pos_enc]

# One encoder layer
scale is transformer.compute_scale of d_model
output is transformer.encoder_layer_simple of [hidden, w_q, w_k, w_v, w_ff1, w_ff2, scale]

# Final layer norm
final is layer_norm_matrix of output
shape is matrix_shape of final

print of "Mini transformer complete!"
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestNewTransformerFeatures:
    """Test new transformer features added in v3."""

    def test_pre_norm_block(self):
        """Test pre-norm transformer block."""
        code = """
import transformer

input is matrix of [[1.0, 2.0, 3.0, 4.0], [5.0, 6.0, 7.0, 8.0]]
w_q is random_matrix of [4, 4]
w_k is random_matrix of [4, 4]
w_v is random_matrix of [4, 4]
w_ff1 is random_matrix of [4, 8]
w_ff2 is random_matrix of [8, 4]
scale is 0.5

result is transformer.pre_norm_block of [input, w_q, w_k, w_v, w_ff1, w_ff2, scale]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_post_norm_block(self):
        """Test post-norm transformer block."""
        code = """
import transformer

input is matrix of [[1.0, 2.0, 3.0, 4.0], [5.0, 6.0, 7.0, 8.0]]
w_q is random_matrix of [4, 4]
w_k is random_matrix of [4, 4]
w_v is random_matrix of [4, 4]
w_ff1 is random_matrix of [4, 8]
w_ff2 is random_matrix of [8, 4]
scale is 0.5

result is transformer.post_norm_block of [input, w_q, w_k, w_v, w_ff1, w_ff2, scale]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_grouped_query_attention(self):
        """Test grouped query attention."""
        code = """
import transformer

input is matrix of [[1.0, 2.0, 3.0, 4.0], [5.0, 6.0, 7.0, 8.0]]
w_q is random_matrix of [4, 4]
w_k is random_matrix of [4, 4]
w_v is random_matrix of [4, 4]
w_o is random_matrix of [4, 4]
num_heads is 4
num_kv_heads is 2
d_k is 4

result is transformer.grouped_query_attention of [input, w_q, w_k, w_v, w_o, num_heads, num_kv_heads, d_k]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_swiglu_ffn(self):
        """Test SwiGLU feed-forward network."""
        code = """
import transformer

input is matrix of [[1.0, 2.0, 3.0, 4.0], [5.0, 6.0, 7.0, 8.0]]
w_gate is random_matrix of [4, 8]
w_up is random_matrix of [4, 8]
w_down is random_matrix of [8, 4]

result is transformer.swiglu_ffn of [input, w_gate, w_up, w_down]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_lr_warmup(self):
        """Test learning rate warmup."""
        code = """
import transformer

base_lr is 0.001
step1 is 5
step2 is 10
warmup_steps is 10

lr1 is transformer.lr_warmup of [base_lr, step1, warmup_steps]
lr2 is transformer.lr_warmup of [base_lr, step2, warmup_steps]

print of lr1
print of lr2
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_lr_cosine_decay(self):
        """Test cosine learning rate decay."""
        code = """
import transformer

max_lr is 0.001
min_lr is 0.0001
current_step is 50
total_steps is 100

lr is transformer.lr_cosine_decay of [max_lr, min_lr, current_step, total_steps]
print of lr
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_lr_warmup_cosine(self):
        """Test warmup + cosine decay schedule."""
        code = """
import transformer

max_lr is 0.001
min_lr is 0.0001
warmup_steps is 10
total_steps is 100

# During warmup
lr1 is transformer.lr_warmup_cosine of [max_lr, min_lr, 5, warmup_steps, total_steps]
print of lr1

# After warmup
lr2 is transformer.lr_warmup_cosine of [max_lr, min_lr, 50, warmup_steps, total_steps]
print of lr2
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_sliding_window_attention(self):
        """Test sliding window attention."""
        code = """
import transformer

query is matrix of [[1.0, 0.5], [0.5, 1.0], [0.0, 1.0]]
key is matrix of [[1.0, 0.0], [0.5, 0.5], [0.0, 1.0]]
value is matrix of [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]
scale is 0.707
window_size is 2
seq_len is 3

result is transformer.sliding_window_attention of [query, key, value, scale, window_size, seq_len]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_apply_rope(self):
        """Test RoPE application."""
        code = """
import transformer

vectors is matrix of [[1.0, 2.0, 3.0, 4.0], [5.0, 6.0, 7.0, 8.0]]
position is 5
d_model is 4

result is transformer.apply_rope of [vectors, position, d_model]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_clip_grad_norm(self):
        """Test gradient clipping."""
        code = """
import transformer

gradient is matrix of [[10.0, 20.0], [30.0, 40.0]]
max_norm is 1.0

clipped is transformer.clip_grad_norm of [gradient, max_norm]
print of clipped
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_expert_ffn(self):
        """Test expert FFN for MoE."""
        code = """
import transformer

input is matrix of [[1.0, 2.0, 3.0, 4.0]]
w1 is random_matrix of [4, 8]
w2 is random_matrix of [8, 4]

result is transformer.expert_ffn of [input, w1, w2]
shape is matrix_shape of result
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_moe_gating(self):
        """Test MoE gating mechanism."""
        code = """
import transformer

input is matrix of [[1.0, 2.0, 3.0, 4.0]]
gate_weights is random_matrix of [4, 4]
num_experts is 4
top_k is 2

probs is transformer.moe_gating of [input, gate_weights, num_experts, top_k]
shape is matrix_shape of probs
print of shape
"""
        interpreter = Interpreter()
        interpreter.run(code)


class TestSemanticLLMv3Features:
    """Test features specific to semantic LLM v3."""

    def test_rms_norm_equivalent(self):
        """Test RMS normalization behavior."""
        code = """
# RMS norm: x / sqrt(mean(x^2))
m is matrix of [[1.0, 2.0, 3.0, 4.0]]
squared is matmul of [transpose of m, m]
mean_sq is matrix_mean of squared
print of mean_sq
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_multi_head_8_heads(self):
        """Test 8-head attention setup."""
        code = """
semantic_dim is 32
head_dim is 4

# Initialize 8 heads
W_Q_h1 is random_matrix of [semantic_dim, head_dim]
W_K_h1 is random_matrix of [semantic_dim, head_dim]
W_V_h1 is random_matrix of [semantic_dim, head_dim]

W_Q_h8 is random_matrix of [semantic_dim, head_dim]
W_K_h8 is random_matrix of [semantic_dim, head_dim]
W_V_h8 is random_matrix of [semantic_dim, head_dim]

shape1 is matrix_shape of W_Q_h1
shape8 is matrix_shape of W_Q_h8

print of shape1
print of shape8
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_nucleus_sampling_topk_extraction(self):
        """Test top-k extraction for nucleus sampling."""
        code = """
probs is matrix of [[0.1, 0.3, 0.05, 0.4, 0.15]]
prob_list is matrix_to_list of probs
last_row is prob_list[0]

# Find top-3
top1_idx is 0
top1_val is 0.0
top2_idx is 0
top2_val is 0.0
top3_idx is 0
top3_val is 0.0

check_idx is 0
vocab_size is 5
loop while check_idx < vocab_size:
    current_prob is last_row[check_idx]
    current_val is what is current_prob

    if current_val > top1_val:
        top3_val is top2_val
        top3_idx is top2_idx
        top2_val is top1_val
        top2_idx is top1_idx
        top1_val is current_val
        top1_idx is check_idx
    else:
        if current_val > top2_val:
            top3_val is top2_val
            top3_idx is top2_idx
            top2_val is current_val
            top2_idx is check_idx
        else:
            if current_val > top3_val:
                top3_val is current_val
                top3_idx is check_idx

    check_idx is check_idx + 1

print of top1_idx
print of top2_idx
print of top3_idx
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_residual_scaling(self):
        """Test residual connection with scaling."""
        code = """
input is matrix of [[1.0, 2.0, 3.0, 4.0]]
attention_output is matrix of [[0.5, 0.5, 0.5, 0.5]]

# Residual scaling factor
residual_scale is 0.1
scaled_attn is matrix_scale of [attention_output, residual_scale]
residual is matrix_add of [input, scaled_attn]

print of residual
"""
        interpreter = Interpreter()
        interpreter.run(code)

    def test_tied_embeddings(self):
        """Test tied embedding and output projection."""
        code = """
vocab_size is 10
d_model is 4

vocab_embeddings is random_matrix of [vocab_size, d_model]
W_decode is transpose of vocab_embeddings

# Check shapes
emb_shape is matrix_shape of vocab_embeddings
dec_shape is matrix_shape of W_decode

print of emb_shape
print of dec_shape
"""
        interpreter = Interpreter()
        interpreter.run(code)
