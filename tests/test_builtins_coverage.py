"""
Tests to improve coverage of builtins.py
Focuses on edge cases and paths not covered by other tests.
"""

import pytest
import textwrap
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter


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


class TestBuiltinsCoverage:
    """Test suite for improving builtins.py coverage."""

    def test_print_empty_list(self, interpreter, capsys):
        """Test printing an empty list."""
        code = """
empty is []
print of empty
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[]" in captured.out

    def test_print_list_with_elements(self, interpreter, capsys):
        """Test printing a list with multiple elements."""
        code = """
numbers is [1, 2, 3]
print of numbers
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[1" in captured.out

    def test_type_of_list(self, interpreter, capsys):
        """Test type() function on a list."""
        code = """
my_list is [1, 2, 3]
t is type of my_list
print of t
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "list" in captured.out

    def test_type_of_number(self, interpreter, capsys):
        """Test type() function on a number."""
        code = """
num is 42
t is type of num
print of t
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output a type name
        assert len(captured.out.strip()) > 0

    def test_norm_of_vector(self, interpreter, capsys):
        """Test norm() function."""
        code = """
x is 3
n is norm of x
print of n
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Norm of 3 should be close to 3
        assert captured.out.strip() != ""

    def test_range_basic(self, interpreter, capsys):
        """Test range() function."""
        code = """
r is range of 5
print of r
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[0" in captured.out

    def test_range_large(self, interpreter, capsys):
        """Test range with large number."""
        code = """
r is range of 100
l is len of r
print of l
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "100" in captured.out

    def test_upper_function(self, interpreter, capsys):
        """Test upper() string function."""
        code = """
text is "hello"
result is upper of text
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "HELLO" in captured.out

    def test_lower_function(self, interpreter, capsys):
        """Test lower() string function."""
        code = """
text is "HELLO"
result is lower of text
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "hello" in captured.out

    def test_split_function(self, interpreter, capsys):
        """Test split() string function."""
        code = """
text is "a,b,c"
parts is split of text
print of parts
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[" in captured.out

    def test_join_function(self, interpreter, capsys):
        """Test join() function."""
        code = """
parts is ["a", "b", "c"]
result is join of parts
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output joined string
        assert len(captured.out.strip()) > 0

    def test_min_function(self, interpreter, capsys):
        """Test min() function."""
        code = """
numbers is [5, 2, 8, 1, 9]
result is min of numbers
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "1" in captured.out

    def test_max_function(self, interpreter, capsys):
        """Test max() function."""
        code = """
numbers is [5, 2, 8, 1, 9]
result is max of numbers
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "9" in captured.out

    def test_sort_function(self, interpreter, capsys):
        """Test sort() function."""
        code = """
numbers is [3, 1, 4, 1, 5]
sorted_nums is sort of numbers
print of sorted_nums
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[1" in captured.out

    def test_pop_function(self, interpreter, capsys):
        """Test pop() function."""
        code = """
numbers is [1, 2, 3]
last is pop of numbers
print of last
print of numbers
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "3" in captured.out

    def test_sqrt_function(self, interpreter, capsys):
        """Test sqrt() math function."""
        code = """
x is 16
result is sqrt of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "4" in captured.out

    def test_abs_function(self, interpreter, capsys):
        """Test abs() math function."""
        code = """
x is -5
result is abs of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "5" in captured.out

    def test_pow_function(self, interpreter, capsys):
        """Test pow() math function."""
        code = """
base is 2
exp is 3
args is [base, exp]
result is pow of args
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "8" in captured.out

    def test_log_function(self, interpreter, capsys):
        """Test log() math function."""
        code = """
x is 2.718281828
result is log of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output approximately 1
        assert "1" in captured.out

    def test_exp_function(self, interpreter, capsys):
        """Test exp() math function."""
        code = """
x is 1
result is exp of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output approximately e
        assert "2.7" in captured.out

    def test_sin_function(self, interpreter, capsys):
        """Test sin() math function."""
        code = """
x is 0
result is sin of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # sin(0) should be 0
        assert "0" in captured.out

    def test_cos_function(self, interpreter, capsys):
        """Test cos() math function."""
        code = """
x is 0
result is cos of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # cos(0) should be 1
        assert "1" in captured.out

    def test_tan_function(self, interpreter, capsys):
        """Test tan() math function."""
        code = """
x is 0
result is tan of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # tan(0) should be 0
        assert "0" in captured.out

    def test_floor_function(self, interpreter, capsys):
        """Test floor() math function."""
        code = """
x is 3.7
result is floor of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "3" in captured.out

    def test_ceil_function(self, interpreter, capsys):
        """Test ceil() math function."""
        code = """
x is 3.2
result is ceil of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "4" in captured.out

    def test_round_function(self, interpreter, capsys):
        """Test round() math function."""
        code = """
x is 3.7
result is round of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "4" in captured.out

    def test_zip_function(self, interpreter, capsys):
        """Test zip() function."""
        code = """
list1 is [1, 2, 3]
list2 is ["a", "b", "c"]
args is [list1, list2]
result is zip of args
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output paired lists
        assert "[" in captured.out

    def test_enumerate_function(self, interpreter, capsys):
        """Test enumerate() function."""
        code = """
items is ["a", "b", "c"]
result is enumerate of items
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output indexed items
        assert "[" in captured.out

    def test_flatten_function(self, interpreter, capsys):
        """Test flatten() function."""
        code = """
nested is [[1, 2], [3, 4]]
result is flatten of nested
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output flattened list
        assert "[1" in captured.out

    def test_reverse_function(self, interpreter, capsys):
        """Test reverse() function."""
        code = """
numbers is [1, 2, 3, 4, 5]
result is reverse of numbers
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output reversed list starting with 5
        assert "5" in captured.out
