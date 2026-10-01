# Suite section golden files

Issue #1298 adopts section-level, separate stdout/stderr transcripts. The
existing section planner is the only section parser. Check or update exactly
one canonical section with:

```sh
bash tools/golden_sections.sh --check 1/15
bash tests/run_all_tests.sh --bless 1/15
```

This first self-contained conversion accepts exactly `1/15`; unknown and
prefix spellings are errors. It stages both streams and replaces their
checked-in files only after the emitted plan exits zero and reports a
non-vacuous, zero-failure verdict. The transcript keeps stdout and stderr
separate, removes only planner chunk sentinels and `SECTION_TIME` telemetry,
and does not normalize arbitrary values or paths. PASS, FAIL, SKIP, child
status, and feature/environment branch evidence remain reviewable.

The adopted source inventory is reproduced by `bash tools/golden_sections.sh
--inventory`. It counts lines containing `grep`, `=~`, `diff`, or `cmp` in
each top-level runner chunk; it is not a performance or quality measurement.
The memo's starting result was `99u=40`, `1/15=26`, `133=21`, `47/47=21`, and
`42a=20`.

## Still open

The memo did not select a cross-variant fixture naming scheme beyond requiring
reviewed variant keys or canonical branches. This first step preserves the
minimal-build branch; a later variant fixture must choose and review its key
without broad normalization. The remaining conversions are `99u`, `133`,
`47/47`, and `42a`; completing them also requires deciding that still-open
variant-key question where each section's feature branches demand it.
