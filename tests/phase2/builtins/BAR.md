# R1.6 per-builtin behaviour table: the pre-registered bar (#1758, design §9.4)

Written before any R1.6 migration. Every `.branch` is derived from the design
(`docs/design/phase2-numbers.md` §6, §2.6, §9.4, §11 at `4ac31e67`; for
`read_text`, §6 and the code at `1fd4422c`, ruling R1.6a-D1), from the
#1758 decisions (comment 6304880619 for N10), from the orchestrator's rulings
(`RULINGS.md`) and from Lua 5.4.9. No `.branch` was copied from a binary. The
binaries only produced `.pre` (R1.5 tip `4ac31e67`,
`/home/jon/src/wt/r15-critic/build/release/eigenscript`) and `.tag` (v0.46.0
release binary). Where a row should not change, its `.branch` equals `.pre`.
That agreement checks the derivation; it is not where the expectation came
from. Every `.branch` that changed after its first observation is listed under
"Corrections log", with its reason.

**Fix round, 2026-10-20.** The blind critic found the first version DEFECTIVE
(witness defects F1-F8, and no wrong scalar expectation). This version applies
the orchestrator's FINAL rulings (`RULINGS.md`): A1-A5 (table structure),
B1-B6 (witnesses), and C1-C10 plus the agreed answers (semantics). Each changed
`.branch` names its ruling in the Corrections log. The hook rows' `.pre` and
`.tag` were recorded with the test shim preloaded, on the same two binaries.
The 25 non-release rows' `.pre` and `.tag` read `PENDING-PROFILE <profile>`;
R1.6a records them on matched builds.

**R1.6a rulings, 2026-10-21 (historical, before R1.6-S2).** R1.6a-D1:
the population was 232 rows, taken at
`1fd4422c` (the R1.6a start, sync #4, which carries main's #1841 and adds
`read_text`). §6 and the inventory at `1fd4422c` differ from `4ac31e67` only by
that row (field by field; the inventory's other changes are line moves and one
accessor list). R1.6a-D2: no probe prints a value the OS or the environment
chooses; `net_port`'s port line and its siblings print a predicate instead.

**Sync #5, R1.6-S1/S2.** Main's `rm` deletion removes no table row: the
number-reading bar never included it. R1.6-S2 adds main's `set_exit_code`
as an int-requiring release-profile row in round c, closed by main #1909.
The current population is 310 rows and 312 cases, with round counts b 46,
c 77, d 53, e 38, f 19 and g 77 (b/f include R1.6b-D3's `http_post` correction).
The new `.branch` is an authorized addition recorded by SHA-256 under
R1.6-S2 in `../builtins_changes.md`; existing frozen expectations stay fixed.

## Files
- `builtins.tsv`, 310 rows: `builtin file class loss q7 round closed_in
  profile hook stdin changes_vs_pre changes_vs_tag`. `make_table.py` writes
  it. Rows come from the §6 table, checked both ways against the inventory's
  `## Builtins` list, field by field. Both files and `src/` are extracted with
  `git archive` from `EIGS_REPO` at `EIGS_REV` (default
  `/home/jon/src/InauguralSystems/EigenScriptEcosystem/EigenScript` at
  `1fd4422c`), so the population is pinned to the ruled commit, not to a
  checkout's state; `EIGS_TREE` overrides it for the plants. `file` is the
  `src/*.c` file that defines the inventory's C function. `round` follows the
  plan's rule, and the counts are checked against b 46, c 77, d 53, e 38,
  f 19 and g 77 (R1.6b-D3, R1.6-S2 and R1.6g-D1). The other columns:
  - `closed_in` (ruling A2) and `profile` (A3) come from `rowmeta.tsv`;
  - `hook` (A4) and `stdin` (A5) list the hooks and the stdin fixtures of the
    row's cases, in case order. `-` means none, and stdin `-` is `/dev/null`;
  - `changes_vs_pre` (A1) is `yes` when `.branch` differs from `.pre` on any
    of the row's cases. It is the R1.6 migration delta, and the vacuity guard
    uses it. It reads `pending-profile` while a non-release row waits for its
    matched build;
  - `changes_vs_tag` (A1) is the same comparison against `.tag`, §9.4's
    original one. It is recorded as an observation and never checked, because
    the tag has no `num_type`, and `set_exit_code` also postdates the tag.
- `rowmeta.tsv`: `builtin closed_in profile`, one line per table row.
- `cases.tsv`: `case builtin hook stdin`, 312 cases. A row's primary case is
  `builtins/<b>`. A second case is `builtins/<b>.<label>`: `gfx_poll.empty`
  (B3) and `proc_read_buf.hi` (A5).
- `builtins/<case>.eigs` is the probe. `<case>.branch` is the pre-registered
  stdout after R1.6, then `rc=<N>`. `<case>.pre` and `<case>.tag` are the
  observed stdout plus `rc=<N>`, or `PENDING-PROFILE <profile>`.
- `builtins/_hooks/observation_hooks.c`: the LD_PRELOAD shim (A4; its repo
  target is `tests/phase2/observation_hooks.c`). `run_probes.sh` compiles it
  with `gcc -shared -fPIC` into its scratch directory on every run.
- `builtins/_stdin/hi`: the two bytes `Hi` (A5).
- `builtins/_profiles/<profile>.eigs`: the profile witnesses (A3).
- `run_probes.sh [case...]` records `.pre` and `.tag`, never `.branch`.
- `make_table.py [--final]` writes `builtins.tsv` and runs every table check.
- `determinism.sh [case...]` records the cases three times (twice normally,
  then pinned to core 0 at nice 19) and fails on any `.pre` or `.tag` that
  differs between the runs (R1.6a-D2's class).
- `plants.sh` plants one fault per check in a scratch copy and requires the
  check's named FAIL line.
- `oracle/<b>.lua` and `oracle/<b>.lua.out`: the Lua 5.4.9 expressions and
  their verbatim output.

Re-run: `./run_probes.sh` (all cases) or `./run_probes.sh abs gfx_poll.empty`,
then `python3 make_table.py`. R1.6a adds `--final` once the matched builds are
recorded. Both exit non-zero on an instrument failure. Run them on Xvfb
(`DISPLAY=:99`). R1.6a's gate runs each case the same way (environment,
stdin fixture, shim) on the branch build and compares stdout plus `rc=` with
`.branch`; this bar ships no branch-mode runner.

## Probe conventions
- Each probe starts with the helper `nt`: `num_type of x`, catching the error.
  `num_type` does not exist on the tag, so there it answers `"undefined_name"`
  and the tag line still shows the value. On R1.5 and after, `nt` equals
  `num_type`.
- Results print as `[value, num_type]`, following §9.4's `len of [1, 2]` ->
  `[2, "int"]`. An expected raise prints `[<label>, e.kind]`, which keeps stdout
  self-describing.
- An int-requiring probe passes a FRACTIONAL value in an integer-valued
  parameter and expects `value`, then passes an integral float (`2.0`) that must
  convert and succeed.
- A LOSS probe uses an int beyond 2^53 (usually 2^53 + 1 = 9007199254740993,
  which a double rounds to 2^53), or INT64 edges, so that the bridge's loss
  shows.
- Files go under `env_get of "EIGS_PROBE_TMP"`. The runner sets it to a fresh
  directory, which is also the working directory.
- Determinism: an RNG is always seeded, or its result range is a single value.
  A real clock prints only its kind and an ordering; `monotonic_ns` reads the
  injected clock (B2). Only loopback is used. No probe may block on any
  binary: a channel read has its values queued first, and a timeout (rc 124)
  is a runner FAIL. No line prints a value the OS or the environment chooses
  (a port, a pid, a socket handle, a time, a path); such a line prints a
  predicate over it instead (R1.6a-D2), and `determinism.sh` fails when one
  slips through.
- Environment (`run_probes.sh`): `env -i` plus the suite's headless conditions
  for gfx and audio (`SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy`, as
  `tests/suite_program_env.txt` gives them to `test_audio.eigs` and
  `test_gfx_*.eigs`), `DISPLAY=:99`, `EIGS_GFX_FONT=/nonexistent/eigs-no-font.ttf`
  (the documented switch to the bitmap font, so text metrics are deterministic),
  `ulimit -v 1500000` (the box's cap for gfx runs; the first version used
  2000000), `timeout 60`, and stdin from the case's fixture (default
  `/dev/null`). `DATABASE_URL` (the db rows) and `R16_HTTP_CAPTURE_URL` (B6)
  pass through when set. A hook case also gets `LD_PRELOAD`, `R16_HOOK` and
  `R16_HOOK_LOG`, set after `timeout` so that only the probed binary loads the
  shim. Strict mode is the default, since `EIGS_STRICT` is unset.
- Float text: R1.6 still prints floats with today's formatter (N6 lands in
  R1.7), so each expected float is written the way `eigs_num_text`
  (eigenscript.c:3003) prints it. An integral double below 2^53 prints as
  `%lld`, so `3.0` prints `3`. Anything else prints the shortest of
  `%.15g`..`%.17g` that round-trips (`1e+300`, `9.223372036854776e+18`). I
  computed these from that source, not from `pre`.

## Capability profiles (ruling A3)
`pre` and `tag` are release builds, which compile out these capabilities.
There, calling such a builtin raises a catchable `value` error naming the
capability. A capability-unavailable transcript is never a change. So the 25
non-release rows' `.pre` and `.tag` read `PENDING-PROFILE <profile>`, both
changes columns read `pending-profile`, and each `.branch` gives the output on
a binary built with the profile, derived from the design:

| profile | build (Makefile) | rows |
|---|---|---|
| server (HTTP, MODEL, NET) | `make server` (`FLAGS_server`) | `shared_incr` (b); `shared_delete`, `shared_size`, `http_*` (f); `net_*` (f); `eigen_eval_loss`, `eigen_generate`, `eigen_model_load`, `model_load_weights`, `native_train_step_builtin` (d) |
| db | `make server-db`, plus `DATABASE_URL` naming a live PostgreSQL | `db_execute`, `db_query_json`, `db_query_value` (b) |
| zlib | `make zlib` | `inflate` (d) |

Current profile counts (R1.6g): release 285, server 21, db 3, zlib 1.

R1.6a records these rows on matched builds: the same profile built at
`4ac31e67` and at v0.46.0, passed as `PRE_BIN_<P>` and `TAG_BIN_<P>` (`P` is
`SERVER`, `DB` or `ZLIB`). It then checks each `.branch` on the branch's build
of that profile. Three guards keep a capability transcript from counting as a
change:
- Before recording, `run_probes.sh` runs `builtins/_profiles/<profile>.eigs`
  on each given binary, and stops with exit 2 unless it prints `profile-ok`.
  For server, none of `shared_size`, `net_listen` and `eigen_model_load` may
  answer "capability unavailable". For db, `db_connect of null` and then
  `SELECT 1` must answer 1. For zlib, `inflate of [203, 200, 4, 0]` must
  decode to `hi`. On the release binary the three witnesses print
  `["capabilities-unavailable", 3]`, the db error and the zlib error.
- `make_table.py` FAILs a non-release record that contains `capability
  unavailable` or `compiled without`. (`http_serve` and `http_early_bind`
  print a capability flag, not the message, so for those two rows the profile
  witness is the guard.)
- `make_table.py --final` FAILs while any record is still pending.

The db mechanism: this box has no PostgreSQL (no `psql`, `postgres`,
`/usr/lib/postgresql` or docker). CI's `database-worker` job
(`.github/workflows/ci.yml`) runs `make server-db` in the dev image, with a
`postgres:16` service and
`DATABASE_URL=postgres://eigs:eigs_test@db:5432/eigs_test`. It runs on every
event except pull requests. Every db probe connects with `db_connect of null`,
which reads `DATABASE_URL`, and the runner passes it through. So R1.6a records
the three db rows in that job's environment, or on any host with a
PostgreSQL, using `server-db` builds of `4ac31e67` and v0.46.0.

## Hooks (ruling A4)
`builtins/_hooks/observation_hooks.c` starts from the critic's
`observation_hooks.c`. The runtime `dlopen()`s SDL and SDL_mixer and
`dlsym()`s each entry point, so interposing `dlsym` reaches them, and
`clock_gettime` is interposed directly. EigenScript's source and binary do not
change. `R16_HOOK` picks one hook per process:

| hook | interposes | effect | case |
|---|---|---|---|
| `pcm` | `SDL_QueueAudio` | logs the int16 samples delivered (up to 8) | `audio_stream_push` |
| `mix` | `SDL_OpenAudioDevice` | wraps the playback callback (EigenScript's own channel mixer, `audio_mix_callback`) and logs the first non-silent buffer it delivers (up to 8 samples) | `audio_play`, `audio_play_loop`, `audio_volume` |
| `mixvol` | `Mix_VolumeMusic` | logs the volume handed to SDL_mixer | `audio_music_volume` |
| `clock` | `clock_gettime(CLOCK_MONOTONIC)` | answers 9007199 s 254740993 ns, that is 2^53 + 1 ns | `monotonic_ns` |
| `events` | `SDL_PollEvent` | delivers mouse motion (17, -9), key scancode 4, then button 1 at (23, 42); after that the queue is empty | `gfx_poll` |

- The channel gain that `audio_volume` sets has no SDL setter: EigenScript
  applies it inside its own callback. So its SDL boundary is the callback's
  output buffer, which `mix` logs.
- A hooked process first writes `hook-loaded <hook>` to `R16_HOOK_LOG`, a
  file in the probe's scratch directory, and capture hooks append their
  payload lines there. Every hook probe prints that log as its last output, so
  the boundary payload is part of `.pre`, `.tag` and `.branch`.
- Two checks catch a missing shim. `run_probes.sh` fails (exit 2) when the
  log's first line is not `hook-loaded <hook>`. `make_table.py` fails when a
  hook case's `.branch`, `.pre` or `.tag` does not hold exactly one such line,
  and when a case without a hook holds one.
- The mixer probes pause the device (`audio_pause of 1`) before installing a
  channel and unpause it afterwards, so the first non-silent buffer starts at
  the channel's first sample. They wait up to 4 s for that buffer
  (`wait_for`).
- `R16_PLANT=silence` is a test mutation that only `plants.sh` uses: the
  delivered PCM becomes zeros.

## Derivation per class
**int-preserving** (§6: "returns an exact int"). With int inputs, the result's
`num_type` is `"int"`:
- arithmetic and min/max/rounding: Lua §6.7's "integer results for integer
  arguments"; `math.min`/`max` return the winning argument with its subtype;
- counts, codes, indices and handles: Lua `#` and `string.byte`;
- `floor`/`ceil`: an int when the result fits int64, else a float, as in Lua
  §6.7. `round` follows them (Q4: half away from zero).

The scalar arms of `add`, `subtract`, `multiply`, `negative` and `sum` mirror
the VM operators (N3), so int64 overflow raises `value` ((A)), and negating
INT64_MIN raises (N4b). Buffer arms stay float. A mixed int/float input gives
a float, as Lua's arithmetic does.

**int-requiring** (§6 and Q1: the parameter's meaning decides, not the C type).
An integer-valued argument converts by N5's exact rule (`num_to_i64_exact`:
an integral double in range converts, anything else has no integer
representation), then the C range applies. So `1.5` raises `value`, `2.0`
converts, and a byte outside 0..255 raises. A result that is a count, a bit
pattern or an id is an int.

**float-producing** (§6: ints convert to float, the result is a float, as Lua's
`/`, `^` and `math.sin` do). With int inputs, `num_type` is `"float"`. Buffer
storage is float (Q2).

**other** (§6): each row follows its note. Codecs and parsers (N10, N13, N14):
integer text decodes to an int when it fits int64, and text with `.` or an
exponent decodes to a float (MAP `N14.decode-kinds`, `N10.int-or-float`).
Writers keep today's float text until R1.7. Continuous parameters follow Q7.

**Q7** (§2.6, §11, decided in comment 6174302316): geometry clips the WHOLE
shape in float space against the drawable area, then rounds half away from
zero, and an out-of-range shape draws nothing outside the area; bounded values
clamp to the domain, then round; magnitudes round and raise `value` when the
C call cannot hold them. A Q7 probe passes one out-of-range value of each class
in its `q7` column.

**LOSS** (§6): the probe must show the bridge's loss, usually with an int beyond
2^53. A row whose loss was closed before R1.6 carries `closed_in` (A2). A row
whose writer loss is R1.7's changes at R1.6 through its decoder (Q-R17,
agreed).

## Per-row derivation, round b (45 rows; R1.6b)
- `abs`: Lua `math.abs`; `-(2^53+1)` gives `2^53+1` as an int; a float stays a
  float; INT64_MIN raises (N4b; Lua wraps, a declared divergence, §10).
  `closed_in` R1.2/R1.3 (A2): the int arm landed in R1.3, so `.branch` equals
  `.pre`.
- `add`, `subtract`, `multiply`: scalar arms mirror `+ - *` (N3/(A)). Exact sums
  above 2^53; overflow raises `value`. The `add` buffer arm stays float. The
  LIST arms go elementwise through the scalar arm (C4;
  `tensor_elementwise_slots`), so ints stay ints: `[[1, 2^53+1], [2, 1]]`
  gives `[3, 2^53+2]`, `[[5, 2^53+1], [2, 1]]` gives `[3, 2^53]`, and
  `[[3, 3037000499], [2, 3037000499]]` gives `[6, 9223372030926249001]`.
- `negative`: mirrors unary `-`. `-(2^53+1)` is exact; `-INT64_MIN` raises (N4b).
- `sum`: an all-int input sums exactly, `[INT64_MAX, 1]` raises `value` with a
  message naming `sum` (MAP `A.sum-overflow-raises`), and a mixed list gives a
  float. `sum of []` is the int 0, in both call forms (C2).
- `floor`, `ceil`, `round`: Lua `math.floor`/`ceil`; Q4 for `round`. An int input
  returns itself; `-2.5` gives `-3`/`-2`/`-3` as ints (`round of 2.5` = `3`);
  `1e300` stays a float.
- `min`, `max`: Lua returns the winning argument with its own subtype.
  `[2^53+1, 2^53+2]` picks exactly; `[3, 3.5]` gives the int 3; `[4, 3.5]` gives
  the float 3.5; a bare `7` returns itself (the code's documented bare-number
  case). In an int/float tie the FIRST argument wins, kind included (agreed;
  Lua): `[3, 3.0]` gives the int 3 and `[3.0, 3]` the float 3, printed `3`.
  An empty call raises `value`, in both call forms, `min of []` and
  `min of ([])`, and likewise for `max` (R1.6b-D2, #1895): there is no
  winning argument, and Lua's `pcall(math.min)` also refuses (`bad argument
  #1 to 'math.min' (value expected)`). `pre` and the tag answer `0`.
- `num_copy`: keeps its subtype (§6 note).
- `hex`: the 2^53 refusal is a double compare (§6), and the C formatting type is
  `unsigned long long`. N5 then the C range accepts every non-negative int64,
  so `2^53+1` prints `20000000000001` (Q-HEX, agreed). `nibbles` is a count,
  so `4.5` raises and `4.0` converts. A fraction already raised and still
  does. A negative raises `value` (Q-HEX); it already does on `pre`.
- `sign_extend`: both arguments are integer-valued (a bit pattern and a width).
  The algorithm is unchanged and reads exactly: `[2^53+129, 8]`, low byte 0x81,
  gives `2^53+129-256` = `9007199254740865`. Results are ints (Q-SIGNEXT).
  The subtraction is checked int64 arithmetic under rule (A), "overflow
  raises, no wraparound" (R1.6b-D1, #1894): `[-9223372036854775553, 8]` has
  low byte 0xFF, and subtracting 256 would give INT64_MIN - 1, so it raises
  `value`, naming `sign_extend`. Lua's integer subtraction wraps the same
  operation to 9223372036854775807; `pre` and the tag answer
  `-9.223372036854776e+18`.
- `random_int`: Lua `math.random(m, n)` is an integer. The bounds follow N5.
  `[2^53+1, 2^53+1]` has a span of 1, so the result is deterministic and exact.
- `seed_random`: a seed's range is all of int64 (§6, design round 2). So seeds
  2^53 and 2^53+1 must give different streams (they give the same stream on
  `pre`). `1.5` raises; `42.0` seeds like `42`. `srand48` keeps only the low 32
  bits; I computed from POSIX's drand48 that low words 0 and 1 give first draws
  850048 and 400395, so they differ. The probe asserts nothing beyond the two
  seeds differing (see OUT OF SCOPE, srand48).
- `task_sched_seed`: `(int64_t)` of a double today. The splitmix64 state
  (task.c:245) for seeds 2^53 and 2^53+1 gives first picks over 3 ready tasks of
  1 and 2 (computed), so the receive orders differ. (Over 4 tasks both pick 3,
  so 4 workers would not show the difference.) `1.5` raises; `5.0` equals `5`.
- `len`, `ord`, `index_of`, `list_index_of`, `range`: counts and indices are
  ints (Lua `#`, `string.byte`). `list_index_of` compares by N2 (exact above
  2^53; 2 equals 2.0). `range`'s bounds follow N5: `2.5` raises (MAP
  `N5.range-fraction-raises`), `[1.0, 3.0]` converts, and the elements are ints.
- `channel`, `spawn`, `task_spawn`, `task_self`: handle dicts with int id/gen
  fields, and int task ids (main is 0). Only the kinds print; the ids are
  allocation order. A spawn handle's `done` is numeric (`make_num(0)`,
  builtins.c:4546), so it is an int (C1).
- `monotonic_ns` (B2): the `clock` hook makes CLOCK_MONOTONIC read 2^53+1 ns,
  so the result is the exact int 9007199254740993 and equals that literal.
  `pre` answers 9007199254740992, a float, unequal: a double cannot hold
  2^53+1.
- `scan_ints`, `scan_int_tokens`: integers accumulate exactly. The
  line/col/offset/is_int/value fields are ints. Token rows were derived by
  hand from the C scanner. Integer text beyond int64 raises `value`, and the
  message names the token (C3): `9223372036854775808`.
- `num` (N10, comment 6304880619): accepts exactly the lexer's numeric grammar.
  The lexer (lexer.c:721-775) takes a strtod decimal span starting at a digit or
  `.digit`, so `.5` and `1.` are floats. Digits-only text is an int when it fits
  int64; `0x`/`0X` hex wraps modulo 2^64. A sign and surrounding whitespace are
  allowed. Everything else raises `value`. The oracle is Lua's `tonumber`, apart
  from the declared hex-float divergence (`0x1p4`). `"-9223372036854775808"`
  decodes to the int INT64_MIN (agreed; Lua's `tonumber` agrees).
- `json_decode`: MAP `N14.decode-kinds`, plus `2^53+1` exact, `-7` an int, and
  `1e2` a float (exponent text).
- `json_path`: returns text. Decoder ints arrive at R1.6, so `2^53+1` and
  INT64_MAX come back as exact digits (MAP `N14.json-path-int-exact`). A nested
  list re-encodes exactly.
- `json_encode`, `json_build`, `sort`, `sort_by`: the int arms are already exact
  (R1.2/R1.3), and float text stays until R1.7. The `.branch` therefore equals
  today's output: `closed_in` R1.2/R1.3 (A2).
- `store_get`, `store_delete`, `store_update`: keys follow N5 (MAP
  `N5.store-key-fraction-raises`). `1.9` raises `value` where today it finds or
  deletes record "1"; `1.0` converts. Key 4294967297 finds the record whose
  `_id` is "4294967297" (§6: "R1.6's `eigs_int_arg` for the key closes"
  #1760; `pre` still misses it). Records decode integer text as ints (N14, R1.6).
  Big keys (B4): `store_update` and `store_delete` act on the record whose
  `_id` is `"9007199254740993"` through the numeric key 2^53+1, exact under
  N5, giving `["update-big-key", true, 2]` and `["delete-big-key", true, 0]`.
  `store_get` finds that record by the same numeric key. `pre` rounds the key
  to 2^53 and misses it.
- `store_put`, `store_query`: the record decoder gives ints for integer text
  (R1.6). Ints are written as exact digits already (R1.2a). The `%.15g` float
  writer is R1.7's (Q-R17).
- `shared_incr` (server profile): the counter adds exactly, and overflow raises
  ((A), §7 lists `shared_incr`). `shared_get` decodes the stored text as an int.
- `db_execute`, `db_query_value`, `db_query_json` (server-db plus PostgreSQL):
  ints bind as exact digits (R1.2a), and int columns decode as ints (R1.6).
  See Q-DB253.

## Per-row derivation, round c (77 rows; R1.6c; R1.6a-D1 and R1.6-S2 additions)
- Float-producing (`acos asin atan atan2 cos sin tan pi random clock_unix
  monotonic_ms get_observer_thresholds dot stream_write`): ints convert and the
  result is a float (Lua `math.*`). Clocks print only their kind and an
  ordering; `random` is seeded and prints its kind and its [0, 1) range.
  Threshold values are the `OBSERVER_*_DEFAULT` constants (eigenscript.h:659-661).
  `stream_write` takes an int (Q2) and reads back through `tensor_load` as a
  float.
- `nearest_in_range`, `nearest_in_range_all`: geometry is float and the
  `index` field is an int (§6 note).
- Formatting, equality and message rows (`append assert join str print write
  text_builder_append text_builder_append_line throw type num_type
  list_contains observe`): R1.6 changes nothing in them. N6 (float text) is
  R1.7's, and ints have printed exact digits since R1.2a. Each `.branch` pins
  today's text, so `3.0` still prints `3`, and an int above 2^53 is exact.
  `throw` binds the thrown value itself.
- `record_history`: a truthiness flag in (`0.5` enables), the previous flag
  out. The previous flag is an int (C1), and the probe prints its kind.
- `task_sleep`: virtual ticks stay a float (§6), so 2 wakes before 2.5. If 2.5
  were truncated, the two tasks would tie and FIFO would deliver "slept-2.5"
  first.
- Bitwise (`bit_and bit_or bit_xor bit_not bit_shl bit_shr`): Lua §3.4.2 and
  the N8 shift rules, exact since R1.5. A fraction raises `value` and an
  integral float converts. `closed_in` R1.5 (A2).
- Strings and lists (`char_at substr list_insert_at list_remove_at list_slice
  list_truncate fill get_at set_at copy_into`): positions, lengths, counts and
  offsets follow N5, so a fraction raises `value` where today it truncates,
  and `1.0` converts. Elements are returned unchanged. A buffer store converts
  to float (Q2).
- `chr`, `dispatch`: "already exactness-checked" (§6 notes), so no change:
  `closed_in` main (A2).
- Handles (`channel_closed close_channel send recv try_recv recv_timeout
  thread_join task_alive task_join task_kill task_detach task_send`): a handle's
  id and gen are integer-valued. A forged handle whose id is `id + 0.5` raises
  `value`; today the `(int)` cast resolves it to the real channel or thread,
  and a fractional task id reads as "unknown" (`false`/`null`/`0`). `id + 0.0`
  converts and reaches the real object. `task_detach`'s 1/0 result is an int
  (C1).
- `recv_timeout`, `exec_capture`, `usleep` (Q7 magnitude): `1e300` cannot be
  held by the C type, so it raises `value`. Today `recv_timeout` caps it at one
  year, `exec_capture` casts it to `time_t` (undefined; the deadline passed at
  once), and `usleep`'s `(int)` cast gives INT_MIN (no sleep). The
  `recv_timeout` probe queues values first, so no binary can block, and its
  `.branch` keeps the values queued (a refusal precedes the effect).
  `exec_capture` exit codes are ints (§6).
- `recv_timeout` (C5): the one-year cap is removed. The milliseconds reach
  `long whole_ms = (long)ms` (builtins.c:4867), and `whole_ms / 1000` (at most
  about 9.2e15 s) is added to the 64-bit `tv_sec` of `EIGS_CHANNEL_CLOCK`
  (CLOCK_MONOTONIC or CLOCK_REALTIME, builtins.c:4713-4715), which cannot
  overflow. So the call can honour any timeout up to LONG_MAX ms. The first
  value past it is 2^63 ms (the literal `9223372036854775808`, which lexes as
  a float), and it raises `value`. The probe queues three values: on `pre`
  and the tag, each of the three raise cases consumes one, and none blocks.
- `exit`: N5, then the C int range. `2.5` and `4294967296` raise `value`, and
  `3.0` exits with rc 3 (today `2.5` exits with rc 2).
- `set_exit_code` (R1.6-S2): N5, then 0..255, already checked by main #1909.
  `1.5`, `256` and `-1` raise `value`; `3.0` succeeds, execution continues,
  and graceful completion uses rc 3. Its `.pre` equals `.branch`, with
  `closed_in` R1.6-S2; the tag has no such builtin. This row stays in round c
  with `exit` until their bridge migration.
- Host (`random_hex read_bytes_buf proc_read_buf build_corpus token_name
  state_at sandbox_run vm_run_bytecode write_bytes stream_open`): counts, caps,
  fds, ids, line numbers, limits, ABI numbers and opcode bytes follow N5. Byte
  values follow Q1: N5, then 0..255, so `write_bytes` 300 raises (today it
  wraps to 44) and 65.5 raises (today 65). `vm_run_bytecode` code byte 256
  raises (today it wraps to 0, `OP_CONST`), and ABI `1.5` raises (today
  `(int)1.5` == 1 passes). Counts returned (`write_bytes`, `build_corpus`) and
  `sandbox_run`'s error `line` are ints (§6 notes). `read_bytes` returns byte
  values as ints (int-preserving).
- `proc_read_buf` (A5, C10): a second case, `proc_read_buf.hi`, reads stdin
  `Hi`. §6's row ("bytes stored as floats") and Q2 (buffer storage is f64)
  agree on the element kind, so the case expects `[2, 72, 105, "float",
  "float"]`, and then EOF answers null. The primary case keeps stdin
  `/dev/null` and its EOF path.
- `stream_open`: the fraction raises `value` by §9.4's class check; today it
  raises `limit`. An integral count outside 1..10,000,000 keeps `limit`
  (Q-STREAMOPEN, agreed): the count 0.
- `read_text` (R1.6a-D1; round c, `builtins_host.c`, release profile, no hook,
  no `closed_in`): §6 at `1fd4422c` says "string result; numeric over-cap size
  is internal tape metadata (#1668), with no numeric argument or successful
  numeric result", so R1.6 changes nothing and the `.branch` is the
  `1fd4422c` code's answer. A missing file raises `io` (`file_io_error`; the
  message names the path, so only the kind prints). A file of 10,485,761
  bytes, written under `EIGS_PROBE_TMP` with `write_text`, raises `io` with
  `read_text: '<path>' is %ld bytes, over the %d-byte cap`, a format the code
  fixes, so the probe pins the digits after the path: `" is 10485761 bytes,
  over the 10485760-byte cap"`, and checks the prefix with `starts_with`. A
  2-byte file reads back as the string `"hi"`. Over-cap REPLAY is not
  exercised: it is the open bug #1890, and a probe must not pin a known
  defect.
  - `.pre` and `.tag` are observations on binaries that predate #1841: there
    `read_text` answers `""` for the missing file and for the over-cap file
    (`["missing-answer", ""]`, `["over-cap-answer", 0]`), so this row's
    `changes_vs_pre` reads `yes` today. Class `other` is not guarded. R1.6a
    re-records `.pre` on `1fd4422c` as this row's in-scope baseline (#1668
    changed it upstream), and then `changes_vs_pre` must read `no`.
- `exec_capture`'s `1e300` line prints only `type of` the answer on `pre` and
  the tag (R1.6a-D2's class, found by the determinism re-run). There
  `(time_t)1e300` is undefined, and the deadline arithmetic
  (`builtin_exec_capture`, builtins_host.c) overflows. While the clock stays
  in the second the deadline was set in, the remaining time reads as huge;
  once a second boundary passes before the read loop sees EOF, it reads as
  already past, and the child is killed (`[-2, "hi\n"]` instead of
  `[0, "hi\n"]`). The pinned nice-19 recording showed `-2` once, and 172
  further runs of the old line did not. The branch raises `value` before the call, so
  the `.branch` is unchanged.
- Structural facts R1.6 does not touch (dict key order such as `{"ok": true,
  "result": 7}`, handle field names, error kinds of unrelated failures) were
  read from the source or from exploratory runs on `pre`. No numeric
  expectation came from a binary.

## Per-row derivation, round d (53 rows; R1.6d)
- Float tensor math (`divide pow sqrt exp log mean norm relu leaky_relu softmax
  log_softmax matmul matmul_at matmul_bt zeros_like numerical_grad sgd_update
  tensor_save tensor_load buf_from_list`): ints convert and results are floats.
  `/` and `^` are always float (Lua §3.4.1). Buffer and tensor-file storage is
  float, so an int above 2^53 converts by IEEE round-to-nearest (Q2):
  `buf_from_list`, `buf_set` and `tensor_save` of 2^53+1 hold
  9007199254740992.
- Buffer windows (`buf_copy buf_fill buf_mix buf_scale_range buf_peak buf_dot
  buf_deinterleave buf_resample_linear buf_to_pcm16le buf_from_pcm16le`):
  offsets, counts, channel indices and `dst_len` are indices and counts, so
  they follow N5 by Q1 (`buf_fill`'s note says so explicitly; Q1 is general,
  see Q-WINDOWS). A fraction raises `value` where today `(long long)`
  truncates.
- `buffer`, `zeros`, `reshape`, `random_normal`: sizes, dims, rows and cols
  follow N5. Elements are float 0.0 (§6).
- `buf_get`, `buf_set`: the index follows N5. The element read is a float, and
  the stored value converts (Q2).
- `buf_len`, `shape`: counts and dimensions are ints (int-preserving).
- Byte readers (`str_from_bytes f64_from_bytes buf_from_pcm16le inflate`): Q1's
  byte reader, so a fraction or a byte outside 0..255 raises `value`. Today
  `finite_num_to_byte` wraps modulo 256 (328 is 'H', 319 is 63), or the byte is
  read as a double (pcm16: MAP `N5.pcm16-byte-raises`, whose tag values I
  recomputed from the C arithmetic). `f64_to_bytes` returns "8 byte ints"
  (§6), so its kind changes from float to int. An int argument converts to
  the nearest double first (C9, Q2): `2^53+1` gives the bits of
  9007199254740992, `[67, 64, 0, 0, 0, 0, 0, 0]`. `inflate`'s output bytes
  are ints (C8, Q1): `[[104, 105], "int"]`, asserted on the zlib profile.
- `buf_to_pcm16le` (Q7 bounded): out-of-range samples clamp to [-1, 1], then
  round half away from zero. That is "today's behaviour" per §6, so the clamp
  does not change. Hand-derived bytes for `[0.5, 2.5, -3]`:
  `[0, 64, 255, 127, 1, 128]`. Its `changes_vs_pre: yes` comes from the N5 window
  (Q-PCM16OUT).
- `gather`: each index follows N5, from a buffer (MAP
  `N5.gather-index-fraction-raises`) or from a list. "Returns elements
  unchanged", so the list path keeps an int element an int (today
  `make_num(cell)` makes it a float). The buffer path returns a float buffer.
- `scatter_add`: indices go through the N5 index reader, so `value` replaces
  today's `index_range` for 1.5 (§6 note). The accumulation is float.
- `numerical_grad_rows/_cols`, `sgd_update_rows/_cols`: row and column indices
  are ints (§6 notes), so N5 applies. The gradients and updates are floats.
  Hand-derived: d(q[1][0]^2)/dq[1][0] at 3 with eps 0.5 is exactly
  (12.25 - 6.25) / 1 = 6.
- Model rows (`eigen_model_load model_load_weights eigen_generate
  eigen_eval_loss native_train_step_builtin`, server profile): each probe writes
  a constant-weight v2 model (the shape of `tests/gen_tiny_model.eigs`) and a
  child script, runs the child with `exec_capture of [exe_path of null, child]`,
  and prints only the child's `R16|` lines. The loader prints its file path on
  stdout, and the path differs each run. Token ids and `max_tokens` follow N5,
  and generated ids are ints (indices). `generate_response` has no stop token,
  so `max_tokens` 4 yields exactly 4 ids. The loss is a float, and the training
  status is JSON text. `eigen_model_load`'s own numbers are internal, so its
  row only pins the loaded config.

## Per-row derivation, round f (20 rows; R1.6f)
- Store handles (`store_open store_close store_collections store_count
  store_drop`): `store_open` returns a handle dict with int id/gen fields. A
  forged handle whose `_store_id` is `id + 0.5` raises `value`; today the
  `(int)` cast resolves it to the real store and closes, counts or drops it.
  `id + 0.0` converts. `store_count` returns a count (int). After a close, the
  handle raises `value`, as BUILTINS.md documents.
- `shared_delete`, `shared_size` (server profile): a removed count and an entry
  count, so ints. Registration sets `eigs_http_active` on the main thread
  (ext_http.c:1950-1958), so the shared store works without serving.
- `http_route`, `http_route_authed`, `http_static` (server profile): numbers
  reach them only through `value_to_string` (N6, R1.7), so the registration
  answers do not change.
- `http_post` (B6, server profile): headers JSON `{"X-Number":
  9007199254740993}` and the string body `ping`, posted to R1.6a's loopback
  capture fixture, which answers with the `X-Number` value it received. The
  JSON decoder gives ints at R1.6, so the header is exactly
  `9007199254740993`: `["9007199254740993", "str"]`. The first probe put the
  number in the body slot, which `ext_http.c:717` ignores. See "B6 capture
  fixture".
- `http_early_bind`, `http_serve` (server profile): the port follows N5. Each
  call runs in a child script under `exec_capture`'s timeout form, because
  `http_early_bind` prints its cwd on stdout and a valid `http_serve` serves
  forever. Only `R16|`-prefixed child lines are printed. `http_serve of 0.0`
  binds an ephemeral port and serves until the 3 s timeout, which returns -2.
  `0.5` raises `value` before binding (today it truncates to 0 and serves).
  The capability flag in each line separates the N5 `value` from the release
  profile's capability `value`. A port is N5, then 0..65535 (C6): 65536
  raises `value`, and 0 (ephemeral) is valid.
- `net_*` (server profile, loopback only): ports, socket handles and max bytes
  follow N5. A handle is a packed number, and `net_unpack`'s `(long long)`
  cast truncates `l + 0.5` to the real socket today. `net_send`'s byte values
  follow Q1 (300 and 65.5 raise; today they wrap to 44 and truncate to 65),
  and a raise sends nothing. Counts and ports are ints, and handles are ints
  (int-requiring results that are ids). `net_recv` returns a buffer, whose
  elements are floats. `net_listen of 65536` and `net_dial` to port 65536
  raise `value` (C6). `net_send` keeps `"hihi"` (C7): `ext_net.c` checks
  `g_has_error` at line 363, before the byte conversion at line 364 and not
  after it, so the R1.6f byte reader's raise must also stop the send, and the
  probe pins that.
- R1.6a-D2: on `pre` and the tag, a fractional handle or port truncates to a
  live socket, so the call answers. Those answers are a port (`net_port`, the
  OS's ephemeral choice: 39805 and 40863 on R1.6a's two matched builds) or a
  socket handle (`net_listen`, `net_dial`, `net_accept`: a handle-table slot
  plus a generation, which depend on the build's allocation order). Each such
  line prints a predicate now: `(net_port of (l + 0.5)) == pt`, `(... ) > 0`
  for a handle, and `(net_accept of ...) != null`. On the branch each call
  raises `value` first, so no `.branch` changes.

## Per-row derivation, round e (38 rows; R1.6e)
Every gfx probe opens a 64x48 window under `SDL_VIDEODRIVER=dummy` (the suite's
headless gfx condition), clears it, draws, and reads pixels back with
`gfx_read` before any present. Expected pixels are derived by hand from Q7
(§2.6) and from the source's tables (the 5x7 `font5x7` glyph for `T` is
`{0x1F,0x04,...}`, a full top row and a stem in column 2; the `gfx_fb` palette
is 0 white, 1 `0xAAAAAA`, 2 `0x555555`, 3 black).
- Geometry (Q7): `gfx_rect [-3e9, 0, 6e9, 4]` and `gfx_clip` with the same rect
  intersect to `[0, 0, 64, 4]`, the top band (the MAP `gate.N5.q7-readers`
  case); `gfx_line [-3e9, 5, 3e9, 5]` clips (Liang-Barsky) to the full row 5;
  `gfx_circle` of radius 3e9 and `gfx_rrect [-3e9, -3e9, 6e9, 6e9, 10]` cover
  the screen; `gfx_fb` of a 1x1 black texel at `[-3e9, -3e9]`, scale 6e9,
  covers the screen; `gfx_text` at scale 3e9 makes the `T`'s column-0, row-0
  square cover the screen. Today the `(int)` casts give INT_MIN and nothing is
  drawn (or the clip is ignored).
- A point outside the drawable area draws or reads nothing: `gfx_point` at x
  `-0.6` (today it truncates to 0 and draws column 0) and `gfx_read` of
  `[3e9, 0]` and `[-0.6, 0]`, which answer `null` (today `[0, 0, 0]`).
- Rounding half away from zero replaces truncation for continuous coordinates
  (Q1, Q4): a rect at x 20.5 with w 2 covers 21..22 (today 20..21); a point at
  10.6 lights 11 (today 10); `T` at x 0.6 starts at column 1 (today 0);
  `gfx_read [9.6, 10.4]` reads (10, 10) (today (9, 10)); `gfx_open
  [64.4, 47.6]` is 64x48 (today 64x47).
- Bounded colour (Q7): `[300, -20, 127.6]` clamps and rounds to
  `[255, 0, 128]` (today `(int)` then Uint8 wraps it to `[44, 236, 127]`). The
  probes cover `gfx_clear`, `gfx_rect`, `gfx_line`, `gfx_point`, `gfx_circle`,
  `gfx_rrect` and `gfx_text`.
- Magnitude (Q7): `gfx_open [3e9, ...]`, `gfx_delay 1e300`,
  `gfx_text_width ["abc", 3e9]` and `gfx_text_height 3e9` raise `value`. A
  measurement's scale rounds (`1.6` gives 2: widths 36 and 14 rather than
  today's 18 and 7). Bitmap metrics are `len * 6 * scale` and `7 * scale`.
- `gfx_text_width`, `gfx_text_height`, `gfx_ticks`, `gfx_read`: int results
  (pixel sizes, Uint32 ms, channel values). `gfx_ticks` prints only its kind,
  an ordering, and 0 before SDL loads.
- `gfx_poll` (B3): with the `events` hook, the three injected events decode
  with int fields: `[17, "int", -9, "int"]`, `[4, "int"]` and `[1, "int", 23,
  "int", 42, "int"]`. The empty-queue `null` case stays as the second case,
  `gfx_poll.empty`.
- `gfx_fb`: w and h follow N5 (`2.5` raises), and palette bytes follow the Q1
  byte reader (`300` and `1.5` raise; today they wrap or truncate and the
  frame is drawn).
- `ppu_render_frame`: the LCDC byte follows the Q1 byte reader, so `145.5` and
  `401` raise (today they read 145 and the frame renders). With LCD off the
  frame is blanked. With LCDC `0x91` and BGP `0xFF`, every pixel is
  `bgp[0] = 3`, derived by hand from the PPU loop (no tile data is needed).
- Audio devices (`SDL_AUDIODRIVER=dummy`): freq, channels, the pause flag,
  loop counts and channel numbers follow N5. Device ids and channel numbers
  are ints. A probe opens only the device it needs, because the mixer device
  blocks the stream device and SDL_mixer under the dummy driver. Counters the
  device drains in real time (`audio_queue_size`, `audio_stream_queued`) print
  their kind and a range only. `audio_music_play` plays a 52-byte WAV that the
  probe writes. `audio_volume`'s and `audio_stop`'s 1/0 answers are ints (C1).
- Delivered audio (B1, through the hooks; Q4 rounding is half away from zero):
  - `audio_stream_push [2.5, -3, 0.5]` delivers `[32767, -32767, 16384]`:
    clamp to [-1, 1], then round 0.5 x 32767 = 16383.5 to 16384. Today
    truncation gives 16383;
  - `audio_play [2.5, -3, 0.5, 0]` mixes `32767 -32767 16384 0` at volume 1;
  - `audio_play_loop [[0.5, -3], 2.0]` mixes `16384 -32767` twice, since loops
    2 is two plays in `audio_mix_callback`;
  - `audio_volume` of 9.0 clamps to the mixer's 4.0, on a looping `[0.1,
    -0.1]` clip: round(3276.7) = 3277, times 4 is 13108. Today 3276 x 4 is
    13104, and an unclamped 9.0 would give 29493;
  - `audio_music_volume` 300, -20 and 64.5 reach `Mix_VolumeMusic` as 128, 0
    and 65: clamp to 0..128, then round. Today 64.5 truncates to 64.
- Generators: samples are floats. The durations used (0.001 s, so 44.1
  samples at 44100 Hz) truncate and round to the same 44 samples. The sample
  count `dur * rate` stays R2.6's (B5), so at R1.6 the generators read `dur`
  through the magnitude reader only for validity; the rounding witness is in
  "R2.6 row list". `audio_sine`, `audio_saw`, `audio_square` and
  `audio_noise` carry `closed_in` main #1767 (their duration caps, A2).
  `audio_sweep`'s wave selector follows N5. `audio_envelope`'s attack and
  release are magnitudes, so `1e300` raises (today `(int)(t * rate)` is
  undefined and the call answers). `audio_gain` and `audio_mix` clamp to
  [-1, 1] (unchanged).

## ORACLE (Lua 5.4.9, `/tmp/r15-critic/lua-5.4.9/src/lua`)
Each `oracle/<b>.lua` is run as is; `oracle/<b>.lua.out` is its verbatim output.
Lua prints floats with `%.14g`, so values are compared by kind and value, never
by text (§10).

| row | Lua expression (file) | Lua output (verbatim, tab-separated) | agrees with `.branch` |
|---|---|---|---|
| abs | `math.abs(-9007199254740993)`, `math.abs(-2.5)`, `math.abs(math.mininteger)` with `math.type` | `9007199254740993 integer` / `2.5 float` / `-9223372036854775808 integer` | yes for 1-2; line 3 is the declared N4b divergence (Lua wraps, EigenScript raises `value`) |
| floor | `math.floor(9007199254740993)`, `(-2.5)`, `(1e300)` | `9007199254740993 integer` / `-3 integer` / `1e+300 float` | yes |
| ceil | `math.ceil(...)`, same arguments | `9007199254740993 integer` / `-2 integer` / `1e+300 float` | yes |
| min | `math.min(9007199254740993, 9007199254740994)`, `(3, 3.5)`, `(4, 3.5)`, `(7)`, `(3, 3.0)`, `(3.0, 3)` | `9007199254740993 integer` / `3 integer` / `3.5 float` / `7 integer` / `3 integer` / `3.0 float` | yes |
| max | `math.max(9007199254740993, 9007199254740992)`, `(3, 2.5)`, `(2, 2.5)`, `(7)`, `(3, 3.0)`, `(3.0, 3)` | `9007199254740993 integer` / `3 integer` / `2.5 float` / `7 integer` / `3 integer` / `3.0 float` | yes |
| len | `#{1, 2}`, `#"hello"` | `2 integer` / `5 integer` | yes |
| ord | `string.byte("A")`, `select("#", string.byte(""))` | `65 integer` / `0` | yes for "A"; `""` gives no value in Lua and EigenScript's documented `-1` (BUILTINS.md) |
| random_int | `math.randomseed(7)`; `math.random(5, 5)`; `(9007199254740993, 9007199254740993)`; `pcall(math.random, 1.5, 3)`; `math.random(2.0, 2.0)` | `5 integer` / `9007199254740993 integer` / `false bad argument #1 to 'math.random' (number has no integer representation)` / `2 integer` | yes (the raise is `value`) |
| seed_random | seeds 2^53+1 vs 2^53 then `math.random(0, 1000000)`; `pcall(math.randomseed, 1.5)`; `42.0` vs `42` | `seeds-2^53+1-and-2^53-differ true` / `false bad argument #1 to 'math.randomseed' (number has no integer representation)` / `integral-float-seed true` | yes (the values differ by RNG; kinds and verdicts agree) |
| num | `tonumber(s)` for the probe's 25 strings (`oracle/num.lua`) | see `oracle/num.lua.out`: ints for `3`, `9007199254740993`, ` 12 `, `+5`, `-0x10` (-16), `0x1F`, `0X1f`, `0xFFFFFFFFFFFFFFFF` (-1), `-9223372036854775808`; floats for `3.0`, `9223372036854775808`, `.5`, `1.`, `1e5`; `nil` for `12abc`, `0b101`, `0o17`, `1_000`, `""`, `" "`, `inf`, `nan`, `1.2.3`, `0x`; `16.0 float` for `0x1p4` | yes; `nil` maps to a raise; `0x1p4` is the declared divergence (N10) |
| acos, asin, atan, cos, sin, tan | `math.<f>(v)` with `math.type` and `%.17g` (`oracle/<f>.lua`) | e.g. `acos`: `0.0 float 0` / `1.5707963267949 float 1.5707963267948966` | yes: every `%.17g` value equals the `.branch` double |
| atan2 | `math.atan(1, 1)`, `math.atan(0, -1)` | `0.78539816339745 float 0.78539816339744828` / `3.1415926535898 float 3.1415926535897931` | yes |
| pi | `math.pi` | `3.1415926535898 float 3.1415926535897931` | yes |
| random | `math.randomseed(7)`; `math.random()` | `float true true` | yes |
| bit_and, bit_or, bit_xor, bit_not, bit_shl, bit_shr | the probe's operands with `& \| ~ <<  >>` (`oracle/bit_*.lua`) | e.g. `9007199254740993 integer` / `false ...: number has no integer representation` / `2 integer`; `1 << 63` = `-9223372036854775808`, `1 << 64` = `0`, `8 << -1` = `4`, `-1 >> 1` = `9223372036854775807`, `1 >> -1` = `2` | yes, all lines |
| char_at | `string.sub("hello", i+1, i+1)` (0-based to 1-based) | `e` / `false bad argument #2 to 'string.sub' (number has no integer representation)` / `e o` | yes |
| chr | `string.char(65)`, `(65.5)`, `(256)`, `(66.0)` | `A` / `false ... (number has no integer representation)` / `false ... (value out of range)` / `B` | yes |
| substr | `string.sub("hello", start+1, start+len)` | `el` / `false bad argument #2 ...` / `false bad argument #3 ...` / `el` | yes |
| list_insert_at | `table.insert(t, i+1, v)` | `1,9,2,3` / `false bad argument #2 to 'table.insert' (number has no integer representation)` / `7,1,9,2,3` | yes |
| list_remove_at | `table.remove(t, i+1)` | `1,3,4` / `false bad argument #2 to 'table.remove' (number has no integer representation)` / `3,4` | yes |
| divide, pow | `7 / 2`, `6 / 3`, `2 ^ 10`, `2 ^ 0.5` with `%.17g` | `3.5 float 3.5` / `2.0 float 2` / `1024.0 float 1024` / `1.4142135623731 float 1.4142135623730951` | yes |
| sqrt, exp, log | `math.sqrt(4)`, `(2)`; `math.exp(0)`, `(1)`; `math.log(1)`, `(8)` | `2.0 float 2` / `1.4142135623731 float 1.4142135623730951`; `1.0 float 1` / `2.718281828459 float 2.7182818284590451`; `0.0 float 0` / `2.0794415416798 float 2.0794415416798357` | yes |
| str_from_bytes | `string.char(72, 105)`, `(65.5)`, `(328)`, `(72.0, 105.0)` | `Hi` / `false ... (number has no integer representation)` / `false ... (value out of range)` / `Hi` | yes |

## QUESTIONS (all ruled 2026-10-20 in `RULINGS.md`)
| question | ruling | applied in |
|---|---|---|
| Q-HIST: LOSS rows closed before R1.6 | A2: `closed_in` R1.2/R1.3, checked as `.pre == .branch` | `abs json_build json_encode sort sort_by` |
| Q-R17: the writers' loss is R1.7's | agreed: the decoders change at R1.6; the writers' float loss is R1.7 | no change |
| Q-DB253: the db 2^53 raise | agreed: exact int64; `db_check_exact_int`'s raise is deleted with its reason | no change (the db `.branch` files assumed it) |
| Q-HEX | agreed: exact digits; negatives raise | `hex` (adds `hex of -1`) |
| Q-SIGNEXT | agreed: an exact int from the existing operation; R1.6b-D1 (#1894): the subtraction is checked int64 arithmetic, so a result below INT64_MIN raises `value` | `sign_extend` (adds the overflow case) |
| Q-CAP: rows the release profile cannot observe | A3: the `profile` column and matched builds | the 25 non-release rows |
| Q-CLOCK | B2: the injected clock | `monotonic_ns` |
| Q-ALREADY: int-requiring rows exact before R1.6 | A2: `closed_in` R1.5 (`bit_*`) and main (`chr`, `dispatch`) | 8 rows |
| Q-STREAMOPEN | agreed: a fraction raises `value`; an integral count outside 1..10,000,000 keeps `limit` | `stream_open` (adds the count 0) |
| Q-FLAGKIND | C1: 1/0 status results are ints | `record_history task_detach audio_volume audio_stop spawn` |
| Q-SANDBOX | agreed: a catchable `value` | no change |
| Q-RECVTIMEOUT | C5: the one-year cap is removed; past LONG_MAX ms raises | `recv_timeout` |
| `proc_read_buf` has no reachable bytes | A5, C10: a stdin `Hi` case | `proc_read_buf.hi` |
| Q-WINDOWS | agreed: N5 for every offset and count | no change |
| Q-PCM16OUT | agreed: the clamp is unchanged; the change comes through the window | no change |
| `inflate`'s output kind; `f64_to_bytes` above 2^53 | C8; C9 | `inflate`; `f64_to_bytes` |
| Q-NETSEND-R26 | C7: keep `"hihi"`; the byte reader's raise must stop the send | no change (the probe pins it) |
| Q-HTTPPORT | C6: N5, then 0..65535; 65536 raises; 0 is valid | `http_serve http_early_bind net_listen net_dial` |
| `http_post` header values | B6: headers JSON plus a string body, and a capture fixture | `http_post` |
| Q-AUDIO-HIDDEN | B1: the hooks assert the delivered PCM or volume | `audio_stream_push audio_play audio_play_loop audio_volume audio_music_volume` |
| Q-GEN-1767 | A2: `closed_in` main #1767; B5: `dur * rate` stays R2.6 | the four generators; "R2.6 row list" |
| Q-GFXPOLL | B3: injected events; the empty-queue case stays | `gfx_poll`, `gfx_poll.empty` |
| Q-TEXT-SCALE | agreed: geometry | no change |
| Q-GFX-ENV | agreed: the declared environment | no change |
| the LIST arms of `add`/`subtract`/`multiply` | C4: elementwise through the scalar arm | `add subtract multiply` |
| `sum of []` | C2: the int 0 | `sum` |
| min/max int/float ties | agreed: the first argument wins, kind included | `min max` |
| empty `min`/`max` | R1.6b-D2 (#1895): raises `value` in both call forms | `min max` (add `of []` and `of ([])`) |
| `num of "-9223372036854775808"` | agreed: the int INT64_MIN | `num` |
| integer text beyond int64 in the scanners | C3: raises `value`, naming the token | `scan_ints scan_int_tokens` |
| the kind of a spawn handle's `done` | C1: an int (it is numeric) | `spawn` |
| the store `3.0` round trip | agreed: transitional between R1.6 and R1.7; the R1.6f commit says so | no probe (R1.6f's commit message) |

No new question arose in this round. For C10, §6's `proc_read_buf` row
("bytes stored as floats") and Q2 (buffer storage is f64) agree on the element
kind: float.

## Vacuity guard (rulings A1, A2)
§9.4's rule ("every LOSS, int-requiring and Q7 row has `changes: yes`") is
checked against `.pre` (`changes_vs_pre`), on every row without `closed_in`.
`make_table.py` prints `guard: guarded=139 yes=106 closed_in=17
pending_profile=16 vacuous=0`.
- `closed_in` (17 rows), one reason per row. Each closure is checked: every
  case of the row has `.pre == .branch`, and its probe still pins exactness
  above 2^53 or the fraction raise:
  - R1.2/R1.3: `abs json_build json_encode sort sort_by`;
  - R1.5: `bit_and bit_not bit_or bit_shl bit_shr bit_xor`;
  - main (already exactness-checked): `chr dispatch`;
  - main #1767 (the duration caps): `audio_sine audio_saw audio_square
    audio_noise`.
- Pending: the 16 guarded non-release rows. `make_table.py --final` checks
  them after R1.6a's matched recordings.
- Three rows change through a class other than their Q7 one:
  `buf_to_pcm16le` (Q-PCM16OUT: the clamp is unchanged, and the change comes
  through the window), `audio_sweep` (B5: through its wave selector) and
  `audio_volume`. Its gain already clamps to [0, 4] today, and the `mix` hook
  now pins that clamp at the boundary (an unclamped 9.0 would mix 29493). The
  row changes through its N5 channel, its int answer (C1) and the rounding of
  its clip.
- The former partial witnesses now observe the row's own effect:
  `audio_stream_push audio_play audio_play_loop audio_music_volume` (B1: the
  delivered PCM or volume), `monotonic_ns` (B2: the digits), `gfx_poll` (B3:
  the event fields) and `proc_read_buf` (A5: the bytes).

## R2.6 row list (ruling B5)
Witnesses that belong to R2.6, not to R1.6:
- `audio_sine`, `audio_saw`, `audio_square`, `audio_noise`: the sample count
  `dur * rate` rounds instead of truncating. At 44100 Hz, 0.00101 s is 44.541
  samples: 45 after R2.6, and 44 at R1.6 and today. The critic's executed
  `enhanced_audio.eigs` gives 44, 44 and 45 samples on `pre` for 0.001,
  0.00101 and 0.001031746031746032 s; rounding gives 44, 45 and 46. At R1.6
  the generators read `dur` through the magnitude reader only for validity
  (finite, and within what the call can honour).

## B6 capture fixture (server profile; R1.6a builds it)
The `http_post` probe posts to `R16_HTTP_CAPTURE_URL` with headers JSON
`{"X-Number": 9007199254740993}` and the string body `ping`. `http_post`
turns each header value into text with `value_to_string`
(`builtin_http_post`, `ext_http.c`), so the header carries whatever number the
JSON decoder produced. R1.6a's fixture:
- listens on 127.0.0.1, on an ephemeral port, before the probe starts; the
  gate exports `R16_HTTP_CAPTURE_URL=http://127.0.0.1:<port>/capture`;
- accepts ONE request, and reads the request line and the headers up to the
  blank line, then the body by `Content-Length`;
- answers `200 OK` with a body that is exactly the received `X-Number` value
  (the bytes after `X-Number:` and optional spaces, up to CR LF), or `MISSING`
  when that header is absent, and then closes;
- keeps the full request in a log, which the gate prints on failure.

The `.branch` is `["9007199254740993", "str"]`. On `pre` and on the tag, the
JSON decoder gives the double 2^53, so the expected `.pre` is
`["9007199254740992", "str"]`. That is derived from the code; R1.6a records
it. Without the fixture the URL is empty, `http_post` answers `""`, and the
row fails visibly.

## R1.6a handoff (assigned by the rulings; not done in this bar)
- Move the shim to its repo target, `tests/phase2/observation_hooks.c` (A4),
  and point `run_probes.sh` at it.
- Record the 25 non-release rows on matched builds (A3): `make server` and
  `make zlib` builds of `4ac31e67` and v0.46.0, and `make server-db` builds of
  both with a PostgreSQL (CI's `database-worker` job, or any host with one).
  Then `make_table.py --final` must exit 0. The profile witnesses' `profile-ok`
  path has not run here, because no profile build exists; if a witness is
  wrong, the runner refuses the build (exit 2), so the failure is loud.
- Build the B6 capture fixture to the spec in "B6 capture fixture", and export
  `R16_HTTP_CAPTURE_URL`.
- Amend §9.4 with A1's measurement: `changes_vs_tag` is yes on 203 of the 207
  recorded rows (`make_table.py`'s `vs_tag` counts), because every probe calls
  `num_type` and the tag has none.
- Re-record `read_text`'s `.pre` (and `.tag`) on `1fd4422c` as its in-scope
  baseline (R1.6a-D1; #1668 changed it upstream of `4ac31e67`); its
  `changes_vs_pre` must then read `no`.
- Run `determinism.sh` on the matched builds too (with `PRE_BIN_<P>` and
  `TAG_BIN_<P>`), since the profile rows' records have never been recorded
  twice (R1.6a-D2's class).
- Add the gate that runs each case on the branch build (same environment,
  stdin fixture and shim) and compares stdout plus `rc=` with `.branch`.
- R1.6f's commit message states that the store `3.0` round trip is
  transitional between R1.6 and R1.7 (agreed answer).
- R1.6's builder confirms the `recv_timeout` limit (LONG_MAX ms, from
  `(long)ms`) against the final C types (C5: "the builder determines it from
  the C types"); the probe's 2^63 ms case assumes that limit.

## OUT OF SCOPE (found while deriving; not part of this bar)
Each item is filed or closed with a reason (the out-of-scope ledger, 2026-10-20):
- `seed_random` seeds `srand48`, which keeps only the low 32 bits. So seeds 1
  and 4294967297 give one stream on v0.46.0 and on 4ac31e67; Lua tells them
  apart. That contradicts §6's "a seed's range is all of int64". Filed:
  https://github.com/InauguralSystems/EigenScript/issues/1886
- §6's counts prose was stale at the then-current branch tip: "230 numeric", "51 other",
  "42 are LOSS" and "the six `bit_*`", against the table's and the
  inventory's 231, 52 and 36 (232 and 53 at `1fd4422c`). Filed:
  https://github.com/InauguralSystems/EigenScript/issues/1887
- `nearest_in_range_all` returns, for EACH entity, its nearest active entity
  (itself included, at distance 0). BUILTINS.md says it "returns ALL active
  entities within range". Filed:
  https://github.com/InauguralSystems/EigenScript/issues/1888
- `numerical_grad_rows/_cols` and `sgd_update_rows/_cols` silently skip an
  out-of-range row or column index, and the model builtins clamp an
  out-of-range token id. Filed:
  https://github.com/InauguralSystems/EigenScript/issues/1889
- Out-of-range gfx arguments are silently wrong today: colours wrap modulo
  256, `gfx_open of [3e9, 48]` answers `true`, and an off-window `gfx_read`
  answers `[0, 0, 0]`. Duplicate of
  https://github.com/InauguralSystems/EigenScript/issues/1763, which lists
  every one of these casts and routes them to #1758's Q7. R1.6e's readers fix
  them, and this bar's `gfx_*` rows pin each case.
- `recv_timeout` silently caps any `ms` above 3.15e10 at one year. Accepted
  into R1.6 and ruled C5: R1.6 removes the cap, and the probe pins the raise
  past LONG_MAX ms.
- The plan's R1.6c row says "`vm.c`'s one builtin", but no builtin is defined
  in `vm.c` (`vm.c:45-46` only declares `builtin_report` and
  `builtin_observe`). Accepted: this is drift in the orchestrator's brief, not
  in the repo; the design doc has no such sentence, and the round counts hold.
- `gfx_poll` has no headless witness in a plain `.eigs` probe. Accepted: not a
  repo gap. `make ui-sdl-input-gfx` (`tests/ui_sdl_input.c`, #1263) pushes
  real SDL events into an embedded state and reads them through `gfx_poll`,
  and `tests/ui_native_input.py` drives xdotool on Xvfb. Ruled B3: the shim's
  `events` hook gives this bar its witness.

## Corrections log (a `.branch` changed after its first observation)
- Every `.branch` predates the first recorded run of its probe: comparing each
  `.branch` mtime with the stderr file of the probe's first `.pre` run gave
  `branches=231 written-after-first-run=0`. The one later change follows.
- `gfx_fb`: an audit found that its probe lacked the int-requiring rule's
  second call (an integral float that converts). I added
  `gfx_fb of [fb, 2.0, 2.0, 0, 0, 1]` and the expected line
  `[[0, 0, 0], [255, 0, 0]]` to the probe and the `.branch` together. The line
  is derived as before: palette index 3 at (1, 1) is black, and (2, 0) keeps
  the red clear colour. No existing expected line changed. The new line equals
  `pre` (integral floats convert today), and the row's other lines still
  differ, so `changes: yes` (now `changes_vs_pre`) stands.
- **Fix round, 2026-10-20.** Each entry below changed a `.branch` (33 rows) or
  added a case (2), under the ruling it names. Every new expectation is
  derived from the design and the rulings, and was written before its case's
  first run in this round: comparing each changed `.branch` mtime with the
  case's first stderr file gave `changed_branches=35 recorded=29
  pending_never_run=6 written-at-or-after-first-run=0`. Against a snapshot of
  `builtins/` taken before the round, the changed `.branch` files and the
  changed probes are the same 35 cases. A hook case's `.branch` also ends with its
  `hook-loaded <hook>` line (the record format, A4).
  - B1 `audio_stream_push`: adds the delivered PCM, `SDL_QueueAudio 3: 32767
    -32767 16384`.
  - B1 `audio_play`: adds the mixed PCM, `mix: 32767 -32767 16384 0 0 0 0 0`.
  - B1 `audio_play_loop`: the clip `[2.5, -3]` becomes `[0.5, -3]`, because
    a clamped ±1 gives ±32767 under truncation and rounding alike. Adds `mix:
    16384 -32767 16384 -32767 0 0 0 0` (two plays).
  - B1, C1 `audio_volume`: the clip `[0.1, 0.2]` becomes `[0.1, -0.1]`. `1`
    becomes `[1, "int"]`, and the line `mix: 13108 -13108 ...` is added (the
    9.0 volume clamps to 4.0; 3277 x 4).
  - B1 `audio_music_volume`: `[300, 64.4]` becomes `[300, -20, 64.5]`, so
    `[null, null]` becomes `[null, null, null]`, and the volumes reaching
    `Mix_VolumeMusic` are 128, 0 and 65. (64.4 rounds and truncates to the
    same 64.)
  - B2 `monotonic_ns`: `["int", "int", true, true]` (two real reads) becomes
    `[9007199254740993, "int", true]` under the injected clock.
  - B3 `gfx_poll`: the probe reads three injected events: `[17, "int", -9,
    "int"]`, `[4, "int"]` and `[1, "int", 23, "int", 42, "int"]`. The old probe
    and its `.branch` (`["open", true]`, `null`) moved unchanged to the new
    case `gfx_poll.empty`.
  - B4 `store_update`, `store_delete`, `store_get`: add `["update-big-key",
    true, 2]`, `["delete-big-key", true, 0]` and `["key-2^53+1-found", true]`.
  - B6 `http_post`: `["", "str"]` (a refused port, with the number in the
    ignored body slot) becomes `["9007199254740993", "str"]` from the capture
    fixture.
  - A5, C10 `proc_read_buf.hi` (new case): `[2, 72, 105, "float", "float"]`,
    then `["eof-after", null]`.
  - C1 `record_history`: `[0, 1]` twice becomes `[0, "int", 1, "int"]` twice.
    `task_detach`: `1` becomes `[1, "int"]`. `audio_stop`: `[1, 0]` becomes
    `[1, "int", 0, "int"]`. `spawn`: `["int", "int"]` becomes `["int", "int",
    "int"]` (the kind of `done`).
  - C2 `sum`: adds `[0, "int"]` twice, for `sum of []` and `sum of ([])`.
  - C3 `scan_ints`, `scan_int_tokens`: each adds `["beyond-int64", "value",
    true]`, where `true` says the message names `9223372036854775808`.
  - C4 `add`, `subtract`, `multiply`: one int-list case each,
    `[[3, 9007199254740994], "int", "int"]`, `[[3, 9007199254740992], "int",
    "int"]` and `[[6, 9223372030926249001], "int", "int"]`.
  - C5 `recv_timeout`: adds `["timeout-past-int64", "value"]` for 2^63 ms,
    and queues a third value so that no binary blocks.
  - C6 `http_serve`, `http_early_bind`, `net_listen`, `net_dial`: each adds
    the port-65536 raise (`value`, with the capability flag `false`), and
    `http_serve` adds its child's `["serve_c-rc", 0]`.
  - C8 `inflate`: adds `[[104, 105], "int"]`.
  - C9 `f64_to_bytes`: adds `[67, 64, 0, 0, 0, 0, 0, 0]` for 2^53+1.
  - Agreed answers: `num` adds `["-9223372036854775808",
    -9223372036854775808, "int"]`; `min` and `max` add `[3, "int", 3,
    "float"]` (the ties `[3, 3.0]` and `[3.0, 3]`); `hex` adds `["negative",
    "value"]`; `stream_open` adds `["count-zero", "limit"]`.
- **R1.6a rulings, 2026-10-21.** Files changed in this round, by mtime after
  the previous round's last edit: the new case `read_text` (`.eigs`,
  `.branch`) and five probes (`net_port`, `net_listen`, `net_dial`,
  `net_accept`, `exec_capture`). No existing `.branch` changed.
  - R1.6a-D1 `read_text` (new row and case): `["missing", "io"]`,
    `["written", 10485761]`, `["over-cap", "io", true]`, `["over-cap-tail", "
    is 10485761 bytes, over the 10485760-byte cap"]`, `["hi", "str"]`, derived
    from §6 and `builtin_read_text` at `1fd4422c`. The `.branch` was written 37
    s before the probe's first run. One exploratory call ran on `pre` before
    it (`read_text` of a missing path answers `""` there, as the ruling says);
    the expectation comes from the `1fd4422c` code, which differs from that.
  - R1.6a-D2 `net_port`: `["fraction-answer", net_port of (l + 0.5)]` became
    `["fraction-answer", (net_port of (l + 0.5)) == pt]`. The `.branch` line
    on that path is the raise, `["handle-fraction", "value"]`, so its shape did
    not change and the `.branch` is unchanged.
  - R1.6a-D2, same class: `net_listen` (the 0.5 and 65536 lines), `net_dial`
    (the `pt + 0.5` and 65536 lines) and `net_accept` (the `l + 0.5` line)
    printed socket handles on `pre`; they print `> 0` or `!= null` now.
    `exec_capture`'s `1e300` line printed a timing-raced exit code on `pre`;
    it prints `type of` the answer now. No `.branch` line changed.
- **R1.6b rulings, 2026-10-21** (frozen-bar amendments, listed with their
  SHA-256 in `tests/phase2/builtins_changes.md`). Each new case is appended
  after its probe's last line, so no existing line moves; the re-recorded
  `.pre` and `.tag` keep every earlier line byte for byte.
  - R1.6b-D1 `sign_extend`: adds `["overflow", "value"]` for
    `sign_extend of [-9223372036854775553, 8]` (the subtraction is checked
    int64 arithmetic; INT64_MIN - 1 raises). `pre` and the tag print
    `["overflow-answer", -9.223372036854776e+18]`.
  - R1.6b-D2 `min`, `max`: each adds `["empty", "value"]` (`of []`) and
    `["empty-list", "value"]` (`of ([])`). `pre` and the tag print
    `["empty-answer", 0]` and `["empty-list-answer", 0]`.

## Instrument notes
- Check machinery, in lines (first version -> fix round -> R1.6a rulings):
  `run_probes.sh` 46 -> 94 -> 94, `make_table.py` 98 -> 212 -> 229 (the
  pinned `git archive` source), `builtins/_hooks/observation_hooks.c` new,
  159 (the critic's was 44), `builtins/_profiles/*.eigs` new, 37, `plants.sh`
  new, 132 -> 140, and `determinism.sh` new in this round, 28 (it replaces a
  scratch script, so R1.6a can run the same check on its matched builds).
  Total 144 -> 634 -> 687. At that R1.6a import, `rowmeta.tsv` and
  `cases.tsv` were declarations of 232 and 234 lines plus headers;
  R1.6g's current populations are 310 and 312.
- `run_probes.sh`:
  - The first version wrote stdout through a relative path after its `cd`,
    so every `.pre` and `.tag` held only `rc=0`. It writes an absolute path,
    deletes the old record before each run, and fails (exit 2) on an empty
    stdout with rc 0. Before the deletion was added, the relative-path plant
    SURVIVED, because the stale file passed the size test.
  - Added in the fix round: cases from `cases.tsv` and profiles from
    `rowmeta.tsv`; the shim, compiled per run and preloaded for hook cases,
    with the `hook-loaded` check; the stdin fixture; `PENDING-PROFILE` and the
    profile witnesses; the `DATABASE_URL` and `R16_HTTP_CAPTURE_URL`
    pass-through; rc 124 as a named failure; `ulimit -v 1500000`.
  - Found while recording: the new `recv_timeout` case at first blocked `pre`
    and the tag for 60 s (rc 124). The old binaries answer the two earlier
    raise cases by consuming the two queued values, so the third read waited
    on an empty channel. A third queued value fixed the probe, and the runner
    now fails on rc 124.
  - The first hook recordings held two `hook-loaded` lines, because
    `LD_PRELOAD` was set before `timeout`, which loaded the shim too. It is
    set after `timeout` now, and `make_table.py` requires exactly one line.
- `plants.sh` runs every plant below in a fresh scratch copy of the bar (and
  of the tree's `docs/design` and `src`), and requires each check's named FAIL
  line. Both baselines are clean first: `make_table.py` with no FAIL, and the
  runner on `abs audio_stream_push gfx_poll.empty proc_read_buf.hi inflate`.
  A mutation that does not apply counts as a failure: the first run caught
  two (an unanchored `hex` also matched `random_hex`, and `len` matched
  `buf_len`). Result after the R1.6a rulings: `plants examined=37 table=37
  red=37 survived=0`, exit 0 (35 in the fix round, plus P28 and T1).
  - table checks: P1 a §6 row deleted; P2 a §6 class edited; P3 a stale §6
    row; P4 an empty table (`examined=0 table=0`); P5 a second definition of
    `builtin_abs`; P6 an inventory class edited; P7 a q7 column dropped; P8 a
    missing `.tag`; P9 a stray probe; P10 `closed_in` on `hex`, whose `.pre`
    differs from its `.branch` (the orchestrator's plant); P11 an edited
    `.branch` on a `closed_in` row; P12 `closed_in` removed from `abs`
    (vacuous); P13 `hex.branch` made equal to `hex.pre` (vacuous); P14 a hook
    record without its `hook-loaded` line; P15 a `hook-loaded` line on a
    non-hook case; P16 a capability transcript as `inflate.pre`; P17
    `PENDING-PROFILE` on a release row; P18 `--final` with pending records;
    P19 a `rowmeta.tsv` row deleted; P20 an unknown profile; P21 a case hook
    that the shim lacks; P22 a shim hook renamed; P23 the stdin fixture
    removed; P24 a stray file in `builtins/`; P25 `closed_in` on an unguarded
    row; P26 a profile witness removed; P27 a primary case removed; P28 the
    pre-#1841 revision (`EIGS_REV=4ac31e67`), which lacks `read_text`: `FAIL:
    in rowmeta.tsv, not in section 6: read_text`.
  - determinism check: T1 a printed time (`monotonic_ns`) appended to the
    `len` probe: `UNSTABLE len.pre` (R1.6a-D2's class).
  - runner and witness checks: R1 the relative output path; R2 a hook case
    run WITHOUT the shim (the orchestrator's plant): the runner prints
    `FAIL: audio_stream_push.pre ran without its hook pcm` and exits 2; R3 the
    same hookless recording, then `make_table.py`: `audio_stream_push.pre
    holds [], not one 'hook-loaded pcm' line`; R4 the `recv_timeout` probe
    without its third queued value (rc 124); R5 the release binary passed as
    the zlib build; R6 the stdin fixture missing; R7 and R8 the `silence`
    mutation, after which `audio_stream_push.pre` records `SDL_QueueAudio 3:
    0 0 0` and `audio_play.pre` records `["mixed", false]`, both unequal to
    the recorded `.pre`. (The critic's F1: an all-silence mutation passed the
    first `audio_stream_push` row.)
- Determinism, fix round: all 233 cases were recorded three times on both
  binaries, twice normally and once pinned to core 0 at `nice 19` (`taskset
  -c 0 nice -n 19`, load average about 2.3 from other jobs). `compared=466
  unstable=0`. The 50 pending records are among the 466 and are trivially
  stable. A fourth recording, after the last runner edit (an EXIT trap that
  removes the compiled shim), equals the pinned run: `run4-vs-run3
  compared=466 unstable=0`.
- `make_table.py --final` on today's records exits 1 with 50 FAIL lines, one
  per pending record (`FAIL: db_execute: .pre is PENDING-PROFILE db
  (--final)`, ...), as it must until R1.6a records the matched builds.
- R1.6a rulings round: `determinism.sh` over the 234 cases first gave
  `compared=468 records=468 unstable=1` (`UNSTABLE exec_capture.pre`; see
  round c), then `unstable=0` after the fix. The earlier rounds' four
  recordings had not shown it.

## COVERAGE (historical R1.6a import, before R1.6-S2)
The following counts and transcripts describe the population at `1fd4422c`.
They are retained as recorded, including the then-pending profile observations;
they are not current checker results. Sync #5's S2 addition makes the current
pre-N9 table 233 rows (c 77) and case files 235 each; R1.6g adds 77, as described above.
Population, both directions, at `1fd4422c`:
- §6's table equals the inventory's `## Builtins` list: 232 = 232, no name
  missing either way, and class/loss/q7 equal on every row.
- `rowmeta.tsv` equals the table (232 = 232), and each table row has its
  primary case in `cases.tsv`.
- The probe files equal `cases.tsv`: `.eigs .branch .pre .tag` are 234 each,
  none missing and none extra, and `builtins/` holds nothing else except the
  three fixture directories.
- The shim's hooks equal the cases' hooks (5 = 5: `pcm mix mixvol clock
  events`); `_stdin` equals the cases' stdin (1 = 1); `_profiles` equals the
  non-release profiles (3 = 3).
- `make_table.py` prints `source=/home/jon/src/InauguralSystems/EigenScriptEcosystem/EigenScript@1fd4422c`
  and `examined=232 section6=232 inventory=232 rowmeta=232 cases=234`, and
  exits 0.
- The Lua oracle set equals the rows whose note names a Lua counterpart, plus
  `num`: 36 = 36 (`read_text`'s note names none). `min`, `max` and `num`
  gained the tie and INT64_MIN cases.

Columns: `closed_in` on 17 rows; profile release 207, server 21, db 3, zlib
1; hooks on 7 cases (7 rows); one stdin case.

| round | rows | done | changes_vs_pre yes / no / pending-profile | changes_vs_tag yes / no / pending-profile |
|---|---|---|---|---|
| b | 45 | 45 | 36 / 5 / 4 | 41 / 0 / 4 |
| c | 76 | 76 | 40 / 36 / 0 | 72 / 4 / 0 |
| d | 53 | 53 | 27 / 20 / 6 | 47 / 0 / 6 |
| e | 38 | 38 | 32 / 6 / 0 | 38 / 0 / 0 |
| f | 20 | 20 | 5 / 0 / 15 | 5 / 0 / 15 |
| total | 232 | 232 | 140 / 67 / 25 | 203 / 4 / 25 |

`read_text`'s `yes` in round c is against a `.pre` that predates #1841; see
its derivation.

## R1.6g N9 addition

R1.6g-D1 and #1758 comment 6304880619 add 77 release-profile rows, sourced
from the N9 definitions in builtins_int.c: 76 int-requiring and fround
float-producing. The live table has 310 rows and 312 cases (release 285,
server 21, db 3, zlib 1). All new branches were captured from Rust std plus
the explicit operand/shape rulings BEFORE builtins_int.c existed; their exact
SHA-256 amendments are in builtins_changes.md. Existing frozen branches remain
unchanged. oracle/n9.rs, its input TSVs and verbatim stdout capture the Rust
arithmetic; the supplemental test_n9_contract pins double rounding and exact
zero-divisor messages. The one-time broader grid stays in the round artifacts.
