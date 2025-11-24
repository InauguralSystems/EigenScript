# EigenSpace Quick Start 🚀

Welcome to **EigenSpace** - the interactive playground for EigenScript!

## How to Run Your Creation

### Step 1: Build Runtime
```bash
python3 src/eigenscript/compiler/runtime/build_runtime.py --target wasm32
```

This compiles the EigenScript runtime (`eigenvalue.c`) to WebAssembly. You only need to do this once.

**Prerequisites:** You need either [WASI SDK](https://github.com/WebAssembly/wasi-sdk) or [Emscripten](https://emscripten.org/) installed for WASM compilation. See [examples/wasm/README.md](../wasm/README.md) for setup instructions.

### Step 2: Start Server
```bash
python3 examples/playground/server.py
```

This starts a local HTTP server on port 8080 that:
- Serves the playground HTML interface
- Compiles your EigenScript code to WASM on-demand

### Step 3: Visit
```
http://localhost:8080
```

Open this URL in your browser (Chrome, Firefox, or Safari recommended).

---

## What You'll See

- **Left Panel**: Code editor with the "Inaugural Algorithm" example
- **Right Panel**: Real-time visualization of your program's output
- **Console**: Compilation status and execution logs

## Try It Out!

1. Click **"▶ RUN SIMULATION"** or press `Ctrl+Enter` (or `Cmd+Enter` on Mac)
2. Watch the convergence visualization appear in real-time!
3. Edit the code and run again to see different behaviors

## Example Programs

### Simple Harmonic Motion
```eigenscript
x is 10
v is 0
dt is 0.1

loop while x > -10:
    accel is 0 - x
    v is v + (accel * dt)
    x is x + (v * dt)
    print of x
```

### Exponential Growth
```eigenscript
x is 1
t is 0

loop while t < 50:
    x is x * 1.05
    t is t + 1
    print of x
```

### Damped Oscillation
```eigenscript
x is 10
v is 0
damping is 0.05

loop while x > 0.1:
    accel is (0 - x) - (damping * v)
    v is v + (accel * 0.1)
    x is x + (v * 0.1)
    print of x
```

---

## Troubleshooting

### "Runtime not built" error
Run: `python3 src/eigenscript/compiler/runtime/build_runtime.py --target wasm32`

### "Failed to fetch /compile"
Make sure the server is running: `python3 examples/playground/server.py`

### "Connection refused" or CORS error
Access via `http://localhost:8080`, not `file://`

### WASM toolchain issues
See [examples/wasm/README.md](../wasm/README.md) for detailed setup instructions

---

## Next Steps

- Explore more examples in [examples/](../)
- Read the full [README.md](README.md) for architecture details
- Check out [Phase 5 Documentation](../../docs/PHASE5_INDEX.md)

**Have fun creating physics! 🌀**
