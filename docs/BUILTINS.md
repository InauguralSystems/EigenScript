# EigenScript Builtin Reference

250+ builtins organized by module (199 core + ~60 extensions).
Core builtins are always available; extension builtins (HTTP, DB, model,
gfx, audio) require a full build or the `gfx` target.

> **Builtins vs. library.** This file is the **compiled-in** surface —
> functions the binary provides directly. The pure-EigenScript `lib/`
> layer (DataFrames, stats, distributions, matrices, sets, sorting,
> the GUI toolkit, the STEM shelf, ...) lives in
> **[STDLIB.md](STDLIB.md)** — start at its "Finding Things" index if you
> know the task but not the function. In particular **`map`, `filter`,
> and `reduce` are NOT builtins** — they are `lib/list.eigs`
> (`import list` → `list.filter of [xs, fn]`, or
> `load_file of "lib/list.eigs"` for bare names), even though `sort_by`
> IS a builtin (#734). Rule of thumb: **file/process/network,
> tensor math, JSON encode-decode, regex, channels/tasks, and the
> interrogatives are builtins (here); everything you `import` is library
> (there).** To resolve a name mechanically, `eigenscript --api [--json]`
> dumps the full surface — every builtin, extension (by group), and lib
> function with its parameter list — in one call.

New since 0.8.1: concurrency (`spawn`, `thread_join`, `channel`, `send`,
`recv`, `try_recv`, `recv_timeout`, `close_channel`, `channel_closed`),
streaming subprocess I/O (`proc_spawn`, `proc_write`, `proc_read_line`,
`proc_read`, `proc_close`, `proc_wait`), spatial queries
(`nearest_in_range`), hashing (`sha256`, `md5`,
`sha256_file`, `md5_file`, `hmac_sha256`), EigenStore (`store_open`,
`store_close`, `store_put`, `store_get`, `store_delete`, `store_query`,
`store_count`, `store_update`, `store_collections`, `store_drop`),
observer tuning (`set_observer_thresholds`, `get_observer_thresholds`),
audio (`audio_open`, `audio_close`, `audio_pause`, `audio_play`,
`audio_play_loop`, `audio_volume`, `audio_stop`, `audio_queue_size`, `audio_clear`, `audio_sine`,
`audio_saw`, `audio_sweep`,
`audio_square`, `audio_noise`, `audio_mix`, `audio_gain`,
`audio_envelope`, `audio_capture_open`, `audio_capture_read`,
`audio_capture_close`, `audio_stream_open`, `audio_stream_push`,
`audio_stream_queued`, `audio_stream_clear`, `audio_stream_close`), and
`free_val` for memory management.

## Core Language

### Type System

| Name | Signature | Description |
|------|-----------|-------------|
| `print` | `print of value` | Output value to stdout with newline |
| `len` | `len of value` | Length of string or list count |
| `str` | `str of value` | Convert to string representation |
| `num` | `num of value` | Convert to number (parse string or coerce) |
| `type` | `type of value` | Return type name: "num", "str", "list", "dict", "buffer", "text_builder", "fn", "builtin", "none" (the null value — SPEC.md is normative and its gated example prints `none`; the string `"null"` is never produced) |
| `math_flags` | `math_flags of null` | Sticky numeric status: `{overflow, invalid}` — 1 when a clamp has fired since the last `clear_math_flags` (#865) |
| `clear_math_flags` | `clear_math_flags of null` | Reset both status bits |
| `assert` | `assert of [cond, msg]` | Raise catchable error `"ASSERT FAIL: <msg>"` if condition is false |
| `exit` | `exit of N` | Terminate the program with exit code `N` (default 0). **Uncatchable** — a `try`/`catch` does not intercept it — and unwinds through normal teardown, so it is leak-clean even with live closures. Code after it does not run. The request is scoped to the evaluating thread and cleared at each host eval entry, so under the embedding API a script that calls `exit` does not disable `try`/`catch` for the host's *next* eval (#739). |
| `coalesce` | `coalesce of [value, default]` | Return value unless empty/null, else default |
| `eval` | `eval of code_string` | Execute EigenScript code, return result |
| `throw` | `throw of message` | Raise catchable error |

Numeric values are finite by construction. `NaN` collapses to `0`, and
overflow or infinity saturates at `+/-1e308`. This applies to numeric
literals, `num` conversion, scalar arithmetic, tensor arithmetic, and the
numeric fast paths used by reassignment and `unobserved` blocks.

### Lists

| Name | Signature | Description |
|------|-----------|-------------|
| `append` | `append of [list, item]` | Append item to list (mutates list) |
| `concat` | `concat of [a, b]` | Concatenate two lists into new list |
| `range` | `range of n` or `range of [start, end]` | Generate integer list [0..n) or [start..end) |
| `set_at` | `set_at of [list, index, value]` | Set element at index (mutates list); negative indices count from the end, like `[]` |
| `get_at` | `get_at of [list, index]` | Get element at index; negative indices count from the end, like `[]` |
| `copy_into` | `copy_into of [dest, src, offset]` | Copy src elements into dest starting at offset |
| `list_slice` | `list_slice of [list, start, end]` | New list with the elements of [start, end) — dual of `copy_into`. Negative indices count from the end, like `[]`; bounds then clamp to [0, len]. `start >= end` gives `[]`. Never raises on bounds |
| `num_copy` | `num_copy of value` | Create independent copy of numeric value |
| `hex` | `hex of n` or `hex of [n, nibbles]` | Uppercase hex string of a non-negative integer, zero-padded to `nibbles` (never truncated). Raises on negatives, fractions, non-numbers |
| `sort` | `sort of list` | Sort an all-number or all-string list in-place (numeric / lexicographic). Mixed or non-scalar elements raise — use `sort_by` for records. Returns the list |
| `list_truncate` | `list_truncate of [list, new_len]` | Shrink list in-place to new_len items. No-op if new_len >= length. Returns the list |
| `list_remove_at` | `list_remove_at of [list, index]` | Remove element at index, shift tail down (mutates). No-op if out of bounds. Returns the list |
| `list_insert_at` | `list_insert_at of [list, index, value]` | Insert value at index, shift tail up (mutates) — dual of `list_remove_at`. `index == len` appends; any other out-of-bounds index is a no-op. Returns the list |
| `list_index_of` | `list_index_of of [list, value]` | Index of the first element structurally equal to `value` (the same comparison `==` uses — nested lists and dicts match by structure), -1 if none |
| `list_contains` | `list_contains of [list, value]` | 1 if any element structurally equals `value`, else 0 — the list counterpart of the string-only `contains` |
| `sort_by` | `sort_by of [list, key_fn]` | Sort list by numeric keys from key_fn (qsort, O(n log n), stable). Returns a new sorted list |
| `dispatch` | `dispatch of [table, key, arg]` | Index list `table` by numeric `key` and call the resulting function with `arg` — a jump table (mirrors the `OP_DISPATCH` fast path). `key` must be a number. An ordinary builtin, not a special form: a user binding of the name wins (#459 — the fast path steps aside for any unit that rebinds `dispatch`, references `eval`, or compiles against an env where it is already rebound), and the parenthesized `dispatch of ([t, k, a])` form is one argument per #355/#405 |

### Strings

| Name | Signature | Description |
|------|-----------|-------------|
| `str_lower` | `str_lower of s` | Convert to lowercase |
| `str_upper` | `str_upper of s` | Convert to uppercase |
| `char_at` | `char_at of [s, index]` | Single character at index as string ("" if out of range); negative indices count from the end, like `[]` |
| `contains` | `contains of [haystack, needle]` | 1 if haystack contains needle, else 0 (non-string operands are 0, never a spurious match) |
| `starts_with` | `starts_with of [s, prefix]` | 1 if s starts with prefix, else 0 |
| `ends_with` | `ends_with of [s, suffix]` | 1 if s ends with suffix, else 0 |
| `index_of` | `index_of of [haystack, needle]` | First index of needle in haystack, or -1 (non-string operands are -1) |
| `substr` | `substr of [s, start, length]` | Extract substring |
| `split` | `split of [s, delim]` | Split string by delimiter into list |
| `scan_ints` | `scan_ints of s` or `scan_ints of [s, comment_marker]` | C-backed scan of whitespace-delimited signed integer tokens, optionally skipping comment lines |
| `scan_tokens` | `scan_tokens of s` or `scan_tokens of [s, comment_marker]` | C-backed scan of whitespace-delimited token rows `[text, line, col, start, end]` |
| `scan_int_tokens` | `scan_int_tokens of s` or `scan_int_tokens of [s, comment_marker]` | Token rows `[text, line, col, start, end, is_int, value]` |
| `trim` | `trim of s` | Strip leading/trailing whitespace |
| `str_replace` | `str_replace of [s, old, new]` | Replace all occurrences of old with new |
| `chr` | `chr of byte` | One-byte string from a byte value 1–255 (the writing inverse of `ord`). Raises outside 1–255 — including 0, since strings are NUL-terminated — and on fractions; for a Unicode *codepoint* use `utf8_encode` (lib/utf8.eigs). |
| `join` | `join of [list, sep]` | Concatenate list elements with separator (C-backed, O(n)) |
| `text_builder_new` | `text_builder_new of null` | Create a native growable text builder |
| `text_builder_append` | `text_builder_append of [builder, value]` | Append one value as text |
| `text_builder_append_line` | `text_builder_append_line of [builder, value]` | Append one value and a newline |
| `text_builder_extend` | `text_builder_extend of [builder, values]` | Append each item in a list |
| `text_builder_part_count` | `text_builder_part_count of builder` | Count appended parts |
| `text_builder_clear` | `text_builder_clear of builder` | Empty a builder for reuse |
| `text_builder_to_string` | `text_builder_to_string of builder` | Render buffered text |
| `secure_equals` | `secure_equals of [a, b]` | Constant-time string equality (`1`/`0`). Compares every byte regardless of where a mismatch occurs, so comparison time doesn't leak how much of a secret matched. Non-strings → `0` |

### Regex

POSIX ERE (extended regular expressions). No lookahead, named groups, or
lazy quantifiers.

| Name | Signature | Description |
|------|-----------|-------------|
| `regex_match` | `regex_match of [s, pattern]` | `[full_match, group1, ...]` or `[]` |
| `regex_find` | `regex_find of [s, pattern]` | All matches as `[match1, match2, ...]` |

On a successful match, group *n* is always at index *n*, for every group in
the pattern (there is no cap on group count). A capture group that did not
participate in the match — e.g. an unmatched optional `(x)?` — is emitted as
`null`, not as `""`, so a non-participating group is distinguishable from one
that matched the empty string. Example: `regex_match of ["ab", "(x)?(a)(b)"]`
→ `["ab", null, "a", "b"]` (mirrors Python's `(None, 'a', 'b')`). A complete
non-match still returns `[]`.
| `regex_replace` | `regex_replace of [s, pattern, replacement]` | Replace all matches |

### Bitwise

Native operators `&`, `|`, `^`, `~`, `<<`, `>>` are preferred. The
builtin-call forms below are retained for backward compatibility.

| Name | Signature | Description |
|------|-----------|-------------|
| `bit_and` | `bit_and of [a, b]` | Bitwise AND (prefer `a & b`) |
| `bit_or` | `bit_or of [a, b]` | Bitwise OR (prefer `a \| b`) |
| `bit_xor` | `bit_xor of [a, b]` | Bitwise XOR (prefer `a ^ b`) |
| `bit_not` | `bit_not of x` | Bitwise NOT (prefer `~x`) |
| `bit_shl` | `bit_shl of [a, b]` | Left shift (prefer `a << b`) |
| `bit_shr` | `bit_shr of [a, b]` | Unsigned right shift (prefer `a >> b`) |
| `sign_extend` | `sign_extend of [val, bits]` | Sign-extend val from given bit width. E.g. `sign_extend of [0xFF, 8]` returns -1 |

### Buffers

Compact typed arrays of doubles with O(1) indexed access. Iterable with
`for x in buf:` and list comprehensions.

| Name | Signature | Description |
|------|-----------|-------------|
| `buffer` | `buffer of count` | Create zero-filled buffer of given size |
| `buf_get` | `buf_get of [buf, index]` | Read element; out-of-range raises `index_range` (#502 — folding to 0 was indistinguishable from a real stored 0), matching the `buf[i]` operator |
| `buf_set` | `buf_set of [buf, index, value]` | Write element |
| `buf_len` | `buf_len of buf` | Return buffer element count |
| `buf_from_list` | `buf_from_list of list` | Convert numeric list to buffer |
| `buf_copy` | `buf_copy of [src, src_off, dst, dst_off, count]` | Bulk copy between buffers (`memmove`, overlap-safe). Out-of-range windows / negative count raise (`index_range`/`value`); count 0 is a no-op |
| `buf_mix` | `buf_mix of [dst, src, dst_off, src_off, count, gain]` | In-place mix: `dst[dst_off+i] += src[src_off+i] * gain` over the window — the audio mix-down kernel (#597). VM-identical arithmetic (byte-equal to the interpreted loop); same-buffer overlap runs forward in index order. Bad windows raise |
| `buf_scale_range` | `buf_scale_range of [b, off, count, gain]` | In-place multiply over a window: `b[off+i] *= gain` (fades, normalize). Bad windows raise |
| `buf_fill` | `buf_fill of [b, off, count, value]` | Bulk store over a window: `b[off+i] = value`. Bad windows raise |
| `buf_peak` | `buf_peak of [b, off, count]` | Max absolute value over a window (normalize/meter scans); 0 for an empty window. Bad windows raise |
| `buf_dot` | `buf_dot of [a, b, a_off, b_off, count]` | Windowed dot product: sum of `a[a_off+i] * b[b_off+i]` (YIN autocorrelation). Like `dot`, summation order/association is **unspecified** (backends may reassociate); no-NaN/Inf preserved. Bad windows raise |
| `buf_from_pcm16le` | `buf_from_pcm16le of [bytes, byte_off, count]` | Decode `count` little-endian signed 16-bit PCM samples starting at `byte_off` into a NEW float buffer: `v = b0 + 256*b1`, two's-complement fold at 32768, `v / 32767` — bit-identical to the interpreted per-sample loop it replaces (#602, the WAV-import kernel). Bad windows raise |
| `buf_to_pcm16le` | `buf_to_pcm16le of [floats, off, count]` | Encode `count` samples into a NEW byte buffer (2 bytes/sample, LE): clamp to [-1, 1], `round(x*32767)`, two's complement via +65536 — bit-identical to the interpreted write loop (#602). Bad windows raise |
| `buf_deinterleave` | `buf_deinterleave of [src, channel, nch, count?]` | Every `nch`-th sample starting at index `channel` into a NEW buffer (interleaved channel split). `count` defaults to the full available tail; bad `channel`/`nch` raise `value`, count overrun raises `index_range` (#602) |
| `buf_resample_linear` | `buf_resample_linear of [src, dst_len]` | Endpoint-inclusive **linear** resample into a NEW buffer: `pos = i*(n-1)/(dst_len-1)`, lerp between the floor/ceil neighbors — bit-identical to DeslanStudio's interpreted `ab_resample_linear` (#603). The kernel is linear interpolation, **not** Fourier/sinc resampling (the consumer-documented divergence from `scipy.signal.resample`; no anti-aliasing). `dst_len` 0 → empty buffer; empty `src` with `dst_len > 0` raises `value` |
| `read_bytes_buf` | `read_bytes_buf of path` / `read_bytes_buf of [path, max_bytes]` | Read binary file as buffer. 1-arg form caps at 10MB; a file over the cap **raises** a catchable `io` error naming size + cap (#601 — was a silent null indistinguishable from "file missing"). `max_bytes` is the bounded opt-in, hard ceiling 512MB (a buffer stores one double per byte — 8x expansion — so the ceiling bounds worst-case memory at the amplification point). Missing/unopenable file returns null |
| `write_bytes` | `write_bytes of [path, <list\|buffer> {, append}]` | Write raw bytes to a file. Binary-clean (NUL written verbatim, unlike `write_text`). `append` (default 0): 0 truncates, nonzero appends. Returns bytes written, 0 on failure. |
| `rename` | `rename of [old, new]` | Rename/replace a file. Atomic on POSIX (`rename(2)`) — a crash leaves either the old or the new file whole, never a mix; basis for crash-safe swaps. Returns 1/0. |
| `remove_file` | `remove_file of path` | Delete a file. Returns 1/0. |

### Self-hosting

| Name | Signature | Description |
|------|-----------|-------------|
| `vm_run_bytecode` | `vm_run_bytecode of <descriptor>` | Assemble a chunk from a descriptor and run it on the C VM, returning the result. Descriptor: `[abi, code, constants, functions?, param_count?, name?, local_names?]` — `abi` is the **bytecode ABI revision** the producer was built against (currently `1`; see below); `code` is a list of byte ints (opcodes + little-endian operands, 16-bit except `OP_LINE`'s, which is 32-bit since #630); `constants` is the pool; `functions` is a list of nested descriptors referenced by `OP_CLOSURE` (nested descriptors carry **no** `abi` element); `local_names` (slot order) sizes the call frame and names parameters. The minimal `[abi, code, constants]` form is a flat module chunk. The bridge for an EigenScript-written compiler: emit bytecode as data, execute it on the same VM (and JIT) the C compiler's output uses. Caller supplies a well-formed chunk ending in `OP_RETURN`. **The chunk must also be stack-balanced**, and is refused (`null`, or `{ok: 0, "invalid chunk descriptor"}` through `sandbox_run`) if it is not: no instruction may be reached with fewer operands on the stack than it consumes, and the stack depth must be the same on every path into a given instruction — the JVM/Wasm rule, which keeps verification linear. So an `if`/`else` whose two arms leave different depths is rejected, as is a `CALL` that cannot see its own callee; the depth an instruction runs at is measured from the chunk's own frame base, and consuming below it would reach the caller's operands. This is the shape the C compiler already emits — a conditional's arms each push their value before the join — so a producer that mirrors compiler output needs no change. **A descriptor whose `abi` is missing or does not match the runtime raises (kind `value`) rather than executing** — #704: opcode numbers *and* operand widths are the bytecode ABI, and before the stamp a producer built against an older revision ran misaligned garbage at exit 0 with no error. Producers must hardcode the revision as a literal; a producer that reads the runtime's current value back would always agree and the check would be decoration. A non-list descriptor also raises (it silently returned `null` before #704). |
| `record_history` | `record_history of flag` | Enable (nonzero) / disable (0) per-assignment history recording that `prev of x` and `<kw> is x at <line>` temporal queries read (sets both value- and observer-state history). The C compiler auto-enables it when compiling a temporal query; a self-hosted compiler calls this. The flag must be a number — a non-numeric flag raises (it is not silently treated as disable). Returns the previous setting. |
| `sandbox_run` | `sandbox_run of [descriptor, max_iterations?, max_bytes?]` | Run a chunk (same ABI-stamped descriptor as `vm_run_bytecode`) under safety bounds. Does not throw: an ABI-revision mismatch comes back as `{ok: 0, error: {kind, message, line}}` with a message naming the revision, distinct from a malformed chunk's `invalid chunk descriptor`, so a grading ladder can tell "your producer is stale" from "your bytecode is wrong" without re-running. **Fail-closed**: only a pure-compute *allowlist* (math, bit, list/dict/string ops, buffers, json, regex, observer reads, parse/tokenize, `print`/`assert`) is visible — every other builtin (file/process/network/db, code-exec, threads, channels, terminal, `exit`, global-state mutators like `set_observer_thresholds`, and the whole extension surface) is shadowed by a blocked stub, so a new builtin is denied by default. The sandbox env is a **sealed root**, not a child of the host global env: the allowlist is copied in, so an outward assignment (`x is v`, `OP_SET_NAME`) has no outer binding to write through to and a name the host defines later is not reachable. `import` is gated at the opcode — it is not a name, so the allowlist never covered it. A **callable cannot cross the boundary**: a `fn` in the result closes over the sandbox env and would run in the host after the caps are restored, so it comes back as `{ok: 0, error: {kind: "sandbox", ...}}` instead. That scan is node/depth budgeted and fails closed, so a result too large to scan is also refused — with a message saying so, distinct from the one naming an actual callable. `max_iterations` bounds loops through **two** counters, whichever trips first, and they are scoped differently. The compiler-emitted cap check (`OP_LOOP_CAP_CHECK`) is **per call frame** — each invocation starts fresh, and tripping it exits the loop gracefully and reports the run as a capped *partial run*. The back-edge counter (`OP_JUMP_BACK`) is a **cumulative total for the whole `sandbox_run`**, deliberately not restored per frame so an assembled chunk cannot reset its own DoS budget by calling a function; tripping it raises. So the same loop called twice within one run can trip the cumulative budget even though each call is individually well inside `max_iterations` — the bound is on the run, not on any one loop. Either way neither a runaway loop nor a single blocking call can hang the host. **A chunk that could underflow the operand stack is refused before it runs** (see `vm_run_bytecode` for the balance rule): the interpreter's arithmetic fast paths index the value stack directly rather than through the guarded pop, so an opcode reached with too few operands read and wrote below the stack's base — `[OP_ADD, OP_RETURN]` was enough. The equivalent env-chain fault is caught at the instruction instead, since it cannot be settled statically: an `OP_LOOP_ENV_END` with no matching `OP_LOOP_ENV_FRESH` raises `loop-env underflow` rather than walking the frame off the end of its scope chain. **Memory is capped at `max_bytes` (default 256 MiB)**: the size-controlled allocators (`zeros`/`fill`/`buffer`/`range`/`concat`) and the zlib codecs (`inflate`/`deflate` and their `zlib_*` duals — both the codec buffer and the list of values built from it) charge a per-run budget, so a single huge allocation *or* an aggregate across a loop raises a caught error (→ `{ok:0}`) instead of an uncatchable out-of-memory `abort()`. The codecs matter here because every other allocator makes the caller *name* a size, which is what the charge reads, while a compressed blob names nothing and amplifies ~1000x. **The descriptor itself is verified as untrusted data, under one bounded context for the whole graph**: a single work allowance covering the root chunk, every nested function chunk, code, constants, function lists and local names — nested chunks share it rather than each declaring their own — plus an explicit recursion-depth bound and back-edge (cycle) refusal. A graph that cannot be verified within that allowance comes back as `{ok: 0, "invalid chunk descriptor"}`. **Descriptor constants are data-only and ISOLATED**: a callable (or text builder) anywhere in the pool is refused at any depth, and each mutable constant (list/dict/buffer) is deep-copied, so the sandbox mutates its own copy — an allowlisted `append`/`set_at`/`dict_set`/`buf_set` on a constant cannot be seen by the host, and the host cannot change a constant mid-run. For the same reason the allowlist copies only the pure C builtin each allowed name actually holds: if the host has rebound one of those names, the sandbox gets the blocked stub rather than the host's value. Runtime errors are caught. Returns `{ok: 1/0, result: value}`. For validating untrusted/generated code. |

### Bytes ↔ values

For serialization: reconstruct strings/floats from raw bytes (the inverse of an
`ord` loop / manual bit-packing), covering cases 32-bit bitwise can't.

| Name | Signature | Description |
|------|-----------|-------------|
| `str_from_bytes` | `str_from_bytes of <list\|buffer>` | Build a string from raw byte values (0–255) — the list form of `chr` (`chr of n` == `str_from_bytes of [n]` for 1–255), inverting an `ord`-over-bytes loop. Strings are NUL-terminated: a `0` byte ends the string — keep NUL-bearing binary in a buffer. |
| `f64_to_bytes` | `f64_to_bytes of x` | List of 8 ints: the big-endian IEEE-754 encoding of double `x` (network byte order, portable across host endianness). |
| `f64_from_bytes` | `f64_from_bytes of <list\|buffer>` | Decode a double from the first 8 big-endian IEEE-754 bytes. Inverse of `f64_to_bytes`. |

Buffers also support direct indexing (`buf[i]`, `buf[i] is val`) and
compound assignment (`buf[i] += val`).

### Compression

DEFLATE codecs (#684), thin wrappers over the system zlib. Byte
representation mirrors `read_bytes`/`write_bytes`: input is a list of
ints 0–255 (values taken mod 256) or a buffer; output is always a fresh
list of ints 0–255. Corrupt or truncated input raises a catchable
`value` error; decompressed output is capped at 256 MiB (`limit`,
zip-bomb bound).

Requires the `zlib` build (`make zlib`, `-DEIGENSCRIPT_EXT_ZLIB=1
-lz`) — the minimal build stays zero-dependency: the four names are
still registered there (so `type of inflate` is `builtin` and the
sandbox allowlist can name them) but every call raises `value`:
"compiled without zlib support". Feature-detect with try/catch.

| Name | Signature | Description |
|------|-----------|-------------|
| `inflate` | `inflate of <list\|buffer>` | Raw DEFLATE decompression (windowBits −15) — the ZIP member format, so `.xlsx`/`.ods` entries are readable. Dual of `deflate`. |
| `deflate` | `deflate of <list\|buffer>` | Raw DEFLATE compression (windowBits −15, default level). Dual of `inflate`. |
| `zlib_inflate` | `zlib_inflate of <list\|buffer>` | Wrapped decompression with windowBits 15+32: auto-detects **zlib AND gzip** headers — this is what makes plain `.gz` files readable (`read_bytes of path` then `zlib_inflate`). Dual of `zlib_deflate`. |
| `zlib_deflate` | `zlib_deflate of <list\|buffer>` | zlib-wrapped compression (RFC 1950 header, default level). Dual of `zlib_inflate`. |

### JSON

| Name | Signature | Description |
|------|-----------|-------------|
| `json_encode` | `json_encode of value` | Serialize value to JSON string. Raises on a value nested deeper than 200 levels — which includes any **cyclic** value (`dict_set of [d, "self", d]`, `append of [a, a]`), since a cycle has no depth. Catchable. |
| `json_decode` | `json_decode of s` | Parse JSON string to value. Raises past the same 200-level limit, so a document that decodes always re-encodes. `\uXXXX` surrogate pairs are combined into one code point; unpaired surrogates, an escaped NUL, and malformed `\u` escapes raise (strict decode — lenient callers such as `json_path` receive the complete document with U+FFFD in place of the bad scalar). |
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

Six keywords for querying a value's observer state. Asking is cheap — the
state is already there — but note that maintaining it is not free: every
assignment outside `unobserved:` is sampled whether or not you ever ask. See
[OBSERVER.md](OBSERVER.md#cost).

| Name | Syntax | Returns |
|------|--------|---------|
| `what` | `what is x` | Current value (scalar), or length (list/string) |
| `who` | `who is x` | Variable name as string |
| `when` | `when is x` | Observation age (number of assignments) |
| `where` | `where is x` | Entropy (information content) |
| `why` | `why is x` | dH (rate of change) |
| `how` | `how is x` | Currently degenerate — returns 0 (1 only at zero entropy); see OBSERVER.md, #412 |

### Temporal

Query a binding's assignment history. Always on for top-level bindings;
`null` on a miss. See [SYNTAX.md](SYNTAX.md) and [TRACE.md](TRACE.md).

| Name | Syntax | Returns |
|------|--------|---------|
| `prev` | `prev of x` | Value of `x` just before its most recent assignment |
| `at` | `what is x at L` | State at or before line `L` — works with all six interrogatives and `prev` |
| `state_at` | `state_at of line` | Dict of every tracked binding's value at or before `line` |

## Observer

| Name | Signature | Description |
|------|-----------|-------------|
| `report` | `report of value` | Classify change trajectory: "improving", "diverging", "stable", "equilibrium", "oscillating", "converged" — or "moving" when a full window matches none of them (#735) |
| `observe` | `observe of value` | Return [status, entropy, dH, prev_dH] snapshot |
| `classify` | `classify of t` or `classify of [t, "entropy"]` | Classify a trajectory snapshot (from `trajectory of x`, #421): value-channel label by default, entropy-channel with `"entropy"`. Raises `type_mismatch` on a non-snapshot — a bare value never silently classifies |

**`report`, `report_value`, `observe`, and `trajectory` on a plain variable
are observer special forms** (decided in #459): like the predicates and
interrogatives, `report of x` / `report_value of x` / `observe of x` /
`trajectory of x` are resolved by the compiler to the named *binding's* slot
trajectory — an operation on the name, not the value — so a user rebinding of
these names does not change them (`--lint` W013 warns on the shadowing
attempt). `trajectory of x` (#421) snapshots the slot's observer windows into
a plain dict (`kind`/`rel`/`raw`/`dh`/`entropy`/…) that survives a call
boundary, for `classify` to read on the other side — the binding slot itself
is binding-identity and a passed value arrives with no history. The non-ident
forms (`report of (x + 0.0)`, `observe of expr`) are ordinary calls to the
value-path builtins. `dispatch` is deliberately NOT in this set — it is a
plain builtin and a user rebinding wins (see Lists above).

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
| `load_file` | `load_file of "path.eigs"` | Load and execute EigenScript file. A missing/unreadable path raises a catchable `io` error (matching `import`); a parse/compile failure in the file raises `parse`. |
| `file_exists` | `file_exists of "path"` | 1 if file exists, 0 otherwise. Trace-recorded, so replay is deterministic (#585) |
| `is_dir` | `is_dir of "path"` | 1 if the path names a directory, 0 for a plain file / missing path (#576 — replaces the `file_exists of "path/."` probe). Trace-recorded, so replay is deterministic |
| `read_text` | `read_text of "path"` | Read file contents as string ("" on failure, 10 MB cap) |
| `read_line` | `read_line of null` | Blocking line read from **stdin**: next line without its trailing newline (`\r\n` stripped as one unit), `null` at EOF; an empty line is `""`. Works on pipes — the stream-safe primitive `read_text of "/dev/stdin"` can't be (fseek fails on unseekable fds, #558). Trace-recorded, so replay is deterministic |
| `read_bytes` | `read_bytes of "path"` | Read a file's raw bytes as a list of integers 0–255 (`null` on failure, 10 MB cap). Trace-recorded, so replay is deterministic |
| `proc_read_buf` | `proc_read_buf of [out_fd, max]` | Single `read(2)` of up to `max` bytes from a child fd, returned as a list of integers 0–255 — the byte-list twin of `proc_read`. `null` on EOF / error, 10 MB cap. Replay-gated |
| `write_text` | `write_text of ["path", text]` | Write string to file (1 on success, 0 on failure) |
| `exec_capture` | `exec_capture of ["cmd", "arg1", ...]` | Run subprocess, return [exit_code, stdout_text]. No shell (direct exec). Child stdin is /dev/null. Returns [-1, ""] on failure, [-2, partial] on timeout. 10 MB output cap. Timeout form: `exec_capture of [["cmd", ...], seconds]` |
| `proc_spawn` | `proc_spawn of ["cmd", "arg1", ...]` | Fork+execvp a child with stdin/stdout connected to anonymous pipes. Returns `[pid, in_fd, out_fd]` (or `[-1,-1,-1]` on failure). Caller is responsible for `proc_close` on both fds and `proc_wait` on the pid. SIGPIPE is set to `SIG_IGN` process-wide on first spawn so the parent gets `EPIPE` from `proc_write` instead of dying; child resets to `SIG_DFL` post-fork. |
| `proc_write` | `proc_write of [in_fd, text]` | Write bytes to child's stdin pipe (raw `write(2)`, no parent-side buffering). Returns bytes written, or `-1` on error (including `EPIPE` when the child has closed its stdin). |
| `proc_read_line` | `proc_read_line of out_fd` | Read up to the next `\n` from the child's stdout (raw `read(2)`). Returns the line without the trailing newline, or `""` at EOF. Line streaming relies on the child not block-buffering its stdout — wrap with `stdbuf -oL` when in doubt. |
| `proc_read` | `proc_read of [out_fd, max_bytes]` | Single non-line-oriented `read(2)` of up to `max_bytes`. Returns the bytes (possibly shorter than asked), or `""` at EOF. |
| `proc_close` | `proc_close of fd` | Idempotent `close(2)`. Returns 1 on success, 0 if already closed / invalid. |
| `proc_wait` | `proc_wait of pid` | Block on `waitpid(pid, ...)` and return the exit code (or `128 + signum` if killed by a signal). |
| `env_get` | `env_get of "VAR_NAME"` | Get environment variable (empty string if unset) |
| `random_hex` | `random_hex of n` | Generate n random hex characters from /dev/urandom |
| `try_parse` | `try_parse of code_string` | 1 if string is valid EigenScript syntax, 0 otherwise |
| `mkdir` | `mkdir of "path"` | Create directory (and parents). 1 on success, 0 on failure. Trace-recorded: replay serves the recorded bit and does not re-create the directory (#585) |
| `ls` | `ls of "path"` | List directory contents as list of strings. Trace-recorded, so replay is deterministic (#585) |
| `getcwd` | `getcwd of null` | Current working directory as string. Trace-recorded, so replay is deterministic (#585) |
| `exe_path` | `exe_path of null` | Absolute path of the running interpreter binary. Lets a script re-invoke the same interpreter (e.g. `exec_capture of [exe_path of null, file]`) without assuming `eigenscript` is on PATH. Trace-recorded, so replay is deterministic (#585) |
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
| `stream_open` | `stream_open of ["path", count]` | Open file, write header for `count` float64 values. 1 on success, 0 on failure. One stream per **thread**: opening a second closes the first, and an unclosed stream is flushed and closed when the thread ends (#739) |
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
| `random_int` | `random_int of [lo, hi]` | Random integer in [lo, hi] inclusive; raises on non-finite or out-of-int64 bounds and on a span over 2^31 |
| `seed_random` | `seed_random of n` | Seed the RNG for deterministic sequences |

## Time

| Name | Signature | Description |
|------|-----------|-------------|
| `monotonic_ns` | `monotonic_ns of null` | Nanoseconds from `CLOCK_MONOTONIC` (jump-free) |
| `monotonic_ms` | `monotonic_ms of null` | Milliseconds from `CLOCK_MONOTONIC` |
| `clock_unix` | `clock_unix of null` | Seconds since the Unix epoch (float, wall clock; tape-captured for replay) |
| `usleep` | `usleep of microseconds` | Pause execution |

## Trace & Replay

Nondeterministic builtins (`random*`, `monotonic_*`, `clock_unix`,
`env_get`, `read_*`, HTTP request/response accessors) are recorded to a
tape when `EIGS_TRACE=<path>` is set, and served back from a recorded
tape when `EIGS_REPLAY=<path>` is set — subsequent runs produce
byte-identical output. Full tape format and replay semantics:
[TRACE.md](TRACE.md).

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
| `min` | `min of [n1, n2, ...]` | Smallest of a list of numbers (any length >= 1) |
| `max` | `max of [n1, n2, ...]` | Largest of a list of numbers (any length >= 1) |
| `floor` | `floor of x` | Round down to integer |
| `ceil` | `ceil of x` | Round up to integer |
| `round` | `round of x` | Round to nearest integer |
| `sin` | `sin of x` | Sine (radians) |
| `cos` | `cos of x` | Cosine (radians) |
| `tan` | `tan of x` | Tangent (radians) |
| `asin` | `asin of x` | Inverse sine; input is clamped to [-1, 1] |
| `acos` | `acos of x` | Inverse cosine; input is clamped to [-1, 1] |
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
| `divide` | `divide of [a, b]` | Element-wise division; zero denominator returns 0, overflow saturates |
| `pow` | `pow of [base, exp]` | Element-wise exponentiation; overflow saturates |
| `negative` | `negative of t` | Element-wise negation |

### Functions

| Name | Signature | Description |
|------|-----------|-------------|
| `sqrt` | `sqrt of t` | Element-wise square root; negative input returns 0 |
| `exp` | `exp of t` | Element-wise e^x; overflow saturates |
| `log` | `log of t` | Element-wise natural log; input is floored at 1e-10 |
| `softmax` | `softmax of t` | Row-wise softmax normalization (a scalar is the one-element case → `1.0`) |
| `log_softmax` | `log_softmax of t` | Row-wise log(softmax) (a scalar → `log(1)` = `0.0`) |
| `relu` | `relu of t` | Element-wise max(0, x) (accepts a scalar) |
| `leaky_relu` | `leaky_relu of t` | Element-wise max(0.01x, x) (accepts a scalar) |

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
| `reshape` | `reshape of [buffer, rows, cols]` | New numeric buffer with the same data reinterpreted as `rows`×`cols` (requires `rows*cols == count`; `null` otherwise) |

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
| `heap_inuse` | `heap_inuse of null` | Return bytes currently in use by the C allocator (glibc `mallinfo2().uordblks`, main arena; null on non-glibc). Debug surface |
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

## Optional: Network Extension (TCP sockets)

Requires a `make net` build (`EIGENSCRIPT_EXT_NET=1`; in no default
build). Raw TCP sockets whose every nondeterministic outcome — accepted
connections, received bytes, bytes-sent counts, dial results,
kernel-assigned ports — rides the trace tape: a session recorded under
`EIGS_TRACE` replays byte-identically under `EIGS_REPLAY` with **no
network present** (the replay run performs zero socket syscalls). See
[TRACE.md](TRACE.md).

| Builtin | Form | Returns |
|---------|------|---------|
| `net_listen` | `net_listen of port` | listener handle, or `null` (bind failed). Port `0` = kernel-assigned ephemeral port |
| `net_port` | `net_port of listener` | the locally bound port (the kernel's pick for port 0), or `null` |
| `net_accept` | `net_accept of listener` / `net_accept of [listener, timeout_ms]` | connection handle, or `null` on timeout |
| `net_dial` | `net_dial of [host, port]` / `net_dial of [host, port, timeout_ms]` | connection handle, or `null` (refused / unresolvable / timeout) |
| `net_recv` | `net_recv of [conn, max_bytes]` / `net_recv of [conn, max_bytes, timeout_ms]` | buffer of byte values (empty buffer = connection over), or `null` on timeout. `max_bytes` is clamped to 8192 per call — loop to drain; decode text with `str_from_bytes` |
| `net_send` | `net_send of [conn, data]` — `data` is a string, buffer, or byte list | bytes sent, or `-1` (peer gone / bad handle) |
| `net_close` | `net_close of handle` | `null`; idempotent |

Environment failures are *values* (`null` / `-1` / empty buffer), never
raises, so every outcome lands on the tape and a `catch` cannot desync
replay; argument-shape mistakes (wrong type or arity) raise
deterministically. A single-threaded program can be both ends of a
connection: on loopback, `net_dial` completes against the listen
backlog before `net_accept` runs (see `examples/net_echo.eigs`).
Sockets left open at exit are closed by the runtime's handle-table
drain. UDP is not yet exposed (#414 tracks it).

## Optional: HTTP Extension

Requires full build. Provides an embedded HTTP server.

**Request limits (DoS bounds).** Each request body is capped by
`EIGS_HTTP_MAX_BODY` (default 16 MiB; an over-cap `Content-Length` gets `400`,
oversized headers `431`). Because that per-request cap times the concurrent-
connection cap is still a large aggregate, the server also bounds the **total**
request-body bytes in flight across *all* connections with
`EIGS_HTTP_MAX_BODY_TOTAL` (default 128 MiB) — once exceeded, further
connections are shed with `503` rather than letting concurrency × per-request
size exhaust host memory.

**Slow-loris bounds.** The server is thread-per-connection with a global cap of
256 workers, so slow clients that each hold a worker are a denial-of-service
axis. Three controls bound it:

- `EIGS_HTTP_MAX_CONN_PER_IP` (default 48) — the maximum concurrent connections
  from a single source IP; further connections from that address get `503`, so
  one source can't hold all 256 slots. **Set to `0` when deploying behind a
  reverse proxy** — every connection then carries the proxy's address, and a
  nonzero cap would throttle the proxy to N; do the per-IP limiting at the proxy
  instead (the recommended posture for a directly-exposed server).
- `EIGS_HTTP_HEADER_TIMEOUT` (default 10s) — a request's headers must arrive
  within this window (separate from, and shorter than, the 30s total-request
  deadline that must accommodate a large body); otherwise `408`.
- `EIGS_HTTP_HEADER_MIN_RATE` (default 256 bytes/sec, `0` disables) — after a
  short grace period the header phase must sustain at least this byte rate, so a
  byte-per-second trickle is dropped (`408`) in a couple of seconds instead of
  holding a worker until the deadline.

| Name | Signature | Description |
|------|-----------|-------------|
| `http_route` | `http_route of [method, path, body]` or `[method, path, "code", source]` | Register a route. `body` is a literal response body, **not** a callback — passing a function raises (#877); use the `code` form for per-request logic |
| `http_route_authed` | `http_route_authed of [method, path, body]` or `[method, path, "code", source]` | Register authenticated route; auth source published via `shared_set of ["require_auth", "<source>"]` |
| `http_static` | `http_static of [prefix, directory]` | Serve static files (realpath-confined to `directory`) |
| `http_early_bind` | `http_early_bind of null` | Pre-bind socket and start health thread |
| `http_serve` | `http_serve of port` | Start blocking HTTP server |
| `http_request_body` | `http_request_body of null` | Get current request body |
| `http_session_id` | `http_session_id of null` | Get current session ID |
| `http_post` | `http_post of [url, headers, body]` | HTTP POST via curl (no shell). `headers` is a JSON **string**, either an object (`"{\"X-Key\": \"v\"}"`) or a flat alternating array (`"[\"X-Key\", \"v\"]"`); `""` means no headers. Any other parsed shape raises `type_mismatch` rather than silently sending none (#755). Max 32 headers; CR/LF is stripped from both halves |
| `http_request_headers` | `http_request_headers of null` | Get current request headers |

### Per-worker code routes

A route declared as `[method, path, "code", source]` evaluates `source`
in a fresh worker `EigsState` on every request — stdlib + the
request-scoped HTTP builtins (`http_request_body`, `http_session_id`,
`http_request_headers`, `http_post`, and the `shared_*` family below)
are available; **startup-scope globals are not**. The final
expression's value is sent as the response body. Per-worker isolation
means concurrent requests don't race on script state and mutations
don't leak across requests; cross-worker state goes through the
shared store.

### Shared store: cross-worker key/value primitive

JSON-serialized map living on the `EigsHttpServer`, mutex-guarded.
Values cross worker boundaries by being encoded on write and re-parsed
on read into a value owned by the caller's state. Function values
can't be stored (encoded as `null` per `json_encode`). A cyclic or
over-deep value can't be stored either — `shared_set` rejects it and
`json_encode` raises, rather than the crash that used to take the whole
server down with it. Total bytes are bounded by
`EIGS_HTTP_SHARED_MAX_BYTES` (default 64 MiB); over-cap writes return
`null` without mutating.

| Name | Signature | Description |
|------|-----------|-------------|
| `shared_set` | `shared_set of [key, value]` | Store `value` (JSON-encoded). Returns `null` if over byte cap. |
| `shared_get` | `shared_get of key` | Return stored value (re-parsed) or `null` if absent. |
| `shared_has` | `shared_has of key` | Return `1` if key present, else `0`. |
| `shared_delete` | `shared_delete of key` | Remove key; return `1` if removed, `0` if absent. |
| `shared_keys` | `shared_keys of null` | Return list of keys. |
| `shared_size` | `shared_size of null` | Return current key count. |
| `shared_clear` | `shared_clear of null` | Drop all entries. |
| `shared_incr` | `shared_incr of [key, delta]` | Atomic single-lock read-modify-write. Missing key treated as `0`. Returns new value, or `null` if existing value is non-numeric. |

Individual op atomicity is guaranteed by the mutex. For
read-modify-write atomicity use `shared_incr`; `shared_get`+`shared_set`
sequences can lose updates under concurrent writers.

### Authenticated routes (`http_route_authed`)

The auth source resolves from `shared_get of "require_auth"` first.
When that key holds a string, the worker tokenizes/parses/compiles/
executes it on every authed request in a fresh env layered on the
worker global. Empty `value_to_string` result allows the request; any
non-empty result becomes the `401 Unauthorized` response body
verbatim. Hosts publish a session table or token-validity flag via
`shared_set` and write the auth check as a small script that consults
it. Re-evaluation happens per request, so flipping the shared state
takes effect immediately.

If the `require_auth` key is absent, the worker falls back to a
`require_auth` *function* in the global env (legacy path; default
worker envs don't populate it).

## Optional: Graphics (SDL2) Extension

Requires a build with graphics enabled (`make gfx`). Dynamically loads
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
| `gfx_rrect` | `gfx_rrect of [x, y, w, h, radius, r, g, b]` or `[..., a]` | Filled rounded rectangle (scanline corner fill); radius clamps to half the smaller dimension, `radius 0` = plain rect |
| `gfx_clip` | `gfx_clip of [x, y, w, h]` / `gfx_clip of null` | Set / clear the render clip rectangle |
| `gfx_read` | `gfx_read of [x, y]` | Read back one rendered pixel as `[r, g, b]` — the render-decode oracle primitive (#823). Reads the current back buffer: call after drawing, **before** `gfx_present`. Null with no window or a failed read. Nondeterministic input (font raster, driver), so it records/replays on the trace tape |
| `gfx_text` | `gfx_text of [x, y, text, r, g, b]` or `[..., scale]` | Text. Proportional antialiased TTF when libSDL2_ttf + a font are available (#593); the 5x7 bitmap font otherwise — see the font note below the table |
| `gfx_text_width` | `gfx_text_width of [text, scale?]` or `of "text"` | Pixel width of `text` under the active text renderer: TTF metrics when active, `len * 6 * scale` in bitmap mode. Works before `gfx_open` |
| `gfx_text_height` | `gfx_text_height of scale?` | Pixel line height under the active text renderer: TTF font height when active, `7 * scale` in bitmap mode |
| `gfx_present` | `gfx_present of null` | Flip backbuffer to screen |
| `gfx_poll` | `gfx_poll of null` | Return next event as dict (`quit`, `keydown`, `keyup`, `mousemove`, `mousedown`, `mouseup`, `wheel`, `resize`), or null. Key, mouse, and wheel events carry `shift`/`ctrl`/`alt` (0/1); wheel `x`/`y` are scroll deltas |
| `gfx_ticks` | `gfx_ticks of null` | Milliseconds since `SDL_Init` |
| `gfx_delay` | `gfx_delay of ms` | Sleep for ms (SDL-coordinated) |
| `gfx_title` | `gfx_title of "text"` | Update window title |
| `gfx_fb` | `gfx_fb of [buf, w, h, x, y, scale]` | Blit buffer (palette indices 0-3) as scaled texture |
| `ppu_render_frame` | `ppu_render_frame of [mem_buf, fb_buf]` | Full Game Boy PPU render (BG/window/sprites) into framebuffer |

**Text rendering and fonts (#593).** `gfx_text` lazily loads
`libSDL2_ttf-2.0.so.0` on first use and renders proportional antialiased
text (`TTF_RenderUTF8_Blended`) when both the library and a font file are
present. Font selection: the `EIGS_GFX_FONT` environment variable
(absolute path to a `.ttf`) wins; when it is set but unreadable the
runtime warns once and stays on the bitmap font (a nonexistent path is
the deterministic off-switch). Otherwise a short list of common system
fonts is probed (DejaVu Sans, Liberation Sans, Noto Sans under
`/usr/share/fonts/truetype/`). Without SDL2_ttf or a font, `gfx_text`
renders through the built-in 5x7 bitmap font exactly as before — the
fallback is load-bearing (CI containers may have neither). Layout code
should measure through `gfx_text_width`/`gfx_text_height` (as `lib/ui`
does) rather than assuming the `6 * scale` monospace advance. Text
rendering is output-only: no trace-tape records in either mode.

## Optional: Database Extension

Requires full build with libpq. PostgreSQL client.

| Name | Signature | Description |
|------|-----------|-------------|
| `db_connect` | `db_connect of null` | Connect via DATABASE_URL env var; returns a status JSON, never raises |
| `db_query_value` | `db_query_value of sql` or `db_query_value of [sql, p1, p2]` | Execute query, return row 0 col 0 typed by its SQL type; `null` for SQL NULL, `""` for no rows |
| `db_execute` | `db_execute of sql` or `db_execute of [sql, p1, p2]` | Execute command with optional params; returns `"ok"` |
| `db_query_json` | `db_query_json of sql` or `db_query_json of [sql, p1, p2]` | Execute query, return all rows as a JSON array of objects, each value typed by its SQL type |

### Failures raise (#888)

`db_connect` is the only one that reports by return value — it hands back
`{"status": ...}` so a program can probe for a database without a `try`.
Every other db builtin **raises** a catchable `io` error when the statement
fails or there is no connection, carrying libpq's own first line
(`ERROR:  relation "orders" does not exist`). A genuinely empty result is
still `[]` / `""`, and only that.

They used to return `[]` / `""` for a syntax error, a missing table, a
revoked permission *and* an empty table alike, so a reporting script kept
printing "0 rows" forever after a schema change and a migration that did
nothing looked healthy in CI.

```eigenscript
try:
    rows is json_decode of (db_query_json of "SELECT * FROM orders")
catch e:
    print of ("query failed: " + e.message)   # e.kind is "io"
```

### SQL types survive the trip (#887)

Values carry their column's SQL type rather than arriving as strings:

| SQL type | Arrives as | Note |
|---|---|---|
| NULL (any column type) | `null` | Distinct from `""` — checked before the type |
| `boolean` | `true` / `false` → `1` / `0` | `if row.is_admin:` means what it reads as |
| `smallint`, `integer`, `bigint`, `oid` | number | `bigint` past 2^53 **raises** — see below |
| `real`, `double precision` | number | `NaN`/`Infinity` arrive as strings; JSON has no literal for them |
| `numeric` | **string** | Deliberate — see below |
| everything else | string | text, date, uuid, json, … unchanged |

The mapping is a function of the column's SQL type alone, never of the
row's value: a column that decoded as a number for row 1 and a string for
row 100 would break `row.n + 1` on data rather than on schema.

**`numeric` stays a string.** It is PostgreSQL's arbitrary-precision decimal
— the money type — and an EigenScript number is a binary double, which
cannot hold `numeric(38,10)` or even `0.1` exactly. Preserving the digits
is the safe default; `SELECT amount::float8` is the one-token opt-in to a
number when approximate is fine. Note `avg()` and `sum(numeric)` return
`numeric`, so those want the cast; `count(*)` and `sum(integer)` return
`bigint` and are already numbers.

**A `bigint` past 2^53 raises** instead of silently rounding, naming the
column and the fix:

```
Error line 3: db: column 'id' value 9007199254740993 exceeds the exact-integer
range of a number (2^53); select it as text (id::text) to keep the digits
```

Before this, every value was a string: SQL `false` arrived as `"f"`, which
is a non-empty string and therefore **truthy**, so `if row.is_admin:` passed
for a non-admin; NULL and `''` were both `""`; and `9 > 10` was true because
`'9' > '1'`.

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

## Concurrency

| Name | Signature | Description |
|------|-----------|-------------|
| `spawn` | `spawn of fn` or `spawn of [fn, arg1, ...]` | Spawn a thread running `fn`. Bare-fn form passes no args; list form passes `arg1...` positionally. Missing trailing params bind to `null`; extra args are ignored. Args are shared by reference (unlike channel sends, which copy) — see thread-safety note below. Returns a thread handle dict. |
| `thread_join` | `thread_join of handle` | Block until thread completes. Returns the thread function's return value. |
| `channel` | `channel of null` | Create a bounded FIFO channel (capacity 64). Returns a channel handle dict. |
| `send` | `send of [channel, value]` | Send a value to the channel. Blocks if full. Sending to a **closed** channel raises a catchable `value` error (rather than silently dropping the value); `recv` on a closed empty channel returns `null` (EOF-like). |
| `recv` | `recv of channel` | Receive a value from the channel. **Blocks** until a value is available or the channel is closed. |
| `try_recv` | `try_recv of channel` | Non-blocking receive. Returns the value if available, `null` if the channel is empty. |
| `recv_timeout` | `recv_timeout of [channel, ms]` | Bounded-wait receive. Returns the value if one arrives before `ms` milliseconds elapse, else `null`. A close while waiting also returns `null`. Fractional `ms` is honored (ns precision on Linux); negative `ms` degenerates to a `try_recv`. |
| `close_channel` | `close_channel of channel` | Close the channel. Wakes all blocked senders/receivers. |
| `channel_closed` | `channel_closed of channel` | Returns 1 if closed, 0 otherwise. |
| `task_spawn` | `task_spawn of fn` or `task_spawn of [fn, arg1, ...]` | Create a cooperative task (#408) running `fn` on the single OS thread — deterministic by construction, unlike `spawn`'s OS thread. Args are deep-COPIED (share-nothing, like channel sends), not shared by reference. Returns a numeric task id. (Increment 1a: the task is recorded and reported by `task_alive`; the copying-stack scheduler that runs and interleaves tasks — `task_yield`/`task_join` — lands in a later increment.) |
| `task_alive` | `task_alive of id` | Returns 1 while the task is runnable or suspended, 0 once it has finished (or for an unknown id). |
| `task_self` | `task_self of null` | The **running task's own id** (a number, in the same integer space `task_spawn` returns; the main task is 0, including before any task has been spawned). Lets a worker hand out its own id as a reply address — the message-link pattern a mailbox otherwise cannot express (#526). Deterministic — reads scheduler state, records no nondeterminism. |
| `task_yield` | `task_yield of null` | Cooperatively hand control to the next ready task; this task resumes round-robin. A no-op when no task has been spawned. Forbidden inside an `arena_mark`…`arena_reset` scope or a nested evaluation (raises `value`). |
| `must_not_yield` | `must_not_yield of fn` | Run `fn of null` as an **atomic** critical section, asserting it issues no scheduler yield (#488). Any *suspending* task builtin inside — `task_yield`, a blocking `task_recv`/`task_join`, `task_sleep` — raises `value` instead of suspending, so a yield introduced into a region that relies on cooperative atomicity fails loudly rather than corrupting under a rare interleaving. Non-suspending ops (`task_try_recv`, `task_send`, joining an already-finished task) are allowed. Returns `fn`'s result (or propagates its error); the region depth is balanced even if the body raises. Nestable. |
| `task_join` | `task_join of id` | Block until task `id` finishes, then return its deep-copied result — or re-raise its uncaught error (as the same `{kind, message, line}` it died with). Joining an already-finished task returns immediately; an unknown id (or self) returns null. All tasks blocked with none runnable is a `deadlock` error, not a hang — catchable by a `try`/`catch` around the join on the main task (`e.kind == "deadlock"`); terminal only if unhandled. |
| `task_send` | `task_send of [id, value]` | Append a deep-copied message to task `id`'s unbounded FIFO mailbox, waking it if it waits in `task_recv`. Returns 1 if delivered, 0 if `id` is finished/unknown (a silent drop — send-to-dead is never an error). Never blocks. |
| `task_recv` | `task_recv of null` | Return the next message from this task's mailbox, or block cooperatively until one arrives. Forbidden inside an `arena_mark`…`arena_reset` scope or a nested evaluation (raises `value`). |
| `task_try_recv` | `task_try_recv of null` | Non-blocking receive: the next mailbox message, or `null` if empty. Never suspends. |
| `task_kill` | `task_kill of id` | Tear down task `id`: drop its mailbox, mark it dead, wake any joiner with an `interrupt` error. Returns 1 if killed, 0 for a finished/unknown/self target. |
| `task_detach` | `task_detach of id` | Mark task `id` **fire-and-forget** (the pthread-detach precedent, #530): it is reaped the moment it finishes — or immediately if already finished — releasing its handle slot for reuse, so task-per-message workloads are bounded by *concurrent* tasks, not lifetime spawns. A detached task's uncaught death still prints its trace and still fails the process at exit (#493). A reaped id reads as unknown afterwards (`task_join` null, `task_alive` 0). A task may detach itself: `task_detach of (task_self of null)`. Returns 1, or 0 for main/unknown. |
| `task_sleep` | `task_sleep of ticks` | Suspend this task until the **virtual clock** advances by `ticks`. The clock is logical (discrete-event): it only jumps forward — to the earliest sleeper — when nothing else is runnable, so sleeping stays deterministic, not wall-clock. A negative sleep is treated as 0. A no-op when no task has been spawned. Forbidden inside an `arena_mark`…`arena_reset` scope. |
| `task_now` | `task_now of null` | The current virtual-clock value (a number; 0 before any `task_sleep`). Deterministic — reads a logical counter, records no nondeterminism. |
| `task_sched_seed` | `task_sched_seed of n` | Install a scheduling **seed**: the scheduler switches from FIFO round-robin to picking the next ready task from a seeded, platform-independent PRNG. Same seed ⇒ same interleaving (byte-identical run + replay, zero tape nondeterminism); a different seed explores a different ordering — the lever a deterministic simulation tester uses to search interleavings. No seed ⇒ unchanged FIFO. Typically called once at program start. Returns null. |

**Thread safety:** Values sent through a channel (or returned through
`thread_join`) are deep-COPIED via `val_clone_for_send` — messages are
share-nothing. Numbers, strings, and nested lists/dicts arrive as independent
copies, so mutating the original after a send cannot be observed by the other
thread (see `docs/CONCURRENCY.md`). The exceptions are handle-like values —
`buffer`, `text_builder`, `fn`, and `builtin` — which remain shared by
reference across a send; do not mutate those concurrently from sender and
receiver.

## Spatial Queries

| Name | Signature | Description |
|------|-----------|-------------|
| `nearest_in_range` | `nearest_in_range of [entities, x, y, range, world_w, world_h]` | Find the nearest active entity within `range` using torus (wrapping) distance. `entities` is a list of dicts with `"px"`, `"py"`, `"active"` keys. Returns `{"index", "dist", "dx", "dy"}` or `null`. Optional extra args: custom key names `[..., px_key, py_key, active_key]`. |
| `nearest_in_range_all` | `nearest_in_range_all of [entities, range, world_w, world_h]` | Like `nearest_in_range`, but returns ALL active entities within `range` (torus distance) as a list, not just the closest. Optional trailing custom key names `[..., px_key, py_key, active_key]`. |

## Audio (additional)

| Name | Signature | Description |
|------|-----------|-------------|
| `audio_sweep` | `audio_sweep of [freq_start, freq_end, duration, amplitude, waveform]` | Generate a frequency sweep with continuous phase. `waveform`: 0=sine, 1=sawtooth. Returns sample list. |
| `audio_play` | `audio_play of samples` | Play a clip once on a free mixer channel (oldest finite channel recycled when all 16 are busy). Returns the channel id, or `0` on bad args / closed device |
| `audio_play_loop` | `audio_play_loop of [samples, loops]` | Play `samples` `loops` times on one mixer channel; `loops == -1` loops forever (the mixer rewinds — no memory multiplication). Returns the channel id, or `0` on bad args / closed device. |
| `audio_volume` | `audio_volume of [channel, vol]` | Live per-channel volume, `0.0`–`4.0`. Returns `1`, or `0` on a bad/inactive channel. |
| `audio_stop` | `audio_stop of channel` | Stop one mixer channel. Returns `1`, or `0` on a bad/inactive channel. |
| `audio_capture_open` | `audio_capture_open of [freq, channels]` | Open the recording (microphone) device and start capturing (#579). Defaults `[44100, 1]`; SDL converts to exactly the requested format. Returns the device id, or `0` when SDL/capture is unavailable. Re-opening closes the previous capture device. Trace-recorded — under `EIGS_REPLAY` no real device is opened. |
| `audio_capture_read` | `audio_capture_read of null` | Drain samples accumulated since the last read as a **buffer** of floats in `[-1, 1]` (interleaved when `channels > 1`). At most 2048 samples per call — loop until the returned buffer is empty to drain fully (keeps each trace record replayable). Empty buffer = nothing new yet; `null` = no capture device open. Trace-recorded — replay serves the recorded samples, never a live microphone. |
| `audio_capture_close` | `audio_capture_close of null` | Stop and close the recording device, dropping undrained samples. Safe to call twice or with no device open. |
| `audio_stream_open` | `audio_stream_open of [freq, channels]` | Open the live streaming playback device (queue mode, F-DS-17 — for on-the-fly synthesis like musical typing). Coexists with the `audio_open` mixer device. Defaults `[44100, 1]`. Returns the device id (`>= 2`), or `0` when SDL/audio is unavailable. Re-opening closes the previous stream device. |
| `audio_stream_push` | `audio_stream_push of samples` | Queue a block of float samples `[-1, 1]` (**list** or **buffer**) onto the live stream. Same size cap / clamp as `audio_play`. Pure output sink (not trace-recorded). Returns `1` on success, `0` on a closed device or bad shape. |
| `audio_stream_queued` | `audio_stream_queued of null` | Samples still buffered (not yet played) on the live stream — the refill pump pushes another block only while this stays under its latency target. Returns `0` when no stream is open. Trace-recorded (a live, timing-dependent value) — replay serves the recorded depth, keeping the session deterministic. |
| `audio_stream_clear` | `audio_stream_clear of null` | Drop any buffered audio on the live stream (flush for a panic / all-notes-off). Safe with no device. |
| `audio_stream_close` | `audio_stream_close of null` | Stop and close the live stream device, dropping buffered audio. Safe to call twice or with no device open. |

## Internal (sanitizer builds only)

| Name | Signature | Description |
|------|-----------|-------------|
| `__borrow_guard_selftest` | `__borrow_guard_selftest of [args...]` | **Not a user builtin.** A planted fault validating the #548 borrow-scan guard: registered only in ASan builds when `EIGS_BORROW_GUARD_SELFTEST` is set, it deliberately returns a borrowed direct child past `VM_BORROW_SCAN_CAP` so the suite can prove the guard aborts loudly (naming the builtin) instead of letting a missed compensating incref become a silent use-after-free. Absent from release builds and from sanitizer builds without the opt-in env var (fuzzers must never reach a deliberate abort). |
