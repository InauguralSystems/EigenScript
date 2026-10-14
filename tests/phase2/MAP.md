# tests/phase2/MAP.md: #1758 items to the test rows that pin them

This is the skeleton, committed in round 0 with `docs/design/phase2-numbers.md`
and revised in design round 2 (row shapes, tier witnesses, the leaf
differential, the record-twice tape rows).
Round 1 writes each row as `tests/phase2/rows/<id>.eigs` (or `<id>.sh` for a
row that needs a shell: tape, env, files), with its exact expected stdout in
`<id>.out`.

`tools/phase2_check.sh <tag-binary> <branch-binary>` (design: §9.2 of the
design doc) runs every row:
- against the **v0.46.0 tag** (`4a3a5c19`, built from the tag commit, not
  main) and the branch;
- in four tiers: `EIGS_JIT_OFF=1`, the default JIT,
  `EIGS_JIT_OSR_THRESHOLD=1`, and `trace` (`EIGS_TRACE=<scratch>/t.tape`,
  default JIT). The leaf evaluator is off under trace, so the `trace` tier is
  the leaf differential: a row must print the same in it as in the others.

Every mapped row must FAIL on the tag and PASS on the branch in every tier,
and its witness must hold on the branch (design §9.1), or it is VACUOUS.

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
  observer oracle with `--floor`, the db parameter test). `phase2_check.sh`
  lists them and verifies their command exists, but does not run or count
  them as rows.
- **Shape and witness.** A row without a `shape:` line is shape `S`
  (straight-line module code, interpreted in every tier, witness `none`).
  The other shapes carry a fourth line, `shape: <L|F|O>  witness: <kind>
  <chunk>... [<OP>]  ops: <OP>...`:
  - `L`: a one-line helper (the leaf evaluator); `F`: a multi-statement
    function called at least 60 times (the function JIT); `O`: a loop, in a
    function or at module level, witnessed in the `osr` tier (OSR).
  - witness kinds (design §9.1): `leaf <fn>` (no `EIGS_JIT_HOT` entries for
    `<fn>` in the normal run, K >= 1 in the `trace` run), `leaf-gen <fn>`
    (the same K >= 1 entries in both: every call took the generic path),
    `fn <fn>` (`jit yes`, `adv RET`), `fn-stop <fn> <OP>` (`jit yes`, the
    op at `adv` is `<OP>`), `osr <chunk>` (`osr yes`, `oent + oadv` past the
    loop's `JUMP_BACK`), `osr-stop <chunk> <OP>` (the op at `oent + oadv` is
    `<OP>`).
  - `leaf` and `leaf-gen` may name several helpers; each must hold.
  - `ops:` lists the opcodes whose JIT or leaf arm the row exercises: run
    natively, or stopped at exactly (a `-stop` witness's `<OP>`, which proves
    the guard or the scanner's refusal of that op). Ops after a stop are not
    listed. `phase2_check.sh` requires the union over all `L`/`F`/`O` rows to
    cover every JIT-emitter and leaf-evaluator arm that holds a numeric site (the
    inventory file's `## Numeric arms` lists them: 15 emitter arms and 5 leaf
    arms today).
  - The witnesses state round 1's expectation. The JIT and the leaf bail on
    an int that meets an arithmetic, comparison, bitwise or index op, or on
    an int literal, until round 5, so such a row's witness is a `-stop` or
    `leaf-gen`: the guard fired and the interpreter produced the output. An
    int that only moves (into a local, a field, a list element or a module
    binding) passes through the JIT's C helpers and the leaf's borrows, so
    those rows' witnesses are native, as are the float rows'.
    `(witness probed main)` marks a witness observed on the main binary
    (with a double where the row passes an int); the others are read from
    design §2.7, §4.1 and §4.5.

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
  tag: `num_type` undefined. (Round 0 named this row as plant 1's check; it cannot see that plant, because everything compares by value (design §2.1). Plant 1's check is `tests/phase2/slot_layer.c`.)
- `N1.leaf-int-literal` [R1.3] `define big(x) as: return 9007199254740993 / define one(x) as: return 1 / print of [big of 0, one of 0]`
  -> `[9007199254740993, 1]`
  tag: `[9007199254740992, 1]` (probed main, all three tiers)
  shape: L  witness: leaf-gen big one (the leaf scanner refuses `OP_INT_CONST` and `OP_INT_ONE`)  ops: INT_CONST INT_ONE
- `N1.leaf-float-literal` [R1.7] `define onef(x) as: return 1.0 / define zerof(x) as: return 0.0 / define halff(x) as: return 0.5 / print of [onef of 7, zerof of 7, halff of 7]`
  -> `[1.0, 0.0, 0.5]` (the leaf's `NUM_ONE`, `NUM_ZERO` and `CONST` keep their float meaning)
  tag: `[1, 0, 0.5]` (probed main)
  shape: L  witness: leaf onef zerof halff (witness probed main: no entries normally, 1 each under trace)  ops: NUM_ONE NUM_ZERO CONST
- `N1.leaf-dot-get` [R1.3] `define px(p) as: return p.x / d is {"x": 9007199254740993} / print of (px of d)`
  -> `9007199254740993` (an int field is borrowed through the leaf with no arithmetic, so the leaf computes it even in round 1)
  tag: `9007199254740992` (probed main)
  shape: L  witness: leaf px (witness probed main: no entries normally, 1 under trace)  ops: LOCAL_DOT_GET
- `N1.fn-float-literals` [R1.7] `define f(a) as: t is a * 1.0 / u is t + 0.0 / return u`, called 60 times with `2.0`; print the last result
  -> `2.0` (the JIT's `NUM_ONE`/`NUM_ZERO` emitters keep their float meaning)
  tag: `2` (probed main)
  shape: F  witness: fn f (witness probed main: `f 60 yes ... RET`)  ops: NUM_ONE NUM_ZERO MUL ADD
- `N1.fn-int-literal` [R1.3] `define g(a) as: t is a + 1 / return t * 2`, called 60 times with `9007199254740992`; print the last result
  -> `18014398509481986`
  tag: `18014398509481984` (probed main)
  shape: F  witness: fn-stop g INT_ONE (the JIT scanner refuses the new opcode)  ops: INT_ONE
- `N1.fn-dot-fields` [R1.3] `define setx(p, q) as: p.x is q / return p.x`, called 60 times with `[{"x": 1}, 9007199254740993]` (a fresh dict each time); print the last result
  -> `9007199254740993` (the field store and load take their C helpers for a non-double and the thunk runs on)
  tag: `9007199254740992` (probed main)
  shape: F  witness: fn setx (witness probed main, with a double: `setx 60 yes ... RET`)  ops: LOCAL_DOT_SET LOCAL_DOT_GET
- `ctl.N1.fn-int-truthiness` (control) `define truth(a) as: if a: return 1 / return 2`, called 60 times with `0`; `print of [truth of 0, truth of 5, truth of 0.0]`
  -> `[2, 1, 2]` on both (0 and 0.0 are falsy)
  shape: F  witness: fn-stop truth JUMP_IF_FALSE (an SMI condition fails the bool and number checks; on main a double 0.0 instead leaves at the jump target, 21)  ops: JUMP_IF_FALSE
- `ctl.N1.fn-int-not` (control) `define neg(a) as: r is not a / return r`, called 60 times with `0`; `print of [neg of 0, neg of 5, neg of 0.0]`
  -> `[true, false, true]` on both
  shape: F  witness: fn-stop neg NOT (an SMI fails NOT's number check)  ops: NOT
- `N1.fn-int-local` [R1.3] `define keep(q) as: t is q / return t`, called 60 times with `9007199254740993`; print the last result
  -> `9007199254740993` (an int stored into a local takes `SET_LOCAL`'s generic swap and the thunk runs on)
  tag: `9007199254740992` (probed main)
  shape: F  witness: fn keep (witness probed main, with a double: `keep 60 yes ... RET`)  ops: SET_LOCAL POP
- `N1.osr-module-int-store` [R1.3] module-level `big is 9007199254740993 / x is 0 / i is 0.0 / loop while i < 100.0: (x is big / i is i + 1.0) / print of x`
  -> `9007199254740993`
  tag: `9007199254740992` (probed main)
  shape: O  witness: osr <module> (witness probed main: `osr yes`, `oent 55`, `oadv 59`, 114 past `JUMP_BACK` at 111)  ops: SET_NAME LT ADD
- `N1.osr-int-counter` [R1.3] `define count(n) as: i is 9007199254740990 / k is 0 / loop while k < n: (i is i + 1 / k is k + 1) / return i`; `print of (count of 10)`
  -> `9007199254741000`
  tag: `9007199254740992`: the double counter stalls at 2^53 (probed main)
  shape: O  witness: osr-stop count LT (the SMI `k` fails LT's operand guard)  ops: LT

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
- `N2.fn-exact-compare` [R1.3] `define lt(a, b) as: t is a < b / return t`, called 60 times with `[9007199254740992, 9007199254740993]`; print the last result
  -> `true`
  tag: `false` (probed main)
  shape: F  witness: fn-stop lt LT (a boxed int fails the operand guard)  ops: LT
- `N2.fn-compare-all` [R1.3] `define cmp(a, b) as: e is a == b / n is a != b / g is a > b / l is a <= b / q is a >= b / return [e, n, g, l, q]`, called 60 times with `[9007199254740993, 9007199254740992.0]`; print the last result
  -> `[false, true, true, false, true]` (N2's exact cross-kind compare)
  tag: `[true, false, false, true, true]` (probed main)
  shape: F  witness: fn-stop cmp EQ (a boxed int fails the first comparison's guard)  ops: EQ
- `ctl.N2.fn-float-compare` (control) `define ltf(a, b) as: t is a < b / return t`, called 60 times with `[0.5, 0.75]`
  -> `true` on both
  shape: F  witness: fn ltf (witness probed main: `ltf 60 yes ... RET`)  ops: LT
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
- `N3.leaf-mul-exact` [R1.3] `define sq(x) as: return x * x / print of (sq of 94906267)`
  -> `9007199515875289`
  tag: `9007199515875288` (probed main; the critic's gdb probe shows the leaf computed it there)
  shape: L  witness: leaf-gen sq (an SMI operand makes the leaf's MUL bail)  ops: MUL
- `N3.leaf-add-exact` [R1.3] `define add2(a, b) as: return a + b / print of (add2 of [9007199254740992, 1])`
  -> `9007199254740993`
  tag: `9007199254740992` (probed main)
  shape: L  witness: leaf-gen add2  ops: ADD
- `ctl.N3.leaf-float` (control) `define sqf(x) as: return x * x / print of (sqf of 1.5)`
  -> `2.25` on both
  shape: L  witness: leaf sqf (witness probed main: no entries normally, 1 under trace)  ops: MUL
- `N3.fn-arith-exact` [R1.3] `define f(a, b) as: t is a * b / u is t + a / return u - b`, called 60 times with `[94906267, 94906267]`; print the last result
  -> `9007199515875289`
  tag: `9007199515875288` (probed main)
  shape: F  witness: fn-stop f MUL  ops: MUL
- `N3.osr-sum-exact` [R1.3] `define total(n) as: acc is 9007199254740000 / i is 0 / loop while i < n: (acc is acc + 1 / i is i + 1) / return acc`; `print of (total of 1000)`
  -> `9007199254741000`
  tag: `9007199254740992`: the double sum stalls at 2^53 (probed main)
  shape: O  witness: osr-stop total LT  ops: LT
- `N3.osr-module-sum` [R1.3] module-level `acc is 9007199254740000 / i is 0 / loop while i < 1000: (acc is acc + 1 / i is i + 1) / print of acc`
  -> `9007199254741000`
  tag: `9007199254740992` (probed main)
  shape: O  witness: osr-stop <module> INT_CONST (the OSR scanner stops at the literal `1000`)  ops: INT_CONST
- `ctl.N3.osr-float` (control) `define totalf(n) as: acc is 0.5 / i is 0.0 / loop while i < n: (acc is acc + 1.5 / i is i + 1.0) / return acc`; `print of (totalf of 100.0)`
  -> `150.5` on both
  shape: O  witness: osr totalf (witness probed main: `osr yes`, `oent 33`, `oadv 57`; 90 is past `JUMP_BACK` at 87)  ops: LT ADD NUM_ONE CONST JUMP_IF_FALSE SET_LOCAL POP

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
- `A.leaf-mul-overflow` [R1.3] `define sq(x) as: return x * x / {try print of (sq of 3037000500) catch}`, printing `e.kind`
  -> `value` (the leaf bails; the generic path raises with the caller's line)
  tag: `9.22337203700025e+18`, no raise (probed main)
  shape: L  witness: leaf-gen sq  ops: MUL
- `A.fn-add-overflow` [R1.3] `define inc(a) as: t is a + 1 / return t`, called 60 times with small ints, then `{try print of (inc of 9223372036854775807) catch}`, printing `e.kind`
  -> `value`
  tag: `9.223372036854776e+18`, no raise (probed main)
  shape: F  witness: fn-stop inc INT_ONE  ops: INT_ONE
- `A.osr-double-overflow` [R1.3] `define dbl(n) as: x is 1 / i is 0 / loop while i < n: (x is x * 2 / i is i + 1) / return x`; `{try print of (dbl of 63) catch}`, printing `e.kind`
  -> `value` (2^63 overflows on the 63rd doubling)
  tag: `9.223372036854776e+18`, no raise (probed main)
  shape: O  witness: osr-stop dbl LT  ops: LT

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
- `N4.fn-floor-mod` [R1.4] `define m(a, b) as: t is a % b / return t`, called 60 times with `[-7, 3]`; `print of [r, m of [-7.5, 2]]`
  -> `[2, 0.5]` (floor modulo for an int and a float)
  tag: `[-1, -1.5]` (probed main)
  shape: F  witness: fn-stop m MOD (the JIT scanner refuses MOD in round 1)  ops: MOD
- `N4.fn-div-float` [R1.7] `define d(a, b) as: t is a / b / return t`, called 60 times with `[6, 2]`; print the last result
  -> `3.0`
  tag: `3` (probed main)
  shape: F  witness: fn-stop d DIV (SMI operands fail DIV's operand guard)  ops: DIV

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
- `N4b.fn-neg-min` [R1.3] `define n(a) as: t is -a / return t`, called 60 times with small ints, then `m is -9223372036854775807 - 1 / {try print of (n of m) catch}`, printing `e.kind`
  -> `value`
  tag: `9.223372036854776e+18`, no raise (probed main)
  shape: F  witness: fn-stop n NEG  ops: NEG

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
- `N5.leaf-buffer-index` [R1.7] `define bat(b, i) as: return b[i] / b is buffer of 3 / print of (bat of [b, 1])`
  -> `0.0` (a buffer element is an f64, Q2)
  tag: `0` (probed main)
  shape: L  witness: leaf-gen bat (an SMI index makes the leaf's INDEX_GET bail in round 1)  ops: INDEX_GET
- `ctl.N5.leaf-float-index` (control) `define nth(xs, i) as: return xs[i] / print of (nth of [[10, 20, 30], 1.0])`
  -> `20` on both (an integral float index converts, N5)
  shape: L  witness: leaf nth (witness probed main: no entries normally, 1 under trace)  ops: INDEX_GET
- `N5.osr-index-set` [R1.3] `define fill(big, n) as: xs is [0, 0, 0, 0] / i is 0.0 / loop while i < n: (xs[i] is big / i is i + 1.0) / return xs`; `print of (fill of [9007199254740993, 4.0])`
  -> `[9007199254740993, 9007199254740993, 9007199254740993, 9007199254740993]` (an integral float index converts, N5; the int value is stored exactly)
  tag: four times `9007199254740992` (probed main)
  shape: O  witness: osr fill (the float counter keeps the loop native; the boxed int value takes `INDEX_SET`'s C helper; witness probed main with a double: `osr yes`, `oent 37`, `oadv 54`, 91 past `JUMP_BACK` at 88)  ops: INDEX_SET LT ADD

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
- `N8.fn-bitwise` [R1.5] `define b(a, c) as: t is a & c / return t`, called 60 times with `[9007199254740993, 9007199254740993]`; print the last result
  -> `9007199254740993`
  tag: `9007199254740992` (probed main)
  shape: F  witness: fn-stop b BAND (the JIT scanner refuses the bitwise ops in round 1)  ops: BAND
- `N8.fn-bitwise-all` [R1.5] `define bits(a, c) as: o is a | c / x is a ^ c / l is a << 1 / r is a >> 1 / n is ~a / return [o, x, l, r, n]`, called 60 times with `[9007199254740993, 2]`; print the last result
  -> `[9007199254740995, 9007199254740995, 18014398509481986, 4503599627370496, -9007199254740994]`
  tag: `[9007199254740994, 9007199254740994, 18014398509481984, 4503599627370496, -9007199254740992]` (probed main)
  shape: F  witness: fn-stop bits BOR (the scanner refuses the bitwise ops)  ops: BOR

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
- `N11.fn-overflow-inf` [R2.5] `define big(a) as: t is a * 10.0 / return t`, called 60 times with `1e308`; print the last result
  -> `inf` (an inf result is not a NaN, so the JIT keeps it native)
  tag: `1e+308`, the clamp (probed main)
  shape: F  witness: fn big  ops: MUL CONST

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
- `N12.fn-nan-canonical` [R2.4] `define nz(a) as: t is a - a / return t`, called 60 times with `x is 1e308 * 10`; `print of (f64_bits of (nz of x))`
  -> `9221120237041090560` (the JIT bails on the NaN result; the interpreter's single writer canonicalizes)
  tag: `f64_bits` undefined
  shape: F  witness: fn-stop nz SUB  ops: SUB
- `N12.leaf-nan-canonical` [R2.4] `define dif(a, b) as: return a - b / x is 1e308 * 10 / print of (f64_bits of (dif of [x, x]))`
  -> `9221120237041090560` (computed in the leaf, written through `slot_from_f64`)
  tag: `f64_bits` undefined
  shape: L  witness: leaf dif  ops: SUB

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
- `N14.store-exact-digits` [R1.7] `s is store_open of "<tmp>/db" / k is store_put of [s, "c", {"v": 1234567890123456, "f": 0.1 + 0.2, "t": 9007199254740991}] / r is store_get of [s, "c", 1] / print of [r["v"] == 1234567890123456, r["f"] == 0.1 + 0.2, r["t"] == 9007199254740991]`
  -> `[true, true, true]`
  tag: `[false, false, false]`: the record encoder's `%.15g` (#1762's reproduction, identical on main and the tag)
- `gate.N14.db-param-exact` [R1.7] `make db-params-test`: `tests/test_db_params.c` drives `db_build_query` without a server; its number rows bind `1234567`, `9007199254740993` and `0.1 + 0.2`
  -> each bound as exact text (`1234567`, `9007199254740993`, `0.30000000000000004`)
  tag: n/a (a C test, not a program); today's `"%g"` binds `1.23457e+06` (#1762). It needs no PostgreSQL server, so it runs in CI as a gate.

### T1
- `T1.v7-header` [R1.3] (sh row) `EIGS_TRACE=t.tape eigenscript p.eigs; head -1 t.tape | cut -d' ' -f1-2`
  -> `V 7`
  tag: `V 6`
- `T1.twice-int` [R1.3] (sh row) the Done-when's "record twice": record `define sq(x) as: return x * x / x is 9007199254740993 / y is sq of 94906267 / print of [x, y]` twice (`EIGS_TRACE=t1.tape`, then `t2.tape`); print whether `cmp t1.tape t2.tape` finds them identical; replay `t1.tape` with `EIGS_REPLAY_STRICT=1` and print whether its stdout byte-equals the live run's (the live run computes `sq` in the leaf, the recording on the generic path); print the A records for `x` and `y`
  -> `tapes identical`, `replay identical`, `A 0 x=9007199254740993`, `A 0 y=9007199515875289`
  tag: `A 0 x=9007199254740992`, `A 0 y=9007199515875288` (the tape machinery is deterministic today: two recordings of a program without randomness differ only in recorded nondeterminism, probed main)
- `T1.twice-float` [R1.7] (sh row) the same procedure for `x is 3.0 / y is 0.1 + 0.2 / z is -0.0 / print of [x, y, z]`
  -> `tapes identical`, `replay identical`, `A 0 x=3.0`, `A 0 y=0.30000000000000004`, `A 0 z=-0.0` (the kind on the tape; the exact text is N6's, R1.7)
  tag: `A 0 x=3` and `A 0 z=-0` (read: `%.17g`)
- `T1.int-replay-kind` [R1.3] (sh row) record `r is random_int of [1, 6] / print of [r, num_type of r]`, then replay
  -> the same line twice, kind `"int"` on replay
  tag: `num_type` undefined
- `T1.v6-refused` [R1.3] (sh row) `EIGS_REPLAY=tests/phase2/fixtures/v6.tape eigenscript p.eigs`; print the rc and whether stderr names version 6
  -> `rc!=0 names-6`
  tag: rc 0 (the fixture is its own version). **Plant 7's named check.**
- `T1.twice-inf` [R2.5] (sh row) the same procedure for `x is 1e308 * 10 / y is -x / print of [x, y]`
  -> `tapes identical`, `replay identical`, `A 0 x=inf`, `A 0 y=-inf`
  tag: `A 0 x=1e+308` (the clamp)
- `T1.twice-nan` [R2.5] (sh row) the same procedure for `x is (1e308 * 10) - (1e308 * 10) / print of (x == x)`
  -> `tapes identical`, `replay identical`, `A 0 x=nan`
  tag: `A 0 x=0` (the clamp, then `inf - inf` collapses to 0)

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
  -> `3`: an int, because Δv fits int64 (Q5, decided)
  tag: `-0.2780719051126377`, a dH (probed main)
- `O4.how-is-settledness` [R3] a binding held constant for one window; `print of (how is x)`
  -> the R3 settledness value at full rest (to be fixed by the R3 design)
  tag: an entropy-derived value
