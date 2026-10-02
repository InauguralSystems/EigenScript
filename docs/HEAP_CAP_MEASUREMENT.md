# Heap-cap accounting and decision record (#1319)

The production cap uses **live requested bytes**, net of releases. This follows
the project's bounded-by-default principle without treating long-running,
bounded allocation churn as a leak. The measurements and original decision
criteria are retained below for reproducibility.

Set `EIGS_MAX_HEAP=<bytes>` before starting the process. Crossing the ceiling
raises the catchable `heap_limit` error; uncaught, it exits normally with status
1 rather than aborting with status 134. The cap counts allocations routed
through the checked allocation API and does not count reserved thread stacks,
libc allocator arenas, memory mappings, dependency allocations, or the small
accounting table itself. The variable must be a positive base-10 byte count;
unset, zero, malformed, and overflowing values leave the cap disabled.

## Diagnostic instrument

Set `EIGS_ALLOC_STATS=1` to print one non-enforcing line at process exit:

    eigs-alloc-stats: cumulative=N live=N peak=N tracked=N

The counters cover successful `xmalloc`, `xcalloc`, `xstrdup`, and `xrealloc`
requests.  Cumulative counts initial requested bytes plus positive requested
growth from reallocations.  Live subtracts the recorded requested size when a
translation unit including `eigenscript.h` calls `free`; peak is the maximum
live value.  The counters are process-wide and mutex-protected for this
measurement phase. `EIGS_ALLOC_STATS` itself does not enforce a limit; setting
`EIGS_MAX_HEAP` enables the same accounting and changes cap crossings into the
error described above.

Known bypasses are direct `malloc`, `calloc`, `realloc`, and `strdup` calls;
allocations made inside libc or dependencies; memory mappings; thread stacks;
and the counter table's own libc allocations.  A release of an untracked
pointer is passed directly to libc and does not change live bytes.  The
interposer experiment below measures and attributes those gaps rather than
assuming this candidate chokepoint is complete.

## Workloads and actual commands

Record cumulative, peak-live, peak RSS, and the interposer totals for every
row.  Run from clean checkouts at the revisions recorded in the result table.

| Workload | Command to record before running |
| --- | --- |
| EigenScript corpus | `make && cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh` (repeat each program under the stats and interposer harnesses, rather than treating the suite shell as one process) |
| EigenScript microbench | `src/eigenscript tests/bench_perf.eigs` |
| DMG | command printed by `bash tools/consumer_acceptance.sh plan` for DMG |
| EigenMiniSat | command printed by `bash tools/consumer_acceptance.sh plan` for EigenMiniSat |
| Tidepool | command printed by `bash tools/consumer_acceptance.sh plan` for Tidepool |
| iLambdaAi | command printed by `bash tools/consumer_acceptance.sh plan` for iLambdaAi |

The plan output is authoritative for consumer revisions and CI commands; copy
those expanded commands into the result table before executing them.  Also
inventory the launch surfaces used by ouroboros, EigenOS, ext_http, the
iLambdaAi grader, `tools/jit_diff.sh`, and consumer acceptance.  Do not add an
environment, CLI, or embedding cap surface until that inventory is complete.

## Pre-recorded decision criteria

1. Disqualify cumulative enforcement if a real long-running consumer's
   cumulative requested bytes are orders of magnitude above its peak-live
   requested bytes.
2. Provisionally prefer live accounting only if requested peak-live tracks
   peak RSS closely enough to choose a useful cap and the interposer finds no
   unaccounted allocation class that invalidates enforcement.
3. Otherwise leave A versus B open and return the measurements to the owner;
   do not invent a threshold after seeing the results.
4. Fault-inject every allocation ordinal under ASan with leak detection and
   compare continued output with a clean run.  Choose a catchable error only
   if arbitrary failures leave state valid; otherwise choose a clean named
   exit.
5. A requested-byte design is acceptable only if a recorded cap-hit run
   replays at the same instruction.
6. Disabled overhead is decided by callgrind instruction counts (`Ir`), never
   wall time on a shared host: paired instrumented-versus-absent builds for DMG
   and `tests/bench_perf.eigs`.

These criteria implement “Best practice by default; depart only by
measurement,” while leaving the accounting model, scope, public surface,
failure semantics, and tape event open until the required table exists.

## Initial disabled-path measurement

The instrumentation change was paired against its base (`2bd607e`) with the
JIT disabled so callgrind measured the same interpreter work.  Three `Ir`
samples of `tests/bench_perf.eigs` were taken for each executable:

| Build | callgrind `Ir` samples | Median |
| --- | --- | ---: |
| base, counters absent | 297,040,942; 297,040,797; 297,045,632 | 297,040,942 |
| instrumented, `EIGS_ALLOC_STATS` unset | 299,460,472; 299,469,884; 299,460,355 | 299,460,472 |

The disabled instrument therefore adds 0.815% instructions on this microbench.
This is an attribution result, not a wall-time claim and not the required DMG
measurement.  It does not select A or B; the owner-required consumer table and
DMG instruction count remain open.
