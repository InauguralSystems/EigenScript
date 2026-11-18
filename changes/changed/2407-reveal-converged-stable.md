- `converged` and `stable` of a number keep the test of v0.47.0, as the
  Round 3 reveal decided (#1758, RULING R30R-2; #2407): over the last ten
  steps, each taken relative to the larger of the two values it joins and of
  0.001, `converged` needs every step under 0.001 and `stable` every step
  under 0.01 with no two steps in a row of opposite sign both above 0.001;
  neither holds for a window that is raw-diverging or raw-oscillating. They
  read this release's observations: a step between two exact integers is
  exact, a window holding inf or NaN answers false, and 1e308 is a finite
  number like any other. Round 3's windowed diameter test and midrange band
  for the two are reverted; `improving`, `oscillating` and `diverging` keep
  Round 3's tests, and `equilibrium` keeps its own.
