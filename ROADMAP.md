# Roadmap

**The milestone set lives on GitHub and this file MIRRORS it.** One table, one
row per milestone; no checkboxes anywhere. `tools/roadmap_check.sh` fails if a
`- [ ]`/`- [x]`/`- [~]` line appears anywhere in this file, and — when `gh` is
available and authenticated — if the table's open rows stop matching the open
milestones returned by
`gh api repos/InauguralSystems/EigenScript/milestones`. That is the point of
the rewrite (#1207/#1155).

The previous version of this file carried 113 checkbox lines in total.
62 checkbox lines of those were historical highlights under `## Completed`, so
anything counting "roadmap items" was counting the past and double-counting the
present (#414 appeared twice, Windows appeared as an umbrella plus three
tiers). Neither number is typed on trust: `tools/docs_claims_check.sh` DERIVES
both by running these two commands against that commit, and SKIPs them BY NAME
on a checkout too shallow to reach it (round 3 — they used to be waived, and a
waiver whose reason describes a derivation nobody runs is a promise, not a
measurement):

    git show b91768e23c5a874a64e76e4af9ab291e6aa49983:ROADMAP.md \
        | grep -cE '^[[:space:]]*- \[( |x|~)\]'
    git show b91768e23c5a874a64e76e4af9ab291e6aa49983:ROADMAP.md | sed -n '/^## Completed/,$p' \
        | grep -cE '^[[:space:]]*- \[( |x|~)\]'

**The counted population is the table, and nothing else.** Everything else here
is either shipped (`## Completed`) or uncommitted
(`## Ideas and deferrals (uncounted)`), and neither is a plan.

Current version: see the "Latest release" line in CLAUDE.md (gated by
`tools/doc_drift_check.sh`) and CHANGELOG.md — this file does not repeat the
number, so it cannot fall behind it.

## Milestones

| # | Milestone | Status | GitHub | DONE when |
| --- | --- | --- | --- | --- |
| 2 | M1 — Consumer acceptance for a release | active | https://github.com/InauguralSystems/EigenScript/milestone/2 | one complete release+pin wave whose record names the candidate, every consumer's result, and the originating gaps actually closed |
| 3 | M2 — A safe hosted concurrency contract | active | https://github.com/InauguralSystems/EigenScript/milestone/3 | #1153's tier criteria met and the race gate covers them |
| 4 | M3 — EigenMiniSat's next AOT rung inside the memory budget | active | https://github.com/InauguralSystems/EigenScript/milestone/4 | 5x6 completes under the cap with a verified certificate; ouroboros#231's iterator finding validated separately rather than assumed to explain the cliff |
| 5 | M4 — One numeric validity contract | declared-not-started | https://github.com/InauguralSystems/EigenScript/milestone/5 | one contract, all producers agreeing, and the strict-default decision made rather than deferred again |
| 6 | M5 — One demanding OS-thread consumer that also uses packages | active | https://github.com/InauguralSystems/EigenScript/milestone/6 | one small certified solve, with the consumer's GAPS.md recording the upstream findings. Hosted threading only — not an attempt to bypass EigenOS's SMP blocker |
| 7 | M6 — The next justified AOT record specialization | declared-not-started | https://github.com/InauguralSystems/EigenScript/milestone/7 | the pre-declared prediction met or refuted on the record. Neither K~86 nor '15x' is an acceptance promise; flat unboxed records follow only when separately sized |
| 8 | M7 — Make JIT selection pay on the measured fleet | active | https://github.com/InauguralSystems/EigenScript/milestone/8 | the intervention lands and the fleet re-measures net-positive — or it fails and an explicit retention/default decision is recorded instead. Misleading diagnostics fixed or removed in the same change |
| 9 | M8 — Gates and claims that measure what they say | active | https://github.com/InauguralSystems/EigenScript/milestone/9 | each listed issue closed with its gate proven to fire, and no gate in the set examining fewer items than the previous run without saying so |
| 10 | M9 — A gfx consumer that looks like 2026 | active | https://github.com/InauguralSystems/EigenScript/milestone/10 | InauguralSystems/EigenScript#1216 closed builtin by builtin with a Tidepool consumer commit per builtin; InauguralSystems/Tidepool#43 and InauguralSystems/Tidepool#59 closed; the M1 wave's Tidepool row carries a gfx oracle and PASSes on a gfx candidate |
| — | Windows Tier 2 — JIT on the Windows x64 ABI | retired | [#419](https://github.com/InauguralSystems/EigenScript/issues/419) | never; it contradicts the standing veto on grinding the JIT toward native claims — native perf routes through the AOT (see the vetoes below) |
| — | Package registry, version solver and `--pkg audit` lockfiles | retired | [#419](https://github.com/InauguralSystems/EigenScript/issues/419) | never; the SHA-pinned vendoring model is structurally sounder at this scale (see the vetoes below), and hq carries the same veto |

Status words, and what each one commits to: `active` — a milestone with open
issues being worked; `declared-not-started` — the contract is fixed in advance
and no issue has been filed against it yet (the GitHub description says so in
its own STATUS line); `blocked` — waiting on something named; `retired` — a
superseded or vetoed item kept here so it is not re-proposed, never a plan;
`completed` — closed on GitHub but still worth a row this cycle. Only the rows
that are NOT `retired` or `completed` are compared against the open GitHub
milestones, so a retired row can never smuggle itself back in as work.

## Ideas and deferrals (uncounted)

Nothing in this section is a commitment, a plan, or a countable item. An entry
graduates by acquiring a milestone row above, with a DONE clause.

### Undecided — no closure condition, so not a milestone

- **More STEM modules** (graph theory, regression, numerical PDEs). No consumer
  has asked for one, and there is no number that would make it finished, so it
  stays here rather than pretending to be a rung.
- **GitHub Linguist submission.** Its condition (2K+ `.eigs` files across public
  repositories) is not ours to set and not measured here; if it ever becomes
  reachable it gets a row with the derived count in it.

### Deliberately NOT doing (standing vetoes — don't re-propose without new facts)

- Gradual/static type system — months buying a worse TypeScript; #404 +
  #395 are the correctness answer for this language.
- JIT grinding toward native claims (tracing tier, ARM64/Windows JIT
  port, thread-safe JIT) — native perf routes through AOT; concurrency
  gets the task tier.
- Untraced FFI — worse than none (silently breaks replay). Design is on
  record as tape-first ([#415](https://github.com/InauguralSystems/EigenScript/issues/415)),
  implementation blocked until a consumer forces it.
- Vendored crypto extension (AEAD/Ed25519) — security liability with
  zero consumers needing it.
- Package registry + version solver, `--pkg audit` behavioral lockfiles —
  the SHA-pinned vendoring model is structurally sounder at this scale.

The first two of those are the retired rows in the table above; they are listed
in both places on purpose, because a veto that lives only in prose is the one
that gets re-proposed.

### Deferred with the evidence that deferred them

These are open design questions, not scheduled work. Each states what was
measured and what would have to be true to pick it up; most of them are the
subject matter of M4 (the numeric validity contract) and will acquire their
milestone row when an issue is filed against it.

- **Value-level invalidity taint for the observer** — **DEFERRED, by
  evidence, not omission.** #971 item 1 proposed threading
  `math_flags & INVALID` into the `ObserverSlot` so a binding produced by
  an invalid op refuses the rest bands the way saturation does. It was
  built (a consumed per-state `math_invalid_pending` edge, a
  `v_invalid` slot bit OR'd into the five band functions) and
  **reverted**: attribution is positional — "the next binding observed
  after an invalid op" — and holds only when the invalid op is lexically
  the last thing evaluated before the observed assignment. Executed:
  `a is sqrt of (0 - 1.0)` reads `diverging`, but `local t is sqrt of
  (0 - 1.0)` / `a is t` and a `safe_sqrt` wrapper both certify
  **`converged`** on the fabricated 0 (false negatives), and the mirror
  false positive — a discarded invalid op tainting an honestly converged
  neighbour — is equally reachable. Saturation needs no state because it
  is derivable from `last_value` alone; a clamped NaN lands mid-band and
  is not. So the bit must **travel with the value**: a taint on `Value`
  propagated through copies, returns and the NaN-boxed `EigsSlot`
  immediates, **and carried on the tape** — `tape_read.c`/`step.c`/
  `eigsdap.c` rebuild slots from recorded values, so the live runtime
  reported `diverging` where `--step` reported `[converged]` on the same
  program (a missing key in an old dump must not read as "valid"). That
  is a design pass of its own, not a sub-bullet. What shipped instead:
  under `EIGS_STRICT=1` every reachable NaN source raises (item 3 of the
  strict ladder), so a grader that needs invalidity loud has it without
  the taint.
  ([#971](https://github.com/InauguralSystems/EigenScript/issues/971))

- **A `matmul` BUFFER result is stored raw — `inf` reads back above
  `1e308`, and a `NaN` reads back as `null`.** The boxed roads go
  through `make_num`, whose `num_guard` saturates an
  infinity and collapses a `NaN` to `0` + `math_flags.invalid`. The
  buffer fast path writes the kernel's accumulator straight into the
  result buffer instead, so both survive: `r[0] > 1e308` is `1`, and a
  `NaN` element is not a number the program can even see — its bit
  pattern IS the boxed-slot tag for null (0xFFF8… == `SLOT_NULL_BITS`),
  so `r[0]` reads `null` out of a buffer of numbers, and
  `math_flags.invalid` stays `0`.
  **#971 built the NaN half of the fix and then reverted it, on
  purpose.** Collapsing NaN there is two lines and passed every test,
  but it changes the DEFAULT path (`null` -> `0`, `invalid` 0 -> 1), and
  the one claim the strict reform makes is that with the flag off
  nothing changed — proven by `tools/strict_differential.sh` against the
  previous release binary. Shipping it meant carrying a waived
  divergence in that tool, i.e. the proof with a hole in it, for an
  incidental fix that was never what #971 was about. So strict raises on
  both paths (`STRICT_DOMAIN`, which cannot touch the soft path) and the
  default answer is byte-identical to v0.43.0; `tests/test_strict_math.sh`
  SM49a/SM49b pin both halves so neither moves by accident.
  **The writer is not the place to fix it.** `matmul` is not the only
  road to a `NaN` buffer element: `ext_store` round-trips one on
  purpose (`store_nonfinite_sentinel` encodes `"nan"`/`"inf"`/`"-inf"`
  because JSON has no literal for them), and the embed API's
  `eigs_value_buffer_set` takes a raw `double` from the host. Whatever
  is decided has to be decided at the READ, where every road meets.
  Doing it properly is its own change: decide the buffer contract for
  BOTH non-finites together (saturate the `inf` too, or keep both raw and
  make the buffer read report a NaN as a number rather than as `null`),
  mirror it in the AOT — ouroboros `aot_rt.h`'s `aot_tensor_matmul`
  reads the same raw buffer and its round-187 fixture PINS the `inf`
  read — and run the differential over both.
  ([#971](https://github.com/InauguralSystems/EigenScript/issues/971))

- **Flip `EIGS_STRICT` to the default?** — **DEFERRED; the evidence
  says it is now cheap, the decision is still open.** Measured
  2026-09-06 on the v0.43.0 tree with the #971 Phase C/D + NaN work
  applied: **94 consumer entry points** (DMG `test_cpu`/`test_memory` +
  the 500K-cycle canary, EigenMiniSat DPLL/CDCL solves, EigenRegex S1–S12
  + smoke, EigenGauntlet's 11 labs at size 1, Tidepool, dynamics,
  liferaft, tidelog, phugoid, polymethod, DeslanStudio's 24 headless
  tests, iLambdaAi, eddy) run twice on the same binary, flag off and
  `EIGS_STRICT=1`: **0 of 94 change exit status under strict**; the six
  that fail do so identically in both modes for load-path reasons
  unrelated to the flag. (Re-spot-checked 2026-09-07 on the final
  binary — DMG `test_cpu`, EigenMiniSat `test_solver`, EigenGauntlet
  `tensor`/`io`, Tidepool `test_game`, dynamics `solve`, liferaft
  `test_prng`, EigenRegex `test_smoke`: 8 of 8 unchanged.) The runtime's own suite is a different story —
  it PINS the soft answers (`sqrt of -1` is `0`, `cos of "hello"` is
  `0`, the `fs:ANSWER` pins) in dozens of sections, so flipping the
  default means rewriting those pins as `EIGS_STRICT=0` rows and
  re-deciding which stand-ins survive as documented answers (the
  classification ledger in `tools/failsoft_classify_check.sh` is the
  input). Two things must land first: the AOT mirror (ouroboros
  `aot_rt.h` carries its own inlined `num_guard`, `op_div`-shaped
  `aot_ddiv` and a raw-`inf` matmul read pinned by its round-187
  fixture — a default flip without the mirror flipping recreates the
  #975 div0 fossil), and a decision on the **raw non-finite in a
  `matmul` buffer result** (the entry below). Until then:
  strict stays opt-in, graders and CI lanes turn it on, and the
  differential (`tools/strict_differential.sh <parent-build>`) keeps
  the default path byte-identical.
  ([#971](https://github.com/InauguralSystems/EigenScript/issues/971))

- **Per-layer headers — break up the `src/eigenscript.h` umbrella.** (The
  "1253-line" figure this entry used to carry was stale by ~900 lines, and
  is not restated: a line count of a file under active edit is a number that
  rots by construction. `wc -l src/eigenscript.h` is the measurement.)
  Item 3 of [#744](https://github.com/InauguralSystems/EigenScript/issues/744),
  the one part of that issue deliberately NOT done in the same round; items
  1, 2, 4 and 5 landed (dead extension includes, stale externs, `fsutil.c`,
  the `task.c` / `builtins_buf.c` splits). The measured facts, from the
  2026-07 modularity review: there is no `lexer.h`, `parser.h`,
  `compiler.h`, `chunk.h` or `builtins.h` — only `vm.h`, `jit.h`,
  `trace.h`, `state.h` (plus, since #744, `fsutil.h`, `task.h` and
  `ext_register.h`). `eigenscript.h` spans the tokenizer, the AST, values,
  the arena, `EigsThread`, env, the parser, registration, the MODEL tensor
  kernels, the handle table, the store, step, and fmt+lint: **26 structs
  with every field visible, 167 declarations, included by 29 of ~30 TUs**.
  Two consequences are measured, not asserted: a lexer change forces a full
  rebuild of everything, and the layer order is violable and violated —
  `compiler.c` increments the PARSER's `g_parse_depth` `EigsThread` field
  as its own recursion guard, and lexer, parser and compiler all write
  `g_parse_errors`, the front end mutating runtime thread state.
  What makes this its own round rather than a follow-up commit: 29 TUs,
  `tools/amalgamate.sh` (which concatenates them in SOURCES order and would
  have to keep an acyclic include order across the split), and the
  freestanding profile's two-stage symbol gate. Note the header GRAPH is
  already clean and acyclic (`eigenscript.h -> value_slot.h`, `vm.h ->
  value_slot.h`, everything else -> `eigenscript.h`), so this is a hub
  problem, not a tangle — the split is mechanical once someone commits to
  doing all 29 at once. `#744` showed the cheap version works: `fsutil.h`
  moved 8 declarations out of the umbrella and 7 TUs now say they read
  files, and nothing else changed.

- **Container-keyed observer trajectory** — dict fields and list
  elements carrying their own observer slot, keyed by (container
  identity, key) ([#1048](https://github.com/InauguralSystems/EigenScript/issues/1048)).
  *Mechanism today:* trajectory lives on an environment slot
  (`env_obs_slot(Env *e, int idx)` → `e->obs[idx]`; the Value carries no
  observer state), so per-entity observation needs one persistent
  binding per entity — a named local or a closure per entity (the
  recommended form; docs/PREDICATES.md "What carries a trajectory").
  *The ask:* let `fleet[i][2] is v` / `ch.a is v` update a slot owned by
  the container entry, so `diverging of fleet[i][2]` answers about that
  entity — the form a consumer reaches for first (phugoid rung 4), whose
  current failure is silent: one binding rebound per entity carries the
  round-robin interleave and manufactures verdicts (lint `W024` now
  names it; the module-level `for`-body `local` answers `equilibrium`
  instead, the same rule from the other side). *Layers it touches:* the
  compiler (new predicate/`report`/`trajectory` operand forms over
  index/field expressions, today `E005` for the report words), the VM
  (`OP_INDEX_SET`/`OP_DOT_SET` observer update + reader opcodes and the
  observer gate's reader scan, #915), the JIT inline caches on dict
  fields and indexed stores, `trajectory of` snapshots, the tape /
  `--step` / DAP / SIGUSR1 dump (a slot per entry to record and
  replay), and the AOT mirror in ouroboros. *Open design questions:*
  list insert/remove shifts identities (is the slot keyed by position
  or by the element's identity, and what does `sort` do to a history?);
  lazy slot allocation keyed by statically-named fields only (`ch.a`)
  versus every dynamic key (memory: a slot per entry of every observed
  container, or an opt-in `observed` container); whether the container
  or the entry owns the slot when the entry is itself a container; and
  the tape format for per-entry observer records. Deliberately not
  built in the same round as `W024` — needs its own design pass.

### Performance carryover

- **NaN-boxing for container storage** — stack and env slots are
  already EigsSlot/NaN-boxed; list items and dict values are still
  `Value**`. Post-5h, the DMG-shaped `make_num` churn is gone
  (writes mutate in place); this now mainly buys allocation-free
  list/dict construction and reads for non-num or shared values.
  Big surface (every `data.list.items` / `data.dict.vals` touch
  site).
- **Extend GET_LOCAL/SET_LOCAL to the locals still excluded from a slot.**
  The old wording here ("currently restricted" to function params) was
  stale: `src/compiler.c`'s escape analysis (a76edce, "Add escape analysis
  for slot promotion") already emits `OP_SET_LOCAL` for a NON-parameter
  local whenever it is `local_eligible` — not captured, not interrogated,
  not already env-bound, not an outer/module/global name. What is left is
  precisely that exclusion list, and each exclusion is there for a reason,
  so this is a design question about closures and interrogation, not a
  matter of "broadening" a restriction.
- **Per-call env churn** — `env_new` / `env_free` per call is the
  likely top DMG cost post-5i for non-recyclable callsites.
  Re-profile before picking; the profile shape moved every stage
  this cycle.

### Downstream gaps feeding back

Filed by stress-test repos; promote into a numbered EigenScript item
when picked up:

- **Tidepool** (`InauguralSystems/Tidepool/GAPS.md`): GAP-003 per-channel
  volume (needs a multi-channel mixer) and GAP-004 inner-loop function-call
  cost (partially mitigated by the v0.12.0 hoist sweep) are what remains.
  Shipped: GAP-001 `audio_sweep`; GAP-002 finite-count `audio_play_loop`
  (0.13.0); GAP-005 non-blocking channel recv and GAP-006 spawn-with-args
  (0.13.0). **GAP-002's infinite-loop variant is CLOSED too** — EigenScript
  PR #375, which is how Tidepool's own GAPS.md cites it (this file
  previously credited it to the Tidepool repository, whose PR #375 does not
  exist) — so the "still open" sentence that stood here was false.
  Tidepool's live gfx asks are M9's subject, not this list.
- **EigenMiniSat** (`InauguralSystems/EigenMiniSat/GAPS.md`):
  open watchlist around CDCL hot-path inlining patterns.

### Ecosystem — capabilities with no committed date

- **Windows support** — not a non-goal, just not yet. The wall is
  in the extensions, not the language core; planned as a ladder
  (CI is the verification instrument — development is Linux-only):
  - Tier 0: WSL2 runs the Linux binary unchanged (works today;
    the immediate answer for a Windows user).
  - Tier 1 (the real target): native **headless interpreter**,
    JIT-off, built with MinGW-w64, suite green on a `windows-latest`
    CI leg. Shims needed: exe-path discovery (`readlink` →
    `GetModuleFileNameA`, `main.c`) and `exec_capture` (`execvp` →
    `CreateProcess`, `builtins.c`); pthread works under winpthreads.
    This is the 80/20 for adoption — `eigenscript foo.eigs` on
    Windows without WSL.
  - Tier 2: JIT on Windows — **RETIRED**, not pending. It contradicts the
    standing veto above on grinding the JIT toward native claims, and it
    has the retired row in the milestone table. Listing it as an
    unchecked tier is what made it read as planned work.
  - Tier 3: extensions on Windows — HTTP server (Winsock +
    `WSAStartup`) and gfx/SDL (`dlopen` → `LoadLibrary`). Per-file,
    on demand.
- Foreign function interface for calling arbitrary C libraries
  from script (the *script → host* direction) — design settled as
  **tape-first** in [#415](https://github.com/InauguralSystems/EigenScript/issues/415)
  (every foreign call is a recorded nondet input, sqlite3 as the
  first binding, which also covers the SQLite DB-driver item);
  implementation blocked until a consumer forces it. The
  *host → script* direction is live via the embedding API; see
  [docs/EMBEDDING.md](docs/EMBEDDING.md).
- Crypto / HTTPS in-process (SHA hashes shipped 0.9.2; no AEAD, no
  TLS) — **deliberately deferred** per the 2026-07 survey critic:
  vendored crypto is a solo-maintainer security liability with zero
  consumers needing AEAD; revisit when one does.
- Additional DB drivers (MySQL, NoSQL; SQLite folds into the #415
  FFI plan)
- bigint / decimal numeric types — superseded by the numeric-tower
  design decision ([#417](https://github.com/InauguralSystems/EigenScript/issues/417)):
  document the f64 + `bit_*` int64 contract now, bigint only when a
  consumer forces it

## Completed

Condensed highlights; see [CHANGELOG.md](CHANGELOG.md) for the full
per-version record. These are HISTORY, deliberately written as a plain list:
most of them used to be `- [x]` checkboxes, which is how a counter came to
report the past as roadmap items "done" (the header above derives both counts
with the commands that produce them; no number is retyped here).

### Shipped since this file last claimed them (corrected 2026-09-21, #1207)

- **Public release.** The repository is public and v0.43.0 shipped 2026-09-06;
  the old `- [ ] Public release` item was false.
- **WASM compilation target.** `web/build.sh` builds it and
  `.github/workflows/pages.yml` publishes the playground; the old
  `- [ ] WASM compilation target` item was false.
- **`utf8_encode`.** Shipped in PR #450 — the #416 decision's parenthetical
  ("`chr` can't emit bytes ≥ 0x80, so `utf8_encode` waits on that") was stale.
- **Package manager, basic `--pkg`.** Namespaced deps, lockfile, commit/tree
  verify, install/update/verify — shipped. What was listed with it (registry,
  version solver, audit lockfiles) is vetoed, not pending: it is the retired
  row in the table above. The old `- [~]` was the only tri-state box in the
  file and meant neither.
- **Raw TCP sockets** (#414) — shipped as the `net_*` extension
  (`eigenscript --api` is the index); it was listed twice in the old active
  region, once under "Next" and once under "Ecosystem". Only the TCP half
  shipped: #414's title says TCP/UDP, and UDP is not exposed — see
  [docs/BUILTINS.md](docs/BUILTINS.md), "Optional: Network Extension", which
  is the pointer of record.

### Decisions taken (kept here so they are not re-opened as "items")

- **Unicode/text position — DECIDED: bytes-forever** ([#416](https://github.com/InauguralSystems/EigenScript/issues/416)).
  `docs/SPEC.md`'s "Text" subsection makes `str`-is-bytes official (byte
  indexing, multibyte-safe concat and f-strings) with byte-checked examples;
  `lib/utf8.eigs` supplies decode/len/at/validate/encode for character
  semantics.
- **Numeric tower position — DECIDED: one f64 number kind** ([#417](https://github.com/InauguralSystems/EigenScript/issues/417)).
  No bigint or decimal until a consumer forces one; SPEC.md states the
  contracts (exactness below 2^53, finite-by-construction NaN→0 and
  saturation, the int64 `bit_*` seam) with byte-checked examples.

### Recently shipped (0.34.0 → 0.40.0, 2026-07-31 → 08-17)

- **0.34.0** — the attack-surface release: `sandbox_run` containment (#713),
  `chunk_verify` bounds against an untrusted chunk running off its code,
  `json_encode` depth bound (cyclic value no longer segfaults), HTTP
  header-injection + Content-Length framing + slow-loris DoS (#718), and
  `--pkg install` no longer executing lockfile commands (#714) — plus the
  loop-cap fix and four more multi-state process-globals (#739).
- **0.35.0** — machine-legibility + charts: `--api [--json]` surface index,
  `chart` as a real x-y plot (#819/#820), lint `W022` over-arity literal
  calls (#733); 0.35.1/0.35.2 bounded the temporal history and restored
  temporal reads for non-bytecode producers.
- **0.36.0–0.38.0** — the fleet-UI ladder DeslanStudio/EigenOS forced:
  wheel-pointer events (#822), `code_view` styled spans (#838), the
  `timeline` (#842), `dock` multi-panel layout (#848), and `hex_view` byte
  grid (#850) — plus the uniform `-Werror=switch` invariant gated (#817/#836)
  and `make` keeping `eigsdap`/`eigenlsp` fresh across a VERSION bump (#825).
- **0.39.0** — fleet-UI + correctness hardening: `math_flags`/`clear_math_flags`
  (numeric clamps observable), `gfx_read` render-decode oracle, `ui_clip_push`/
  `ui_clip_pop`, `<kw> is x when <n>` per-assignment past addressing, the
  arena-escape memory-corruption fix, JSON lossless number round-trip (#875),
  typed DB results + raising failures (#887), and freestanding switch
  exhaustiveness.
- **0.40.0** — the sandbox-budget + verifier release (forced by iLambdaAi's
  grade ladder): `sandbox_run` now charges every amplifying allocator class at
  its growth chokepoint and reports a cap-truncated run as NOT ok, `eigen_generate`
  temperature sampling is script-seedable, and a cluster of bytecode-verifier
  hardening fixes (stack-effect drift gate, `OP_LOOP_ENV_END` pairing, a bare
  back edge crossing the loop cap, and an assembled chunk that could pass the
  verifier and then corrupt the heap).

### 0.19.0 (2026-06-26) — flat-buffer tensors

- Shaped `VAL_BUFFER` (`buffer of [r, c]` / `reshape`); `matmul`/
  `add`/`relu` compute on the flat `double[]`, byte-identical to
  the nested-list path (3-layer MLP forward ~11×). `dot`/`norm`
  reductions with spec-unspecified summation association.

### 0.18.0 (2026-06-25)

- Streaming audio-file playback (`audio_music_*`) in the gfx
  extension via lazily-`dlopen`ed SDL_mixer.

### 0.17.0 → 0.17.2 (2026-06-25)

- Stdlib gap-fill (`any`/`all`/`find_index`/`partition`/`group_by`,
  string/math helpers, pure EigenScript).
- `spawn` raises on OS thread-create failure instead of returning a
  dead handle (#269); OSR thunk confined to its own loop back-edge
  (#267); Linux release binary pinned to glibc 2.35 (Ubuntu 22.04).

### 0.16.0 → 0.16.3 (2026-06-18 → 06-19)

- Windowed observer predicates (the #202 series): all six
  predicates read a window of the last N observations.
- Leak campaign + HTTP DoS hardening + OSR perf (0.16.1);
  `load_file` now raises parse errors + stdlib keyword sweep
  (0.16.2); observer loop-halting made opt-in (0.16.3, #247).

### 0.14.0 (2026-06-13) — trust/identity

- OpenSSF passing badge, CodeQL, Scorecard 7.5/10, Sigstore-signed
  releases, OSS-Fuzz enrollment in flight.

### 0.13.0 (2026-06-12) — language features

- Destructuring assignment, slicing + negative indexing, default
  parameters, streaming subprocess I/O (`proc_*`), non-blocking
  channel recv, multi-arg `spawn`, finite-count `audio_play_loop`.

### 0.15.0 (2026-06-15) — multi-state refactor + embedding API

- **Multi-state refactor (Phases 1–9).** Every `__thread` global in
  the runtime now lives on `EigsState` (per-interpreter: global env,
  JIT cache, module cache, observer thresholds, handle table,
  multithread flag, JIT tuning thresholds) or `EigsThread`
  (per-OS-thread: arena, error state, VM, freelists, intern table,
  recursion-depth guards, cycle-collector registry). Hot fields keep
  single-indirection cost via `eigs_current->field` bridge macros, so
  the common single-state path is unchanged. Two `EigsState`
  instances can run concurrently in the same process with no shared
  state.
- **Embedding API (Phase 10).** Public C surface in
  `src/eigs_embed.h`: opaque `EigsState` / `EigsThread` / `EigsValue`
  handles, lifecycle (`eigs_open` / `eigs_close` or finer-grained
  `eigs_state_new` / `eigs_thread_attach` / `eigs_state_init_runtime`),
  REPL-style source eval (`eigs_eval_string` / `eigs_eval_file`),
  error retrieval, global env read/write, ref-counted value
  constructors/accessors, and `eigs_register_function` for exposing
  host C functions to script. Contract test in `src/embed_smoke.c`
  (`make embed-smoke`). Reference: [docs/EMBEDDING.md](docs/EMBEDDING.md).

### 0.12.0 (2026-06-10)

- **JIT Stage 5 — inline the hot fast paths.** Buffer-INDEX_SET
  and GET_NAME/SET name EnvIC fast paths emit as native templates
  with helper fallback on guard failure, plus a
  (env, binding_version, slot) write cache for the per-iteration
  `__loop_iterations__` update. bench_dmg_shape 239→218 ms,
  bench_idxset 29.7→24.6 ms; isolation probes 2.8–3.4×. Spec in
  `docs/JIT_STAGE5_INLINE_IC.md`.
- **JIT Stage 5d — inline dict-dot fast paths.** LOCAL_DOT_GET/SET
  cache-hit paths emit inline (baked hash, interned-key pointer
  equality, in-place num mutate); helper fallback repopulates the
  dict cache. Isolated dict-RMW loop −31% (65→45 ms).
- **JIT Stage 5e — tracked-num operands in arith/compare
  templates.** ADD/SUB/MUL/DIV/MOD and all six comparisons accept
  heap/tracked VAL_NUM operands (refcount ≥ 2; rc==1 routes to
  interpreter so NUM_REUSE keeps in-place semantics). JIT
  SET_LOCAL template gained the interpreter's exact in-place
  branch (the swap path would free a Value `g_last_observer` can
  still point at). Poisoned-counter loop −26% (141→105 ms);
  bench_idxset −10% (24.6→22.2 ms).
- **JIT Stage 5f/5g — native VAL_FN calls + per-loop OSR slots.**
  Chunks carry one OSR slot per hot loop header (`jit_osr[4]`) so
  a setup loop can't pin the slot away from the main loop;
  `jit_helper_call` pushes the callee frame and invokes a compiled
  callee's thunk directly, with `-2` deep-bail sentinel. Plus
  OP_DOT_SET coverage. bench_dmg_shape 212→156 ms (−27%); JIT now
  ~33% faster than EIGS_JIT_OFF on it (previously near parity).
- **Stage 5h — DOT_SET immediate fast path + 2-way dict cache.**
  DOT_SET mutates exclusive untracked num fields in place; the
  dict field cache is 2-way set-associative (the DMG "pc"/"cycles"
  pair collided in the direct map). dmg 156→118 ms; interpreter
  (EIGS_JIT_OFF) 230→213 ms.
- **Stage 5i — per-chunk call-env recycling.** A returned call env
  parks on its chunk (values nulled; param names/hash/version
  kept) and the next call rebinds params in place — EnvICs stay
  valid across calls. Guarded: single-threaded, non-captured,
  fully-bound params, layout-exact count. env_new on
  bench_dmg_shape: 500k → 9 per run; trivial-call probe −26%
  (147→109 ms), recursive fib −17%.
- **Temporal-trace compile gate.** `g_trace_hist` /
  `g_trace_obs_hist` set only when the program uses a temporal
  query or `EIGS_TRACE` is set — no per-assign cost otherwise.

### 0.11.5 → 0.11.8

- Cross-platform CI + sanitizer matrix
- HTTP server hardening (threaded accept, protocol hygiene)
- Execution trace tape + deterministic replay
  (`EIGS_TRACE` / `EIGS_REPLAY`)
- Temporal interrogatives (`prev of`, `at`, `state_at` +
  line-floor index)
- Debugger step-back
- Leak-clean suite under ASan (enforced in CI)
- Refcounted bytecode chunks

### 0.11.4 (2026-05-23)

- Dict-key interning + pointer-equality short-circuit in dict inline cache
- PGO build target (`make pgo`)
- Builtin ref-protocol fix — direct-borrow scan replaces unconditional
  compensating incref at CALL/JIT-helper/OP_DISPATCH sites; stops the
  fresh-builtin-return leak (range, make_str, keys, …)

### 0.11.0 → 0.11.2

- Eliminate dispatch builtin re-entry (OP_DISPATCH inlines without re-entry)
- In-place numeric mutation for refcount-1 values (NUM_REUSE)
- Dict field inline caching (128-entry direct-mapped, 99.99% hit rate)
- Stack-top arithmetic (ARITH_FAST) + inlined JUMP_IF/POP
- Superinstructions: LOCAL_DOT_GET/SET, LOCAL_IDX_GET, LOCAL_IDX_DOT_GET/SET
- Bytecode bring-up complete — eval.c deleted, VM is sole engine
- Hit DMG 0.5+ MHz target (1.094 MHz at 0.11.4)

### 0.10.0 (2026-05-21)

- Bytecode VM — replaced AST tree-walker with compiled bytecode + computed-goto dispatch
- Non-recursive function calls — no C stack recursion, 4096 frame depth
- Stack-local optimization — GET_LOCAL/SET_LOCAL for function params
- Observer stall detection in VM loops (OP_LOOP_STALL_CHECK)
- list_truncate, list_remove_at, sort_by builtins

### 0.9.3

- Computational geometry library — 60+ functions, convex hull, transforms
- Lab data collection framework
- 49 stdlib modules, 14 STEM
- 15 STEM simulation examples

### 0.9.2

- 12 STEM modules
- SDL2 audio extension
- Code formatter and linter
- Tidepool game near-parity

### 0.9.1

- Language server protocol (LSP) — eigenlsp, VS Code extension
- Hashing builtins — SHA-256, MD5, HMAC-SHA256

### 0.9.0

- UI toolkit — 44 widgets, 3 themes, flex layout, animation
- Real concurrency — spawn/thread_join/channels
- EigenStore embedded database
- Graphical debugger with observer-aware inspection
- 817 tests

### 0.8.0

- Reference counting GC, unobserved blocks, SDL2 graphics
- Bitwise operations, terminal I/O, arena allocator
- Fuzz testing, security hardening

### 0.7.0

- Pattern matching, pipe operator, lambdas, break/continue
- Regex, import system, EBNF grammar

### 0.6.0

- REPL, dictionaries, closures, f-strings, try/catch, eval

### 0.5.0

- Observer semantics, 121 builtins, 25 stdlib modules
- HTTP, PostgreSQL, transformer extensions
