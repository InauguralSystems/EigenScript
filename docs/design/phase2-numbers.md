# Phase 2 numbers (#1758): design (round 0, revised in design round 2)

Status: design for blind review, before round 1 builds. Nothing here changes
`src/`. Spec: issue #1758 (Revision 1), its owner decisions (A), (B), (C), and
the Q1-Q6 decisions
([comment](https://github.com/InauguralSystems/EigenScript/issues/1758#issuecomment-6171744498)).
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
11. Decided questions (Q1-Q6) and what stays open

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
`--no-write`), never the worktree; the unplanted copy passes first. All 18
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

M is the critic's plant verbatim; on the round-0 oracle it stayed green.

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
| **Alt 1R** | the same sites | **Measured (§2.3a): 1,416 of the 1,798 sites stop compiling (1,380 non-JIT, 36 in the JIT files)**, plus 44 inside a deleted definition. The other 338 keep a token on purpose, each class with its reason in §2.3a: the AST kind (52), the clamp R2.2 deletes (60), the decided embed accessor (48), f64 buffer reads (26), the libc parsers (15), the exact-conversion and formatter helpers (9), definitions (38), 87 JIT emitter immediates and helpers reviewed per guard (§4), and 3 `offsetof` uses that a real member rename does reach (measured). | **A compile error.** It cannot exist in code that names the vocabulary. The meaning changes that carry no token are listed with the token event that forces them (§2.7); the last `default:` that could absorb `VAL_INT` (builtins.c:998) is removed first in round 1. |
| **Alt 2** | payload reads and producers (enforced only if `num_` is renamed); the type tests keep compiling and now admit ints | none for the 382+63 type tests and the 484 checked reads | **A silent wrong number.** After `== VAL_NUM`, a `VAL_NUM_RAW` read of an int reads its int64 bits as a double (5 reads as 2.5e-323). An accessor that converts loses precision above 2^53 silently. In the JIT, three emitters misread with no compiler to catch them: `emit_load_numeric_operand`'s heap arm (jit.c:2343) loads `data.num_` of a boxed int; the `OP_SET_LOCAL` in-place branch (jit.c:3410) writes double bits into an int Value; the `OP_CONST` emitter (jit.c:2816) pushes `VAL_NUM_RAW` bits of an int constant. Constant dedup `const_equal` (chunk.c:212) merges `3` and `3.0`. |
| **Alt 3** | only the sites that need exactness (N2, N3, N6, N8, N14, tape) | none: every existing read compiles and works below 2^53 | **A silently lossy double**, exact below 2^53, so ordinary tests cannot see it. This is precisely the class the brief says to design out. |

### 2.3a The compile measurement (design round 2)

Round 0 claimed 1,449 non-JIT sites stop compiling. That was a token count,
not a compile. The critic compiled it and found 1,331, with 118 sites
carrying tokens round 0 never renamed (`AST_NUM` 52, `list_set_num` 21,
`slot_as_double` 16, `data.num` 7, `num_val` 5, and 17 more). This round
extends the rename list and measures again, the critic's way.

**Method.**
- A scratch copy of `src/` (never the worktree). Each token Alt 1R renames
  or deletes gets a declaration with clang's
  `__attribute__((unavailable("P2 ...")))`, so every USE is a compile error
  and the definition stays legal. `SLOT_NUM_RAW`, a macro, is routed
  through an unavailable `extern` so each expansion errors; `VAL_NUM_RAW`
  expands to the unavailable member `num_` and errors with a macro note.
- The list: the enumerator `VAL_NUM`; the members `num_` (Value), `num`
  (AST literal payload) and `num_val` (token); `eigs_num_arg`,
  `eigs_num_arg_slow`, `eigs_list_num`, `eigs_elem_num`, `eigs_opt_num`,
  `eigs_slot_num`, `eigs_slot_elem_num`, `eigs_slot_opt_num` and
  `buf_num_arg` (deleted); `make_num` and `make_num_permanent`;
  `finite_num_to_byte` and `buffer_read_byte` (deleted: Q1 byte values
  follow N5); `SLOT_NUM_RAW`,
  `slot_is_num`, `slot_from_num` and `slot_is_numeric` (deleted);
  `slot_as_double` (deleted in R1.1, §2.7); and the container f64 helpers
  `list_set_num`, `list_append_num`, `list_rewrite_num`,
  `dict_value_set_num`, `dict_value_rewrite_num`, `list_get_num`,
  `dict_value_get_num` (renamed `_f64`).
- clang 18.1.3, `-fsyntax-only -ferror-limit=0
  -Werror=implicit-function-declaration` plus `tools/werror_flags.txt`, one
  translation unit at a time. The three configurations take their TU sets
  from the Makefile at run time (`make print-<VAR>`):
  - `server-db`: every `src/*.c` (41 TUs), all extensions on;
  - `release`: `HOSTED_SOURCES` (29 TUs), gfx on, http/model/db off;
  - `freestanding`: `SOURCES` minus `CLI_ONLY` (23 TUs), `-ffreestanding
    -DEIGENSCRIPT_FREESTANDING=1`, every extension off.
- The generated `lsp_stdlib_index.h` is produced into the scratch copy
  (`tools/gen_lsp_stdlib_index.sh <copy>/lsp_stdlib_index.h`), so
  `eigenlsp.c` compiles.
- An error line, and each macro-expansion note under it, is mapped back to
  the unmutated copy's line (difflib). A site is **flagged** when its
  file:line carries an error.

**Results** (the unmutated copy first, as the control):

```
base:  cfg=server-db tus=41 errors=0 unparsed_failures=0
       cfg=release tus=29 errors=0 unparsed_failures=0
       cfg=freestanding tus=23 errors=0 unparsed_failures=0
R:     cfg=server-db tus=41 errors=2756 unparsed_failures=0
       cfg=release tus=29 errors=2293 unparsed_failures=0
       cfg=freestanding tus=23 errors=1740 unparsed_failures=0
inventory sites=1798 (non-JIT 1671, JIT-file 127)
cfg=server-db    distinct_flagged_lines=1245 sites_flagged=1416 (non-JIT 1380, JIT-file 36)
cfg=release      distinct_flagged_lines=1151 sites_flagged=1315 (non-JIT 1310, JIT-file 5)
cfg=freestanding distinct_flagged_lines=812 sites_flagged=960 (non-JIT 960, JIT-file 0)
UNION: flagged=1416 (non-JIT 1380, JIT-file 36)  inside-deleted-definitions=44  not-flagged=338 (non-JIT 247, JIT-file 91)
```

The error totals count a header's error once per TU that includes it;
the distinct lines and the sites are what matter. The union equals
`server-db`, because every TU is in it. `release` and
`freestanding` matter for what a build of that configuration forces (a
freestanding build cannot see the JIT, for instance), not for the union.

**The 338 sites that do not stop compiling, every one classified:**

| class | sites | why it keeps compiling, and what forces it instead |
|---|---:|---|
| `AST_NUM` | 52 | Under (B) the node kind still means "number literal". Its payload `num` is renamed, so all 7 reads of the literal's value are flagged; a site that only tests the kind is right for both kinds. The critic made the same call. |
| the clamp: `num_guard` 48, `num_guard_named` 4, `EIGS_NUM_MAX` 8 | 60 | A float clamp whose meaning does not change in round 1. R2.2 deletes all three, so every one of these sites stops compiling in that round: a token event of its own. |
| `eigs_value_as_num` | 48 | The embed accessor, used by the embed test harnesses (`embed_smoke.c` 42, `embed_concurrent.c` 6). Q3 decided it converts an int as `lua_tonumber` does, so "this value as a double" is unchanged. Exact ints get `eigs_value_as_int`/`eigs_value_is_int`. |
| `buffer_read_num` | 26 | Buffers are f64 storage (Q2): the read is a float by contract. Of its other 12 sites, 11 share a line with a renamed token and one is inside the deleted `buffer_read_byte`. |
| `strtod` 14, `atof` 1 | 15 | The libc parsers. The lexer's result reaches the renamed `num_val` through `tok_add`, whose store is flagged; the literal's kind changes `tok_add`'s parameter, which forces the call. The JSON, store and trace scalar parsers return `make_num(d)` a few lines on (flagged); trace.c:2324 fills a buffer's f64 storage (Q2). The rest parse model hyperparameters (float), the tape's observer config, and `tape_read.c:368`, which feeds the observer replay a double (`tape_read.c:635`); round 1 observes ints as doubles live and on replay alike (§8 risks), and round 3's change to `observer_slot_record_value`'s parameter forces this line. |
| `num_to_i64_exact` 6, `eigs_num_text` 3 | 9 | Pure helpers over a double, unchanged in meaning; every input reaches them through a renamed reader. N6 changes the formatter's output on purpose (pinned by the N6 rows), not silently. |
| definitions | 38 | Declarations and bodies of the renamed and deleted names themselves. |
| `VAL_NUM_OFFSET` in jit.c | 3 | `offsetof` uses, which the attribute does not reach. A real rename does: renaming `num_` to `f64_` (and the macro) in a further scratch copy gives exactly 3 errors, jit.c:2367, 2368 and 3471. |
| JIT emitter immediates and helpers | 87 | Tag compares (`0xFFF8`/`0xFFF9`/`0xFFFB`/`0xFFFD`) and the `emit_*` helpers. Reviewed per guard in §4.1: an SMI or a `VAL_INT` box fails every consuming guard and bails; the producer emitters keep their float meaning (§4.2). |
| **total** | **338** | |

So the round-0 headline becomes: **1,416 of 1,798 sites stop compiling**
(1,380 non-JIT, 36 JIT-file), 44 more are inside deleted definitions, and
338 keep a token for the reasons above. None of the 338 changes meaning
without a token event: the ones that change meaning later change it in
R2.2 (the clamp) or round 3 (the observer), each forced then.

### 2.4 The choice: Alt 1R

1. **It is the only alternative whose missed site is loud by construction.**
   Measured: 1,416 of 1,798 sites stop compiling until a person decides,
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
(§6) deciding each builtin's accessor and the int-fuzz gate (§9) checking it.

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

<!-- slot-table:begin -->
| name | disposition | why an SMI is safe there, or what R1.1 does |
|---|---|---|
| `builtins.c:bool_gate_name` | guarded | skips every non-pointer slot (`!slot_is_ptr`); an SMI is never a builtin (D2) |
| `builtins.c:sort_cmp_str` | guarded | reached only after `builtin_sort` proved every element a string (its homogeneity test names `VAL_NUM`, compile-forced) (D2) |
| `builtins_host.c:ls_entry_cmp` | guarded | sorts the string entries `ls` built itself (D2) |
| `container.h:eigs_slot_ref` | refuse | today an immediate double or an SMI is dereferenced as a pointer; every caller tests `slot_is_num` first (compile-forced). R1.1 aborts on any slot that is not a pointer, null or bool, so a caller missed later fails loudly (D2) |
| `eigenscript.c:#define GC_EDGE_TABLE` | guarded | a GC edge exists only for `slot_is_ptr`; an SMI has no edge (D2) |
| `eigenscript.c:env_get_hashed` | guarded | a non-pointer slot goes through `slot_to_value` (compile-forced) and comes back boxed: the lift boxes on purpose (§2.1) (D2) |
| `eigenscript.c:env_get_local_hashed` | guarded | as `env_get_hashed` (D2) |
| `eigenscript.c:gc_collect_at_exit` | guarded | skips every non-pointer slot (D2) |
| `value_slot.h:#define slot_as_heap` | refuse | alias of `slot_as_ptr` (D2) |
| `value_slot.h:slot_as_ptr` | refuse | the raw dereference: R1.1 asserts the heap tag in ASan and debug builds (D2) |
| `vm.c:jit_helper_iter_next` | guarded | a non-pointer state slot returns 1 (bail); its index-kind test `!= VAL_NUM` is compile-forced (D2) |
| `vm.c:obs_slot_value` | guarded | called only after `obs_slot_observable` answered true (pointer or bool) (D2) |
| `vm.c:slot_type_name` | smi-arm | today an SMI reaches the final `return "num"` by accident. R1.1 adds an explicit SMI arm ("num") and aborts on an unknown tag (D2) |
| `vm.c:vm_borrow_scan` | guarded | compares heap slots with the result pointer; an SMI is not heap (D2) |
| `vm.c:vm_builtin_name_for` | guarded | skips every non-heap slot (D2) |
| `vm.c:vm_leaf_accessor_exec/OP_LOCAL_DOT_GET` | guarded | a non-pointer target bails (`return 0`); a non-null field is borrowed as its bits, an SMI included (D2) |
| `vm.c:vm_local_lift` | guarded | a non-pointer, non-null slot goes through `slot_to_value` (compile-forced) and is boxed on purpose (D2) |
| `vm.c:vm_run_ex/CASE(DESTRUCTURE_UNPACK)` | guarded | a non-pointer source takes the error path, which names the type through `slot_type_name` (D2) |
| `vm.c:vm_run_ex/CASE(SLICE_GET)` | guarded | as DESTRUCTURE_UNPACK (D2) |
| `vm.c:vm_slot_value_opaque` | guarded | only a pointer can be a fn or builtin; an SMI answers "not opaque", which is right (D2) |
| `container.h:eigs_slot_adopt` | guarded | decides ownership from what `eigs_container_slot` returned (compile-forced); a small int comes back as an SMI and its box is released (D3) |
| `jit.c:jit_compile_to_thunk/OP_EQ` | not-a-classifier | writes the bool result bits (D3) |
| `jit.c:jit_compile_to_thunk/OP_NEG` | not-a-classifier | the NOT arm writes bool result bits (D3) |
| `jit.c:jit_compile_to_thunk/OP_NULL` | not-a-classifier | the constant arm writes null and bool bits (D3) |
| `jit_smoke.c:run_bool_cases` | not-a-classifier | test harness: expected bool bits (D3) |
| `jit_smoke.c:run_index_bail_cases` | guarded | test harness: an exact null test of a result (D3) |
| `value_slot.h:slot_decref` | guarded | acts only on tag `0xFFFB`; an SMI has no refcount (D3) |
| `value_slot.h:slot_false` | not-a-classifier | constructor (D3) |
| `value_slot.h:slot_from_bool` | not-a-classifier | constructor (D3) |
| `value_slot.h:slot_from_heap` | guarded | maps null and bool Values to their immediates and every other Value to a heap slot, so a `VAL_INT` box stays a box: the lifts depend on that (§2.1) (D3) |
| `value_slot.h:slot_incref` | guarded | as `slot_decref` (D3) |
| `value_slot.h:slot_is_bool` | guarded | exact tag test (D3) |
| `value_slot.h:slot_is_heap` | guarded | exact tag test (D3) |
| `value_slot.h:slot_is_null` | guarded | exact bit test (D3) |
| `value_slot.h:slot_is_ptr` | guarded | exact tag test (D3) |
| `value_slot.h:slot_null` | not-a-classifier | constructor (D3) |
| `value_slot.h:slot_true` | not-a-classifier | constructor (D3) |
| `vm.c:jit_helper_dot_get` | guarded | a non-null field is pushed as its bits; an SMI is a valid stack slot (D3) |
| `vm.c:jit_helper_local_idx_dot_get` | guarded | as `jit_helper_dot_get` (D3) |
| `vm.c:obs_slot_observable` | refuse | answers "pointer or bool", so an SMI is silently unobserved. Its callers test `slot_is_num` first (compile-forced) and must route an SMI into the numeric channel; R1.1 aborts here on an SMI, so a missed caller fails loudly (D3) |
| `vm.c:vm_local_is_null` | guarded | exact null test (D3) |
| `vm.c:vm_run_ex/CASE(DOT_GET)` | guarded | exact null test of a field (D3) |
| `vm.c:vm_run_ex/CASE(LOCAL_IDX_DOT_GET)` | guarded | exact null test of a field (D3) |
<!-- slot-table:end -->

### 2.6 The accessor API after round 1 (Alt 1R)

```
/* slots (R1.1) */
int      slot_is_f64(EigsSlot);     /* high16 < 0xFFF8 */
int      slot_is_smi(EigsSlot);     /* high16 == 0xFFFA */
int      slot_is_int(EigsSlot);     /* SMI or heap VAL_INT */
int      slot_is_number(EigsSlot);  /* f64 or int */
EigsSlot slot_from_f64(double);     /* the ONE double writer; round 2: canonical NaN */
EigsSlot slot_from_int(int64_t);    /* the ONE int writer: SMI in range, else a box */
int      slot_f64_value(EigsSlot, double *);   /* an immediate double or a VAL_FLOAT
                                                  box; 0 for anything else, ints
                                                  included. Replaces slot_as_double. */
int      slot_int_value(EigsSlot, int64_t *);  /* an SMI or a VAL_INT box */
#define  SLOT_F64_RAW(s)            /* was SLOT_NUM_RAW */
/* container f64 storage helpers (R1.1): list_set_f64, list_append_f64,
   list_rewrite_f64, dict_value_set_f64, dict_value_rewrite_f64,
   list_get_f64, dict_value_get_f64 (were *_num) */

/* Values (R1.2) */
Value   *make_float(double);   Value *make_float_permanent(double);
Value   *make_int(int64_t);
#define  VAL_F64_RAW(v)             /* member f64_; were VAL_NUM_RAW and num_ */
#define  VAL_F64_OFFSET             /* was VAL_NUM_OFFSET (the JIT's fixed-offset load) */
EigsNum  eigs_number_arg(const Value *, const char *who); /* int-preserving */
double   eigs_float_arg(const Value *, const char *who);  /* float-producing: int converts */
int64_t  eigs_int_arg(const Value *, const char *who);    /* int-requiring: N5 exact rule */
int      eigs_int_arg_range(const Value *, int64_t lo, int64_t hi,
                            int64_t *out, const char *who);  /* N5, then the C range */
uint8_t  eigs_byte_arg(const Value *, const char *who);   /* Q1: N5, then 0..255 */
int      eigs_round_arg(const Value *, int *out, const char *who);
                                    /* Q1 continuous: round to nearest, half away
                                       from zero (as Q4's round); non-finite is
                                       refused (N13); finite but outside the C int
                                       range is open: §11 Q7 */

/* literals (R1.3) */
OP_INT_ZERO, OP_INT_ONE, OP_INT_CONST   /* appended to OpCode; §2.7 */
/* AST literal payload `num` and the token's `num_val` become an EigsNum */
```

Each `_arg` reader also has the list, slot and optional forms of today's
checked accessors.

### 2.7 Every meaning change coincides with a token change

Round 0's order changed meanings with no token change: R1.1 widened
`slot_as_double` with an SMI arm, and R1.3 re-meant `OP_NUM_ZERO`/`OP_NUM_ONE`
as ints. Neither produces a compile error, so a missed caller or a missed
executor (the critic found the leaf evaluator's `OP_NUM_ZERO`/`OP_NUM_ONE`
arms, vm.c:1872-1877) would keep compiling with the old meaning. The rule
now: **a meaning change lands in the same commit as the token change that
stops every affected site**, or it is listed below with the reason no token
exists and the gate that catches a miss instead.

| meaning change | commit | token change in that commit | a missed site |
|---|---|---|---|
| a slot may hold an int (SMI tag 0xFFFA) | R1.1 | `slot_is_num` -> `slot_is_f64`, `SLOT_NUM_RAW` -> `SLOT_F64_RAW`, `slot_from_num` -> `slot_from_f64`; `slot_is_numeric` deleted; the container helpers `*_num` -> `*_f64` | compile error (D1, 58 entries) |
| "a number from an immediate or a box" (`slot_as_double`) | R1.1 | **deleted**. Its 15 calls (leaf `INDEX_GET` and `ADD/SUB/MUL`, `ARITH_FAST`, `INT_BINOP_R`, `NEG`, `BNOT`, `EQ`, `NE`, `NUM_CMP`) are rewritten with an explicit int decision: the float fast path reads `slot_f64_value` (float only), an int takes the slow path that R1.2/R1.3 give int semantics, and the leaf bails | compile error at all 15 |
| a slot classifier without a number test meets an SMI | R1.1 | none can exist (they name no number token) | the derived D2/D3 table (§2.5): `refuse` entries abort, `smi-arm` entries answer; the inventory fails on an unreviewed entry |
| raw access to a slot's or Value's double | R1.1/R1.2 | the members and macros renamed (`SLOT_F64_RAW`, `VAL_F64_RAW`, `f64_`) | a spelled-out `.d_`/`.num_` is refused by `tools/num_read_check.sh` and by the inventory (BYPASS) |
| a Value number may be an int (`VAL_INT`) | R1.2a | `VAL_NUM` -> `VAL_FLOAT`; `VAL_INT` appended, so `-Werror=switch` stops every default-less ValType switch; the one `default:` (builtins.c:998) is removed in the same commit | compile error |
| the checked readers' contract (number in, double out) | R1.2 | `eigs_num_arg` family, `eigs_slot_num` family and `buf_num_arg` deleted; the replacements name the intent (§2.6) | compile error |
| the number constructors | R1.2 | `make_num` -> `make_float`, `make_num_permanent` -> `make_float_permanent`; `make_int` added | compile error |
| equality, ordering and hashing across kinds | R1.2 | their `VAL_NUM` arms and cross-type test renamed (`values_equal_impl`'s type-mismatch block names `VAL_NUM`; `sort_cmp_num`; `const_hash_value`/`const_equal`) | compile error |
| `VAL_NUM_OFFSET` (the JIT's fixed-offset load) | R1.2 | renamed `VAL_F64_OFFSET` with the member | compile error (jit.c:2367, 2368, 3471; measured) |
| an int literal | R1.3 | **new opcodes `OP_INT_ZERO`, `OP_INT_ONE`, `OP_INT_CONST`, appended** (the opcode-ABI rule, no `EIGS_BYTECODE_ABI` bump); the AST payload `num` and the token's `num_val` renamed to an `EigsNum` in the same commit | the four exhaustive OpCode switches stop compiling (`op_name` chunk.c:337, `op_verify_operands` chunk.c:466, `op_verify_stack_effect` chunk.c:615, `op_stack_effect` compiler.c:305), and `tools/obs_marker_check.sh` requires each new enumerator's `/*obs:NONE*/` marker (`opcode_is_observer_reader`, chunk.c:1302, has a `default:` that correctly answers "not a reader"); the JIT scanner and the leaf scanner refuse an opcode they do not know (their `default:`), so the literal runs interpreted; the interpreter's computed-goto table is the one executor the compiler cannot check, and a missing entry is a NULL jump that crashes the first int-literal row (loud) |
| `OP_NUM_ZERO`, `OP_NUM_ONE` | none | **no meaning change**: they keep pushing float 0.0 and 1.0, so their three executors (interpreter vm.c:3257, JIT emitter jit.c:2797, leaf evaluator vm.c:1872) and two scanners stay correct untouched. The compiler emits them only for a float literal (compiler.c:2073, which reads the renamed payload) | n/a |
| `OP_CONST` | none | **no meaning change**: an int is never an `OP_CONST` operand (`OP_INT_CONST` carries it). Its three executors already push any non-number constant as a box, and the leaf scanner refuses a non-`VAL_FLOAT` constant (renamed test, chunk.c:1090) | a stray int constant is a box: correct, merely slow |
| the byte conversion (wrap modulo 256 -> N5, Q1) | R1.6 | `finite_num_to_byte` deleted (7 calls), and with it `buffer_read_byte` (21 calls in `gfx_fb` and `ppu_render_frame`), replaced by a reader that raises on a non-byte | compile error |
| the observer's numeric channel receives an int | R1.1 (refusal), R1.3 (routing) | `obs_slot_observable` refuses an SMI (D3 `refuse`); its callers are D1 (forced in R1.1) and route an SMI into the numeric channel as a double once ints exist | abort |
| `tape_read.c:368`'s double (the observer replay's input) | round 3 | none in round 1: live and replayed observers both see an int as its double. Round 3 changes `observer_slot_record_value`'s parameter to the numeric kind, which forces this line | n/a in round 1 |
| the embed accessor `eigs_value_as_num` given an int | R1.8 | none, **by decision** (Q3): it converts, like `lua_tonumber`; `eigs_value_as_int`, `eigs_value_is_int` and `eigs_value_new_int` are added | n/a |
| the clamp's removal: NaN and inf become reachable | R2.2 | `num_guard`, `num_guard_named`, `EIGS_NUM_MAX` deleted (74 sites forced: 60, 6 and 8) | compile error |

**The meaning changes that cannot carry a token**, each with the gate that
catches a miss:
- **The leaf evaluator vs the generic path.** The leaf has no frame and no
  `OP_LINE`, so nothing marks it when the generic path's semantics change.
  The gate is the leaf differential (§9.2, the `trace` tier): every row runs
  with the leaf on and off, and the outputs must be byte-identical.
- **Consumers that assumed a finite double (R2.2).** No token marks code that
  merely receives a NaN or an inf after the clamp is gone:
  - `values_equal_impl`'s identity shortcut (`if (a == b && ...) return
    1;`) would call a NaN box equal to itself. No program path reaches it
    with one float box on both sides today (EQ compares two floats in its
    fast path, and container comparisons pass fresh element views; read,
    not probed, since no NaN exists yet), so R2.2 excludes floats from the
    shortcut as #1417 excluded buffers, and the C slot test calls it with
    one NaN box on both sides;
  - C casts of a double to an integer type (undefined on NaN/inf): every
    builtin argument goes through a §2.6 reader, which refuses a non-finite
    value (N13); the internal casts left are the #1746 residue (R2.6);
  - the sort comparators: NaN has no order, and the order a sort should
    give it is not decided (§11 Q8).

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
| `INDEX_GET` (1907) | the index through `slot_as_double` (an immediate or a boxed `VAL_NUM`) then `vm_index_is_int`; a list element is borrowed; a buffer element is `slot_from_num(buffer_read_num(...))` | `slot_as_double` is deleted (R1.1), so this arm stops compiling. It reads the index with `slot_f64_value` and **bails on an int index**; the buffer element is `slot_from_f64` (Q2: f64 storage). Round 5 adds the SMI index |
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
    C API needs an int, `eigs_round_arg` rounds to nearest (half away from
    zero, as `round`), replacing today's truncation toward zero, which gets
    negative coordinates wrong; a finite value outside the C range is §11
    Q7, still open. (Byte consumers, which truncated and
    wrapped modulo 256 here in round 0, are int-requiring under Q1.)

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

**Counts** (from the table below, checked by `tools/phase2_inventory.py`,
which prints them): 230 numeric builtins (`ppu_render_frame` joined when
`buffer_read_byte` entered the vocabulary). By class: 37 int-preserving, 58
float-producing, 84 int-requiring, 51 other. The decided Q1 moved 16 rows
from other to int-requiring (counts, byte values, handles, flags and
selectors), and `ppu_render_frame` is a new int-requiring row. 42 are LOSS:
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
| builtin | class | loss | note |
|---|---|---|---|
| `abs` | int-preserving | LOSS | Lua math.abs (integer/float); abs of INT64_MIN raises (N4b) |
| `acos` | float-producing | - | Lua math.acos |
| `add` | int-preserving | LOSS | scalar arm mirrors `+` (overflow raises, (A)); buffer arms stay float |
| `append` | other | - | appends any value; VAL_NUM appears only as a diagnostic default |
| `asin` | float-producing | - | Lua math.asin |
| `assert` | other | - | message via value_to_string (N6) |
| `atan` | float-producing | - | Lua math.atan |
| `atan2` | float-producing | - | Lua math.atan(y, x) |
| `audio_capture_open` | int-requiring | - | freq (samples per second) and channels are counts: N5, then the C int range (Q1); returns a device id |
| `audio_envelope` | float-producing | - | float samples; times in seconds |
| `audio_gain` | float-producing | - | float samples |
| `audio_mix` | float-producing | - | float samples |
| `audio_music_play` | int-requiring | - | loop count: N5, then the C int range (Q1) |
| `audio_music_volume` | other | - | volume is a gain: continuous, rounds to nearest for the C int API (Q1) |
| `audio_noise` | float-producing | - | float samples |
| `audio_open` | int-requiring | - | freq (samples per second) and channels are counts: N5, then the C int range (Q1); returns a device id |
| `audio_pause` | int-requiring | - | the pause flag is discrete, not continuous: N5 (Q1; today `(int)0.5` silently un-pauses) |
| `audio_play` | other | - | float samples in; returns a channel number |
| `audio_play_loop` | int-requiring | - | loop count: N5, then the C int range (Q1); returns a channel |
| `audio_queue_size` | int-preserving | - | byte count (computed in a double, below 2^53) |
| `audio_saw` | float-producing | - | float samples |
| `audio_sine` | float-producing | - | float samples |
| `audio_square` | float-producing | - | float samples |
| `audio_stop` | int-requiring | - | channel number |
| `audio_stream_open` | int-requiring | - | freq (samples per second) and channels are counts: N5, then the C int range (Q1); returns a device id |
| `audio_stream_push` | other | - | float samples quantized to int16 |
| `audio_stream_queued` | int-preserving | - | sample count |
| `audio_sweep` | float-producing | - | float samples; frequencies, duration and amplitude are continuous; the wave selector is integer-valued: N5 (Q1) |
| `audio_volume` | int-requiring | - | channel index: N5 (Q1); the volume is a float gain |
| `bit_and` | int-requiring | LOSS | Lua `&` (§3.4.2): N5 operands, int64-pattern result (N8); today a double result |
| `bit_not` | int-requiring | LOSS | Lua unary `~` |
| `bit_or` | int-requiring | LOSS | Lua `\|` |
| `bit_shl` | int-requiring | LOSS | Lua `<<`; today masks the count mod 64, N8 needs >=64 gives 0 and negative shifts right |
| `bit_shr` | int-requiring | LOSS | Lua `>>` is logical (N8); today an arithmetic shift with `& 63` |
| `bit_xor` | int-requiring | LOSS | Lua binary `~` |
| `buf_copy` | int-requiring | - | offsets and counts |
| `buf_deinterleave` | int-requiring | - | channel count and index |
| `buf_dot` | float-producing | - | buffer dot product |
| `buf_fill` | float-producing | - | fills float storage; offsets by N5 |
| `buf_from_list` | float-producing | - | buffer storage is float: an int element converts (Q2) |
| `buf_from_pcm16le` | float-producing | - | decodes bytes to floats |
| `buf_get` | int-requiring | - | index; returns the float element |
| `buf_len` | int-preserving | - | element count |
| `buf_mix` | float-producing | - | float storage |
| `buf_peak` | float-producing | - | float max abs |
| `buf_resample_linear` | float-producing | - | float storage |
| `buf_scale_range` | float-producing | - | float storage |
| `buf_set` | int-requiring | - | index; the value converts to float storage (Q2) |
| `buf_to_pcm16le` | other | - | quantizes floats to byte values |
| `buffer` | int-requiring | - | size or [rows, cols] |
| `build_corpus` | int-requiring | - | counts; returns counts |
| `ceil` | int-preserving | LOSS | Lua math.ceil: an int when the result fits int64, else a float |
| `channel` | int-preserving | - | handle dict with int id/gen fields |
| `channel_closed` | int-requiring | - | channel handle ids |
| `char_at` | int-requiring | - | string position (Lua string.sub) |
| `chr` | int-requiring | - | byte 1..255, already exactness-checked (Lua string.char) |
| `clock_unix` | float-producing | - | fractional seconds |
| `close_channel` | int-requiring | - | channel handle ids |
| `copy_into` | int-requiring | - | offset; values convert to float storage |
| `cos` | float-producing | - | Lua math.cos |
| `db_execute` | other | LOSS | binds every numeric parameter with `%g`, 6 significant digits (ext_db.c:57-58, #1762). R1.7: the N6/N14 writer |
| `db_query_json` | other | LOSS | binds parameters with `%g` (#1762); encodes rows (N14) |
| `db_query_value` | other | LOSS | binds parameters with `%g` (#1762); decodes a numeric column with strtod, so integer text beyond 2^53 rounds |
| `dispatch` | int-requiring | - | integer table key, already exactness-checked |
| `divide` | float-producing | - | mirrors `/` (Lua §3.4.1: always float) |
| `dot` | float-producing | - | buffer dot product |
| `eigen_eval_loss` | float-producing | - | token ids are indices; the loss is a float |
| `eigen_generate` | int-requiring | - | token ids and max_tokens are integer-valued (N5, Q1); temperature and top_p are floats |
| `eigen_model_load` | other | - | parses model JSON numbers with strtod |
| `exec_capture` | other | - | the timeout is a duration in seconds (continuous, a float; Q1); returns exit status ints |
| `exit` | int-requiring | - | exit code: N5, then the C int range (Q1) |
| `exp` | float-producing | - | Lua math.exp |
| `f64_from_bytes` | int-requiring | - | 8 byte values: N5, then 0..255 (Q1; the modulo-256 wrap is gone); the float result's NaN is canonical (N12) |
| `f64_to_bytes` | other | - | float to 8 byte ints; f64_bits (N12) is the int-valued sibling |
| `fill` | int-requiring | - | count |
| `floor` | int-preserving | LOSS | Lua math.floor: an int when the result fits int64, else a float |
| `gather` | int-requiring | - | index or index vector; returns elements unchanged |
| `get_at` | int-requiring | - | index, row and col; returns the element |
| `get_observer_thresholds` | float-producing | - | observer thresholds (O3 drops h_low) |
| `gfx_circle` | other | - | centre, radius and colour are continuous: round to nearest (Q1), replacing truncation |
| `gfx_clear` | other | - | colour channels are continuous: round to nearest (Q1) |
| `gfx_clip` | other | - | the clip rect is continuous: round to nearest (Q1) |
| `gfx_delay` | other | - | milliseconds are a duration: continuous, round to nearest into Uint32 (Q1) |
| `gfx_fb` | int-requiring | - | w and h lay out the pixel buffer (integer-valued: N5, Q1); its elements are palette bytes read through `buffer_read_byte` (N5, then 0..255); dx, dy and scale are drawing coordinates and size (continuous: round to nearest, Q1) |
| `gfx_line` | other | - | endpoints and colour are continuous: round to nearest (Q1) |
| `gfx_open` | other | - | window width and height are gfx sizes: continuous, round to nearest (Q1) |
| `gfx_point` | other | - | position and colour are continuous: round to nearest (Q1) |
| `gfx_poll` | int-preserving | - | event fields x, y, scancode, button are ints |
| `gfx_read` | other | - | the origin is continuous: round to nearest (Q1); returns the channel values as ints |
| `gfx_rect` | other | - | rect and colour are continuous: round to nearest (Q1) |
| `gfx_rrect` | other | - | rect, radius and colour are continuous: round to nearest (Q1) |
| `gfx_text` | other | - | position, colour and scale are continuous: round to nearest (Q1) |
| `gfx_text_height` | int-preserving | - | pixel height, an int; the scale is continuous: round to nearest (Q1) |
| `gfx_text_width` | int-preserving | - | pixel width, an int; the scale is continuous: round to nearest (Q1) |
| `gfx_ticks` | int-preserving | - | SDL ticks (Uint32 ms) |
| `hex` | int-requiring | LOSS | refuses above 2^53 by a double compare, so int 2^53+1 reads as 2^53 and passes silently |
| `http_early_bind` | int-requiring | - | port |
| `http_post` | other | - | header values via value_to_string (N6) |
| `http_route` | other | - | formats via value_to_string |
| `http_route_authed` | other | - | formats via value_to_string |
| `http_serve` | int-requiring | - | port |
| `http_static` | other | - | formats via value_to_string |
| `index_of` | int-preserving | - | byte index or -1 |
| `inflate` | int-requiring | - | byte values: N5, then 0..255 (Q1; the modulo-256 wrap is gone) |
| `join` | other | - | elements via value_to_string (N6) |
| `json_build` | other | LOSS | N14 encoder; reads values through eigs_num_arg (a double) |
| `json_decode` | other | LOSS | N14 decoder; integer text decodes through strtod (a double) |
| `json_encode` | other | LOSS | N13/N14 encoder; reads values through eigs_num_arg; its `default:` writes null (builtins.c:998) |
| `json_path` | other | LOSS | decodes with strtod, then formats (N14, N6) |
| `leaky_relu` | float-producing | - | ML activation (float tensors; no Lua counterpart) |
| `len` | int-preserving | - | count (Lua `#` is an integer) |
| `list_contains` | other | - | equality via values_equal (N2) |
| `list_index_of` | int-preserving | - | returns an index; equality via values_equal (N2) |
| `list_insert_at` | int-requiring | - | position (Lua table.insert) |
| `list_remove_at` | int-requiring | - | position (Lua table.remove) |
| `list_slice` | int-requiring | - | start and end indices |
| `list_truncate` | int-requiring | - | new length |
| `log` | float-producing | - | Lua math.log; log of 0 is -inf (N11) |
| `log_softmax` | float-producing | - | ML (float) |
| `matmul` | float-producing | - | float tensors |
| `matmul_at` | float-producing | - | float tensors |
| `matmul_bt` | float-producing | - | float tensors |
| `max` | int-preserving | LOSS | Lua math.max returns the winning argument with its own subtype |
| `mean` | float-producing | - | arithmetic mean |
| `min` | int-preserving | LOSS | Lua math.min |
| `model_load_weights` | other | - | alias of eigen_model_load |
| `monotonic_ms` | float-producing | - | fractional milliseconds |
| `monotonic_ns` | int-preserving | LOSS | exact below 2^53 ns (104 days of uptime), a rounded double after; an exact int under N1 |
| `multiply` | int-preserving | LOSS | scalar arm mirrors `*` (overflow raises, (A)); buffer arms float |
| `native_train_step_builtin` | int-requiring | - | token ids are integer-valued (N5, Q1); lr is a float (a numeric string is accepted through strtod) |
| `nearest_in_range` | float-producing | - | geometry floats; the `index` field is an int |
| `nearest_in_range_all` | float-producing | - | geometry floats; the `index` field is an int |
| `negative` | int-preserving | LOSS | mirrors unary `-`; negating INT64_MIN raises (N4b) |
| `net_accept` | int-requiring | - | socket handle |
| `net_close` | int-requiring | - | socket handle |
| `net_dial` | int-requiring | - | port; returns a handle |
| `net_listen` | int-requiring | - | port; returns a handle |
| `net_port` | int-requiring | - | socket handle; returns a port |
| `net_recv` | int-requiring | - | handle and max bytes |
| `net_send` | int-requiring | - | the handle and the byte values: N5, bytes then 0..255 (Q1; the modulo-256 wrap is gone) |
| `norm` | float-producing | - | L2 norm |
| `num` | other | LOSS | N10 parser: integer text decodes through strtod today (a double) |
| `num_copy` | int-preserving | LOSS | copies a number and must keep its subtype; today re-boxes through a double |
| `numerical_grad` | float-producing | - | finite differences |
| `numerical_grad_cols` | float-producing | - | finite differences; column indices int |
| `numerical_grad_rows` | float-producing | - | finite differences; row indices int |
| `observe` | other | - | observer readouts (O4) |
| `ord` | int-preserving | - | byte code (Lua string.byte) |
| `pi` | float-producing | - | Lua math.pi |
| `pow` | float-producing | - | mirrors `^` (Lua §3.4.1: exponentiation is always float) |
| `ppu_render_frame` | int-requiring | - | reads the emulated memory buffer through `buffer_read_byte`: byte values by N5, then 0..255 (Q1; the modulo-256 wrap is gone) |
| `print` | other | - | N6 printing via value_to_string |
| `proc_read_buf` | int-requiring | - | fd and max bytes; bytes stored as floats |
| `random` | float-producing | - | Lua math.random() in [0,1) |
| `random_hex` | int-requiring | - | digit count |
| `random_int` | int-requiring | LOSS | Lua math.random(m, n) is an integer; bounds read as doubles today |
| `random_normal` | float-producing | - | dims int; samples float |
| `range` | int-preserving | - | bounds by N5; the elements are ints (floats today, inside int range) |
| `read_bytes` | int-preserving | - | byte values 0..255 |
| `read_bytes_buf` | int-requiring | - | cap and length; bytes stored as floats |
| `record_history` | other | - | truthiness flag in; previous flag out |
| `recv` | int-requiring | - | channel handle ids |
| `recv_timeout` | int-requiring | - | the channel handle: N5 (Q1); milliseconds are a duration (continuous, a float) |
| `relu` | float-producing | - | ML activation (float tensors; no Lua counterpart) |
| `reshape` | int-requiring | - | rows and cols |
| `round` | int-preserving | LOSS | no Lua counterpart; follows floor and ceil (Q4) |
| `sandbox_run` | int-requiring | - | iteration, byte and work limits; returns line ints |
| `scan_int_tokens` | int-preserving | LOSS | integers accumulate in a double |
| `scan_ints` | int-preserving | LOSS | integers accumulate in a double |
| `scatter_add` | float-producing | - | indices exactness-checked; float accumulation |
| `seed_random` | int-requiring | LOSS | `(long)` of a double; Lua randomseed takes integers |
| `send` | int-requiring | - | channel handle ids |
| `set_at` | int-requiring | - | index, row and col; a buffer value converts to float |
| `sgd_update` | float-producing | - | float update |
| `sgd_update_cols` | float-producing | - | column indices int |
| `sgd_update_rows` | float-producing | - | row indices int |
| `shape` | int-preserving | - | dimension counts |
| `shared_delete` | int-preserving | - | removed count |
| `shared_incr` | int-preserving | LOSS | shared counter: delta and stored value in doubles |
| `shared_size` | int-preserving | - | entry count |
| `sign_extend` | int-requiring | LOSS | `(int64_t)` of a double |
| `sin` | float-producing | - | Lua math.sin |
| `softmax` | float-producing | - | ML (float) |
| `sort` | other | LOSS | sort_cmp_num compares doubles: ints beyond 2^53 tie (N2 needs exact) |
| `sort_by` | other | LOSS | key results compared as doubles |
| `spawn` | int-preserving | - | handle dict with int id/gen fields |
| `sqrt` | float-producing | - | Lua math.sqrt; sqrt of -1 is NaN (N11) |
| `state_at` | int-requiring | - | step index |
| `store_close` | int-requiring | - | handle id/gen |
| `store_collections` | int-requiring | - | handle id |
| `store_count` | int-requiring | - | handle and page ids; returns a count |
| `store_delete` | int-requiring | LOSS | key formatted `%d` of an `(int)` cast: 1.9 finds "1"; keys above INT_MAX are UB (probed) |
| `store_drop` | int-requiring | - | handle and page ids |
| `store_get` | int-requiring | LOSS | same key cast as store_delete; decodes records (N14) |
| `store_open` | int-preserving | - | handle dict with int id/gen fields |
| `store_put` | other | LOSS | the record encoder writes a non-int32 number with `%.15g`: 1234567890123456 is stored as 1234567890123460 and 0.1 + 0.2 as 0.3, on main and the tag (#1762). R1.7: the N6/N14 writer; R2.3: refusal inside the encoder |
| `store_query` | other | LOSS | decodes records; integer text through strtod (N14) |
| `store_update` | other | LOSS | same key cast as store_delete; re-puts through the `%.15g` encoder (#1762); N13/N14 |
| `str` | other | - | N6 printing via value_to_string |
| `str_from_bytes` | int-requiring | - | byte values: N5, then 0..255 (Q1; Lua string.char raises on 65.5 and on 256) |
| `stream_open` | int-requiring | - | element count, already floor-checked |
| `stream_write` | float-producing | - | writes a raw f64 |
| `substr` | int-requiring | - | start and length (Lua string.sub) |
| `subtract` | int-preserving | LOSS | scalar arm mirrors `-` (overflow raises, (A)) |
| `sum` | int-preserving | LOSS | an all-int input sums exactly, and overflow raises (A); today a guarded double sum |
| `tan` | float-producing | - | Lua math.tan |
| `task_alive` | int-requiring | - | task handle (packed below 2^53, exactness-checked) |
| `task_detach` | int-requiring | - | task handle |
| `task_join` | int-requiring | - | task handle |
| `task_kill` | int-requiring | - | task handle |
| `task_sched_seed` | int-requiring | LOSS | `(int64_t)` of a double |
| `task_self` | int-preserving | - | task handle |
| `task_send` | int-requiring | - | task handle |
| `task_sleep` | other | - | milliseconds are a duration: continuous, a float (Q1) |
| `task_spawn` | int-preserving | - | returns a task handle |
| `tensor_load` | float-producing | - | float tensor; shape ints |
| `tensor_save` | float-producing | - | writes float cells |
| `text_builder_append` | other | - | formats via value_to_string (N6) |
| `text_builder_append_line` | other | - | formats via value_to_string (N6) |
| `thread_join` | int-requiring | - | thread handle id/gen |
| `throw` | other | - | message via value_to_string |
| `token_name` | int-requiring | - | token id |
| `try_recv` | int-requiring | - | channel handle ids |
| `type` | other | - | `type of` an int or a float is "num" ((B)) |
| `usleep` | other | - | microseconds are a duration: continuous, round to nearest (Q1) |
| `vm_run_bytecode` | int-requiring | - | opcode bytes and ABI numbers |
| `write` | other | - | N6 printing |
| `write_bytes` | int-requiring | - | byte values: N5, then 0..255 (Q1; the modulo-256 wrap is gone); returns bytes written |
| `zeros` | int-requiring | - | size or [rows, cols]; elements are float 0.0 |
| `zeros_like` | float-producing | - | float zeros |
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
    parameters; `eigs_round_arg` for its continuous ones);
  - vm.c index paths (`jit_helper_index_get`/`set`, `CASE(INDEX_*)`) and
    `range_bound` (builtins.c:3877);
  - the JIT `OP_INDEX_SET` integrality guard (jit.c:4100-4112) stays
    correct, because a non-exact index goes to the helper;
  - the leaf's `INDEX_GET` arm (vm.c:1907-1931): in round 1 it bails on an
    int index (the generic path applies N5), and a float index still goes
    through `vm_index_is_int`;
  - `buffer_read_byte` and `finite_num_to_byte` (Q1 byte values), deleted
    in R1.6 (§2.7).
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
    NaN box equal to itself; the sort comparators (NaN order: §11 Q8).
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
  - the observe helpers `jit_helper_observe_assign_local` (1661) and
    `jit_sample_num_gated`, which must route an SMI into the numeric channel
    in round 1 already, converting to double for the distance (§2.5);
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
meaning change lands in the commit that carries its token change (§2.7).

### Round 1: the core model (Alt 1R)

1. **R1.1, the slot layer: the SMI exists, every slot reader is forced (no
   producer yet).**
   - Add `TAG_SMI`, `slot_is_smi`, `slot_from_int`, `slot_smi_val`,
     `slot_f64_value` and `slot_int_value` (§2.6).
   - The token changes of this commit: `slot_is_num` -> `slot_is_f64`,
     `SLOT_NUM_RAW` -> `SLOT_F64_RAW`, `slot_from_num` -> `slot_from_f64`,
     the container helpers `*_num` -> `*_f64`; `slot_is_numeric` deleted;
     **`slot_as_double` deleted**. Its 15 calls are rewritten with an
     explicit int decision: the arithmetic and compare arms take their float
     fast path through `slot_f64_value` and send anything else to the slow
     path; the leaf evaluator's `INDEX_GET` and `ADD`/`SUB`/`MUL` arms bail
     on anything that is not a float.
   - The D2/D3 dispositions (§2.5): `eigs_slot_ref`, `obs_slot_observable`,
     `slot_as_ptr` and `slot_as_heap` refuse an SMI (abort; `slot_as_ptr`
     in ASan and debug builds); `slot_type_name` gains its SMI arm. Every D1
     function gets its SMI arm as the compiler stops at it.
   - `tools/phase2_check.sh` (§9.2) lands here with its calibration, and
     runs the rows whose round has landed.
   - Test: the C slot test (§2.5), through the amalgamation, built from the
     inventory's D1-D3 list and run under ASan; plant 1 (§9.3). Language
     behaviour is unchanged (differential over the suite's `.eigs` corpus),
     because nothing produces an SMI yet.
2. **R1.2, the Value layer and the renames (deprecate, then delete).**
   - R1.2a: `VAL_INT` (appended), `make_int`, the §2.6 readers and
     `val_type_name(VAL_INT) = "num"`. **Delete the `default:` arm of
     `eigs_json_encode_value` (builtins.c:998)**, enumerating the types, so
     `-Werror=switch` reaches the last switch that could absorb `VAL_INT`
     silently. The old names stay, marked `__attribute__((deprecated))`;
     macros are routed through a deprecated inline.
   - R1.2b-n: one commit per file group (vm.c; builtins.c; tensor; buf;
     host; gfx; net/http/db/model; store; trace; observer; embed; lint and
     LSP). Each migrates its sites by the §6 table and lowers the
     deprecation-warning count. `VAL_INT` exists and is handled (the int
     arms are written against the final semantics), but nothing produces
     it, so behaviour is unchanged (differential).
   - R1.2z: delete the old names (`VAL_NUM`, `num_`, `VAL_NUM_RAW`,
     `VAL_NUM_OFFSET`, `make_num`, `make_num_permanent`, the `eigs_num_arg`
     and `eigs_slot_num` families, `buf_num_arg`). A straggler fails to
     compile (§2.3a measured which sites).
   - Risk: the size (1,416 compile-forced sites across R1.1-R1.2); and a
     mis-migration that picks `eigs_float_arg` for an int-preserving
     builtin, caught by the int-fuzz gate (§9.4).
3. **R1.3, the flip: int literals and exact int arithmetic.**
   - N1, with its token changes in this same commit: the lexer produces an
     int literal; the AST payload `num` and the token's `num_val` become an
     `EigsNum` (renamed, so the parser, compiler, lint and LSP sites stop
     compiling here); **`OP_INT_ZERO`, `OP_INT_ONE` and `OP_INT_CONST` are
     appended** to `OpCode` (the four exhaustive OpCode switches stop
     compiling until they name them; three new interpreter CASEs; the JIT
     scanner and the leaf scanner refuse them by their `default:`);
     `OP_NUM_ZERO`/`OP_NUM_ONE`/`OP_CONST` keep their float meaning in all
     three executors. The constant pool keys on kind and bits.
   - N3 with (A) overflow raise, N2 exact cross-kind comparison, N4b `-x`,
     N7 `num_type`.
   - EQ/NE: the only bit fast path is "both SMI"; anything boxed compares by
     value (§2.1).
   - The JIT scanner refuses `BAND`/`BOR`/`BXOR`/`SHL`/`SHR`/`BNOT`/`MOD`.
   - **The tape goes to v7 in this commit.** The moment ints exist, a v6
     writer would print `3` for both kinds and replay would turn ints into
     floats. The float token marks its kind now (`3.0`); N6's full repr
     replaces it in R1.7, still inside v7.
   - The observer routes an SMI into the numeric channel (converted to
     double); `obs_slot_observable`'s refusal (R1.1) catches a missed caller.
   - The `trace` tier (§9.2, the leaf differential) and the tier witnesses
     start gating here, because ints now reach all three evaluators.
   - The visible change is small: ints print as today. The rest waits for
     N4/N6.
   - Risks:
     - JIT int loops leave the JIT (§3: +70% Ir on a counter loop), and the
       leaf evaluator stops computing int helpers. Declare the CodSpeed
       baseline move first.
     - Consumer hashes that relied on double rounding now raise ((A)); they
       move to the N9 wrapping builtins.
4. **R1.4, N4.** `//` (token, parser, `OP_IDIV` appended,
   `op_name`/`op_stack_effect`/obs marker/ABI test), `//=` beside `/=`
   (Q6, decided), `%` floor modulo for ints and floats, int division by
   zero raises, `INT64_MIN % -1` is 0.
5. **R1.5, N8.** Bitwise ops on ints with Lua's shift rules; `bit_*`
   returns ints.
6. **R1.6, N5, N9, N10 and the §6 builtins.** Every int-preserving and
   int-requiring row, the 42 LOSS rows first; Q1 (decided): integer-valued
   parameters through `eigs_int_arg_range`/`eigs_byte_arg`
   (`finite_num_to_byte` and `buffer_read_byte` deleted in this commit),
   continuous ones through `eigs_round_arg` once §11 Q7 is decided (until
   then they keep R1.2's behaviour-preserving truncation); Q4 `round`;
   `num of` (#1638); the N9 width family.
7. **R1.7, N6 and N14's int half.**
   - Python-repr floats; ints as exact digits.
   - The constant dedup compares bits, so `-0.0` survives.
   - JSON writes ints as digits and floats with `.0`; integer text within
     int64 decodes as an int; `1e400` raises.
   - #1762's writers: `store_json_encode` and `db_build_query` go through
     the same N6 writer (§6), unless #1762 landed on main first.
   - `src/freestanding/mini_fmt.c` and `mini_strtod.c` follow, gated by
     `make freestanding-libc-diff`.
   - This is the largest visible change: every golden that prints an
     integral float.
8. **R1.8, the embed API (Q3, decided), lint/LSP type knowledge and docs.**
   `eigs_value_as_num` converts an int (like `lua_tonumber`);
   `eigs_value_new_int`, `eigs_value_as_int` (with a success flag, like
   `lua_tointegerx`) and `eigs_value_is_int` are added; `EIGS_TYPE_NUM`
   covers both kinds. Docs: SPEC, COMPARISON, README, llms.txt executed
   fences. The CLAUDE.md same-PR docs rule applies to the integration PR as
   a whole.

### Round 2: IEEE (N11-N14 remainder), on the experiment's evidence

1. **R2.1, canonical NaN at the single double writer** (`slot_from_f64`)
   **and the JIT NaN bails** (§4.3), while `num_guard` still keeps NaN out:
   memory safety first.
   - Test: the C slot test writes every tag-spelling NaN payload. The
     #1746 plant (a raw store) segfaults in `slot_incref`.
2. **R2.2, retire `num_guard`, `num_guard_named`, `EIGS_NUM_MAX` and the
   1e308 clamp** (74 sites, the leaf's included). `EIGS_STRICT` becomes an
   opt-in trap
   (state.c:62). `sqrt of -1` is NaN, `log of 0` is -inf, `x/0` is ±inf,
   `0/0` and float `x%0` are NaN. The consumers no token marks (§2.7):
   `values_equal_impl`'s identity shortcut excludes floats; NaN order in
   sort follows §11 Q8 once decided.
3. **R2.3, N13 refusal inside the writers:** the JSON encoder, the store
   encoder (delete the pre-walk `store_nonfinite_scalar`), the byte
   encoders and the int conversion. This removes the class #1746 chased for
   three rounds, rather than its instances.
4. **R2.4, N12.** `f64_bits`/`f64_from_bits`, buffer bits get/set, and a
   canonical NaN at the embed boundary.
5. **R2.5, tape v7 `inf`/`-inf`/`nan` tokens; N6 non-finite printing;
   N14 `1e400` raises.**
6. **R2.6, the #1746 residue:**
   - the gfx/net/model `fix_trunc` sites;
   - `net_send` continuing after a raise (ext_net.c:364);
   - `buf_to_pcm16le` NaN;
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
  used to wrap. The DMG emulator feeds `ppu_render_frame` its memory buffer
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
- `O`: a loop, in a function or at module level, run in the `osr` tier
  (`EIGS_JIT_OSR_THRESHOLD=1`): the OSR shape.

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
| `osr <chunk>` | in the `osr` tier, `<chunk>`'s row has `osr yes`, and `oent + oadv` lies past the loop's `JUMP_BACK`: the thunk ran the loop to its exit |
| `osr-stop <chunk> <OP>` | `osr yes`, and the opcode at `oent + oadv` is `<OP>` |

Why `EIGS_JIT_HOT` and not only `EIGS_JIT_STATS`/`EIGS_JIT_STOPS`:
`STATS` counts are process-wide (`scanned`, `compiled`), and `STOPS` records
where each compile's prefix ended. Neither says whether a run executed the
operation natively. `HOT` records, per chunk, the last run's native advance
(`adv` for the function thunk, `oadv` from `oent` for the OSR thunk, jit.c:
237-245), which is exactly that. `phase2_check.sh` reads all three: `STATS`
must show `compiled >= 1` for an `fn`/`osr` claim, and for a `-stop` claim
whose stop is a compile stop, `STOPS` must name `<OP>`. The leaf has no
counter; its witness is the entry count, because both generic call paths
count an entry (vm.c:2617, vm.c:4353) and the leaf path never does. The
witness uses only existing diagnostics: nothing in production changes so a
test can observe it.

**Calibrated on the main binary this round** (each predicate holds where it
should and fails where it should not):
- `leaf sq`: `sq` called 200 times has no `HOT` row in the `off`, default and
  `osr` tiers; with `EIGS_TRACE` set it shows `sq 200 yes ... RET`. The same
  predicate is false for the leaf-off run.
- `fn g`: `g` called 60 times shows `g 60 yes ... RET ... RETURN`.
- `fn-stop h ADD`: `h` called 55 times with numbers and then once with a
  string operand (the program raises there) shows `h 56 yes ... 30`; offset
  30 of `h` is `ADD`: the thunk's guard bailed there and the interpreter
  raised.
- `osr f`: `f`'s loop under `EIGS_JIT_OSR_THRESHOLD=1` shows `osr yes`,
  `oent 31`, `oadv 57`: 31 + 57 = 88, past `JUMP_BACK` at 85.

**What the witnesses expect in round 1.** The JIT and the leaf bail on an
int that meets an arithmetic, comparison, bitwise or index op, and refuse an
int literal, until round 5 (§4), so such a row's honest witness is
`fn-stop`, `osr-stop` or `leaf-gen`: it proves the guard fired (or the
scanner refused) and the interpreter produced the row's output. An int that
only moves, into a local, a field, a list element or a module binding,
passes through the JIT's C helpers and the leaf's borrows, so those rows
(`N1.fn-int-local`, `N1.fn-dot-fields`, `N1.osr-module-int-store`,
`N5.osr-index-set`, `N1.leaf-dot-get`) have native witnesses already in
round 1. A float row's witness is native too: it proves the float meaning of
`NUM_ZERO`/`NUM_ONE`/`CONST` survived in the JIT and the leaf. Round 5 flips
the int witnesses to native, one row at a time, and each flip is a
deliberate edit of the row.

### 9.2 `tools/phase2_check.sh <tag-binary> <branch-binary>` (R1.1 builds it)

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
  - zero rows is a FAIL.
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
- **Exit 0** iff in every tier examined == tag_fail == branch_pass > 0,
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
    the row.

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

### 9.4 The int-fuzz gate (round 1; the §6 table's enforcement)

It follows `tests/test_bool_fuzz.sh` (which feeds bools to every builtin
`--api --json` lists):
- every numeric builtin of §6 is called with ints in each numeric slot;
- **int-preserving:** the result's `num_type` is "int" for int inputs;
- **int-requiring:** a float with a fraction raises `value` (N5), and an
  integral float converts;
- **float-producing:** the result is a float;
- the population is derived from `--api --json` intersected with the table,
  and the gate prints `examined=N` equal to the table's row count.

It catches a mis-migrated accessor (R1.2) that compiles.

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

## 11. Decided questions (Q1-Q6) and what stays open

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
    consumers no longer wrap), `eigs_byte_arg`, `eigs_int_arg_range` and
    `eigs_round_arg` (§2.6), R1.6 (§8).
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
  §6 (`round` int-preserving, LOSS), R1.6; `eigs_round_arg` uses the same
  tie rule.
- **Q5, `why is x` for an int binding: DECIDED.** An int when Δv fits in
  int64, otherwise a float. A readout never raises; (A) applies to
  operators, not to observer readouts. Applied: round 3 (O4).
- **Q6, `//=`: DECIDED.** Add it beside `/=`. Applied: R1.4.

**Open, new in design round 2.** Round 1 must not pick these silently; each
needs the standard answer cited or an owner decision.
- **Q7. A finite continuous parameter outside the C type's range**
  (`gfx_rect of [3e9, 0, 10, 10, ...]`). Q1 decides rounding to nearest,
  and N13 already decides that a non-finite one is refused (it is an int
  conversion). The finite out-of-range case is open; today the C cast is
  undefined behaviour. Options: saturate to the C range (it draws
  off-screen, as a huge float coordinate does in SDL3), or raise `value`.
  This design does not pick: R1.2's gfx group re-points the reads to
  `eigs_float_arg` with today's truncation (behaviour unchanged, like every
  R1.2 commit), and the part of R1.6 that installs `eigs_round_arg` waits
  for the decision. Nothing else in round 1 depends on it.
- **Q8. NaN in an ordering.** From R2.2 a NaN can reach `sort`, `sort_by`,
  `min` and `max`. NaN has no order: C's `qsort` with an inconsistent
  comparator gives an unspecified order, Python's `sorted` too, and Lua's
  `table.sort` may raise "invalid order function". Options: raise `value`
  when a NaN is compared for order, or define a total order (NaN last, as
  IEEE `totalOrder` and numpy's `sort` do).
