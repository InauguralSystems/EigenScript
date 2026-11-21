# Observer cross-repo validation corpus (#262)

Real observer-using programs harvested from downstream consumer repos, plus
EigenScript's own examples, each pinned to a **value-path golden output**. The
EigenScript unit suite proves the observer *predicates* in isolation; this
corpus proves that an observer change doesn't silently alter *real consumer
behavior* — convergence loops, `report`-driven solvers, interrogative reads —
across the ecosystem.

It exists because the observer predicate / `report` surface is load-bearing in
multiple production repos (see #262): a change that passes the unit suite can
still shift convergence or learning-rate adaptation in dynamics, iLambdaAi, or
EigenScript's own `lib/optimize.eigs`.

## Layout
- `programs/` — vendored, self-contained `.eigs` (named `<repo>__<name>`).
- `golden/`   — captured value-path stdout+stderr, one `.out` per program.
- `MANIFEST.tsv` — provenance: source repo, path, commit, observer features used.
- `run.sh`    — run every program against a binary and diff the golden.

## Usage
```sh
./run.sh                      # validate ../../src/eigenscript against golden
EIGS_OBS_SHADOW=1 ./run.sh    # validate the slot model vs the value-path golden
./run.sh /path/to/eigenscript # validate any build (e.g. a Phase-3 binary)
./run.sh --capture            # re-capture golden from the value-path binary
```
Exit 0 iff every program reproduces its golden. A divergence names the program;
inspect with `diff <(cd programs && BIN prog.eigs) golden/prog.out`.

## Coverage note (#685)

Until 2026-07-25 every program here observed **scalars**. All 13 therefore
produced byte-identical output under deep, shallow and size-only container
entropy walks — and under a build with container entropy destroyed outright.
The oracle whose job is catching consumer-visible observer changes could not
see the container-entropy axis at all.

`EigenScript__container_observer` closes that: it observes containers
directly (flat content, content-change at fixed size, nesting through a
reference, a buffer reference for contrast, shared substructure, and a
trajectory over a growing container). Keep at least one container-observing
program in the corpus — a scalar-only corpus is silently narrower than it
looks.

## Golden recapture note (#1093, 2026-09-07)

`dynamics__solve` diverged when `zeros of n` became a flat buffer: its three
result vectors are built with `zeros` and printed through an f-string, so
`[0.999…, …]` became `<buffer:3>`. **Only the rendering moved.** Element-wise
against the pre-change binary the numbers are byte-identical
(`{rj[0][0]} {rj[0][1]} {rj[0][2]}` and the two siblings agree to the last
digit), and every iteration count in the golden (19 / 17 / 14 / 24) is
unchanged — so the observer-driven stopping behaviour this corpus exists to
watch did not move. The golden was recaptured for those three lines only.

Cost to record: those three lines no longer carry the solvers' numeric values,
so the corpus watches their convergence *counts* but not their *results*. When
`dynamics` next refreshes `solve.eigs` it should print the elements (or
`buf_to_list`) so the numeric signal comes back.

## Local edit note (#1758 R1.3, 2026-10-19)

`iLambdaAi__test_halting_descent` differs from its source (iLambdaAi `246bd9a`,
`eigenscript_native/tests/test_halting_descent.eigs`) in two lines: `x is 10`
became `x is 10.0`. Since #1758 R1.3, `10` is an int literal and int `*` raises
`value` on int64 overflow (decision (A)), so the source's runaway doubling stops
with `integer overflow in '*'` after about 60 doublings instead of saturating at
`1e308`. The source relied on its int silently becoming a float; `10.0` is the
literal its author must write under (A). This row pins the observer's reading of
a doubling sequence; overflow belongs to the N3/(A) rows of
`tests/phase2/MAP.md`. **The golden is unchanged**: byte-identical with the edit
in the interpreter, the default JIT and forced OSR, which is the proof that the
observer's reading did not move. Re-vendoring from `246bd9a` would undo the edit;
take the source's own fix when it lands, or keep this one.

## Sources (same-owner repos; vendored with provenance)
- **dynamics** — `solve`/`physics`/`life`: real solvers and trajectory demos
  using `report`, the six predicates, `unobserved`, and `prev`.
- **iLambdaAi** — its observer-specific test variants (distinct from this repo's).
- **EigenScript** — self-contained observer example demos.

## Regenerating
Programs are vendored copies (golden stays reproducible). To refresh from the
sources, re-clone the repos at the commits in `MANIFEST.tsv`, copy the listed
paths, and `./run.sh --capture` with a value-path binary.

## Why this is the Phase-3 gate
Phase 3 (slot-keyed observer, single model) must reproduce these goldens. The
`report` work in particular is read-driven and known to be sensitive; running
`EIGS_OBS_SHADOW=1 ./run.sh` (or a Phase-3 binary) immediately flags any real
consumer whose behavior changes — the dynamics solvers and iLambdaAi report
tests are the canaries.
