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

    def test_relative_import_same_package(self):
        """Test relative import from same package (from . import)."""
        import os

        # Load a module that uses relative imports
        module_path = os.path.join(
            os.path.dirname(__file__), "test_packages", "mypackage", "main.eigs"
        )

        with open(module_path, "r") as f:
            source = f.read()

        from eigenscript.lexer.tokenizer import Tokenizer
        from eigenscript.parser.ast_builder import Parser

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        # Push the module path onto the stack to simulate being inside a module
        interp.module_stack.append(module_path)

        try:
            result = interp.evaluate(ast)

            # Check that relative imports worked
            assert "double" in interp.environment.bindings
            assert "magic_number" in interp.environment.bindings
            assert "result" in interp.environment.bindings
            assert "check" in interp.environment.bindings
        finally:
            interp.module_stack.pop()

    def test_relative_import_parent_package(self):
        """Test relative import from parent package (from .. import)."""
        import os

        # Load the deep module that imports from parent
        module_path = os.path.join(
            os.path.dirname(__file__),
            "test_packages",
            "mypackage",
            "subpackage",
            "deep.eigs",
        )

        with open(module_path, "r") as f:
            source = f.read()

        from eigenscript.lexer.tokenizer import Tokenizer
        from eigenscript.parser.ast_builder import Parser

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        # Push the module path onto the stack to simulate being inside a module
        interp.module_stack.append(module_path)

        try:
            result = interp.evaluate(ast)

            # Check that relative imports from parent worked
            assert "triple" in interp.environment.bindings
            assert "increment" in interp.environment.bindings
            assert "x" in interp.environment.bindings
            assert "y" in interp.environment.bindings
        finally:
            interp.module_stack.pop()

    def test_relative_import_without_context_fails(self):
        """Test that relative imports fail outside module context."""
        source = "from . import something"

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        # Don't push anything onto module_stack - no context

        with pytest.raises(
            ImportError, match="Relative import outside of package context"
        ):
            interp.evaluate(ast)

    def test_relative_import_wildcard(self):
        """Test relative wildcard import (from . import *)."""
        import os
        import tempfile

        # Create a temporary module that uses relative wildcard import
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create utils module
            utils_path = os.path.join(tmpdir, "utils.eigs")
            with open(utils_path, "w") as f:
                f.write(
                    """
define helper as:
    return 100

value is 42
"""
                )

            # Create main module with relative wildcard import
            main_path = os.path.join(tmpdir, "main.eigs")
            with open(main_path, "w") as f:
                f.write(
                    """
from .utils import *
result is helper of 1
check is value
"""
                )

            # Read and evaluate main module
            with open(main_path, "r") as f:
                source = f.read()

            from eigenscript.lexer.tokenizer import Tokenizer
            from eigenscript.parser.ast_builder import Parser

            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            parser = Parser(tokens)
            ast = parser.parse()

            interp = Interpreter()
            interp.module_stack.append(main_path)

            try:
                result = interp.evaluate(ast)

                # Check that wildcard relative import worked
                assert "helper" in interp.environment.bindings
                assert "value" in interp.environment.bindings
                assert "result" in interp.environment.bindings
                assert "check" in interp.environment.bindings
            finally:
                interp.module_stack.pop()

    def test_package_import_with_init(self):
        """Test importing a package with __init__.eigs."""
        import os

        # Change to test_packages directory for import resolution
        original_cwd = os.getcwd()
        test_packages_dir = os.path.join(os.path.dirname(__file__), "test_packages")
        os.chdir(test_packages_dir)

        try:
            source = "import mathlib"

            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            parser = Parser(tokens)
            ast = parser.parse()

            interp = Interpreter()
            result = interp.evaluate(ast)

            # Package should be imported as a module
            assert "mathlib" in interp.environment.bindings

            # Access package functions through module namespace
            source2 = """
x is mathlib.square of 5
y is mathlib.cube of 3
pi_val is mathlib.PI
"""
            tokenizer2 = Tokenizer(source2)
            tokens2 = tokenizer2.tokenize()
            parser2 = Parser(tokens2)
            ast2 = parser2.parse()

            interp.evaluate(ast2)

            assert "x" in interp.environment.bindings
            assert "y" in interp.environment.bindings
            assert "pi_val" in interp.environment.bindings
        finally:
            os.chdir(original_cwd)

    def test_package_from_import(self):
        """Test from...import with a package."""
        import os

        original_cwd = os.getcwd()
        test_packages_dir = os.path.join(os.path.dirname(__file__), "test_packages")
        os.chdir(test_packages_dir)

        try:
            source = """
from mathlib import square, PI
result is square of 4
pi_value is PI
"""
            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            parser = Parser(tokens)
            ast = parser.parse()

            interp = Interpreter()
            result = interp.evaluate(ast)

            # Functions from __init__.eigs should be accessible
            assert "square" in interp.environment.bindings
            assert "PI" in interp.environment.bindings
            assert "result" in interp.environment.bindings
            assert "pi_value" in interp.environment.bindings
            # Package name should NOT be bound
            assert "mathlib" not in interp.environment.bindings
        finally:
            os.chdir(original_cwd)

    def test_package_with_relative_imports(self):
        """Test package __init__.eigs with relative imports."""
        import os

        original_cwd = os.getcwd()
        test_packages_dir = os.path.join(os.path.dirname(__file__), "test_packages")
        os.chdir(test_packages_dir)

        try:
            source = "import shapes"

            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            parser = Parser(tokens)
            ast = parser.parse()

            interp = Interpreter()
            result = interp.evaluate(ast)

            # Package should be imported
            assert "shapes" in interp.environment.bindings

            # Access re-exported functions
            source2 = """
circle_a is shapes.circle_area of 5
rect_a is shapes.rectangle_area of 3
circ is shapes.circumference of 10
perim is shapes.perimeter of 4
"""
            tokenizer2 = Tokenizer(source2)
            tokens2 = tokenizer2.tokenize()
            parser2 = Parser(tokens2)
            ast2 = parser2.parse()

            interp.evaluate(ast2)

            assert "circle_a" in interp.environment.bindings
            assert "rect_a" in interp.environment.bindings
            assert "circ" in interp.environment.bindings
            assert "perim" in interp.environment.bindings
        finally:
            os.chdir(original_cwd)

    def test_package_wildcard_import(self):
        """Test wildcard import from package."""
        import os

        original_cwd = os.getcwd()
        test_packages_dir = os.path.join(os.path.dirname(__file__), "test_packages")
        os.chdir(test_packages_dir)

        try:
            source = """
from mathlib import *
sq is square of 6
cb is cube of 2
e_val is E
"""
            tokenizer = Tokenizer(source)
            tokens = tokenizer.tokenize()
            parser = Parser(tokens)
            ast = parser.parse()

            interp = Interpreter()
            result = interp.evaluate(ast)

            # All package exports should be available
            assert "square" in interp.environment.bindings
            assert "cube" in interp.environment.bindings
            assert "E" in interp.environment.bindings
            assert "PI" in interp.environment.bindings
            assert "sq" in interp.environment.bindings
            assert "cb" in interp.environment.bindings
            assert "e_val" in interp.environment.bindings
        finally:
            os.chdir(original_cwd)

    def test_import_hook_logging(self):
        """Test import hook for logging imports."""
        logged_imports = []

        def logging_hook(name, path):
            logged_imports.append((name, path))
            return None  # Continue with normal loading

        source = "import control"

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.register_import_hook(logging_hook)
        interp.evaluate(ast)

        # Hook should have been called
        assert len(logged_imports) == 1
        assert logged_imports[0][0] == "control"
        assert "control.eigs" in logged_imports[0][1]

    def test_import_hook_virtual_module(self):
        """Test import hook providing a virtual module."""

        def virtual_module_hook(name, path):
            if name == "virtual":
                # Return source for virtual module
                return """
magic_value is 42

define double as:
    x is n
    return x * x
"""
            return None  # Fall back for other modules

        source = """
import virtual
result is virtual.magic_value
squared is virtual.double of 5
"""

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.register_import_hook(virtual_module_hook)
        interp.evaluate(ast)

        # Virtual module should work
        assert "virtual" in interp.environment.bindings
        assert "result" in interp.environment.bindings
        assert "squared" in interp.environment.bindings

    def test_import_hook_source_transformation(self):
        """Test import hook for transforming source code."""

        def transform_hook(name, path):
            if name == "control":
                # Read file and add debugging
                with open(path, "r") as f:
                    source = f.read()
                # Prepend a debug variable
                return "debug_loaded is 1\n" + source
            return None

        source = """
import control
check is control.debug_loaded
"""

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.register_import_hook(transform_hook)
        interp.evaluate(ast)

        # Transformed module should have debug variable
        assert "control" in interp.environment.bindings
        assert "check" in interp.environment.bindings

    def test_import_hook_multiple_priority(self):
        """Test that hooks are called in order and first match wins."""
        calls = []

        def hook1(name, path):
            calls.append("hook1")
            return None  # Pass to next hook

        def hook2(name, path):
            calls.append("hook2")
            if name == "control":
                return "test_value is 99"  # Provide source
            return None

        def hook3(name, path):
            calls.append("hook3")
            return None  # Should not be reached for control

        source = "import control"

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.register_import_hook(hook1)
        interp.register_import_hook(hook2)
        interp.register_import_hook(hook3)
        interp.evaluate(ast)

        # Hooks 1 and 2 should be called, but not 3 (hook2 returned source)
        assert calls == ["hook1", "hook2"]

    def test_import_hook_unregister(self):
        """Test unregistering import hooks."""
        calls = []

        def hook(name, path):
            calls.append(name)
            return None

        source = "import control"

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.register_import_hook(hook)
        interp.evaluate(ast)

        assert len(calls) == 1

        # Unregister and import another module
        interp.unregister_import_hook(hook)

        source2 = "import geometry"
        tokenizer2 = Tokenizer(source2)
        tokens2 = tokenizer2.tokenize()
        parser2 = Parser(tokens2)
        ast2 = parser2.parse()

        interp.evaluate(ast2)

        # Hook should not have been called again
        assert len(calls) == 1

    def test_import_hook_clear_all(self):
        """Test clearing all import hooks."""
        calls = []

        def hook1(name, path):
            calls.append("hook1")
            return None

        def hook2(name, path):
            calls.append("hook2")
            return None

        interp = Interpreter()
        interp.register_import_hook(hook1)
        interp.register_import_hook(hook2)

        source = "import control"
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp.evaluate(ast)
        assert len(calls) == 2

        # Clear all hooks
        interp.clear_import_hooks()

        source2 = "import geometry"
        tokenizer2 = Tokenizer(source2)
        tokens2 = tokenizer2.tokenize()
        parser2 = Parser(tokens2)
        ast2 = parser2.parse()

        interp.evaluate(ast2)

        # No new calls
        assert len(calls) == 2

    def test_import_hook_with_from_import(self):
        """Test that import hooks work with from...import."""

        def hook(name, path):
            if name == "control":
                return "custom_func is 123"
            return None

        source = """
from control import custom_func
result is custom_func
"""

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        interp.register_import_hook(hook)
        interp.evaluate(ast)

        # Hook-provided module should work with from...import
        assert "custom_func" in interp.environment.bindings
        assert "result" in interp.environment.bindings
