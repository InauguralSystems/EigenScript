- `docs/PREDICATES.md` states three more limits of the observer's windowed tests, each with its measured numbers
  (#1580):
  - a float counter reads `stable` and then `converged` once it is large, and from 2^50 `report` says `converged`
    for a unit-step float counter; two executed examples pin it beside an int counter, which does not settle;
  - `x_n = 1e-160 − n·1e-170` reads `converged`;
  - near the scale 0.001 a verdict can change with the unit.

  The scale experiment registered on #1580 adopted no rule, and `docs/design/phase2-numbers.md` records what ran
  and what came out. No runtime change.
