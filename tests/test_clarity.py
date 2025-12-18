"""
Tests for EigenScript Communication Clarity Framework.

The Clarity Framework implements hypothesis-driven communication semantics where:
- Clarity is required before execution (not optional)
- Hidden variables are made explicit
- Intent is treated as falsifiable hypothesis
- Agency remains with the speaker (programmer)

Key Principles:
    1. Questions and statements both assign objectives
    2. Implication is not universal (hidden variables cause failure)
    3. Clarification is hypothesis testing
    4. Withhold inference intentionally
    5. Control remains with the speaker
    6. Speakers discover their own intent
"""

import pytest
import textwrap
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.builtins import decode_vector
from eigenscript.runtime.clarity import (
    ClarityType,
    ClarityState,
    ClarityTracker,
    ClarityExplainer,
    Assumption,
    detect_assumptions,
    ActiveListener,
    DialogueManager,
    InteractiveClarifier,
)


@pytest.fixture
def interpreter():
    """Create a fresh interpreter for each test."""
    return Interpreter()


@pytest.fixture
def clarity_tracker():
    """Create a fresh clarity tracker for each test."""
    return ClarityTracker()


def run_code(code: str, interpreter):
    """Helper to run EigenScript code."""
    code = textwrap.dedent(code).strip()
    tokenizer = Tokenizer(code)
    tokens = tokenizer.tokenize()
    parser = Parser(tokens)
    ast = parser.parse()
    return interpreter.evaluate(ast)


class TestClarityTracker:
    """Tests for the ClarityTracker class."""

    def test_initial_state(self, clarity_tracker):
        """Test tracker starts with no bindings."""
        assert len(clarity_tracker.bindings) == 0
        assert clarity_tracker.compute_clarity_score() == 1.0  # No bindings = trivially clear

    def test_register_clarified_binding(self, clarity_tracker):
        """Test registering a clarified binding."""
        state = clarity_tracker.register_binding("x", tentative=False)
        assert state.clarity_type == ClarityType.CLARIFIED
        assert clarity_tracker.is_clarified("x")
        assert clarity_tracker.compute_clarity_score() == 1.0

    def test_register_tentative_binding(self, clarity_tracker):
        """Test registering a tentative (hypothesis) binding."""
        state = clarity_tracker.register_binding(
            "x", tentative=True, hypothesis="x is a counter"
        )
        assert state.clarity_type == ClarityType.TENTATIVE
        assert not clarity_tracker.is_clarified("x")
        assert state.hypothesis == "x is a counter"
        assert clarity_tracker.compute_clarity_score() == 0.0

    def test_clarify_tentative_binding(self, clarity_tracker):
        """Test clarifying a tentative binding."""
        clarity_tracker.register_binding("x", tentative=True)
        assert not clarity_tracker.is_clarified("x")

        success = clarity_tracker.clarify("x")
        assert success
        assert clarity_tracker.is_clarified("x")
        assert clarity_tracker.compute_clarity_score() == 1.0

    def test_clarify_nonexistent_binding(self, clarity_tracker):
        """Test clarifying a binding that doesn't exist."""
        success = clarity_tracker.clarify("nonexistent")
        assert not success

    def test_multiple_bindings_clarity_score(self, clarity_tracker):
        """Test clarity score with multiple bindings."""
        clarity_tracker.register_binding("a", tentative=False)
        clarity_tracker.register_binding("b", tentative=True)
        clarity_tracker.register_binding("c", tentative=False)

        # 2 out of 3 clarified = 0.666...
        score = clarity_tracker.compute_clarity_score()
        assert abs(score - 2 / 3) < 0.01

    def test_get_unresolved_bindings(self, clarity_tracker):
        """Test getting list of unresolved bindings."""
        clarity_tracker.register_binding("a", tentative=False)
        clarity_tracker.register_binding("b", tentative=True)
        clarity_tracker.register_binding("c", tentative=True)

        unresolved = clarity_tracker.get_unresolved_bindings()
        assert "b" in unresolved
        assert "c" in unresolved
        assert "a" not in unresolved

    def test_register_assumption(self, clarity_tracker):
        """Test registering an assumption (hidden variable)."""
        clarity_tracker.register_binding("x")
        assumption = clarity_tracker.register_assumption(
            name="non_zero",
            source="division operation",
            context="Assuming divisor is not zero",
            binding="x",
        )

        assert assumption.name == "non_zero"
        assert len(clarity_tracker.get_assumptions("x")) == 1
        state = clarity_tracker.get_clarity("x")
        assert state.clarity_type == ClarityType.AMBIGUOUS

    def test_global_assumptions(self, clarity_tracker):
        """Test global assumptions not tied to a binding."""
        assumption = clarity_tracker.register_assumption(
            name="environment",
            source="runtime",
            context="Assuming production environment",
        )

        global_assumptions = clarity_tracker.get_assumptions()
        assert len(global_assumptions) == 1
        assert global_assumptions[0].name == "environment"


class TestClarityPredicates:
    """Tests for clarity predicates in the interpreter."""

    def test_clarified_predicate_all_clear(self, interpreter):
        """Test CLARIFIED returns 1.0 when all bindings are clarified."""
        code = """
        x is 10
        y is 20
        clarified
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1.0

    def test_clarified_predicate_with_tentative(self, interpreter):
        """Test CLARIFIED returns 0.0 when tentative bindings exist."""
        code = """
        x is 10
        y might is 20
        clarified
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 0.0

    def test_clarified_after_clarify(self, interpreter):
        """Test CLARIFIED returns 1.0 after clarifying tentative binding."""
        code = """
        x might is 10
        clarify of x
        clarified
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1.0

    def test_ambiguous_predicate_with_tentative(self, interpreter):
        """Test AMBIGUOUS returns 1.0 when tentative bindings exist."""
        code = """
        x might is 10
        ambiguous
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1.0

    def test_ambiguous_predicate_all_clear(self, interpreter):
        """Test AMBIGUOUS returns 0.0 when all bindings are clarified."""
        code = """
        x is 10
        ambiguous
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 0.0

    def test_explicit_predicate(self, interpreter):
        """Test EXPLICIT predicate (opposite of ambiguous)."""
        code = """
        x is 10
        y is 20
        explicit
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1.0

    def test_clarity_score_numeric(self, interpreter):
        """Test CLARITY returns numeric score."""
        code = """
        x is 10
        y might is 20
        z is 30
        clarity
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # 2 out of 3 clarified = 0.666...
        assert abs(value - 2 / 3) < 0.01

    def test_cs_alias_for_clarity(self, interpreter):
        """Test CS is alias for CLARITY."""
        code1 = """
        x is 10
        clarity
        """
        code2 = """
        x is 10
        cs
        """
        interpreter1 = Interpreter()
        interpreter2 = Interpreter()

        result1 = run_code(code1, interpreter1)
        result2 = run_code(code2, interpreter2)

        value1 = decode_vector(result1, interpreter1.space)
        value2 = decode_vector(result2, interpreter2.space)
        assert value1 == value2


class TestTentativeAssignment:
    """Tests for MIGHT IS (tentative assignment) syntax."""

    def test_tentative_assignment_creates_binding(self, interpreter):
        """Test MIGHT IS creates a binding with the value."""
        code = """
        x might is 42
        x
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 42

    def test_tentative_assignment_marks_as_tentative(self, interpreter):
        """Test MIGHT IS marks binding as tentative."""
        code = """
        x might is 42
        clarified
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 0.0  # Not clarified because x is tentative

    def test_clarify_tentative_assignment(self, interpreter):
        """Test clarifying a tentative assignment."""
        code = """
        x might is 42
        clarify of x
        clarified
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1.0  # Now clarified

    def test_multiple_tentative_assignments(self, interpreter):
        """Test multiple tentative assignments."""
        code = """
        a might is 1
        b might is 2
        c is 3
        clarity
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # 1 out of 3 clarified = 0.333...
        assert abs(value - 1 / 3) < 0.01


class TestClarifyOperator:
    """Tests for CLARIFY OF operator."""

    def test_clarify_returns_success(self, interpreter):
        """Test CLARIFY OF returns 1.0 on success."""
        code = """
        x might is 10
        clarify of x
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1.0

    def test_clarify_nonexistent_returns_failure(self, interpreter):
        """Test CLARIFY OF returns 0.0 for nonexistent binding."""
        code = """
        clarify of nonexistent
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 0.0

    def test_clarify_already_clarified(self, interpreter):
        """Test CLARIFY OF on already clarified binding."""
        code = """
        x is 10
        clarify of x
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Should still succeed (idempotent)
        assert value == 1.0


class TestAssumesInterrogative:
    """Tests for ASSUMES interrogative."""

    def test_assumes_empty_for_clarified(self, interpreter):
        """Test ASSUMES returns empty string for clarified binding."""
        code = """
        x is 10
        assumes is x
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == ""

    def test_assumes_on_tentative(self, interpreter):
        """Test ASSUMES on a tentative binding (no explicit assumptions)."""
        code = """
        x might is 10
        assumes is x
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Tentative but no explicit assumptions registered
        assert value == ""


class TestClarityInConditionals:
    """Tests for using clarity predicates in conditionals."""

    def test_if_clarified(self, interpreter):
        """Test using CLARIFIED in a conditional."""
        code = """
        x is 10
        result is 0
        if clarified:
            result is 1
        result
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1

    def test_if_not_clarified(self, interpreter):
        """Test using NOT CLARIFIED in a conditional."""
        code = """
        x might is 10
        result is 0
        if not clarified:
            result is 1
        result
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1

    def test_clarify_before_critical_operation(self, interpreter):
        """Test pattern: clarify before critical operation."""
        code = """
        config might is "strict"
        result is 0

        if not clarified:
            clarify of config

        if clarified:
            result is 1
        result
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1


class TestClarityInLoops:
    """Tests for using clarity predicates in loops."""

    def test_loop_while_not_clarified(self, interpreter):
        """Test looping until all bindings are clarified."""
        code = """
        a might is 1
        b might is 2

        clarify of a
        clarify of b

        clarified
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1.0

    def test_clarity_changes_during_loop(self, interpreter):
        """Test clarity score changes as bindings are clarified."""
        code = """
        a might is 1
        b might is 2
        c is 3

        before is clarity
        clarify of a
        after is clarity

        after > before
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1.0  # clarity increased


class TestClarityIntegration:
    """Integration tests combining clarity with other features."""

    def test_clarity_with_framework_strength(self, interpreter):
        """Test using both clarity and framework strength."""
        code = """
        x is 1
        x is 2
        x is 3
        x is 4
        x is 5

        cs_value is cs
        fs_value is fs

        cs_value + fs_value
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Both should be between 0 and 1, so sum between 0 and 2
        assert 0 <= value <= 2

    def test_clarity_with_interrogatives(self, interpreter):
        """Test using clarity with other interrogatives."""
        code = """
        x is 10
        value is what is x
        quality is how is x
        clarity_score is cs

        value
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 10

    def test_mixed_clarity_and_convergence(self, interpreter):
        """Test combining clarity predicates with convergence predicates."""
        code = """
        x is 10

        clarity_ok is clarified
        conv_check is converged

        clarity_ok + conv_check
        """
        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Sum of two booleans (0 or 1 each)
        assert 0 <= value <= 2


class TestClarityExplainer:
    """Tests for the ClarityExplainer class."""

    def test_explainer_disabled_by_default(self):
        """Test explainer is disabled by default."""
        explainer = ClarityExplainer(enabled=False)
        # Should not raise or print anything
        explainer.explain_clarified(
            result=True,
            clarity_score=1.0,
            threshold=0.95,
            unresolved=[],
        )

    def test_explainer_enabled(self, capsys):
        """Test explainer outputs when enabled."""
        explainer = ClarityExplainer(enabled=True, use_color=False)
        explainer.explain_clarified(
            result=False,
            clarity_score=0.5,
            threshold=0.95,
            unresolved=["x", "y"],
        )

        captured = capsys.readouterr()
        assert "clarified" in captured.err.lower()
        assert "0.5" in captured.err


class TestAssumptionDetection:
    """Tests for automatic assumption detection."""

    def test_detect_type_compatibility_assumption(self):
        """Test detecting type compatibility assumption."""
        assumptions = detect_assumptions(
            "binary_op",
            {"left_type": "number", "right_type": "string"},
        )
        assert len(assumptions) == 1
        assert assumptions[0].name == "type_compatibility"

    def test_detect_division_by_zero_assumption(self):
        """Test detecting division by zero assumption."""
        assumptions = detect_assumptions(
            "division",
            {"divisor_checked": False},
        )
        assert len(assumptions) == 1
        assert assumptions[0].name == "non_zero_divisor"

    def test_detect_index_bounds_assumption(self):
        """Test detecting index bounds assumption."""
        assumptions = detect_assumptions(
            "index",
            {"bounds_checked": False},
        )
        assert len(assumptions) == 1
        assert assumptions[0].name == "valid_index"

    def test_no_assumption_when_checked(self):
        """Test no assumption when precondition is checked."""
        assumptions = detect_assumptions(
            "division",
            {"divisor_checked": True},
        )
        assert len(assumptions) == 0


class TestClarityState:
    """Tests for the ClarityState dataclass."""

    def test_default_state_is_ambiguous(self):
        """Test default state is ambiguous."""
        state = ClarityState()
        assert state.clarity_type == ClarityType.AMBIGUOUS
        assert state.is_ambiguous()
        assert not state.is_clear()

    def test_clarified_state(self):
        """Test clarified state."""
        state = ClarityState(clarity_type=ClarityType.CLARIFIED)
        assert state.is_clear()
        assert not state.is_ambiguous()
        assert not state.is_tentative()

    def test_tentative_state(self):
        """Test tentative state."""
        state = ClarityState(clarity_type=ClarityType.TENTATIVE)
        assert state.is_tentative()
        assert not state.is_clear()

    def test_state_with_assumptions(self):
        """Test state with assumptions."""
        assumption = Assumption(
            name="test",
            source="test_source",
            context="test context",
        )
        state = ClarityState(assumptions=[assumption])
        assert state.has_assumptions()


class TestActiveListener:
    """Tests for the ActiveListener class."""

    def test_active_listener_creation(self):
        """Test creating an ActiveListener."""
        listener = ActiveListener(interactive=False)
        assert not listener.interactive
        assert len(listener.clarification_log) == 0
        assert len(listener.pending_clarifications) == 0

    def test_detect_division_ambiguity(self):
        """Test detecting division by zero ambiguity."""
        listener = ActiveListener(interactive=False)
        ambiguity = listener.detect_ambiguity(
            "division",
            {"divisor": 0, "divisor_name": "x", "proven_non_zero": False},
        )
        assert ambiguity is not None
        assert ambiguity["type"] == "division_safety"
        assert "x" in ambiguity["message"]

    def test_detect_index_ambiguity(self):
        """Test detecting index bounds ambiguity."""
        listener = ActiveListener(interactive=False)
        ambiguity = listener.detect_ambiguity(
            "index",
            {
                "index": 10,
                "index_name": "i",
                "list_name": "items",
                "proven_in_bounds": False,
            },
        )
        assert ambiguity is not None
        assert ambiguity["type"] == "index_safety"
        assert "i" in ambiguity["message"]
        assert "items" in ambiguity["message"]

    def test_detect_coercion_ambiguity(self):
        """Test detecting type coercion ambiguity."""
        listener = ActiveListener(interactive=False)
        ambiguity = listener.detect_ambiguity(
            "coercion",
            {"from_type": "string", "to_type": "number"},
        )
        assert ambiguity is not None
        assert ambiguity["type"] == "type_coercion"

    def test_detect_null_access_ambiguity(self):
        """Test detecting null access ambiguity."""
        listener = ActiveListener(interactive=False)
        ambiguity = listener.detect_ambiguity(
            "null_access",
            {"name": "user"},
        )
        assert ambiguity is not None
        assert ambiguity["type"] == "null_safety"

    def test_detect_intent_ambiguity(self):
        """Test detecting semantic ambiguity."""
        listener = ActiveListener(interactive=False)
        ambiguity = listener.detect_ambiguity(
            "intent",
            {
                "name": "mode",
                "meanings": ["strict parsing", "strict security", "strict types"],
            },
        )
        assert ambiguity is not None
        assert ambiguity["type"] == "semantic_ambiguity"

    def test_no_ambiguity_when_proven(self):
        """Test no ambiguity detected when precondition is proven."""
        listener = ActiveListener(interactive=False)
        ambiguity = listener.detect_ambiguity(
            "division",
            {"divisor": 5, "divisor_name": "x", "proven_non_zero": True},
        )
        assert ambiguity is None

    def test_non_interactive_returns_default(self):
        """Test non-interactive mode returns first option."""
        listener = ActiveListener(interactive=False)
        ambiguity = listener.detect_ambiguity(
            "division",
            {"divisor": 0, "divisor_name": "x", "proven_non_zero": False},
        )
        choice = listener.request_clarification(ambiguity)
        # In non-interactive mode, should return first option
        assert choice == "proceed"

    def test_pending_clarifications(self):
        """Test pending clarifications are recorded."""
        listener = ActiveListener(interactive=False)
        ambiguity = listener.detect_ambiguity(
            "division",
            {"divisor": 0, "divisor_name": "x", "proven_non_zero": False},
        )
        listener.request_clarification(ambiguity)
        pending = listener.get_pending_clarifications()
        assert len(pending) == 1


class TestDialogueManager:
    """Tests for the DialogueManager class."""

    def test_dialogue_manager_creation(self):
        """Test creating a DialogueManager."""
        dm = DialogueManager(use_color=False, verbose=False)
        assert not dm.verbose
        assert len(dm.dialogue_history) == 0

    def test_dialogue_history_logging(self):
        """Test dialogue history is logged."""
        dm = DialogueManager(use_color=False, verbose=True)
        dm.explain_reasoning(
            decision="Using strict mode",
            because="User specified strict",
            alternatives=["lenient", "auto"],
        )
        history = dm.get_dialogue_history()
        assert len(history) == 1
        assert history[0]["type"] == "explanation"

    def test_verbose_mode_outputs(self, capsys):
        """Test verbose mode produces output."""
        dm = DialogueManager(use_color=False, verbose=True)
        dm.explain_reasoning(
            decision="Testing output",
            because="This is a test",
        )
        captured = capsys.readouterr()
        assert "Testing output" in captured.err
        assert "This is a test" in captured.err

    def test_non_verbose_no_output(self, capsys):
        """Test non-verbose mode produces no output for explanations."""
        dm = DialogueManager(use_color=False, verbose=False)
        dm.explain_reasoning(
            decision="Testing output",
            because="This is a test",
        )
        captured = capsys.readouterr()
        assert "Testing output" not in captured.err


class TestInteractiveClarifier:
    """Tests for the InteractiveClarifier class."""

    def test_interactive_clarifier_creation(self):
        """Test creating an InteractiveClarifier."""
        clarifier = InteractiveClarifier(interactive=False, verbose=False)
        assert not clarifier.interactive
        assert clarifier.listener is not None
        assert clarifier.dialogue is not None

    def test_clarify_binding_no_options(self):
        """Test clarifying binding with no ambiguity."""
        clarifier = InteractiveClarifier(interactive=False)
        result = clarifier.clarify_binding(
            name="x",
            value=10,
            possible_meanings=None,
        )
        assert result["clarified"] is True
        assert result["confidence"] == 1.0

    def test_clarify_binding_with_options_non_interactive(self):
        """Test clarifying binding with options in non-interactive mode."""
        clarifier = InteractiveClarifier(interactive=False)
        result = clarifier.clarify_binding(
            name="mode",
            value="strict",
            possible_meanings=["strict types", "strict parsing", "strict security"],
        )
        # Non-interactive: returns first option with low confidence
        assert result["clarified"] is False
        assert result["confidence"] == 0.5
        assert "pending_options" in result

    def test_clarify_operation_no_ambiguity(self):
        """Test clarifying operation with no ambiguity."""
        clarifier = InteractiveClarifier(interactive=False)
        result = clarifier.clarify_operation(
            "unknown_operation",
            {},
        )
        assert result["strategy"] == "proceed"
        assert result["clarified"] is True

    def test_clarify_operation_with_ambiguity(self):
        """Test clarifying operation with ambiguity."""
        clarifier = InteractiveClarifier(interactive=False)
        result = clarifier.clarify_operation(
            "division",
            {"divisor": 0, "divisor_name": "x", "proven_non_zero": False},
        )
        assert result["strategy"] == "proceed"  # Default in non-interactive
        assert result["clarified"] is False
        assert result["ambiguity_type"] == "division_safety"

    def test_should_pause_non_interactive(self):
        """Test should_pause returns False in non-interactive mode."""
        clarifier = InteractiveClarifier(interactive=False)
        assert not clarifier.should_pause(0.5)

    def test_summarize_pending_empty(self):
        """Test summarizing when no pending clarifications."""
        clarifier = InteractiveClarifier(interactive=False)
        summary = clarifier.summarize_pending()
        assert "No pending" in summary

    def test_summarize_pending_with_items(self):
        """Test summarizing pending clarifications."""
        clarifier = InteractiveClarifier(interactive=False)
        # Generate some pending clarifications
        clarifier.clarify_operation(
            "division",
            {"divisor": 0, "divisor_name": "x", "proven_non_zero": False},
        )
        summary = clarifier.summarize_pending()
        assert "Pending" in summary
        assert "1" in summary


class TestInterpreterActiveListening:
    """Tests for interpreter with active listening mode."""

    def test_interpreter_with_active_listening(self):
        """Test creating interpreter with active listening enabled."""
        interp = Interpreter(active_listening=True)
        assert interp.active_listening is True
        assert interp.active_listener is not None
        assert interp.interactive_clarifier is not None

    def test_interpreter_without_active_listening(self):
        """Test interpreter without active listening."""
        interp = Interpreter(active_listening=False)
        assert interp.active_listening is False
        assert interp.active_listener is None

    def test_interpreter_with_interactive_mode(self):
        """Test creating interpreter with interactive mode."""
        interp = Interpreter(interactive_mode=True)
        assert interp.interactive_mode is True
        assert interp.interactive_clarifier is not None

    def test_division_with_active_listening_non_zero(self):
        """Test division with active listening when divisor is non-zero."""
        interp = Interpreter(active_listening=True)
        code = """
        x is 10
        y is 2
        x / y
        """
        result = run_code(code, interp)
        value = decode_vector(result, interp.space)
        assert value == 5.0  # Normal division works

    def test_format_agency_error_undefined(self):
        """Test agency-preserving error format for undefined variable."""
        interp = Interpreter(active_listening=True)
        msg = interp._format_agency_error(
            "undefined_variable",
            {"name": "foo", "suggestions": ["food", "foot"]},
        )
        assert "foo" in msg
        assert "Possible intentions" in msg
        assert "food" in msg

    def test_format_agency_error_type_mismatch(self):
        """Test agency-preserving error format for type mismatch."""
        interp = Interpreter(active_listening=True)
        msg = interp._format_agency_error(
            "type_mismatch",
            {"expected": "number", "got": "string", "operation": "addition"},
        )
        assert "Type question" in msg
        assert "number" in msg
        assert "string" in msg

    def test_format_agency_error_function_not_found(self):
        """Test agency-preserving error format for function not found."""
        interp = Interpreter(active_listening=True)
        msg = interp._format_agency_error(
            "function_not_found",
            {"name": "calculate"},
        )
        assert "calculate" in msg
        assert "Possible intentions" in msg


class TestClarityWithActiveListening:
    """Tests combining clarity framework with active listening."""

    def test_clarify_with_active_listening(self):
        """Test clarify of works with active listening."""
        interp = Interpreter(active_listening=True)
        code = """
        x might is 10
        clarify of x
        clarified
        """
        result = run_code(code, interp)
        value = decode_vector(result, interp.space)
        assert value == 1.0

    def test_ambiguous_with_active_listening(self):
        """Test ambiguous predicate with active listening."""
        interp = Interpreter(active_listening=True)
        code = """
        x might is 10
        ambiguous
        """
        result = run_code(code, interp)
        value = decode_vector(result, interp.space)
        assert value == 1.0

    def test_clarity_score_with_active_listening(self):
        """Test clarity score with active listening."""
        interp = Interpreter(active_listening=True)
        code = """
        x is 10
        y might is 20
        clarity
        """
        result = run_code(code, interp)
        value = decode_vector(result, interp.space)
        assert value == 0.5  # 1 out of 2 clarified
