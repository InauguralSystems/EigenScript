# EigenScript Diagnostics

EigenScript reports errors with source line numbers and consistent formatting.
This document defines the error contract.

## Error Categories

| Category | Format | Exit Code | Behavior |
|----------|--------|-----------|----------|
| Syntax error | `Syntax error line N: ...` | 1 | Tokenizer problem. Accumulates all errors, aborts before execution. |
| Parse error | `Parse error line N: ...` | 1 | Parser problem. Accumulates all errors, aborts before execution. |
| Runtime error | `Error line N: ...` | 0 | Type mismatch, undefined variable, index out of bounds, non-callable. Prints to stderr, returns null, continues execution. |
| Warning | `Warning line N: ...` | 0 | Recoverable issue (division by zero). Prints to stderr, returns fallback value, continues execution. |
| Assertion | `ASSERT FAIL: ...` | 1 | Intentional termination via `assert`. |

Parse errors prevent execution entirely — the program never runs if parsing fails.
Runtime errors and warnings allow execution to continue. This is intentional:
EigenScript is designed for iterative computation where partial results are useful.

## Exit Codes

| Situation | Exit Code |
|-----------|-----------|
| Successful execution | 0 |
| File not found | 1 |
| Parse errors (syntax) | 1 |
| Assertion failure | 1 |
| Runtime errors only | 0 |
| Warnings only | 0 |

## Examples

### Parse error — aborts before execution
```
$ cat bad.eigs
if x > 0
    print of x

$ eigenscript bad.eigs
Parse error line 1: expected ':', got newline
1 parse error(s) — aborting
```

### Runtime error — continues execution
```
$ cat type_err.eigs
x is [1, 2, 3]
y is x - 5
print of "reached"

$ eigenscript type_err.eigs
Error line 2: cannot apply '-' to list and num
reached
```

### Warning — returns fallback value
```
$ cat div_zero.eigs
result is 10 / 0
print of result

$ eigenscript div_zero.eigs
Warning line 1: division by zero
0
```

### Line numbers in nested code
```
$ cat nested.eigs
x is 5
if x == 5:
    y is x[0]

$ eigenscript nested.eigs
Error line 3: cannot index num
```

## Runtime Error Types

| Error | Trigger | Example |
|-------|---------|---------|
| `cannot apply 'OP' to T1 and T2` | Binary operator on incompatible types | `[1,2] - 5` |
| `undefined variable 'NAME'` | Using a name that hasn't been assigned | `print of x` (never defined) |
| `index N out of range (length M)` | List/string index outside bounds | `items[10]` on a 3-element list |
| `'for' requires a list, got T` | For loop over non-list value | `for i in 42:` |
| `cannot call T (not a function)` | Using `of` with a non-function | `5 of 10` |
| `cannot negate T` | Unary minus on non-number | `-"hello"` |
| `cannot index T` | Indexing a non-list/non-string | `42[0]` |
| `division by zero` | Dividing or modulo by zero | `10 / 0` (warning, returns 0) |

## Builtin Errors

Builtin functions report errors without line numbers (the error is in the
builtin's domain, not at a specific source location):

```
Type error: json_decode requires a string, got num
load_file: cannot read 'missing.eigs'
```

## Informational Messages

Diagnostic messages use bracketed prefixes and are not errors:

```
[load_file] Loading lib/math.eigs (1301 bytes)
```
