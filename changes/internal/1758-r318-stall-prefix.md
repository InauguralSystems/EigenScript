- Add an exact observer-stall prefix witness and the named
  `r318-stall-window-index` mutation under RULING R31-8. An initial NaN,
  followed by `x is 1.0 / n` with n starting at 1000 and incremented before
  x, must stall at exactly 100 iterations without certification in every
  tier. Moving the non-finite scan's starting index one slot ahead instead
  gives 101 and fails the witness. R31-9 adds `nan-newest` for the reverse
  index direction, bringing registration to ten stall plants and 68
  contract readings; runtime code and numeric rules are unchanged.

  Deviations: the earlier periodic and overflowing-step witnesses could not
  expose this index error. The ring holds exactly W+1 inputs, so a full scan
  visits the same set from any starting slot; their prefixes did not isolate
  an oldest NaN. The new witness tests that prefix before the ring fills.
  No W+2 row is added because the read length is capped by the W+1 ring at
  the default window. The pre-registration's arms, split and decision rule
  are unchanged.
