"""
Unified semantic operations for EigenScript.

This module implements the fundamental insight:
    OF is the projection of IS through the metric tensor g.

Mathematical Foundation:
    - IS(x, y) ⟺ ||x - y||² = 0  (symmetric identity)
    - OF(x, y) = x^T g y = π_g(IS(x, y))  (projected identity)
    - AND(x, y) = x + y  (vector addition)
"""

import numpy as np
from typing import Tuple
from eigenscript.semantic.lrvm import LRVMVector
from eigenscript.semantic.metric import MetricTensor


class GeometricOperations:
    """
    Implements the three fundamental geometric operations in EigenScript.

    These operations form a complete basis for all computation:
        1. IS - symmetric identity relation
        2. OF - projected identity (IS through metric g)
        3. AND - vector addition in LRVM space
    """

    def __init__(self, metric: MetricTensor):
        """
        Initialize with a metric tensor.

        Args:
            metric: The metric tensor g that defines the geometry
        """
        self.metric = metric

    # ========================================================================
    # IS - The Fundamental Identity Relation
    # ========================================================================

    def is_identical(
        self, x: LRVMVector, y: LRVMVector, epsilon: float = 1e-10
    ) -> bool:
        """
        Test if x IS y (identity relation).

        Mathematical definition:
            is(x, y) ⟺ ||x - y||² = 0

        This is the symmetric, whole-space equality relation.

        Args:
            x: First LRVM vector
            y: Second LRVM vector
            epsilon: Threshold for numerical zero

        Returns:
            True if x and y are identical (lightlike separation)

        Example:
            >>> ops = GeometricOperations(metric)
            >>> x = LRVMVector([1.0, 2.0, 3.0])
            >>> y = LRVMVector([1.0, 2.0, 3.0])
            >>> ops.is_identical(x, y)
            True
        """
        diff = x.subtract(y)
        norm_squared = self.metric.norm(diff)
        return abs(norm_squared) < epsilon

    def bind_identity(self, x: LRVMVector, y: LRVMVector) -> LRVMVector:
        """
        Bind x to y (force identity).

        This is the operational form of IS - it creates identity
        by projecting y into x's location in semantic space.

        Args:
            x: Target vector (may not exist yet)
            y: Source vector to bind

        Returns:
            The bound vector (copy of y)

        Note:
            In the interpreter, this binding happens in the Environment.
            This method represents the geometric operation.
        """
        # IS simply returns y (the identity)
        # The binding happens at the environment level
        return y

    # ========================================================================
    # OF - Projected Identity Through Metric
    # ========================================================================

    def of_relation(self, x: LRVMVector, y: LRVMVector) -> LRVMVector:
        """
        Compute x OF y (projected identity relation).

        Mathematical definition:
            of(x, y) = π_g(is(x, y)) = x^T g y

        This is the directional projection of the identity relation.

        Properties:
            - of(x, y) is asymmetric: x of y ≠ y of x
            - ||of(x, y)||² → 0 recovers IS
            - OF is IS passed through the metric tensor

        Args:
            x: Left operand (the "accessor")
            y: Right operand (the "target")

        Returns:
            Result of metric contraction as LRVM vector

        Example:
            >>> ops = GeometricOperations(metric)
            >>> engine = LRVMVector([1.0, 0.0, 0.0])
            >>> car = LRVMVector([2.0, 0.0, 0.0])
            >>> result = ops.of_relation(engine, car)  # "engine of car"
        """
        return self.metric.contract_to_vector(x, y)

    def of_collapses_to_is(
        self, x: LRVMVector, y: LRVMVector, epsilon: float = 1e-10
    ) -> bool:
        """
        Check if OF relation has collapsed to IS (lightlike).

        Mathematical test:
            ||of(x, y)||² ≈ 0  ⟺  is(x, y)

        Args:
            x: First vector
            y: Second vector
            epsilon: Threshold for lightlike

        Returns:
            True if OF has collapsed to identity

        Example:
            >>> # When OF collapses, we recover IS
            >>> if ops.of_collapses_to_is(x, y):
            ...     print("x IS y")
        """
        relation = self.of_relation(x, y)
        return self.metric.is_lightlike(relation, epsilon)

    # ========================================================================
    # AND - Vector Addition
    # ========================================================================

    def and_combine(self, x: LRVMVector, y: LRVMVector) -> LRVMVector:
        """
        Compute x AND y (vector addition).

        Mathematical definition:
            and(x, y) = x + y

        This is geometric addition in LRVM space.

        Args:
            x: First vector
            y: Second vector

        Returns:
            Sum vector x + y

        Example:
            >>> ops = GeometricOperations(metric)
            >>> a = space.embed_scalar(3.0)
            >>> b = space.embed_scalar(4.0)
            >>> sum_vec = ops.and_combine(a, b)  # 3 and 4 = 7
        """
        return x.add(y)

    # ========================================================================
    # The Projection Law: OF = π_g(IS)
    # ========================================================================

    def project_identity(self, x: LRVMVector, y: LRVMVector) -> Tuple[LRVMVector, bool]:
        """
        Demonstrate that OF is the projection of IS.

        This method shows the fundamental relationship:
            OF(x, y) = π_g(IS(x, y))

        Args:
            x: First vector
            y: Second vector

        Returns:
            Tuple of (projected_relation, is_identity)
            - projected_relation: The OF result (x^T g y)
            - is_identity: Whether this is actually IS (norm = 0)

        Example:
            >>> relation, is_id = ops.project_identity(x, y)
            >>> if is_id:
            ...     print("OF collapsed to IS")
            >>> else:
            ...     print("OF is a directed projection")
        """
        # Compute the projection (OF operation)
        projected = self.of_relation(x, y)

        # Check if it collapsed to identity
        is_identity = self.metric.is_lightlike(projected)

        return projected, is_identity

    # ========================================================================
    # Symmetry Tests
    # ========================================================================

    def is_is_symmetric(self, x: LRVMVector, y: LRVMVector) -> bool:
        """
        Verify that IS is symmetric: is(x,y) = is(y,x).

        Returns:
            True always (IS is always symmetric)
        """
        return self.is_identical(x, y) == self.is_identical(y, x)

    def is_of_symmetric(
        self, x: LRVMVector, y: LRVMVector, epsilon: float = 1e-10
    ) -> bool:
        """
        Check if OF is symmetric for this particular x, y.

        In general, OF is NOT symmetric: of(x,y) ≠ of(y,x).

        Returns:
            True if of(x,y) ≈ of(y,x) for these specific vectors
        """
        of_xy = self.of_relation(x, y)
        of_yx = self.of_relation(y, x)

        diff = of_xy.subtract(of_yx)
        return abs(self.metric.norm(diff)) < epsilon

    # ========================================================================
    # Eigenstate Convergence
    # ========================================================================

    def converge_to_eigenstate(
        self,
        initial: LRVMVector,
        transform: callable,
        max_iterations: int = 1000,
        epsilon: float = 1e-6,
    ) -> Tuple[LRVMVector, int, bool]:
        """
        Apply repeated OF projections until convergence to IS identity.

        Mathematical principle:
            lim_{n→∞} f^n(x) = x*  where ||of(x*, x*)||² = 0

        This demonstrates that repeated OF operations converge to
        an eigenstate where OF collapses to IS.

        Args:
            initial: Starting vector
            transform: Function to apply repeatedly
            max_iterations: Maximum iterations
            epsilon: Convergence threshold

        Returns:
            Tuple of (eigenstate, iterations, converged)

        Example:
            >>> def self_apply(v):
            ...     return ops.of_relation(v, v)
            >>> eigenstate, iters, converged = ops.converge_to_eigenstate(
            ...     initial, self_apply
            ... )
        """
        current = initial

        for iteration in range(max_iterations):
            next_vec = transform(current)

            # Check convergence: ||current of next||² → 0
            if self.of_collapses_to_is(current, next_vec, epsilon):
                return next_vec, iteration, True

            current = next_vec

        return current, max_iterations, False

    def __repr__(self) -> str:
        """String representation."""
        return f"GeometricOperations(metric={self.metric.metric_type}, dim={self.metric.dimension})"
