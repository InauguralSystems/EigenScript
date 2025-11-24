"""
LRVM (Lightlike-Relational Vector Model) implementation.

This module defines the geometric vector representation used in EigenScript's
semantic model. Every value and expression exists as a vector in LRVM space.
"""

import numpy as np
from typing import Union, List


class LRVMVector:
    """
    Represents a vector in the Lightlike-Relational Vector Model (LRVM) space.

    In EigenScript's geometric model, every value, expression, and operation
    exists as a point in this high-dimensional semantic space. The metric tensor
    defines the geometric properties of this space.

    Attributes:
        coords: NumPy array of coordinates
        dimension: Dimensionality of the vector

    Example:
        >>> v = LRVMVector([1.0, 0.0, -1.0])
        >>> v.dimension
        3
        >>> v.coords
        array([ 1.,  0., -1.])
    """

    def __init__(
        self, coordinates: Union[np.ndarray, List[float]], metadata: dict = None
    ):
        """
        Initialize an LRVM vector.

        Args:
            coordinates: Vector coordinates (array-like)
            metadata: Optional metadata dictionary (e.g., {"string_value": "hello"})
        """
        if isinstance(coordinates, list):
            self.coords = np.array(coordinates, dtype=np.float64)
        else:
            self.coords = np.array(coordinates, dtype=np.float64)

        self.dimension = len(self.coords)
        self.metadata = metadata or {}

    def norm(self, metric: np.ndarray) -> float:
        """
        Compute the geometric norm of this vector.

        Uses the metric tensor to compute ||v||² = v^T g v

        Args:
            metric: Metric tensor g

        Returns:
            Norm squared value (can be positive, negative, or zero)

        Example:
            >>> v = LRVMVector([1.0, 0.0, 0.0])
            >>> g = np.eye(3)
            >>> v.norm(g)
            1.0
        """
        return float(self.coords.T @ metric @ self.coords)

    def signature_type(self, metric: np.ndarray, epsilon: float = 1e-10) -> str:
        """
        Determine the geometric type based on norm signature.

        Args:
            metric: Metric tensor g
            epsilon: Threshold for considering norm as zero

        Returns:
            "lightlike" if ||v||² ≈ 0
            "spacelike" if ||v||² > 0
            "timelike" if ||v||² < 0

        Example:
            >>> v = LRVMVector([1.0, 1.0, 0.0])
            >>> g = np.eye(3)
            >>> v.signature_type(g)
            'spacelike'
        """
        n = self.norm(metric)

        if abs(n) < epsilon:
            return "lightlike"
        elif n > 0:
            return "spacelike"
        else:
            return "timelike"

    def add(self, other: "LRVMVector") -> "LRVMVector":
        """
        Vector addition.

        Args:
            other: Another LRVM vector

        Returns:
            New vector representing the sum

        Raises:
            ValueError: If dimensions don't match
        """
        if self.dimension != other.dimension:
            raise ValueError(
                f"Dimension mismatch: {self.dimension} vs {other.dimension}"
            )

        # Preserve metadata from self (left operand takes precedence)
        # Note: String concatenation is handled specially in interpreter
        return LRVMVector(self.coords + other.coords, metadata=self.metadata.copy())

    def subtract(self, other: "LRVMVector") -> "LRVMVector":
        """
        Vector subtraction.

        Args:
            other: Another LRVM vector

        Returns:
            New vector representing the difference

        Raises:
            ValueError: If dimensions don't match
        """
        if self.dimension != other.dimension:
            raise ValueError(
                f"Dimension mismatch: {self.dimension} vs {other.dimension}"
            )

        # Preserve metadata from self (left operand)
        return LRVMVector(self.coords - other.coords, metadata=self.metadata.copy())

    def scale(self, scalar: float) -> "LRVMVector":
        """
        Scalar multiplication.

        Args:
            scalar: Scaling factor

        Returns:
            New scaled vector
        """
        # Preserve metadata from self
        return LRVMVector(scalar * self.coords, metadata=self.metadata.copy())

    def dot(self, other: "LRVMVector") -> float:
        """
        Standard Euclidean dot product (not using metric).

        For metric-aware contraction, use MetricTensor.contract()

        Args:
            other: Another LRVM vector

        Returns:
            Scalar dot product

        Raises:
            ValueError: If dimensions don't match
        """
        if self.dimension != other.dimension:
            raise ValueError(
                f"Dimension mismatch: {self.dimension} vs {other.dimension}"
            )

        return float(np.dot(self.coords, other.coords))

    def distance(self, other: "LRVMVector", metric: np.ndarray) -> float:
        """
        Compute geometric distance to another vector.

        Uses metric: d(v1, v2) = sqrt(||(v1 - v2)||²)

        Args:
            other: Another LRVM vector
            metric: Metric tensor g

        Returns:
            Distance (absolute value of norm for proper distance)
        """
        diff = self.subtract(other)
        norm_squared = diff.norm(metric)
        return float(np.sqrt(abs(norm_squared)))

    def __repr__(self) -> str:
        """String representation."""
        return f"LRVMVector({self.coords.tolist()[:5]}{'...' if self.dimension > 5 else ''}, dim={self.dimension})"

    def __eq__(self, other: object) -> bool:
        """Equality comparison."""
        if not isinstance(other, LRVMVector):
            return False
        return np.allclose(self.coords, other.coords)

    def __hash__(self) -> int:
        """Hash for use in sets/dicts."""
        return hash(tuple(self.coords.tolist()))


class LRVMSpace:
    """
    Represents the entire LRVM semantic space.

    This class manages the embedding of values into LRVM vectors
    and provides utilities for working in the space.
    """

    def __init__(self, dimension: int = 768):
        """
        Initialize LRVM space with given dimensionality.

        Args:
            dimension: Dimensionality of the vector space (default: 768, BERT-like)
        """
        self.dimension = dimension

    def zero_vector(self) -> LRVMVector:
        """
        Create a zero vector in this space.

        Returns:
            Zero vector
        """
        return LRVMVector(np.zeros(self.dimension))

    def random_vector(self, scale: float = 1.0) -> LRVMVector:
        """
        Create a random vector (for testing/initialization).

        Args:
            scale: Scaling factor for random values

        Returns:
            Random LRVM vector
        """
        coords = np.random.randn(self.dimension) * scale
        return LRVMVector(coords)

    def embed_scalar(self, value: float) -> LRVMVector:
        """
        Embed a scalar number into LRVM space.

        Uses a distributed representation across multiple dimensions
        to encode both magnitude and sign information.

        Args:
            value: Scalar number to embed

        Returns:
            LRVM vector representation

        Example:
            >>> space = LRVMSpace(dimension=3)
            >>> v = space.embed_scalar(5.0)
        """
        coords = np.zeros(self.dimension)

        # Use first coordinate for the actual value
        coords[0] = value

        # Use additional coordinates for encoding properties
        # This creates a richer representation that captures numeric relationships
        if self.dimension > 1:
            # Magnitude in second coordinate
            coords[1] = abs(value)

        if self.dimension > 2:
            # Sign in third coordinate
            coords[2] = 1.0 if value >= 0 else -1.0

        if self.dimension > 3:
            # Log scale (for large numbers)
            coords[3] = np.log1p(abs(value)) * np.sign(value)

        if self.dimension > 4:
            # Fractional part (for decimals)
            coords[4] = value - int(value)

        return LRVMVector(coords)

    def embed_string(self, text: str) -> LRVMVector:
        """
        Embed a string into LRVM space using character-based features.

        For production, this should use pretrained embeddings (BERT, GPT, etc.)
        but for the MVP, we use a character-based distributed representation.

        Args:
            text: String to embed

        Returns:
            LRVM vector representation

        Example:
            >>> space = LRVMSpace(dimension=768)
            >>> v = space.embed_string("hello")
        """
        coords = np.zeros(self.dimension)

        # For empty strings, still add metadata to preserve string type
        if not text:
            return LRVMVector(coords, metadata={"string_value": ""})

        # Use multiple encoding strategies for robust representation

        # 1. Character frequency distribution (first 256 dims for ASCII)
        char_freq = np.zeros(min(256, self.dimension))
        for char in text:
            idx = min(ord(char), 255)
            if idx < len(char_freq):
                char_freq[idx] += 1.0

        # Normalize by length
        if len(text) > 0:
            char_freq /= len(text)

        coords[: len(char_freq)] = char_freq

        # 2. Length encoding (if space available)
        if self.dimension > 256:
            coords[256] = len(text) / 100.0  # Normalized length

        # 3. Hash-based features for semantic similarity
        if self.dimension > 257:
            hash_val = hash(text)
            hash_dim_count = min(20, self.dimension - 257)

            for i in range(hash_dim_count):
                coords[257 + i] = ((hash_val >> (i * 6)) & 0x3F) / 64.0

        # 4. Character n-grams (bigrams)
        if self.dimension > 277 and len(text) > 1:
            bigram_dims = min(50, self.dimension - 277)
            for i in range(len(text) - 1):
                bigram = text[i : i + 2]
                bigram_hash = hash(bigram) % bigram_dims
                coords[277 + bigram_hash] += 1.0 / (len(text) - 1)

        # Store original string in metadata for string operations (concatenation, indexing, slicing)
        return LRVMVector(coords, metadata={"string_value": text})

    def embed(self, value) -> LRVMVector:
        """
        General-purpose embedding method that dispatches to appropriate embedder.

        Args:
            value: Value to embed (int, float, str, list, or LRVMVector)

        Returns:
            LRVM vector representation

        Example:
            >>> space = LRVMSpace(dimension=768)
            >>> space.embed(5)        # Embeds scalar
            >>> space.embed("hello")  # Embeds string
            >>> space.embed([1,2,3])  # Embeds vector
        """
        # Already an LRVM vector
        if isinstance(value, LRVMVector):
            return value

        # Numeric scalar
        elif isinstance(value, (int, float)):
            return self.embed_scalar(float(value))

        # String
        elif isinstance(value, str):
            return self.embed_string(value)

        # List/tuple (treat as vector)
        elif isinstance(value, (list, tuple)):
            return self.embed_vector(value)

        # NumPy array
        elif isinstance(value, np.ndarray):
            if value.ndim == 1:
                # Directly wrap if dimension matches
                if len(value) == self.dimension:
                    return LRVMVector(value)
                else:
                    # Embed as list
                    return self.embed_vector(value.tolist())
            else:
                raise ValueError(
                    f"Cannot embed multi-dimensional array: shape {value.shape}"
                )

        # None/null
        elif value is None:
            return self.zero_vector()

        else:
            raise TypeError(f"Cannot embed value of type {type(value)}")

    def embed_vector(self, values: list) -> LRVMVector:
        """
        Embed a vector/list into LRVM space.

        Args:
            values: List of values

        Returns:
            LRVM vector representation
        """
        # For small vectors, directly use coordinates
        if len(values) <= self.dimension:
            coords = np.zeros(self.dimension)
            for i, val in enumerate(values):
                if isinstance(val, (int, float)):
                    coords[i] = float(val)
                else:
                    # Embed non-numeric elements and take first coordinate
                    embedded = self.embed(val)
                    coords[i] = embedded.coords[0]
            return LRVMVector(coords)
        else:
            # For larger vectors, use hash-based dimensionality reduction
            coords = np.zeros(self.dimension)
            for i, val in enumerate(values):
                idx = hash((i, val)) % self.dimension
                if isinstance(val, (int, float)):
                    coords[idx] += float(val)
                else:
                    coords[idx] += 1.0
            return LRVMVector(coords)

    def of_operator(
        self, x: LRVMVector, y: LRVMVector, metric: np.ndarray
    ) -> LRVMVector:
        """
        Compute the OF operator: x of y = x^T g y (metric contraction).

        This is the fundamental relational operator in EigenScript.
        Returns the result as an embedded scalar vector.

        Args:
            x: Left operand (LRVM vector)
            y: Right operand (LRVM vector)
            metric: Metric tensor g

        Returns:
            LRVM vector containing the contraction result

        Example:
            >>> space = LRVMSpace(dimension=3)
            >>> x = space.embed(5)
            >>> y = space.embed(3)
            >>> g = np.eye(3)
            >>> result = space.of_operator(x, y, g)
        """
        # Compute metric contraction: x^T g y
        contraction = float(x.coords.T @ metric @ y.coords)

        # Embed result as scalar
        return self.embed_scalar(contraction)

    def is_operator(
        self, x: LRVMVector, y: LRVMVector, metric: np.ndarray, epsilon: float = 1e-6
    ) -> bool:
        """
        Compute the IS operator: test if x is y (equilibrium condition).

        In EigenScript, x is y ⟺ ‖x - y‖² ≈ 0 (lightlike equilibrium).

        Args:
            x: Left operand (LRVM vector)
            y: Right operand (LRVM vector)
            metric: Metric tensor g
            epsilon: Threshold for equilibrium (default: 1e-6)

        Returns:
            True if x and y are in equilibrium (equal within epsilon)

        Example:
            >>> space = LRVMSpace(dimension=3)
            >>> x = space.embed(5)
            >>> y = space.embed(5)
            >>> g = np.eye(3)
            >>> space.is_operator(x, y, g)
            True
        """
        # Compute difference vector
        diff = x.subtract(y)

        # Compute norm squared: ‖x - y‖²
        norm_sq = diff.norm(metric)

        # Test for equilibrium (lightlike: ‖·‖² ≈ 0)
        return abs(norm_sq) < epsilon
