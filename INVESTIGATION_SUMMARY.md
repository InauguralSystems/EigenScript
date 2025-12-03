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

## Remaining Work

The Stage 1 compiler can now compile simple programs correctly. However, bootstrapping (Stage 1 compiling itself) still has issues:

```
Parse error at line: 181.000000
```

This is a separate issue related to the parser, not the numeric literal bug that was fixed.

## Files Modified

1. `src/eigenscript/compiler/selfhost/main.eigs` - Fixed token type constants

## Conclusion

✅ **The numeric literal bug has been fixed.** Stage 1 compiler now correctly generates numeric literals in LLVM IR output.

The fix was a simple one-line change to synchronize token type constant values between modules. The investigation methodology (static analysis → runtime debugging → root cause identification) was effective in finding this subtle bug.

---

**Status:** ✅ Complete - Bug Fixed
**Fix verified:** Yes
**Next steps:** Investigate parser error for self-hosting bootstrap
