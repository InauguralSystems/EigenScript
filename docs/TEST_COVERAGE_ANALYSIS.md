# Test Coverage Analysis (0.13.0, post #148–#159)

Method: `make coverage` (gcov-instrumented minimal build, full
`run_all_tests.sh`), then per-function `gcov -f` and uncovered-block
analysis on the big files, cross-checked against what CI
(`.github/workflows/ci.yml`) actually executes.

**Status: the gap-closure round is implemented** (same branch). Each
section below records the original finding, what was done, and what
remains. Line coverage, before → after:

| File | Before | After | Lines |
|---|---|---|---|
| strbuf.c | 100% | 100% | 51 |
| hash.c | 96.9% | 96.9% | 196 |
| compiler.c | 86.5% | **94.4%** | 1329 |
| builtins_tensor.c | 92.5% | 92.5% | 684 |
| fmt.c | **0%** | **88.9%** | 243 |
| main.c | 81.2% | 86.7% | 165 |
| jit.c | 70.2% | **86.0%** | 1930 |
| builtins.c | 77.2% | **85.8%** | 2875 |
| ext_store.c | 78.2% | 82.0% | 771 |
| trace.c | 81.6% | 81.6% | 517 |
| parser.c | 77.6% | 81.1% | 1186 |
| vm.c | 73.5% | **80.2%** | 2356 |
| arena.c | 77.8% | 77.8% | 117 |
| eigenscript.c | 74.7% | 74.7% | 977 |
| chunk.c | 73.0% | 73.0% | 152 |
| lexer.c | 69.7% | 71.2% | 423 |
| lint.c | **0%** | **49.7%** | 509 |

## 1. Orphaned fmt/lint suites — DONE

`tests/test_fmt.sh` and `tests/test_lint.sh` existed but were
referenced by neither `run_all_tests.sh` nor CI; `fmt.c` and `lint.c`
were the only core files at literally 0%. `test_lint.sh` had one
cwd-dependent check (`examples/hello.eigs` resolved relative to the
caller's directory) — fixed to an absolute path. Both are now suite
sections [80]/[81]. Remaining: lint.c is at ~50% — the untested half
is mostly rule implementations the 10 checks don't reach; extending
`test_lint.sh` rule-by-rule is cheap follow-up work.

## 2. Extension builds in CI — DONE

CI built only the minimal variant, so the probe-gated suite sections
([44]–[45] HTTP, [47] model roundtrip/overflow, transformer smoke,
[62] audio) silently skipped on every CI run, and `ext_http.c`,
`model_*.c`, `ext_gfx.c`, `ext_db.c`, `eigenlsp.c` (~6,700 lines)
never even compiled there. The new `extensions` CI job runs
`make jit-smoke`, builds `make http` and runs the full suite against
it (1713 checks incl. HTTP server integration + model roundtrip),
then compile-checks `make gfx` and `make lsp`.

Found in the process: **`make lsp` had been broken for months** (80
unresolved symbols — the hand-picked source list predated the bytecode
VM). Fixed by linking the full runtime minus `main.c`; `eigenlsp.c`
gained the `g_exe_dir` / `g_load_env` definitions `main.c` normally
provides. The CI compile-check keeps it from rotting again.

Remaining: `ext_db.c` needs a libpq service container to run [46] in
CI; audio [62] needs SDL — both still compile-only or skipped.

## 3. JIT fast paths — DONE

The Stage-5 fused opcodes and JIT helpers only fired on
benchmark-shaped workloads, and benches aren't in the suite — so
`jit_helper_index_set`, `jit_helper_local_idx_dot_get`,
`jit_helper_iter_next`, `jit_helper_dot_get/dot_set`,
`jit_helper_local_dot_set`, and the `OP_LOCAL_IDX_DOT_GET/SET`
interpreter cases were all at 0%.

`tests/test_jit_paths.eigs` (section [82], 19 checksummed checks) now
covers: the fused `local[const].field` get/set (via an OSR thunk —
the from-zero thunk stops at the function's dict/list literals, so the
loop needs >5000 cumulative back-edges), dict-dot inline ICs plus
their polymorphic-shape miss paths, global-dict dot (plain
`OP_DOT_GET/SET` → out-of-line helpers), the `LOCAL_DOT_SET`
guard-miss path (num store over a string slot), buffer/list
`INDEX_SET` incl. the non-num slow path, `for`-in iteration
(`jit_helper_iter_next`), native VAL_FN calls inside thunks, OSR on a
single 7000-iteration loop, and error semantics from hot code. The
runner section runs it under `EIGS_JIT_STATS=1` and (on x86-64) fails
if no thunk compiled — the file cannot silently pass interpreted.
Helper coverage went from 0% to 42–65% each; the residual is
`jit_helper_set_fn_name_local` (26 lines, still 0%).

## 4. Walker matrix (#156 bug class) — DONE

`collect_referenced_names`' AST_FUNC/AST_LAMBDA/AST_INTERROGATE cases
never executed, and #156 was precisely a walker that didn't know a
node kind silently breaking closure capture.
`tests/test_walker_matrix.eigs` (section [83], 27 checks) captures a
name reachable *only* through each construct — if/elif/while/for
conditions and bodies, match subject/pattern/body, lambda body, dict
and list literals, index target/expr/assign, dot get/assign, slice
bounds and target (#156's AST_SLICE), destructure RHS (#156's
AST_LIST_PATTERN_ASSIGN), f-string, unary, interrogative, try/catch
bodies, return, pipe, two-level nesting, call args. compiler.c's
pre-pass walkers are the main reason its coverage rose to 94%.

## 5. Builtin fallbacks shadowed by lowerings — DONE

`dispatch of [t, k, ctx]` (literal 3-list) lowers to `OP_DISPATCH`, so
`builtin_dispatch` — the path indirect calls take — was at 0%, along
with the bench-only buffer builtins (`fill`, `buf_from_list`,
`buf_get`, `buf_len`, `ord`, `sign_extend`) and
`nearest_in_range(_all)`. `tests/test_builtin_indirect.eigs` (section
[84], 37 checks) asserts the lowered opcode and the C fallback agree —
including out-of-range/null semantics — by calling each through an
alias.

## 6. Orphaned test files — DONE

All 28 orphaned `.eigs` files passed when finally run; they're wired
in as suite section [85] via `check_eigs_suite` (exit 0 + their own
pass marker), one suite-level check each. Nothing in `tests/` is a
silent no-op anymore.

## 7. Smaller gaps — PARTIALLY DONE

- **Exit-code blindness — done.** Every `.eigs` section now requires
  rc=0 via `rc_ok` (the 51 legacy marker-grep blocks were converted
  mechanically). One tolerated exception, see below.
- **`clone_ast` — resolved.** Not dead: it's the read-side clone in
  compound dot-assign desugaring (`obj.f += e`), which had zero test
  coverage. Compound `+= -= *= /= <<= >>= |= &= ^=` on dot targets —
  including indexed (`items[i].f +=`) and nested (`a.b.c +=`) — are
  now in `test_dot_assign.eigs` (15 → 26 checks). The fn-body cloning
  half of its old job was dead (`make_fn` body params removed); the
  clone helpers are parser-static now.
- **Remaining**: `builtin_build_corpus` + the `tok_base_string`
  detokenizer (~250 lines; model-adjacent, belongs with a corpus
  test under `make http`), ext_store corrupt-header recovery
  (`store_read_header` 51%) and JSON-array store fields
  (`store_json_parse_array` 0%), JSON string-escape edges
  (`eigs_json_parse_string` ~51%), `chunk_disassemble` (debug-only),
  the lexer's REPL-continuation branches.

## The leak finding (came out of the exit-code hardening)

Requiring rc=0 made ~26 test programs fail under
`ASAN_OPTIONS=detect_leaks=1` — they had been printing LeakSanitizer
reports for a long time, invisibly, because the old runner only
grepped markers. Two distinct mechanisms:

1. **Fixed: ownerless env ref in OP_CLOSURE.** `OP_CLOSURE` bumped
   `env_refcount` and `make_fn` took the fn's own ref — nothing ever
   dropped the first one, so a call env that created any closure could
   never be freed. With it removed, lambda-style closures
   (`return (x) => ...`) are leak-clean (verified: leaked at HEAD,
   clean now; full ASan suite shows zero new UAF/UB).
2. **Known and documented: the `define` cycle.** `define inner` inside
   a function binds `inner` *in the env that `inner` captures* —
   env↔fn refcount cycle, unreachable but uncollectable. LSan
   under-reports it (NaN-boxed slot pointers aren't scannable, and
   stale VM frame slots keep some objects "reachable"), typically
   showing only the tracked nums. A real fix needs cycle detection or
   weak self-bindings — runtime design work, out of scope here.

   The runner's `rc_ok` therefore tolerates exactly one nonzero-exit
   shape — output containing "LeakSanitizer: detected memory leaks" —
   and tallies it in the final summary line. Crashes, asserts, and
   UBSan still fail. **Watch the tally** (currently 26 under ASan, 0
   under release): a jump means a new leak.

## Suite state

Release: 1666/1666. ASan+UBSan (`detect_leaks=1`,
`halt_on_error=1`): 1666/1666 with 26 tallied leak-exits. http+model
build: 1713/1713. `make jit-smoke`, `make gfx`, `make lsp`: build
clean.

---

# Round 2 (same release): the residual-gaps list, closed

Everything tagged "Remaining" above, plus the CI execution gaps. New
measured coverage where re-measured (minimal build, full suite):

| File | Round 1 | Round 2 | Lines |
|---|---|---|---|
| lexer.c | 71.2% | **92.2%** | 423 |
| builtins.c | 85.8% | **91.5%** | 2875 |
| ext_store.c | 82.0% | 82.8% | 771 |
| vm.c | 80.2% | 81.3% | 2356 |
| lint.c | 49.7% | **80.6%** | 509 |
| eigenscript.c | 74.7% | 74.9% | 978 |

## Corpus builder — DONE

New `tests/test_corpus.eigs` (section [86], 25 checks):
`build_corpus` 3-pass builder end-to-end (return triple, stream file,
vocab JSON structure incl. `base_names[]` — which walks
`tok_base_string` for every base TokType, the lexer's big jump —
structural ids, determinism, missing-file tolerance, top_n clamping,
the optional identifier-histogram output with its descending sort, and
bad-arg nulls).

## ext_store — DONE

`test_store.eigs` 14 → 22 checks: list-valued record fields
(`store_json_encode` VAL_LIST branch on write, `store_json_parse_array`
— previously 0% — on read-back, incl. across a close/reopen so it
parses from disk), and three `store_read_header` corruption rejects
(short file, bad magic, bad version), all required to fail cleanly
(null/catchable, no crash).

## JSON escapes — DONE

`test_json_hard.eigs` JH32–JH43: the direct `\n \r \t \/ \\ \"`
branches (only `\uXXXX` ran before), the 2-byte and 3-byte UTF-8
encodings of `\uXXXX` (only ASCII ran before), and the unknown-escape
pass-through default.

## Last 0% JIT helper — DONE

`jit_helper_set_fn_name_local` 0% → 69%: `test_jit_paths.eigs` section
8 (19 → 21 checks) assigns to an *interrogated* name and a
*closure-captured* name in hot loops — both compile to
OP_SET_FN_NAME_LOCAL, and each call's fresh env misses the EnvIC
starting_env guard into the helper. (The captured variant adds one
define-closure, so the ASan leak tally is now 27.)

## Linter — DONE (80.6%)

`test_lint.sh` 10 → 13: the fn-definition builtin-shadow rule (only
assignment-shadow was tested), unreachable-after-return inside a
function body, and a feature-rich *clean* file (dicts, lambdas, list
comprehensions, match, try/catch, pipes, nested dot/index) that walks
every AST case in the lint collectors. Finding: the empty-block rules
(`empty if/loop/for/function/try/catch block`) and
`'x is ...' in condition` are **dead code** — the parser rejects
comment-only blocks and `is` inside conditions before the linter ever
runs. They're the bulk of the remaining ~20%; a future cleanup could
delete them.

## Fuzz harness — FIXED + IN CI

`make fuzz` had bitrotted exactly like the LSP: FUZZ_SOURCES was a
pre-VM hand-picked list and `fuzz_stdin.c` called the deleted
tree-walker `eval_node`. It now links the full runtime minus main.c
and drives the real pipeline (tokenize → parse → compile_ast →
vm_execute) — the layers it previously skipped are where the memory
bugs live. All 44 curated adversarial cases pass under ASan, and the
extensions CI job runs it on every push.

## ext_db — EXECUTES IN CI (was: never executed anywhere)

New `database` CI job: postgres:16 service container, `make full`
(libpq), full suite with `DATABASE_URL` set. `test_db.eigs` gained
DB09–DB15: a real table round-trip (CREATE / parameterized INSERT /
COUNT / parameterized SELECT / multi-row `db_query_json` / malformed
SQL → "error"), gated on a live connection so the section stays green
without one. Verified locally against a real postgres: 1766/1766 with
the live path active.

## Still open after round 2

- **The closure-cycle leak** (env↔fn from `define`-bound closures) —
  the one item on this list that is runtime engineering, not tests.
  **Investigated in round 3 (`docs/CLOSURE_CYCLE_GC.md`): it
  *accumulates* — ~12 allocations per escaping closure (500 → ~6,000
  leaked allocations), not the bounded exit-time blip earlier text
  implied.** The cheap fixes (weak self-binding either way) each
  introduce use-after-free, and a correct collector is blocked by
  `Env` having no uniform refcount (trial deletion) or needing an
  intrusive all-objects registry + complete root set (mark-sweep) — a
  reviewed project, not a patch, because its failure mode is memory
  corruption. `tests/test_closure_cycles.eigs` (section [87]) now pins
  the functional correctness of every cycle shape and the non-leaking
  invariants. Leak tally: 28 under ASan (the +1 is that new section),
  0 under release.
- eigenscript.c's last ~25%: re-examined in round 3 and **not a
  cleanup target after all** — `tok_type_name` is a complete,
  defensive token→string switch (every case is wanted the moment that
  token appears in a parse error), and the uncalled `env_*` helpers
  (`env_set`, `env_set_hashed`, `env_set_hashed_slot`,
  `env_get_local_hashed`, `env_get_hashed_slot`, `env_clear`) are
  public-header API. Deleting either to lift a coverage % would be
  gaming the metric / risking an embedder, not a correctness fix.
- Lint empty-block / `is`-in-condition rules: confirmed unreachable
  (the parser rejects those inputs first), but they're harmless
  defensive code — same reasoning, leave them.
- gfx/audio still compile-only in CI (needs SDL on the runner);
  macOS leg still runs no sanitizers; no `coverage-http` target to
  measure extension-file coverage.
- LSP behavioral tests (JSON-RPC handlers) — addressed in round 3
  (`tests/test_lsp.sh`).

## Suite state (round 2)

Release: 1704/1704. ASan+UBSan (`detect_leaks=1`,
`halt_on_error=1`): 1704/1704 with 27 tallied leak-exits. Full build
(http+model+db) with live postgres: 1766/1766. `make fuzz`: 44/44.
