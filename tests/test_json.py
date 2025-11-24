"""
Tests for JSON support in EigenScript.
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


class TestJSONParse:
    """Tests for json_parse function."""

    def test_parse_number(self, interpreter):
        """Test parsing JSON number."""
        code = """
        json_parse of "42"
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 42

    def test_parse_string(self, interpreter):
        """Test parsing JSON string."""
        code = """
        json_parse of "\\"hello\\""
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == "hello"

    def test_parse_boolean_true(self, interpreter):
        """Test parsing JSON true."""
        code = """
        json_parse of "true"
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 1

    def test_parse_boolean_false(self, interpreter):
        """Test parsing JSON false."""
        code = """
        json_parse of "false"
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 0

    def test_parse_null(self, interpreter):
        """Test parsing JSON null."""
        code = """
        json_parse of "null"
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == "null"

    def test_parse_array(self, interpreter):
        """Test parsing JSON array."""
        code = """
        json_parse of "[1, 2, 3]"
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == [1, 2, 3]

    def test_parse_nested_array(self, interpreter):
        """Test parsing nested JSON array."""
        code = """
        json_parse of "[[1, 2], [3, 4]]"
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)

        # Check structure
        assert len(result.elements) == 2
        assert isinstance(result.elements[0], EigenList)
        assert isinstance(result.elements[1], EigenList)

    def test_parse_object(self, interpreter):
        """Test parsing JSON object."""
        code = """
        data is json_parse of "{\\"name\\": \\"Alice\\", \\"age\\": 30}"
        data
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)

        # Object is represented as list of [key, value] pairs
        assert len(result.elements) == 2

    def test_parse_empty_array(self, interpreter):
        """Test parsing empty JSON array."""
        code = """
        json_parse of "[]"
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_parse_empty_object(self, interpreter):
        """Test parsing empty JSON object."""
        code = """
        json_parse of "{}"
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_parse_invalid_json(self, interpreter):
        """Test error on invalid JSON."""
        code = """
        json_parse of "not valid json"
        """

        with pytest.raises(ValueError, match="Invalid JSON"):
            run_code(code, interpreter)

    def test_parse_malformed_json(self, interpreter):
        """Test error on malformed JSON."""
        code = """
        json_parse of "{\\"incomplete\\":"
        """

        with pytest.raises(ValueError, match="Invalid JSON"):
            run_code(code, interpreter)


class TestJSONStringify:
    """Tests for json_stringify function."""

    def test_stringify_number(self, interpreter):
        """Test stringifying number."""
        code = """
        json_stringify of 42
        """

        result = run_code(code, interpreter)
        json_str = decode_vector(result, interpreter.space)
        assert json_str == "42" or json_str == "42.0"

    def test_stringify_string(self, interpreter):
        """Test stringifying string."""
        code = """
        json_stringify of "hello"
        """

        result = run_code(code, interpreter)
        json_str = decode_vector(result, interpreter.space)
        assert json_str == '"hello"'

    def test_stringify_list(self, interpreter):
        """Test stringifying list."""
        code = """
        items is [1, 2, 3]
        json_stringify of items
        """

        result = run_code(code, interpreter)
        json_str = decode_vector(result, interpreter.space)
        # Could be with or without .0 for floats
        assert json_str in ["[1, 2, 3]", "[1.0, 2.0, 3.0]"]

    def test_stringify_nested_list(self, interpreter):
        """Test stringifying nested list."""
        code = """
        nested is [[1, 2], [3, 4]]
        json_stringify of nested
        """

        result = run_code(code, interpreter)
        json_str = decode_vector(result, interpreter.space)
        # Basic structure check
        assert json_str.startswith("[[")
        assert json_str.endswith("]]")

    def test_stringify_empty_list(self, interpreter):
        """Test stringifying empty list."""
        code = """
        empty is []
        json_stringify of empty
        """

        result = run_code(code, interpreter)
        json_str = decode_vector(result, interpreter.space)
        assert json_str == "[]"

    def test_stringify_with_indent(self, interpreter):
        """Test stringifying with indentation."""
        code = """
        items is [1, 2, 3]
        json_stringify of [items, 2]
        """

        result = run_code(code, interpreter)
        json_str = decode_vector(result, interpreter.space)
        # Check for indentation (newlines and spaces)
        assert "\n" in json_str
        assert "  " in json_str


class TestJSONRoundTrip:
    """Tests for JSON round-trip conversion."""

    def test_roundtrip_number(self, interpreter):
        """Test round-trip for number."""
        code = """
        original is 42
        json_str is json_stringify of original
        parsed is json_parse of json_str
        parsed
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == 42

    def test_roundtrip_string(self, interpreter):
        """Test round-trip for string."""
        code = """
        original is "hello"
        json_str is json_stringify of original
        parsed is json_parse of json_str
        parsed
        """

        result = run_code(code, interpreter)
        value = decode_vector(result, interpreter.space)
        assert value == "hello"

    def test_roundtrip_list(self, interpreter):
        """Test round-trip for list."""
        code = """
        original is [1, 2, 3]
        json_str is json_stringify of original
        parsed is json_parse of json_str
        parsed
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == [1, 2, 3]

    def test_roundtrip_nested_list(self, interpreter):
        """Test round-trip for nested list."""
        code = """
        original is [[1, 2], [3, 4]]
        json_str is json_stringify of original
        parsed is json_parse of json_str
        parsed
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 2
        assert isinstance(result.elements[0], EigenList)
        assert isinstance(result.elements[1], EigenList)


class TestJSONIntegration:
    """Integration tests for JSON with other features."""

    def test_json_with_file_io(self, interpreter):
        """Test using JSON with file I/O (conceptually)."""
        code = """
        # Create data structure
        data is [1, 2, 3, 4, 5]
        
        # Convert to JSON
        json_str is json_stringify of data
        
        # Parse back
        parsed is json_parse of json_str
        
        # Verify
        len of parsed
        """

        result = run_code(code, interpreter)
        length = decode_vector(result, interpreter.space)
        assert length == 5

    def test_json_with_map(self, interpreter):
        """Test using JSON with map function."""
        code = """
        # Parse JSON array
        numbers is json_parse of "[1, 2, 3, 4, 5]"
        
        # Define a doubling function
        define double as:
            return arg * 2
        
        # Map over the numbers
        doubled is map of [double, numbers]
        
        # Convert back to JSON
        json_stringify of doubled
        """

        result = run_code(code, interpreter)
        json_str = decode_vector(result, interpreter.space)
        # Check that it's a valid JSON array with doubled values
        assert "[" in json_str and "]" in json_str

    def test_json_complex_structure(self, interpreter):
        """Test JSON with complex nested structures."""
        code = """
        # Create a complex JSON structure
        json_str is "[{\\"id\\": 1, \\"name\\": \\"Alice\\"}, {\\"id\\": 2, \\"name\\": \\"Bob\\"}]"
        
        # Parse it
        data is json_parse of json_str
        
        # Get length
        len of data
        """

        result = run_code(code, interpreter)
        length = decode_vector(result, interpreter.space)
        assert length == 2
