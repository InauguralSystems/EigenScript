"""
Complete Integration: Bridging Python Autodiff and EigenScript Modules

This example demonstrates the full integration loop:
1. Use Python Tensor autodiff for training
2. Call EigenScript modules for preprocessing
3. Use Matrix operations for analysis
4. Export trained model weights to EigenScript format
"""

import numpy as np
from eigenscript.ai.autodiff import tensor, Tensor
from eigenscript.semantic.matrix import Matrix
from eigenscript.lexer.tokenizer import Tokenizer
from eigenscript.parser.ast_builder import Parser
from eigenscript.evaluator.interpreter import Interpreter


def evaluate_eigenscript_module(source_code, working_dir=None):
    """Execute EigenScript code and return the interpreter."""
    import os

    # Change to AI modules directory if needed
    original_dir = os.getcwd()
    if working_dir:
        os.chdir(working_dir)

    try:
        tokenizer = Tokenizer(source_code)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)
        return interpreter
    finally:
        os.chdir(original_dir)


def train_simple_model():
    """Train a simple linear model."""
    print("Training a simple linear model with Python autodiff...")
    print("-" * 60)

    # Generate simple linear data: y = 2x + 1
    np.random.seed(42)
    X = np.linspace(-1, 1, 50).reshape(-1, 1)
    y = 2 * X + 1 + 0.1 * np.random.randn(50, 1)

    # Convert to tensors
    X_tensor = tensor(X, requires_grad=False)
    y_tensor = tensor(y, requires_grad=False)

    # Initialize parameters
    w = tensor(np.random.randn(1, 1), requires_grad=True)
    b = tensor(np.random.randn(1, 1), requires_grad=True)

    # Training
    learning_rate = 0.1
    for epoch in range(100):
        # Forward pass
        y_pred = X_tensor @ w + b

        # MSE loss
        diff = y_pred - y_tensor
        loss = (diff * diff).mean()

        # Backward pass
        w.zero_grad()
        b.zero_grad()
        loss.backward()

        # Update
        w.data -= learning_rate * w.grad
        b.data -= learning_rate * b.grad

        if (epoch + 1) % 20 == 0:
            print(f"  Epoch {epoch + 1}: Loss = {loss.data.item():.4f}, "
                  f"w = {w.data[0,0]:.4f}, b = {b.data[0,0]:.4f}")

    print(f"  Final model: y = {w.data[0,0]:.4f}x + {b.data[0,0]:.4f}")
    print(f"  Target: y = 2.0000x + 1.0000")
    print()

    return w.data[0,0], b.data[0,0]


def use_eigenscript_preprocessing():
    """Use EigenScript modules for data preprocessing."""
    import os
    print("Using EigenScript modules for preprocessing...")
    print("-" * 60)

    eigenscript_code = """
import utils

raw_value is 10
normalized is utils.standardize of raw_value
augmented is utils.add_gaussian_noise of normalized
"""

    ai_dir = os.path.join(os.path.dirname(__file__), 'ai')
    interpreter = evaluate_eigenscript_module(eigenscript_code, working_dir=ai_dir)

    # Extract values from EigenScript environment
    raw = interpreter.environment.lookup("raw_value")
    normalized = interpreter.environment.lookup("normalized")
    augmented = interpreter.environment.lookup("augmented")

    print(f"  Raw value: {raw.coords[0]:.4f}")
    print(f"  Normalized: {normalized.coords[0]:.4f}")
    print(f"  Augmented: {augmented.coords[0]:.4f}")
    print()


def use_eigenscript_loss_functions():
    """Use EigenScript loss functions."""
    import os
    print("Using EigenScript loss functions...")
    print("-" * 60)

    eigenscript_code = """
import losses

prediction is 0.8
mse is losses.mse_loss of prediction
mae is losses.mae_loss of prediction
huber is losses.huber_loss of prediction
"""

    ai_dir = os.path.join(os.path.dirname(__file__), 'ai')
    interpreter = evaluate_eigenscript_module(eigenscript_code, working_dir=ai_dir)

    mse = interpreter.environment.lookup("mse")
    mae = interpreter.environment.lookup("mae")
    huber = interpreter.environment.lookup("huber")

    print(f"  Prediction: 0.8, Target: 1.0")
    print(f"  MSE Loss: {mse.coords[0]:.4f}")
    print(f"  MAE Loss: {mae.coords[0]:.4f}")
    print(f"  Huber Loss: {huber.coords[0]:.4f}")
    print()


def use_eigenscript_optimizers():
    """Use EigenScript optimizer modules."""
    import os
    print("Using EigenScript optimizer modules...")
    print("-" * 60)

    eigenscript_code = """
import optimizers

weight is 1.5
sgd_updated is optimizers.sgd_step of weight
adam_updated is optimizers.adam_step of weight
clipped is optimizers.clip_gradient_norm of 2.0
"""

    ai_dir = os.path.join(os.path.dirname(__file__), 'ai')
    interpreter = evaluate_eigenscript_module(eigenscript_code, working_dir=ai_dir)

    sgd_updated = interpreter.environment.lookup("sgd_updated")
    adam_updated = interpreter.environment.lookup("adam_updated")
    clipped = interpreter.environment.lookup("clipped")

    print(f"  Initial weight: 1.5")
    print(f"  After SGD step: {sgd_updated.coords[0]:.4f}")
    print(f"  After Adam step: {adam_updated.coords[0]:.4f}")
    print(f"  Clipped gradient (2.0): {clipped.coords[0]:.4f}")
    print()


def matrix_analysis_example():
    """Perform matrix analysis on model weights."""
    print("Matrix analysis of trained weights...")
    print("-" * 60)

    # Create a sample weight matrix from a trained model
    np.random.seed(42)
    weights = np.random.randn(3, 3) * 0.5

    # Convert to EigenScript Matrix
    W = Matrix(weights)

    print(f"  Weight matrix shape: {W.shape}")
    print(f"  Determinant: {W.det():.6f}")
    print(f"  Trace: {W.trace():.6f}")
    print(f"  Frobenius norm: {W.frobenius_norm():.6f}")

    # Eigenvalues and eigenvectors
    eigenvals, eigenvecs = W.eigenvalues()
    print(f"  Eigenvalues: {[f'{v.real:.4f}' for v in eigenvals]}")

    # SVD
    U, S, Vt = W.svd()
    print(f"  Singular values: {[f'{s:.4f}' for s in S[:3]]}")
    print()


def export_to_eigenscript_format(w, b):
    """Export trained model to EigenScript format."""
    print("Exporting model to EigenScript format...")
    print("-" * 60)

    eigenscript_model = f"""
# Trained Linear Model
# Generated from Python autodiff training

define predict as:
    x is n
    weight is {w:.6f}
    bias is {b:.6f}
    prediction is x * weight + bias
    return prediction

# Test predictions
test1 is predict of 0.0
test2 is predict of 1.0
test3 is predict of 2.0
"""

    print("Generated EigenScript code:")
    print(eigenscript_model)

    # Verify it works
    interpreter = evaluate_eigenscript_module(eigenscript_model)
    test1 = interpreter.environment.lookup("test1")
    test2 = interpreter.environment.lookup("test2")
    test3 = interpreter.environment.lookup("test3")

    print("Verification:")
    print(f"  predict(0.0) = {test1.coords[0]:.4f}")
    print(f"  predict(1.0) = {test2.coords[0]:.4f}")
    print(f"  predict(2.0) = {test3.coords[0]:.4f}")
    print()


def full_pipeline_example():
    """Demonstrate complete pipeline."""
    import os
    print("Complete Pipeline: EigenScript preprocessing → Python training → EigenScript inference")
    print("-" * 60)

    # Step 1: Preprocess data using EigenScript
    eigenscript_preprocessing = """
import utils
import layers

raw_input is 5
preprocessed is utils.standardize of raw_input
processed is layers.relu of preprocessed
"""

    ai_dir = os.path.join(os.path.dirname(__file__), 'ai')
    interp = evaluate_eigenscript_module(eigenscript_preprocessing, working_dir=ai_dir)
    processed = interp.environment.lookup("processed")
    input_value = processed.coords[0]

    print(f"Step 1 - EigenScript preprocessing: {input_value:.4f}")

    # Step 2: Train with Python autodiff
    X_train = tensor(np.array([[input_value]]), requires_grad=False)
    y_train = tensor(np.array([[1.0]]), requires_grad=False)

    w = tensor(np.array([[0.5]]), requires_grad=True)

    for _ in range(10):
        y_pred = X_train @ w
        loss = ((y_pred - y_train) ** tensor(np.array(2.0))).mean()
        w.zero_grad()
        loss.backward()
        w.data -= 0.1 * w.grad

    trained_weight = w.data[0,0]
    print(f"Step 2 - Python training: learned weight = {trained_weight:.4f}")

    # Step 3: Use trained model in EigenScript
    eigenscript_inference = f"""
define model_predict as:
    x is n
    weight is {trained_weight:.6f}
    result is x * weight
    return result

prediction is model_predict of {input_value:.6f}
"""

    interp2 = evaluate_eigenscript_module(eigenscript_inference)
    prediction = interp2.environment.lookup("prediction")

    print(f"Step 3 - EigenScript inference: prediction = {prediction.coords[0]:.4f}")
    print()


def main():
    """Run all integration examples."""
    print()
    print("=" * 70)
    print("COMPLETE INTEGRATION: Python Autodiff ⟷ EigenScript Modules")
    print("=" * 70)
    print()

    # 1. Train model with Python
    w, b = train_simple_model()

    # 2. Use EigenScript for preprocessing
    use_eigenscript_preprocessing()

    # 3. Use EigenScript loss functions
    use_eigenscript_loss_functions()

    # 4. Use EigenScript optimizers
    use_eigenscript_optimizers()

    # 5. Matrix analysis
    matrix_analysis_example()

    # 6. Export model to EigenScript
    export_to_eigenscript_format(w, b)

    # 7. Full pipeline
    full_pipeline_example()

    print("=" * 70)
    print("Integration Summary:")
    print("  ✓ Python Tensor training → EigenScript inference")
    print("  ✓ EigenScript preprocessing → Python training")
    print("  ✓ Matrix operations on model weights")
    print("  ✓ Bidirectional data flow between systems")
    print("  ✓ Complete ML pipeline using both frameworks")
    print("=" * 70)
    print()


if __name__ == "__main__":
    main()
