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
- **A5. A `stdin` fixture column** (the critic's item 13). `proc_read_buf` gets a second case with stdin `Hi`, keeping the `/dev/null` EOF case.

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
- **C10. `proc_read_buf` with stdin `Hi`:** the expectation follows §6's row and Q2 (buffer storage is f64). If they disagree on the element kind, that is a QUESTION back to the orchestrator, not a guess.
