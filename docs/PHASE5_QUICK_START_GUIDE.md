# Phase 5 Quick Start Guide

**Ready to build the Interactive Playground? Start here.**

---

## Week 1: Verify WASM Foundation

### Day 1-2: Build WASM Runtime

```bash
# Test WASM compilation
cd src/eigenscript/compiler/runtime
python3 build_runtime.py --target wasm32

# Verify output
ls -lh build/wasm32-unknown-unknown/
# Should see: eigenvalue.o, eigenvalue.bc
```

**Success Criteria:** WASM object file compiles without errors

### Day 3-4: Link WASM Binary

```bash
# Install LLVM tools if needed
# Ubuntu: sudo apt-get install llvm lld
# macOS: brew install llvm

# Link to WASM
wasm-ld build/wasm32-unknown-unknown/eigenvalue.o \
  -o eigenvalue.wasm \
  --no-entry \
  --export-all \
  --allow-undefined

# Inspect exports
wasm-objdump -x eigenvalue.wasm | grep "export"
```

**Success Criteria:** See exported functions: `eigen_create`, `eigen_update`, etc.

### Day 5: Test in Browser

```html
<!-- test/wasm-test.html -->
<!DOCTYPE html>
<html>
<head><title>WASM Test</title></head>
<body>
  <h1>EigenScript WASM Test</h1>
  <pre id="output"></pre>
  
  <script type="module">
    const log = msg => document.getElementById('output').textContent += msg + '\n';
    
    async function testWASM() {
      log('Loading eigenvalue.wasm...');
      
      const response = await fetch('../src/eigenscript/compiler/runtime/eigenvalue.wasm');
      const buffer = await response.arrayBuffer();
      
      log('Instantiating WASM module...');
      const { instance } = await WebAssembly.instantiate(buffer, {
        env: {
          // Provide required imports (e.g., malloc, free)
          malloc: size => 0,
          free: ptr => {},
        }
      });
      
      log('Testing eigen_create...');
      const ptr = instance.exports.eigen_create(42.0);
      log(`Created EigenValue at address: ${ptr}`);
      
      log('✅ WASM test passed!');
    }
    
    testWASM().catch(err => log(`❌ Error: ${err}`));
  </script>
</body>
</html>
```

**Success Criteria:** Page loads, WASM instantiates, function calls work

---

## Week 2: Pyodide Integration

### Day 1: Set Up Pyodide Test

```bash
# Create test directory
mkdir -p playground/wasm-bridge
cd playground/wasm-bridge
```

```html
<!-- pyodide-test.html -->
<!DOCTYPE html>
<html>
<head><title>Pyodide Test</title></head>
<body>
  <h1>Pyodide + EigenScript Test</h1>
  <pre id="output"></pre>
  
  <script type="module">
    const log = msg => {
      document.getElementById('output').textContent += msg + '\n';
      console.log(msg);
    };
    
    async function testPyodide() {
      log('Loading Pyodide...');
      const pyodide = await loadPyodide({
        indexURL: "https://cdn.jsdelivr.net/pyodide/v0.25.0/full/"
      });
      
      log('✅ Pyodide loaded');
      
      // Test basic Python
      log('Testing Python execution...');
      await pyodide.runPythonAsync(`
        print("Hello from Python!")
        x = 42
        print(f"x = {x}")
      `);
      
      log('Loading numpy...');
      await pyodide.loadPackage('numpy');
      
      const result = await pyodide.runPythonAsync(`
        import numpy as np
        arr = np.array([1, 2, 3])
        arr.sum()
      `);
      
      log(`✅ Numpy test: sum([1,2,3]) = ${result}`);
      
      // Check for llvmlite
      log('Checking for llvmlite...');
      const hasLLVM = await pyodide.runPythonAsync(`
        try:
            import micropip
            await micropip.install('llvmlite')
            'llvmlite installed!'
        except Exception as e:
            f'llvmlite not available: {e}'
      `);
      
      log(`llvmlite status: ${hasLLVM}`);
    }
    
    testPyodide().catch(err => log(`❌ Error: ${err}`));
  </script>
  <script src="https://cdn.jsdelivr.net/pyodide/v0.25.0/full/pyodide.js"></script>
</body>
</html>
```

### Day 2-3: Package EigenScript for Browser

```python
# scripts/build-browser-package.py
"""Build minimal EigenScript package for browser deployment."""

import shutil
import os
from pathlib import Path

def build_browser_package():
    """Create browser-optimized package."""
    
    print("🔨 Building browser package...")
    
    # Clean old build
    build_dir = Path('dist/eigenscript-browser')
    if build_dir.exists():
        shutil.rmtree(build_dir)
    
    build_dir.mkdir(parents=True)
    
    # Copy essential modules only
    essential_modules = [
        'src/eigenscript/__init__.py',
        'src/eigenscript/lexer/',
        'src/eigenscript/parser/',
        'src/eigenscript/compiler/',
        'src/eigenscript/builtins.py',
        'src/eigenscript/runtime/',
        'src/eigenscript/semantic/',
    ]
    
    for module in essential_modules:
        src = Path(module)
        
        if src.is_dir():
            dest = build_dir / src.relative_to('src')
            shutil.copytree(src, dest, 
                          ignore=shutil.ignore_patterns('__pycache__', '*.pyc', 'test_*'))
            print(f"  ✅ Copied {src} -> {dest}")
        else:
            dest = build_dir / src.relative_to('src')
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            print(f"  ✅ Copied {src} -> {dest}")
    
    # Create setup.py for package
    setup_py = build_dir / 'setup.py'
    setup_py.write_text("""
from setuptools import setup, find_packages

setup(
    name='eigenscript-browser',
    version='0.2.0',
    packages=find_packages(),
    install_requires=['numpy'],
)
""")
    
    print(f"\n✅ Browser package built: {build_dir}")
    print(f"   Size: {sum(f.stat().st_size for f in build_dir.rglob('*') if f.is_file()) / 1024:.1f} KB")
    
    return build_dir

if __name__ == '__main__':
    build_browser_package()
```

Run it:
```bash
python3 scripts/build-browser-package.py
```

### Day 4-5: Create Compiler Bridge

```javascript
// playground/wasm-bridge/compiler-api.js
/**
 * EigenScript Compiler API for Browser
 * Provides high-level interface to compile and execute EigenScript code.
 */

export class EigenScriptCompiler {
  constructor() {
    this.pyodide = null;
    this.ready = false;
  }

  async initialize() {
    console.log('Initializing EigenScript compiler...');
    
    // Load Pyodide
    this.pyodide = await loadPyodide({
      indexURL: "https://cdn.jsdelivr.net/pyodide/v0.25.0/full/"
    });
    
    // Load dependencies
    await this.pyodide.loadPackage(['numpy', 'micropip']);
    
    // Try to install llvmlite
    try {
      const micropip = this.pyodide.pyimport('micropip');
      await micropip.install('llvmlite');
      console.log('✅ llvmlite installed');
    } catch (err) {
      console.warn('⚠️ llvmlite not available, using fallback:', err);
    }
    
    // Mount EigenScript package
    await this.mountEigenScript();
    
    this.ready = true;
    console.log('✅ EigenScript compiler ready');
  }

  async mountEigenScript() {
    // Load packaged EigenScript code
    // Option 1: From pre-built wheel
    // Option 2: Load Python files directly
    
    await this.pyodide.runPythonAsync(`
      import sys
      sys.path.insert(0, '/eigenscript')
      
      # Import core modules
      from eigenscript.lexer.tokenizer import tokenize
      from eigenscript.parser.ast_builder import build_ast, Program
      from eigenscript.evaluator.interpreter import Interpreter
    `);
  }

  async execute(code) {
    if (!this.ready) {
      throw new Error('Compiler not initialized. Call initialize() first.');
    }

    console.log('Executing EigenScript code...');

    const result = await this.pyodide.runPythonAsync(`
import io
import sys
from contextlib import redirect_stdout

# Capture output
output_buffer = io.StringIO()

try:
    with redirect_stdout(output_buffer):
        # Tokenize
        tokens = tokenize("""${code.replace(/"/g, '\\"')}""")
        
        # Parse
        ast = build_ast(tokens)
        
        # For now, use interpreter (later: compile to WASM)
        interpreter = Interpreter()
        result = interpreter.visit(ast)
    
    {
        'status': 'success',
        'output': output_buffer.getvalue(),
        'result': str(result) if result is not None else '',
    }
except Exception as e:
    import traceback
    {
        'status': 'error',
        'message': str(e),
        'traceback': traceback.format_exc(),
    }
    `);

    return result.toJs();
  }

  async compile(code) {
    // Future: Actually compile to WASM
    // For MVP: just parse and validate
    if (!this.ready) {
      throw new Error('Compiler not initialized');
    }

    const result = await this.pyodide.runPythonAsync(`
try:
    tokens = tokenize("""${code.replace(/"/g, '\\"')}""")
    ast = build_ast(tokens)
    
    {
        'status': 'success',
        'ast': str(ast),
    }
except Exception as e:
    {
        'status': 'error',
        'message': str(e),
    }
    `);

    return result.toJs();
  }
}

// Export factory function
export async function createCompiler() {
  const compiler = new EigenScriptCompiler();
  await compiler.initialize();
  return compiler;
}
```

**Test it:**

```html
<!-- playground/wasm-bridge/compiler-test.html -->
<!DOCTYPE html>
<html>
<head><title>Compiler Test</title></head>
<body>
  <h1>EigenScript Compiler Test</h1>
  
  <textarea id="code" rows="10" cols="60">
x is 42
y is x + 8
print of y
  </textarea>
  <br>
  <button id="run">Run</button>
  
  <h2>Output:</h2>
  <pre id="output"></pre>
  
  <script src="https://cdn.jsdelivr.net/pyodide/v0.25.0/full/pyodide.js"></script>
  <script type="module">
    import { createCompiler } from './compiler-api.js';
    
    const codeEl = document.getElementById('code');
    const outputEl = document.getElementById('output');
    const runBtn = document.getElementById('run');
    
    let compiler = null;
    
    async function init() {
      outputEl.textContent = 'Loading compiler...\n';
      compiler = await createCompiler();
      outputEl.textContent = '✅ Compiler ready! Click "Run" to execute code.\n';
      runBtn.disabled = false;
    }
    
    runBtn.addEventListener('click', async () => {
      const code = codeEl.value;
      outputEl.textContent = 'Running...\n';
      
      const result = await compiler.execute(code);
      
      if (result.status === 'success') {
        outputEl.textContent = result.output || '(no output)';
      } else {
        outputEl.textContent = `❌ Error: ${result.message}\n\n${result.traceback || ''}`;
      }
    });
    
    runBtn.disabled = true;
    init();
  </script>
</body>
</html>
```

**Success Criteria:** Can execute simple EigenScript programs in browser

---

## Week 3-4: Build Web UI

### Day 1: Project Setup

```bash
# Create frontend project
mkdir -p playground/frontend
cd playground/frontend

# Initialize Vite + React
npm create vite@latest . -- --template react
npm install

# Install dependencies
npm install @monaco-editor/react
npm install tailwindcss postcss autoprefixer
npx tailwindcss init -p
```

### Day 2: Basic Layout

```jsx
// src/App.jsx
import { useState } from 'react';
import Editor from '@monaco-editor/react';
import './App.css';

function App() {
  const [code, setCode] = useState('x is 42\nprint of x');
  const [output, setOutput] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleRun() {
    setLoading(true);
    setOutput('Running...');
    
    // TODO: Actually execute code
    setTimeout(() => {
      setOutput('42');
      setLoading(false);
    }, 500);
  }

  return (
    <div className="app">
      <header className="header">
        <h1>🌀 EigenScript Playground</h1>
        <a href="https://github.com/InauguralPhysicist/EigenScript" target="_blank">
          GitHub
        </a>
      </header>

      <main className="main">
        <div className="editor-panel">
          <div className="toolbar">
            <button onClick={handleRun} disabled={loading}>
              ▶️ Run
            </button>
          </div>
          <Editor
            height="calc(100% - 40px)"
            language="python"
            theme="vs-dark"
            value={code}
            onChange={setCode}
            options={{
              minimap: { enabled: false },
              fontSize: 14,
            }}
          />
        </div>

        <div className="output-panel">
          <h3>Output</h3>
          <pre className="output">{output}</pre>
        </div>
      </main>
    </div>
  );
}

export default App;
```

```css
/* src/App.css */
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: system-ui, -apple-system, sans-serif;
  background: #1e1e1e;
  color: #fff;
}

.app {
  height: 100vh;
  display: flex;
  flex-direction: column;
}

.header {
  background: #2d2d2d;
  padding: 1rem 2rem;
  display: flex;
  justify-content: space-between;
  align-items: center;
  border-bottom: 1px solid #444;
}

.header h1 {
  font-size: 1.5rem;
}

.header a {
  color: #58a6ff;
  text-decoration: none;
}

.main {
  flex: 1;
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1px;
  background: #444;
  overflow: hidden;
}

.editor-panel,
.output-panel {
  background: #1e1e1e;
  display: flex;
  flex-direction: column;
}

.toolbar {
  padding: 0.5rem;
  background: #2d2d2d;
  border-bottom: 1px solid #444;
}

.toolbar button {
  background: #0d6efd;
  color: white;
  border: none;
  padding: 0.5rem 1rem;
  border-radius: 4px;
  cursor: pointer;
  font-size: 1rem;
}

.toolbar button:hover {
  background: #0b5ed7;
}

.toolbar button:disabled {
  background: #666;
  cursor: not-allowed;
}

.output-panel {
  padding: 1rem;
}

.output-panel h3 {
  margin-bottom: 0.5rem;
}

.output {
  background: #0d1117;
  padding: 1rem;
  border-radius: 4px;
  overflow: auto;
  flex: 1;
  font-family: 'Monaco', 'Courier New', monospace;
  font-size: 14px;
  line-height: 1.5;
}
```

### Day 3-4: Integrate Compiler

```jsx
// src/App.jsx (updated)
import { useState, useEffect } from 'react';
import Editor from '@monaco-editor/react';
import { createCompiler } from '../../wasm-bridge/compiler-api.js';
import './App.css';

function App() {
  const [compiler, setCompiler] = useState(null);
  const [code, setCode] = useState('x is 42\nprint of x');
  const [output, setOutput] = useState('Click "Run" to execute code');
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);

  useEffect(() => {
    async function init() {
      setOutput('Loading EigenScript compiler...');
      try {
        const comp = await createCompiler();
        setCompiler(comp);
        setOutput('✅ Compiler ready! Click "Run" to execute code.');
      } catch (err) {
        setOutput(`❌ Failed to load compiler: ${err.message}`);
      } finally {
        setLoading(false);
      }
    }
    init();
  }, []);

  async function handleRun() {
    if (!compiler || running) return;

    setRunning(true);
    setOutput('Running...');

    try {
      const result = await compiler.execute(code);

      if (result.status === 'success') {
        setOutput(result.output || '(no output)');
      } else {
        setOutput(`❌ Error: ${result.message}\n\n${result.traceback || ''}`);
      }
    } catch (err) {
      setOutput(`❌ Execution failed: ${err.message}`);
    } finally {
      setRunning(false);
    }
  }

  return (
    <div className="app">
      <header className="header">
        <h1>🌀 EigenScript Playground</h1>
        <div className="header-links">
          <a href="https://eigenscript.org/docs" target="_blank">Docs</a>
          <a href="https://github.com/InauguralPhysicist/EigenScript" target="_blank">
            GitHub
          </a>
        </div>
      </header>

      <main className="main">
        <div className="editor-panel">
          <div className="toolbar">
            <button onClick={handleRun} disabled={loading || running}>
              {running ? '⏳ Running...' : '▶️ Run'}
            </button>
            <button onClick={() => setCode('')} disabled={loading}>
              🗑️ Clear
            </button>
          </div>
          <Editor
            height="calc(100% - 40px)"
            language="python"
            theme="vs-dark"
            value={code}
            onChange={setCode}
            options={{
              minimap: { enabled: false },
              fontSize: 14,
              lineNumbers: 'on',
              scrollBeyondLastLine: false,
            }}
          />
        </div>

        <div className="output-panel">
          <h3>Output</h3>
          <pre className="output">{output}</pre>
        </div>
      </main>
    </div>
  );
}

export default App;
```

### Day 5: Test & Debug

```bash
# Run dev server
npm run dev

# Test in browser at http://localhost:5173
```

**Success Criteria:** Can write and execute EigenScript code in browser

---

## Next Steps

### Week 5-6: Add Examples & Visualization
- Build example selector component
- Add geometric visualizer (D3.js)
- Implement error highlighting

### Week 7-8: Polish & Share
- Add share button (URL encoding)
- Performance optimization
- Mobile responsive design

### Week 9-10: Deploy
- Set up CI/CD
- Deploy to GitHub Pages
- Marketing launch

---

## Troubleshooting

### Problem: Pyodide won't load
```javascript
// Check browser console for errors
// Common issues:
// 1. CORS - need to serve from http server, not file://
// 2. Old browser - need WebAssembly support
// 3. Network issues - try different CDN

// Fallback to older Pyodide version
const pyodide = await loadPyodide({
  indexURL: "https://cdn.jsdelivr.net/pyodide/v0.24.0/full/"
});
```

### Problem: llvmlite not available
```python
# For MVP, can skip LLVM compilation and use interpreter only
# Modify compiler-api.js to use Interpreter instead:

const result = await pyodide.runPythonAsync(`
from eigenscript.evaluator.interpreter import Interpreter
interpreter = Interpreter()
result = interpreter.visit(ast)
`);
```

### Problem: Out of memory on mobile
```javascript
// Detect mobile and show warning
if (/Android|iPhone|iPad/i.test(navigator.userAgent)) {
  console.warn('Mobile detected - may have memory constraints');
  // Reduce history buffer, disable visualizations
}
```

---

## Quick Commands Reference

```bash
# Build WASM runtime
cd src/eigenscript/compiler/runtime
python3 build_runtime.py --target wasm32

# Package for browser
python3 scripts/build-browser-package.py

# Start dev server
cd playground/frontend
npm run dev

# Build for production
npm run build

# Deploy to GitHub Pages
npm run build
cd dist
git init
git add .
git commit -m "Deploy playground"
git push -f git@github.com:InauguralPhysicist/EigenScript.git main:gh-pages
```

---

## Need Help?

- 📖 Full roadmap: [PHASE5_INTERACTIVE_PLAYGROUND_ROADMAP.md](./PHASE5_INTERACTIVE_PLAYGROUND_ROADMAP.md)
- 💬 Discord: #playground channel
- 🐛 Issues: [GitHub Issues](https://github.com/InauguralPhysicist/EigenScript/issues)
- 📧 Email: inauguralphysicist@gmail.com

---

**Last Updated:** November 23, 2025  
**Status:** Ready to start
