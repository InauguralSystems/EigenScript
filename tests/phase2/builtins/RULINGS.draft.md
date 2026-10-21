# R1.6 bar: orchestrator rulings (DRAFT, to be finalized after the Astra bar critic's readings)

Each ruling settles one of BAR.md's QUESTIONS. A ruling that changes a row (its `.branch`, a probe line, or a column) is applied in R1.6a's first commit, and recorded in `tests/phase2/builtins_changes.md` with this text.

## Vacuity exemptions: a `closed_in` column
- **Q-HIST** (`abs`, `json_build`, `json_encode`, `sort`, `sort_by`) and **Q-ALREADY** (the six `bit_*`, `chr`, `dispatch`) are LOSS or int-requiring rows whose loss closed BEFORE R1.6. They are R1.2/R1.3 for Q-HIST, R1.5 for the `bit_*` six, and main before Phase 2 for `chr`/`dispatch`.
- RULING: `builtins.tsv` gains a `closed_in` column naming the round, or `main`.
- The vacuity check (`changes: yes` for every LOSS, int-requiring and Q7 row) applies to every row WITHOUT `closed_in`. A row WITH it must have `.pre == .branch`: the closure is checked, not declared. Its probe still pins exactness above 2^53, so a regression goes red.
- Q-GEN-1767 (`audio_sine`, `audio_saw`, `audio_square`, `audio_noise`; refused since #1767) gets `closed_in: main`.

## Semantics
- **Q-R17:** agreed. `store_put`, `db_execute`, `db_query_json` and `store_update` change at R1.6 through their DECODERS. The writers' float-digit loss is R1.7's (N14, #1762), and no probe pins the known-defect output.
- **Q-DB253:** agreed. With int columns decoded as ints, int2/int4/int8/oid columns beyond 2^53 return the exact int, and `db_check_exact_int`'s raise is deleted in the same commit, since its reason ("a double cannot represent it") is gone.
- **Q-HEX:** agreed. An int prints its exact uppercase digits (`hex of 9007199254740993` is `20000000000001`). Negatives still raise, and a float follows N5.
- **Q-SIGNEXT:** agreed. The result is an int. `bits <= 0` or `bits > 32` behaviour is unchanged (not part of R1.6).
- **Q-STREAMOPEN:** agreed. N5 comes first, so a fractional count raises `value`. An integral count outside the cap still raises `limit`. BUILTINS.md changes in the same commit.
- **Q-FLAGKIND:** 1/0 status numbers (`record_history`'s previous flag, `task_detach`'s result, `audio_volume`'s and `audio_stop`'s answers, a `spawn` handle's `done`) become INTS. Each probe adds `num_type` to pin the kind.
- **Q-SANDBOX:** agreed. A fractional limit is the host's argument, so it raises a catchable `value`.
- **Q-RECVTIMEOUT:** the magnitude rule (Q7). Round, then raise `value` when the C call cannot honour the value. Today's silent one-year cap is removed if the C call can honour longer; otherwise that cap is the C limit and raises past it. No silent clamp.
- **Q-WINDOWS:** agreed. Q1 is general: every offset, index and count follows N5.
- **Q-PCM16OUT:** agreed. The bounded clamp is unchanged by design, and the row changes through its window. The Q7 class is still exercised.
- **Q-NETSEND-R26:** agreed with the bar's reading.
- **Q-HTTPPORT:** a port is N5, then 0..65535 (`value` outside it). Port 0 (ephemeral) is valid.
- **Q-TEXT-SCALE:** agreed. `gfx_text`'s scale is geometry (its §6 note).
- **Not exercised, now settled:**
  - the `add`/`subtract`/`multiply` LIST arms are elementwise through the scalar arm (ints stay ints, and (A) overflow raises). A probe line is added;
  - `sum of []` is the int `0`;
  - `min`/`max` ties between an int and a float keep the FIRST argument, its kind included (Lua 5.4: `math.max(1, 1.0)` is `1`);
  - `num of "-9223372036854775808"` is the int INT64_MIN. The string grammar includes the sign, unlike the lexer's unary minus; Lua agrees;
  - integer text beyond int64 in `scan_ints`/`scan_int_tokens` raises `value` naming the token, because an integer scanner never returns a float;
  - inflate's output bytes are ints (Q1), and a probe line pins the kind;
  - `f64_to_bytes` of an int converts to the nearest double first (documented, not pinned).
- **The store float round trip between R1.6 and R1.7** (`3.0` written as `3`, read back as an int) is a known TRANSITIONAL state inside the unreleased branch. The R1.6f commit says so, and R1.7's `N14.store-exact-digits` row closes it.

## Witnesses
- **Q-CAP:** capability rows carry a `cap` column (`http`, `net`, `model`, `zlib` or `db`). The tool runs a capability row only against a binary built with that capability, and CI checks them in the lanes that have it: the server lane (`make server`: http, net, model), the zlib lane, and the db lane with its postgres:16 service.
  - Their `.pre`/`.tag` are re-recorded on capability builds of the same commits (`make server` and `make zlib` locally). The db rows are recorded where PostgreSQL exists; the R1.6a builder reports the mechanism.
- **Q-CLOCK:** agreed. `monotonic_ns` changes through its kind (float to int). The digit loss above 2^53 ns (104 days of uptime) is a stated residual.
- **Q-AUDIO-HIDDEN:** `audio_stream_push` and `audio_music_volume` get `witness: none (mixer-internal)`, a VISIBLE exemption from the changes rule. Their wiring is reviewed by reading in R1.6e, and the reader itself is covered by `gate.N5.q7-readers`.
- **Q-GFXPOLL:** R1.6e adds a line to `tests/ui_sdl_input.c` (`make ui-sdl-input-gfx`, #1263) printing `num_type` of the event's `x`, `y`, `scancode` and `button`, which gives a real int witness. The table row stays null-only, with that cross-reference.
- **Unreachable** (`proc_read_buf`'s float bytes; `http_post`'s header digits): stated residuals.
- **Q-GFX-ENV:** agreed. The gate runs where the suite's gfx and audio sections run (dummy drivers, xvfb).
