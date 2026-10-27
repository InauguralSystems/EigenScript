# EigenCore-0 Lean reference frontend

This directory is **D1 step 1 of [issue #2018](https://github.com/InauguralSystems/EigenScript/issues/2018)**. It pins Lean 4.35.0 and the matching Batteries and Plausible revisions. From this directory:

```bash
lake build
../../tools/spec_lean_no_sorry.py
../../tools/spec_lean_axioms.py
../../tools/spec_lean_corpus.py
.lake/build/bin/eigs-ref --classify FILE
```

The current model contains the EigenCore-0 AST, subset classifier/parser, values, and the byte-compatible value printer. It models only the syntax listed in #2017: safe integers, strings, booleans, null, closures, the selected operators and calls, assignments, conditionals, loops, definitions, returns, and temporal readers. Unsupported syntax is rejected rather than recovered or reinterpreted.

Execution semantics, environments, fuel, nondeterministic oracles, tape records, and T1–T5 are intentionally **not** modeled in step 1. They arrive in later steps of #2018. `EigenCore.step1_sanity` exists solely to keep the axiom inventory non-empty until those theorems land.
