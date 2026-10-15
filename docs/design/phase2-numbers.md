# Phase 2 numbers (#1758): design (round 0, revised in design rounds 2 and 3)

Status: the last design round before round 1 builds. Nothing here changes
`src/`. Spec: issue #1758 (Revision 1), its owner decisions (A), (B), (C), the
Q1-Q6 decisions
([comment](https://github.com/InauguralSystems/EigenScript/issues/1758#issuecomment-6171744498))
and the Q7-Q8 decisions
([comment](https://github.com/InauguralSystems/EigenScript/issues/1758#issuecomment-6174302316)).
Evidence base: issue #1746 and the `exp-ieee-p1` branch (canonical NaN, the
single slot writer, the JIT bailing on NaN, refusal inside writers).

Tree measured: `phase2-numbers` at `0740af03` (main, v0.46.0-8). The tag the
Done-when means is `v0.46.0` = `4a3a5c19`.

Companion artifacts:
- `tools/phase2_inventory.py`: the site inventory, the executor matrix, the
  slot-classifier derivation, and the builtin-table check. It writes
  `docs/design/phase2-inventory.txt`.
- `tests/phase2/MAP.md`: every N, O and T item mapped to planned rows, with
  row shapes and tier witnesses.

**What design round 2 changed** (after the blind critic's FAIL on round 0):
- The third numeric evaluator, `vm_leaf_accessor_exec` (vm.c:1856, scanner
  chunk.c:1072, #366), is in the inventory (§1), the JIT/leaf section (§4.5)
  and the map (§7), with every arm, and it gets its own gate (§9.2).
- Every meaning change now coincides with a token change (§2.7). Int
  literals get new opcodes; `OP_NUM_ZERO`/`OP_NUM_ONE` keep their float
  meaning; `slot_as_double` is deleted in R1.1.
- The compile-forced count is re-measured with clang's `unavailable`
  attribute under three configurations (§2.3a), and every site that does
  not stop compiling is classified.
- The slot classifiers are derived, not listed (§2.5), and raw union-member
  reads are in the vocabulary.
- The canonical-form invariant is corrected (§2.1): the lifts box on purpose.
- The builtin table follows the decided Q1 (§6), with the LOSS rows #1762
  found; §11 records Q1-Q6 as decided.
- The test plan has row shapes and tier witnesses (§9).

**What design round 3 changed** (after the critic's FAIL on round 2):
- The `osr` witness proves the loop BODY ran natively: every OSR row is a
  `loop while true:` whose only exit is a `return` right after the claimed
  ops, and the witness requires the OSR record to reach the return sentinel
  (§9.1). Every witness kind now has a negative plant, calibrated on main
  (§9.2); the old form passed a plant with 0 native `INDEX_SET` calls.
- R1.2 is behaviour-preserving and stays so: the builtin readers and
  producers are a named BRIDGE that R1.6 deletes, so every builtin behaviour
  change coincides with a token change, and a per-builtin behaviour table
  gates R1.6 (§2.7, §8, §9.4). The first int value appears at R1.3, and
  §8 lists every consumer converted in that commit.
- `phase2_check.sh --through Rk` checks a round against exactly the rows that
  have landed; R1.1 and R1.2 are mechanical rounds with named gates (§9.2).
- The observer's boxed-int path is mapped and routed (§7, MAP
  `O1.int-observed-numeric`).
- `buffer_read_num` is renamed in R1.6, so the index reads (`gather`,
  `scatter_add`) and the byte reads (`buf_from_pcm16le` and the byte
  consumers) are re-decided there; the compile count is re-measured under the
  Makefile's exact flags and attributed per commit (§2.3a).
- Q7 and Q8 are decided and folded in: a validated `q7` column in the builtin
  table, a geometry reader that clips the whole shape, and IEEE `totalOrder`
  for sorting with NaN propagating through `min`/`max` (§2.6, §6, §11).

Contents:
1. The inventory
2. Representation
3. Measured prototype
4. The JIT and the leaf evaluator
5. N12 and SMI share the NaN space
6. Builtin classification
7. Semantics-to-sites map
8. Round plan
9. Test plan
10. Lua differential tool
11. Decided questions (Q1-Q8)

---

## 1. The inventory

`python3 tools/phase2_inventory.py` prints `examined=1798 classified=1798
unclassified=0` on this tree and writes every site to
`docs/design/phase2-inventory.txt` (file:line, enclosing function, token,
syntactic kind, category).

**Population.** A site is one occurrence, outside comments and string
literals, of a token of the value model's numeric vocabulary in `src/*.c` and
`src/*.h`. The vocabulary is:
- the type tag `VAL_NUM` and the slot predicates;
- the raw and checked payload accessors and the constructors;
- the raw union members themselves: `.d_` / `->d_` (the slot's double) and
  `.num_` / `->num_` (the Value's double). Inside their three accessor
  macros (`SLOT_NUM_RAW`, `VAL_NUM_RAW`, `VAL_NUM_OFFSET`) they are RAW
  sites; anywhere else they are a `BYPASS`, which the script leaves
  unclassified, so the run fails. This closes the blind spot the critic's
  plant `e_blind_member` (`static double p2_plant_blind(EigsSlot s) {
  return s.d_; }` appended to vm.c) showed: the round-0 oracle stayed green
  on it. The repo's own `tools/num_read_check.sh` (#1637) already refuses
  such a bypass in CI; the inventory now sees it too;
- the clamp (`num_guard`) and the number formatter;
- the double parsers (`strtod`, `atof`);
- the AST literal fields (`AST_NUM`, `data.num`, `num_val`);
- in the JIT files only, the tag-range immediates (`0xFFF8`..`0xFFFF`) and the
  emitters that assume a double (`emit_load_numeric_operand`, the `*sd`
  arithmetic, `cvt*`, `fmod`, ...). The JIT's guards compare raw tag bits and
  name no vocabulary token, so without these the JIT category would hold 40
  sites instead of 127.

**Attribution.** Each site carries its enclosing function. Inside the five
opcode dispatchers it also carries its arm:
- `vm_run_ex` (the interpreter): `CASE(X)`. A macro whose body spells
  `CASE(<its first parameter>)` generates an arm at each invocation, closed
  over chains (`INT_BINOP` -> `INT_BINOP_R` -> `CASE(NAME)`), so
  `NUM_BINOP(SUB, ...)` and `NUM_CMP(LT, ...)` are interpreter arms too;
- `jit_supported_prefix` and `jit_compile_to_thunk` (the JIT scanner and
  emitter): the `if (op == OP_X || ...)` chain, named by its first opcode;
- `chunk_scan_leaf_accessor` and `vm_leaf_accessor_exec` (the leaf scanner
  and evaluator): the `case` labels at the dispatch switch's own depth,
  grouped labels joined (`OP_ADD|OP_SUB|OP_MUL`).

**The key and its blind spot.** The key is the token, so code that handles a
number without naming one is invisible. Four derived checks bound that, and
each can fail the run:
1. Every function that returns or writes out a `double` and whose body
   performs a payload read is a numeric accessor. It must be in the
   vocabulary (its call sites then count as sites) or in a reviewed
   `WRAPPERS` list with a reason. 17 such functions exist. 11 are in the
   vocabulary and 6 are wrappers, for example `tensor_to_flat`, whose
   per-element read is the site.
2. Every `VAL_NUM`/`AST_NUM` must sit in a recognized syntactic position:
   test, case, tag store, type yield, data, or emitter immediate. An
   unrecognized position (for example `1u << VAL_NUM`) is unclassified.
3. **The executor matrix** (`## Executors` in the inventory file). For every
   opcode, the roles that implement it: `interp`, `jit_scan`, `jit_emit`,
   `leaf_scan`, `leaf_exec`. The leaf scanner and the leaf evaluator must
   admit exactly the same opcodes, in both directions (a scanner arm with no
   evaluator arm, or the reverse, fails the run). Today both hold the same
   11: `LINE`, `CONST`, `NUM_ZERO`, `NUM_ONE`, `GET_LOCAL`, `LOCAL_DOT_GET`,
   `INDEX_GET`, `ADD`, `SUB`, `MUL`, `RETURN`. So `OP_NUM_ZERO` and
   `OP_NUM_ONE` have three executors (interpreter vm.c:3257, JIT emitter
   jit.c:2797, leaf evaluator vm.c:1872) and two scanners; the round-0 draft
   named two executors.
4. **The slot classifiers** (`## Slot classifiers`). Every function, or
   dispatcher arm, that tests, dereferences or types an `EigsSlot`, by the
   tokens it names:
   - D1: it names a number test (`slot_is_num`, `slot_is_numeric`,
     `slot_as_double`). All three are renamed or deleted, so the compiler
     forces every D1 entry (58 today);
   - D2: it dereferences (`slot_as_ptr`, `slot_as_heap`, `eigs_slot_ref`)
     without a number test (20);
   - D3: it tests other tags or raw tag bits (23);
   - T: it only reads a slot's `ValType` (`slot_type`, `list_elem_type`,
     `dict_value_type`), 67. A comparison with `VAL_NUM` is compile-forced;
     a comparison with another enumerator is unaffected by ints; a switch is
     forced by `-Werror=switch`.

   Every D2 and D3 entry needs a reviewed row in §2.5's table, with a
   disposition from a fixed set. A missing row and a stale row each fail the
   run. The three classifiers the critic found outside round 0's rule
   (`eigs_slot_ref`, `obs_slot_observable`, `slot_type_name`) are D2/D3
   entries of this derivation.

Also outside the population:
- `src/freestanding/` (`mini_strtod.c`, `mini_fmt.c`), which N1, N6 and N10
  must also reach for the EigenOS profile; the round plan names it;
- code that computes on a double after a counted read extracted it.

**Categories** (one per site; the first matching rule wins). Role rules,
keyed by file or function, come first; otherwise the token's own kind
decides (a)/(b)/(c)/(e).

| | category | sites | kinds |
|---|---|---:|---|
| a | type tests | 384 | TEST 327, CASE 52, DATA 3, YIELD 2 |
| b | payload reads | 530 | READ 414, RAW 116 |
| c | producers | 472 | PRODUCE 373, GUARD 71, WRITE 22, PARSE 3, TAGSET 3 |
| d | JIT emitters and guards | 127 | EMIT 89, RAW 27, PRODUCE 6, TEST 2, GUARD 1, TAGSET 1, WRITE 1 |
| e | number formatting | 14 | |
| f | equality, ordering and hashing | 27 | |
| g | tape encode and decode | 20 | |
| h | JSON, store and db encoders | 70 | |
| i | observer numeric paths | 90 | |
| j | embed API | 64 | |
| | **total** | **1798** | |

`WRITE` is `VAL_NUM_RAW(v) = x`, the NUM_REUSE in-place writes the brief
names as producers. Design round 2 added 25 sites: the raw members inside
their three accessor macros (`RAW`, 3) and `buffer_read_byte`, the byte
reader Q1 changes (`READ`, 22).

Largest files: builtins.c 319, vm.c 304, ext_gfx.c 250, builtins_tensor.c
184, builtins_buf.c 97, jit.c 96. The per-file and per-token tables are in
the inventory file.

**The brief's headline figures, re-measured.** The brief says ~420 `VAL_NUM`,
366 `make_num` and 274 argument reads. Outside comments and literals this
tree has:
- `VAL_NUM` 329, plus `VAL_NUM_RAW` 92;
- `make_num` 368;
- argument and element reads 357 (`eigs_num_arg` 145, `eigs_list_num` 130,
  `eigs_slot_num` 52, the optional and element forms 30).

**Builtins.** The registration table is derived from the
`env_set_local_owned(env, "name", make_builtin(fn))` lines plus the
`ext_names.h` X-lists. It holds 311 names, and it was calibrated once against
the runtime's own `eigenscript --api --json` (223 core + 88 extension = 311;
equal in both directions). A builtin is numeric when a site is contained in
its function, in a same-file function it calls or names as a value (a
comparator, an op-table entry; closure depth 4), or in the shared formatter
or equality it calls. That gives 230 numeric builtins, and §6
classifies every one. (The closure does not follow a call into another
file, so a header helper that reads a number must itself be in the
vocabulary for its callers to count: `buffer_read_byte` entered the
vocabulary this round, which made `ppu_render_frame` numeric. A one-off scan
of every header inline and every exported function that reads a number and
returns something other than a double found no other such reader: the rest
return a status (`jit_helper_*`, the observer), a slot (`slot_from_value`,
the container writers) or a truth value (`is_truthy`,
`slot_truthy_immediate`).) The script fails if a numeric builtin has no
row, a row names no numeric builtin, a class or loss mark is not one of the
allowed tokens, or a `LOSS` row has no double path in its closure.

**Calibration: every check turns red on its plant.** Each plant runs
against a scratch copy of `src/` and of this document (`--src`, `--doc`,
`--no-write`), never the worktree; the unplanted copy passes first. All 20
were KILLED on this tree, each by its own FAIL line:

| plant | mutation | the red line |
|---|---|---|
| A | `1u << VAL_NUM` appended to vm.c | `UNCLASSIFIED: ... VAL_NUM (VAL_NUM/AST_NUM in an unrecognized position)` |
| B | a new function returning `VAL_NUM_RAW(v)` | `UNCLASSIFIED: ... p2_plant_read (reads a payload and returns/writes a double; not in VOCAB or WRAPPERS)` |
| C | a registered numeric builtin with no row | ``numeric builtin `p2plant` ... has no classification row`` |
| D | class `integer` | `` `abs` has unknown class 'integer' `` |
| E | loss mark `maybe` | `` `type` has unknown loss mark 'maybe' `` |
| F | a row for a non-numeric builtin | ``classification row `keys` names no numeric registered builtin`` |
| G | `LOSS` on a builtin with no double path | `` `type` is marked LOSS but its closure has no double-path token `` |
| H | a row without backticks | `unparsed table line: \| type \| other ...` |
| I | the JIT files removed | `role rule 0 (d ...) matched no site` |
| J | an empty source tree | `examined=0 classified=0` (fails) |
| K | a VOCAB token that never occurs | `VOCAB token never occurs: p2_never_token` |
| L | the `abs` row deleted | ``numeric builtin `abs` ... has no classification row`` |
| M | the critic's `e_blind_member`: `static double p2_plant_blind(EigsSlot s) { return s.d_; }` | `UNCLASSIFIED: vm.c:6733 p2_plant_blind d_ (raw union member outside its accessor macro)` |
| N | the leaf scanner admits `OP_DIV` | `leaf scanner admits OP_DIV but the leaf evaluator has no arm` |
| O | a new function returning `slot_as_ptr(s)` | ``slot classifier `vm.c:p2_plant_deref` has no disposition row`` |
| P | a disposition row for a function that does not exist | ``disposition row `vm.c:p2_gone` names no D2/D3 slot classifier`` |
| Q | disposition `fine` | `` `vm.c:slot_type_name` has unknown disposition 'fine' `` |
| R | `vm_leaf_accessor_exec` renamed | `dispatcher vm_leaf_accessor_exec (leaf_exec) attributed no opcode arm` |
| S | `gfx_clear`'s `q7` column set to `size` | `` `gfx_clear` has a bad Q7 column 'size' (want `-` or an ordered subset of geometry,bounded,magnitude) `` |
| T | `gfx_clear`'s `q7` column set to `-` (its note says continuous) | `` `gfx_clear`: Q7 column '-' disagrees with its note (a continuous parameter must be named in both) `` |

M is the critic's plant verbatim; on the round-0 oracle it stayed green. (On
its first run the plant driver reported T as SURVIVED although the gate
exited 1 with the right FAIL line: the driver's expected-message pattern
did not allow for the quotes around `-`. The pattern was fixed and T
re-run; the gate was never green on it.)

---

## 2. Representation

### 2.1 What every alternative shares: the slot

`EigsSlot` stays a NaN-boxed 64-bit word (`src/value_slot.h`).

| bits (high 16) | meaning |
|---|---|
| `< 0xFFF8` | a double (`slot_is_num` today) |
| `0xFFF8` | null |
| `0xFFF9` | bool |
| `0xFFFA` | **SMI: an int in [-2^47, 2^47), 48-bit two's complement payload** (reserved today, unused) |
| `0xFFFB` | heap pointer; **an int outside the SMI range is a heap-boxed int64 here** |
| `0xFFFC`-`0xFFFE` | reserved |
| `0xFFFF` | sentinel |

- SMI encode: `s.u = 0xFFFA000000000000 | ((uint64_t)i & 0x0000FFFFFFFFFFFF)`.
- SMI decode, sign-extending bit 47 portably:
  `(int64_t)((s.u & PAYLOAD) ^ 0x800000000000) - 0x800000000000`.
  The `(int64_t)(u << 16) >> 16` form relies on implementation-defined right
  shifts.
- Adding or subtracting two SMIs cannot overflow int64 (|a ± b| < 2^48), so
  round 1 computes those in int64 and range-checks the result into SMI or
  boxed. Multiplication can overflow int64 (|a·b| < 2^94), so it always uses
  `__builtin_mul_overflow`, as do boxed operands for every operator. An int64
  overflow raises `value` ((A)).

**Canonical form (all alternatives), corrected in design round 2.** The
round-0 draft said an int in [-2^47, 2^47) is never boxed in any slot, with
`slot_from_heap` normalizing a small box. That cannot hold: the VM boxes
numbers on purpose today, and must keep doing it for ints.
- `vm_slot_lift` (vm.c:826, the store at 834) and `vm_local_lift` (vm.c:717,
  store at 723) materialize an immediate into a heap Value and **overwrite
  the slot with it**, because the caller keeps using that pointer.
  `env_get_hashed` and `env_get_local_hashed` (eigenscript.c:4986-5026) do
  the same through `slot_to_value` plus `slot_from_heap`.
- `vm_push` goes through `slot_bridge_wrap` (vm.c:768), which by contract
  "NEVER emits an immediate": a builtin's boxed result stays a heap slot.
- So a boxed number on the stack or in an env slot is a legal state today
  (the JIT's operand loader already accepts a heap `VAL_NUM` with refcount
  >= 2, jit.c:2343). A boxed small int is the same state.

The invariant that does hold, and that round 1 keeps:
- **Container storage is canonical.** A list item or dict value is an
  immediate number, null, bool, or a heap pointer to a Value that is not a
  number (container.h:4-16). After round 1: a small int is stored as an
  SMI, and a `VAL_INT` box only for an int outside [-2^47, 2^47). It is
  enforced inside the four container writers that already unbox a
  `VAL_NUM` (`eigs_container_slot`, `eigs_slot_adopt`,
  `eigs_slot_store_owned`, `eigs_slot_store_borrow`), not beside their
  callers (the #1746 lesson).
- **The int writers produce the SMI.** `slot_from_int(int64_t)` (new, the
  only int constructor) and `slot_from_value` (an owned Value*, which
  already releases a `VAL_NUM` box into an immediate, eigenscript.c:1862)
  produce an SMI for a small int and a box outside the range.
- **Everything that compares compares by value whenever a box is
  involved.** The only bit-level fast path is "both operands SMI" (equal
  bits iff equal ints). An SMI against a box, or two boxes, compares the
  int64 values; an int against a float uses N2's exact rule.
  `values_equal_impl`, the EQ/NE/compare arms, the sort comparators and
  every hash of a number follow this.

Consequences:
- A writer that skips the small-int rule produces a box where an SMI was
  due. No program can see that: equality, ordering, printing and the tape
  all go by value. The only witness is the C slot test
  (`tests/phase2/slot_layer.c`, §8 R1.1), which drives each writer above
  with every boundary value (±2^47, ±(2^47 - 1), 0, INT64_MIN, INT64_MAX)
  and asserts the resulting tag. That is plant 1's named check (§9.3); the
  round-0 claim that a program row (`N1.canon-eq`) would see it was wrong.
- The JIT `OP_CONST` emitter never meets an int: int literals use new
  opcodes (§2.7, §4.2).

### 2.2 The four alternatives

**Alt 1: `VAL_INT` beside `VAL_NUM`.**
- Value: a new `ValType VAL_INT` with an `int64_t` payload, appended after
  `VAL_BOOL`. `VAL_NUM` keeps meaning a double.
- Slot: SMI plus boxed `VAL_INT`.
- `type of` still answers `"num"` for both ((B)): `val_type_name(VAL_INT)`
  returns `"num"`. `num_type of x` reads the tag.

**Alt 1R (chosen): Alt 1, and the double vocabulary renamed, the ambiguous
accessors deleted.**
- `VAL_NUM` becomes `VAL_FLOAT`, `num_` becomes `f64_`, `VAL_NUM_RAW` and
  `SLOT_NUM_RAW` become `*_F64_RAW`, `slot_is_num` becomes `slot_is_f64`,
  `make_num` becomes `make_float`, `slot_from_num` becomes `slot_from_f64`.
- `eigs_num_arg`, `eigs_list_num`, `eigs_opt_num` and the slot forms are
  deleted. Replacements state intent:
  - `eigs_float_arg` converts an int to a double. It is legal only for
    float-producing builtins.
  - `eigs_int_arg` applies N5's exact rule and raises otherwise.
  - `eigs_number_arg` returns `EigsNum { kind, i, f }` for int-preserving
    builtins.
  - `make_int`.
- Design round 2 extends the list (measured in §2.3a): the AST and token
  literal payloads, `slot_as_double` (deleted), the container f64 helpers,
  `make_num_permanent`, `buf_num_arg`, `finite_num_to_byte` and
  `buffer_read_byte`.
- This is the repo's own precedent: #1637 round 4 renamed the union member to
  `num_` "so no unchecked read compiles" (eigenscript.h:281).

**Alt 2: one `VAL_NUM` with an int/float subtype (Lua 5.4's `TValue`
model).**
- Value: `VAL_NUM` plus a `numkind` field. The payload union holds `num_`
  (double) or `i64_`.
- Slot: SMI plus boxed `VAL_NUM`/INT.
- (B) falls out of the type layer for free: `type of`, `who is` and every
  `== VAL_NUM` test already say "number".

**Alt 3: double-plus-int shadow.**
- As Alt 2, but an int Value also keeps `num_ = (double)i64_`, so every
  existing double read keeps working.
- Slots still need the SMI tag, because a slot has no room for a shadow, so
  the slot work equals Alt 1's.

### 2.3 How many sites change, and what a missed site does

The counts come from the inventory (§1); the token-by-token split was
computed from the site list.

| | sites that must be revisited | how the revisit is forced | what a MISSED site does |
|---|---|---|---|
| **Alt 1** | the 382 TEST and 63 CASE sites (all categories) that should admit ints; reads after them; every producer that should yield an int; JIT producers | CASE only: 62 of the 63 `case VAL_NUM:`/`case AST_NUM:` switches have no `default:`, so `-Werror=switch` names them. TEST sites are not forced. | The int fails `== VAL_NUM` and takes the non-number branch. That raises a type error where the branch raises (loud, acceptable), but returns a **soft default** where the branch is soft. Examples: `what is 5` answers 0 and `who is 5` answers "unknown" (vm.c:5465-5484); `json_encode of 5` writes `null` (builtins.c:998, the one switch with a `default:`). Silently wrong, but never a lossy double. |
| **Alt 1R** | the same sites | **Measured (§2.3a), under the Makefile's exact flags: 1,488 of the 1,798 sites stop compiling (1,450 non-JIT, 38 in the JIT files)**, each attributed to the commit that first forces it (R1.1 223, R1.2 464, R1.3 11, R1.6 743, R2.2 47), plus 53 inside a deleted definition. The other 257 keep a token on purpose, each class with its reason in §2.3a: the AST kind (52), the decided embed accessor (48), the libc parsers (15), the exact-conversion and formatter helpers (9), definitions (44), 86 JIT emitter immediates and helpers reviewed per guard (§4), and 3 `offsetof` uses that a real member rename does reach (measured). | **A compile error.** It cannot exist in code that names the vocabulary. The meaning changes that carry no token are listed with the gate that catches a miss (§2.7); the last `default:` that could absorb `VAL_INT` (builtins.c:998) is removed first in R1.2a. |
| **Alt 2** | payload reads and producers (enforced only if `num_` is renamed); the type tests keep compiling and now admit ints | none for the 382+63 type tests and the 484 checked reads | **A silent wrong number.** After `== VAL_NUM`, a `VAL_NUM_RAW` read of an int reads its int64 bits as a double (5 reads as 2.5e-323). An accessor that converts loses precision above 2^53 silently. In the JIT, three emitters misread with no compiler to catch them: `emit_load_numeric_operand`'s heap arm (jit.c:2343) loads `data.num_` of a boxed int; the `OP_SET_LOCAL` in-place branch (jit.c:3410) writes double bits into an int Value; the `OP_CONST` emitter (jit.c:2816) pushes `VAL_NUM_RAW` bits of an int constant. Constant dedup `const_equal` (chunk.c:212) merges `3` and `3.0`. |
| **Alt 3** | only the sites that need exactness (N2, N3, N6, N8, N14, tape) | none: every existing read compiles and works below 2^53 | **A silently lossy double**, exact below 2^53, so ordinary tests cannot see it. This is precisely the class the brief says to design out. |

### 2.3a The compile measurement (design rounds 2 and 3)

Round 0 claimed 1,449 non-JIT sites stop compiling; that was a token count,
and the critic's compile measured 1,331. Round 2 extended the rename list
and measured 1,416 of 1,798, under three hand-written configurations; the
one it called `server-db` was really every TU with every extension, ZLIB
included (the critic reproduced the count only with ZLIB). Round 3 does two
things: it adds the two token events the plan still lacked (`buffer_read_num`,
renamed in R1.6 so every buffer element read is re-decided, and the clamp,
deleted in R2.2), and it measures under the Makefile's exact flags.

**Method.**
- A scratch copy of `src/`, never the worktree. Each token the plan renames
  or deletes gets a declaration carrying clang's
  `__attribute__((unavailable("P2 ...")))`, so every USE is a compile error
  and the definition stays legal. The macros `SLOT_NUM_RAW` and
  `EIGS_NUM_MAX` are routed through an unavailable `extern`; `VAL_NUM_RAW`
  expands to the unavailable member `num_`.
- The tokens, by the commit that removes them (§2.7):

  | commit | tokens |
  |---|---|
  | R1.1 | `slot_is_num`, `slot_is_numeric`, `SLOT_NUM_RAW`, `slot_from_num`, `slot_as_double` |
  | R1.2 | `VAL_NUM`, the member `num_` (so `VAL_NUM_RAW`), `VAL_NUM_OFFSET` |
  | R1.3 | the AST literal payload `num`, the token payload `num_val` |
  | R1.6 | the bridge (§2.7): `eigs_num_arg`, `eigs_num_arg_slow`, `eigs_list_num`, `eigs_elem_num`, `eigs_opt_num`, `eigs_slot_num`, `eigs_slot_elem_num`, `eigs_slot_opt_num`, `buf_num_arg`, `make_num`, `make_num_permanent`, the container helpers `list_set_num`, `list_append_num`, `list_rewrite_num`, `dict_value_set_num`, `dict_value_rewrite_num`, `list_get_num`, `dict_value_get_num`; `finite_num_to_byte`, `buffer_read_byte`, `buffer_read_num` |
  | R2.2 | `num_guard`, `num_guard_named`, `EIGS_NUM_MAX` |
- clang 18.1.3, `-fsyntax-only -ferror-limit=0`, one translation unit at a
  time, five configurations. Three are the Makefile's own build variants,
  with flags and TU lists read at run time (`make print-FLAGS_<v>`,
  `make print-SRC_V_<v>`); `freestanding` takes `tools/freestanding_check.sh`'s
  flags; `all` adds the TUs no build variant compiles (`eigenlsp.c`,
  `eigsdap.c`, the embed and JIT smoke programs), with every extension on:

  ```
  release      (29 TUs) -Wall -Wextra -Werror=implicit-function-declaration -Werror=switch -Werror=comment
               -Werror=misleading-indentation -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE
               -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0
               -DEIGENSCRIPT_EXT_GFX=1 -DEIGENSCRIPT_VERSION="0.46.0"
  server-db    (35 TUs) the same CFLAGS, -I/usr/include/postgresql -DEIGENSCRIPT_EXT_HTTP=1
               -DEIGENSCRIPT_EXT_MODEL=1 -DEIGENSCRIPT_EXT_DB=1 -DEIGENSCRIPT_EXT_NET=1
               -DEIGENSCRIPT_EXT_GFX=1 (no ZLIB: the Makefile's FLAGS_server-db omits it)
  zlib         (29 TUs) release's flags plus -DEIGENSCRIPT_EXT_ZLIB=1
  freestanding (23 TUs) -O2 -ffreestanding -fno-stack-protector -U_FORTIFY_SOURCE
               -Werror=implicit-function-declaration -Werror=switch -Werror=comment
               -Werror=misleading-indentation -DEIGENSCRIPT_FREESTANDING=1
               -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0
  all          (41 TUs) CFLAGS plus every extension, -DEIGENSCRIPT_EXT_ZLIB=1 included
  ```
- The generated `lsp_stdlib_index.h` is produced into the copy
  (`tools/gen_lsp_stdlib_index.sh <copy>/lsp_stdlib_index.h`).
- An error line and each macro-expansion note under it are mapped back to
  the unmutated copy's line (difflib). A site is **flagged** when its
  file:line carries an error. A flagged site is attributed to the FIRST
  commit whose token errors on its line: that is when a migrator must first
  visit it.

**Results** (the unmutated copy first, as the control):

```
base:  cfg=release tus=29 errors=0      cfg=server-db tus=35 errors=0     cfg=zlib tus=29 errors=0
       cfg=freestanding tus=23 errors=0 cfg=all tus=41 errors=0           (unparsed_failures=0 everywhere)
R3:    cfg=release tus=29 errors=2501   cfg=server-db tus=35 errors=2780  cfg=zlib tus=29 errors=2506
       cfg=freestanding tus=23 errors=1920 cfg=all tus=41 errors=3011     (unparsed_failures=0 everywhere)
inventory sites=1798 (non-JIT 1671, JIT-file 127)
cfg=release      distinct_flagged_lines=1209 sites_flagged=1384 (non-JIT 1377, JIT-file 7)
cfg=server-db    distinct_flagged_lines=1265 sites_flagged=1442 (non-JIT 1435, JIT-file 7)
cfg=zlib         distinct_flagged_lines=1213 sites_flagged=1389 (non-JIT 1382, JIT-file 7)
cfg=freestanding distinct_flagged_lines=866 sites_flagged=1024 (non-JIT 1024, JIT-file 0)
cfg=all          distinct_flagged_lines=1307 sites_flagged=1488 (non-JIT 1450, JIT-file 38)
UNION of the four build configs: sites_flagged=1447; all-TU config adds 41
UNION: flagged=1488 (non-JIT 1450, JIT-file 38)  inside-deleted-definitions=53  not-flagged=257 (non-JIT 168, JIT-file 89)
first forced in: R1.1=223  R1.2=464  R1.3=11  R1.6=743  R2.2=47
errors not naming a planned token: {"cannot take the address of an rvalue of type 'double'": 5}
```

The error totals count a header's error once per TU that includes it; the
distinct lines and the sites are what matter. The five errors that name no
token are an artifact of the `SLOT_NUM_RAW` reroute (it takes an address,
and five uses pass an rvalue); every one sits on a line that also carries
an `unavailable` error, so no site depends on them. Every flagged site has a
first commit.

**The 257 sites that never stop compiling, every one classified:**

| class | sites | why it keeps compiling, and what forces it instead |
|---|---:|---|
| JIT emitter immediates and helpers | 86 | Tag compares (`0xFFF8`/`0xFFF9`/`0xFFFB`/`0xFFFD`) and the `emit_*` helpers. Reviewed per guard in §4.1: an SMI or a `VAL_INT` box fails every consuming guard and bails; the producer emitters keep their float meaning (§4.2). |
| `AST_NUM` | 52 | Under (B) the node kind still means "number literal". Its payload `num` is renamed in R1.3, so all 7 reads of the literal's value are flagged; a site that only tests the kind is right for both kinds. The critic made the same call. |
| `eigs_value_as_num` | 48 | The embed accessor: 40 call sites in `embed_smoke.c` and 6 in `embed_concurrent.c` (the embed test harnesses), plus its definition (`eigs_embed.c`) and declaration (`eigs_embed.h`). Q3 decided it converts an int as `lua_tonumber` does, so "this value as a double" is unchanged; exact ints get `eigs_value_as_int`/`eigs_value_is_int` (R1.8). |
| definitions | 44 | Declarations and bodies of the renamed and deleted names themselves. |
| `strtod` 14, `atof` 1 | 15 | The libc parsers. The lexer's result reaches the renamed `num_val` through `tok_add`, whose store is flagged; the literal's kind changes `tok_add`'s parameter, which forces the call. The JSON, store and trace scalar parsers return `make_num(d)` a few lines on (flagged, R1.6); trace.c:2324 fills a buffer's f64 storage (Q2). The rest parse model hyperparameters (float), the tape's observer config, and `tape_read.c:368`, which feeds the observer replay a double (`tape_read.c:635`); round 1 observes ints as doubles live and on replay alike (§8 risks), and round 3's change to `observer_slot_record_value`'s parameter forces this line. |
| `num_to_i64_exact` 6, `eigs_num_text` 3 | 9 | Pure helpers over a double, unchanged in meaning; every input reaches them through a renamed reader. N6 changes the formatter's output on purpose in R1.7, a token-less change listed in §2.7 with its rows. |
| `VAL_NUM_OFFSET` in jit.c | 3 | `offsetof` uses, which the attribute does not reach. A real rename does: renaming `num_` to `f64_` (and the macro) in a further scratch copy gives exactly 3 errors, jit.c:2367, 2368 and 3471. |
| **total** | **257** | |

**What round 2 got wrong here, and round 3 fixes.** Round 2 kept
`buffer_read_num` (26 unflagged sites) as "a float by contract". Ten of its
38 sites read a value that is NOT a float: byte values (`str_from_bytes`
builtins_buf.c:240, `f64_from_bytes` :284, the zlib input :351,
`buf_from_pcm16le` :754 and :756, `write_bytes` builtins_host.c:1548,
`net_send` ext_net.c:361, and inside `buffer_read_byte` eigenscript.h:1920)
and indices (`scatter_add` builtins_tensor.c:1036, `flat_index_at` :1436, the
`gather` path the critic probed: an index of 1.5 truncates to 1 today). With
`buffer_read_num` renamed in R1.6, all 38 sites are flagged in that commit,
and each is re-decided: `buffer_read_f64` for data, the Q1 byte reader for a
byte, the N5 index reader for an index (§2.6). Without the rename, nine of
the ten lines stayed unflagged in round 2; most sit in a function another
token forces anyway (the `finite_num_to_byte` call a line later), but
`buf_from_pcm16le` names no other token before R2.2's clamp deletion, so
nothing would have made R1.6 visit it.

So the headline is: **1,488 of 1,798 sites stop compiling across the
plan** (first forced: R1.1 223, R1.2 464, R1.3 11, R1.6 743, R2.2 47), 53
more sit inside deleted definitions, and 257 keep a token for the reasons
above. None of the 257 changes meaning without a token event: the ones that
change meaning later do so in a commit listed in §2.7.

### 2.4 The choice: Alt 1R

1. **It is the only alternative whose missed site is loud by construction.**
   Measured: 1,488 of 1,798 sites stop compiling until a person decides,
   site by site, whether the site admits ints and with what semantics
   (§2.3a). Alt 2 and Alt 3 leave 445 type tests and cases plus 484 checked
   reads compiling with a widened or lossy meaning.
2. **The JIT argues for it independently.** All three of Alt 2's emitted
   misreads exist because the emitter checks `type == VAL_NUM` and then loads
   at a fixed offset (`VAL_NUM_OFFSET`). Under Alt 1R a boxed int has another
   type, so the same unchanged code bails (§4).
3. **(B) does not require Alt 2.** (B) is a language-surface decision.
   `val_type_name(VAL_INT)` returns `"num"`, and the `who` interrogative
   answers "number". Lua itself keeps two variant tags under one basic type
   (`LUA_VNUMINT` / `LUA_VNUMFLT` of `LUA_TNUMBER`) and tests the variant
   wherever arithmetic cares, which is Alt 1's shape at the C level.
4. **No measurement favours another alternative** (§3). The slot cost is
   identical for all four; the Value-level type test is one compare (Alt 1)
   against two (Alt 2).

The cost of Alt 1R is the size of the round-1 diff. §8 stages it with
deprecation warnings, so the compiler's warning count is the progress meter
and the final commit deletes the old names. A mechanical `sed` from old name
to new would reintroduce the silent class (`len` returning
`make_float(count)`), so the migration is per site, with the builtin table
(§6) deciding each builtin's accessor and the per-builtin behaviour table
(§9.4) checking it.

### 2.5 The slot classifiers, derived

Nothing produces `0xFFFA` yet. The first SMI producer meets every function
that classifies a slot, and today those guess: "not a number, null or bool"
is taken to mean heap. What an SMI would do, once one exists:
- **pointer misread**: `slot_type` (container.h:92), `eigs_slot_ref`
  (container.h:98), `slot_bridge_unwrap` (vm.c:784), `slot_truthy`
  (vm.c:862) dereference the payload as a `Value *`;
- **silent null**: `vm_slot_lift` (vm.c:826) and `slot_to_value`
  (eigenscript.c:1885) turn the int into null;
- **silently unobserved**: `obs_slot_observable` (vm.c:1630) answers
  "pointer or bool", so the binding answers from no data;
- **unreplayable**: `write_slot` (trace.c:2836) writes `<unknown>`;
- **slow path into a misread**: `slot_as_double` (vm.c:872) returns 0;
- **right by accident**: `slot_type_name` (vm.c:3000) answers `"num"`.

Round 0 listed these by hand and gave R1.1 a rule ("every function holding
both `slot_is_num` and `slot_as_ptr`") that the critic showed misses three of
them: `eigs_slot_ref`, `obs_slot_observable` and `slot_type_name`. Round 2
derives the population instead (§1, check 4, `## Slot classifiers` in the
inventory file):
- **D1 (58)** names `slot_is_num`, `slot_is_numeric` or `slot_as_double`.
  All three are renamed or deleted in R1.1, so the compiler stops at every
  D1 entry. `slot_type`, `slot_bridge_unwrap`, `slot_truthy`,
  `vm_slot_lift`, `slot_to_value`, `write_slot` and every arithmetic and
  compare arm are D1.
- **D2 (20) and D3 (23)** name no number test, so nothing forces them. Each
  has the reviewed row below. The inventory fails on a D2/D3 entry with no
  row and on a row with no entry, and accepts only these dispositions:
  - `guarded`: an SMI can reach it and is handled correctly as written (it
    skips non-pointers, or tests one exact tag);
  - `smi-arm`: R1.1 adds an explicit SMI arm;
  - `refuse`: R1.1 makes it abort on an SMI, and on any tag it does not
    handle, so a caller missed later fails loudly instead of misreading;
  - `not-a-classifier`: it writes bits (a constructor, a bool result) and
    classifies nothing.
- **T (67)** only reads a slot's `ValType` (§1).

The three the critic named are now derived entries: `eigs_slot_ref` (D2,
refuse), `obs_slot_observable` (D3, refuse) and `slot_type_name` (D2,
smi-arm).

**R1.1's C slot test** (`tests/phase2/slot_layer.c`) reaches the static
classifiers by including the single-file amalgamation (`make amalgamation`,
#397, which already leaves out the CLI's `main`). Its population is the
inventory file's D1/D2/D3 function entries (the file lists them; the test's
generator reads each signature from the source and keeps those whose first
parameter is an `EigsSlot`); it asserts `examined` equals that count and is
above zero. Each
entry is called under ASan with hand-built SMI slots at the boundary values
(0, ±1, ±(2^47 - 1), -2^47): a `refuse` entry must abort (in a forked
child), and every other entry must return without a sanitizer report, with
the int's Value, type name or truthiness where it returns one. This runs in
R1.1, before any program can produce an SMI.

**As implemented in R1.1 (reported as design deviations in the R1.1
result).**
- **The table covers D1 too.** The rename made the compiler stop at every D1
  entry, but a rename can be typed without a decision, so every D1, D2 and
  D3 entry now has a reviewed row below (98 after R1.1), and the inventory
  fails on a slot classifier of any class without one.
- **A fifth disposition, `unwired`.** Some D1 arms need what R1.1 does not
  have: an int Value (`make_int`, R1.3), the int ValType (R1.2a), or tape v7
  (R1.3). Each calls `eigs_int_unwired(who, bits)`, which aborts naming the
  reader. R1.3 deletes `eigs_int_unwired`, so each one stops compiling in the
  commit that makes ints reachable (2.7). They are `slot_to_value` (the one
  place that boxes an SMI: the lifts, `slot_bridge_unwrap`, `eigs_slot_box`
  and the `*_get_return` readers route there), `slot_type`, `slot_view`,
  `write_slot`, and `slot_from_int`'s out-of-range arm (the `VAL_INT` box).
- **The permanent refusals** (`refuse`) go through `eigs_slot_refuse(who,
  slot)`, which prints the bits and aborts; `slot_as_ptr` refuses a non-heap
  slot under ASan and `-DEIGS_SLOT_CHECKED`. Readers that used to turn an
  unknown tag into null or `<unknown>` (`slot_to_value`, `vm_slot_lift`,
  `write_slot`) refuse it now; no slot carries such a tag today.
- **The C slot test's population** is
  `tools/phase2_inventory.py --slot-population` (33 entries after R1.1);
  `tests/phase2/slot_layer.sh` compares it with the entries the test
  examined, both ways. The test also runs a tag matrix (a double, the
  canonical NaN, -0.0, null, both bools, an SMI, a heap pointer, the
  reserved tags and the sentinel against the predicates and the deciding
  readers) and plant 1's named check (`slot_from_int` over the boundary
  values). Its ABORT rows run in forked children and must name the reader.

**As corrected in the R1.1 fix round (the R1.1 critic's FAIL).**
- **The four type-error arms are `unwired`, not `guarded`.** `NUM_CMP`
  (`< > <= >=`), `INT_BINOP_R` (`& | ^ << >>`), `CASE(NEG)` and
  `CASE(BNOT)` met an SMI with the type error naming `num`; inside a `try`
  that error became a wrong value (`r is xs[0] < 6` with an SMI 5 gave
  `false`, the float control `true`). "Handled correctly as written" was
  false. Each now refuses through `eigs_int_unwired`, so R1.3, which deletes
  the token, cannot compile until each has its int arm. All four are tied to
  **R1.3**, bitwise included: R1.3's int literals reach `&` at once
  (`tests/bench_dmg_shape.eigs:21`, `c.a is c.a & 255`), and §8 already
  gives bitwise operators exact int64 operands at R1.3, with R1.5 changing
  only the shift rule.
- **The tag matrix covers every entry.** Each of the 33 population entries
  meets all twelve kinds (a double, the canonical NaN, -0.0, null, false,
  true, an SMI, a heap pointer, the three reserved tags and the sentinel),
  each kind with its expected outcome: a value, a refusal naming the reader,
  or a raise. The runner requires the MATRIX set to equal the population.
- **Part D drives the operator arms through the VM.** A host builtin
  (`phase2_poke`) writes an SMI into a list element, and a program then
  applies each refusing operator to it, plain and inside a `try`: each must
  abort naming its arm, where the float control computes the value.
- **The slot test builds at -O0** (about 41 s instead of 162 s, and well
  under -O2's 602 MB peak), after the warnings #1775 listed were fixed:
  `builtin_tensor_gather`'s missing return, and the maybe-uninitialized
  locals behind `num_to_i64_exact` and `vm_index_resolve`. The first fix
  round initialised those locals at all nine declarations, which cost
  +2.07% Ir on DMG and +4.17% on a JIT-off float loop (the second R1.1
  critic). Moving the write into the readers instead (`slot_f64_value`
  writing 0.0, or the slot's bits, when it answers 0; `vm_index_is_int`
  writing on both paths) cost the same: measured with callgrind, any of
  them changed `vm_run_ex`'s code, +3.8% (+0.44% for `vm_index_is_int`
  alone) on the float loop, which executes neither failure path. What
  stays is the initialisation at exactly the three declarations GCC
  flags at -O1 (`INT_BINOP_R`'s `_ad`/`_bd`, the `i` of `CASE(INDEX_SET)`
  and of `jit_helper_index_set`): against R1.1, -0.0001% on the JIT-off
  float loop, +0.0001% with the JIT, -0.08% on the DMG canary.
- **A build warning fails the slot test under gcc only.** gcc is the
  reference toolchain for #1775's class (-Wreturn-type,
  -Wmaybe-uninitialized at -O0/-O1). R1.1's macOS lane (clang) printed 103
  warnings the gcc build does not have (-Wdefault-const-init-field-unsafe
  on `EigsView`), which the main clang build prints too. Under any compiler
  other than gcc (asked through its predefined macros: `__GNUC__` without
  `__clang__`) the slot test follows the main build's policy on that
  platform: warnings print, and only the -Werror set fails.
- **Its runner reads each tool on its own channel.** The scan and the test
  each have a grammar; a line outside it, or any stderr, is a FAIL that
  prints the line (the R1.1 critic: Python 3.13's DeprecationWarning on the
  scan's stderr was read as two classifiers). The Python runs with `-W
  error`.
- **"The int's Value"** cannot be checked in R1.1: no int Value kind exists,
  so `slot_to_value` and the readers that route to it are ABORT rows until
  R1.3 turns them into RETURN rows.

<!-- slot-table:begin -->
| name | disposition | what an int (an SMI) does there, as of R1.1 |
|---|---|---|
| `builtins.c:bool_gate_name` | guarded | skips every non-pointer slot (`!slot_is_ptr`); an SMI is never a builtin (D2) |
| `builtins.c:sort_cmp_str` | guarded | reached only after `builtin_sort` proved every element a string (its homogeneity test names `VAL_NUM`, compile-forced) (D2) |
| `builtins_host.c:ls_entry_cmp` | guarded | sorts the string entries `ls` built itself (D2) |
| `container.h:dict_value_get_num` | smi-arm | bridge reader (2.7): an int element converts to its double, exactly (|SMI| < 2^47), until R1.6 deletes the bridge (D1) |
| `container.h:dict_value_get_ref` | smi-arm | NULL for a number by contract, an int included; the caller then types the element (D1) |
| `container.h:dict_value_get_return` | smi-arm | an int element returns a fresh int Value through `slot_to_value`, the one SMI boxer (unwired until R1.3) (D1) |
| `container.h:eigs_container_slot` | not-a-classifier | the canonicalizing Value-to-slot writer (R1.2): it reads a Value, not a slot, and writes the bits; a `VAL_INT` box becomes an SMI inside [-2^47, 2^47) and stays a heap slot outside it (2.1) (D3) |
| `container.h:eigs_slot_adopt` | guarded | decides ownership from what `eigs_container_slot` returned (compile-forced); a small int comes back as an SMI and its box is released (D3) |
| `container.h:eigs_slot_box` | smi-arm | boxes an int through `slot_to_value`, kind-preserving (unwired until R1.3) (D1) |
| `container.h:eigs_slot_elem_num` | smi-arm | bridge reader: an int converts to its double (D1) |
| `container.h:eigs_slot_num` | smi-arm | bridge reader: an int converts to its double (D1) |
| `container.h:eigs_slot_opt_num` | smi-arm | bridge reader: an int converts to its double and answers present (D1) |
| `container.h:eigs_slot_ref` | refuse | an immediate double or an SMI was dereferenced as a pointer; every caller tests for a number first. R1.1 aborts on any slot that is not a pointer, null or bool, so a caller missed later fails loudly (D2) |
| `container.h:eigs_slot_store_borrow` | guarded | an SMI is canonical storage and comes back as it is, with no reference to take (D1) |
| `container.h:eigs_slot_store_owned` | guarded | an SMI is canonical storage and comes back as it is, with no reference to release (D1) |
| `container.h:list_get_num` | smi-arm | bridge reader: an int element converts to its double (D1) |
| `container.h:list_get_ref` | smi-arm | NULL for a number by contract, an int included (D1) |
| `container.h:list_get_return` | smi-arm | an int element returns a fresh int Value through `slot_to_value` (unwired until R1.3) (D1) |
| `container.h:slot_type` | unwired | an SMI's type is the int ValType, which lands in R1.2a; any other unknown tag refuses instead of being read as a pointer (D1) |
| `container.h:slot_view` | unwired | an SMI's facade is a `VAL_INT` view (R1.2a) (D1) |
| `eigenscript.c:#define GC_EDGE_TABLE` | guarded | a GC edge exists only for `slot_is_ptr`; an SMI has no edge (D2) |
| `eigenscript.c:ent_child_slot` | smi-arm | an int's entropy is its double's: the numeric channel until round 3 (design 7) (D1) |
| `eigenscript.c:env_get_hashed` | guarded | a non-pointer slot goes through `slot_to_value` (compile-forced) and comes back boxed: the lift boxes on purpose (§2.1) (D2) |
| `eigenscript.c:env_get_local_hashed` | guarded | as `env_get_hashed` (D2) |
| `eigenscript.c:gc_collect_at_exit` | guarded | skips every non-pointer slot (D2) |
| `eigenscript.c:module_ns_project` | guarded | an int skips the float-over-float rewrite: `slot_to_value` boxes it and the dict store re-canonicalizes it (D1) |
| `eigenscript.c:observer_entropy_now` | smi-arm | an int is the numeric kind, as its double (D1) |
| `eigenscript.c:slot_to_value` | unwired | the one SMI boxer: a fresh int Value needs `make_int` (R1.3). Any other unknown tag now refuses; it used to read back as null (D1) |
| `ext_store.c:store_json_encode_slot` | smi-arm | an int is written as its exact digits (design 7) (D1) |
| `jit.c:jit_compile_to_thunk/OP_EQ` | not-a-classifier | writes the bool result bits (D3) |
| `jit.c:jit_compile_to_thunk/OP_NEG` | not-a-classifier | the NOT arm writes bool result bits (D3) |
| `jit.c:jit_compile_to_thunk/OP_NULL` | not-a-classifier | the constant arm writes null and bool bits (D3) |
| `jit_smoke.c:run_bool_cases` | not-a-classifier | test harness: expected bool bits (D3) |
| `jit_smoke.c:run_index_bail_cases` | guarded | test harness: an exact null test of a result (D3) |
| `trace.c:write_slot` | unwired | an int needs tape v7 (ints as digits, floats marked), R1.3; a v6 tape would replay it as a float. Any other tag refuses; it was written as `<unknown>` (D1) |
| `value_slot.h:#define SLOT_SMI_TRAP` | refuse | the smi-trap build's check (`-DEIGS_SMI_TRAP`): every slot classifier aborts on an SMI before R1.3; nothing in other builds (D3) |
| `value_slot.h:#define slot_as_heap` | refuse | alias of `slot_as_ptr` (D2) |
| `value_slot.h:slot_as_ptr` | refuse | the raw dereference: R1.1 refuses a non-heap slot in ASan builds and under `-DEIGS_SLOT_CHECKED` (the C slot test) (D2) |
| `value_slot.h:slot_decref` | guarded | acts only on tag `0xFFFB`; an SMI has no refcount (D3) |
| `value_slot.h:slot_f64_value` | guarded | the float reader (was vm.c's `slot_as_double`): answers 0 for an int, so each caller decided where an int goes (D1) |
| `value_slot.h:slot_false` | not-a-classifier | constructor (D3) |
| `value_slot.h:slot_from_bool` | not-a-classifier | constructor (D3) |
| `value_slot.h:slot_from_heap` | guarded | maps null and bool Values to their immediates and every other Value to a heap slot, so a `VAL_INT` box stays a box: the lifts depend on that (§2.1) (D3) |
| `value_slot.h:slot_from_int` | not-a-classifier | the one int writer: an SMI inside [-2^47, 2^47); outside it the `VAL_INT` box is unwired until R1.3 (D3) |
| `value_slot.h:slot_incref` | guarded | as `slot_decref` (D3) |
| `value_slot.h:slot_int_value` | smi-arm | an SMI's int; the `VAL_INT` box arm lands in R1.2a with the type it names (D1) |
| `value_slot.h:slot_is_bool` | guarded | exact tag test (D3) |
| `value_slot.h:slot_is_f64` | guarded | the double test (was `slot_is_num`): an SMI answers 0 (D1) |
| `value_slot.h:slot_is_heap` | guarded | exact tag test (D3) |
| `value_slot.h:slot_is_null` | guarded | exact bit test (D3) |
| `value_slot.h:slot_is_ptr` | guarded | exact tag test (D3) |
| `value_slot.h:slot_is_smi` | smi-arm | the SMI tag test (D1) |
| `value_slot.h:slot_null` | not-a-classifier | constructor (D3) |
| `value_slot.h:slot_smi_val` | smi-arm | an SMI's int, sign-extending bit 47 without a right shift (2.1) (D1) |
| `value_slot.h:slot_true` | not-a-classifier | constructor (D3) |
| `value_slot.h:slot_truthy_immediate` | smi-arm | an int is truthy when it is not 0, like a double (D1) |
| `vm.c:#define ARITH_FAST` | guarded | an int is not a float (`slot_f64_value`): the arm's slow path pops it through `slot_bridge_unwrap`; R1.3 gives that path int arithmetic (D1) |
| `vm.c:#define INT_BINOP_R` | unwired | an int operand used to reach the type error naming `num`, which a `try` turned into a wrong value (the R1.1 critic). It now refuses through `eigs_int_unwired` until R1.3 gives the bitwise arms exact int64 operands (D1) |
| `vm.c:#define NUM_CMP` | unwired | an int operand used to reach the type error naming `num` (`r is xs[0] < 6` gave `false` inside a `try`). It now refuses through `eigs_int_unwired` until R1.3 adds N2's exact compare (D1) |
| `vm.c:#define READ_SLICE_BOUND` | smi-arm | an int bound is its value when a C `int` holds it, else a value error (D1) |
| `vm.c:jit_helper_dot_get` | guarded | a non-null field is pushed as its bits; an SMI is a valid stack slot (D3) |
| `vm.c:jit_helper_dot_set` | guarded | an int value skips the immediate store: the slow path pops it through `slot_bridge_unwrap` (D1) |
| `vm.c:jit_helper_index_get` | guarded | an int index skips the fast path: the slow path lifts it through `slot_to_value` (D1) |
| `vm.c:jit_helper_index_set` | guarded | an int index or value skips the fast path: the slow path pops it through `slot_bridge_unwrap` (D1) |
| `vm.c:jit_helper_iter_next` | guarded | a non-pointer state slot returns 1 (bail); its index-kind test `!= VAL_NUM` is compile-forced (D2) |
| `vm.c:jit_helper_local_dot_set` | guarded | an int value skips the immediate store: `vm_slot_lift` boxes it (D1) |
| `vm.c:jit_helper_local_idx_dot_get` | guarded | as `jit_helper_dot_get` (D3) |
| `vm.c:loop_iter_store` | guarded | the loop counter is a float the VM makes; a non-float slot takes the `make_num` path (D1) |
| `vm.c:obs_dump_scope` | smi-arm | an int's entropy, as its double (D1) |
| `vm.c:obs_dump_value` | smi-arm | an int prints as its exact digits (D1) |
| `vm.c:obs_slot_num` | smi-arm | the observer's numeric channel: a float, or an int as its exact double until round 3 (design 7) (D1) |
| `vm.c:obs_slot_observable` | refuse | answered "pointer or bool", so an SMI was silently unobserved. R1.1 aborts on an SMI or a reserved tag; every caller routes a number to `obs_slot_num` first. A BOXED int is a pointer and goes to `observer_slot_update(Value *)`, whose number arm (eigenscript.c:785) R1.2's `VAL_NUM` rename forces (§7, O map) (D1 since R1.1: it names `slot_is_f64`) |
| `vm.c:obs_slot_value` | guarded | called only after `obs_slot_observable` answered true (pointer or bool) (D2) |
| `vm.c:slot_bridge_unwrap` | smi-arm | an int materializes through `slot_to_value` (unwired until R1.3) (D1) |
| `vm.c:slot_truthy` | smi-arm | an int is truthy when it is not 0; a reserved tag refuses instead of being dereferenced (D1) |
| `vm.c:slot_type_name` | smi-arm | an SMI reached the final `return "num"` by accident. R1.1 adds the explicit SMI arm ("num", (B)) and aborts on a reserved tag (D1 since R1.1) |
| `vm.c:vm_borrow_scan` | guarded | compares heap slots with the result pointer; an SMI is not heap (D2) |
| `vm.c:vm_builtin_name_for` | guarded | skips every non-heap slot (D2) |
| `vm.c:vm_leaf_accessor_exec/OP_ADD|OP_SUB|OP_MUL` | guarded | bails unless both operands are floats, so the generic call computes an int or mixed operation (4.5) (D1) |
| `vm.c:vm_leaf_accessor_exec/OP_INDEX_GET` | guarded | bails on an int index; the generic call indexes (4.5) (D1) |
| `vm.c:vm_leaf_accessor_exec/OP_LOCAL_DOT_GET` | guarded | a non-pointer target bails (`return 0`); a non-null field is borrowed as its bits, an SMI included (D2) |
| `vm.c:vm_local_is_null` | guarded | exact null test (D3) |
| `vm.c:vm_local_lift` | guarded | a non-pointer, non-null slot goes through `slot_to_value` (compile-forced) and is boxed on purpose (D2) |
| `vm.c:vm_run_ex/CASE(BNOT)` | unwired | an int used to reach the type error naming `num`. It now refuses through `eigs_int_unwired` until R1.3 gives the bitwise arms exact int64 operands (D1) |
| `vm.c:vm_run_ex/CASE(DESTRUCTURE_UNPACK)` | guarded | a non-pointer source takes the error path, which names the type through `slot_type_name` (D2) |
| `vm.c:vm_run_ex/CASE(DISPATCH)` | smi-arm | an int key is its value when a C `int` holds it, else a value error; the result returns through `slot_bridge_unwrap` (D1) |
| `vm.c:vm_run_ex/CASE(DOT_GET)` | guarded | exact null test of a field (D3) |
| `vm.c:vm_run_ex/CASE(DOT_SET)` | guarded | an int value skips the immediate store: the slow path pops it (D1) |
| `vm.c:vm_run_ex/CASE(EQ)` | guarded | an int is not a float: the slow path (`values_equal_op` on the lifted Values); R1.3 adds N2 (D1) |
| `vm.c:vm_run_ex/CASE(INDEX_GET)` | guarded | an int index skips the fast path: the slow path lifts it through `slot_to_value` (D1) |
| `vm.c:vm_run_ex/CASE(INDEX_SET)` | guarded | an int index or value skips the fast path: the slow path pops it (D1) |
| `vm.c:vm_run_ex/CASE(LOCAL_DOT_SET)` | guarded | an int value: `vm_slot_lift` boxes it (D1) |
| `vm.c:vm_run_ex/CASE(LOCAL_IDX_DOT_GET)` | guarded | exact null test of a field (D3) |
| `vm.c:vm_run_ex/CASE(LOCAL_IDX_DOT_SET)` | guarded | an int value: `vm_slot_lift` boxes it (D1) |
| `vm.c:vm_run_ex/CASE(NE)` | guarded | an int is not a float: the slow path; R1.3 adds N2 (D1) |
| `vm.c:vm_run_ex/CASE(NEG)` | unwired | an int used to reach the type error naming `num`. It now refuses through `eigs_int_unwired` until R1.3 adds N4b (D1) |
| `vm.c:vm_run_ex/CASE(SLICE_GET)` | guarded | as DESTRUCTURE_UNPACK (D2) |
| `vm.c:vm_slot_lift` | smi-arm | an int is boxed on purpose through `slot_to_value` (2.1; unwired until R1.3); a reserved tag refuses, where it became null (D1) |
| `vm.c:vm_slot_value_opaque` | guarded | only a pointer can be a fn or builtin; an SMI answers "not opaque", which is right (D2) |
| `vm.c:vm_store_local_slot` | guarded | an int skips the in-place float store; the generic swap stores the SMI (D1) |
<!-- slot-table:end -->

### 2.6 The accessor API after round 1 (Alt 1R)

```
/* slots (R1.1: readers and the SMI encoding; no int VALUE can exist yet) */
int      slot_is_f64(EigsSlot);     /* high16 < 0xFFF8 */
int      slot_is_smi(EigsSlot);     /* high16 == 0xFFFA */
int      slot_is_int(EigsSlot);     /* SMI or heap VAL_INT */
int      slot_is_number(EigsSlot);  /* f64 or int */
EigsSlot slot_from_f64(double);     /* the ONE double writer; round 2: canonical NaN */
EigsSlot slot_from_int(int64_t);    /* the ONE int writer: SMI in range, else a box.
                                       Until R1.3 its only callers convert an
                                       existing VAL_INT (§8, the int-source check);
                                       R1.1's box arm is eigs_int_unwired */
void     eigs_slot_refuse(const char *, EigsSlot);  /* R1.1: a broken contract */
void     eigs_int_unwired(const char *, uint64_t);  /* R1.1; R1.3 deletes it (2.5) */
int      slot_f64_value(EigsSlot, double *);   /* an immediate double or a VAL_FLOAT
                                                  box; 0 for anything else, ints
                                                  included. Replaces slot_as_double. */
int      slot_int_value(EigsSlot, int64_t *);  /* an SMI or a VAL_INT box */
#define  SLOT_F64_RAW(s)            /* was SLOT_NUM_RAW */

/* Values (R1.2a; make_int lands in R1.3, the first int producer) */
Value   *make_float(double);   Value *make_float_permanent(double);
Value   *make_int(int64_t);
#define  VAL_F64_RAW(v)             /* member f64_; were VAL_NUM_RAW and num_ */
#define  VAL_F64_OFFSET             /* was VAL_NUM_OFFSET (the JIT's fixed-offset load) */
#define  VAL_I64_RAW(v)             /* member i64_ of a VAL_INT */

/* the final readers, which replace the bridge in R1.6 (§2.7) */
EigsNum  eigs_number_arg(const Value *, const char *who); /* int-preserving */
double   eigs_float_arg(const Value *, const char *who);  /* float-producing: int converts */
int64_t  eigs_int_arg(const Value *, const char *who);    /* int-requiring: N5 exact rule */
int      eigs_int_arg_range(const Value *, int64_t lo, int64_t hi,
                            int64_t *out, const char *who);  /* N5, then the C range */
uint8_t  eigs_byte_arg(const Value *, const char *who);   /* Q1: N5, then 0..255 */
/* buffer elements (buffer_read_num renamed in R1.6; every site re-decided) */
double   buffer_read_f64(const Value *buf, int64_t i);   /* data: an f64 element (Q2) */
int      buffer_byte_at(const Value *buf, int64_t i, uint8_t *out, const char *who);
                                    /* a byte value: N5, then 0..255 (Q1) */
int      buffer_index_at(const Value *buf, int64_t i, int64_t *out, const char *who);
                                    /* an index: N5 (gather, scatter_add) */
/* the container f64/int helpers (R1.6): list_set_f64, list_append_f64,
   list_get_f64, dict_value_set_f64, ... and their _int twins (were *_num) */

/* Q7 (decided): continuous parameters, by the quantity they represent */
int      eigs_geom_shape(const Value *args, int first, EigsShapeKind kind,
                         const EigsRect *drawable, EigsShape *out, const char *who);
int      eigs_bounded_arg(const Value *, double lo, double hi, int *out, const char *who);
int      eigs_magnitude_arg(const Value *, int64_t lo, int64_t hi, int64_t *out,
                            const char *who);

/* literals (R1.3) */
OP_INT_ZERO, OP_INT_ONE, OP_INT_CONST   /* appended to OpCode; §2.7 */
/* AST literal payload `num` and the token's `num_val` become an EigsNum */
```

Each `_arg` reader also has the list, slot and optional forms of today's
checked accessors.

**The Q7 readers** (decided in
[#1758 comment 6174302316](https://github.com/InauguralSystems/EigenScript/issues/1758#issuecomment-6174302316);
the builtin table's `q7` column, §6, names each builtin's classes):
- **Geometry** (coordinates and sizes): clip the WHOLE shape in float
  space against the drawable area, then round to nearest. A per-argument
  reader cannot do that: saturating each endpoint of
  `gfx_rect of [-3e9, 0, 6e9, 10]` separately covers half the screen
  instead of all of it, so the reader takes the shape. `eigs_geom_shape`
  reads all of a shape's numbers as doubles (a non-finite one raises
  `value`, N13), then clips by kind and only then converts:
  - `POINT` (x, y): outside the drawable rect, the shape is empty;
  - `RECT` (x, y, w, h; also the clip rect, the framebuffer's destination
    `dx, dy, w*scale, h*scale`, and a glyph cell of `gfx_text`): intersect
    with the drawable rect in float space; an empty intersection draws
    nothing;
  - `LINE` (x1, y1, x2, y2): Liang-Barsky clipping of the segment in float
    space, so the visible part keeps its slope;
  - `CIRCLE` (cx, cy, r) and `RRECT` (x, y, w, h, r): reject when the
    bounding box misses the drawable rect; otherwise clamp the span loop to
    the drawable rows and columns before converting, so a radius of `3e9`
    costs the visible rows, not 6e9 iterations;
  - every surviving coordinate is then rounded half away from zero (Q4's
    rule) into a C `int`, which the clip guarantees holds it.
  `EigsShape.empty` tells the caller to draw nothing; that is the only
  outcome a finite out-of-range shape has.
- **Bounded** (colour channels, gain, volume, PCM samples): clamp to the
  domain, then round (`eigs_bounded_arg`); a NaN raises `value` (N13).
- **Magnitude** (durations, sleeps, timeouts, sample counts, window sizes, a
  measurement's scale): round, and raise `value` naming the builtin when the
  result does not fit what the C call can honour (`eigs_magnitude_arg`).

### 2.7 Every meaning change coincides with a token change

Round 0's order changed meanings with no token change: R1.1 widened
`slot_as_double` with an SMI arm, and R1.3 re-meant `OP_NUM_ZERO`/`OP_NUM_ONE`
as ints. Neither produces a compile error, so a missed caller or a missed
executor (the critic found the leaf evaluator's `OP_NUM_ZERO`/`OP_NUM_ONE`
arms, vm.c:1872-1877) would keep compiling with the old meaning. Round 2's
order had a second flaw the critic found: R1.2 deleted the builtin readers
(a compile error) while claiming to preserve behaviour, and R1.6 then changed
about 114 builtin rows with no token event at all.

The rule: **a meaning change lands in the same commit as the token change
that stops every affected site**, or it is listed below with the reason no
token exists and the gate that catches a miss instead.

**The bridge.** The builtin-facing readers and producers are kept, under
their current names, until R1.6, and they are the bridge: `eigs_num_arg` and
its family, `buf_num_arg`, `make_num`/`make_num_permanent`, the container
`*_num` helpers, `finite_num_to_byte`, `buffer_read_byte` and
`buffer_read_num`. Through R1.5 they keep exactly today's meaning: a number
read is a double (an int converts, as every number already is on the tag), a
number produced is a float. R1.6 deletes the bridge, so every builtin site
stops compiling in the commit that gives it its §6 semantics. R1.2 touches
no builtin's behaviour.

| commit | meaning change | token change in that commit | a missed site |
|---|---|---|---|
| R1.1 | a slot may hold an SMI (no producer yet) | `slot_is_num` -> `slot_is_f64`, `SLOT_NUM_RAW` -> `SLOT_F64_RAW`, `slot_from_num` -> `slot_from_f64`; `slot_is_numeric` and **`slot_as_double`** deleted | compile error: 223 sites first forced here (§2.3a), the 58 D1 classifiers among them |
| R1.1 | a slot classifier without a number test meets an SMI | none can exist (they name no number token) | the derived D2/D3 table (§2.5): `refuse` entries abort, `smi-arm` entries answer; the inventory fails on an unreviewed entry |
| R1.2a | a Value number may be an int (`VAL_INT`; no producer yet) | `VAL_NUM` -> `VAL_FLOAT`, `num_` -> `f64_`, `VAL_NUM_RAW`/`VAL_NUM_OFFSET` renamed; `VAL_INT` appended, so `-Werror=switch` stops every default-less ValType switch; the one `default:` (builtins.c:998) removed in the same commit | compile error: 464 sites first forced here. Each forced site gets its final int arm, live from R1.3; a builtin's number test admits an int and reads it through the bridge |
| R1.3 | **the first int values**: int literals, and int arithmetic on them | the AST payload `num` and the token's `num_val` become an `EigsNum`; **new opcodes `OP_INT_ZERO`, `OP_INT_ONE`, `OP_INT_CONST`, appended** (the opcode-ABI rule; no `EIGS_BYTECODE_ABI` bump); `make_int` introduced; `eigs_int_unwired` deleted (the R1.1 placeholders, 2.5) | compile error at the 11 payload sites, at each `eigs_int_unwired` caller, and the four exhaustive OpCode switches (`op_name` chunk.c:337, `op_verify_operands` chunk.c:466, `op_verify_stack_effect` chunk.c:615, `op_stack_effect` compiler.c:305; `tools/obs_marker_check.sh` requires each new enumerator's `/*obs:NONE*/`); the JIT and leaf scanners refuse an opcode they do not know (their `default:`); the interpreter's dispatch table is the one executor the compiler cannot check, and a missing entry is a NULL jump that crashes the first int-literal row (loud) |
| R1.3 | `OP_NUM_ZERO`, `OP_NUM_ONE`, `OP_CONST` | **no meaning change**: they keep their float meaning in all three executors (interpreter vm.c:3257, JIT emitter jit.c:2797, leaf evaluator vm.c:1872); an int is never an `OP_CONST` operand | n/a |
| R1.4 | `//` | `OP_IDIV` appended, `TOK_SLASH_SLASH` appended (and `//=`, Q6) | compile error at the exhaustive switches |
| R1.6 | **every builtin's §6 semantics** (N5 raises, int results, Q1 byte and Q7 continuous readers, the index readers of `gather`/`scatter_add`) | **the bridge is deleted** (21 tokens, §2.3a) | compile error: 743 sites first forced here; the per-builtin behaviour table (§9.4) checks every row's result against §6, on the tag and the branch |
| R1.8 | the embed API gains ints | `eigs_value_new_int`, `eigs_value_as_int`, `eigs_value_is_int` added; `eigs_value_as_num` keeps its name **by decision** (Q3: it converts, like `lua_tonumber`) | the embed gate row (MAP `gate.N7.embed-int`) |
| R2.2 | NaN and inf become reachable | `num_guard`, `num_guard_named`, `EIGS_NUM_MAX` deleted | compile error: 47 sites first forced here (the rest of the clamp's 74 sites were forced earlier) |

**The meaning changes that cannot carry a token**, each with the gate that
catches a miss:
- **R1.3, the int arms written in R1.1 and R1.2 go live.** They were forced
  then and written with their final semantics while no int could reach them.
  Gate: R1.3's 42 MAP rows and the C slot test; and the int-source check
  (§8) proves nothing before R1.3 could produce an int, so nothing earlier
  could have exercised an unfinished arm. The R1.1 arms that could not be
  final (`unwired`, 2.5) are token-forced instead: R1.3 deletes
  `eigs_int_unwired`. Since the R1.1 fix round the four operator arms that
  raised a type error for an SMI (`NUM_CMP`, `INT_BINOP_R`, `NEG`, `BNOT`)
  are among them.
- **R1.3, the tape parser.** `parse_value_p` (trace.c:2284) reads digits as
  an int from v7 on; the version bump refuses an older tape. Gate: the T1
  rows (`T1.twice-int`, `T1.v6-refused`).
- **R1.3, the leaf evaluator vs the generic path.** The leaf has no frame and
  no `OP_LINE`, so nothing marks it when the generic path's semantics change.
  Gate: the `trace` tier of §9.2, which runs every row with the leaf off and
  requires byte-identical output.
- **R1.4 `%` and R1.5 the shift rules.** Each has one live executor in round
  1: the interpreter (`CASE(MOD)`, `INT_BINOP_R`). The JIT scanner refuses
  MOD and the bitwise ops from R1.3, the leaf admits neither, and nothing
  folds constants (checked: the compiler and parser evaluate no operator at
  compile time). Gate: the N4 and N8 rows, including their `F` shapes.
- **R1.7, the float text.** N6 changes `eigs_num_text`, the one shared
  float formatter, and in the same commit the writers that format a float on
  their own: the JSON encoder, `store_json_encode` and `db_build_query`
  (#1762), and trace.c's `%.17g` writers (2817, 2836, 2950). (The decoders'
  int kinds for integer text, `json_decode`, `json_path`, `store_query`,
  `db_query_value` and `num of`, land in R1.6, where deleting `make_num`
  forces them.) Gate: one row per writer (`N6.*`, `N14.encode-kinds`,
  `N14.store-exact-digits`, `gate.N14.db-param-exact`, `T1.twice-float`).
- **R2.2, consumers that assumed a finite double.** No token marks code that
  merely receives a NaN or an inf once the clamp is gone:
  - `values_equal_impl`'s identity shortcut (`if (a == b && ...) return
    1;`) would call a NaN box equal to itself. No program path reaches it
    with one float box on both sides today (EQ compares two floats in its
    fast path, and container comparisons pass fresh element views; read,
    not probed, since no NaN exists yet), so R2.2 excludes floats from the
    shortcut as #1417 excluded buffers, and the C slot test calls it with
    one NaN box on both sides;
  - C casts of a double to an integer type (undefined on NaN or inf): every
    builtin argument goes through a §2.6 reader, which refuses a non-finite
    value (N13); the internal casts left are the #1746 residue (R2.6);
  - the sort comparators and `min`/`max` (Q8, decided): `sort` and `sort_by`
    order floats by IEEE 754 `totalOrder`, the canonical NaN after +inf;
    `min` and `max` propagate NaN. Gate: `N11.sort-total-order`,
    `N11.min-max-nan`.

---

## 3. Measured prototype

**Question.** What does an SMI arm cost in the VM's ADD fast path, in which
order, and does inline SMI beat boxing every int?

**Probe.** A 155-line standalone C file
(`/tmp/claude-1000/.../p2r0/bench/p2bench.c`, not committed). It mirrors
`ARITH_FAST` (vm.c:3290) on a two-slot stack. Each variant is one `noinline`
handler; the accumulator round-trips through memory as on the VM stack. It
is built with the runtime's flags: `-O2 -fstack-protector-strong
-D_FORTIFY_SOURCE=2 -fPIE`, gcc 13.3. All nine runs agree on the checksum
(2984375 at 1e6 iterations).

**Instrument.** `perf` is unavailable (perf_event_paranoid=4). Instruction
counts come from callgrind at 1e6 and 2e6 iterations. The difference divided
by 1e6 cancels startup cost, and both runs scale exactly, so the counts are
deterministic. Wall time is the interleaved median of 7 runs at 2e7
iterations. The box (Celeron N3350) carried load 1.2-3.8 from another job,
so read wall time as secondary.

| variant | data | Ir/op | wall median ns/op |
|---|---|---:|---:|
| A: today, double-only + `num_guard` | float | **38** | 8.38 |
| B: float first, then SMI (range check) | float | 40 (+2) | 8.88 |
| C: SMI first, then float | float | 44 (+6) | 10.17 |
| D: float first, SMI via shifted add + overflow flag | float | 40 (+2) | 9.04 |
| E: no SMI, every int a boxed int64 (freelist hit) | float | 49 (+11: harness prologue, see below) | 8.76 |
| B | int | 50 | 10.97 |
| C | int | **42** | 10.46 |
| D | int | **44** | 10.45 |
| E | int | **77** | 17.24 |

**Reading the disassembly.**
- B's +2 on floats is two register copies the compiler keeps live for the
  SMI arm (`movq %xmm0,%rdx; mov %rdx,%rcx`). That is a real cost of sharing
  the operand bits.
- E's +11 on floats is four callee-saved push/pop pairs in the per-variant
  function prologue. That is an artifact of the harness: in the VM the
  handler is inside `vm_run_ex`, which saves those registers once per call.

**What it decides.**
1. **Check order: float first.** It costs the float path +2 Ir (5% of the
   isolated op). SMI-first costs floats +6. Float-first keeps every existing
   float program within 2 Ir per arithmetic op.
2. **Overflow check: the shifted add (D)** is 6 Ir cheaper on the int path
   than a range check on the sum (B). Put both payloads in the top 48 bits
   and let the hardware overflow flag fire exactly when the sum leaves 48
   bits. This is a round-5 fast-path choice, recorded here because it
   decides the int arm's shape.
3. **Inline SMI against boxing every int: +33 Ir (+75%) and +65% wall per
   add for boxing, even when every allocation hits a freelist.** This
   confirms #1758's SMI tag decision with a number.

**Scale.** The real interpreter spends 685 Ir per iteration of `loop while i
< N: i is i + 1` (callgrind on the existing main binary, `EIGS_JIT_OFF=1`,
1e5 against 2e5 iterations: 69,804,271 and 138,304,271). The SMI arm's +2
on the float path is 0.3% of that.

**What it does not decide.** Alt 1R against Alt 2. Their slot cost is
identical, and at the Value level the difference is one compare against two.
The choice rests on §2.3, not on speed.

**A measured risk it exposes.** The same loop under the default JIT costs 402
Ir per iteration (42,924,355 against 83,124,355; `[jit] compiled=1`). After
N1, `i` is an int: the JIT scanner stops at the new `OP_INT_ONE` (§2.7), and
the LT and ADD guards bail on the SMI (§4). Expect at least the
interpreter's 685 (+70%) on int loops until round 5's fast paths.

The leaf evaluator (#366, §4.5) loses int helpers the same way: an int
literal makes its scanner refuse the chunk, and an int argument bails at the
first arithmetic or index op. `define inc(x) as: return x + 1` then takes the
generic call, the round trip #366 measured at about 200 ns per call
(vm.c:1836-1842), until round 5 gives the leaf int arms.

The CodSpeed lane's two-sided Ir gate (#1220) will fire on its JIT-tier
targets with int loops: `scalar_loop`, `bench_perf`, `bench_dmg_shape`,
`bench_idxset` and the real DMG `cpu_instrs` row (codspeed.yml). The lane's
own measurement bounds the size: "JIT removes 48% of the instructions on
bench_dmg_shape, 11.8% on DMG itself" (codspeed.yml:65-67). Losing the JIT
on int code costs up to about 1.9x Ir there, and about 1.13x on DMG. That
must be accepted up front, not discovered.

---

## 4. The JIT and the leaf evaluator

Three evaluators compute numbers: the interpreter (`vm_run_ex`), the JIT
(`jit_compile_to_thunk`, admitted by `jit_supported_prefix`) and the leaf
evaluator (`vm_leaf_accessor_exec`, admitted by `chunk_scan_leaf_accessor`;
§4.5). The inventory's executor matrix (§1, check 3) lists which of them
implements each opcode.

Round 1 needs correctness by bailing; fast paths are round 5. Every
consuming guard was read for how it treats a slot whose high 16 bits are
`0xFFFA` (SMI), and how it treats a heap slot whose `Value` is a boxed int.
Line numbers are jit.c at `0740af03`.

### 4.1 Consuming guards: all bail on SMI

| guard | the tag-range test | SMI (`0xFFFA`) | boxed int, Alt 1R (`VAL_INT`) |
|---|---|---|---|
| `emit_immediate_num_check_rax/rdx` (1625-1636) | `shr $48; cmp $0xFFF8; jae bail` | 0xFFFA >= 0xFFF8: **bail** | 0xFFFB >= 0xFFF8: **bail** |
| `emit_load_numeric_operand` (2343-2378) | `< 0xFFF8` is a double; `< 0xFFFB` bails (the comment reads "Tag 0xFFF8-0xFFFA (null/bool/SMI-reserved): not numeric"); `>= 0xFFFD` bails; else a heap Value must have `type == VAL_NUM && refcount >= 2` | **bail** | type is `VAL_INT`, not `VAL_NUM`: **bail** |
| `emit_jump_unless_bool_rax` (1911-1916) | `cmp $0xFFF9; jnz` | not a bool, falls to the num check: **bail** | not a bool: **bail** |
| `emit_dict_cache_probe` (2172-2185) | `cmp $0xFFFB; jne slow` | **slow path** (helper) | heap, then type `!= VAL_DICT`: **slow** |
| `OP_SET_LOCAL` in-place branch (3410-3475) | TOS `>= 0xFFF8` goes to the generic swap; the old slot must be a heap `VAL_NUM` with rc 1 | TOS SMI: **generic swap** (correct) | old slot `VAL_INT`: **generic swap** |
| `OP_INDEX_SET` inline (4067-4130) | index and value use `emit_immediate_num_check_*`; target `== 0xFFFB && type == VAL_BUFFER` | **helper** (C, the interpreter's semantics) | **helper** |
| `OP_LOCAL_DOT_GET` inline (3108-3170) | the field uses `emit_immediate_num_check_rax` | **helper** | **helper** |

The refcount paths treat an SMI as an immediate, which is correct (it has no
refcount):
- `emit_conditional_incref_rax` (1279) and `emit_conditional_decref_rsi_hook`
  (2028) test `cmp $0xFFFB; jb skip`, and 0xFFFA < 0xFFFB.
- The binop commit's OR-of-tags exit (2391, 2421) already lists "bool|smi
  tags OR-ing up to 0xFFFB" as taking the per-slot path, which handles every
  tag.

The opcodes that consume through these guards are:
- ADD, SUB, MUL, DIV, MOD, EQ, NE, LT, GT, LE and GE through
  `emit_load_numeric_operand`;
- BAND, BOR, BXOR, SHL, SHR, NEG, NOT, BNOT and JUMP_IF_* through
  `emit_immediate_num_check_*`.

ITER_NEXT, INDEX_GET and LOCAL_IDX_GET are C helper calls (`jit_helper_*` in
vm.c). They are migrated with the C code, and the inventory counts their
sites (for example `jit_helper_index_get` 17).

**Finding: no consuming guard reads SMI tag bits as a double.** Under Alt 2
three would misread a boxed int (§2.3). Under Alt 1R none does.

### 4.2 Producer emitters: these do not bail

The emitter writes bits directly, so a guard cannot protect these. Round 0
re-meant two of them; round 2 changes none of their meanings, so none can be
missed (§2.7):

| emitter | today | round 1 |
|---|---|---|
| `OP_NUM_ZERO`/`OP_NUM_ONE` (2797-2814) | pushes the double bits of 0.0 and 1.0 | **Unchanged: they keep meaning float 0.0 and 1.0** in all three executors (this emitter, the interpreter vm.c:3257, the leaf vm.c:1872-1877). Today the compiler (compiler.c:2073-2074) emits them for any literal `== 0.0` or `== 1.0`, so `0` and `0.0` share an opcode; from R1.3 the compiler emits them only for a float literal, and `0`/`1` become the new `OP_INT_ZERO`/`OP_INT_ONE`. |
| `OP_CONST` (2816-2838) | `VAL_NUM`: the bits of `num_`; else pushes a `TAG_HEAP` pointer plus an incref | **Unchanged**: an int is never an `OP_CONST` operand. Its `VAL_NUM` test is renamed `VAL_FLOAT` (forced), and `last_imm` (4375) stays 1 exactly for a float constant. |
| `OP_INT_ZERO`/`OP_INT_ONE`/`OP_INT_CONST` (new, R1.3) | none | **Refused by the scanner** (its `default:`), so an int literal ends the compiled prefix and runs interpreted. Round 5 emits them: SMI bits computed by `slot_from_int` at compile time, or a `TAG_HEAP` box for an int64 outside the SMI range; `last_imm` is then 1 exactly when the bits are immediate (the jit skill's lockstep rule). |
| BAND/BOR/BXOR/SHL/SHR (3716-3768), BNOT (3819-3830) | double operands, cvttsd2si, op, cvtsi2sd: a **double** result | N8 makes bitwise results ints. Round 1: **the scanner refuses these opcodes** (the op interprets) until round 5 emits SMI results. |
| MOD (3511-3585) | `call fmod`, which truncates toward zero | N4 makes `%` floor modulo (sign of the divisor), so fmod is wrong for mixed-sign floats (`-7.5 % 2` gives -1.5; Lua gives 0.5). Round 1: **the scanner refuses MOD** (§8 R1.3; the MAP's `N4.fn-floor-mod` witness expects it); round 5 may emit the floor correction. |

### 4.3 For round 2 (N11/N12)

The experiment already did each of these and the branch carries the code:
- `max_normal_bits` (2634) becomes inf's bits, so a NaN result bails;
- NEG gains a NaN bail, because a flipped canonical NaN spells
  `SLOT_NULL_BITS`;
- comparisons gain a `jp` bail;
- CONST canonicalizes a NaN constant.

### 4.4 For round 5 (recorded so it is not rediscovered)

An int fast path must bail when its result leaves the SMI range. A boxed
result is a heap push, and `last_imm = 1` on ADD (4366) would then skip its
decref at the following POP: one leak per iteration (the #231 shape).
`jit_smoke` needs SMI rows for every guard above, each with a value that
differs only in the tag bits, so a guard that compared the wrong bits would
fail. The jit skill's wide-bit rule applies.

### 4.5 The leaf evaluator (`vm_leaf_accessor_exec`, #366)

**What it is.** `chunk_scan_leaf_accessor` (chunk.c:1072-1134) runs once per
compiled function (compiler.c:2703 and 2767). It flags a chunk `leaf_accessor` when the body is one
side-effect-free expression over the parameters ending in `RETURN`: at most
128 bytes of code, at most 8 parameters, stack depth at most 8, no
defaulted parameters, and only
the 11 opcodes `LINE`, `CONST` (a `VAL_NUM` constant only), `NUM_ZERO`,
`NUM_ONE`, `GET_LOCAL` (a parameter), `LOCAL_DOT_GET`, `INDEX_GET`, `ADD`,
`SUB`, `MUL`, `RETURN`; its `default:` refuses everything else. An
exactly-fed call to such a chunk is then computed by
`vm_leaf_accessor_exec` (vm.c:1856-1971) against the caller's stack, with no
frame, no env, no `OP_LINE` and no dispatch. Its contract: return 1 with the
generic call's stack effect, or return 0 having touched nothing, and the
generic path re-executes.

**Where it runs.** Both call paths try it before the generic call:
`CASE(CALL)` (vm.c:4253) and `jit_helper_call` (vm.c:2503, the JIT's calls).
The gate is `!g_sandbox_active && leaf_accessor && argc == param_count &&
!g_trace_hist`. So it computes `define sq(x) as: return x * x` and
`one of 7` in **every** tier, `EIGS_JIT_OFF=1` included. Probed on the main
binary: 200 calls of a leaf `sq` leave its chunk with no entries at all in
`EIGS_JIT_HOT` under all three tiers (the leaf path never counts an entry;
both generic paths do, vm.c:2617 and vm.c:4353).

**It is off under `EIGS_TRACE`.** `g_trace_hist` is set while recording, so a
recorded run computes every leaf call on the generic path and a live run
computes it in the leaf. Probed: the same program records `sq` with 200
generic entries (`jit yes`, `adv RET`). A recorded run and a live run
therefore execute different evaluators. That is correct only while the two
agree on every value, so it gets a gate: the `trace` tier of §9.2 runs every
row with the leaf off and requires byte-identical output. Round 1 keeps the
leaf off under trace (the tape records every line, and the leaf skips
`OP_LINE`).

**Every arm** (vm.c line, today, round 1):

| arm | today | round 1 |
|---|---|---|
| `LINE` (1863) | skips the operand | unchanged |
| `CONST` (1866) | `slot_from_num(VAL_NUM_RAW(constant))`; the scanner admitted only a `VAL_NUM` constant (chunk.c:1090) | renamed `slot_from_f64(VAL_F64_RAW(...))`; the scanner's test becomes `!= VAL_FLOAT`, so an int constant is refused (it is an `OP_INT_CONST` anyway) |
| `NUM_ZERO` (1872), `NUM_ONE` (1875) | `slot_from_num(0.0)` / `(1.0)` | renamed `slot_from_f64`; **meaning unchanged** (float 0.0/1.0) |
| `OP_INT_ZERO/ONE/CONST` | do not exist | **not admitted**: the scanner's `default:` refuses the chunk, so an int literal sends every call down the generic path. Round 5 adds scanner and evaluator arms together (the inventory requires both directions) |
| `GET_LOCAL` (1878) | borrows the argument slot | unchanged (an SMI argument is a valid slot) |
| `LOCAL_DOT_GET` (1883) | the target must be a pointer to a dict, else bail; a missing field is null; a field is borrowed as its bits | unchanged: an SMI field is borrowed as an SMI (§2.5 row `guarded`) |
| `INDEX_GET` (1907) | the index through `slot_as_double` (an immediate or a boxed `VAL_NUM`) then `vm_index_is_int`; a list element is borrowed; a buffer element is `slot_from_num(buffer_read_num(...))` | `slot_as_double` is deleted (R1.1), so this arm stops compiling. It reads the index with `slot_f64_value` and **bails on an int index**; the buffer element is `slot_from_f64` (Q2: f64 storage), read through `buffer_read_f64` once R1.6 renames `buffer_read_num`. Round 5 adds the SMI index |
| `ADD`/`SUB`/`MUL` (1933) | both operands through `slot_as_double`; `r = a op b`; the underflow flag for MUL (#1079); `slot_from_num(num_guard(r))` | stops compiling (R1.1). Reads with `slot_f64_value` and **bails unless both operands are floats**, so an int or mixed operation runs on the generic path with N2/N3/(A) semantics. Round 5 adds int arms whose overflow bails (never raises inside the leaf: the generic path raises with the caller's line). R2.2 deletes `num_guard` here with the others |
| `RETURN` (1957) | increfs the result, pops args and fn, pushes the result | unchanged (`slot_incref` ignores an SMI) |
| `default` (1966) | unreachable; returns 0 | unchanged |

**Its witness.** No counter exists for the leaf. The design uses the hot-chunk
table instead of adding one (§9.2): both generic call paths count an entry
and the leaf never does, so "the callee has no entries in the normal run, and
K entries in the leaf-off (`trace`) run" proves that all K calls were
computed by the leaf. Probed on main: `sq` absent with the leaf on, `sq
200` with it off.

---

## 5. N12 and SMI share the NaN space

- **The canonical quiet NaN is `0x7FF8000000000000`**, with the sign bit
  clear, as in #1746 and the `exp-ieee-p1` `SLOT_CANON_NAN`.
- **Every tag has the sign bit set** (high 16 bits `0xFFF8`-`0xFFFF`). The
  SMI tag is `0xFFFA`.
- So canonical NaN (high 16 = `0x7FF8`) and every tag, SMI included, differ
  in bit 63. **They cannot collide.**
- The patterns that *can* collide are NaNs with the sign set and the quiet
  bit set (high 16 `0xFFF8`-`0xFFFF`). This includes x86's default NaN
  `0xFFF8000000000000`, which **is** `SLOT_NULL_BITS`, and any NaN built
  from bytes (`f64_from_bits of 0xFFFA000000000005` spells SMI 5).
- `slot_from_f64` is the single double-to-slot writer, and the JIT bails
  before storing a NaN result, so no such pattern reaches a slot. Every NaN
  is rewritten to `0x7FF8000000000000`. The other negative NaNs (high 16
  `0xFFF0`-`0xFFF7` with a nonzero mantissa: the signalling ones) do not
  collide but are canonicalized too: one NaN.
- `-0.0` (`0x8000...`) and `-inf` (`0xFFF0000000000000`) are below `0xFFF8`,
  so they are ordinary doubles.

**`f64_bits of x`** returns the IEEE bits as an int, exact (int64
reinterpretation, two's complement). Cases:
- for a float held in a slot, the stored bits; for NaN that is always
  `0x7FF8000000000000` = 9221120237041090560, which is outside the SMI
  range, so a boxed int;
- `f64_bits of -0.0` = INT64_MIN (boxed);
- `f64_bits of 1.0` = 4607182418800017408 (boxed).

**`f64_from_bits of i`** builds the double from `i`'s 64 bits. If they spell
a NaN, the result enters a slot as the canonical NaN. Its payload is gone
from the float but still held by the int `i`. So `f64_bits of (f64_from_bits
of i) == i` for every `i` that is not a non-canonical NaN pattern, and
payload fidelity goes through ints (N12: "Ints are never NaN-canonicalized").

**Buffers** hold raw doubles and are not slots, so a buffer element may hold
any payload. Reading it as a float (`buf_get`) puts it in a slot, so it is
canonicalized. Reading it through the new bits accessor (N12: "Buffer
elements are also readable and writable as bits") returns the stored bits
exactly as an int. That is the path the bar critic found missing: payload
`0x7FF0...01` came back canonical through every route on the prototype.

---

## 6. Builtin classification

**Classes.** The reference for counterparts is Lua 5.4 (manual §6.7,
`math`; §3.4.1-3.4.3, operators and coercions; §6.4, `string`; §6.6,
`table`).

- **int-preserving:** returns an exact int.
  - Where the inputs are ints: `abs`, `min`, `max`, `sum`, `floor`, `ceil`,
    `round`. These follow §6.7's "integer/float" annotation: "integer
    results for integer arguments". `math.min`/`math.max` return the winning
    argument.
  - Where the result is a count, code or index by definition: `len`,
    `range`, `ord`, `index_of`, handles. These follow Lua's `#` and
    `string.byte`.
  - Rounding (§6.7): "math.ceil, math.floor, and math.modf return an integer
    when the result fits in the range of an integer, or a float otherwise".
    `round` has no Lua counterpart and follows floor and ceil (Q4,
    decided: half away from zero, an int when it fits int64).
- **float-producing:** ints convert to float and the result is a float.
  Examples: Lua's `math.sin`, `sqrt`, `log`, `exp`; `/` and `^`, which
  "always convert integer operands to floats" (§3.4.1); and the float-tensor
  and audio-sample builtins (buffer storage is float).
- **int-requiring:** an argument is integer-valued, so it converts by N5's
  exact rule, then the C type's range: an index, count, size, code, bit
  pattern, byte value, handle, port or seed (Q1, decided: the parameter's
  meaning decides, not the C type). Examples: Lua's string positions,
  `table.insert`/`table.remove` positions, bitwise operands (§3.4.2),
  `math.random(m, n)` bounds, `math.randomseed`, and `string.char`, which
  raises on `65.5` and on `256` (probed, 5.4.9).
- **other:** everything else that takes or returns numbers:
  - formatting (N6);
  - JSON, store and db codecs (N13, N14);
  - parsing (`num`, N10);
  - `type` ((B));
  - continuous parameters (Q1, decided): gfx coordinates and sizes, colour
    channels, durations and audio gain accept an int or a float. Where the
    C API needs an int the value rounds to nearest (half away from zero, as
    `round`), replacing today's truncation toward zero, which gets negative
    coordinates wrong. What a finite value outside the C range does follows
    the quantity (Q7, decided): geometry is clipped as a whole shape in
    float space, a bounded quantity is clamped, a magnitude raises `value`
    (§2.6). (Byte consumers, which truncated and wrapped modulo 256 here in
    round 0, are int-requiring under Q1.)

**The `loss` column.** `LOSS` marks a builtin whose *current* body reads its
argument through a double accessor, or builds its result from a computed
double, on a path where its class needs an exact int. An int beyond 2^53
would then come out silently wrong if the body were kept and its accessor
re-pointed to int-to-float conversion. Under Alt 1R the old accessors no
longer compile, so every row is revisited anyway; `LOSS` rows are where the
mechanical re-point would be wrong. Builtins that only call the shared
formatter or equality (`print`, `str`, `join`, `list_contains`) are `-`,
because their exactness change happens once, in `eigs_num_text` or
`values_equal_impl`.

Two consequences of the definition, made explicit in design round 2:
- **The Q1 rows are not LOSS.** A byte, a count, a handle, a port or a C
  `int` is range-checked after the exact rule, and every int beyond 2^53 is
  outside every such range, so the double path cannot return a wrong
  in-range value: it raises either way. What WAS lossy beyond 2^53 is the
  modulo-256 wrap the byte consumers did, and Q1 deletes it. Seeds are the
  exception (a seed's range is all of int64), so `seed_random` and
  `task_sched_seed` stay LOSS.
- **A writer that loses digits of a double is LOSS even without ints.**
  `store_put`/`store_update` (the record encoder's `%.15g`) and
  `db_execute`/`db_query_json`/`db_query_value` (the parameter binder's
  `%g`) lose digits on main and on the tag today, filed as
  [#1762](https://github.com/InauguralSystems/EigenScript/issues/1762).
  Round 0 missed them; the critic found them. R1.7, N14's int half, fixes
  both writers by routing them through the one N6 number writer:
  `store_json_encode` (ext_store.c:184-202) writes an int as exact digits
  and a float as its shortest round-trip repr, replacing the int32 `%d` arm
  and `%.15g`; `db_build_query` (ext_db.c:57-58) binds the same text
  instead of `"%g"`. N13's refusal of a non-finite value stays inside the
  encoder (R2.3). If #1762 lands on main first (it does not depend on ints),
  R1.7 inherits the fix and only adds the int arm. Its MAP entries are the
  row `N14.store-exact-digits` and the gate `gate.N14.db-param-exact`.

**The `q7` column** (design round 3) names the Q7 class of each continuous
parameter a builtin converts: an ordered subset of `geometry`, `bounded`,
`magnitude`, or `-`. The inventory refuses any other token, and checks the
column against the note both ways: a row's note says "continuous" exactly
when its `q7` column is not `-`. Counts: geometry 9, bounded 13, magnitude 13.

**Counts** (from the table below, checked by `tools/phase2_inventory.py`,
which prints them): 230 numeric builtins (`ppu_render_frame` joined when
`buffer_read_byte` entered the vocabulary). By class: 37 int-preserving, 57
float-producing, 85 int-requiring, 51 other. The decided Q1 moved 16 rows
from other to int-requiring (counts, byte values, handles, flags and
selectors); `ppu_render_frame` is a new int-requiring row; design round 3
moved `buf_from_pcm16le` from float-producing to int-requiring (its inputs are
byte values, #1758 comment 6174964306) and corrected `gather` (its indices
truncate today). 42 are LOSS:
- arithmetic: `abs`, `add`, `subtract`, `multiply`, `negative`, `sum`,
  `num_copy`;
- min/max and rounding: `min`, `max`, `floor`, `ceil`, `round`;
- bitwise: the six `bit_*`, `sign_extend`, `hex`;
- clock, RNG and seeds: `monotonic_ns`, `random_int`, `seed_random`,
  `task_sched_seed`;
- shared counters: `shared_incr`;
- integer scanners: `scan_ints`, `scan_int_tokens`;
- ordering: `sort`, `sort_by`;
- store keys: `store_get`, `store_delete`, `store_update`, plus
  `store_query` and `db_query_value`, which decode integer text with
  `strtod`;
- writers that drop digits today (#1762): `store_put` (and `store_update`)
  through `%.15g`, `db_execute` and `db_query_json` (and `db_query_value`)
  through `%g`;
- JSON and parsing: `json_decode`, `json_path`, `num`, `json_encode`,
  `json_build`.

Probes on the main binary (0.46.0, built 2026-10-13; not the tag) show the
current state behind several rows:
- `str of 3.0` prints `3`.
- `json_encode of [3.0, 0.1]` gives `[3,0.1]`.
- `9007199254740993 == 9007199254740992` is `true`: the lexer rounds.
- `store_get of [s, "c", 1.9]` finds record `"1"` (a silent truncating key).
- `store_get of [s, "c", 4294967297]` returns `null`, because the `(int)`
  cast is out of range (a pre-existing defect, filed as
  [#1760](https://github.com/InauguralSystems/EigenScript/issues/1760); R1.6's
  `eigs_int_arg` for the key closes it if it is still open then).

<!-- builtin-table:begin -->
| builtin | class | loss | q7 | note |
|---|---|---|---|---|
| `abs` | int-preserving | LOSS | - | Lua math.abs (integer/float); abs of INT64_MIN raises (N4b) |
| `acos` | float-producing | - | - | Lua math.acos |
| `add` | int-preserving | LOSS | - | scalar arm mirrors `+` (overflow raises, (A)); buffer arms stay float |
| `append` | other | - | - | appends any value; VAL_NUM appears only as a diagnostic default |
| `asin` | float-producing | - | - | Lua math.asin |
| `assert` | other | - | - | message via value_to_string (N6) |
| `atan` | float-producing | - | - | Lua math.atan |
| `atan2` | float-producing | - | - | Lua math.atan(y, x) |
| `audio_capture_open` | int-requiring | - | - | freq (samples per second) and channels are counts: N5, then the C int range (Q1); returns a device id |
| `audio_envelope` | float-producing | - | magnitude | float samples; the attack and release times are continuous durations: a sample count the C int cannot hold raises (Q7 magnitude) |
| `audio_gain` | float-producing | - | - | float samples |
| `audio_mix` | float-producing | - | - | float samples |
| `audio_music_play` | int-requiring | - | - | loop count: N5, then the C int range (Q1) |
| `audio_music_volume` | other | - | bounded | the volume is a continuous gain: clamped to SDL_mixer's 0..128, then rounded (Q7 bounded) |
| `audio_noise` | float-producing | - | magnitude | float samples; the duration is continuous: a sample count the C int cannot hold raises (Q7 magnitude) |
| `audio_open` | int-requiring | - | - | freq (samples per second) and channels are counts: N5, then the C int range (Q1); returns a device id |
| `audio_pause` | int-requiring | - | - | the pause flag is discrete: N5 (Q1; today `(int)0.5` silently un-pauses) |
| `audio_play` | other | - | bounded | the samples are continuous: clamped to [-1, 1], then rounded to int16 (Q7 bounded; today they truncate); returns a channel number |
| `audio_play_loop` | int-requiring | - | bounded | loop count: N5, then the C int range (Q1); the samples are continuous: clamped and rounded to int16 (Q7 bounded); returns a channel |
| `audio_queue_size` | int-preserving | - | - | byte count (computed in a double, below 2^53) |
| `audio_saw` | float-producing | - | magnitude | float samples; the duration is continuous: a sample count the C int cannot hold raises (Q7 magnitude) |
| `audio_sine` | float-producing | - | magnitude | float samples; the duration is continuous: a sample count the C int cannot hold raises (Q7 magnitude) |
| `audio_square` | float-producing | - | magnitude | float samples; the duration is continuous: a sample count the C int cannot hold raises (Q7 magnitude) |
| `audio_stop` | int-requiring | - | - | channel number |
| `audio_stream_open` | int-requiring | - | - | freq (samples per second) and channels are counts: N5, then the C int range (Q1); returns a device id |
| `audio_stream_push` | other | - | bounded | the samples are continuous: clamped to [-1, 1], then rounded to int16 (Q7 bounded) |
| `audio_stream_queued` | int-preserving | - | - | sample count |
| `audio_sweep` | float-producing | - | magnitude | float samples; frequencies and amplitude stay floats; the duration is continuous: a sample count the C int cannot hold raises (Q7 magnitude); the wave selector is integer-valued: N5 (Q1) |
| `audio_volume` | int-requiring | - | bounded | channel index: N5 (Q1); the volume is a continuous gain: clamped to the mixer's range (Q7 bounded) |
| `bit_and` | int-requiring | LOSS | - | Lua `&` (§3.4.2): N5 operands, int64-pattern result (N8); today a double result |
| `bit_not` | int-requiring | LOSS | - | Lua unary `~` |
| `bit_or` | int-requiring | LOSS | - | Lua `\|` |
| `bit_shl` | int-requiring | LOSS | - | Lua `<<`; today masks the count mod 64, N8 needs >=64 gives 0 and negative shifts right |
| `bit_shr` | int-requiring | LOSS | - | Lua `>>` is logical (N8); today an arithmetic shift with `& 63` |
| `bit_xor` | int-requiring | LOSS | - | Lua binary `~` |
| `buf_copy` | int-requiring | - | - | offsets and counts |
| `buf_deinterleave` | int-requiring | - | - | channel count and index |
| `buf_dot` | float-producing | - | - | buffer dot product |
| `buf_fill` | float-producing | - | - | fills float storage; offsets by N5 |
| `buf_from_list` | float-producing | - | - | buffer storage is float: an int element converts (Q2) |
| `buf_from_pcm16le` | int-requiring | - | - | its input elements are byte values: each is read through the Q1 byte reader (N5, then 0..255), so a byte of 300 or 1.5 raises `value` (#1758 comment 6174964306; today 300 and 1.5 decode silently); the decoded samples are floats |
| `buf_get` | int-requiring | - | - | index; returns the float element |
| `buf_len` | int-preserving | - | - | element count |
| `buf_mix` | float-producing | - | - | float storage |
| `buf_peak` | float-producing | - | - | float max abs |
| `buf_resample_linear` | float-producing | - | - | float storage |
| `buf_scale_range` | float-producing | - | - | float storage |
| `buf_set` | int-requiring | - | - | index; the value converts to float storage (Q2) |
| `buf_to_pcm16le` | other | - | bounded | the samples are continuous: clamped to [-1, 1] and rounded (Q7 bounded, today's behaviour); the result is byte values |
| `buffer` | int-requiring | - | - | size or [rows, cols] |
| `build_corpus` | int-requiring | - | - | counts; returns counts |
| `ceil` | int-preserving | LOSS | - | Lua math.ceil: an int when the result fits int64, else a float |
| `channel` | int-preserving | - | - | handle dict with int id/gen fields |
| `channel_closed` | int-requiring | - | - | channel handle ids |
| `char_at` | int-requiring | - | - | string position (Lua string.sub) |
| `chr` | int-requiring | - | - | byte 1..255, already exactness-checked (Lua string.char) |
| `clock_unix` | float-producing | - | - | fractional seconds |
| `close_channel` | int-requiring | - | - | channel handle ids |
| `copy_into` | int-requiring | - | - | offset; values convert to float storage |
| `cos` | float-producing | - | - | Lua math.cos |
| `db_execute` | other | LOSS | - | binds every numeric parameter with `%g`, 6 significant digits (ext_db.c:57-58, #1762). R1.7: the N6/N14 writer |
| `db_query_json` | other | LOSS | - | binds parameters with `%g` (#1762); encodes rows (N14) |
| `db_query_value` | other | LOSS | - | binds parameters with `%g` (#1762); decodes a numeric column with strtod, so integer text beyond 2^53 rounds |
| `dispatch` | int-requiring | - | - | integer table key, already exactness-checked |
| `divide` | float-producing | - | - | mirrors `/` (Lua §3.4.1: always float) |
| `dot` | float-producing | - | - | buffer dot product |
| `eigen_eval_loss` | float-producing | - | - | token ids are indices; the loss is a float |
| `eigen_generate` | int-requiring | - | - | token ids and max_tokens are integer-valued (N5, Q1); temperature and top_p are floats |
| `eigen_model_load` | other | - | - | parses model JSON numbers with strtod |
| `exec_capture` | other | - | magnitude | the timeout is a continuous duration in seconds: a poll interval the C int cannot hold raises (Q7 magnitude); returns exit status ints |
| `exit` | int-requiring | - | - | exit code: N5, then the C int range (Q1) |
| `exp` | float-producing | - | - | Lua math.exp |
| `f64_from_bytes` | int-requiring | - | - | 8 byte values: N5, then 0..255 (Q1; the modulo-256 wrap is gone); the float result's NaN is canonical (N12) |
| `f64_to_bytes` | other | - | - | float to 8 byte ints; f64_bits (N12) is the int-valued sibling |
| `fill` | int-requiring | - | - | count |
| `floor` | int-preserving | LOSS | - | Lua math.floor: an int when the result fits int64, else a float |
| `gather` | int-requiring | - | - | each index, from a list or an index buffer, is integer-valued: N5 raises on 1.5 (today `flat_index_at` truncates: `gather of [t, ib]` with `ib[0]` = 1.5 returns `[11, 22]`, probed); returns elements unchanged |
| `get_at` | int-requiring | - | - | index, row and col; returns the element |
| `get_observer_thresholds` | float-producing | - | - | observer thresholds (O3 drops h_low) |
| `gfx_circle` | other | - | geometry,bounded | centre and radius are continuous geometry: the circle is clipped in float space against the drawable area, then rounded; the colour channels are continuous and bounded: clamped to 0..255, then rounded (Q7) |
| `gfx_clear` | other | - | bounded | the colour channels are continuous and bounded: clamped to 0..255, then rounded (Q7) |
| `gfx_clip` | other | - | geometry | the clip rect is continuous geometry: intersected with the drawable area in float space, then rounded (Q7) |
| `gfx_delay` | other | - | magnitude | the milliseconds are a continuous duration: rounded; a delay Uint32 cannot hold raises (Q7 magnitude) |
| `gfx_fb` | int-requiring | - | geometry | w and h lay out the pixel buffer (integer-valued: N5, Q1); its elements are palette bytes read through the Q1 byte reader; dx, dy and scale are continuous geometry: the destination rect is clipped in float space, then rounded (Q7) |
| `gfx_line` | other | - | geometry,bounded | the endpoints are continuous geometry: the segment is clipped in float space against the drawable area, then rounded; the colour is bounded (Q7) |
| `gfx_open` | other | - | magnitude | window width and height are continuous sizes with no drawable area yet to clip against: rounded, and a size the C int cannot hold raises (Q7 magnitude) |
| `gfx_point` | other | - | geometry,bounded | the position is continuous geometry: a point outside the drawable area draws nothing; the colour is bounded (Q7) |
| `gfx_poll` | int-preserving | - | - | event fields x, y, scancode, button are ints |
| `gfx_read` | other | - | geometry | the origin is continuous geometry: rounded, and a point outside the drawable area reads nothing (Q7); returns the channel values as ints |
| `gfx_rect` | other | - | geometry,bounded | the rect is continuous geometry: intersected with the drawable area in float space, then rounded; the colour is bounded (Q7) |
| `gfx_rrect` | other | - | geometry,bounded | the rect and radius are continuous geometry: clipped in float space, then rounded; the colour is bounded (Q7) |
| `gfx_text` | other | - | geometry,bounded | the position and scale are continuous geometry: each glyph cell is clipped in float space, then rounded; the colour is bounded (Q7) |
| `gfx_text_height` | int-preserving | - | magnitude | pixel height, an int; the scale is continuous, and a measurement has no drawable area to clip against: rounded, and a scale the C int cannot hold raises (Q7 magnitude) |
| `gfx_text_width` | int-preserving | - | magnitude | pixel width, an int; the scale is continuous, and a measurement has no drawable area to clip against: rounded, and a scale the C int cannot hold raises (Q7 magnitude) |
| `gfx_ticks` | int-preserving | - | - | SDL ticks (Uint32 ms) |
| `hex` | int-requiring | LOSS | - | refuses above 2^53 by a double compare, so int 2^53+1 reads as 2^53 and passes silently |
| `http_early_bind` | int-requiring | - | - | port |
| `http_post` | other | - | - | header values via value_to_string (N6) |
| `http_route` | other | - | - | formats via value_to_string |
| `http_route_authed` | other | - | - | formats via value_to_string |
| `http_serve` | int-requiring | - | - | port |
| `http_static` | other | - | - | formats via value_to_string |
| `index_of` | int-preserving | - | - | byte index or -1 |
| `inflate` | int-requiring | - | - | byte values: N5, then 0..255 (Q1; the modulo-256 wrap is gone) |
| `join` | other | - | - | elements via value_to_string (N6) |
| `json_build` | other | LOSS | - | N14 encoder; reads values through eigs_num_arg (a double) |
| `json_decode` | other | LOSS | - | N14 decoder; integer text decodes through strtod (a double) |
| `json_encode` | other | LOSS | - | N13/N14 encoder; reads values through eigs_num_arg; its `default:` writes null (builtins.c:998) |
| `json_path` | other | LOSS | - | decodes with strtod, then formats (N14, N6) |
| `leaky_relu` | float-producing | - | - | ML activation (float tensors; no Lua counterpart) |
| `len` | int-preserving | - | - | count (Lua `#` is an integer) |
| `list_contains` | other | - | - | equality via values_equal (N2) |
| `list_index_of` | int-preserving | - | - | returns an index; equality via values_equal (N2) |
| `list_insert_at` | int-requiring | - | - | position (Lua table.insert) |
| `list_remove_at` | int-requiring | - | - | position (Lua table.remove) |
| `list_slice` | int-requiring | - | - | start and end indices |
| `list_truncate` | int-requiring | - | - | new length |
| `log` | float-producing | - | - | Lua math.log; log of 0 is -inf (N11) |
| `log_softmax` | float-producing | - | - | ML (float) |
| `matmul` | float-producing | - | - | float tensors |
| `matmul_at` | float-producing | - | - | float tensors |
| `matmul_bt` | float-producing | - | - | float tensors |
| `max` | int-preserving | LOSS | - | Lua math.max returns the winning argument with its own subtype; a NaN argument makes the result NaN (Q8: IEEE 754-2019 maximum) |
| `mean` | float-producing | - | - | arithmetic mean |
| `min` | int-preserving | LOSS | - | Lua math.min; a NaN argument makes the result NaN (Q8: IEEE 754-2019 minimum) |
| `model_load_weights` | other | - | - | alias of eigen_model_load |
| `monotonic_ms` | float-producing | - | - | fractional milliseconds |
| `monotonic_ns` | int-preserving | LOSS | - | exact below 2^53 ns (104 days of uptime), a rounded double after; an exact int under N1 |
| `multiply` | int-preserving | LOSS | - | scalar arm mirrors `*` (overflow raises, (A)); buffer arms float |
| `native_train_step_builtin` | int-requiring | - | - | token ids are integer-valued (N5, Q1); lr is a float (a numeric string is accepted through strtod) |
| `nearest_in_range` | float-producing | - | - | geometry floats; the `index` field is an int |
| `nearest_in_range_all` | float-producing | - | - | geometry floats; the `index` field is an int |
| `negative` | int-preserving | LOSS | - | mirrors unary `-`; negating INT64_MIN raises (N4b) |
| `net_accept` | int-requiring | - | - | socket handle |
| `net_close` | int-requiring | - | - | socket handle |
| `net_dial` | int-requiring | - | - | port; returns a handle |
| `net_listen` | int-requiring | - | - | port; returns a handle |
| `net_port` | int-requiring | - | - | socket handle; returns a port |
| `net_recv` | int-requiring | - | - | handle and max bytes |
| `net_send` | int-requiring | - | - | the handle and the byte values: N5, bytes then 0..255 (Q1; the modulo-256 wrap is gone) |
| `norm` | float-producing | - | - | L2 norm |
| `num` | other | LOSS | - | N10 parser: integer text decodes through strtod today (a double) |
| `num_copy` | int-preserving | LOSS | - | copies a number and must keep its subtype; today re-boxes through a double |
| `numerical_grad` | float-producing | - | - | finite differences |
| `numerical_grad_cols` | float-producing | - | - | finite differences; column indices int |
| `numerical_grad_rows` | float-producing | - | - | finite differences; row indices int |
| `observe` | other | - | - | observer readouts (O4) |
| `ord` | int-preserving | - | - | byte code (Lua string.byte) |
| `pi` | float-producing | - | - | Lua math.pi |
| `pow` | float-producing | - | - | mirrors `^` (Lua §3.4.1: exponentiation is always float) |
| `ppu_render_frame` | int-requiring | - | - | reads the emulated memory buffer through `buffer_read_byte`: byte values by N5, then 0..255 (Q1; the modulo-256 wrap is gone) |
| `print` | other | - | - | N6 printing via value_to_string |
| `proc_read_buf` | int-requiring | - | - | fd and max bytes; bytes stored as floats |
| `random` | float-producing | - | - | Lua math.random() in [0,1) |
| `random_hex` | int-requiring | - | - | digit count |
| `random_int` | int-requiring | LOSS | - | Lua math.random(m, n) is an integer; bounds read as doubles today |
| `random_normal` | float-producing | - | - | dims int; samples float |
| `range` | int-preserving | - | - | bounds by N5; the elements are ints (floats today, inside int range) |
| `read_bytes` | int-preserving | - | - | byte values 0..255 |
| `read_bytes_buf` | int-requiring | - | - | cap and length; bytes stored as floats |
| `record_history` | other | - | - | truthiness flag in; previous flag out |
| `recv` | int-requiring | - | - | channel handle ids |
| `recv_timeout` | int-requiring | - | magnitude | the channel handle: N5 (Q1); the milliseconds are a continuous duration: a timeout the C long cannot hold raises (Q7 magnitude) |
| `relu` | float-producing | - | - | ML activation (float tensors; no Lua counterpart) |
| `reshape` | int-requiring | - | - | rows and cols |
| `round` | int-preserving | LOSS | - | no Lua counterpart; follows floor and ceil (Q4) |
| `sandbox_run` | int-requiring | - | - | iteration, byte and work limits; returns line ints |
| `scan_int_tokens` | int-preserving | LOSS | - | integers accumulate in a double |
| `scan_ints` | int-preserving | LOSS | - | integers accumulate in a double |
| `scatter_add` | float-producing | - | - | indices are exactness-checked today, but raise an index error for 1.5; R1.6 reads them through the N5 index reader (`value`); float accumulation |
| `seed_random` | int-requiring | LOSS | - | `(long)` of a double; Lua randomseed takes integers |
| `send` | int-requiring | - | - | channel handle ids |
| `set_at` | int-requiring | - | - | index, row and col; a buffer value converts to float |
| `sgd_update` | float-producing | - | - | float update |
| `sgd_update_cols` | float-producing | - | - | column indices int |
| `sgd_update_rows` | float-producing | - | - | row indices int |
| `shape` | int-preserving | - | - | dimension counts |
| `shared_delete` | int-preserving | - | - | removed count |
| `shared_incr` | int-preserving | LOSS | - | shared counter: delta and stored value in doubles |
| `shared_size` | int-preserving | - | - | entry count |
| `sign_extend` | int-requiring | LOSS | - | `(int64_t)` of a double |
| `sin` | float-producing | - | - | Lua math.sin |
| `softmax` | float-producing | - | - | ML (float) |
| `sort` | other | LOSS | - | sort_cmp_num compares doubles: ints beyond 2^53 tie (N2 needs exact); from R2.2 floats sort by IEEE totalOrder, NaN after +inf (Q8) |
| `sort_by` | other | LOSS | - | key results compared as doubles; from R2.2 by IEEE totalOrder, NaN after +inf (Q8) |
| `spawn` | int-preserving | - | - | handle dict with int id/gen fields |
| `sqrt` | float-producing | - | - | Lua math.sqrt; sqrt of -1 is NaN (N11) |
| `state_at` | int-requiring | - | - | step index |
| `store_close` | int-requiring | - | - | handle id/gen |
| `store_collections` | int-requiring | - | - | handle id |
| `store_count` | int-requiring | - | - | handle and page ids; returns a count |
| `store_delete` | int-requiring | LOSS | - | key formatted `%d` of an `(int)` cast: 1.9 finds "1"; keys above INT_MAX are UB (probed) |
| `store_drop` | int-requiring | - | - | handle and page ids |
| `store_get` | int-requiring | LOSS | - | same key cast as store_delete; decodes records (N14) |
| `store_open` | int-preserving | - | - | handle dict with int id/gen fields |
| `store_put` | other | LOSS | - | the record encoder writes a non-int32 number with `%.15g`: 1234567890123456 is stored as 1234567890123460 and 0.1 + 0.2 as 0.3, on main and the tag (#1762). R1.7: the N6/N14 writer; R2.3: refusal inside the encoder |
| `store_query` | other | LOSS | - | decodes records; integer text through strtod (N14) |
| `store_update` | other | LOSS | - | same key cast as store_delete; re-puts through the `%.15g` encoder (#1762); N13/N14 |
| `str` | other | - | - | N6 printing via value_to_string |
| `str_from_bytes` | int-requiring | - | - | byte values: N5, then 0..255 (Q1; Lua string.char raises on 65.5 and on 256) |
| `stream_open` | int-requiring | - | - | element count, already floor-checked |
| `stream_write` | float-producing | - | - | writes a raw f64 |
| `substr` | int-requiring | - | - | start and length (Lua string.sub) |
| `subtract` | int-preserving | LOSS | - | scalar arm mirrors `-` (overflow raises, (A)) |
| `sum` | int-preserving | LOSS | - | an all-int input sums exactly, and overflow raises (A); today a guarded double sum |
| `tan` | float-producing | - | - | Lua math.tan |
| `task_alive` | int-requiring | - | - | task handle (packed below 2^53, exactness-checked) |
| `task_detach` | int-requiring | - | - | task handle |
| `task_join` | int-requiring | - | - | task handle |
| `task_kill` | int-requiring | - | - | task handle |
| `task_sched_seed` | int-requiring | LOSS | - | `(int64_t)` of a double |
| `task_self` | int-preserving | - | - | task handle |
| `task_send` | int-requiring | - | - | task handle |
| `task_sleep` | other | - | - | milliseconds of virtual time, kept as a float: no C integer conversion, so Q7 does not apply |
| `task_spawn` | int-preserving | - | - | returns a task handle |
| `tensor_load` | float-producing | - | - | float tensor; shape ints |
| `tensor_save` | float-producing | - | - | writes float cells |
| `text_builder_append` | other | - | - | formats via value_to_string (N6) |
| `text_builder_append_line` | other | - | - | formats via value_to_string (N6) |
| `thread_join` | int-requiring | - | - | thread handle id/gen |
| `throw` | other | - | - | message via value_to_string |
| `token_name` | int-requiring | - | - | token id |
| `try_recv` | int-requiring | - | - | channel handle ids |
| `type` | other | - | - | `type of` an int or a float is "num" ((B)) |
| `usleep` | other | - | magnitude | the microseconds are a continuous duration: rounded; a sleep the C int cannot hold raises (Q7 magnitude) |
| `vm_run_bytecode` | int-requiring | - | - | opcode bytes and ABI numbers |
| `write` | other | - | - | N6 printing |
| `write_bytes` | int-requiring | - | - | byte values: N5, then 0..255 (Q1; the modulo-256 wrap is gone); returns bytes written |
| `zeros` | int-requiring | - | - | size or [rows, cols]; elements are float 0.0 |
| `zeros_like` | float-producing | - | - | float zeros |
<!-- builtin-table:end -->

**Builtins to add**, outside the checked table until they exist:
- `num_type` (N7);
- `f64_bits` and `f64_from_bits`, plus buffer bits get/set (N12);
- the N9 width family: wrapping, checked and saturating i8..i64 and u8..u64;
  unsigned compare, div, rem and to-string; `fround`.

---

## 7. Semantics-to-sites map

Each item lists the files and functions that implement it. The site lists
inside each function are in `docs/design/phase2-inventory.txt`. All line
numbers are at `0740af03`.

- **N1 (int literals; decimal outside int64 is a float; hex wraps):**
  - lexer.c:717-753 (number lexing, hex accumulates in a double today);
    the token's `num_val` (eigenscript.h:188);
  - parser.c:791 (`TOK_NUM` to `AST_NUM`, `data.num`);
  - compiler.c:2071-2077 (`AST_NUM` emission, reading the renamed payload):
    from R1.3 an int literal emits the new `OP_INT_ZERO`/`OP_INT_ONE`/
    `OP_INT_CONST`, and a float literal keeps `OP_NUM_ZERO`/`OP_NUM_ONE`/
    `OP_CONST` (§2.7); compiler.c:2929/2985/3030 (index fast paths read
    `data.num`);
  - vm.h `OpCode` (the three opcodes appended, each `/*obs:NONE*/`), and the
    exhaustive switches that must name them: `op_name` (chunk.c:337),
    `op_verify_operands` (chunk.c:466), `op_verify_stack_effect`
    (chunk.c:615), `op_stack_effect` (compiler.c:305); the interpreter's
    dispatch table (vm.c:3091) and three new CASEs; `tests/test_opcode_abi.c`;
  - chunk.c:193-260 (constant pool dedup: `const_hash_value`, `const_equal`,
    `chunk_add_constant_ex`, which must key on kind and bits);
  - vm.c:3238 `CASE(CONST)` and 3257 `CASE(NUM_ZERO)`/`NUM_ONE`: renamed,
    float meaning unchanged;
  - the JIT: the scanner refuses the new opcodes in round 1 (round 5 emits
    them); its `NUM_ZERO`/`NUM_ONE`/`CONST` emitters (jit.c:2797/2816) keep
    their float meaning (§4.2);
  - the leaf evaluator: its scanner refuses the new opcodes (chunk.c:1129,
    the `default:`); its `CONST`, `NUM_ZERO` and `NUM_ONE` arms
    (vm.c:1866-1877) keep their float meaning (§4.5);
  - lint.c, lint_host.c and eigenlsp.c (the `AST_NUM` type knowledge, 34
    sites);
  - `src/freestanding/mini_strtod.c`;
  - ouroboros `src/frontend.eigs` (the AOT's lexer).
- **N2 (subtype visible; exact comparison across kinds):**
  - vm.c:3579 `CASE(EQ)`, 3600 `CASE(NE)` and 3621 `NUM_CMP`;
  - eigenscript.c:2849 `values_equal_impl`;
  - builtins.c:5868 `sort_cmp_num`, and `sort_by`, `list_contains`,
    `list_index_of`;
  - JIT comparisons bail on SMI (§4.1).
  - The exact int/float compare:
    - if the float is NaN, the result is unordered (every comparison
      false except `!=`);
    - if `f >= 2^63`, the float is greater than every int; if `f < -2^63`,
      it is smaller;
    - otherwise compare `i` with `fl = (int64_t)floor(f)`: `i < fl` or
      `i > fl` decides, and when `i == fl` the float is greater exactly when
      `f != floor(f)`.
    - Lua's `LTintfloat`/`EQintfloat` (lvm.c) reach the same answers by
      converting whichever side converts exactly.
- **N3 (`+ - *` on ints give an int; overflow raises):**
  - vm.c:3290 `ARITH_FAST`, 3324 `CASE(ADD)` and 3377 `NUM_BINOP`
    (SUB, MUL);
  - builtins_tensor.c `op_add`, `op_sub`, `op_mul` and
    `tensor_elementwise` (the scalar arms of `add`, `subtract`,
    `multiply`), plus `sum` and `shared_incr`;
  - JIT bails (§4.1);
  - the leaf's `ADD`/`SUB`/`MUL` arm (vm.c:1933-1956): bails unless both
    operands are floats in round 1, so int, mixed and overflowing operations
    take the generic path (§4.5).
- **N4 (`/` float; `//` new; `%` floor; division by zero):**
  - vm.c:3407 `CASE(DIV)` (int/int gives a float) and 3432 `CASE(MOD)`
    (fmod becomes floor-mod; int by zero raises);
  - **new `OP_IDIV`**, appended at the end of `OpCode` (vm.h). The
    extend-vm checklist applies: dispatch table, handler, `op_name`
    (chunk.c), `op_stack_effect` (compiler.c), an `/*obs:NONE*/` marker
    (`tools/obs_marker_check.sh`) and `tests/test_opcode_abi.c`. Appending
    needs no `EIGS_BYTECODE_ABI` bump.
  - Lexer: `//` lexes as two `TOK_SLASH` today, so a new `TOK_SLASH_SLASH`
    is appended to the token enum, the X2 table (lexer.c:241) and the token
    text (lexer.c:357).
  - parser.c (multiplicative level), fmt.c, lint, the LSP and ouroboros
    `frontend.eigs`;
  - JIT MOD (§4.2).
  - Float `x % 0` (NaN) and `x / 0` (inf) wait for N11 in round 2.
- **N4b (INT64_MIN edges):**
  - vm.c:3522 `CASE(NEG)` (int arm raises on INT64_MIN);
  - builtins.c `builtin_abs` (2056);
  - the new `OP_IDIV` (`x // -1`);
  - `CASE(MOD)`: `INT64_MIN % -1` is 0, computed without `idiv`, which
    faults on x86.
- **N5 (float-to-int by the exact rule wherever an int is needed):**
  - eigenscript.h:1910 `num_to_i64_exact` (#1740);
  - every int-requiring row of §6, through `eigs_int_arg` (with
    `eigs_int_arg_range`, `eigs_byte_arg` for Q1's integer-valued
    parameters; the Q7 readers `eigs_geom_shape`, `eigs_bounded_arg` and
    `eigs_magnitude_arg` for its continuous ones);
  - vm.c index paths (`jit_helper_index_get`/`set`, `CASE(INDEX_*)`) and
    `range_bound` (builtins.c:3877);
  - the JIT `OP_INDEX_SET` integrality guard (jit.c:4100-4112) stays
    correct, because a non-exact index goes to the helper;
  - the leaf's `INDEX_GET` arm (vm.c:1907-1931): in round 1 it bails on an
    int index (the generic path applies N5), and a float index still goes
    through `vm_index_is_int`;
  - `buffer_read_byte` and `finite_num_to_byte` (Q1 byte values), deleted
    in R1.6 (§2.7), and the byte reads `buffer_read_num` performs today:
    `buf_from_pcm16le` (builtins_buf.c:754, :756; #1758 comment 6174964306),
    `str_from_bytes` (:240), `f64_from_bytes` (:284), the zlib input (:351),
    `write_bytes` (builtins_host.c:1548) and `net_send` (ext_net.c:361), each
    through `buffer_byte_at` after R1.6 renames `buffer_read_num`;
  - the index reads: `gather`'s `flat_index_at` (builtins_tensor.c:1428-1440,
    both its list path and its buffer path truncate today) and
    `scatter_add` (:1036, exactness-checked but raising an index error),
    each through `buffer_index_at` or `eigs_int_arg` (N5, `value`);
  - the Q7 readers (§2.6) for every continuous parameter the `q7` column
    names: the gfx shapes (ext_gfx.c), the audio samples, gains and
    durations, `usleep`, `gfx_delay`, `exec_capture`, `recv_timeout`.
- **N6 (printing):**
  - eigenscript.c:2938 `eigs_num_text` (today integral doubles below 2^53
    print without `.0`) and 2957 `value_to_string`;
  - the f-string conversion (`EIGS_FSTR_CONV_NAME`, builtins.c:6207);
  - vm.c `obs_dump_num` (106);
  - chunk.c `chunk_disassemble`;
  - the JSON encoders (h);
  - trace.c's `%.17g` writers (2817, 2836, 2950), whose tape text is §7 T1;
  - `src/freestanding/mini_fmt.c`.
  - Also chunk.c:196, the constant dedup folding `-0.0` into `+0.0`. Under
    N6, `-0.0` prints `-0.0`, so the dedup must compare bits.
- **N7 (B: `type of` is `"num"`; `num_type`):**
  - builtins.c:864 `builtin_type`, unchanged;
  - `val_type_name(VAL_INT)` returns `"num"`;
  - vm.c:5476 `who`, which answers "number";
  - new `num_type` (builtins.c, registration at 6184).
- **N8 (bitwise on ints, Lua shift rules):**
  - vm.c:3459 `INT_BINOP_R` (`& 63` becomes Lua's rule; `>>` becomes
    logical) and 3548 `CASE(BNOT)`;
  - builtins.c:349-414 `bit_*`;
  - JIT bitwise is refused (§4.2).
- **N9 (width builtins):** new code (builtins.c or a new `builtins_int.c`);
  `fround` (`(double)(float)x`).
- **N10 (`num of`):** builtins.c:494 `builtin_num` (partial input #1638,
  radix prefixes, int or float result).
- **N11 (IEEE doubles; strict becomes opt-in):**
  - eigenscript.h:1876 `num_guard`, `num_guard_named`, `EIGS_NUM_MAX` and
    `STRICT_DOMAIN`: the 74 clamp sites (`num_guard` 60, `num_guard_named`
    6, `EIGS_NUM_MAX` 8);
  - builtins_tensor.c `op_sqrt` (711) and `op_log_safe` (729);
  - builtins.c `asin`/`acos` domain;
  - state.c:62 `st->strict` defaults to 1 and must become opt-in;
  - jit.c:2634 `max_normal_bits`;
  - the leaf's `num_guard(r)` (vm.c:1954), deleted with the others;
  - the consumers no token marks (§2.7): `values_equal_impl`'s identity
    shortcut (eigenscript.c, first line of the function) must not call a
    NaN box equal to itself; the sort comparators (`sort_cmp_num`,
    builtins.c:5868, and `sort_by`'s key comparison, 5815) order floats by
    IEEE `totalOrder`, NaN after +inf; `minmax_reduce` (builtins.c:2086-2088,
    `min`/`max`) propagates NaN (Q8, decided).
- **N12 (canonical NaN; payload fidelity through ints):**
  - value_slot.h:73 `slot_from_num`, becoming `slot_from_f64`: the single
    writer, including the leaf's five calls (vm.c:1869, 1873, 1876, 1927,
    1954), so a NaN the leaf computes is canonical too;
  - the JIT NaN bails (§4.3);
  - new `f64_bits`/`f64_from_bits` and buffer bits accessors;
  - builtins_buf.c `f64_from_bytes` and `f64_to_bytes`;
  - eigs_embed.c:339 (the host boundary; #1746 round 3, item 4).
- **N13 (refusal inside writers):**
  - builtins.c:907 `eigs_json_encode_value`;
  - ext_store.c's encoder: the #1746 residue is `store_nonfinite_scalar`
    (ext_store.c:278 on the experiment), which must be deleted in favour of
    refusal inside the encoder;
  - the byte encoders (`eigs_byte_arg`, which replaces `finite_num_to_byte`
    and `buffer_read_byte` in R1.6) and the `buf_to_pcm16le` quantizer;
  - every int conversion (`eigs_int_arg`, `num_to_i64_exact` callers);
  - the tape writers record, not refuse.
- **N14 (JSON):**
  - builtins.c:907 encode and 1406 `builtin_json_decode`, plus
    `eigs_json_parse_value`, `json_path` and `json_build`;
  - the ext_store.c record codec;
  - ext_http.c request/response JSON;
  - model_io.c `json_*` (model files).
- **(A) (overflow raises, no wraparound):** the N3 and N4b sites; `sum`,
  `shared_incr`, the `add`/`subtract`/`multiply` scalar arms; the N9
  builtins provide explicit wrapping.
- **(B):** as N7; `type of` and the 54 consumer `type of ... == "num"` lines
  keep working.
- **T1 (tape v7):**
  - trace.h:32 `TRACE_FORMAT_VERSION`, 6 becoming 7;
  - trace.c:2817 `write_value_ptr`, 2836 `write_slot` and 2950
    `write_value_ptr_full`: ints as digits, floats in a form that always
    shows the kind (N6 repr), `inf`/`-inf`/`nan` in round 2;
  - trace.c:2284 `parse_value_p`: digits only give an int, anything else
    goes through strtod as a float;
  - trace.c:2194 and tape_read.c:155 (version refusal);
  - tape_read.c:368 (the step reader's `strtod`);
  - eigsdap.c;
  - docs/TRACE.md (bump plus the compat decision, #411);
  - the `O cfg` record (trace.c:1577-1584 writes `h_low`; tape_read.c:389
    reads it). O3 drops it in round 3;
  - the leaf evaluator is off while recording (`g_trace_hist`, vm.c:2505
    and vm.c:4255), so a tape always holds the generic path's values; the
    `trace` tier (§9.2) gates that the live leaf agrees;
  - the Done-when's "record twice and replay strict byte-identically" for
    int, float, inf and NaN programs: rows `T1.twice-int` (R1.3),
    `T1.twice-float` (R1.7, N6's text), `T1.twice-inf` and `T1.twice-nan`
    (R2.5). Each records one deterministic program twice, requires
    byte-identical tapes, and replays strict against the live (leaf-on)
    output.
- **O1-O4 (observer, round 3):**
  - eigenscript.c:698 `observer_slot_record_value`, 804
    `observer_slot_update_num`, the `obs_num_*` predicates (935-1193) and
    `compute_entropy_impl` (435), from which entropy is removed for numerics;
  - vm.c `obs_slot_observable` (1630);
  - **the routing of an int into the numeric channel, from R1.3 (when the
    first int exists), converted to a double for the distance until round
    3.** Two paths, both forced before R1.3 and both live in R1.3:
    - **an SMI**: the observe sites test `slot_is_num` first (D1, forced in
      R1.1): `CASE(OBSERVE_ASSIGN_LOCAL)` (vm.c:5189, its elided
      `unobserved:` path at 5202), `CASE(OBSERVE_NAME_POST)` (5431),
      `jit_helper_observe_assign_local` (1678-1684) and
      `jit_helper_observe_name_post` (1730). Each gains `slot_is_smi(s)` ->
      `observer_slot_update_num(e, slot, (double)smi)` (or the sample form);
      `obs_slot_observable` aborts on an SMI that reaches it (§2.5);
    - **a boxed int** (an int outside [-2^47, 2^47), or any int a lift
      boxed): `obs_slot_observable` answers true for any pointer, so it goes
      to `observer_slot_update(Value *)` (eigenscript.c:769), whose number
      arm (`newval->type == VAL_NUM`, :785) feeds the value channel and whose
      `else` ends the numeric trajectory (#861). R1.2's `VAL_NUM` rename
      forces that arm; it gains `VAL_INT` ->
      `observer_slot_record_value(s, (double)i)`. The same holds for the
      elided `observer_slot_sample_gated` (:851, its arm at :852) and for
      `compute_entropy_impl`'s exhaustive switch (:437), whose `VAL_INT` arm
      gives an int the entropy of its double;
    - the MAP row `O1.int-observed-numeric` (R1.3) pins both: an SMI and a
      boxed int (2^47 and up) must answer every observer readout exactly as
      their float twins do;
  - vm.c:5460 `CASE(INTERROGATE)` (`where`/`why`/`how`);
  - `builtin_observe`;
  - the `O cfg` record;
  - tools/observer_oracle/score.py (the IEEE mode and `--floor` from the
    oracle PR).
- **The leaf evaluator, arm by arm** (vm.c:1856-1971, scanner
  chunk.c:1072-1134; every arm is in §4.5):
  - `CONST` (1866), `NUM_ZERO` (1872), `NUM_ONE` (1875): N1, float
    literals only; the renamed writer `slot_from_f64` (N12); int literals
    are refused by the scanner (§2.7);
  - `GET_LOCAL` (1878), `LOCAL_DOT_GET` (1883): borrow any slot, an SMI
    included (§2.5, `guarded`);
  - `INDEX_GET` (1907): N5 (index exactness), Q2 (a buffer element is an
    f64); bails on an int index in round 1;
  - `ADD`/`SUB`/`MUL` (1933): N3, (A), N2's float half, #1079's underflow
    flag, N11 (`num_guard` goes in R2.2), N12 (canonical NaN through
    `slot_from_f64`); bails unless both operands are floats in round 1;
  - `RETURN` (1957): unchanged;
  - the gate `!g_trace_hist` (vm.c:2505, vm.c:4255): T1, and the `trace`
    tier of §9.2.

---

## 8. Round plan

Every commit builds, passes the full suite, and carries its own MAP rows.
"Unchanged" means a differential against the baseline binary captured
before the commit (the verify-and-fix rule), not "the suite passed". Every
meaning change lands in the commit that carries its token change, or is in
§2.7's token-less list with its gate. `phase2_check.sh --through <commit>`
checks each commit against exactly the rows that have landed (§9.2).

### Where the first int value appears: R1.3

No int VALUE exists before R1.3, and this is structural, not a promise:
- `make_int` is introduced in R1.3, so nothing earlier can call it;
- `slot_from_int` exists from R1.1 (the C slot test needs it), but until R1.3
  its only production callers are the canonicalizing writers of §2.1, which
  convert an existing `VAL_INT`, and none exists. `phase2_check.sh --through
  R1.2` checks this: it derives the callers of `slot_from_int` and
  `make_int` from the source and fails on any caller outside that list
  (the int-source check). A producer can also write the tag bits without
  calling the writer, so the check fails on `TAG_SMI` or the SMI bit pattern
  anywhere outside its definitions in `value_slot.h`, and its dynamic half
  runs the corpus on a `make smi-trap` build, where every slot classifier
  aborts on an SMI and `slot_from_int` aborts on any call (the R1.1 fix
  round, after the critic's plants P3-P5);
- the lexer produces only float literals until R1.3, and the tape cannot
  carry an int until v7 (R1.3).

**Every consumer of an int is converted AT R1.3**, either by code forced and
written earlier (R1.1, R1.2) that goes live, or by code R1.3 adds:

| consumer | converted by | how it treats an int at R1.3 |
|---|---|---|
| VM arithmetic, comparison, negation (N2, N3, N4b, (A)) | R1.1 forced the arms (`slot_as_double` deleted); R1.3 adds the int semantics | exact int64, overflow raises |
| `/` and `%` | R1.3 (transitional) | converted to doubles, today's semantics, until R1.4 |
| bitwise operators | R1.3 (transitional) | exact int64 operands (#1740's rule), today's shift rule until R1.5 |
| equality, ordering, hashing, the constant pool | R1.2 (forced arms) | by value across kinds (N2); the pool keys on kind |
| printing (`value_to_string`, f-strings) | R1.2a (the exhaustive switch) | exact digits, as today for small ints |
| `type of`, `num_type` | R1.2a (`val_type_name`), R1.3 (`num_type`) | `"num"`; `"int"` |
| containers | R1.2 (the four canonicalizing writers) | an SMI, or a box outside the SMI range (§2.1) |
| the observer | R1.1 (SMI sites, D1) and R1.2 (the boxed arm at eigenscript.c:785, the entropy switch) | the numeric channel, as a double until round 3 (§7) |
| the tape | R1.3: v7 writer and parser | ints as digits, floats marked as floats; a v6 tape is refused |
| the JIT | nothing to convert: its guards bail on an SMI or a `VAL_INT` box (§4.1), and its scanner refuses `OP_INT_*` | interpreted |
| the leaf evaluator | R1.1 (its arithmetic and index arms bail) | the generic path computes it |
| builtins | the bridge (R1.2's number tests admit ints) | a double, exactly as the tag sees every number, until R1.6 |
| JSON, store and db encoders | R1.2a (their `VAL_INT` arms) | exact digits |
| the embed API (`eigs_value_as_num`) | R1.2 (its forced `VAL_NUM` test) | converts to a double (Q3) |
| lint and the LSP | R1.3 (the AST payload rename) | the literal's kind |

### Round 1: the core model (Alt 1R)

1. **R1.1, the slot layer: the SMI exists, every slot reader is forced (no
   producer).**
   - Add `TAG_SMI`, `slot_is_smi`, `slot_from_int`, `slot_smi_val`,
     `slot_f64_value` and `slot_int_value` (§2.6).
   - The token changes: `slot_is_num` -> `slot_is_f64`, `SLOT_NUM_RAW` ->
     `SLOT_F64_RAW`, `slot_from_num` -> `slot_from_f64`; `slot_is_numeric`
     deleted; **`slot_as_double` deleted**. Its 15 calls are rewritten with
     an explicit int decision: the arithmetic and compare arms take their
     float fast path through `slot_f64_value` and send anything else to the
     slow path; the leaf evaluator's `INDEX_GET` and `ADD`/`SUB`/`MUL` arms
     bail on anything that is not a float. 223 sites first forced (§2.3a).
   - The D2/D3 dispositions (§2.5): `eigs_slot_ref`, `obs_slot_observable`,
     `slot_as_ptr` and `slot_as_heap` refuse an SMI (abort; `slot_as_ptr`
     in ASan and debug builds); `slot_type_name` gains its SMI arm.
   - `tools/phase2_check.sh` lands here with its calibration (§9.2).
   - Gates (a mechanical round, zero MAP rows): the compile errors, the C
     slot test (§2.5) and plant 1 (§9.3); the int-source check; language
     behaviour unchanged (differential over the suite's `.eigs` corpus).
2. **R1.2, the Value layer (behaviour-preserving; no builtin decision).**
   - R1.2a: `VAL_INT` appended; `VAL_NUM` -> `VAL_FLOAT`, `num_` -> `f64_`,
     `VAL_NUM_RAW`/`VAL_NUM_OFFSET` renamed, with deprecated aliases as the
     progress meter; `val_type_name(VAL_INT) = "num"`; **the `default:` arm
     of `eigs_json_encode_value` (builtins.c:998) deleted**, so
     `-Werror=switch` reaches the last switch that could absorb `VAL_INT`
     silently.
   - R1.2b-n: one commit per file group. Each forced site gets its final
     int arm (dead until R1.3), and a builtin's number test admits an int
     and reads it through the bridge (§2.7). The bridge's names are NOT
     touched: no builtin's behaviour changes. 464 sites first forced.
   - R1.2z: delete the deprecated aliases. A straggler fails to compile.
   - Gates (a mechanical round, zero MAP rows): the compile errors; the
     differential over the suite's `.eigs` corpus (identical to the
     baseline); the int-source check.
3. **R1.3, the flip: the first int values.** See the table above.
   - N1, with its token changes in this same commit: the lexer produces an
     int literal; the AST payload `num` and the token's `num_val` become an
     `EigsNum`; **`OP_INT_ZERO`, `OP_INT_ONE` and `OP_INT_CONST` are
     appended** (the four exhaustive OpCode switches; three new interpreter
     CASEs; the JIT and leaf scanners refuse them by their `default:`);
     `make_int` is introduced. `OP_NUM_ZERO`/`OP_NUM_ONE`/`OP_CONST` keep
     their float meaning in all three executors.
   - N3 with (A), N2's exact cross-kind comparison, N4b `-x`, N7 `num_type`;
     EQ/NE's only bit fast path is "both SMI" (§2.1).
   - The JIT scanner refuses `BAND`/`BOR`/`BXOR`/`SHL`/`SHR`/`BNOT`/`MOD`.
   - **Tape v7 in this commit**: a v6 writer would print `3` for both kinds
     and replay would turn ints into floats. The float token marks its kind
     now (`3.0`); N6's repr replaces it in R1.7, still inside v7.
   - `eigs_int_unwired` is deleted: `slot_to_value` boxes an SMI with
     `make_int`, `slot_type` answers `VAL_INT`, `slot_view` gives a
     `VAL_INT` facade, `write_slot` writes v7 digits, and `slot_from_int`
     boxes an int outside the SMI range (each R1.1 placeholder, 2.5).
   - The observer routes an SMI and a boxed int into the numeric channel
     (§7).
   - The `trace` tier (the leaf differential) and the tier witnesses gate
     from here.
   - Risks: JIT int loops leave the JIT (§3: +70% Ir on a counter loop),
     and the leaf stops computing int helpers; declare the CodSpeed baseline
     move first. Consumer hashes that relied on double rounding now raise
     ((A)); they move to the N9 wrapping builtins.
4. **R1.4, N4.** `//` (token, parser, `OP_IDIV` appended,
   `op_name`/`op_stack_effect`/obs marker/ABI test), `//=` beside `/=` (Q6),
   `%` floor modulo for ints and floats, int division by zero raises,
   `INT64_MIN % -1` is 0.
5. **R1.5, N8.** Bitwise operators on ints with Lua's shift rules.
6. **R1.6, the bridge deletion: every builtin's §6 semantics.** The bridge's
   21 tokens are deleted (743 sites first forced), in per-file-group commits
   that each migrate their sites off the deprecated bridge and give those
   builtins their final behaviour in the same commit:
   - every int-preserving and int-requiring row, the 42 LOSS rows first;
   - Q1: integer-valued parameters through `eigs_int_arg_range`,
     `eigs_byte_arg`, `buffer_byte_at` and `buffer_index_at`;
   - Q7: continuous parameters through `eigs_geom_shape`,
     `eigs_bounded_arg` and `eigs_magnitude_arg` (§2.6);
   - Q4 `round`; `num of` (#1638) and the decoders' int kinds for integer
     text (`json_decode`, `json_path`, `store_query`, `db_query_value`); the
     N9 width family;
   - gate: the per-builtin behaviour table (§9.4), on the tag and the branch.
7. **R1.7, the float text (N6) and N14's writers.**
   - Python-repr floats; ints as exact digits.
   - The constant dedup compares bits, so `-0.0` survives.
   - JSON writes floats with `.0`; #1762's writers (`store_json_encode`,
     `db_build_query`) go through the same N6 writer, unless #1762 landed on
     main first.
   - `src/freestanding/mini_fmt.c` and `mini_strtod.c` follow, gated by
     `make freestanding-libc-diff`.
   - This is the largest visible change: every golden that prints an
     integral float.
8. **R1.8, the embed API (Q3), lint/LSP type knowledge and docs.**
   `eigs_value_as_num` converts an int (like `lua_tonumber`);
   `eigs_value_new_int`, `eigs_value_as_int` (with a success flag, like
   `lua_tointegerx`) and `eigs_value_is_int` are added; `EIGS_TYPE_NUM`
   covers both kinds. Gate: `gate.N7.embed-int` (the embed smoke test), the
   executed doc fences (suite [89]/[90]) and the LSP and lint suite sections.
   Docs: SPEC, COMPARISON, README, llms.txt; the CLAUDE.md same-PR docs rule
   applies to the integration PR as a whole.

### Round 2: IEEE (N11-N14 remainder), on the experiment's evidence

1. **R2.1, canonical NaN at the single double writer** (`slot_from_f64`)
   **and the JIT NaN bails** (§4.3), while `num_guard` still keeps NaN out:
   memory safety first. A mechanical round (no program can make a NaN yet):
   the C slot test writes every tag-spelling NaN payload, and the #1746
   plant (a raw store) segfaults in `slot_incref`.
2. **R2.2, retire `num_guard`, `num_guard_named`, `EIGS_NUM_MAX` and the
   1e308 clamp** (74 sites, the leaf's included; 47 first forced here).
   `EIGS_STRICT` becomes an opt-in trap (state.c:62). `sqrt of -1` is NaN,
   `log of 0` is -inf, `x/0` is ±inf, `0/0` and float `x%0` are NaN. Q8:
   `sort`/`sort_by` order floats by IEEE `totalOrder` (NaN after +inf), and
   `min`/`max` propagate NaN. `values_equal_impl`'s identity shortcut
   excludes floats.
3. **R2.3, N13 refusal inside the writers:** the JSON encoder, the store
   encoder (delete the pre-walk `store_nonfinite_scalar`), the byte
   encoders and the int conversion. This removes the class #1746 chased for
   three rounds, rather than its instances.
4. **R2.4, N12.** `f64_bits`/`f64_from_bits`, buffer bits get/set, and a
   canonical NaN at the embed boundary.
5. **R2.5, tape v7 `inf`/`-inf`/`nan` tokens; N6 non-finite printing;
   N14 `1e400` raises.**
6. **R2.6, the #1746 residue:**
   - the internal `(int)` casts the Q7 readers do not cover (the audio
     generators' `dur * rate`, the model builtins);
   - `net_send` continuing after a raise (ext_net.c:364);
   - `buf_to_pcm16le` with a NaN sample;
   - the `numerical_grad` waiver.

### Risks across both rounds

- The AOT is a round of its own (ouroboros, pinned to the integration SHA).
  Its numeric model is C `double` throughout: 294 `double` in aot_rt.h and
  228 in compile.eigs, with `make_num` 40+27 and `num_guard` 61+27. Under
  Alt 1R its generated C fails to compile against the renamed runtime,
  which is loud.
  - The AOT's existing int census (a `long` storage regime for counters)
    must follow literal kinds, not inference.
  - `fuzzdiff` must never apply `ULP_BOUND` to an int result (the
    aot-differential skill: "Integer data compare exactly even inside a
    reduction arm").
- Consumers. N6 printing moves goldens in all 16; N4 changes `%` on
  negatives; (A) raises where doubles lost precision silently; Q1 raises on
  a non-integral count, handle or byte, and on a byte outside 0..255 that
  used to wrap; Q7 raises on a duration or window size the C call cannot
  honour. The DMG emulator feeds `ppu_render_frame` its memory buffer
  through `buffer_read_byte`; the consumer acceptance run (Done-when) shows
  whether any program stored a non-byte there.
- Observer. Until round 3, ints are observed as their double value (the
  distance channel works on doubles), so `where`/`why`/`how` keep today's
  meaning.
- The leaf evaluator. It is off while recording, so every recorded run and
  every live run compute leaf helpers on different evaluators. The `trace`
  tier is the only thing that keeps them equal; it runs on every row.

---

## 9. Test plan

### 9.1 `tests/phase2/MAP.md`

The skeleton is committed with this design. Every item (N1-N14, N4b, (A),
(B), T1, O1-O4) has planned rows, each recording:
- an id;
- the program;
- the expected branch output;
- the round that lands it;
- why the row **fails on the v0.46.0 tag**;
- its **shape** and its **tier witness** (below).

Behaviour the branch must *preserve* (`1 == 1.0` is true on both binaries)
cannot fail on the tag, so it is pinned two ways:
- inside a mapped row that also checks the kind (the row fails on the tag
  because the kind is invisible there);
- as a separate **control** row, counted on its own line and never in
  `tag_fail` (§121: each population pinned separately).

**Shapes.** The round-0 rows were all module-level straight-line code. The
critic ran them: both JIT tiers printed `[jit] scanned=0 compiled=0`, so
`phase2_check.sh`'s three tiers would have run the interpreter three times,
and no row reached a JIT producer emitter or the leaf evaluator. Every row
now has one of four shapes:
- `S`: straight-line module code. It runs interpreted in every tier and
  claims nothing about tiers (witness `none`). These rows pin semantics.
- `L`: a one-line helper, `define h(x) as: return <expr>`, called K >= 1
  times: the leaf evaluator's shape (§4.5).
- `F`: a multi-statement function called at least 60 times, above the
  default entry threshold of 50 (jit.c:2478): the function JIT's shape.
  `EIGS_JIT_HOT` records a chunk's LAST run, so the witnessed call must be
  the function's last call (round 2's two truthiness controls ended on a
  float call and could not hold; both are reordered).
- `O`: a `loop while true:` loop, in a function or at module level, run in
  the `osr` tier (`EIGS_JIT_OSR_THRESHOLD=1`), **whose only exit is a
  `return` placed right after the claimed ops** (`if <done>: return <r>`; at
  module level, `print of <r>` first). The OSR thunk's record holds only its
  last entry, and with a `loop while <cond>:` header that entry is always the
  final condition check, which exits through the header whether or not the
  body ever ran natively. With the return inside the body, the only way the
  last entry ends at the return sentinel is to run the whole body natively
  first.

The `L`, `F` and `O` rows (35 in the MAP) cover every JIT-emitter and leaf
arm that holds a numeric site (the inventory's `## Numeric arms`, 20 today;
§9.2 checks the coverage): the literals (`NUM_ZERO`, `NUM_ONE`, `CONST` and
the new `INT_*`), the arithmetic, `DIV`/`MOD`, `NEG`/`NOT`/`BNOT`, the
comparisons, the bitwise ops, the conditional jumps, the field, local, name
and index stores, and the leaf's `INDEX_GET`, over ints and floats, with
overflow rows for the leaf, the function JIT and OSR.

**Tier witnesses.** A row that claims a tier must prove the tier ran its
operation; otherwise it is **VACUOUS**, a FAIL with its own counter. The
witness line is `witness: <kind> <chunk>... [<OP>]` (a `leaf` or `leaf-gen`
witness may name several helpers, each of which must hold), followed by
`ops: <OP>...`, the opcodes whose JIT or leaf arm the row exercises:

| kind | holds when (read from the branch run) |
|---|---|
| `none` | no claim (shape `S`) |
| `leaf <fn>` | in every tier, the normal run's `EIGS_JIT_HOT` table has no entries for `<fn>`, and the `trace` run (leaf off) has K >= 1: the leaf computed every call |
| `leaf-gen <fn>` | the normal run and the `trace` run both show the same K >= 1 entries: every call took the generic path (the scanner refused the chunk, or the leaf bailed) |
| `fn <fn>` | in the default and `osr` tiers, `<fn>`'s row has `jit yes` and `adv RET`: its last call ran natively to its return |
| `fn-stop <fn> <OP>` | `jit yes`, and the opcode at offset `adv` of `<fn>`'s bytecode (`EIGS_DUMP_BC=1`) is `<OP>`: the thunk handed back at `<OP>`, by a compile stop or a guard bail |
| `osr <chunk>` | in the `osr` tier, `<chunk>`'s row has `osr yes` and `oadv == len`: the OSR thunk's last entry reached the return sentinel (jit_advance -1, which `EIGS_JIT_HOT` prints as the chunk length, jit.c:244), so it ran the whole body natively on the way. Round 2's form (`oent + oadv` past `JUMP_BACK`) is withdrawn: the critic's plant ran native `INDEX_SET` 0 times and still passed it |
| `osr-stop <chunk> <OP>` | `osr yes`, `oadv != len`, and the opcode at `oent + oadv` is `<OP>`: every entry handed back at `<OP>` |

Why `EIGS_JIT_HOT` and not only `EIGS_JIT_STATS`/`EIGS_JIT_STOPS`:
`STATS` counts are process-wide (`scanned`, `compiled`), and `STOPS` records
where each compile's prefix ended. Neither says whether a run executed the
operation natively. `HOT` records, per chunk, the last run's native advance
(`adv` for the function thunk, `oadv` from `oent` for the OSR thunk, jit.c:
237-245), which is exactly that. `phase2_check.sh` reads all three: `STATS`
must show `compiled >= 1` for an `fn`/`osr` claim, and for a `-stop` claim
whose stop is a compile stop, `STOPS` must name `<OP>`. The leaf has no
counter; its witness is the entry count, because both generic call paths
count an entry (vm.c:2617, vm.c:4353) and the leaf path never does.

**Calibrated on the main binary: every kind holds on its honest row and is
VACUOUS on a plant where the claimed op did not run as claimed** (design
round 3; a scratch model of the predicates read `EIGS_JIT_HOT` and
`EIGS_DUMP_BC`; the `osr` pair also counted native `jit_helper_index_set`
calls under gdb, with the critic's `gdbcount.gdb`):

| kind | honest row (main) | evidence | plant | evidence |
|---|---|---|---|---|
| `leaf sq` | `define sq(x) as: return x * x`, one call with 1.5 | `sq normal=0 trace=1`: HOLDS | the body split into two statements (not leaf-eligible) | `sq normal=1 trace=1`: VACUOUS |
| `leaf-gen nth` | `define nth(xs, i) as: return xs[i]`, called on a string (the leaf's `INDEX_GET` bails) | `nth normal=1 trace=1`: HOLDS | called on a list (the leaf computes it) | `nth normal=0 trace=1`: VACUOUS |
| `fn keep` | `t is q / return t`, 60 calls with 2.5 | `keep jit=yes adv=RET`: HOLDS | `zz is [q]` first (the scanner stops at `LIST`) | `keep jit=no stop=LIST`: VACUOUS |
| `fn-stop cat ADD` | `t is a + b / return t`, 60 calls with two strings (the `ADD` guard bails) | `cat jit=yes adv=11`, offset 11 is `ADD`: HOLDS | 60 calls with two floats | `adv=RET`: VACUOUS |
| `osr fill` | the critic's `osr_ret`: `loop while true: (xs[i] is big / i is i + 1.0 / if i >= n: return xs)` | `osr=yes oadv=123 len=123 oent=37`; 3 native `INDEX_SET` helper calls: HOLDS | the critic's `osr_ret_PLANT2`: `s is s + "a"` first in the body | `oadv=20 len=157`; 0 native calls: VACUOUS |
| `osr fill`, round 2's shape | `loop while i < n:` (the critic's `osr_index_set`) | 3 native calls, but no sentinel: VACUOUS under the new rule | `zz is [i]` first (`osr_index_set_PLANT`) | 0 native calls; `oent + oadv` = 109, past `JUMP_BACK` at 106: the round-2 rule PASSED it; the new rule is VACUOUS |
| `osr-stop g ADD` | `loop while true: (s is s + "a" / i is i + 1.0 / if i >= n: return s)` | `oent=33 oadv=20`, offset 53 is `ADD`: HOLDS | `s` a float (`s is s + 1.5`) | `oadv=122=len` (the sentinel): VACUOUS |

The witness uses only existing diagnostics: nothing in production changes so
a test can observe it.

**What the witnesses expect in round 1.** The JIT and the leaf bail on an
int that meets an arithmetic, comparison, bitwise or index op, and refuse an
int literal, until round 5 (§4), so such a row's honest witness is
`fn-stop`, `osr-stop` or `leaf-gen`: it proves the guard fired (or the
scanner refused) and the interpreter produced the row's output. An int that
only moves, into a local, a field, a list element or a module binding,
passes through the JIT's C helpers and the leaf's borrows, so those rows
(`N1.fn-int-local`, `N1.fn-dot-fields`, `N1.osr-global-int-store`,
`N5.osr-index-set`, `N1.leaf-dot-get`) have native witnesses already in
round 1. A float row's witness is native too: it proves the float meaning of
`NUM_ZERO`/`NUM_ONE`/`CONST` survived in the JIT and the leaf. Round 5 flips
the int witnesses to native, one row at a time, and each flip is a
deliberate edit of the row.

### 9.2 `tools/phase2_check.sh [--through <commit>] <tag-binary> <branch-binary>` (R1.1 builds it)

**The landed-round filter.** Each MAP row names the commit that makes it
pass (`[R1.3]`; a row needing two commits names both, `[R2.1/R2.4]`, and
lands with the later). `--through Rk` selects the rows that have landed by
Rk, in the order R1.1 < R1.2 < ... < R1.8 < R2.1 < ... < R2.6 < R3; controls
run in every mode; the default is the whole plan. A round is checked against
exactly its landed rows, so R1.3's check cannot fail on an R1.7 row, and the
final check runs all of them. Each round has a non-zero set of its own rows,
or a mechanical guarantee stated here, which `--through` runs instead of
failing on zero rows:

| round | its own MAP rows | its gates, or the mechanical guarantee |
|---|---:|---|
| R1.1 | 0 | mechanical: the compile errors (223 sites), the C slot test (§2.5; `examined` equals the derived classifier count), plant 1, the int-source check, and the differential over the suite's `.eigs` corpus |
| R1.2 | 0 | mechanical: the compile errors (464 sites), the int-source check, and the differential over the suite's `.eigs` corpus (behaviour-preserving) |
| R1.3 | 43 | |
| R1.4 | 6 | |
| R1.5 | 7 | |
| R1.6 | 18 | `gate.N5.q7-readers`, and the per-builtin behaviour table (§9.4) |
| R1.7 | 12 | `gate.N14.db-param-exact` |
| R1.8 | 0 | `gate.N7.embed-int` (the embed smoke test), the executed doc fences (suite [89]/[90]), the LSP and lint suite sections |
| R2.1 | 0 | mechanical: the C slot test's NaN-payload rows and plant 2 (no program can make a NaN before R2.2) |
| R2.2 | 9 | |
| R2.3 | 3 | |
| R2.4 | 6 | |
| R2.5 | 6 | |
| R2.6 | 1 | |
| R3 | 5 | `gate.O1.oracle-floor`, `gate.O2.predicate-floors` |

(The counts are the MAP's at this commit; `phase2_check.sh` derives them, and
fails if a round named here has neither rows nor its mechanical gates.)

- **Rows** live in `tests/phase2/rows/<id>.eigs`. Each has a header
  `# ROW: <id>`, `# ITEMS: N1 N2`, `# EXPECT-RC: <n>`, `# SHAPE: S|L|F|O`,
  `# WITNESS: <kind> <chunk>... [<OP>]`, `# OPS: <OP>...`, plus `<id>.out`
  (the exact branch stdout). Controls live in `tests/phase2/controls/`.
- **Population:**
  - the row set is the directory listing (it cannot drift from a list);
  - every row id appears in MAP.md and every MAP id has a file (both
    directions), with the same shape and witness;
  - every item in the fixed list (N1-N14, N4b, A, B, T1, O1-O4, transcribed
    from #1758 Revision 1) has at least one row;
  - the `ops:` of the `L`, `F` and `O` rows together cover every
    JIT-emitter arm and leaf-evaluator arm that holds a numeric site, read
    from the inventory file's `## Numeric arms` (15 emitter arms and 5 leaf
    arms today, each with its opcode chain; an arm is covered when some
    row's `ops:` names an opcode of its chain that the row runs natively or
    stops exactly at; the MAP's shaped rows cover all 20);
  - zero rows is a FAIL, except a mechanical round under `--through`
    (the table above), which runs its named gates instead.
- **Tiers:**
  - `off` = `EIGS_JIT_OFF=1`;
  - `default`;
  - `osr` = `EIGS_JIT_OSR_THRESHOLD=1`;
  - `trace` = `EIGS_TRACE=<scratch>/t.tape` with the default JIT. The leaf
    evaluator is off under trace (§4.5), so this tier is the **leaf
    differential**: every `.eigs` row must print exactly what it prints in
    the other tiers, so an `L` row compares the leaf with the generic path
    on its int, float or overflow program. (`sh` rows that set `EIGS_TRACE`
    themselves skip this tier.)
  - Every run is bounded at 30 s, with `</dev/null` and a fresh scratch
    cwd. Use the runner's probe (`timeout`, else `gtimeout`), never a bare
    `timeout`: macOS runners lack coreutils (`.claude/rules/test-suite.md`).
    These knobs are the ones jit.c reads (jit.c:2501-2509, 4524).
  - Each `L`/`F`/`O` row runs once more per claimed tier on the branch with
    `EIGS_JIT_STATS=1 EIGS_JIT_STOPS=1 EIGS_JIT_HOT=1` (and `EIGS_DUMP_BC=1`
    for a `-stop` or `osr` claim) to read its witness.
- **Verdicts per row and tier:**
  - branch PASS = rc equals EXPECT-RC and stdout byte-equals `.out`;
  - tag FAIL = not that;
  - VACUOUS = the branch passed but the witness does not hold;
  - rc 124 is the named verdict `TIMEOUT` and rc >= 128 is `SIGNAL`. Both
    are a FAIL on the branch; on the tag they count as `tag_fail` and are
    also shown in their own counters.
- **Output, one line per tier:** `tier=<t> examined=N rows tag_fail=N
  branch_pass=N vacuous=0 tag_timeout=K tag_signal=K`, then `controls=M
  both_pass=M`, `witnessed=W` (the rows whose witness held), and an
  environment banner (both binaries' `--version` and sha256).
- **Exit 0** iff in every tier examined == tag_fail == branch_pass > 0
  (or, for a mechanical round under `--through`, its named gates pass),
  vacuous == 0, the controls all pass on both, and the population checks
  pass.
- **Calibration** (one-time, in the commit that adds it):
  - tag passed as both binaries: `branch_pass=0`, exit 1;
  - one `.out` corrupted: exit 1, naming the row;
  - an empty rows directory: exit 1;
  - a MAP id with no file, and a file with no MAP id: exit 1 each;
  - a `leaf` row run against a scratch build whose leaf scanner returns
    early (`chunk_scan_leaf_accessor` never sets the flag): `vacuous=1`,
    exit 1;
  - an `fn` row whose function is called 10 times instead of 60: `vacuous=1`
    (the JIT never compiled it);
  - an `L` row run against a scratch build whose leaf `MUL` arm computes
    `a * b + 1`: the `trace` tier differs from the others, exit 1, naming
    the row;
  - **one negative plant per witness kind, each a row where the claimed op
    did not run as claimed** (the rows of §9.1's calibration table, which
    this design ran on main): `leaf` (the helper split into two statements),
    `leaf-gen` (the helper computed by the leaf), `fn` (an unsupported op
    before the claimed one), `fn-stop` (the claimed op runs natively), `osr`
    (the critic's `osr_ret_PLANT2`: a string concat ahead of the claimed op,
    0 native `INDEX_SET` calls), `osr-stop` (the claimed op runs natively to
    the sentinel). Each must give `vacuous=1`, exit 1, naming the row;
  - `--through R1.2` on a tree with no R1.1/R1.2 rows: exit 0 by the
    mechanical gates, `mapped=0`; and with the int-source check planted (a
    production `slot_from_int(count)` call): exit 1.

**As built in R1.1** (`tools/phase2_check.sh`, a wrapper over
`tools/phase2_check.py`, whose docstring is the reference):
- **Controls land with R1.3**, the first round with rows of its own. Under a
  mechanical `--through` they are not required: their witnesses are about
  ints (`ctl.N1.fn-int-truthiness` expects the int call to bail), which
  cannot hold before an int exists.
- **The leaf witness is read in the default and `osr` tiers.** With
  `EIGS_JIT_OFF=1` the hot table counts no call at all (probed on the R1.1
  binary: a function called 60 times has no row), so the `off` tier cannot
  witness either way.
- **The token gate** checks, in every mode, that each token a landed round
  deleted (2.7) occurs in no code line of `src/` or `tests/` C files.
  (Until the second R1.1 fix round it ran only in the mechanical rounds;
  it runs in every mode now, as this line said.)
- **The inventory gate** runs in every mode too:
  `tools/phase2_inventory.py --check` must PASS, so a slot classifier with
  no reviewed disposition row fails the check, and so does a committed
  `docs/design/phase2-inventory.txt` that is not exactly the generated
  file (#1804: nothing ran the inventory's verdict, and the committed file
  had gone stale).
- **The corpus differential** is `tools/phase2_corpus_diff.sh <baseline>
  <branch>`: both binaries run every `.eigs` under the branch tree's
  `tests/` from the branch tree's `src/` (the suite's cwd), so the file and
  whatever it loads by a relative path are the same bytes for both; only
  the binary and its stdlib differ. A file only the branch has (a new
  fixture) is counted as `new`; one only the baseline has is a DELETED
  failure. **As corrected in the R1.1 fix round** (the critic's plants B
  and D passed the first version):
  - each binary runs each file TWICE. A file is deterministic when the
    baseline's two runs agree, and then any branch run that differs is a
    DIFF: a branch that is wrong on every other run is wrong;
  - randomness runs LIVE with a pinned seed. The runtime has no seed flag
    or variable, so the tool builds an `LD_PRELOAD` shim. The drand48
    self-seed is `srand48(tv_sec ^ tv_nsec ^ getpid())` from a
    `CLOCK_MONOTONIC` reading taken just before; the shim records each
    thread's last such reading and pins a seed equal to that formula,
    whatever its value, while a script's `seed_random of N` passes
    unchanged. (The first fix round's shim pinned seeds >= 2^20 instead,
    and the self-seed falls below that: 5 of 3,000 draws went unpinned; the
    second round's pinned 3,000 of 3,000.) libc `rand()`, which
    `audio_noise` draws from and `main()` seeds with `srand(time(NULL))`,
    is pinned at every `srand` call. `random_hex` reads `/dev/urandom` by
    design and stays unpinned; the shim marks every run that opens it, and
    those files are listed (`UNPINNED`) with their verdicts. The tool
    checks the shim first (two pinned draws agree). A random builtin changed
    on the branch therefore shows wherever the corpus observes it;
    `test_system.eigs` now draws `random_int` 300 times against its bounds;
  - a tape is the last resort, for a file whose baseline disagrees with
    itself even pinned (timing, threads): the baseline records it and
    replays it twice, the branch replays it once and must match
    (`same_under_replay`). Such a file's nondeterministic builtins did not
    run live, so their behaviour is invisible there; the report lists every
    file adjudicated that way (`REPLAYED`). Files whose replays disagree with
    each other stay NONDET, also listed;
  - no blanket memory cap: only files that drive the gfx, ui or audio
    surface run under `ulimit -v 2097152` (listed as `CAPPED`).
    `handles_full.eigs` varied only because of the old blanket cap.

  **As corrected in the second R1.1 fix round** (the second critic's plants
  C and B2 passed the whole oracle while the suite went red on C):
  - each file runs under its run conditions from the one loader the suite,
    `jit_diff.sh` and `replay_diff.sh` use (`tests/suite_program_env.sh`,
    policy `tests/suite_program_env.txt`). Before, every file started in
    the default strict mode, so 14 fail-soft numeric-boundary files died at
    an early strict raise on both binaries, about 394 asserts never ran, and
    the two early deaths were counted `same`. The four files the suite ran
    with an inline `EIGS_STRICT=0` (and one with an inline
    `SDL_VIDEODRIVER=dummy`) now have rows there, so there is no second
    source;
  - a file with conditions must complete (rc 0) on both baseline runs, the
    rule `jit_diff.sh` already applied; otherwise it is INCOMPLETE and
    never compared;
  - every file whose baseline exits nonzero must be declared, with that
    code and a reason, in `tests/phase2/corpus_nonzero.txt` (32 rows: the
    runaway guard's fixture, deliberate errors, fixtures of other hosts,
    capabilities the release build lacks). An undeclared exit is
    UNDECLARED-NONZERO and a row whose file exits otherwise is STALE: both
    fail the run. So removing a file's run conditions turns the
    differential red, and so does a new test that dies early. Every
    declared file is listed with its code (`SAME-NONZERO`);
  - a timeout or a crash all four runs agree on is counted as
    `timeout_both` or `crash_both`, no longer also as `same`;
  - every run uses SDL's dummy audio device (`SDL_AUDIODRIVER=dummy`): a
    real capture device delivers samples or not by timing, so
    `test_audio.eigs` printed a SKIP on some runs, and with its conditions
    applied the two-run baseline check let it through as deterministic and
    a branch run that differed read as a DIFF.
- **The smi-trap gate** (`--smi-trap BIN`, R1.1 and R1.2) runs the same
  differential with a `make smi-trap` build as the branch; until R1.3 it
  must show no difference, because no program may make an int.
- **The calibration** is `phase2_check.sh --calibrate [--build-plants] <tag>
  <branch>`, on the fixtures in `tests/phase2/calib/`: each ends in a line
  that fails on the tag (#1740: `5.5 & 1` raises `value` on the branch and
  truncates on v0.46.0), so an honest fixture has tag_fail == branch_pass.
  `--through R1.2` cannot pass on the R1.1 tree (its token gate would find
  `VAL_NUM`, correctly), so the R1.1 run of that item is `--through R1.1`;
  the int-source plant runs against a planted copy of `src/`. Cases the
  design did not list were added for the plan-level checks (an item with no
  row, an arm no row exercises, a round with neither rows nor gates) and
  for the token gate (a reintroduced `slot_is_num`). The fix round added the
  critic's plants: the differential's A (a deterministic file prints one
  more line), B (a branch wrong on alternate runs, both phases) and D (a
  build whose `random_int` answers lo+1..hi+1), each of which must make the
  differential name the file DIFF; the int-source plants P1-P5, each of
  which the static half must name at R1.1 (at R1.2, P4 sits inside an
  allowed writer and the static half passes it); and P4 built into a
  smi-trap binary, which the dynamic half must stop. The second fix round
  added the second critic's plants C (a build whose buffer equality reads
  raw elements) and B2 (an int whose tag bits are spelled from
  `SLOT_QNAN_MASK`, which the static half does not see, on the smi-trap
  build), each of which must make the differential name a conditioned file
  DIFF; a removed policy row, which must be UNDECLARED-NONZERO; a ledger row
  for a completing file (STALE); a conditioned file that does not complete
  (INCOMPLETE); and the inventory gate's plants (`vm.c:critic_new_reader`
  with no disposition row, and a stale committed inventory). A restricted
  run (the calibration's file list) prints `RESTRICTED` and exits 3, never
  PASS.
  The calibration is a `tools/selftests.txt` row (`phase2_check.py
  --selftest`, which builds v0.46.0 and the four planted binaries itself):
  it runs when the checker or its fixtures change, and nightly, never on
  every suite or CI run (docs/PRINCIPLES.md 5: a check proves it fires once,
  when it is written or changed).

### 9.3 `tools/phase2_plants.sh` (round 1 builds it; detached, about 7 release builds)

Each plant:
1. `git archive HEAD` into a scratch dir (no `.git`);
2. applies one `sed`, asserting the original text occurs exactly once before
   and the planted text after (a plant that did not apply is `BROKEN`);
3. builds the release with plain `make`, once at a time, `timeout 1500`;
4. runs **its named check** and requires the check's own FAIL line naming
   the row (keyed on the gate's message, not on a nonzero exit, §179).

Verdicts: `KILLED`, `SURVIVED`, or `BROKEN` (patch, build or timeout).
Output: `plants=7 killed=7 survived=0 broken=0`; exit 0 only for exactly
that.

| # | plant | where | named check that must turn RED |
|---|---|---|---|
| 1 | an int that fits inline stored boxed | `eigs_container_slot` (or `slot_from_int`) skips the small-int rule and stores a `VAL_INT` box | `tests/phase2/slot_layer.c`: every canonicalizing writer of §2.1, driven with every boundary value, must give tag 0xFFFA inside ±2^47 and a box outside. No program row can see this plant (§2.1: everything compares by value), so the round-0 claim that `N1.canon-eq` would turn red is withdrawn; that row now pins only semantics |
| 2 | a NaN stored raw in a slot | `slot_from_f64` without the canonical branch | row `N12.nan-payload-tags` (`f64_from_bits` of every tag-spelling payload into a variable, list, dict and buffer; `type of` each is "num", under ASan in the plant build) |
| 3 | a writer accepting a non-finite value | the refusal inside `eigs_json_encode_value` deleted; separately inside the store encoder | rows `N13.json-refuses-inf` and `N13.store-refuses-nan` (raise `value`, and nothing written: the store row re-reads the record count) |
| 4 | `+` wrapping on overflow | the SMI+boxed add path uses wrapping `uint64` add | row `A.add-overflow-raises` (`9223372036854775807 + 1` raises `value` naming `+`) |
| 5 | `-INT64_MIN` wrapping | `CASE(NEG)`'s int arm without the INT64_MIN check | row `N4b.neg-min-raises` |
| 6 | `num_type of 3.0` returning "int" | `num_type` answers "int" for an integral float | row `N7.num-type-float` |
| 7 | a v6 tape accepted | the version check accepts 6 | row `T1.v6-refused` (the committed v6 fixture must exit nonzero naming version 6) |

Each plant is transverse (§100): deleting its named check's assertion must
let the plant through. That is shown once per plant during calibration by
running the plant against a copy of the check with its assertion removed.

The tier-witness and leaf-differential plants (§9.2's calibration) belong to
`phase2_check.sh`'s own calibration, not to this list: they test the
instrument, not the semantics.

As built in R1.1, the tool holds the plants whose named checks exist: plant
1 (`slot_from_int` tags an int that fits as a heap pointer; its named line
is `slot-layer-test: FAIL slot_from_int(0): bits ...`). Plants 2-7 join the
table in the commits that land their rows, and its output then reads
`plants=7`. Its transverse run deletes exactly the named assertion
(`if (s.u != smi(v).u)` becomes `if (0)`) and requires the plant to pass.

The R1.1 fix round added three instrument plants on the slot test, each
with its own transverse run: `arm-refusal` (`NUM_CMP`'s int refusal
deleted; named line `slot-layer-test: FAIL arm lt with an int: got ...`),
`stderr-noise` (the population scan writes a line to stderr; named line
`slot-layer: FAIL: the population scan wrote to stderr`) and
`stdout-noise` (the scan prints a line outside its grammar; named line
`slot-layer: FAIL: the population scan printed lines outside its
grammar`). The tool also fails a plant whose check writes to stderr. Like
the calibration, the plants are a `tools/selftests.txt` row (`phase2_plants.sh
--selftest`), keyed on the checks they name (the slot test, its runner and
the population scan), so they run when those change, never per suite or CI
run (docs/PRINCIPLES.md 5).

### 9.4 The per-builtin behaviour table (R1.6's gate; replaces the int-fuzz class check)

Round 2 planned an int-fuzz gate asserting "the result is an int for int
inputs". The critic showed what it cannot see: builtins whose int result
comes from a non-numeric input (`len`, `ord`, `index_of`, `buf_len`,
`scan_ints`, `read_bytes`: fed an int they raise `type_mismatch` on both
binaries), and builtins that need a valid argument to run at all
(`shared_size` raises `value` on a bare int). R1.6 changes about 114 rows, so
its gate must exercise every builtin with a VALID call.

`tests/phase2/builtins.tsv` (written in R1.6, checked by
`tools/phase2_builtins.sh <tag-binary> <branch-binary>`):
- **One row per numeric builtin of §6, both directions** (the population is
  the inventory file's `## Builtins` list, not a hand list): `builtin`,
  `class` (must equal §6's), `probe` (a short program that calls it validly
  and prints the result, plus `num_type of` it where the result is a
  number), `branch` (the exact expected stdout and rc), `tag` (the tag's
  observed stdout and rc), `changes` (`yes`/`no`).
- **Checks:**
  1. the row set equals §6's numeric builtins, both directions; zero rows
     is a FAIL;
  2. `class` equals §6's class, and the row's `branch` output is consistent
     with it: an `int-preserving` row prints `"int"` for its result's
     `num_type`; a `float-producing` row prints `"float"`; an
     `int-requiring` row's probe passes a fractional value in an
     integer-valued parameter and expects `value` (and a second line with
     an integral float that converts); a Q7 row's probe exercises one
     out-of-range value of each class it names (a clipped shape draws
     nothing, a bounded value clamps, a magnitude raises);
  3. the branch's actual output equals `branch`, and the tag's equals
     `tag`;
  4. `changes` is `yes` exactly when `branch` and `tag` differ, and every
     `LOSS`, `int-requiring` and Q7 row has `changes: yes`: a probe that
     does not show the tag/branch difference for a builtin §6 says changes
     is VACUOUS.
- **What it sees that the fuzz could not:** `len of [1, 2]` must print
  `[2, "int"]`; `ord of "A"` `[65, "int"]`; `shared_size` is probed with a
  valid shared value; every `int-requiring` row raises on 1.5; `gather` and
  `scatter_add` raise on an index of 1.5; `buf_from_pcm16le` raises on a
  byte of 300 and of 1.5.
- **Calibration plants** (one-time, in the commit that adds it): `len`
  reverted to `make_float`: its row red; an `int-requiring` builtin reverted
  to truncation: red; a row deleted, and a stale row added: membership red
  both ways; a class edited: red; a `LOSS` row whose probe stays below 2^53:
  VACUOUS.

The int-fuzz sweep, if kept, shrinks to what the table does not do: a
crash-only sweep (every builtin fed ints in every numeric slot must raise
or return, never crash), in the shape of `tests/test_bool_fuzz.sh`.

---

## 10. The Lua differential tool (`tools/phase2_lua_diff.py`, round 1)

**Oracle.**
`/home/jon/src/InauguralSystems/EigenScriptEcosystem/EigenLua/.ref/bin/lua`
(PUC-Rio 5.4.9, pristine).
- Checked at start with `EigenLua/tools/build_ref.sh --check-not-compat
  <bin>`. The binary argument is required; the bare form fails with
  `$2: unbound variable`. It exited 0 on this box.
- A failed check stops the run as an instrument failure (exit 2), never as
  a verdict.

**Cases.** Expressions over operands drawn from the edge set {0, ±1, ±2^31,
±(2^47 - 1), ±2^47 (the SMI boundary), ±2^53, ±(2^53 + 1), ±2^62,
INT64_MIN, INT64_MAX, 0.5, -0.0, 1e308, 2^63 as a float}. Operators:
- arithmetic `+ - * / // %`;
- unary `-`;
- bitwise `& | ~ << >>`;
- comparisons `== < <=`;
- `math.abs`, `math.floor`, `math.ceil`, `math.max`, `math.min` against
  `abs`/`floor`/`ceil`/`max`/`min`;
- `math.type` against `num_type`.

Translation: Lua binary `~` is EigenScript `^`, Lua `^` is `pow of`, and
Lua unary `~` is `~`.

String operands are excluded: Lua coerces `"10" + 1` and EigenScript does
not. That divergence is documented and not exercised.

**Comparison by value, never by text.**
- Each side prints its result in a canonical machine form. Lua uses
  `math.type(x)` plus `string.format("%d" | "%a", x)`. EigenScript uses
  `num_type` plus `str` for ints, and `f64_bits` once round 2 lands it;
  until then, float text parsed to a double by Python, whose float parsing
  is correctly rounded.
- Kind and value must match.
- A raise on both sides compares as `RAISE` (for example Lua `n//0` "attempt
  to perform 'n//0'" against EigenScript `value`).

**Deliberate divergences**, each a rule with its own counter, never a skip:

| rule | Lua 5.4.9 (probed) | EigenScript | how the tool checks it |
|---|---|---|---|
| (A) | `math.maxinteger + 1` gives `-9223372036854775808` (wraps) | raises `value` naming the operator | the tool computes the exact result in Python (arbitrary precision); when Lua's int result differs from it, EigenScript must raise |
| N6 | prints `%.14g` (`0.3`, `1e+15`, `-nan`) | Python `repr` (`0.30000000000000004`, `1000000000000000.0`, `nan`) | values compared by bits; EigenScript's text is checked against Python `repr` separately (Python is the N6 oracle, not Lua) |
| (B) | `type(3)` is "number", `math.type(3)` is "integer", `math.type("3")` is nil | `type of 3` is "num", `num_type of 3` is "int", `num_type of "3"` is null | name mapping number to num, integer to int, nil to null |
| N4b | `-mininteger`, `math.abs(mininteger)` and `mininteger//-1` all give mininteger | each raises `value` | expected RAISE; `mininteger % -1` is 0 on both (no divergence) |

**Output:** `examined=N agree=N rule_A=N rule_N6=N rule_B=N rule_N4b=N
disagree=0`. It exits 1 on any unexplained disagreement or on examined=0.

**Calibration plants:**
- flip rule (A) to expect wrapping: red on the overflow cases;
- compare by text instead of value: red on the N6 cases;
- a fake `lua` that prints `float` for an int: red.

---

## 11. Decided questions (Q1-Q8)

Q1-Q6 were open in round 0. They were decided on 2026-10-14 by the
standard answer, each verified by probe, in
[#1758 (comment)](https://github.com/InauguralSystems/EigenScript/issues/1758#issuecomment-6171744498).
The owner may overrule any of them; until then this design follows them.

- **Q1, N5's scope: DECIDED.** The parameter's meaning decides, not the C
  type.
  - Integer-valued parameters (indices, counts, sizes, byte values,
    handles, ports, seeds) follow N5: `1.5` raises `value`. Lua:
    `string.sub("abc", 1.5)` raises "number has no integer representation".
  - Continuous parameters (gfx coordinates and sizes, colour channels,
    durations, audio gain) accept floats; where the C API needs an int, the
    conversion rounds to nearest, replacing truncation toward zero (SDL3's
    float coordinates, LÖVE's numeric drawing API).
  - Applied: §6's rows (16 moved from other to int-requiring; byte
    consumers no longer wrap), `eigs_byte_arg`, `eigs_int_arg_range`, and
    the Q7 readers (§2.6), R1.6 (§8).
- **Q2, an int stored into float storage: DECIDED.** Convert with IEEE
  round-to-nearest, documented as the container's contract (Python
  `float(2**53+1)`, numpy, JS `Float64Array`). Applied: `buf_set`,
  `buf_from_list`, `copy_into`, `set_at` on a buffer, `stream_write`; the
  inventory's `buffer_read_num` sites keep their token (§2.3a).
- **Q3, the embed API: DECIDED, Lua's C API.** `eigs_value_as_num(int)`
  converts (lossy above 2^53, like `lua_tonumber`); add
  `eigs_value_new_int`, `eigs_value_as_int` (succeeds only for an exact
  int64, with a success flag, like `lua_tointegerx`) and `eigs_value_is_int`
  (like `lua_isinteger`); `EIGS_TYPE_NUM` covers both kinds (like
  `LUA_TNUMBER`). Applied: R1.8; the 48 `eigs_value_as_num` sites keep
  their token (§2.3a).
- **Q4, `round`: DECIDED.** Keep half away from zero (C and Rust `round`);
  the result is an int when it fits int64 and a float otherwise, like Lua's
  `math.floor`/`math.ceil` (`math.floor(1e300)` stays `1e+300`). Applied:
  §6 (`round` int-preserving, LOSS), R1.6; the Q7 readers use the same
  tie rule.
- **Q5, `why is x` for an int binding: DECIDED.** An int when Δv fits in
  int64, otherwise a float. A readout never raises; (A) applies to
  operators, not to observer readouts. Applied: round 3 (O4).
- **Q6, `//=`: DECIDED.** Add it beside `/=`. Applied: R1.4.

- **Q7, a finite continuous parameter outside the C range: DECIDED**
  ([#1758 comment 6174302316](https://github.com/InauguralSystems/EigenScript/issues/1758#issuecomment-6174302316)).
  It follows the quantity it represents:
  - geometry (coordinates and sizes): clip in float space against the
    drawable area, then round to nearest. Saturating each argument
    separately is wrong: `gfx_rect of [-3e9, 0, 6e9, 10]` would cover half
    the screen instead of all of it;
  - bounded quantities (colour channels, gain, volume): clamp to the domain;
  - unbounded magnitudes the C call cannot honour (durations, sleeps): raise
    `value`, naming the builtin (Python's `time.sleep(3e12)` raises
    `OverflowError`).
  - Applied: the builtin table's validated `q7` column (§6); the readers
    `eigs_geom_shape`, `eigs_bounded_arg`, `eigs_magnitude_arg` (§2.6),
    landing in R1.6. Two classifications this design made inside the
    decided categories: a window size (`gfx_open`) and a measurement's
    scale (`gfx_text_width`/`height`) have no drawable area to clip against,
    so they are magnitudes.
- **Q8, NaN in an ordering: DECIDED** (same comment). IEEE 754-2019
  `totalOrder`: the canonical (positive, quiet) NaN sorts after +inf,
  deterministically, in `sort` and `sort_by` (numpy's `sort` and Rust's
  `f64::total_cmp` give the same order); `min` and `max` propagate NaN
  (IEEE 754-2019 `minimum`/`maximum`). Lua and Python produce a garbage
  order here (probed for #1758: Lua's `table.sort` left a list holding NaNs
  unsorted without an error). Applied: R2.2, when NaN first becomes
  reachable; rows `N11.sort-total-order` and `N11.min-max-nan`.
