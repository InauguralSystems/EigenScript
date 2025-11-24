# EigenSpace Architecture Documentation

## Overview

EigenSpace is the interactive playground for EigenScript, implementing **Phase 5** of the roadmap. It's a split-screen web IDE where code on the left creates real-time physics visualizations on the right.

## The Technical Constraint

### Why Not In-Browser Compilation (Pyodide)?

The original plan was to use **Pyodide** to run the Python compiler directly in the browser. However, this approach has critical blockers:

1. **Native Dependencies:** The EigenScript compiler uses `llvmlite.binding`, which links to native C++ LLVM libraries. These cannot run in a browser's WebAssembly sandbox.

2. **Subprocess Calls:** The compiler invokes `clang` as a subprocess for linking. Browsers cannot spawn subprocesses for security reasons.

3. **Size:** Pyodide is a 20MB+ download, which would make the playground slow to load.

4. **Complexity:** Even if Pyodide worked, setting up LLVM toolchains in-browser would be extremely fragile.

### The Solution: Local Compilation Server

Instead, we use a **client-server architecture**:

```
┌─────────────┐              ┌──────────────┐              ┌─────────────┐
│   Browser   │   HTTP/JSON  │    Server    │   Subprocess │   Compiler  │
│  (Frontend) │◄────────────►│  (server.py) │◄────────────►│   + LLVM    │
└─────────────┘              └──────────────┘              └─────────────┘
      │                             │
      │ WebAssembly Binary          │ Full Native Toolchain
      ▼                             ▼
┌─────────────┐              ┌──────────────┐
│ WASM Runtime│              │ eigenscript  │
│  + Canvas   │              │   compile    │
└─────────────┘              └──────────────┘
```

**Benefits:**
- ✅ Full access to native LLVM toolchain
- ✅ Fast compilation (no browser limitations)
- ✅ Small frontend (HTML + JS only)
- ✅ Easy debugging (server logs)
- ✅ Works with existing Phase 3 infrastructure

## Component Architecture

### 1. Frontend (`index.html`)

**Responsibilities:**
- Code editor (textarea with syntax highlighting)
- Real-time canvas visualization
- HTTP client for compilation requests
- WASM instantiation and execution

**Key Technologies:**
- Vanilla JavaScript (no frameworks)
- HTML5 Canvas with `requestAnimationFrame`
- Fetch API for server communication
- WebAssembly API

**Data Flow:**
```
User Code → POST /compile → WASM Binary → WebAssembly.instantiate() → main() → eigen_print → Canvas
```

### 2. Backend (`server.py`)

**Responsibilities:**
- Serve static files (index.html)
- Accept compilation requests
- Invoke the EigenScript compiler
- Return WASM binaries or error messages

**Implementation:**
```python
# Uses Python's built-in http.server
class CompilerHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        # 1. Receive EigenScript code
        # 2. Write to temp file
        # 3. Call: python -m eigenscript.compiler.cli.compile
        # 4. Return .wasm binary
```

**Key Design Choices:**
- Uses `python -m` to invoke the compiler (clean imports)
- Runs compilation from PROJECT_ROOT (proper Python path)
- Temporary directories for isolation
- CORS headers for local development

### 3. Compiler Integration

The server invokes the existing Phase 3 compiler:

```bash
python -m eigenscript.compiler.cli.compile \
    main.eigs \
    --target wasm32-unknown-unknown \
    --exec \
    -o main.wasm
```

This command:
1. Parses EigenScript → AST
2. Generates LLVM IR
3. Compiles to WebAssembly object file
4. Links with `eigenvalue.o` runtime
5. Produces standalone `.wasm` binary

### 4. Runtime Bridge

The WASM module needs functions from JavaScript:

```javascript
const importObject = {
    env: {
        // Core I/O
        eigen_print: (val) => dataPoints.push(val),
        
        // Math library
        exp: Math.exp,
        sin: Math.sin,
        cos: Math.cos,
        // ... etc
        
        // Memory management stubs
        malloc: (n) => 0,
        free: (p) => {},
    }
};
```

The C runtime declares these as `extern`:
```c
extern void eigen_print(double value);
extern double exp(double x);
// ...
```

The WASM linker marks them as "to be provided at instantiation time."

## Visualization System

### Real-Time Animation

Instead of redrawing on every print, we use continuous animation:

```javascript
let dataPoints = [];

function draw() {
    // Fade effect (motion blur)
    ctx.fillStyle = 'rgba(0,0,0,0.1)';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    
    // Draw latest data
    // ... plot line ...
    
    requestAnimationFrame(draw);  // 60 FPS
}
```

### Auto-Scaling

Y-axis dynamically adjusts to data range:

```javascript
const maxVal = Math.max(...dataPoints, 10);
const minVal = Math.min(...dataPoints, -10);
const range = maxVal - minVal || 1;

// Normalize: [minVal, maxVal] → [0, 1]
const normalizedY = (val - minVal) / range;

// Map to screen: [0, 1] → [bottom, top]
const y = canvas.height - (normalizedY * canvas.height * 0.8) - (canvas.height * 0.1);
```

### Sliding Window

Only show last 100 points to prevent slowdown:

```javascript
const startIndex = Math.max(0, dataPoints.length - 100);
for (let i = startIndex; i < dataPoints.length; i++) {
    // ... plot point i ...
}
```

## Security Considerations

### Server Security

- **Isolation:** Each compilation uses a temporary directory
- **No Shell Injection:** Uses subprocess arrays, not shell=True
- **Limited Scope:** Server only compiles code, doesn't execute it
- **Local Only:** Designed for localhost (not production-ready)

### Browser Security

- **CORS:** Enabled for localhost only
- **CSP:** Could add Content-Security-Policy headers
- **Sandboxed WASM:** WASM runs in browser sandbox

## Performance Profile

### Compilation Time
- **Simple programs:** 100-300ms
- **Complex programs:** 500-1000ms
- **Bottleneck:** LLVM optimization passes

### Execution Time
- **WASM overhead:** ~1-2ms baseline
- **Speed:** Near-native (2-5ms for typical programs)
- **Visualization:** 60 FPS up to ~1000 data points

### Network
- **Code upload:** <10KB typically
- **WASM download:** 5-50KB depending on program
- **Latency:** localhost ~1ms

## Deployment Scenarios

### Development (Current)
```bash
python3 server.py  # Run locally
# Visit http://localhost:8080
```

### Future: Public Deployment

For public hosting, you'd need:

1. **Backend:** Deploy server.py to cloud (e.g., Heroku, Railway)
2. **Security:** Rate limiting, input validation, timeout
3. **Caching:** Cache compiled WASM for common examples
4. **CDN:** Serve static files from CDN

### Future: Serverless

Could use serverless functions:
- AWS Lambda with custom runtime
- Google Cloud Functions
- But 10s timeout may be tight for compilation

## Extensibility

### Adding Language Features

1. Update compiler (Phase 3)
2. Rebuild WASM runtime if needed
3. No frontend changes needed!

### Adding Visualization Modes

```javascript
// In index.html, add visualization selector
function plot(value) {
    if (vizMode === 'line') {
        drawLine(value);
    } else if (vizMode === 'scatter') {
        drawScatter(value);
    } else if (vizMode === '3d') {
        draw3D(value);
    }
}
```

### Adding Code Examples

Just add buttons that load different code:

```javascript
const examples = {
    'harmonic': `x is 10\nv is 0\n...`,
    'exponential': `x is 1\nloop...`,
};

function loadExample(name) {
    document.getElementById('code').value = examples[name];
}
```

## Testing Strategy

### Unit Tests
- `tests/test_playground.py`: File structure, syntax, content

### Integration Tests (Manual)
1. Build WASM runtime
2. Start server
3. Open browser
4. Test compilation + execution

### Future: E2E Tests
- Playwright/Selenium to automate browser testing
- Test compilation errors, execution, visualization

## Comparison to Other Approaches

### Approach 1: Pure Interpreter
❌ 50-100x slower than compiled WASM  
✅ No compilation step  

### Approach 2: Pyodide
❌ 20MB download  
❌ Can't use llvmlite  
❌ No subprocess support  

### Approach 3: Local Server (Current)
✅ Fast compilation  
✅ Full toolchain access  
✅ Small frontend  
❌ Requires local setup  

### Approach 4: Cloud Compiler
✅ No local setup  
❌ Network latency  
❌ Hosting costs  
❌ Security concerns  

## Future Enhancements

### Phase 5.2
- Monaco Editor integration
- Syntax highlighting
- Error underlining
- Auto-completion

### Phase 5.3
- Multiple visualization modes
- Export plots as PNG/SVG
- Share code via URL
- Local storage persistence

### Phase 6: Self-Hosting
Rewrite compiler in EigenScript itself:
```eigenscript
# compiler.eigs
define parse as:
    tokens is tokenize of source
    ast is build_tree of tokens
    return ast
```

Then compile the compiler to WASM and run it in-browser!

## Related Documentation

- [Phase 5 Roadmap](../../docs/PHASE5_INTERACTIVE_PLAYGROUND_ROADMAP.md)
- [Phase 5 Quick Start](../../docs/PHASE5_QUICK_START_GUIDE.md)
- [WASM Examples](../wasm/README.md)
- [Compiler Documentation](../../src/eigenscript/compiler/README.md)

---

**Bottom Line:** The local server architecture gives us the best of both worlds - the power of native compilation with the convenience of browser-based visualization.
