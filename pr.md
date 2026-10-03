Adds eight declared thread lifecycle fixtures and documents the concurrency boundary for shared bindings, containers, and embedding APIs. Missing fixtures fail explicitly; worker exit follows the whole-state stop contract. The JIT row requires a named native-return diagnostic before module-level spawn.

This updates test coverage and documentation on current main, preserving the numeric normalization, descriptor/meta, hosted-profile, and state-stop implementations.

Validation: the seven reviewed ordinary inputs passed in release and ASan/UBSan with leak detection enabled. All sanitizer classifications were clean; worker exit returned5 with only its expected marker. The warm JIT row matched both owning runner predicates. Ten inert controls exercised the actual row checker: two positive/restored cases and eight expected rejections, including a missing fixture with all eight rows still examined. Bash5 and Bash3.2 parse checks passed. Contributor precheck:18 passed,0 failed,0 skipped; changed-selftest selection:0 rows out of38 enrolled. Local TSan and full-suite execution are unrun; required merge-group CI owns that coverage.

The close fixture does not prove a receiver was blocked, and the JIT fixture does not spawn from an active native caller. Calibration of the race detector against a newly declared row remains outstanding. These limitations keep the broader issue open.

Refs #1152
