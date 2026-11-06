- Make the observer-loop stall backstop count an iteration when any of the
  newest W+1 retained numeric input values (or the available prefix, the
  same window the amplitude clause reads) is non-finite, under RULING
  R31-7. Every certifying numeric predicate requires a finite window, so a
  retained non-finite input prevents certification on that iteration. The
  clause reads input values only: an overflowing difference between finite
  inputs does not count through it, so finite contracting alternations keep
  their convergence route. The quiet, diverging and finite-amplitude clauses,
  their order, numeric predicates and report ranking retain their rules;
  the counter resets on every non-counting iteration.

  Cover a period-3 NaN cycle, the oldest retained input in a period-W+1 NaN
  cycle, and a contracting finite alternation with overflowing steps in all
  four tiers. Three named plants replace `r316-stall-step-nonfinite`;
  R31-8 adds the initial-NaN prefix witness and one-slot index plant, for
  nine stall plants and 64 contract readings. The 60 readings established
  before R31-8 retain their exits and counts.

  A period-12 cycle with one NaN can leave a finite window and reset the
  counter at default W = 10. R31-7 records this residual alongside
  period-6-or-longer constant-amplitude cycles and slow contracting
  alternations; the sparse-NaN and longer-cycle cases are Phase 3 candidates
  with the certified-verdict work.
