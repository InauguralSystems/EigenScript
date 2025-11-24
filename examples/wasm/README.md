# EigenScript WebAssembly Examples

This directory contains the HTML/JavaScript bridge for running EigenScript programs compiled to WebAssembly in the browser.

## Phase 3.3 - "Hello Web" Protocol

This is the bridge between your EigenScript compiler and the browser. It demonstrates that the compiler can generate valid WebAssembly binaries that run in Chrome, Firefox, and other modern browsers.

## Prerequisites

To compile EigenScript to WebAssembly, you need one of the following toolchains:

### Option 1: WASI SDK (Recommended)
```bash
# Download and install WASI SDK
wget https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-21/wasi-sdk-21.0-linux.tar.gz
tar xzf wasi-sdk-21.0-linux.tar.gz
export WASI_SDK_PATH=$PWD/wasi-sdk-21.0

# Use wasi-clang instead of regular clang
export CC=$WASI_SDK_PATH/bin/clang
```

### Option 2: Emscripten
```bash
# Install Emscripten
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
./emsdk install latest
./emsdk activate latest
source ./emsdk_env.sh

# Use emcc compiler
export CC=emcc
```

## Quick Start

### Step 1: Build the WASM Runtime

First, build the EigenScript runtime for WebAssembly:

```bash
cd ../../src/eigenscript/compiler/runtime
python3 build_runtime.py --target wasm32
```

This compiles `eigenvalue.c` to `build/wasm32-unknown-unknown/eigenvalue.o` with the necessary WASM flags.

### Step 2: Compile Your Program

Compile an EigenScript program to WebAssembly:

```bash
cd ../../..  # Back to repository root

# Compile a simple program
eigenscript-compile examples/benchmarks/loop_fast.eigs \
    --target wasm32-unknown-unknown \
    --exec \
    -o examples/wasm/loop_fast.wasm

# Or compile a custom program
eigenscript-compile your_program.eigs \
    --target wasm32-unknown-unknown \
    --exec \
    -o examples/wasm/program.wasm
```

### Step 3: Serve the HTML

Start a local web server (WASM requires HTTP/HTTPS, not file:// protocol):

```bash
cd examples/wasm

# Option 1: Python 3
python3 -m http.server 8000

# Option 2: Node.js
npx http-server -p 8000

# Option 3: PHP
php -S localhost:8000
```

### Step 4: Open in Browser

Open your browser and navigate to:
```
http://localhost:8000/index.html
```

Click **"▶️ Run Program"** to execute the WASM module!

## How It Works

### 1. Compilation Pipeline

```
EigenScript (.eigs)
    ↓ [Tokenizer + Parser]
AST (Abstract Syntax Tree)
    ↓ [LLVM Code Generator]
LLVM IR (.ll)
    ↓ [LLVM → WASM Backend]
WebAssembly Object (.o)
    ↓ [clang linker with WASM flags]
WebAssembly Binary (.wasm)
```

### 2. The JavaScript Bridge

The HTML file provides the bridge between WASM and JavaScript:

```javascript
// Import object: Functions that WASM can call
const importObject = {
    env: {
        eigen_print: (value) => {
            console.log(value);
        },
        // Math functions
        exp: Math.exp,
        fabs: Math.abs,
        // etc.
    }
};

// Load and instantiate WASM
const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);

// Call the main function
instance.exports.main();
```

### 3. The Linker Flags

The key linker flags for WebAssembly:

- `--target=wasm32-unknown-unknown`: Target WebAssembly
- `-nostdlib`: Don't link against system libc (not available in browser)
- `-Wl,--no-entry`: Library mode (linker doesn't require `_start`)
- `-Wl,--export-all`: Export all symbols so JavaScript can call them
- `-Wl,--allow-undefined`: Allow JavaScript imports (like `eigen_print`) to be undefined at link time

## Benchmarking

The HTML playground includes a benchmark mode that runs your program multiple times and reports:
- Average execution time
- Median execution time
- Min/Max execution time
- Output verification

Click **"⚡ Run Benchmark"** to test performance!

### Expected Results

For `loop_fast.eigs` (sum of 1 to 1,000,000):
- **Native (compiled with gcc)**: ~2-5ms
- **WebAssembly (in browser)**: ~3-8ms
- **Interpreter**: ~100-200ms

WebAssembly maintains the 50x+ speedup over interpretation!

## Troubleshooting

### "Failed to fetch WASM file"
- Make sure you're using a web server (not file:// protocol)
- Check that the .wasm file exists in the correct location
- Check browser console for CORS errors

### "WASM module does not export a main function"
- Verify the compilation succeeded
- Check that you used `--exec` flag when compiling
- Ensure the linker flags include `-Wl,--export-all`

### Compilation fails with "stdlib.h not found"
- You need WASI SDK or Emscripten installed
- Regular clang doesn't have WASM-compatible libc headers
- See Prerequisites section above

### "malloc undefined" or similar errors
- Check that the import object in index.html provides all required functions
- Some functions may need to be stubbed out for WASM

## Examples

### Example 1: Simple Calculation
```eigenscript
# program.eigs
result is 2 + 2
print of result
```

Compile and run:
```bash
eigenscript-compile program.eigs --target wasm32-unknown-unknown --exec -o examples/wasm/program.wasm
```

### Example 2: Loop Benchmark
```eigenscript
# loop_fast.eigs (already exists)
i is 0
sum is 0
limit is 1000000

loop while i < limit:
    i is i + 1
    sum is sum + i

print of sum
```

This tests pure scalar iteration speed - the core strength of EigenScript's fast path optimization.

## Next Steps

- **Phase 4**: Add interactive REPL in the browser
- **Phase 5**: Visual debugging and profiling
- **Phase 6**: Collaborative coding environment

## Resources

- [WebAssembly Spec](https://webassembly.github.io/spec/)
- [LLVM WebAssembly Backend](https://llvm.org/docs/WebAssembly.html)
- [WASI SDK](https://github.com/WebAssembly/wasi-sdk)
- [Emscripten](https://emscripten.org/)
