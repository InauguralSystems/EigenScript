"""
EigenControl: Universal geometric algorithm for opposing quantities.

This module implements the core EigenControl algorithm that unifies
Geometric-Control, EigenFunction, and EigenScript under a single
mathematical primitive: the lightlike invariant I = (A - B)².

From this single value, all geometric properties emerge:
- Radius: r = √I (1D scale)
- Surface Area: S = 4πr² (2D complexity)
- Volume: V = (4/3)πr³ (3D search space)
- Curvature: κ = 1/r (problem conditioning)

Key Insight: Convergence occurs when I → 0, which makes κ → ∞
(infinitely well-conditioned problem).
"""

import numpy as np
from typing import Tuple, List
from eigenscript.semantic.lrvm import LRVMVector


class EigenControl:
    """
    Universal geometric algorithm for analyzing opposing quantities.

    Given two opposing quantities A and B (positions, states, embeddings),
    this computes the complete geometric characterization via the
    lightlike invariant I = ||A - B||².

    Example:
        >>> from eigenscript.semantic.lrvm import LRVMSpace
        >>> space = LRVMSpace(768)
        >>> A = space.embed_scalar(5.0)
        >>> B = space.embed_scalar(3.0)
        >>> eigen = EigenControl(A, B)
        >>> print(f"Radius: {eigen.radius:.4f}")
        >>> print(f"Curvature: {eigen.curvature:.4f}")
        >>> print(f"Converged: {eigen.has_converged()}")
    """

    def __init__(self, A: LRVMVector, B: LRVMVector):
        """
        Initialize with two opposing quantities.

        Args:
            A: First LRVM vector (current state, position, embedding)
            B: Second LRVM vector (target, goal, expected value)
        """
        self.A = A
        self.B = B

        # Compute lightlike invariant: I = ||A - B||²
        diff = A.subtract(B)
        self.invariant = float(np.dot(diff.coords, diff.coords))
        self.I = self.invariant  # Alias

        # Derive all geometric properties from I
        self._compute_geometry()

    def _compute_geometry(self) -> None:
        """
        Derive all geometric properties from the invariant I.

        This is the core of the EigenControl algorithm:
        from one number (I), generate the complete geometric description.
        """
        # 1D: Radius (scale of the problem)
        self.radius = np.sqrt(self.I) if self.I > 0 else 0.0
        self.r = self.radius  # Alias

        # 2D: Surface area (complexity measure)
        self.surface_area = 4.0 * np.pi * self.radius**2
        self.S = self.surface_area  # Alias

        # 3D: Volume (search space size)
        self.volume = (4.0 / 3.0) * np.pi * self.radius**3
        self.V = self.volume  # Alias

        # 0D: Curvature (problem conditioning)
        # κ = 1/r, but handle r=0 case (perfect convergence)
        if self.radius > 1e-10:
            self.curvature = 1.0 / self.radius
        else:
            self.curvature = float("inf")  # Perfectly conditioned
        self.kappa = self.curvature  # Alias

    def has_converged(self, epsilon: float = 1e-6) -> bool:
        """
        Check if the system has reached equilibrium.

        Convergence occurs when I → 0, which means A ≈ B.

        Args:
            epsilon: Convergence threshold

        Returns:
            True if I < epsilon (equilibrium reached)
        """
        return self.I < epsilon

    def get_conditioning(self) -> str:
        """
        Classify problem conditioning based on curvature.

        Returns:
            "well-conditioned", "moderately-conditioned", or "ill-conditioned"
        """
        if np.isinf(self.curvature) or self.curvature > 1e6:
            return "well-conditioned"  # κ → ∞, tight problem
        elif self.curvature > 1.0:
            return "moderately-conditioned"  # κ > 1, reasonable
        else:
            return "ill-conditioned"  # κ < 1, flat problem

    def get_framework_strength(self) -> float:
        """
        Compute Framework Strength from curvature.

        FS = normalized curvature = κ / (κ + 1) = 1 / (r + 1)

        Properties:
        - FS → 1.0 as r → 0 (converged, high curvature)
        - FS → 0.0 as r → ∞ (diverging, low curvature)
        - FS ∈ [0, 1] (always normalized)

        Returns:
            Framework Strength value in [0, 1]
        """
        return 1.0 / (self.radius + 1.0)

    def scaling_summary(self) -> dict:
        """
        Get summary of how all quantities scale with I.

        Returns:
            Dictionary with scaling relationships
        """
        return {
            "invariant": f"I = {self.I:.4e}",
            "radius": f"r ∝ I^(1/2) = {self.radius:.4e}",
            "surface_area": f"S ∝ I = {self.surface_area:.4e}",
            "volume": f"V ∝ I^(3/2) = {self.volume:.4e}",
            "curvature": f"κ ∝ I^(-1/2) = {self.curvature:.4e}",
        }

    def __repr__(self) -> str:
        """String representation."""
        return (
            f"EigenControl(\n"
            f"  I={self.I:.4e},\n"
            f"  r={self.radius:.4e},\n"
            f"  S={self.surface_area:.4e},\n"
            f"  V={self.volume:.4e},\n"
            f"  κ={self.curvature:.4e},\n"
            f"  {self.get_conditioning()}\n"
            f")"
        )

    def __str__(self) -> str:
        """Human-readable string."""
        converged = "✓" if self.has_converged() else "✗"
        return (
            f"{converged} I={self.I:.2e}, r={self.radius:.2e}, "
            f"κ={self.curvature:.2e}, {self.get_conditioning()}"
        )


class EigenControlTracker:
    """
    Track EigenControl geometry over a trajectory.

    This monitors how the geometric properties evolve during computation,
    providing convergence diagnostics.
    """

    def __init__(self):
        """Initialize empty trajectory."""
        self.trajectory: List[EigenControl] = []

    def update(self, current: LRVMVector, target: LRVMVector) -> EigenControl:
        """
        Add new state to trajectory and compute EigenControl geometry.

        Args:
            current: Current state vector
            target: Target/expected state vector

        Returns:
            EigenControl analysis for this step
        """
        eigen = EigenControl(current, target)
        self.trajectory.append(eigen)
        return eigen

    def get_latest(self) -> EigenControl:
        """Get most recent EigenControl analysis."""
        if not self.trajectory:
            raise ValueError("No trajectory data available")
        return self.trajectory[-1]

    def has_converged(self, window: int = 5, epsilon: float = 1e-6) -> bool:
        """
        Check if trajectory has converged.

        Convergence occurs when recent invariants are all below threshold.

        Args:
            window: Number of recent steps to check
            epsilon: Convergence threshold

        Returns:
            True if last 'window' steps all have I < epsilon
        """
        if len(self.trajectory) < window:
            return False

        recent = self.trajectory[-window:]
        return all(eigen.I < epsilon for eigen in recent)

    def get_radius_trend(self, window: int = 10) -> Tuple[float, str]:
        """
        Compute radius trend (expanding, stable, or contracting).

        Args:
            window: Number of recent steps to analyze

        Returns:
            Tuple of (average_change, classification)
        """
        if len(self.trajectory) < 2:
            return 0.0, "stable"

        recent = self.trajectory[-min(window, len(self.trajectory)) :]
        radii = [eigen.radius for eigen in recent]

        # Compute average change
        changes = np.diff(radii)
        avg_change = float(np.mean(changes))

        # Classify
        if avg_change < -1e-6:
            classification = "contracting"  # Converging
        elif avg_change > 1e-6:
            classification = "expanding"  # Diverging
        else:
            classification = "stable"  # Equilibrium

        return avg_change, classification

    def get_curvature_trend(self, window: int = 10) -> Tuple[float, str]:
        """
        Compute curvature trend (increasing, stable, or decreasing).

        Args:
            window: Number of recent steps to analyze

        Returns:
            Tuple of (average_change, classification)
        """
        if len(self.trajectory) < 2:
            return 0.0, "stable"

        recent = self.trajectory[-min(window, len(self.trajectory)) :]
        # Filter out infinite curvatures for trend analysis
        curvatures = [
            eigen.curvature for eigen in recent if not np.isinf(eigen.curvature)
        ]

        if len(curvatures) < 2:
            return 0.0, "stable"

        # Compute average change
        changes = np.diff(curvatures)
        avg_change = float(np.mean(changes))

        # Classify
        if avg_change > 1e-3:
            classification = "increasing"  # Better conditioning
        elif avg_change < -1e-3:
            classification = "decreasing"  # Worse conditioning
        else:
            classification = "stable"  # Steady

        return avg_change, classification

    def summary(self) -> dict:
        """
        Get summary statistics for the trajectory.

        Returns:
            Dictionary with trajectory statistics
        """
        if not self.trajectory:
            return {"error": "No trajectory data"}

        latest = self.get_latest()
        radius_change, radius_trend = self.get_radius_trend()
        curvature_change, curvature_trend = self.get_curvature_trend()

        return {
            "steps": len(self.trajectory),
            "current_I": latest.I,
            "current_r": latest.radius,
            "current_kappa": latest.curvature,
            "converged": self.has_converged(),
            "radius_trend": radius_trend,
            "curvature_trend": curvature_trend,
            "conditioning": latest.get_conditioning(),
            "framework_strength": latest.get_framework_strength(),
        }

    def __repr__(self) -> str:
        """String representation."""
        if not self.trajectory:
            return "EigenControlTracker(empty)"

        summary = self.summary()
        return (
            f"EigenControlTracker(\n"
            f"  steps={summary['steps']},\n"
            f"  I={summary['current_I']:.2e},\n"
            f"  r_trend={summary['radius_trend']},\n"
            f"  κ_trend={summary['curvature_trend']},\n"
            f"  converged={summary['converged']}\n"
            f")"
        )
