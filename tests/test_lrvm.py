"""
Unit tests for LRVM (Lightlike-Relational Vector Model).

Tests vector operations in semantic space.
"""

import pytest
import numpy as np
from eigenscript.semantic.lrvm import LRVMVector, LRVMSpace


class TestLRVMVector:
    """Test suite for LRVMVector class."""

    def test_vector_creation(self):
        """Should create vector from coordinates."""
        coords = [1.0, 2.0, 3.0]
        v = LRVMVector(coords)
        assert v.dimension == 3
        assert np.allclose(v.coords, coords)

    def test_vector_from_numpy(self):
        """Should create vector from numpy array."""
        coords = np.array([1.0, 2.0, 3.0])
        v = LRVMVector(coords)
        assert v.dimension == 3

    def test_norm_euclidean(self):
        """Should compute norm with Euclidean metric."""
        v = LRVMVector([1.0, 0.0, 0.0])
        g = np.eye(3)  # Euclidean metric
        norm = v.norm(g)
        assert np.isclose(norm, 1.0)

    def test_norm_vector(self):
        """Should compute correct norm for general vector."""
        v = LRVMVector([3.0, 4.0, 0.0])
        g = np.eye(3)
        norm = v.norm(g)
        assert np.isclose(norm, 25.0)  # 3² + 4² = 25

    def test_signature_type_spacelike(self):
        """Positive norm should be spacelike."""
        v = LRVMVector([1.0, 1.0, 0.0])
        g = np.eye(3)
        sig = v.signature_type(g)
        assert sig == "spacelike"

    def test_signature_type_lightlike(self):
        """Zero norm should be lightlike."""
        v = LRVMVector([0.0, 0.0, 0.0])
        g = np.eye(3)
        sig = v.signature_type(g)
        assert sig == "lightlike"

    def test_signature_type_timelike(self):
        """Negative norm (Minkowski) should be timelike."""
        # Minkowski metric: (-1, 1, 1)
        v = LRVMVector([2.0, 1.0, 0.0])
        g = np.diag([-1.0, 1.0, 1.0])
        norm = v.norm(g)
        assert norm < 0  # -4 + 1 = -3
        sig = v.signature_type(g)
        assert sig == "timelike"

    def test_vector_addition(self):
        """Should add vectors correctly."""
        v1 = LRVMVector([1.0, 2.0, 3.0])
        v2 = LRVMVector([4.0, 5.0, 6.0])
        v3 = v1.add(v2)
        assert np.allclose(v3.coords, [5.0, 7.0, 9.0])

    def test_vector_subtraction(self):
        """Should subtract vectors correctly."""
        v1 = LRVMVector([5.0, 7.0, 9.0])
        v2 = LRVMVector([1.0, 2.0, 3.0])
        v3 = v1.subtract(v2)
        assert np.allclose(v3.coords, [4.0, 5.0, 6.0])

    def test_scalar_multiplication(self):
        """Should scale vectors correctly."""
        v = LRVMVector([1.0, 2.0, 3.0])
        v2 = v.scale(2.0)
        assert np.allclose(v2.coords, [2.0, 4.0, 6.0])

    def test_dot_product(self):
        """Should compute Euclidean dot product."""
        v1 = LRVMVector([1.0, 0.0, 0.0])
        v2 = LRVMVector([0.0, 1.0, 0.0])
        dot = v1.dot(v2)
        assert np.isclose(dot, 0.0)

        v3 = LRVMVector([1.0, 2.0, 3.0])
        v4 = LRVMVector([4.0, 5.0, 6.0])
        dot2 = v3.dot(v4)
        assert np.isclose(dot2, 32.0)  # 1*4 + 2*5 + 3*6 = 32

    def test_distance(self):
        """Should compute geometric distance."""
        v1 = LRVMVector([0.0, 0.0, 0.0])
        v2 = LRVMVector([3.0, 4.0, 0.0])
        g = np.eye(3)
        dist = v1.distance(v2, g)
        assert np.isclose(dist, 5.0)  # 3-4-5 triangle

    def test_dimension_mismatch(self):
        """Operations on mismatched dimensions should raise error."""
        v1 = LRVMVector([1.0, 2.0])
        v2 = LRVMVector([1.0, 2.0, 3.0])

        with pytest.raises(ValueError):
            v1.add(v2)

    def test_vector_equality(self):
        """Equal vectors should compare as equal."""
        v1 = LRVMVector([1.0, 2.0, 3.0])
        v2 = LRVMVector([1.0, 2.0, 3.0])
        assert v1 == v2

    def test_vector_repr(self):
        """Vector should have readable representation."""
        v = LRVMVector([1.0, 2.0, 3.0])
        repr_str = repr(v)
        assert "LRVMVector" in repr_str
        assert "dim=3" in repr_str


class TestLRVMSpace:
    """Test suite for LRVMSpace class."""

    def test_space_creation(self):
        """Should create space with specified dimension."""
        space = LRVMSpace(dimension=768)
        assert space.dimension == 768

    def test_zero_vector(self):
        """Should create zero vector."""
        space = LRVMSpace(dimension=5)
        zero = space.zero_vector()
        assert zero.dimension == 5
        assert np.allclose(zero.coords, np.zeros(5))

    def test_random_vector(self):
        """Should create random vector."""
        space = LRVMSpace(dimension=10)
        rand = space.random_vector()
        assert rand.dimension == 10
        # Should not be all zeros
        assert not np.allclose(rand.coords, np.zeros(10))

    def test_embed_scalar(self):
        """Should embed scalar as vector."""
        space = LRVMSpace(dimension=100)
        v = space.embed_scalar(5.0)
        assert v.dimension == 100
        # First coordinate should contain the value
        assert v.coords[0] == 5.0

    def test_embed_string(self):
        """Should embed string as vector."""
        space = LRVMSpace(dimension=768)
        v = space.embed_string("hello")
        assert v.dimension == 768
        # Should not be zero vector
        assert not np.allclose(v.coords, np.zeros(768))

    def test_embed_string_consistency(self):
        """Same string should embed to same vector."""
        space = LRVMSpace(dimension=768)
        v1 = space.embed_string("test")
        v2 = space.embed_string("test")
        assert np.allclose(v1.coords, v2.coords)

    def test_embed_different_strings(self):
        """Different strings should embed differently."""
        space = LRVMSpace(dimension=768)
        v1 = space.embed_string("hello")
        v2 = space.embed_string("world")
        # Should be different (with high probability)
        assert not np.allclose(v1.coords, v2.coords)

    def test_embed_dispatcher_scalar(self):
        """embed() should dispatch to embed_scalar for numbers."""
        space = LRVMSpace(dimension=100)
        v1 = space.embed(42)
        v2 = space.embed_scalar(42.0)
        assert np.allclose(v1.coords, v2.coords)

    def test_embed_dispatcher_string(self):
        """embed() should dispatch to embed_string for strings."""
        space = LRVMSpace(dimension=768)
        v1 = space.embed("test")
        v2 = space.embed_string("test")
        assert np.allclose(v1.coords, v2.coords)

    def test_embed_dispatcher_list(self):
        """embed() should handle lists as vectors."""
        space = LRVMSpace(dimension=10)
        v = space.embed([1.0, 2.0, 3.0])
        assert v.dimension == 10
        assert v.coords[0] == 1.0
        assert v.coords[1] == 2.0
        assert v.coords[2] == 3.0

    def test_embed_dispatcher_none(self):
        """embed() should return zero vector for None."""
        space = LRVMSpace(dimension=5)
        v = space.embed(None)
        assert np.allclose(v.coords, np.zeros(5))

    def test_embed_dispatcher_lrvm_vector(self):
        """embed() should return LRVM vectors unchanged."""
        space = LRVMSpace(dimension=5)
        original = LRVMVector([1.0, 2.0, 3.0, 4.0, 5.0])
        result = space.embed(original)
        assert result == original

    def test_embed_vector_small(self):
        """embed_vector() should handle small vectors."""
        space = LRVMSpace(dimension=10)
        v = space.embed_vector([1.0, 2.0, 3.0])
        assert v.dimension == 10
        assert v.coords[0] == 1.0
        assert v.coords[1] == 2.0
        assert v.coords[2] == 3.0
        # Rest should be zero
        assert all(v.coords[3:] == 0.0)

    def test_of_operator_scalar_multiplication(self):
        """OF operator should compute metric contraction."""
        space = LRVMSpace(dimension=3)
        x = space.embed(2.0)
        y = space.embed(3.0)
        g = np.eye(3)

        result = space.of_operator(x, y, g)

        # Verify result is an LRVM vector
        assert isinstance(result, LRVMVector)
        assert result.dimension == 3

    def test_of_operator_orthogonal(self):
        """OF operator should give 0 for orthogonal vectors."""
        space = LRVMSpace(dimension=3)
        x = LRVMVector([1.0, 0.0, 0.0])
        y = LRVMVector([0.0, 1.0, 0.0])
        g = np.eye(3)

        result = space.of_operator(x, y, g)

        # Orthogonal vectors should have near-zero contraction
        assert abs(result.coords[0]) < 1e-10

    def test_is_operator_equal_values(self):
        """IS operator should return True for equal values."""
        space = LRVMSpace(dimension=10)
        x = space.embed(5)
        y = space.embed(5)
        g = np.eye(10)

        result = space.is_operator(x, y, g)

        assert result is True

    def test_is_operator_different_values(self):
        """IS operator should return False for different values."""
        space = LRVMSpace(dimension=10)
        x = space.embed(5)
        y = space.embed(7)
        g = np.eye(10)

        result = space.is_operator(x, y, g)

        assert result is False

    def test_is_operator_equilibrium(self):
        """IS operator tests for equilibrium (lightlike condition)."""
        space = LRVMSpace(dimension=10)
        g = np.eye(10)

        # Same vector should be in equilibrium with itself
        v = space.embed(42.0)
        assert space.is_operator(v, v, g) is True

        # Very close vectors should be in equilibrium
        v1 = LRVMVector([1.0, 0.0, 0.0] + [0.0] * 7)
        v2 = LRVMVector([1.0 + 1e-7, 0.0, 0.0] + [0.0] * 7)
        assert space.is_operator(v1, v2, g, epsilon=1e-12) is True

    def test_of_and_is_integration(self):
        """Integration test: OF and IS operators work together."""
        space = LRVMSpace(dimension=10)
        g = np.eye(10)

        # Test basic EigenScript semantics: x is y ⟺ ‖x - y‖² ≈ 0
        x = space.embed(3.14)
        y = space.embed(3.14)

        # IS operator should detect equilibrium
        assert space.is_operator(x, y, g) is True

        # OF operator should compute metric contraction
        contraction = space.of_operator(x, y, g)
        assert isinstance(contraction, LRVMVector)
