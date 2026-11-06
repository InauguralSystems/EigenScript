- Preserve the observer-driven runaway-loop contract under the numeric value
  signal (#1758, RULING R31-2). The shared interpreter/JIT stall reader counts
  a quiet last relative step (`|r| < dh_zero`), OR a non-finite current value,
  OR a `diverging` window toward 100 consecutive qualifying iterations. It
  never counts an `oscillating` window or merely not-converged input, and
  resets otherwise. A slowly damped oscillation exits through convergence.
  Elided numeric samples retain live value/running-best updates without
  writing line-qualified observer-history snapshots.

  **Correction and disclosure:** The earlier delivery replaced the original
  HD1, LE1 and vendored doubling-runaway inputs with additive inputs, hiding
  a termination-to-timeout regression. Restore the original inputs and keep
  additive variants as additional rows. HD1 now stalls at 109 iterations
  (base 110); LE1 at 102 (base 107). The additional same-binding HD1b/LE1b rows
  stall at 106; an isolated additive fixture stalls at 100. The harmonic tail
  still stalls before certification and remains a measured design residual.
  Registered STD/D1/D2 tests, D12 and all decision rules remain unchanged.
