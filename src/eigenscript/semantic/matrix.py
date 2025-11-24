"""
Matrix and Tensor operations for EigenScript.

Provides efficient numerical computing capabilities for AI/ML applications,
building on EigenScript's geometric semantic model.
"""

import numpy as np
from typing import Union, List, Tuple, Optional
from eigenscript.semantic.lrvm import LRVMVector


class Matrix:
    """
    Matrix representation in EigenScript.

    Wraps NumPy arrays to provide matrix operations while integrating
    with EigenScript's geometric semantic model.

    Attributes:
        data: NumPy array containing matrix data
        shape: Tuple of (rows, columns)

    Example:
        >>> m = Matrix([[1, 2], [3, 4]])
        >>> m.shape
        (2, 2)
        >>> m.transpose()
        Matrix([[1, 3], [2, 4]])
    """

    def __init__(self, data: Union[np.ndarray, List[List[float]], List[float]]):
        """
        Initialize a matrix.

        Args:
            data: Matrix data as 2D array, list of lists, or flat list
        """
        if isinstance(data, list):
            # Handle both 2D and 1D lists
            if data and isinstance(data[0], (list, np.ndarray)):
                self.data = np.array(data, dtype=np.float64)
            else:
                # 1D list - treat as row vector
                self.data = np.array([data], dtype=np.float64)
        elif isinstance(data, np.ndarray):
            self.data = np.array(data, dtype=np.float64)
            # Ensure at least 2D
            if self.data.ndim == 1:
                self.data = self.data.reshape(1, -1)
        else:
            raise TypeError(f"Cannot create Matrix from {type(data)}")

        self.shape = self.data.shape

    @property
    def rows(self) -> int:
        """Number of rows."""
        return self.shape[0]

    @property
    def cols(self) -> int:
        """Number of columns."""
        return self.shape[1]

    def __repr__(self) -> str:
        return f"Matrix({self.shape[0]}x{self.shape[1]})"

    def __str__(self) -> str:
        return str(self.data)

    def __eq__(self, other) -> bool:
        """Check matrix equality."""
        if not isinstance(other, Matrix):
            return False
        return np.allclose(self.data, other.data)

    def __getitem__(self, key):
        """Support indexing: m[i, j] or m[i]."""
        result = self.data[key]
        if isinstance(result, np.ndarray) and result.ndim >= 1:
            return Matrix(result)
        return float(result)

    def __setitem__(self, key, value):
        """Support assignment: m[i, j] = value."""
        self.data[key] = value

    # ========== Basic Operations ==========

    def transpose(self) -> "Matrix":
        """
        Transpose the matrix.

        Returns:
            Transposed matrix (M^T)

        Example:
            >>> m = Matrix([[1, 2], [3, 4]])
            >>> m.transpose()
            Matrix([[1, 3], [2, 4]])
        """
        return Matrix(self.data.T)

    def reshape(self, rows: int, cols: int) -> "Matrix":
        """
        Reshape the matrix.

        Args:
            rows: New number of rows
            cols: New number of columns

        Returns:
            Reshaped matrix

        Raises:
            ValueError: If new shape is incompatible
        """
        return Matrix(self.data.reshape(rows, cols))

    def flatten(self) -> List[float]:
        """
        Flatten matrix to 1D list.

        Returns:
            Flattened matrix as list
        """
        return self.data.flatten().tolist()

    # ========== Arithmetic Operations ==========

    def __add__(self, other: "Matrix") -> "Matrix":
        """Matrix addition: A + B."""
        if not isinstance(other, Matrix):
            raise TypeError("Can only add Matrix to Matrix")
        if self.shape != other.shape:
            raise ValueError(f"Shape mismatch: {self.shape} vs {other.shape}")
        return Matrix(self.data + other.data)

    def __sub__(self, other: "Matrix") -> "Matrix":
        """Matrix subtraction: A - B."""
        if not isinstance(other, Matrix):
            raise TypeError("Can only subtract Matrix from Matrix")
        if self.shape != other.shape:
            raise ValueError(f"Shape mismatch: {self.shape} vs {other.shape}")
        return Matrix(self.data - other.data)

    def __mul__(self, other: Union["Matrix", float]) -> "Matrix":
        """
        Element-wise multiplication or scalar multiplication.

        Args:
            other: Matrix for element-wise mul, or scalar

        Returns:
            Result matrix
        """
        if isinstance(other, Matrix):
            if self.shape != other.shape:
                raise ValueError(f"Shape mismatch: {self.shape} vs {other.shape}")
            return Matrix(self.data * other.data)
        else:
            # Scalar multiplication
            return Matrix(self.data * float(other))

    def __rmul__(self, other: float) -> "Matrix":
        """Scalar multiplication from left: scalar * Matrix."""
        return Matrix(float(other) * self.data)

    def __truediv__(self, scalar: float) -> "Matrix":
        """Scalar division: Matrix / scalar."""
        return Matrix(self.data / float(scalar))

    def matmul(self, other: "Matrix") -> "Matrix":
        """
        Matrix multiplication: A @ B.

        Args:
            other: Matrix to multiply with

        Returns:
            Product matrix

        Raises:
            ValueError: If shapes are incompatible
        """
        if self.cols != other.rows:
            raise ValueError(
                f"Cannot multiply {self.shape} by {other.shape}: "
                f"columns of first ({self.cols}) must match rows of second ({other.rows})"
            )
        return Matrix(self.data @ other.data)

    def __matmul__(self, other: "Matrix") -> "Matrix":
        """Matrix multiplication operator: A @ B."""
        return self.matmul(other)

    # ========== Linear Algebra Operations ==========

    def det(self) -> float:
        """
        Compute determinant.

        Returns:
            Determinant value

        Raises:
            ValueError: If matrix is not square
        """
        if self.rows != self.cols:
            raise ValueError(f"Determinant requires square matrix, got {self.shape}")
        return float(np.linalg.det(self.data))

    def inv(self) -> "Matrix":
        """
        Compute matrix inverse.

        Returns:
            Inverse matrix

        Raises:
            ValueError: If matrix is not square
            np.linalg.LinAlgError: If matrix is singular
        """
        if self.rows != self.cols:
            raise ValueError(f"Inverse requires square matrix, got {self.shape}")
        return Matrix(np.linalg.inv(self.data))

    def trace(self) -> float:
        """
        Compute trace (sum of diagonal elements).

        Returns:
            Trace value
        """
        return float(np.trace(self.data))

    def eigenvalues(self) -> Tuple[List[complex], "Matrix"]:
        """
        Compute eigenvalues and eigenvectors.

        Returns:
            Tuple of (eigenvalues list, eigenvectors matrix)

        Raises:
            ValueError: If matrix is not square
        """
        if self.rows != self.cols:
            raise ValueError(f"Eigenvalues require square matrix, got {self.shape}")

        eigenvals, eigenvecs = np.linalg.eig(self.data)
        return eigenvals.tolist(), Matrix(eigenvecs)

    def svd(self) -> Tuple["Matrix", List[float], "Matrix"]:
        """
        Singular Value Decomposition: A = U Σ V^T.

        Returns:
            Tuple of (U, singular_values, V^T)
        """
        u, s, vt = np.linalg.svd(self.data)
        return Matrix(u), s.tolist(), Matrix(vt)

    def qr(self) -> Tuple["Matrix", "Matrix"]:
        """
        QR decomposition: A = QR.

        Returns:
            Tuple of (Q, R) where Q is orthogonal and R is upper triangular
        """
        q, r = np.linalg.qr(self.data)
        return Matrix(q), Matrix(r)

    # ========== Norms and Distances ==========

    def norm(self, ord: Optional[Union[int, str]] = "fro") -> float:
        """
        Compute matrix norm.

        Args:
            ord: Order of norm ('fro' for Frobenius, 2 for spectral, etc.)

        Returns:
            Norm value
        """
        return float(np.linalg.norm(self.data, ord=ord))

    def frobenius_norm(self) -> float:
        """Compute Frobenius norm (square root of sum of squared elements)."""
        return self.norm("fro")

    # ========== Factory Methods ==========

    @staticmethod
    def zeros(rows: int, cols: int) -> "Matrix":
        """Create matrix of zeros."""
        return Matrix(np.zeros((rows, cols)))

    @staticmethod
    def ones(rows: int, cols: int) -> "Matrix":
        """Create matrix of ones."""
        return Matrix(np.ones((rows, cols)))

    @staticmethod
    def identity(size: int) -> "Matrix":
        """Create identity matrix."""
        return Matrix(np.eye(size))

    @staticmethod
    def random(rows: int, cols: int, scale: float = 1.0) -> "Matrix":
        """
        Create matrix with random values from normal distribution.

        Args:
            rows: Number of rows
            cols: Number of columns
            scale: Standard deviation of distribution

        Returns:
            Random matrix
        """
        return Matrix(np.random.randn(rows, cols) * scale)

    # ========== Conversion Methods ==========

    def to_list(self) -> List[List[float]]:
        """Convert to nested Python list."""
        return self.data.tolist()

    def to_vector(self) -> LRVMVector:
        """
        Convert to LRVM vector (flattens the matrix).

        Returns:
            LRVMVector containing flattened matrix data
        """
        flat = self.data.flatten()
        # Pad to match LRVM dimension if needed
        return LRVMVector(flat)
