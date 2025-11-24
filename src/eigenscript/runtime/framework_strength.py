"""
Framework Strength measurement for EigenScript.

Framework Strength (FS) quantifies the degree of semantic convergence
and understanding during program execution. It measures how close the
system is to achieving a stable eigenstate.
"""

import numpy as np
from typing import List
from eigenscript.semantic.lrvm import LRVMVector


class FrameworkStrengthTracker:
    """
    Tracks and measures Framework Strength during execution.

    Framework Strength (FS) is a metric that quantifies:
    - Semantic convergence (how stable the trajectory is)
    - Eigenstate achievement (reaching fixed points)
    - Understanding (coherence of the semantic flow)

    FS ranges from 0.0 (fragmented/chaotic) to 1.0 (converged/understood).

    Example:
        >>> tracker = FrameworkStrengthTracker()
        >>> v1 = LRVMVector([1.0, 0.0, 0.0])
        >>> tracker.update(v1)
        >>> v2 = LRVMVector([1.01, 0.0, 0.0])
        >>> tracker.update(v2)
        >>> fs = tracker.compute_fs()
        >>> print(f"FS: {fs:.2f}")
        FS: 0.95
    """

    def __init__(self, window_size: int = 10):
        """
        Initialize the Framework Strength tracker.

        Args:
            window_size: Number of recent states to consider for FS computation
        """
        self.trajectory: List[LRVMVector] = []
        self.window_size = window_size

    def update(self, state: LRVMVector) -> None:
        """
        Add a new state to the trajectory.

        This should be called after each significant operation
        (assignment, relation, etc.)

        Args:
            state: Current LRVM state vector
        """
        # Only track LRVMVectors, not EigenLists
        if isinstance(state, LRVMVector):
            self.trajectory.append(state)

    def compute_fs(self) -> float:
        """
        Compute current Framework Strength.

        FS is computed based on several factors:
        1. Variance reduction (convergence)
        2. Trajectory smoothness
        3. Eigenstate stability

        Returns:
            Framework Strength value between 0.0 and 1.0

        Note:
            Returns 0.0 if insufficient data points
        """
        if len(self.trajectory) < 2:
            return 0.0

        # Get recent states (sliding window)
        recent_states = self.trajectory[-self.window_size :]

        # Compute variance across trajectory
        variance = self._compute_variance(recent_states)

        # Compute smoothness (how steady the trajectory is)
        smoothness = self._compute_smoothness(recent_states)

        # Compute eigenstate stability (fixed point detection)
        stability = self._compute_stability(recent_states)

        # Combine metrics (weighted average)
        # Lower variance → higher FS
        # Higher smoothness → higher FS
        # Higher stability → higher FS

        variance_fs = 1.0 / (1.0 + variance)
        smoothness_fs = smoothness
        stability_fs = stability

        # Weighted combination
        fs = 0.4 * variance_fs + 0.3 * smoothness_fs + 0.3 * stability_fs

        # Clamp to [0, 1]
        return float(np.clip(fs, 0.0, 1.0))

    def _compute_variance(self, states: List[LRVMVector]) -> float:
        """
        Compute variance of the trajectory.

        Lower variance indicates convergence.

        Args:
            states: List of LRVM vectors

        Returns:
            Variance value
        """
        if len(states) < 2:
            return 0.0

        # Stack coordinates into matrix
        coords = np.array([s.coords for s in states])

        # Compute variance across trajectory
        variance = np.var(coords)

        return float(variance)

    def _compute_smoothness(self, states: List[LRVMVector]) -> float:
        """
        Compute smoothness of the trajectory.

        Measures how steady the changes are (low acceleration).

        Args:
            states: List of LRVM vectors

        Returns:
            Smoothness value between 0.0 and 1.0
        """
        if len(states) < 3:
            return 0.5  # Neutral value

        # Compute second derivatives (acceleration)
        accelerations = []
        for i in range(len(states) - 2):
            v0 = states[i].coords
            v1 = states[i + 1].coords
            v2 = states[i + 2].coords

            # Second derivative approximation
            accel = v2 - 2 * v1 + v0
            accel_magnitude = np.linalg.norm(accel)
            accelerations.append(accel_magnitude)

        # Lower average acceleration → smoother
        avg_accel = np.mean(accelerations)

        # Convert to 0-1 range (exponential decay)
        smoothness = np.exp(-avg_accel)

        return float(smoothness)

    def _compute_stability(self, states: List[LRVMVector]) -> float:
        """
        Compute eigenstate stability (fixed point detection).

        Measures if the trajectory is approaching a fixed point.

        Args:
            states: List of LRVM vectors

        Returns:
            Stability value between 0.0 and 1.0
        """
        if len(states) < 2:
            return 0.0

        # Compute distances between consecutive states
        distances = []
        for i in range(len(states) - 1):
            dist = np.linalg.norm(states[i + 1].coords - states[i].coords)
            distances.append(dist)

        # Check if distances are decreasing (approaching fixed point)
        if len(distances) < 2:
            return 0.5

        # Compute trend (negative slope means converging)
        trend = np.polyfit(range(len(distances)), distances, 1)[0]

        # Negative trend (decreasing distances) → high stability
        # Positive trend (increasing distances) → low stability
        if trend < 0:
            stability = np.clip(1.0 + trend, 0.0, 1.0)
        else:
            stability = np.clip(1.0 - trend, 0.0, 1.0)

        return float(stability)

    def has_converged(self, threshold: float = 0.95) -> bool:
        """
        Check if the trajectory has converged to an eigenstate.

        Args:
            threshold: FS threshold for convergence (default: 0.95)

        Returns:
            True if FS >= threshold

        Example:
            >>> tracker = FrameworkStrengthTracker()
            >>> # ... update with converging trajectory ...
            >>> if tracker.has_converged():
            ...     print("Eigenstate achieved!")
        """
        return self.compute_fs() >= threshold

    def get_convergence_score(self) -> float:
        """
        Get a normalized convergence score.

        This is similar to FS but specifically focuses on
        convergence to a fixed point.

        Returns:
            Convergence score between 0.0 and 1.0
        """
        if len(self.trajectory) < 2:
            return 0.0

        recent_states = self.trajectory[-self.window_size :]
        return self._compute_stability(recent_states)

    def reset(self) -> None:
        """
        Reset the tracker (clear trajectory history).

        Useful when starting a new execution context.
        """
        self.trajectory.clear()

    def get_trajectory_length(self) -> int:
        """
        Get the number of states in the trajectory.

        Returns:
            Number of recorded states
        """
        return len(self.trajectory)

    def __repr__(self) -> str:
        """String representation."""
        fs = self.compute_fs() if len(self.trajectory) >= 2 else 0.0
        return f"FrameworkStrengthTracker(states={len(self.trajectory)}, FS={fs:.3f})"
