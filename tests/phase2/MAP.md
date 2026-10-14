# tests/phase2/MAP.md: #1758 items to the test rows that pin them

This is the skeleton, committed in round 0 with `docs/design/phase2-numbers.md`.
Round 1 writes each row as `tests/phase2/rows/<id>.eigs` (or `<id>.sh` for a
row that needs a shell: tape, env, files), with its exact expected stdout in
`<id>.out`.

`tools/phase2_check.sh <tag-binary> <branch-binary>` (design: §9.2 of the
design doc) runs every row:
- against the **v0.46.0 tag** (`4a3a5c19`, built from the tag commit, not
  main) and the branch;
- in three tiers: `EIGS_JIT_OFF=1`, the default JIT, and
  `EIGS_JIT_OSR_THRESHOLD=1`.

Every mapped row must FAIL on the tag and PASS on the branch in every tier.

## Format (machine-read by `phase2_check.sh`)

- `### <ITEM>` opens an item. The items are fixed by #1758 Revision 1: `N1`
  to `N14`, `N4b`, `A`, `B`, `T1`, `O1` to `O4`. Every item must have at
  least one row.
- ``- `<row-id>` [Rn] <program sketch>`` is one row. Below it, two more
  lines: `-> <branch stdout>`, and `tag: <behaviour>`.
  A row whose program pins several items lists them in its file header
  (`# ITEMS: O3 T1`); it appears here once, under its first item.
  - The row id is the file stem. Every id must have a file, and every file
    must be listed here.
  - `[Rn]` is the commit of the round plan that makes the row pass on the
    branch.
- In program sketches, ` / ` separates source lines and `{try X catch}` means:
  ```
  try:
      X
  catch e:
      print of [e.kind, ...]
  ```
  The row file holds the exact program.
- `tag:` says why the row fails on v0.46.0:
  - `(probed main)` is output observed on the main-checkout binary (0.46.0,
    built 2026-10-13). Main differs from the tag only by #1740/#1741
    (bitwise and range conversion) and #1735.
  - `(read)` is derived from the tag's source.
- **Controls** (`ctl.*`) must PASS on both binaries. They guard behaviour
  the branch must preserve, and are counted separately: never in
  `tag_fail`.
- **Gates** (`gate.*`) name a check the Done-when runs on its own (the
  observer oracle with `--floor`). `phase2_check.sh` lists them and verifies
  their command exists, but does not run or count them as rows.

---

### N1
- `N1.literal-kind` [R1.3] `print of [num_type of 3, num_type of 3.0, num_type of 1e3, num_type of 0x10]`
  -> `["int", "float", "float", "int"]`
  tag: `num_type` is undefined, an error (read)
- `N1.exact-past-2p53` [R1.3] `print of [9007199254740993, 9223372036854775807]`
  -> `[9007199254740993, 9223372036854775807]`
  tag: `[9007199254740992, 9.223372036854776e+18]` (probed main)
- `N1.decimal-past-int64-is-float` [R1.3] `x is 9223372036854775808 / print of [num_type of x, x]`
  -> `["float", 9.223372036854776e+18]`
  tag: `num_type` undefined (read)
- `N1.hex-wraps` [R1.3] `print of [0x1FFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF]`
  -> `[-1, -1, 9223372036854775807]`
  tag: `[3.6893488147419103e+19, 1.8446744073709552e+19, 9.223372036854776e+18]` (probed main)
- `N1.canon-eq` [R1.3] `a is abs of -5 / b is 0 - 5 / print of [a == 5, -b == 5, num_type of a]`
  -> `[true, true, "int"]`
  tag: `num_type` undefined. **Plant 1's named check**: with small ints boxed, the SMI/boxed-int equality fast path, which relies on canonical form, answers false. The direct witness is `tests/phase2/slot_layer.c`.

### N2
- `N2.int-eq-float-kinds` [R1.3] `print of [1 == 1.0, 1 != 1.0, num_type of 1, num_type of 1.0]`
  -> `[true, false, "int", "float"]`
  tag: `num_type` undefined (read)
- `N2.exact-eq-past-2p53` [R1.3] `print of [9007199254740993 == 9007199254740992.0, 9007199254740993 != 9007199254740992.0]`
  -> `[false, true]`
  tag: `[true, false]` (probed main: the lexer rounds)
- `N2.exact-order` [R1.3] `print of [9007199254740993 > 9007199254740992.0, 9223372036854775807 < 9223372036854775808.0]`
  -> `[true, true]`
  tag: `[false, false]` (probed main for the second)
- `N2.membership-exact` [R1.3] `print of [list_contains of [[9007199254740993], 9007199254740992.0], list_index_of of [[1, 9007199254740993], 9007199254740992.0]]`
  -> `[false, -1]`
  tag: `[true, 1]` (read: everything is a double)
- `N2.sort-exact` [R1.6] `print of (sort of [9007199254740993, 9007199254740992, -1])`
  -> `[-1, 9007199254740992, 9007199254740993]`
  tag: the literal rounds, so `[-1, 9007199254740992, 9007199254740992]` (probed main, same shape)
- `ctl.N2.float-eq` (control) `print of [0.5 + 0.25 == 0.75, 1 == 1.0, 3 < 3.5]`
  -> `[true, true, true]`, both binaries

### N3
- `N3.int-ops-kind` [R1.3] `print of [num_type of (2 + 3), num_type of (7 - 9), num_type of (6 * 7), num_type of (2 + 0.5)]`
  -> `["int", "int", "int", "float"]`
  tag: `num_type` undefined
- `N3.exact-product` [R1.3] `print of [3037000499 * 3037000499, 4503599627370496 * 2 + 1]`
  -> `[9223372030926249001, 9007199254740993]`
  tag: `[9.223372030926249e+18, 9007199254740992]` (probed main)
- `ctl.N3.small-ints` (control) `print of [1 + 2, 10 - 3, 6 * 7, -4]`
  -> `[3, 7, 42, -4]`, both binaries

### A
- `A.add-overflow-raises` [R1.3] `{try print of (9223372036854775807 + 1) catch}`, printing `[e.kind, (index_of of [e.message, "+"]) >= 0]`
  -> `["value", true]`
  tag: prints a rounded double, no raise (read). **Plant 4's named check.**
- `A.sub-overflow-raises` [R1.3] `{try print of (-9223372036854775807 - 2) catch}`, the same print with `"-"`
  -> `["value", true]`
  tag: a double, no raise
- `A.mul-overflow-raises` [R1.3] `{try print of (4611686018427387904 * 2) catch}`, the same print with `"*"`
  -> `["value", true]`
  tag: `9.223372036854776e+18`, no raise
- `A.sum-overflow-raises` [R1.6] `{try print of (sum of [9223372036854775807, 1]) catch}`
  -> `["value", true]`, the message naming `sum`
  tag: a double sum, no raise
- `A.tensor-scalar-overflow-raises` [R1.6] `{try print of (multiply of [4611686018427387904, 2]) catch}`
  -> `["value", true]`
  tag: a double

### B
- `B.type-of-both-num` [R1.3] `print of [type of 3, type of 3.0, (type of 3) == (type of 3.0), num_type of 3]`
  -> `["num", "num", true, "int"]`
  tag: `num_type` undefined
- `ctl.B.type-of` (control) `print of [type of 3, type of 3.0, type of -2]`
  -> `["num", "num", "num"]`, both binaries

### N4
- `N4.div-always-float` [R1.7] `print of [7 / 2, 6 / 2, num_type of (6 / 2)]`
  -> `[3.5, 3.0, "float"]`
  tag: `[3.5, 3, ...]` then `num_type` undefined (probed main for `[3.5, 3]`)
- `N4.floordiv` [R1.4] `print of [7 // 2, -7 // 2, 7.5 // 2, num_type of (7 // 2), num_type of (7.5 // 2)]`
  -> `[3, -4, 3.0, "int", "float"]`
  tag: parse error, `unexpected '/'` (probed main)
- `N4.floor-mod` [R1.4] `print of [-7 % 3, 7 % -3, -7.5 % 2, 7 % 3]`
  -> `[2, -2, 0.5, 1]`
  tag: `[-1, 1, -1.5, 1]`, i.e. fmod (probed main)
- `N4.int-floordiv-zero-raises` [R1.4] `{try print of (7 // 0) catch}`, printing `e.kind`
  -> `value`
  tag: parse error
- `N4.float-div-zero-inf` [R2.2] `print of [1.0 / 0, -1.0 / 0, 1 / 0]`
  -> `[inf, -inf, inf]`
  tag: raises `division by zero` (read)
- `N4.float-zero-div-zero-nan` [R2.2] `x is 0.0 / 0 / print of [x == x, num_type of x]`
  -> `[false, "float"]`
  tag: raises
- `N4.float-mod-zero-nan` [R2.2] `x is 5.5 % 0 / print of (x == x)`
  -> `false`
  tag: raises `modulo by zero`
- `ctl.N4.int-mod-zero-raises` (control) `{try x is 7 % 0 catch}`, printing `e.kind`
  -> `value`, both binaries (probed main)

### N4b
- `N4b.neg-min-raises` [R1.3] `m is -9223372036854775807 - 1 / {try print of (-m) catch}`
  -> `["value", true]`, the message naming the unary minus
  tag: a double, no raise. **Plant 5's named check.**
- `N4b.abs-min-raises` [R1.6] `m is -9223372036854775807 - 1 / {try print of (abs of m) catch}`
  -> `["value", true]`
  tag: `9.223372036854776e+18`, no raise
- `N4b.floordiv-min-by-neg1-raises` [R1.4] `m is ... / {try print of (m // -1) catch}`
  -> `["value", true]`
  tag: parse error
- `N4b.min-mod-neg1-zero` [R1.4] `m is ... / print of [m % -1, num_type of (m % -1)]`
  -> `[0, "int"]`, with no hardware fault (x86 `idiv` faults on `INT64_MIN % -1`)
  tag: `num_type` undefined

### N5
- `N5.substr-fraction-raises` [R1.6] `{try print of (substr of ["hello", 1.5, 2]) catch}`, printing `e.kind`
  -> `value`
  tag: `el` (probed main: truncation)
- `N5.store-key-fraction-raises` [R1.6] `s is store_open of "<tmp>/db" / k is store_put of [s, "c", {"v": 1}] / {try print of (store_get of [s, "c", 1.9]) catch}`
  -> `value`
  tag: returns record "1" (probed main)
- `N5.bitwise-fraction-raises` [R1.5] `{try print of (1.5 | 0) catch}`, printing `e.kind`
  -> `value`
  tag: `1` (the bar critic's probe of the tag; main already raises: #1740)
- `N5.integral-float-converts` [R1.5] `print of [6.0 | 1, num_type of (6.0 | 1), (list_slice of [[1, 2, 3], 1.0, 2.0])]`
  -> `[7, "int", [2]]`
  tag: `num_type` undefined
- `N5.range-fraction-raises` [R1.6] `{try print of (range of 2.5) catch}`, printing `e.kind`
  -> `value`
  tag: no raise (read: `range_bound` accepts any double inside the int range)

### N6
- `N6.float-repr` [R1.7] `print of [3.0, 1e3, -0.0, 0.1 + 0.2, 1e15, 1e16, 1e-05, 0.0001]`
  -> `[3.0, 1000.0, -0.0, 0.30000000000000004, 1000000000000000.0, 1e+16, 1e-05, 0.0001]`
  tag: `[3, 1000, 0, 0.30000000000000004, 1000000000000000, 1e+16, 1e-05, 0.0001]` (probed main for the first seven)
- `N6.int-exact-digits` [R1.7] `print of [9007199254740993, -9223372036854775807 - 1]`
  -> `[9007199254740993, -9223372036854775808]`
  tag: rounded doubles
- `N6.str-fstring` [R1.7] `x is 2.0 / print of [str of x, f"{x}", str of 2]`
  -> `["2.0", "2.0", "2"]`
  tag: `["2", "2", ...]` (probed main)
- `N6.neg-zero-literal-dedup` [R1.7] `a is 0.0 / b is -0.0 / print of [a, b]`
  -> `[0.0, -0.0]`
  tag: `[0, 0]`. (The constant pool dedup folds `-0.0` into `+0.0`, chunk.c:196; the row pins that a literal `-0.0` survives a chunk that also holds `0.0`.)
- `N6.nonfinite` [R2.5] `print of [1.0 / 0, -1.0 / 0, 0.0 / 0, -(0.0 / 0)]`
  -> `[inf, -inf, nan, nan]` (never `-nan`)
  tag: raises
- `ctl.N6.small-ints` (control) `print of [1, 2, 3, -4, 100000]`
  -> `[1, 2, 3, -4, 100000]`, both binaries

### N7
- `N7.num-type-float` [R1.3] `print of [num_type of 3.0, num_type of -0.0, num_type of 1e300, num_type of 2.5]`
  -> `["float", "float", "float", "float"]`
  tag: `num_type` undefined. **Plant 6's named check.**
- `N7.num-type-int` [R1.3] `print of [num_type of 0, num_type of -1, num_type of 9223372036854775807, num_type of (2 * 3)]`
  -> `["int", "int", "int", "int"]`
  tag: undefined
- `N7.num-type-non-number` [R1.3] `print of [num_type of "3", num_type of null, num_type of true, num_type of [1]]`
  -> `[null, null, null, null]` (Lua `math.type` returns fail)
  tag: undefined

### N8
- `N8.bitwise-results-int` [R1.5] `print of [6 & 3, 6 | 3, 6 ^ 3, ~0, num_type of (6 & 3)]`
  -> `[2, 7, 5, -1, "int"]`
  tag: `num_type` undefined
- `N8.lua-shifts` [R1.5] `print of [1 << 64, 1 << 63, 1 << -1, -1 >> 1, 8 >> -1]`
  -> `[0, -9223372036854775808, 0, 9223372036854775807, 16]`
  tag: not this (probed main: `1 << 64` is `1`, `1 << 63` a negative double, `-1 >> 1` is `-1`)
- `N8.bit-builtins-int64` [R1.5] `print of [bit_or of [4611686018427387904, 1], bit_shl of [1, 64]]`
  -> `[4611686018427387905, 0]`
  tag: `4.611686018427388e+18`, ...

### N9
The builtin names are decided in round 1 (`<w-add-i64>` etc. below are placeholders the row files replace).
- `N9.wrapping` [R1.6] `print of [<wrapping add i64> of [9223372036854775807, 1], <wrapping add u8> of [255, 1]]`
  -> `[-9223372036854775808, 0]`
  tag: undefined
- `N9.checked-raises` [R1.6] `{try print of (<checked add u8> of [200, 100]) catch}`
  -> `["value", ...]`
  tag: undefined
- `N9.saturating` [R1.6] `print of [<saturating sub i8> of [-100, 100], <saturating add u64> of [-1, 1]]`
  -> `[-128, -1]`. A u64 is carried in an int64 bit pattern, so u64 max is `-1`.
  tag: undefined
- `N9.unsigned-ops` [R1.6] `print of [<u64 compare> of [-1, 1], <u64 to string> of [-1], <u64 div> of [-1, 2]]`
  -> `[1, "18446744073709551615", 9223372036854775807]`
  tag: undefined
- `N9.fround` [R1.6] `print of (fround of 0.1)`
  -> `0.10000000149011612`
  tag: undefined

### N10
- `N10.partial-refused` [R1.6] `{try print of (num of "12abc") catch}`, printing `e.kind`
  -> `value`
  tag: `12` (probed main)
- `N10.radix` [R1.6] `print of [num of "0x1F", num of "0b101", num of "0o17"]`
  -> `[31, 5, 15]` (the prefix set is decided in round 1; `0x` is certain)
  tag: `[31, 0, ...]` (probed main for the first two)
- `N10.int-or-float` [R1.6] `print of [num_type of (num of "3"), num_type of (num of "3.0"), num_type of (num of "9223372036854775808"), num of "9007199254740993"]`
  -> `["int", "float", "float", 9007199254740993]`
  tag: `num_type` undefined

### N11
- `N11.sqrt-neg-nan` [R2.2] `x is sqrt of -1 / print of [x == x, num_type of x]`
  -> `[false, "float"]`
  tag: raises `sqrt: argument out of domain` (probed main)
- `N11.log-zero` [R2.2] `print of (log of 0)`
  -> `-inf`
  tag: raises `log: argument out of domain` (probed main)
- `N11.no-clamp` [R2.2] `print of [1e308 * 10, 1e308 * 10 == 1e308]`
  -> `[inf, false]`
  tag: `1e+308` then `true` (probed main for the first)
- `N11.strict-opt-in` [R2.2] (sh row, `EIGS_STRICT=1`) `{try print of (1e308 * 10) catch}`
  -> `value`. Default strict off: the same program prints `inf`.
  tag: `1e+308` under either setting (read: the clamp, not a raise)
- `N11.constant-1e308-converges` [R2.2] the #1746 row: a binding assigned the literal `1e308` 12 times; `print of (converged of x)`
  -> `true`
  tag: `false`, because saturation reads as diverging (#861; probed on the #1746 baseline)

### N12
- `N12.f64-bits` [R2.4] `print of [f64_bits of 1.0, f64_bits of -0.0, f64_from_bits of 4607182418800017408]`
  -> `[4607182418800017408, -9223372036854775808, 1.0]`
  tag: undefined
- `N12.nan-canonical-bits` [R2.4] `print of (f64_bits of (0.0 / 0))`
  -> `9221120237041090560` (`0x7FF8000000000000`)
  tag: raises
- `N12.nan-payload-tags` [R2.1/R2.4] for every tag-spelling payload `p` in `0xFFF8000000000000, 0xFFF9000000000001, 0xFFFA000000000005, 0xFFFB000000001000, 0xFFFF000000000000`, `x is f64_from_bits of p`, stored in a variable, a list, a dict and a buffer; print `[type of x, x == x, f64_bits of x]` for each
  -> `["num", false, 9221120237041090560]` five times
  tag: undefined. **Plant 2's named check**, run under the plant build with ASan.
- `N12.payload-through-ints` [R2.4] `i is 9218868437227405313 / print of [f64_bits of (f64_from_bits of i), <buffer bits get> of (<buffer bits set> of [buffer of 1, 0, i])]`
  -> `[9221120237041090560, 9218868437227405313]`. Ints and buffer bits keep the payload; a float does not.
  tag: undefined

### N13
- `N13.json-refuses-inf` [R2.3] `x is 1e308 * 10 / {try print of (json_encode of [x]) catch}`, printing `e.kind`
  -> `value`
  tag: `1e+308`, the clamp (read; a one-element literal list passes its element, #405). **Plant 3's named check.**
- `N13.store-refuses-nan` [R2.3] `x is (1e308 * 10) - (1e308 * 10) / s is store_open of "<tmp>/db" / {try k is store_put of [s, "c", {"v": x}] catch} / print of (store_count of [s, "c"])`
  -> `value` then `0` (refused, and nothing written)
  tag: no raise, so the count is `1` (read: `1e308 - 1e308` is `0`). **Plant 3's second named check.**
- `N13.int-conversion-refuses` [R2.3] `x is 1e308 * 10 / {try print of (substr of ["abc", x, 1]) catch}`
  -> `value`
  tag: no raise (read: `(int)` of a clamped 1e308)

### N14
- `N14.encode-kinds` [R1.7] `print of (json_encode of [3, 3.0, 0.1, -0.0])`
  -> `[3,3.0,0.1,-0.0]`
  tag: `[3,3,0.1,0]` (probed main for the first three)
- `N14.decode-kinds` [R1.7] `v is json_decode of "[3, 3.0, 9223372036854775807, 18446744073709551615]" / print of [num_type of v[0], num_type of v[1], v[2], num_type of v[3]]`
  -> `["int", "float", 9223372036854775807, "float"]`
  tag: `num_type` undefined
- `N14.decode-overflow-raises` [R2.5] `{try print of (json_decode of "1e400") catch}`
  -> `value`
  tag: `1e+308` (read: strtod gives inf, then the clamp)

### T1
- `T1.v7-header` [R1.3] (sh row) `EIGS_TRACE=t.tape eigenscript p.eigs; head -1 t.tape | cut -d' ' -f1-2`
  -> `V 7`
  tag: `V 6`
- `T1.int-float-on-tape` [R1.3] (sh row) record `x is 3 / y is 3.0 / print of [x, y]`; grep the tape's A records for `x=3` and `y=3.0`; replay with `EIGS_REPLAY_STRICT=1`; the output is byte-identical
  -> `A x=3`, `A y=3.0`, `replay identical`
  tag: `A y=3` (read: `%.17g`)
- `T1.int-replay-kind` [R1.3] (sh row) record `r is random_int of [1, 6] / print of [r, num_type of r]`, then replay
  -> the same line twice, kind `"int"` on replay
  tag: `num_type` undefined
- `T1.v6-refused` [R1.3] (sh row) `EIGS_REPLAY=tests/phase2/fixtures/v6.tape eigenscript p.eigs`; print the rc and whether stderr names version 6
  -> `rc!=0 names-6`
  tag: rc 0 (the fixture is its own version). **Plant 7's named check.**
- `T1.nonfinite-on-tape` [R2.5] (sh row) record inf, -inf and nan values; the tape holds the tokens `inf`, `-inf`, `nan`; strict replay is byte-identical
  -> as stated
  tag: the program raises

The `O cfg` record's v7 shape is pinned by `O3.ocfg-no-hlow` (its file lists
`# ITEMS: O3 T1`).

### O1
- `gate.O1.oracle-floor` [R3] for each oracle int row (a counter, doubling to 2^62, an INT64_MIN to INT64_MAX swing), in all three tiers: `make observer-oracle` with `--floor floor.json` exits 0
  -> exit 0
  tag: n/a. This is the oracle gate of #1758 Done-when "Observer", so it is a gate, not a row.
- `O1.where-is-value` [R3] `x is 2.5 / print of (where is x)`
  -> `2.5`
  tag: `0.7219...`, an entropy (probed main: `where is x` after 1 and 4 gives `0.7219280948873623`)

### O2
- `gate.O2.predicate-floors` [R3] the post-#1754 corpus with per-predicate TP/TN floors (`floor.json`, the corpus sha256 recorded)
  -> at or above every floor
  tag: n/a (the floors are measured on the tag), so it is a gate
- `O2.noise-not-oscillating` [R3] a seeded iid noise sequence (±1 around 100, 60 steps, an LCG in the program); `print of (oscillating of x)`
  -> `false`, per #1754's definition (Hardy §62; iid noise is the in-control baseline, not an oscillation)
  tag: `true` (#1746 prior-art report, probe P3: 99.3% of steps read `oscillating`)

### O3
- `O3.ocfg-no-hlow` [R3] (sh row) record any observed program; print the field count of the `O cfg` record
  -> one fewer field than v6: no `h_low`
  tag: has `h_low` (trace.c:1580-1584 writes it)

### O4
- `O4.why-is-displacement` [R3] `x is 1 / x is 4 / print of (why is x)`
  -> `3`, or `3.0` (the int-or-float question is design §11 Q5)
  tag: `-0.2780719051126377`, a dH (probed main)
- `O4.how-is-settledness` [R3] a binding held constant for one window; `print of (how is x)`
  -> the R3 settledness value at full rest (to be fixed by the R3 design)
  tag: an entropy-derived value
