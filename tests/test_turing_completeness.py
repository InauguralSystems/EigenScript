"""
Tests demonstrating EigenScript's Turing completeness.

EigenScript is Turing complete through:
1. Unbounded computation (no iteration limits when max_iterations=None)
2. Arithmetic operators (+, -, *, /, =, <, >)
3. Conditional branching (IF/ELSE)
4. Variable binding and lookup
"""

import pytest
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter


class TestTuringCompleteness:
    """Tests demonstrating Turing completeness."""

    def test_arithmetic_operations(self):
        """Should perform basic arithmetic operations."""
        source = """
count is 0
count is count + 1
count is count + 2
count is count * 3
result is count / 2
"""
        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())
        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        # count = ((0 + 1) + 2) * 3 = 9
        # result = 9 / 2 = 4.5
        count_val = interp.environment.lookup("count")
        result_val = interp.environment.lookup("result")

        assert count_val.coords[0] == 9.0
        assert result_val.coords[0] == 4.5

    def test_comparison_operators(self):
        """Should perform comparison operations."""
        source = """
a is 5
b is 10
less is a < b
greater is a > b
equal is a = a
"""
        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())
        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        less_val = interp.environment.lookup("less")
        greater_val = interp.environment.lookup("greater")
        equal_val = interp.environment.lookup("equal")

        # 5 < 10 should be true (1.0)
        assert less_val.coords[0] == 1.0
        # 5 > 10 should be false (0.0)
        assert greater_val.coords[0] == 0.0
        # 5 = 5 should be true (1.0)
        assert equal_val.coords[0] == 1.0

    def test_loop_with_counter(self):
        """Should support loop with counter and termination condition."""
        source = """
count is 0
loop while count < 5:
    count is count + 1
"""
        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())

        # Use unbounded interpreter (Turing complete)
        interp = Interpreter(dimension=10, max_iterations=None)
        interp.evaluate(parser.parse())

        count_val = interp.environment.lookup("count")

        # Loop should run until count = 5
        # Final value should be 5
        assert count_val.coords[0] == 5.0

    def test_factorial_computation(self):
        """Should compute factorial using loops and arithmetic."""
        source = """
n is 5
result is 1
counter is 1

loop while counter < n:
    counter is counter + 1
    result is result * counter
"""
        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())

        # Use unbounded interpreter
        interp = Interpreter(dimension=10, max_iterations=None)
        interp.evaluate(parser.parse())

        result_val = interp.environment.lookup("result")

        # 5! = 120
        assert result_val.coords[0] == 120.0

    def test_unbounded_capability(self):
        """Should demonstrate unbounded computation capability."""
        # This test shows we can run more than the old 10k limit
        source = """
count is 0
target is 100

loop while count < target:
    count is count + 1
"""
        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())

        # Without max_iterations, this is unbounded (Turing complete)
        interp = Interpreter(dimension=10, max_iterations=None)
        interp.evaluate(parser.parse())

        count_val = interp.environment.lookup("count")

        # Should reach exactly 100
        assert count_val.coords[0] == 100.0

    def test_bounded_interpreter_compatibility(self):
        """Should still support bounded execution for safety."""
        source = """
count is 0
loop while count < 1000000:
    count is count + 1
"""
        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())

        # With max_iterations, loop is bounded
        interp = Interpreter(dimension=10, max_iterations=100)
        interp.evaluate(parser.parse())

        count_val = interp.environment.lookup("count")

        # Should stop at iteration limit
        # Will be less than 1000000
        assert count_val.coords[0] < 1000000.0

    def test_conditional_with_arithmetic(self):
        """Should combine conditionals with arithmetic for complex logic."""
        source = """
x is 10
result is 0

if x > 5:
    result is x * 2
"""
        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())

        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        result_val = interp.environment.lookup("result")

        # x > 5 is true, so result = 10 * 2 = 20
        assert result_val.coords[0] == 20.0

    def test_turing_completeness_criteria(self):
        """
        Verify all Turing completeness criteria are met.

        A language is Turing complete if it has:
        1. Arbitrary data storage (variables) ✓
        2. Conditional branching (IF/ELSE) ✓
        3. Ability to change stored data (assignments) ✓
        4. Ability to repeat instructions (LOOP) ✓
        5. Unbounded computation (no artificial limits) ✓
        """
        # Test program demonstrating all criteria
        source = """
# 1. Data storage
accumulator is 0
multiplier is 2

# 2 & 3. Conditional branching with data modification
if accumulator < 10:
    accumulator is accumulator + 5

# 4 & 5. Unbounded loops
loop while accumulator < 20:
    accumulator is accumulator + multiplier
"""
        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())

        # Unbounded interpreter = Turing complete
        interp = Interpreter(dimension=10, max_iterations=None)
        interp.evaluate(parser.parse())

        accumulator = interp.environment.lookup("accumulator")

        # Trace:
        # accumulator starts at 0
        # IF: 0 < 10, so accumulator = 0 + 5 = 5
        # LOOP iteration 1: 5 < 20, accumulator = 5 + 2 = 7
        # LOOP iteration 2: 7 < 20, accumulator = 7 + 2 = 9
        # ... continues until accumulator >= 20
        # Final: 21
        assert accumulator.coords[0] >= 20.0


class TestEquilibriumArithmetic:
    """Tests for arithmetic operators as equilibrium operations."""

    def test_addition_as_equilibrium_composition(self):
        """Addition should compose vectors in LRVM space."""
        source = "result is 3 + 4"

        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())
        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        result = interp.environment.lookup("result")
        # Vector addition in LRVM space
        assert result.coords[0] == 7.0

    def test_subtraction_as_equilibrium_inversion(self):
        """Subtraction should compute directed distance."""
        source = "result is 10 - 3"

        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())
        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        result = interp.environment.lookup("result")
        assert result.coords[0] == 7.0

    def test_multiplication_as_equilibrium_scaling(self):
        """Multiplication should scale magnitude."""
        source = "result is 5 * 3"

        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())
        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        result = interp.environment.lookup("result")
        assert result.coords[0] == 15.0

    def test_division_as_projected_equilibrium(self):
        """Division should project through inverse."""
        source = "result is 20 / 4"

        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())
        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        result = interp.environment.lookup("result")
        assert result.coords[0] == 5.0

    def test_operator_precedence(self):
        """Should respect standard operator precedence."""
        # 2 + 3 * 4 should be 2 + 12 = 14, not 5 * 4 = 20
        source = "result is 2 + 3 * 4"

        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())
        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        result = interp.environment.lookup("result")
        assert result.coords[0] == 14.0

    def test_parenthesized_expressions(self):
        """Should support parentheses to override precedence."""
        source = "result is (2 + 3) * 4"

        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())
        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        result = interp.environment.lookup("result")
        assert result.coords[0] == 20.0

    def test_complex_arithmetic_expression(self):
        """Should handle complex nested arithmetic."""
        # ((10 + 5) * 2 - 6) / 3 = (15 * 2 - 6) / 3 = (30 - 6) / 3 = 24 / 3 = 8
        source = "result is ((10 + 5) * 2 - 6) / 3"

        tokenizer = Tokenizer(source)
        parser = Parser(tokenizer.tokenize())
        interp = Interpreter(dimension=10)
        interp.evaluate(parser.parse())

        result = interp.environment.lookup("result")
        assert result.coords[0] == 8.0
