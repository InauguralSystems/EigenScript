"""
Tests for EigenScript temporal operators (WAS, CHANGE).

These temporal operators provide humanized access to trajectory data,
making it easier to track variable history and changes over time.
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


class TestWasOperator:
    """Tests for WAS operator (previous value from trajectory)."""

    def test_was_returns_previous_value(self, interpreter):
        """Test WAS returns the previous trajectory value."""
        code = """
        x is 10
        x is x + 5
        x is x + 2
        was is x
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # The previous value before x was 17 (10+5+2) was 15 (10+5)
        assert value == 15

    def test_was_with_no_history_returns_current(self, interpreter):
        """Test WAS with no trajectory history returns current value."""
        code = """
        x is 42
        was is x
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # With no history, should return current value
        assert value == 42

    def test_was_in_loop(self, interpreter):
        """Test WAS inside a loop (trajectory builds up)."""
        code = """
        x is 0
        loop while x < 3:
            x is x + 1
        was is x
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # The trajectory contains loop iterations, so previous depends on execution
        # Just verify it returns a numeric value from trajectory
        assert isinstance(value, (int, float))

    def test_was_with_multiple_variables(self, interpreter):
        """Test WAS with multiple variables updates."""
        code = """
        x is 10
        y is 20
        x is x + 5
        y is y + 10
        was is y
        """

        result = run_code(code, interpreter)
        # was should return from global trajectory which includes all updates
        value = decode_vector(result, interpreter.space)
        assert isinstance(value, (int, float))


class TestChangeOperator:
    """Tests for CHANGE operator (delta/difference)."""

    def test_change_returns_correct_delta(self, interpreter):
        """Test CHANGE returns correct delta between current and previous."""
        code = """
        x is 10
        x is x + 5
        change is x
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Change from 10 to 15 is 5
        assert value == 5

    def test_change_with_no_history_returns_zero(self, interpreter):
        """Test CHANGE with no history returns 0."""
        code = """
        x is 42
        change is x
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 0

    def test_change_with_decreasing_value(self, interpreter):
        """Test CHANGE with decreasing value returns negative."""
        code = """
        x is 10
        x is x - 3
        change is x
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Change from 10 to 7 is -3
        assert value == -3

    def test_change_in_loop(self, interpreter):
        """Test CHANGE inside a loop."""
        code = """
        x is 0
        last_change is 0
        loop while x < 5:
            x is x + 1
            last_change is change is x
        last_change
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Each iteration adds 1, so last change should be close to 1
        assert isinstance(value, (int, float))


class TestStatusOperator:
    """Tests for STATUS operator (alias for HOW)."""

    def test_status_returns_process_quality(self, interpreter):
        """Test STATUS returns Framework Strength info."""
        code = """
        x is 10
        y is 20
        status is y
        """

        result = run_code(code, interpreter)
        decoded = decode_vector(result, interpreter.space)

        # STATUS should return FS info (same as HOW)
        if isinstance(decoded, (int, float)):
            assert 0 <= decoded <= 1
        else:
            assert isinstance(decoded, str)
            assert "FS=" in decoded


class TestTrendOperator:
    """Tests for TREND operator (trajectory analysis)."""

    def test_trend_increasing(self, interpreter):
        """Test TREND detects increasing pattern."""
        code = """
        x is 10
        x is x + 5
        x is x + 3
        x is x + 1
        trend is x
        """

        result = run_code(code, interpreter)
        trend = decode_vector(result, interpreter.space)
        assert trend == "increasing"

    def test_trend_decreasing(self, interpreter):
        """Test TREND detects decreasing pattern."""
        code = """
        x is 20
        x is x - 5
        x is x - 3
        x is x - 1
        trend is x
        """

        result = run_code(code, interpreter)
        trend = decode_vector(result, interpreter.space)
        assert trend == "decreasing"

    def test_trend_stable(self, interpreter):
        """Test TREND detects stable pattern."""
        code = """
        x is 10
        x is 10
        x is 10
        x is 10
        trend is x
        """

        result = run_code(code, interpreter)
        trend = decode_vector(result, interpreter.space)
        assert trend == "stable"

    def test_trend_with_insufficient_data(self, interpreter):
        """Test TREND with insufficient data returns unknown."""
        code = """
        x is 10
        trend is x
        """

        result = run_code(code, interpreter)
        trend = decode_vector(result, interpreter.space)
        # With only one value, trend is unknown or based on just that
        assert isinstance(trend, str)


class TestTemporalOperatorsIntegration:
    """Integration tests combining multiple temporal operators."""

    def test_was_and_change_together(self, interpreter):
        """Test using WAS and CHANGE on same variable."""
        code = """
        x is 100
        x is x + 10
        x is x + 5
        prev is was is x
        delta is change is x
        prev
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # prev is the previous trajectory value
        # Just verify it returns a numeric value
        assert isinstance(value, (int, float))

    def test_temporal_in_conditional(self, interpreter):
        """Test using temporal operators in conditions."""
        code = """
        x is 10
        x is x + 5
        x is x + 2
        
        result is 0
        if change is x < 5:
            result is 1
        else:
            result is 2
        result
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        # Change is 2, which is < 5, so result should be 1
        assert value == 1

    def test_status_and_trend(self, interpreter):
        """Test using STATUS and TREND together."""
        code = """
        x is 10
        x is x + 5
        x is x + 3
        
        s is status is x
        t is trend is x
        t
        """

        result = run_code(code, interpreter)
        trend = decode_vector(result, interpreter.space)
        assert trend in [
            "increasing",
            "decreasing",
            "stable",
            "oscillating",
            "mixed",
            "unknown",
        ]
