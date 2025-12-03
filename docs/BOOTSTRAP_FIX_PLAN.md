# EigenScript Bootstrap Fix Plan

**Created:** 2025-12-03  
**Status:** Active Investigation  
**Priority:** Critical - Blocking full self-hosting  
**Owner:** Development Team

---

## Executive Summary

This document provides a comprehensive plan for investigating and fixing the critical bootstrapping issues in the EigenScript self-hosted compiler. The primary focus is the **numeric literal bug** where all numeric values are generated as `0.0` instead of their actual values when the Stage 1 compiler compiles programs.

**Current Situation:**
- ✅ Stage 0 (Python reference compiler) successfully compiles all selfhost modules (5,642 lines)
- ✅ Stage 1 (self-hosted compiler) executes and generates valid LLVM IR
- ❌ **CRITICAL BUG:** Stage 1 generates `fadd double 0.0, 0.0` instead of `fadd double 0.0, 42.0` for `x is 42`
- ❌ Full bootstrap (Stage 1 → Stage 2) not achieved

**Impact:**
- Stage 1 compiler cannot compile any real programs with numeric literals
- Self-hosting milestone incomplete
- Blocks progress toward compiler independence

---

## Table of Contents

1. [Problem Analysis](#problem-analysis)
2. [Known Facts](#known-facts)
3. [Investigation Strategy](#investigation-strategy)
4. [Specific Areas to Investigate](#specific-areas-to-investigate)
5. [Diagnostic Steps](#diagnostic-steps)
6. [Hypothesis Testing](#hypothesis-testing)
7. [Fix Implementation Plan](#fix-implementation-plan)
8. [Validation Strategy](#validation-strategy)
9. [Timeline](#timeline)
10. [Resources](#resources)

---

## Problem Analysis

### The Bug

**Symptom:**  
When Stage 1 compiler compiles `x is 42`, it generates:
```llvm
%1 = fadd double 0.0, 0.0
```

**Expected:**
```llvm
%1 = fadd double 0.0, 42.0
```

### Data Flow Path

The numeric literal value flows through these stages:

1. **Lexer** (`lexer.eigs`):
   - Scans source code character by character
   - Recognizes numeric literal "42"
   - Stores value in `lex_last_num_val`
   - Sets token type to TOK_NUMBER (1)

2. **Main** (`main.eigs`, function `run_lexer`):
   - Calls `lexer_next_token()` repeatedly
   - Reads `lex_last_num_val` after each token
   - Appends to `parser_token_num_vals` list

3. **Parser** (`parser.eigs`):
   - Reads from `parser_token_num_vals[parser_pos]`
   - Stores in AST: `ast_num_value[arr_idx] is num_val`
   - Creates AST node for literal (type=LIT_NUMBER, node_type=1)

4. **Codegen** (`codegen.eigs`, function `gen_literal`):
   - Reads `num_val is ast_num_value[arr_idx]`
   - Should use `num_val` to generate LLVM IR
   - **BUG LOCATION:** `num_val` is 0.0 instead of 42.0

### Root Cause Analysis

The bug is **NOT** in the self-hosted compiler source code. The data flow in EigenScript is correct. The bug is in **how the Python reference compiler generates LLVM IR for the selfhost modules**.

**Key Insight:**  
When the reference compiler compiles `codegen.eigs`, it needs to generate code that:
1. Accesses the `ast_num_value` list at runtime
2. Reads the double value stored at `arr_idx`
3. Uses that value in subsequent LLVM IR generation

The reference compiler is somehow generating code that always reads `0.0` from the list.

---

## Known Facts

### ✅ What Works

1. **Lexer → Main data flow:**
   - Verified: `lex_last_num_val` is read correctly in `run_lexer`
   - Token num values are appended to `parser_token_num_vals`

2. **Main → Parser data flow:**
   - Parser reads from `parser_token_num_vals` correctly
   - Values are stored in `ast_num_value` array

3. **AST array sharing:**
   - Global variables like `ast_num_value` are properly declared
   - Cross-module visibility is configured correctly
   - `@__eigs_global_ast_num_value` exists in both parser.ll and codegen.ll

4. **LLVM IR structure:**
   - All modules compile to valid LLVM IR
   - Runtime functions are called correctly
   - Module linking succeeds

### ❌ What Doesn't Work

1. **Numeric value reading in codegen:**
   - `num_val is ast_num_value[arr_idx]` reads 0.0 at runtime
   - Affects ALL numeric literals uniformly
   - Not a single-instance bug; systematic problem

2. **Observed variable tracking:**
   - The reference compiler tracks which variables are "observed"
   - Observed variables trigger geometric EigenValue wrapping
   - List access of observed data may be compiled incorrectly

### 🔍 What Was Investigated

From `COMPILER_SELF_HOSTING.md` section "Troubleshooting":

> Investigation Summary:
> - The data flow path (lexer → main → parser → codegen) has been traced and verified
> - LLVM IR generation and runtime function implementations are correct
> - AST array sharing between modules is properly configured
> - **The issue appears to be in how the reference compiler handles observed variables and list operations when compiling selfhost modules**

---

## Investigation Strategy

### Phase 1: Reproduce and Isolate (1-2 days)

**Goal:** Create minimal reproducible test case

**Steps:**
1. Create tiny EigenScript program that mimics the problematic pattern
2. Compile with reference compiler to LLVM IR
3. Examine generated IR for list access patterns
4. Compare with working examples

### Phase 2: LLVM IR Analysis (2-3 days)

**Goal:** Understand the incorrect code generation

**Steps:**
1. Analyze `codegen.ll` generated by Stage 0
2. Find the `codegen_gen_literal` function in LLVM IR
3. Trace how `ast_num_value[arr_idx]` is compiled
4. Identify the exact instruction sequence that reads 0.0

### Phase 3: Reference Compiler Debugging (3-5 days)

**Goal:** Find the bug in `llvm_backend.py`

**Steps:**
1. Add debug logging to list access compilation
2. Trace compilation of `num_val is ast_num_value[arr_idx]`
3. Identify where the constant 0.0 is generated
4. Determine why actual value is lost

### Phase 4: Fix Implementation (2-3 days)

**Goal:** Patch the reference compiler

**Steps:**
1. Implement fix in `llvm_backend.py`
2. Recompile selfhost modules
3. Test Stage 1 compiler
4. Verify numeric literals work

### Phase 5: Validation (1-2 days)

**Goal:** Ensure fix is complete and doesn't break anything

**Steps:**
1. Run full test suite
2. Test complex numeric operations
3. Attempt full bootstrap (Stage 1 → Stage 2)
4. Verify Stage 1 and Stage 2 produce identical output

---

## Specific Areas to Investigate

### 1. Reference Compiler: List Access Compilation

**File:** `src/eigenscript/compiler/codegen/llvm_backend.py`

**Function:** `_compile_index` (Index operations like `list[idx]`)

**What to check:**
- How is `eigen_list_get` called?
- Is the result properly extracted from EigenValue?
- Are observed variables handled differently?

**Relevant code sections:**
```python
# Around line 3103
result = self.builder.call(self.eigen_list_get, [list_ptr, index_val])
```

**Questions:**
- When the list is a shared global (`ast_num_value`), how is it accessed?
- Is the pointer to the list retrieved correctly?
- Is `eigen_list_get` implemented correctly in the runtime?

### 2. Reference Compiler: Observed Variable Tracking

**File:** `src/eigenscript/compiler/codegen/llvm_backend.py`

**Mechanism:** Variables passed to `observed_variables` set trigger EigenValue wrapping

**What to check:**
- Is `ast_num_value` in the observed variables set?
- If yes, how does that affect list access compilation?
- Could EigenValue wrapping cause the 0.0 bug?

**Key insight from documentation:**
> The issue appears to be in how the reference compiler handles observed variables and list operations when compiling selfhost modules

**Hypothesis:**  
If `ast_num_value` is treated as observed, the reference compiler might:
1. Wrap each access in an EigenValue
2. Initialize the EigenValue incorrectly (with 0.0)
3. Lose the actual numeric value in the process

### 3. Reference Compiler: Global Variable Linkage

**File:** `src/eigenscript/compiler/codegen/llvm_backend.py`

**Function:** `_create_global_variable` (around line 1040-1080)

**What to check:**
- How are shared globals like `ast_num_value` initialized?
- Is the linkage correct for cross-module access?
- Could initialization to `0.0` be the problem?

**Relevant code:**
```python
# For library modules (is_library=True), only export shared data
shared_prefixes = (
    "lex_",  # Lexer state
    "ast_",  # AST data (INCLUDES ast_num_value!)
    "parser_token_",
    ...
)
```

**Questions:**
- Is `ast_num_value` declared as external in `codegen.ll`?
- Does the linker correctly resolve the symbol?
- At runtime, is the pointer to the actual data correct?

### 4. Runtime Library: List Implementation

**File:** `src/eigenscript/compiler/runtime/eigenvalue.c`

**Function:** `eigen_list_get`

**What to check:**
- Is the function implemented correctly?
- Does it handle the index bounds?
- Does it properly extract double values from EigenValue elements?

**Potential issues:**
- Off-by-one errors in indexing
- Incorrect pointer arithmetic
- Uninitialized data access

### 5. Reference Compiler: Binary Operations with Literals

**File:** `src/eigenscript/compiler/codegen/llvm_backend.py`

**Function:** `_compile_binary_op`

**What to check:**
- When `x is 42` is compiled, how is the literal handled?
- Is the RHS evaluated correctly?
- Does comparison trigger geometric tracking that corrupts the value?

**Code pattern:**
```eigenscript
num_val is ast_num_value[arr_idx]  # Reads value
if lit_type = LIT_STRING:          # Compares value
```

**Hypothesis:**  
The comparison operation might trigger observational mode, wrapping `num_val` in an EigenValue and losing the actual value.

---

## Diagnostic Steps

### Step 1: Create Minimal Test Case

**File:** `tests/bootstrap_debug_minimal.eigs`

```eigenscript
# Minimal reproduction of the bug pattern
global_nums is [42, 99, 123]

define get_num of idx as:
    val is global_nums[idx]
    return val

result is get_num of 0
print of result
```

**Compile and examine:**
```bash
eigenscript-compile tests/bootstrap_debug_minimal.eigs -o test_minimal.ll -O0
cat test_minimal.ll | grep -A 20 "define.*get_num"
```

**Expected behavior:** Should return 42  
**If buggy:** Will return 0.0

**What to look for:**
- How is `global_nums[idx]` compiled?
- Is `eigen_list_get` called correctly?
- Is the result extracted properly?

### Step 2: Examine Stage 1 LLVM IR

**File:** `build/bootstrap/codegen.ll`

**Focus on:** `codegen_gen_literal` function

**Commands:**
```bash
cd build/bootstrap
grep -A 100 "define.*codegen_gen_literal" codegen.ll > gen_literal_ir.txt
```

**Analyze:**
1. Find the load from `@__eigs_global_ast_num_value`
2. Trace the `eigen_list_get` call
3. Check what value is stored in the result register
4. Find where the LLVM IR string is built

**Look for patterns like:**
```llvm
; Should see actual index calculation
%arr_idx = fadd double %node_idx, 1.0

; Should see list access
%list_ptr = load double*, double** @__eigs_global_ast_num_value
%num_val = call double @eigen_list_get(double* %list_ptr, double %arr_idx)

; This is where the bug manifests: %num_val should be 42.0, but is 0.0
```

### Step 3: Add Debug Logging to Reference Compiler

**File:** `src/eigenscript/compiler/codegen/llvm_backend.py`

**Modifications:**

```python
def _compile_index(self, node: Index) -> GeneratedValue:
    """Compile list indexing: list[index]"""
    
    # ADD LOGGING
    print(f"DEBUG: Compiling index access")
    print(f"  Target: {node.target}")
    print(f"  Index: {node.index}")
    
    # Compile the list expression
    list_val = self._compile_expression(node.target)
    
    # ADD LOGGING
    print(f"  List kind: {list_val.kind}")
    if isinstance(node.target, Identifier):
        print(f"  List name: {node.target.name}")
        print(f"  Is observed: {node.target.name in self.observed_variables}")
    
    # ... rest of function
```

**Recompile selfhost modules with debug output:**
```bash
cd build/bootstrap
eigenscript-compile ../../src/eigenscript/compiler/selfhost/codegen.eigs -o codegen.ll -O0 --lib 2>&1 | tee codegen_debug.log
```

**Analyze `codegen_debug.log`:**
- How many times is `ast_num_value` accessed?
- Is it marked as observed?
- What is its ValueKind?

### Step 4: Compare Working vs Broken

**Create parallel test:**

**File:** `tests/bootstrap_debug_working.eigs`
```eigenscript
# Simple case that works
x is 42
y is x + 8
print of y
```

**File:** `tests/bootstrap_debug_broken.eigs`
```eigenscript
# Pattern that mimics selfhost codegen
nums is [42]
val is nums[0]
y is val + 8
print of y
```

**Compile both and compare IR:**
```bash
eigenscript-compile tests/bootstrap_debug_working.eigs -o working.ll -O0
eigenscript-compile tests/bootstrap_debug_broken.eigs -o broken.ll -O0
diff working.ll broken.ll
```

**Analyze differences:**
- How is the literal `42` handled in each case?
- Is there EigenValue wrapping in one but not the other?
- What's different about list access vs direct assignment?

### Step 5: Runtime Debugging

**Compile Stage 1 with debug symbols:**
```bash
cd build/bootstrap
# Add -g flag for debugging
gcc -g -c lexer.s parser.s semantic.s codegen.s main.s eigenvalue.c
gcc -g *.o -o eigensc_debug -lm
```

**Run under GDB:**
```bash
cat > test.eigs << 'EOF'
x is 42
print of x
EOF

gdb ./eigensc_debug
(gdb) break eigen_list_get
(gdb) run test.eigs
(gdb) print list
(gdb) print index
(gdb) print list->elements[index].value
```

**Check:**
- Is `ast_num_value` populated with correct values?
- Is `eigen_list_get` reading from the right memory?
- Is the value lost before or after the function call?

---

## Hypothesis Testing

### Hypothesis 1: EigenValue Wrapping Bug

**Theory:**  
When the reference compiler compiles list access for observed variables, it wraps the result in an EigenValue but initializes it incorrectly.

**Test:**
1. Check if `ast_num_value` is in `observed_variables`
2. If yes, temporarily remove it and recompile
3. See if Stage 1 works

**Expected result:**  
If this is the bug, Stage 1 should work after removing observation.

**Implementation:**
```python
# In llvm_backend.py, before compiling codegen.eigs
if 'ast_num_value' in self.observed_variables:
    self.observed_variables.remove('ast_num_value')
```

### Hypothesis 2: List Access Returns Uninitialized EigenValue

**Theory:**  
`eigen_list_get` returns a double, but the code expects an EigenValue pointer, leading to incorrect value extraction.

**Test:**
1. Examine `eigen_list_get` implementation
2. Check its return type in LLVM IR
3. Verify the caller correctly extracts the double

**Expected result:**  
Type mismatch or incorrect extraction.

### Hypothesis 3: Global Variable Not Shared Correctly

**Theory:**  
`ast_num_value` is not properly shared between `parser.ll` and `codegen.ll`, so codegen reads from a separate, uninitialized copy.

**Test:**
1. Check symbol visibility in object files:
   ```bash
   nm parser.o | grep ast_num_value
   nm codegen.o | grep ast_num_value
   ```
2. Verify the symbols match

**Expected result:**  
If broken: `parser.o` has a defined symbol, `codegen.o` references a different address.

**Fix:**  
Adjust linkage in `_create_global_variable` to ensure proper external linkage.

### Hypothesis 4: Comparison Operator Triggers Tracking

**Theory:**  
When `gen_literal` compares `lit_type = LIT_STRING`, the comparison wraps `lit_type` (which is `num_val`) in an EigenValue, losing the value.

**Test:**
1. Find the IR for the comparison
2. Check if it creates an EigenValue
3. See if the original value is still accessible after

**Expected result:**  
The value is wrapped but not unwrapped correctly.

**Fix:**  
Ensure comparisons don't corrupt the original value, or copy the value before comparison.

### Hypothesis 5: List Initialization Issue

**Theory:**  
When `ast_num_value` list is created and populated by the parser, the values are stored incorrectly.

**Test:**
1. Add debug output in `parser_parse_literal` to print values as they're stored
2. Verify values in `ast_num_value` immediately after parsing
3. Check if values are corrupted before codegen reads them

**Expected result:**  
Values are already 0.0 in the list after parsing.

**Fix:**  
Fix how the parser stores values in `ast_num_value`.

---

## Fix Implementation Plan

### Phase 1: Identify Root Cause (Week 1)

**Day 1-2:** Reproduce and isolate
- Create minimal test case
- Verify bug manifestation
- Document exact symptoms

**Day 3-4:** LLVM IR analysis
- Examine generated IR for all modules
- Trace data flow at IR level
- Identify incorrect instruction

**Day 5-7:** Reference compiler debugging
- Add comprehensive logging
- Step through compilation
- Pinpoint buggy code section

### Phase 2: Implement Fix (Week 2)

**Day 1-2:** Code the fix
- Modify `llvm_backend.py`
- Add necessary safeguards
- Document the change

**Day 3:** Test the fix
- Recompile selfhost modules
- Run Stage 1 compiler
- Verify numeric literals work

**Day 4:** Edge cases
- Test with various numeric values (negative, float, large numbers)
- Test with multiple list accesses
- Test with nested structures

**Day 5:** Integration testing
- Run full test suite (665 tests)
- Ensure no regressions
- Update documentation

### Phase 3: Validation (Week 3)

**Day 1-2:** Bootstrap testing
- Attempt Stage 1 → Stage 2 compilation
- Compare Stage 1 and Stage 2 outputs
- Verify byte-for-byte identical IR generation

**Day 3:** Performance testing
- Measure compilation times
- Check runtime performance
- Ensure no slowdowns

**Day 4:** Documentation
- Update COMPILER_SELF_HOSTING.md
- Remove "known issue" warnings
- Add "fix details" section

**Day 5:** Release preparation
- Create changelog entry
- Prepare release notes
- Tag version (v0.4.1 or v0.5.0)

---

## Validation Strategy

### Level 1: Unit Tests

**Create specific tests for the fix:**

**File:** `tests/test_selfhost_numeric_literals.py`

```python
import subprocess
import os

def test_stage1_numeric_literal_simple():
    """Test Stage 1 compiler with simple numeric literal."""
    code = "x is 42\nprint of x"
    
    # Compile with Stage 1
    result = subprocess.run(
        ["./build/bootstrap/eigensc"],
        input=code,
        capture_output=True,
        text=True
    )
    
    # Check LLVM IR contains correct value
    assert "42.0" in result.stdout or "4.2e+01" in result.stdout
    assert "0.0, 0.0" not in result.stdout  # Should NOT be 0.0, 0.0

def test_stage1_numeric_literal_complex():
    """Test with various numeric values."""
    test_cases = [
        ("x is 0", "0.0"),
        ("x is 42", "42.0"),
        ("x is -10", "-10.0"),
        ("x is 3.14159", "3.14159"),
        ("x is 1000000", "1000000.0"),
    ]
    
    for code, expected in test_cases:
        result = subprocess.run(
            ["./build/bootstrap/eigensc"],
            input=code,
            capture_output=True,
            text=True
        )
        assert expected in result.stdout or expected in result.stderr
```

### Level 2: Integration Tests

**Run existing test suite:**
```bash
pytest tests/ -v
```

**Expected:** All 665 tests pass

### Level 3: Bootstrap Test

**Run the full bootstrap script:**
```bash
bash scripts/bootstrap_test.sh
```

**Success criteria:**
- ✅ Stage 0 → Stage 1: Compiles successfully
- ✅ Stage 1 test: Generates correct LLVM IR with real numeric values
- ✅ Stage 1 → Stage 2: Compiles successfully (NEW!)
- ✅ Stage 1 and Stage 2 outputs are identical (NEW!)

### Level 4: Real-World Programs

**Test Stage 1 compiler with complex programs:**

```bash
cd build/bootstrap

# Test 1: Fibonacci
cat > fib.eigs << 'EOF'
define fib of n as:
    if n = 0:
        return 0
    if n = 1:
        return 1
    a is fib of (n - 1)
    b is fib of (n - 2)
    return a + b

result is fib of 10
print of result
EOF

./eigensc fib.eigs > fib.ll
llvm-as fib.ll -o fib.bc
llc fib.bc -o fib.s
gcc fib.s eigenvalue.o -o fib -lm
./fib  # Should output 55

# Test 2: List operations
cat > lists.eigs << 'EOF'
nums is [10, 20, 30, 40, 50]
sum is 0
i is 0
while i < 5:
    sum is sum + nums[i]
    i is i + 1
print of sum
EOF

./eigensc lists.eigs > lists.ll
# ... compile and run, should output 150

# Test 3: Self-compilation
./eigensc ../../src/eigenscript/compiler/selfhost/main.eigs > main_stage2.ll
# Should succeed without errors
```

---

## Timeline

### Aggressive Timeline (2-3 weeks)

| Phase | Duration | Milestone |
|-------|----------|-----------|
| Investigation | 5-7 days | Root cause identified |
| Fix Implementation | 2-3 days | Patch applied |
| Testing | 2-3 days | Stage 1 works correctly |
| Bootstrap Validation | 2-3 days | Stage 1 → Stage 2 successful |
| Documentation | 1 day | Docs updated |
| **Total** | **14-21 days** | **Full self-hosting achieved** |

### Conservative Timeline (4-6 weeks)

| Phase | Duration | Milestone |
|-------|----------|-----------|
| Investigation | 10-14 days | Multiple hypotheses tested |
| Fix Implementation | 5-7 days | Complex refactoring needed |
| Testing | 5-7 days | Comprehensive validation |
| Bootstrap Validation | 3-5 days | Stage 1 → Stage 2 verified |
| Documentation | 2-3 days | Complete docs update |
| **Total** | **28-42 days** | **Full self-hosting achieved** |

### Milestones

- [ ] **Milestone 1:** Root cause identified and documented
- [ ] **Milestone 2:** Fix implemented and tested
- [ ] **Milestone 3:** Stage 1 compiles programs with correct numeric literals
- [ ] **Milestone 4:** Stage 1 compiles itself (Stage 2 created)
- [ ] **Milestone 5:** Stage 1 and Stage 2 produce identical output
- [ ] **Milestone 6:** Full self-hosting achieved and documented

---

## Resources

### Primary Files

**Self-hosted compiler:**
- `src/eigenscript/compiler/selfhost/lexer.eigs` (578 lines)
- `src/eigenscript/compiler/selfhost/parser.eigs` (1,612 lines)
- `src/eigenscript/compiler/selfhost/semantic.eigs` (758 lines)
- `src/eigenscript/compiler/selfhost/codegen.eigs` (2,372 lines)
- `src/eigenscript/compiler/selfhost/main.eigs` (322 lines)

**Reference compiler:**
- `src/eigenscript/compiler/codegen/llvm_backend.py` (3,126 lines)

**Runtime:**
- `src/eigenscript/compiler/runtime/eigenvalue.c` (~1,700 lines)

**Testing:**
- `scripts/bootstrap_test.sh`

### Documentation

- `docs/COMPILER_SELF_HOSTING.md` - Comprehensive guide
- `docs/SELF_HOSTING_QUICKSTART.md` - Quick start
- `docs/KNOWN_ISSUES.md` - Known issues list
- `ROADMAP.md` - Project roadmap

### Tools

**LLVM toolchain:**
```bash
llvm-as    # Assemble LLVM IR to bitcode
llc        # Compile bitcode to assembly
llvm-dis   # Disassemble bitcode to IR
opt        # Optimize LLVM IR
```

**Debugging:**
```bash
gdb        # C debugger
valgrind   # Memory checker
lldb       # LLVM debugger
```

**Analysis:**
```bash
nm         # Symbol table viewer
objdump    # Object file analyzer
readelf    # ELF file reader
```

### References

**LLVM Documentation:**
- LLVM IR Language Reference: https://llvm.org/docs/LangRef.html
- LLVM Programmer's Manual: https://llvm.org/docs/ProgrammersManual.html

**Compiler Design:**
- Engineering a Compiler (Cooper & Torczon)
- Modern Compiler Implementation in ML (Appel)

**Self-hosting:**
- The Art of the Metaobject Protocol (Kiczales et al.)
- Reflections on Trusting Trust (Ken Thompson, 1984)

---

## Success Criteria

### Definition of Done

**The bootstrap fix is complete when:**

1. ✅ **Root cause identified and documented**
   - Exact line of code causing the bug is known
   - Mechanism of failure is understood
   - Fix approach is validated

2. ✅ **Fix implemented and tested**
   - Reference compiler patched
   - All 665 existing tests pass
   - No regressions introduced

3. ✅ **Stage 1 works correctly**
   - Compiles simple programs with numeric literals
   - Generated LLVM IR contains correct values (not 0.0)
   - Compiled programs execute with correct results

4. ✅ **Full bootstrap achieved**
   - Stage 1 compiles itself to produce Stage 2
   - Stage 2 is executable
   - Stage 1 and Stage 2 produce identical output for test programs

5. ✅ **Documentation updated**
   - COMPILER_SELF_HOSTING.md reflects new status
   - Known issues removed or updated
   - Fix details documented for future reference

6. ✅ **Release prepared**
   - Version bumped (v0.4.1 or v0.5.0)
   - Changelog updated
   - Release notes written

### Quality Gates

**Before merging fix:**
- [ ] All tests pass (665/665)
- [ ] No new compiler warnings
- [ ] No memory leaks (valgrind clean)
- [ ] Code review completed
- [ ] Documentation reviewed

**Before release:**
- [ ] Bootstrap test passes end-to-end
- [ ] Stage 1 compiles multiple real-world programs
- [ ] Performance benchmarks stable or improved
- [ ] Security audit passed (no new vulnerabilities)

---

## Next Steps

### Immediate Actions (Today)

1. **Create test branch:**
   ```bash
   git checkout -b fix/numeric-literal-bug
   ```

2. **Set up debug environment:**
   ```bash
   mkdir -p debug/
   cd debug/
   cp ../scripts/bootstrap_test.sh ./bootstrap_debug.sh
   ```

3. **Create minimal test case:**
   - Write `tests/bootstrap_debug_minimal.eigs`
   - Compile and verify bug manifests

4. **Begin LLVM IR analysis:**
   - Extract `codegen_gen_literal` from `build/bootstrap/codegen.ll`
   - Save to `debug/gen_literal_ir.txt`
   - Annotate and analyze

### This Week

- [ ] Complete Phase 1 investigation
- [ ] Create comprehensive debug logs
- [ ] Test all 5 hypotheses
- [ ] Narrow down to root cause

### Next Week

- [ ] Implement fix
- [ ] Test Stage 1 with fix
- [ ] Validate across test suite
- [ ] Prepare for bootstrap attempt

### Week 3

- [ ] Attempt full bootstrap
- [ ] Document findings
- [ ] Prepare release
- [ ] Update roadmap

---

## Risk Assessment

### High Risk Areas

1. **Complex interaction between observation and list access**
   - Risk: Fix might break geometric tracking
   - Mitigation: Comprehensive testing of observed variables

2. **Runtime library dependencies**
   - Risk: Changes might require runtime updates
   - Mitigation: Keep runtime API stable

3. **Performance impact**
   - Risk: Fix might slow compilation
   - Mitigation: Benchmark before and after

### Mitigation Strategies

**For each risk:**
- Create specific test cases
- Profile performance
- Have rollback plan ready

**Rollback plan:**
- Keep working reference compiler binary
- Tag commits clearly
- Document what worked and what didn't

---

## Appendices

### Appendix A: Key Code Sections

**`codegen.eigs` gen_literal function:**
```eigenscript
define gen_literal of node_idx as:
    arr_idx is node_idx + 1
    num_val is ast_num_value[arr_idx]  # BUG: reads 0.0
    str_idx is ast_str_index[arr_idx]
    reg is next_reg of 0
    reg_str is make_reg of reg
    
    lit_type is num_val  # Uses num_val for comparison
    
    if lit_type = LIT_STRING:
        # ... string handling
    else:
        # Number literal
        num_str is number_to_string of num_val  # Converts 0.0 to "0.0"
        line is cat3 of ["  ", reg_str, " = fadd double 0.0, "]
        line is cat2 of [line, num_str]  # Appends "0.0"
        append of output_lines of line
```

**Pattern to fix:** Ensure `num_val` reads actual value from `ast_num_value[arr_idx]`

### Appendix B: Glossary

- **Stage 0:** Python reference compiler
- **Stage 1:** Self-hosted compiler compiled by Stage 0
- **Stage 2:** Self-hosted compiler compiled by Stage 1
- **Bootstrap:** The process where Stage 1 compiles itself
- **EigenValue:** Runtime struct wrapping double for geometric tracking
- **Observed variable:** Variable subject to geometric state tracking
- **LLVM IR:** LLVM Intermediate Representation (textual assembly)

### Appendix C: Contact and Support

**Questions or issues:**
- Open GitHub issue with tag `bootstrap-bug`
- Reference this document in issue description
- Include minimal reproduction case

**Contributing:**
- See `CONTRIBUTING.md` for guidelines
- Submit PR with fix when ready
- Include test cases demonstrating fix

---

**Document version:** 1.0  
**Last updated:** 2025-12-03  
**Next review:** After root cause identified
