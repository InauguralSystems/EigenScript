"""
Test suite for module vs program compilation mode.
Tests that libraries generate {module}_init() while programs generate main().
"""

import pytest
import tempfile
import os

# Check if llvmlite is available
try:
    from llvmlite import binding as llvm
    from eigenscript.compiler.codegen.llvm_backend import LLVMCodeGenerator
    from eigenscript.lexer import Tokenizer
    from eigenscript.parser.ast_builder import Parser

    COMPILER_AVAILABLE = True
except ImportError:
    COMPILER_AVAILABLE = False


@pytest.mark.skipif(
    not COMPILER_AVAILABLE, reason="Compiler dependencies not installed"
)
class TestModuleVsProgram:
    """Test module vs program compilation modes."""

    def compile_source(
        self, source_code: str, module_name: str = None
    ) -> tuple[str, llvm.ModuleRef]:
        """Helper to compile EigenScript source to LLVM IR."""
        tokenizer = Tokenizer(source_code)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        codegen = LLVMCodeGenerator(module_name=module_name)
        llvm_ir = codegen.compile(ast.statements)

        # Parse and return both IR string and module
        llvm_module = llvm.parse_assembly(llvm_ir)
        llvm_module.verify()

        return llvm_ir, llvm_module

    def test_program_mode_generates_main(self):
        """Program mode (module_name=None) should generate main() function."""
        source = """x is 42
print of x"""

        llvm_ir, llvm_module = self.compile_source(source, module_name=None)

        # Should have main function (with or without quotes)
        assert "define i32 @main()" in llvm_ir or 'define i32 @"main"()' in llvm_ir
        assert "ret i32 0" in llvm_ir

        # Verify the function exists in the module
        main_func = None
        for func in llvm_module.functions:
            if func.name == "main":
                main_func = func
                break

        assert main_func is not None
        # Verify it returns i32 by checking the IR
        assert "ret i32 0" in llvm_ir

    def test_library_mode_generates_init(self):
        """Library mode (module_name set) should generate {module}_init() function."""
        source = """x is 42
print of x"""

        llvm_ir, llvm_module = self.compile_source(source, module_name="math")

        # Should NOT have main function
        assert (
            "define i32 @main()" not in llvm_ir
            and 'define i32 @"main"()' not in llvm_ir
        )

        # Should have math_init function returning void (with or without quotes)
        assert (
            "define void @math_init()" in llvm_ir
            or 'define void @"math_init"()' in llvm_ir
        )
        assert "ret void" in llvm_ir

        # Verify the function exists in the module
        init_func = None
        for func in llvm_module.functions:
            if func.name == "math_init":
                init_func = func
                break

        assert init_func is not None
        # Verify it returns void by checking the IR
        assert "ret void" in llvm_ir

    def test_library_mode_name_mangling(self):
        """Library mode should apply name mangling to functions."""
        source = """define add as:
    result is n * 2
    return result"""

        llvm_ir, llvm_module = self.compile_source(source, module_name="math")

        # Function should be mangled to math_add (with or without quotes)
        assert (
            "define double @math_add" in llvm_ir
            or 'define double @"math_add"' in llvm_ir
        )
        # Original unmangled name should not be a top-level function
        assert (
            "define double @add(" not in llvm_ir
            and 'define double @"add"(' not in llvm_ir
        )

        # Verify the function exists in the module with mangled name
        add_func = None
        for func in llvm_module.functions:
            if func.name == "math_add":
                add_func = func
                break

        assert add_func is not None

    def test_program_mode_no_name_mangling(self):
        """Program mode should NOT apply name mangling to functions."""
        source = """define double as:
    result is n * 2
    return result"""

        llvm_ir, llvm_module = self.compile_source(source, module_name=None)

        # Function should keep original name (with or without quotes)
        assert (
            "define double @double(" in llvm_ir or 'define double @"double"(' in llvm_ir
        )
        # Should not have any prefix like _double
        assert "define double @_double" not in llvm_ir

        # Verify the function exists in the module with original name
        double_func = None
        for func in llvm_module.functions:
            if func.name == "double":
                double_func = func
                break

        assert double_func is not None

    def test_multiple_functions_in_library(self):
        """Library with multiple functions should mangle all function names."""
        source = """define add as:
    result is n + 10
    return result

define multiply as:
    result is n * 2
    return result"""

        llvm_ir, llvm_module = self.compile_source(source, module_name="utils")

        # Both functions should be mangled (with or without quotes)
        assert (
            "define double @utils_add" in llvm_ir
            or 'define double @"utils_add"' in llvm_ir
        )
        assert (
            "define double @utils_multiply" in llvm_ir
            or 'define double @"utils_multiply"' in llvm_ir
        )

        # Verify both functions exist
        func_names = [func.name for func in llvm_module.functions]
        assert "utils_add" in func_names
        assert "utils_multiply" in func_names

    def test_library_init_with_globals(self):
        """Library init should initialize global variables."""
        source = """x is 42
y is 100
z is x + y"""

        llvm_ir, llvm_module = self.compile_source(source, module_name="physics")

        # Should have physics_init function (with or without quotes)
        assert (
            "define void @physics_init()" in llvm_ir
            or 'define void @"physics_init"()' in llvm_ir
        )

        # Should have variable initialization code in init function
        init_func = None
        for func in llvm_module.functions:
            if func.name == "physics_init":
                init_func = func
                break

        assert init_func is not None
        # The init function should have basic blocks with code
        assert len(list(init_func.blocks)) > 0

    def test_different_module_names_different_prefixes(self):
        """Different modules should get different prefixes."""
        source = """define helper as:
    return n"""

        # Compile as math module
        llvm_ir_math, _ = self.compile_source(source, module_name="math")
        assert (
            "define double @math_helper" in llvm_ir_math
            or 'define double @"math_helper"' in llvm_ir_math
        )

        # Compile as physics module
        llvm_ir_physics, _ = self.compile_source(source, module_name="physics")
        assert (
            "define double @physics_helper" in llvm_ir_physics
            or 'define double @"physics_helper"' in llvm_ir_physics
        )

        # Verify they have different prefixes
        assert "math_" in llvm_ir_math
        assert "physics_" in llvm_ir_physics

    def test_library_mode_verification_passes(self):
        """Library mode generated code should pass LLVM verification."""
        source = """x is 42
define double as:
    return n * 2
y is double of x"""

        llvm_ir, llvm_module = self.compile_source(source, module_name="test_lib")

        # If we got here without exception, verification passed
        assert llvm_module is not None

    def test_program_mode_verification_passes(self):
        """Program mode generated code should pass LLVM verification."""
        source = """x is 42
define double as:
    return n * 2
y is double of x
print of y"""

        llvm_ir, llvm_module = self.compile_source(source, module_name=None)

        # If we got here without exception, verification passed
        assert llvm_module is not None


@pytest.mark.skipif(
    not COMPILER_AVAILABLE, reason="Compiler dependencies not installed"
)
class TestModuleCompilationIntegration:
    """Test end-to-end module compilation with compile.py."""

    def test_compile_module_with_name(self):
        """Test that compile_module correctly passes module_name to codegen."""
        from eigenscript.compiler.cli.compile import compile_module
        from eigenscript.compiler.analysis.resolver import ModuleResolver

        # Create a temporary module file
        with tempfile.NamedTemporaryFile(mode="w", suffix=".eigs", delete=False) as f:
            f.write("x is 42\n")
            f.write("y is x * 2\n")
            temp_file = f.name

        try:
            # Compile as library (is_main=False)
            root_dir = os.path.dirname(temp_file)
            resolver = ModuleResolver(root_dir=root_dir)
            compiled_objects = set()

            obj_path = compile_module(
                temp_file,
                resolver,
                compiled_objects,
                target_triple=None,
                opt_level=0,
                is_main=False,
            )

            assert obj_path is not None
            assert os.path.exists(obj_path)

            # The module should be marked as compiled
            assert os.path.abspath(temp_file) in compiled_objects

        finally:
            # Cleanup
            if os.path.exists(temp_file):
                os.remove(temp_file)
            if obj_path and os.path.exists(obj_path):
                os.remove(obj_path)

    def test_compile_main_without_module_name(self):
        """Test that main entry point compiles without module_name."""
        from eigenscript.compiler.cli.compile import compile_module
        from eigenscript.compiler.analysis.resolver import ModuleResolver

        # Create a temporary main file
        with tempfile.NamedTemporaryFile(mode="w", suffix=".eigs", delete=False) as f:
            f.write("x is 42\n")
            f.write("print of x\n")
            temp_file = f.name

        try:
            # Compile as main (is_main=True)
            root_dir = os.path.dirname(temp_file)
            resolver = ModuleResolver(root_dir=root_dir)
            compiled_objects = set()

            obj_path = compile_module(
                temp_file,
                resolver,
                compiled_objects,
                target_triple=None,
                opt_level=0,
                is_main=True,
            )

            assert obj_path is not None
            assert os.path.exists(obj_path)

        finally:
            # Cleanup
            if os.path.exists(temp_file):
                os.remove(temp_file)
            if obj_path and os.path.exists(obj_path):
                os.remove(obj_path)
