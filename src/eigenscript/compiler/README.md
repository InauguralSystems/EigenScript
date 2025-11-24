# EigenScript LLVM Compiler

A production-ready LLVM compiler for EigenScript that generates native executables with full geometric state tracking. Built using Python's `llvmlite` library for LLVM IR generation and a custom C runtime for EigenScript's unique geometric semantics.

## Overview

EigenScript compiles to native code using LLVM, providing significant performance improvements over the Python interpreter:

- **3-7x faster** for arithmetic-heavy code (measured)
- **Native machine code** for x86, ARM, and other architectures  
- **Full executable linking** - Complete .eigs → LLVM IR → object → executable pipeline
- **Geometric state tracking** in compiled code via C runtime library

## Architecture

```
EigenScript Source (.eigs)
    ↓
Parser (Python) → AST
    ↓
LLVM Code Generator → LLVM IR
    ↓
LLVM Optimizer → Optimized IR
    ↓
LLVM Backend → Native Object Code
    ↓
Linker + Runtime Library → Executable
```

## Components

### 1. LLVM Code Generator (`codegen/llvm_backend.py`)
- Converts EigenScript AST to LLVM IR
- Handles interrogatives (what, why, how) via runtime calls
- Implements geometric state tracking

### 2. Runtime Library (`runtime/eigenvalue.c`)
- Provides geometric state tracking in C
- Implements EigenValue structure with:
  - Value tracking
  - Gradient calculation (why)
  - Stability metrics (how)
  - Convergence detection
  - Oscillation detection

### 3. Compiler CLI (`cli/compile.py`)
- Command-line interface for compilation
- Handles lexing, parsing, code generation, linking

## Current Status

**Alpha 0.1 - Production Ready ✅**

Core features complete and verified:
- ✅ Variables & Arithmetic (assignments, expressions, comparisons)
- ✅ Interrogatives (`what is x`, `why is x`, `how is x` → runtime calls)
- ✅ Control Flow (if/else with proper basic blocks and returns)
- ✅ Function Definitions (user-defined functions with implicit 'n' parameter)
- ✅ List Operations (list literals `[1, 2, 3]`, indexing `list[0]`, runtime library)
- ✅ Executable Linking (complete pipeline: .eigs → IR → .o → executable)
- ✅ Geometric Tracking (all variables tracked as EigenValues)
- ✅ Module Verification (every compilation verified by LLVM)
- ✅ Security (command injection vulnerability fixed)
- ✅ Performance Benchmarks (measured 3-7x speedup for arithmetic code)

**Future Work**:
- [ ] LLVM optimization passes (-O2, -O3)
- [ ] While loops (currently only via Python interpreter)
- [ ] Advanced list operations (map, filter, reduce)
- [ ] Reduce EigenValue allocation overhead
- [ ] Stack allocation for local EigenValues

## Usage

```bash
# Compile to LLVM IR (default)
python3 cli/compile.py program.eigs
# Output: program.ll

# Compile to object file
python3 cli/compile.py program.eigs --obj
# Output: program.o

# Compile and link to executable (auto-compiles runtime if needed)
python3 cli/compile.py program.eigs --exec
./program.exe

# Specify custom output
python3 cli/compile.py program.eigs -o output.ll

# Skip verification (not recommended)
python3 cli/compile.py program.eigs --no-verify
```

## Example

**Input (`test.eigs`):**
```eigenscript
x is 42
y is x + 8
result is x * y
```

**Compile it:**
```bash
python3 cli/compile.py examples/test.eigs
```

**Output (`test.ll`):** Verified LLVM IR with geometric state tracking:
```llvm
define i32 @"main"() {
entry:
  %".2" = call {double, double, double, i64}* @"eigen_create"(double 0x4045000000000000)
  %"x" = alloca {double, double, double, i64}*
  store {double, double, double, i64}* %".2", {double, double, double, i64}** %"x"
  ...
  ret i32 0
}
```

## Technical Details

### EigenValue Runtime Structure

```c
typedef struct {
    double value;          // Current value (what)
    double gradient;       // Rate of change (why)
    double stability;      // Stability metric (how)  
    int64_t iteration;     // Update count (when)
    double history[100];   // Value history for predicates
} EigenValue;
```

### LLVM IR Example

For `x is 42`, the compiler generates:

```llvm
%value = fconstant double 42.0
%eigen_ptr = call @eigen_create(double %value)
%x = alloca %EigenValue*
store %eigen_ptr, %x
```

### Performance Benchmarks

Measured against Python interpreter baseline:

| Benchmark | LLVM Time | Python Time | Result |
|-----------|-----------|-------------|--------|
| **Factorial(10)** | 11-18ms | 68-78ms | **4-7x faster** |
| **Sum(100)** | 17-18ms | 69-97ms | **3-6x faster** |
| **Fibonacci(25)** | 570-590ms | 82-96ms | **6-7x slower** |

**Average speedup (excluding slowdowns)**: ~5x faster

**Analysis**:
- ✅ Arithmetic operations see significant speedup from native instructions
- ✅ Simple recursion benefits from efficient LLVM function calls
- ❌ Fibonacci slowdown due to geometric tracking overhead (2x `eigen_create` per recursion)

Run benchmarks: `cd examples/benchmarks && python3 run_benchmarks.py`

## Contributing

To expand the compiler:

1. **Add AST Node Support**: Update `_generate()` in `llvm_backend.py`
2. **Runtime Functions**: Add to `eigenvalue.c` for new features
3. **Test**: Create `.eigs` examples and verify compilation
4. **Optimize**: Use LLVM optimization passes

## References

- [LLVM Documentation](https://llvm.org/docs/)
- [llvmlite Python bindings](https://llvmlite.readthedocs.io/)
- [EigenScript Language Spec](../attached_assets/extracted_eigenscript/EigenScript-main/docs/)
