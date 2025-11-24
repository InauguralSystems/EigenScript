"""
End-to-end neural network example using EigenScript's autodiff system.

Demonstrates:
- Building a simple 2-layer neural network
- Training with gradient descent
- Using the Tensor class for automatic differentiation
- Integration with EigenScript's AI modules
"""

import numpy as np
from eigenscript.ai.autodiff import tensor, Tensor


class SimpleNeuralNetwork:
    """
    A simple 2-layer neural network for binary classification.

    Architecture:
    - Input layer (2 features)
    - Hidden layer (4 neurons, ReLU activation)
    - Output layer (1 neuron, sigmoid activation)
    """

    def __init__(self, input_size=2, hidden_size=4, output_size=1):
        """Initialize network with random weights."""
        # Xavier initialization
        self.W1 = tensor(
            np.random.randn(input_size, hidden_size) * np.sqrt(2.0 / input_size),
            requires_grad=True
        )
        self.b1 = tensor(np.zeros((1, hidden_size)), requires_grad=True)

        self.W2 = tensor(
            np.random.randn(hidden_size, output_size) * np.sqrt(2.0 / hidden_size),
            requires_grad=True
        )
        self.b2 = tensor(np.zeros((1, output_size)), requires_grad=True)

    def forward(self, X):
        """Forward pass through the network."""
        # Hidden layer with ReLU
        self.z1 = X @ self.W1 + self.b1
        self.h1 = self.z1.relu()

        # Output layer with sigmoid
        self.z2 = self.h1 @ self.W2 + self.b2
        self.output = self.z2.sigmoid()

        return self.output

    def zero_grad(self):
        """Zero out all gradients."""
        self.W1.zero_grad()
        self.b1.zero_grad()
        self.W2.zero_grad()
        self.b2.zero_grad()

    def parameters(self):
        """Return all trainable parameters."""
        return [self.W1, self.b1, self.W2, self.b2]


def binary_cross_entropy(y_pred, y_true):
    """
    Binary cross-entropy loss.

    Uses MSE as a simpler alternative since we don't have log in autodiff yet.
    """
    # Simple squared error loss
    diff = y_pred - y_true
    loss = (diff * diff).mean()
    return loss


def train_step(model, X, y, learning_rate=0.01):
    """Perform one training step."""
    # Forward pass
    y_pred = model.forward(X)

    # Compute loss
    loss = binary_cross_entropy(y_pred, y)

    # Backward pass
    model.zero_grad()
    loss.backward()

    # Update weights (simple SGD)
    for param in model.parameters():
        param.data -= learning_rate * param.grad

    return loss.data.item()


def generate_xor_data(n_samples=100):
    """Generate XOR dataset for binary classification."""
    np.random.seed(42)

    # Generate random points
    X = np.random.randn(n_samples, 2)

    # XOR labels: y = 1 if x1*x2 > 0, else 0
    y = ((X[:, 0] * X[:, 1]) > 0).astype(np.float64).reshape(-1, 1)

    return X, y


def evaluate_accuracy(model, X, y):
    """Compute classification accuracy."""
    y_pred = model.forward(X)
    predictions = (y_pred.data > 0.5).astype(np.float64)
    accuracy = (predictions == y.data).mean()
    return accuracy


def main():
    """Main training loop."""
    print("=" * 60)
    print("EigenScript Neural Network Training Example")
    print("=" * 60)
    print()

    # Generate data
    print("Generating XOR dataset...")
    X_train, y_train = generate_xor_data(n_samples=200)
    X_test, y_test = generate_xor_data(n_samples=50)

    # Convert to tensors
    X_train_tensor = tensor(X_train, requires_grad=False)
    y_train_tensor = tensor(y_train, requires_grad=False)
    X_test_tensor = tensor(X_test, requires_grad=False)
    y_test_tensor = tensor(y_test, requires_grad=False)

    print(f"Training samples: {len(X_train)}")
    print(f"Test samples: {len(X_test)}")
    print()

    # Create model
    print("Initializing neural network...")
    model = SimpleNeuralNetwork(input_size=2, hidden_size=4, output_size=1)
    print(f"  Input → Hidden: {model.W1.shape}")
    print(f"  Hidden → Output: {model.W2.shape}")
    print()

    # Training
    print("Training...")
    print("-" * 60)
    n_epochs = 2000
    learning_rate = 1.0

    for epoch in range(n_epochs):
        # Train
        loss = train_step(model, X_train_tensor, y_train_tensor, learning_rate)

        # Evaluate every 100 epochs
        if (epoch + 1) % 100 == 0:
            train_acc = evaluate_accuracy(model, X_train_tensor, y_train_tensor)
            test_acc = evaluate_accuracy(model, X_test_tensor, y_test_tensor)

            print(f"Epoch {epoch + 1:4d} | "
                  f"Loss: {loss:.4f} | "
                  f"Train Acc: {train_acc:.2%} | "
                  f"Test Acc: {test_acc:.2%}")

    print("-" * 60)
    print()

    # Final evaluation
    print("Final Results:")
    train_acc = evaluate_accuracy(model, X_train_tensor, y_train_tensor)
    test_acc = evaluate_accuracy(model, X_test_tensor, y_test_tensor)
    print(f"  Training Accuracy: {train_acc:.2%}")
    print(f"  Test Accuracy: {test_acc:.2%}")
    print()

    # Show some predictions
    print("Sample Predictions:")
    print("-" * 60)
    test_samples = X_test[:5]
    test_labels = y_test[:5]
    test_tensor = tensor(test_samples, requires_grad=False)
    predictions = model.forward(test_tensor)

    for i, (x, y_true, y_pred) in enumerate(zip(test_samples, test_labels, predictions.data)):
        pred_class = 1 if y_pred[0] > 0.5 else 0
        correct = "✓" if pred_class == y_true[0] else "✗"
        print(f"  Sample {i+1}: x1={x[0]:6.3f}, x2={x[1]:6.3f} | "
              f"True: {int(y_true[0])} | Pred: {y_pred[0]:.3f} ({pred_class}) {correct}")

    print()
    print("=" * 60)
    print("Training complete!")
    print("=" * 60)


if __name__ == "__main__":
    main()
