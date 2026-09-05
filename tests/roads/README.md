# The three-road oracle

`bash tools/road_diff.sh` enumerates every `*.eigs` directly in this directory.
Each fixture runs as main, through `load_file`, and through `import`, from two
working directories. Support files live under `assets/` and are reached by the
fixtures; they are not independent oracle programs. Each run gets a private copy
of the fixture tree and an empty HOME. Children are bounded to 30 seconds.
The second run invokes the entry point through a symlink in a third directory,
so main-program provenance must agree with import's canonical-file rule.

Every fixture declares `# road-bind: name ...` and has a nonempty `.out` file
containing its expected prints followed by `[name, value]` snapshots. The main
wrapper appends snapshots; the load wrapper snapshots after the call returns;
the import wrapper reads those names back from the namespace, checking `has_key`
before access. Missing bindings print `<missing>`, distinct from `null`.
Functions can be checked through their results instead of printing identities.

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

Stdout is compared byte for byte against the expected file AND between roads and
directories; every child must exit zero and have empty stderr (including under
sanitizers). An error on all three roads cannot masquerade as agreement. Missing
metadata, missing expected files, timeouts and zero fixtures fail. `--fixture
blocks` selects a single diagnostic repro; the suite always runs the whole set.

`--selftest` first runs a clean fixture through the actual gate, then plants a
cwd-printing fixture whose isolated runs must diverge, and finally removes all
fixtures. Both faults must go red. The suite runs the ordinary gate and selftest.

The `blocks` fixture is red on c1684bc: import has no `from_for` key while main
and load_file expose 4. `shadow` exercises the same A/prog.eigs from directories
A and B; only A/inc.eigs may run. `nested_load` checks sibling and project-root
loads, calls functions after the loaded file returns, and checks restored caller
provenance. `eigs.json` in that support tree is the project-root marker.

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
