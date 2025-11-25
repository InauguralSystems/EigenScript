"""
Tests for runtime/evaluator module support in EigenScript.

Tests the ability to import and use modules in the interpreter/REPL,
not just at compile-time.
"""

import pytest
from eigenscript.lexer.tokenizer import Tokenizer
from eigenscript.parser.ast_builder import Parser
from eigenscript.evaluator.interpreter import Interpreter


class TestModuleEvaluator:
    """Test runtime module loading and execution."""

    def test_import_stdlib_module(self):
        """Test importing a standard library module."""
        source = """
import control
result is control.apply_damping of 10
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # apply_damping should reduce velocity
        # Check that result is an LRVM vector
        assert hasattr(result, "coords")
        # The result should be stored in the environment
        assert "result" in interp.environment.bindings

    def test_import_with_alias(self):
        """Test importing a module with an alias."""
        source = """
import control as ctrl
result is ctrl.apply_damping of 20
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Check that the alias works
        assert "result" in interp.environment.bindings
        # Original module name should not be bound
        assert "control" not in interp.environment.bindings
        # Alias should be bound
        assert "ctrl" in interp.environment.bindings

    def test_import_geometry_module(self):
        """Test importing geometry module and using its functions."""
        source = """
import geometry
result is geometry.norm of -5
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # norm of -5 should be 5
        assert "result" in interp.environment.bindings

    def test_multiple_imports(self):
        """Test importing multiple modules."""
        source = """
import control
import geometry
x is geometry.norm of -10
y is control.apply_damping of x
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Both modules should be loaded
        assert "control" in interp.environment.bindings
        assert "geometry" in interp.environment.bindings
        assert "x" in interp.environment.bindings
        assert "y" in interp.environment.bindings

    def test_module_caching(self):
        """Test that modules are cached and not reloaded."""
        source = """
import control
import control
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.evaluate(ast)

        # Module should only be loaded once
        assert len(interp.loaded_modules) == 1
        assert "control" in interp.loaded_modules

    def test_import_nonexistent_module_fails(self):
        """Test that importing a non-existent module raises ImportError."""
        source = "import nonexistent_module_12345"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        with pytest.raises(ImportError, match="Cannot find module"):
            interp.evaluate(ast)

    def test_member_access_nonexistent_member_fails(self):
        """Test that accessing a non-existent member raises AttributeError."""
        source = """
import control
x is control.nonexistent_function of 10
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        with pytest.raises(AttributeError, match="has no attribute"):
            interp.evaluate(ast)

    def test_member_access_on_non_module_fails(self):
        """Test that member access on non-module types fails."""
        source = """
x is 5
y is x.something
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        with pytest.raises(TypeError, match="Cannot access member"):
            interp.evaluate(ast)

    def test_module_function_as_value(self):
        """Test that module functions can be assigned to variables."""
        source = """
import geometry
func is geometry.norm
result is func of -7
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Check that we can assign and use module functions
        assert "func" in interp.environment.bindings
        assert "result" in interp.environment.bindings

    def test_from_import_single_name(self):
        """Test importing a single name from a module."""
        source = """
from geometry import norm
result is norm of -5
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # norm should be directly accessible without module prefix
        assert "norm" in interp.environment.bindings
        assert "result" in interp.environment.bindings
        # geometry module should NOT be in environment
        assert "geometry" not in interp.environment.bindings

    def test_from_import_multiple_names(self):
        """Test importing multiple names from a module."""
        source = """
from control import apply_damping, pid_step
x is apply_damping of 10
y is pid_step of 5
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Both names should be accessible
        assert "apply_damping" in interp.environment.bindings
        assert "pid_step" in interp.environment.bindings
        assert "x" in interp.environment.bindings
        assert "y" in interp.environment.bindings
        # Module should NOT be in environment
        assert "control" not in interp.environment.bindings

    def test_from_import_with_alias(self):
        """Test importing a name with an alias."""
        source = """
from geometry import lerp as interpolate
result is interpolate of 0
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Alias should be accessible
        assert "interpolate" in interp.environment.bindings
        assert "result" in interp.environment.bindings
        # Original name should NOT be in environment
        assert "lerp" not in interp.environment.bindings
        assert "geometry" not in interp.environment.bindings

    def test_from_import_mixed_aliases(self):
        """Test importing multiple names with some aliased and some not."""
        source = """
from control import apply_damping, pid_step as controller
x is apply_damping of 10
y is controller of 5
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Non-aliased name should be accessible
        assert "apply_damping" in interp.environment.bindings
        # Alias should be accessible
        assert "controller" in interp.environment.bindings
        # Original aliased name should NOT be accessible
        assert "pid_step" not in interp.environment.bindings
        assert "x" in interp.environment.bindings
        assert "y" in interp.environment.bindings

    def test_from_import_nonexistent_name_fails(self):
        """Test that importing a non-existent name raises ImportError."""
        source = "from control import nonexistent_function"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        with pytest.raises(ImportError, match="Cannot import name"):
            interp.evaluate(ast)

    def test_from_import_caching(self):
        """Test that modules are cached when using from...import."""
        source = """
from control import apply_damping
from control import pid_step
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.evaluate(ast)

        # Module should only be loaded once
        assert len(interp.loaded_modules) == 1
        assert "control" in interp.loaded_modules
        # Both names should be accessible
        assert "apply_damping" in interp.environment.bindings
        assert "pid_step" in interp.environment.bindings

    def test_from_import_mixed_with_regular_import(self):
        """Test that from...import and regular import work together."""
        source = """
import geometry
from control import apply_damping
x is geometry.norm of -10
y is apply_damping of x
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Regular import should bind module
        assert "geometry" in interp.environment.bindings
        # from...import should bind name directly
        assert "apply_damping" in interp.environment.bindings
        assert "control" not in interp.environment.bindings
        assert "x" in interp.environment.bindings
        assert "y" in interp.environment.bindings
        # Both modules should be cached
        assert len(interp.loaded_modules) == 2

    def test_from_import_same_module_caching(self):
        """Test that using both import styles on same module uses cache."""
        source = """
import control
from control import apply_damping
result is control.pid_step of 5
result2 is apply_damping of 10
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.evaluate(ast)

        # Module should only be loaded once
        assert len(interp.loaded_modules) == 1
        assert "control" in interp.loaded_modules
        # Both access styles should work
        assert "control" in interp.environment.bindings
        assert "apply_damping" in interp.environment.bindings
        assert "result" in interp.environment.bindings
        assert "result2" in interp.environment.bindings

    def test_from_import_wildcard(self):
        """Test wildcard import (from module import *)."""
        source = """
from geometry import *
result is norm of -5
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # All functions from geometry should be accessible
        assert "norm" in interp.environment.bindings
        assert "distance_1d" in interp.environment.bindings
        assert "lerp" in interp.environment.bindings
        assert "clamp" in interp.environment.bindings
        assert "smooth_step" in interp.environment.bindings
        # Module itself should NOT be bound
        assert "geometry" not in interp.environment.bindings
        # Result should be computed
        assert "result" in interp.environment.bindings

    def test_from_import_wildcard_excludes_builtins(self):
        """Test that wildcard import doesn't overwrite builtins."""
        source = """
from control import *
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        # Store original print builtin
        original_print = interp.environment.bindings["print"]

        interp.evaluate(ast)

        # Module functions should be imported
        assert "apply_damping" in interp.environment.bindings
        assert "pid_step" in interp.environment.bindings
        # Builtins should not be overwritten
        assert interp.environment.bindings["print"] is original_print

    def test_from_import_wildcard_with_usage(self):
        """Test using wildcard imported functions."""
        source = """
from control import *
x is apply_damping of 10
y is pid_step of 5
z is convergence_check of 1
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.evaluate(ast)

        # All imported functions should work
        assert "apply_damping" in interp.environment.bindings
        assert "pid_step" in interp.environment.bindings
        assert "convergence_check" in interp.environment.bindings
        assert "x" in interp.environment.bindings
        assert "y" in interp.environment.bindings
        assert "z" in interp.environment.bindings

    def test_from_import_wildcard_caching(self):
        """Test that wildcard imports use module cache."""
        source = """
from control import *
from control import apply_damping
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.evaluate(ast)

        # Module should only be loaded once
        assert len(interp.loaded_modules) == 1
        assert "control" in interp.loaded_modules

    def test_from_import_wildcard_mixed_with_regular_import(self):
        """Test mixing wildcard import with regular imports."""
        source = """
import control
from geometry import *
x is control.apply_damping of 10
y is norm of -5
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.evaluate(ast)

        # Regular import should bind module
        assert "control" in interp.environment.bindings
        # Wildcard should import all geometry functions
        assert "norm" in interp.environment.bindings
        assert "lerp" in interp.environment.bindings
        # Module name should NOT be bound for wildcard
        assert "geometry" not in interp.environment.bindings
        # Both should be cached
        assert len(interp.loaded_modules) == 2
