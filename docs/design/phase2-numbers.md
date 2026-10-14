# Phase 2 numbers (#1758): round 0 design

Status: design for blind review, before round 1 builds. Nothing here changes
`src/`. Spec: issue #1758 (Revision 1) and its owner decisions (A), (B), (C).
Evidence base: issue #1746 and the `exp-ieee-p1` branch (canonical NaN, the
single slot writer, the JIT bailing on NaN, refusal inside writers).

Tree measured: `phase2-numbers` at `0740af03` (main, v0.46.0-8). The tag the
Done-when means is `v0.46.0` = `4a3a5c19`.

Companion artifacts:
- `tools/phase2_inventory.py`: the site inventory and the builtin-table check.
  It writes `docs/design/phase2-inventory.txt`.
- `tests/phase2/MAP.md`: every N, O and T item mapped to planned rows.

Contents:
1. The inventory
2. Representation
3. Measured prototype
4. The JIT
5. N12 and SMI share the NaN space
6. Builtin classification
7. Semantics-to-sites map
8. Round plan
9. Test plan
10. Lua differential tool
11. Open questions this design does not decide

---

## 1. The inventory

`python3 tools/phase2_inventory.py` prints `examined=1773 classified=1773
unclassified=0` on this tree and writes every site to
`docs/design/phase2-inventory.txt` (file:line, enclosing function, token,
syntactic kind, category).

**Population.** A site is one occurrence, outside comments and string
literals, of a token of the value model's numeric vocabulary in `src/*.c` and
`src/*.h`. The vocabulary is:
- the type tag `VAL_NUM` and the slot predicates;
- the raw and checked payload accessors and the constructors;
- the clamp (`num_guard`) and the number formatter;
- the double parsers (`strtod`, `atof`);
- the AST literal fields (`AST_NUM`, `data.num`, `num_val`);
- in the JIT files only, the tag-range immediates (`0xFFF8`..`0xFFFF`) and the
  emitters that assume a double (`emit_load_numeric_operand`, the `*sd`
  arithmetic, `cvt*`, `fmod`, ...). The JIT's guards compare raw tag bits and
  name no vocabulary token, so without these the JIT category would hold 40
  sites instead of 127.

**The key and its blind spot.** The key is the token, so code that handles a
number without naming one is invisible. Two derived checks bound that, and
both can make `unclassified` nonzero:
1. Every function that returns or writes out a `double` and whose body
   performs a payload read is a numeric accessor. It must be in the
   vocabulary (its call sites then count as sites) or in a reviewed
   `WRAPPERS` list with a reason. 17 such functions exist. 11 are in the
   vocabulary and 6 are wrappers, for example `tensor_to_flat`, whose
   per-element read is the site.
2. Every `VAL_NUM`/`AST_NUM` must sit in a recognized syntactic position:
   test, case, tag store, type yield, data, or emitter immediate. An
   unrecognized position (for example `1u << VAL_NUM`) is unclassified.

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
| b | payload reads | 505 | READ 392, RAW 113 |
| c | producers | 472 | PRODUCE 373, GUARD 71, WRITE 22, PARSE 3, TAGSET 3 |
| d | JIT emitters and guards | 127 | EMIT 89, RAW 27, PRODUCE 6, TEST 2, GUARD 1, TAGSET 1, WRITE 1 |
| e | number formatting | 14 | |
| f | equality, ordering and hashing | 27 | |
| g | tape encode and decode | 20 | |
| h | JSON, store and db encoders | 70 | |
| i | observer numeric paths | 90 | |
| j | embed API | 64 | |
| | **total** | **1773** | |

`WRITE` is `VAL_NUM_RAW(v) = x`, the NUM_REUSE in-place writes the brief
names as producers.

Largest files: builtins.c 319, vm.c 304, ext_gfx.c 229, builtins_tensor.c
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
or equality it calls. That gives 229 numeric builtins, and §6
classifies every one. The script fails if a numeric builtin has no row, a row
names no numeric builtin, a class or loss mark is not one of the allowed
tokens, or a `LOSS` row has no double path in its closure.

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

**Canonical-form invariant (all alternatives):** an int in [-2^47, 2^47) is
always an SMI in a slot, never boxed; a boxed int is always outside that
range. Equality fast paths, hashing and the tape depend on it (#1758).

It is enforced inside the two writers that can put an int into a slot, not
beside their callers (the #1746 lesson):
- `slot_from_int(int64_t)`, the only int-to-slot constructor;
- `slot_from_heap(Value *)`, which already normalizes the null and bool
  singletons (value_slot.h:86) and gains the same rule for a small boxed
  int.

Every other route into a slot goes through one of them: `slot_from_value`,
`eigs_container_slot`, `vm_push`/`slot_bridge_wrap`, the tape decoder (it
returns Values), and the JIT `OP_CONST` emitter, which must compute its bits
with the same function (§4).

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
| **Alt 1R** | the same sites | **1,449 non-JIT sites and 39 JIT-file sites name a renamed or deleted token and stop compiling** until visited. 197 sites keep their token (the clamp 73, the formatter 7, buffer float reads 38, parsers 17, conversions 14, the embed accessor 48); each is pinned by a MAP row or a round-2 item. 88 JIT emitter tokens are reviewed per opcode (§4). | **A compile error.** It cannot exist in code that names the vocabulary. Two residual routes remain: (1) a switch with a `default:` absorbs the new `VAL_INT` (only builtins.c:915-998, removed first in round 1), and (2) code that tests raw slot bits: 74 sites, 59 of them value_slot.h's own definitions, 13 in the JIT files, 2 in eigenscript.c (a bit-identity shortcut that stays correct). |
| **Alt 2** | payload reads and producers (enforced only if `num_` is renamed); the type tests keep compiling and now admit ints | none for the 382+63 type tests and the 484 checked reads | **A silent wrong number.** After `== VAL_NUM`, a `VAL_NUM_RAW` read of an int reads its int64 bits as a double (5 reads as 2.5e-323). An accessor that converts loses precision above 2^53 silently. In the JIT, three emitters misread with no compiler to catch them: `emit_load_numeric_operand`'s heap arm (jit.c:2343) loads `data.num_` of a boxed int; the `OP_SET_LOCAL` in-place branch (jit.c:3410) writes double bits into an int Value; the `OP_CONST` emitter (jit.c:2816) pushes `VAL_NUM_RAW` bits of an int constant. Constant dedup `const_equal` (chunk.c:212) merges `3` and `3.0`. |
| **Alt 3** | only the sites that need exactness (N2, N3, N6, N8, N14, tape) | none: every existing read compiles and works below 2^53 | **A silently lossy double**, exact below 2^53, so ordinary tests cannot see it. This is precisely the class the brief says to design out. |

### 2.4 The choice: Alt 1R

1. **It is the only alternative whose missed site is loud by construction.**
   1,488 of 1,773 sites stop compiling until a person decides, site by site,
   whether the site admits ints and with what semantics. Alt 2 and Alt 3
   leave 445 type tests and cases plus 484 checked reads compiling with a
   widened or lossy meaning.
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

### 2.5 The slot layer already mishandles an unknown tag, today

Nothing produces `0xFFFA` yet, so these paths are dead today. They show what
the **first** SMI producer would do anywhere it is missed, and they are why
round 1 starts by making every slot classifier exhaustive:

| function | what an SMI slot does today |
|---|---|
| `slot_type` (container.h:92), `eigs_slot_ref` (container.h:98), `slot_bridge_unwrap` (vm.c:784), `slot_truthy` (vm.c:862) | **pointer misread**: "not num/null/bool" is taken to mean heap, so the payload is dereferenced as a `Value *` |
| `vm_slot_lift` (vm.c:826), `slot_to_value` (eigenscript.c:1885) | **silent null**: the int becomes null |
| `obs_slot_observable` (vm.c:1630) and the observe sites | **silently unobserved**: the binding answers from no data |
| `write_slot` (trace.c:2836) | writes `<unknown>`, an unreplayable marker, so replay falls back to live source |
| `slot_as_double` (vm.c:872) | returns 0, taking the slow path into `slot_bridge_unwrap`, which misreads |
| `slot_type_name` (vm.c:3000) | answers `"num"` (right by accident) |

Round 1's first commit makes each of these test the SMI tag explicitly and
`abort()` on an unknown tag, instead of guessing heap or null.

### 2.6 The accessor API after round 1 (Alt 1R)

```
/* slots */
int      slot_is_f64(EigsSlot);     /* high16 < 0xFFF8 */
int      slot_is_smi(EigsSlot);     /* high16 == 0xFFFA */
int      slot_is_int(EigsSlot);     /* SMI or heap VAL_INT */
int      slot_is_number(EigsSlot);  /* f64 or int */
EigsSlot slot_from_f64(double);     /* the ONE double writer; round 2: canonical NaN */
EigsSlot slot_from_int(int64_t);    /* the ONE int writer; SMI or boxed (canonical) */

/* Values */
Value   *make_float(double);
Value   *make_int(int64_t);
EigsNum  eigs_number_arg(const Value *, const char *who); /* int-preserving */
double   eigs_float_arg(const Value *, const char *who);  /* float-producing: int converts */
int64_t  eigs_int_arg(const Value *, const char *who);    /* int-requiring: N5 exact rule */
```

Each `_arg` reader also has the list, slot and optional forms of today's
checked accessors.

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
N1, `i` is an int, so the JIT's LT and ADD bail on the SMI every iteration
(§4). Expect at least the interpreter's 685 (+70%) on int loops until round
5's fast paths.

The CodSpeed lane's two-sided Ir gate (#1220) will fire on its JIT-tier
targets with int loops: `scalar_loop`, `bench_perf`, `bench_dmg_shape`,
`bench_idxset` and the real DMG `cpu_instrs` row (codspeed.yml). The lane's
own measurement bounds the size: "JIT removes 48% of the instructions on
bench_dmg_shape, 11.8% on DMG itself" (codspeed.yml:65-67). Losing the JIT
on int code costs up to about 1.9x Ir there, and about 1.13x on DMG. That
must be accepted up front, not discovered.

---

## 4. The JIT

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

### 4.2 Producer emitters: these do not bail, they must change

The emitter writes bits directly, so a guard cannot protect these. A missed
one silently produces a float where the interpreter produces an int:

| emitter | today | round 1 |
|---|---|---|
| `OP_NUM_ZERO`/`OP_NUM_ONE` (2797-2814) | pushes the double bits of 0.0 and 1.0 | The compiler (compiler.c:2071-2077) emits these for any literal `== 0.0` or `== 1.0`, so `0` and `0.0` share an opcode. Round 1 makes them mean int 0 and 1: the interpreter (vm.c:3257) and the emitter push SMI bits; `0.0` and `1.0` go through `OP_CONST`. |
| `OP_CONST` (2816-2838) | `VAL_NUM`: the bits of `num_`; else pushes a `TAG_HEAP` pointer plus an incref | An int constant would be pushed boxed, breaking the canonical form. Compute the bits with `slot_from_int` at compile time: SMI immediate, or `TAG_HEAP` for an int64 outside the SMI range. `last_imm` (4375) must then be 1 exactly when the pushed bits are immediate, never for a boxed int: the jit skill's lockstep rule. |
| BAND/BOR/BXOR/SHL/SHR (3716-3768), BNOT (3819-3830) | double operands, cvttsd2si, op, cvtsi2sd: a **double** result | N8 makes bitwise results ints. Round 1: **the scanner refuses these opcodes** (the op interprets) until round 5 emits SMI results. |
| MOD (3511-3585) | `call fmod`, which truncates toward zero | N4 makes `%` floor modulo (sign of the divisor), so fmod is wrong for mixed-sign floats (`-7.5 % 2` gives -1.5; Lua gives 0.5). Round 1: the scanner refuses MOD, or the emitter adds the floor correction. |

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
    `round` has no Lua counterpart and follows floor and ceil (§11, Q4).
- **float-producing:** ints convert to float and the result is a float.
  Examples: Lua's `math.sin`, `sqrt`, `log`, `exp`; `/` and `^`, which
  "always convert integer operands to floats" (§3.4.1); and the float-tensor
  and audio-sample builtins (buffer storage is float).
- **int-requiring:** an argument is an index, count, size, code or bit
  pattern, so it converts by N5's exact rule. Examples: Lua's string
  positions, `table.insert`/`table.remove` positions, bitwise operands
  (§3.4.2), `math.random(m, n)` bounds, and `math.randomseed`.
- **other:** everything else that takes or returns numbers:
  - formatting (N6);
  - JSON, store and db codecs (N13, N14);
  - parsing (`num`, N10);
  - `type` ((B));
  - byte consumers (truncate and wrap modulo 256, documented
    eigenscript.h:1901);
  - C-API arguments that truncate today: gfx coordinates, audio rates,
    `usleep`. Their N5 scope is open: §11, Q1.

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

**Counts** (from the table below, checked by `tools/phase2_inventory.py`,
which prints them): 229 numeric builtins. By class: 37 int-preserving, 58
float-producing, 67 int-requiring, 67 other. 39 are LOSS:
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
- JSON and parsing: `json_decode`, `json_path`, `num`, `json_encode`,
  `json_build`.

Probes on the main binary (0.46.0, built 2026-10-13; not the tag) show the
current state behind several rows:
- `str of 3.0` prints `3`.
- `json_encode of [3.0, 0.1]` gives `[3,0.1]`.
- `9007199254740993 == 9007199254740992` is `true`: the lexer rounds.
- `store_get of [s, "c", 1.9]` finds record `"1"` (a silent truncating key).
- `store_get of [s, "c", 4294967297]` returns `null`, because the `(int)`
  cast is out of range (a pre-existing defect, reported for filing; out of
  scope here).

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
| `audio_capture_open` | other | - | freq/channels truncated to C int (Q1); returns a device id |
| `audio_envelope` | float-producing | - | float samples; times in seconds |
| `audio_gain` | float-producing | - | float samples |
| `audio_mix` | float-producing | - | float samples |
| `audio_music_play` | other | - | loop count truncated to C int (Q1) |
| `audio_music_volume` | other | - | volume truncated to C int (Q1) |
| `audio_noise` | float-producing | - | float samples |
| `audio_open` | other | - | freq/channels truncated to C int (Q1); returns a device id |
| `audio_pause` | other | - | flag truncated to C int |
| `audio_play` | other | - | float samples in; returns a channel number |
| `audio_play_loop` | other | - | loop count truncated to C int (Q1); returns a channel |
| `audio_queue_size` | int-preserving | - | byte count (computed in a double, below 2^53) |
| `audio_saw` | float-producing | - | float samples |
| `audio_sine` | float-producing | - | float samples |
| `audio_square` | float-producing | - | float samples |
| `audio_stop` | int-requiring | - | channel number |
| `audio_stream_open` | other | - | freq/channels truncated to C int (Q1); returns a device id |
| `audio_stream_push` | other | - | float samples quantized to int16 |
| `audio_stream_queued` | int-preserving | - | sample count |
| `audio_sweep` | float-producing | - | float samples; wave selector truncated |
| `audio_volume` | other | - | channel index plus a float volume |
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
| `db_execute` | other | - | parameter encoding (ext_db) |
| `db_query_json` | other | - | row encoding (ext_db, N14) |
| `db_query_value` | other | LOSS | decodes a numeric column with strtod: integer text beyond 2^53 rounds |
| `dispatch` | int-requiring | - | integer table key, already exactness-checked |
| `divide` | float-producing | - | mirrors `/` (Lua §3.4.1: always float) |
| `dot` | float-producing | - | buffer dot product |
| `eigen_eval_loss` | float-producing | - | token ids are indices; the loss is a float |
| `eigen_generate` | other | - | token ids in and out are ints; temperature and top_p floats |
| `eigen_model_load` | other | - | parses model JSON numbers with strtod |
| `exec_capture` | other | - | float timeout in seconds; returns exit status ints |
| `exit` | int-requiring | - | exit code (today truncates) |
| `exp` | float-producing | - | Lua math.exp |
| `f64_from_bytes` | other | - | byte consumer (truncate and wrap) into a float; NaN canonical (N12) |
| `f64_to_bytes` | other | - | float to 8 byte ints; f64_bits (N12) is the int-valued sibling |
| `fill` | int-requiring | - | count |
| `floor` | int-preserving | LOSS | Lua math.floor: an int when the result fits int64, else a float |
| `gather` | int-requiring | - | index or index vector; returns elements unchanged |
| `get_at` | int-requiring | - | index, row and col; returns the element |
| `get_observer_thresholds` | float-producing | - | observer thresholds (O3 drops h_low) |
| `gfx_circle` | other | - | coordinates and colours truncated to C int (Q1) |
| `gfx_clear` | other | - | colours truncated to C int (Q1) |
| `gfx_clip` | other | - | rect truncated to C int (Q1) |
| `gfx_delay` | other | - | milliseconds truncated to Uint32 (Q1) |
| `gfx_fb` | other | - | dims and scale truncated to C int (Q1) |
| `gfx_line` | other | - | coordinates and colours truncated to C int (Q1) |
| `gfx_open` | other | - | width and height truncated to C int (Q1) |
| `gfx_point` | other | - | coordinates and colours truncated to C int (Q1) |
| `gfx_poll` | int-preserving | - | event fields x, y, scancode, button are ints |
| `gfx_read` | other | - | rect origin truncated; returns channel ints |
| `gfx_rect` | other | - | rect and colours truncated to C int (Q1) |
| `gfx_rrect` | other | - | truncated to C int (Q1) |
| `gfx_text` | other | - | position, colours and scale truncated to C int (Q1) |
| `gfx_text_height` | int-preserving | - | pixel height |
| `gfx_text_width` | int-preserving | - | pixel width |
| `gfx_ticks` | int-preserving | - | SDL ticks (Uint32 ms) |
| `hex` | int-requiring | LOSS | refuses above 2^53 by a double compare, so int 2^53+1 reads as 2^53 and passes silently |
| `http_early_bind` | int-requiring | - | port |
| `http_post` | other | - | header values via value_to_string (N6) |
| `http_route` | other | - | formats via value_to_string |
| `http_route_authed` | other | - | formats via value_to_string |
| `http_serve` | int-requiring | - | port |
| `http_static` | other | - | formats via value_to_string |
| `index_of` | int-preserving | - | byte index or -1 |
| `inflate` | other | - | byte consumer (truncate and wrap) |
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
| `native_train_step_builtin` | other | - | token ids are ints; lr float (a numeric string is accepted through strtod) |
| `nearest_in_range` | float-producing | - | geometry floats; the `index` field is an int |
| `nearest_in_range_all` | float-producing | - | geometry floats; the `index` field is an int |
| `negative` | int-preserving | LOSS | mirrors unary `-`; negating INT64_MIN raises (N4b) |
| `net_accept` | int-requiring | - | socket handle |
| `net_close` | int-requiring | - | socket handle |
| `net_dial` | int-requiring | - | port; returns a handle |
| `net_listen` | int-requiring | - | port; returns a handle |
| `net_port` | int-requiring | - | socket handle; returns a port |
| `net_recv` | int-requiring | - | handle and max bytes |
| `net_send` | other | - | byte consumer (truncate and wrap) |
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
| `recv_timeout` | other | - | channel handle ids; float milliseconds |
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
| `store_put` | other | - | N13/N14 encoder; refusal belongs inside the encoder |
| `store_query` | other | LOSS | decodes records; integer text through strtod (N14) |
| `store_update` | other | LOSS | same key cast as store_delete; N13/N14 encoder |
| `str` | other | - | N6 printing via value_to_string |
| `str_from_bytes` | other | - | byte consumer (truncate and wrap) |
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
| `task_sleep` | other | - | float milliseconds |
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
| `usleep` | other | - | microseconds truncated to C int (Q1) |
| `vm_run_bytecode` | int-requiring | - | opcode bytes and ABI numbers |
| `write` | other | - | N6 printing |
| `write_bytes` | other | - | byte consumer (truncate and wrap); returns bytes written |
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
  - compiler.c:2071-2077 (`AST_NUM` emission, `NUM_ZERO`/`NUM_ONE`,
    `add_num_constant`) and compiler.c:2929/2985/3030 (index fast paths read
    `data.num`);
  - chunk.c:193-260 (constant pool dedup: `const_hash_value`, `const_equal`,
    `chunk_add_constant_ex`, which must key on kind and bits);
  - vm.c:3238 `CASE(CONST)` and 3257 `CASE(NUM_ZERO)`/`NUM_ONE`;
  - jit.c:2797/2816 (producer emitters, §4.2);
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
  - JIT bails (§4.1).
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
  - every int-requiring row of §6, through `eigs_int_arg`;
  - vm.c index paths (`jit_helper_index_get`/`set`, `CASE(INDEX_*)`) and
    `range_bound` (builtins.c:3877);
  - the JIT `OP_INDEX_SET` integrality guard (jit.c:4100-4112) stays
    correct, because a non-exact index goes to the helper.
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
    `STRICT_DOMAIN`: the 73 GUARD and clamp sites of (c);
  - builtins_tensor.c `op_sqrt` (711) and `op_log_safe` (729);
  - builtins.c `asin`/`acos` domain;
  - state.c:62 `st->strict` defaults to 1 and must become opt-in;
  - jit.c:2634 `max_normal_bits`.
- **N12 (canonical NaN; payload fidelity through ints):**
  - value_slot.h:73 `slot_from_num`, becoming `slot_from_f64`: the single
    writer;
  - the JIT NaN bails (§4.3);
  - new `f64_bits`/`f64_from_bits` and buffer bits accessors;
  - builtins_buf.c `f64_from_bytes` and `f64_to_bytes`;
  - eigs_embed.c:339 (the host boundary; #1746 round 3, item 4).
- **N13 (refusal inside writers):**
  - builtins.c:907 `eigs_json_encode_value`;
  - ext_store.c's encoder: the #1746 residue is `store_nonfinite_scalar`
    (ext_store.c:278 on the experiment), which must be deleted in favour of
    refusal inside the encoder;
  - the byte encoders (`finite_num_to_byte`, eigenscript.h:1901) and the
    `buf_to_pcm16le` quantizer;
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
    reads it). O3 drops it in round 3.
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

---

## 8. Round plan

Every commit builds, passes the full suite, and carries its own MAP rows.
"Unchanged" means a differential against the baseline binary captured
before the commit (the verify-and-fix rule), not "the suite passed".

### Round 1: the core model (Alt 1R)

1. **R1.1, the slot layer becomes exhaustive (no producer yet).**
   - Add `TAG_SMI`, `slot_is_smi`, `slot_from_int` and `slot_smi_val` in
     value_slot.h.
   - Every slot classifier in §2.5 gets an explicit SMI arm and aborts on an
     unknown tag.
   - `slot_as_ptr` asserts the heap tag in ASan and debug builds.
   - Test: a C unit test (`tests/phase2/slot_layer.c`) builds SMI slots by
     hand and drives every classifier. Before the commit it crashes or
     misreads; after, it answers. Language behaviour is unchanged
     (differential over the suite's `.eigs` corpus).
   - Risk: a classifier the test does not enumerate. Its list is derived
     from the inventory: every function holding both `slot_is_num` and
     `slot_as_ptr`.
2. **R1.2, the Value layer and the renames (deprecate, then delete).**
   - R1.2a: `VAL_INT` (appended), `make_int`, the §2.6 accessors and
     `val_type_name(VAL_INT) = "num"`. **Delete the `default:` arm of
     `eigs_json_encode_value` (builtins.c:998)**, enumerating the types, so
     `-Werror=switch` reaches the last switch that could absorb `VAL_INT`
     silently. The old names stay, marked
     `__attribute__((deprecated))`; macros are routed through a deprecated
     inline.
   - R1.2b-n: one commit per file group (vm.c; builtins.c; tensor; buf;
     host; gfx; net/http/db/model; store; trace; observer; embed; lint and
     LSP). Each migrates its sites by the §6 table and lowers the
     deprecation-warning count. `VAL_INT` exists and is handled, but nothing
     produces it, so behaviour is unchanged (differential).
   - R1.2z: delete the old names. A straggler fails to compile.
   - Risk: the size (1,488 compile-forced sites); and a mis-migration that
     picks `eigs_float_arg` for an int-preserving builtin, caught by the
     int-fuzz gate (§9.4).
3. **R1.3, the flip: int literals and exact int arithmetic.**
   - N1 (lexer, parser, AST kind, constant pool keyed by kind and bits,
     `NUM_ZERO`/`NUM_ONE` mean int, the JIT `CONST`/`NUM_ZERO`/`NUM_ONE`
     emit SMI bits).
   - N3 with (A) overflow raise, N2 exact cross-kind comparison, N4b `-x`,
     N7 `num_type`.
   - The EQ/NE int fast path relies on canonical form, as #1758 says
     equality does. Two SMIs compare by bits; an SMI against a boxed int is
     unequal without loading the box (a boxed int is outside the SMI range).
     This is what makes plant 1 visible from a program (§9.3).
   - The JIT scanner refuses `BAND`/`BOR`/`BXOR`/`SHL`/`SHR`/`BNOT`/`MOD`.
   - **The tape goes to v7 in this commit.** The moment ints exist, a v6
     writer would print `3` for both kinds and replay would turn ints into
     floats. The float token marks its kind now (`3.0`); N6's full repr
     replaces it in R1.7, still inside v7.
   - The observer routes an SMI into the numeric channel (converted to
     double).
   - The visible change is small: ints print as today. The rest waits for
     N4/N6.
   - Risks:
     - JIT int loops bail every iteration (§3: +70% Ir on a counter loop).
       Declare the CodSpeed baseline move first.
     - Consumer hashes that relied on double rounding now raise ((A)); they
       move to the N9 wrapping builtins.
4. **R1.4, N4.** `//` (token, parser, `OP_IDIV` appended,
   `op_name`/`op_stack_effect`/obs marker/ABI test), `%` floor modulo for
   ints and floats, int division by zero raises, `INT64_MIN % -1` is 0.
5. **R1.5, N8.** Bitwise ops on ints with Lua's shift rules; `bit_*`
   returns ints.
6. **R1.6, N5, N9, N10 and the §6 builtins.** Every int-preserving and
   int-requiring row, the 39 LOSS rows first; `num of` (#1638); the N9
   width family.
7. **R1.7, N6 and N14's int half.**
   - Python-repr floats; ints as exact digits.
   - The constant dedup compares bits, so `-0.0` survives.
   - JSON writes ints as digits and floats with `.0`; integer text within
     int64 decodes as an int; `1e400` raises.
   - `src/freestanding/mini_fmt.c` and `mini_strtod.c` follow, gated by
     `make freestanding-libc-diff`.
   - This is the largest visible change: every golden that prints an
     integral float.
8. **R1.8, the embed API, lint/LSP type knowledge and docs** (SPEC,
   COMPARISON, README, llms.txt executed fences). The CLAUDE.md same-PR
   docs rule applies to the integration PR as a whole.

### Round 2: IEEE (N11-N14 remainder), on the experiment's evidence

1. **R2.1, canonical NaN at the single double writer** (`slot_from_f64`)
   **and the JIT NaN bails** (§4.3), while `num_guard` still keeps NaN out:
   memory safety first.
   - Test: the C slot test writes every tag-spelling NaN payload. The
     #1746 plant (a raw store) segfaults in `slot_incref`.
2. **R2.2, retire `num_guard`** (73 sites), `EIGS_NUM_MAX` and the 1e308
   clamp. `EIGS_STRICT` becomes an opt-in trap (state.c:62).
   `sqrt of -1` is NaN, `log of 0` is -inf, `x/0` is ±inf, `0/0` and
   float `x%0` are NaN.
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
  negatives; (A) raises where doubles lost precision silently.
- Observer. Until round 3, ints are observed as their double value (the
  distance channel works on doubles), so `where`/`why`/`how` keep today's
  meaning.

---

## 9. Test plan

### 9.1 `tests/phase2/MAP.md`

The skeleton is committed with this round. Every item (N1-N14, N4b, (A),
(B), T1, O1-O4) has planned rows, each recording:
- an id;
- the program;
- the expected branch output;
- the round that lands it;
- why the row **fails on the v0.46.0 tag**.

Behaviour the branch must *preserve* (`1 == 1.0` is true on both binaries)
cannot fail on the tag, so it is pinned two ways:
- inside a mapped row that also checks the kind (the row fails on the tag
  because the kind is invisible there);
- as a separate **control** row, counted on its own line and never in
  `tag_fail` (§121: each population pinned separately).

### 9.2 `tools/phase2_check.sh <tag-binary> <branch-binary>` (round 1 builds it)

- **Rows** live in `tests/phase2/rows/<id>.eigs`. Each has a header
  `# ROW: <id>`, `# ITEMS: N1 N2`, `# EXPECT-RC: <n>`, `# TIER-WITNESS:
  loop|none`, plus `<id>.out` (the exact branch stdout). Controls live in
  `tests/phase2/controls/`.
- **Population:**
  - the row set is the directory listing (it cannot drift from a list);
  - every row id appears in MAP.md and every MAP id has a file (both
    directions);
  - every item in the fixed list (N1-N14, N4b, A, B, T1, O1-O4, transcribed
    from #1758 Revision 1) has at least one row;
  - zero rows is a FAIL.
- **Tiers:**
  - `off` = `EIGS_JIT_OFF=1`;
  - `default`;
  - `osr` = `EIGS_JIT_OSR_THRESHOLD=1`.
  - Every run is bounded at 30 s, with `</dev/null` and a fresh scratch
    cwd. Use the runner's probe (`timeout`, else `gtimeout`), never a bare
    `timeout`: macOS runners lack coreutils (`.claude/rules/test-suite.md`). These knobs are the ones jit.c reads (jit.c:2501-2509, 4524).
  - Rows marked `TIER-WITNESS: loop` run once more on the branch with
    `EIGS_JIT_STATS=1` in the JIT tiers and must show `[jit] ...
    compiled=N` with N >= 1 (`lar_jit_witness`'s rule): a JIT row that
    compiled nothing measured the interpreter.
- **Verdicts per row and tier:**
  - branch PASS = rc equals EXPECT-RC and stdout byte-equals `.out`;
  - tag FAIL = not that;
  - rc 124 is the named verdict `TIMEOUT` and rc >= 128 is `SIGNAL`. Both
    are a FAIL on the branch; on the tag they count as `tag_fail` and are
    also shown in their own counters.
- **Output, one line per tier:** `tier=<t> examined=N rows tag_fail=N
  branch_pass=N tag_timeout=K tag_signal=K`, then `controls=M both_pass=M`
  and an environment banner (both binaries' `--version` and sha256).
- **Exit 0** iff in every tier examined == tag_fail == branch_pass > 0, the
  controls all pass on both, and the population checks pass.
- **Calibration** (one-time, in the commit that adds it):
  - tag passed as both binaries: `branch_pass=0`, exit 1;
  - one `.out` corrupted: exit 1, naming the row;
  - an empty rows directory: exit 1;
  - a MAP id with no file, and a file with no MAP id: exit 1 each.

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
| 1 | an int that fits inline stored boxed | `slot_from_heap` skips the small-`VAL_INT` normalization | row `N1.canon-eq` (`abs of -5` round-trips through a Value; then `== 5` in the bit fast path) and `tests/phase2/slot_layer.c` (every int writer, every value in ±2^47, must carry tag 0xFFFA) |
| 2 | a NaN stored raw in a slot | `slot_from_f64` without the canonical branch | row `N12.nan-payload-tags` (`f64_from_bits` of every tag-spelling payload into a variable, list, dict and buffer; `type of` each is "num", under ASan in the plant build) |
| 3 | a writer accepting a non-finite value | the refusal inside `eigs_json_encode_value` deleted; separately inside the store encoder | rows `N13.json-refuses-inf` and `N13.store-refuses-nan` (raise `value`, and nothing written: the store row re-reads the record count) |
| 4 | `+` wrapping on overflow | the SMI+boxed add path uses wrapping `uint64` add | row `A.add-overflow-raises` (`9223372036854775807 + 1` raises `value` naming `+`) |
| 5 | `-INT64_MIN` wrapping | `CASE(NEG)`'s int arm without the INT64_MIN check | row `N4b.neg-min-raises` |
| 6 | `num_type of 3.0` returning "int" | `num_type` answers "int" for an integral float | row `N7.num-type-float` |
| 7 | a v6 tape accepted | the version check accepts 6 | row `T1.v6-refused` (the committed v6 fixture must exit nonzero naming version 6) |

Each plant is transverse (§100): deleting its named check's assertion must
let the plant through. That is shown once per plant during calibration by
running the plant against a copy of the check with its assertion removed.

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

## 11. Open questions this design does not decide

These need an owner decision or the standard answer cited. Round 1 must not
pick them silently.

- **Q1. N5's scope beyond index, count and bitwise.** gfx coordinates and
  colours, audio rates, `usleep`/`gfx_delay` durations and C-API ints
  truncate a float today. N5 lists "index, count, bitwise". Raising on
  `gfx_rect of [10.5, ...]` would break every app that computes float
  positions. Options:
  - (a) keep truncation for C-API arguments, documented;
  - (b) apply N5 everywhere.
- **Q2. An int stored into float storage** (`buf_set`, `buf_from_list`,
  `copy_into`, `set_at` on a buffer, `stream_write`). Converting rounds
  above 2^53. Options:
  - (a) convert, as numpy float64 does;
  - (b) refuse an inexact int, as N13 refuses non-finite values.
- **Q3. The embed accessors for an int.** Options for `eigs_value_as_num`
  given an int:
  - (a) convert, as Lua's `lua_tonumber` does, lossy above 2^53;
  - (b) convert only when exact and leave an error pending otherwise.
  - Either way: `eigs_value_new_int`, `eigs_value_as_int` and a kind query
    are added; and `EIGS_TYPE_NUM` covers both kinds, or a new type value is
    appended?
- **Q4. `round`.** It has no Lua counterpart. Proposed: follow floor and
  ceil (an int when it fits), keeping C `round`'s half-away-from-zero.
  Python's `round` uses banker's rounding and returns an int; JavaScript
  rounds half up.
- **Q5. `why is x` for an int binding.** Δv is exact in int64 except at the
  INT64_MIN↔INT64_MAX swing the oracle rows include (it overflows). Options:
  - (a) always a float;
  - (b) an int when it fits, else a float.
  - (A) does not apply: a readout is not an operator.
- **Q6. `//=`** beside `/=` (the lexer's X2 table). N4 adds `//` and is
  silent on the compound form.
