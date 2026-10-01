- Fixed concurrent shared-environment binding reads, observer bookkeeping, and
`__loop_iterations__` updates racing with replacement during worker loads.

Verification evidence:

- The TSan shared-binding fixture is paired with the seeded-race self-check;
  removing the owned reference from the shared lookup makes the planted fault
  report a race, while the production path and loop-counter fixture are clean.
- CodSpeed compared all 12 configured benchmarks with `d7398b5` and reported
  every target unchanged (no statistically significant delta).
- The deterministic instruction-count gate compares both directions: it rejects
  a greater-than-5% regression and also rejects a greater-than-5% improvement as
  a stale baseline. The PR-vs-base run passed, so neither side crossed 5%.
