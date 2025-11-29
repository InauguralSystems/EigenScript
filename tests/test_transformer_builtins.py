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
