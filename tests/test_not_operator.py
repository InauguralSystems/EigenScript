"""
Unit tests for the NOT operator in EigenScript.

Tests logical negation with comparisons, predicates, and nested operations.
"""

import pytest
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.builtins import decode_vector


class TestNotOperator:
    """Test NOT operator basic functionality."""

    def test_not_true(self):
        """Test not of true value."""
        source = "not (5 = 5)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0

    def test_not_false(self):
        """Test not of false value."""
        source = "not (5 = 10)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_not_with_less_than(self):
        """Test not with less than comparison."""
        source = "not (10 < 5)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_not_with_greater_than(self):
        """Test not with greater than comparison."""
        source = "not (10 > 5)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0


class TestNotInConditionals:
    """Test NOT operator in if-then-else statements."""

    def test_not_in_if_true_branch(self):
        """Test not in if causing true branch."""
        source = """
x is 10
if not (x = 5):
    result is 100
else:
    result is 200
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result_vector = interpreter.environment.lookup("result")
        value = decode_vector(result_vector, interpreter.space, interpreter.metric)
        assert value == 100

    def test_not_in_if_false_branch(self):
        """Test not in if causing false branch."""
        source = """
x is 5
if not (x = 5):
    result is 100
else:
    result is 200
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result_vector = interpreter.environment.lookup("result")
        value = decode_vector(result_vector, interpreter.space, interpreter.metric)
        assert value == 200


class TestDoubleNegation:
    """Test double negation (not not x = x)."""

    def test_not_not_true(self):
        """Test not not of true value."""
        source = "not not (5 = 5)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_not_not_false(self):
        """Test not not of false value."""
        source = "not not (5 = 10)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0


class TestNotWithLists:
    """Test NOT operator with list operations."""

    def test_not_with_list_length(self):
        """Test not with list length comparison."""
        source = """
numbers is [1, 2, 3, 4, 5]
not (len of numbers = 3)
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_not_with_list_indexing(self):
        """Test not with list element comparison."""
        source = """
values is [10, 20, 30]
not (values[0] = 20)
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0


class TestNotComplexExpressions:
    """Test NOT operator with complex boolean expressions."""

    def test_not_with_variable(self):
        """Test not with variable comparison."""
        source = """
x is 42
result is not (x = 100)
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result_vector = interpreter.environment.lookup("result")
        value = decode_vector(result_vector, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_not_in_loop_condition(self):
        """Test not in loop condition."""
        source = """
i is 0
count is 0
loop while not (i > 2):
    count is count + 1
    i is i + 1
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        count_vector = interpreter.environment.lookup("count")
        value = decode_vector(count_vector, interpreter.space, interpreter.metric)
        assert value == 3
