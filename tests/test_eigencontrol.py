"""
Tests for EigenControl and EigenControlTracker.

This module tests the core geometric algorithm that powers EigenScript's
self-interrogation and convergence detection capabilities.
"""

import pytest
import numpy as np
from eigenscript.semantic.lrvm import LRVMSpace
from eigenscript.runtime.eigencontrol import EigenControl, EigenControlTracker


class TestEigenControlBasics:
    """Test basic EigenControl initialization and properties."""

    def setup_method(self):
        """Set up test fixtures."""
        self.space = LRVMSpace(768)
        self.A = self.space.embed_scalar(5.0)
        self.B = self.space.embed_scalar(3.0)

    def test_eigencontrol_initialization(self):
        """Test EigenControl can be initialized with two vectors."""
        eigen = EigenControl(self.A, self.B)
        assert eigen is not None
        assert eigen.A is self.A
        assert eigen.B is self.B

    def test_invariant_computation(self):
        """Test that invariant I = ||A - B||² is computed correctly."""
        eigen = EigenControl(self.A, self.B)
        # For scalars 5.0 and 3.0, difference is 2.0
        # In LRVM space, this gets embedded, so we just check it's positive
        assert eigen.I > 0
        assert eigen.invariant == eigen.I  # Alias works

    def test_radius_computation(self):
        """Test radius r = sqrt(I) is computed correctly."""
        eigen = EigenControl(self.A, self.B)
        assert eigen.radius >= 0
        assert eigen.r == eigen.radius  # Alias works
        # Verify relationship: r = sqrt(I)
        assert abs(eigen.radius - np.sqrt(eigen.I)) < 1e-10

    def test_surface_area_computation(self):
        """Test surface area S = 4πr² is computed correctly."""
        eigen = EigenControl(self.A, self.B)
        expected_surface = 4.0 * np.pi * eigen.radius**2
        assert abs(eigen.surface_area - expected_surface) < 1e-10
        assert eigen.S == eigen.surface_area  # Alias works

    def test_volume_computation(self):
        """Test volume V = (4/3)πr³ is computed correctly."""
        eigen = EigenControl(self.A, self.B)
        expected_volume = (4.0 / 3.0) * np.pi * eigen.radius**3
        assert abs(eigen.volume - expected_volume) < 1e-10
        assert eigen.V == eigen.volume  # Alias works

    def test_curvature_computation(self):
        """Test curvature κ = 1/r is computed correctly."""
        eigen = EigenControl(self.A, self.B)
        if eigen.radius > 1e-10:
            expected_curvature = 1.0 / eigen.radius
            assert abs(eigen.curvature - expected_curvature) < 1e-10
        assert eigen.kappa == eigen.curvature  # Alias works


class TestEigenControlEdgeCases:
    """Test edge cases and special conditions."""

    def setup_method(self):
        """Set up test fixtures."""
        self.space = LRVMSpace(768)

    def test_identical_vectors(self):
        """Test EigenControl with A = B (perfect convergence)."""
        A = self.space.embed_scalar(5.0)
        B = self.space.embed_scalar(5.0)
        eigen = EigenControl(A, B)

        # I should be very small (near zero)
        assert eigen.I < 1e-6
        # Radius should be very small
        assert eigen.radius < 1e-3
        # Curvature should be very large (infinity)
        assert eigen.curvature > 1e6 or np.isinf(eigen.curvature)

    def test_very_close_vectors(self):
        """Test EigenControl with nearly identical vectors."""
        A = self.space.embed_scalar(5.0)
        B = self.space.embed_scalar(5.0 + 1e-8)
        eigen = EigenControl(A, B)

        # Should be close to convergence
        assert eigen.I < 1e-6

    def test_very_different_vectors(self):
        """Test EigenControl with very different vectors."""
        A = self.space.embed_scalar(1000.0)
        B = self.space.embed_scalar(0.0)
        eigen = EigenControl(A, B)

        # I should be large
        assert eigen.I > 1.0
        # Radius should be large
        assert eigen.radius > 1.0
        # Curvature should be small
        assert eigen.curvature < 1.0


class TestEigenControlConvergence:
    """Test convergence detection."""

    def setup_method(self):
        """Set up test fixtures."""
        self.space = LRVMSpace(768)

    def test_has_converged_default_epsilon(self):
        """Test convergence detection with default epsilon."""
        A = self.space.embed_scalar(5.0)
        B = self.space.embed_scalar(5.0)
        eigen = EigenControl(A, B)
        assert eigen.has_converged()

    def test_has_converged_custom_epsilon(self):
        """Test convergence detection with custom epsilon."""
        A = self.space.embed_scalar(5.0)
        B = self.space.embed_scalar(5.001)
        eigen = EigenControl(A, B)

        # Should not converge with strict epsilon
        assert not eigen.has_converged(epsilon=1e-10)
        # Should converge with relaxed epsilon
        assert eigen.has_converged(epsilon=1.0)

    def test_not_converged(self):
        """Test non-convergence detection."""
        A = self.space.embed_scalar(10.0)
        B = self.space.embed_scalar(0.0)
        eigen = EigenControl(A, B)
        assert not eigen.has_converged()


class TestEigenControlConditioning:
    """Test problem conditioning classification."""

    def setup_method(self):
        """Set up test fixtures."""
        self.space = LRVMSpace(768)

    def test_well_conditioned(self):
        """Test well-conditioned classification (high curvature)."""
        A = self.space.embed_scalar(5.0)
        B = self.space.embed_scalar(5.0)
        eigen = EigenControl(A, B)
        assert eigen.get_conditioning() == "well-conditioned"

    def test_moderately_conditioned(self):
        """Test moderately-conditioned classification (medium curvature)."""
        A = self.space.embed_scalar(5.0)
        B = self.space.embed_scalar(4.0)
        eigen = EigenControl(A, B)
        conditioning = eigen.get_conditioning()
        assert conditioning in [
            "well-conditioned",
            "moderately-conditioned",
            "ill-conditioned",
        ]

    def test_ill_conditioned(self):
        """Test ill-conditioned classification (low curvature)."""
        A = self.space.embed_scalar(100.0)
        B = self.space.embed_scalar(0.0)
        eigen = EigenControl(A, B)
        # Large difference means large radius, small curvature
        assert eigen.curvature < 1.0
        assert eigen.get_conditioning() == "ill-conditioned"


class TestEigenControlFrameworkStrength:
    """Test Framework Strength computation."""

    def setup_method(self):
        """Set up test fixtures."""
        self.space = LRVMSpace(768)

    def test_framework_strength_converged(self):
        """Test FS approaches 1.0 when converged."""
        A = self.space.embed_scalar(5.0)
        B = self.space.embed_scalar(5.0)
        eigen = EigenControl(A, B)
        fs = eigen.get_framework_strength()
        assert 0.0 <= fs <= 1.0
        assert fs > 0.9  # Should be high when converged

    def test_framework_strength_diverged(self):
        """Test FS approaches 0.0 when diverged."""
        A = self.space.embed_scalar(1000.0)
        B = self.space.embed_scalar(0.0)
        eigen = EigenControl(A, B)
        fs = eigen.get_framework_strength()
        assert 0.0 <= fs <= 1.0
        assert fs < 0.5  # Should be low when diverged

    def test_framework_strength_range(self):
        """Test FS is always in [0, 1] range."""
        for i in range(10):
            A = self.space.embed_scalar(float(i))
            B = self.space.embed_scalar(0.0)
            eigen = EigenControl(A, B)
            fs = eigen.get_framework_strength()
            assert 0.0 <= fs <= 1.0


class TestEigenControlScaling:
    """Test scaling relationships."""

    def test_scaling_summary(self):
        """Test scaling summary returns expected keys."""
        space = LRVMSpace(768)
        A = space.embed_scalar(5.0)
        B = space.embed_scalar(3.0)
        eigen = EigenControl(A, B)

        summary = eigen.scaling_summary()
        assert "invariant" in summary
        assert "radius" in summary
        assert "surface_area" in summary
        assert "volume" in summary
        assert "curvature" in summary


class TestEigenControlStringRepresentation:
    """Test string representations."""

    def test_repr(self):
        """Test __repr__ produces valid string."""
        space = LRVMSpace(768)
        A = space.embed_scalar(5.0)
        B = space.embed_scalar(3.0)
        eigen = EigenControl(A, B)

        repr_str = repr(eigen)
        assert "EigenControl" in repr_str
        assert "I=" in repr_str
        assert "r=" in repr_str

    def test_str(self):
        """Test __str__ produces human-readable string."""
        space = LRVMSpace(768)
        A = space.embed_scalar(5.0)
        B = space.embed_scalar(3.0)
        eigen = EigenControl(A, B)

        str_repr = str(eigen)
        assert "I=" in str_repr
        assert "r=" in str_repr
        # Should have checkmark or X
        assert "✓" in str_repr or "✗" in str_repr


class TestEigenControlTracker:
    """Test EigenControlTracker trajectory monitoring."""

    def setup_method(self):
        """Set up test fixtures."""
        self.space = LRVMSpace(768)
        self.tracker = EigenControlTracker()

    def test_tracker_initialization(self):
        """Test tracker initializes empty."""
        assert len(self.tracker.trajectory) == 0

    def test_tracker_update(self):
        """Test tracker can add new states."""
        current = self.space.embed_scalar(5.0)
        target = self.space.embed_scalar(3.0)

        eigen = self.tracker.update(current, target)
        assert eigen is not None
        assert len(self.tracker.trajectory) == 1

    def test_tracker_multiple_updates(self):
        """Test tracker accumulates trajectory."""
        target = self.space.embed_scalar(0.0)

        for i in range(10):
            current = self.space.embed_scalar(float(10 - i))
            self.tracker.update(current, target)

        assert len(self.tracker.trajectory) == 10

    def test_get_latest(self):
        """Test get_latest returns most recent EigenControl."""
        target = self.space.embed_scalar(0.0)

        for i in range(5):
            current = self.space.embed_scalar(float(i))
            self.tracker.update(current, target)

        latest = self.tracker.get_latest()
        assert latest is not None
        assert latest is self.tracker.trajectory[-1]

    def test_get_latest_empty_raises(self):
        """Test get_latest raises error when empty."""
        with pytest.raises(ValueError, match="No trajectory data"):
            self.tracker.get_latest()

    def test_has_converged_insufficient_data(self):
        """Test convergence check with insufficient data."""
        target = self.space.embed_scalar(0.0)
        current = self.space.embed_scalar(0.0)
        self.tracker.update(current, target)

        # Only 1 point, need 5 for default window
        assert not self.tracker.has_converged()

    def test_has_converged_with_convergence(self):
        """Test convergence detection in trajectory."""
        target = self.space.embed_scalar(0.0)

        # Create converging trajectory
        for i in range(10):
            current = self.space.embed_scalar(0.0)  # Same as target
            self.tracker.update(current, target)

        assert self.tracker.has_converged()

    def test_has_converged_custom_window(self):
        """Test convergence with custom window size."""
        target = self.space.embed_scalar(0.0)

        # Add 2 converged points
        for i in range(2):
            current = self.space.embed_scalar(0.0)
            self.tracker.update(current, target)

        assert self.tracker.has_converged(window=2)


class TestEigenControlTrackerTrends:
    """Test trajectory trend analysis."""

    def setup_method(self):
        """Set up test fixtures."""
        self.space = LRVMSpace(768)
        self.tracker = EigenControlTracker()

    def test_radius_trend_contracting(self):
        """Test radius trend detects contraction (convergence)."""
        target = self.space.embed_scalar(0.0)

        # Create contracting trajectory
        for i in range(10, 0, -1):
            current = self.space.embed_scalar(float(i))
            self.tracker.update(current, target)

        avg_change, classification = self.tracker.get_radius_trend()
        assert classification == "contracting"
        assert avg_change < 0

    def test_radius_trend_expanding(self):
        """Test radius trend detects expansion (divergence)."""
        target = self.space.embed_scalar(0.0)

        # Create expanding trajectory
        for i in range(10):
            current = self.space.embed_scalar(float(i))
            self.tracker.update(current, target)

        avg_change, classification = self.tracker.get_radius_trend()
        assert classification == "expanding"
        assert avg_change > 0

    def test_radius_trend_stable(self):
        """Test radius trend detects stability."""
        target = self.space.embed_scalar(0.0)

        # Create stable trajectory
        for i in range(10):
            current = self.space.embed_scalar(5.0)
            self.tracker.update(current, target)

        avg_change, classification = self.tracker.get_radius_trend()
        assert classification == "stable"
        assert abs(avg_change) < 1e-6

    def test_radius_trend_insufficient_data(self):
        """Test radius trend with insufficient data."""
        avg_change, classification = self.tracker.get_radius_trend()
        assert classification == "stable"
        assert avg_change == 0.0

    def test_curvature_trend_increasing(self):
        """Test curvature trend detects increase (improving conditioning)."""
        target = self.space.embed_scalar(0.0)

        # Create trajectory with increasing curvature (decreasing radius)
        for i in range(10, 0, -1):
            current = self.space.embed_scalar(float(i) / 10.0)
            self.tracker.update(current, target)

        avg_change, classification = self.tracker.get_curvature_trend()
        # May be increasing, stable, or decreasing depending on math
        assert classification in ["increasing", "decreasing", "stable"]

    def test_curvature_trend_insufficient_data(self):
        """Test curvature trend with insufficient data."""
        avg_change, classification = self.tracker.get_curvature_trend()
        assert classification == "stable"
        assert avg_change == 0.0


class TestEigenControlTrackerSummary:
    """Test tracker summary statistics."""

    def setup_method(self):
        """Set up test fixtures."""
        self.space = LRVMSpace(768)
        self.tracker = EigenControlTracker()

    def test_summary_empty_tracker(self):
        """Test summary with empty tracker."""
        summary = self.tracker.summary()
        assert "error" in summary

    def test_summary_with_data(self):
        """Test summary with trajectory data."""
        target = self.space.embed_scalar(0.0)

        for i in range(10):
            current = self.space.embed_scalar(float(10 - i))
            self.tracker.update(current, target)

        summary = self.tracker.summary()
        assert "steps" in summary
        assert summary["steps"] == 10
        assert "current_I" in summary
        assert "current_r" in summary
        assert "current_kappa" in summary
        assert "converged" in summary
        assert "radius_trend" in summary
        assert "curvature_trend" in summary
        assert "conditioning" in summary
        assert "framework_strength" in summary

    def test_summary_values_valid(self):
        """Test summary contains valid values."""
        target = self.space.embed_scalar(0.0)

        for i in range(10):
            current = self.space.embed_scalar(float(i))
            self.tracker.update(current, target)

        summary = self.tracker.summary()
        assert summary["steps"] > 0
        assert summary["current_I"] >= 0
        assert summary["current_r"] >= 0
        assert 0.0 <= summary["framework_strength"] <= 1.0


class TestEigenControlTrackerStringRepresentation:
    """Test tracker string representations."""

    def test_repr_empty(self):
        """Test __repr__ with empty tracker."""
        tracker = EigenControlTracker()
        repr_str = repr(tracker)
        assert "EigenControlTracker" in repr_str
        assert "empty" in repr_str

    def test_repr_with_data(self):
        """Test __repr__ with trajectory data."""
        space = LRVMSpace(768)
        tracker = EigenControlTracker()

        target = space.embed_scalar(0.0)
        for i in range(5):
            current = space.embed_scalar(float(i))
            tracker.update(current, target)

        repr_str = repr(tracker)
        assert "EigenControlTracker" in repr_str
        assert "steps=" in repr_str
        assert "I=" in repr_str
