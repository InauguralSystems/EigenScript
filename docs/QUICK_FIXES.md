# Quick Fixes for EigenScript Issues

This document provides copy-paste ready solutions for the issues identified in `ISSUE_REPORT.md`.

---

## Quick Win #1: Remove Unused Imports (5 minutes)

### File: `src/eigenscript/__main__.py`

**Line 9 - Remove unused import:**
```python
# BEFORE:
from pathlib import Path

# AFTER:
# Remove this line - Path is not used
```

**Line 61 - Remove or use the result variable:**
```python
# BEFORE:
result = interpreter.eval(source_code)

# AFTER (Option 1 - Remove if not needed):
interpreter.eval(source_code)

# AFTER (Option 2 - Use it if you need to return it):
result = interpreter.eval(source_code)
return result
```

---

### File: `src/eigenscript/builtins.py`

**Line 7 - Remove unused import:**
```python
# BEFORE:
import sys

# AFTER:
# Remove this line - sys is not used
```

**Line 1370 - Remove unused import:**
```python
# BEFORE:
from eigenscript.evaluator.interpreter import EigenList

# AFTER:
# Remove this line if it's truly unused in this scope
# OR add # noqa: F401 if it's a re-export
```

---

### File: `src/eigenscript/compiler/analysis/resolver.py`

**Line 7 - Remove unused import:**
```python
# BEFORE:
from typing import Optional

# AFTER:
# Remove this line if not used elsewhere
```

**Line 88 - Remove or use the variable:**
```python
# BEFORE:
is_wasm = target_triple.startswith("wasm")

# AFTER (Option 1 - Use it):
is_wasm = target_triple.startswith("wasm")
if is_wasm:
    # Handle WASM-specific logic

# AFTER (Option 2 - Remove if not needed):
# Remove this line
```

---

### File: `src/eigenscript/semantic/operations.py`

**Line 13 - Remove unused import:**
```python
# BEFORE:
import numpy as np

# AFTER:
# Remove this line - numpy is not used in this file
```

---

### File: `src/eigenscript/lexer/tokenizer.py`

**Line 516 - Prefix with underscore:**
```python
# BEFORE:
start_pos = self.pos

# AFTER:
_start_pos = self.pos  # Prefix with _ to indicate intentionally unused
```

---

## Quick Win #2: Fix Whitespace Before Colons (1 minute)

Run Black formatter to auto-fix all PEP 8 style issues:

```bash
cd /home/runner/work/EigenScript/EigenScript
black src/eigenscript/
```

Or manually fix these 5 files:

### File: `src/eigenscript/runtime/eigencontrol.py`

**Line 234 and 264:**
```python
# BEFORE:
metrics = {"key" : "value"}

# AFTER:
metrics = {"key": "value"}
```

### File: `src/eigenscript/runtime/framework_strength.py`

**Line 79 and 231:**
```python
# BEFORE:
data = {"field" : value}

# AFTER:
data = {"field": value}
```

### File: `src/eigenscript/semantic/lrvm.py`

**Line 343:**
```python
# BEFORE:
mapping = {"item" : val}

# AFTER:
mapping = {"item": val}
```

---

## Quick Win #3: Add Intentional Style Override Comments (5 minutes)

### File: `src/eigenscript/runtime/eigencontrol.py`

**Line 56 - Add noqa comment:**
```python
# BEFORE:
I = (A - B) ** 2  # E741: ambiguous variable name 'I'

# AFTER:
I = (A - B) ** 2  # noqa: E741 - Mathematical notation for Intensity metric
```

---

### File: `src/eigenscript/evaluator/interpreter.py`

**Line 957 - Remove unnecessary f-string:**
```python
# BEFORE:
message = f"Some static message"

# AFTER:
message = "Some static message"
```

**Line 1022 - Remove unnecessary f-string:**
```python
# BEFORE:
error = f"Error text"

# AFTER:
error = "Error text"
```

---

## Quick Win #4: Add Version Flag to CLI (10 minutes)

### File: `src/eigenscript/__main__.py`

Add after the argument parser is created:

```python
# Find where parser is created, then add:
parser.add_argument(
    '--version',
    action='version',
    version='EigenScript 0.3.0'
)
```

Or if you want it dynamic:

```python
# At the top of the file, add:
from eigenscript import __version__

# Then in the argument parser:
parser.add_argument(
    '--version',
    action='version',
    version=f'EigenScript {__version__}'
)
```

---

## Medium Priority Fix #1: Replace Star Import (30 minutes)

### File: `src/eigenscript/evaluator/interpreter.py`

**Line 11 - Replace star import with explicit imports:**

```python
# BEFORE:
from eigenscript.parser.ast_builder import *

# AFTER:
from eigenscript.parser.ast_builder import (
    ASTNode,
    Program,
    Assignment,
    Relation,
    BinaryOp,
    UnaryOp,
    Conditional,
    Loop,
    FunctionDef,
    Return,
    Literal,
    ListLiteral,
    ListComprehension,
    Index,
    Slice,
    Identifier,
    Interrogative,
)
```

**Benefits:**
- IDE autocomplete works correctly
- Clear which symbols are used
- Easier to track dependencies
- Removes 39 F405 warnings

---

## Medium Priority Fix #2: Add Optional Type Annotations (2-3 hours)

### File: `src/eigenscript/compiler/codegen/llvm_backend.py`

**Add Optional imports at the top:**
```python
from typing import Optional, Any
```

**Line 39 - Fix function signature:**
```python
# BEFORE:
def compile_error(self, message: str, hint: str = None, node: ASTNode = None):

# AFTER:
def compile_error(
    self, 
    message: str, 
    hint: Optional[str] = None, 
    node: Optional[ASTNode] = None
):
```

**Lines 82-84 - Fix __init__ signature:**
```python
# BEFORE:
def __init__(
    self,
    observed_variables: set[str] = None,
    target_triple: str = None,
    module_name: str = None,
):

# AFTER:
def __init__(
    self,
    observed_variables: Optional[set[str]] = None,
    target_triple: Optional[str] = None,
    module_name: Optional[str] = None,
):
```

---

### File: `src/eigenscript/parser/ast_builder.py`

Apply similar pattern to ~50 instances. Example template:

```python
# BEFORE:
def peek(self) -> Token:
    if self.current.type == TokenType.NEWLINE:  # Can fail if current is None
        ...

# AFTER (Option 1 - Add check):
def peek(self) -> Optional[Token]:
    if self.current and self.current.type == TokenType.NEWLINE:
        ...

# AFTER (Option 2 - Add assertion):
def peek(self) -> Token:
    assert self.current is not None, "Unexpected end of tokens"
    if self.current.type == TokenType.NEWLINE:
        ...
```

---

## Batch Script for All Quick Fixes

Save this as `apply_quick_fixes.sh`:

```bash
#!/bin/bash
set -e

# Get the repository root directory (where this script is located)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

echo "Applying quick fixes to EigenScript..."

# 1. Run Black formatter (fixes whitespace)
echo "Running Black formatter..."
black src/eigenscript/

# 2. Remove unused imports with autoflake
echo "Removing unused imports..."
pip install -q autoflake
autoflake --in-place --remove-all-unused-imports -r src/eigenscript/

# 3. Run isort to organize imports
echo "Organizing imports..."
pip install -q isort
isort src/eigenscript/

# 4. Verify no tests broke
echo "Running test suite..."
pytest -x -q

echo "✅ Quick fixes applied successfully!"
echo "📝 Review changes with: git diff"
echo "💾 Commit changes with: git add . && git commit -m 'Apply quick fixes from QUICK_FIXES.md'"
```

Make it executable and run:

```bash
chmod +x apply_quick_fixes.sh
./apply_quick_fixes.sh
```

---

## After Applying Fixes

### Verification Checklist:

Run these commands from the repository root:

```bash
# 1. Run tests
pytest -v

# 2. Check linting improved
flake8 src/eigenscript --count --exit-zero

# 3. Check type checking improved
mypy src/eigenscript | wc -l  # Count remaining errors

# 4. Run all examples
for f in examples/*.eigs; do 
    python -m eigenscript "$f" > /dev/null 2>&1 || echo "FAIL: $f"
done

# 5. Check coverage
pytest --cov=eigenscript --cov-report=term
```

### Expected Improvements:

**Before fixes:**
- Flake8 issues: 112
- Mypy warnings: ~70
- Test pass rate: 665/665

**After quick fixes only:**
- Flake8 issues: ~80 (reduction of 32)
- Mypy warnings: ~70 (unchanged - need medium priority fixes)
- Test pass rate: 665/665 (maintained)

**After all fixes:**
- Flake8 issues: ~30 (reduction of 82)
- Mypy warnings: ~10 (reduction of 60)
- Test pass rate: 665/665 (maintained)

---

## Priority Order

Apply fixes in this order for best results:

1. ✅ **Quick Win #2** - Run Black formatter (1 minute)
2. ✅ **Quick Win #1** - Remove unused imports (5 minutes)
3. ✅ **Quick Win #3** - Add noqa comments (5 minutes)
4. ✅ **Quick Win #4** - Add version flag (10 minutes)
5. ⏳ **Medium #1** - Replace star import (30 minutes)
6. ⏳ **Medium #2** - Add Optional annotations (2-3 hours)

**Total time for all quick wins:** ~20 minutes  
**Total time for medium priority:** ~3.5 hours

---

**Note:** Always run the test suite after applying fixes to ensure nothing broke!

```bash
pytest -v
```
