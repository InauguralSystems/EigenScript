"""
Tests for Matrix and Tensor operations.

Comprehensive test suite for linear algebra and numerical computing
capabilities in EigenScript.
"""

import pytest
import numpy as np
from eigenscript.semantic.matrix import Matrix


class TestMatrixCreation:
    """Test matrix creation and initialization."""

    def test_create_from_2d_list(self):
        """Test creating matrix from 2D list."""
        m = Matrix([[1, 2], [3, 4]])
        assert m.shape == (2, 2)
        assert m.rows == 2
        assert m.cols == 2

    def test_create_from_1d_list(self):
        """Test creating matrix from 1D list (row vector)."""
        m = Matrix([1, 2, 3])
        assert m.shape == (1, 3)
        assert m.rows == 1
        assert m.cols == 3

    def test_create_from_numpy_array(self):
        """Test creating matrix from numpy array."""
        arr = np.array([[1, 2], [3, 4]])
        m = Matrix(arr)
        assert m.shape == (2, 2)

    def test_create_zeros(self):
        """Test creating zero matrix."""
        m = Matrix.zeros(3, 4)
        assert m.shape == (3, 4)
        assert np.allclose(m.data, np.zeros((3, 4)))

    def test_create_ones(self):
        """Test creating matrix of ones."""
        m = Matrix.ones(2, 3)
        assert m.shape == (2, 3)
        assert np.allclose(m.data, np.ones((2, 3)))

    def test_create_identity(self):
        """Test creating identity matrix."""
        m = Matrix.identity(3)
        assert m.shape == (3, 3)
        assert np.allclose(m.data, np.eye(3))

    def test_create_random(self):
        """Test creating random matrix."""
        m = Matrix.random(4, 5, scale=2.0)
        assert m.shape == (4, 5)
        # Should have non-zero variance
        assert np.var(m.data) > 0


class TestMatrixBasicOperations:
    """Test basic matrix operations."""

    def test_transpose(self):
        """Test matrix transpose."""
        m = Matrix([[1, 2, 3], [4, 5, 6]])
        mt = m.transpose()
        assert mt.shape == (3, 2)
        assert mt[0, 0] == 1
        assert mt[1, 0] == 2
        assert mt[2, 1] == 6

    def test_reshape(self):
        """Test matrix reshape."""
        m = Matrix([[1, 2], [3, 4]])
        reshaped = m.reshape(1, 4)
        assert reshaped.shape == (1, 4)
        assert reshaped.flatten() == [1, 2, 3, 4]

    def test_flatten(self):
        """Test matrix flattening."""
        m = Matrix([[1, 2], [3, 4]])
        flat = m.flatten()
        assert flat == [1, 2, 3, 4]

    def test_to_list(self):
        """Test converting to nested list."""
        m = Matrix([[1, 2], [3, 4]])
        lst = m.to_list()
        assert lst == [[1, 2], [3, 4]]


class TestMatrixArithmetic:
    """Test matrix arithmetic operations."""

    def test_addition(self):
        """Test matrix addition."""
        m1 = Matrix([[1, 2], [3, 4]])
        m2 = Matrix([[5, 6], [7, 8]])
        result = m1 + m2
        assert result == Matrix([[6, 8], [10, 12]])

    def test_subtraction(self):
        """Test matrix subtraction."""
        m1 = Matrix([[5, 6], [7, 8]])
        m2 = Matrix([[1, 2], [3, 4]])
        result = m1 - m2
        assert result == Matrix([[4, 4], [4, 4]])

    def test_scalar_multiplication(self):
        """Test scalar multiplication."""
        m = Matrix([[1, 2], [3, 4]])
        result = m * 2
        assert result == Matrix([[2, 4], [6, 8]])

    def test_scalar_multiplication_left(self):
        """Test left scalar multiplication."""
        m = Matrix([[1, 2], [3, 4]])
        result = 3 * m
        assert result == Matrix([[3, 6], [9, 12]])

    def test_scalar_division(self):
        """Test scalar division."""
        m = Matrix([[2, 4], [6, 8]])
        result = m / 2
        assert result == Matrix([[1, 2], [3, 4]])

    def test_element_wise_multiplication(self):
        """Test element-wise multiplication."""
        m1 = Matrix([[1, 2], [3, 4]])
        m2 = Matrix([[2, 2], [2, 2]])
        result = m1 * m2
        assert result == Matrix([[2, 4], [6, 8]])

    def test_matrix_multiplication(self):
        """Test matrix multiplication."""
        m1 = Matrix([[1, 2], [3, 4]])
        m2 = Matrix([[5, 6], [7, 8]])
        result = m1.matmul(m2)
        # [1*5 + 2*7, 1*6 + 2*8] = [19, 22]
        # [3*5 + 4*7, 3*6 + 4*8] = [43, 50]
        assert result == Matrix([[19, 22], [43, 50]])

    def test_matrix_multiplication_operator(self):
        """Test @ operator for matrix multiplication."""
        m1 = Matrix([[1, 2], [3, 4]])
        m2 = Matrix([[5, 6], [7, 8]])
        result = m1 @ m2
        assert result == Matrix([[19, 22], [43, 50]])

    def test_incompatible_shapes_add(self):
        """Test that incompatible shapes raise error on addition."""
        m1 = Matrix([[1, 2]])
        m2 = Matrix([[1], [2]])
        with pytest.raises(ValueError):
            m1 + m2

    def test_incompatible_shapes_matmul(self):
        """Test that incompatible shapes raise error on multiplication."""
        m1 = Matrix([[1, 2]])  # 1x2
        m2 = Matrix([[1], [2], [3]])  # 3x1
        with pytest.raises(ValueError):
            m1.matmul(m2)


class TestLinearAlgebra:
    """Test linear algebra operations."""

    def test_determinant_2x2(self):
        """Test determinant of 2x2 matrix."""
        m = Matrix([[1, 2], [3, 4]])
        # det = 1*4 - 2*3 = -2
        assert abs(m.det() - (-2)) < 1e-10

    def test_determinant_3x3(self):
        """Test determinant of 3x3 matrix."""
        m = Matrix([[1, 2, 3], [4, 5, 6], [7, 8, 10]])
        det = m.det()
        # Should be non-zero
        assert abs(det - (-3)) < 1e-10

    def test_determinant_non_square(self):
        """Test that determinant raises error for non-square matrix."""
        m = Matrix([[1, 2, 3]])
        with pytest.raises(ValueError):
            m.det()

    def test_inverse_2x2(self):
        """Test matrix inverse."""
        m = Matrix([[1, 2], [3, 4]])
        inv = m.inv()
        # M * M^(-1) should be identity
        identity = m @ inv
        expected = Matrix.identity(2)
        assert np.allclose(identity.data, expected.data)

    def test_inverse_non_square(self):
        """Test that inverse raises error for non-square matrix."""
        m = Matrix([[1, 2, 3]])
        with pytest.raises(ValueError):
            m.inv()

    def test_trace(self):
        """Test matrix trace."""
        m = Matrix([[1, 2, 3], [4, 5, 6], [7, 8, 9]])
        # trace = 1 + 5 + 9 = 15
        assert m.trace() == 15

    def test_eigenvalues(self):
        """Test eigenvalue decomposition."""
        # Use a symmetric matrix for real eigenvalues
        m = Matrix([[2, 1], [1, 2]])
        eigenvals, eigenvecs = m.eigenvalues()
        assert len(eigenvals) == 2
        assert eigenvecs.shape == (2, 2)
        # Eigenvalues should be 3 and 1
        eigenvals_real = [e.real if isinstance(e, complex) else e for e in eigenvals]
        eigenvals_sorted = sorted(eigenvals_real)
        assert abs(eigenvals_sorted[0] - 1) < 1e-10
        assert abs(eigenvals_sorted[1] - 3) < 1e-10

    def test_eigenvalues_non_square(self):
        """Test that eigenvalues raise error for non-square matrix."""
        m = Matrix([[1, 2, 3]])
        with pytest.raises(ValueError):
            m.eigenvalues()

    def test_svd(self):
        """Test singular value decomposition."""
        m = Matrix([[1, 2], [3, 4], [5, 6]])
        u, s, vt = m.svd()
        # Reconstruct matrix from SVD
        sigma = np.zeros((3, 2))
        sigma[:2, :2] = np.diag(s)
        reconstructed = u.data @ sigma @ vt.data
        assert np.allclose(reconstructed, m.data)

    def test_qr_decomposition(self):
        """Test QR decomposition."""
        m = Matrix([[1, 2], [3, 4], [5, 6]])
        q, r = m.qr()
        # Q should be orthogonal (Q^T @ Q = I)
        qt_q = q.transpose() @ q
        identity = Matrix.identity(2)
        assert np.allclose(qt_q.data, identity.data, atol=1e-10)
        # Q @ R should equal original matrix
        reconstructed = q @ r
        assert np.allclose(reconstructed.data, m.data)


class TestMatrixNorms:
    """Test matrix norm calculations."""

    def test_frobenius_norm(self):
        """Test Frobenius norm."""
        m = Matrix([[1, 2], [3, 4]])
        # Frobenius norm = sqrt(1^2 + 2^2 + 3^2 + 4^2) = sqrt(30)
        expected = np.sqrt(30)
        assert abs(m.frobenius_norm() - expected) < 1e-10

    def test_norm_with_order(self):
        """Test matrix norm with different orders."""
        m = Matrix([[1, 2], [3, 4]])
        # Should not raise error
        norm_fro = m.norm("fro")
        norm_2 = m.norm(2)
        assert norm_fro > 0
        assert norm_2 > 0


class TestMatrixIndexing:
    """Test matrix indexing and assignment."""

    def test_get_element(self):
        """Test getting single element."""
        m = Matrix([[1, 2], [3, 4]])
        assert m[0, 0] == 1
        assert m[1, 1] == 4
        assert m[0, 1] == 2

    def test_get_row(self):
        """Test getting entire row."""
        m = Matrix([[1, 2, 3], [4, 5, 6]])
        row = m[0]
        assert isinstance(row, Matrix)
        assert row.shape == (3,) or row.shape == (1, 3)

    def test_set_element(self):
        """Test setting single element."""
        m = Matrix([[1, 2], [3, 4]])
        m[0, 0] = 99
        assert m[0, 0] == 99

    def test_equality(self):
        """Test matrix equality."""
        m1 = Matrix([[1, 2], [3, 4]])
        m2 = Matrix([[1, 2], [3, 4]])
        m3 = Matrix([[1, 2], [3, 5]])
        assert m1 == m2
        assert m1 != m3


class TestMatrixEdgeCases:
    """Test edge cases and error handling."""

    def test_single_element_matrix(self):
        """Test 1x1 matrix."""
        m = Matrix([[42]])
        assert m.shape == (1, 1)
        assert m[0, 0] == 42

    def test_row_vector(self):
        """Test row vector (1xN matrix)."""
        m = Matrix([[1, 2, 3, 4]])
        assert m.shape == (1, 4)
        assert m.rows == 1
        assert m.cols == 4

    def test_column_vector(self):
        """Test column vector (Nx1 matrix)."""
        m = Matrix([[1], [2], [3], [4]])
        assert m.shape == (4, 1)
        assert m.rows == 4
        assert m.cols == 1

    def test_large_matrix(self):
        """Test operations on larger matrices."""
        m = Matrix.random(100, 100)
        assert m.shape == (100, 100)
        # Should complete without error
        mt = m.transpose()
        assert mt.shape == (100, 100)

    def test_repr(self):
        """Test string representation."""
        m = Matrix([[1, 2], [3, 4]])
        repr_str = repr(m)
        assert "2x2" in repr_str
