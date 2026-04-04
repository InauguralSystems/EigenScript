# EigenScript Standard Library

The standard library lives in `lib/`. Libraries are pure EigenScript — no C
extensions required.

## Loading Libraries

```eigenscript
load_file of "lib/math.eigs"
load_file of "lib/list.eigs"
```

Paths are relative to the **current working directory**, not the script file.
Run scripts from the EigenScript root directory, or use absolute paths.

## Calling Convention

EigenScript functions take one argument, `n`. Libraries follow two patterns:

**Single argument** — `n` is the value directly:
```eigenscript
abs of -5             # n is -5
reverse of [1, 2, 3]  # n is the list [1, 2, 3]
```

**Multiple arguments** — pass a list, unpack `n[0]`, `n[1]`:
```eigenscript
clamp of [15, 0, 10]         # n[0]=15, n[1]=0, n[2]=10
map of [items, double_fn]    # n[0]=items, n[1]=double_fn
```

The difference: does the function need one thing or several? Check the
signature comment above each function (e.g., `# clamp of [value, lo, hi]`).

## Module Index

### lib/math.eigs — Numeric Utilities

| Function | Signature | Description |
|----------|-----------|-------------|
| `abs` | `abs of value` | Absolute value |
| `max_val` | `max_val of list` | Maximum element |
| `min_val` | `min_val of list` | Minimum element |
| `clamp` | `clamp of [value, lo, hi]` | Restrict to range |
| `lerp` | `lerp of [a, b, t]` | Linear interpolation |
| `dot` | `dot of [list_a, list_b]` | Dot product |

### lib/list.eigs — Functional List Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `map` | `map of [list, fn]` | Apply fn to each element |
| `filter` | `filter of [list, fn]` | Keep elements where fn is truthy |
| `reduce` | `reduce of [list, fn, init]` | Fold left with initial value |
| `reverse` | `reverse of list` | Reverse a list |
| `zip` | `zip of [list_a, list_b]` | Pair elements from two lists |
| `flatten` | `flatten of list` | Flatten one level of nesting |

Higher-order functions take EigenScript functions as arguments:

```eigenscript
load_file of "lib/list.eigs"

define double as:
    return n * 2

define is_even as:
    return (n % 2) == 0

define add_fn as:
    return n[0] + n[1]

doubled is map of [[1,2,3], double]      # [2, 4, 6]
evens is filter of [[1,2,3,4], is_even]  # [2, 4]
total is reduce of [[1,2,3], add_fn, 0]  # 6
```

### lib/string.eigs — String Utilities

| Function | Signature | Description |
|----------|-----------|-------------|
| `join` | `join of [list, separator]` | Join elements with separator |
| `repeat` | `repeat of [string, count]` | Repeat string n times |
| `pad_left` | `pad_left of [string, width, char]` | Left-pad to width |

### lib/sanitize.eigs — Text Validation

| Function | Signature | Description |
|----------|-----------|-------------|
| `sanitize_text` | `sanitize_text of string` | Trim whitespace |
| `is_garble` | `is_garble of string` | 1 if text looks like nonsense |
| `clean_response` | `clean_response of string` | Trim at "User:" marker |
| `check_openai` | `check_openai of null` | 1 if OpenAI API key available |

### lib/auth.eigs — Token Authentication

| Function | Signature | Description |
|----------|-----------|-------------|
| `auth_login` | `auth_login of password` | Verify password, set session token |
| `auth_check` | `auth_check of token` | 1 if token is valid |
| `auth_logout` | `auth_logout of null` | Clear session |
| `auth_get_token` | `auth_get_token of null` | Return current token |
| `require_auth` | `require_auth of null` | Check auth from HTTP headers |

Requires: `env_get`, `random_hex`, `http_request_headers` builtins.

## Writing Library Functions

Follow these conventions:

1. **Header**: Use the standard format with `# ====` borders, module name, and
   complete usage examples.

2. **Signature comment**: Add `# func_name of args -> return_type` above each
   function definition.

3. **Naming**: Use `snake_case`. Prefer clear names over short ones.

4. **Validation**: Check for empty lists where relevant. Return a sensible
   default (0, empty list, empty string) rather than crashing.

5. **No side effects**: Library functions should return values, not print.
   Exception: auth/sanitize modules that manage state.

Example:
```eigenscript
# ---- my_func: description of what it does ----
# my_func of [arg1, arg2] -> return_type
define my_func as:
    a is n[0]
    b is n[1]
    # ... implementation ...
    return result
```
