- Add `nan-newest-jitter`, pinned to a stall at exactly 101 iterations without
  certification in all four tiers, and the named
  `r319-stall-window-newest` plant under RULING R31-9. A finite subject
  receives one NaN at iteration 5, with x assigned last. Moving the reader
  from `values_head - 1 - i` to `values_head - 2 - i` instead gives 105.
  Register ten stall plants. The `100..112` bands on `nan-alternating` and
  `nan-period3` remain unchanged.

  Deviations: R31-8's exact oldest-prefix witness missed the opposite
  direction, which drops the newest prefix input. Its changes to the two
  periodic rows remained inside their registered bands. The new exact row
  complements `nan-prefix-jitter` rather than tightening those bands. The
  design lists the four reader degrees of freedom and their witnesses:
  forward start (`nan-prefix-jitter`/r318), backward start
  (`nan-newest-jitter`/r319), short extent (`nan-window-edge`/r317 extent),
  and wrap modulus/count source (`nan-window-edge` plus `nan-prefix-jitter`,
  critic plants (e)/(f)). One long extent remains equivalent because the
  ring holds W+1. No runtime code, ranking, arm, held-out split or decision
  rule changes.
