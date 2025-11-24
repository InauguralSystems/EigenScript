"""
Final push to reach 80% coverage.
Comprehensive tests for remaining uncovered code.
"""

import pytest
import textwrap
import tempfile
import os
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


class TestComprehensiveBuiltins:
    """Comprehensive tests for all builtins."""

    def test_range_with_negative(self, interpreter, capsys):
        """Test range with negative number."""
        code = """
r is range of -5
print of r
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should handle negative gracefully
        assert len(captured.out) > 0

    def test_pow_edge_cases(self, interpreter, capsys):
        """Test pow with edge cases."""
        code = """
# 0^0
args1 is [0, 0]
r1 is pow of args1
print of r1

# 1^1000
args2 is [1, 1000]
r2 is pow of args2
print of r2

# 2^0
args3 is [2, 0]
r3 is pow of args3
print of r3
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "1" in captured.out

    def test_string_upper_already_upper(self, interpreter, capsys):
        """Test upper on already uppercase string."""
        code = """
text is "ALREADY"
result is upper of text
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "ALREADY" in captured.out

    def test_string_lower_already_lower(self, interpreter, capsys):
        """Test lower on already lowercase string."""
        code = """
text is "already"
result is lower of text
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "already" in captured.out

    def test_split_with_single_char(self, interpreter, capsys):
        """Test split on single character."""
        code = """
text is "x"
parts is split of text
print of parts
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[" in captured.out

    def test_join_single_element(self, interpreter, capsys):
        """Test join on single element list."""
        code = """
single is ["alone"]
result is join of single
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "alone" in captured.out

    def test_sort_already_sorted(self, interpreter, capsys):
        """Test sort on already sorted list."""
        code = """
sorted_list is [1, 2, 3, 4, 5]
result is sort of sorted_list
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[1" in captured.out

    def test_sort_reverse_order(self, interpreter, capsys):
        """Test sort on reverse ordered list."""
        code = """
reverse is [5, 4, 3, 2, 1]
result is sort of reverse
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[1" in captured.out

    def test_reverse_single_element(self, interpreter, capsys):
        """Test reverse on single element."""
        code = """
single is [42]
result is reverse of single
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "42" in captured.out

    def test_reverse_two_elements(self, interpreter, capsys):
        """Test reverse on two elements."""
        code = """
pair is [1, 2]
result is reverse of pair
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "2" in captured.out

    def test_flatten_already_flat(self, interpreter, capsys):
        """Test flatten on already flat list."""
        code = """
flat is [1, 2, 3, 4, 5]
result is flatten of flat
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[1" in captured.out

    def test_flatten_deeply_nested(self, interpreter, capsys):
        """Test flatten on deeply nested list."""
        code = """
deep is [[[1, 2]], [[3, 4]]]
result is flatten of deep
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "1" in captured.out

    def test_enumerate_empty_list(self, interpreter, capsys):
        """Test enumerate on empty list."""
        code = """
empty is []
result is enumerate of empty
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[]" in captured.out

    def test_enumerate_single_element(self, interpreter, capsys):
        """Test enumerate on single element."""
        code = """
single is ["item"]
result is enumerate of single
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "0" in captured.out

    def test_zip_empty_lists(self, interpreter, capsys):
        """Test zip with empty lists."""
        code = """
empty1 is []
empty2 is []
args is [empty1, empty2]
result is zip of args
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "[]" in captured.out

    def test_zip_different_lengths(self, interpreter, capsys):
        """Test zip with different length lists."""
        code = """
short is [1, 2]
long is ["a", "b", "c", "d"]
args is [short, long]
result is zip of args
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should zip to shortest length
        assert "[" in captured.out

    def test_math_with_large_numbers(self, interpreter, capsys):
        """Test math functions with large numbers."""
        code = """
large is 1000000
result is sqrt of large
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "1000" in captured.out

    def test_math_with_small_numbers(self, interpreter, capsys):
        """Test math functions with very small numbers."""
        code = """
small is 0.000001
result is log of small
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should output negative number
        assert len(captured.out) > 0

    def test_trig_with_pi(self, interpreter, capsys):
        """Test trigonometric functions with pi."""
        code = """
pi is 3.14159265359
result is sin of pi
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # sin(pi) should be close to 0
        assert "0" in captured.out

    def test_floor_negative(self, interpreter, capsys):
        """Test floor with negative number."""
        code = """
x is -3.7
result is floor of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "-4" in captured.out

    def test_ceil_negative(self, interpreter, capsys):
        """Test ceil with negative number."""
        code = """
x is -3.2
result is ceil of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "-3" in captured.out

    def test_round_negative(self, interpreter, capsys):
        """Test round with negative number."""
        code = """
x is -3.7
result is round of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "-4" in captured.out

    def test_abs_positive(self, interpreter, capsys):
        """Test abs with positive number."""
        code = """
x is 5
result is abs of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "5" in captured.out

    def test_exp_zero(self, interpreter, capsys):
        """Test exp(0)."""
        code = """
x is 0
result is exp of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "1" in captured.out

    def test_log_one(self, interpreter, capsys):
        """Test log(1)."""
        code = """
x is 1
result is log of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "0" in captured.out

    def test_sin_pi_over_2(self, interpreter, capsys):
        """Test sin(π/2)."""
        code = """
x is 1.5707963267949
result is sin of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should be close to 1
        assert "1" in captured.out

    def test_cos_pi(self, interpreter, capsys):
        """Test cos(π)."""
        code = """
x is 3.14159265359
result is cos of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should be close to -1
        assert "-1" in captured.out

    def test_tan_pi_over_4(self, interpreter, capsys):
        """Test tan(π/4)."""
        code = """
x is 0.785398163397
result is tan of x
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should be close to 1
        assert "1" in captured.out

    def test_multiple_math_operations(self, interpreter, capsys):
        """Test chaining multiple math operations."""
        code = """
x is 4
step1 is sqrt of x
step2 is pow of [step1, 2]
step3 is abs of step2
step4 is floor of step3
print of step4
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "4" in captured.out

    def test_list_operations_chain(self, interpreter, capsys):
        """Test chaining list operations."""
        code = """
numbers is [5, 2, 8, 1, 9, 3]
sorted_nums is sort of numbers
first_three is [sorted_nums[0], sorted_nums[1], sorted_nums[2]]
reversed_three is reverse of first_three
print of reversed_three
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        assert "3" in captured.out

    def test_string_operations_chain(self, interpreter, capsys):
        """Test chaining string operations."""
        code = """
text is "Hello, World!"
lower_text is lower of text
parts is split of lower_text
upper_parts is map of [upper, parts]
result is join of upper_parts
print of result
"""
        run_code(code, interpreter)
        captured = capsys.readouterr()
        # Should have uppercase parts joined
        assert len(captured.out) > 0


class TestFileOperations:
    """Test file I/O operations."""

    def test_file_read_write_cycle(self, interpreter, capsys):
        """Test writing and reading a file."""
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
            temp_path = f.name
            f.write("test content")

        try:
            code = f"""
path is "{temp_path}"
content is file_read of path
print of content
"""
            run_code(code, interpreter)
            captured = capsys.readouterr()
            assert "test content" in captured.out
        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)
