"""
Tests for EigenScript interrogatives (WHO, WHAT, WHEN, WHERE, WHY, HOW).

These interrogatives allow code to introspect its own execution state,
enabling self-aware computation.
"""

import pytest
import textwrap
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.evaluator.interpreter import EigenList
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


class TestWhoInterrogative:
    """Tests for WHO interrogative (identity extraction)."""

    def test_who_is_variable(self, interpreter):
        """Test WHO on a variable returns its name."""
        code = """
        x is 42
        who is x
        """

        result = run_code(code, interpreter)
        identity = decode_vector(result, interpreter.space)
        assert identity == "x"

    def test_who_is_expression(self, interpreter):
        """Test WHO on an expression returns a description."""
        code = """
        y is 10 + 5
        who is y
        """

        result = run_code(code, interpreter)
        identity = decode_vector(result, interpreter.space)
        assert identity == "y"


class TestWhatInterrogative:
    """Tests for WHAT interrogative (magnitude extraction)."""

    def test_what_is_scalar(self, interpreter):
        """Test WHAT on a scalar returns the value."""
        code = """
        x is 42
        what is x
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 42

    def test_what_is_list(self, interpreter):
        """Test WHAT on a list returns its length."""
        code = """
        nums is [1, 2, 3, 4, 5]
        what is nums
        """

        result = run_code(code, interpreter)
        length = decode_vector(result, interpreter.space)
        assert length == 5

    def test_what_is_computation(self, interpreter):
        """Test WHAT on a computation result."""
        code = """
        result is 10 + 32
        what is result
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 42


class TestWhenInterrogative:
    """Tests for WHEN interrogative (temporal coordinate)."""

    def test_when_simple(self, interpreter):
        """Test WHEN returns trajectory length or recursion depth."""
        code = """
        x is 10
        y is 20
        z is 30
        when is z
        """

        result = run_code(code, interpreter)
        temporal = decode_vector(result, interpreter.space)
        # Should be a non-negative number representing time/step
        assert isinstance(temporal, (int, float))
        assert temporal >= 0

    def test_when_in_loop(self, interpreter):
        """Test WHEN tracking in a loop."""
        code = """
        counter is 0
        loop while counter < 3:
            counter is counter + 1
        when is counter
        """

        result = run_code(code, interpreter)
        temporal = decode_vector(result, interpreter.space)
        assert isinstance(temporal, (int, float))


class TestWhereInterrogative:
    """Tests for WHERE interrogative (spatial position)."""

    def test_where_returns_value(self, interpreter):
        """Test WHERE returns the value itself (its position in semantic space)."""
        code = """
        x is 42
        where is x
        """

        result = run_code(code, interpreter)
        # WHERE should return the LRVM vector itself
        # We can verify it's not just a scalar by checking the type
        value = decode_vector(result, interpreter.space)
        assert isinstance(value, (int, float))


class TestWhyInterrogative:
    """Tests for WHY interrogative (causal direction/gradient)."""

    def test_why_with_trajectory(self, interpreter):
        """Test WHY returns direction of change."""
        code = """
        x is 10
        y is 20
        z is 30
        why is z
        """

        result = run_code(code, interpreter)
        # WHY returns a direction vector
        # Should be an LRVM vector
        assert result is not None

    def test_why_no_trajectory(self, interpreter):
        """Test WHY with no trajectory returns zero vector."""
        code = """
        x is 42
        why is x
        """

        result = run_code(code, interpreter)
        # Should return zero vector (no trajectory yet)
        assert result is not None


class TestHowInterrogative:
    """Tests for HOW interrogative (process quality/transformation)."""

    def test_how_returns_framework_strength(self, interpreter):
        """Test HOW returns Framework Strength."""
        code = """
        x is 10
        y is 20
        how is y
        """

        result = run_code(code, interpreter)
        # HOW should return FS or a description with FS
        decoded = decode_vector(result, interpreter.space)

        # Could be either a number (FS) or a string with FS info
        if isinstance(decoded, (int, float)):
            # Numeric FS value
            assert 0 <= decoded <= 1
        else:
            # String description with FS
            assert isinstance(decoded, str)
            assert "FS=" in decoded or "fs=" in decoded.lower()

    def test_how_with_trajectory(self, interpreter):
        """Test HOW with sufficient trajectory for EigenControl."""
        code = """
        x is 10
        y is 20
        z is 30
        how is z
        """

        result = run_code(code, interpreter)
        decoded = decode_vector(result, interpreter.space)

        # With trajectory, should get rich description
        if isinstance(decoded, str):
            # Should include geometric metrics
            assert any(metric in decoded for metric in ["FS=", "r=", "κ="])


class TestInterrogativeIntegration:
    """Integration tests combining multiple interrogatives."""

    def test_multiple_interrogatives(self, interpreter):
        """Test using multiple interrogatives on same value."""
        code = """
        x is 42
        identity is who is x
        magnitude is what is x
        temporal is when is x
        identity
        """

        result = run_code(code, interpreter)
        identity = decode_vector(result, interpreter.space)
        assert identity == "x"

    def test_interrogatives_in_computation(self, interpreter):
        """Test interrogatives within computations."""
        code = """
        x is 10
        y is 20
        z is x + y
        result is what is z
        result
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 30


class TestEigenControlCoverage:
    """Tests specifically to exercise EigenControl module code paths."""

    def test_improving_predicate_uses_eigencontrol(self, interpreter):
        """Test that improving predicate exercises EigenControl radius calculation."""
        code = """
        counter is 0
        loop while counter < 5:
            counter is counter + 1
        improving
        """

        result = run_code(code, interpreter)
        # improving is a predicate that returns 1.0 or 0.0
        value = decode_vector(result, interpreter.space)
        assert value in [0.0, 1.0]

    def test_how_interrogative_with_eigencontrol(self, interpreter):
        """Test HOW interrogative uses EigenControl when trajectory exists."""
        code = """
        # Build up trajectory
        a is 10
        b is 20
        c is 30
        d is 40
        # Now query with HOW
        how is d
        """

        result = run_code(code, interpreter)
        decoded = decode_vector(result, interpreter.space)

        # Should get a rich response with EigenControl metrics
        if isinstance(decoded, str):
            # Should include curvature (κ) or radius (r) from EigenControl
            assert "κ=" in decoded or "r=" in decoded
