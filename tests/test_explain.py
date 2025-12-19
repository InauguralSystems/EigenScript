"""
Unit tests for the EigenScript --explain mode.

Tests the explain mode functionality that provides human-readable
explanations of predicate evaluations.
"""

import pytest
import sys
from io import StringIO
from unittest.mock import patch

from eigenscript.__main__ import run_file, main
from eigenscript.evaluator import Interpreter
from eigenscript.runtime.explain import PredicateExplainer


class TestPredicateExplainer:
    """Test suite for PredicateExplainer class."""

    def test_explainer_disabled_by_default(self):
        """Should not emit output when disabled."""
        explainer = PredicateExplainer(enabled=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_stable(
                result=True,
                signature=100.0,
                classification="timelike",
                stable_dims=768,
                changing_dims=0,
            )
        assert stderr.getvalue() == ""

    def test_explainer_enabled(self):
        """Should emit output when enabled."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_stable(
                result=True,
                signature=100.0,
                classification="timelike",
                stable_dims=768,
                changing_dims=0,
            )
        output = stderr.getvalue()
        assert "`stable` → TRUE" in output
        assert "signature = 100.00" in output
        assert "timelike" in output
        assert "stable dimensions: 768" in output

    def test_explain_stable_false(self):
        """Should format FALSE result correctly."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_stable(
                result=False,
                signature=-50.0,
                classification="spacelike",
                stable_dims=10,
                changing_dims=20,
            )
        output = stderr.getvalue()
        assert "`stable` → FALSE" in output
        assert "spacelike" in output

    def test_explain_converged(self):
        """Should explain converged predicate."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_converged(
                result=True,
                fs=0.98,
                threshold=0.95,
            )
        output = stderr.getvalue()
        assert "`converged` → TRUE" in output
        assert "framework_strength = 0.9800" in output
        assert "threshold: 0.95" in output
        assert "≥" in output

    def test_explain_converged_false(self):
        """Should explain converged=False with < comparison."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_converged(
                result=False,
                fs=0.42,
                threshold=0.95,
            )
        output = stderr.getvalue()
        assert "`converged` → FALSE" in output
        assert "<" in output

    def test_explain_diverging(self):
        """Should explain diverging predicate."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_diverging(
                result=True,
                signature=-100.0,
                classification="spacelike",
            )
        output = stderr.getvalue()
        assert "`diverging` → TRUE" in output
        assert "spacelike" in output

    def test_explain_equilibrium(self):
        """Should explain equilibrium predicate."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_equilibrium(
                result=True,
                signature=0.0,
                classification="lightlike",
            )
        output = stderr.getvalue()
        assert "`equilibrium` → TRUE" in output
        assert "lightlike" in output

    def test_explain_improving(self):
        """Should explain improving predicate with trajectory data."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_improving(
                result=True,
                previous_radius=10.0,
                current_radius=8.0,
                trajectory_length=5,
            )
        output = stderr.getvalue()
        assert "`improving` → TRUE" in output
        assert "radius: 10.0000 → 8.0000" in output
        assert "decreasing (improving)" in output

    def test_explain_improving_flat(self):
        """Should explain improving predicate when radius is unchanged."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_improving(
                result=False,
                previous_radius=5.0,
                current_radius=5.0,
                trajectory_length=3,
            )
        output = stderr.getvalue()
        assert "`improving` → FALSE" in output
        assert "unchanged (not improving)" in output

    def test_explain_improving_insufficient_data(self):
        """Should explain improving with insufficient trajectory."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_improving(
                result=False,
                previous_radius=None,
                current_radius=None,
                trajectory_length=1,
            )
        output = stderr.getvalue()
        assert "`improving` → FALSE" in output
        assert "insufficient trajectory data" in output

    def test_explain_oscillating(self):
        """Should explain oscillating predicate."""
        explainer = PredicateExplainer(enabled=True, use_color=False)
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            explainer.explain_oscillating(
                result=True,
                oscillation_score=0.25,
                threshold=0.15,
                sign_changes=2,
                trajectory_length=5,
                trajectory_values=[1.0, 2.0, 1.5, 2.5, 1.8],
            )
        output = stderr.getvalue()
        assert "`oscillating` → TRUE" in output
        assert "oscillation_score = 0.250" in output
        assert "sign_changes: 2" in output
        assert "trajectory:" in output


class TestInterpreterExplainMode:
    """Test suite for Interpreter with explain mode."""

    def test_interpreter_default_no_explain(self):
        """Interpreter should have explain mode disabled by default."""
        interp = Interpreter()
        assert not interp.explainer.enabled

    def test_interpreter_explain_mode_enabled(self):
        """Interpreter should enable explain mode when requested."""
        interp = Interpreter(explain_mode=True)
        assert interp.explainer.enabled


class TestExplainFlag:
    """Test suite for --explain CLI flag."""

    def test_explain_flag_recognized(self, tmp_path, capsys):
        """Should recognize --explain flag."""
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        with patch.object(sys, "argv", ["eigenscript", str(test_file), "--explain"]):
            exit_code = main()

        assert exit_code == 0

    def test_explain_short_flag_recognized(self, tmp_path, capsys):
        """Should recognize -e flag."""
        test_file = tmp_path / "test.eigs"
        test_file.write_text("x is 5\n")

        with patch.object(sys, "argv", ["eigenscript", str(test_file), "-e"]):
            exit_code = main()

        assert exit_code == 0

    def test_explain_flag_emits_to_stderr(self, tmp_path, capsys):
        """Should emit explain output to stderr."""
        test_file = tmp_path / "test.eigs"
        test_file.write_text(
            """
x is 10
if stable:
    y is 1
"""
        )

        exit_code = run_file(str(test_file), explain=True)

        captured = capsys.readouterr()
        assert exit_code == 0
        # Explain output should be in stderr
        assert "`stable`" in captured.err
        # stdout should remain clean
        assert "`stable`" not in captured.out

    def test_explain_combined_with_verbose(self, tmp_path, capsys):
        """Should work with --verbose flag."""
        test_file = tmp_path / "test.eigs"
        test_file.write_text(
            """
x is 5
if converged:
    print of "done"
"""
        )

        with patch.object(sys, "argv", ["eigenscript", str(test_file), "-e", "-v"]):
            exit_code = main()

        captured = capsys.readouterr()
        assert exit_code == 0
        # Should have both verbose output and explain output
        assert "Executing:" in captured.out
        assert "`converged`" in captured.err

    def test_explain_output_format(self, tmp_path, capsys):
        """Should have correct output format with indentation."""
        test_file = tmp_path / "test.eigs"
        test_file.write_text(
            """
x is 100
loop while x > 0:
    x is x - 10
if stable:
    print of "stable"
"""
        )

        exit_code = run_file(str(test_file), explain=True)

        captured = capsys.readouterr()
        assert exit_code == 0
        # Check format with tree-like indentation
        assert "└─" in captured.err

    def test_explain_all_predicates(self, tmp_path, capsys):
        """Should explain all predicates when used."""
        test_file = tmp_path / "test.eigs"
        test_file.write_text(
            """
x is 100
i is 0
loop while i < 6:
    x is x - 5
    i is i + 1

if stable:
    y is 1
if converged:
    y is 2
if diverging:
    y is 3
if equilibrium:
    y is 4
if improving:
    y is 5
if oscillating:
    y is 6
"""
        )

        exit_code = run_file(str(test_file), explain=True)

        captured = capsys.readouterr()
        assert exit_code == 0
        # All predicates should be explained
        assert "`stable`" in captured.err
        assert "`converged`" in captured.err
        assert "`diverging`" in captured.err
        assert "`equilibrium`" in captured.err
        assert "`improving`" in captured.err
        assert "`oscillating`" in captured.err
