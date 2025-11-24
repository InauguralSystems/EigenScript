"""
Automatic Differentiation for EigenScript.

Implements computational graphs and backpropagation for neural networks
and gradient-based optimization, building on EigenScript's geometric
semantic model and the WHY interrogative.
"""

import numpy as np
from typing import Optional, List, Callable, Dict, Set, Tuple


class Tensor:
    """
    Tensor with automatic differentiation support.

    Extends EigenScript's Matrix with gradient tracking for backpropagation.

    Attributes:
        data: NumPy array containing tensor data
        grad: Gradient accumulated during backpropagation
        requires_grad: Whether to track gradients for this tensor
        _backward: Function to compute gradients during backprop
        _prev: Previous tensors in computational graph
        _op: Operation that created this tensor

    Example:
        >>> x = Tensor([[1, 2], [3, 4]], requires_grad=True)
        >>> y = x @ x.T
        >>> y.backward()
        >>> print(x.grad)
    """

    def __init__(
        self,
        data: np.ndarray,
        grad: Optional[np.ndarray] = None,
        requires_grad: bool = False,
        _backward: Optional[Callable] = None,
        _prev: Optional[Set["Tensor"]] = None,
        _op: str = "",
    ):
        """
        Initialize a Tensor.

        Args:
            data: NumPy array containing tensor data
            grad: Optional gradient array
            requires_grad: Whether to track gradients
            _backward: Backward function for gradient computation
            _prev: Set of parent tensors in computational graph
            _op: Operation that created this tensor
        """
        self.data = data
        self.requires_grad = requires_grad
        self._backward = _backward
        self._prev = _prev if _prev is not None else set()
        self._op = _op

        # Always initialize gradient for consistency
        if grad is None:
            self.grad = np.zeros_like(self.data)
        else:
            self.grad = grad

    def __hash__(self):
        """Make Tensor hashable based on identity."""
        return id(self)

    def __eq__(self, other):
        """Equality based on identity for graph operations."""
        return self is other

    @property
    def shape(self) -> Tuple[int, ...]:
        """Shape of the tensor."""
        return self.data.shape

    def __repr__(self) -> str:
        grad_str = ", requires_grad=True" if self.requires_grad else ""
        return f"Tensor({self.data.tolist()}{grad_str})"

    def zero_grad(self):
        """Zero out accumulated gradients."""
        if self.requires_grad:
            self.grad = np.zeros_like(self.data)
        for child in self._prev:
            child.zero_grad()

    def backward(self, gradient: Optional[np.ndarray] = None):
        """
        Compute gradients via backpropagation.

        Args:
            gradient: Gradient from upstream (defaults to ones)

        Example:
            >>> x = Tensor([[1, 2]], requires_grad=True)
            >>> y = x * 2
            >>> z = y.sum()
            >>> z.backward()  # Computes dz/dx
        """
        if not self.requires_grad:
            return

        # Initialize gradient if this is the output
        if gradient is None:
            if self.data.size == 1:
                gradient = np.ones_like(self.data)
            else:
                raise RuntimeError("Gradient must be specified for non-scalar backward")

        # Accumulate gradient
        if self.grad is None:
            self.grad = gradient
        else:
            self.grad += gradient

        # Build topological ordering
        topo = []
        visited = set()

        def build_topo(tensor):
            if tensor not in visited:
                visited.add(tensor)
                for parent in tensor._prev:
                    build_topo(parent)
                topo.append(tensor)

        build_topo(self)

        # Backpropagate through computational graph
        for tensor in reversed(topo):
            if tensor._backward is not None:
                tensor._backward()

    # ========== Arithmetic Operations ==========

    def __add__(self, other: "Tensor") -> "Tensor":
        """Element-wise addition with gradient tracking."""
        other = other if isinstance(other, Tensor) else Tensor(np.array(other))
        out = Tensor(
            self.data + other.data,
            requires_grad=self.requires_grad or other.requires_grad,
        )
        out._prev = {self, other}
        out._op = "add"

        def _backward():
            if self.requires_grad:
                # Gradient of addition flows through unchanged
                grad = out.grad.copy()
                # Handle broadcasting: sum out dimensions that were broadcasted
                grad = self._unbroadcast(grad, self.data.shape)
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

            if other.requires_grad:
                grad = out.grad.copy()
                # Handle broadcasting: sum out dimensions that were broadcasted
                grad = other._unbroadcast(grad, other.data.shape)
                if other.grad is None:
                    other.grad = grad
                else:
                    other.grad += grad

        out._backward = _backward
        return out

    @staticmethod
    def _unbroadcast(grad: np.ndarray, shape: Tuple[int, ...]) -> np.ndarray:
        """
        Reverse broadcasting by summing gradient along broadcasted dimensions.

        Args:
            grad: Gradient array (potentially broadcasted shape)
            shape: Original shape before broadcasting

        Returns:
            Gradient reduced to original shape
        """
        # Sum out added dims
        ndims_added = len(grad.shape) - len(shape)
        for _ in range(ndims_added):
            grad = grad.sum(axis=0)

        # Sum along dims that were 1 in original shape
        for i, (grad_dim, orig_dim) in enumerate(zip(grad.shape, shape)):
            if orig_dim == 1 and grad_dim > 1:
                grad = grad.sum(axis=i, keepdims=True)

        return grad

    def __mul__(self, other: "Tensor") -> "Tensor":
        """Element-wise multiplication with gradient tracking."""
        other = other if isinstance(other, Tensor) else Tensor(np.array(other))
        out = Tensor(
            self.data * other.data,
            requires_grad=self.requires_grad or other.requires_grad,
        )
        out._prev = {self, other}
        out._op = "mul"

        def _backward():
            # d(xy)/dx = y, d(xy)/dy = x
            if self.requires_grad:
                grad = out.grad * other.data
                # Handle broadcasting
                grad = self._unbroadcast(grad, self.data.shape)
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

            if other.requires_grad:
                grad = out.grad * self.data
                # Handle broadcasting
                grad = other._unbroadcast(grad, other.data.shape)
                if other.grad is None:
                    other.grad = grad
                else:
                    other.grad += grad

        out._backward = _backward
        return out

    def __matmul__(self, other: "Tensor") -> "Tensor":
        """Matrix multiplication with gradient tracking."""
        out = Tensor(
            self.data @ other.data,
            requires_grad=self.requires_grad or other.requires_grad,
        )
        out._prev = {self, other}
        out._op = "matmul"

        def _backward():
            # d(AB)/dA = grad @ B^T
            # d(AB)/dB = A^T @ grad
            if self.requires_grad:
                grad = out.grad @ other.data.T
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

            if other.requires_grad:
                grad = self.data.T @ out.grad
                if other.grad is None:
                    other.grad = grad
                else:
                    other.grad += grad

        out._backward = _backward
        return out

    def __neg__(self) -> "Tensor":
        """Negation with gradient tracking."""
        return self * Tensor(np.array(-1.0))

    def __sub__(self, other: "Tensor") -> "Tensor":
        """Subtraction with gradient tracking."""
        return self + (-other)

    def __truediv__(self, other: "Tensor") -> "Tensor":
        """Division with gradient tracking."""
        return self * (other ** Tensor(np.array(-1.0)))

    def __pow__(self, other: "Tensor") -> "Tensor":
        """Power operation with gradient tracking."""
        other = other if isinstance(other, Tensor) else Tensor(np.array(other))
        out = Tensor(
            self.data**other.data,
            requires_grad=self.requires_grad or other.requires_grad,
        )
        out._prev = {self, other}
        out._op = "pow"

        def _backward():
            # d(x^n)/dx = n * x^(n-1)
            if self.requires_grad:
                grad = out.grad * other.data * (self.data ** (other.data - 1))
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

            # d(a^x)/dx = a^x * ln(a)
            if other.requires_grad:
                grad = out.grad * out.data * np.log(np.maximum(self.data, 1e-10))
                if other.grad is None:
                    other.grad = grad
                else:
                    other.grad += grad

        out._backward = _backward
        return out

    # ========== Activation Functions ==========

    def relu(self) -> "Tensor":
        """
        ReLU activation: max(0, x).

        Returns:
            Tensor with ReLU applied

        Example:
            >>> x = Tensor([[-1, 2], [3, -4]], requires_grad=True)
            >>> y = x.relu()  # [[0, 2], [3, 0]]
        """
        out = Tensor(np.maximum(0, self.data), requires_grad=self.requires_grad)
        out._prev = {self}
        out._op = "relu"

        def _backward():
            if self.requires_grad:
                # Gradient is 1 where x > 0, else 0
                grad = out.grad * (self.data > 0)
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

        out._backward = _backward
        return out

    def sigmoid(self) -> "Tensor":
        """
        Sigmoid activation: 1 / (1 + exp(-x)).

        Returns:
            Tensor with sigmoid applied
        """
        sig = 1 / (1 + np.exp(-self.data))
        out = Tensor(sig, requires_grad=self.requires_grad)
        out._prev = {self}
        out._op = "sigmoid"

        def _backward():
            if self.requires_grad:
                # d(sigmoid)/dx = sigmoid * (1 - sigmoid)
                grad = out.grad * sig * (1 - sig)
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

        out._backward = _backward
        return out

    def tanh(self) -> "Tensor":
        """
        Tanh activation: (exp(x) - exp(-x)) / (exp(x) + exp(-x)).

        Returns:
            Tensor with tanh applied
        """
        t = np.tanh(self.data)
        out = Tensor(t, requires_grad=self.requires_grad)
        out._prev = {self}
        out._op = "tanh"

        def _backward():
            if self.requires_grad:
                # d(tanh)/dx = 1 - tanh^2
                grad = out.grad * (1 - t**2)
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

        out._backward = _backward
        return out

    def softmax(self, axis: int = -1) -> "Tensor":
        """
        Softmax activation: exp(x_i) / sum(exp(x_j)).

        Args:
            axis: Axis along which to compute softmax

        Returns:
            Tensor with softmax applied
        """
        # Numerical stability: subtract max
        exp_shifted = np.exp(self.data - np.max(self.data, axis=axis, keepdims=True))
        softmax_out = exp_shifted / np.sum(exp_shifted, axis=axis, keepdims=True)

        out = Tensor(softmax_out, requires_grad=self.requires_grad)
        out._prev = {self}
        out._op = "softmax"

        def _backward():
            if self.requires_grad:
                # Jacobian of softmax is s_i(δ_ij - s_j)
                # For simplicity, use: grad = softmax * (grad - (grad * softmax).sum())
                s = softmax_out
                grad = s * (out.grad - (out.grad * s).sum(axis=axis, keepdims=True))
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

        out._backward = _backward
        return out

    # ========== Reduction Operations ==========

    def sum(self, axis: Optional[int] = None, keepdims: bool = False) -> "Tensor":
        """Sum reduction with gradient tracking."""
        out = Tensor(
            np.sum(self.data, axis=axis, keepdims=keepdims),
            requires_grad=self.requires_grad,
        )
        out._prev = {self}
        out._op = "sum"

        def _backward():
            if self.requires_grad:
                # Gradient broadcasts back to original shape
                grad = out.grad
                if axis is not None and not keepdims:
                    grad = np.expand_dims(grad, axis=axis)
                grad = np.broadcast_to(grad, self.data.shape)

                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

        out._backward = _backward
        return out

    def mean(self, axis: Optional[int] = None, keepdims: bool = False) -> "Tensor":
        """Mean reduction with gradient tracking."""
        out = Tensor(
            np.mean(self.data, axis=axis, keepdims=keepdims),
            requires_grad=self.requires_grad,
        )
        out._prev = {self}
        out._op = "mean"

        def _backward():
            if self.requires_grad:
                # Gradient is divided by number of elements
                if axis is None:
                    n = self.data.size
                else:
                    n = self.data.shape[axis]

                grad = out.grad / n
                if axis is not None and not keepdims:
                    grad = np.expand_dims(grad, axis=axis)
                grad = np.broadcast_to(grad, self.data.shape)

                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

        out._backward = _backward
        return out

    # ========== Shape Operations ==========

    def reshape(self, *shape) -> "Tensor":
        """Reshape tensor while preserving gradients."""
        out = Tensor(self.data.reshape(shape), requires_grad=self.requires_grad)
        out._prev = {self}
        out._op = "reshape"

        original_shape = self.data.shape

        def _backward():
            if self.requires_grad:
                grad = out.grad.reshape(original_shape)
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

        out._backward = _backward
        return out

    def transpose(self) -> "Tensor":
        """Transpose tensor while preserving gradients."""
        out = Tensor(self.data.T, requires_grad=self.requires_grad)
        out._prev = {self}
        out._op = "transpose"

        def _backward():
            if self.requires_grad:
                grad = out.grad.T
                if self.grad is None:
                    self.grad = grad
                else:
                    self.grad += grad

        out._backward = _backward
        return out

    @property
    def T(self) -> "Tensor":
        """Transpose property."""
        return self.transpose()


def tensor(data, requires_grad: bool = False) -> Tensor:
    """
    Create a tensor from data.

    Args:
        data: Array-like data
        requires_grad: Whether to track gradients

    Returns:
        Tensor object

    Example:
        >>> x = tensor([[1, 2], [3, 4]], requires_grad=True)
    """
    return Tensor(np.array(data, dtype=np.float64), requires_grad=requires_grad)
