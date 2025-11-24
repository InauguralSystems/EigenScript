"""
Test suite for EigenScript LLVM compiler code generation.
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
class TestLLVMCodeGen:
    """Test LLVM code generation from EigenScript AST."""

    def compile_source(self, source_code: str) -> str:
        """Helper to compile EigenScript source to LLVM IR."""
        tokenizer = Tokenizer(source_code)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        codegen = LLVMCodeGenerator()
        llvm_ir = codegen.compile(ast.statements)
        return llvm_ir

    def verify_llvm_ir(self, llvm_ir: str) -> bool:
        """Helper to verify LLVM IR is valid."""
        try:
            llvm_module = llvm.parse_assembly(llvm_ir)
            llvm_module.verify()
            return True
        except Exception as e:
            print(f"Verification failed: {e}")
            return False

    def test_simple_assignment(self):
        """Test compilation of simple variable assignment."""
        source = "x is 42"
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "eigen_create" in llvm_ir
        assert "double" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_arithmetic_operations(self):
        """Test compilation of arithmetic operations."""
        source = """x is 10
y is 20
z is x + y"""
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "fadd" in llvm_ir or "add" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_function_definition(self):
        """Test compilation of function definition."""
        source = """define double as:
    result is n * 2
    return result"""
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "define" in llvm_ir
        assert "double" in llvm_ir
        assert "ret" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_conditional(self):
        """Test compilation of if/else."""
        source = """x is 10
if x > 5:
    y is 1
else:
    y is 0"""
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "br" in llvm_ir  # Branch instruction
        assert "label" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_list_literal(self):
        """Test compilation of list literal."""
        source = "numbers is [1, 2, 3, 4, 5]"
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "eigen_list_create" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_list_indexing(self):
        """Test compilation of list indexing."""
        source = """numbers is [1, 2, 3]
first is numbers[0]"""
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "eigen_list_get" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_loop_with_comparison(self):
        """Test compilation of loop with comparison condition."""
        source = """i is 0
limit is 10
loop while i < limit:
    i is i + 1"""
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "br" in llvm_ir  # Branch instruction
        assert "loop.cond" in llvm_ir
        assert "loop.body" in llvm_ir
        assert "loop.end" in llvm_ir
        assert "fcmp" in llvm_ir  # Comparison instruction
        assert self.verify_llvm_ir(llvm_ir)

    def test_loop_with_scalar_condition(self):
        """Test compilation of loop with scalar variable as condition (truthiness)."""
        source = """count is 5
loop while count:
    count is count - 1"""
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "br" in llvm_ir  # Branch instruction
        assert "loop.cond" in llvm_ir
        assert "loop.body" in llvm_ir
        assert "loop.end" in llvm_ir
        # Should have fcmp != 0.0 for truthiness check
        assert "fcmp" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_conditional_with_scalar(self):
        """Test compilation of if with scalar variable as condition."""
        source = """x is 5
if x:
    y is 1"""
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "br" in llvm_ir
        assert "if.then" in llvm_ir
        # Should have fcmp != 0.0 for truthiness check
        assert "fcmp" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_interrogatives(self):
        """Test compilation of interrogatives (what/why/how)."""
        source = """x is 100
value is what is x
direction is why is x
quality is how is x"""
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "eigen_get_value" in llvm_ir
        assert "eigen_get_gradient" in llvm_ir
        assert "eigen_get_stability" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_comparison_operators(self):
        """Test compilation of comparison operators."""
        source = """x is 10
y is 20
result1 is x < y
result2 is x > y
result3 is x = y"""
        llvm_ir = self.compile_source(source)

        assert llvm_ir is not None
        assert "fcmp" in llvm_ir or "cmp" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_module_verification(self):
        """Test that all generated modules pass LLVM verification."""
        test_cases = [
            "x is 42",
            "x is 10\ny is x + 5",
            "define foo as:\n    return n * 2",
            "if True:\n    x is 1\nelse:\n    x is 2",
        ]

        for source in test_cases:
            llvm_ir = self.compile_source(source)
            assert self.verify_llvm_ir(llvm_ir), f"Failed to verify: {source}"

    def test_runtime_functions_declared(self):
        """Test that runtime functions are properly declared."""
        source = "x is 42"
        llvm_ir = self.compile_source(source)

        # Check for runtime function declarations
        assert "declare" in llvm_ir
        assert "eigen_create" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)

    def test_main_function_generated(self):
        """Test that a main function is generated."""
        source = "x is 42"
        llvm_ir = self.compile_source(source)

        assert 'define i32 @"main"()' in llvm_ir
        assert "ret i32 0" in llvm_ir
        assert self.verify_llvm_ir(llvm_ir)


@pytest.mark.skipif(
    not COMPILER_AVAILABLE, reason="Compiler dependencies not installed"
)
class TestCompilerCLI:
    """Test the compiler CLI interface."""

    def test_compile_to_llvm_ir(self):
        """Test compiling to LLVM IR file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create a simple EigenScript file
            eigs_file = os.path.join(tmpdir, "test.eigs")
            with open(eigs_file, "w") as f:
                f.write("x is 42\ny is x + 8")

            # Compile it
            from eigenscript.compiler.cli.compile import compile_file

            result = compile_file(eigs_file, verify=True)

            assert result == 0
            assert os.path.exists(os.path.join(tmpdir, "test.ll"))

    def test_compile_with_verification(self):
        """Test compilation with verification enabled."""
        with tempfile.TemporaryDirectory() as tmpdir:
            eigs_file = os.path.join(tmpdir, "test.eigs")
            with open(eigs_file, "w") as f:
                f.write("x is 10\nif x > 5:\n    y is 1")

            from eigenscript.compiler.cli.compile import compile_file

            result = compile_file(eigs_file, verify=True)

            assert result == 0


@pytest.mark.skipif(
    not COMPILER_AVAILABLE, reason="Compiler dependencies not installed"
)
class TestExamples:
    """Test that example programs compile successfully."""

    EXAMPLES_DIR = "examples/compiler"

    def test_simple_example(self):
        """Test compilation of test.eigs example."""
        example_file = os.path.join(self.EXAMPLES_DIR, "test.eigs")
        if not os.path.exists(example_file):
            pytest.skip(f"Example file not found: {example_file}")

        with open(example_file, "r") as f:
            source = f.read()

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        codegen = LLVMCodeGenerator()
        llvm_ir = codegen.compile(ast.statements)

        llvm_module = llvm.parse_assembly(llvm_ir)
        llvm_module.verify()

    def test_functions_example(self):
        """Test compilation of functions.eigs example."""
        example_file = os.path.join(self.EXAMPLES_DIR, "functions.eigs")
        if not os.path.exists(example_file):
            pytest.skip(f"Example file not found: {example_file}")

        with open(example_file, "r") as f:
            source = f.read()

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        codegen = LLVMCodeGenerator()
        llvm_ir = codegen.compile(ast.statements)

        llvm_module = llvm.parse_assembly(llvm_ir)
        llvm_module.verify()

    def test_list_example(self):
        """Test compilation of list.eigs example."""
        example_file = os.path.join(self.EXAMPLES_DIR, "list.eigs")
        if not os.path.exists(example_file):
            pytest.skip(f"Example file not found: {example_file}")

        with open(example_file, "r") as f:
            source = f.read()

        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        codegen = LLVMCodeGenerator()
        llvm_ir = codegen.compile(ast.statements)

        llvm_module = llvm.parse_assembly(llvm_ir)
        llvm_module.verify()
