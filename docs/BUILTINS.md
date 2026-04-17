# EigenScript Builtin Reference

168 builtins organized by module (136 core + 32 extensions).
Core builtins are always available; extension builtins (HTTP, DB, model,
gfx) require a full build (`./build.sh full`).

## Core Language

### Type System

| Name | Signature | Description |
|------|-----------|-------------|
| `print` | `print of value` | Output value to stdout with newline |
| `len` | `len of value` | Length of string or list count |
| `str` | `str of value` | Convert to string representation |
| `num` | `num of value` | Convert to number (parse string or coerce) |
| `type` | `type of value` | Return type name: "num", "str", "list", "fn", "builtin", "null" |
| `assert` | `assert of [cond, msg]` | Exit with message if condition is false |
| `coalesce` | `coalesce of [value, default]` | Return value unless empty/null, else default |
| `eval` | `eval of code_string` | Execute EigenScript code, return result |
| `throw` | `throw of message` | Raise catchable error |

### Lists

| Name | Signature | Description |
|------|-----------|-------------|
| `append` | `append of [list, item]` | Append item to list (mutates list) |
| `concat` | `concat of [a, b]` | Concatenate two lists into new list |
| `range` | `range of n` or `range of [start, end]` | Generate integer list [0..n) or [start..end) |
| `set_at` | `set_at of [list, index, value]` | Set element at index (mutates list) |
| `get_at` | `get_at of [list, index]` | Get element at index |
| `copy_into` | `copy_into of [dest, src, offset]` | Copy src elements into dest starting at offset |
| `num_copy` | `num_copy of value` | Create independent copy of numeric value |

### Strings

| Name | Signature | Description |
|------|-----------|-------------|
| `str_lower` | `str_lower of s` | Convert to lowercase |
| `str_upper` | `str_upper of s` | Convert to uppercase |
| `char_at` | `char_at of [s, index]` | Single character at index as string ("" if out of range) |
| `contains` | `contains of [haystack, needle]` | 1 if haystack contains needle, else 0 |
| `starts_with` | `starts_with of [s, prefix]` | 1 if s starts with prefix, else 0 |
| `ends_with` | `ends_with of [s, suffix]` | 1 if s ends with suffix, else 0 |
| `index_of` | `index_of of [haystack, needle]` | First index of needle in haystack, or -1 |
| `substr` | `substr of [s, start, length]` | Extract substring |
| `split` | `split of [s, delim]` | Split string by delimiter into list |
| `trim` | `trim of s` | Strip leading/trailing whitespace |
| `str_replace` | `str_replace of [s, old, new]` | Replace all occurrences of old with new |
| `chr` | `chr of code` | Convert ASCII code to single character |
| `join` | `join of [list, sep]` | Concatenate list elements with separator (C-backed, O(n)) |

### Regex

POSIX ERE (extended regular expressions). No lookahead, named groups, or
lazy quantifiers.

| Name | Signature | Description |
|------|-----------|-------------|
| `regex_match` | `regex_match of [s, pattern]` | `[full_match, group1, ...]` or `[]` |
| `regex_find` | `regex_find of [s, pattern]` | All matches as `[match1, match2, ...]` |
| `regex_replace` | `regex_replace of [s, pattern, replacement]` | Replace all matches |

### Bitwise

Operate on 32-bit two's-complement integers. Shift amounts are masked
to `[0,31]`; non-numeric arguments yield 0.

| Name | Signature | Description |
|------|-----------|-------------|
| `bit_and` | `bit_and of [a, b]` | Bitwise AND |
| `bit_or` | `bit_or of [a, b]` | Bitwise OR |
| `bit_xor` | `bit_xor of [a, b]` | Bitwise XOR |
| `bit_not` | `bit_not of x` | Bitwise NOT |
| `bit_shl` | `bit_shl of [a, b]` | Left shift |
| `bit_shr` | `bit_shr of [a, b]` | Unsigned right shift |

### JSON

| Name | Signature | Description |
|------|-----------|-------------|
| `json_encode` | `json_encode of value` | Serialize value to JSON string |
| `json_decode` | `json_decode of s` | Parse JSON string to value |
| `json_build` | `json_build of [k1, v1, k2, v2, ...]` | Build JSON object from key-value pairs |
| `json_raw` | `json_raw of s` | Wrap raw JSON string (skip encoding) |
| `json_path` | `json_path of [json_str, "dot.path"]` | Extract nested value by dot-notation path |

## Dictionaries

| Name | Signature | Description |
|------|-----------|-------------|
| `keys` | `keys of dict` | List of keys |
| `values` | `values of dict` | List of values |
| `has_key` | `has_key of [dict, "key"]` | 1 or 0 |
| `dict_set` | `dict_set of [dict, "key", value]` | Set key in dict (mutates), return dict |
| `dict_remove` | `dict_remove of [dict, "key"]` | Remove key from dict (mutates), return dict |

## Interrogatives

Six keywords for querying a value's observer state. Zero cost when unused.

| Name | Syntax | Returns |
|------|--------|---------|
| `what` | `what is x` | Current value (scalar), or length (list/string) |
| `who` | `who is x` | Variable name as string |
| `when` | `when is x` | Observation age (number of assignments) |
| `where` | `where is x` | Entropy (information content) |
| `why` | `why is x` | dH (rate of change) |
| `how` | `how is x` | Stability score (0 = unstable, 1 = stable) |

## Observer

| Name | Signature | Description |
|------|-----------|-------------|
| `report` | `report of value` | Classify change trajectory: "improving", "diverging", "stable", "equilibrium", "oscillating", "converged" |
| `observe` | `observe of value` | Return [status, entropy, dH, prev_dH] snapshot |

### Predicates

Boolean keywords that check the most recently observed value:

| Name | True when |
|------|-----------|
| `converged` | Entropy very low and stable |
| `stable` | Entropy changing slowly |
| `improving` | Entropy decreasing |
| `oscillating` | dH sign-flipping |
| `diverging` | Entropy increasing |
| `equilibrium` | dH near zero |

## File I/O

| Name | Signature | Description |
|------|-----------|-------------|
| `load_file` | `load_file of "path.eigs"` | Load and execute EigenScript file |
| `file_exists` | `file_exists of "path"` | 1 if file exists, 0 otherwise |
| `read_text` | `read_text of "path"` | Read file contents as string ("" on failure, 10 MB cap) |
| `write_text` | `write_text of ["path", text]` | Write string to file (1 on success, 0 on failure) |
| `exec_capture` | `exec_capture of ["cmd", "arg1", ...]` | Run subprocess, return [exit_code, stdout_text]. No shell (direct exec). Child stdin is /dev/null. Returns [-1, ""] on failure, [-2, partial] on timeout. 10 MB output cap. Timeout form: `exec_capture of [["cmd", ...], seconds]` |
| `env_get` | `env_get of "VAR_NAME"` | Get environment variable (empty string if unset) |
| `random_hex` | `random_hex of n` | Generate n random hex characters from /dev/urandom |
| `try_parse` | `try_parse of code_string` | 1 if string is valid EigenScript syntax, 0 otherwise |
| `mkdir` | `mkdir of "path"` | Create directory (and parents). 1 on success, 0 on failure |
| `ls` | `ls of "path"` | List directory contents as list of strings |
| `getcwd` | `getcwd of null` | Current working directory as string |
| `chdir` | `chdir of "path"` | Change working directory. 1 on success, 0 on failure |
| `mktemp` | `mktemp of null` | Create temporary file, return its path |
| `rm` | `rm of "path"` | Remove a file. 1 on success, 0 on failure |
| `write` | `write of value` | Write to stdout without newline |
| `flush` | `flush of null` | Flush stdout |

### Streaming Tensor I/O

Single-handle streaming writer for the tensor binary format. Use when
producing tensors too large to materialise in memory.

| Name | Signature | Description |
|------|-----------|-------------|
| `stream_open` | `stream_open of ["path", count]` | Open file, write header for `count` float64 values. 1 on success, 0 on failure |
| `stream_write` | `stream_write of value` | Append one float64 to the open stream. 1 on success, 0 on failure |
| `stream_close` | `stream_close of null` | Close the stream. 1 on success, 0 on failure |

## Path Manipulation

| Name | Signature | Description |
|------|-----------|-------------|
| `path_join` | `path_join of [a, b]` | Join two path segments with `/` |
| `path_dir` | `path_dir of path` | Directory portion ("a/b/c" → "a/b") |
| `path_base` | `path_base of path` | Filename portion ("a/b/c.txt" → "c.txt") |
| `path_ext` | `path_ext of path` | Extension including dot (".eigs"), or "" |

## Random

| Name | Signature | Description |
|------|-----------|-------------|
| `random` | `random of null` | Random float in [0, 1) |
| `random_int` | `random_int of [lo, hi]` | Random integer in [lo, hi] inclusive |
| `seed_random` | `seed_random of n` | Seed the RNG for deterministic sequences |

## Time

| Name | Signature | Description |
|------|-----------|-------------|
| `monotonic_ns` | `monotonic_ns of null` | Nanoseconds from `CLOCK_MONOTONIC` (jump-free) |
| `monotonic_ms` | `monotonic_ms of null` | Milliseconds from `CLOCK_MONOTONIC` |
| `usleep` | `usleep of microseconds` | Pause execution |

## Terminal

Raw-mode keyboard input and ANSI cursor rendering. Terminal is restored
automatically at exit.

| Name | Signature | Description |
|------|-----------|-------------|
| `raw_key` | `raw_key of null` | Non-blocking single keypress. Returns key as string, arrow keys as `"up"`/`"down"`/`"left"`/`"right"`, or `""` if none |
| `screen_clear` | `screen_clear of null` | Clear screen and hide cursor |
| `screen_end` | `screen_end of null` | Show cursor, reset attributes, newline |
| `screen_put` | `screen_put of [row, col, char, color]` | Write single character with optional ANSI color code |
| `screen_render` | `screen_render of [entities, sw, sh, px, py, ww, wh]` | Project a list of `[wx, wy, char, color]` entities onto a `sw×sh` viewport centred on player `(px, py)` in a toroidal `ww×wh` world |

## Command-Line Arguments

| Name | Signature | Description |
|------|-----------|-------------|
| `args` | `args of null` | List of arguments after the script name |

## Scalar Math

| Name | Signature | Description |
|------|-----------|-------------|
| `abs` | `abs of x` | Absolute value |
| `min` | `min of [a, b]` | Smaller of two numbers |
| `max` | `max of [a, b]` | Larger of two numbers |
| `floor` | `floor of x` | Round down to integer |
| `ceil` | `ceil of x` | Round up to integer |
| `round` | `round of x` | Round to nearest integer |
| `sin` | `sin of x` | Sine (radians) |
| `cos` | `cos of x` | Cosine (radians) |
| `tan` | `tan of x` | Tangent (radians) |
| `asin` | `asin of x` | Inverse sine |
| `acos` | `acos of x` | Inverse cosine |
| `atan` | `atan of x` | Inverse tangent |
| `atan2` | `atan2 of [y, x]` | Two-argument inverse tangent |
| `pi` | `pi of null` | The constant &pi; (3.14159265...) |

## Tensor Math

### Arithmetic

| Name | Signature | Description |
|------|-----------|-------------|
| `add` | `add of [a, b]` | Element-wise addition |
| `subtract` | `subtract of [a, b]` | Element-wise subtraction |
| `multiply` | `multiply of [a, b]` | Element-wise multiplication |
| `divide` | `divide of [a, b]` | Element-wise division |
| `pow` | `pow of [base, exp]` | Element-wise exponentiation |
| `negative` | `negative of t` | Element-wise negation |

### Functions

| Name | Signature | Description |
|------|-----------|-------------|
| `sqrt` | `sqrt of t` | Element-wise square root |
| `exp` | `exp of t` | Element-wise e^x |
| `log` | `log of t` | Element-wise natural log |
| `softmax` | `softmax of t` | Row-wise softmax normalization |
| `log_softmax` | `log_softmax of t` | Row-wise log(softmax) |
| `relu` | `relu of t` | Element-wise max(0, x) |
| `leaky_relu` | `leaky_relu of t` | Element-wise max(0.01x, x) |

### Linear Algebra

| Name | Signature | Description |
|------|-----------|-------------|
| `matmul` | `matmul of [a, b]` | Matrix multiplication |
| `gather` | `gather of [matrix, indices, dim]` | Gather rows/columns by index |

### Reductions

| Name | Signature | Description |
|------|-----------|-------------|
| `mean` | `mean of t` | Average of all elements |
| `sum` | `sum of t` | Sum of all elements |

### Construction

| Name | Signature | Description |
|------|-----------|-------------|
| `zeros` | `zeros of [rows, cols]` or `zeros of n` | Create zero tensor |
| `zeros_like` | `zeros_like of t` | Create zero tensor matching shape |
| `random_normal` | `random_normal of [rows, cols, scale]` | Gaussian random tensor |
| `shape` | `shape of t` | Return dimensions as list |

### Persistence

| Name | Signature | Description |
|------|-----------|-------------|
| `tensor_save` | `tensor_save of [tensor, "path"]` | Save tensor to binary file (preserves observer state) |
| `tensor_load` | `tensor_load of "path"` | Load tensor from binary file (restores observer state) |

### Gradients & SGD

| Name | Signature | Description |
|------|-----------|-------------|
| `numerical_grad` | `numerical_grad of [loss_fn, params, eps]` | Finite-difference gradient |
| `numerical_grad_rows` | `numerical_grad_rows of [loss_fn, params, eps, rows]` | Gradient for specific rows |
| `numerical_grad_cols` | `numerical_grad_cols of [loss_fn, params, eps, cols]` | Gradient for specific columns |
| `sgd_update` | `sgd_update of [params, grad, lr]` | In-place SGD: params -= lr * grad |
| `sgd_update_rows` | `sgd_update_rows of [params, grad, lr, rows]` | SGD for specific rows |
| `sgd_update_cols` | `sgd_update_cols of [params, grad, lr, cols]` | SGD for specific columns |

## Memory

| Name | Signature | Description |
|------|-----------|-------------|
| `arena_mark` | `arena_mark of null` | Snapshot arena allocation point |
| `arena_reset` | `arena_reset of null` | Reclaim all allocations since mark |
| `arena_stats` | `arena_stats of null` | Return total bytes allocated |
| `free_val` | `free_val of value` | Free a heap-allocated value tree (no-op while arena is active). Advanced use only |

## Tokenizer Introspection

| Name | Signature | Description |
|------|-----------|-------------|
| `tokenize_ids` | `tokenize_ids of code_string` | Return list of token type IDs |
| `tokenize_with_names` | `tokenize_with_names of code_string` | Return list of `[id, name]` pairs |
| `token_name` | `token_name of id` | Return token type name by ID |

## Corpus Preparation

| Name | Signature | Description |
|------|-----------|-------------|
| `build_corpus` | `build_corpus of [files, top_n, stream_path, vocab_path]` | Three-pass C-backed corpus builder: tokenise `files`, emit top-`n` vocabulary and stream-format token IDs |

## Optional: HTTP Extension

Requires full build. Provides an embedded HTTP server.

| Name | Signature | Description |
|------|-----------|-------------|
| `http_route` | `http_route of [method, path, handler]` | Register route handler |
| `http_route_authed` | `http_route_authed of [method, path, handler]` | Register authenticated route |
| `http_static` | `http_static of [prefix, directory]` | Serve static files |
| `http_early_bind` | `http_early_bind of null` | Pre-bind socket and start health thread |
| `http_serve` | `http_serve of port` | Start blocking HTTP server |
| `http_request_body` | `http_request_body of null` | Get current request body |
| `http_session_id` | `http_session_id of null` | Get current session ID |
| `http_post` | `http_post of [url, headers, body]` | HTTP POST via curl (no shell) |
| `http_request_headers` | `http_request_headers of null` | Get current request headers |

## Optional: Graphics (SDL2) Extension

Requires full build with gfx (`./build.sh gfx`). Dynamically loads
libSDL2 at runtime — no SDL2 headers needed at build time.

| Name | Signature | Description |
|------|-----------|-------------|
| `gfx_open` | `gfx_open of [width, height, title]` | Open window and renderer |
| `gfx_close` | `gfx_close of null` | Destroy window and quit SDL |
| `gfx_clear` | `gfx_clear of [r, g, b]` | Clear backbuffer to color |
| `gfx_rect` | `gfx_rect of [x, y, w, h, r, g, b]` or `[..., a]` | Filled rectangle |
| `gfx_line` | `gfx_line of [x1, y1, x2, y2, r, g, b]` | Line segment |
| `gfx_point` | `gfx_point of [x, y, r, g, b]` | Single pixel |
| `gfx_circle` | `gfx_circle of [cx, cy, radius, r, g, b]` | Filled circle (midpoint) |
| `gfx_text` | `gfx_text of [x, y, text, r, g, b]` or `[..., scale]` | Bitmap-font text |
| `gfx_present` | `gfx_present of null` | Flip backbuffer to screen |
| `gfx_poll` | `gfx_poll of null` | Return next event as dict (`quit`, `keydown`, `keyup`, `mousemove`, `mousedown`, `mouseup`), or null |
| `gfx_ticks` | `gfx_ticks of null` | Milliseconds since `SDL_Init` |
| `gfx_delay` | `gfx_delay of ms` | Sleep for ms (SDL-coordinated) |
| `gfx_title` | `gfx_title of "text"` | Update window title |

## Optional: Database Extension

Requires full build with libpq. PostgreSQL client.

| Name | Signature | Description |
|------|-----------|-------------|
| `db_connect` | `db_connect of null` | Connect via DATABASE_URL env var |
| `db_query_value` | `db_query_value of sql` | Execute query, return first value |
| `db_execute` | `db_execute of sql` or `db_execute of [sql, p1, p2]` | Execute command with optional params |
| `db_query_json` | `db_query_json of sql` | Execute query, return all rows as JSON |

## Optional: Model Extension

Requires full build. Transformer model inference and training.

| Name | Signature | Description |
|------|-----------|-------------|
| `eigen_model_load` | `eigen_model_load of "path.json"` | Load model weights from JSON |
| `eigen_model_loaded` | `eigen_model_loaded of null` | 1 if model loaded, 0 otherwise |
| `eigen_model_info` | `eigen_model_info of null` | JSON with model config and stats |
| `eigen_generate` | `eigen_generate of [prompt, temp, max_tokens]` | Generate text from prompt |
| `native_train_step_builtin` | `native_train_step_builtin of [input, output, lr]` | Single training step |
| `model_save_weights` | `model_save_weights of "path.json"` | Save model weights to JSON |
| `model_load_weights` | `model_load_weights of "path.json"` | Load model weights (alias) |
