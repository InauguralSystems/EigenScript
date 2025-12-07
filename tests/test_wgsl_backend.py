"""
Tests for the WGSL Backend (GPU support).

These tests verify that the WGSL code generator produces valid
compute shader code for matrix operations.
"""

import pytest
from eigenscript.compiler.codegen.wgsl_backend import (
    WGSLCodeGenerator,
    WGSLKernel,
    WGSLBuffer,
    WGSLType,
    generate_webgpu_runtime,
)
from eigenscript.parser.ast_builder import GPUBlock, Assignment, Identifier, Relation
from eigenscript.lexer import Tokenizer
from eigenscript.parser import Parser


class TestWGSLCodeGenerator:
    """Test the WGSL code generator."""

    def test_generator_initialization(self):
        """Test generator initializes correctly."""
        gen = WGSLCodeGenerator()
        assert gen.binding_counter == 0
        assert gen.temp_counter == 0
        assert len(gen.kernels) == 0

    def test_eigen_lite_struct_generation(self):
        """Test GPU-lite EigenValue struct is generated correctly."""
        gen = WGSLCodeGenerator()
        struct = gen.generate_eigen_lite_struct()

        assert "struct EigenLite" in struct
        assert "value: f32" in struct
        assert "gradient: f32" in struct
        # Should NOT contain full geometric tracking fields
        assert "stability" not in struct
        assert "history" not in struct

    def test_matmul_kernel_generation(self):
        """Test matrix multiplication kernel generation."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_matmul_kernel(256, 256, 256)

        assert isinstance(kernel, WGSLKernel)
        assert kernel.name == "matmul"
        assert kernel.entry_point == "main"

        # Check workgroup size
        assert kernel.workgroup_size == (16, 16, 1)

        # Check buffers
        assert len(kernel.buffers) == 4  # A, B, C, dimensions
        buffer_names = [b.name for b in kernel.buffers]
        assert "matrix_a" in buffer_names
        assert "matrix_b" in buffer_names
        assert "matrix_c" in buffer_names
        assert "dimensions" in buffer_names

        # Check WGSL source
        assert "@compute" in kernel.source
        assert "@workgroup_size" in kernel.source
        assert "workgroupBarrier" in kernel.source  # Tiled algorithm uses barriers
        assert "var<workgroup>" in kernel.source  # Uses shared memory

    def test_dot_kernel_generation(self):
        """Test dot product kernel generation."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_dot_kernel(1024)

        assert kernel.name == "dot"
        assert len(kernel.buffers) == 4  # vector_a, vector_b, result, length

        # Check for parallel reduction
        assert "workgroupBarrier" in kernel.source
        assert "var<workgroup>" in kernel.source

    def test_norm_kernel_generation(self):
        """Test vector norm kernel generation."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_norm_kernel(1024)

        assert kernel.name == "norm"

        # Should compute squared sum then sqrt
        assert "sqrt" in kernel.source
        assert "var<workgroup>" in kernel.source

    def test_elementwise_add_kernel(self):
        """Test element-wise addition kernel."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_elementwise_kernel("add", 1024)

        assert kernel.name == "elementwise_add"
        assert "input_a[gid] + input_b[gid]" in kernel.source

    def test_elementwise_mul_kernel(self):
        """Test element-wise multiplication kernel."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_elementwise_kernel("mul", 1024)

        assert kernel.name == "elementwise_mul"
        assert "input_a[gid] * input_b[gid]" in kernel.source

    def test_elementwise_scale_kernel(self):
        """Test scalar multiplication kernel."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_elementwise_kernel("scale", 1024)

        assert kernel.name == "elementwise_scale"
        assert "input[gid] * scalar" in kernel.source
        assert "var<uniform> scalar: f32" in kernel.source

    def test_binding_counter_increments(self):
        """Test that binding numbers increment correctly."""
        gen = WGSLCodeGenerator()

        kernel1 = gen.generate_matmul_kernel(64, 64, 64)
        bindings1 = [b.binding for b in kernel1.buffers]
        assert bindings1 == [0, 1, 2, 3]

        # After reset, should start from 0 again
        kernel2 = gen.generate_dot_kernel(128)
        bindings2 = [b.binding for b in kernel2.buffers]
        assert bindings2 == [0, 1, 2, 3]


class TestGPUBlockParsing:
    """Test parsing of GPU blocks."""

    def test_parse_simple_gpu_block(self):
        """Test parsing a simple GPU block."""
        source = """
gpu:
    result is matmul of [A, B]
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        assert len(ast.statements) == 1
        gpu_block = ast.statements[0]
        assert isinstance(gpu_block, GPUBlock)
        assert len(gpu_block.body) == 1

    def test_parse_multi_statement_gpu_block(self):
        """Test parsing GPU block with multiple statements."""
        source = """
gpu:
    C is matmul of [A, B]
    n is norm of C
    result is C / n
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        assert len(ast.statements) == 1
        gpu_block = ast.statements[0]
        assert isinstance(gpu_block, GPUBlock)
        assert len(gpu_block.body) == 3

    def test_gpu_block_in_program(self):
        """Test GPU block mixed with regular code."""
        source = """
A is [[1, 2], [3, 4]]
B is [[1, 0], [0, 1]]

gpu:
    C is matmul of [A, B]

print of C
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        # Should have: 2 assignments, 1 GPU block, 1 expression
        assert len(ast.statements) == 4
        assert isinstance(ast.statements[2], GPUBlock)


class TestWebGPURuntime:
    """Test the JavaScript runtime generation."""

    def test_runtime_generation(self):
        """Test that WebGPU runtime JS is generated."""
        runtime = generate_webgpu_runtime()

        assert "class EigenGPU" in runtime
        assert "async initialize()" in runtime
        assert "createBuffer" in runtime
        assert "readBuffer" in runtime
        assert "dispatch" in runtime
        assert "matmul" in runtime

    def test_runtime_has_gpu_lite_promotion(self):
        """Test that runtime includes GPU-lite to full EigenValue promotion."""
        runtime = generate_webgpu_runtime()

        assert "promoteToFullEigenValue" in runtime
        assert "gradient" in runtime
        assert "stability" in runtime


class TestWGSLBufferTypes:
    """Test buffer type handling."""

    def test_buffer_types(self):
        """Test various buffer types are handled correctly."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_matmul_kernel(64, 64, 64)

        buffer_types = {b.name: b.type for b in kernel.buffers}
        assert buffer_types["matrix_a"] == WGSLType.ARRAY_F32
        assert buffer_types["matrix_b"] == WGSLType.ARRAY_F32
        assert buffer_types["matrix_c"] == WGSLType.ARRAY_F32
        assert buffer_types["dimensions"] == WGSLType.VEC3F

    def test_buffer_access_modes(self):
        """Test buffer access modes are set correctly."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_matmul_kernel(64, 64, 64)

        buffer_access = {b.name: b.access for b in kernel.buffers}
        assert buffer_access["matrix_a"] == "read"
        assert buffer_access["matrix_b"] == "read"
        assert buffer_access["matrix_c"] == "read_write"
        assert buffer_access["dimensions"] == "read"


class TestWGSLValidSyntax:
    """Test that generated WGSL is syntactically valid."""

    def test_matmul_has_required_decorators(self):
        """Test matmul kernel has required WGSL decorators."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_matmul_kernel(64, 64, 64)

        # Required entry point decorators
        assert "@compute" in kernel.source
        assert "@workgroup_size" in kernel.source

        # Required binding decorators
        assert "@group(0)" in kernel.source
        assert "@binding(0)" in kernel.source
        assert "@binding(1)" in kernel.source
        assert "@binding(2)" in kernel.source
        assert "@binding(3)" in kernel.source

        # Required builtins
        assert "@builtin(global_invocation_id)" in kernel.source
        assert "@builtin(local_invocation_id)" in kernel.source

    def test_no_invalid_wgsl_syntax(self):
        """Test generated WGSL doesn't contain common syntax errors."""
        gen = WGSLCodeGenerator()
        kernel = gen.generate_matmul_kernel(64, 64, 64)

        # Should not have HLSL/GLSL-style syntax
        assert "float" not in kernel.source  # Should use f32
        assert "int " not in kernel.source  # Should use i32 or u32
        assert "__device__" not in kernel.source  # Not CUDA
        assert "#include" not in kernel.source  # Not C


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
