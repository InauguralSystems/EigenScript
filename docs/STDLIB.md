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

### lib/sort.eigs — Sorting Utilities

| Function | Signature | Description |
|----------|-----------|-------------|
| `sort_asc` | `sort_asc of list` | Sort ascending |
| `sort_desc` | `sort_desc of list` | Sort descending |
| `sort_by` | `sort_by of [list, key_fn]` | Sort by key function |
| `sorted_indices` | `sorted_indices of list` | Indices that would sort the list |
| `is_sorted` | `is_sorted of list` | 1 if ascending order |
| `unique` | `unique of list` | Sorted, deduplicated list |

### lib/map.eigs — Key-Value Data Structure

Maps are lists of `[key, value]` pairs. Keys are compared with `==`.

| Function | Signature | Description |
|----------|-----------|-------------|
| `map_new` | `map_new of null` | Create empty map |
| `map_get` | `map_get of [map, key]` | Get value or null |
| `map_get_default` | `map_get_default of [map, key, default]` | Get value or default |
| `map_has` | `map_has of [map, key]` | 1 if key exists |
| `map_set` | `map_set of [map, key, value]` | Set key (returns new map) |
| `map_remove` | `map_remove of [map, key]` | Remove key (returns new map) |
| `map_keys` | `map_keys of map` | List all keys |
| `map_values` | `map_values of map` | List all values |
| `map_size` | `map_size of map` | Number of entries |
| `map_from_lists` | `map_from_lists of [keys, values]` | Build from parallel lists |
| `map_merge` | `map_merge of [map_a, map_b]` | Merge (second wins) |
| `map_entries` | `map_entries of map` | List of [key, value] pairs |

```eigenscript
load_file of "lib/map.eigs"

m is map_new of null
m is map_set of [m, "lang", "EigenScript"]
m is map_set of [m, "version", "0.5"]
print of (map_get of [m, "lang"])       # "EigenScript"
print of (map_keys of m)                # ["lang", "version"]
```

### lib/functional.eigs — Composition and Higher-Order Utilities

| Function | Signature | Description |
|----------|-----------|-------------|
| `identity` | `identity of x` | Return argument unchanged |
| `constantly` | `constantly of x` | Return value (sentinel pattern) |
| `chain` | `chain of [fn_list, value]` | Pipeline: apply left to right |
| `apply_all` | `apply_all of [fn_list, value]` | Apply each fn, collect results |
| `juxt` | `juxt of [fn_list, value]` | Alias for apply_all |
| `complement` | `complement of [pred, value]` | Negate predicate result |
| `when` | `when of [pred, fn, value]` | Apply fn if pred is truthy |
| `unless` | `unless of [pred, fn, value]` | Apply fn if pred is falsy |
| `times` | `times of [count, fn]` | Call fn(i) for i in 0..count-1 |
| `iterate` | `iterate of [fn, value, count]` | Apply fn n times |

```eigenscript
load_file of "lib/functional.eigs"

define double as:
    return n * 2

define square as:
    return n * n

# Pipeline: double then square
result is chain of [[double, square], 3]   # square(double(3)) = 36

# Apply multiple functions to same value
results is apply_all of [[double, square], 5]  # [10, 25]
```

### lib/args.eigs — CLI Argument Parsing

| Function | Signature | Description |
|----------|-----------|-------------|
| `parse_args` | `parse_args of null` | Parse CLI args into map |
| `get_flag` | `get_flag of [parsed, "--flag"]` | 1 if flag present |
| `get_opt` | `get_opt of [parsed, "--key", default]` | Get option or default |
| `get_positional` | `get_positional of parsed` | List of positional args |
| `has_flag` | `has_flag of [parsed, "--flag"]` | Alias for get_flag |
| `require_opt` | `require_opt of [parsed, "--key", usage]` | Get option or exit |

```eigenscript
load_file of "lib/args.eigs"
# eigenscript myscript.eigs --verbose --output=result.txt input.csv
parsed is parse_args of null
if (get_flag of [parsed, "--verbose"]) == 1:
    print of "Verbose mode on"
outfile is get_opt of [parsed, "--output", "out.txt"]
files is get_positional of parsed    # ["input.csv"]
```

### lib/datetime.eigs — Date, Time, and Duration

| Function | Signature | Description |
|----------|-----------|-------------|
| `now` | `now of null` | Current date and time string |
| `today` | `today of null` | Current date string |
| `timestamp` | `timestamp of null` | Unix epoch seconds |
| `iso_date` | `iso_date of null` | ISO 8601 timestamp |
| `elapsed` | `elapsed of [start, end]` | Human-readable duration |
| `elapsed_ms` | `elapsed_ms of [start, end]` | Duration in milliseconds |
| `sleep_ms` | `sleep_ms of ms` | Pause execution |
| `year` | `year of null` | Current year |
| `month` | `month of null` | Current month (1-12) |
| `day` | `day of null` | Current day |
| `weekday` | `weekday of null` | Day of week name |
| `timer_start` | `timer_start of null` | Capture start timestamp |
| `timer_elapsed` | `timer_elapsed of start` | Seconds since start |
| `format_date` | `format_date of fmt` | strftime format string |

### lib/config.eigs — Configuration File Loading

| Function | Signature | Description |
|----------|-----------|-------------|
| `load_env_file` | `load_env_file of ".env"` | Parse KEY=VALUE file |
| `load_ini` | `load_ini of "config.ini"` | Parse INI config |
| `config_get` | `config_get of [cfg, key, default]` | Get with default |
| `config_require` | `config_require of [cfg, key]` | Get or exit |
| `env_or` | `env_or of ["VAR", default]` | Env var with fallback |
| `config_keys` | `config_keys of cfg` | List all keys |
| `config_section` | `config_section of [cfg, "section"]` | Get section keys |

### lib/set.eigs — Set Operations

Sets are sorted lists with no duplicates.

| Function | Signature | Description |
|----------|-----------|-------------|
| `set_from` | `set_from of list` | Create set from list |
| `set_has` | `set_has of [set, value]` | 1 if member |
| `set_add` | `set_add of [set, value]` | Add element |
| `set_remove` | `set_remove of [set, value]` | Remove element |
| `set_size` | `set_size of set` | Element count |
| `union` | `union of [a, b]` | All from both |
| `intersect` | `intersect of [a, b]` | Common elements |
| `difference` | `difference of [a, b]` | In a, not in b |
| `symmetric_diff` | `symmetric_diff of [a, b]` | In one, not both |
| `is_subset` | `is_subset of [a, b]` | 1 if a ⊆ b |
| `is_superset` | `is_superset of [a, b]` | 1 if a ⊇ b |
| `set_equal` | `set_equal of [a, b]` | 1 if same elements |

### lib/log.eigs — Structured Logging

| Function | Signature | Description |
|----------|-----------|-------------|
| `log_level` | `log_level of "debug"` | Set minimum level |
| `log_debug` | `log_debug of msg` | Debug message |
| `log_info` | `log_info of msg` | Info message |
| `log_warn` | `log_warn of msg` | Warning message |
| `log_error` | `log_error of msg` | Error message |
| `log_msg` | `log_msg of ["level", msg]` | Log with named level |

Levels: debug < info < warn < error < silent. Default: info.

### lib/validate.eigs — Input Validation

| Function | Signature | Description |
|----------|-----------|-------------|
| `is_nonempty` | `is_nonempty of value` | Non-empty string/list |
| `is_number` | `is_number of value` | Numeric or parseable |
| `is_integer` | `is_integer of value` | Whole number |
| `in_range` | `in_range of [val, lo, hi]` | Within bounds |
| `is_one_of` | `is_one_of of [val, list]` | Value in allowed list |
| `is_email` | `is_email of string` | Basic email format |
| `is_alpha` | `is_alpha of string` | Letters only |
| `is_alphanumeric` | `is_alphanumeric of string` | Letters and digits |
| `is_url` | `is_url of string` | Basic URL format |
| `validate_all` | `validate_all of checks` | Run multiple checks |

### lib/http.eigs — HTTP Client and Server Helpers

Requires full build for server builtins. Client uses `exec_capture` + `curl`.

| Function | Signature | Description |
|----------|-----------|-------------|
| `http_get` | `http_get of url` | GET request |
| `http_post_json` | `http_post_json of [url, data]` | POST JSON |
| `route_get` | `route_get of [path, handler]` | Register GET route |
| `route_post` | `route_post of [path, handler]` | Register POST route |
| `json_response` | `json_response of data` | Build JSON response |
| `text_response` | `text_response of string` | Build text response |
| `error_response` | `error_response of [code, msg]` | Build error response |
| `parse_query` | `parse_query of string` | Parse query string |
| `start_server` | `start_server of port` | Bind and serve |

### lib/queue.eigs — Queue, Stack, and Priority Queue

All structures are immutable — operations return new structures.

| Function | Signature | Description |
|----------|-----------|-------------|
| `queue_new` | `queue_new of null` | New FIFO queue |
| `enqueue` | `enqueue of [q, item]` | Add to back |
| `dequeue` | `dequeue of q` | [item, rest] from front |
| `peek` | `peek of q` | Front item |
| `stack_new` | `stack_new of null` | New LIFO stack |
| `push` | `push of [s, item]` | Push to top |
| `pop` | `pop of s` | [item, rest] from top |
| `stack_peek` | `stack_peek of s` | Top item |
| `pq_new` | `pq_new of null` | New priority queue |
| `pq_push` | `pq_push of [pq, priority, item]` | Insert with priority |
| `pq_pop` | `pq_pop of pq` | [item, rest] (min first) |
| `pq_peek` | `pq_peek of pq` | Lowest-priority item |

### lib/state.eigs — Finite State Machine

| Function | Signature | Description |
|----------|-----------|-------------|
| `sm_new` | `sm_new of "initial"` | Create state machine |
| `sm_add_transition` | `sm_add_transition of [sm, from, event, to]` | Add rule |
| `sm_send` | `sm_send of [sm, event]` | Trigger transition |
| `sm_try_send` | `sm_try_send of [sm, event]` | Trigger or no-op |
| `sm_can_send` | `sm_can_send of [sm, event]` | 1 if valid |
| `sm_state` | `sm_state of sm` | Current state |
| `sm_history` | `sm_history of sm` | State history |
| `sm_is` | `sm_is of [sm, "state"]` | Check current state |
| `sm_reset` | `sm_reset of sm` | Reset to initial |
| `sm_available_events` | `sm_available_events of sm` | Valid events |
| `sm_transitions_from` | `sm_transitions_from of [sm, state]` | Transitions list |

```eigenscript
load_file of "lib/state.eigs"
sm is sm_new of "idle"
sm is sm_add_transition of [sm, "idle", "start", "running"]
sm is sm_add_transition of [sm, "running", "stop", "idle"]
sm is sm_add_transition of [sm, "running", "error", "failed"]
sm is sm_send of [sm, "start"]
print of (sm_state of sm)              # "running"
print of (sm_can_send of [sm, "stop"]) # 1
```

### lib/template.eigs — String Templating

| Function | Signature | Description |
|----------|-----------|-------------|
| `render` | `render of [template, vars]` | Interpolate `{{key}}` |
| `render_file` | `render_file of [path, vars]` | Load and render |
| `render_lines` | `render_lines of [template, vars]` | Render to line list |
| `render_each` | `render_each of [template, items, key]` | Render per item |
| `render_block` | `render_block of [template, vars, cond]` | Conditional render |
| `fill` | `fill of [template, key, value]` | Single-variable shorthand |

```eigenscript
load_file of "lib/template.eigs"
vars is [["name", "World"], ["version", "0.5"]]
msg is render of ["{{name}} is running v{{version}}", vars]
print of msg   # "World is running v0.5"
```

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
