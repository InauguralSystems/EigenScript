"""
Tests for enhanced list operations in EigenScript.
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


class TestZip:
    """Tests for zip function."""

    def test_zip_two_lists_equal_length(self, interpreter):
        """Test zipping two lists of equal length."""
        code = """
        list1 is [1, 2, 3]
        list2 is ["a", "b", "c"]
        zip of [list1, list2]
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

        # Check first pair
        first_pair = result.elements[0]
        assert isinstance(first_pair, EigenList)
        assert len(first_pair.elements) == 2

        # Decode values
        val1 = decode_vector(first_pair.elements[0], interpreter.space)
        val2 = decode_vector(first_pair.elements[1], interpreter.space)
        assert val1 == 1
        assert val2 == "a"

    def test_zip_two_lists_unequal_length(self, interpreter):
        """Test zipping two lists of unequal length (stops at shortest)."""
        code = """
        list1 is [1, 2, 3, 4, 5]
        list2 is ["a", "b", "c"]
        zip of [list1, list2]
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        # Should stop at shortest list (length 3)
        assert len(result.elements) == 3

    def test_zip_three_lists(self, interpreter):
        """Test zipping three lists."""
        code = """
        list1 is [1, 2, 3]
        list2 is ["a", "b", "c"]
        list3 is [10, 20, 30]
        zip of [list1, list2, list3]
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

        # Check first tuple has 3 elements
        first_tuple = result.elements[0]
        assert isinstance(first_tuple, EigenList)
        assert len(first_tuple.elements) == 3

    def test_zip_empty_lists(self, interpreter):
        """Test zipping empty lists."""
        code = """
        list1 is []
        list2 is []
        zip of [list1, list2]
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_zip_one_empty_list(self, interpreter):
        """Test zipping when one list is empty."""
        code = """
        list1 is [1, 2, 3]
        list2 is []
        zip of [list1, list2]
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        # Should be empty since one list is empty
        assert len(result.elements) == 0


class TestEnumerate:
    """Tests for enumerate function."""

    def test_enumerate_basic(self, interpreter):
        """Test basic enumerate."""
        code = """
        items is ["apple", "banana", "cherry"]
        enumerate of items
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

        # Check first pair
        first_pair = result.elements[0]
        assert isinstance(first_pair, EigenList)
        assert len(first_pair.elements) == 2

        index = decode_vector(first_pair.elements[0], interpreter.space)
        value = decode_vector(first_pair.elements[1], interpreter.space)
        assert index == 0
        assert value == "apple"

    def test_enumerate_numbers(self, interpreter):
        """Test enumerate with numbers."""
        code = """
        numbers is [10, 20, 30, 40, 50]
        enumerate of numbers
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 5

        # Check indices are sequential
        for i, pair in enumerate(result.elements):
            assert isinstance(pair, EigenList)
            index = decode_vector(pair.elements[0], interpreter.space)
            assert index == i

    def test_enumerate_empty_list(self, interpreter):
        """Test enumerate with empty list."""
        code = """
        items is []
        enumerate of items
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_enumerate_single_element(self, interpreter):
        """Test enumerate with single element."""
        code = """
        items is ["only"]
        enumerate of items
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 1

        pair = result.elements[0]
        index = decode_vector(pair.elements[0], interpreter.space)
        value = decode_vector(pair.elements[1], interpreter.space)
        assert index == 0
        assert value == "only"


class TestFlatten:
    """Tests for flatten function."""

    def test_flatten_basic(self, interpreter):
        """Test basic flatten."""
        code = """
        nested is [[1, 2], [3, 4], [5]]
        flatten of nested
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 5

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == [1, 2, 3, 4, 5]

    def test_flatten_mixed_elements(self, interpreter):
        """Test flatten with mixed nested and non-nested elements."""
        code = """
        mixed is [1, [2, 3], 4, [5, 6]]
        flatten of mixed
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 6

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == [1, 2, 3, 4, 5, 6]

    def test_flatten_empty_sublists(self, interpreter):
        """Test flatten with empty sublists."""
        code = """
        nested is [[1, 2], [], [3, 4]]
        flatten of nested
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        # Empty sublist contributes nothing
        assert len(result.elements) == 4

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == [1, 2, 3, 4]

    def test_flatten_all_empty(self, interpreter):
        """Test flatten with all empty sublists."""
        code = """
        nested is [[], [], []]
        flatten of nested
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_flatten_single_level(self, interpreter):
        """Test that flatten only flattens one level."""
        code = """
        deep is [[[1, 2]], [[3, 4]]]
        flatten of deep
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        # Should have 2 elements (each a list)
        assert len(result.elements) == 2

        # First element should still be a list
        assert isinstance(result.elements[0], EigenList)

    def test_flatten_empty_list(self, interpreter):
        """Test flatten with empty list."""
        code = """
        empty is []
        flatten of empty
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 0


class TestReverse:
    """Tests for reverse function."""

    def test_reverse_basic(self, interpreter):
        """Test basic reverse."""
        code = """
        items is [1, 2, 3, 4, 5]
        reverse of items
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 5

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == [5, 4, 3, 2, 1]

    def test_reverse_strings(self, interpreter):
        """Test reverse with strings."""
        code = """
        items is ["a", "b", "c"]
        reverse of items
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == ["c", "b", "a"]

    def test_reverse_single_element(self, interpreter):
        """Test reverse with single element."""
        code = """
        items is [42]
        reverse of items
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 1

        value = decode_vector(result.elements[0], interpreter.space)
        assert value == 42

    def test_reverse_empty_list(self, interpreter):
        """Test reverse with empty list."""
        code = """
        items is []
        reverse of items
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 0

    def test_reverse_twice(self, interpreter):
        """Test that reversing twice returns original."""
        code = """
        original is [1, 2, 3, 4, 5]
        reversed is reverse of original
        back is reverse of reversed
        back
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == [1, 2, 3, 4, 5]


class TestEnhancedListsIntegration:
    """Integration tests combining enhanced list operations."""

    def test_zip_and_enumerate(self, interpreter):
        """Test combining zip and enumerate."""
        code = """
        list1 is [1, 2, 3]
        list2 is ["a", "b", "c"]
        zipped is zip of [list1, list2]
        enumerate of zipped
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        # Should have 3 pairs: [index, [value1, value2]]
        assert len(result.elements) == 3

    def test_flatten_and_reverse(self, interpreter):
        """Test combining flatten and reverse."""
        code = """
        nested is [[1, 2], [3, 4], [5]]
        flat is flatten of nested
        reverse of flat
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == [5, 4, 3, 2, 1]

    def test_enumerate_and_reverse(self, interpreter):
        """Test combining enumerate and reverse."""
        code = """
        items is ["a", "b", "c"]
        indexed is enumerate of items
        reverse of indexed
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

        # First element (after reverse) should be [2, "c"]
        first = result.elements[0]
        index = decode_vector(first.elements[0], interpreter.space)
        value = decode_vector(first.elements[1], interpreter.space)
        assert index == 2
        assert value == "c"

    def test_zip_flatten_pattern(self, interpreter):
        """Test zip followed by flatten for interleaving."""
        code = """
        list1 is [1, 2, 3]
        list2 is ["a", "b", "c"]
        zipped is zip of [list1, list2]
        flatten of zipped
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        # Should interleave: [1, "a", 2, "b", 3, "c"]
        assert len(result.elements) == 6

        values = [decode_vector(elem, interpreter.space) for elem in result.elements]
        assert values == [1, "a", 2, "b", 3, "c"]

    def test_with_map_and_zip(self, interpreter):
        """Test enhanced list operations with map."""
        code = """
        # Define doubling function
        define double as:
            return arg * 2
        
        # Create lists
        numbers is [1, 2, 3]
        doubled is map of [double, numbers]
        
        # Zip original and doubled
        zip of [numbers, doubled]
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

        # Check first pair: [1, 2]
        first = result.elements[0]
        orig = decode_vector(first.elements[0], interpreter.space)
        dbl = decode_vector(first.elements[1], interpreter.space)
        assert orig == 1
        assert dbl == 2

    def test_range_and_enumerate(self, interpreter):
        """Test enumerate with range."""
        code = """
        numbers is range of 5
        enumerate of numbers
        """

        result = run_code(code, interpreter)
        assert isinstance(result, EigenList)
        assert len(result.elements) == 5

        # Each element should be [index, value] where value == index
        for i, pair in enumerate(result.elements):
            index = decode_vector(pair.elements[0], interpreter.space)
            value = decode_vector(pair.elements[1], interpreter.space)
            assert index == i
            assert value == i
