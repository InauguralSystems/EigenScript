# Phase 2 R1.2 Value layer report

Implementation is committed in the isolated Git metadata used by this sandbox.
The full release, sanitizer, differential, and Phase 2 gates are green.

## Summary

All runtime and C-fixture aliases are migrated. Int consumers either have
their final reader arm or abort through the R1.3 unwired token. The number
bridge names remain. No `make_int` or int-producing opcode exists.

The sandbox makes the worktree common Git metadata read-only.
`/tmp/phase2-r12/git.sh` commits this worktree through isolated metadata;
`/tmp/phase2-r12/commits.bundle` contains the series from `46617422`.
The orchestrator can import with `git fetch /tmp/phase2-r12/commits.bundle
phase2-numbers` then `git reset --mixed FETCH_HEAD` (updates branch/index;
keeps working files). No push or main merge was performed.

## Commits

Counts are deprecated code-token inventory sites; the C fixtures are outside
that source inventory. The runtime total is 370; fixtures add 28.

| Round | Commit | File group | Sites |
|---|---|---|---:|
| R1.2d | `40ef2d84` | builtins.c | 85 |
| R1.2e | `10849e60` | builtins_tensor.c | 39 |
| R1.2f | `f28b94b0` | builtins_buf.c | 21 |
| R1.2g | `f9e711df` | builtins_host.c | 11 |
| R1.2h | `2fb9b5e2` | ext_gfx.c; audio policy | 56 |
| R1.2i | `7038423c` | container/value-slot reader arms | 0 |
| R1.2j | `3f1ff968` | jit.c, jit_smoke.c | 10 |
| R1.2k | `a0f66387` | chunk.c | 11 |
| R1.2l | `6640b3d5` | trace.c | 6 |
| R1.2m | `d5ff982c` | ext_store.c | 14 |
| R1.2n | `23262614` | eigs_embed.c | 4 |
| R1.2o | `1a2c4e44` | network/HTTP/database/model | 11 |
| R1.2p | `1822df24` | seven C test fixtures | 28 |
| R1.2q | `14471e2f` | vm.c | 97 |
| R1.2z | `ce66ede5` | alias definitions and final cleanup | 5 |
| R1.2r | `664c28d5` | P4 calibration templates (4 spellings) | 0 |
| R1.2s | `7e5662d0` | strict shape fingerprints (39 rows) | 0 |
| R1.2t | `95ce2fed` | bool renderer probe (1 expectation) | 0 |
| R1.2u | `0b6d9673` | sanitizer renderer note and inert timeout control | 0 |
| R1.2v | `7ade7cc7` | retire stale audio replay fixture ledger row | 0 |
| R1.2w | this report | verification report and handoff | 0 |

The reader follow-up additionally completes three int arms. Each group was
built while landing it, and all twenty implementation/tooling commits were
then independently rebuilt from their committed trees, serially. The report
commit also gets a default build. Logs are in `/tmp/phase2-r12/logs`.
Every commit carries the requested Claude trailers.

## Cost

Default release gcc -O2: GCC 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1),
Valgrind 3.26.0.codspeed7. Same DMG source/ROM and float program for every arm.
DMG export: `afd9bd52778cb0a8d1ab0473ec726aaae556fb90`, all 19 runtime
EigenScript/ROM files checked against its Git blobs, zero mismatches.
ROM SHA256: `8c5e12f41e0ba5bbca796944f92ffe6de28809198682c4332e38d1b3cf56fcf2`.
Float program SHA256: `67a1dc2f7db8ae581c58f0c781c21de3037e8f6b3d8a14f63ee5ee4e12e88fe6`.

Commands (all serial; `BINARY` is the independently built baseline or candidate):

Baseline binary: `/tmp/phase2-r12/baseline/src/eigenscript`; final candidate:
`/home/jon/src/wt/es-phase2/src/eigenscript`.

```sh
cd /tmp/phase2-r11-critic2/DMG
valgrind --tool=callgrind BINARY dmg.eigs roms/cpu_instrs.gb --cycles 500000
cd /tmp/phase2-r12
valgrind --tool=callgrind BINARY float_loop.eigs
EIGS_JIT_OFF=1 valgrind --tool=callgrind BINARY float_loop.eigs
```

The float loop runs 200,000 iterations. Source/build inputs for baseline
`46617422`, corpus oracle `0740af03`, and tag `v0.46.0` were checked against
150 Git blobs each, all with zero mismatches. No binary copies were used.

| Candidate | DMG 500K Ir | Float JIT Ir | Float interpreter Ir | Verdict |
|---|---:|---:|---:|---|
| baseline | 1,195,422,765 (+0.000000%) | 172,214,775 (+0.000000%) | 364,233,396 (+0.000000%) | baseline |
| vmrename | 1,195,320,483 (-0.008556%) | 172,216,054 (+0.000743%) | 364,235,224 (+0.000502%) | rename control |
| vm1 | 1,193,790,787 (-0.136519%) | 172,190,897 (-0.013865%) | 363,235,041 (-0.274098%) | rejected |
| vm2 | 1,193,798,401 (-0.135882%) | 172,191,010 (-0.013800%) | 363,235,208 (-0.274052%) | rejected |
| vm3 | 1,198,112,295 (+0.224986%) | 172,276,017 (+0.035561%) | 366,635,271 (+0.659433%) | rejected |
| vm4 | 1,199,112,814 (+0.308682%) | 172,276,017 (+0.035561%) | 366,635,271 (+0.659433%) | rejected |
| vm5 | 1,193,848,621 (-0.131681%) | 172,191,053 (-0.013775%) | 363,235,205 (-0.274053%) | rejected |
| vm6 | 1,200,113,794 (+0.392416%) | 172,306,061 (+0.053007%) | 367,835,319 (+0.988905%) | rejected |
| vm7 | 1,192,778,866 (-0.221169%) | 172,191,053 (-0.013775%) | 363,235,205 (-0.274053%) | rejected |
| vm8 | 1,194,010,544 (-0.118136%) | 172,191,053 (-0.013775%) | 363,235,205 (-0.274053%) | rejected |
| vm9 | 1,197,353,964 (+0.161549%) | 172,246,061 (+0.018167%) | 365,435,313 (+0.329985%) | rejected |
| vm10 | 1,193,839,891 (-0.132411%) | 172,191,053 (-0.013775%) | 363,235,205 (-0.274053%) | rejected |
| vm11 | 1,195,567,598 (+0.012116%) | 172,251,028 (+0.021051%) | 365,635,216 (+0.384869%) | rejected |
| vm12 | 1,193,533,071 (-0.158077%) | 172,190,961 (-0.013828%) | 363,235,170 (-0.274062%) | rejected |
| vm13 | 1,200,115,350 (+0.392546%) | 172,271,887 (+0.033163%) | 366,435,423 (+0.604565%) | rejected |
| vm14 | 1,197,839,406 (+0.202158%) | 172,276,879 (+0.036062%) | 366,635,321 (+0.659447%) | rejected |
| vm15 | 1,196,101,881 (+0.056810%) | 172,226,927 (+0.007056%) | 364,635,287 (+0.110339%) | rejected |
| vm16 | 1,197,057,949 (+0.136787%) | 172,226,919 (+0.007052%) | 364,635,279 (+0.110337%) | rejected |
| vm17 | 1,200,722,940 (+0.443372%) | 172,281,935 (+0.038998%) | 366,835,395 (+0.714377%) | rejected |
| vm18 | 1,194,707,923 (-0.059798%) | 172,216,927 (+0.001250%) | 364,235,286 (+0.000519%) | PASS |
| final | 1,194,717,491 (-0.058998%) | 172,216,927 (+0.001250%) | 364,235,286 (+0.000519%) | PASS |

Candidate 18 is the committed VM. Final reruns it after alias deletion and
restoring the old sort-key pair footprint. All three final deltas fit
±0.1%; stdout matches the baseline (DMG Time/Speed lines omitted).
The same callgrind brk-segment note appears on baseline and candidates;
each completed normally and reported its instruction count.

## Plants

- A `VAL_NUM` straggler in actual `builtin_usleep`: token gate `hits=1`;
  `make build/release/builtins.o` exits 2, undeclared identifier. Restored:
  `tokens: rounds<=R1.2 tokens=9 files=90 hits=0`.
- Remove the JSON encoder's `VAL_INT` arm: actual make exits 2 with
  `VAL_INT not handled in switch [-Werror=switch]`. All 17 Value-type
  switches enumerate all 12 types, with no default.
- Remove the boxed `slot_int_value` reader: actual slot gate exits 1 with
  five assertion failures and no build-warning witness. Restored:
  `examined=33 calls=165 matrix_cells=396 arm_rows=32 failures=0`.

- P4 calibration templates: both stale anchors had zero matches. After the
  four token spellings were migrated, all 13 build/static anchors match once.
  Official planted builder plus restricted corpus: control 2/2 same; mutant
  2/2 DIFF with `slot_from_int under EIGS_SMI_TRAP` observed.
- The strict renderer probe expected `1`, while a real capped X11 call to
  `gfx_open` prints `true`. Temporary `gfx_read` fault flips a red bit at
  (31,31): old checker exits 0 and skips pixels; fixed checker exits 1 with
  37/37 pixel rows differing. Restore exact C source and rebuild: 37/37
  identical, differing=0, final `OK`. Existing capture self-test: 88/88.

These mutations were temporary. No permanent check of these checks was added.
The inventory's legacy-matcher retirement was also compared before/after
on the real source: identical output. Its numeric builtin population stays
230/230.

A temporary C host injected `INT64_MAX` into try-wrapped addition/comparison
and both iterator snapshot implementations. All four aborted via the
R1.3 diagnostic/SIGABRT; paired floats returned 6, true, 42, 42 (8/8).

## Gates run

- Default `make`: gcc -O2 warnings=0.
- `make build/server-db/eigenscript CFLAGS='-Wall -Wextra -Werror=implicit-function-declaration -Werror=switch -Werror=comment -Werror=misleading-indentation -O0 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE'`:
  35/35 translation units, warnings=0.
- `make -B build/server-db/eigenscript CFLAGS='-Wall -Wextra -Werror=implicit-function-declaration -Werror=switch -Werror=comment -Werror=misleading-indentation -O1 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE'`:
  35/35 translation units, warnings=0.
- `make -B build/server-db/eigenscript` (default -O2):
  35/35 translation units, warnings=0.
- `make jit-smoke`: `JIT smoke: all cases passed.`
- `make embed-smoke`: `embed_smoke: OK`.
- `make smi-trap` in the `ce66ede5` archive (runtime C identical to final HEAD): built.
- `python3 tools/phase2_inventory.py --check`:
  `builtins: registered=311 numeric=230 classified=230 unclassified=0 stale=0`;
  `examined=2014 classified=2014 unclassified=0`; `phase2-inventory: PASS`.
- `bash tools/num_read_check.sh`:
  `num-read: examined=197 functions=81 allowlisted=81 violations=0 stale=0`;
  `num-read: PASS`.
- `env -u XAUTHORITY DISPLAY=:99 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy bash tools/phase2_check.sh /tmp/eigs-oracle-anchor/v0.46.0/src/eigenscript /home/jon/src/wt/es-phase2/src/eigenscript --through R1.2 --baseline /tmp/phase2-r12/main/src/eigenscript --smi-trap /tmp/phase2-r12/trap/src/eigenscript`:
  `phase2-check: PASS` (final checker artifact; 1351.09 seconds). Both corpus halves:
  `examined=441 same=435 same_nonzero=31 same_under_replay=4 nondet=1 diff=0 new=14 deleted=0 crash_both=0 timeout_both=1 conditioned=15 incomplete=0 undeclared=0 stale=0 ledger_refused=0 unpinned=1 capped=13`.
  Static int-source: `files=64 slot_from_int_defs=1 make_int_defs=0 calls=2 outside_writers=0 tag_homes=4/4 tag_spellings_outside=0`.
  Inventory: `examined=2014 classified=2014 unclassified=0`; freshness PASS;
  numeric builtins 230/230, dispositions 101 missing=0 stale=0, leaf 11/11.
  Slot gate: `examined=33 calls=165 matrix_cells=396 arm_rows=32 failures=0`.
- `make test`: `RESULTS: 4268/4268 passed, 0 failed, 9 skipped`; child-script ledger: `0 nonzero exits`.
- `env -u XAUTHORITY DISPLAY=:99 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
  bash tools/jit_diff.sh`:
  `jit_diff: OK (258 programs x {jit, osr} vs the interpreter; suite-env completed=15; OBS examined=630 denied=12; 30 arms adjudicated; 2 ledgered)`.
- `env -u XAUTHORITY DISPLAY=:99 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy bash tools/replay_diff.sh`:
  `replay_diff: OK (258 programs record+replay; 21 at the documented boundary; 0 nondeterministic; 1 ledgered)`.
- `env -u XAUTHORITY DISPLAY=:99 SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy
  bash tools/strict_differential.sh /tmp/phase2-r12/main/src/eigenscript`: `OK`.
  `identical-when-off: 156 differing: 0`; `unset-equals-strict: 156 / 156`;
  `raises-under-strict: 156 silent: 0 misattributed: 0`;
  `valid-input rows unchanged in all three modes: 252 / 252`.
  Typed controls: `declared=139 examined=139 passed=130 failed=0 unavailable=9 backend_absent=0 pending=0 unrun=0`.
  Pixels: `rows=37 (valid=14 wrong=23)`, `identical-when-off: 37 differing: 0`.
  `bash tools/strict_differential.sh --selftest`:
  `SHAPE_CAPTURE_SELFTEST: 88 passed, 0 failed, 88 declared`.
- `env -u XAUTHORITY DISPLAY=:99 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy make asan`:
  build exits 0. Then `(cd tests && env -u XAUTHORITY DISPLAY=:99 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh)`:
  `RESULTS: 4259/4259 passed, 0 failed, 8 skipped`;
  `PASS: every child .sh test ran to completion (0 nonzero exits)`.
  LeakSanitizer nonzero-exit tally: 0. `RLIMIT_AS` was unlimited throughout.
  The full suite took 2401.51 seconds; default `make` restored the release alias.
- `bash tools/suite_label_check.sh`:
  `PASS: 294 labelled echo lines; labels and tallies carry no hand-typed counts; no two sections share a label`.
- `python3 /tmp/phase2-r12/build_committed_trees.py`:
  `committed-tree-builds: examined=20 failures=0 target=build/server-db/eigenscript`.
  This covers every implementation/tooling commit; the report-only commit
  also receives its own default build.

The first full release suite caught stale strict shape fingerprints:
`RESULTS: 4266/4268 passed, 2 failed, 9 skipped` and
`SHAPE_CONTRACT: candidates=190 guarded=139 exempt=51 errors=39`.
All 39 exemption roots and helper closures were reviewed, including an
independent pass; only fingerprint fields changed. The checker now reports
`SHAPE_CONTRACT: candidates=190 guarded=139 exempt=51 errors=0`.
The final suite rerun uses those reviewed fingerprints and the repaired bool
renderer probe. Earlier runs' no-renderer notes came from that stale probe;
they were not evidence of an unavailable renderer.

The first `jit_diff` run inherited native X11 video and reported two extra
OBS rows (`ui_canvas_events.eigs`, `ui_dock.eigs`): JIT programs=258,
OBS examined=630 denied=12. The subsequent bounded X11 controls ran both
examples on candidate and `0740af03`, each in REF and OBS mode: all eight
were silent and timed out at 25 seconds (rc=124). The remaining gate train
uses explicit `SDL_VIDEODRIVER=dummy`; its full JIT verdict is green with
only the existing two ledger rows. The ledger is unchanged; the
initial failed run is retained as `logs/jit-diff-native-x11.log`.

The first unforced -O1/-O2 requests reused objects; those logs are retained
as `warnings-*-unforced.log` and are not evidence. The forced builds above
count actual compiler invocations.

An independent serial replay of all twenty committed trees builds the
server-db target from archived Git sources and exact successive Git blobs.
Intermediate trees retain the intentional deprecated-alias warnings; the
zero-warning requirement is measured on the final tree at all three levels.
The initial replay driver mistakenly required zero warnings on the first
intermediate tree: its actual make exited 0 with 340 warnings, all tagged
`-Wdeprecated-declarations`. That log is retained; the driver was narrowed
to successful builds and resumed from that successful first build.

The sanitizer renderer note shared the obsolete `sdl-present: 1` spelling.
Its corrected helper was run with an available software renderer and an
unavailable video driver: `15 passed, 0 failed` in each profile, respectively
no false note and an accurate renderer-unavailable note. `RLIMIT_AS` was
unlimited. The initial invalid renderer hint fell back to a working renderer;
that attempt was not counted as a negative control.

## Audio artifact

`strace` identified `test_audio.eigs` using SDL's disk backend: it opened
`sdlaudio.raw` four times from src/. The shared per-program policy now sets
`SDL_AUDIODRIVER=dummy`; the same test completed 53/53 plus mixer checks and
left no raw artifact even with an inherited disk-driver setting. The stray
file was removed.

The first full replay gate examined 258 programs and failed because
`test_audio.eigs` no longer diverged under the dummy-driver policy; no new
divergence was reported. The candidate and `0740af03` also matched on that
whole fixture when record and replay were separated by more than a second
(53/53 assertions plus mixer checks). Its noise assertions check length
and range, never sample values. The old CI log records a divergent row
without the underlying transcripts, so its cause remains unknown.

A separate minimal program that prints the noise samples still diverges
across seconds on both binaries, with no `audio_noise` entry in either tape:
`NOISE_FIDELITY_PREEXISTING: candidate=divergent main0740=divergent`.
Retiring the whole-fixture row tightens the current gate's expectation;
it does not claim the sample-level issue is fixed on this branch. The
remaining untaped mixer-queue timing is another reason any future CI failure
needs actual record/replay transcripts before a cause is assigned.

## Design deviations and caveats

The header-reader follow-up completes arms missed by the earlier R1.2a
commit. Seven C fixtures needed an extra group. R1.2z also changes the two
mutually exclusive sort-key fields to a union to retain the old 16-byte
allocation footprint. These implement the behaviour-preserving scope.
After alias deletion, two stale P4 injection templates, 39 reviewed source
fingerprints and the renderer probe needed follow-up groups. The latter
restores pixel coverage that had silently disappeared with bool printing.
The sanitizer helper’s matching diagnostic and inert false control were
corrected in a separate group; its pass/fail predicate is unchanged.
The no-longer-reproducing audio-fixture replay row was retired after the
full gate failed on its absence and a fresh review checked the scope;
the replacement full run passes with one remaining fidelity row.
Runtime C source after `ce66ede5` is byte-identical; these follow-ups change
checker fixtures and machinery only. After the temporary pixel fault was
restored, the release binary SHA256 is
`9fa86d63826b385a2e21133ee78b7a292ba6665c45e379e6106532874be509c2`,
whose prefix matches the pre-plant SHA256 recorded by the completed R1.2 gate.

The Git metadata import remains an orchestrator action because of sandbox
permissions. Raw logs and profiles are under /tmp/phase2-r12.
The global instructions mention failsoft_classify_check, which is absent
from this checkout; no result is claimed for that nonexistent command.

## Distillation

The cost table records why the VM's cold int refusals need measurement:
17 rejected source candidates changed the interpreter instruction count
beyond the round's tolerance despite leaving today's numeric semantics
unchanged. The existing performance skill already requires measuring this
effect; no new performance rule is needed.

The real pixel fault exposed an untested capability assumption: the renderer
was available while a bool-printing change made the checker skip its rows.
The repaired probes use the actual `true`/`false` output. The one-time red
and restored green above document that repair without a permanent check of
the check, following PRINCIPLES §5.

## Out of scope

R1.3 int producers, arithmetic and tape v7; R1.6 bridge deletion and builtin
semantic changes; main integration, CI upload, and pushing.
