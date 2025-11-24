"""
Unit tests for list comprehensions in EigenScript.

Tests the Phase 4 - Option B implementation of list comprehensions,
which allow concise transformation and filtering of lists.
"""

import pytest
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator.interpreter import Interpreter, EigenList


class TestBasicListComprehensions:
    """Tests for basic list comprehension functionality."""

    @pytest.fixture
    def interpreter(self):
        return Interpreter()

    def test_simple_comprehension(self, interpreter):
        """Test basic list comprehension without filter."""
        code = """
numbers is [1, 2, 3, 4, 5]
doubled is [x * 2 for x in numbers]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        result = interpreter.evaluate(ast)

        doubled = interpreter.environment.lookup("doubled")
        assert isinstance(doubled, EigenList)
        assert len(doubled.elements) == 5

        # Check each element is doubled
        for i, elem in enumerate(doubled.elements):
            expected = (i + 1) * 2
            assert abs(elem.coords[0] - expected) < 1e-6

    def test_identity_comprehension(self, interpreter):
        """Test comprehension that just copies elements."""
        code = """
numbers is [1, 2, 3]
copied is [x for x in numbers]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        copied = interpreter.environment.lookup("copied")
        assert isinstance(copied, EigenList)
        assert len(copied.elements) == 3

    def test_empty_list_comprehension(self, interpreter):
        """Test comprehension over empty list."""
        code = """
empty is []
result is [x * 2 for x in empty]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        assert isinstance(result, EigenList)
        assert len(result.elements) == 0


class TestComprehensionsWithFilters:
    """Tests for list comprehensions with filter conditions."""

    @pytest.fixture
    def interpreter(self):
        return Interpreter()

    def test_filter_evens(self, interpreter):
        """Test filtering even numbers."""
        code = """
numbers is [1, 2, 3, 4, 5, 6]
evens is [x for x in numbers if x % 2 = 0]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        evens = interpreter.environment.lookup("evens")
        assert isinstance(evens, EigenList)
        assert len(evens.elements) == 3  # 2, 4, 6

        # Verify the values
        assert abs(evens.elements[0].coords[0] - 2) < 1e-6
        assert abs(evens.elements[1].coords[0] - 4) < 1e-6
        assert abs(evens.elements[2].coords[0] - 6) < 1e-6

    def test_filter_greater_than(self, interpreter):
        """Test filtering with greater than condition."""
        code = """
numbers is [1, 2, 3, 4, 5]
big is [x for x in numbers if x > 3]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        big = interpreter.environment.lookup("big")
        assert isinstance(big, EigenList)
        assert len(big.elements) == 2  # 4, 5

    def test_filter_less_than(self, interpreter):
        """Test filtering with less than condition."""
        code = """
numbers is [1, 2, 3, 4, 5]
small is [x for x in numbers if x < 3]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        small = interpreter.environment.lookup("small")
        assert isinstance(small, EigenList)
        assert len(small.elements) == 2  # 1, 2

    def test_filter_with_transformation(self, interpreter):
        """Test filter and transformation together."""
        code = """
numbers is [-2, -1, 0, 1, 2, 3]
positives_doubled is [x * 2 for x in numbers if x > 0]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("positives_doubled")
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3  # 1, 2, 3 → 2, 4, 6

        assert abs(result.elements[0].coords[0] - 2) < 1e-6
        assert abs(result.elements[1].coords[0] - 4) < 1e-6
        assert abs(result.elements[2].coords[0] - 6) < 1e-6

    def test_filter_none_match(self, interpreter):
        """Test filter where no elements match."""
        code = """
numbers is [1, 2, 3]
empty is [x for x in numbers if x > 100]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        empty = interpreter.environment.lookup("empty")
        assert isinstance(empty, EigenList)
        assert len(empty.elements) == 0

    def test_filter_all_match(self, interpreter):
        """Test filter where all elements match."""
        code = """
numbers is [1, 2, 3, 4, 5]
all is [x for x in numbers if x > 0]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        all_items = interpreter.environment.lookup("all")
        assert isinstance(all_items, EigenList)
        assert len(all_items.elements) == 5


class TestComplexComprehensions:
    """Tests for more complex comprehension scenarios."""

    @pytest.fixture
    def interpreter(self):
        return Interpreter()

    def test_comprehension_with_addition(self, interpreter):
        """Test comprehension with addition expression."""
        code = """
numbers is [1, 2, 3]
incremented is [x + 10 for x in numbers]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("incremented")
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

        assert abs(result.elements[0].coords[0] - 11) < 1e-6
        assert abs(result.elements[1].coords[0] - 12) < 1e-6
        assert abs(result.elements[2].coords[0] - 13) < 1e-6

    def test_comprehension_with_subtraction(self, interpreter):
        """Test comprehension with subtraction expression."""
        code = """
numbers is [10, 20, 30]
decremented is [x - 5 for x in numbers]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("decremented")
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

        assert abs(result.elements[0].coords[0] - 5) < 1e-6
        assert abs(result.elements[1].coords[0] - 15) < 1e-6
        assert abs(result.elements[2].coords[0] - 25) < 1e-6

    def test_comprehension_with_division(self, interpreter):
        """Test comprehension with division expression."""
        code = """
numbers is [10, 20, 30]
halved is [x / 2 for x in numbers]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("halved")
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3

        assert abs(result.elements[0].coords[0] - 5) < 1e-6
        assert abs(result.elements[1].coords[0] - 10) < 1e-6
        assert abs(result.elements[2].coords[0] - 15) < 1e-6

    def test_nested_comprehensions(self, interpreter):
        """Test using result of one comprehension in another."""
        code = """
numbers is [1, 2, 3, 4, 5]
doubled is [x * 2 for x in numbers]
evens is [x for x in doubled if x % 2 = 0]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        doubled = interpreter.environment.lookup("doubled")
        assert len(doubled.elements) == 5

        evens = interpreter.environment.lookup("evens")
        assert len(evens.elements) == 5  # All are even after doubling

    def test_comprehension_with_equality(self, interpreter):
        """Test filter using equality comparison."""
        code = """
numbers is [1, 2, 3, 2, 1]
twos is [x for x in numbers if x = 2]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("twos")
        assert isinstance(result, EigenList)
        assert len(result.elements) == 2

    def test_comprehension_with_inequality(self, interpreter):
        """Test filter using inequality comparison."""
        code = """
numbers is [1, 2, 3, 2, 1]
not_twos is [x for x in numbers if x != 2]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("not_twos")
        assert isinstance(result, EigenList)
        assert len(result.elements) == 3  # 1, 3, 1


class TestComprehensionEdgeCases:
    """Tests for edge cases and error handling."""

    @pytest.fixture
    def interpreter(self):
        return Interpreter()

    def test_comprehension_over_single_element(self, interpreter):
        """Test comprehension over list with one element."""
        code = """
numbers is [42]
result is [x * 2 for x in numbers]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("result")
        assert isinstance(result, EigenList)
        assert len(result.elements) == 1
        assert abs(result.elements[0].coords[0] - 84) < 1e-6

    def test_comprehension_variable_scope(self, interpreter):
        """Test that comprehension variable doesn't leak out."""
        code = """
numbers is [1, 2, 3]
result is [x * 2 for x in numbers]
# x should not be defined here
y is 42
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        # x should not be in the environment
        with pytest.raises(NameError, match="Undefined variable"):
            interpreter.environment.lookup("x")

        # But y should be
        y = interpreter.environment.lookup("y")
        assert abs(y.coords[0] - 42) < 1e-6

    def test_comprehension_not_list_error(self, interpreter):
        """Test error when iterating over non-list."""
        code = """
not_a_list is 42
result is [x * 2 for x in not_a_list]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()

        with pytest.raises(
            TypeError, match="List comprehension requires iterable to be a list"
        ):
            interpreter.evaluate(ast)

    def test_comprehension_complex_filter(self, interpreter):
        """Test filter with complex boolean expression."""
        code = """
numbers is [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
special is [x for x in numbers if x > 3 and x < 8]
"""
        tokens = Tokenizer(code).tokenize()
        ast = Parser(tokens).parse()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("special")
        assert isinstance(result, EigenList)
        assert len(result.elements) == 4  # 4, 5, 6, 7
