# EigenScript Compiler Self-Hosting Guide

## Overview

EigenScript includes a **self-hosted compiler** - a complete EigenScript compiler written entirely in EigenScript. This is a major milestone demonstrating that EigenScript is powerful enough to implement its own compilation pipeline.

### What is Compiler Self-Hosting?

Compiler self-hosting means that the language compiler is written in the language itself. For EigenScript, this means:
- The lexer is written in EigenScript (`lexer.eigs`)
- The parser is written in EigenScript (`parser.eigs`)  
- The semantic analyzer is written in EigenScript (`semantic.eigs`)
- The code generator is written in EigenScript (`codegen.eigs`)

This demonstrates:
1. **Language Completeness** - EigenScript has sufficient features to implement a compiler
2. **Practical Power** - The language can handle real-world, complex programs
3. **Dogfooding** - We use the language to build its own tools
4. **Bootstrap Path** - Foundation for future full bootstrapping

### Two Types of Self-Hosting

EigenScript has achieved two different types of self-hosting:

1. **Meta-Circular Evaluator** (✅ Complete)
   - An EigenScript interpreter written in EigenScript
   - See [docs/meta_circular_evaluator.md](./meta_circular_evaluator.md)
   - Located in [examples/eval.eigs](../examples/eval.eigs)

2. **Compiler Self-Hosting** (⚠️ Partial - this document)
   - An EigenScript compiler written in EigenScript
   - Compiles EigenScript to LLVM IR
   - Located in `src/eigenscript/compiler/selfhost/`

## Current Status (v0.4.0)

### ✅ What Works

- **Reference Compiler Stage**: The Python-based reference compiler can successfully compile the self-hosted compiler
- **Stage 1 Compiler**: The compiled self-hosted compiler can:
  - Parse simple EigenScript programs
  - Generate valid LLVM IR output
  - Link with the EigenScript runtime library
- **Module System**: All four compiler modules (lexer, parser, semantic, codegen) compile and link correctly

### ⚠️ Known Limitations

- **Runtime Bugs**: Stage 1 compiler has issues with print output (produces 0 instead of correct values)
- **Parser Limitation**: The parser cannot handle blank lines inside function bodies, which prevents the compiler from compiling itself (full bootstrap)
- **No Full Bootstrap**: Stage 1 cannot yet compile itself to produce Stage 2

### 🎯 Future Goals

- Fix print/runtime issues in Stage 1
- Enhance parser to handle blank lines in function bodies
- Achieve full bootstrap (Stage 1 compiling itself)
- Verify Stage 1 and Stage 2 produce identical output

## Architecture

The self-hosted compiler consists of four modules:

```
┌─────────────────────────────────────────────────────────────┐
│                    EigenScript Source Code                    │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  lexer.eigs            │  Tokenization                       │
│  - String processing   │  - Recognize keywords, operators    │
│  - Token generation    │  - Track line/column numbers        │
└────────────────────────┼────────────────────────────────────┘
                         │ Tokens
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  parser.eigs           │  Syntax Analysis                    │
│  - Token parsing       │  - Build Abstract Syntax Tree (AST) │
│  - AST construction    │  - Handle all language constructs   │
└────────────────────────┼────────────────────────────────────┘
                         │ AST
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  semantic.eigs         │  Semantic Analysis                  │
│  - Variable scoping    │  - Detect undefined variables       │
│  - Symbol tables       │  - Type checking (basic)            │
└────────────────────────┼────────────────────────────────────┘
                         │ Validated AST
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  codegen.eigs          │  Code Generation                    │
│  - LLVM IR generation  │  - Generate functions, control flow │
│  - Runtime calls       │  - Link with C runtime library      │
└────────────────────────┼────────────────────────────────────┘
                         │ LLVM IR (text)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              LLVM Toolchain (llvm-as, llc, gcc)              │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                    Native Executable                          │
└─────────────────────────────────────────────────────────────┘
```

## How to Use the Self-Hosted Compiler

### Prerequisites

1. **Install EigenScript**:
   ```bash
   pip install -e .[compiler]
   ```

2. **Install LLVM Tools**:
   ```bash
   # Ubuntu/Debian
   sudo apt-get install llvm gcc
   
   # macOS
   brew install llvm gcc
   ```

3. **Verify Installation**:
   ```bash
   which eigenscript-compile llvm-as llc gcc
   ```

### Running the Bootstrap Test

The bootstrap test script demonstrates the self-hosting capability:

```bash
# Run the complete bootstrap test
bash scripts/bootstrap_test.sh
```

This script performs the following stages:

1. **Stage 0 → Stage 1**: Compile self-hosted compiler with reference compiler
2. **Test Stage 1**: Verify Stage 1 can compile simple programs
3. **Bootstrap Attempt**: Try to have Stage 1 compile itself (currently fails)

### Manual Compilation Steps

If you want to compile the self-hosted compiler manually:

#### Step 1: Compile the Self-Hosted Compiler Modules

```bash
# Create build directory
mkdir -p build/bootstrap
cd build/bootstrap

# Set paths
SELFHOST_DIR="../../src/eigenscript/compiler/selfhost"
RUNTIME_DIR="../../src/eigenscript/compiler/runtime"

# Compile each module to LLVM IR
eigenscript-compile "$SELFHOST_DIR/lexer.eigs" -o lexer.ll -O0 --lib
eigenscript-compile "$SELFHOST_DIR/parser.eigs" -o parser.ll -O0 --lib
eigenscript-compile "$SELFHOST_DIR/semantic.eigs" -o semantic.ll -O0 --lib
eigenscript-compile "$SELFHOST_DIR/codegen.eigs" -o codegen.ll -O0 --lib
eigenscript-compile "$SELFHOST_DIR/main.eigs" -o main.ll -O0
```

**Note**: We use `-O0` because llvmlite (used by the reference compiler) has compatibility issues with optimization passes.

#### Step 2: Compile the Runtime Library

```bash
# Compile the C runtime library
gcc -c "$RUNTIME_DIR/eigenvalue.c" -o eigenvalue.o -O2
```

#### Step 3: Assemble and Link

```bash
# Assemble each LLVM IR module to object code
for module in lexer parser semantic codegen main; do
    llvm-as ${module}.ll -o ${module}.bc
    llc ${module}.bc -o ${module}.s -O2
    gcc -c ${module}.s -o ${module}.o
done

# Link all modules together
gcc lexer.o parser.o semantic.o codegen.o main.o eigenvalue.o \
    -o eigensc -lm

echo "Stage 1 compiler created: eigensc"
```

#### Step 4: Test the Stage 1 Compiler

```bash
# Create a simple test program
cat > test.eigs << 'EOF'
x is 42
y is x + 8
print of y
EOF

# Compile with Stage 1 compiler
./eigensc test.eigs > test.ll

# Verify it generated LLVM IR
if grep -q "define" test.ll; then
    echo "✓ Stage 1 compiler produced valid LLVM IR"
else
    echo "✗ Output is not valid LLVM IR"
fi

# Assemble and run (if needed)
llvm-as test.ll -o test.bc
llc test.bc -o test.s
gcc test.s eigenvalue.o -o test -lm
./test
```

## Module Details

### lexer.eigs

**Purpose**: Tokenize EigenScript source code

**Key Features**:
- String scanning and character processing
- Token type recognition (keywords, operators, literals)
- String and identifier storage with index tracking
- Line and column number tracking for error reporting

**Key Functions**:
- `lexer_set_source(source)` - Set the source code to tokenize
- `lexer_next_token()` - Get the next token
- `lexer_get_string(index)` - Retrieve a stored string by index
- `lexer_get_identifier(index)` - Retrieve an identifier by index

### parser.eigs

**Purpose**: Parse tokens into an Abstract Syntax Tree (AST)

**Key Features**:
- Recursive descent parser
- Handles all EigenScript language constructs
- Error detection with line/column reporting
- AST node storage using parallel arrays

**AST Node Types**:
- Literals, identifiers, binary operations
- Assignments, conditionals, loops
- Function definitions, imports
- Lists, structs, interrogatives

**Key Functions**:
- `parser_parse()` - Parse tokens and return root AST node
- `parser_get_node(index)` - Retrieve AST node by index

### semantic.eigs

**Purpose**: Perform semantic analysis on the AST

**Key Features**:
- Variable scoping (global, function, block, loop)
- Symbol table management
- Undefined variable detection
- Basic type checking

**Key Functions**:
- `semantic_analyze(ast_root)` - Analyze AST and return error count
- `semantic_print_errors()` - Display semantic errors

### codegen.eigs

**Purpose**: Generate LLVM IR from validated AST

**Key Features**:
- LLVM IR text generation
- Register allocation
- Label generation for control flow
- Runtime library function calls
- String constant handling with proper escaping

**Key Functions**:
- `codegen_generate(ast_root)` - Generate LLVM IR
- `codegen_print_ir()` - Output generated IR

**LLVM IR Features**:
- SSA form with phi nodes
- Proper function definitions
- Control flow with branches and labels
- Runtime integration for geometric operations

### main.eigs

**Purpose**: Orchestrate the compilation pipeline

**Key Features**:
- Command-line argument parsing
- Pipeline coordination (lexer → parser → semantic → codegen)
- Error handling and reporting
- File I/O for reading source files

**Usage**:
```bash
./eigensc source.eigs          # Compile and output IR
./eigensc --verbose source.eigs  # Verbose mode
./eigensc --parse-only source.eigs  # Only parse, don't generate
```

## File Locations

```
src/eigenscript/compiler/
├── selfhost/              # Self-hosted compiler source
│   ├── lexer.eigs        # ~700 lines
│   ├── parser.eigs       # ~1800 lines
│   ├── semantic.eigs     # ~600 lines
│   ├── codegen.eigs      # ~2300 lines
│   └── main.eigs         # ~320 lines
├── runtime/              # C runtime library
│   └── eigenvalue.c      # ~1700 lines
└── codegen/              # Reference compiler (Python)
    └── llvm_backend.py

scripts/
└── bootstrap_test.sh     # Bootstrap testing script

docs/
└── COMPILER_SELF_HOSTING.md  # This document
```

## Technical Notes

### Why LLVM IR Text?

The self-hosted compiler generates **textual LLVM IR** rather than bitcode because:
1. Simpler to generate (just string building)
2. Human-readable for debugging
3. Can be assembled with `llvm-as` to bitcode
4. Avoids needing LLVM API bindings in EigenScript

### String Escaping

Special characters in strings must be properly escaped for LLVM IR:
- Newline `\n` → `\0A`
- Tab `\t` → `\09`
- Quotes `"` → `\22`

The codegen module includes an `escape_string` function for this.

### Module Linking

Modules are linked using **name mangling**:
- Function `foo` in module `bar` becomes `bar_foo`
- The reference compiler handles module initialization automatically
- Cross-module calls use mangled names (e.g., `lexer_get_string`)

### Runtime Library

The self-hosted compiler links against the same C runtime library (`eigenvalue.c`) as the reference compiler. This provides:
- `EigenValue` struct for geometric tracking
- List and string operations
- Mathematical functions
- I/O operations

## Troubleshooting

### "eigenscript-compile not found"

Install EigenScript with compiler support:
```bash
pip install -e .[compiler]
```

### "llvm-as not found"

Install LLVM tools:
```bash
# Ubuntu/Debian
sudo apt-get install llvm

# macOS
brew install llvm
```

### Stage 1 Produces Wrong Output

This is a known issue. The Stage 1 compiler has runtime bugs that cause incorrect output values. This is being investigated.

### "Parse error at line X"

The parser cannot handle blank lines inside function bodies. To work around this, remove blank lines from the source file before compiling with Stage 1.

### Compilation is Slow

Use `-O0` optimization level when compiling with the reference compiler, as llvmlite has compatibility issues with optimization passes.

## Performance

### Compilation Times

Approximate times on a modern system:

| Stage | Time | Description |
|-------|------|-------------|
| Reference → Stage 1 | ~30-60s | Compile self-hosted compiler |
| Stage 1 → Simple Program | ~1-5s | Compile hello world |
| Full Bootstrap | N/A | Not yet working |

### Generated Code Size

| Module | Lines of .eigs | Lines of LLVM IR |
|--------|----------------|------------------|
| lexer | ~700 | ~3000 |
| parser | ~1800 | ~8000 |
| semantic | ~600 | ~2500 |
| codegen | ~2300 | ~12000 |
| main | ~320 | ~1500 |
| **Total** | **~5700** | **~27000** |

## Next Steps

To achieve full bootstrap (Stage 1 compiling itself), the following issues need to be resolved:

1. **Parser Enhancement**:
   - Support blank lines inside function bodies
   - Improve error recovery

2. **Runtime Fixes**:
   - Fix print output issues
   - Verify all built-in functions work correctly

3. **Testing**:
   - Expand test suite for self-hosted compiler
   - Add more complex example programs

4. **Optimization**:
   - Enable optimization passes safely
   - Improve compilation speed

## Comparison with Meta-Circular Evaluator

| Feature | Meta-Circular Evaluator | Self-Hosted Compiler |
|---------|------------------------|---------------------|
| **Implementation** | Interpreter in EigenScript | Compiler in EigenScript |
| **Status** | ✅ Complete | ⚠️ Partial |
| **Output** | Direct execution results | LLVM IR code |
| **Use Case** | Education, demonstrations | Production compilation |
| **Bootstrap** | Can evaluate itself | Cannot yet compile itself |
| **Location** | `examples/eval.eigs` | `src/eigenscript/compiler/selfhost/` |
| **Lines of Code** | ~200 | ~5700 |

## Resources

### Related Documentation

- [Meta-Circular Evaluator Guide](./meta_circular_evaluator.md) - Interpreter self-hosting
- [CHANGELOG.md](../CHANGELOG.md) - Release history with v0.4.0 details
- [Self-Hosting Roadmap](./self_hosting_roadmap.md) - Future plans

### Example Code

- `examples/compiler/` - Test programs for the compiler
- `examples/meta_eval.eigs` - Meta-circular evaluator

### Test Scripts

- `scripts/bootstrap_test.sh` - Automated bootstrap testing
- `tests/test_meta_evaluator.py` - Python tests for meta-evaluation

## Contributing

If you'd like to help improve the self-hosted compiler:

1. **Fix Runtime Bugs**: Debug why Stage 1 produces incorrect output
2. **Enhance Parser**: Add support for blank lines in function bodies
3. **Add Tests**: Create more test cases for the self-hosted compiler
4. **Documentation**: Improve this guide with your findings

See [CONTRIBUTING.md](../CONTRIBUTING.md) for contribution guidelines.

## Conclusion

The EigenScript self-hosted compiler is a significant achievement demonstrating the language's maturity and capability. While full bootstrap is not yet achieved, the foundation is solid:

- ✅ All compiler modules compile successfully
- ✅ Stage 1 compiler runs and generates valid LLVM IR
- ⚠️ Some runtime bugs need fixing
- 🎯 Full bootstrap is within reach

This work represents ~5700 lines of EigenScript code implementing a complete compilation pipeline from source code to LLVM IR. It proves that EigenScript is a practical, powerful language capable of implementing complex systems.

---

**Version**: 0.4.0  
**Last Updated**: December 2025  
**Status**: Partial Bootstrap Achieved
