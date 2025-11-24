# EigenSpace - Interactive Playground 🌀

**Phase 5: The Interactive Playground Architecture**

EigenSpace is a split-screen IDE where code on the left creates physics visualizations on the right. This is the "Feedback Loop" - edit, compile, visualize, iterate.

## How to Run Your Creation

1. **Build Runtime:** `python3 src/eigenscript/compiler/runtime/build_runtime.py --target wasm32`
2. **Start Server:** `python3 examples/playground/server.py`
3. **Visit:** `http://localhost:8080`

See [QUICKSTART.md](QUICKSTART.md) for detailed setup instructions.

## Why a Local Server?

**The Physical Constraint:** The EigenScript compiler uses `llvmlite.binding` (which links to C++ LLVM libraries) and makes subprocess calls to `clang`. Running these directly in a browser via Pyodide is extremely difficult because:
- Browsers can't spawn subprocesses
- Browsers can't load arbitrary native C libraries
- Pyodide is 20MB+ and doesn't support `llvmlite` out of the box

**The Solution:** We use a **Local Compilation Server**. You run a tiny Python server (`server.py`) on your machine. The browser sends code to it, your machine compiles it using the robust toolchain you built in Phase 3, and sends the `.wasm` binary back to the browser for execution.

This architecture gives us:
- ✅ Full access to the native LLVM toolchain
- ✅ Fast compilation with zero browser limitations
- ✅ Easy debugging (server logs show compilation errors)
- ✅ No 20MB download for users

## Architecture

```
┌─────────────────┐                    ┌──────────────────┐
│   Editor (Left) │                    │ Visualizer (Right)│
│                 │                    │                  │
│  Monaco-style   │◄───Keyboard────────│  HTML5 Canvas    │
│  Code Editor    │    Shortcuts       │  Phase Plot      │
│                 │                    │                  │
└────────┬────────┘                    └────────▲─────────┘
         │                                      │
         │ User Code                            │ eigen_print
         │ (.eigs)                              │ interception
         ▼                                      │
┌─────────────────┐                    ┌──────────────────┐
│ Compiler (Backend)                   │ Runtime (WASM)   │
│                 │                    │                  │
│ Python Server   │────WASM Binary────►│ WebAssembly      │
│ (server.py)     │                    │ Execution        │
│                 │                    │                  │
└─────────────────┘                    └──────────────────┘
```

### Components

1. **Editor (Left Panel)**: A code editor where users type EigenScript
   - Syntax: EigenScript with real-time editing
   - Shortcut: `Ctrl+Enter` or `Cmd+Enter` to compile and run

2. **Compiler (Backend)**: A Python HTTP server that compiles code
   - Endpoint: `POST /compile` accepts `.eigs` source
   - Returns: Binary `.wasm` or error messages
   - Uses: Your existing `eigenscript-compile` CLI

3. **Runtime (Hidden)**: The eigenvalue.c runtime compiled to WASM
   - Pre-built: `build/wasm32-unknown-unknown/eigenvalue.o`
   - Linked: At compile-time with user code

4. **Visualizer (Right Panel)**: HTML5 Canvas for phase space plots
   - Intercepts: `eigen_print` calls from WASM
   - Renders: Real-time phase space visualization
   - Shows: Console output with values

## Quick Start

### Prerequisites

1. **Install EigenScript with compiler support:**
   ```bash
   pip install -e ".[dev,compiler]"
   ```

2. **Install WASM toolchain (REQUIRED):**
   
   The runtime uses standard C library functions, so you need WASI SDK or Emscripten:
   
   **Option A: WASI SDK (Recommended)**
   ```bash
   # Download WASI SDK (check latest version at releases page)
   # Example with version 21 (latest as of Nov 2024):
   wget https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-21/wasi-sdk-21.0-linux.tar.gz
   tar xzf wasi-sdk-21.0-linux.tar.gz
   export CC=$PWD/wasi-sdk-21.0/bin/clang
   ```
   
   **Note:** Check [WASI SDK releases](https://github.com/WebAssembly/wasi-sdk/releases) for the latest version.
   
   **Option B: Emscripten**
   ```bash
   git clone https://github.com/emscripten-core/emsdk.git
   cd emsdk
   ./emsdk install latest
   ./emsdk activate latest
   source ./emsdk_env.sh
   ```
   
   See [examples/wasm/README.md](../wasm/README.md) for detailed setup instructions.

3. **Build the WASM runtime:**
   ```bash
   cd ../../src/eigenscript/compiler/runtime
   python3 build_runtime.py --target wasm32
   ```
   
   This compiles `eigenvalue.c` to WebAssembly.

### Running EigenSpace

1. **Start the compilation server:**
   ```bash
   cd examples/playground
   python3 server.py
   ```

   This starts a server on `http://localhost:8080` that:
   - Serves the `index.html` playground interface
   - Provides the `/compile` endpoint for compiling code

2. **Open in browser:**
   ```
   http://localhost:8080
   ```

3. **Start coding!**
   - Edit the code in the left panel
   - Click **"▶ Run Simulation"** or press `Ctrl+Enter`
   - Watch the visualization appear on the right!

## Example Programs

### Simple Harmonic Motion (Default)
```eigenscript
# EigenScript Orbit Simulation
x is 10
v is 0
dt is 0.1

loop while x > -10:
    # Simple Harmonic Motion
    accel is 0 - x
    v is v + (accel * dt)
    x is x + (v * dt)
    
    print of x
```

This creates an oscillating wave pattern - physics in action!

### Exponential Growth
```eigenscript
# Exponential growth demonstration
x is 1
t is 0
dt is 0.1

loop while t < 5:
    x is x * 1.1
    t is t + dt
    print of x
```

### Damped Oscillation
```eigenscript
# Damped harmonic oscillator
x is 10
v is 0
dt is 0.1
damping is 0.1

loop while x > 0.01:
    accel is (0 - x) - (damping * v)
    v is v + (accel * dt)
    x is x + (v * dt)
    print of x
```

## How It Works

### 1. Edit Phase
You write EigenScript code in the editor (left panel).

### 2. Compile Phase
When you click "Run" or press `Ctrl+Enter`:
1. JavaScript sends your code to `POST /compile`
2. The server creates a temporary `.eigs` file
3. It calls `eigenscript-compile --target wasm32-unknown-unknown --exec`
4. Returns the compiled `.wasm` binary (or errors)

### 3. Execute Phase
The browser:
1. Receives the WASM binary
2. Instantiates it with an import object that provides:
   - `eigen_print`: JavaScript function for plotting
   - Math functions: `exp`, `sin`, `cos`, etc.
3. Calls `instance.exports.main()`

### 4. Visualize Phase
Every time your code calls `print of x`:
1. WASM calls the imported `eigen_print(value)`
2. JavaScript intercepts it
3. Adds the value to the plot history
4. Redraws the canvas with the updated graph

## Troubleshooting

### "Failed to fetch /compile"
- Make sure `server.py` is running
- Check that you're accessing `http://localhost:8080`, not `file://`

### "Compilation failed"
Common issues:
- **Syntax error**: Check your EigenScript syntax
- **Runtime not built**: Run `python3 build_runtime.py --target wasm32` in `src/eigenscript/compiler/runtime/`
- **No WASM toolchain**: Install WASI SDK or Emscripten (see [examples/wasm/README.md](../wasm/README.md))

### "malloc undefined" or similar
- Check that the import object in `index.html` provides all required functions
- The current version stubs out `malloc`/`free` - WASM uses internal memory

### Visualization not updating
- Make sure your code calls `print of <variable>`
- Check browser console (F12) for JavaScript errors
- Verify WASM is actually executing (check console output)

## Architecture Details

### Why a Local Server?

The original plan (Pyodide) would run Python in the browser, but:
- Pyodide is 20MB+ download
- `llvmlite.binding` requires native C++ LLVM libraries
- Subprocess calls to `clang` don't work in browsers

**Solution:** Run the compiler on your machine, stream WASM to the browser.

### The Import Object

WASM can't access browser APIs directly. We provide a "bridge":

```javascript
const importObject = {
    env: {
        eigen_print: (val) => plot(val),  // Redirect to visualizer
        exp: Math.exp,                     // Math functions
        fabs: Math.abs,
        // ... more functions
    }
};
```

Your C runtime (`eigenvalue.c`) declares these as `extern` functions, and the linker marks them as "to be provided by JavaScript".

### The Linker Flags

From `compile.py`, the key WASM linker flags:
```
-nostdlib              # No system libraries
-Wl,--no-entry         # No _start needed (library mode)
-Wl,--export-all       # Export all symbols to JavaScript
-Wl,--allow-undefined  # Allow unresolved symbols (provided by JS)
```

## Next Steps

### Phase 5.2 - Enhanced Features
- [ ] Monaco Editor integration for better syntax highlighting
- [ ] Error highlighting in the editor
- [ ] Multiple visualization modes (line, scatter, 3D)
- [ ] Export plots as PNG/SVG
- [ ] Save/load programs from local storage

### Phase 5.3 - Collaboration
- [ ] Share playground links with code embedded
- [ ] Real-time collaborative editing
- [ ] Gallery of example programs

### Phase 6 - Self-Hosting
- [ ] Rewrite compiler in EigenScript
- [ ] Compile the compiler to WASM
- [ ] Run entirely in the browser (no server needed)

## Technical Notes

### Performance
- **Compilation**: ~100-500ms depending on code size
- **Execution**: Near-native speed (2-5ms for typical programs)
- **Visualization**: 60 FPS for up to ~1000 data points

### Limitations
- Max code size: ~10KB (reasonable for playground demos)
- Max output points: ~10,000 (for smooth visualization)
- No file I/O (browser sandbox)
- No modules yet (single-file programs only)

### Security
- Server only accepts code compilation requests
- No shell access or arbitrary file operations
- CORS enabled for local development only
- Temp directories cleaned up after compilation

## Resources

- [Phase 5 Roadmap](../../docs/PHASE5_INTERACTIVE_PLAYGROUND_ROADMAP.md)
- [Phase 5 Quick Start](../../docs/PHASE5_QUICK_START_GUIDE.md)
- [WASM Examples](../wasm/README.md)
- [Compiler Documentation](../../src/eigenscript/compiler/README.md)

## Credits

**Phase 5: Interactive Playground** - Built on the WASM infrastructure from Phase 3.

This playground proves that EigenScript can compile and run in the browser at near-native speeds, with real-time physics visualization.

---

**Have fun creating physics! 🌀**
