"""
Metric Tensor implementation for EigenScript.

The metric tensor g defines the geometric structure of LRVM space.
It is used to compute norms, distances, and contractions (the OF operator).
"""

import numpy as np
from typing import List
from eigenscript.semantic.lrvm import LRVMVector


class MetricTensor:
    """
    Represents the metric tensor g in LRVM space.

    The metric tensor defines the geometry of semantic space:
    - Determines which vectors are lightlike/spacelike/timelike
    - Used for the OF operator: x of y → x^T g y
    - Computes norms: ||v||² = v^T g v

    Attributes:
        dimension: Dimensionality of the space
        g: The metric tensor matrix (dimension × dimension)

    Example:
        >>> metric = MetricTensor(dimension=3)
        >>> v = LRVMVector([1.0, 0.0, 0.0])
        >>> metric.norm(v)
        1.0
    """

    def __init__(self, dimension: int = 768, metric_type: str = "euclidean"):
        """
        Initialize the metric tensor.

        Args:
            dimension: Dimensionality of LRVM space
            metric_type: Type of metric to use
                - "euclidean": Identity matrix (default)
                - "minkowski": Spacetime-like metric
                - "custom": User-defined (not yet implemented)
        """
        self.dimension = dimension
        self.metric_type = metric_type
        self.g = self._initialize_metric(metric_type)

    def _initialize_metric(self, metric_type: str) -> np.ndarray:
        """
        Initialize the metric tensor matrix.

        Args:
            metric_type: Type of metric

        Returns:
            Metric tensor as numpy array
        """
        if metric_type == "euclidean":
            # Standard Euclidean metric (identity matrix)
            return np.eye(self.dimension, dtype=np.float64)

        elif metric_type == "minkowski":
            # Minkowski metric for spacetime: (-1, +1, +1, +1, ...)
            # First component timelike, rest spacelike
            g = np.eye(self.dimension, dtype=np.float64)
            g[0, 0] = -1.0
            return g

        else:
            # Default to Euclidean
            return np.eye(self.dimension, dtype=np.float64)

    def norm(self, vector: LRVMVector) -> float:
        """
        Compute norm of a vector: ||v||² = v^T g v

        Args:
            vector: LRVM vector to measure

        Returns:
            Norm squared (can be positive, negative, or zero)

        Example:
            >>> metric = MetricTensor(dimension=3)
            >>> v = LRVMVector([1.0, 1.0, 0.0])
            >>> metric.norm(v)
            2.0
        """
        return vector.norm(self.g)

    def contract(self, v1: LRVMVector, v2: LRVMVector) -> float:
        """
        Compute metric contraction: v1^T g v2

        This is the geometric operation underlying the OF operator.

        Args:
            v1: First LRVM vector
            v2: Second LRVM vector

        Returns:
            Scalar result of contraction

        Raises:
            ValueError: If vector dimensions don't match metric

        Example:
            >>> metric = MetricTensor(dimension=3)
            >>> v1 = LRVMVector([1.0, 0.0, 0.0])
            >>> v2 = LRVMVector([0.0, 1.0, 0.0])
            >>> metric.contract(v1, v2)
            0.0
        """
        if v1.dimension != self.dimension or v2.dimension != self.dimension:
            raise ValueError(
                f"Vector dimension mismatch: vectors are {v1.dimension} and {v2.dimension}, "
                f"but metric has dimension {self.dimension}"
            )

        # Compute v1^T g v2
        result = v1.coords.T @ self.g @ v2.coords
        return float(result)

    def contract_to_vector(self, v1: LRVMVector, v2: LRVMVector) -> LRVMVector:
        """
        Compute metric contraction and embed result as LRVM vector.

        This version returns a vector rather than a scalar, allowing
        the result to participate in further geometric operations.

        Args:
            v1: First LRVM vector
            v2: Second LRVM vector

        Returns:
            LRVM vector containing the contraction result

        Example:
            >>> metric = MetricTensor(dimension=3)
            >>> v1 = LRVMVector([1.0, 0.0, 0.0])
            >>> v2 = LRVMVector([2.0, 0.0, 0.0])
            >>> result = metric.contract_to_vector(v1, v2)
            >>> result.coords[0]
            2.0
        """
        scalar_result = self.contract(v1, v2)

        # Embed scalar as vector (put in first coordinate)
        coords = np.zeros(self.dimension)
        coords[0] = scalar_result

        return LRVMVector(coords)

    def distance(self, v1: LRVMVector, v2: LRVMVector) -> float:
        """
        Compute geometric distance between two vectors.

        Uses the metric: d(v1, v2) = sqrt(||(v1 - v2)||²)

        Args:
            v1: First LRVM vector
            v2: Second LRVM vector

        Returns:
            Distance (always non-negative)

        Example:
            >>> metric = MetricTensor(dimension=3)
            >>> v1 = LRVMVector([1.0, 0.0, 0.0])
            >>> v2 = LRVMVector([0.0, 0.0, 0.0])
            >>> metric.distance(v1, v2)
            1.0
        """
        return v1.distance(v2, self.g)

    def parallel_transport(
        self, vector: LRVMVector, path: List[LRVMVector]
    ) -> LRVMVector:
        """
        Parallel transport a vector along a geodesic path.

        This operation is used for function application in EigenScript.
        Current implementation supports flat metrics (Euclidean and Minkowski).

        Args:
            vector: Vector to transport
            path: List of points defining the geodesic

        Returns:
            Transported vector

        Note:
            For flat metrics (Euclidean, Minkowski), parallel transport is trivial -
            the vector remains unchanged along any path. This is geometrically correct.

            Curved metrics (e.g., Schwarzschild, FLRW) are not currently supported
            and would require implementing the parallel transport equation with
            Christoffel symbols. This is planned for Phase 6+ as an advanced feature.

        Supported metrics:
            - euclidean: Flat positive-definite metric (production)
            - minkowski: Flat Lorentzian metric (research/experimental)
        """
        # For flat metrics, parallel transport leaves vectors unchanged
        # This is mathematically correct: ∇_v V = 0 for constant vector fields
        if self.metric_type in ("euclidean", "minkowski"):
            return vector
        else:
            # Curved metrics not implemented - return unchanged as approximation
            # Future: Implement Christoffel symbol computation and transport equation
            return vector

    def geodesic(
        self, start: LRVMVector, end: LRVMVector, steps: int = 10
    ) -> List[LRVMVector]:
        """
        Compute geodesic (shortest path) between two points.

        In Euclidean space, this is a straight line.
        In curved spaces, this would solve the geodesic equation.

        Args:
            start: Starting point
            end: Ending point
            steps: Number of intermediate points

        Returns:
            List of vectors along the geodesic

        Example:
            >>> metric = MetricTensor(dimension=3)
            >>> v1 = LRVMVector([0.0, 0.0, 0.0])
            >>> v2 = LRVMVector([1.0, 1.0, 0.0])
            >>> path = metric.geodesic(v1, v2, steps=5)
            >>> len(path)
            5
        """
        path = []

        for i in range(steps):
            t = i / (steps - 1) if steps > 1 else 0.0
            # Linear interpolation for Euclidean space
            point = LRVMVector((1 - t) * start.coords + t * end.coords)
            path.append(point)

        return path

    def is_lightlike(self, vector: LRVMVector, epsilon: float = 1e-10) -> bool:
        """
        Check if a vector is lightlike (null norm).

        Args:
            vector: LRVM vector to test
            epsilon: Threshold for considering norm as zero

        Returns:
            True if ||v||² ≈ 0

        Example:
            >>> metric = MetricTensor(dimension=3, metric_type="minkowski")
            >>> # In Minkowski space, (1, 1, 0, 0, ...) is lightlike
            >>> v = LRVMVector([1.0, 1.0] + [0.0] * 766)
            >>> metric.is_lightlike(v)
            True
        """
        return abs(self.norm(vector)) < epsilon

    def is_spacelike(self, vector: LRVMVector, epsilon: float = 1e-10) -> bool:
        """
        Check if a vector is spacelike (positive norm).

        Args:
            vector: LRVM vector to test
            epsilon: Threshold for distinguishing from lightlike

        Returns:
            True if ||v||² > 0
        """
        n = self.norm(vector)
        return n > epsilon

    def is_timelike(self, vector: LRVMVector, epsilon: float = 1e-10) -> bool:
        """
        Check if a vector is timelike (negative norm).

        Args:
            vector: LRVM vector to test
            epsilon: Threshold for distinguishing from lightlike

        Returns:
            True if ||v||² < 0
        """
        n = self.norm(vector)
        return n < -epsilon

    def __repr__(self) -> str:
        """String representation."""
        return f"MetricTensor(dimension={self.dimension}, type={self.metric_type!r})"
