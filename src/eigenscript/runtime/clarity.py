"""
Communication Clarity Framework for EigenScript.

This module implements hypothesis-driven communication semantics where:
- Clarity is required before execution (not optional)
- Hidden variables are made explicit
- Intent is treated as falsifiable hypothesis
- Agency remains with the speaker (programmer)

The framework applies the same rigor to code that EigenScript applies
to computation: programs must pass clarity checks before execution,
just as they must pass convergence checks.

Key Principles:
    1. Questions and statements both assign objectives (create work)
    2. Implication is not universal (hidden variables cause failure)
    3. Clarification is hypothesis testing (not social correction)
    4. Withhold inference intentionally (don't collapse ambiguity silently)
    5. Control remains with the speaker (present options, don't decide)
    6. Speakers discover their own intent (force internal alignment)

Clarity Types (parallel to geometric signatures):
    - Ambiguous: Multiple valid interpretations exist (||c||² < 0, spacelike)
    - Tentative: Hypothesis stated but unverified (||c||² = 0, lightlike)
    - Clarified: Intent verified, ready for execution (||c||² > 0, timelike)
"""

import sys
import numpy as np
from typing import List, Dict, Optional, Set, Tuple, Any
from dataclasses import dataclass, field
from enum import Enum


class ClarityType(Enum):
    """
    Classification of intent clarity (parallel to geometric signatures).

    Maps to the communication framework:
    - AMBIGUOUS: Hidden variables present, multiple interpretations possible
    - TENTATIVE: Hypothesis stated but not yet confirmed
    - CLARIFIED: Intent explicit and verified, safe to execute
    """

    AMBIGUOUS = "ambiguous"  # Spacelike: exploring, unstable
    TENTATIVE = "tentative"  # Lightlike: at boundary
    CLARIFIED = "clarified"  # Timelike: converged, stable


@dataclass
class Assumption:
    """
    Represents an implicit assumption in code.

    Assumptions are hidden variables that haven't been made explicit.
    The clarity framework detects and surfaces these for verification.
    """

    name: str  # What is being assumed
    source: str  # Where the assumption originates (variable, operation, etc.)
    context: str  # Additional context about why this is an assumption
    line: Optional[int] = None  # Source line if available

    def __repr__(self) -> str:
        loc = f" (line {self.line})" if self.line else ""
        return f"Assumption({self.name!r} from {self.source!r}{loc})"


@dataclass
class ClarityState:
    """
    Tracks the clarity state of a value or binding.

    Each binding in EigenScript can have an associated clarity state
    that tracks whether its intent has been verified.
    """

    clarity_type: ClarityType = ClarityType.AMBIGUOUS
    assumptions: List[Assumption] = field(default_factory=list)
    verified_at: Optional[int] = None  # Iteration when clarified
    hypothesis: Optional[str] = None  # The stated hypothesis if tentative

    def is_clear(self) -> bool:
        """Check if this state is clarified (safe to execute)."""
        return self.clarity_type == ClarityType.CLARIFIED

    def is_tentative(self) -> bool:
        """Check if this state is a hypothesis awaiting verification."""
        return self.clarity_type == ClarityType.TENTATIVE

    def is_ambiguous(self) -> bool:
        """Check if this state has unresolved ambiguity."""
        return self.clarity_type == ClarityType.AMBIGUOUS

    def has_assumptions(self) -> bool:
        """Check if there are unverified assumptions."""
        return len(self.assumptions) > 0


class ClarityTracker:
    """
    Tracks communication clarity throughout program execution.

    Analogous to FrameworkStrengthTracker, but measures semantic
    clarity rather than computational convergence.

    The tracker monitors:
    - Hidden variables (assumptions not made explicit)
    - Ambiguous bindings (values with multiple interpretations)
    - Tentative hypotheses (stated but unverified intent)
    - Clarified state (verified, ready for execution)

    Example:
        >>> tracker = ClarityTracker()
        >>> tracker.register_binding("x", tentative=True, hypothesis="x is a counter")
        >>> tracker.get_clarity("x")
        ClarityState(clarity_type=TENTATIVE, ...)
        >>> tracker.clarify("x")
        >>> tracker.is_clarified("x")
        True
    """

    def __init__(self):
        """Initialize the clarity tracker."""
        self.bindings: Dict[str, ClarityState] = {}
        self.global_assumptions: List[Assumption] = []
        self.clarification_history: List[Tuple[str, int]] = []
        self.iteration: int = 0

    def register_binding(
        self,
        name: str,
        tentative: bool = False,
        hypothesis: Optional[str] = None,
        assumptions: Optional[List[Assumption]] = None,
    ) -> ClarityState:
        """
        Register a new binding with its clarity state.

        Args:
            name: Variable name
            tentative: Whether this is a tentative (might is) binding
            hypothesis: The stated hypothesis for tentative bindings
            assumptions: Any detected assumptions

        Returns:
            The created ClarityState
        """
        if tentative:
            clarity_type = ClarityType.TENTATIVE
        elif assumptions:
            clarity_type = ClarityType.AMBIGUOUS
        else:
            clarity_type = ClarityType.CLARIFIED

        state = ClarityState(
            clarity_type=clarity_type,
            assumptions=assumptions or [],
            hypothesis=hypothesis,
            verified_at=self.iteration if clarity_type == ClarityType.CLARIFIED else None,
        )

        self.bindings[name] = state
        return state

    def register_assumption(
        self,
        name: str,
        source: str,
        context: str,
        line: Optional[int] = None,
        binding: Optional[str] = None,
    ) -> Assumption:
        """
        Register a detected assumption (hidden variable).

        Args:
            name: What is being assumed
            source: Where the assumption originates
            context: Why this is considered an assumption
            line: Source line number if available
            binding: Associated binding name, if any

        Returns:
            The created Assumption
        """
        assumption = Assumption(name=name, source=source, context=context, line=line)

        if binding and binding in self.bindings:
            self.bindings[binding].assumptions.append(assumption)
            self.bindings[binding].clarity_type = ClarityType.AMBIGUOUS
        else:
            self.global_assumptions.append(assumption)

        return assumption

    def clarify(self, name: str) -> bool:
        """
        Mark a binding as clarified (intent verified).

        Args:
            name: Variable name to clarify

        Returns:
            True if successfully clarified, False if not found
        """
        if name not in self.bindings:
            return False

        state = self.bindings[name]
        state.clarity_type = ClarityType.CLARIFIED
        state.verified_at = self.iteration
        self.clarification_history.append((name, self.iteration))
        return True

    def get_clarity(self, name: str) -> Optional[ClarityState]:
        """
        Get the clarity state of a binding.

        Args:
            name: Variable name

        Returns:
            ClarityState or None if not found
        """
        return self.bindings.get(name)

    def is_clarified(self, name: str) -> bool:
        """
        Check if a binding is clarified.

        Args:
            name: Variable name

        Returns:
            True if clarified, False otherwise
        """
        state = self.bindings.get(name)
        return state is not None and state.is_clear()

    def get_assumptions(self, name: Optional[str] = None) -> List[Assumption]:
        """
        Get assumptions for a binding or all global assumptions.

        Args:
            name: Variable name, or None for global assumptions

        Returns:
            List of assumptions
        """
        if name is None:
            return self.global_assumptions.copy()

        state = self.bindings.get(name)
        if state:
            return state.assumptions.copy()
        return []

    def get_unresolved_bindings(self) -> List[str]:
        """
        Get all bindings that are not yet clarified.

        Returns:
            List of binding names that need clarification
        """
        return [
            name
            for name, state in self.bindings.items()
            if not state.is_clear()
        ]

    def compute_clarity_score(self) -> float:
        """
        Compute overall clarity score (0.0 to 1.0).

        Similar to Framework Strength, measures the degree of
        semantic clarity in the current program state.

        Returns:
            Clarity score between 0.0 (fully ambiguous) and 1.0 (fully clarified)
        """
        if not self.bindings:
            return 1.0  # No bindings = trivially clear

        clarified = sum(1 for s in self.bindings.values() if s.is_clear())
        return clarified / len(self.bindings)

    def has_clarity(self, threshold: float = 0.95) -> bool:
        """
        Check if clarity score meets threshold.

        Args:
            threshold: Minimum clarity score (default: 0.95)

        Returns:
            True if clarity score >= threshold
        """
        return self.compute_clarity_score() >= threshold

    def advance_iteration(self) -> None:
        """Advance the iteration counter."""
        self.iteration += 1

    def reset(self) -> None:
        """Reset the tracker to initial state."""
        self.bindings.clear()
        self.global_assumptions.clear()
        self.clarification_history.clear()
        self.iteration = 0


class ClarityExplainer:
    """
    Provides human-readable explanations of clarity evaluations.

    Follows the agency-preserving principle: presents options rather
    than dictating corrections. Shows WHY clarity is insufficient
    without telling the programmer what they "should" do.

    Example output:
        `clarified` → FALSE
          └─ binding 'x' is TENTATIVE
          └─ hypothesis: "x represents user count"
          └─ possible interpretations:
             1. x as total users (all time)
             2. x as active users (current session)
             3. x as unique users (deduplicated)
          └─ which interpretation is intended?
    """

    def __init__(self, enabled: bool = False, use_color: bool = True):
        """
        Initialize the explainer.

        Args:
            enabled: Whether explain mode is active
            use_color: Whether to use ANSI color codes
        """
        self.enabled = enabled
        self.use_color = use_color and self._supports_color()

    def _supports_color(self) -> bool:
        """Check if the terminal supports color output."""
        import os

        if not hasattr(sys.stderr, "isatty") or not sys.stderr.isatty():
            return False
        if os.environ.get("NO_COLOR"):
            return False
        return True

    def _color(self, text: str, color: str) -> str:
        """Apply ANSI color to text if colors are enabled."""
        if not self.use_color:
            return text

        colors = {
            "green": "\033[32m",
            "red": "\033[31m",
            "yellow": "\033[33m",
            "cyan": "\033[36m",
            "magenta": "\033[35m",
            "bold": "\033[1m",
            "reset": "\033[0m",
        }

        return f"{colors.get(color, '')}{text}{colors['reset']}"

    def explain_clarified(
        self,
        result: bool,
        clarity_score: float,
        threshold: float,
        unresolved: List[str],
    ) -> None:
        """
        Explain the evaluation of the `clarified` predicate.

        Args:
            result: Whether the predicate evaluated to True
            clarity_score: The current clarity score
            threshold: The clarity threshold
            unresolved: List of unresolved binding names
        """
        if not self.enabled:
            return

        result_str = (
            self._color("TRUE", "green") if result else self._color("FALSE", "red")
        )

        print(f"`clarified` → {result_str}", file=sys.stderr)
        print(
            f"  └─ clarity_score = {clarity_score:.4f} (threshold: {threshold})",
            file=sys.stderr,
        )

        if not result and unresolved:
            print(f"  └─ unresolved bindings:", file=sys.stderr)
            for name in unresolved[:5]:  # Show first 5
                print(f"     • {self._color(name, 'yellow')}", file=sys.stderr)
            if len(unresolved) > 5:
                print(f"     ... and {len(unresolved) - 5} more", file=sys.stderr)

    def explain_ambiguous(
        self,
        result: bool,
        binding: str,
        state: Optional[ClarityState],
        interpretations: Optional[List[str]] = None,
    ) -> None:
        """
        Explain the evaluation of the `ambiguous` predicate.

        Presents possible interpretations without dictating which is "correct".

        Args:
            result: Whether the predicate evaluated to True
            binding: The binding being checked
            state: The clarity state of the binding
            interpretations: Possible interpretations (if known)
        """
        if not self.enabled:
            return

        result_str = (
            self._color("TRUE", "green") if result else self._color("FALSE", "red")
        )

        print(f"`ambiguous` → {result_str}", file=sys.stderr)
        print(f"  └─ binding: {self._color(binding, 'cyan')}", file=sys.stderr)

        if state:
            print(
                f"  └─ clarity_type: {state.clarity_type.value}",
                file=sys.stderr,
            )

            if state.assumptions:
                print(f"  └─ detected assumptions:", file=sys.stderr)
                for assumption in state.assumptions[:3]:
                    print(f"     • {assumption.name}: {assumption.context}", file=sys.stderr)

        if interpretations:
            print(f"  └─ possible interpretations:", file=sys.stderr)
            for i, interp in enumerate(interpretations, 1):
                print(f"     {i}. {interp}", file=sys.stderr)
            print(
                f"  └─ {self._color('which interpretation is intended?', 'yellow')}",
                file=sys.stderr,
            )

    def explain_assumed(
        self,
        result: bool,
        assumptions: List[Assumption],
    ) -> None:
        """
        Explain the evaluation of the `assumed` predicate.

        Shows what hidden variables have been detected.

        Args:
            result: Whether the predicate evaluated to True
            assumptions: List of detected assumptions
        """
        if not self.enabled:
            return

        result_str = (
            self._color("TRUE", "green") if result else self._color("FALSE", "red")
        )

        print(f"`assumed` → {result_str}", file=sys.stderr)
        print(f"  └─ assumption_count = {len(assumptions)}", file=sys.stderr)

        if assumptions:
            print(f"  └─ hidden variables detected:", file=sys.stderr)
            for assumption in assumptions[:5]:
                loc = f" (line {assumption.line})" if assumption.line else ""
                print(
                    f"     • {self._color(assumption.name, 'magenta')}: "
                    f"{assumption.context}{loc}",
                    file=sys.stderr,
                )
            if len(assumptions) > 5:
                print(f"     ... and {len(assumptions) - 5} more", file=sys.stderr)

    def explain_tentative(
        self,
        result: bool,
        binding: str,
        hypothesis: Optional[str],
    ) -> None:
        """
        Explain the evaluation of the `tentative` predicate.

        Args:
            result: Whether the predicate evaluated to True
            binding: The binding being checked
            hypothesis: The stated hypothesis
        """
        if not self.enabled:
            return

        result_str = (
            self._color("TRUE", "green") if result else self._color("FALSE", "red")
        )

        print(f"`tentative` → {result_str}", file=sys.stderr)
        print(f"  └─ binding: {self._color(binding, 'cyan')}", file=sys.stderr)

        if hypothesis:
            print(f"  └─ hypothesis: \"{hypothesis}\"", file=sys.stderr)
            print(
                f"  └─ {self._color('awaiting verification', 'yellow')}",
                file=sys.stderr,
            )


class AmbiguityResolver:
    """
    Provides agency-preserving ambiguity resolution.

    Instead of guessing what the programmer meant, presents options
    and returns control to them. This follows the principle:
    "True intellect is knowing you could be wrong—and refusing
    to act as if you aren't."

    Example:
        resolver = AmbiguityResolver()
        options = resolver.generate_options("x", context)
        # Returns options like:
        # [
        #     "x as numeric value (apply arithmetic)",
        #     "x as string identifier (apply concatenation)",
        #     "x as function reference (apply invocation)",
        # ]
    """

    def __init__(self):
        """Initialize the resolver."""
        self.type_interpretations = {
            "numeric": "apply arithmetic operations",
            "string": "apply string operations (concatenation, slicing)",
            "function": "invoke as function",
            "list": "apply sequence operations (indexing, iteration)",
            "boolean": "use in conditional logic",
        }

    def generate_options(
        self,
        name: str,
        possible_types: Optional[List[str]] = None,
        context: Optional[str] = None,
    ) -> List[str]:
        """
        Generate possible interpretations for an ambiguous binding.

        Args:
            name: Variable name
            possible_types: List of possible types
            context: Additional context

        Returns:
            List of interpretation strings
        """
        if possible_types is None:
            possible_types = list(self.type_interpretations.keys())

        options = []
        for ptype in possible_types:
            if ptype in self.type_interpretations:
                options.append(
                    f"{name} as {ptype} ({self.type_interpretations[ptype]})"
                )

        if not options:
            options.append(f"{name} with unspecified intent")

        return options

    def format_resolution_prompt(
        self,
        name: str,
        options: List[str],
    ) -> str:
        """
        Format an agency-preserving resolution prompt.

        Returns a message that presents options without dictating.

        Args:
            name: Variable name
            options: List of possible interpretations

        Returns:
            Formatted prompt string
        """
        lines = [
            f"Ambiguity detected for '{name}'.",
            "Possible interpretations:",
        ]

        for i, option in enumerate(options, 1):
            lines.append(f"  {i}. {option}")

        lines.append("")
        lines.append("Which interpretation is intended?")

        return "\n".join(lines)


def detect_assumptions(
    expression_type: str,
    context: Dict[str, Any],
) -> List[Assumption]:
    """
    Detect implicit assumptions in an expression.

    This is a heuristic-based detector that identifies common
    sources of hidden variables in code.

    Args:
        expression_type: Type of expression being analyzed
        context: Context dictionary with relevant information

    Returns:
        List of detected assumptions
    """
    assumptions = []

    # Type coercion assumptions
    if expression_type == "binary_op":
        left_type = context.get("left_type")
        right_type = context.get("right_type")
        if left_type != right_type:
            assumptions.append(
                Assumption(
                    name="type_compatibility",
                    source=f"{left_type} + {right_type}",
                    context=f"Assuming {left_type} and {right_type} can be combined",
                )
            )

    # Division by zero assumptions
    if expression_type == "division":
        if not context.get("divisor_checked"):
            assumptions.append(
                Assumption(
                    name="non_zero_divisor",
                    source="division operation",
                    context="Assuming divisor is not zero",
                )
            )

    # Index bounds assumptions
    if expression_type == "index":
        if not context.get("bounds_checked"):
            assumptions.append(
                Assumption(
                    name="valid_index",
                    source="index operation",
                    context="Assuming index is within bounds",
                )
            )

    # Null/undefined assumptions
    if expression_type == "member_access":
        if not context.get("null_checked"):
            assumptions.append(
                Assumption(
                    name="non_null",
                    source="member access",
                    context="Assuming object is not null",
                )
            )

    # Function purity assumptions
    if expression_type == "function_call":
        if context.get("has_side_effects") is None:
            assumptions.append(
                Assumption(
                    name="function_behavior",
                    source=context.get("function_name", "function"),
                    context="Side effects and return behavior unspecified",
                )
            )

    return assumptions
