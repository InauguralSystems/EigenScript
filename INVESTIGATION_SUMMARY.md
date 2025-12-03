# Bootstrapping Issues Investigation Summary

**Date:** December 3, 2025
**Status:** ✅ **BUG FIXED**
**Investigator:** Claude Code Agent

---

## Executive Summary

The numeric literal bug in EigenScript's self-hosted compiler has been **successfully identified and fixed**. The bug was a simple constant value mismatch between modules.

## The Bug

When Stage 1 compiler (the self-hosted compiler compiled by the Python reference compiler) attempted to compile a program, it generated incorrect LLVM IR where all numeric literals were 0.0 instead of their actual values.

**Example:**
```eigenscript
# Input program
x is 42
y is x + 8
print of y
```

**Before fix (WRONG):**
```llvm
%1 = fadd double 0.0, 0.0  ; Should be 0.0, 42.0
%4 = fadd double 0.0, 0.0  ; Should be 0.0, 8.0
```

**After fix (CORRECT):**
```llvm
%1 = fadd double 0.0, 42.0  ; ✅ Correct!
%4 = fadd double 0.0, 8.0   ; ✅ Correct!
```

## Root Cause

**Token type constant mismatch between modules.**

The `main.eigs` module defined token type constants with **different values** than `lexer.eigs`:

| Constant | `lexer.eigs` | `main.eigs` (WRONG) | `main.eigs` (FIXED) |
|----------|--------------|---------------------|---------------------|
| TT_NUMBER | 31 | 30 ❌ | 31 ✅ |
| TT_STRING | 32 | 31 ❌ | 32 ✅ |

When the lexer returned `TT_NUMBER` (value 31) and main.eigs compared it against its own `TT_NUMBER` (value 30), the comparison failed. This caused the code to take the wrong branch and append `0.0` instead of the actual numeric value.

## The Fix

**File:** `src/eigenscript/compiler/selfhost/main.eigs`

**Change:**
```eigenscript
# Before (WRONG):
TT_NUMBER is 30
TT_STRING is 31

# After (CORRECT):
TT_NUMBER is 31
TT_STRING is 32
```

## Investigation Process

### Phase 1: Reproduction ✅
- Confirmed bug with minimal test case (`x is 42; print of x` → outputs 0)
- Built Stage 1 compiler from source

### Phase 2: Static Analysis ✅
- Analyzed LLVM IR for all modules
- Verified code generation was correct
- Determined bug was in runtime behavior

### Phase 3: Runtime Debugging ✅
- Added debug instrumentation to C runtime
- Traced value flow from lexer to codegen
- Found `eigen_string_to_number("42") -> 42.0` was correct
- But 42.0 was NEVER appended to any list

### Phase 4: Root Cause Analysis ✅
- Examined list appends around number parsing
- Discovered `tok == TT_NUMBER` comparison was failing
- Found token type constants had different values across modules
- Identified the off-by-one error in `main.eigs` constants

### Phase 5: Fix Implementation ✅
- Updated `TT_NUMBER` and `TT_STRING` values in `main.eigs`
- Rebuilt Stage 1 compiler
- Verified fix: `test_simple.eigs` now outputs `50` (42 + 8) correctly

## Verification

```bash
# After fix, Stage 1 generates correct LLVM IR:
$ ./eigensc test_simple.eigs | grep "fadd double"
%1 = fadd double 0.0, 42.0
%4 = fadd double 0.0, 8.0
%5 = fadd double %3, %4

# Compiled program outputs correct result:
$ ./test_simple
50
```

## Lessons Learned

1. **Module constants must be synchronized** - When multiple modules define the same constants, they must have identical values.

2. **Runtime debugging was key** - Static analysis alone couldn't find this bug because the code generation was correct; only runtime tracing revealed the comparison was failing.

3. **Simple bugs can hide in plain sight** - The bug was a simple typo/off-by-one error, but it was difficult to find because:
   - The code structure was correct
   - The comparison logic was correct
   - Only the constant VALUES were wrong

## Additional Fixes (Session 2 - December 3, 2025)

After the initial numeric literal bug fix, several additional issues were discovered and fixed:

### 1. Local Variable Scope Bug ✅
**Problem:** Variables in functions weren't found when `var_count` was reset for new functions.
**Fix:** Changed `add_var` to use direct array assignment at `var_count+1` instead of append, plus pre-populate arrays in `init_codegen`.

### 2. External Variable Type Handling ✅
**Problem:** External variables like `symbol_count` were all declared as `ptr`, but scalars need `double`.
**Fix:** Added `is_external_array` function to detect type by suffix patterns (_types, _names, etc.).

### 3. External Function Declarations ✅
**Problem:** Functions from imported modules weren't declared.
**Fix:** Added `extern_func_names`, `extern_func_counts` tracking and `emit_extern_func_declarations` function.

### 4. Append Special Case Bug ✅
**Problem:** `append of ast_strings of str` was treating nested relation as function call.
**Fix:** Check for append BEFORE evaluating arguments, extract parts directly from AST.

### 5. Module Name Prefixing ✅
**Problem:** Self-hosted compiler didn't add module prefixes (e.g., `set_source` should be `lexer_set_source`).
**Fix:** Added:
- `module_name` variable in codegen state
- `set_module_name` function to set prefix
- `get_module_prefix` in main.eigs to extract from filename
- Prefix function definitions and local function calls

## Current Bootstrap Status

### What Works ✅
- Simple programs compile and execute correctly
- Stage 1 can compile lexer.eigs with correct `lexer_` prefixes
- Stage 1 can compile parser.eigs with correct `parser_` prefixes
- Stage 1 can compile semantic.eigs with correct `semantic_` prefixes
- All three modules assemble with `llvm-as` successfully

### Remaining Issues
- **codegen.eigs**: Produces duplicate function definitions (3 functions: make_reg, make_label, make_external_name). Possibly a bug in handling larger files.
- **main.eigs**: Causes Bus error during compilation. Likely memory issue with complex imports.

## Files Modified

1. `src/eigenscript/compiler/selfhost/main.eigs` - Fixed token constants, added module prefix extraction
2. `src/eigenscript/compiler/selfhost/codegen.eigs` - Fixed multiple codegen issues:
   - Local variable scope handling
   - External variable type detection
   - External function declarations
   - Append builtin handling
   - Module name prefixing for function definitions and calls

## Commits

1. `3e7b3aa` - Fix major codegen bugs enabling valid Stage 2 LLVM IR
2. `6d2570c` - Fix append builtin to not pre-evaluate nested relation
3. `8eb8b40` - Add module name prefixing to self-hosted compiler

## Conclusion

✅ **Significant progress on bootstrap.** The core infrastructure for multi-module compilation is now in place:
- Module name prefixing works for function definitions
- Module name prefixing works for internal function calls
- External function detection and declaration works
- 3 of 4 compiler modules compile successfully to valid LLVM IR

The remaining issues appear to be related to handling larger/more complex source files. Further investigation needed for the duplicate function bug and memory corruption with large files.

---

**Status:** ✅ Significant Progress
**Next steps:** Debug duplicate function generation in codegen.eigs, investigate bus error in main.eigs
