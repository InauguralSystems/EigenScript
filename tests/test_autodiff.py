"""
Tests for automatic differentiation system.

Tests gradient computation, backpropagation, and neural network operations.
"""

import pytest
import numpy as np
from eigenscript.ai.autodiff import Tensor, tensor


class TestTensorCreation:
    """Test tensor creation and initialization."""

    def test_create_tensor_from_list(self):
        """Test creating tensor from Python list."""
        t = tensor([[1, 2], [3, 4]])
        assert t.shape == (2, 2)
        assert np.allclose(t.data, [[1, 2], [3, 4]])

    def test_tensor_requires_grad(self):
        """Test gradient tracking flag."""
        t = tensor([[1, 2]], requires_grad=True)
        assert t.requires_grad
        assert t.grad is not None
        assert np.allclose(t.grad, np.zeros_like(t.data))

    def test_tensor_no_grad(self):
        """Test tensor without gradient tracking."""
        t = tensor([[1, 2]], requires_grad=False)
        assert not t.requires_grad
        assert t.grad is not None  # Still initialized for consistency

    def test_tensor_from_numpy(self):
        """Test creating tensor from numpy array."""
        arr = np.array([[1, 2], [3, 4]])
        t = Tensor(arr, requires_grad=True)
        assert t.shape == (2, 2)


class TestBasicGradients:
    """Test basic gradient computation."""

    def test_addition_gradient(self):
        """Test gradient of addition."""
        x = tensor([[1, 2]], requires_grad=True)
        y = tensor([[3, 4]], requires_grad=True)
        z = x + y

        z.backward(np.ones_like(z.data))

        # dz/dx = 1, dz/dy = 1
        assert np.allclose(x.grad, [[1, 1]])
        assert np.allclose(y.grad, [[1, 1]])

    def test_multiplication_gradient(self):
        """Test gradient of element-wise multiplication."""
        x = tensor([[2, 3]], requires_grad=True)
        y = tensor([[4, 5]], requires_grad=True)
        z = x * y  # [8, 15]

        z.backward(np.ones_like(z.data))

        # dz/dx = y, dz/dy = x
        assert np.allclose(x.grad, [[4, 5]])
        assert np.allclose(y.grad, [[2, 3]])

    def test_matmul_gradient(self):
        """Test gradient of matrix multiplication."""
        x = tensor([[1, 2]], requires_grad=True)  # 1x2
        y = tensor([[3], [4]], requires_grad=True)  # 2x1
        z = x @ y  # 1x1, result: [[11]]

        z.backward()

        # dz/dx = y^T = [[3, 4]]
        # dz/dy = x^T = [[1], [2]]
        assert np.allclose(x.grad, [[3, 4]])
        assert np.allclose(y.grad, [[1], [2]])

    def test_power_gradient(self):
        """Test gradient of power operation."""
        x = tensor([[2, 3]], requires_grad=True)
        n = tensor([[2, 2]], requires_grad=False)
        z = x**n  # [4, 9]

        z.backward(np.ones_like(z.data))

        # dz/dx = 2*x = [4, 6]
        assert np.allclose(x.grad, [[4, 6]])

    def test_zero_grad(self):
        """Test zeroing gradients."""
        x = tensor([[1, 2]], requires_grad=True)
        y = x * tensor([[2, 2]])
        y.backward(np.ones_like(y.data))

        assert not np.allclose(x.grad, 0)

        x.zero_grad()
        assert np.allclose(x.grad, 0)


class TestActivationFunctions:
    """Test activation function gradients."""

    def test_relu_forward(self):
        """Test ReLU forward pass."""
        x = tensor([[-1, 2], [3, -4]])
        y = x.relu()
        assert np.allclose(y.data, [[0, 2], [3, 0]])

    def test_relu_backward(self):
        """Test ReLU gradient."""
        x = tensor([[-1, 2], [3, -4]], requires_grad=True)
        y = x.relu()
        y.backward(np.ones_like(y.data))

        # Gradient is 1 where x > 0, else 0
        expected = [[0, 1], [1, 0]]
        assert np.allclose(x.grad, expected)

    def test_sigmoid_forward(self):
        """Test sigmoid forward pass."""
        x = tensor([[0, 1, -1]])
        y = x.sigmoid()

        # sigmoid(0) = 0.5, sigmoid(1) ≈ 0.73, sigmoid(-1) ≈ 0.27
        assert np.allclose(y.data[0, 0], 0.5, atol=0.01)
        assert y.data[0, 1] > 0.7
        assert y.data[0, 2] < 0.3

    def test_sigmoid_backward(self):
        """Test sigmoid gradient."""
        x = tensor([[0]], requires_grad=True)
        y = x.sigmoid()
        y.backward()

        # At x=0: sigmoid=0.5, gradient = 0.5*(1-0.5) = 0.25
        assert np.allclose(x.grad, 0.25, atol=0.01)

    def test_tanh_forward(self):
        """Test tanh forward pass."""
        x = tensor([[0, 1, -1]])
        y = x.tanh()

        # tanh(0) = 0, tanh(1) ≈ 0.76, tanh(-1) ≈ -0.76
        assert np.allclose(y.data[0, 0], 0, atol=0.01)
        assert y.data[0, 1] > 0.7
        assert y.data[0, 2] < -0.7

    def test_tanh_backward(self):
        """Test tanh gradient."""
        x = tensor([[0]], requires_grad=True)
        y = x.tanh()
        y.backward()

        # At x=0: tanh=0, gradient = 1 - 0^2 = 1
        assert np.allclose(x.grad, 1, atol=0.01)

    def test_softmax_forward(self):
        """Test softmax forward pass."""
        x = tensor([[1, 2, 3]])
        y = x.softmax()

        # Softmax should sum to 1
        assert np.allclose(np.sum(y.data), 1.0)
        # Probabilities should be positive
        assert np.all(y.data > 0)
        # Higher inputs should have higher probabilities
        assert y.data[0, 2] > y.data[0, 1] > y.data[0, 0]


class TestReductions:
    """Test reduction operations."""

    def test_sum_all(self):
        """Test sum over all elements."""
        x = tensor([[1, 2], [3, 4]], requires_grad=True)
        y = x.sum()

        assert y.data == 10

        y.backward()
        # Gradient flows equally to all elements
        assert np.allclose(x.grad, [[1, 1], [1, 1]])

    def test_sum_axis(self):
        """Test sum along axis."""
        x = tensor([[1, 2], [3, 4]], requires_grad=True)
        y = x.sum(axis=0)  # Sum columns: [4, 6]

        assert np.allclose(y.data, [4, 6])

        y.backward(np.ones_like(y.data))
        assert np.allclose(x.grad, [[1, 1], [1, 1]])

    def test_mean_all(self):
        """Test mean over all elements."""
        x = tensor([[2, 4], [6, 8]], requires_grad=True)
        y = x.mean()

        assert y.data == 5

        y.backward()
        # Gradient is 1/n for each element
        assert np.allclose(x.grad, [[0.25, 0.25], [0.25, 0.25]])


class TestShapeOperations:
    """Test shape manipulation with gradients."""

    def test_reshape(self):
        """Test reshape with gradient flow."""
        x = tensor([[1, 2], [3, 4]], requires_grad=True)
        y = x.reshape(4, 1)

        assert y.shape == (4, 1)

        y.backward(np.ones_like(y.data))
        # Gradient should flow back to original shape
        assert x.grad.shape == (2, 2)
        assert np.allclose(x.grad, [[1, 1], [1, 1]])

    def test_transpose(self):
        """Test transpose with gradient flow."""
        x = tensor([[1, 2, 3], [4, 5, 6]], requires_grad=True)
        y = x.transpose()

        assert y.shape == (3, 2)

        y.backward(np.ones_like(y.data))
        # Gradient should transpose back
        assert x.grad.shape == (2, 3)
        assert np.allclose(x.grad, [[1, 1, 1], [1, 1, 1]])

    def test_transpose_property(self):
        """Test .T property."""
        x = tensor([[1, 2], [3, 4]], requires_grad=True)
        y = x.T

        assert y.shape == (2, 2)
        assert np.allclose(y.data, [[1, 3], [2, 4]])


class TestComputationalGraph:
    """Test complex computational graphs."""

    def test_chain_rule(self):
        """Test chain rule through multiple operations."""
        x = tensor([[2]], requires_grad=True)
        y = x * x  # x^2 = 4
        z = y + y  # 2x^2 = 8
        w = z * tensor([[3]])  # 6x^2 = 24

        w.backward()

        # dw/dx = d(6x^2)/dx = 12x = 24
        assert np.allclose(x.grad, [[24]])

    def test_multipath_gradient(self):
        """Test gradient accumulation from multiple paths."""
        x = tensor([[2]], requires_grad=True)
        y = x + x  # Two paths from x to y

        y.backward()

        # Gradient should accumulate from both paths
        assert np.allclose(x.grad, [[2]])

    def test_deep_network(self):
        """Test gradient through deep computation."""
        x = tensor([[1, 2]], requires_grad=True)

        # Simulate a simple 2-layer network
        w1 = tensor([[1, 3], [2, 4]], requires_grad=True)
        h = x @ w1  # Hidden layer: [5, 11]

        w2 = tensor([[1], [1]], requires_grad=True)
        y = h @ w2  # Output: [[16]]

        y.backward()

        # All parameters should have gradients
        assert x.grad is not None
        assert w1.grad is not None
        assert w2.grad is not None

        # Check gradient shapes
        assert x.grad.shape == x.shape
        assert w1.grad.shape == w1.shape
        assert w2.grad.shape == w2.shape


class TestNeuralNetworkExample:
    """Test realistic neural network scenario."""

    def test_simple_linear_regression(self):
        """Test gradient descent on simple linear regression."""
        # Data: y = 2x + 1
        x_data = tensor([[1], [2], [3]], requires_grad=False)
        y_true = tensor([[3], [5], [7]], requires_grad=False)

        # Parameters
        w = tensor([[2]], requires_grad=True)
        b = tensor([[0]], requires_grad=True)

        # Forward pass
        y_pred = x_data @ w + b

        # Loss: MSE
        diff = y_pred - y_true
        loss = (diff * diff).mean()

        # Backward pass
        loss.backward()

        # Gradients should be computed
        assert w.grad is not None
        assert b.grad is not None

        # Gradient descent step
        learning_rate = 0.01
        w_new = w.data - learning_rate * w.grad
        b_new = b.data - learning_rate * b.grad

        # Loss should decrease after update
        w_updated = tensor(w_new, requires_grad=True)
        b_updated = tensor(b_new, requires_grad=True)

        y_pred_new = x_data @ w_updated + b_updated
        diff_new = y_pred_new - y_true
        loss_new = (diff_new * diff_new).mean()

        # New loss should be smaller (or equal if already optimal)
        assert loss_new.data <= loss.data + 1e-6

    def test_two_layer_network(self):
        """Test 2-layer neural network forward and backward."""
        # Input
        x = tensor([[1, 2]], requires_grad=False)

        # Layer 1
        w1 = tensor([[0.5, 0.3], [0.2, 0.4]], requires_grad=True)
        b1 = tensor([[0.1, 0.1]], requires_grad=True)
        h = (x @ w1 + b1).relu()

        # Layer 2
        w2 = tensor([[0.6], [0.7]], requires_grad=True)
        b2 = tensor([[0.05]], requires_grad=True)
        y = h @ w2 + b2

        # Backward pass
        y.backward()

        # All parameters should have gradients
        assert w1.grad is not None
        assert b1.grad is not None
        assert w2.grad is not None
        assert b2.grad is not None


class TestEdgeCases:
    """Test edge cases and error handling."""

    def test_scalar_backward(self):
        """Test backward on scalar output."""
        x = tensor([[5]], requires_grad=True)
        y = x * x
        y.backward()  # Should work without explicit gradient

        assert np.allclose(x.grad, [[10]])

    def test_no_grad_backward(self):
        """Test backward on tensor without gradient tracking."""
        x = tensor([[1, 2]], requires_grad=False)
        y = x * x
        y.backward()  # Should not error, just do nothing

        # No error should occur

    def test_gradient_accumulation(self):
        """Test that gradients accumulate properly."""
        x = tensor([[1]], requires_grad=True)

        y1 = x * tensor([[2]])
        y1.backward()
        grad_after_first = x.grad.copy()

        y2 = x * tensor([[3]])
        y2.backward()
        grad_after_second = x.grad

        # Gradient should have accumulated
        assert np.allclose(grad_after_second, grad_after_first + [[3]])
