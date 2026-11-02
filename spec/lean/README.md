# EigenCore-0 Lean reference frontend

This directory contains the current EigenCore-0 model developed by [issue #2018](https://github.com/InauguralSystems/EigenScript/issues/2018). Steps 1–4 have landed: the frontend, executable semantics, oracle/tape model, parity corpus, and proof infrastructure are present. T1 (`record_replay`) and T3 (`record_transparent`) are proved; T2 is in progress.

From this directory:

```bash
lake build
../../tools/spec_lean_no_sorry.py
../../tools/spec_lean_axioms.py
../../tools/spec_lean_corpus.py
.lake/build/bin/eigs-ref --classify FILE
.lake/build/bin/eigs-ref --version "$(cat ../../VERSION)" --trace TAPE FILE
```

The model contains the EigenCore-0 AST, subset classifiers/parser, values, byte-compatible value printer, execution semantics, environments, fuel, nondeterministic oracles, and tape records. Unsupported syntax is rejected rather than recovered or reinterpreted.

Tape format `8` is a model constant, but the EigenScript runtime version is deliberately not. For record and replay, callers supply the version with `--version VERSION`; parity and differential tools obtain that value from the C binary under test using `eigenscript --version`. Lean-only fixtures use the non-release sentinel `0.0.0-model`.
