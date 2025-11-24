"""
Tests for list mutation operations (append, pop).
"""

import pytest
from eigenscript.lexer.tokenizer import Tokenizer
from eigenscript.parser.ast_builder import Parser
from eigenscript.evaluator.interpreter import Interpreter, EigenList
from eigenscript.builtins import decode_vector


class TestAppendOperation:
    """Test list append operation."""

    def test_append_single_element(self):
        """Test appending a single element to a list."""
        source = """
my_list is [1, 2, 3]
append of [my_list, 4]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("my_list")
        assert isinstance(result, EigenList)
        assert len(result) == 4

        # Check values
        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == [1.0, 2.0, 3.0, 4.0]

    def test_append_to_empty_list(self):
        """Test appending to an empty list."""
        source = """
my_list is []
append of [my_list, 42]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("my_list")
        assert isinstance(result, EigenList)
        assert len(result) == 1

        value = decode_vector(result.elements[0], interpreter.space, interpreter.metric)
        assert value == 42.0

    def test_append_multiple_times(self):
        """Test appending multiple elements."""
        source = """
my_list is [1]
append of [my_list, 2]
append of [my_list, 3]
append of [my_list, 4]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("my_list")
        assert isinstance(result, EigenList)
        assert len(result) == 4

        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == [1.0, 2.0, 3.0, 4.0]

    def test_append_string_to_list(self):
        """Test appending a string to a list."""
        source = """
my_list is ["hello"]
append of [my_list, "world"]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("my_list")
        assert isinstance(result, EigenList)
        assert len(result) == 2

        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == ["hello", "world"]


class TestPopOperation:
    """Test list pop operation."""

    def test_pop_single_element(self):
        """Test popping from a list with one element."""
        source = """
my_list is [42]
result is pop of my_list
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        # Check the popped value
        result = interpreter.environment.lookup("result")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 42.0

        # Check the list is now empty
        my_list = interpreter.environment.lookup("my_list")
        assert isinstance(my_list, EigenList)
        assert len(my_list) == 0

    def test_pop_from_multiple_elements(self):
        """Test popping from a list with multiple elements."""
        source = """
my_list is [1, 2, 3, 4, 5]
last is pop of my_list
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        # Check the popped value
        result = interpreter.environment.lookup("last")
        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 5.0

        # Check the list has 4 elements left
        my_list = interpreter.environment.lookup("my_list")
        assert isinstance(my_list, EigenList)
        assert len(my_list) == 4

        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in my_list.elements
        ]
        assert values == [1.0, 2.0, 3.0, 4.0]

    def test_pop_multiple_times(self):
        """Test popping multiple times."""
        source = """
my_list is [10, 20, 30]
a is pop of my_list
b is pop of my_list
c is pop of my_list
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        # Check the popped values (LIFO order)
        a = decode_vector(
            interpreter.environment.lookup("a"), interpreter.space, interpreter.metric
        )
        b = decode_vector(
            interpreter.environment.lookup("b"), interpreter.space, interpreter.metric
        )
        c = decode_vector(
            interpreter.environment.lookup("c"), interpreter.space, interpreter.metric
        )

        assert a == 30.0
        assert b == 20.0
        assert c == 10.0

        # List should be empty
        my_list = interpreter.environment.lookup("my_list")
        assert len(my_list) == 0

    def test_pop_from_empty_list_fails(self):
        """Test that popping from an empty list raises an error."""
        source = """
my_list is []
result is pop of my_list
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()

        with pytest.raises(RuntimeError, match="Cannot pop from empty list"):
            interpreter.evaluate(ast)


class TestMinMaxOperations:
    """Test min and max built-in functions."""

    def test_min_of_numbers(self):
        """Test finding minimum in a list of numbers."""
        source = """
numbers is [5, 2, 8, 1, 9]
result is min of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = decode_vector(
            interpreter.environment.lookup("result"),
            interpreter.space,
            interpreter.metric,
        )
        assert result == 1.0

    def test_max_of_numbers(self):
        """Test finding maximum in a list of numbers."""
        source = """
numbers is [5, 2, 8, 1, 9]
result is max of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = decode_vector(
            interpreter.environment.lookup("result"),
            interpreter.space,
            interpreter.metric,
        )
        assert result == 9.0

    def test_min_of_single_element(self):
        """Test min with a single element list."""
        source = """
numbers is [42]
result is min of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = decode_vector(
            interpreter.environment.lookup("result"),
            interpreter.space,
            interpreter.metric,
        )
        assert result == 42.0

    def test_max_of_single_element(self):
        """Test max with a single element list."""
        source = """
numbers is [42]
result is max of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = decode_vector(
            interpreter.environment.lookup("result"),
            interpreter.space,
            interpreter.metric,
        )
        assert result == 42.0

    def test_min_max_with_negative_numbers(self):
        """Test min and max with negative numbers."""
        source = """
numbers is [-5, -2, -8, -1, -9]
min_result is min of numbers
max_result is max of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        min_result = decode_vector(
            interpreter.environment.lookup("min_result"),
            interpreter.space,
            interpreter.metric,
        )
        max_result = decode_vector(
            interpreter.environment.lookup("max_result"),
            interpreter.space,
            interpreter.metric,
        )

        assert min_result == -9.0
        assert max_result == -1.0

    def test_min_of_empty_list_fails(self):
        """Test that min of empty list raises an error."""
        source = """
numbers is []
result is min of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()

        with pytest.raises(ValueError, match="min of empty list is undefined"):
            interpreter.evaluate(ast)

    def test_max_of_empty_list_fails(self):
        """Test that max of empty list raises an error."""
        source = """
numbers is []
result is max of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()

        with pytest.raises(ValueError, match="max of empty list is undefined"):
            interpreter.evaluate(ast)


class TestSortOperation:
    """Test sort built-in function."""

    def test_sort_numbers(self):
        """Test sorting a list of numbers."""
        source = """
numbers is [5, 2, 8, 1, 9, 3]
sorted_numbers is sort of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("sorted_numbers")
        assert isinstance(result, EigenList)

        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == [1.0, 2.0, 3.0, 5.0, 8.0, 9.0]

    def test_sort_empty_list(self):
        """Test sorting an empty list."""
        source = """
empty is []
sorted_empty is sort of empty
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("sorted_empty")
        assert isinstance(result, EigenList)
        assert len(result) == 0

    def test_sort_single_element(self):
        """Test sorting a single element list."""
        source = """
single is [42]
sorted_single is sort of single
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("sorted_single")
        assert isinstance(result, EigenList)
        assert len(result) == 1

        value = decode_vector(result.elements[0], interpreter.space, interpreter.metric)
        assert value == 42.0

    def test_sort_negative_numbers(self):
        """Test sorting list with negative numbers."""
        source = """
numbers is [-5, 2, -8, 1, -9, 3]
sorted_numbers is sort of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("sorted_numbers")
        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == [-9.0, -8.0, -5.0, 1.0, 2.0, 3.0]

    def test_sort_already_sorted(self):
        """Test sorting an already sorted list."""
        source = """
numbers is [1, 2, 3, 4, 5]
sorted_numbers is sort of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("sorted_numbers")
        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == [1.0, 2.0, 3.0, 4.0, 5.0]

    def test_sort_reverse_order(self):
        """Test sorting a reverse-sorted list."""
        source = """
numbers is [5, 4, 3, 2, 1]
sorted_numbers is sort of numbers
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.lookup("sorted_numbers")
        values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in result.elements
        ]
        assert values == [1.0, 2.0, 3.0, 4.0, 5.0]

    def test_sort_does_not_mutate_original(self):
        """Test that sort returns a new list without mutating the original."""
        source = """
original is [3, 1, 2]
sorted_list is sort of original
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        # Check original list is unchanged
        original = interpreter.environment.lookup("original")
        original_values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in original.elements
        ]
        assert original_values == [3.0, 1.0, 2.0]

        # Check sorted list is correct
        sorted_list = interpreter.environment.lookup("sorted_list")
        sorted_values = [
            decode_vector(elem, interpreter.space, interpreter.metric)
            for elem in sorted_list.elements
        ]
        assert sorted_values == [1.0, 2.0, 3.0]


class TestAppendPopCombined:
    """Test append and pop operations together."""

    def test_append_then_pop(self):
        """Test appending and then popping."""
        source = """
my_list is [1, 2]
append of [my_list, 3]
result is pop of my_list
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        # Popped value should be 3
        result = decode_vector(
            interpreter.environment.lookup("result"),
            interpreter.space,
            interpreter.metric,
        )
        assert result == 3.0

        # List should have original 2 elements
        my_list = interpreter.environment.lookup("my_list")
        assert len(my_list) == 2

    def test_stack_behavior(self):
        """Test using list as a stack (LIFO)."""
        source = """
stack is []
append of [stack, 1]
append of [stack, 2]
append of [stack, 3]
top is pop of stack
second is pop of stack
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        top = decode_vector(
            interpreter.environment.lookup("top"), interpreter.space, interpreter.metric
        )
        second = decode_vector(
            interpreter.environment.lookup("second"),
            interpreter.space,
            interpreter.metric,
        )

        assert top == 3.0
        assert second == 2.0

        stack = interpreter.environment.lookup("stack")
        assert len(stack) == 1
        value = decode_vector(stack.elements[0], interpreter.space, interpreter.metric)
        assert value == 1.0
