"""
Tests for AI/ML standard library modules.

Tests CNN operations, RNN/LSTM operations, attention mechanisms,
and advanced optimizers in EigenScript's stdlib.
"""

import pytest
from eigenscript.lexer.tokenizer import Tokenizer
from eigenscript.parser.ast_builder import Parser
from eigenscript.evaluator.interpreter import Interpreter


class TestCNNOperations:
    """Test CNN layer operations from cnn.eigs."""

    def test_import_cnn_module(self):
        """Test importing the cnn module."""
        source = """
import cnn
x is 5
result is cnn.relu of x
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Check that module and result are bound
        assert "cnn" in interp.environment.bindings
        assert "result" in interp.environment.bindings
        # Result should be an LRVM vector
        assert hasattr(interp.environment.bindings["result"], "coords")

    def test_conv2d_function(self):
        """Test conv2d convolution operation."""
        source = """
from cnn import conv2d
input is 10
result is conv2d of input
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # conv2d should be imported and callable
        assert "conv2d" in interp.environment.bindings
        assert "result" in interp.environment.bindings

    def test_pooling_operations(self):
        """Test max_pool2d and avg_pool2d."""
        source = """
from cnn import max_pool2d, avg_pool2d
input is 100
max_pooled is max_pool2d of input
avg_pooled is avg_pool2d of input
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Both pooling operations should work
        assert "max_pooled" in interp.environment.bindings
        assert "avg_pooled" in interp.environment.bindings

    def test_batch_normalization(self):
        """Test batch_norm operation."""
        source = """
from cnn import batch_norm
input is 50
normalized is batch_norm of input
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "batch_norm" in interp.environment.bindings
        assert "normalized" in interp.environment.bindings

    def test_activation_functions(self):
        """Test CNN-specific activation functions."""
        source = """
from cnn import relu, relu6, leaky_relu
x is -5
r1 is relu of x
r2 is relu6 of x
r3 is leaky_relu of x
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # All activations should be imported and work
        assert "relu" in interp.environment.bindings
        assert "relu6" in interp.environment.bindings
        assert "leaky_relu" in interp.environment.bindings
        assert "r1" in interp.environment.bindings
        assert "r2" in interp.environment.bindings
        assert "r3" in interp.environment.bindings

    def test_attention_mechanisms(self):
        """Test squeeze-excitation and CBAM attention."""
        source = """
from cnn import squeeze_excitation, cbam_attention
features is 64
se_out is squeeze_excitation of features
cbam_out is cbam_attention of features
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "squeeze_excitation" in interp.environment.bindings
        assert "cbam_attention" in interp.environment.bindings
        assert "se_out" in interp.environment.bindings
        assert "cbam_out" in interp.environment.bindings

    def test_residual_connections(self):
        """Test residual block operations."""
        source = """
from cnn import residual_block, dense_connection
input is 32
residual_out is residual_block of input
dense_out is dense_connection of input
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "residual_block" in interp.environment.bindings
        assert "dense_connection" in interp.environment.bindings
        assert "residual_out" in interp.environment.bindings
        assert "dense_out" in interp.environment.bindings

    def test_wildcard_import_cnn(self):
        """Test importing all CNN functions with wildcard."""
        source = """
from cnn import *
x is 10
result is conv2d of x
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # conv2d should be available directly (not cnn.conv2d)
        assert "conv2d" in interp.environment.bindings
        assert "result" in interp.environment.bindings


class TestRNNOperations:
    """Test RNN/LSTM operations from rnn.eigs."""

    def test_import_rnn_module(self):
        """Test importing the rnn module."""
        source = """
import rnn
hidden is 128
output is rnn.lstm_cell of hidden
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "rnn" in interp.environment.bindings
        assert "output" in interp.environment.bindings

    def test_basic_rnn_cells(self):
        """Test basic RNN cell operations."""
        source = """
from rnn import rnn_cell, gru_cell, lstm_cell
hidden is 64
rnn_out is rnn_cell of hidden
gru_out is gru_cell of hidden
lstm_out is lstm_cell of hidden
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "rnn_cell" in interp.environment.bindings
        assert "gru_cell" in interp.environment.bindings
        assert "lstm_cell" in interp.environment.bindings
        assert "rnn_out" in interp.environment.bindings
        assert "gru_out" in interp.environment.bindings
        assert "lstm_out" in interp.environment.bindings

    def test_bidirectional_rnn(self):
        """Test bidirectional RNN operations."""
        source = """
from rnn import bidirectional_rnn, bidirectional_lstm
sequence is 10
bi_rnn_out is bidirectional_rnn of sequence
bi_lstm_out is bidirectional_lstm of sequence
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "bidirectional_rnn" in interp.environment.bindings
        assert "bidirectional_lstm" in interp.environment.bindings
        assert "bi_rnn_out" in interp.environment.bindings
        assert "bi_lstm_out" in interp.environment.bindings

    def test_attention_mechanisms_rnn(self):
        """Test attention mechanisms for sequences."""
        source = """
from rnn import attention_mechanism, self_attention, multi_head_attention
query is 8
attn_out is attention_mechanism of query
self_attn_out is self_attention of query
mha_out is multi_head_attention of query
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "attention_mechanism" in interp.environment.bindings
        assert "self_attention" in interp.environment.bindings
        assert "multi_head_attention" in interp.environment.bindings
        assert "attn_out" in interp.environment.bindings
        assert "self_attn_out" in interp.environment.bindings
        assert "mha_out" in interp.environment.bindings

    def test_sequence_operations(self):
        """Test sequence processing operations."""
        source = """
from rnn import sequence_mask, packed_sequence, teacher_forcing
seq_len is 20
mask is sequence_mask of seq_len
packed is packed_sequence of seq_len
forced is teacher_forcing of seq_len
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "sequence_mask" in interp.environment.bindings
        assert "packed_sequence" in interp.environment.bindings
        assert "teacher_forcing" in interp.environment.bindings
        assert "mask" in interp.environment.bindings
        assert "packed" in interp.environment.bindings
        assert "forced" in interp.environment.bindings

    def test_positional_encoding(self):
        """Test positional encoding for sequences."""
        source = """
from rnn import positional_encoding, learned_positional_embedding
seq_pos is 16
pos_enc is positional_encoding of seq_pos
learned_pos is learned_positional_embedding of seq_pos
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "positional_encoding" in interp.environment.bindings
        assert "learned_positional_embedding" in interp.environment.bindings
        assert "pos_enc" in interp.environment.bindings
        assert "learned_pos" in interp.environment.bindings


class TestAttentionOperations:
    """Test attention and transformer operations from attention.eigs."""

    def test_import_attention_module(self):
        """Test importing the attention module."""
        source = """
import attention
query is 8
result is attention.scaled_dot_product_attention of query
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "attention" in interp.environment.bindings
        assert "result" in interp.environment.bindings

    def test_core_attention_variants(self):
        """Test different attention mechanisms."""
        source = """
from attention import scaled_dot_product_attention, additive_attention, multiplicative_attention
q is 10
sdpa is scaled_dot_product_attention of q
add_attn is additive_attention of q
mul_attn is multiplicative_attention of q
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "scaled_dot_product_attention" in interp.environment.bindings
        assert "additive_attention" in interp.environment.bindings
        assert "multiplicative_attention" in interp.environment.bindings
        assert "sdpa" in interp.environment.bindings
        assert "add_attn" in interp.environment.bindings
        assert "mul_attn" in interp.environment.bindings

    def test_multi_head_attention(self):
        """Test multi-head attention operations."""
        source = """
from attention import transformer_attention_head, concat_attention_heads
query is 64
head is transformer_attention_head of query
concat_heads is concat_attention_heads of query
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "transformer_attention_head" in interp.environment.bindings
        assert "concat_attention_heads" in interp.environment.bindings
        assert "head" in interp.environment.bindings
        assert "concat_heads" in interp.environment.bindings

    def test_transformer_blocks(self):
        """Test transformer encoder/decoder layers."""
        source = """
from attention import transformer_encoder_layer, transformer_decoder_layer
input is 128
encoder_out is transformer_encoder_layer of input
decoder_out is transformer_decoder_layer of input
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "transformer_encoder_layer" in interp.environment.bindings
        assert "transformer_decoder_layer" in interp.environment.bindings
        assert "encoder_out" in interp.environment.bindings
        assert "decoder_out" in interp.environment.bindings

    def test_positional_encodings(self):
        """Test different positional encoding schemes."""
        source = """
from attention import sinusoidal_position_encoding, rotary_position_embedding, alibi_position_bias
seq_len is 32
sin_pos is sinusoidal_position_encoding of seq_len
rope is rotary_position_embedding of seq_len
alibi is alibi_position_bias of seq_len
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "sinusoidal_position_encoding" in interp.environment.bindings
        assert "rotary_position_embedding" in interp.environment.bindings
        assert "alibi_position_bias" in interp.environment.bindings
        assert "sin_pos" in interp.environment.bindings
        assert "rope" in interp.environment.bindings
        assert "alibi" in interp.environment.bindings

    def test_efficient_attention_variants(self):
        """Test memory-efficient attention mechanisms."""
        source = """
from attention import local_attention, sparse_attention, linear_attention
input is 256
local is local_attention of input
sparse is sparse_attention of input
linear is linear_attention of input
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "local_attention" in interp.environment.bindings
        assert "sparse_attention" in interp.environment.bindings
        assert "linear_attention" in interp.environment.bindings
        assert "local" in interp.environment.bindings
        assert "sparse" in interp.environment.bindings
        assert "linear" in interp.environment.bindings

    def test_vision_transformer_components(self):
        """Test vision transformer operations."""
        source = """
from attention import patch_embedding, cls_token
image is 224
patches is patch_embedding of image
cls is cls_token of patches
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "patch_embedding" in interp.environment.bindings
        assert "cls_token" in interp.environment.bindings
        assert "patches" in interp.environment.bindings
        assert "cls" in interp.environment.bindings


class TestAdvancedOptimizers:
    """Test advanced optimization algorithms from advanced_optimizers.eigs."""

    def test_import_optimizers_module(self):
        """Test importing the advanced_optimizers module."""
        source = """
import advanced_optimizers
weight is 10
updated is advanced_optimizers.adamw of weight
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "advanced_optimizers" in interp.environment.bindings
        assert "updated" in interp.environment.bindings

    def test_adam_variants(self):
        """Test AdamW, RAdam, LAMB, and Adafactor."""
        source = """
from advanced_optimizers import adamw, radam, lamb, adafactor
weight is 100
w1 is adamw of weight
w2 is radam of weight
w3 is lamb of weight
w4 is adafactor of weight
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "adamw" in interp.environment.bindings
        assert "radam" in interp.environment.bindings
        assert "lamb" in interp.environment.bindings
        assert "adafactor" in interp.environment.bindings
        assert "w1" in interp.environment.bindings
        assert "w2" in interp.environment.bindings
        assert "w3" in interp.environment.bindings
        assert "w4" in interp.environment.bindings

    def test_meta_optimizers(self):
        """Test Lookahead, Ranger, and SAM."""
        source = """
from advanced_optimizers import lookahead_step, ranger, sam_step
fast_weights is 50
lookahead_out is lookahead_step of fast_weights
ranger_out is ranger of fast_weights
sam_out is sam_step of fast_weights
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "lookahead_step" in interp.environment.bindings
        assert "ranger" in interp.environment.bindings
        assert "sam_step" in interp.environment.bindings
        assert "lookahead_out" in interp.environment.bindings
        assert "ranger_out" in interp.environment.bindings
        assert "sam_out" in interp.environment.bindings

    def test_adaptive_methods(self):
        """Test Adadelta, Nadam, and AMSGrad."""
        source = """
from advanced_optimizers import adadelta, nadam, amsgrad
weight is 75
delta is adadelta of weight
nadam_out is nadam of weight
ams is amsgrad of weight
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "adadelta" in interp.environment.bindings
        assert "nadam" in interp.environment.bindings
        assert "amsgrad" in interp.environment.bindings
        assert "delta" in interp.environment.bindings
        assert "nadam_out" in interp.environment.bindings
        assert "ams" in interp.environment.bindings

    def test_second_order_methods(self):
        """Test AdaHessian and K-FAC."""
        source = """
from advanced_optimizers import adahessian_step, kfac_step
weight is 60
hessian_out is adahessian_step of weight
kfac_out is kfac_step of weight
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "adahessian_step" in interp.environment.bindings
        assert "kfac_step" in interp.environment.bindings
        assert "hessian_out" in interp.environment.bindings
        assert "kfac_out" in interp.environment.bindings

    def test_gradient_clipping(self):
        """Test gradient clipping operations."""
        source = """
from advanced_optimizers import clip_by_global_norm, clip_by_value, normalize_gradients
gradient is 1000
clipped_norm is clip_by_global_norm of gradient
clipped_value is clip_by_value of gradient
normalized is normalize_gradients of gradient
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "clip_by_global_norm" in interp.environment.bindings
        assert "clip_by_value" in interp.environment.bindings
        assert "normalize_gradients" in interp.environment.bindings
        assert "clipped_norm" in interp.environment.bindings
        assert "clipped_value" in interp.environment.bindings
        assert "normalized" in interp.environment.bindings

    def test_learning_rate_schedules(self):
        """Test learning rate scheduling."""
        source = """
from advanced_optimizers import cosine_annealing, warmup_cosine_schedule, onecycle_schedule
epoch is 50
cos_lr is cosine_annealing of epoch
warmup_lr is warmup_cosine_schedule of epoch
cycle_lr is onecycle_schedule of epoch
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "cosine_annealing" in interp.environment.bindings
        assert "warmup_cosine_schedule" in interp.environment.bindings
        assert "onecycle_schedule" in interp.environment.bindings
        assert "cos_lr" in interp.environment.bindings
        assert "warmup_lr" in interp.environment.bindings
        assert "cycle_lr" in interp.environment.bindings

    def test_training_utilities(self):
        """Test gradient accumulation and loss scaling."""
        source = """
from advanced_optimizers import accumulate_gradients, dynamic_loss_scaling, gradient_unscaling
gradient is 10
loss is 1
accumulated is accumulate_gradients of gradient
scaled_loss is dynamic_loss_scaling of loss
unscaled is gradient_unscaling of gradient
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "accumulate_gradients" in interp.environment.bindings
        assert "dynamic_loss_scaling" in interp.environment.bindings
        assert "gradient_unscaling" in interp.environment.bindings
        assert "accumulated" in interp.environment.bindings
        assert "scaled_loss" in interp.environment.bindings
        assert "unscaled" in interp.environment.bindings


class TestCombinedAIOperations:
    """Test combining operations from multiple AI/ML modules."""

    def test_import_multiple_ai_modules(self):
        """Test importing multiple AI modules together."""
        source = """
import cnn
import rnn
import attention
import advanced_optimizers

# Use functions from different modules
x is 32
conv_out is cnn.conv2d of x
lstm_out is rnn.lstm_cell of conv_out
attn_out is attention.scaled_dot_product_attention of lstm_out
final is advanced_optimizers.adamw of attn_out
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # All modules should be imported
        assert "cnn" in interp.environment.bindings
        assert "rnn" in interp.environment.bindings
        assert "attention" in interp.environment.bindings
        assert "advanced_optimizers" in interp.environment.bindings

        # All intermediate results should exist
        assert "conv_out" in interp.environment.bindings
        assert "lstm_out" in interp.environment.bindings
        assert "attn_out" in interp.environment.bindings
        assert "final" in interp.environment.bindings

    def test_selective_imports_from_all_modules(self):
        """Test selective imports from all AI modules."""
        source = """
from cnn import conv2d, batch_norm
from rnn import lstm_cell, attention_mechanism
from attention import transformer_encoder_layer
from advanced_optimizers import adamw, cosine_annealing

# Build a simple pipeline
x is 64
conv is conv2d of x
norm is batch_norm of conv
lstm is lstm_cell of norm
encoder is transformer_encoder_layer of lstm
optimized is adamw of encoder
lr is cosine_annealing of 10
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # All imported functions should be available
        assert "conv2d" in interp.environment.bindings
        assert "batch_norm" in interp.environment.bindings
        assert "lstm_cell" in interp.environment.bindings
        assert "attention_mechanism" in interp.environment.bindings
        assert "transformer_encoder_layer" in interp.environment.bindings
        assert "adamw" in interp.environment.bindings
        assert "cosine_annealing" in interp.environment.bindings

        # All pipeline stages should exist
        assert "conv" in interp.environment.bindings
        assert "norm" in interp.environment.bindings
        assert "lstm" in interp.environment.bindings
        assert "encoder" in interp.environment.bindings
        assert "optimized" in interp.environment.bindings
        assert "lr" in interp.environment.bindings

    def test_wildcard_imports_ai_modules(self):
        """Test wildcard imports from AI modules."""
        source = """
from cnn import *
from advanced_optimizers import *

# Use functions imported via wildcard
input is 128
processed is conv2d of input
pooled is max_pool2d of processed
updated is adamw of pooled
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Functions should be available directly
        assert "conv2d" in interp.environment.bindings
        assert "max_pool2d" in interp.environment.bindings
        assert "adamw" in interp.environment.bindings
        assert "processed" in interp.environment.bindings
        assert "pooled" in interp.environment.bindings
        assert "updated" in interp.environment.bindings
