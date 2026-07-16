# EigenScript Standard Library

The standard library lives in `lib/`. Libraries are pure EigenScript — no C
extensions required. This file documents **every module and its public
functions**. Its module tables are the gate: `tools/stdlib_index_check.sh`
(suite section [98]) fails if a `lib/*.eigs` module has no heading here.

> **Builtins vs. library.** File I/O, subprocess, tensor math, JSON
> encode/decode, regex, channels/tasks, and the six interrogatives are
> **built into the binary** — see **[BUILTINS.md](BUILTINS.md)**. This file
> covers the pure-EigenScript `lib/` layer you `import`/`load_file`. If you
> can't find something here, it is almost certainly a builtin: check
> BUILTINS.md.

## Finding Things — "I need to..." → module

Check this table **before hand-rolling.** The library is broad; the failure
mode is re-inventing what already ships (see "Before you hand-roll" below).

| I need to... | Use | Where |
|---|---|---|
| average / median / stddev / quantiles / correlation | `stats.mean`, `stats.median`, `stats.std_dev`, `stats.quantile`, `stats.correlation`, `stats.describe` | `lib/stats.eigs` |
| tables, CSV, group-by, join, select/where | `data.df_from_csv`, `df_where`, `df_group_by`, `df_join`, `df_select` | `lib/data.eigs` |
| probability distributions, combinatorics, Bayes | `probability.normal_pdf`, `binomial_pmf`, `combinations`, `bayes` | `lib/probability.eigs` |
| matrices / vectors / solve Ax=b / eigenvalues | `linalg.mat_mul`, `mat_inverse`, `solve_linear`, `eigenvalues_2x2` | `lib/linalg.eigs` |
| element-wise / GPU-style tensor math (matmul, softmax) | `matmul`, `softmax`, `add`, `mean` (**builtins**) | BUILTINS.md → Tensor Math |
| derivatives / integrals / root-finding / ODEs | `calculus.derivative`, `integrate_simpson`, `newton_raphson`, `rk4_method` | `lib/calculus.eigs` |
| minimize a function (gradient descent, annealing, GA) | `optimize.gradient_descent`, `simulated_annealing`, `genetic_optimize` | `lib/optimize.eigs` |
| iterative linear solvers / power iteration | `numerics.jacobi_solve`, `gauss_seidel_solve`, `power_iteration` | `lib/numerics.eigs` |
| sort / dedup / sort-by-key / argsort | `sort.sort_asc`, `unique`, `sort_by`, `sorted_indices` | `lib/sort.eigs` |
| set operations (union, intersect, membership) | `set.set_from`, `union`, `intersect`, `set_has` | `lib/set.eigs` |
| map / filter / reduce / zip / group_by / frequencies | `list.map`, `filter`, `reduce`, `group_by`, `frequencies` | `lib/list.eigs` |
| function composition / pipelines / retry | `functional.chain`, `compose`, `complement`, `wait_until` | `lib/functional.eigs` |
| key/value structure (assoc list) | `map.map_new`, `map_get`, `map_set` | `lib/map.eigs` |
| queue / stack / priority queue | `queue.enqueue`, `push`, `pq_push` | `lib/queue.eigs` |
| finite state machine | `state.sm_new`, `sm_add_transition`, `sm_send` | `lib/state.eigs` |
| parse a number / hex / codepoint | `num`, `hex`, `ord`, `chr`, `utf8_encode` (**builtins** / `lib/utf8.eigs`) | BUILTINS.md, `lib/utf8.eigs` |
| pad / format numbers / aligned tables / progress bars | `format.fmt_num`, `fmt_padded`, `fmt_table`, `fmt_bar`, `hexdump` | `lib/format.eigs` |
| join / repeat / capitalize / replace-all strings | `string.join`, `repeat`, `capitalize`, `replace_all` | `lib/string.eigs` |
| build a big string efficiently | `text_builder_new`, `text_builder_append` (**builtins**) | `lib/text_builder.eigs` |
| Unicode codepoints over byte strings | `utf8.utf8_len`, `utf8_at`, `utf8_encode` | `lib/utf8.eigs` |
| checksums (CRC-32, Adler-32) | `checksum.crc32`, `adler32`, `sum8` | `lib/checksum.eigs` |
| packed BCD (RTC / DAA) | `bcd.from_bcd`, `to_bcd` | `lib/bcd.eigs` |
| dates / durations / civil-calendar math | `datetime.now`, `elapsed`, `days_from_civil` | `lib/datetime.eigs` |
| read/write files, CSV, lines | `io.read_lines`, `read_csv`, `write_csv`, `slurp` | `lib/io.eigs` |
| load .env / INI config | `config.load_env_file`, `load_ini`, `config_get` | `lib/config.eigs` |
| parse CLI args / flags / options | `args.parse_args`, `get_flag`, `get_opt` | `lib/args.eigs` |
| structured logging with levels | `log.log_info`, `log_warn`, `log_level` | `lib/log.eigs` |
| validate input (email, number, range) | `validate.is_email`, `is_number`, `in_range` | `lib/validate.eigs` |
| render a `{{template}}` string | `template.render`, `render_file`, `fill` | `lib/template.eigs` |
| manipulate JSON (get path, merge, pretty) | `json.json_get_path`, `json_merge`, `json_pretty` | `lib/json.eigs` |
| an embedded document store / DB | `store.open`, `put`, `find`, `upsert` | `lib/store.eigs` |
| a lock across cooperative tasks | `sync.lock_new`, `with_lock` | `lib/sync.eigs` |
| parallel threads (future, worker pool, parallel_map) | `concurrent.future`, `parallel_map`, `worker_pool` | `lib/concurrent.eigs` |
| supervise & restart wedged/crashed workers | `supervise.supervisor_new`, `supervise`, `supervise_run` | `lib/supervise.eigs` |
| read observer state programmatically | `observer.entropy_of`, `is_converged`, `snapshot` | `lib/observer.eigs` |
| observe a dynamic collection by index | `observer_slots.feed`, `verdict` | `lib/observer_slots.eigs` |
| assert convergence/stability contracts | `contract.expect_converging`, `invariant_stable`, `require` | `lib/contract.eigs` |
| runtime invariant descent/preservation | `invariant.make_invariant`, `run_descent` | `lib/invariant.eigs` |
| write tests with pass/fail tally | `test.assert_eq`, `test_summary`; `harness.start`/`check`/`finish` | `lib/test.eigs`, `lib/harness.eigs` |
| neural-net helpers (init, loss, accuracy) | `tensor.xavier_init`, `linear`, `mse_loss`, `cross_entropy_loss` | `lib/tensor.eigs` |
| fixed-size integer vectors (buffer-backed) | `int_vector.int_vector_new`, `int_vector_from_list` | `lib/int_vector.eigs` |
| a GUI (windows, widgets, charts) | `ui.panel`, `ui.button`, `ui.app_loop` + `ui_w_*` families | `lib/ui*.eigs` |
| synthesize / play audio | `audio.play_note`, `note_freq`, `play_chord` | `lib/audio.eigs` |
| HTTP client / server helpers | `http.http_get`, `route_get`, `start_server` | `lib/http.eigs` |
| physics / chemistry / biology / engineering / earth-science formulae | STEM shelf | `lib/physics.eigs` etc. |
| 2D/3D geometry (triangles, polygons, hull) | `geometry.triangle_area`, `convex_hull`, `point_in_polygon` | `lib/geometry.eigs` |
| run/record a lab experiment with observer feedback | `lab.new_experiment`, `record`, `find_outliers` | `lib/lab.eigs` |
| interpret EigenScript from EigenScript | `eigen.eigen_run`, `eigen_tokenize` | `lib/eigen.eigs` |
| the package manager runtime | `pkg.*` (via `eigenscript --pkg`) | `lib/pkg.eigs` |

### Before you hand-roll

These have each been re-invented in a consumer project (or nearly so).
They already ship — reach for them first:

| You were about to write... | It already exists as |
|---|---|
| `_pr_median` / your own mean | `stats.median`, `stats.mean` (`lib/stats.eigs`) |
| `hex4` / `pad2` (fixed-width hex) | `hex of [n, nibbles]` (**builtin** — zero-padded, never truncates) |
| a byte-to-int / char-code helper | `ord` (read), `chr` / `str_from_bytes` (write) — **builtins** |
| `_log10` / a log-base helper | *not yet a builtin* — `log2`/`log10` are tracked in **#545**; `lib/chemistry.eigs` has a private `_log10`. Until then use `log of x` (natural) and divide: `(log of x) / (log of 10)` |
| a clamp / lerp | `math.clamp of [v, lo, hi]`, `math.lerp of [a, b, t]` (`lib/math.eigs`) |
| a CSV reader/writer | `io.read_csv` / `write_csv`, or `data.df_from_csv` for typed columns |
| a "wait until ready" poll loop | `functional.wait_until of [pred, tries, sleep_fn]` |
| a group-by / frequency count | `list.group_by`, `list.frequencies` |
| an aligned text table | `format.fmt_table of [headers, rows]` |
| a CRC / checksum | `checksum.crc32`, `checksum.adler32` |

## Loading Libraries

```eigenscript
load_file of "lib/math.eigs"
load_file of "lib/list.eigs"
```

Path resolution order:
1. Relative to the **current working directory**
2. Relative to the **script file's directory**
3. Relative to the **script file's parent directory**
4. Relative to the **EigenScript executable's parent directory**
5. Relative to the installed stdlib beside the executable
6. Relative to `~/.local/lib/eigenscript`

This means `load_file of "lib/math.eigs"` works whether you run the
script from the project root, from an external project while using a source
tree binary, or from an installed binary.

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
| `sign` | `sign of value` | Returns -1, 0, or 1 |
| `max_val` | `max_val of list` | Maximum element |
| `min_val` | `min_val of list` | Minimum element |
| `clamp` | `clamp of [value, lo, hi]` | Restrict to range |
| `lerp` | `lerp of [a, b, t]` | Linear interpolation |
| `dot` | `dot of [list_a, list_b]` | Dot product |
| `gcd` | `gcd of [a, b]` | Greatest common divisor |
| `lcm` | `lcm of [a, b]` | Least common multiple |
| `argmax` | `argmax of list` | Index of the largest element (first on ties, -1 if empty) |
| `argmin` | `argmin of list` | Index of the smallest element (first on ties, -1 if empty) |

### lib/list.eigs — Functional List Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `map` | `map of [list, fn]` | Apply fn to each element |
| `filter` | `filter of [list, fn]` | Keep elements where fn is truthy |
| `reduce` | `reduce of [list, fn, init]` | Fold left with initial value |
| `reverse` | `reverse of list` | Reverse a list |
| `zip` | `zip of [list_a, list_b]` | Pair elements from two lists |
| `flatten` | `flatten of list` | Flatten one level of nesting |
| `take` | `take of [list, n]` | First n elements (clamps to length) |
| `drop` | `drop of [list, n]` | All but the first n elements |
| `any` | `any of [list, fn]` | 1 if fn is truthy for some element, else 0 (empty: 0) |
| `all` | `all of [list, fn]` | 1 if fn is truthy for every element, else 0 (empty: 1) |
| `find_index` | `find_index of [list, fn]` | Index of first element where fn is truthy, or -1 |
| `partition` | `partition of [list, fn]` | Split into `[passing, failing]` in one pass |
| `group_by` | `group_by of [list, key_fn]` | Bucket elements into a dict by stringified key |
| `deep_flatten` | `deep_flatten of list` | Fully flatten nested lists (recursive) |
| `count_of` | `count_of of [list, val]` | Count occurrences of a value (`==` equality) |
| `frequencies` | `frequencies of list` | Distribution of values as a dict (stringified keys) |

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
| `pad_right` | `pad_right of [string, width, char]` | Right-pad to width |
| `capitalize` | `capitalize of string` | Uppercase the first character, leave the rest |
| `replace_all` | `replace_all of [string, find, replacement]` | Replace every occurrence of `find` |

### lib/text_builder.eigs — Buffered Text Assembly

`text_builder_*` functions are root-backed builtins exposed through this
load-compatible stdlib module. Builders use a native growable text buffer while
keeping the original stdlib API.

| Function | Signature | Description |
|----------|-----------|-------------|
| `text_builder_new` | `text_builder_new of null` | Create a native mutable text builder |
| `text_builder_append` | `text_builder_append of [builder, value]` | Append one value as text |
| `text_builder_append_line` | `text_builder_append_line of [builder, value]` | Append one value and a newline |
| `text_builder_extend` | `text_builder_extend of [builder, values]` | Append each item in a list |
| `text_builder_part_count` | `text_builder_part_count of builder` | Count appended parts |
| `text_builder_to_string` | `text_builder_to_string of builder` | Render buffered text |
| `text_builder_clear` | `text_builder_clear of builder` | Empty a builder for reuse |

### lib/int_vector.eigs - Fixed-Size Integer Vectors

`int_vector` functions return EigenScript buffers, so vectors support direct
indexing (`vec[i]`), indexed assignment (`vec[i] is value`), `len`, and
iteration.

| Function | Signature | Description |
|----------|-----------|-------------|
| `int_vector_new` | `int_vector_new of count` | Create a zero-filled integer vector |
| `int_vector_filled` | `int_vector_filled of [count, value]` | Create an integer vector filled with one value |
| `int_vector_fill` | `int_vector_fill of [vec, value]` | Overwrite every slot with one value |
| `int_vector_from_list` | `int_vector_from_list of list` | Convert a numeric list to an integer vector |
| `int_vector_to_list` | `int_vector_to_list of vec` | Convert an integer vector to a list |
| `int_vector_clone` | `int_vector_clone of vec` | Copy a vector into a new buffer |
| `int_vector_copy` | `int_vector_copy of [src, src_off, dst, dst_off, count]` | Copy a range between vectors |
| `int_vector_len` | `int_vector_len of vec` | Return vector length |
| `int_vector_get` | `int_vector_get of [vec, index]` | Explicit indexed read |
| `int_vector_set` | `int_vector_set of [vec, index, value]` | Explicit indexed write |

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

### lib/bcd.eigs — Packed BCD Codec

`from_bcd of 0x26` → 26, `to_bcd of 59` → 0x59 — any width, each hex
nibble a decimal digit. Invalid nibbles, negatives, and fractions
raise (a torn RTC register read must fail loudly, not decode to a
plausible number). Consumers: CMOS RTC registers, the Game Boy's DAA.

### lib/harness.eigs — Count-and-Continue Test Scaffolding

`harness.start of "MARKER"` / `harness.check of [tag, got, want]` /
`harness.check_true` / `harness.finish of []` — every check prints and
COUNTS (one failure never hides the rest), finish prints
`MARKER_ALL_PASS` on success or throws with the tally. The twin-gate
pattern extracted from six hand-rolled EigenOS harnesses.

### lib/observer_slots.eigs — Observe a Dynamic Collection

`observer_slots.feed of [i, v]` / `is_stable of i` / `is_diverging of
i` / `verdict of i` (the full regime string) — eight NAMED scalar slots
behind index dispatch, because observer
trajectories key to named bindings and `stable of xs[i]` can never
accumulate one (#262). Feed forces fresh values; slot 9 throws
(silently-unobserved is the failure mode this prevents). Feed bounded
signatures, not raw counters (the #294 flat-entropy band).

### lib/datetime.eigs — Dates, Times, Durations

Two halves. The **clock/timer** functions shell out to system `date` and are
host-profile only:

| Function | Signature | Description |
|----------|-----------|-------------|
| `now` | `now of null` | Current date and time string |
| `today` | `today of null` | Current date string |
| `timestamp` | `timestamp of null` | Unix epoch seconds |
| `iso_date` | `iso_date of null` | ISO 8601 timestamp |
| `elapsed` | `elapsed of [start, end]` | Human-readable duration |
| `elapsed_ms` | `elapsed_ms of [start, end]` | Duration in milliseconds |
| `sleep_ms` | `sleep_ms of ms` | Pause execution |
| `year` / `month` / `day` | `year of null` (etc.) | Current field |
| `weekday` | `weekday of null` | Day-of-week name |
| `timer_start` | `timer_start of null` | Capture start timestamp |
| `timer_elapsed` | `timer_elapsed of start` | Seconds since start |
| `format_date` | `format_date of fmt` | strftime format string |

The **civil-math** functions are pure and run on every profile:
`days_from_civil of [y, m, d]` / `civil_from_days of days` (day 0 =
1970-01-01, proleptic Gregorian), `weekday_from_days of days`
(0=Sunday), `epoch_from_civil of [y, m, d, hh, mm, ss]` /
`civil_from_epoch of secs`. A bare-metal RTC driver turns CMOS
registers into epoch seconds with these and no host clock.

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

### lib/checksum.eigs — Byte Integrity

`crc32 of data`, `adler32 of data`, `sum8 of data` — over a string or a
buffer (bytes 0..255); results are unsigned 32-bit numbers. CRC-32 is
the reflected 0xEDB88320 polynomial (zlib/PNG/ethernet), Adler-32 is
zlib's. Written once so storage layers, cartridge headers, and network
frames stop hand-rolling integrity math.

```eigenscript
load_file of "lib/checksum.eigs"
print of (crc32 of "123456789")      # 3421780262
print of (adler32 of "Wikipedia")    # 300286872
```

`format.eigs` also ships `hexdump of data` (string or buffer → classic
offset/hex/ascii rows), and `functional.eigs` ships
`wait_until of [pred, tries, sleep_fn]` — the bounded-poll shape every
IRQ drain and readiness check re-derives.

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
| `apply_when` | `apply_when of [pred, fn, value]` | Apply fn if pred is truthy |
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

### The UI Toolkit — lib/ui*.eigs

A widget toolkit over the gfx extension, split across focused modules:
`lib/ui.eigs` (core + the `_ui` shared-state dict — the reference
pattern for cross-file module state), `lib/ui_layout.eigs`,
`lib/ui_draw.eigs`, `lib/ui_theme.eigs`, `lib/ui_focus.eigs`,
`lib/ui_anim.eigs`, `lib/ui_dnd.eigs`, `lib/ui_registry.eigs`, and the
widget families `lib/ui_w_basic.eigs`, `lib/ui_w_button.eigs`,
`lib/ui_w_container.eigs`, `lib/ui_w_data.eigs`,
`lib/ui_w_dialog.eigs`, `lib/ui_w_input.eigs`, `lib/ui_w_menu.eigs`,
`lib/ui_w_slider.eigs`, `lib/ui_w_special.eigs`, `lib/ui_w_viz.eigs`.
Start from `lib/ui.eigs`'s header; the modules document their own
widget signatures.

**Core (`lib/ui.eigs`):** `panel`, `add_child`, `find_by_id`,
`stack_vertical`, `stack_horizontal`, `show_toast`, `register_hotkey`,
`push_modal`/`pop_modal`, `show_menu`, `show_dialog`, `claim_drag`/
`release_drag`, `dispatch`, `handle_key`, `request_quit`, `app_loop`.
Theme (`lib/ui_theme.eigs`):
`theme`, `set_theme`, `theme_dark`/`theme_light`/`theme_high_contrast`.
Animation (`lib/ui_anim.eigs`): `tween`, `cancel_tweens`. Text metrics
(`lib/ui_draw.eigs`): `text_width`, `text_height`.

**Widget constructors, by family** (each returns a plain dict; see the
module header for the full argument list):

| Family (`lib/…`) | Widgets |
|---|---|
| `ui_w_basic` | `label`, `separator`, `section`, `color_dot`, `badge`, `progress_bar` |
| `ui_w_button` | `button`, `toggle_button`, `checkbox`, `toggle` |
| `ui_w_container` | `panel`, `hbox`, `vbox`, `toolbar`, `statusbar`, `scroll_panel` |
| `ui_w_input` | `text_input`, `editable_label`, `spinbox`, `combobox` |
| `ui_w_slider` | `slider`, `vslider`, `knob`, `scrollbar` |
| `ui_w_menu` | `dropdown`, `menu`, `radio_group`, `tabs` |
| `ui_w_data` | `table`, `tree`, `item_list`, `grid` |
| `ui_w_viz` | `chart`, `bar_chart`, `gauge`, `meter`, `canvas`, `waveform_view`, `code_view` |
| `ui_w_dialog` | `dialog`, `color_picker`, `property_editor` |
| `ui_w_special` | `splitter`, `piano_keyboard` |

Notes on widget state, where the toolkit could otherwise shadow yours:

- **`label` measures itself.** Its `w`/`h` come from its text and scale,
  at construction and again on every `_layout` pass — so a caption whose
  text changes each frame (a BPM or time display) keeps a box matching
  what is drawn. A label draws no chrome, so its box is exactly its text;
  space between labels in an `hbox`/`toolbar` comes from the container's
  `gap`.
- **`grid.owns_cells`** (default 1) decides who owns the pattern. Leave it
  1 and the widget flips `cells[r][c]` itself, then calls `on_cell`. Set
  it 0 and mouse/keyboard report `(row, col)` without touching `cells` —
  for an app whose model is the source of truth (undo history, pattern
  switching, randomize), so both sides don't keep copies that drift.
  `row_label_w` (60) and `row_label_scale` (1) size the row-label gutter,
  which is drawn to the *left* of the grid's `x`, outside its own bounds.
- **`piano_keyboard` is a horizontal trigger strip**, not a piano-roll
  pitch sidebar: a click fires `on_note(w, note, 1)` and the release
  fires `on_note(w, note, 0)` — including when the pointer leaves the key
  or the widget first. For a vertical pitch ruler (one key per MIDI
  pitch, scrolled with a note grid), paint it on a `canvas`.
- **Hover/pressed feedback** is a translucent `hover_shade`/`pressed_shade`
  overlay from the theme, not a color swap — so it composes with a
  per-widget `bg` (`button`, via #566) instead of erasing it. `button`,
  `checkbox`, and `toggle` all draw it; a theme-colored `button` still
  swaps `btn_hover`/`btn_pressed` as before.

Custom-widget input seams (`canvas` is the reference consumer;
`examples/ui_canvas_events.eigs` exercises all three): a widget's
`on_mouse(w, ev)` receives mousedown, hover mousemove, and — after the
mousedown handler claims the pointer with `claim_drag of w` — every
drag mousemove plus the terminating mouseup (branch on `ev.type`;
`release_drag of null` abandons a capture early). Setting `on_wheel`
(`fn(w, ev)`, `ev.x`/`ev.y` are scroll deltas) on any widget consumes
wheel input under the cursor before the `scroll_panel` walk sees it.
Drag handling for the built-in draggable types goes through the widget
registry's `on_drag` entry, so a registered custom type can supply its
own.

Keyboard goes through the same door: `dispatch of [root, ev]` routes a
`keydown`/`keyup` event dict to `handle_key of [root, ev]`, the toolkit's
public key handler that `app_loop` itself calls. It applies hotkeys >
escape-pops-modal > open combobox > focused text input > focus
navigation, and returns 1 when the toolkit consumed the key, 0 when it is
free for the app — so a headless test drives keys exactly like mouse
instead of reaching for the private handlers.

`request_quit of null` ends `app_loop` from any callback (a File→Exit
menu item, a button, a hotkey), so the loop's own `gfx_close` teardown
still runs; `app_loop` clears the flag on entry, so a stale request never
quits a later loop.

Mouse and wheel events from `gfx_poll` carry `shift`/`ctrl`/`alt`
(0/1) like key events; headless tests synthesize event dicts, where
absent keys read null.

### lib/invariant.eigs — Runtime Invariant Checks

Declare-and-check invariants inside programs; see the module header
for the assertion forms.

### lib/contract.eigs — Trajectory Contracts

Machine-checked convergence/stability properties — the observer-native
answer to "what replaces static types here." `require`/`ensure` are plain
predicates; the trajectory contracts drive a seed through a one-arg step
function and assert a property of the resulting trajectory.

| Function | Signature | Description |
|----------|-----------|-------------|
| `require` | `require of [cond, msg]` | Precondition; throws unless `cond` is truthy |
| `ensure` | `ensure of [cond, msg]` | Postcondition; throws unless `cond` is truthy |
| `expect_converging` | `expect_converging of [x0, step_fn, max_obs, msg]` | Throws unless the trajectory settles within `max_obs` (value channel) |
| `expect_monotone` | `expect_monotone of [x0, step_fn, max_obs, msg]` | Throws on a sign-flipping (oscillating) value trajectory |
| `invariant_stable` | `invariant_stable of [x0, step_fn, max_obs, msg]` | Throws if the value ever begins moving or oscillating |

Convergence is read on the value channel, not entropy (a monotonically
exploding value reads `converged` on the entropy channel — the #294 blind
spot). Convergence is not correctness: pair with `ensure` on the final
residual. See docs/OBSERVER.md "Contracts" and
`examples/stem/contract_solver.eigs`.

### lib/utf8.eigs — UTF-8 Codepoints over Byte Strings

`str` is a byte string (docs/SPEC.md "Text"); this module gives character
semantics when you need them, decoding UTF-8 over the byte primitives.

| Function | Signature | Description |
|----------|-----------|-------------|
| `utf8_len` | `utf8_len of s` | Number of codepoints |
| `utf8_codepoints` | `utf8_codepoints of s` | List of codepoint numbers |
| `utf8_at` | `utf8_at of [s, i]` | i-th codepoint (0-indexed), or -1 |
| `utf8_char_at` | `utf8_char_at of [s, i]` | i-th character as a (multi-byte) string, or "" |
| `utf8_validate` | `utf8_validate of s` | 1 if structurally valid UTF-8, else 0 |
| `utf8_encode` | `utf8_encode of cp` | Codepoint → UTF-8 byte string ("" if unencodable) |
| `utf8_from_codepoints` | `utf8_from_codepoints of cps` | List of codepoints → UTF-8 string (inverse of `utf8_codepoints`) |

### lib/pkg.eigs — Package Manager Runtime

The `--pkg` machinery's script half (eigs.json, SHA-pinned lockfiles);
used by the package tooling rather than imported directly.

### lib/test_runner.eigs — Suite Runner

Drives multi-file test suites (used with lib/test.eigs); prints
per-file and total tallies.

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
Client helpers only allow `http://` and `https://` URLs; rejected URLs return `[-1, ""]`.

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

{% raw %}
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
{% endraw %}

### lib/eigen.eigs — Meta-Circular Interpreter

| Function | Signature | Description |
|----------|-----------|-------------|
| `eigen_tokenize` | `eigen_tokenize of source` | Tokenize source string into token list |
| `eigen_parse` | `eigen_parse of tokens` | Parse token list into AST |
| `eigen_eval` | `eigen_eval of [ast, env]` | Evaluate AST in environment, return value |
| `eigen_run` | `eigen_run of source` | Evaluate source string end-to-end |

```eigenscript
load_file of "lib/eigen.eigs"
tokens is eigen_tokenize of "x is 2 + 3"
ast is eigen_parse of tokens
result is eigen_run of "x is 2 + 3"
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

### Signature-comment coverage (flagged, not yet fixed)

The signature-comment convention (rule 2) is the source of truth this file's
tables and any future LSP hover would read from. These modules define public
functions with **no `# name of args -> type` comment** (or only a section
banner) above them — signatures in the tables above were reconstructed from
the `define name(params)` line and should be back-filled in the lib files:
`bcd`, `checksum`, `format` (`hexdump`), `datetime` (civil-math half),
`eigen`, `harness`, `observer_slots`, `store`, `queue`, `lab`, `linalg`
(`mat_inverse`), `engineering` (unit converters), `geometry` (vector/solid
helpers), and the `ui`/`ui_w_*`/`ui_theme`/`ui_anim`/`ui_draw` widget modules
(which document widgets in the module header instead). Adding the per-function
signature comment is a good first-issue-sized cleanup per module. These
comments are also the planned source for LSP completion/hover (#590) and a
"you're shadowing a stdlib function you didn't import" lint hint (#591).

## STEM & Numeric Libraries

### lib/stats.eigs

Descriptive statistics over flat lists of numbers. Population and sample variants where they differ.

| Function | Signature | Description |
|---|---|---|
| `sum` | `sum of vals` | sum of all values |
| `count` | `count of vals` | number of values |
| `mean` | `mean of vals` | arithmetic mean |
| `median` | `median of vals` | middle value (sort + pick middle) |
| `mode` | `mode of vals` | most common value |
| `variance` | `variance of vals` | POPULATION variance (divides by N); use `variance_sample` for a sample |
| `variance_sample` | `variance_sample of vals` | sample variance with Bessel's correction (divides by N-1). |
| `std_dev` | `std_dev of vals` | population standard deviation (sqrt of population variance) |
| `std_dev_sample` | `std_dev_sample of vals` | sample standard deviation (sqrt of sample variance) |
| `range_of` | `range_of of vals` | max - min |
| `quantile` | `quantile of [vals, q]` | q-th quantile (0 to 1), linear interpolation |
| `percentile` | `percentile of [vals, p]` | p-th percentile (0 to 100) |
| `iqr` | `iqr of vals` | interquartile range (Q3 - Q1) |
| `histogram` | `histogram of [vals, bins]` | return list of {lo, hi, count} dicts |
| `normalize` | `normalize of vals` | scale values to 0-1 range |
| `z_scores` | `z_scores of vals` | standardize (subtract mean, divide by std_dev) |
| `covariance` | `covariance of [xs, ys]` | covariance of two lists |
| `correlation` | `correlation of [xs, ys]` | Pearson correlation coefficient |
| `describe` | `describe of vals` | return dict with count, mean, median, std_dev, min, max, q25, q75 |

`stats.mean` and `stats.median` already exist — reach for them instead of
re-deriving a `_pr_mean`/`_pr_median`. This example is executed and checked
byte-for-byte by the suite (`tests/test_doc_examples.py`, section [89]):

```eigenscript
import stats
import data

scores is [88, 92, 79, 95, 73]
print of (stats.mean of scores)
print of (stats.median of scores)

rows is data.df_from_rows of [["name", "score"], [["Ada", 90], ["Bo", 70]]]
print of (data.df_mean of [rows, "score"])
```
```output
85.4
88
80
```

### lib/data.eigs

DataFrame operations on lists of dicts (each dict is a row with the same keys).

| Function | Signature | Description |
|---|---|---|
| `df_from_csv` | `df_from_csv of path` | read CSV file, first row is headers, returns list of dicts |
| `df_from_rows` | `df_from_rows of [headers, rows]` | headers is list of strings, rows is list of lists |
| `df_new` | `df_new of _headers` | empty dataframe (returns empty list) |
| `df_select` | `df_select of [df, columns]` | returns new df with only specified columns |
| `df_where` | `df_where of [df, pred]` | filter rows where pred(row) is truthy |
| `df_head` | `df_head of [df, n]` | first n rows |
| `df_tail` | `df_tail of [df, n]` | last n rows |
| `df_slice` | `df_slice of [df, start, cnt]` | rows from start index, count rows |
| `df_sort_by` | `df_sort_by of [df, column, asc]` | sort by column value. asc=1 ascending, asc=0 descending. |
| `df_map` | `df_map of [df, column, fn]` | apply fn to each value in column, return new df |
| `df_add_column` | `df_add_column of [df, name, fn]` | add computed column where fn(row) returns value |
| `df_rename` | `df_rename of [df, old_name, new_name]` | rename a column |
| `df_drop` | `df_drop of [df, columns]` | remove columns (opposite of select) |
| `df_group_by` | `df_group_by of [df, column, agg_column, agg_fn]` | group rows by column, apply agg_fn to agg_column. |
| `df_count` | `df_count of df` | number of rows |
| `df_sum` | `df_sum of [df, column]` | sum of column values |
| `df_mean` | `df_mean of [df, column]` | mean of column values |
| `df_min` | `df_min of [df, column]` | min value in column |
| `df_max` | `df_max of [df, column]` | max value in column |
| `df_unique` | `df_unique of [df, column]` | unique values in column |
| `df_join` | `df_join of [left, right, on]` | inner join on column name |
| `df_left_join` | `df_left_join of [left, right, on]` | left join, keep all left rows |
| `df_to_csv` | `df_to_csv of [df, path]` | write dataframe to CSV file |
| `df_to_table` | `df_to_table of df` | format as aligned text table (returns string) |
| `df_column` | `df_column of [df, name]` | extract single column as flat list |
| `df_columns` | `df_columns of df` | return list of column names (keys of first row) |
| `df_describe` | `df_describe of [df, column]` | return dict with count, mean, min, max, sum for a numeric column |

### lib/probability.eigs

Combinatorics, distributions (binomial, Poisson, normal, exponential, uniform — pmf/pdf + cdf), Bayesian inference, expected value/variance, chi-squared statistic.

| Function | Signature | Description |
|---|---|---|
| `factorial` | `factorial of n` | n! |
| `combinations` | `combinations of [n, k]` | C(n, k) = n! / (k! * (n-k)!) |
| `permutations` | `permutations of [n, k]` | P(n, k) = n! / (n-k)! |
| `binomial_pmf` | `binomial_pmf of [n, k, p]` | P(X=k) = C(n,k) * p^k * (1-p)^(n-k) |
| `binomial_cdf` | `binomial_cdf of [n, k, p]` | P(X <= k) = sum_{i=0}^{k} binomial_pmf(n, i, p) |
| `poisson_pmf` | `poisson_pmf of [k, lam]` | P(X=k) = lambda^k * e^(-lambda) / k! |
| `poisson_cdf` | `poisson_cdf of [k, lam]` | P(X <= k) = sum_{i=0}^{k} poisson_pmf(i, lambda) |
| `normal_pdf` | `normal_pdf of [x, mu, sigma]` | phi(x) = (1 / (sigma * sqrt(2*pi))) * exp(-(x-mu)^2 / (2*sigma^2)) |
| `normal_cdf_approx` | `normal_cdf_approx of x` | Abramowitz & Stegun approximation for Phi(x) (standard normal CDF) |
| `exponential_pdf` | `exponential_pdf of [x, lam]` | f(x) = lambda * e^(-lambda * x) for x >= 0 |
| `exponential_cdf` | `exponential_cdf of [x, lam]` | F(x) = 1 - e^(-lambda * x) for x >= 0 |
| `uniform_pdf` | `uniform_pdf of [x, a, b]` | 1/(b-a) if a <= x <= b, else 0 |
| `uniform_cdf` | `uniform_cdf of [x, a, b]` | (x-a)/(b-a) clamped to [0,1] |
| `bayes` | `bayes of [prior, likelihood, evidence]` | P(A\|B) = P(B\|A) * P(A) / P(B) |
| `expected_value` | `expected_value of [values, probabilities]` | E[X] = sum xi * pi |
| `variance_discrete` | `variance_discrete of [values, probabilities]` | Var(X) = sum pi * (xi - E[X])^2 |
| `chi_squared_stat` | `chi_squared_stat of [observed, expected]` | chi^2 = sum (O - E)^2 / E |

### lib/linalg.eigs

Pure-EigenScript matrices (lists of lists) and vectors: transpose/multiply/determinant/inverse, dot/cross/norm/project, linear solve, least squares, 2×2 eigen-decomposition. For GPU-style element-wise tensor math see BUILTINS.md.

| Function | Signature | Description |
|---|---|---|
| `mat_new` | `mat_new of [rows, cols, fill]` | create rows x cols matrix filled with fill value |
| `mat_identity` | `mat_identity of n` | n x n identity matrix |
| `mat_shape` | `mat_shape of A` | returns [rows, cols] |
| `mat_row` | `mat_row of [A, i]` | extract row i |
| `mat_col` | `mat_col of [A, j]` | extract column j |
| `mat_trace` | `mat_trace of A` | sum of diagonal elements |
| `mat_transpose` | `mat_transpose of A` | transpose matrix |
| `mat_add` | `mat_add of [A, B]` | element-wise addition |
| `mat_sub` | `mat_sub of [A, B]` | element-wise subtraction |
| `mat_scale` | `mat_scale of [A, scalar]` | multiply all elements by scalar |
| `mat_mul` | `mat_mul of [A, B]` | matrix multiplication (nested loops, not tensor builtin) |
| `mat_det` | `mat_det of A` | determinant via cofactor expansion (2x2, 3x3) or LU for general |
| `mat_inverse` | `mat_inverse of A` | Matrix inverse via Gauss-Jordan elimination |
| `vec_add` | `vec_add of [a, b]` | element-wise addition |
| `vec_sub` | `vec_sub of [a, b]` | element-wise subtraction |
| `vec_scale` | `vec_scale of [a, s]` | scalar multiplication |
| `vec_dot` | `vec_dot of [a, b]` | dot product |
| `vec_cross` | `vec_cross of [a, b]` | 3D cross product |
| `vec_norm` | `vec_norm of a` | Euclidean norm |
| `vec_normalize` | `vec_normalize of a` | unit vector |
| `vec_angle` | `vec_angle of [a, b]` | angle between vectors (radians) |
| `vec_project` | `vec_project of [a, b]` | project a onto b |
| `solve_linear` | `solve_linear of [A, b]` | Solve Ax = b via Gaussian elimination with partial pivoting |
| `least_squares` | `least_squares of [A, b]` | Solve overdetermined Ax ~ b via normal equations |
| `eigenvalues_2x2` | `eigenvalues_2x2 of A` | eigenvalues of 2x2 matrix via characteristic polynomial |
| `eigenvectors_2x2` | `eigenvectors_2x2 of A` | eigenvectors for each eigenvalue of 2x2 matrix |

### lib/calculus.eigs

Numerical differentiation, integration (trapezoidal/Simpson/Monte Carlo), root finding (bisection/Newton/secant), ODEs (Euler, RK4 scalar and system), Taylor series, interpolation.

| Function | Signature | Description |
|---|---|---|
| `derivative` | `derivative of [f, x, h]` | central difference f'(x) ~ (f(x+h) - f(x-h)) / (2h) |
| `second_derivative` | `second_derivative of [f, x, h]` | f''(x) ~ (f(x+h) - 2f(x) + f(x-h)) / h^2 |
| `partial_derivative` | `partial_derivative of [f, vars, index, h]` | partial derivative of f(vars) with respect to vars[index] |
| `gradient` | `gradient of [f, vars, h]` | gradient vector [df/dx1, df/dx2, ...] |
| `integrate_trapezoidal` | `integrate_trapezoidal of [f, a, b, n]` | trapezoidal rule with n intervals |
| `integrate_simpson` | `integrate_simpson of [f, a, b, n]` | Simpson's 1/3 rule (n must be even) |
| `integrate_midpoint` | `integrate_midpoint of [f, a, b, n]` | midpoint rule |
| `integrate_monte_carlo` | `integrate_monte_carlo of [f, a, b, n]` | Monte Carlo integration |
| `bisection` | `bisection of [f, a, b, tol]` | find x where f(x)=0 in [a,b] |
| `newton_raphson` | `newton_raphson of [f, df, x0, tol, max_iter]` | Newton's method x_{n+1} = x_n - f(x_n)/f'(x_n) |
| `secant_method` | `secant_method of [f, x0, x1, tol, max_iter]` | derivative-free root finding |
| `euler_method` | `euler_method of [f, y0, t0, t1, n]` | solve y' = f(t, y) from t0 to t1 with n steps |
| `rk4_method` | `rk4_method of [f, y0, t0, t1, n]` | 4th-order Runge-Kutta for scalar ODE y' = f(t, y) |
| `rk4_system` | `rk4_system of [f, y0, t0, t1, n]` | RK4 for systems y' = f(t, y) where y is a vector |
| `taylor_exp` | `taylor_exp of [x, terms]` | e^x = sum x^n / n! |
| `taylor_sin` | `taylor_sin of [x, terms]` | sin(x) = sum (-1)^n * x^(2n+1) / (2n+1)! |
| `taylor_cos` | `taylor_cos of [x, terms]` | cos(x) = sum (-1)^n * x^(2n) / (2n)! |
| `lagrange_interpolation` | `lagrange_interpolation of [xs, ys, x]` | Lagrange polynomial interpolation at point x |
| `linear_interpolation` | `linear_interpolation of [x0, y0, x1, y1, x]` | linear interpolation between (x0,y0) and (x1,y1) at x |

### lib/optimize.eigs

**Observer-aware.** Gradient descent with observer-adaptive learning rate, multi-variable optimization, simulated annealing, golden-section search, genetic algorithm. All use `report of loss` for automatic convergence detection.

| Function | Signature | Description |
|---|---|---|
| `gradient_descent` | `gradient_descent of [f, x0, lr, max_iter]` | 1D observer-adaptive gradient descent |
| `gradient_descent_multi` | `gradient_descent_multi of [f, x0, lr, max_iter]` | multi-variable observer-adaptive gradient descent |
| `simulated_annealing` | `simulated_annealing of [f, x0, T0, cooling, max_iter]` | observer-convergence-aware SA |
| `golden_section` | `golden_section of [f, a, b, max_iter]` | 1D minimization with observer convergence |
| `genetic_optimize` | `genetic_optimize of [fitness_fn, bounds, pop_size, generations]` | GA with observer convergence detection |

### lib/numerics.eigs

**Observer-aware.** Jacobi/Gauss-Seidel iterative solvers, power iteration for the dominant eigenvalue, fixed-point iteration. Observer detects residual convergence.

| Function | Signature | Description |
|---|---|---|
| `jacobi_solve` | `jacobi_solve of [A, b, max_iter]` | solve Ax = b via Jacobi iteration |
| `gauss_seidel_solve` | `gauss_seidel_solve of [A, b, max_iter]` | solve Ax = b via Gauss-Seidel (in-place updates) |
| `power_iteration` | `power_iteration of [A, max_iter]` | find dominant eigenvalue and eigenvector |
| `fixed_point` | `fixed_point of [g, x0, max_iter]` | find x where g(x) = x |

### lib/simulation.eigs

**Observer-aware.** Generic equilibrium detector, stability analyzer, spring-mass-damper, Lotka-Volterra predator-prey, 1D heat equation.

| Function | Signature | Description |
|---|---|---|
| `simulate_to_equilibrium` | `simulate_to_equilibrium of [step_fn, state, max_steps]` | run step_fn until observer detects equilibrium |
| `analyze_stability` | `analyze_stability of time_series` | classify behavior of a time series via observer |
| `spring_mass_damper` | `spring_mass_damper of [m, k, c, x0, v0, dt, duration]` | simulate damped harmonic oscillator |
| `lotka_volterra` | `lotka_volterra of [prey0, pred0, alpha, beta, gamma, delta, dt, duration]` | predator-prey simulation |
| `heat_equation_1d` | `heat_equation_1d of [initial, dx, dt, alpha, steps]` | 1D heat diffusion with observer equilibrium detection |

### lib/experiment.eigs

**Observer-aware.** Measurement stability tracking, entropy-spike outlier detection, convergence-rate estimation, behavioural regime detection.

| Function | Signature | Description |
|---|---|---|
| `track_measurements` | `track_measurements of values` | annotate each measurement with observer state |
| `is_measurement_stable` | `is_measurement_stable of [values, min_stable_count]` | check if recent measurements are stable |
| `detect_entropy_spikes` | `detect_entropy_spikes of [values, threshold]` | find anomalies via entropy derivative |
| `convergence_rate` | `convergence_rate of values` | estimate how fast a sequence converges |
| `detect_regimes` | `detect_regimes of values` | identify behavioral phase transitions |

### lib/geometry.eigs

Computational geometry: 2D/3D points and vectors, line/segment intersection, triangles, polygons (shoelace, point-in-polygon, convexity), convex hull (Andrew's monotone chain), circles, 2D transforms, Hausdorff distance, solid geometry.

| Function | Signature | Description |
|---|---|---|
| `point2` | `point2 of [x, y]` | 2D point [x, y] |
| `distance2d` | `distance2d of [a, b]` | Euclidean distance between two 2D points |
| `midpoint2d` | `midpoint2d of [a, b]` | Midpoint of two 2D points |
| `lerp2d` | `lerp2d of [a, b, t]` | Linear interpolation between two 2D points |
| `vec2_add` | `vec2_add of [a, b]` | Add two 2D vectors |
| `vec2_sub` | `vec2_sub of [a, b]` | Subtract two 2D vectors |
| `vec2_scale` | `vec2_scale of [a, s]` | Scale a 2D vector by a scalar |
| `vec2_dot` | `vec2_dot of [a, b]` | 2D dot product |
| `vec2_cross` | `vec2_cross of [a, b]` | 2D cross product (scalar): ax*by - ay*bx |
| `vec2_norm` | `vec2_norm of a` | Magnitude of a 2D vector |
| `vec2_normalize` | `vec2_normalize of a` | Unit vector of a 2D vector |
| `vec2_rotate` | `vec2_rotate of [v, angle]` | Rotate a 2D vector by angle (radians) |
| `vec2_perpendicular` | `vec2_perpendicular of v` | Perpendicular of a 2D vector |
| `vec2_angle` | `vec2_angle of [a, b]` | Angle between two 2D vectors (radians) |
| `point3` | `point3 of [x, y, z]` | 3D point [x, y, z] |
| `distance3d` | `distance3d of [a, b]` | Euclidean distance between two 3D points |
| `midpoint3d` | `midpoint3d of [a, b]` | Midpoint of two 3D points |
| `lerp3d` | `lerp3d of [a, b, t]` | Linear interpolation between two 3D points |
| `line_from_points` | `line_from_points of [p1, p2]` | Returns [a, b, c] coefficients for ax + by + c = 0 |
| `point_to_line_distance` | `point_to_line_distance of [point, line_p1, line_p2]` | Perpendicular distance from point to infinite line defined by two points |
| `point_to_segment_distance` | `point_to_segment_distance of [point, seg_p1, seg_p2]` | Distance from point to finite line segment |
| `closest_point_on_segment` | `closest_point_on_segment of [point, seg_p1, seg_p2]` | Project point onto segment, clamp to endpoints |
| `segment_length` | `segment_length of [p1, p2]` | Length of line segment |
| `orientation` | `orientation of [p, q, r]` | Returns: 1 = counter-clockwise, -1 = clockwise, 0 = collinear |
| `collinear` | `collinear of [p, q, r]` | Are three points collinear? |
| `on_segment` | `on_segment of [p, q, r]` | Is q on segment pr? (assuming collinear) |
| `segments_intersect` | `segments_intersect of [a1, a2, b1, b2]` | Do two line segments intersect? |
| `line_intersection` | `line_intersection of [a1, a2, b1, b2]` | Returns point or null if parallel |
| `triangle_area` | `triangle_area of [a, b, c]` | Area via cross product: 0.5 * \|AB x AC\| |
| `triangle_centroid` | `triangle_centroid of [a, b, c]` | Average of vertices |
| `triangle_circumcenter` | `triangle_circumcenter of [a, b, c]` | Center of circumscribed circle |
| `triangle_incenter` | `triangle_incenter of [a, b, c]` | Center of inscribed circle |
| `point_in_triangle` | `point_in_triangle of [p, a, b, c]` | Is point inside triangle? (barycentric coordinates method) |
| `barycentric_coords` | `barycentric_coords of [p, a, b, c]` | Returns [u, v, w] barycentric coordinates |
| `triangle_circumradius` | `triangle_circumradius of [a, b, c]` | Radius of circumscribed circle |
| `triangle_inradius` | `triangle_inradius of [a, b, c]` | Radius of inscribed circle |
| `polygon_area` | `polygon_area of vertices` | Positive = counter-clockwise, negative = clockwise |
| `polygon_centroid` | `polygon_centroid of vertices` | Centroid of simple polygon |
| `polygon_perimeter` | `polygon_perimeter of vertices` | Sum of edge lengths |
| `point_in_polygon` | `point_in_polygon of [point, vertices]` | Ray casting algorithm -- odd number of crossings = inside |
| `polygon_is_convex` | `polygon_is_convex of vertices` | Check if all cross products have same sign |
| `polygon_is_clockwise` | `polygon_is_clockwise of vertices` | Check winding order via signed area |
| `convex_hull` | `convex_hull of points` | Convex hull (Andrew's monotone chain) |
| `circle_from_three_points` | `circle_from_three_points of [a, b, c]` | Returns [center_x, center_y, radius] |
| `circles_intersect` | `circles_intersect of [c1x, c1y, c1r, c2x, c2y, c2r]` | Do two circles intersect? |
| `circle_intersection_points` | `circle_intersection_points of [c1x, c1y, c1r, c2x, c2y, c2r]` | Returns list of intersection points (0, 1, or 2 points) |
| `point_in_circle` | `point_in_circle of [px, py, cx, cy, r]` | Is point inside circle? |
| `circle_area` | `circle_area of r` | Area of a circle of radius r |
| `circle_circumference` | `circle_circumference of r` | Circumference of a circle of radius r |
| `translate2d` | `translate2d of [points, dx, dy]` | Translate all points by (dx, dy) |
| `rotate2d_around` | `rotate2d_around of [points, center, angle]` | Rotate all points around center by angle (radians) |
| `scale2d_from` | `scale2d_from of [points, center, sx, sy]` | Scale all points from center |
| `reflect2d` | `reflect2d of [points, line_p1, line_p2]` | Reflect points across a line defined by two points |
| `nearest_point` | `nearest_point of [query, points]` | Find nearest point in a set to the query point, returns index |
| `k_nearest` | `k_nearest of [query, points, k]` | Find k nearest points, returns list of indices |
| `bounding_box` | `bounding_box of points` | Returns [min_x, min_y, max_x, max_y] |
| `hausdorff_distance` | `hausdorff_distance of [set_a, set_b]` | Hausdorff distance: max of min distances between two point sets |
| `polygon_to_polygon_distance` | `polygon_to_polygon_distance of [poly_a, poly_b]` | Minimum distance between two polygons (vertex-to-edge) |
| `sphere_volume` | `sphere_volume of r` | Volume of a sphere |
| `sphere_surface_area` | `sphere_surface_area of r` | Surface area of a sphere |
| `cylinder_volume` | `cylinder_volume of [r, h]` | Volume of a cylinder |
| `cone_volume` | `cone_volume of [r, h]` | Volume of a cone |
| `ellipse_area` | `ellipse_area of [a, b]` | Area of an ellipse (semi-axes a, b) |

### lib/physics.eigs

14 CODATA constants + 80 functions: kinematics, projectile motion, forces, energy, waves, thermodynamics, EM, optics, special relativity, nuclear/quantum, fluid mechanics. SI units; angles in radians. Constants are bare globals (`SPEED_OF_LIGHT`, `PLANCK`, `GRAVITATIONAL`, ...).

| Function | Signature | Description |
|---|---|---|
| `displacement` | `displacement of [v0, a, t]` | displacement of [v0, a, t] -> metres |
| `final_velocity` | `final_velocity of [v0, a, t]` | final_velocity of [v0, a, t] -> m/s |
| `velocity_from_displacement` | `velocity_from_displacement of [v0, a, x]` | velocity_from_displacement of [v0, a, x] -> m/s (returns magnitude) |
| `time_of_flight` | `time_of_flight of [v0, a, x]` | time_of_flight of [v0, a, x] -> seconds |
| `projectile_range` | `projectile_range of [v0, angle]` | projectile_range of [v0, angle] -> metres |
| `projectile_max_height` | `projectile_max_height of [v0, angle]` | projectile_max_height of [v0, angle] -> metres |
| `projectile_time` | `projectile_time of [v0, angle]` | projectile_time of [v0, angle] -> seconds |
| `projectile_position` | `projectile_position of [v0, angle, t]` | projectile_position of [v0, angle, t] -> [x, y] |
| `gravitational_force` | `gravitational_force of [m1, m2, r]` | gravitational_force of [m1, m2, r] -> Newtons |
| `spring_force` | `spring_force of [k, x]` | spring_force of [k, x] -> Newtons |
| `friction_force` | `friction_force of [mu, normal]` | friction_force of [mu, normal] -> Newtons |
| `centripetal_force` | `centripetal_force of [m, v, r]` | centripetal_force of [m, v, r] -> Newtons |
| `centripetal_acceleration` | `centripetal_acceleration of [v, r]` | centripetal_acceleration of [v, r] -> m/s² |
| `momentum` | `momentum of [m, v]` | momentum of [m, v] -> kg·m/s |
| `impulse` | `impulse of [f, dt]` | impulse of [f, dt] -> N·s |
| `kinetic_energy` | `kinetic_energy of [m, v]` | kinetic_energy of [m, v] -> Joules |
| `potential_energy_gravity` | `potential_energy_gravity of [m, h]` | potential_energy_gravity of [m, h] -> Joules |
| `potential_energy_spring` | `potential_energy_spring of [k, x]` | potential_energy_spring of [k, x] -> Joules |
| `work` | `work of [f, d, angle]` | work of [f, d, angle] -> Joules |
| `power_from_work` | `power_from_work of [w, t]` | power_from_work of [w, t] -> Watts |
| `power_from_force` | `power_from_force of [f, v]` | power_from_force of [f, v] -> Watts |
| `wave_speed` | `wave_speed of [freq, wavelength]` | wave_speed of [freq, wavelength] -> m/s |
| `period` | `period of freq` | period of freq -> seconds |
| `frequency` | `frequency of per` | frequency of per -> Hz |
| `angular_frequency` | `angular_frequency of freq` | angular_frequency of freq -> rad/s |
| `wave_number` | `wave_number of wavelength` | wave_number of wavelength -> 1/m |
| `simple_harmonic_position` | `simple_harmonic_position of [amp, omega, t, phi]` | simple_harmonic_position of [amp, omega, t, phi] -> metres |
| `pendulum_period` | `pendulum_period of length` | pendulum_period of length -> seconds |
| `spring_period` | `spring_period of [m, k]` | spring_period of [m, k] -> seconds |
| `doppler_frequency` | `doppler_frequency of [f0, v_source, v_observer]` | doppler_frequency of [f0, v_source, v_observer] -> Hz |
| `standing_wave_harmonics` | `standing_wave_harmonics of [length, n, mode]` | standing_wave_harmonics of [length, n, mode] -> Hz |
| `ideal_gas_pressure` | `ideal_gas_pressure of [n, T, V]` | ideal_gas_pressure of [n, T, V] -> Pascals |
| `ideal_gas_volume` | `ideal_gas_volume of [n, T, P]` | ideal_gas_volume of [n, T, P] -> m³ |
| `ideal_gas_temperature` | `ideal_gas_temperature of [P, V, n]` | ideal_gas_temperature of [P, V, n] -> Kelvin |
| `heat_transfer` | `heat_transfer of [m, c, dT]` | heat_transfer of [m, c, dT] -> Joules |
| `thermal_expansion` | `thermal_expansion of [L0, alpha, dT]` | thermal_expansion of [L0, alpha, dT] -> metres |
| `carnot_efficiency` | `carnot_efficiency of [T_hot, T_cold]` | carnot_efficiency of [T_hot, T_cold] -> dimensionless (0 to 1) |
| `entropy_change` | `entropy_change of [Q, T]` | entropy_change of [Q, T] -> J/K |
| `stefan_boltzmann_power` | `stefan_boltzmann_power of [A, T]` | stefan_boltzmann_power of [A, T] -> Watts |
| `wien_peak_wavelength` | `wien_peak_wavelength of T` | wien_peak_wavelength of T -> metres |
| `coulomb_force` | `coulomb_force of [q1, q2, r]` | coulomb_force of [q1, q2, r] -> Newtons |
| `electric_field` | `electric_field of [q, r]` | electric_field of [q, r] -> N/C (V/m) |
| `electric_potential` | `electric_potential of [q, r]` | electric_potential of [q, r] -> Volts |
| `capacitance_parallel_plate` | `capacitance_parallel_plate of [A, d]` | capacitance_parallel_plate of [A, d] -> Farads |
| `capacitor_energy` | `capacitor_energy of [C, V]` | capacitor_energy of [C, V] -> Joules |
| `ohms_law_current` | `ohms_law_current of [V, R]` | ohms_law_current of [V, R] -> Amperes |
| `ohms_law_voltage` | `ohms_law_voltage of [I, R]` | ohms_law_voltage of [I, R] -> Volts |
| `resistor_power` | `resistor_power of [I, R]` | resistor_power of [I, R] -> Watts |
| `series_resistance` | `series_resistance of resistors` | series_resistance of [r1, r2, ...] -> Ohms |
| `parallel_resistance` | `parallel_resistance of resistors` | parallel_resistance of [r1, r2, ...] -> Ohms |
| `magnetic_force` | `magnetic_force of [q, v, B]` | magnetic_force of [q, v, B] -> Newtons |
| `solenoid_field` | `solenoid_field of [n, I]` | solenoid_field of [n, I] -> Tesla (n = turns per metre) |
| `induced_emf` | `induced_emf of [N, dflux, dt]` | induced_emf of [N, dflux, dt] -> Volts |
| `snells_law_angle` | `snells_law_angle of [n1, n2, theta1]` | snells_law_angle of [n1, n2, theta1] -> radians |
| `critical_angle` | `critical_angle of [n1, n2]` | critical_angle of [n1, n2] -> radians |
| `thin_lens` | `thin_lens of [f, do]` | thin_lens of [f, do] -> metres (image distance) |
| `magnification` | `magnification of [di, do]` | magnification of [di, do] -> dimensionless |
| `mirror_equation` | `mirror_equation of [f, do]` | mirror_equation of [f, do] -> metres |
| `photon_energy` | `photon_energy of freq` | photon_energy of freq -> Joules |
| `photon_wavelength` | `photon_wavelength of energy` | photon_wavelength of energy -> metres |
| `de_broglie_wavelength` | `de_broglie_wavelength of [m, v]` | de_broglie_wavelength of [m, v] -> metres |
| `lorentz_factor` | `lorentz_factor of v` | lorentz_factor of v -> dimensionless |
| `time_dilation` | `time_dilation of [t0, v]` | time_dilation of [t0, v] -> seconds |
| `length_contraction` | `length_contraction of [L0, v]` | length_contraction of [L0, v] -> metres |
| `relativistic_momentum` | `relativistic_momentum of [m, v]` | relativistic_momentum of [m, v] -> kg·m/s |
| `relativistic_energy` | `relativistic_energy of [m, v]` | relativistic_energy of [m, v] -> Joules |
| `rest_energy` | `rest_energy of m` | rest_energy of m -> Joules |
| `mass_energy_equivalence` | `mass_energy_equivalence of E` | mass_energy_equivalence of E -> kg |
| `half_life_remaining` | `half_life_remaining of [N0, t, half_life]` | half_life_remaining of [N0, t, half_life] -> amount remaining |
| `decay_constant` | `decay_constant of half_life` | decay_constant of half_life -> 1/s |
| `binding_energy_per_nucleon` | `binding_energy_per_nucleon of [BE, A]` | binding_energy_per_nucleon of [BE, A] -> MeV/nucleon |
| `bohr_radius_n` | `bohr_radius_n of n` | bohr_radius_n of n -> metres |
| `bohr_energy_n` | `bohr_energy_n of n` | bohr_energy_n of n -> eV |
| `hydrogen_wavelength` | `hydrogen_wavelength of [n1, n2]` | hydrogen_wavelength of [n1, n2] -> metres |
| `pressure_depth` | `pressure_depth of [rho, h]` | pressure_depth of [rho, h] -> Pascals |
| `buoyant_force` | `buoyant_force of [rho_fluid, V]` | buoyant_force of [rho_fluid, V] -> Newtons |
| `bernoulli_velocity` | `bernoulli_velocity of [P1, P2, rho]` | bernoulli_velocity of [P1, P2, rho] -> m/s |
| `flow_rate` | `flow_rate of [A, v]` | flow_rate of [A, v] -> m³/s |
| `reynolds_number` | `reynolds_number of [rho, v, L, mu]` | reynolds_number of [rho, v, L, mu] -> dimensionless |
| `viscous_drag` | `viscous_drag of [mu, r, v]` | viscous_drag of [mu, r, v] -> Newtons |

### lib/chemistry.eigs

Periodic table (36 elements H–Kr), molecular-weight parser, stoichiometry, gas laws, acids/bases (pH, Henderson-Hasselbalch), thermochemistry (Gibbs, Nernst), solution properties.

| Function | Signature | Description |
|---|---|---|
| `element` | `element of symbol` | element of symbol -> dict with name, Z, mass, en, group, period |
| `atomic_mass` | `atomic_mass of symbol` | atomic_mass of symbol -> molar mass in g/mol |
| `molecular_weight` | `molecular_weight of formula` | No parentheses support. |
| `moles_to_grams` | `moles_to_grams of [moles, molar_mass]` | moles_to_grams of [moles, molar_mass] -> grams |
| `grams_to_moles` | `grams_to_moles of [grams, molar_mass]` | grams_to_moles of [grams, molar_mass] -> moles |
| `moles_to_particles` | `moles_to_particles of moles` | moles_to_particles of moles -> number of particles |
| `molarity` | `molarity of [moles, liters]` | molarity of [moles, liters] -> mol/L |
| `dilution` | `dilution of [C1, V1, V2]` | dilution of [C1, V1, V2] -> C2  (C1*V1 = C2*V2) |
| `ideal_gas_pressure` | `ideal_gas_pressure of [n, T, V]` | ideal_gas_pressure of [n, T, V] -> Pascals |
| `boyles_law` | `boyles_law of [P1, V1, V2]` | boyles_law of [P1, V1, V2] -> P2  (P1V1 = P2V2) |
| `charles_law` | `charles_law of [V1, T1, T2]` | charles_law of [V1, T1, T2] -> V2  (V1/T1 = V2/T2) |
| `combined_gas_law` | `combined_gas_law of [P1, V1, T1, T2, V2]` | P1V1/T1 = P2V2/T2  =>  P2 = P1*V1*T2 / (T1*V2) |
| `daltons_partial_pressure` | `daltons_partial_pressure of pressures` | daltons_partial_pressure of pressures_list -> P_total = sum |
| `ph` | `ph of H_conc` | ph of H_concentration -> pH = -log10([H+]) |
| `poh` | `poh of OH_conc` | poh of OH_concentration -> pOH = -log10([OH-]) |
| `ph_to_concentration` | `ph_to_concentration of ph_val` | ph_to_concentration of ph_val -> [H+] = 10^(-pH) |
| `ph_from_poh` | `ph_from_poh of poh_val` | ph_from_poh of poh_val -> pH = 14 - pOH |
| `buffer_ph` | `buffer_ph of [pka, acid_conc, base_conc]` | pH = pKa + log10([A-]/[HA]) |
| `enthalpy_reaction` | `enthalpy_reaction of [products_H, reactants_H]` | ΔH = ΣH_products - ΣH_reactants |
| `gibbs_free_energy` | `gibbs_free_energy of [dH, T, dS]` | gibbs_free_energy of [dH, T, dS] -> ΔG = ΔH - T*ΔS |
| `equilibrium_constant_from_gibbs` | `equilibrium_constant_from_gibbs of [dG, T]` | equilibrium_constant_from_gibbs of [dG, T] -> K = e^(-ΔG/(RT)) |
| `nernst_equation` | `nernst_equation of [E0, n, Q, T]` | nernst_equation of [E0, n, Q, T] -> E = E0 - (RT/(nF))*ln(Q) |
| `mass_percent` | `mass_percent of [solute_mass, solution_mass]` | mass_percent of [solute_mass, solution_mass] -> percent |
| `ppm` | `ppm of [solute_mass, solution_mass]` | ppm of [solute_mass, solution_mass] -> parts per million |
| `osmotic_pressure` | `osmotic_pressure of [M, T, i]` | osmotic_pressure of [M, T, i] -> π = iMRT  (Pascals) |
| `boiling_point_elevation` | `boiling_point_elevation of [Kb, m, i]` | boiling_point_elevation of [Kb, m, i] -> ΔT = i*Kb*m |
| `freezing_point_depression` | `freezing_point_depression of [Kf, m, i]` | freezing_point_depression of [Kf, m, i] -> ΔT = i*Kf*m |

### lib/biology.eigs

Population dynamics, genetics (Hardy-Weinberg, Punnett squares), molecular biology (DNA complement, transcription, full 64-codon translation), enzyme kinetics (Michaelis-Menten), ecology (Shannon/Simpson diversity).

| Function | Signature | Description |
|---|---|---|
| `exponential_growth` | `exponential_growth of [N0, r, t]` | exponential_growth of [N0, r, t] -> N = N0 * e^(rt) |
| `logistic_growth` | `logistic_growth of [N0, K, r, t]` | logistic_growth of [N0, K, r, t] -> N = K / (1 + ((K-N0)/N0)*e^(-rt)) |
| `doubling_time` | `doubling_time of r` | doubling_time of r -> t = ln(2)/r |
| `carrying_capacity_estimate` | `carrying_capacity_estimate of [N, dN, r]` | carrying_capacity_estimate of [N, dN, r] -> K = N / (1 - (1/r)*(dN/N)) |
| `hardy_weinberg` | `hardy_weinberg of p` | Given allele frequency p, returns genotype frequencies |
| `punnett_square` | `punnett_square of [parent1, parent2]` | parent1 and parent2 are 2-character strings like "Aa", "Bb" |
| `complement` | `complement of dna` | complement of dna -> DNA complement (A<->T, G<->C) |
| `transcribe` | `transcribe of dna` | transcribe of dna -> RNA (T -> U) |
| `gc_content` | `gc_content of sequence` | gc_content of sequence -> fraction of G+C in sequence |
| `translate` | `translate of rna` | Starts at first AUG, stops at stop codon |
| `michaelis_menten` | `michaelis_menten of [Vmax, Km, S]` | michaelis_menten of [Vmax, Km, S] -> v = Vmax*[S]/(Km+[S]) |
| `lineweaver_burk` | `lineweaver_burk of [Vmax, Km, S]` | lineweaver_burk of [Vmax, Km, S] -> 1/v = (Km/Vmax)*(1/[S]) + 1/Vmax |
| `turnover_number` | `turnover_number of [Vmax, Et]` | turnover_number of [Vmax, Et] -> kcat = Vmax/[Et] |
| `catalytic_efficiency` | `catalytic_efficiency of [kcat, Km]` | catalytic_efficiency of [kcat, Km] -> kcat/Km |
| `shannon_diversity` | `shannon_diversity of proportions` | shannon_diversity of proportions -> H = -sum(pi * ln(pi)) |
| `simpson_diversity` | `simpson_diversity of proportions` | simpson_diversity of proportions -> D = 1 - sum(pi^2) |
| `species_richness` | `species_richness of species_list` | species_richness of species_list -> count of unique species |

### lib/engineering.eigs

Unit conversions, signal processing (DFT/IDFT, convolution, spectrum), control (PID), structural (beam deflection, Euler buckling), electrical (impedance, resonance, dividers).

| Function | Signature | Description |
|---|---|---|
| `celsius_to_fahrenheit` | `celsius_to_fahrenheit of c` | Convert Celsius to Fahrenheit |
| `fahrenheit_to_celsius` | `fahrenheit_to_celsius of f` | Convert Fahrenheit to Celsius |
| `celsius_to_kelvin` | `celsius_to_kelvin of c` | Convert Celsius to Kelvin |
| `kelvin_to_celsius` | `kelvin_to_celsius of k` | Convert Kelvin to Celsius |
| `meters_to_feet` | `meters_to_feet of m` | Convert metres to feet |
| `feet_to_meters` | `feet_to_meters of ft` | Convert feet to metres |
| `miles_to_km` | `miles_to_km of mi` | Convert miles to kilometres |
| `km_to_miles` | `km_to_miles of km` | Convert kilometres to miles |
| `kg_to_lbs` | `kg_to_lbs of kg` | Convert kilograms to pounds |
| `lbs_to_kg` | `lbs_to_kg of lbs` | Convert pounds to kilograms |
| `atm_to_pascal` | `atm_to_pascal of atm` | Convert atmospheres to pascals |
| `pascal_to_atm` | `pascal_to_atm of pa` | Convert pascals to atmospheres |
| `psi_to_pascal` | `psi_to_pascal of psi` | Convert psi to pascals |
| `joules_to_calories` | `joules_to_calories of j` | Convert joules to calories |
| `calories_to_joules` | `calories_to_joules of cal` | Convert calories to joules |
| `kwh_to_joules` | `kwh_to_joules of kwh` | Convert kilowatt-hours to joules |
| `ev_to_joules` | `ev_to_joules of ev` | Convert electronvolts to joules |
| `dft` | `dft of signal` | Returns list of [real, imaginary] pairs |
| `idft` | `idft of spectrum` | Inverse DFT |
| `magnitude_spectrum` | `magnitude_spectrum of dft_result` | \|X[k]\| = sqrt(re^2 + im^2) |
| `power_spectrum` | `power_spectrum of dft_result` | \|X[k]\|^2 |
| `convolve` | `convolve of [signal, kernel]` | Linear convolution |
| `moving_average` | `moving_average of [signal, window]` | Moving average filter |
| `db_from_amplitude` | `db_from_amplitude of amplitude` | Convert amplitude to decibels |
| `amplitude_from_db` | `amplitude_from_db of db` | Convert decibels to amplitude |
| `db_from_power` | `db_from_power of power` | Convert power to decibels |
| `pid_step` | `pid_step of [kp, ki, kd, error, integral, prev_error, dt]` | Returns [output, new_integral, new_prev_error] |
| `transfer_function_poles` | `transfer_function_poles of [a, b, c]` | Returns [[re1, im1], [re2, im2]] |
| `beam_deflection_center` | `beam_deflection_center of [F, L, E, I]` | delta = FL^3 / (48EI) |
| `beam_max_stress` | `beam_max_stress of [M, c, I]` | Bending stress: sigma = Mc/I |
| `moment_of_inertia_rect` | `moment_of_inertia_rect of [b, h]` | Rectangular cross-section: I = bh^3/12 |
| `moment_of_inertia_circle` | `moment_of_inertia_circle of r` | Circular cross-section: I = pi*r^4/4 |
| `youngs_modulus_stress_strain` | `youngs_modulus_stress_strain of [stress, strain]` | Young's modulus: E = stress/strain |
| `factor_of_safety` | `factor_of_safety of [ultimate, actual]` | Factor of safety: FOS = ultimate/actual |
| `buckling_load` | `buckling_load of [E, I, L]` | Euler buckling load: Pcr = pi^2 * EI / L^2 |
| `rc_time_constant` | `rc_time_constant of [R, C]` | RC time constant: tau = R*C |
| `rl_time_constant` | `rl_time_constant of [L, R]` | RL time constant: tau = L/R |
| `resonant_frequency` | `resonant_frequency of [L, C]` | LC resonant frequency: f = 1/(2*pi*sqrt(LC)) |
| `impedance_capacitor` | `impedance_capacitor of [C, freq]` | Capacitive impedance: Xc = 1/(2*pi*f*C) |
| `impedance_inductor` | `impedance_inductor of [L, freq]` | Inductive impedance: Xl = 2*pi*f*L |
| `voltage_divider` | `voltage_divider of [Vin, R1, R2]` | Voltage divider: Vout = Vin * R2/(R1+R2) |
| `current_divider` | `current_divider of [Itotal, R1, R2]` | Current divider: I1 = Itotal * R2/(R1+R2)  (current through R1) |
| `power_factor` | `power_factor of [real_power, apparent_power]` | Power factor: PF = real_power / apparent_power |
| `three_phase_power` | `three_phase_power of [V, I, pf]` | Three-phase power: P = sqrt(3) * V * I * pf |

### lib/earth_science.eigs

Atmospheric science, seismology (Richter), oceanography, astronomy (Kepler, escape velocity, Schwarzschild radius, stellar luminosity), climate (CO2 forcing).

| Function | Signature | Description |
|---|---|---|
| `barometric_pressure` | `barometric_pressure of h` | P = P0 * (1 - L*h/T0)^(g*M/(R*L)) |
| `temperature_at_altitude` | `temperature_at_altitude of h` | Troposphere lapse rate: T = T0 - L*h (Kelvin) |
| `dew_point` | `dew_point of [T, RH]` | Dew point via Magnus formula approximation (T in Celsius, RH in percent) |
| `wind_chill` | `wind_chill of [T, V]` | Wind chill index (T in Celsius, V in km/h) |
| `air_density` | `air_density of [P, T]` | Air density: rho = P/(R_specific * T), R_specific = 287.058 J/(kg*K) |
| `richter_energy` | `richter_energy of magnitude` | Richter energy: E = 10^(1.5*M + 4.8) joules |
| `richter_amplitude_ratio` | `richter_amplitude_ratio of [M1, M2]` | Amplitude ratio between two magnitudes |
| `p_wave_distance` | `p_wave_distance of [t_p, t_s]` | d ~ (t_s - t_p) * 8 |
| `ocean_depth_from_pressure` | `ocean_depth_from_pressure of P` | Depth from pressure: d = P/(rho*g), rho_seawater ~ 1025 kg/m^3 |
| `wave_speed_deep` | `wave_speed_deep of wavelength` | Deep water wave speed: v = sqrt(g*lambda/(2*pi)) |
| `wave_speed_shallow` | `wave_speed_shallow of depth` | Shallow water wave speed: v = sqrt(g*d) |
| `salinity_density` | `salinity_density of [S, T]` | S in PSU, T in Celsius |
| `orbital_period` | `orbital_period of [a, M]` | Kepler's third law: T = 2*pi*sqrt(a^3/(G*M)) |
| `orbital_velocity` | `orbital_velocity of [M, r]` | Orbital velocity: v = sqrt(G*M/r) |
| `escape_velocity` | `escape_velocity of [M, r]` | Escape velocity: v = sqrt(2*G*M/r) |
| `schwarzschild_radius` | `schwarzschild_radius of M` | Schwarzschild radius: rs = 2*G*M/c^2 |
| `apparent_magnitude` | `apparent_magnitude of [M, d]` | Apparent magnitude: m = M + 5*log10(d/10), d in parsecs |
| `luminosity_distance` | `luminosity_distance of [m, M]` | Luminosity distance: d = 10^((m-M+5)/5) parsecs |
| `stellar_luminosity` | `stellar_luminosity of [R, T]` | Stellar luminosity: L = 4*pi*R^2*sigma*T^4 (Stefan-Boltzmann for stars) |
| `hubble_distance` | `hubble_distance of [v, H0]` | Hubble distance: d = v/H0, H0 typically in km/s/Mpc |
| `redshift_velocity` | `redshift_velocity of z` | Redshift velocity (non-relativistic): v = c*z |
| `parallax_distance` | `parallax_distance of arcseconds` | Parallax distance: d = 1/p parsecs (p in arcseconds) |
| `co2_radiative_forcing` | `co2_radiative_forcing of [C, C0]` | C0 = pre-industrial CO2 (280 ppm typically) |
| `climate_sensitivity` | `climate_sensitivity of [dF, dT]` | Climate sensitivity: lambda = dT/dF (K per W/m^2) |
| `sea_level_thermal` | `sea_level_thermal of [dT, depth, alpha]` | Sea level rise from thermal expansion: dh = alpha * depth * dT |

### lib/lab.eigs

Experiment management composing EigenStore, observer semantics, stats, and the experiment library — record measurements with live observer feedback, detect stability, flag outliers, export to CSV.

| Function | Signature | Description |
|---|---|---|
| `new_experiment` | `new_experiment of name` | Create a new experiment record |
| `set_param` | `set_param of [exp, key, value]` | Set an experiment parameter |
| `set_unit` | `set_unit of [exp, variable, unit]` | Set the unit for a variable |
| `add_note` | `add_note of [exp, text]` | Attach a note to the experiment |
| `record` | `record of [exp, variable, value]` | Record one measurement (with live observer feedback) |
| `record_batch` | `record_batch of [exp, variable, vals]` | Record a list of measurements |
| `record_with_tag` | `record_with_tag of [exp, variable, value, tag]` | Record a measurement with a tag |
| `status` | `status of [exp, variable]` | Current observer status for a variable |
| `is_stable` | `is_stable of [exp, variable]` | 1 if the variable's measurements are stable |
| `wait_for_stable` | `wait_for_stable of [exp, variable, collect_fn, interval, timeout]` | Poll collect_fn until the variable stabilizes or times out |
| `measurements` | `measurements of [exp, variable]` | All measurement records for a variable |
| `values` | `values of [exp, variable]` | Flat list of a variable's values |
| `to_dataframe` | `to_dataframe of [exp, variable]` | Measurements as a data.eigs DataFrame |
| `to_csv` | `to_csv of [exp, variable, path]` | Export a variable's measurements to CSV |
| `summary` | `summary of [exp, variable]` | Descriptive-stats summary for a variable |
| `compare` | `compare of [exp, var1, var2]` | Compare two variables |
| `tagged_groups` | `tagged_groups of [exp, variable]` | Group measurements by tag |
| `close_experiment` | `close_experiment of exp` | Close the experiment and its store handle |
| `save` | `save of exp` | Persist the experiment |
| `load` | `load of name` | Load a saved experiment by name |
| `list_experiments` | `list_experiments of null` | List saved experiment names |
| `delete_experiment` | `delete_experiment of name` | Delete a saved experiment |
| `find_outliers` | `find_outliers of [exp, variable, threshold]` | Flag measurements beyond an entropy threshold |
| `detect_phases` | `detect_phases of [exp, variable]` | Identify behavioural phase transitions |
| `convergence_info` | `convergence_info of [exp, variable]` | Convergence-rate info for a variable |

## Data, Concurrency & Media Libraries

### lib/store.eigs

| Function | Signature | Description |
|---|---|---|
| `open` | `open of path` | Open an EigenStore database file |
| `close` | `close of handle` | Close the store handle |
| `put` | `put of [handle, collection, record]` | Insert a record into a collection |
| `get` | `get of [handle, collection, key]` | Get a record by key |
| `delete` | `delete of [handle, collection, key]` | Delete a record by key |
| `query` | `query of [handle, collection]` | All records in a collection |
| `count` | `count of [handle, collection]` | Record count in a collection |
| `update` | `update of [handle, collection, key, record]` | Replace a record by key |
| `collections` | `collections of handle` | List collection names |
| `drop` | `drop of [handle, collection]` | Drop a collection |
| `find` | `find of [handle, collection, predicate]` | Records in a collection matching a predicate |
| `find_one` | `find_one of [handle, collection, predicate]` | First record matching a predicate (or null) |
| `upsert` | `upsert of [handle, collection, key, record]` | Insert or replace a record by key |
| `bulk_put` | `bulk_put of [handle, collection, records]` | Insert many records at once |
| `to_dataframe` | `to_dataframe of [handle, collection]` | A collection as a data.eigs DataFrame |

### lib/concurrent.eigs

High-level concurrency over OS threads (`spawn`). Futures, join-all, parallel map/each, and a channel-fed worker pool.

| Function | Signature | Description |
|---|---|---|
| `future` | `future of fn` | future(fn) — spawn and return handle |
| `future_get` | `future_get of handle` | future_get(handle) — block and get result |
| `await_all` | `await_all of handles` | await_all(handles) — join all, return results |
| `parallel_map` | `parallel_map of [items, fn]` | parallel_map(items, fn) — process items in parallel threads |
| `parallel_each` | `parallel_each of [items, fn]` | parallel_each(items, fn) — run fn on each item in parallel, no return |
| `worker_pool` | `worker_pool of [n, work_fn, ch]` | worker_pool(n, work_fn, ch) — spawn n workers reading from channel |

### lib/audio.eigs

Audio synthesis over the gfx/audio extension: note frequencies, ADSR notes, chords, and drum sounds. Requires a `gfx`/full build.

| Function | Signature | Description |
|---|---|---|
| `note_freq` | `note_freq of [name, octave]` | Frequency (Hz) of a note name + octave |
| `play_note` | `play_note of [freq, duration, volume]` | Play a single note with an ADSR envelope |
| `play_chord` | `play_chord of [notes, duration, volume]` | Play a chord (list of frequencies) |
| `play_kick` | `play_kick of volume` | Kick drum — sine sweep 150→40 Hz |
| `play_snare` | `play_snare of volume` | Snare — noise plus a short sine body |
| `play_hihat` | `play_hihat of volume` | Hi-hat — short noise burst |
| `audio_wait` | `audio_wait of null` | Block until queued playback drains |


### lib/sync.eigs

Cooperative-task synchronization for the #408 task layer. A lock gives
mutual exclusion **across** `task_yield` points — while one task holds it,
another that tries to acquire cooperatively yields until it is released
(correct because there is no preemption between the acquire check passing
and the claim). `lock_new`, `lock_acquire`, `lock_release`, and
`with_lock of [lock, fn]` (runs `fn of null` under the lock, releasing even
if the body raises). Acquire only from within tasks — it spins with
`task_yield`, so it needs the scheduler active.

### lib/supervise.eigs

Observer-native supervision over the #408 task layer. Beyond BEAM-style
crash-restart, it also detects the silently **wedged** worker — alive, not
crashed, never timing out, but no longer making progress — by sampling each
worker's progress trajectory and seeing it go `stable` (the EigenOS
red-title pattern generalized). Workers publish raw progress with
`heartbeat of [slot, value]`; the supervisor turns it into a bounded
signature (dodging the #294 flat-entropy blind spot). `supervisor_new`,
`supervise of [sup, fn, slot]`, `supervise_step`, and `supervise_run of
[sup, max_ticks]` (drive to settled); wedged and crashed workers are
restarted from their spec under a per-worker restart-intensity cap. Eight
slots. See `examples/supervisor_tree.eigs`.
