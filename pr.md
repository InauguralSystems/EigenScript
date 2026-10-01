# PR validation notes

- Red/green: `make tsan` followed by `TSAN_RUN_TIMEOUT=120 bash tests/test_tsan.sh`
  passes with the declared eight-fixture concurrency-shape inventory.
- Planted fault: restored the old `tsan_spawn_emitted_jit.eigs` one-expression
  `hot` body, which marks the chunk as a leaf accessor and bypasses JIT entry.
- Observed failure: the planted fixture made `tests/test_tsan.sh` report
  `FAIL: tsan_spawn_emitted_jit did not compile emitted JIT code` because its
  JIT footer was `compiled=0`; the corrected fixture reports `compiled=1` and
  passes the new non-vacuity assertion.
