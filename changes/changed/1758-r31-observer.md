- Numeric observer bindings now expose their value, last displacement and
  relative-step settledness through `where`, `why` and `how`, and preserve
  exact int64 displacement across interpreter, JIT, snapshots and replay.
  Numeric convergence uses the windowed Cauchy test, stability the registered
  1% midrange band, and improvement Keras' running lower best with relative
  significant improvement and ten-step patience. A current NaN reports
  `undefined` with all six predicates false; opposite-sign infinities in the
  window report `oscillating`. Numeric trajectory snapshots carry exact flags
  and running-best state; explicit entropy classification of one raises
  `value`. Non-numeric entropy observation remains available (#1758).

  **Deviations from the pre-registration — D12 (RULING R31-1):**

  - Registered: R3-STD = each predicate's test replaced by STD_p; keyword, window and tape unchanged.
  - Deviation: R3-STD computes STD_p's tests on the exact-aware signal (#1830's int path, decided per window): a window of all-exact int64 steps uses a noise floor of 0 in the raw tests and the absolute tolerance `rtol·scale` in the settled tests.
  - Reason: Rule 6 (#1830's declaration list empty) binds every subject arm including R3-STD, and STD_p on a float signal cannot satisfy it (int64 verdicts 12/18 against 18/18; an exactly incrementing counter is not converged). The signal is the measurement device; the test is unchanged (R30-2 item 3).
  - Modelled effect: Two keys per predicate on the 72-row corpus: `int64_count`@10 and @60 × {`converged`, `stable`}, four keys total, R3 false and STD/D1 true.
  - The LOO arm "R3-STD without the int path" is already in the
    pre-registration's ablation list and is scored on H1 beside R3-STD,
    so a reader applying the strict reading has that number. No decision
    rule changes. Per-key parity must print exactly those four differences,
    each with both verdicts; examined == declared == 4. A fifth or missing
    key fails. Frozen standard/reference implementations, instrument and
    labels are unchanged.


  **R31-2 correction and disclosure:** The earlier delivery changed the
  original HD1, LE1 and vendored doubling-runaway inputs to additive
  trajectories. That concealed a regression from termination to timeout;
  it was not a valid expectation migration. Restore those original inputs
  and retain additive cases as additional HD1b/LE1b rows.

  The one shared interpreter/JIT stall reader counts a numeric iteration
  when its last relative step is quiet (`|r| < dh_zero`), OR its current
  value is non-finite, OR its window is `diverging`. It never counts an
  `oscillating` window or merely not-converged input, and resets otherwise.
  Original HD1 now stalls at109 iterations (base110); LE1 at102 (base107).
  This follows the amended reader rather than an artificial count delay.
  A damped oscillation now exits through convergence. The harmonic tail
  still stalls before certification; R31-2 records that as a residual.

  Elided numeric samples still update the live value rings and running
  best/since, but do not write trace-history observer snapshots. Their
  line-qualified where/why/how remain null, matching the base. All four
  design-named oracle plant messages are asserted in the repository's
  once-at-acceptance plant gate; no external executable supplement remains.
