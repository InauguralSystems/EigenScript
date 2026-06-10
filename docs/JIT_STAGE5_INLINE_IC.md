# JIT Stage 5 — inline the hot fast paths (implementation spec)

Status: **implemented and extended** — 5a/5b shipped as specified; 5c
shipped as a semantics-preserving (env, binding_version, slot) write
cache rather than the set-on-exit-only variant (tests read
`__loop_iterations__` mid-loop). The work then continued well past
this spec; see CHANGELOG.md entries "Stage 5" through "Stage 5h" for
the design record of: 5d (inline dict-dot fast paths), 5e (tracked-num
operands in arith/compare + the SET_LOCAL in-place branch), 5f (native
VAL_FN calls inside thunks), 5g (per-loop OSR slots), 5h (DOT_SET
in-place write + 2-way dict cache). Cumulative: bench_dmg_shape
239 → ~118 ms (2.0×).

## As-built deltas (read alongside the spec below)

The spec body is kept as written for the 5a–5c design rationale; the
emitter has since grown. What changed relative to the text below:

- **Register table**: add `%r15` = `&g_vm.frames[frame_count-1]`,
  loaded when the scanner sets `needs_frame_cache` (GET_NAME/SET name
  family use it for `frame->env`). It is pushed TWICE in the prologue
  to keep the body's `%rsp ≡ 8 (mod 16)` call-alignment invariant.
  When both caches are wanted, `%r12` derives from `%r15`.
- **Advance sentinels**: `-1` (RETURN) is joined by `-2` (Stage 5f
  deep bail — a native callee bailed mid-body; `jit_helper_call` left
  every frame ip consistent; vm_run resyncs without any decref).
- **OSR**: `chunk->jit_osr_*` scalars became `chunk->jit_osr[4]` — one
  slot per hot loop header (Stage 5g), selected by the JUMP_BACK
  handler's scan.
- **Dict cache**: 2-way set-associative since Stage 5h (64 sets × 2
  ways); the inline probe checks both ways. `EigsJitLayout` gained the
  dict-cache fields plus `dcache_mask` (a SET mask) and `dcache_ways`.
- **Operand loaders**: arith/compare templates accept heap/tracked
  VAL_NUM operands with `refcount >= 2` (rc==1 bails so the
  interpreter's NUM_REUSE branch keeps value-identity semantics);
  multi-guard ops route all guard failures through one per-op bail
  trampoline so the 256-slot patch budget scales.
- **Line-number references** in the spec body have drifted; use grep
  anchors (`emit_dict_cache_probe`, `jit_supported_prefix`,
  `jit_helper_call`) rather than the quoted offsets.

Prerequisite (done): Stages 4v/4w/4x give whole-loop thunk coverage
with zero bailouts on the benchmark workloads.

## Why

Profile (post-0.11.8, `tests/bench_dmg_shape.eigs`): ~65% vm_run
dispatch, and after Stage 4x the hot loops compile fully into thunks —
yet timings are flat. Reason: every GET_NAME / SET_NAME / INDEX_SET /
LOOP_STALL_CHECK in a thunk is an out-of-line helper call (sync %ecx →
g_vm.sp, push for alignment, movabs+call, pop, reload %ecx). The call
ABI costs roughly what dispatch did. The win is emitting the few-
instruction fast paths inline and calling the helper only on guard
failure.

## Emitter architecture you must know (src/jit.c)

Register conventions inside a thunk (see the prologue, ~line 1575):

| Reg | Meaning |
|-----|---------|
| `%rbx` | `&g_vm` (thread-local; prologue does `mov %fs:0` + `lea g_vm_tpoff(%rbx)`) |
| `%ecx` | cached `g_vm.sp` — must be synced to memory before any helper call and reloaded after |
| `%r14` | chunk pointer (loaded in prologue only when scanner set `has_bail_op`) |
| `%r13d` | bail advance for the epilogue writeback (`chunk->jit_advance`); `-1` = RETURN sentinel |
| `%r12` | `&g_vm.frames[frame_count-1]` — **only when `needs_env_cache`** was set by the scanner; see the prologue block. This is how you reach `frame->env`/`fn_env` without a helper. |

`g_layout` (filled by `eigs_jit_get_layout`, src/vm.c ~1233) provides:
`g_vm_tpoff`, `g_unobserved_depth_tpoff`, `off_sp`, `off_frames`,
`off_current_line`, `off_callframe_ip`, `off_callframe_fn_env`,
`sizeof_callframe`, `off_env_values`, `off_env_count`. Add fields here
(and in `EigsJitLayout`, src/jit.h) if you need more struct offsets —
e.g. `off_callframe_env`, `offsetof(Env, binding_version)`,
`offsetof(EigsChunk, env_ic)`, `sizeof(EnvIC)` and its field offsets.

Forward jumps use the `pending[]` patch array (see OP_JUMP /
OP_ITER_NEXT emitters). The scanner (~line 400) and the emitter's
`last_imm` switch (~line 2426) must be updated **in lockstep** for any
op whose handling changes — `last_imm` decides whether a following
OP_POP can use the `dec %ecx` peephole.

Helper-call ABI (the thing we are amortizing): see the OP_GET_NAME
emitter (~line 1646) — `mov %ecx→off_sp(%rbx)`, `mov %r14,%rdi`,
`mov $idx,%esi`, `push %rcx` (16-byte alignment), `movabs`+`call`,
`pop %rcx`, reload `%ecx`.

## The work, in order of payoff-per-risk

### 5a. Buffer INDEX_SET fast path (easiest, do first)

The hot DMG write is `mem[pc] is v` where mem is VAL_BUFFER, idx and
val are immediate nums. Fast path semantics (see CASE(INDEX_SET),
src/vm.c ~2271): bounds-checked `target->data.buffer.data[i] =
(int)val` — **no refcounts, no observer, no allocation**. Inline:

1. Load the three slots from the stack (`%rbx`-relative via `%ecx`).
2. Guard: idx slot is immediate num (NaN-box tag check — encodings in
   `src/value_slot.h`; you need the tag mask as an immediate), target
   slot is heap/tracked ptr, `target->type == VAL_BUFFER`
   (`offsetof(Value, type)`), val slot is immediate num, idx integral
   and in `[0, count)`.
3. Store the double-converted-to-int, `sub $2, %ecx` (val stays TOS),
   skip the decrefs (idx imm = no-op; target needs a real decref —
   careful: buffer slot from GET_NAME was incref'd. `slot_decref` of a
   heap ptr = refcount decrement + free-on-zero; inline only the
   decrement-when->1 case and fall back to helper when refcount==1).
4. Any guard failure → jump to the existing helper-call sequence
   (keep it; it handles everything).

Decide explicitly what to inline vs. guard-fail: a defensible v1 is
guards + store + `dec refcount if > 1`, helper on everything else.

### 5b. GET_NAME / SET_NAME EnvIC fast path

EnvIC (src/vm.h ~145): `starting_env`, `starting_ver`, `target_ver`,
`slot_idx`, `walk_depth (0|1)`. The interpreter fast path is:

```
ic = &chunk->env_ic[idx]                 ; %r14 + offsetof + idx*sizeof(EnvIC)
start = frame->env                        ; needs frame ptr — set needs_env_cache
ic->starting_env == start                 ; pointer compare
&& ic->starting_ver == start->binding_version
target = walk_depth ? start->parent : start
target->binding_version == ic->target_ver
GET:  s = target->values[ic->slot_idx]; slot_incref(s); push
SET:  env_store_slot(target, ic->slot_idx, s); assign_counts bump
```

- GET inline must do `slot_incref`: tag-check, `incl refcount` when
  ptr. Push = store at `(values_base + %ecx*8)`, `inc %ecx`.
- SET inline must replicate `env_store_slot` (src/eigenscript.c
  ~1059): the arena-promotion branch is the ugly part — guard it out:
  inline only when the incoming slot is immediate or a non-arena ptr,
  helper otherwise. Old-slot decref: same refcount>1-only rule as 5a.
- SET also has the `g_trace_hist` hook *before* the store: load the
  flag (it's a plain global int — add its address to g_layout or
  emit a movabs load) and guard-fail to the helper when set, so trace
  semantics stay helper-side.
- `assign_counts` bump: `target->assign_counts && g_unobserved_depth
  == 0` — g_unobserved_depth is TLS (`g_unobserved_depth_tpoff`
  already in g_layout).
- IC-miss / version-mismatch → helper (which also populates the IC, so
  the next iteration hits the inline path).

### 5c. LOOP_STALL_CHECK cheap path (optional, measure first)

Per iteration it currently calls a helper that does observer math AND
an `env_set_local("__loop_iterations__")` **every iteration** — that
env write is itself a perf bug worth fixing independently (set it on
exit and on loop end only, if no program reads it mid-loop; grep
examples/tests for `__loop_iterations__` before changing semantics).

## Measurement protocol

- `make` (NOT the asan binary), then 3 runs each of
  `tests/bench_dmg_shape.eigs` (~243 ms baseline, 500k steps),
  `tests/bench_idxset.eigs` (~30 ms baseline, 100k writes),
  `tests/bench_perf.eigs`.
- `EIGS_JIT_STOPS=1` must stay at zero bailouts on both benches.
- Sanity-check thunk execution with `EIGS_JIT_STATS=1` (compiled ≥ 1).

## Validation gates (all required)

1. `make test` — full suite green (1287+).
2. `make asan && cd tests && ASAN_OPTIONS=detect_leaks=1
   UBSAN_OPTIONS=halt_on_error=1 bash run_all_tests.sh` — green, zero
   leaks. Inline refcount code is exactly where UAF/leak bugs will
   hide; the suite is the oracle.
3. `make jit-smoke` — add stubs to jit_smoke.c for any new helper.
4. The temporal suite ([70]) exercises `g_trace_hist=1` programs —
   confirms the SET inline guard correctly routes traced assigns to
   the helper.

## Gotchas inherited from Stage 4

- A preceding OBSERVE_ASSIGN may promote the TOS from immediate to
  tracked pointer — never assume TOS immediacy across it (`last_imm`
  is already conservative; keep it so).
- `has_bail_op` must be 1 for any op needing `%r14` (chunk).
- `needs_env_cache` must be set by the scanner for ops whose emitter
  uses `%r12`; check how existing users trigger it.
- Helper fallback blocks share the epilogue's `%r13d` advance
  machinery — the inline guard-fail jump target is the start of the
  full helper sequence for the *same* op, not the epilogue.
- x86-64 only: everything here is inside `#if defined(__x86_64__)`.
