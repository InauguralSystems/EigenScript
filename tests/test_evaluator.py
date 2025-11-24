"""
Unit tests for the EigenScript evaluator/interpreter.

Tests execution of AST nodes and geometric transformations.
"""

import pytest
import numpy as np
from eigenscript.evaluator import Interpreter, Environment
from eigenscript.parser.ast_builder import *
from eigenscript.semantic.lrvm import LRVMVector
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser


class TestEnvironment:
    """Test suite for Environment class."""

    def test_environment_creation(self):
        """Should create empty environment."""
        env = Environment()
        assert len(env.bindings) == 0
        assert env.parent is None

    def test_bind_and_lookup(self):
        """Should bind and lookup variables."""
        env = Environment()
        v = LRVMVector([1.0, 2.0, 3.0])

        env.bind("x", v)
        result = env.lookup("x")

        assert result == v

    def test_lookup_undefined_variable(self):
        """Lookup of undefined variable should raise NameError."""
        env = Environment()

        with pytest.raises(NameError):
            env.lookup("undefined")

    def test_parent_environment(self):
        """Should lookup in parent if not found locally."""
        parent = Environment()
        child = Environment(parent=parent)

        v = LRVMVector([1.0, 2.0, 3.0])
        parent.bind("x", v)

        # Child should find x in parent
        result = child.lookup("x")
        assert result == v

    def test_shadowing(self):
        """Child binding should shadow parent."""
        parent = Environment()
        child = Environment(parent=parent)

        v1 = LRVMVector([1.0, 0.0, 0.0])
        v2 = LRVMVector([2.0, 0.0, 0.0])

        parent.bind("x", v1)
        child.bind("x", v2)

        # Child lookup should get child's binding
        assert child.lookup("x") == v2
        # Parent lookup should still get parent's binding
        assert parent.lookup("x") == v1


class TestInterpreter:
    """Test suite for Interpreter class."""

    def test_interpreter_creation(self):
        """Should create interpreter with default settings."""
        interp = Interpreter()
        assert interp.space.dimension == 768
        assert interp.metric.dimension == 768

    def test_interpreter_custom_dimension(self):
        """Should create interpreter with custom dimension."""
        interp = Interpreter(dimension=100)
        assert interp.space.dimension == 100
        assert interp.metric.dimension == 100

    def test_eval_literal_number(self):
        """Should evaluate number literal."""
        interp = Interpreter(dimension=10)
        lit = Literal(value=5.0, literal_type="number")

        result = interp.evaluate(lit)

        assert isinstance(result, LRVMVector)
        assert result.dimension == 10

    def test_eval_literal_string(self):
        """Should evaluate string literal."""
        interp = Interpreter(dimension=10)
        lit = Literal(value="hello", literal_type="string")

        result = interp.evaluate(lit)

        assert isinstance(result, LRVMVector)
        assert result.dimension == 10

    def test_eval_literal_null(self):
        """Should evaluate null literal as zero vector."""
        interp = Interpreter(dimension=10)
        lit = Literal(value=None, literal_type="null")

        result = interp.evaluate(lit)

        assert isinstance(result, LRVMVector)
        assert np.allclose(result.coords, np.zeros(10))

    def test_eval_assignment(self):
        """Should evaluate assignment and bind variable."""
        interp = Interpreter(dimension=10)

        # x is 5
        assign = Assignment(
            identifier="x", expression=Literal(value=5.0, literal_type="number")
        )

        interp.evaluate(assign)

        # x should now be bound in environment
        result = interp.environment.lookup("x")
        assert isinstance(result, LRVMVector)

    def test_eval_identifier(self):
        """Should evaluate identifier to bound value."""
        interp = Interpreter(dimension=10)

        # Bind x first
        v = LRVMVector(np.ones(10))
        interp.environment.bind("x", v)

        # Evaluate identifier
        ident = Identifier(name="x")
        result = interp.evaluate(ident)

        assert result == v

    def test_eval_relation(self):
        """Should evaluate OF operator via metric contraction."""
        interp = Interpreter(dimension=5)

        # Bind x and y
        x = LRVMVector([1.0, 0.0, 0.0, 0.0, 0.0])
        y = LRVMVector([2.0, 0.0, 0.0, 0.0, 0.0])
        interp.environment.bind("x", x)
        interp.environment.bind("y", y)

        # x of y
        rel = Relation(left=Identifier("x"), right=Identifier("y"))
        result = interp.evaluate(rel)

        # Result should be contraction: x^T g y = 1*2 = 2
        assert isinstance(result, LRVMVector)
        # First coordinate should have contraction value
        assert np.isclose(result.coords[0], 2.0)

    def test_eval_program_multiple_statements(self):
        """Should evaluate program with multiple statements."""
        interp = Interpreter(dimension=10)

        # Create program: x is 5; y is 10
        prog = Program(
            statements=[
                Assignment(identifier="x", expression=Literal(5.0, "number")),
                Assignment(identifier="y", expression=Literal(10.0, "number")),
            ]
        )

        interp.evaluate(prog)

        # Both should be bound
        x_val = interp.environment.lookup("x")
        y_val = interp.environment.lookup("y")

        assert isinstance(x_val, LRVMVector)
        assert isinstance(y_val, LRVMVector)

    def test_framework_strength_tracking(self):
        """Should track Framework Strength during execution."""
        interp = Interpreter(dimension=10)

        # Execute some operations
        lit1 = Literal(value=1.0, literal_type="number")
        lit2 = Literal(value=2.0, literal_type="number")

        interp.evaluate(lit1)
        interp.evaluate(lit2)

        # Should be able to get FS
        fs = interp.get_framework_strength()
        assert isinstance(fs, float)
        assert 0.0 <= fs <= 1.0

    def test_convergence_detection(self):
        """Should detect eigenstate convergence."""
        interp = Interpreter(dimension=10)

        # Initially should not be converged
        assert not interp.has_converged(threshold=0.95)


class TestEndToEnd:
    """End-to-end integration tests."""

    def test_simple_assignment(self):
        """Should execute simple program: x is 5"""
        # Full pipeline: Source → Lexer → Parser → Evaluator
        source = "x is 5"

        # Tokenize
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        # Parse
        parser = Parser(tokens)
        ast = parser.parse()

        # Evaluate
        interp = Interpreter(dimension=10)
        result = interp.evaluate(ast)

        # x should be bound
        x_val = interp.environment.lookup("x")
        assert isinstance(x_val, LRVMVector)
        # First coordinate should be 5
        assert x_val.coords[0] == 5.0

    def test_relation_program(self):
        """Should execute: z is x of y"""
        source = """x is 3
y is 4
z is x of y"""

        # Full pipeline
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter(dimension=10)
        interp.evaluate(ast)

        # All should be bound
        x_val = interp.environment.lookup("x")
        y_val = interp.environment.lookup("y")
        z_val = interp.environment.lookup("z")

        assert isinstance(x_val, LRVMVector)
        assert isinstance(y_val, LRVMVector)
        assert isinstance(z_val, LRVMVector)

        # z should be the metric contraction of x and y
        # For our embedding: x of y should give a meaningful value
        assert z_val.dimension == 10

    def test_multiple_assignments(self):
        """Should handle multiple variable assignments."""
        source = """a is 10
b is 20
c is 30"""

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter(dimension=10)
        interp.evaluate(ast)

        # All variables should be bound
        assert "a" in interp.environment.bindings
        assert "b" in interp.environment.bindings
        assert "c" in interp.environment.bindings

    def test_string_assignment(self):
        """Should handle string assignments."""
        source = 'name is "Alice"'

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter(dimension=768)  # Larger for strings
        interp.evaluate(ast)

        name_val = interp.environment.lookup("name")
        assert isinstance(name_val, LRVMVector)
        assert name_val.dimension == 768

    def test_chained_relations(self):
        """Should handle chained OF operations."""
        source = """a is 2
b is 3
c is 5
result is a of b of c"""

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter(dimension=10)
        interp.evaluate(ast)

        # result should exist
        result_val = interp.environment.lookup("result")
        assert isinstance(result_val, LRVMVector)

    def test_vector_literal(self):
        """Should handle vector literals."""
        source = "v is (1, 2, 3)"

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()

        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter(dimension=10)
        interp.evaluate(ast)

        v_val = interp.environment.lookup("v")
        assert isinstance(v_val, LRVMVector)

    def test_mvp_goal_achieved(self):
        """MVP Success: Can execute 'x is 5' and 'z is x of y'"""
        # This is the official MVP success criterion from the roadmap

        # Test 1: x is 5
        source1 = "x is 5"
        tokenizer1 = Tokenizer(source1)
        parser1 = Parser(tokenizer1.tokenize())
        interp1 = Interpreter(dimension=10)
        interp1.evaluate(parser1.parse())
        assert "x" in interp1.environment.bindings

        # Test 2: z is x of y
        source2 = """x is 10
y is 20
z is x of y"""
        tokenizer2 = Tokenizer(source2)
        parser2 = Parser(tokenizer2.tokenize())
        interp2 = Interpreter(dimension=10)
        interp2.evaluate(parser2.parse())
        assert "z" in interp2.environment.bindings

        # MVP ACHIEVED! 🎉
