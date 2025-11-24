"""
Runtime module for EigenScript.

This module handles runtime state management including:
- Framework Strength measurement
- Convergence detection
- Built-in functions
"""

from eigenscript.runtime.framework_strength import FrameworkStrengthTracker

__all__ = ["FrameworkStrengthTracker"]
