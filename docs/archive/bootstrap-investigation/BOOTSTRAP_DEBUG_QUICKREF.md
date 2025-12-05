# Bootstrap Debug Quick Reference

**One-page reference for debugging the numeric literal bug**

---

## Reproduce the Bug

```bash
cd build/bootstrap
./eigensc test.eigs > out.ll
grep "fadd double" out.ll
# ❌ Shows: fadd double 0.0, 0.0
# ✅ Want:  fadd double 0.0, 42.0
```

---

## Build Stage 1

```bash
# Full rebuild
bash scripts/bootstrap_test.sh

# Quick rebuild (after changing reference compiler)
cd build/bootstrap
rm codegen.ll codegen.bc codegen.s codegen.o eigensc
eigenscript-compile ../../src/eigenscript/compiler/selfhost/codegen.eigs -o codegen.ll -O0 --lib
llvm-as codegen.ll && llc codegen.bc -O2 && gcc -c codegen.s
gcc *.o -o eigensc -lm
```

---

## Analyze LLVM IR

```bash
cd build/bootstrap

# Extract function
grep -A 200 "define.*codegen_gen_literal" codegen.ll > gen_literal.ll

# Find list access
grep -n "eigen_list_get" codegen.ll

# Check global variables
grep "@__eigs_global_ast_num_value" *.ll

# Verify linking
nm parser.o | grep ast_num_value  # Should show: D (defined)
nm codegen.o | grep ast_num_value # Should show: U (undefined reference)
```

---

## Add Debug Logging

**In `llvm_backend.py`:**

```python
# In _compile_index
print(f"[DEBUG] List access: {node.target}")
if isinstance(node.target, Identifier):
    print(f"  Name: {node.target.name}")
    print(f"  Observed: {node.target.name in self.observed_variables}")
```

```bash
# Recompile with logging
eigenscript-compile codegen.eigs -o codegen.ll -O0 --lib 2>&1 | tee log.txt
grep "DEBUG" log.txt
```

---

## Test Hypotheses

### H1: Observed variable issue
```python
self.observed_variables.discard('ast_num_value')
```

### H2: Check function signature
```bash
grep "declare.*eigen_list_get" *.ll
```

### H3: Symbol visibility
```bash
nm -C *.o | grep ast_num_value
```

### H4: Create value copy
```eigenscript
num_val_copy is num_val + 0
```

### H5: Debug parser output
```eigenscript
ast_num_value[arr_idx] is y
print of y  # Should show actual value
```

---

## Compare Working vs Broken

```bash
# Create tests
cat > working.eigs << 'EOF'
x is 42
y is x + 8
EOF

cat > broken.eigs << 'EOF'
nums is [42]
y is nums[0] + 8
EOF

# Compare IR
eigenscript-compile working.eigs -o working.ll -O0
eigenscript-compile broken.eigs -o broken.ll -O0
diff working.ll broken.ll | less
```

---

## Runtime Debugging

```bash
# Compile with debug symbols
cd build/bootstrap
gcc -g *.s eigenvalue.c
gcc -g *.o -o eigensc_debug -lm

# Run under GDB
gdb ./eigensc_debug
(gdb) break eigen_list_get
(gdb) run test.eigs
(gdb) print list
(gdb) print list->elements[0].value
(gdb) continue
```

---

## Test Cases

```bash
# Test 1: Simple
cat > t1.eigs <<< 'x is 42\nprint of x'
./eigensc t1.eigs > t1.ll

# Test 2: Multiple values
cat > t2.eigs <<< 'a is 10\nb is 20\nsum is a + b\nprint of sum'
./eigensc t2.eigs > t2.ll

# Test 3: List
cat > t3.eigs <<< 'nums is [42, 99]\nx is nums[0]\nprint of x'
./eigensc t3.eigs > t3.ll

# Test 4: Function
cat > t4.eigs <<< 'define f as:\n    return 42\nx is f of 0\nprint of x'
./eigensc t4.eigs > t4.ll

# Verify all
grep "fadd double" t*.ll
```

---

## Validation Checklist

After fix:
- [ ] `x is 42` generates `fadd double 0.0, 42.0`
- [ ] Negative numbers work: `x is -42`
- [ ] Floats work: `x is 3.14159`
- [ ] Lists work: `nums is [1,2,3]; x is nums[1]`
- [ ] All 665 tests pass: `pytest tests/`
- [ ] Bootstrap succeeds: `bash scripts/bootstrap_test.sh`

---

## Emergency Rollback

```bash
git stash
cd build/bootstrap && rm -rf * && cd ../..
bash scripts/bootstrap_test.sh
git stash pop
```

---

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `src/eigenscript/compiler/codegen/llvm_backend.py` | 3126 | Reference compiler (THE BUG IS HERE) |
| `src/eigenscript/compiler/selfhost/codegen.eigs` | 2372 | Self-hosted codegen (victim of bug) |
| `src/eigenscript/compiler/selfhost/parser.eigs` | 1612 | AST creation |
| `src/eigenscript/compiler/runtime/eigenvalue.c` | 1700 | Runtime library |
| `scripts/bootstrap_test.sh` | 242 | Full bootstrap test |

---

## Root Cause Location

**Data flow:**
```
lexer.eigs: lex_last_num_val = 42.0        ✅ Works
main.eigs: append to parser_token_num_vals ✅ Works  
parser.eigs: ast_num_value[idx] = 42.0     ✅ Works
codegen.eigs: val is ast_num_value[idx]    ❌ Reads 0.0!
```

**The bug:** Reference compiler generates incorrect code for `ast_num_value[idx]` in codegen.eigs

**Function:** `_compile_index` in llvm_backend.py (around line 3103)

---

## Success Signature

```llvm
; BEFORE (buggy)
%1 = fadd double 0.0, 0.0

; AFTER (fixed)
%1 = fadd double 0.0, 42.0
```

---

**Full docs:** [BOOTSTRAP_FIX_PLAN.md](./BOOTSTRAP_FIX_PLAN.md)  
**Checklist:** [BOOTSTRAP_INVESTIGATION_CHECKLIST.md](./BOOTSTRAP_INVESTIGATION_CHECKLIST.md)  
**Roadmap:** [BOOTSTRAP_ROADMAP.md](./BOOTSTRAP_ROADMAP.md)
