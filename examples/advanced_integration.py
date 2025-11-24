"""
Advanced Integration Example: Python Autodiff + EigenScript Modules

Demonstrates how to:
1. Train a neural network using Python's Tensor class
2. Use EigenScript modules for preprocessing and metrics
3. Build modular, reusable neural network components
4. Implement advanced features like momentum and learning rate decay
"""

import numpy as np
from eigenscript.ai.autodiff import tensor, Tensor
from eigenscript.semantic.matrix import Matrix


class Layer:
    """Base class for neural network layers."""

    def forward(self, x):
        raise NotImplementedError

    def parameters(self):
        return []


class Dense(Layer):
    """Fully connected (dense) layer with configurable activation."""

    def __init__(self, input_size, output_size, activation='relu', init='he'):
        """
        Initialize dense layer.

        Args:
            input_size: Number of input features
            output_size: Number of output neurons
            activation: Activation function ('relu', 'sigmoid', 'tanh', or None)
            init: Weight initialization ('he', 'xavier', or 'zero')
        """
        self.input_size = input_size
        self.output_size = output_size
        self.activation = activation

        # Initialize weights based on initialization scheme
        if init == 'he':
            scale = np.sqrt(2.0 / input_size)
        elif init == 'xavier':
            scale = np.sqrt(1.0 / input_size)
        else:
            scale = 0.01

        self.W = tensor(
            np.random.randn(input_size, output_size) * scale,
            requires_grad=True
        )
        self.b = tensor(np.zeros((1, output_size)), requires_grad=True)

    def forward(self, x):
        """Forward pass."""
        z = x @ self.W + self.b

        if self.activation == 'relu':
            return z.relu()
        elif self.activation == 'sigmoid':
            return z.sigmoid()
        elif self.activation == 'tanh':
            return z.tanh()
        else:
            return z

    def parameters(self):
        """Return trainable parameters."""
        return [self.W, self.b]


class Sequential:
    """Sequential model container."""

    def __init__(self, *layers):
        """Initialize with a sequence of layers."""
        self.layers = list(layers)

    def forward(self, x):
        """Forward pass through all layers."""
        for layer in self.layers:
            x = layer.forward(x)
        return x

    def parameters(self):
        """Return all parameters from all layers."""
        params = []
        for layer in self.layers:
            params.extend(layer.parameters())
        return params

    def zero_grad(self):
        """Zero gradients for all parameters."""
        for param in self.parameters():
            param.zero_grad()


class SGDOptimizer:
    """SGD optimizer with momentum."""

    def __init__(self, parameters, lr=0.01, momentum=0.0):
        """
        Initialize optimizer.

        Args:
            parameters: List of tensors to optimize
            lr: Learning rate
            momentum: Momentum coefficient (0 = no momentum)
        """
        self.parameters = parameters
        self.lr = lr
        self.momentum = momentum

        # Initialize velocity for momentum
        self.velocities = [np.zeros_like(p.data) for p in parameters]

    def step(self):
        """Perform one optimization step."""
        for i, param in enumerate(self.parameters):
            if self.momentum > 0:
                # Momentum update
                self.velocities[i] = (
                    self.momentum * self.velocities[i] - self.lr * param.grad
                )
                param.data += self.velocities[i]
            else:
                # Simple SGD
                param.data -= self.lr * param.grad

    def set_lr(self, new_lr):
        """Update learning rate."""
        self.lr = new_lr


class LRScheduler:
    """Learning rate scheduler with exponential decay."""

    def __init__(self, optimizer, decay_rate=0.95, decay_every=100):
        """
        Initialize scheduler.

        Args:
            optimizer: Optimizer to schedule
            decay_rate: Multiplicative decay factor
            decay_every: Apply decay every N steps
        """
        self.optimizer = optimizer
        self.initial_lr = optimizer.lr
        self.decay_rate = decay_rate
        self.decay_every = decay_every
        self.step_count = 0

    def step(self):
        """Update learning rate according to schedule."""
        self.step_count += 1
        if self.step_count % self.decay_every == 0:
            new_lr = self.optimizer.lr * self.decay_rate
            self.optimizer.set_lr(new_lr)
            return new_lr
        return self.optimizer.lr


def mse_loss(y_pred, y_true):
    """Mean squared error loss."""
    diff = y_pred - y_true
    return (diff * diff).mean()


def compute_metrics(y_pred, y_true, threshold=0.5):
    """Compute classification metrics."""
    predictions = (y_pred.data > threshold).astype(np.float64)
    targets = y_true.data

    # Accuracy
    accuracy = (predictions == targets).mean()

    # Precision, Recall, F1
    tp = ((predictions == 1) & (targets == 1)).sum()
    fp = ((predictions == 1) & (targets == 0)).sum()
    fn = ((predictions == 0) & (targets == 1)).sum()

    precision = tp / (tp + fp + 1e-7)
    recall = tp / (tp + fn + 1e-7)
    f1 = 2 * precision * recall / (precision + recall + 1e-7)

    return {
        'accuracy': accuracy,
        'precision': precision,
        'recall': recall,
        'f1': f1
    }


def generate_spiral_data(n_samples=100, noise=0.1):
    """Generate spiral dataset for binary classification."""
    np.random.seed(42)
    n_per_class = n_samples // 2

    # Class 0: inner spiral
    theta0 = np.linspace(0, 2 * np.pi, n_per_class)
    r0 = np.linspace(0.5, 1.5, n_per_class)
    X0 = np.column_stack([
        r0 * np.cos(theta0) + noise * np.random.randn(n_per_class),
        r0 * np.sin(theta0) + noise * np.random.randn(n_per_class)
    ])
    y0 = np.zeros((n_per_class, 1))

    # Class 1: outer spiral
    theta1 = np.linspace(np.pi, 3 * np.pi, n_per_class)
    r1 = np.linspace(0.5, 1.5, n_per_class)
    X1 = np.column_stack([
        r1 * np.cos(theta1) + noise * np.random.randn(n_per_class),
        r1 * np.sin(theta1) + noise * np.random.randn(n_per_class)
    ])
    y1 = np.ones((n_per_class, 1))

    # Combine and shuffle
    X = np.vstack([X0, X1])
    y = np.vstack([y0, y1])

    indices = np.random.permutation(n_samples)
    return X[indices], y[indices]


def main():
    """Main training loop with advanced features."""
    print("=" * 70)
    print("Advanced Integration: Python Autodiff + EigenScript Modules")
    print("=" * 70)
    print()

    # Generate data
    print("Generating spiral dataset...")
    X_train, y_train = generate_spiral_data(n_samples=400, noise=0.15)
    X_test, y_test = generate_spiral_data(n_samples=100, noise=0.15)

    X_train_tensor = tensor(X_train, requires_grad=False)
    y_train_tensor = tensor(y_train, requires_grad=False)
    X_test_tensor = tensor(X_test, requires_grad=False)
    y_test_tensor = tensor(y_test, requires_grad=False)

    print(f"Training samples: {len(X_train)}")
    print(f"Test samples: {len(X_test)}")
    print()

    # Build model
    print("Building neural network...")
    model = Sequential(
        Dense(2, 16, activation='relu', init='he'),
        Dense(16, 8, activation='relu', init='he'),
        Dense(8, 1, activation='sigmoid', init='xavier')
    )
    print(f"  Layer 1: 2 → 16 (ReLU)")
    print(f"  Layer 2: 16 → 8 (ReLU)")
    print(f"  Layer 3: 8 → 1 (Sigmoid)")
    print(f"  Total parameters: {sum(p.data.size for p in model.parameters())}")
    print()

    # Create optimizer and scheduler
    optimizer = SGDOptimizer(model.parameters(), lr=1.0, momentum=0.9)
    scheduler = LRScheduler(optimizer, decay_rate=0.95, decay_every=200)

    print(f"Optimizer: SGD with momentum={optimizer.momentum}")
    print(f"Initial learning rate: {optimizer.lr}")
    print(f"LR decay: {scheduler.decay_rate} every {scheduler.decay_every} steps")
    print()

    # Training loop
    print("Training...")
    print("-" * 70)
    n_epochs = 1000

    for epoch in range(n_epochs):
        # Forward pass
        y_pred = model.forward(X_train_tensor)
        loss = mse_loss(y_pred, y_train_tensor)

        # Backward pass
        model.zero_grad()
        loss.backward()

        # Optimization step
        optimizer.step()
        current_lr = scheduler.step()

        # Evaluate every 100 epochs
        if (epoch + 1) % 100 == 0:
            with_no_grad = model.forward(X_test_tensor)
            metrics = compute_metrics(with_no_grad, y_test_tensor)

            print(f"Epoch {epoch + 1:4d} | "
                  f"Loss: {loss.data.item():.4f} | "
                  f"Test Acc: {metrics['accuracy']:.2%} | "
                  f"F1: {metrics['f1']:.3f} | "
                  f"LR: {current_lr:.4f}")

    print("-" * 70)
    print()

    # Final evaluation
    print("Final Evaluation:")
    y_pred_train = model.forward(X_train_tensor)
    y_pred_test = model.forward(X_test_tensor)

    train_metrics = compute_metrics(y_pred_train, y_train_tensor)
    test_metrics = compute_metrics(y_pred_test, y_test_tensor)

    print(f"  Training Set:")
    print(f"    Accuracy:  {train_metrics['accuracy']:.2%}")
    print(f"    Precision: {train_metrics['precision']:.3f}")
    print(f"    Recall:    {train_metrics['recall']:.3f}")
    print(f"    F1 Score:  {train_metrics['f1']:.3f}")
    print()
    print(f"  Test Set:")
    print(f"    Accuracy:  {test_metrics['accuracy']:.2%}")
    print(f"    Precision: {test_metrics['precision']:.3f}")
    print(f"    Recall:    {test_metrics['recall']:.3f}")
    print(f"    F1 Score:  {test_metrics['f1']:.3f}")
    print()

    # Demonstrate Matrix integration
    print("Matrix Integration Example:")
    print("-" * 70)
    W1 = model.layers[0].W.data
    print(f"Layer 1 weight matrix shape: {W1.shape}")

    # Convert to EigenScript Matrix
    eigen_matrix = Matrix(W1)
    print(f"Converted to EigenScript Matrix: {eigen_matrix.shape}")

    # Transpose for demonstration
    W1_T = eigen_matrix.transpose()
    print(f"Transposed matrix shape: {W1_T.shape}")

    # Compute Gram matrix (W^T W) which is square
    gram = W1_T.matmul(eigen_matrix)
    print(f"Gram matrix (W^T W) shape: {gram.shape}")
    print(f"Gram matrix determinant: {gram.det():.6e}")
    print(f"Gram matrix trace: {gram.trace():.4f}")

    # Matrix norms
    frobenius_norm = eigen_matrix.frobenius_norm()
    print(f"Weight matrix Frobenius norm: {frobenius_norm:.4f}")
    print()

    print("=" * 70)
    print("Training complete! Successfully integrated:")
    print("  ✓ Python Tensor autodiff system")
    print("  ✓ Modular neural network architecture")
    print("  ✓ Advanced optimizers (SGD + Momentum)")
    print("  ✓ Learning rate scheduling")
    print("  ✓ EigenScript Matrix operations")
    print("=" * 70)


if __name__ == "__main__":
    main()
