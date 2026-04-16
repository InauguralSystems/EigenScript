# EigenScript Standard Library

The standard library lives in `lib/`. Libraries are pure EigenScript — no C
extensions required.

## Loading Libraries

```eigenscript
load_file of "lib/math.eigs"
load_file of "lib/list.eigs"
```

Path resolution order:
1. Relative to the **current working directory**
2. Relative to the **script file's directory**
3. Relative to the **script file's parent directory**

This means `load_file of "lib/math.eigs"` works whether you run the
script from the project root or from any other directory.

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

### lib/observer.eigs — Observer Utilities

| Function | Signature | Description |
|----------|-----------|-------------|
| `entropy_of` | `entropy_of of value` | Current entropy |
| `delta_of` | `delta_of of value` | Current dH (rate of change) |
| `prev_delta_of` | `prev_delta_of of value` | Previous dH |
| `is_converged` | `is_converged of value` | 1 if converged |
| `is_stable` | `is_stable of value` | 1 if stable or converged |
| `is_improving` | `is_improving of value` | 1 if entropy decreasing |
| `is_diverging` | `is_diverging of value` | 1 if entropy increasing |
| `is_oscillating` | `is_oscillating of value` | 1 if dH sign-flipping |
| `wait_until_converged` | `wait_until_converged of [val, fn, max]` | Run fn until convergence |
| `track_regimes` | `track_regimes of [val, fn, max]` | Log regime transitions |
| `threshold_alert` | `threshold_alert of [val, lo, hi]` | "below", "above", or "ok" |
| `snapshot` | `snapshot of value` | [value, status, entropy, dH, prev_dH] |

### lib/tensor.eigs — Tensor Convenience Wrappers

| Function | Signature | Description |
|----------|-----------|-------------|
| `xavier_init` | `xavier_init of [rows, cols]` | Xavier/Glorot initialization |
| `he_init` | `he_init of [rows, cols]` | He/Kaiming initialization |
| `ones` | `ones of [rows, cols]` | Tensor of ones |
| `linear` | `linear of [input, W, bias]` | Affine transform x@W + b |
| `mse_loss` | `mse_loss of [pred, target]` | Mean squared error |
| `cross_entropy_loss` | `cross_entropy_loss of [logits, idx]` | Cross-entropy loss |
| `accuracy` | `accuracy of [logits_list, labels]` | Classification accuracy |
| `normalize` | `normalize of tensor` | Zero-mean, unit-variance |
| `clip` | `clip of [tensor, lo, hi]` | Clamp elements |
| `l2_norm` | `l2_norm of tensor` | Euclidean norm |
| `scale` | `scale of [tensor, scalar]` | Scalar multiplication |

### lib/io.eigs — File and Data Helpers

| Function | Signature | Description |
|----------|-----------|-------------|
| `read_lines` | `read_lines of "path"` | File to list of lines |
| `write_lines` | `write_lines of ["path", lines]` | List of lines to file |
| `read_csv` | `read_csv of "path.csv"` | CSV to list of lists |
| `write_csv` | `write_csv of ["path.csv", rows]` | List of lists to CSV |
| `file_copy` | `file_copy of ["src", "dst"]` | Copy file contents |
| `slurp` | `slurp of "path"` | Read with existence check |

### lib/json.eigs — JSON Manipulation

| Function | Signature | Description |
|----------|-----------|-------------|
| `json_get` | `json_get of [json, "key"]` | Extract top-level value |
| `json_get_path` | `json_get_path of [json, "a.b"]` | Extract nested value |
| `json_has` | `json_has of [json, "key"]` | 1 if key exists |
| `json_from_pairs` | `json_from_pairs of pairs` | [[k,v],...] to JSON |
| `json_merge` | `json_merge of [json_a, json_b]` | Merge two objects |
| `json_pretty` | `json_pretty of json_str` | Indented output |

### lib/test.eigs — Test Runner

| Function | Signature | Description |
|----------|-----------|-------------|
| `assert_eq` | `assert_eq of [actual, expected, desc]` | Exact equality |
| `assert_near` | `assert_near of [actual, expected, tol, desc]` | Approximate equality |
| `assert_true` | `assert_true of [cond, desc]` | Truthy check |
| `assert_false` | `assert_false of [cond, desc]` | Falsy check |
| `test_summary` | `test_summary of null` | Print results, exit on failure |

### lib/format.eigs — Number Formatting and Tables

| Function | Signature | Description |
|----------|-----------|-------------|
| `fmt_num` | `fmt_num of [value, decimals]` | Fixed decimal places |
| `fmt_percent` | `fmt_percent of [value, decimals]` | Format as percentage |
| `fmt_bar` | `fmt_bar of [val, max, width]` | Text progress bar |
| `fmt_padded` | `fmt_padded of [value, width]` | Right-aligned field |
| `fmt_table` | `fmt_table of [headers, rows]` | Aligned text table |

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
