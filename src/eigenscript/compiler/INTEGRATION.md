# EigenScript LLVM Compiler Integration

## Overview

This directory contains the LLVM compiler for EigenScript, integrated from the `Has_compiler.zip` archive. The compiler provides native code generation capabilities, enabling significant performance improvements over the Python interpreter.

## Installation

### Basic Installation (Interpreter Only)
```bash
pip install eigenscript
```

### With Compiler Support
```bash
pip install eigenscript[compiler]
```

This installs the additional dependency:
- `llvmlite>=0.41.0` - Python bindings for LLVM

### System Requirements

The compiler also requires:
- **GCC or Clang** - For linking native executables
- **LLVM** - Installed system-wide (usually comes with llvmlite)

On Ubuntu/Debian:
```bash
sudo apt-get install gcc build-essential
```

On macOS:
```bash
xcode-select --install
```

## Usage

### Command Line

Compile EigenScript to LLVM IR:
```bash
eigenscript-compile program.eigs
```

Compile to object file:
```bash
eigenscript-compile program.eigs --obj
```

Compile and link to executable:
```bash
eigenscript-compile program.eigs --exec
./program.exe
```

With optimizations:
```bash
eigenscript-compile program.eigs --exec -O2
```

### Programmatic API

```python
from eigenscript.compiler.cli.compile import compile_file

# Compile to LLVM IR
result = compile_file("program.eigs", verify=True)

# Compile to executable
result = compile_file("program.eigs", link_exec=True, opt_level=2)
```

### Direct Code Generation

```python
from eigenscript.lexer import Tokenizer
from eigenscript.parser.ast_builder import Parser
from eigenscript.compiler.codegen.llvm_backend import LLVMCodeGenerator

source_code = "x is 42\ny is x + 8"

# Tokenize and parse
tokenizer = Tokenizer(source_code)
tokens = tokenizer.tokenize()
parser = Parser(tokens)
ast = parser.parse()

# Generate LLVM IR
codegen = LLVMCodeGenerator()
llvm_ir = codegen.compile(ast.statements)
print(llvm_ir)
```

## Architecture

### Components

1. **`codegen/llvm_backend.py`** - Main LLVM IR generator
   - Converts EigenScript AST to LLVM IR
   - Handles all language constructs
   - ~750 lines of code

2. **`runtime/eigenvalue.c`** - C runtime library
   - Implements geometric state tracking
   - Provides EigenValue structure
   - Runtime functions for interrogatives and predicates
   - ~230 lines of C code

3. **`runtime/eigenvalue.h`** - Runtime header
   - API definitions
   - Structure declarations
   - Constants and thresholds

4. **`cli/compile.py`** - Command-line interface
   - File I/O handling
   - Compilation pipeline orchestration
   - Optimization pass management
   - Linking and executable generation

### Compilation Pipeline

```
EigenScript Source (.eigs)
    ↓
Tokenizer → Tokens
    ↓
Parser → AST
    ↓
LLVMCodeGenerator → LLVM IR
    ↓
LLVM Optimizer (optional -O1/-O2/-O3)
    ↓
LLVM Backend → Object Code (.o)
    ↓
GCC Linker + Runtime → Executable (.exe)
```

### EigenValue Runtime

Every variable is wrapped in an `EigenValue` structure:

```c
typedef struct {
    double value;          // Current value (what)
    double gradient;       // Rate of change (why)
    double stability;      // Stability metric (how)
    int64_t iteration;     // Update count (when)
    double history[100];   // Value history
    // ... internal fields
} EigenValue;
```

This enables:
- **Interrogatives**: `what is x`, `why is x`, `how is x`
- **Predicates**: `converged`, `stable`, `diverging`, `oscillating`, `improving`
- **Geometric self-awareness**: Programs can introspect their execution

## Performance

### Benchmarks

From `examples/compiler/benchmarks/`:

| Benchmark | LLVM | Python | Speedup |
|-----------|------|--------|---------|
| Factorial(10) | 10-18ms | 68-78ms | **4-7x faster** ✅ |
| Sum(100) | 17-18ms | 69-97ms | **3-6x faster** ✅ |
| Fibonacci(25) | 570-590ms | 82-96ms | **6-7x slower** ❌ |

**Summary**:
- ✅ Arithmetic-heavy code: **3-7x speedup**
- ❌ Deep recursion: **6-7x slower** (due to EigenValue allocation overhead)
- Average (excluding slowdowns): **~5x faster**

### Optimization Levels

- `-O0` (default): No optimization, fast compilation
- `-O1`: Basic optimizations
- `-O2`: Moderate optimizations, vectorization
- `-O3`: Aggressive optimizations

Example:
```bash
eigenscript-compile factorial.eigs --exec -O2
```

## Features

### Supported Language Constructs

✅ **Variables and Arithmetic**
```eigenscript
x is 42
y is x + 8
result is x * y
```

✅ **Functions**
```eigenscript
define double as:
    result is n * 2
    return result

y is double of 5
```

✅ **Control Flow**
```eigenscript
if x > 10:
    y is 1
else:
    y is 0
```

✅ **Lists**
```eigenscript
numbers is [1, 2, 3, 4, 5]
first is numbers[0]
```

✅ **Interrogatives**
```eigenscript
x is 100
value is what is x      # Get current value
rate is why is x        # Get gradient
quality is how is x     # Get stability
```

✅ **Geometric Predicates**
```eigenscript
if converged:
    return result

if diverging:
    print of 999
    return 0

if stable:
    continue_optimization
```

### Limitations

❌ **While Loops** - Currently limited (use recursion instead)
❌ **Advanced List Operations** - map/filter/reduce not yet implemented
❌ **Memory Management** - No automatic cleanup of EigenValues (potential leaks)

## Security

✅ **Command Injection** - Fixed in November 2025
- All subprocess calls use list arguments
- No `shell=True` usage
- See `SECURITY_AUDIT.md` for full details

## Testing

Run compiler tests:
```bash
# Install test dependencies
pip install eigenscript[dev,compiler]

# Run tests
pytest tests/compiler/
```

Tests cover:
- Code generation for all language constructs
- LLVM IR verification
- Example program compilation
- CLI interface

## Examples

Located in `examples/compiler/`:

- `test.eigs` - Basic arithmetic
- `functions.eigs` - Function definitions
- `adaptive_sqrt.eigs` - Self-aware Newton's method
- `list.eigs` - List operations
- `predicate_test.eigs` - Geometric predicates
- `benchmarks/` - Performance benchmarks

## Documentation

- `README.md` - Original compiler documentation
- `docs/SELF_SIMULATION.md` - Predicate implementation details
- `../../COMPILER_REVIEW.md` - Integration review
- `../../SECURITY_AUDIT.md` - Security analysis

## Development

### Building from Source

```bash
# Clone repository
git clone https://github.com/InauguralPhysicist/eigenscript.git
cd eigenscript

# Install in development mode with compiler
pip install -e .[dev,compiler]

# Run tests
pytest tests/compiler/
```

### Modifying the Compiler

1. **Add AST node support**: Update `_generate()` in `llvm_backend.py`
2. **Add runtime functions**: Update `eigenvalue.c` and `eigenvalue.h`
3. **Test changes**: Add tests to `tests/compiler/`
4. **Verify**: Ensure all examples still compile

### Debugging

Enable verification (default):
```bash
eigenscript-compile program.eigs --verify
```

Inspect generated IR:
```bash
eigenscript-compile program.eigs
cat program.ll
```

## Known Issues

See `../../KNOWN_ISSUES.md` for current limitations and workarounds.

## Future Work

- [ ] Enable more LLVM optimization passes
- [ ] Reduce EigenValue allocation overhead
- [ ] Implement proper memory management
- [ ] Complete while loop support
- [ ] Add memoization for recursive functions
- [ ] Stack allocation for local EigenValues
- [ ] Lazy geometric tracking

## References

- [LLVM Documentation](https://llvm.org/docs/)
- [llvmlite Python bindings](https://llvmlite.readthedocs.io/)
- [EigenScript Language Docs](../../../docs/)

## Credits

Original compiler implementation from `Has_compiler.zip` archive, integrated November 2025.

---

**Status**: Alpha 0.1 - Production ready with known limitations
**Last Updated**: 2025-11-21
