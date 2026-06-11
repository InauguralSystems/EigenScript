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
