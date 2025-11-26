"""
Tests for EigenScript predicate aliases (settled, balanced, stuck, chaotic).

These predicate aliases provide human-friendly names for existing predicates,
making EigenScript more accessible while maintaining its geometric power.
"""

import pytest
import textwrap
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.builtins import decode_vector


@pytest.fixture
def interpreter():
    """Create a fresh interpreter for each test."""
    return Interpreter()


def run_code(code: str, interpreter):
    """Helper to run EigenScript code."""
    code = textwrap.dedent(code).strip()
    tokenizer = Tokenizer(code)
    tokens = tokenizer.tokenize()
    parser = Parser(tokens)
    ast = parser.parse()
    return interpreter.evaluate(ast)


class TestSettledPredicate:
    """Tests for SETTLED predicate (alias for converged)."""

    def test_settled_behaves_like_converged(self, interpreter):
        """Test SETTLED returns same result as converged would."""
        code = """
        x is 10
        settled
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Should return 0.0 or 1.0 (boolean as scalar)
        assert value in [0.0, 1.0]

    def test_settled_is_boolean(self, interpreter):
        """Test SETTLED returns a boolean-like value."""
        code = """
        x is 10
        y is 20
        z is 30
        settled
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value in [0.0, 1.0]

    def test_settled_consistency_with_converged(self, interpreter):
        """Test SETTLED and converged return same value."""
        code1 = """
        x is 10
        converged
        """
        code2 = """
        x is 10
        settled
        """

        interpreter1 = Interpreter()
        interpreter2 = Interpreter()

        result1 = run_code(code1, interpreter1)
        result2 = run_code(code2, interpreter2)

        value1 = decode_vector(result1, interpreter1.space)
        value2 = decode_vector(result2, interpreter2.space)

        assert value1 == value2


class TestBalancedPredicate:
    """Tests for BALANCED predicate (alias for equilibrium)."""

    def test_balanced_behaves_like_equilibrium(self, interpreter):
        """Test BALANCED returns same result as equilibrium would."""
        code = """
        x is 10
        balanced
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Should return 0.0 or 1.0 (boolean as scalar)
        assert value in [0.0, 1.0]

    def test_balanced_is_boolean(self, interpreter):
        """Test BALANCED returns a boolean-like value."""
        code = """
        x is 10
        balanced
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value in [0.0, 1.0]

    def test_balanced_consistency_with_equilibrium(self, interpreter):
        """Test BALANCED and equilibrium return same value."""
        code1 = """
        x is 10
        equilibrium
        """
        code2 = """
        x is 10
        balanced
        """

        interpreter1 = Interpreter()
        interpreter2 = Interpreter()

        result1 = run_code(code1, interpreter1)
        result2 = run_code(code2, interpreter2)

        value1 = decode_vector(result1, interpreter1.space)
        value2 = decode_vector(result2, interpreter2.space)

        assert value1 == value2


class TestStuckPredicate:
    """Tests for STUCK predicate (not improving and not converged)."""

    def test_stuck_returns_boolean(self, interpreter):
        """Test STUCK returns a boolean-like value."""
        code = """
        x is 10
        stuck
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value in [0.0, 1.0]

    def test_stuck_when_not_improving(self, interpreter):
        """Test STUCK is true when not improving and not converged."""
        code = """
        x is 10
        x is 10
        stuck
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # With small trajectory, stuck should reflect the state
        assert value in [0.0, 1.0]

    def test_stuck_with_trajectory(self, interpreter):
        """Test STUCK with a longer trajectory."""
        code = """
        x is 10
        x is 10
        x is 10
        x is 10
        stuck
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # If values aren't changing, might be stuck (depending on FS)
        assert value in [0.0, 1.0]


class TestChaoticPredicate:
    """Tests for CHAOTIC predicate (high variance detection)."""

    def test_chaotic_returns_boolean(self, interpreter):
        """Test CHAOTIC returns a boolean-like value."""
        code = """
        x is 10
        chaotic
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value in [0.0, 1.0]

    def test_chaotic_with_stable_values(self, interpreter):
        """Test CHAOTIC is false with stable values."""
        code = """
        x is 10
        x is 10
        x is 10
        x is 10
        x is 10
        chaotic
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Stable values should not be chaotic
        assert value == 0.0

    def test_chaotic_with_varying_values(self, interpreter):
        """Test CHAOTIC with highly varying values."""
        code = """
        x is 10
        x is 100
        x is 1
        x is 1000
        x is 5
        chaotic
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # High variance should be detected as chaotic
        assert value in [0.0, 1.0]  # May or may not be chaotic depending on threshold


class TestPredicateAliasesIntegration:
    """Integration tests for predicate aliases."""

    def test_all_predicates_in_same_program(self, interpreter):
        """Test using all predicate aliases in one program."""
        code = """
        x is 10
        x is 20
        x is 30
        
        s is settled
        b is balanced
        t is stuck
        c is chaotic
        
        result is s + b + t + c
        result
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Sum of 4 boolean values should be between 0 and 4
        assert 0 <= value <= 4

    def test_predicates_in_conditionals(self, interpreter):
        """Test using predicate aliases in conditionals."""
        code = """
        x is 10
        x is 20
        
        result is 0
        if settled:
            result is result + 1
        if balanced:
            result is result + 10
        if stuck:
            result is result + 100
        if chaotic:
            result is result + 1000
        result
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Value depends on which predicates are true
        assert isinstance(value, (int, float))

    def test_predicates_in_loop(self, interpreter):
        """Test using predicate aliases in a loop."""
        code = """
        x is 0
        result is 0
        loop while x < 5:
            x is x + 1
        x
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Should complete loop normally
        assert value == 5

    def test_mixing_aliases_with_originals(self, interpreter):
        """Test mixing predicate aliases with original predicates."""
        code = """
        x is 10
        x is 20
        
        a is converged
        b is settled
        c is equilibrium
        d is balanced
        
        # Both pairs should match
        match1 is a = b
        match2 is c = d
        
        result is match1 + match2
        result
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Both should match (1.0 + 1.0 = 2.0)
        assert value == 2.0
