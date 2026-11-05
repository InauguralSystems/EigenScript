- Superseded by RULING R31-7: the observer-loop stall backstop counts an
  iteration when any of the newest W+1 retained numeric input values (or
  the available prefix, the same window the amplitude clause reads) is
  non-finite. The quiet, diverging and finite-amplitude clauses retain their
  rules. The counter resets on every
  non-counting iteration. Finite/NaN alternation now has a four-tier contract
  row; R31-7 replaces the last-step plant with retained-window and
  finite-overflow witnesses.

  The oscillation arm covers non-contracting oscillations whose peaks fall
  in both halves of the retained window. Period-6 `[5, 1, -2, 3, -2, 1]`
  remains a recorded residual on R3-STD, c8 and main, for Phase 3. Slow
  contracting alternations retain their convergence route: multiplier
  -0.999 takes 14511 iterations and -0.9999 takes 145089, with cost growing
  approximately as ln(scale)/ln|r|.

  Deviations: the earlier HD1b/LE1b assertions had no suite consumer of their
  exit status; the owning suite blocks now require successful completion and
  the final marker. The finite/NaN class returned through c8's NaN-blind
  convergence rule and hung after its removal; the R31-7 clause uses the
  retained input window, so an overflowing difference between finite inputs
  does not count through it. Numeric predicate rules, report ranking
  and registered decision rules are unchanged.

  The sanitizer sweep control includes the one new Assert completion check
  and eight task capture-status checks: its exact passing population is 93 (84 + 9).
  Seven semantic display rows remain declared alongside their owning
  completion checks; hard diagnostics still fail each owning section.
