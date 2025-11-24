"""
Tests for mathematical built-in functions.

These tests verify that EigenScript provides comprehensive
mathematical operations for scientific and engineering use cases.
"""

import math
import pytest
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.builtins import decode_vector


class TestBasicMath:
    """Test basic mathematical operations."""

    def test_sqrt(self):
        """Test square root function."""
        source = """
result is sqrt of 16
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 4.0

    def test_sqrt_non_integer(self):
        """Test square root of non-integer."""
        source = """
result is sqrt of 2
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert abs(decoded - math.sqrt(2)) < 1e-6

    def test_abs_positive(self):
        """Test absolute value of positive number."""
        source = """
result is abs of 5
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 5

    def test_abs_negative(self):
        """Test absolute value of negative number."""
        source = """
result is abs of -5
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 5

    def test_pow(self):
        """Test power function."""
        source = """
result is pow of [2, 3]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 8.0

    def test_pow_square(self):
        """Test power function for squaring."""
        source = """
result is pow of [10, 2]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 100.0


class TestExponentialLogarithmic:
    """Test exponential and logarithmic functions."""

    def test_log(self):
        """Test natural logarithm."""
        source = """
result is log of 2.718281828
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert abs(decoded - 1.0) < 1e-6

    def test_exp(self):
        """Test exponential function."""
        source = """
result is exp of 1
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert abs(decoded - math.e) < 1e-6

    def test_exp_zero(self):
        """Test exp(0) = 1."""
        source = """
result is exp of 0
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert abs(decoded - 1.0) < 1e-6


class TestTrigonometric:
    """Test trigonometric functions."""

    def test_sin_zero(self):
        """Test sin(0) = 0."""
        source = """
result is sin of 0
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert abs(decoded) < 1e-9

    def test_cos_zero(self):
        """Test cos(0) = 1."""
        source = """
result is cos of 0
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert abs(decoded - 1.0) < 1e-9

    def test_tan_zero(self):
        """Test tan(0) = 0."""
        source = """
result is tan of 0
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert abs(decoded) < 1e-9


class TestRounding:
    """Test rounding functions."""

    def test_floor_positive(self):
        """Test floor of positive number."""
        source = """
result is floor of 3.7
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 3.0

    def test_floor_negative(self):
        """Test floor of negative number."""
        source = """
result is floor of -2.3
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == -3.0

    def test_ceil_positive(self):
        """Test ceiling of positive number."""
        source = """
result is ceil of 3.2
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 4.0

    def test_ceil_negative(self):
        """Test ceiling of negative number."""
        source = """
result is ceil of -2.7
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == -2.0

    def test_round_up(self):
        """Test rounding up."""
        source = """
result is round of 3.5
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 4.0

    def test_round_down(self):
        """Test rounding down."""
        source = """
result is round of 3.4
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 3.0


class TestMathCompositions:
    """Test composing math functions together."""

    def test_sqrt_of_pow(self):
        """Test sqrt(pow(x, 2)) = x."""
        source = """
squared is pow of [5, 2]
result is sqrt of squared
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert abs(decoded - 5.0) < 1e-6

    def test_log_of_exp(self):
        """Test log(exp(x)) = x."""
        source = """
e_to_3 is exp of 3
result is log of e_to_3
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert abs(decoded - 3.0) < 1e-6

    def test_abs_of_negative_sqrt(self):
        """Test abs can be used with computed values."""
        source = """
x is 0 - 4
result is abs of x
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        interpreter = Interpreter()
        interpreter.evaluate(ast)

        result = interpreter.environment.bindings["result"]
        decoded = decode_vector(result, interpreter.space, interpreter.metric)
        assert decoded == 4.0
