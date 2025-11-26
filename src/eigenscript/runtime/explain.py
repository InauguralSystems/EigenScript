"""
Explain mode for EigenScript semantic predicates.

This module provides human-readable explanations of predicate evaluations
at runtime, enabling users to understand *why* a predicate evaluated to
true or false.

Example output:
    Line 12: `if stable` → TRUE
      └─ signature = 1024.0 (timelike)
      └─ stable dimensions: 768, changing: 0
"""

import sys
from typing import Optional, List


class PredicateExplainer:
    """
    Manages explain mode for predicate evaluations.
    
    When explain mode is enabled, emits human-readable explanations
    of predicate evaluations to stderr.
    """
    
    def __init__(self, enabled: bool = False, use_color: bool = True):
        """
        Initialize the explainer.
        
        Args:
            enabled: Whether explain mode is active
            use_color: Whether to use ANSI color codes (auto-detected if True)
        """
        self.enabled = enabled
        self.use_color = use_color and self._supports_color()
        
    def _supports_color(self) -> bool:
        """Check if the terminal supports color output."""
        # Check if stderr is a TTY
        if not hasattr(sys.stderr, 'isatty') or not sys.stderr.isatty():
            return False
        # Check for NO_COLOR environment variable
        import os
        if os.environ.get('NO_COLOR'):
            return False
        return True
    
    def _color(self, text: str, color: str) -> str:
        """Apply ANSI color to text if colors are enabled."""
        if not self.use_color:
            return text
            
        colors = {
            'green': '\033[32m',
            'red': '\033[31m',
            'yellow': '\033[33m',
            'cyan': '\033[36m',
            'bold': '\033[1m',
            'reset': '\033[0m',
        }
        
        return f"{colors.get(color, '')}{text}{colors['reset']}"
    
    def explain_stable(
        self,
        result: bool,
        signature: float,
        classification: str,
        stable_dims: int,
        changing_dims: int,
    ) -> None:
        """
        Explain the evaluation of the `stable` predicate.
        
        Args:
            result: Whether the predicate evaluated to True
            signature: The spacetime signature value (S² - C²)
            classification: The classification ("timelike", "lightlike", "spacelike")
            stable_dims: Number of stable dimensions
            changing_dims: Number of changing dimensions
        """
        if not self.enabled:
            return
            
        result_str = self._color("TRUE", "green") if result else self._color("FALSE", "red")
        
        print(f"`stable` → {result_str}", file=sys.stderr)
        print(f"  └─ signature = {signature:.2f} ({classification})", file=sys.stderr)
        print(f"  └─ stable dimensions: {stable_dims}, changing: {changing_dims}", file=sys.stderr)
    
    def explain_converged(
        self,
        result: bool,
        fs: float,
        threshold: float,
    ) -> None:
        """
        Explain the evaluation of the `converged` predicate.
        
        Args:
            result: Whether the predicate evaluated to True
            fs: The Framework Strength value
            threshold: The convergence threshold
        """
        if not self.enabled:
            return
            
        result_str = self._color("TRUE", "green") if result else self._color("FALSE", "red")
        comparison = "≥" if result else "<"
        
        print(f"`converged` → {result_str}", file=sys.stderr)
        print(f"  └─ framework_strength = {fs:.4f} (threshold: {threshold})", file=sys.stderr)
        print(f"  └─ {fs:.4f} {comparison} {threshold}", file=sys.stderr)
    
    def explain_diverging(
        self,
        result: bool,
        signature: float,
        classification: str,
    ) -> None:
        """
        Explain the evaluation of the `diverging` predicate.
        
        Args:
            result: Whether the predicate evaluated to True
            signature: The spacetime signature value
            classification: The classification ("timelike", "lightlike", "spacelike")
        """
        if not self.enabled:
            return
            
        result_str = self._color("TRUE", "green") if result else self._color("FALSE", "red")
        
        print(f"`diverging` → {result_str}", file=sys.stderr)
        print(f"  └─ signature = {signature:.2f} ({classification})", file=sys.stderr)
        print(f"  └─ diverging when spacelike (S² - C² < 0)", file=sys.stderr)
    
    def explain_equilibrium(
        self,
        result: bool,
        signature: float,
        classification: str,
    ) -> None:
        """
        Explain the evaluation of the `equilibrium` predicate.
        
        Args:
            result: Whether the predicate evaluated to True
            signature: The spacetime signature value
            classification: The classification
        """
        if not self.enabled:
            return
            
        result_str = self._color("TRUE", "green") if result else self._color("FALSE", "red")
        
        print(f"`equilibrium` → {result_str}", file=sys.stderr)
        print(f"  └─ signature = {signature:.2f} ({classification})", file=sys.stderr)
        print(f"  └─ equilibrium when lightlike (S² - C² = 0)", file=sys.stderr)
    
    def explain_improving(
        self,
        result: bool,
        previous_radius: Optional[float],
        current_radius: Optional[float],
        trajectory_length: int,
    ) -> None:
        """
        Explain the evaluation of the `improving` predicate.
        
        Args:
            result: Whether the predicate evaluated to True
            previous_radius: The previous trajectory radius (None if not enough data)
            current_radius: The current trajectory radius (None if not enough data)
            trajectory_length: The length of the trajectory
        """
        if not self.enabled:
            return
            
        result_str = self._color("TRUE", "green") if result else self._color("FALSE", "red")
        
        print(f"`improving` → {result_str}", file=sys.stderr)
        if trajectory_length < 2:
            print(f"  └─ insufficient trajectory data (length: {trajectory_length})", file=sys.stderr)
        elif previous_radius is not None and current_radius is not None:
            delta = current_radius - previous_radius
            direction = "decreasing (improving)" if delta < 0 else "increasing (not improving)"
            print(f"  └─ radius: {previous_radius:.4f} → {current_radius:.4f}", file=sys.stderr)
            print(f"  └─ delta: {delta:+.4f} ({direction})", file=sys.stderr)
        else:
            print(f"  └─ radius data unavailable", file=sys.stderr)
    
    def explain_oscillating(
        self,
        result: bool,
        oscillation_score: float,
        threshold: float,
        sign_changes: int,
        trajectory_length: int,
        trajectory_values: Optional[List[float]] = None,
    ) -> None:
        """
        Explain the evaluation of the `oscillating` predicate.
        
        Args:
            result: Whether the predicate evaluated to True
            oscillation_score: The computed oscillation frequency
            threshold: The oscillation threshold (0.15)
            sign_changes: Number of sign changes in deltas
            trajectory_length: The length of the trajectory
            trajectory_values: Optional list of recent trajectory values
        """
        if not self.enabled:
            return
            
        result_str = self._color("TRUE", "green") if result else self._color("FALSE", "red")
        
        print(f"`oscillating` → {result_str}", file=sys.stderr)
        if trajectory_length < 5:
            print(f"  └─ insufficient trajectory data (length: {trajectory_length}, need: 5)", file=sys.stderr)
        else:
            comparison = ">" if result else "≤"
            print(f"  └─ oscillation_score = {oscillation_score:.3f} (threshold: {threshold})", file=sys.stderr)
            print(f"  └─ sign_changes: {sign_changes}", file=sys.stderr)
            if trajectory_values:
                values_str = ", ".join(f"{v:.2f}" for v in trajectory_values[-5:])
                print(f"  └─ trajectory: [{values_str}]", file=sys.stderr)
