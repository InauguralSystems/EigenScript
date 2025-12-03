# Bootstrap Investigation Checklist

**Purpose:** Quick reference for investigating the numeric literal bug  
**Status:** Active  
**Created:** 2025-12-03

This is a companion to `BOOTSTRAP_FIX_PLAN.md` providing actionable checklists and quick commands.

---

## Quick Start

### Setup Investigation Environment

```bash
# 1. Create debug directory
mkdir -p debug/bootstrap_investigation
cd debug/bootstrap_investigation

# 2. Copy scripts
cp ../../scripts/bootstrap_test.sh ./

# 3. Create test files directory
mkdir -p test_cases

# 4. Build fresh Stage 1 compiler
cd ../../
bash scripts/bootstrap_test.sh
```

---

## Investigation Phases

### Phase 1: Reproduce the Bug ✓

#### Checklist

- [ ] Compile Stage 1 compiler using reference compiler
- [ ] Create simple test program with numeric literal
- [ ] Run Stage 1 on test program
- [ ] Verify output contains `0.0, 0.0` instead of `0.0, 42.0`
- [ ] Document exact output

#### Commands

```bash
# Build Stage 1
cd build/bootstrap
bash ../../scripts/bootstrap_test.sh

# Create test case
cat > test_literal.eigs << 'EOF'
x is 42
y is x + 8
print of y
EOF

# Run Stage 1
./eigensc test_literal.eigs > test_literal.ll 2>&1

# Check output
grep "fadd double" test_literal.ll
# Expected: fadd double 0.0, 42.0
# Actual:   fadd double 0.0, 0.0
```

#### Success Criteria

- [ ] Bug consistently reproduces
- [ ] Same behavior with different numeric values
- [ ] Output is otherwise valid LLVM IR

---

### Phase 2: Analyze LLVM IR ✓

#### Checklist

- [ ] Extract `codegen_gen_literal` function from codegen.ll
- [ ] Identify list access pattern for `ast_num_value`
- [ ] Find `eigen_list_get` call
- [ ] Trace value extraction
- [ ] Locate where constant 0.0 appears

#### Commands

```bash
cd build/bootstrap

# Extract gen_literal function
grep -A 200 "define.*codegen_gen_literal" codegen.ll > gen_literal.ll

# Find list accesses
grep -n "eigen_list_get" codegen.ll

# Find ast_num_value references
grep -n "@__eigs_global_ast_num_value" codegen.ll

# Check global declarations
grep "global_ast_num_value" *.ll
```

#### Analysis Template

Save findings to `debug/ir_analysis.md`:

```markdown
## LLVM IR Analysis - codegen_gen_literal

### Function Entry
- Line: [line number]
- Parameters: [parameters]
- Entry block: [block name]

### List Access Pattern
- ast_num_value load: [instruction]
- Index calculation: [instruction]
- eigen_list_get call: [instruction]
- Result: [register name]

### Value Usage
- Where num_val is used: [list of uses]
- Where it should be 42.0: [specific instruction]
- Actual value observed: [actual value]

### Hypothesis
[What you think is wrong]
```

#### Success Criteria

- [ ] Understand the exact IR instruction sequence
- [ ] Identify where 0.0 originates
- [ ] Have clear hypothesis about root cause

---

### Phase 3: Trace Reference Compiler ✓

#### Checklist

- [ ] Add debug logging to `llvm_backend.py`
- [ ] Recompile codegen.eigs with logging
- [ ] Capture compilation trace
- [ ] Identify where bug is introduced
- [ ] Correlate with IR analysis

#### Instrumentation Points

**File:** `src/eigenscript/compiler/codegen/llvm_backend.py`

**Add logging to these functions:**

1. `_compile_index` (list access):
```python
def _compile_index(self, node: Index) -> GeneratedValue:
    print(f"[DEBUG] _compile_index called")
    print(f"  Target: {node.target}")
    print(f"  Target type: {type(node.target)}")
    if isinstance(node.target, Identifier):
        print(f"  List name: {node.target.name}")
        print(f"  Is observed: {node.target.name in self.observed_variables}")
    # ... existing code
```

2. `_compile_binary_op` (comparisons):
```python
def _compile_binary_op(self, node: BinaryOp) -> GeneratedValue:
    print(f"[DEBUG] _compile_binary_op: {node.op}")
    left_val = self._compile_expression(node.left)
    right_val = self._compile_expression(node.right)
    print(f"  Left kind: {left_val.kind}")
    print(f"  Right kind: {right_val.kind}")
    # ... existing code
```

3. `_compile_assignment` (storing to variables):
```python
def _compile_assignment(self, node: Assignment) -> None:
    print(f"[DEBUG] _compile_assignment: {node.target}")
    value = self._compile_expression(node.value)
    print(f"  Value kind: {value.kind}")
    if node.target in self.observed_variables:
        print(f"  Target is observed: {node.target}")
    # ... existing code
```

#### Commands

```bash
# Recompile with debug logging
cd build/bootstrap
eigenscript-compile ../../src/eigenscript/compiler/selfhost/codegen.eigs \
    -o codegen_debug.ll -O0 --lib 2>&1 | tee codegen_compile.log

# Analyze log
grep "DEBUG" codegen_compile.log > debug_trace.txt
grep "ast_num_value" debug_trace.txt
```

#### Success Criteria

- [ ] Captured full compilation trace
- [ ] Identified problematic function calls
- [ ] Understand observed variable handling
- [ ] Know exact point where bug is introduced

---

### Phase 4: Test Hypotheses ✓

Use this checklist to systematically test each hypothesis.

#### Hypothesis 1: EigenValue Wrapping Bug

- [ ] Check if `ast_num_value` is in observed variables
- [ ] Temporarily remove from observed set
- [ ] Recompile codegen.eigs
- [ ] Test Stage 1 compiler
- [ ] Document result

**Test code:**
```python
# In llvm_backend.py, in __init__ or before compiling codegen.eigs
if 'ast_num_value' in self.observed_variables:
    print(f"Removing ast_num_value from observed set")
    self.observed_variables.discard('ast_num_value')
```

**Result:** [ ] Fixed / [ ] No change / [ ] Made worse

---

#### Hypothesis 2: List Access Returns Wrong Type

- [ ] Examine `eigen_list_get` signature
- [ ] Check return type (double vs EigenValue*)
- [ ] Verify caller extracts value correctly
- [ ] Check for type mismatches

**Commands:**
```bash
# Check function signature in IR
grep "declare.*eigen_list_get" build/bootstrap/*.ll

# Check runtime implementation
grep -A 20 "eigen_list_get" src/eigenscript/compiler/runtime/eigenvalue.c
```

**Result:** [ ] Type mismatch found / [ ] Types correct

---

#### Hypothesis 3: Global Variable Not Shared

- [ ] Check symbol visibility with `nm`
- [ ] Verify external linkage in codegen.ll
- [ ] Compare addresses at runtime
- [ ] Test with explicit external declaration

**Commands:**
```bash
cd build/bootstrap

# Check symbols
nm -C parser.o | grep ast_num_value
nm -C codegen.o | grep ast_num_value

# Should see:
# parser.o: D __eigs_global_ast_num_value (defined)
# codegen.o: U __eigs_global_ast_num_value (undefined, external)
```

**Result:** [ ] Linkage issue found / [ ] Linkage correct

---

#### Hypothesis 4: Comparison Corrupts Value

- [ ] Find IR for `if lit_type = LIT_STRING:`
- [ ] Check if comparison creates EigenValue
- [ ] Verify `num_val` still accessible after
- [ ] Test with value copy before comparison

**Test modification to codegen.eigs:**
```eigenscript
define gen_literal of node_idx as:
    arr_idx is node_idx + 1
    num_val is ast_num_value[arr_idx]
    
    # Create a copy before comparison
    num_val_copy is num_val + 0
    lit_type is num_val_copy  # Use copy for comparison
    
    if lit_type = LIT_STRING:
        # ... existing code
```

**Result:** [ ] Copy helps / [ ] No difference

---

#### Hypothesis 5: Parser Stores Incorrectly

- [ ] Add debug output to parser.eigs
- [ ] Print values as they're stored
- [ ] Verify `ast_num_value` contents after parsing
- [ ] Check if corruption happens before codegen

**Test modification to parser.eigs:**
```eigenscript
# In parse_literal function, after storing value
ast_num_value[arr_idx] is y
print of y  # Debug: should print actual value
```

**Result:** [ ] Values correct in parser / [ ] Already corrupted

---

### Phase 5: Implement Fix ✓

Once root cause is identified, use this checklist for implementation.

#### Pre-Implementation

- [ ] Document root cause clearly
- [ ] Design fix approach
- [ ] Review with team/community
- [ ] Plan test strategy
- [ ] Create backup branch

#### Implementation

- [ ] Make code changes
- [ ] Add inline comments explaining fix
- [ ] Update relevant docstrings
- [ ] Add debug assertions if helpful
- [ ] Keep changes minimal and focused

#### Testing

- [ ] Run minimal test case
- [ ] Run full bootstrap script
- [ ] Run existing test suite (665 tests)
- [ ] Test edge cases (negative numbers, floats, large values)
- [ ] Test multiple list accesses
- [ ] Test nested data structures

#### Documentation

- [ ] Update COMPILER_SELF_HOSTING.md
- [ ] Remove "Known Limitations" section
- [ ] Add "Fix Details" section
- [ ] Update CHANGELOG.md
- [ ] Update ROADMAP.md status

---

## Quick Reference Commands

### Build and Test

```bash
# Full bootstrap test
bash scripts/bootstrap_test.sh

# Quick Stage 1 rebuild (after fixing reference compiler)
cd build/bootstrap
rm -f codegen.ll codegen.bc codegen.s codegen.o eigensc
eigenscript-compile ../../src/eigenscript/compiler/selfhost/codegen.eigs -o codegen.ll -O0 --lib
llvm-as codegen.ll -o codegen.bc
llc codegen.bc -o codegen.s -O2
gcc -c codegen.s -o codegen.o
gcc *.o -o eigensc -lm

# Test Stage 1
cat > test.eigs << 'EOF'
x is 42
print of x
EOF
./eigensc test.eigs > test.ll
grep "fadd double" test.ll
```

### Analysis

```bash
# View LLVM IR function
function_name="codegen_gen_literal"
grep -A 100 "define.*$function_name" build/bootstrap/codegen.ll | less

# Find all list accesses
grep -rn "eigen_list_get" build/bootstrap/*.ll

# Check global variable linkage
grep "@__eigs_global" build/bootstrap/*.ll | grep "ast_num_value"

# Disassemble bitcode
llvm-dis build/bootstrap/codegen.bc -o codegen_dis.ll
diff build/bootstrap/codegen.ll codegen_dis.ll
```

### Debugging

```bash
# Compile with debug symbols
cd build/bootstrap
gcc -g -c *.s eigenvalue.c
gcc -g *.o -o eigensc_debug -lm

# Run under GDB
gdb ./eigensc_debug
(gdb) break eigen_list_get
(gdb) run test.eigs
(gdb) print *list
(gdb) print index
(gdb) continue

# Memory check
valgrind --leak-check=full ./eigensc test.eigs
```

### Comparison

```bash
# Compare Stage 1 and reference compiler output
eigenscript-compile test.eigs -o test_ref.ll -O0
./eigensc test.eigs > test_stage1.ll
diff test_ref.ll test_stage1.ll
```

---

## Test Cases

### Minimal Reproduction

**File:** `test_cases/minimal.eigs`
```eigenscript
x is 42
print of x
```

**Expected:** Prints 42  
**Actual:** Prints 0

---

### Multiple Values

**File:** `test_cases/multiple.eigs`
```eigenscript
a is 10
b is 20
c is 30
sum is a + b + c
print of sum
```

**Expected:** Prints 60  
**Actual:** Prints 0

---

### List Access

**File:** `test_cases/list_access.eigs`
```eigenscript
nums is [42, 99, 123]
x is nums[0]
y is nums[1]
z is nums[2]
sum is x + y + z
print of sum
```

**Expected:** Prints 264  
**Actual:** Prints 0

---

### Negative and Float

**File:** `test_cases/types.eigs`
```eigenscript
neg is -42
pos is 42
zero is 0
flt is 3.14159
print of neg
print of pos
print of zero
print of flt
```

**Expected:** -42, 42, 0, 3.14159  
**Actual:** 0, 0, 0, 0

---

### Function with Numeric Return

**File:** `test_cases/function.eigs`
```eigenscript
define get_answer as:
    return 42

x is get_answer of 0
print of x
```

**Expected:** Prints 42  
**Actual:** Prints 0

---

## Progress Tracking

### Investigation Status

| Phase | Started | Completed | Status | Notes |
|-------|---------|-----------|--------|-------|
| 1. Reproduce | YYYY-MM-DD | YYYY-MM-DD | ⏳ | |
| 2. IR Analysis | YYYY-MM-DD | YYYY-MM-DD | ⏳ | |
| 3. Trace Compiler | YYYY-MM-DD | YYYY-MM-DD | ⏳ | |
| 4. Test Hypotheses | YYYY-MM-DD | YYYY-MM-DD | ⏳ | |
| 5. Implement Fix | YYYY-MM-DD | YYYY-MM-DD | ⏳ | |
| 6. Validate | YYYY-MM-DD | YYYY-MM-DD | ⏳ | |

### Hypothesis Results

| # | Hypothesis | Tested | Result | Confidence |
|---|------------|--------|--------|------------|
| 1 | EigenValue wrapping | [ ] | - | - |
| 2 | Type mismatch | [ ] | - | - |
| 3 | Global not shared | [ ] | - | - |
| 4 | Comparison corrupts | [ ] | - | - |
| 5 | Parser stores wrong | [ ] | - | - |

**Legend:**
- ✅ Confirmed root cause
- ❌ Ruled out
- ⚠️ Partially explains
- ⏳ In progress
- ⬜ Not tested

---

## Notes and Findings

### Date: YYYY-MM-DD

**What I tried:**
- [Description]

**What I found:**
- [Findings]

**Next steps:**
- [Action items]

---

### Date: YYYY-MM-DD

**What I tried:**
- [Description]

**What I found:**
- [Findings]

**Next steps:**
- [Action items]

---

## Emergency Rollback

If something breaks during investigation:

```bash
# 1. Stash changes
git stash

# 2. Rebuild from known good state
cd build/bootstrap
rm -rf *
cd ../..
bash scripts/bootstrap_test.sh

# 3. Verify Stage 1 works (with bug, but works)
cd build/bootstrap
cat > test.eigs << 'EOF'
x is 1
print of x
EOF
./eigensc test.eigs > test.ll
llvm-as test.ll -o test.bc  # Should succeed

# 4. Restore changes carefully
git stash pop
```

---

## Success Metrics

### Definition of Success

The investigation is successful when:

1. **Root cause identified**
   - [ ] Exact code section causing bug is known
   - [ ] Mechanism is understood and documented
   - [ ] Reproducible in minimal test case

2. **Fix validated**
   - [ ] Stage 1 compiles programs with correct numeric values
   - [ ] All existing tests pass (665/665)
   - [ ] No regressions introduced

3. **Bootstrap achieved**
   - [ ] Stage 1 compiles itself (Stage 2 created)
   - [ ] Stage 1 and Stage 2 produce identical output
   - [ ] Full self-hosting milestone reached

---

## Resources

- **Main plan:** `docs/BOOTSTRAP_FIX_PLAN.md`
- **Self-hosting guide:** `docs/COMPILER_SELF_HOSTING.md`
- **Bootstrap script:** `scripts/bootstrap_test.sh`
- **Reference compiler:** `src/eigenscript/compiler/codegen/llvm_backend.py`
- **Self-hosted codegen:** `src/eigenscript/compiler/selfhost/codegen.eigs`

---

**Last Updated:** 2025-12-03  
**Document Version:** 1.0  
**Status:** Active
