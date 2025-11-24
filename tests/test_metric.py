"""
Unit tests for Metric Tensor.

Tests geometric operations using the metric tensor.
"""

import pytest
import numpy as np
from eigenscript.semantic.lrvm import LRVMVector
from eigenscript.semantic.metric import MetricTensor


class TestMetricTensor:
    """Test suite for MetricTensor class."""

    def test_euclidean_metric_creation(self):
        """Should create Euclidean metric (identity matrix)."""
        metric = MetricTensor(dimension=3, metric_type="euclidean")
        assert metric.dimension == 3
        assert metric.metric_type == "euclidean"
        assert np.allclose(metric.g, np.eye(3))

    def test_minkowski_metric_creation(self):
        """Should create Minkowski metric with timelike first component."""
        metric = MetricTensor(dimension=4, metric_type="minkowski")
        expected = np.diag([-1.0, 1.0, 1.0, 1.0])
        assert np.allclose(metric.g, expected)

    def test_norm_computation(self):
        """Should compute vector norm correctly."""
        metric = MetricTensor(dimension=3)
        v = LRVMVector([3.0, 4.0, 0.0])
        norm = metric.norm(v)
        assert np.isclose(norm, 25.0)  # 3² + 4² = 25

    def test_metric_contraction(self):
        """Should compute metric contraction x^T g y."""
        metric = MetricTensor(dimension=3)
        v1 = LRVMVector([1.0, 0.0, 0.0])
        v2 = LRVMVector([2.0, 0.0, 0.0])

        contraction = metric.contract(v1, v2)
        assert np.isclose(contraction, 2.0)  # 1*2 = 2

    def test_contraction_orthogonal_vectors(self):
        """Contraction of orthogonal vectors should be zero."""
        metric = MetricTensor(dimension=3)
        v1 = LRVMVector([1.0, 0.0, 0.0])
        v2 = LRVMVector([0.0, 1.0, 0.0])

        contraction = metric.contract(v1, v2)
        assert np.isclose(contraction, 0.0)

    def test_contract_to_vector(self):
        """Should return contraction as LRVM vector."""
        metric = MetricTensor(dimension=5)
        v1 = LRVMVector([1.0, 2.0, 0.0, 0.0, 0.0])
        v2 = LRVMVector([3.0, 4.0, 0.0, 0.0, 0.0])

        result = metric.contract_to_vector(v1, v2)
        assert isinstance(result, LRVMVector)
        assert result.dimension == 5
        # Contraction: 1*3 + 2*4 = 11
        assert np.isclose(result.coords[0], 11.0)

    def test_distance(self):
        """Should compute geometric distance."""
        metric = MetricTensor(dimension=3)
        v1 = LRVMVector([0.0, 0.0, 0.0])
        v2 = LRVMVector([3.0, 4.0, 0.0])

        dist = metric.distance(v1, v2)
        assert np.isclose(dist, 5.0)

    def test_is_lightlike(self):
        """Should correctly identify lightlike vectors."""
        metric = MetricTensor(dimension=3, metric_type="minkowski")

        # In Minkowski space (-, +, +), vector (1, 1, 0) is lightlike
        # norm = -1 + 1 + 0 = 0
        v = LRVMVector([1.0, 1.0, 0.0])
        assert metric.is_lightlike(v)

    def test_is_spacelike(self):
        """Should correctly identify spacelike vectors."""
        metric = MetricTensor(dimension=3)
        v = LRVMVector([1.0, 1.0, 1.0])
        assert metric.is_spacelike(v)

    def test_is_timelike(self):
        """Should correctly identify timelike vectors."""
        metric = MetricTensor(dimension=3, metric_type="minkowski")

        # Vector (2, 0, 0) in Minkowski: norm = -4 < 0
        v = LRVMVector([2.0, 0.0, 0.0])
        assert metric.is_timelike(v)

    def test_geodesic_euclidean(self):
        """Geodesic in Euclidean space should be straight line."""
        metric = MetricTensor(dimension=3)
        v1 = LRVMVector([0.0, 0.0, 0.0])
        v2 = LRVMVector([1.0, 1.0, 0.0])

        path = metric.geodesic(v1, v2, steps=3)

        assert len(path) == 3
        # Should be linear interpolation
        assert np.allclose(path[0].coords, [0.0, 0.0, 0.0])
        assert np.allclose(path[1].coords, [0.5, 0.5, 0.0])
        assert np.allclose(path[2].coords, [1.0, 1.0, 0.0])

    def test_parallel_transport_euclidean(self):
        """Parallel transport in flat space should preserve vector."""
        metric = MetricTensor(dimension=3, metric_type="euclidean")
        v = LRVMVector([1.0, 2.0, 3.0])
        path = [
            LRVMVector([0.0, 0.0, 0.0]),
            LRVMVector([1.0, 0.0, 0.0]),
            LRVMVector([2.0, 0.0, 0.0]),
        ]

        transported = metric.parallel_transport(v, path)

        # In flat space, vector should be unchanged
        assert transported == v

    def test_dimension_mismatch_error(self):
        """Operations with mismatched dimensions should raise error."""
        metric = MetricTensor(dimension=3)
        v1 = LRVMVector([1.0, 2.0])  # dim=2
        v2 = LRVMVector([1.0, 2.0, 3.0])  # dim=3

        with pytest.raises(ValueError):
            metric.contract(v1, v2)

    def test_of_operator_property(self):
        """OF operator should be lightlike: ||OF||² = 0."""
        # This tests the theoretical property that OF must satisfy
        metric = MetricTensor(dimension=3, metric_type="minkowski")

        # Construct lightlike vector for OF
        of_vector = LRVMVector([1.0, 1.0, 0.0])

        # Should have zero norm
        norm = metric.norm(of_vector)
        assert np.isclose(norm, 0.0)

        # OF of OF should also be lightlike
        # (Though in practice, this would be handled by interpreter)
        assert metric.is_lightlike(of_vector)

    def test_metric_repr(self):
        """Metric should have readable representation."""
        metric = MetricTensor(dimension=768, metric_type="euclidean")
        repr_str = repr(metric)
        assert "MetricTensor" in repr_str
        assert "768" in repr_str
        assert "euclidean" in repr_str
