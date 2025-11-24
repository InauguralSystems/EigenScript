"""
Tests for date/time operations in EigenScript.
"""

import pytest
import time
import textwrap
from datetime import datetime
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


class TestTimeNow:
    """Tests for time_now function."""

    def test_time_now_returns_timestamp(self, interpreter):
        """Test that time_now returns a valid timestamp."""
        code = """
        time_now of null
        """

        before = time.time()
        result = run_code(code, interpreter)
        after = time.time()

        timestamp = decode_vector(result, interpreter.space)

        # Should be a number
        assert isinstance(timestamp, (int, float))

        # Should be between before and after
        assert before <= timestamp <= after

    def test_time_now_successive_calls(self, interpreter):
        """Test that successive calls to time_now increase."""
        code = """
        t1 is time_now of null
        t2 is time_now of null
        t2 - t1
        """

        result = run_code(code, interpreter)
        diff = decode_vector(result, interpreter.space)

        # Difference should be small but non-negative
        assert diff >= 0
        assert diff < 1  # Should be less than 1 second


class TestTimeFormat:
    """Tests for time_format function."""

    def test_format_basic(self, interpreter):
        """Test basic time formatting."""
        # Use a known timestamp: 2025-11-19 00:00:00 UTC
        timestamp = 1763049600  # Approximate

        code = f"""
        time_format of [{timestamp}, "%Y-%m-%d"]
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        # Should be a string with date format
        assert isinstance(formatted, str)
        assert len(formatted) == 10  # YYYY-MM-DD format

    def test_format_with_time(self, interpreter):
        """Test formatting with time components."""
        timestamp = 1763049600

        code = f"""
        time_format of [{timestamp}, "%Y-%m-%d %H:%M:%S"]
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        # Should be a string with datetime format
        assert isinstance(formatted, str)
        assert " " in formatted  # Should have space between date and time
        assert ":" in formatted  # Should have time separators

    def test_format_year_only(self, interpreter):
        """Test formatting only the year."""
        timestamp = 1763049600

        code = f"""
        time_format of [{timestamp}, "%Y"]
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        # Should be just the year
        assert formatted.startswith("202")  # 2020s

    def test_format_current_time(self, interpreter):
        """Test formatting current time."""
        code = """
        now is time_now of null
        time_format of [now, "%Y-%m-%d"]
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        # Should be today's date
        today = datetime.now().strftime("%Y-%m-%d")
        assert formatted == today


class TestTimeParse:
    """Tests for time_parse function."""

    def test_parse_date(self, interpreter):
        """Test parsing a date string."""
        code = """
        time_parse of ["2025-11-19", "%Y-%m-%d"]
        """

        result = run_code(code, interpreter)
        timestamp = decode_vector(result, interpreter.space)

        # Should be a valid timestamp
        assert isinstance(timestamp, (int, float))
        assert timestamp > 0

    def test_parse_datetime(self, interpreter):
        """Test parsing a datetime string."""
        code = """
        time_parse of ["2025-11-19 14:30:00", "%Y-%m-%d %H:%M:%S"]
        """

        result = run_code(code, interpreter)
        timestamp = decode_vector(result, interpreter.space)

        # Should be a valid timestamp
        assert isinstance(timestamp, (int, float))
        assert timestamp > 0

    def test_parse_invalid_format(self, interpreter):
        """Test error with invalid format."""
        code = """
        time_parse of ["not a date", "%Y-%m-%d"]
        """

        with pytest.raises(RuntimeError, match="Error parsing time"):
            run_code(code, interpreter)

    def test_parse_mismatch_format(self, interpreter):
        """Test error when string doesn't match format."""
        code = """
        time_parse of ["2025-11-19", "%Y/%m/%d"]
        """

        with pytest.raises(RuntimeError, match="Error parsing time"):
            run_code(code, interpreter)


class TestTimeRoundTrip:
    """Tests for round-trip time conversions."""

    def test_roundtrip_date(self, interpreter):
        """Test round-trip for date."""
        code = """
        # Parse a date
        timestamp is time_parse of ["2025-11-19", "%Y-%m-%d"]
        
        # Format it back
        time_format of [timestamp, "%Y-%m-%d"]
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        assert formatted == "2025-11-19"

    def test_roundtrip_datetime(self, interpreter):
        """Test round-trip for datetime."""
        code = """
        # Parse a datetime
        timestamp is time_parse of ["2025-11-19 14:30:00", "%Y-%m-%d %H:%M:%S"]
        
        # Format it back
        time_format of [timestamp, "%Y-%m-%d %H:%M:%S"]
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        assert formatted == "2025-11-19 14:30:00"

    def test_roundtrip_current_time(self, interpreter):
        """Test round-trip with current time."""
        code = """
        # Get current time
        now is time_now of null
        
        # Format it
        formatted is time_format of [now, "%Y-%m-%d %H:%M:%S"]
        
        # Parse it back
        timestamp is time_parse of [formatted, "%Y-%m-%d %H:%M:%S"]
        
        # Difference should be small (< 1 second due to rounding)
        diff is now - timestamp
        abs of diff
        """

        result = run_code(code, interpreter)
        diff = decode_vector(result, interpreter.space)

        # Should be very small difference (< 2 seconds for rounding)
        assert diff < 2


class TestTimeArithmetic:
    """Tests for time arithmetic operations."""

    def test_add_seconds(self, interpreter):
        """Test adding seconds to timestamp."""
        code = """
        # Parse a time
        base is time_parse of ["2025-11-19 12:00:00", "%Y-%m-%d %H:%M:%S"]
        
        # Add 1 hour (3600 seconds)
        later is base + 3600
        
        # Format result
        time_format of [later, "%Y-%m-%d %H:%M:%S"]
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        assert formatted == "2025-11-19 13:00:00"

    def test_subtract_seconds(self, interpreter):
        """Test subtracting seconds from timestamp."""
        code = """
        # Parse a time
        base is time_parse of ["2025-11-19 12:00:00", "%Y-%m-%d %H:%M:%S"]
        
        # Subtract 1 hour (3600 seconds)
        earlier is base - 3600
        
        # Format result
        time_format of [earlier, "%Y-%m-%d %H:%M:%S"]
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        assert formatted == "2025-11-19 11:00:00"

    def test_time_difference(self, interpreter):
        """Test calculating difference between timestamps."""
        code = """
        # Parse two times
        time1 is time_parse of ["2025-11-19 12:00:00", "%Y-%m-%d %H:%M:%S"]
        time2 is time_parse of ["2025-11-19 14:30:00", "%Y-%m-%d %H:%M:%S"]
        
        # Calculate difference (in seconds)
        time2 - time1
        """

        result = run_code(code, interpreter)
        diff = decode_vector(result, interpreter.space)

        # Should be 2.5 hours = 9000 seconds
        assert abs(diff - 9000) < 1

    def test_add_days(self, interpreter):
        """Test adding days to timestamp."""
        code = """
        # Parse a date
        base is time_parse of ["2025-11-19", "%Y-%m-%d"]
        
        # Add 7 days (7 * 24 * 3600 seconds)
        later is base + (7 * 24 * 3600)
        
        # Format result
        time_format of [later, "%Y-%m-%d"]
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        assert formatted == "2025-11-26"


class TestTimeIntegration:
    """Integration tests for time operations."""

    def test_measure_execution_time(self, interpreter):
        """Test measuring execution time of code."""
        code = """
        # Record start time
        start is time_now of null
        
        # Do some computation
        define factorial as:
            if arg <= 1:
                return 1
            else:
                return arg * (factorial of (arg - 1))
        
        result is factorial of 10
        
        # Record end time
        end is time_now of null
        
        # Calculate elapsed time
        elapsed is end - start
        
        # Elapsed should be a small positive number
        elapsed
        """

        result = run_code(code, interpreter)
        elapsed = decode_vector(result, interpreter.space)

        # Should be a small positive number (< 1 second)
        assert isinstance(elapsed, (int, float))
        assert 0 <= elapsed < 1

    def test_time_with_formatting(self, interpreter):
        """Test time operations with different formats."""
        code = """
        # Get current time
        now is time_now of null
        
        # Format in different ways
        date is time_format of [now, "%Y-%m-%d"]
        time is time_format of [now, "%H:%M:%S"]
        full is time_format of [now, "%Y-%m-%d %H:%M:%S"]
        
        # Return the full format
        full
        """

        result = run_code(code, interpreter)
        formatted = decode_vector(result, interpreter.space)

        # Should be a valid datetime string
        assert isinstance(formatted, str)
        assert " " in formatted
        assert "-" in formatted
        assert ":" in formatted

    def test_time_comparison(self, interpreter):
        """Test comparing timestamps."""
        code = """
        # Parse two times
        time1 is time_parse of ["2025-11-19 12:00:00", "%Y-%m-%d %H:%M:%S"]
        time2 is time_parse of ["2025-11-19 14:00:00", "%Y-%m-%d %H:%M:%S"]
        
        # Check if time2 is later than time1
        diff is time2 - time1
        
        # Result should be positive
        is_later is diff > 0
        is_later
        """

        result = run_code(code, interpreter)
        is_later = decode_vector(result, interpreter.space)

        # time2 should be later than time1
        assert is_later != 0  # Non-zero means true
