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
from typing import List, Dict, Optional, Tuple, Any
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
            verified_at=(
                self.iteration if clarity_type == ClarityType.CLARIFIED else None
            ),
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
        return [name for name, state in self.bindings.items() if not state.is_clear()]

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
                    print(
                        f"     • {assumption.name}: {assumption.context}",
                        file=sys.stderr,
                    )

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
            print(f'  └─ hypothesis: "{hypothesis}"', file=sys.stderr)
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


class ActiveListener:
    """
    Makes EigenScript an active listener that detects ambiguity and seeks clarification.

    The ActiveListener embodies the communication framework principle:
    "You treat inferred intent as a hypothesis, not a fact."

    Instead of silently proceeding on assumptions, the ActiveListener:
    1. Detects when multiple interpretations are possible
    2. Pauses execution to seek clarification
    3. Presents options without deciding for the speaker
    4. Records the clarified intent for future reference

    Example:
        listener = ActiveListener(interactive=True)

        # When division is attempted:
        # > Clarification needed for division operation:
        # >   The divisor 'x' could be zero.
        # >   1. Proceed (assuming x ≠ 0)
        # >   2. Add explicit check
        # >   3. Provide default value
        # > Which approach? _
    """

    def __init__(
        self,
        interactive: bool = False,
        strict: bool = False,
        use_color: bool = True,
    ):
        """
        Initialize the ActiveListener.

        Args:
            interactive: If True, prompt user for clarification
            strict: If True, refuse to proceed on any ambiguity
            use_color: Whether to use ANSI color codes
        """
        self.interactive = interactive
        self.strict = strict
        self.use_color = use_color and self._supports_color()
        self.clarification_log: List[Dict[str, Any]] = []
        self.pending_clarifications: List[Dict[str, Any]] = []

    def _supports_color(self) -> bool:
        """Check if the terminal supports color output."""
        import os

        if not hasattr(sys.stdout, "isatty") or not sys.stdout.isatty():
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
            "dim": "\033[2m",
            "reset": "\033[0m",
        }

        return f"{colors.get(color, '')}{text}{colors['reset']}"

    def detect_ambiguity(
        self,
        operation: str,
        context: Dict[str, Any],
    ) -> Optional[Dict[str, Any]]:
        """
        Detect if an operation has ambiguous intent.

        Args:
            operation: Type of operation (e.g., "division", "index", "coercion")
            context: Context about the operation

        Returns:
            Ambiguity info dict if ambiguous, None otherwise
        """
        ambiguity = None

        if operation == "division":
            divisor_name = context.get("divisor_name", "divisor")
            # Can't statically prove non-zero
            if not context.get("proven_non_zero"):
                ambiguity = {
                    "type": "division_safety",
                    "message": f"The divisor '{divisor_name}' might be zero.",
                    "options": [
                        ("proceed", f"Proceed (assuming {divisor_name} ≠ 0)"),
                        ("check", "Add explicit zero check"),
                        ("default", "Return default value if zero"),
                    ],
                    "context": context,
                }

        elif operation == "index":
            index_name = context.get("index_name", "index")
            list_name = context.get("list_name", "list")
            if not context.get("proven_in_bounds"):
                ambiguity = {
                    "type": "index_safety",
                    "message": f"The index '{index_name}' might be out of bounds for '{list_name}'.",
                    "options": [
                        ("proceed", "Proceed (assuming valid index)"),
                        ("check", "Add bounds check"),
                        ("clamp", "Clamp to valid range"),
                        ("wrap", "Wrap around (modulo length)"),
                    ],
                    "context": context,
                }

        elif operation == "coercion":
            from_type = context.get("from_type", "unknown")
            to_type = context.get("to_type", "unknown")
            ambiguity = {
                "type": "type_coercion",
                "message": f"Converting {from_type} to {to_type} - intent unclear.",
                "options": [
                    ("strict", f"Strict conversion (fail if not exactly {to_type})"),
                    ("lenient", "Lenient conversion (best effort)"),
                    ("explicit", "Require explicit conversion"),
                ],
                "context": context,
            }

        elif operation == "null_access":
            name = context.get("name", "value")
            ambiguity = {
                "type": "null_safety",
                "message": f"'{name}' might be null/undefined.",
                "options": [
                    ("proceed", f"Proceed (assuming {name} is defined)"),
                    ("check", "Add null check"),
                    ("default", "Use default value if null"),
                    ("optional", "Return null (optional chaining)"),
                ],
                "context": context,
            }

        elif operation == "intent":
            name = context.get("name", "value")
            possible_meanings = context.get("meanings", [])
            if possible_meanings:
                options = [(f"meaning_{i}", m) for i, m in enumerate(possible_meanings)]
                options.append(("other", "Something else (please specify)"))
                ambiguity = {
                    "type": "semantic_ambiguity",
                    "message": f"Multiple interpretations possible for '{name}'.",
                    "options": options,
                    "context": context,
                }

        return ambiguity

    def request_clarification(
        self,
        ambiguity: Dict[str, Any],
    ) -> str:
        """
        Request clarification from the user.

        In interactive mode, prompts and waits for input.
        In non-interactive mode, logs and returns default.

        Args:
            ambiguity: Ambiguity info dict from detect_ambiguity

        Returns:
            The chosen option key
        """
        message = ambiguity["message"]
        options = ambiguity["options"]

        if self.interactive:
            # Print the clarification request
            print(
                f"\n{self._color('⚡ Clarification needed:', 'yellow')}",
                file=sys.stderr,
            )
            print(f"   {message}", file=sys.stderr)
            print(file=sys.stderr)

            for i, (key, desc) in enumerate(options, 1):
                print(f"   {self._color(str(i), 'cyan')}. {desc}", file=sys.stderr)

            print(file=sys.stderr)

            # Get user input
            while True:
                try:
                    choice = input(
                        f"   {self._color('Which approach?', 'bold')} [1-{len(options)}]: "
                    )
                    choice_idx = int(choice) - 1
                    if 0 <= choice_idx < len(options):
                        chosen_key = options[choice_idx][0]
                        self._log_clarification(ambiguity, chosen_key)
                        return chosen_key
                    print(
                        f"   Please enter a number between 1 and {len(options)}",
                        file=sys.stderr,
                    )
                except ValueError:
                    print(
                        f"   Please enter a number between 1 and {len(options)}",
                        file=sys.stderr,
                    )
                except EOFError:
                    # Non-interactive fallback
                    return options[0][0]
        else:
            # Non-interactive: log and return first option (default)
            self.pending_clarifications.append(ambiguity)
            return options[0][0]

    def _log_clarification(
        self,
        ambiguity: Dict[str, Any],
        choice: str,
    ) -> None:
        """Log a clarification for future reference."""
        self.clarification_log.append(
            {
                "ambiguity_type": ambiguity["type"],
                "message": ambiguity["message"],
                "choice": choice,
                "context": ambiguity.get("context", {}),
            }
        )

    def get_pending_clarifications(self) -> List[Dict[str, Any]]:
        """Get list of pending clarifications that weren't resolved interactively."""
        return self.pending_clarifications.copy()

    def clear_pending(self) -> None:
        """Clear pending clarifications."""
        self.pending_clarifications.clear()


class DialogueManager:
    """
    Manages the dialogue between EigenScript and the user.

    Implements the "active speaker" pattern where EigenScript:
    1. Explains its reasoning when asked
    2. Presents options clearly
    3. Preserves user agency
    4. Never assumes understanding

    From the communication framework:
    "Control remains with the speaker - you do not decide intent for them."

    Example:
        dm = DialogueManager()

        # When explaining a decision:
        dm.explain_reasoning(
            decision="Using strict mode for parsing",
            because="The 'mode' binding was clarified as 'strict'",
            alternatives=["lenient", "auto-detect"]
        )
        # Output:
        # I'm using strict mode for parsing.
        # Reason: The 'mode' binding was clarified as 'strict'.
        # Alternatives considered: lenient, auto-detect
    """

    def __init__(self, use_color: bool = True, verbose: bool = False):
        """
        Initialize the DialogueManager.

        Args:
            use_color: Whether to use ANSI color codes
            verbose: Whether to provide detailed explanations
        """
        self.use_color = use_color and self._supports_color()
        self.verbose = verbose
        self.dialogue_history: List[Dict[str, Any]] = []

    def _supports_color(self) -> bool:
        """Check if the terminal supports color output."""
        import os

        if not hasattr(sys.stdout, "isatty") or not sys.stdout.isatty():
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
            "dim": "\033[2m",
            "reset": "\033[0m",
        }

        return f"{colors.get(color, '')}{text}{colors['reset']}"

    def ask_for_intent(
        self,
        what: str,
        options: List[Tuple[str, str]],
        context: Optional[str] = None,
    ) -> str:
        """
        Ask the user to clarify their intent.

        Agency-preserving: presents options without judgment.

        Args:
            what: What needs clarification
            options: List of (key, description) tuples
            context: Optional context explaining why clarification is needed

        Returns:
            The chosen option key
        """
        print(f"\n{self._color('?', 'cyan')} {what}", file=sys.stderr)

        if context:
            print(f"  {self._color('Context:', 'dim')} {context}", file=sys.stderr)

        print(file=sys.stderr)
        for i, (key, desc) in enumerate(options, 1):
            print(f"  {self._color(str(i), 'cyan')}. {desc}", file=sys.stderr)

        print(file=sys.stderr)

        while True:
            try:
                choice = input(
                    f"  {self._color('Your choice', 'bold')} [1-{len(options)}]: "
                )
                choice_idx = int(choice) - 1
                if 0 <= choice_idx < len(options):
                    chosen_key = options[choice_idx][0]
                    self._log_dialogue("intent_request", what, chosen_key)
                    return chosen_key
                print(
                    f"  Please enter a number between 1 and {len(options)}",
                    file=sys.stderr,
                )
            except ValueError:
                print(
                    f"  Please enter a number between 1 and {len(options)}",
                    file=sys.stderr,
                )
            except EOFError:
                return options[0][0]

    def explain_reasoning(
        self,
        decision: str,
        because: str,
        alternatives: Optional[List[str]] = None,
    ) -> None:
        """
        Explain the reasoning behind a decision.

        Makes the interpreter's "thinking" visible.

        Args:
            decision: What was decided
            because: Why it was decided
            alternatives: Other options that were considered
        """
        if not self.verbose:
            return

        print(f"\n{self._color('→', 'green')} {decision}", file=sys.stderr)
        print(f"  {self._color('Because:', 'dim')} {because}", file=sys.stderr)

        if alternatives:
            alts = ", ".join(alternatives)
            print(f"  {self._color('Alternatives:', 'dim')} {alts}", file=sys.stderr)

        self._log_dialogue("explanation", decision, because)

    def confirm_understanding(
        self,
        statement: str,
        understood_as: str,
    ) -> bool:
        """
        Confirm understanding of a statement.

        From the framework: "You test [inferred intent] by offering explicit options."

        Args:
            statement: The original statement
            understood_as: How it was interpreted

        Returns:
            True if understanding confirmed, False otherwise
        """
        print(
            f"\n{self._color('?', 'yellow')} Confirming understanding:", file=sys.stderr
        )
        print(f"  You said: {self._color(statement, 'cyan')}", file=sys.stderr)
        print(f"  I understood: {self._color(understood_as, 'green')}", file=sys.stderr)
        print(file=sys.stderr)

        try:
            response = (
                input(f"  {self._color('Is this correct?', 'bold')} [Y/n]: ")
                .strip()
                .lower()
            )
            confirmed = response in ("", "y", "yes")
            self._log_dialogue("confirmation", statement, confirmed)
            return confirmed
        except EOFError:
            return True

    def present_options(
        self,
        situation: str,
        options: List[Tuple[str, str, str]],  # (key, short_desc, long_desc)
    ) -> None:
        """
        Present options without asking for a choice (informational).

        Preserves agency by showing possibilities without forcing a decision.

        Args:
            situation: The current situation
            options: List of (key, short_desc, long_desc) tuples
        """
        print(f"\n{self._color('ℹ', 'cyan')} {situation}", file=sys.stderr)
        print(f"  Possible approaches:", file=sys.stderr)
        print(file=sys.stderr)

        for key, short_desc, long_desc in options:
            print(f"  • {self._color(short_desc, 'bold')}", file=sys.stderr)
            if self.verbose and long_desc:
                print(f"    {self._color(long_desc, 'dim')}", file=sys.stderr)

        self._log_dialogue("options_presented", situation, [o[0] for o in options])

    def acknowledge_clarification(
        self,
        what: str,
        clarified_as: str,
    ) -> None:
        """
        Acknowledge a clarification from the user.

        Shows the user their clarification was received.

        Args:
            what: What was clarified
            clarified_as: The clarified value/intent
        """
        print(
            f"{self._color('✓', 'green')} Understood: {what} → {self._color(clarified_as, 'cyan')}",
            file=sys.stderr,
        )
        self._log_dialogue("acknowledgment", what, clarified_as)

    def _log_dialogue(
        self,
        dialogue_type: str,
        subject: str,
        response: Any,
    ) -> None:
        """Log a dialogue exchange."""
        self.dialogue_history.append(
            {
                "type": dialogue_type,
                "subject": subject,
                "response": response,
            }
        )

    def get_dialogue_history(self) -> List[Dict[str, Any]]:
        """Get the full dialogue history."""
        return self.dialogue_history.copy()


class InteractiveClarifier:
    """
    Combines ActiveListener and DialogueManager for interactive clarification.

    This is the main interface for making EigenScript an active participant
    in the communication process.

    Example:
        clarifier = InteractiveClarifier(interactive=True)

        # During execution, when ambiguity is detected:
        result = clarifier.clarify_binding(
            name="mode",
            value="strict",
            possible_meanings=[
                "Strict type checking",
                "Strict parsing rules",
                "Strict security settings",
            ]
        )
        # Prompts user and returns clarified meaning
    """

    def __init__(
        self,
        interactive: bool = False,
        verbose: bool = False,
        use_color: bool = True,
    ):
        """
        Initialize the InteractiveClarifier.

        Args:
            interactive: If True, prompt user for clarification
            verbose: If True, explain reasoning
            use_color: Whether to use ANSI color codes
        """
        self.interactive = interactive
        self.listener = ActiveListener(interactive=interactive, use_color=use_color)
        self.dialogue = DialogueManager(use_color=use_color, verbose=verbose)

    def clarify_binding(
        self,
        name: str,
        value: Any,
        possible_meanings: Optional[List[str]] = None,
    ) -> Dict[str, Any]:
        """
        Clarify the meaning/intent of a binding.

        Args:
            name: Binding name
            value: Current value
            possible_meanings: List of possible interpretations

        Returns:
            Dict with clarified meaning and confidence
        """
        if not possible_meanings:
            # No ambiguity if no alternatives
            return {"meaning": str(value), "confidence": 1.0, "clarified": True}

        if self.interactive:
            options = [(f"m{i}", m) for i, m in enumerate(possible_meanings)]
            options.append(("other", "None of these / something else"))

            chosen = self.dialogue.ask_for_intent(
                what=f"What does '{name}' = {value} mean?",
                options=options,
                context="Multiple interpretations are possible",
            )

            if chosen == "other":
                # Ask for custom meaning
                try:
                    custom = input("  Please specify: ")
                    self.dialogue.acknowledge_clarification(name, custom)
                    return {"meaning": custom, "confidence": 1.0, "clarified": True}
                except EOFError:
                    return {
                        "meaning": str(value),
                        "confidence": 0.5,
                        "clarified": False,
                    }

            idx = int(chosen[1:])
            meaning = possible_meanings[idx]
            self.dialogue.acknowledge_clarification(name, meaning)
            return {"meaning": meaning, "confidence": 1.0, "clarified": True}

        else:
            # Non-interactive: return first meaning with low confidence
            return {
                "meaning": possible_meanings[0] if possible_meanings else str(value),
                "confidence": 0.5,
                "clarified": False,
                "pending_options": possible_meanings,
            }

    def clarify_operation(
        self,
        operation: str,
        context: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        Clarify how to handle an operation with potential issues.

        Args:
            operation: Operation type (division, index, etc.)
            context: Context about the operation

        Returns:
            Dict with handling strategy
        """
        ambiguity = self.listener.detect_ambiguity(operation, context)

        if not ambiguity:
            return {"strategy": "proceed", "clarified": True}

        choice = self.listener.request_clarification(ambiguity)

        if self.interactive:
            self.dialogue.acknowledge_clarification(
                ambiguity["type"],
                dict(ambiguity["options"]).get(choice, choice),
            )

        return {
            "strategy": choice,
            "clarified": self.interactive,
            "ambiguity_type": ambiguity["type"],
        }

    def should_pause(self, clarity_score: float, threshold: float = 0.95) -> bool:
        """
        Determine if execution should pause for clarification.

        Args:
            clarity_score: Current clarity score
            threshold: Minimum acceptable clarity

        Returns:
            True if should pause, False otherwise
        """
        if not self.interactive:
            return False

        return clarity_score < threshold

    def summarize_pending(self) -> str:
        """
        Summarize pending clarifications.

        Returns:
            Human-readable summary of what needs clarification
        """
        pending = self.listener.get_pending_clarifications()
        if not pending:
            return "No pending clarifications."

        lines = [f"Pending clarifications ({len(pending)}):"]
        for p in pending:
            lines.append(f"  • {p['message']}")

        return "\n".join(lines)
