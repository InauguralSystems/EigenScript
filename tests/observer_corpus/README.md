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
