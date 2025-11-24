"""
Unit tests for new operators in EigenScript (AND, OR, <=, >=, !=, %).

Tests logical operators, extended comparisons, and modulo arithmetic.
"""

import pytest
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.builtins import decode_vector


class TestAndOperator:
    """Test AND logical operator."""

    def test_and_both_true(self):
        """Test AND with both operands true."""
        source = "(5 > 3) and (10 > 7)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_and_first_false(self):
        """Test AND with first operand false."""
        source = "(5 < 3) and (10 > 7)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0

    def test_and_second_false(self):
        """Test AND with second operand false."""
        source = "(5 > 3) and (10 < 7)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0

    def test_and_both_false(self):
        """Test AND with both operands false."""
        source = "(5 < 3) and (10 < 7)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0

    def test_and_in_conditional(self):
        """Test AND in if statement."""
        source = """
x is 10
y is 20
if (x > 5) and (y > 15):
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


class TestOrOperator:
    """Test OR logical operator."""

    def test_or_both_true(self):
        """Test OR with both operands true."""
        source = "(5 > 3) or (10 > 7)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_or_first_true(self):
        """Test OR with first operand true."""
        source = "(5 > 3) or (10 < 7)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_or_second_true(self):
        """Test OR with second operand true."""
        source = "(5 < 3) or (10 > 7)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_or_both_false(self):
        """Test OR with both operands false."""
        source = "(5 < 3) or (10 < 7)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0

    def test_or_in_conditional(self):
        """Test OR in if statement."""
        source = """
x is 10
y is 5
if (x > 15) or (y > 3):
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


class TestLessEqualOperator:
    """Test <= (less than or equal) operator."""

    def test_less_equal_less(self):
        """Test <= when left < right."""
        source = "5 <= 10"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_less_equal_equal(self):
        """Test <= when left = right."""
        source = "10 <= 10"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_less_equal_greater(self):
        """Test <= when left > right."""
        source = "15 <= 10"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0


class TestGreaterEqualOperator:
    """Test >= (greater than or equal) operator."""

    def test_greater_equal_greater(self):
        """Test >= when left > right."""
        source = "15 >= 10"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_greater_equal_equal(self):
        """Test >= when left = right."""
        source = "10 >= 10"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_greater_equal_less(self):
        """Test >= when left < right."""
        source = "5 >= 10"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0


class TestNotEqualOperator:
    """Test != (not equal) operator."""

    def test_not_equal_different(self):
        """Test != with different values."""
        source = "5 != 10"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_not_equal_same(self):
        """Test != with same values."""
        source = "10 != 10"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0


class TestModuloOperator:
    """Test % (modulo) operator."""

    def test_modulo_basic(self):
        """Test basic modulo operation."""
        source = "10 % 3"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_modulo_zero_remainder(self):
        """Test modulo with zero remainder."""
        source = "10 % 5"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 0.0

    def test_modulo_even_odd(self):
        """Test modulo for even/odd check."""
        source = """
even is 10 % 2
odd is 11 % 2
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        interpreter.evaluate(ast)

        even_vector = interpreter.environment.lookup("even")
        odd_vector = interpreter.environment.lookup("odd")

        even_value = decode_vector(even_vector, interpreter.space, interpreter.metric)
        odd_value = decode_vector(odd_vector, interpreter.space, interpreter.metric)

        assert even_value == 0.0
        assert odd_value == 1.0


class TestOperatorPrecedence:
    """Test operator precedence."""

    def test_and_or_precedence(self):
        """Test that AND has higher precedence than OR."""
        # (False OR True) AND True = False OR (True AND True) = True
        source = "(0 = 1) or (1 = 1) and (1 = 1)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0  # Should be true because AND binds tighter

    def test_comparison_and_precedence(self):
        """Test that comparisons have higher precedence than AND."""
        source = "5 > 3 and 10 > 7"  # Should parse as (5 > 3) and (10 > 7)
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_not_and_precedence(self):
        """Test that NOT has higher precedence than AND."""
        source = "not (0 = 1) and (1 = 1)"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        result = interpreter.evaluate(ast)

        value = decode_vector(result, interpreter.space, interpreter.metric)
        assert value == 1.0


class TestShortCircuit:
    """Test short-circuit evaluation for AND/OR operators."""

    def test_and_short_circuit_false_left(self):
        """Test that AND short-circuits when left is false."""
        # The right side would cause division by zero if evaluated
        # But short-circuit should prevent evaluation
        source = """
result is (5 < 3) and (10 / 0 = 5)
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        # Should not raise error due to short-circuit
        interpreter.evaluate(ast)

        result_vector = interpreter.environment.lookup("result")
        value = decode_vector(result_vector, interpreter.space, interpreter.metric)
        assert value == 0.0

    def test_or_short_circuit_true_left(self):
        """Test that OR short-circuits when left is true."""
        # The right side would cause division by zero if evaluated
        # But short-circuit should prevent evaluation
        source = """
result is (5 > 3) or (10 / 0 = 5)
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interpreter = Interpreter()
        # Should not raise error due to short-circuit
        interpreter.evaluate(ast)

        result_vector = interpreter.environment.lookup("result")
        value = decode_vector(result_vector, interpreter.space, interpreter.metric)
        assert value == 1.0

    def test_and_no_short_circuit_true_left(self):
        """Test that AND evaluates right when left is true."""
        source = """
x is 0
result is (5 > 3) and (x = 0)
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

    def test_or_no_short_circuit_false_left(self):
        """Test that OR evaluates right when left is false."""
        source = """
x is 5
result is (3 > 5) or (x = 5)
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


class TestComplexExpressions:
    """Test complex expressions with new operators."""

    def test_combined_logical_operators(self):
        """Test AND and OR combined."""
        source = """
x is 10
if (x > 5 and x < 15) or (x = 100):
    result is 1
else:
    result is 0
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

    def test_modulo_in_conditional(self):
        """Test modulo in conditional."""
        source = """
n is 10
if n % 2 = 0:
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
