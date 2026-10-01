# Issue #1184 verification evidence

The regression corpus is `tests/test_arena_heap_edges.eigs`. Its first arena
window reconstructs the reported shape: a loop creates 200 promoted strings,
stores them in arena-allocated concat lists, and returns the final list across
the arena reset. The fixture's second window independently covers thread
detach ordering with one heap number.

All results below use `ASAN_OPTIONS=detect_leaks=1` and the binary produced by
`make asan -j2`. Exit statuses were captured immediately after each command.

## Unmodified main baseline

To measure the defect before applying the fix, commit `2bd607e` (the
unmodified PR base) was checked out in a detached worktree. Only the new
`.eigs` corpus input was copied into that tree; no source or build-script file
was changed. After building that tree, this command was run:

```sh
cd /tmp/eigs-1184-base/src
ASAN_OPTIONS=detect_leaks=1 ./eigenscript ../tests/test_arena_heap_edges.eigs
```

The 200 escaping strings account for the 200 indirect allocations and 200 of
the direct allocations below. The fixture's separate detach witness accounts
for the remaining 72-byte direct allocation:

```text
Tests: 3 | Pass: 3 | Fail: 0
All tests passed.
==5187==ERROR: LeakSanitizer: detected memory leaks
Direct leak of 14472 byte(s) in 201 object(s) allocated from:
    #1 ... in xcalloc src/arena.c:58
Indirect leak of 3400 byte(s) in 200 object(s) allocated from:
    #1 ... in xmalloc src/arena.c:51
SUMMARY: AddressSanitizer: 17872 byte(s) leaked in 401 allocation(s).
RC=1
```

This is the issue's reported approximately-200-string leak on unmodified main,
not a teardown-order-only fault.

## Post-fix result

With the arena-list ownership fix and detach ordering in place, the identical
direct command produced no sanitizer diagnostic:

```text
Tests: 3 | Pass: 3 | Fail: 0
All tests passed.
RC=0
```

The strict ordinary-suite row also passed:

```sh
EIGS_SUITE_SECTIONS=14 ASAN_OPTIONS=detect_leaks=1 bash tests/run_all_tests.sh
```

```text
PASS: arena list releases heap children on reset (#1184)
RESULTS: 27/27 passed, 0 failed, 0 skipped
RC=0
```

## Planted fault: revert only the arena-list fix

To validate that the corpus row gates the actual #1184 fix, a detached
worktree at the fixed commit was given a narrowly planted fault: only
`src/arena.c`, `src/eigenscript.c`, and `src/eigenscript.h` were restored from
`2bd607e`. This removes arena-list tracking and child release while retaining
the corrected teardown order in `src/state.c`, the strict suite behavior, and
the regression fixture. The planted-fault tree was rebuilt with `make asan
-j2` before running the same section command.

The suite rejected the original 200-string leak rather than merely detecting
the independent 72-byte teardown-order leak:

```text
FAIL: arena list releases heap children on reset (#1184) (rc=1)
==13569==ERROR: LeakSanitizer: detected memory leaks
Direct leak of 14472 byte(s) in 201 object(s) allocated from:
    #1 ... in xcalloc src/arena.c:58
Indirect leak of 3400 byte(s) in 200 object(s) allocated from:
    #1 ... in xmalloc src/arena.c:51
SUMMARY: AddressSanitizer: 17872 byte(s) leaked in 401 allocation(s).
RESULTS: 24/27 passed, 3 failed, 0 skipped
RC=1
```
