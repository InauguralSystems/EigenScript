# Test suite contributors

Run `make precheck` before sending a change. Suite sections live in
`tests/sections/*.sh` and are sourced by `run_all_tests.sh`; their directory
variable is `TESTS_DIR`. A section's helper definitions must come from the
runner, its sourced helpers, or the section itself.

## Suite environment variables

The table below documents external inputs to the suite. The static section
variable check reads only this marked table, not uppercase words in prose.
Optional inputs should normally use `${NAME:-default}` at their point of use.
Bash's own variables are derived by the check: from a clean shell (`compgen -v` after one command), and from the constructs that set a name implicitly (`read` and `select` set `REPLY`, `mapfile` sets `MAPFILE`, `getopts` sets `OPTARG`, `[[ =~ ]]` sets `BASH_REMATCH`, `coproc` sets `COPROC` and `COPROC_PID`, or `NAME` and `NAME_PID` before a compound command, `wait -p` and `{name}>` set their name). Any other input, such as `HOME` or `TMPDIR`, is read only if it is in the table below.

<!-- suite-environment -->
| Variable | Purpose |
| --- | --- |
| `EIGS_PLAN_TESTS_DIR` | Directory of tests for a generated section runner. |
| `EIGS_SUITE_SHARD` | Select a shard as `k/N`. |
| `EIGS_SUITE_CHANGED` | Select sections changed since a Git reference. |
| `EIGS_SUITE_SECTIONS` | Select explicit section labels. |
| `EIGS_PLAN_ACTIVE` | Mark a generated runner to avoid planning again. |
| `EIGS_TREE_LOCK_HELD` | Indicate that the caller owns the build lock. |
| `EIGS_GFX_MEMORY_KIB` | Address space cap for graphics tests. |
| `EIGS_GFX137_DEFER` | Path to the deferred graphics outcome ledger. |
| `ASAN_OPTIONS` | AddressSanitizer and leak detector options. |
| `TSAN_OPTIONS` | ThreadSanitizer options. |
| `UBSAN_OPTIONS` | UndefinedBehaviorSanitizer options. |
| `DISPLAY` | Display server used by graphics tests. |
| `SDL_VIDEODRIVER` | SDL video backend for headless tests. |
| `SDL_AUDIODRIVER` | SDL audio backend for headless tests. |
<!-- /suite-environment -->

`tools/section_undefined_vars.py` checks all sections before execution.
Order and scope are not modelled: a setter anywhere in the fragment, its source
closure, or the runner's source closure counts as set everywhere in that fragment.
Bare names evaluated as arithmetic outside $(( ))/(( )) (including subscripts, parameter offsets, numeric tests, -v/unset operands, integer attributes and let) are not checked.
Text that a builtin evaluates again when it runs (a quoted subscript given to unset, -v or declare; eval; trap) is not checked.
Reads are $NAME and ${NAME...} where Bash expands the fragment's words (including operator words),
plus bare arithmetic names inside $(( )) and (( )).
It follows literal and `TESTS_DIR`-relative source paths recursively;
dynamically computed paths are not evaluated.
