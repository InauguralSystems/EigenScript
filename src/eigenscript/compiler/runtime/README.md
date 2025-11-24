# EigenScript Runtime Cross-Compilation System

This directory contains the EigenScript runtime library and its cross-compilation build system (Phase 3.2).

## Overview

The runtime provides geometric state tracking for compiled EigenScript programs. The build system enables cross-compilation for multiple target architectures, essential for WebAssembly deployment and ARM devices.

## Files

- **`eigenvalue.c`** - Runtime implementation (C99)
- **`eigenvalue.h`** - Runtime API header
- **`build_runtime.py`** - Cross-compilation build script
- **`eigenvalue.o`** - Symlink to host runtime object file
- **`eigenvalue.bc`** - Symlink to host runtime bitcode (for LTO)
- **`build/`** - Build output directory (created by build script)

## Quick Start

### Build for Host Architecture

```bash
python3 build_runtime.py
```

This builds the runtime for your current system architecture and creates convenience symlinks.

### Build for Specific Target

```bash
# WebAssembly (requires WASI SDK or Emscripten)
python3 build_runtime.py --target wasm32

# Apple Silicon
python3 build_runtime.py --target aarch64

# 32-bit ARM (Raspberry Pi)
python3 build_runtime.py --target arm

# Explicit x86_64
python3 build_runtime.py --target x86_64
```

### Build All Targets

```bash
python3 build_runtime.py --all
```

Attempts to build for all supported targets. Gracefully skips targets without required toolchains.

### List Available Targets

```bash
python3 build_runtime.py --list
```

Shows all supported targets and indicates which have compilers available.

## Supported Targets

| Target Name | LLVM Triple | Pointer Size | Use Case |
|------------|-------------|--------------|----------|
| `host` | System default | System native | Local development |
| `wasm32` | wasm32-unknown-unknown | 32-bit | Browser/WASM |
| `aarch64` | aarch64-apple-darwin | 64-bit | Apple Silicon (M1/M2/M3) |
| `arm` | arm-linux-gnueabihf | 32-bit | Raspberry Pi, embedded |
| `x86_64` | x86_64-unknown-linux-gnu | 64-bit | Linux/macOS/Windows |

## Build Output

Each target creates:

```
build/{target-triple}/
├── eigenvalue.o   # Object file for linking
└── eigenvalue.bc  # LLVM bitcode for LTO optimization
```

Example:
```
build/
├── host/
│   ├── eigenvalue.o
│   └── eigenvalue.bc
├── x86_64-unknown-linux-gnu/
│   ├── eigenvalue.o
│   └── eigenvalue.bc
└── wasm32-unknown-unknown/
    ├── eigenvalue.o
    └── eigenvalue.bc
```

## Compiler Integration

The EigenScript compiler automatically uses the correct runtime:

```bash
# Compile with explicit target
eigenscript-compile program.eigs --target wasm32-unknown-unknown

# Compiler automatically:
# 1. Looks for build/wasm32-unknown-unknown/eigenvalue.{o,bc}
# 2. If not found, attempts to build it
# 3. Uses it for linking
```

## Requirements

### Minimum (Host Build Only)

- **clang** or **gcc** - C compiler
- LLVM tools (for bitcode generation)

On Ubuntu/Debian:
```bash
sudo apt-get install clang llvm
```

On macOS:
```bash
xcode-select --install
```

### Cross-Compilation

Additional requirements for specific targets:

- **WASM**: WASI SDK or Emscripten
  ```bash
  # Using Emscripten
  git clone https://github.com/emscripten-core/emsdk.git
  cd emsdk
  ./emsdk install latest
  ./emsdk activate latest
  ```

- **ARM**: Cross-compilation toolchain
  ```bash
  sudo apt-get install gcc-arm-linux-gnueabihf
  ```

- **aarch64**: Xcode (macOS) or cross-compiler (Linux)

## Troubleshooting

### Build Fails: "clang not found"

Install clang:
```bash
# Ubuntu/Debian
sudo apt-get install clang

# macOS
xcode-select --install
```

### Cross-Compilation Fails

This is normal if you don't have cross-compilation toolchains installed. The build system will:
1. Skip unavailable targets with a warning
2. Fall back to host runtime when compiling
3. Allow compilation to succeed using compatible runtime

### WASM Build Fails: "stdlib.h not found"

WASM requires special system headers. Options:

1. **Use WASI SDK** (recommended):
   ```bash
   # Download from: https://github.com/WebAssembly/wasi-sdk/releases
   export CC="/path/to/wasi-sdk/bin/clang"
   python3 build_runtime.py --target wasm32
   ```

2. **Use Emscripten**:
   ```bash
   source /path/to/emsdk/emsdk_env.sh
   emcc -c -O3 eigenvalue.c -o build/wasm32-unknown-unknown/eigenvalue.o
   ```

3. **Skip WASM** (use host runtime as fallback)

## Development

### Testing

```bash
# Run build system tests
pytest tests/test_runtime_build_system.py -v

# Test specific target
python3 build_runtime.py --target x86_64 --verbose
```

### Adding New Targets

Edit `build_runtime.py` and add to the `TARGETS` dictionary:

```python
TARGETS = {
    "newtarget": {
        "triple": "newtarget-triple-here",
        "compiler": "clang",
        "flags": ["-c", "-O3", "-fPIC", "--target=newtarget-triple-here"],
        "output": "eigenvalue.o",
        "bitcode": "eigenvalue.bc",
    },
}
```

### Modifying Runtime

If you modify `eigenvalue.c`:

1. Rebuild all targets:
   ```bash
   python3 build_runtime.py --all
   ```

2. Test compilation:
   ```bash
   eigenscript-compile examples/factorial_simple.eigs
   ```

3. Run tests:
   ```bash
   pytest tests/ -v
   ```

## Performance Notes

### LTO (Link-Time Optimization)

The `.bc` (bitcode) files enable LLVM's Link-Time Optimization:
- Runtime functions get inlined into generated code
- Eliminates function call overhead (~2-5 cycles per call)
- Better register allocation across module boundaries
- Can improve performance by 2-10x on geometric operations

### Object Files vs Bitcode

- **Object files (`.o`)**: Used for final executable linking
- **Bitcode files (`.bc`)**: Used for LTO during LLVM IR compilation

Both are generated for maximum flexibility.

## Architecture Notes

### Why Cross-Compilation Matters

1. **WebAssembly**: Enables browser-based Interactive Playground (Phase 5)
2. **ARM**: Supports embedded systems and Raspberry Pi deployment
3. **Apple Silicon**: Native M1/M2/M3 performance without Rosetta
4. **Future-Proof**: Easy to add new architectures

### Design Decisions

- **Separate builds per target**: Avoids ABI conflicts
- **Automatic fallback**: Graceful degradation if target unavailable
- **Build-time vs runtime**: Pre-compile for faster development iteration
- **Symlinks for host**: Maintains backward compatibility with existing code

## Related Documentation

- [Phase 3.1: Architecture-Agnostic Compiler](../../docs/architecture-agnostic.md)
- [Phase 3.2: Runtime Cross-Compilation](../../docs/runtime-cross-compile.md)
- [ROADMAP.md](../../../../ROADMAP.md) - Phase 3 goals

## License

Same as EigenScript project.
