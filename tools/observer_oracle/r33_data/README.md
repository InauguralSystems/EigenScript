# R33-1 instrument, fixed subject 54008422, addenda 1–3

This directory contains sealed inputs, labels and F0 identity evidence.
It contains no experiment U/BA/Z/K tables. The posting copy of MANIFEST.json
is byte-identical to the branch copy; the manifest excludes its own bytes.
Historical manifests and each pre-read seal remain in the delivery folder.
Every new fixture program is committed before the binary first reads it.

`populations/cal/{x1,x1e-3,x1e3}` is the 61-base calibration. The certified
`confirm-cal/{x1,x1e6}` and `confirm-hcal/{x1,x1e-3,x1e3,x1e6}` use matched
refusal exclusions. Attempt corpora are not automatically runnable sets.
`confirmation-counts.json` records exclusions, certifier messages and masks.
The BA guard uses original released H-cal32 and, where a label is absent,
the original released calibration72 plus H-cal. `judge-proof/` preserves the
once-only F0/F0 program proof. No bootstrap is copied or reimplemented.

The original 512 seeded sequences, four IEEE anchors and their programs are
unchanged. Separate site, surface and import fixtures reach the ruled sites.
Identity compares every declared key and the available scalar values/types,
with NaN equality and signed zeros handled explicitly. `quiet` has no query
at this commit. The port's claim is the default configuration, live bindings
and imported trajectories at the covered depths 4,6,10,64. Other live-window
or configuration changes require extended binary identity first.

`MUTANTS.json` has four disjoint lists: caught; equivalent under the declared
value-route read contract; outside the experiment's configuration, with its
premise; and not reachable by a program or legal tape at this commit. Error
catches are marked and counted. Trajectory import is in the source census. Empty-channel imports follow C's reconstruction gate and retained DH validation; separate routing probes verify both acceptance and refusal.
The enrolled isolated Python selftest checks actual saved binary readings,
staged derivations and certification output, plus handwritten step cases.
It needs only the standard library and leaves no bytecode cache in the tree.

All procedure code is present before measurement:

- `r33_run.single/subject_tables`: one subject's U, BA, Z and K tables, no choice.
- `r33_run.positive_control`: PRE1045's separate U_above >= 0.10 judgment.
- `r33_procedure.confirmation_judgment`: every confirmation criterion, using
  the printed four-decimal bound; -0.0200 fails. Receipts bind the actual
  build, local recipe F0, posted choice, manifest and released guard files.
- `r33_procedure.standard_first`: both confirmation results, C's BA advantage
  or U_all(STD)-U_all(C) >= 0.02, and conditional STD build permission.
- `r33_identity.confirmation_build`: declared build/commit/policy identity on
  all confirmation checkpoints and every queried scalar field.
- `r33_procedure.leave_one_out`: S1, N1 and reference-only tables; effects
  against F0 and total effect minus the three group effects.
- `r33_collect.collect_logged`: actual starts/completions/failures beside
  the seed1580 draw, with no duplicate arm/phase/group run.

For later use, from the repository root, set `R33_DATA` to
`tools/observer_oracle/r33_data/populations`. Collect F0 and PRE1045 first,
using `r33_collect.py --calibration --policy NAME --manifest MANIFEST
--data "$R33_DATA" --run-log RUNS.json --out READINGS.jsonl`. Write a single
subject's tables with `r33_run.py --single --subject NAME --manifest MANIFEST
--data "$R33_DATA" --readings READINGS.jsonl --out TABLE.json`; use
`--positive-control --subject PRE1045` for the separate control. A failed
control stops the experiment and prevents a calibration choice.

After the first measurement is posted, every remaining arm collector requires
`--first-measurement POSTED-FIRST-MEASUREMENT`; its exact sha256 appears in
every reading. The sweep takes that same file and refuses missing or different
provenance. Continue the remaining arms in their seed1580 draw order; the
ledger preserves the separate F0/PRE1045 prelude and the actual order too.
No machine proves human posting history.

`r33_binary.py` reports INC47 and ANCHOR outside the eleven policy names.
It calls frozen score.measure one row at a time and uses interp/straight.
Only capability skips, a row measurement raising, or the capability probe
raising can remove a reading. Tier splits, vacuity and unwitnessed JIT are
printed diagnostics. Missing one calibration scale removes all comparisons
for that base; missing Z/K is printed not read, with denominators. The fourth
manifest has exact score.py program commands for F0, INC47 and ANCHOR; whole
stdout/stderr/returncode are retained by r33_binary.run_old_method.

Confirmation requires `--choice POSTED-CHOICE.json`, containing the provisional
arm and sweep_tables_sha256. Every output carries the exact choice-file hash.
The chosen build matches the port before judgment. Bounds come only from the
frozen judge as a program: seed175833,10000 paired resamples, predicate-specific
released x1 sets, matched support and printed set-aside counts. STD-rel is
first judged on port U/Z/K; only an eligible standard-first plan permits its
build and bound. Raw judge text can be inspected; judgment needs its execution
receipt tied to the checked build and source files.

This instrument turn performs no experiment arm sweep or metric reduction.
Historical binaries receive handwritten windows only. No H1 input is generated
or read, no float twin is built, and no runtime or frozen oracle file changes.
