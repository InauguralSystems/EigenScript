# Suite section golden files

Issue #1298 adopts section-level, separate stdout/stderr transcripts. The
existing section planner is the only section parser. Check or update exactly
one canonical section with:

```sh
bash tools/golden_sections.sh --check 1/15
bash tests/run_all_tests.sh --bless 1/15
```

The converted set is `99u`, `1/15`, `133`, `47/47`, and `42a`; unknown and
prefix spellings are errors. Ordinary suite runs compare every converted
section. Blessing stages both streams and replaces their checked-in files even
when the old inline assertions fail, which is precisely when a changed result
needs a reviewable diff and a deliberate re-bless. The transcript keeps stdout and stderr
separate, removes only planner chunk sentinels and `SECTION_TIME` telemetry,
and does not normalize arbitrary values or paths. PASS, FAIL, SKIP, child
status, and feature/environment branch evidence remain reviewable.

The adopted source inventory is reproduced by `bash tools/golden_sections.sh
--inventory`. It counts lines containing `grep`, `=~`, `diff`, or `cmp` in
each top-level runner chunk; it is not a performance or quality measurement.
The memo's starting result was `99u=40`, `1/15=26`, `133=21`, `47/47=21`, and
`42a=20`.

The fixtures record the minimal/default build's named feature branches without
normalizing them away.
