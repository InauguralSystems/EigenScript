# EigenScript AI/ML Modules

This directory contains a modular AI/ML framework implemented in EigenScript, demonstrating how to organize neural network components using the module system.

## Module Structure

```
ai/
├── layers.eigs       - Neural network layers and activation functions
├── optimizers.eigs   - Gradient-based optimization algorithms
├── losses.eigs       - Loss functions for training
├── utils.eigs        - Data preprocessing and utility functions
├── train_model.eigs  - Complete training example
└── README.md         - This file
```

## Modules Overview

### layers.eigs - Neural Network Layers

**Activation Functions:**
- `relu` - ReLU activation: max(0, x)
- `sigmoid_activation` - Sigmoid: 1 / (1 + exp(-x))
- `tanh_activation` - Hyperbolic tangent
- `leaky_relu` - Leaky ReLU with α = 0.01

**Layer Operations:**
- `dense_forward` - Forward pass for dense (fully connected) layer
- `batch_norm` - Batch normalization
- `dropout` - Dropout regularization (inference mode)

**Initialization:**
- `xavier_init` - Xavier/Glorot initialization
- `he_init` - He initialization for ReLU networks

**Example:**
```eigenscript
import layers

x is 5
activated is layers.relu of x
normalized is layers.batch_norm of activated
```

### optimizers.eigs - Optimization Algorithms

**Optimizers:**
- `sgd_step` - Stochastic Gradient Descent
- `sgd_with_momentum` - SGD with momentum
- `adam_step` - Adam optimizer (adaptive learning rates)
- `rmsprop_step` - RMSprop optimizer
- `adagrad_step` - AdaGrad optimizer

**Learning Rate Schedules:**
- `lr_step_decay` - Step decay schedule
- `lr_exponential_decay` - Exponential decay
- `warmup_lr` - Linear warmup

**Gradient Utilities:**
- `clip_gradient_norm` - Clip gradients by norm
- `clip_gradient_value` - Clip gradients by value

**Example:**
```eigenscript
import optimizers

weight is 1.0
updated_weight is optimizers.adam_step of weight
scheduled_lr is optimizers.lr_exponential_decay of 0.001
```

### losses.eigs - Loss Functions

**Regression Losses:**
- `mse_loss` - Mean Squared Error
- `mae_loss` - Mean Absolute Error
- `huber_loss` - Huber loss (smooth L1)
- `mse_gradient` - Gradient of MSE

**Classification Losses:**
- `binary_crossentropy` - Binary cross-entropy
- `categorical_crossentropy` - Categorical cross-entropy
- `hinge_loss` - Hinge loss for SVM

**Regularization:**
- `l1_regularization` - L1 (Lasso) regularization
- `l2_regularization` - L2 (Ridge) regularization
- `elastic_net_regularization` - Elastic Net (L1 + L2)

**Example:**
```eigenscript
import losses

prediction is 0.8
loss is losses.mse_loss of prediction
reg is losses.l2_regularization of 0.5
total_loss is loss + reg
```

### utils.eigs - Data Preprocessing & Utilities

**Normalization:**
- `min_max_normalize` - Min-max scaling to [0, 1]
- `standardize` - Z-score normalization
- `robust_scale` - Robust scaling using median/IQR

**Data Augmentation:**
- `add_gaussian_noise` - Add Gaussian noise
- `random_flip` - Random flip
- `random_scale` - Random scaling

**Metrics:**
- `accuracy` - Classification accuracy
- `precision` - Precision score
- `recall` - Recall score
- `f1_score` - F1 score

**Activation Utilities:**
- `softmax_single` - Softmax activation
- `gelu_activation` - GELU activation
- `swish_activation` - Swish activation

**Example:**
```eigenscript
import utils

raw_data is 5
normalized is utils.standardize of raw_data
augmented is utils.add_gaussian_noise of normalized
acc is utils.accuracy of 0.8
```

## Complete Training Example

The `train_model.eigs` file demonstrates a complete training pipeline:

```eigenscript
import layers
import optimizers
import losses
import utils

# 1. Data preparation
raw_input is 5
normalized_input is utils.standardize of raw_input
augmented_input is utils.add_gaussian_noise of normalized_input

# 2. Forward pass
layer1_output is layers.dense_forward of augmented_input
layer1_activated is layers.relu of layer1_output
layer2_output is layers.dense_forward of layer1_activated
final_output is layers.sigmoid_activation of layer2_output

# 3. Loss computation
loss is losses.mse_loss of final_output
reg_loss is losses.l2_regularization of 0.5
total_loss is loss + reg_loss

# 4. Optimization
gradient is losses.mse_gradient of final_output
updated_weight is optimizers.adam_step of 0.5

# 5. Metrics
accuracy is utils.accuracy of final_output
```

## Running the Example

### Using the Interpreter:
```bash
python -m eigenscript.evaluator examples/ai/train_model.eigs
```

### Using the Compiler:
```bash
eigenscript compile examples/ai/train_model.eigs -o train_model
./train_model
```

### In REPL:
```python
from eigenscript.lexer.tokenizer import Tokenizer
from eigenscript.parser.ast_builder import Parser
from eigenscript.evaluator.interpreter import Interpreter

source = """
import layers
import optimizers
x is 5
activated is layers.relu of x
optimized is optimizers.sgd_step of activated
"""

tokenizer = Tokenizer(source)
tokens = tokenizer.tokenize()
parser = Parser(tokens)
ast = parser.parse()

interpreter = Interpreter()
result = interpreter.evaluate(ast)
```

## Integration with Autodiff

These modules complement the Python-based autodiff system (`src/eigenscript/ai/autodiff.py`) and can be used together:

**Python side:**
```python
from eigenscript.ai.autodiff import tensor, Tensor

# Create tensors with gradient tracking
x = tensor([[1, 2], [3, 4]], requires_grad=True)
w = tensor([[0.5, 0.3]], requires_grad=True)

# Forward pass
y = x @ w.T
loss = (y * y).sum()

# Backward pass
loss.backward()
print(x.grad, w.grad)
```

**EigenScript side:**
```eigenscript
import layers
import optimizers

# Use the gradient from Python autodiff to update weights
gradient is 0.1
new_weight is optimizers.adam_step of gradient
```

## Module System Benefits

1. **Organization**: Separate concerns into focused modules
2. **Reusability**: Import only what you need
3. **Maintainability**: Easy to update individual components
4. **Scalability**: Add new modules without modifying existing code
5. **Testing**: Test each module independently

## Future Enhancements

Potential additions to the AI module ecosystem:

- **models.eigs** - Pre-built model architectures
- **datasets.eigs** - Data loading and batching
- **callbacks.eigs** - Training callbacks (early stopping, checkpointing)
- **metrics.eigs** - Advanced evaluation metrics
- **preprocessing.eigs** - Feature engineering pipelines
- **vision.eigs** - Computer vision utilities
- **nlp.eigs** - Natural language processing tools

## Notes

- Current implementation uses simplified approximations for mathematical functions
- Future versions will integrate with the Matrix and Tensor classes
- Module system supports import caching for performance
- All modules are compatible with both interpreter and compiler modes
