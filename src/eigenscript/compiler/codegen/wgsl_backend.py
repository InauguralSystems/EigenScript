"""
WGSL Backend for EigenScript GPU Compute.

Generates WebGPU Shading Language (WGSL) compute shaders from EigenScript AST nodes.
This enables GPU-accelerated matrix operations in the web playground.

Architecture:
    AST
     ├── [CPU path] → llvm_backend.py → LLVM IR → native/WASM
     └── [GPU path] → wgsl_backend.py → WGSL → WebGPU compute shaders

GPU-lite EigenValue Model:
    On GPU: Only track value + gradient (8 bytes per value)
    On CPU: Full geometric tracking (value, gradient, stability, history)
    Sync: Observation triggers device→host transfer + full promotion
"""

from dataclasses import dataclass
from typing import Dict, List, Optional, Set, Tuple
from enum import Enum

from eigenscript.parser.ast_builder import (
    ASTNode,
    Literal,
    Identifier,
    BinaryOp,
    UnaryOp,
    Assignment,
    FunctionDef,
    Return,
    Conditional,
    Loop,
    Relation,
    Interrogative,
    ListLiteral,
    Index,
    GPUBlock,
)


class WGSLType(Enum):
    """WGSL data types."""

    F32 = "f32"
    I32 = "i32"
    U32 = "u32"
    VEC2F = "vec2<f32>"
    VEC3F = "vec3<f32>"
    VEC4F = "vec4<f32>"
    MAT4X4F = "mat4x4<f32>"
    ARRAY_F32 = "array<f32>"
    EIGEN_LITE = "EigenLite"  # GPU-lite EigenValue struct


@dataclass
class WGSLBuffer:
    """Represents a WebGPU buffer binding."""

    name: str
    binding: int
    group: int
    type: WGSLType
    access: str  # "read", "read_write", "write"
    size: Optional[int] = None  # For arrays


@dataclass
class WGSLKernel:
    """Represents a generated WGSL compute kernel."""

    name: str
    source: str
    workgroup_size: Tuple[int, int, int]
    buffers: List[WGSLBuffer]
    entry_point: str = "main"


class WGSLCodeGenerator:
    """
    Generates WGSL compute shaders from EigenScript GPU blocks.

    This generator produces WebGPU-compatible compute shaders that can be
    executed in the browser via the WebGPU API.

    Example usage:
        generator = WGSLCodeGenerator()
        kernel = generator.generate_matmul(M, N, K)
        # Returns WGSLKernel with shader code and buffer bindings
    """

    def __init__(self):
        self.binding_counter = 0
        self.temp_counter = 0
        self.kernels: List[WGSLKernel] = []

        # Track variables in current GPU block
        self.gpu_vars: Dict[str, WGSLType] = {}

        # Standard workgroup sizes (optimized for common GPUs)
        self.default_workgroup_size = (8, 8, 1)  # 64 threads
        self.matmul_workgroup_size = (16, 16, 1)  # 256 threads for matmul

    def _next_binding(self) -> int:
        """Get next available binding number."""
        binding = self.binding_counter
        self.binding_counter += 1
        return binding

    def _next_temp(self) -> str:
        """Generate unique temporary variable name."""
        name = f"_t{self.temp_counter}"
        self.temp_counter += 1
        return name

    def _reset_bindings(self):
        """Reset binding counter for new kernel."""
        self.binding_counter = 0

    def generate_eigen_lite_struct(self) -> str:
        """
        Generate the GPU-lite EigenValue struct definition.

        This is a minimal version of EigenValue for GPU computation:
        - value: Current scalar value
        - gradient: Rate of change (for 'why' queries)

        Full geometric tracking (stability, history) remains on CPU.
        """
        return """
// GPU-lite EigenValue: minimal tracking for GPU computation
// Full geometric state syncs to host on observation
struct EigenLite {
    value: f32,
    gradient: f32,
}
"""

    def generate_matmul_kernel(
        self, m: int, n: int, k: int, tile_size: int = 16
    ) -> WGSLKernel:
        """
        Generate a tiled matrix multiplication kernel.

        Computes C = A @ B where:
            A is (M x K)
            B is (K x N)
            C is (M x N)

        Uses tiled algorithm with shared workgroup memory for efficiency.

        Args:
            m: Number of rows in A and C
            n: Number of columns in B and C
            k: Number of columns in A / rows in B
            tile_size: Size of tiles for blocking (default 16)

        Returns:
            WGSLKernel with shader code and buffer bindings
        """
        self._reset_bindings()

        buffers = [
            WGSLBuffer(
                "matrix_a", self._next_binding(), 0, WGSLType.ARRAY_F32, "read", m * k
            ),
            WGSLBuffer(
                "matrix_b", self._next_binding(), 0, WGSLType.ARRAY_F32, "read", k * n
            ),
            WGSLBuffer(
                "matrix_c",
                self._next_binding(),
                0,
                WGSLType.ARRAY_F32,
                "read_write",
                m * n,
            ),
            WGSLBuffer(
                "dimensions", self._next_binding(), 0, WGSLType.VEC3F, "read"
            ),  # M, N, K
        ]

        source = f"""
// Matrix Multiplication Kernel: C = A @ B
// A: ({m} x {k}), B: ({k} x {n}), C: ({m} x {n})
// Tile size: {tile_size}x{tile_size}

@group(0) @binding(0) var<storage, read> matrix_a: array<f32>;
@group(0) @binding(1) var<storage, read> matrix_b: array<f32>;
@group(0) @binding(2) var<storage, read_write> matrix_c: array<f32>;
@group(0) @binding(3) var<uniform> dimensions: vec3<u32>;  // M, N, K

// Shared memory tiles for blocking
var<workgroup> tile_a: array<f32, {tile_size * tile_size}>;
var<workgroup> tile_b: array<f32, {tile_size * tile_size}>;

@compute @workgroup_size({tile_size}, {tile_size}, 1)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) workgroup_id: vec3<u32>
) {{
    let M = dimensions.x;
    let N = dimensions.y;
    let K = dimensions.z;

    let row = global_id.y;
    let col = global_id.x;

    let local_row = local_id.y;
    let local_col = local_id.x;

    var sum: f32 = 0.0;

    // Number of tiles needed to cover K dimension
    let num_tiles = (K + {tile_size}u - 1u) / {tile_size}u;

    for (var t: u32 = 0u; t < num_tiles; t = t + 1u) {{
        // Load tile from A into shared memory
        let a_row = row;
        let a_col = t * {tile_size}u + local_col;
        if (a_row < M && a_col < K) {{
            tile_a[local_row * {tile_size}u + local_col] = matrix_a[a_row * K + a_col];
        }} else {{
            tile_a[local_row * {tile_size}u + local_col] = 0.0;
        }}

        // Load tile from B into shared memory
        let b_row = t * {tile_size}u + local_row;
        let b_col = col;
        if (b_row < K && b_col < N) {{
            tile_b[local_row * {tile_size}u + local_col] = matrix_b[b_row * N + b_col];
        }} else {{
            tile_b[local_row * {tile_size}u + local_col] = 0.0;
        }}

        // Synchronize to ensure tile is loaded
        workgroupBarrier();

        // Compute partial dot product for this tile
        for (var i: u32 = 0u; i < {tile_size}u; i = i + 1u) {{
            sum = sum + tile_a[local_row * {tile_size}u + i] * tile_b[i * {tile_size}u + local_col];
        }}

        // Synchronize before loading next tile
        workgroupBarrier();
    }}

    // Write result
    if (row < M && col < N) {{
        matrix_c[row * N + col] = sum;
    }}
}}
"""

        return WGSLKernel(
            name="matmul",
            source=source,
            workgroup_size=(tile_size, tile_size, 1),
            buffers=buffers,
            entry_point="main",
        )

    def generate_dot_kernel(self, n: int) -> WGSLKernel:
        """
        Generate a dot product kernel with parallel reduction.

        Computes: result = sum(a[i] * b[i]) for i in 0..n

        Uses workgroup reduction for efficiency.

        Args:
            n: Length of input vectors

        Returns:
            WGSLKernel with shader code and buffer bindings
        """
        self._reset_bindings()

        workgroup_size = 256

        buffers = [
            WGSLBuffer(
                "vector_a", self._next_binding(), 0, WGSLType.ARRAY_F32, "read", n
            ),
            WGSLBuffer(
                "vector_b", self._next_binding(), 0, WGSLType.ARRAY_F32, "read", n
            ),
            WGSLBuffer("result", self._next_binding(), 0, WGSLType.F32, "read_write"),
            WGSLBuffer("length", self._next_binding(), 0, WGSLType.U32, "read"),
        ]

        source = f"""
// Dot Product Kernel with Parallel Reduction
// result = sum(a[i] * b[i])

@group(0) @binding(0) var<storage, read> vector_a: array<f32>;
@group(0) @binding(1) var<storage, read> vector_b: array<f32>;
@group(0) @binding(2) var<storage, read_write> result: atomic<u32>;  // Use atomic for reduction
@group(0) @binding(3) var<uniform> length: u32;

var<workgroup> shared_data: array<f32, {workgroup_size}>;

@compute @workgroup_size({workgroup_size}, 1, 1)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(workgroup_id) workgroup_id: vec3<u32>
) {{
    let tid = local_id.x;
    let gid = global_id.x;

    // Each thread computes one product
    var product: f32 = 0.0;
    if (gid < length) {{
        product = vector_a[gid] * vector_b[gid];
    }}
    shared_data[tid] = product;

    workgroupBarrier();

    // Parallel reduction in shared memory
    for (var stride: u32 = {workgroup_size // 2}u; stride > 0u; stride = stride >> 1u) {{
        if (tid < stride) {{
            shared_data[tid] = shared_data[tid] + shared_data[tid + stride];
        }}
        workgroupBarrier();
    }}

    // Thread 0 writes result (using atomics for multi-workgroup accumulation)
    if (tid == 0u) {{
        // Convert float to bits for atomic add
        let bits = bitcast<u32>(shared_data[0]);
        atomicAdd(&result, bits);
    }}
}}
"""

        return WGSLKernel(
            name="dot",
            source=source,
            workgroup_size=(workgroup_size, 1, 1),
            buffers=buffers,
            entry_point="main",
        )

    def generate_norm_kernel(self, n: int) -> WGSLKernel:
        """
        Generate a vector norm kernel (L2 norm / Euclidean norm).

        Computes: result = sqrt(sum(x[i]^2))

        Args:
            n: Length of input vector

        Returns:
            WGSLKernel with shader code and buffer bindings
        """
        self._reset_bindings()

        workgroup_size = 256

        buffers = [
            WGSLBuffer(
                "vector", self._next_binding(), 0, WGSLType.ARRAY_F32, "read", n
            ),
            WGSLBuffer("result", self._next_binding(), 0, WGSLType.F32, "read_write"),
            WGSLBuffer("length", self._next_binding(), 0, WGSLType.U32, "read"),
        ]

        source = f"""
// Vector Norm Kernel (L2/Euclidean Norm)
// result = sqrt(sum(x[i]^2))

@group(0) @binding(0) var<storage, read> vector: array<f32>;
@group(0) @binding(1) var<storage, read_write> result: array<f32>;  // [0] = sum, [1] = final norm
@group(0) @binding(2) var<uniform> length: u32;

var<workgroup> shared_data: array<f32, {workgroup_size}>;

@compute @workgroup_size({workgroup_size}, 1, 1)
fn main(
    @builtin(global_invocation_id) global_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
    @builtin(num_workgroups) num_workgroups: vec3<u32>
) {{
    let tid = local_id.x;
    let gid = global_id.x;

    // Each thread computes squared value
    var squared: f32 = 0.0;
    if (gid < length) {{
        let val = vector[gid];
        squared = val * val;
    }}
    shared_data[tid] = squared;

    workgroupBarrier();

    // Parallel reduction
    for (var stride: u32 = {workgroup_size // 2}u; stride > 0u; stride = stride >> 1u) {{
        if (tid < stride) {{
            shared_data[tid] = shared_data[tid] + shared_data[tid + stride];
        }}
        workgroupBarrier();
    }}

    // Thread 0 accumulates partial sum
    if (tid == 0u) {{
        result[0] = result[0] + shared_data[0];
    }}
}}

// Second pass kernel to compute sqrt
@compute @workgroup_size(1, 1, 1)
fn finalize() {{
    result[1] = sqrt(result[0]);
}}
"""

        return WGSLKernel(
            name="norm",
            source=source,
            workgroup_size=(workgroup_size, 1, 1),
            buffers=buffers,
            entry_point="main",
        )

    def generate_elementwise_kernel(self, operation: str, n: int) -> WGSLKernel:
        """
        Generate an element-wise operation kernel.

        Supports: add, sub, mul, div, scale

        Args:
            operation: One of "add", "sub", "mul", "div", "scale"
            n: Length of vectors

        Returns:
            WGSLKernel with shader code and buffer bindings
        """
        self._reset_bindings()

        workgroup_size = 256

        # Determine operation and buffers
        if operation == "scale":
            buffers = [
                WGSLBuffer(
                    "input", self._next_binding(), 0, WGSLType.ARRAY_F32, "read", n
                ),
                WGSLBuffer("scalar", self._next_binding(), 0, WGSLType.F32, "read"),
                WGSLBuffer(
                    "output",
                    self._next_binding(),
                    0,
                    WGSLType.ARRAY_F32,
                    "read_write",
                    n,
                ),
                WGSLBuffer("length", self._next_binding(), 0, WGSLType.U32, "read"),
            ]
            op_code = "input[gid] * scalar"
            bindings = """
@group(0) @binding(0) var<storage, read> input: array<f32>;
@group(0) @binding(1) var<uniform> scalar: f32;
@group(0) @binding(2) var<storage, read_write> output: array<f32>;
@group(0) @binding(3) var<uniform> length: u32;
"""
        else:
            buffers = [
                WGSLBuffer(
                    "input_a", self._next_binding(), 0, WGSLType.ARRAY_F32, "read", n
                ),
                WGSLBuffer(
                    "input_b", self._next_binding(), 0, WGSLType.ARRAY_F32, "read", n
                ),
                WGSLBuffer(
                    "output",
                    self._next_binding(),
                    0,
                    WGSLType.ARRAY_F32,
                    "read_write",
                    n,
                ),
                WGSLBuffer("length", self._next_binding(), 0, WGSLType.U32, "read"),
            ]

            op_map = {
                "add": "input_a[gid] + input_b[gid]",
                "sub": "input_a[gid] - input_b[gid]",
                "mul": "input_a[gid] * input_b[gid]",
                "div": "input_a[gid] / input_b[gid]",
            }
            op_code = op_map.get(operation, "input_a[gid] + input_b[gid]")

            bindings = """
@group(0) @binding(0) var<storage, read> input_a: array<f32>;
@group(0) @binding(1) var<storage, read> input_b: array<f32>;
@group(0) @binding(2) var<storage, read_write> output: array<f32>;
@group(0) @binding(3) var<uniform> length: u32;
"""

        source = f"""
// Element-wise {operation.upper()} Kernel
{bindings}

@compute @workgroup_size({workgroup_size}, 1, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {{
    let gid = global_id.x;

    if (gid < length) {{
        output[gid] = {op_code};
    }}
}}
"""

        return WGSLKernel(
            name=f"elementwise_{operation}",
            source=source,
            workgroup_size=(workgroup_size, 1, 1),
            buffers=buffers,
            entry_point="main",
        )

    def generate_from_gpu_block(self, node: GPUBlock) -> List[WGSLKernel]:
        """
        Generate WGSL kernels from a GPU block AST node.

        Analyzes the GPU block to identify:
        1. Matrix operations that benefit from GPU
        2. Element-wise operations
        3. Reduction operations

        Returns a list of kernels that implement the block.

        Args:
            node: GPUBlock AST node

        Returns:
            List of WGSLKernel objects
        """
        kernels = []

        for stmt in node.body:
            kernel = self._analyze_statement(stmt)
            if kernel:
                kernels.append(kernel)

        return kernels

    def _analyze_statement(self, stmt: ASTNode) -> Optional[WGSLKernel]:
        """
        Analyze a statement to determine if it can be GPU-accelerated.

        Identifies patterns like:
        - matmul of [A, B]
        - norm of x
        - x + y (element-wise)
        """
        if isinstance(stmt, Assignment):
            return self._analyze_expression(stmt.expression)
        elif isinstance(stmt, Relation):
            return self._analyze_relation(stmt)
        return None

    def _analyze_expression(self, expr: ASTNode) -> Optional[WGSLKernel]:
        """Analyze expression for GPU-acceleratable operations."""
        if isinstance(expr, Relation):
            return self._analyze_relation(expr)
        elif isinstance(expr, BinaryOp):
            return self._analyze_binary_op(expr)
        return None

    def _analyze_relation(self, rel: Relation) -> Optional[WGSLKernel]:
        """
        Analyze a Relation (OF operator) for GPU operations.

        Patterns:
        - matmul of [A, B] → matmul kernel
        - norm of x → norm kernel
        - dot of [a, b] → dot kernel
        """
        if isinstance(rel.left, Identifier):
            func_name = rel.left.name.lower()

            if func_name == "matmul":
                # For now, generate placeholder with dynamic sizing
                return self.generate_matmul_kernel(256, 256, 256)
            elif func_name == "norm":
                return self.generate_norm_kernel(1024)
            elif func_name == "dot":
                return self.generate_dot_kernel(1024)

        return None

    def _analyze_binary_op(self, op: BinaryOp) -> Optional[WGSLKernel]:
        """
        Analyze binary operation for element-wise GPU kernel.

        Patterns:
        - a + b → elementwise_add
        - a * b → elementwise_mul (if both are arrays)
        """
        op_map = {
            "+": "add",
            "-": "sub",
            "*": "mul",
            "/": "div",
        }

        if op.operator in op_map:
            return self.generate_elementwise_kernel(op_map[op.operator], 1024)

        return None


def generate_webgpu_runtime() -> str:
    """
    Generate the JavaScript/TypeScript WebGPU runtime code.

    This provides the bridge between EigenScript and WebGPU:
    - Buffer management
    - Kernel dispatch
    - Host↔Device transfers
    - GPU-lite EigenValue synchronization
    """
    return """
/**
 * EigenScript WebGPU Runtime
 *
 * Provides GPU acceleration for EigenScript matrix operations.
 * Implements the GPU-lite EigenValue model for efficient geometric tracking.
 */

class EigenGPU {
    constructor() {
        this.device = null;
        this.adapter = null;
        this.pipelines = new Map();
        this.buffers = new Map();
    }

    async initialize() {
        if (!navigator.gpu) {
            throw new Error("WebGPU not supported in this browser");
        }

        this.adapter = await navigator.gpu.requestAdapter();
        if (!this.adapter) {
            throw new Error("Failed to get GPU adapter");
        }

        this.device = await this.adapter.requestDevice();
        console.log("EigenGPU initialized:", this.adapter.name);
        return this;
    }

    /**
     * Create a GPU buffer from CPU data.
     * @param {Float32Array} data - CPU data to upload
     * @param {string} usage - Buffer usage ("storage", "uniform", "read", "write")
     * @returns {GPUBuffer} - Created buffer
     */
    createBuffer(data, usage = "storage") {
        const usageFlags = {
            storage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC,
            uniform: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
            read: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
            write: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC,
        };

        const buffer = this.device.createBuffer({
            size: data.byteLength,
            usage: usageFlags[usage] || usageFlags.storage,
            mappedAtCreation: true,
        });

        new Float32Array(buffer.getMappedRange()).set(data);
        buffer.unmap();

        return buffer;
    }

    /**
     * Read data from GPU buffer back to CPU.
     * @param {GPUBuffer} buffer - GPU buffer to read
     * @param {number} size - Size in bytes
     * @returns {Promise<Float32Array>} - CPU data
     */
    async readBuffer(buffer, size) {
        const stagingBuffer = this.device.createBuffer({
            size: size,
            usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
        });

        const commandEncoder = this.device.createCommandEncoder();
        commandEncoder.copyBufferToBuffer(buffer, 0, stagingBuffer, 0, size);
        this.device.queue.submit([commandEncoder.finish()]);

        await stagingBuffer.mapAsync(GPUMapMode.READ);
        const result = new Float32Array(stagingBuffer.getMappedRange().slice(0));
        stagingBuffer.unmap();
        stagingBuffer.destroy();

        return result;
    }

    /**
     * Compile and cache a compute pipeline from WGSL source.
     * @param {string} name - Pipeline name for caching
     * @param {string} wgslSource - WGSL shader source
     * @returns {GPUComputePipeline} - Compiled pipeline
     */
    async createPipeline(name, wgslSource) {
        if (this.pipelines.has(name)) {
            return this.pipelines.get(name);
        }

        const shaderModule = this.device.createShaderModule({
            code: wgslSource,
        });

        const pipeline = await this.device.createComputePipelineAsync({
            layout: "auto",
            compute: {
                module: shaderModule,
                entryPoint: "main",
            },
        });

        this.pipelines.set(name, pipeline);
        return pipeline;
    }

    /**
     * Dispatch a compute kernel.
     * @param {string} pipelineName - Name of cached pipeline
     * @param {Array<GPUBuffer>} buffers - Buffers to bind
     * @param {Array<number>} workgroups - [x, y, z] workgroup counts
     */
    async dispatch(pipelineName, buffers, workgroups) {
        const pipeline = this.pipelines.get(pipelineName);
        if (!pipeline) {
            throw new Error(`Pipeline "${pipelineName}" not found`);
        }

        // Create bind group
        const bindGroupEntries = buffers.map((buffer, index) => ({
            binding: index,
            resource: { buffer },
        }));

        const bindGroup = this.device.createBindGroup({
            layout: pipeline.getBindGroupLayout(0),
            entries: bindGroupEntries,
        });

        // Encode and submit
        const commandEncoder = this.device.createCommandEncoder();
        const passEncoder = commandEncoder.beginComputePass();
        passEncoder.setPipeline(pipeline);
        passEncoder.setBindGroup(0, bindGroup);
        passEncoder.dispatchWorkgroups(...workgroups);
        passEncoder.end();

        this.device.queue.submit([commandEncoder.finish()]);
        await this.device.queue.onSubmittedWorkDone();
    }

    /**
     * Matrix multiplication: C = A @ B
     * @param {Float32Array} a - Matrix A (M x K), row-major
     * @param {Float32Array} b - Matrix B (K x N), row-major
     * @param {number} m - Rows of A
     * @param {number} n - Columns of B
     * @param {number} k - Columns of A / Rows of B
     * @returns {Promise<Float32Array>} - Result matrix C (M x N)
     */
    async matmul(a, b, m, n, k) {
        const bufferA = this.createBuffer(a, "read");
        const bufferB = this.createBuffer(b, "read");
        const bufferC = this.createBuffer(new Float32Array(m * n), "storage");
        const bufferDims = this.createBuffer(new Uint32Array([m, n, k]), "uniform");

        // Dispatch with appropriate workgroup counts
        const tileSize = 16;
        const workgroupsX = Math.ceil(n / tileSize);
        const workgroupsY = Math.ceil(m / tileSize);

        await this.dispatch("matmul", [bufferA, bufferB, bufferC, bufferDims], [workgroupsX, workgroupsY, 1]);

        const result = await this.readBuffer(bufferC, m * n * 4);

        // Cleanup
        bufferA.destroy();
        bufferB.destroy();
        bufferC.destroy();
        bufferDims.destroy();

        return result;
    }

    /**
     * GPU-lite EigenValue: Sync gradient from GPU to full CPU tracking.
     * Called when an observation (why, how, etc.) is made on a GPU value.
     * @param {Float32Array} gpuData - [value, gradient] from GPU
     * @returns {Object} - Full EigenValue with stability, history, etc.
     */
    promoteToFullEigenValue(gpuData) {
        return {
            value: gpuData[0],
            gradient: gpuData[1],
            stability: 1.0,  // Assume stable on first observation
            iteration: 1,
            history: [gpuData[0]],
            prev_value: gpuData[0],
            prev_gradient: 0.0,
        };
    }

    destroy() {
        // Cleanup all buffers
        for (const buffer of this.buffers.values()) {
            buffer.destroy();
        }
        this.buffers.clear();
        this.pipelines.clear();
    }
}

// Export for module usage
if (typeof module !== "undefined") {
    module.exports = { EigenGPU };
}
"""
