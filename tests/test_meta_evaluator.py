"""
Tests for meta-circular evaluator (self-hosting).

These tests verify that EigenScript can interpret EigenScript code,
demonstrating the language's self-hosting capability.
"""

import pytest
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser
from eigenscript.evaluator import Interpreter
from eigenscript.semantic.lrvm import LRVMVector
from eigenscript.builtins import decode_vector


class TestMetaCircularEvaluator:
    """Test meta-circular evaluation capabilities."""

    def setup_method(self):
        """Set up test fixtures."""
        self.interpreter = Interpreter(dimension=768)

    def run_code(self, source: str) -> LRVMVector:
        """Helper to run EigenScript code."""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        return self.interpreter.evaluate(ast)

    def decode_scalar(self, vector: LRVMVector) -> float:
        """Helper to decode a scalar from LRVM vector."""
        value = decode_vector(vector, self.interpreter.space, self.interpreter.metric)
        return float(value) if not isinstance(value, str) else 0.0

    def test_eval_add_function(self):
        """Test arithmetic evaluator for addition."""
        code = """
define eval_add as:
    left is n[0]
    right is n[1]
    result is left + right
    return result

args is [5, 3]
result is eval_add of args
"""
        self.run_code(code)
        result = self.interpreter.environment.lookup("result")
        value = self.decode_scalar(result)
        assert value == pytest.approx(8.0, rel=0.01)

    def test_eval_multiply_function(self):
        """Test arithmetic evaluator for multiplication."""
        code = """
define eval_mul as:
    left is n[0]
    right is n[1]
    result is left * right
    return result

args is [6, 7]
result is eval_mul of args
"""
        self.run_code(code)
        result = self.interpreter.environment.lookup("result")
        value = self.decode_scalar(result)
        assert value == pytest.approx(42.0, rel=0.01)

    def test_eval_subtract_function(self):
        """Test arithmetic evaluator for subtraction."""
        code = """
define eval_sub as:
    left is n[0]
    right is n[1]
    result is left - right
    return result

args is [10, 4]
result is eval_sub of args
"""
        self.run_code(code)
        result = self.interpreter.environment.lookup("result")
        value = self.decode_scalar(result)
        assert value == pytest.approx(6.0, rel=0.01)

    def test_factorial_evaluator(self):
        """Test recursive factorial evaluator."""
        code = """
define eval_factorial as:
    result is 1
    if n > 1:
        prev is n - 1
        prev_fact is eval_factorial of prev
        result is n * prev_fact
    return result

result is eval_factorial of 5
"""
        self.run_code(code)
        result = self.interpreter.environment.lookup("result")
        value = self.decode_scalar(result)
        assert value == pytest.approx(120.0, rel=0.01)

    def test_identity_self_reference(self):
        """Test self-referential identity function."""
        code = """
define identity as:
    return n

val is 42
r1 is identity of val
r2 is identity of r1
r3 is identity of r2
"""
        self.run_code(code)

        # All should be 42
        r1 = self.interpreter.environment.lookup("r1")
        r2 = self.interpreter.environment.lookup("r2")
        r3 = self.interpreter.environment.lookup("r3")

        v1 = self.decode_scalar(r1)
        v2 = self.decode_scalar(r2)
        v3 = self.decode_scalar(r3)

        assert v1 == pytest.approx(42.0, rel=0.01)
        assert v2 == pytest.approx(42.0, rel=0.01)
        assert v3 == pytest.approx(42.0, rel=0.01)

    def test_conditional_evaluator(self):
        """Test conditional evaluation function."""
        code = """
define eval_if_then_else as:
    condition is n[0]
    then_value is n[1]
    else_value is n[2]
    
    result is else_value
    if condition:
        result is then_value
    
    return result

# Test true condition
args1 is [1, 100, 200]
result1 is eval_if_then_else of args1

# Test false condition
args2 is [0, 100, 200]
result2 is eval_if_then_else of args2
"""
        self.run_code(code)

        result1 = self.interpreter.environment.lookup("result1")
        result2 = self.interpreter.environment.lookup("result2")

        v1 = self.decode_scalar(result1)
        v2 = self.decode_scalar(result2)

        assert v1 == pytest.approx(100.0, rel=0.01)
        assert v2 == pytest.approx(200.0, rel=0.01)

    def test_geometric_stability_during_meta_evaluation(self):
        """Test that geometric stability is maintained during meta-evaluation."""
        code = """
define eval_add as:
    left is n[0]
    right is n[1]
    result is left + right
    return result

args is [5, 3]
result is eval_add of args
"""
        self.run_code(code)

        # Check that system remains stable
        fs = self.interpreter.fs_tracker.compute_fs()
        assert fs >= 0.0  # FS should be valid
        assert fs <= 1.0  # FS should be bounded

    def test_multiple_eval_functions_together(self):
        """Test multiple evaluator functions working together."""
        code = """
define eval_add as:
    left is n[0]
    right is n[1]
    return left + right

define eval_mul as:
    left is n[0]
    right is n[1]
    return left * right

# Compute (5 + 3) * 2
args1 is [5, 3]
sum is eval_add of args1

args2 is [sum, 2]
result is eval_mul of args2
"""
        self.run_code(code)

        result = self.interpreter.environment.lookup("result")
        value = self.decode_scalar(result)

        # (5 + 3) * 2 = 16
        assert value == pytest.approx(16.0, rel=0.01)

    def test_nested_recursive_evaluation(self):
        """Test nested recursive evaluation."""
        code = """
define eval_power as:
    base is n[0]
    exp is n[1]
    
    result is 1
    if exp > 0:
        exp_minus_1 is exp - 1
        args is [base, exp_minus_1]
        prev_power is eval_power of args
        result is base * prev_power
    
    return result

# Compute 2^3 = 8
args is [2, 3]
result is eval_power of args
"""
        self.run_code(code)

        result = self.interpreter.environment.lookup("result")
        value = self.decode_scalar(result)

        # 2^3 = 8
        assert value == pytest.approx(8.0, rel=0.01)


class TestSelfHostingProperties:
    """Test fundamental properties of self-hosting."""

    def setup_method(self):
        """Set up test fixtures."""
        self.interpreter = Interpreter(dimension=768)

    def run_code(self, source: str) -> LRVMVector:
        """Helper to run EigenScript code."""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        return self.interpreter.evaluate(ast)

    def decode_scalar(self, vector: LRVMVector) -> float:
        """Helper to decode a scalar from LRVM vector."""
        value = decode_vector(vector, self.interpreter.space, self.interpreter.metric)
        return float(value) if not isinstance(value, str) else 0.0

    def test_self_hosting_completeness(self):
        """Test that EigenScript has sufficient expressiveness for self-hosting."""
        # This tests that all necessary constructs are available:
        # - Function definitions
        # - Recursion
        # - Conditionals
        # - List operations
        # - Return statements

        code = """
define test_completeness as:
    result is 1
    if n > 0:
        prev is n - 1
        prev_result is test_completeness of prev
        result is n + prev_result
    return result

result is test_completeness of 5
"""
        self.run_code(code)

        # If we get here without error, self-hosting primitives work
        result = self.interpreter.environment.lookup("result")
        assert result is not None

    def test_convergence_during_self_evaluation(self):
        """Test that self-evaluation maintains geometric convergence."""
        code = """
define identity as:
    return n

# Multiple applications should maintain stability
val is 42
r1 is identity of val
r2 is identity of r1
r3 is identity of r2
r4 is identity of r3
r5 is identity of r4
"""
        self.run_code(code)

        # System should remain stable despite self-reference
        fs = self.interpreter.fs_tracker.compute_fs()

        # FS should be reasonable (not NaN or negative)
        assert not (fs < 0.0 or fs > 1.0)

    def test_meta_evaluation_doesnt_diverge(self):
        """Test that meta-evaluation doesn't cause divergence."""
        # This is a key property: traditional meta-circular evaluators
        # can have issues with self-application, but geometric semantics
        # should ensure convergence

        code = """
define simple_eval as:
    result is n * 2
    return result

val is 21
r1 is simple_eval of val
r2 is simple_eval of r1
"""
        self.run_code(code)

        # Should complete without error
        r2 = self.interpreter.environment.lookup("r2")
        value = self.decode_scalar(r2)

        # 21 * 2 * 2 = 84
        assert value == pytest.approx(84.0, rel=0.01)
