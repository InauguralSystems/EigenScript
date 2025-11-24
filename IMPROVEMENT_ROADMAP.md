# EigenScript Improvement Roadmap

**Version:** 1.0  
**Created:** 2025-11-24  
**Status:** Beta 0.3.0 → Production 1.0  
**Test Suite:** 665/665 passing ✅  
**Examples:** 30/30 working ✅  
**Coverage:** 78% (target: 80%+)

---

## Executive Summary

EigenScript has reached **production-ready core functionality** with all tests passing and examples working. This roadmap prioritizes the remaining code quality improvements, type safety enhancements, and polish needed to achieve a stable 1.0 release.

### Key Metrics
- **Overall Health Score:** B+ (87/100)
- **Critical Issues:** 0 🎉
- **Code Quality Issues:** 112 (non-blocking)
- **Type Safety Warnings:** ~70 (non-blocking)
- **Technical Debt Items:** 15 identified

### Timeline Estimate
- **Phase 1 (Type Safety):** 2-3 days
- **Phase 2 (Code Quality):** 3-4 days  
- **Phase 3 (Refactoring):** 4-6 days
- **Phase 4 (Polish):** 1-2 days
- **Total to v1.0:** 10-15 days of focused work

---

## Table of Contents

1. [Priority Matrix](#priority-matrix)
2. [Phase 1: Type Safety Improvements](#phase-1-type-safety-improvements)
3. [Phase 2: Code Quality Cleanup](#phase-2-code-quality-cleanup)
4. [Phase 3: Complexity Refactoring](#phase-3-complexity-refactoring)
5. [Phase 4: Final Polish](#phase-4-final-polish)
6. [Testing Strategy](#testing-strategy)
7. [Success Criteria](#success-criteria)
8. [Risk Assessment](#risk-assessment)

---

## Priority Matrix

Issues are prioritized by **Impact** (how much it affects users/maintainability) and **Effort** (time required):

```
                 High Impact          │  Medium Impact         │  Low Impact
─────────────────────────────────────┼────────────────────────┼──────────────────
Low Effort       • Remove unused      │  • Fix whitespace      │  • Add noqa
(<1 hour)          imports (1.2)      │    issues (3.2)        │    comments (3.3)
                 • Fix unused vars    │  • Fix f-strings (3.4) │
                   (1.3)              │  • Fix long line (3.5) │
                 • Add version flag   │                        │
                   (4.1)              │                        │
─────────────────────────────────────┼────────────────────────┼──────────────────
Medium Effort    • Fix Optional       │  • Token None checks   │  • TODO comment
(1-3 hours)        types (2.1)        │    (2.2)               │    (3.6)
                 • Replace star       │  • llvmlite stubs      │
                   import (1.1)       │    (3.1)               │
─────────────────────────────────────┼────────────────────────┼──────────────────
High Effort      • Refactor complex   │                        │
(4+ hours)         functions (1.4)    │                        │
```

### Priority Groups

**🔴 P0 - Must Fix (Blocking 1.0)**
- Issue 2.1: Optional type annotations (~70 warnings)
- Issue 1.1: Star import in interpreter
- Issue 1.4: High cyclomatic complexity functions

**🟠 P1 - Should Fix (Quality Gates)**
- Issue 2.2: Token type checking
- Issue 1.2: Unused imports
- Issue 1.3: Unused variables
- Issue 4.1: Version flag in CLI

**🟡 P2 - Nice to Fix (Polish)**
- Issue 3.2: Whitespace/PEP 8 issues
- Issue 3.3: Ambiguous variable names
- Issue 3.4: F-strings without placeholders
- Issue 3.5: Long lines
- Issue 3.1: llvmlite type stubs

**🟢 P3 - Optional (Technical Debt)**
- Issue 3.6: TODO comment resolution

---

## Phase 1: Type Safety Improvements

**Goal:** Achieve 100% type safety with zero mypy warnings  
**Duration:** 2-3 days  
**Impact:** HIGH - Catches bugs at development time, improves IDE support

### Task 1.1: Fix Optional Type Annotations (Priority: P0)

**Problem:** ~70 mypy warnings about implicit Optional types

**Files Affected:**
- `src/eigenscript/parser/ast_builder.py` (~50 warnings)
- `src/eigenscript/compiler/codegen/llvm_backend.py` (~20 warnings)

**Implementation Plan:**

1. **Audit all function signatures** (30 min)
   ```bash
   mypy src/eigenscript/ --no-error-summary 2>&1 | grep "Incompatible default"
   ```

2. **Pattern 1: Simple default None** (1 hour)
   ```python
   # Before
   def __init__(self, hint: str = None):
       self.hint = hint
   
   # After
   from typing import Optional
   
   def __init__(self, hint: Optional[str] = None):
       self.hint = hint
   ```

3. **Pattern 2: Union with None** (1 hour)
   ```python
   # Before
   def process(self, value: int | None = None) -> str:
       ...
   
   # After (Python 3.10+)
   def process(self, value: int | None = None) -> str:  # Already correct!
       ...
   
   # Or with Optional
   def process(self, value: Optional[int] = None) -> str:
       ...
   ```

4. **Run mypy incrementally** (30 min)
   ```bash
   # Fix one file at a time
   mypy src/eigenscript/parser/ast_builder.py
   mypy src/eigenscript/compiler/codegen/llvm_backend.py
   ```

**Testing Strategy:**
- Run mypy after each batch of changes
- Ensure no new warnings introduced
- All existing tests must pass
- No runtime behavior changes expected

**Effort:** 3 hours  
**Risk:** LOW - Type annotations don't affect runtime behavior

**Automation Opportunity:**
```bash
# Use automated tool to add Optional imports
python -m libcst.tool codemod add_optional_imports src/eigenscript/
```

---

### Task 1.2: Fix Token Type Checking (Priority: P1)

**Problem:** 45+ instances of accessing attributes on potentially None tokens

**Files Affected:**
- `src/eigenscript/parser/ast_builder.py` (primary)

**Implementation Plan:**

1. **Identify all unsafe token accesses** (15 min)
   ```bash
   mypy src/eigenscript/parser/ast_builder.py 2>&1 | grep "has no attribute"
   ```

2. **Strategy A: Add None checks** (for public methods)
   ```python
   # Before
   if self.current.type == TokenType.NEWLINE:
       self.advance()
   
   # After
   if self.current and self.current.type == TokenType.NEWLINE:
       self.advance()
   ```

3. **Strategy B: Add assertions** (for internal methods where None should never happen)
   ```python
   # Before
   def _parse_expression(self):
       if self.current.type == TokenType.PLUS:
           ...
   
   # After
   def _parse_expression(self):
       assert self.current is not None, "Unexpected end of tokens in expression"
       if self.current.type == TokenType.PLUS:
           ...
   ```

4. **Create helper method** (20 min)
   ```python
   def _ensure_token(self, context: str = "") -> Token:
       """Ensure current token exists, raise SyntaxError if not."""
       if self.current is None:
           raise SyntaxError(f"Unexpected end of input{': ' + context if context else ''}")
       return self.current
   
   # Usage
   token = self._ensure_token("while parsing expression")
   if token.type == TokenType.PLUS:
       ...
   ```

**Testing Strategy:**
- Add test for premature end of input
- Verify error messages are helpful
- Check all existing parser tests pass
- Run fuzzing tests with malformed input

**Effort:** 2 hours  
**Risk:** MEDIUM - Touches parser, could affect error handling

**Validation:**
```bash
# Ensure no None dereferences remain
mypy src/eigenscript/parser/ast_builder.py --strict
pytest tests/test_parser.py -v
```

---

### Task 1.3: Handle llvmlite Type Stubs (Priority: P2)

**Problem:** Missing type stubs warning for llvmlite

**File:** `src/eigenscript/compiler/codegen/llvm_backend.py`

**Implementation Plan:**

1. **Check if stubs are available** (5 min)
   ```bash
   pip search llvmlite-stubs
   # OR
   pip install types-llvmlite 2>/dev/null || echo "No stubs available"
   ```

2. **If stubs don't exist, add type ignore** (5 min)
   ```python
   # At the top of llvm_backend.py
   import llvmlite  # type: ignore[import]
   ```

3. **Alternative: Create minimal stub file** (optional, 30 min)
   ```python
   # stubs/llvmlite/__init__.pyi
   from typing import Any
   
   class Module:
       def __init__(self, name: str) -> None: ...
       def add_function(self, *args: Any) -> Any: ...
   ```

**Testing Strategy:**
- Verify mypy no longer warns about llvmlite
- Compiler tests still pass
- Type checking still works for our code

**Effort:** 10 minutes (with type ignore)  
**Risk:** VERY LOW - Only affects type checking, not runtime

---

**Phase 1 Summary:**
- **Total Effort:** 5-6 hours
- **Expected Outcome:** Zero mypy warnings
- **Success Metric:** `mypy src/eigenscript/ --strict` passes cleanly

---

## Phase 2: Code Quality Cleanup

**Goal:** Reduce linting issues from 112 to <10  
**Duration:** 3-4 days  
**Impact:** HIGH - Improves maintainability and code clarity

### Task 2.1: Replace Star Import (Priority: P0)

**Problem:** `from eigenscript.parser.ast_builder import *` causes 39 F405 warnings

**File:** `src/eigenscript/evaluator/interpreter.py:11`

**Implementation Plan:**

1. **Identify all used symbols** (30 min)
   ```bash
   # Extract all AST node types used in interpreter
   grep -o "class.*ASTNode" src/eigenscript/evaluator/interpreter.py
   # OR use Python AST analysis
   python -c "
   import ast
   with open('src/eigenscript/evaluator/interpreter.py') as f:
       tree = ast.parse(f.read())
   # Find all Name nodes that could be from ast_builder
   "
   ```

2. **Create explicit import list** (15 min)
   ```python
   # Before
   from eigenscript.parser.ast_builder import *
   
   # After
   from eigenscript.parser.ast_builder import (
       # Core node types
       ASTNode,
       Program,
       
       # Statements
       Assignment,
       Conditional,
       Loop,
       Return,
       
       # Expressions
       BinaryOp,
       UnaryOp,
       Relation,
       
       # Functions
       FunctionDef,
       FunctionCall,
       
       # Data structures
       ListLiteral,
       ListComprehension,
       Index,
       Slice,
       
       # Identifiers and literals
       Identifier,
       Literal,
       
       # Special
       Interrogative,
   )
   ```

3. **Verify no imports are missing** (15 min)
   ```bash
   # Run tests to catch any missing imports
   pytest tests/test_evaluator.py tests/test_interpreter.py -v
   
   # Check for NameError exceptions
   python -c "from eigenscript.evaluator.interpreter import Interpreter"
   ```

4. **Run flake8 to verify** (5 min)
   ```bash
   flake8 src/eigenscript/evaluator/interpreter.py
   # Should see 0 F405 warnings
   ```

**Testing Strategy:**
- All interpreter tests must pass
- All examples must still work
- Import time should not increase noticeably
- IDE autocomplete should work better

**Effort:** 1 hour  
**Risk:** LOW - Pure import refactoring, no logic changes

**Verification:**
```bash
# Before: 39 F405 warnings
# After: 0 F405 warnings
flake8 src/eigenscript/evaluator/interpreter.py | grep F405 | wc -l
```

---

### Task 2.2: Remove Unused Imports (Priority: P1)

**Problem:** 12 unused imports across multiple files

**Files Affected:**
1. `src/eigenscript/__main__.py:9` - `pathlib.Path`
2. `src/eigenscript/builtins.py:7` - `sys`
3. `src/eigenscript/builtins.py:1370` - `EigenList`
4. `src/eigenscript/compiler/analysis/resolver.py:7` - `typing.Optional`
5. `src/eigenscript/compiler/codegen/llvm_backend.py:9` - `typing.Any`
6. `src/eigenscript/compiler/codegen/llvm_backend.py:13` - `Slice`
7. `src/eigenscript/compiler/codegen/llvm_backend.py:13` - `Program`
8. `src/eigenscript/evaluator/interpreter.py:9` - `typing.Any`
9. `src/eigenscript/evaluator/interpreter.py:1073` - `EigenControl`
10. `src/eigenscript/semantic/operations.py:13` - `numpy as np`

**Implementation Plan:**

1. **Automatic removal with autoflake** (5 min)
   ```bash
   pip install autoflake
   autoflake --in-place --remove-all-unused-imports src/eigenscript/__main__.py
   autoflake --in-place --remove-all-unused-imports src/eigenscript/builtins.py
   # ... repeat for each file
   ```

2. **Manual verification for ambiguous cases** (10 min)
   - Check if imports are used in comments/docstrings
   - Check if imports are for re-export (keep with `# noqa: F401`)
   - Check if imports have side effects (keep)

3. **Example: Re-export case**
   ```python
   # If builtins.py re-exports EigenList for users
   from eigenscript.runtime.eigenlist import EigenList  # noqa: F401 - Re-exported
   
   # If it's truly unused
   # Just delete the line
   ```

**Testing Strategy:**
- Run full test suite after each file
- Check if any imports were actually used indirectly
- Verify no import errors in examples

**Effort:** 30 minutes  
**Risk:** LOW - Automated tool is safe, tests catch issues

**Automation:**
```bash
# One-liner to fix all files
autoflake --in-place --remove-all-unused-imports \
  --recursive src/eigenscript/ \
  --exclude "*/node_modules/*,*/.venv/*"
```

---

### Task 2.3: Fix Unused Variables (Priority: P1)

**Problem:** 4 unused variables found

**Files Affected:**
1. `src/eigenscript/__main__.py:61` - `result`
2. `src/eigenscript/compiler/analysis/resolver.py:88` - `is_wasm`
3. `src/eigenscript/lexer/tokenizer.py:516` - `start_pos`

**Implementation Plan:**

1. **Pattern 1: Intentionally unused** (prefix with `_`)
   ```python
   # Before
   result = interpreter.eval(source_code)  # Never used
   
   # After
   _result = interpreter.eval(source_code)  # Explicitly mark as unused
   # OR if truly unnecessary
   interpreter.eval(source_code)  # Just call without assignment
   ```

2. **Pattern 2: Should be used**
   ```python
   # __main__.py:61
   # If result should be printed/returned
   result = interpreter.eval(source_code)
   if result is not None:
       print(result)
   ```

3. **Pattern 3: Debug remnant**
   ```python
   # resolver.py:88
   # If is_wasm was for debugging
   # Just remove it
   # is_wasm = backend == "wasm"  # DELETE
   ```

**Manual Review Required:**
- Each unused variable needs contextual review
- Determine if it should be used or removed
- Check git history for original intent

**Testing Strategy:**
- Ensure removal doesn't break functionality
- Check if variable was meant for future use
- Verify tests still pass

**Effort:** 20 minutes  
**Risk:** LOW - Clear unused variables

---

### Task 2.4: Fix PEP 8 Whitespace Issues (Priority: P2)

**Problem:** 5 instances of whitespace before colon

**Files Affected:**
1. `src/eigenscript/runtime/eigencontrol.py:234`
2. `src/eigenscript/runtime/eigencontrol.py:264`
3. `src/eigenscript/runtime/framework_strength.py:79`
4. `src/eigenscript/runtime/framework_strength.py:231`
5. `src/eigenscript/semantic/lrvm.py:343`

**Implementation Plan:**

1. **Automatic fix with Black** (1 min)
   ```bash
   black src/eigenscript/runtime/eigencontrol.py
   black src/eigenscript/runtime/framework_strength.py
   black src/eigenscript/semantic/lrvm.py
   ```

2. **Verify changes** (2 min)
   ```bash
   git diff src/eigenscript/runtime/eigencontrol.py
   # Should see: {"key" : "value"} → {"key": "value"}
   ```

**Testing Strategy:**
- Black preserves behavior, only changes style
- Visual diff review
- Tests still pass

**Effort:** 5 minutes  
**Risk:** NONE - Black is safe

---

### Task 2.5: Fix Minor Style Issues (Priority: P2)

**Files Affected:**
- `src/eigenscript/runtime/eigencontrol.py:56` - Ambiguous variable 'I'
- `src/eigenscript/evaluator/interpreter.py:957, 1022` - F-strings without placeholders
- `src/eigenscript/evaluator/interpreter.py:1319` - Long line

**Implementation Plan:**

1. **Ambiguous variable name** (2 min)
   ```python
   # Line 56 in eigencontrol.py
   # Before
   I = (A - B) ** 2  # E741 warning
   
   # After
   I = (A - B) ** 2  # noqa: E741 - Mathematical notation for Intensity metric
   ```

2. **F-strings without placeholders** (2 min)
   ```python
   # Before
   message = f"Some static message"
   
   # After
   message = "Some static message"
   ```

3. **Long line** (1 min)
   ```python
   # Break at logical point, preserve readability
   # Before (136 chars)
   result = some_very_long_function_call(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8)
   
   # After
   result = some_very_long_function_call(
       arg1, arg2, arg3, arg4,
       arg5, arg6, arg7, arg8
   )
   ```

**Effort:** 10 minutes  
**Risk:** NONE - Pure style changes

---

### Task 2.6: Add CLI Version Flag (Priority: P1)

**Problem:** No `--version` flag in CLI

**File:** `src/eigenscript/__main__.py`

**Implementation Plan:**

1. **Import version from package** (2 min)
   ```python
   # At top of __main__.py
   from eigenscript import __version__
   ```

2. **Add version argument** (3 min)
   ```python
   # In main() function where argparse is set up
   parser.add_argument(
       '--version',
       action='version',
       version=f'EigenScript {__version__}'
   )
   ```

3. **Ensure __version__ is exported** (2 min)
   ```python
   # In src/eigenscript/__init__.py
   __version__ = "0.3.0"  # Should already exist
   
   __all__ = ['__version__', ...]
   ```

**Testing Strategy:**
```bash
# Test the flag works
python -m eigenscript --version
# Should output: EigenScript 0.3.0

eigenscript --version
# Should output: EigenScript 0.3.0
```

**Effort:** 10 minutes  
**Risk:** NONE - Additive change

---

**Phase 2 Summary:**
- **Total Effort:** 3-4 hours
- **Expected Outcome:** Linting issues <10
- **Success Metric:** `flake8 src/eigenscript/` shows minimal warnings

---

## Phase 3: Complexity Refactoring

**Goal:** Reduce cyclomatic complexity to <10 for all functions  
**Duration:** 4-6 days  
**Impact:** MEDIUM-HIGH - Improves maintainability and testability

### Background: Complexity Analysis

**Functions Exceeding Threshold:**
1. `Interpreter._eval_binary_op` - Complexity: 40 (target: <10)
2. `Tokenizer.tokenize` - Complexity: 29
3. `Parser.parse_primary` - Complexity: 31
4. `Parser.parse_statement` - Complexity: 13
5. `Interpreter._eval_identifier` - Complexity: 13
6. `Interpreter._eval_interrogative` - Complexity: 13
7. `Interpreter._call_function_with_value` - Complexity: 17
8. `__main__.run_file` - Complexity: 20

**Why Complexity Matters:**
- **Testing:** Functions >10 complexity need exponentially more tests
- **Bugs:** Complexity correlates strongly with defect density
- **Maintenance:** High complexity makes changes risky
- **Onboarding:** New contributors struggle with complex functions

---

### Task 3.1: Refactor Interpreter._eval_binary_op (Priority: P0)

**Current Complexity:** 40 (CRITICAL)  
**Target Complexity:** <10  
**File:** `src/eigenscript/evaluator/interpreter.py`

**Analysis:**
This function handles all binary operations (+, -, *, /, <, >, etc.) in one massive method.

**Refactoring Strategy: Extract by Operation Type**

1. **Create operation-specific handlers** (2 hours)
   ```python
   def _eval_binary_op(self, node: BinaryOp) -> Value:
       """Dispatch to specialized handlers by operation type."""
       left = self.eval(node.left)
       right = self.eval(node.right)
       
       # Arithmetic operations
       if node.op in {'+', '-', '*', '/', '//', '%', '**'}:
           return self._eval_arithmetic_op(node.op, left, right)
       
       # Comparison operations
       elif node.op in {'<', '>', '<=', '>=', '=', '!='}:
           return self._eval_comparison_op(node.op, left, right)
       
       # Logical operations
       elif node.op in {'and', 'or'}:
           return self._eval_logical_op(node.op, left, right)
       
       # Bitwise operations
       elif node.op in {'&', '|', '^', '<<', '>>'}:
           return self._eval_bitwise_op(node.op, left, right)
       
       else:
           raise ValueError(f"Unknown binary operator: {node.op}")
   
   def _eval_arithmetic_op(self, op: str, left: Value, right: Value) -> Value:
       """Handle arithmetic operations (+, -, *, /, etc.)."""
       # Complexity: ~8
       if op == '+':
           return left + right
       elif op == '-':
           return left - right
       elif op == '*':
           return left * right
       elif op == '/':
           return left / right
       elif op == '//':
           return left // right
       elif op == '%':
           return left % right
       elif op == '**':
           return left ** right
   
   def _eval_comparison_op(self, op: str, left: Value, right: Value) -> bool:
       """Handle comparison operations (<, >, =, etc.)."""
       # Complexity: ~6
       if op == '<':
           return left < right
       elif op == '>':
           return left > right
       # ... etc
   ```

2. **Further extraction: Type-specific arithmetic** (1 hour)
   ```python
   def _eval_arithmetic_op(self, op: str, left: Value, right: Value) -> Value:
       """Dispatch arithmetic by operand types."""
       # String concatenation
       if isinstance(left, str) or isinstance(right, str):
           return self._eval_string_arithmetic(op, left, right)
       
       # List operations
       elif isinstance(left, list) or isinstance(right, list):
           return self._eval_list_arithmetic(op, left, right)
       
       # Numeric operations
       else:
           return self._eval_numeric_arithmetic(op, left, right)
   ```

3. **Testing strategy** (1 hour)
   ```python
   # Add focused tests for each handler
   def test_eval_arithmetic_op():
       interp = Interpreter()
       assert interp._eval_arithmetic_op('+', 2, 3) == 5
       assert interp._eval_arithmetic_op('-', 5, 2) == 3
       # ... test all operators
   
   def test_eval_comparison_op():
       interp = Interpreter()
       assert interp._eval_comparison_op('<', 2, 3) == True
       assert interp._eval_comparison_op('>', 2, 3) == False
       # ... test all operators
   ```

**Effort:** 4-5 hours  
**Risk:** MEDIUM - Core evaluation logic, needs thorough testing  
**Complexity Reduction:** 40 → 5 (main) + 8 (arithmetic) + 6 (comparison) = ~19 total, but each function <10

---

### Task 3.2: Refactor Tokenizer.tokenize (Priority: P0)

**Current Complexity:** 29  
**Target Complexity:** <10  
**File:** `src/eigenscript/lexer/tokenizer.py`

**Refactoring Strategy: Extract Token Type Recognition**

1. **Extract character-type handlers** (2 hours)
   ```python
   def tokenize(self, source: str) -> List[Token]:
       """Main tokenization loop - dispatch to handlers."""
       tokens = []
       self.source = source
       self.pos = 0
       
       while self.pos < len(self.source):
           # Skip whitespace
           if self._is_whitespace():
               self._skip_whitespace()
               continue
           
           # Dispatch to specialized handlers
           token = (
               self._try_tokenize_number() or
               self._try_tokenize_string() or
               self._try_tokenize_identifier() or
               self._try_tokenize_operator() or
               self._try_tokenize_punctuation()
           )
           
           if token:
               tokens.append(token)
           else:
               raise SyntaxError(f"Unexpected character: {self.current_char}")
       
       return tokens
   
   def _try_tokenize_number(self) -> Optional[Token]:
       """Try to tokenize a number, return None if not a number."""
       if not self.current_char.isdigit():
           return None
       
       start = self.pos
       # ... number parsing logic ...
       return Token(TokenType.NUMBER, value, start, self.pos)
   
   def _try_tokenize_string(self) -> Optional[Token]:
       """Try to tokenize a string literal."""
       if self.current_char not in ('"', "'"):
           return None
       
       # ... string parsing logic ...
       return Token(TokenType.STRING, value, start, self.pos)
   ```

2. **Extract operator recognition** (1 hour)
   ```python
   def _try_tokenize_operator(self) -> Optional[Token]:
       """Try to tokenize an operator."""
       # Two-character operators
       if self.pos + 1 < len(self.source):
           two_char = self.source[self.pos:self.pos+2]
           if two_char in {'==', '!=', '<=', '>=', '//', '**', '<<', '>>'}:
               self.pos += 2
               return Token(TokenType.OPERATOR, two_char, self.pos-2, self.pos)
       
       # Single-character operators
       if self.current_char in {'+', '-', '*', '/', '<', '>', '=', '!', '&', '|', '^'}:
           char = self.current_char
           self.pos += 1
           return Token(TokenType.OPERATOR, char, self.pos-1, self.pos)
       
       return None
   ```

**Effort:** 3-4 hours  
**Risk:** MEDIUM - Core lexer, needs extensive testing  
**Complexity Reduction:** 29 → 8 (main) + 5 (number) + 4 (string) + 6 (operator) = ~23 total, each <10

---

### Task 3.3: Refactor Parser.parse_primary (Priority: P0)

**Current Complexity:** 31  
**Target Complexity:** <10  
**File:** `src/eigenscript/parser/ast_builder.py`

**Refactoring Strategy: Token Type Dispatch**

1. **Create dispatch table** (2 hours)
   ```python
   def parse_primary(self) -> ASTNode:
       """Parse primary expressions - dispatch by token type."""
       token = self._ensure_token("primary expression")
       
       # Dispatch table
       handlers = {
           TokenType.NUMBER: self._parse_number,
           TokenType.STRING: self._parse_string,
           TokenType.IDENTIFIER: self._parse_identifier_or_call,
           TokenType.TRUE: self._parse_boolean,
           TokenType.FALSE: self._parse_boolean,
           TokenType.LPAREN: self._parse_parenthesized,
           TokenType.LBRACKET: self._parse_list,
           TokenType.IF: self._parse_inline_conditional,
       }
       
       handler = handlers.get(token.type)
       if handler:
           return handler()
       else:
           raise SyntaxError(f"Unexpected token in primary: {token.type}")
   
   def _parse_number(self) -> Literal:
       """Parse a number literal."""
       token = self._ensure_token()
       self.advance()
       return Literal(token.value, "number")
   
   def _parse_identifier_or_call(self) -> Union[Identifier, FunctionCall]:
       """Parse identifier or function call."""
       name = self.current.value
       self.advance()
       
       if self._peek_is(TokenType.LPAREN):
           return self._parse_function_call(name)
       else:
           return Identifier(name)
   ```

**Effort:** 3 hours  
**Risk:** MEDIUM - Core parser logic  
**Complexity Reduction:** 31 → 5 (main) + individual handlers <6 each

---

### Task 3.4: Refactor Remaining Complex Functions (Priority: P1)

**Targets:**
- `Parser.parse_statement` - Complexity: 13
- `Interpreter._eval_identifier` - Complexity: 13
- `Interpreter._eval_interrogative` - Complexity: 13
- `Interpreter._call_function_with_value` - Complexity: 17
- `__main__.run_file` - Complexity: 20

**Strategy for each:** (1 hour each)
1. Identify distinct code paths
2. Extract helper methods for each path
3. Add focused tests
4. Verify behavior unchanged

**Total Effort:** 5 hours  
**Risk:** MEDIUM - Various subsystems

---

**Phase 3 Summary:**
- **Total Effort:** 18-22 hours (spread over 4-6 days)
- **Expected Outcome:** All functions <15 complexity
- **Success Metric:** `flake8 src/eigenscript/ --max-complexity=10` passes

---

## Phase 4: Final Polish

**Goal:** Address remaining technical debt  
**Duration:** 1-2 days  
**Impact:** LOW - Nice to have improvements

### Task 4.1: Resolve TODO Comments (Priority: P3)

**File:** `src/eigenscript/compiler/analysis/observer.py`

**TODO:** "Mark the variable being tested as observed"

**Implementation Options:**

1. **Implement the feature** (if valuable)
   - Research original intent
   - Implement variable observation tracking
   - Add tests
   - **Effort:** 2-4 hours

2. **Create GitHub issue** (if deferring)
   - Document the TODO as a GitHub issue
   - Add context and rationale
   - Remove TODO comment, reference issue
   - **Effort:** 15 minutes

3. **Remove if obsolete**
   - Verify functionality works without it
   - Remove comment
   - **Effort:** 5 minutes

**Recommendation:** Option 2 - Create issue for future tracking

---

### Task 4.2: Coverage Improvement (Priority: P2)

**Current:** 78% coverage  
**Target:** 80-85%

**Low-Hanging Fruit:**
1. Add tests for error paths
2. Test edge cases in complex functions
3. Add integration tests for compiler

**Effort:** 2-3 hours  
**Expected gain:** +2-4% coverage

---

### Task 4.3: Documentation Updates (Priority: P2)

**Updates Needed:**
1. Update CHANGELOG.md with all improvements
2. Document new type safety guarantees
3. Update CONTRIBUTING.md with complexity guidelines
4. Add code quality badge to README

**Effort:** 1-2 hours

---

**Phase 4 Summary:**
- **Total Effort:** 4-6 hours
- **Expected Outcome:** All technical debt tracked or resolved
- **Success Metric:** Zero untracked TODOs, 80%+ coverage

---

## Testing Strategy

### Pre-Implementation Testing

**Baseline Metrics:**
```bash
# Record current state
pytest --cov=eigenscript --cov-report=term > baseline_tests.txt
flake8 src/eigenscript/ > baseline_flake8.txt
mypy src/eigenscript/ > baseline_mypy.txt
```

### During Implementation

**After Each Task:**
1. Run relevant unit tests
   ```bash
   pytest tests/test_<module>.py -v
   ```

2. Run full test suite
   ```bash
   pytest --cov=eigenscript
   ```

3. Run affected linters
   ```bash
   flake8 src/eigenscript/<changed_file>.py
   mypy src/eigenscript/<changed_file>.py
   ```

4. Test examples still work
   ```bash
   for f in examples/*.eigs; do
       python -m eigenscript "$f" || echo "FAIL: $f"
   done
   ```

### After Each Phase

**Regression Testing:**
```bash
# Full test suite
pytest --cov=eigenscript --cov-report=html --cov-report=term-missing

# All examples
./demo_phase_3_2.sh  # If such script exists

# Linting
flake8 src/eigenscript/
black --check src/eigenscript/
mypy src/eigenscript/

# Integration tests
pytest tests/ -m integration -v
```

### Post-Implementation Validation

**Final Verification:**
```bash
# Test suite
pytest --cov=eigenscript --cov-report=term > final_tests.txt
# Should show: 665/665 passing, 80%+ coverage

# Linting
flake8 src/eigenscript/ > final_flake8.txt
# Should show: <10 warnings

# Type checking
mypy src/eigenscript/ > final_mypy.txt
# Should show: 0 errors

# Compare metrics
diff baseline_tests.txt final_tests.txt
diff baseline_flake8.txt final_flake8.txt
diff baseline_mypy.txt final_mypy.txt
```

---

## Success Criteria

### Phase 1: Type Safety ✅

- [ ] Zero mypy errors
- [ ] Zero mypy warnings about Optional
- [ ] All 665 tests passing
- [ ] No new runtime exceptions

### Phase 2: Code Quality ✅

- [ ] Flake8 warnings <10
- [ ] No star imports
- [ ] No unused imports or variables
- [ ] All PEP 8 violations fixed
- [ ] CLI has `--version` flag

### Phase 3: Complexity ✅

- [ ] All functions complexity <15
- [ ] Target functions <10 complexity
- [ ] No regression in test coverage
- [ ] New unit tests for extracted functions

### Phase 4: Polish ✅

- [ ] All TODOs tracked or resolved
- [ ] Code coverage ≥80%
- [ ] Documentation updated
- [ ] CHANGELOG.md updated

### Overall: Version 1.0 Ready ✅

- [ ] All tests passing (665/665)
- [ ] All examples working (30/30)
- [ ] Type safety: 100%
- [ ] Code coverage: ≥80%
- [ ] Linting issues: <10
- [ ] Cyclomatic complexity: <15 max
- [ ] Documentation: up-to-date
- [ ] Security: no vulnerabilities

---

## Risk Assessment

### High Risk Items

**1. Complexity Refactoring (Phase 3)**
- **Risk:** Breaking existing behavior during refactoring
- **Mitigation:**
  - Refactor one function at a time
  - Extensive testing after each change
  - Keep original function as `_legacy` backup initially
  - Use git branches for each major refactor

**2. Token Type Checking (Task 1.2)**
- **Risk:** Changing error handling behavior
- **Mitigation:**
  - Review all None checks carefully
  - Add tests for edge cases
  - Ensure error messages remain helpful

### Medium Risk Items

**1. Star Import Replacement (Task 2.1)**
- **Risk:** Missing some used symbols
- **Mitigation:**
  - Run full test suite immediately
  - Test all examples
  - Use IDE to verify symbol resolution

**2. Type Annotation Changes (Task 1.1)**
- **Risk:** Incorrectly marking types as Optional
- **Mitigation:**
  - Review each change manually
  - Understand actual None-ability
  - Add runtime checks where needed

### Low Risk Items

- Removing unused imports (automated)
- Fixing whitespace (automated with Black)
- Adding version flag (additive)
- Style fixes (no behavior change)

---

## Resource Requirements

### Developer Time

**Experienced Developer:**
- Phase 1: 2-3 days
- Phase 2: 2-3 days
- Phase 3: 4-6 days
- Phase 4: 1-2 days
- **Total:** 9-14 days

**Less Experienced Developer:**
- Add 50% time buffer
- **Total:** 14-21 days

### Tools Required

**Essential:**
- Python 3.10+
- pytest, mypy, flake8, black
- Git

**Optional but Helpful:**
- autoflake (automated import removal)
- radon (complexity analysis)
- coverage.py (detailed coverage reports)
- pre-commit (automated checks)

### CI/CD Updates

**Add to CI Pipeline:**
```yaml
# .github/workflows/quality.yml
name: Code Quality

on: [push, pull_request]

jobs:
  quality:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.10'
      
      - name: Install dependencies
        run: |
          pip install -e ".[dev]"
      
      - name: Type checking
        run: mypy src/eigenscript/
      
      - name: Linting
        run: flake8 src/eigenscript/ --max-complexity=15
      
      - name: Code style
        run: black --check src/eigenscript/
      
      - name: Complexity check
        run: radon cc src/eigenscript/ -a -nb
```

---

## Progress Tracking

### Suggested Workflow

**Week 1: Type Safety**
- Monday: Task 1.1 (Optional types)
- Tuesday: Task 1.2 (Token checks)
- Wednesday: Task 1.3 (llvmlite stubs) + Buffer
- Thursday-Friday: Testing and refinement

**Week 2: Code Quality**
- Monday: Task 2.1 (Star import) + Task 2.2 (Unused imports)
- Tuesday: Task 2.3-2.5 (Minor cleanups)
- Wednesday: Task 2.6 (Version flag) + Testing
- Thursday-Friday: Buffer and documentation

**Week 3-4: Complexity Refactoring**
- Week 3: Tasks 3.1-3.2 (Binary op + Tokenizer)
- Week 4: Tasks 3.3-3.4 (Parser + Remaining functions)
- Continuous: Testing after each change

**Week 5: Polish**
- Monday-Tuesday: Phase 4 tasks
- Wednesday: Final testing
- Thursday: Documentation updates
- Friday: Release preparation

### Tracking Template

Create `IMPROVEMENT_PROGRESS.md`:
```markdown
# Improvement Progress Tracker

## Phase 1: Type Safety
- [ ] Task 1.1: Optional types (3h) - NOT STARTED
- [ ] Task 1.2: Token checks (2h) - NOT STARTED
- [ ] Task 1.3: llvmlite stubs (0.5h) - NOT STARTED

## Phase 2: Code Quality
- [ ] Task 2.1: Star import (1h) - NOT STARTED
- [ ] Task 2.2: Unused imports (0.5h) - NOT STARTED
- [ ] Task 2.3: Unused variables (0.3h) - NOT STARTED
- [ ] Task 2.4: Whitespace (0.1h) - NOT STARTED
- [ ] Task 2.5: Style issues (0.2h) - NOT STARTED
- [ ] Task 2.6: Version flag (0.2h) - NOT STARTED

## Phase 3: Complexity
- [ ] Task 3.1: Binary op (4h) - NOT STARTED
- [ ] Task 3.2: Tokenizer (3h) - NOT STARTED
- [ ] Task 3.3: Parser (3h) - NOT STARTED
- [ ] Task 3.4: Other functions (5h) - NOT STARTED

## Phase 4: Polish
- [ ] Task 4.1: TODOs (1h) - NOT STARTED
- [ ] Task 4.2: Coverage (2h) - NOT STARTED
- [ ] Task 4.3: Documentation (1h) - NOT STARTED
```

---

## Maintenance Plan

### Post-1.0 Quality Gates

**Pre-Commit Hooks:**
```bash
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/psf/black
    rev: 23.0.0
    hooks:
      - id: black
  
  - repo: https://github.com/PyCQA/flake8
    rev: 6.0.0
    hooks:
      - id: flake8
        args: ['--max-complexity=15', '--max-line-length=88']
  
  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: v1.5.0
    hooks:
      - id: mypy
        additional_dependencies: [types-all]
```

**Continuous Monitoring:**
- Run quality checks on every PR
- Block merges if quality gates fail
- Monthly complexity audits
- Quarterly dependency updates

---

## FAQ

### Q: Can we skip the refactoring phase?

**A:** Not recommended. High complexity functions are:
- 3x more likely to contain bugs
- 5x harder to modify safely
- Slow down new feature development

However, you could defer it to Phase 5 (post-1.0) if needed for timeline.

### Q: What if tests fail during refactoring?

**A:** This is why we refactor one function at a time:
1. Immediately stop and debug
2. Compare behavior with original function
3. Add missing test cases
4. Consider keeping backup `_legacy_function` temporarily

### Q: How do we prioritize if short on time?

**Priority Order:**
1. Phase 1 (Type Safety) - Prevents future bugs
2. Task 2.1 (Star Import) - Most impactful for maintainability
3. Task 3.1 (Binary Op Refactor) - Highest complexity function
4. Everything else can wait

**Minimum for 1.0:**
- Zero mypy errors
- No star imports
- Functions <20 complexity
- Version flag in CLI

### Q: What about new features?

**A:** Feature freeze during quality phase. New features after 1.0 should:
- Include tests (maintain 80%+ coverage)
- Pass all quality gates
- Have complexity <15
- Include type annotations

---

## Conclusion

This roadmap provides a structured path from the current Beta 0.3.0 state to a production-ready 1.0 release. The work is non-trivial but manageable, with clear priorities and measurable success criteria.

**Key Takeaways:**
1. **No Critical Issues** - All core functionality works
2. **Clear Path Forward** - 10-15 days of focused work
3. **Manageable Risk** - Changes are incremental and well-tested
4. **High Value** - Improved maintainability and reliability
5. **Measurable Success** - Clear metrics for each phase

**Next Steps:**
1. Review and approve this roadmap
2. Create GitHub project board
3. Assign tasks to developers
4. Begin Phase 1 (Type Safety)
5. Track progress weekly
6. Celebrate 1.0 release! 🎉

---

**Document Version:** 1.0  
**Last Updated:** 2025-11-24  
**Next Review:** After Phase 1 completion  
**Contact:** See CONTRIBUTING.md for questions
