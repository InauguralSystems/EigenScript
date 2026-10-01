# Issue #1184 verification evidence

The regression is exercised by `tests/test_arena_heap_edges.eigs`, including
an intentionally unclosed arena whose list retains a heap number through
thread detach. All commands below used the ASan/LSan build produced by
`make asan -j2` with `ASAN_OPTIONS=detect_leaks=1`.

## Pre-fix allocator leak (reproduced with the teardown order reverted)

Command:

```sh
cd src
ASAN_OPTIONS=detect_leaks=1 ./eigenscript ../tests/test_arena_heap_edges.eigs
```

Relevant output and exit status:

```text
Tests: 3 | Pass: 3 | Fail: 0
All tests passed.
==5205==ERROR: LeakSanitizer: detected memory leaks
Direct leak of 72 byte(s) in 1 object(s) allocated from:
    #1 ... in xcalloc src/arena.c:58
SUMMARY: AddressSanitizer: 72 byte(s) leaked in 1 allocation(s).
RC=1
```

## Post-fix result

The same direct command at the fixed teardown order produced no sanitizer
diagnostic:

```text
Tests: 3 | Pass: 3 | Fail: 0
All tests passed.
RC=0
```

The strict suite lane also passed:

```sh
EIGS_SUITE_SECTIONS=14 ASAN_OPTIONS=detect_leaks=1 bash tests/run_all_tests.sh
```

```text
PASS: arena list releases heap children on reset (#1184)
RESULTS: 27/27 passed, 0 failed, 0 skipped
```

## Planted-fault ASan-lane failure

To prove the regression gate, the two teardown calls were temporarily changed
back to the faulty order (`eigs_thread_drain_caches(th)` before
`arena_destroy()`), the ASan target was rebuilt, and the section command above
was rerun. The source was then restored and rebuilt. The strict row rejected
the otherwise leak-only sanitizer exit:

```text
FAIL: arena list releases heap children on reset (#1184) (rc=1)
==13229==ERROR: LeakSanitizer: detected memory leaks
SUMMARY: AddressSanitizer: 72 byte(s) leaked in 1 allocation(s).
RESULTS: 24/27 passed, 3 failed, 0 skipped
RC=1
```
