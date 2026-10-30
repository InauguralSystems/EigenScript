# R1.6 bar: orchestrator rulings (FINAL, 2026-10-20)

Inputs:
- the bar author's QUESTIONS (BAR.md);
- the blind bar critic's report (`/home/jon/src/wt/briefs/out/r1-6-bar-critic/REPORT.md`, verdict DEFECTIVE). The critic derived all 36 LOSS rows and 88 more independently, found no wrong scalar expectation, and found eight witness defects (F1–F8).

Every ruling below is applied to the bar BEFORE R1.6a commits it, and each changed row is logged in BAR.md's Corrections log with the ruling's id.

## A. Table structure
- **A1. `changes` becomes two columns.**
  - `changes_vs_pre` is the R1.6 migration delta: `.branch` differs from `.pre`, the R1.5 tip. The vacuity guard uses it.
  - `changes_vs_tag` is §9.4's original comparison, recorded as an observation.
  - Why: measured on the table, `.branch` differs from `.tag` on 115 of 120 rows, because every probe calls `num_type` and the tag has no `num_type`. A guard against the tag is vacuous by construction (mechanical-gates §196).
  - R1.6a amends §9.4 to say this, with the measurement.
- **A2. A `closed_in` column, one reason per row, never one blanket waiver.** It holds the round (or `main #<n>`) that already closed a row's loss or check:
  - `abs`, `json_build`, `json_encode`, `sort`, `sort_by`: R1.2/R1.3;
  - the six `bit_*`: R1.5;
  - `chr`, `dispatch`: main (already exactness-checked);
  - the duration caps of `audio_sine`/`saw`/`square`/`noise`: main #1767.

  The vacuity guard (`changes_vs_pre: yes` for every LOSS, int-requiring and Q7 row) applies to rows WITHOUT `closed_in`. A row WITH it must have `.pre == .branch`, so the closure is CHECKED, not declared. Its probe keeps pinning exactness above 2^53.
- **A3. A `profile` column: `release`, `server`, `zlib` or `db`** (F2, Q-CAP).
  - `.pre`, `.tag` and `.branch` for a non-release row are recorded and checked on a MATCHED capability build: the same profile at 4ac31e67, at the v0.46.0 tag, and on the branch.
  - A capability-unavailable transcript is never a "change".
  - The db rows need PostgreSQL. CI's db lane has a postgres:16 service. Record and check them there, or wherever a PostgreSQL exists, and report the mechanism.
- **A4. A `hook` column: the test-only interposition shim** (F1, F4, F5; Q-AUDIO-HIDDEN, Q-CLOCK, Q-GFXPOLL).
  - `tests/phase2/observation_hooks.c` is built as an LD_PRELOAD `.so`, starting from the critic's `observation_hooks.c`. It intercepts `SDL_QueueAudio` (capturing the delivered PCM), the mixer gain and volume setters, `clock_gettime` (injecting a deterministic clock) and `SDL_PollEvent` (injecting deterministic events).
  - A row with a hook runs with the shim preloaded, and its expectation asserts the boundary payload.
  - This SUPERSEDES the draft's "witness: none" waivers: the critic executed every one of these witnesses on the existing binary.
- **A5. A `stdin` fixture column** (the critic's item 13). `proc_read_buf` gets a second case with stdin `Hi`, keeping the `/dev/null` EOF case. **S10-D2 later retires both cases explicitly; see below.**

## B. Witness rulings (the critic's findings)
- **B1 (F1). `audio_stream_push` asserts the delivered int16 PCM.** `[2.5, -3, 0.5]` gives `[32767, -32767, 16384]`: Q4 rounding of 0.5×32767. Today the result is 16383 (truncation), and an all-silence mutation also passes the current row.
  - `audio_play`, `audio_play_loop`, `audio_music_volume` and `audio_volume` assert their gain or volume at the SDL/mixer boundary through the hook, with an out-of-range value that clamps.
- **B2 (F4). `monotonic_ns` with the injected clock 9007199254740993 ns** gives `[9007199254740993, "int", true]`; pre gives `[9007199254740992, "float", false]`.
- **B3 (F5). `gfx_poll` with the injected events** gives `[17, "int", -9, "int"]`, `[4, "int"]` and `[1, "int", 23, "int", 42, "int"]`. The empty-queue `null` case stays as a second probe.
- **B4 (F6). Big store KEYS:**
  - `store_update` and `store_delete` act on a record whose `_id` is `"9007199254740993"`, through that numeric key, giving `["update-big-key", true, 2]` and `["delete-big-key", true, 0]`;
  - `store_get` adds a 2^53+1 key case.
- **B5 (F7, scope decision). The generators' sample-count conversion (`dur * rate`) stays R2.6**, as design §8 R2.6 lists it in the #1746 residue. So at R1.6, 0.00101 s still gives 44 samples. R1.6 reads `dur` through the magnitude reader for validity only (finite; within what the call can honour).
  - The rounding witness (0.00101 s gives 45) goes into R2.6's row list. The design's staging stands, since no silent wrong answer forces it earlier.
  - `audio_sweep` changes through its wave selector, as the bar has it.
- **B6 (F8). `http_post` passes headers JSON `{"X-Number": 9007199254740993}` and a STRING body.** On the server profile, a loopback capture fixture asserts that the received header is exactly `9007199254740993`. Today's probe put the number in the body slot, which `ext_http.c:717` ignores.

## C. Semantic rulings (the bar's questions)
Where the author and the critic agreed, I adopted the answer:
- Q-R17: the decoders change at R1.6, and the writers' float loss is R1.7.
- Q-DB253: exact int64 replaces the 2^53 refusal, and `db_check_exact_int`'s raise is deleted with its reason.
- Q-HEX: exact digits; negatives raise.
- Q-SIGNEXT: an exact int result from the existing operation (`[9007199254741121, 8]` gives `9007199254740865`).
- Q-STREAMOPEN: a fraction raises `value`; an integral count outside 1..10,000,000 keeps `limit`.
- Q-SANDBOX: a catchable `value`.
- Q-WINDOWS: N5 for every offset and count.
- Q-PCM16OUT: unchanged clamp; the change comes through the window.
- Q-TEXT-SCALE: geometry.
- Q-GFX-ENV: the declared environment.
- `num of "-9223372036854775808"`: the int INT64_MIN.
- min/max int-vs-float ties: the FIRST argument wins, kind included (Lua). Add both orders.
- The store `3.0` round trip: a transitional state between R1.6 and R1.7, inside the unreleased branch. The R1.6f commit says so.

Decided here, because the documents leave each one open:
- **C1. Q-FLAGKIND:** 1/0 status results are INTS: `record_history`'s previous flag, `task_detach`'s result, `audio_volume`'s and `audio_stop`'s answers, and a `spawn` handle's `done` when it is numeric. A flag that is always 0 or 1 has no fractional meaning; the float is the bridge's artefact. Each probe adds `num_type`.
- **C2. `sum of []` is the int 0,** the additive identity over ints (Python's `sum([])` is `0`). No input makes it a float.
- **C3. Integer text beyond int64 in `scan_ints`/`scan_int_tokens` RAISES `value`,** naming the token. An integer scanner that returns a float or wraps is a silent wrong answer (§2), and the scanners' contract is ints.
- **C4. The LIST arms of `add`/`subtract`/`multiply`** are elementwise through the scalar arm, so ints stay ints and (A) overflow raises. Add one int-list case.
- **C5. Q-RECVTIMEOUT:**
  - 1e300 raises `value`;
  - the silent one-year cap is REMOVED: a timeout the wait call can honour is honoured, and beyond the call's representable limit (the builder determines it from the C types) it raises `value`;
  - add a case just past that limit.
- **C6. Q-HTTPPORT:** a port is N5, then 0..65535; 65536 raises `value` (add the case), and 0 (ephemeral) is valid.
- **C7. Q-NETSEND-R26:** keep `"hihi"` (no partial send). Because ext_net.c checks `g_has_error` BEFORE the byte conversion (line 363) and not after it (line 364), the R1.6f byte reader's raise must also stop the send. The probe pins it.
- **C8. inflate:** its output bytes are ints (Q1), asserted on the zlib profile.
- **C9. `f64_to_bytes` of an int converts to the nearest double first** (Q2). Add a 2^53+1 case expecting the bits of 9007199254740992.
- **C10. `proc_read_buf` with stdin `Hi`:** the expectation follows §6's row and Q2 (buffer storage is f64). If they disagree on the element kind, that is a QUESTION back to the orchestrator, not a guess. **S10-D2 below supersedes this retired-builtin witness while preserving its host-byte f64 intent.**

## S10-D2 — main retirement of `proc_read_buf` stands (2026-10-28)

The orchestrator ruled on PR #1776 that main #1691 (`5029856a`) stands:
after `proc_spawn` was removed (#1677), no surviving builtin produces a child-pipe
descriptor. Reading inherited fd 0 in this bar is a self-test, not a consumer
under the zero-consumer rule. This explicitly supersedes A5/C10's two
`proc_read_buf` probes, their eight case files, the sole `_stdin/hi` fixture,
and dependent plants P23 and R6. Their prior SHA-256 values and the two
`DELETED` frozen amendments are recorded in `../builtins_changes.md` under
S10-D2, as required by R1.7-D2. The only additional frozen amendment is the recorded #1888 decision below.

The existing frozen `builtins/read_bytes_buf.eigs` preserves A5/C10's intent:
it writes host bytes `[1, 2, 3]`, then pins `[3, 1.0, "float"]` from the read
buffer and `[3, "float"]` for its integral-float cap path and `d[2]` element.
These source-bound observations cover f64 typing of host-byte buffer elements;
the literal identity of `Hi` was not the typing property. Its source and
expectation remain byte-identical. A one-time real scalar-buffer-read typing
fault must make this surviving probe red; execution is recorded in sync10
evidence, not inferred from this note.

### S10-D2 sibling decision: #1888 nearest OTHER active entity

[The orchestrator's #1888 comment 6402855103](https://github.com/InauguralSystems/EigenScript/issues/1888#issuecomment-6402855103)
rules that `nearest_in_range_all` returns each entity's nearest OTHER active
entity, excludes itself and expressly assigns the next main-to-phase2 sync.
Main #1888/#2010 fixes that behavior. S10-D2 step 3 therefore replaces only
the old incidental index `1` with `0` in `nearest_in_range_all.branch`,
retaining its unchanged source/scenario and int/float kind witnesses. Exact
bank source and before/after branch hashes are in `../builtins_changes.md`.
This authorized semantic amendment is separate from N6's text-only allowance;
every other frozen expectation remains unchanged until the explicit S10-D3 diagnostic amendment below.

## S10-D3 — main read_text cap diagnostic stands (2026-10-29)

The PR #1776 orchestrator ruling authorizes ONLY the over-cap diagnostic line in `builtins/read_text.branch`. Main `e0d491598ee19108802bf25c99c5b59d23039117` closes [#2076](https://github.com/InauguralSystems/EigenScript/issues/2076), whose Done-when requires "the same raise message naming the escape" for `read_text`, `read_bytes` and `read_bytes_buf`, from one shared cap helper. EigenMiniSat#131 supplied the consumer: competition instances of14–21MB were refused. The bar case is a builtin self-test, not a separate Phase2 numeric rule.

The diagnostic appends ` — pass read_text of [path, max_bytes] (hard ceiling 536870912) to raise it`. All other lines, sizes, kinds, results, exit status, source and .pre/.tag stay unchanged. The exact before/after hashes are recorded in `../builtins_changes.md`; one-time bank census and bank/main/merged observations are in sync10 evidence. This explicit diagnostic amendment is additional to S10-D2's retirements and #1888 amendment.

For the rest of this sync, a frozen diagnostic/error-text amendment needs ALL three: only diagnostic text changes (no value, kind, status, line number or numeric rendering); the named main commit closed an issue whose Done-when/discussion requested that text (quoted for each case); and Phase2 has no own rule about that text. Each amendment gets its own ledger/RULINGS entry with commit and closed issue. Any case failing a condition remains a STOP; collect all such cases in one record.

## S10-D3 one-time corpus diagnostic classifications

These are individually reviewed corpus observations; none rewrites another frozen builtin case. The only additional frozen amendment beyond S10-D2 is read_text.branch above. For each path below, repeat statuses, stdout, diagnostic message, numeric rendering and source line/frame numbers are unchanged; only a source path is inserted in the header/frame. Closed [#1651](https://github.com/InauguralSystems/EigenScript/issues/1651) requires: "The uncaught-error header and every traceback frame carry a path". Main `0f6fddd43bd80dff9ad24e414099fd27f20d59a0` (#2004) implements it. Phase2 has no separate rule for this header text. Exact per-row byte evidence and line checks are retained in sync10/S10-D3-corpus-headers.json; this is the one-time merge sweep under PRINCIPLES §5.

| Corpus path | Main diagnostic contract |
|---|---|
| `tests/bool_fuzz_gen.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/embed_roads/eigs_modules/entrywrapper/entrywrapper.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/embed_roads/entry.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/embed_roads/helper/functions.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/embed_roads/helper/peer.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/embed_roads/import_entry.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/gfx_asan_corpus/06_rejected.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/line_after_callback_halt.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/line_after_return_fn.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/line_after_return_module.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/line_after_return_null.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/loader_mt_modules/lm_cyc_a.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/loader_mt_modules/lm_cyc_b.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/roads/assets/eval_loaded/caller.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/roads/assets/hardlinks/b/child.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/roads/assets/hardlinks/b/entry.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/roads/assets/no_project/cwd_only.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/roads/assets/no_project/parent.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/roads/assets/observer/assets/observer/target.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/roads/assets/observer/entry.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_deadlock.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_deadlock_worker_try.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detach_dead.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detach_dead_nested.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detach_dead_tape.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detach_dead_worker.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detach_observed.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detached_death.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detached_drain.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detached_join.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detached_self.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_detached_tape.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_join_later.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_thread_death.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_thread_detached.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_unjoined_death.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_worker_joined_task.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/task_exit_worker_unjoined_task.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/test_assert_fail.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/test_db.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/test_http.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/test_inflate.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/test_net.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/thread_exit_join_catch.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/thread_exit_join_throw_value.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/thread_exit_join_uncaught.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/thread_exit_unjoined_death.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |
| `tests/ui_native_input.eigs` | `0f6fddd4`, closed #1651: unchanged values/status/line numbers, file-bearing header/frame text only |

The following four rows add a worker diagnostic that the bank incorrectly suppressed; each keeps its status and stdout. These are ordinary main semantic fixes, separately classified from the path-only rows. Closed [#1808](https://github.com/InauguralSystems/EigenScript/issues/1808) requires "The rule for a task's uncaught-error print depends only on that task's own handlers", including the join-inside-try case. Main `8061e5a0e455f269e6dd0ce9a1185bdd47025f1a` (#2098) implements that rule. Phase2 has no contradictory numeric or diagnostic rule, and no frozen expectation is amended for these rows.

| Corpus path | Specific retained behavior |
|---|---|
| `tests/task_exit_detached_try.eigs` | rc1/stdout unchanged; worker excerpt/caret/frame precedes the fatal-boundary header, unaffected by main's parked try |
| `tests/task_exit_join_catch.eigs` | rc0/stdout unchanged; worker trace prints before join re-raises into main's catch |
| `tests/test_tasks.eigs` | rc0/stdout unchanged; crasher worker diagnostic at its unchanged line88 prints before the joining task handles it |

| `tests/task_exit_other_try.eigs` | rc1 and `main done` stdout unchanged; only the previously suppressed worker diagnostic at its actual line4 is added |

For `task_exit_other_try.eigs` specifically, closed #1808 Done-when also states: "The program above prints the worker’s error (message and trace) on stderr." Main `8061e5a0e455f269e6dd0ce9a1185bdd47025f1a` implements it. Both repeated statuses/stdout match, no value, kind, existing line number or numeric rendering changes, and Phase2 has no rule of its own about that worker text. This S10-D3 class record is a one-time corpus observation; it changes no frozen expectation. Exact per-arm evidence is in sync10/analysis/cont5-corpus/second-pass-85rows.json.
