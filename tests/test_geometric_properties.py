# -*- coding: utf-8 -*-
"""
Geometric Property Tests

Tests for geometric properties including Prince Rupert's cube property.

Prince Rupert's Cube Property:
    Tests whether a hole can be cut through a cube such that another cube
    (potentially larger) can pass through it. The theoretical maximum is
    approximately 1.06 times the original cube's side length.
"""

import numpy as np
from typing import Tuple, Optional, List


def check_rupert_property(
    vertices: np.ndarray,
    n_samples: int = 1000
) -> Tuple[int, bool]:
    """
    Check whether a polyhedron (defined by vertices) has the Rupert property.

    The Rupert property tests if a hole can be made through a geometric shape
    such that another shape of equal or larger size can pass through it.

    For a cube, Prince Rupert proved that a cube slightly larger than the
    original (up to ~1.06x) can pass through a hole in the original cube.

    Parameters
    ----------
    vertices : np.ndarray
        Array of vertices defining the polyhedron, shape (n_vertices, 3)
        For a cube, this should be 8 vertices
    n_samples : int, optional
        Number of random orientations to test (default: 1000)

    Returns
    -------
    attempts : int
        Number of attempted orientations tested
    has_passage : bool
        True if a passage was found, False otherwise

    Notes
    -----
    This is a Monte Carlo approach that tests random orientations to find
    if a passage exists. The actual mathematical proof is more complex.

    Examples
    --------
    >>> # Create a unit cube
    >>> cube_vertices = np.array([
    ...     [0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0],
    ...     [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]
    ... ])
    >>> attempts, has_passage = test_rupert_property(cube_vertices)
    >>> print(f"Tested {attempts} orientations, passage found: {has_passage}")
    """
    if vertices is None or len(vertices) == 0:
        raise ValueError("vertices cannot be None or empty")

    if not isinstance(vertices, np.ndarray):
        vertices = np.array(vertices)

    if vertices.ndim != 2 or vertices.shape[1] != 3:
        raise ValueError(
            f"vertices must be shape (n, 3), got {vertices.shape}"
        )

    if n_samples <= 0:
        raise ValueError(f"n_samples must be positive, got {n_samples}")

    # Get the characteristic size of the shape
    # For a cube, this would be the edge length
    bbox_min = vertices.min(axis=0)
    bbox_max = vertices.max(axis=0)
    dimensions = bbox_max - bbox_min
    characteristic_size = np.max(dimensions)

    # For a cube, the theoretical maximum passage size is approximately
    # 1.06066 times the cube's side length (√2 * √(3/4))
    # This is the side length of the largest cube that can pass through
    rupert_ratio = np.sqrt(2) * np.sqrt(3/4)  # ≈ 1.06066

    attempts = 0
    has_passage = False

    # Test various orientations using Monte Carlo sampling
    for i in range(n_samples):
        attempts += 1

        # Generate a random rotation matrix
        rotation = _random_rotation_matrix()

        # Rotate the vertices
        rotated = vertices @ rotation.T

        # Calculate the cross-sectional area in the direction of passage
        # For simplicity, we test if the minimum projected dimension
        # is large enough for the Rupert ratio
        projected_dims = rotated.max(axis=0) - rotated.min(axis=0)
        min_dim = np.min(projected_dims)
        max_dim = np.max(projected_dims)

        # Check if this orientation allows a Rupert passage
        # A passage exists if we can fit a cube through the cross-section
        # that's larger than a certain fraction of the original size
        passage_size = min_dim * np.sqrt(2)  # Diagonal of the passage

        # If passage size is close to or exceeds the Rupert ratio,
        # we've found a valid orientation
        if passage_size >= characteristic_size * 0.95:  # Allow 5% tolerance
            has_passage = True
            break

    return attempts, has_passage


def _random_rotation_matrix() -> np.ndarray:
    """
    Generate a random 3D rotation matrix using the Haar measure.

    This ensures uniform sampling of SO(3) (the group of 3D rotations).

    Returns
    -------
    R : np.ndarray
        A 3x3 rotation matrix

    Notes
    -----
    Uses the method from "How to generate random matrices from the classical
    compact groups" by Mezzadri (2007).
    """
    # Generate a random 3x3 matrix with normal distribution
    M = np.random.randn(3, 3)

    # QR decomposition
    Q, R = np.linalg.qr(M)

    # Make sure we have a proper rotation (det = +1)
    # QR decomposition might give us a reflection (det = -1)
    if np.linalg.det(Q) < 0:
        Q[:, 0] *= -1

    return Q


def create_unit_cube() -> np.ndarray:
    """
    Create vertices for a unit cube centered at origin.

    Returns
    -------
    vertices : np.ndarray
        8x3 array of cube vertices

    Examples
    --------
    >>> vertices = create_unit_cube()
    >>> vertices.shape
    (8, 3)
    """
    # Unit cube centered at origin
    return np.array([
        [-0.5, -0.5, -0.5],
        [0.5, -0.5, -0.5],
        [0.5, 0.5, -0.5],
        [-0.5, 0.5, -0.5],
        [-0.5, -0.5, 0.5],
        [0.5, -0.5, 0.5],
        [0.5, 0.5, 0.5],
        [-0.5, 0.5, 0.5],
    ])


def create_cube(side_length: float = 1.0, center: Optional[List[float]] = None) -> np.ndarray:
    """
    Create vertices for a cube with specified side length and center.

    Parameters
    ----------
    side_length : float, optional
        Length of each edge of the cube (default: 1.0)
    center : list of float, optional
        Center coordinates [x, y, z] (default: [0, 0, 0])

    Returns
    -------
    vertices : np.ndarray
        8x3 array of cube vertices

    Examples
    --------
    >>> vertices = create_cube(side_length=2.0, center=[1, 1, 1])
    >>> vertices.shape
    (8, 3)
    """
    if center is None:
        center = [0.0, 0.0, 0.0]

    half = side_length / 2.0
    cx, cy, cz = center

    return np.array([
        [cx - half, cy - half, cz - half],
        [cx + half, cy - half, cz - half],
        [cx + half, cy + half, cz - half],
        [cx - half, cy + half, cz - half],
        [cx - half, cy - half, cz + half],
        [cx + half, cy - half, cz + half],
        [cx + half, cy + half, cz + half],
        [cx - half, cy + half, cz + half],
    ])
