"""
Runtime module for EigenScript.

This module handles runtime state management including:
- Framework Strength measurement
- Convergence detection
- Communication clarity tracking
- Built-in functions
"""

from eigenscript.runtime.framework_strength import FrameworkStrengthTracker
from eigenscript.runtime.clarity import (
    ClarityType,
    ClarityState,
    ClarityTracker,
    ClarityExplainer,
    AmbiguityResolver,
    Assumption,
    detect_assumptions,
)

__all__ = [
    "FrameworkStrengthTracker",
    "ClarityType",
    "ClarityState",
    "ClarityTracker",
    "ClarityExplainer",
    "AmbiguityResolver",
    "Assumption",
    "detect_assumptions",
]
