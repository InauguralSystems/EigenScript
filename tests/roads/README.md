# The three-road oracle

`bash tools/road_diff.sh` enumerates every `*.eigs` directly in this directory.
Each fixture runs as main, through `load_file`, and through `import`, from two
working directories. Support files live under `assets/` and `eigs_modules/`, reached by the
fixtures; they are not independent oracle programs. Each run gets a private copy
of the fixture tree and an empty HOME. Children are bounded to 30 seconds.
The second cwd run invokes the entry point through a symlink in a third directory,
so main-program provenance must agree with import's canonical-file rule.

Every fixture declares `# road-bind: name ...` and has a nonempty `.out` file
containing its expected prints followed by `[name, 1, value]` snapshots for
present bindings, or `[name, 0]` for absent bindings. Presence is structural:
neither `null` nor the literal string `"<missing>"` can impersonate absence. The main
wrapper appends snapshots; the load wrapper snapshots after the call returns;
the import wrapper reads those names back from the namespace, checking `has_key`
before access. The golden decides whether a particular binding may be absent.
Functions can be checked through their results instead of printing identities.

Each driver captures `print`, `has_key`, `load_file` and `throw` before any
fixture code runs, including before the main-road source splice. Captures and
temporary bindings use a fresh UUID prefix. Readback calls only the captured
builtins; it never consults fixture-rebindable `print` or `has_key`, and uses no
`keys` call. The UUID is driver hygiene, not part of the compared output or runtime
semantics; this is an oracle for fixtures, not a sandbox against malicious code
that reads and rewrites its generated driver.

For a top-level return, the main wrapper inserts snapshots immediately before
each unindented `return`; `# road-return: expression` also checks the load's
returned value. Fixtures with a return nested in a block need a separate wrapper
extension: this instrument currently supports unindented file returns only.
It changes no fixture statement, and retains the containing directory. Snapshot
reads are observations, so these fixtures test values and scope, not observer
history or exact diagnostic line numbers. `# road-cwd: relative/directory` lines
override the default fixture-directory/unrelated-directory pair.
`# road-hardlink: source target` recreates a hard link in each private tree
(Git stores file contents, not hard-link relationships).

After the snapshots, the captured `print` emits a fresh UUID completion marker.
Each run must contain that marker exactly once, at the end of stdout. The gate
removes only that marker before comparing fixture output. Early `exit of 0`
cannot skip readback and substitute forged snapshot lines. Invalid binding
identifiers produce named failures before any child runs.

Stdout is compared byte for byte against the expected file AND between roads and
directories; every child must exit zero and have empty stderr (including under
sanitizers). An error on all three roads cannot masquerade as agreement. Missing
metadata, missing expected files, timeouts and zero fixtures fail. `--fixture
blocks` selects a single diagnostic repro; the suite always runs the whole set.

`--selftest` starts with five green controls: a numeric value, a literal `"<missing>"`
created in a `for` body, and fixtures rebinding `print`, `has_key`/`keys`, and
`throw`, plus a native loop with compilation statistics, an ARM64-policy control,
and a check that the lowered threshold reaches the child. On x86-64, sixteen
faults must go red: cwd divergence; deletion of the sentinel
assignment; forged absence goldens for both readback-rebinding fixtures;
incorrect return metadata despite a rebound `throw`; genuine absence where
present `null` is expected; a nonzero exit alone; stderr alone; exit before readback; an invalid binding
identifier; forced-off native arms; missing JIT statistics; a removed lowered
threshold; an invalid native-header value; duplicate native headers; and zero fixtures.
The membership control also calls the shared namespace-snapshot emitter from
within a scope that rebinds `has_key`/`keys`, so module isolation cannot conceal
a missing capture. The suite runs the ordinary gate and selftest.

`--selftest --bad-binary /path/to/known-bad/eigenscript` replaces the assignment
deletion and two forged goldens with execution of the unchanged sentinel,
print-rebinding and membership-rebinding fixtures on a runtime that drops
imported `for`-body bindings. Each plant must have clean child exits and exactly
two import-only presence mismatches, so an unavailable or crashing binary is
not accepted as a detected regression. The default selftest uses no external
checkout or compiler build.

The exit/stderr plants run the real binary through a bounded Python wrapper
that changes only its process status or stderr after successful evaluation.
Stdout must still match exactly. All six exit-plant runs return the same 17:
cross-road status comparison must not hide a missing absolute exit check.

Bought in #1056 round 3: rebinding `print` forged an absent-binding snapshot on
the known-bad runtime, and deleting either the exit or stderr check survived
the old selftest. The driver captures and independent process-result plants
close those holes. Reverting the print or membership capture, delaying main's
captures until after the fixture, using the rebound `throw`, or removing either
process-result check now fails selftest. Existing fixture goldens are unchanged
in this round.

Bought in #1056 round 2: the old `[name, "<missing>"]` representation gave a
false green on the known-bad runtime when the actual value was that same string.
The structural presence field and both missing-value plants close that hole.
The 11 existing goldens changed only their snapshot encoding (37 rows); their
fixture prints and value expectations were retained.

The `blocks` fixture is red on c1684bc: import has no `from_for` key while main
and load_file expose 4. `shadow` exercises the same A/prog.eigs from directories
A and B; only A/inc.eigs may run. `nested_load` checks sibling and project-root
loads, calls functions after the loaded file returns, and checks restored caller
provenance. `eigs.json` in that support tree is the project-root marker.

`importer_scope` gives the importer an `outer` binding before importing a helper
whose `for` body assigns that same name. It requires the importer to retain 1
and the helper to export its own binding. Replacing the compiler's imported
block assignment with `OP_SET_NAME` passed all 11 older fixtures but clobbered
the main/load importer's `outer` to 2 and omitted the helper's key; this fixture
rejects that plant. It also rejects c1684bc's loop-local assignment, which keeps
the importer at 1 but still omits the helper's key.

`resolution_order` pins sibling > package > project-root precedence;
`resolution_errors` rejects the removed cwd and one-parent steps and checks
both loaders' diagnostics. `observer_nested` has an observer-free decoy at the
old scan base: resolving nested eager reads from the main file must go red.
`hardlink_observer` gives one hard-linked source two different sibling modules.
An inode-only scan memo missed the observing sibling and raised at runtime;
the memo must include the containing directory. This was reproduced during
#1056, and is why file provenance belongs in the scan as well as execution.

`binders` deliberately retains the existing function-slot exception documented
in LANGUAGE_CONTRACT.md: a binder with no prior binding in a function remains
readable after the loop. On c1684bc `define f(): for z in [7, 8]: ...; return z`
returns 8. This differs from module scope, but is uniform across roads; #1056
does not change it. Pre-existing parameters, locals and module bindings are
protected on every road.

The sanitizer run also checks compiler ownership: extending loop-binder
tracking from functions to modules requires freeing the root compiler's
`lev_names` array. Before that cleanup, `blocks` produced correct stdout but
all six executions failed with a 32-byte leak. The gate rejects those exits
instead of accepting matching output from leaking children.

`f29_loop_local` pins writes to a current loop-local, an enclosing loop-local,
and locals in module-level `if`/`loop while` bodies. `f29_loop_local_cache`
alternates between a nearer local and module state over 80 iterations. These
f29 fixtures test interpreter scope behavior: `LOOP_ENV_CLEAR` prevents native
compilation, even with `EIGS_JIT_OSR_THRESHOLD=1`. A direct cache-fixture run
reports `[jit] scanned=1 compiled=0 cache_used=0`, with `LOOP_ENV_CLEAR` as its
only bailout. The earlier claim that this demonstrated native stores was wrong.
`f30_eval_dir` calls a helper's eval and direct load from main, a loaded file,
an imported wrapper, and a nested import; every call must load the helper's peer.

Bought in #1056 round 4: pinning every imported block write to the module
repaired missing exports but skipped existing loop locals. Check both sides
of a scope boundary: stop outward writes at it, and preserve nearer bindings
inside it. Import's compile-only directory override also leaked into execution
and redirected another file's eval. Its lifetime must end before module code
runs. The new fixtures fail with either respective fix removed.

The installed-layout subset symlinks test sources, so their canonical containing
directory differs from the temporary runner's cwd. Both suite runners export
`EIGS_TEST_DIR`; generated module writers use it for writes, loads, and cleanup.
The standalone fallback assumes the documented `src/` cwd. To reproduce the
actual installed layout without modifying the normal installation, set
`EIGENSCRIPT_INSTALL_PREFIX` when running `install.sh`, then put its `bin` on PATH
and pass its interpreter as `EIGENSCRIPT` to `tests/run_install_smoke_subset.sh`.
That lane failed two sections before the canonical-directory migration.
Existing fixture goldens are unchanged in this round.

## Native scope coverage (#1056 round 5)

`# road-native: required` fixtures run on all three roads and both cwds under
`EIGS_JIT_OFF=1`, default JIT, and `EIGS_JIT_OSR_THRESHOLD=1`. Each run must emit
exactly one JIT statistics line. These are configurations, not three measured
entry mechanisms: the same compiled chunk is exercised with the OSR threshold
lowered in the `osr` arm. Both native arms compile code and must agree. The
statistics count compiled chunks, not OSR entries; default JIT may already use
OSR. The reference requires `compiled=0`; each
native arm requires `compiled>0`. On ARM64, which has no JIT emitter, the gate
prints an explicit notice and runs only the reference tier (still requiring
its stats and `compiled=0`) on all roads/cwds. This does not waive a zero-compilation
native arm on x86-64. A separate selftest simulates this ARM64 policy.
The gate strips only that recognized stats
line from stderr; every other diagnostic still fails. The selftest runs a
known native loop, then forces JIT off or removes its stats through child
wrappers and requires named failures with matching stdout. Another wrapper
checks the child environment for the lowered threshold; removing that setting
must fail even when compilation statistics and stdout stay identical.

`native_alternate`, `native_late`, `native_outer`, `native_match`, and
`native_catch` use the critic's compilable inner loops to exercise the helper
lookup through alternating, late, nested, match, and catch locals.
`native_inline` creates a local with eval after a native inner loop has cached
a module target. It writes without reading that name first, so a GET_NAME
cannot refresh the caller's IC and conceal a stale inline store.
For `native_inline` on x86-64, the measured import-road lines are:

```text
ref: [jit] scanned=0 compiled=0 cache_used=0
jit: [jit] scanned=2 compiled=1 cache_used=19878
osr: [jit] scanned=2 compiled=1 cache_used=19878
```

All three return 14999. Without the inline scope guard, the native arms
return 19999. Removing only the JIT helper's bounded lookup instead breaks
`native_alternate` (and the other helper probes). The interpreter is the
independent value oracle; existing goldens are unchanged.

## Embed provenance and override audit

`python3 tools/embed_roads.py --selftest` builds `make embed-roads` without
relinking the CLI. A unique objdir inode match reuses that build variant.
A standalone `build.sh` CLI or ambiguous match uses the plain SOURCES list
through the release objects, or ASan objects when ASAN_OPTIONS is set.
The test covers provenance semantics with either layout; it does not infer
an unidentified CLI's compiler flags. Four metadata controls exercise zero,
one, and multiple matches, including the sanitizer fallback.
Its C harness checks `eigs_eval_file`, successive `eigs_eval_string` calls,
loaded helpers, imported wrappers, and restoration to no-file string eval.
A registered host probe checks the compile override while each file executes.
A wrong helper peer, a missing fixture tree, a nonzero exit, stderr, zero
checks, and a compile override planted only during a host probe must fail its
selftest. The scope plant leaves file lookup and ordinary values untouched,
so gutting host_scope_clean makes the selftest fail. Process plants must retain the healthy C result
and produce exactly their intended symptom.

| Directory state | Lifetime and regression coverage |
|---|---|
| `builtins_host.c` load_file override | Saved/set/restored around compile_ast; embed loaded-helper probes and f30_eval_dir. |
| `vm.c` import override | Restored before vm_execute; embed imported-wrapper probe and f30_eval_dir's nested import. |
| `eigs_embed.c` file override | Shared eval_source scopes it around compile_ast; embed file/string and execution probes. No script_dir mutation remains. |
| `main.c` script_dir | Entry-file base for the state, with canonical file provenance captured in chunks; shadow/chdir/nested_load and the native fixtures. |
| `state.c` initial script_dir | No-file `.` base; embed string eval before and after file eval checks its cwd peer. |
| `lint_host.c` E003.base_dir | Private lint traversal context, not a runtime global override. |
| `bundle.c` | Rewrites argv to the extracted entry; main establishes its base. No resolver-global writes. Existing bundle suite covers execution. |

Bought in round 5: a lowered OSR threshold was mistaken for evidence of compilation,
and the embed setter retained the same override lifetime import had just fixed.
The compilation assertions and execution-time embed probes enforce those
claims. Round 6 corrects the narrower overstatement: compiled>0 does not
distinguish default JIT entry from OSR entry. No runtime semantics change is
needed to describe the measured configurations accurately.
