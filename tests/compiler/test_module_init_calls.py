"""
Test suite for Phase 4.4: Module initialization calls.
Tests that main() calls imported module init functions.
"""

import pytest

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
class TestModuleInitCalls:
    """Test that main() calls module init functions."""

    def compile_source(
        self, source_code: str, module_name: str = None, imported_modules: list = None
    ) -> tuple[str, llvm.ModuleRef]:
        """Helper to compile EigenScript source to LLVM IR."""
        tokenizer = Tokenizer(source_code)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        codegen = LLVMCodeGenerator(module_name=module_name)
        llvm_ir = codegen.compile(ast.statements, imported_modules)

        # Parse and return both IR string and module
        llvm_module = llvm.parse_assembly(llvm_ir)
        llvm_module.verify()

        return llvm_ir, llvm_module

    def test_no_imports_no_init_calls(self):
        """Program with no imports should not call any init functions."""
        source = """x is 42
print of x"""

        llvm_ir, llvm_module = self.compile_source(
            source, module_name=None, imported_modules=None
        )

        # Should have main but no module init calls
        assert "@main" in llvm_ir or '@"main"' in llvm_ir
        # Check there are no module init calls (not eigen_init which is runtime)
        assert "call void @math" not in llvm_ir
        assert "call void @physics" not in llvm_ir

    def test_single_import_generates_init_call(self):
        """Program with one import should call that module's init function."""
        source = """x is 42
print of x"""

        llvm_ir, llvm_module = self.compile_source(
            source, module_name=None, imported_modules=["math_utils"]
        )

        # Should have main
        assert "@main" in llvm_ir or '@"main"' in llvm_ir

        # Should declare math_utils_init
        assert (
            "declare void @math_utils_init()" in llvm_ir
            or 'declare void @"math_utils_init"()' in llvm_ir
        )

        # Should call math_utils_init
        assert (
            "call void @math_utils_init()" in llvm_ir
            or 'call void @"math_utils_init"()' in llvm_ir
        )

    def test_multiple_imports_generate_multiple_init_calls(self):
        """Program with multiple imports should call all module init functions."""
        source = """x is 42
print of x"""

        llvm_ir, llvm_module = self.compile_source(
            source, module_name=None, imported_modules=["math_utils", "physics"]
        )

        # Should have main
        assert "@main" in llvm_ir or '@"main"' in llvm_ir

        # Should declare both init functions
        assert (
            "declare void @math_utils_init()" in llvm_ir
            or 'declare void @"math_utils_init"()' in llvm_ir
        )
        assert (
            "declare void @physics_init()" in llvm_ir
            or 'declare void @"physics_init"()' in llvm_ir
        )

        # Should call both init functions
        assert (
            "call void @math_utils_init()" in llvm_ir
            or 'call void @"math_utils_init"()' in llvm_ir
        )
        assert (
            "call void @physics_init()" in llvm_ir
            or 'call void @"physics_init"()' in llvm_ir
        )

    def test_library_mode_ignores_imports(self):
        """Library mode should not generate init calls even if imports provided."""
        source = """x is 42"""

        llvm_ir, llvm_module = self.compile_source(
            source, module_name="mylib", imported_modules=["math_utils"]
        )

        # Should have mylib_init, not main
        assert (
            "define void @mylib_init()" in llvm_ir
            or 'define void @"mylib_init"()' in llvm_ir
        )
        assert "@main" not in llvm_ir and '@"main"' not in llvm_ir

        # Should NOT call math_utils_init (libraries don't import other libraries)
        assert "call void @math_utils_init()" not in llvm_ir

    def test_init_calls_before_main_logic(self):
        """Init calls should appear before any stores or computation."""
        source = """x is 42
y is x + 10
print of y"""

        llvm_ir, llvm_module = self.compile_source(
            source, module_name=None, imported_modules=["math"]
        )

        # Find the main function in the IR
        main_start = llvm_ir.find("define i32 @main()")
        if main_start == -1:
            main_start = llvm_ir.find('define i32 @"main"()')
        assert main_start != -1

        # Find the init call
        init_call = llvm_ir.find("call void @math_init()")
        if init_call == -1:
            init_call = llvm_ir.find('call void @"math_init"()')
        assert init_call != -1

        # Find the first store instruction (actual user logic)
        first_store = llvm_ir.find("store double", main_start)
        assert first_store != -1

        # Init call should come before the first store
        assert (
            init_call < first_store
        ), "Init call should come before user logic execution"

    def test_verification_passes_with_init_calls(self):
        """LLVM verification should pass with init calls."""
        source = """x is 42
print of x"""

        llvm_ir, llvm_module = self.compile_source(
            source, module_name=None, imported_modules=["math", "physics"]
        )

        # If we got here without exception, verification passed
        assert llvm_module is not None
