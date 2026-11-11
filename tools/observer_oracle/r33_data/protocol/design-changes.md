<!-- Portable historical path projection; verbatim OUT sha256 eb2504a09a11d0c1f7155c6a024ba996669112e3ee50711f87ed031624a2676f -->
# Design changes: design-0 to R33-1 alignment

62 replacement places: 31 for the original R33-1 alignment, 13 for addendum 1/continuation alignment, and 18 for addendum 2/continuation 2 alignment. Old and new text below are exact text regions; no experimental result is asserted. Unchanged definitions, including the fixture formulas, remain in r3-3-design.r1.md.

## 1. Title

Authority: R33-1 section 6, items 22–24.

Old words:

```text
# Proposed replacement: R3.3 — #1580's scale experiment and #1830's float twin
```

New words:

```text
# R3.3 — #1580's scale experiment, aligned with RULING R33-1
```

## 2. Status and subject names

Authority: R33-1 items 1–2; section 6; section 7.

Old words:

```text
Status: **proposed, not ruled and not executed**. This text is a build specification conditional on the owner ruling on `deviations.md`. Alternatives there are alternatives to the proposed specification, never extra arms a builder may choose after seeing results. No registration, Round 3 arm, margin, H1 population or outcome is amended by this document. R30R-2 controls the reveal. The source subject here is `54008422b7bb4950131f4dd4d15ead942a2ecb2e` (R3.1 + R3.2), called **F0** below. Registered Round 3 **INC** remains v0.47.0 (`3d8a14b4`), **ANCHOR** remains v0.46.0 (`4a3a5c19`), and **R3-STD** remains `3eed5cafd678665ba1d0667fb73ce1b1437fa724`. These names are not interchangeable.
```

New words:

```text
Status: **ruled design, no experiment results asserted here**. This text brings the design of 2026-11-11 into line with RULING R33-1, which controls every change recorded in `design-changes.md`. It restates the registered scale experiment and its implementation definitions in one text. It adds no arm, proposal, population, margin or reveal outcome. R30R-1 freezes the original instrument and prohibits pre-reveal H1 scoring; R30R-2 controls the reveal. The source subject is `54008422b7bb4950131f4dd4d15ead942a2ecb2e` (R3.1 + R3.2), called **F0**, with the state's scale as it is, default 1e-3. Local references to the registration's INC mean F0. Registered Round 3 **INC**, called **INC47** here, remains v0.47.0 (`3d8a14b4`); **ANCHOR** remains v0.46.0 (`4a3a5c19`), and **R3-STD** remains `3eed5cafd678665ba1d0667fb73ce1b1437fa724`. These names are not interchangeable. The float twin is withdrawn from R3.3.
```

## 3. Section a, table status

Authority: R33-1 item 4.

Old words:

```text
The table records the branch as it exists, not the proposed policy.
```

New words:

```text
The table records the branch as it exists, before any arm policy is applied.
```

## 4. Section a, policy seam

Authority: R33-1 items 4 and 7.

Old words:

```text
The proposed implementation centralizes a **policy**, with purpose/reference arguments; it does not pretend that every consumer can continue to take one scalar unmodified.
```

New words:

```text
The implementation centralizes a **policy**, with purpose/reference arguments; a build changes the sites that read the scale and, for C arms, the readers of stored steps specified in (b). One scalar cannot express every policy.
```

## 5. Section a, configuration table header

Authority: R33-1 item 4.

Old words:

```text
| function / object | lines | operation and reference | proposed treatment for every experimental arm |
```

New words:

```text
| function / object | lines | operation and reference | treatment for every experimental arm |
```

## 6. Section b, policy authority

Authority: R33-1 items 2 and 4–6.

Old words:

```text
The registered eleven names are retained in the ledger. Their proposed **classifier substrate** is F0, with the float twin disabled for the entire floor experiment. Call the registration's historical binary **INC47**, and the registration's INC **floor policy on F0** **F0**. The proposed #1580 comparisons use F0; historical INC47 and ANCHOR are separately reported references, with absent capabilities printed. This is a result-changing proposal, not a correction of a spelling.

The following is the proposed per-site extension; its exact-path exception and raw-guard extension require rulings. Every arithmetic comparison not named here keeps the F0 code, including strictness, saturation of `since`, finite-window checks, non-vanishing slack and report priority.
```

New words:

```text
The registered eleven policies use F0's classifier substrate: F0, STD-rel, four C^win fractions, four C^hist fractions and PRE1045. Local #1580 comparisons use F0; historical INC47 and ANCHOR are separately reported recipe-built binary references, with absent capabilities printed. At the Round 3 reveal INC still means INC47.

The per-site policy follows. Every arithmetic comparison not named here keeps the F0 code, including strictness, saturation of `since`, finite-window checks, non-vanishing slack and report priority. Exact S5/S7 and N1's exact branch remain unchanged under every policy.
```

## 7. Section b, F0 arm name

Authority: R33-1 item 2.

Old words:

```text
| INC policy on F0 (identifier F0) |
```

New words:

```text
| F0 |
```

## 8. Section b, STD-rel exact path

Authority: R33-1 item 6.

Old words:

```text
| STD-rel | 0 | R | state scale (default 1e-3), proposed #1830 exception | `4*eps*R` |
```

New words:

```text
| STD-rel | 0 | R | state scale (default 1e-3), unchanged exact path | `4*eps*R` |
```

## 9. Section b, PRE1045 exact path

Authority: R33-1 item 6.

Old words:

```text
| PRE1045 on F0 | no scalar floor can express it | `1+R` (S1 current-only as above) | same state scale, proposed #1830 exception | incumbent `4*eps*(1+R)` |
```

New words:

```text
| PRE1045 on F0 | no scalar floor can express it | `1+R` (S1 current-only as above) | same state scale, unchanged exact path | incumbent `4*eps*(1+R)` |
```

## 10. Section b, peak timing, readers and state lifetime

Authority: R33-1 item 7.

Old words:

```text
`Phist` is the largest finite magnitude since the slot's first numeric observation, including the incoming observation before scale resolution. Empty/no finite history has peak 0. NaN and infinities do not become peaks; the existing non-finite verdict rules still apply. The alternative “inf is the peak forever” is in the ledger. Peaks are double magnitudes; integer identity/exactness remains in ObserverNumber. Relative steps are computed **once when recorded** and retained, as on F0; changing the later window does not renormalize old relative steps. D2's best and since are also folded online with the scale at that observation. A query never rebuilds either history.

For hist the slot gains `peak_abs` (double, initially 0) and `peak_used` (initially false; set on the first finite numeric observation). It updates even when no new best occurs. Numeric-to-nonnumeric detours preserve it just as the branch preserves value history; slot reset/new binding clears it. A window-size change does not clear it. Copies and lifetime follow R30-4 item 5: `trajectory of` carries it, `at`/`when` snapshots carry it, all slot/snapshot copy and reset paths carry/clear it, and ouroboros `aot_rt.h` mirrors it. The tape carries **no observer peak state**; replay folds the values to reconstruct it, including observations before the selected query. No per-binding peak is written into `O cfg`. The default raw/settled changes need no float-run state; the run is derived from retained values.
```

New words:

```text
`Phist` is the largest finite magnitude since the slot's first numeric observation, including the incoming observation before scale resolution. Empty/no finite history has peak 0. NaN and infinities do not become peaks; existing non-finite verdict rules still apply. Peaks are double magnitudes; integer identity/exactness remains in ObserverNumber.

**C-arm steps use the peak at the time of the question.** Every retained step is recomputed from the retained values against that one peak. All readers use the recomputed step: `quiet`, `how`, window flags and partial report, relative oscillation, `equilibrium`, and trajectory export. Imported trajectories are recomputed the same way; their carried relative steps are ignored under C arms. Temporal `at`/`when` reads answer as of their own moment: a snapshot holds the step judged against that moment's peak. F0, STD-rel and PRE1045 have no peak and keep their recording-time steps. D2's running significant `best` and `since` remain an online fold: each update uses its own moment's peak, and a later query cannot reconstruct discarded historical values.

For C^hist, running peak is slot state, carried and cleared wherever D2's `best` and `since` are carried and cleared (R30-4 item 5). This runtime state is built only if a C^hist arm is selected. It updates even when no new best occurs. Numeric-to-nonnumeric detours preserve it just as the branch preserves value history; slot reset/new binding clears it, and a window-size change does not clear it. `trajectory of`, `at`/`when` snapshots, slot/snapshot copy/reset paths and the AOT mirror follow that lifetime. Replay folds the values to reconstruct it, including observations before a selected query. No per-binding peak is written into `O cfg`.
```

## 11. Section b, frozen-file contingency

Authority: R33-1 item 8; section 8; R30R-1 item 1.

Old words:

```text
No frozen Python instrument file needs a change.
```

New words:

```text
The instrument is additive. If any requirement needs a frozen-file change, stop under R30R-1 item 1 with the file, smallest diff and reason; do not assume an additive implementation is possible from this text.
```

## 12. Section c, exact exception and float-twin withdrawal

Authority: R33-1 items 6 and 10; section 6, items 22–24.

Old words:

```text
## c. The exact path and the float twin

**Exact windows.** “All exact” is the branch's `observer_slot_all_exact`: a nonempty active step window, every step flagged exact because both operands are ints and their subtraction fits int64. Partial raw tests use it too; settled tests additionally need the full W+1 finite values. One inexact or overflowing subtraction in the window selects the float-tolerance path until it leaves. SMI ints count as ints.

Under the proposed exception, F0 and **all ten other policies** keep S5/S7's default tolerances 1e-6 and 2e-5. Because a nonconstant integer window has diameter at least 1, only a constant integer window settles. Exact raw noise stays 0. A nonzero, constant-step, same-sign exact counter has raw `diverging=true` after the raw test has enough steps, and at full checkpoints has `converged=false, stable=false`. This is the property K checks, including negative counters. It is not a claim that every nonconstant integer sequence is diverging.

The literal common-scale reading must also be shown to the owner. With C at S5/S7, D is compared with z*f*peak and 2*b*f*peak. At peak ≥2^53, even the smallest registered f=1e-6 gives z*f*peak ≥9,007,199, much greater than a 10-step unit counter's D=10. It would certify that counter; a winner could fail K by construction. STD-rel's literal exact scale 0 settles only constants. PRE1045's literal extension `1+abs(reference)` would also certify sufficiently large exact counters. Keeping the int exception is a proposed semantic departure, not an algebraic identity. `work/exact_examples.txt` records arithmetic only, with no classifier run.

**Proposed executable meaning of R30-1 item 3.** A float-motion run is the last **W consecutive steps** (10 by default), hence W+1 values, satisfying all of the following:

1. Every endpoint is a finite float observation (not an int); every subtraction is finite and nonzero. Zeros among the steps break the run.
2. Every raw step has the same sign, compared by sign bits / order, never by multiplying steps.
3. For every adjacent pair a,b, `min(ulp(a),ulp(b)) <= abs(b-a) <= 4*max(ulp(a),ulp(b))`. `ulp` is binary64 spacing as in `math.ulp`, including subnormal spacing and the finite spacing at DBL_MAX. Signed zero has the minimum positive subnormal spacing. The lower and upper tests are inclusive.

For a qualifying run return `converged=false`, `stable=false`, and `diverging=true`, overriding their ordinary finite-window results. Else use those results unchanged. Keep `improving`, `oscillating`, `equilibrium`, `quiet`, `where/why/how` and report priority unchanged; `report` consequently sees the changed predicate results. Do not require non-shrinking step sizes or “recent half ≥ older half”: a down-counter crossing a power of two is still motion. A run of W−1 qualifying steps does not activate the override. W, four ulps, all-float endpoints and its effect on all three predicates are proposed precisions of an underspecified ruling; alternatives and their consequences are in the ledger. This is a finite-window motion rule, not an inference that every such mathematical sequence has an infinite limit. A slowly converging float computation can supply such a run and will be called moving while it does.

**Judging rows and their status.**

| object | status on 54008422 | planned use |
|---|---|---|
| `float_count_2p50`, `float_count_2p52`, `float_count_2p53_by2` | absent from branch corpus, certificate and labels; present in `${WORKTREES}/briefs/out/r3/model/oracle_ext/{corpus,certificate,labels}.json` | add a separately pinned `r33_float/` corpus of these three affine float rows, n=60, checkpoints 10 and 60; regenerate certificates/labels with unchanged frozen tools; compare existing branch labels byte-for-byte; keep the original 72-row calibration pin |
| their generators | x0=2^50,2^52,2^53; a=1.0; b=1.0,1.0,2.0 respectively | each has limit null, tends_to +inf, bounded false, deterministic, HARDY_60; the six-vector label is `[false,false,false,false,true,false]` in schema order |
| `O2.float-counter-2p53-by2` | absent from MAP and row files | 60 updates from 9007199254740992.0 by 2.0; print `[x, converged, stable, diverging]`: proposed final stdout `[9007199254741112.0, false, false, true]`; design's base `[... ,true,true,false]` remains an unverified source/handoff expectation until measured in the authorized build round |
| `issue1891_underflow_tail` | in canonical corpus, checkpoints 10 and 80; labels false converged/stable and true diverging | retain and report it, without promising a fix from a floor change |

At underflow_tail, the last value is about 1e-160, a step is about 1e-170, and the 10-step diameter about 1e-169. Every registered max-form float tolerance at S6 is **at least** z*abs(last) ≈1e-163. The diameter fits even STD-rel's tolerance. N1 additionally contains the incumbent absolute “1”, and raw sign multiplication can underflow at line 1016. The proposed four-ulp float rule does not cover ~1e-170 steps at ~1e-160 (spacing is ~1e-176). Thus the existing design's “residual fixed here … from #1580's absolute floor” is unsupported. Remove that promise; list all six disagreements. A broader tiny-step/sign-product correction would be another proposed mechanism, with its own review and ablation; it is not silently included here.

Keep the scale policy/state/zero work and the float-run override in separate commits and toggles. A no-scale scratch build restores **all** scale sites including N1 and the zero/peak machinery's behavioral effects while retaining the float twin. A no-float scratch build removes only the run override while retaining the selected scale. Unused state fields may remain in scratch builds. Test both reverts against their specified behavior before the final SHA. Never use the float override to make the scale-only arm's K or Z pass.
```

New words:

```text
## c. The exact path and the withdrawn float twin

**Exact windows.** “All exact” is the branch's `observer_slot_all_exact`: a nonempty active step window, every step flagged exact because both operands are ints and their subtraction fits int64. Partial raw tests use it too; settled tests additionally need the full W+1 finite values. One inexact or overflowing subtraction selects the float-tolerance path until it leaves. SMI ints count as ints.

All eleven policies keep S5/S7's default tolerances 1e-6 and 2e-5 and exact N1=0. A nonconstant integer window has diameter at least 1, so only a constant integer window settles. A nonzero, constant-step, same-sign exact counter has raw `diverging=true` when the raw test has enough steps and, at full checkpoints, `converged=false, stable=false`. This is not a claim that every nonconstant integer sequence diverges. The float scale rule is qualified by this exact-path exception. **K is identical in every arm: it checks the untouched exact path and decides nothing between scale policies.**

**The float twin is withdrawn.** No same-sign, 1–4-ulp run override is built, no separate `r33_float/` corpus is added, and no float-twin MAP row, toggle, ablation or scratch build belongs to R3.3. R33-1 items 22–24 give the reasons: the proposed rule calls a convergent sequence diverging (`1 + 1e-13*0.99^n`, qualifying windows 19–162 in the ruling's arithmetic); it does not reach the family-14 starts at 1e6 and 2^40; and it is absent from the registered mechanism list. These are the ruling's pre-data reasons, not results established by this document.

The remaining limitation is stated: a float sequence whose ten steps travel less than a thousandth of its value reads `converged`; a sufficiently large counter has such a window. On the branch a unit-step float counter reads `converged` from about 1e4 and `stable` from about 500; main has the same kind of finite-window limit on slow divergence. #2326's three rows record it and stay outside the frozen calibration corpus until after the reveal; #2326 remains open. `issue1891_underflow_tail` is not fixed by any registered floor and remains a stated residual. R3.3 promises no wider tiny-step/sign-product correction.
```

## 13. Section d, identity seed status

Authority: R33-1 item 1.

Old words:

```text
Seed `0x158033` is proposed and fixed before generation.
```

New words:

```text
Seed `0x158033` is fixed before generation by R33-1 item 1.
```

## 14. Section d, calibration authority

Authority: R33-1 items 3 and 8.

Old words:

```text
**Scaled calibration.** Proposed primary rule:
```

New words:

```text
**Scaled calibration.** The rule:
```

## 15. Section d, scales and float-valued copies

Authority: R33-1 items 8 and 12.

Old words:

```text
At ×1, ×1e-3, ×1e3, regenerate scaled generators (multiply values/affine x0 and b, cycle entries, stochastic location/amplitude; conjugate recurrences x→x/s and multiply output by s). Scale `second` as well as `gen`, props.limit and manual claims; recompute capabilities and certificates. Preserve random seeds, parameters not carrying units, n, regimes and checkpoints. Non-capability rows remain the **float programs** that score.py:164–168 emits even where corpus JSON has ints. Do not change the four frozen execution forms. The proposed reading uses regenerated parameters (like existing family-15 scaling), not a claim of bit-exact base×s streams. Alternative held-value scaling is in the ledger.
```

New words:

```text
At ×1, ×1e-3, ×1e3 and ×1e6, regenerate scaled generators: multiply values/affine x0 and b, cycle entries and stochastic location/amplitude; conjugate recurrences x→x/s and multiply output by s. Scale `second` as well as `gen`, props.limit and manual claims; recompute capabilities and certificates. Preserve random seeds, parameters not carrying units, n, regimes and checkpoints. Every scaled population is **float-valued, including ×1**, as score.py emits these rows today even where corpus JSON has ints; remove integer generator typing for the scaled copies. K remains a separate typed exact row and is not scaled. Preserve the four frozen execution forms. Parameter regeneration is not a promise of bit-exact base×s streams.
```

## 16. Section d, exclusion horizon and counts

Authority: R33-1 items 3, 8 and 12.

Old words:

```text
Drop an entire base row and all copies if **any** assigned x0..xn in either binding at any study scale has |x|≥1e305. Nonfinite values are also excluded (the common source rows are finite before scaling). This is a whole-run, inclusive, matched-population exclusion, not an arm-dependent skip or a test of just the last window. The small `work/runnable_rows.py` evaluates only generator values for this inventory, never a classifier or label. It removes `const_1e308_literal` and `huge_conv`, leaving **61 bases /97 checkpoints**, **183 scaled rows /291 checkpoints**. There are 194 candidate (base,checkpoint,nonunit-scale) comparisons before the above-floor test. The retained IDs, in corpus order, are:
```

New words:

```text
Drop an entire base row and all copies if **any** assigned x0 through the last checkpoint, in either binding and at any scale, has |x|≥1e305; nonfinite scaled values are excluded by the same recipe. Examine the generated observation prefix, not the oracle's longer label horizon. The instrument must derive the ruling's counts and stop on disagreement: 72 canonical rows/118 checkpoints; 63 runnable common rows/100 checkpoints; after dropping `const_1e308_literal` and `huge_conv`, 61 bases/97 checkpoints. The three calibration scales give 183 rows/291 checkpoints and 194 base/checkpoint/nonunit-scale comparisons. The ×1e6 copies serve confirmation rather than enlarging calibration. All 32 H-cal rows are expected to survive the same exclusion. Counts are required derivations, not measured subject results. The design's retained calibration IDs, in corpus order, are:
```

## 17. Section d, complete metric and bound definitions

Authority: R33-1 items 6 and 8–10, 12, 17 and 20.

Old words:

```text
- `U_all`: count unequal V(base,c,1) vs V(base,c,s), divided by declared comparisons, s∈{1e-3,1e3}. `U_above` is the same ratio restricted to checkpoints whose **entire active value window** at the smallest scale has finite |x|≥1e-2 (inclusive). Every comparison has a base/checkpoint/scale key; retain the two per-scale tables as well as their pooled ratio. An unequal six-vector is one flip even if several bits change; also print per-predicate flips. A two-binding row is keyed on observed x as score.py does; y is a preserved second-binding execution control. No eligible comparisons → NOT EVALUATED, never zero flips/pass. At held-out ×1e6 is reported separately and does not silently enlarge these registered U denominators.
- `BA_p = (TP/(TP+FN)+TN/(TN+FP))/2` on **×1** scored keys. Undefined if either class is absent. Print the counts, raw accuracy and FPR beside it. On binary comparisons use paired common rows and print capability absences; F0 and its variants must read all designated rows. Point comparisons use exact rationals; bootstrap bounds enter rules rounded to 1e-9 as in judge.py.
- `Z`: fraction with `converged=true` at their **last checkpoint**, in a fixed zero-limit roster: `geo_decay_0.5`, `geo_decay_0.9`, `geo_decay_0.99`, `neg_decay`, `damped_osc_0.9`, `damped_osc_0.99`. Use all three study scales (18 declared last-checkpoint readings) and also print Z by scale. “Exactly 0” here means the mathematical limit is exactly zero, not an injected clamp and not necessarily a binary64 zero by the checkpoint. Z=1 means all 18. This roster/pooled-scale reading is proposed, not a claim that the registration fixed it. Machine-zero-only and all-zero-limit-row alternatives are in the ledger.
- `K`: fraction of the **three requested bits** that are correct, across checkpoints 10 and 60 of the existing exact `int64_count` row at ×1: six declared readings, expected false/false/true for converged/stable/diverging. Require 6/6. It is a separate typed-int validation stratum (not a fractional-scale conversion of int64 into floats). Print each bit; INC47 has capability absent here. Add the SMI and negative-counter direct acceptance controls described in (g). The proposed K scope excludes the float twin, which is independently judged after the floor choice; including float counters is a different reading in the ledger.

For each BA difference the **cluster is the original base trajectory**, carrying all its checkpoints (and any binding/scale replicas if reported); draw the same clusters for both arms, 10,000 replacement resamples, seed 175833 logged. For repeated appearances of one source row in confirmation components use the same cluster, never independent duplicated evidence. Use the pair's common row set, exactly the judge's pairing/undefined-resample conventions and percentile interpolation. No pooling six predicates into one BA. Print undefined bootstrap counts; an undefined required bound yields INCOMPLETE. A row is not a checkpoint, a scale copy or a predicate bit.
```

New words:

```text
- `U_all`: count unequal V(base,c,1) versus V(base,c,s), divided by declared comparisons and pooled over the scales compared. Calibration uses s∈{1e-3,1e3}; confirmation uses exactly (e), including ×1e6. One unequal six-vector is one flip even if several bits change. Retain per-row/per-scale tables, vectors for every flipped key and per-predicate flips. A two-binding row is keyed on observed x as score.py does; y remains a second-binding execution control.
- `U_above`: the same ratio, restricted to checkpoints whose **entire active value window** has finite |x|≥1e-2 at the smallest scale that population holds. That is ×1e-3 for calibration and H-cal, and ×1 for calibration ×1 versus ×1e6. Every base/checkpoint/scale comparison has a declared key. Empty comparisons are **INCOMPLETE**, never a pass or a zero flip rate.
- `BA_p = (TP/(TP+FN)+TN/(TN+FP))/2` on **×1** scored keys against unchanged oracle labels. Undefined if either class is absent. Print confusion counts, raw accuracy and FPR beside it. Binary comparisons pair common rows and disclose capability absences; F0 and its policies must read all designated rows. Point comparisons use exact rationals. The port's BA is a point estimate: it decides calibration step 1, never a rule requiring a bound. REPORTED cells remain visible outside confusion counts.
- `Z`: derive the roster by a rule over **every runnable corpus row** with `props.limit == 0` whose derived `converged` label at its last checkpoint is true at ×1, ×1e-3 and ×1e3. Print the labels at those scales and ×1e6 before the sweep. Stop unless the roster is exactly `geo_decay_0.5`, `geo_decay_0.9`, `damped_osc_0.9`, `neg_decay`, `two_vars`, `issue1891_repeated_tail` (ordering has no semantic weight). Calibration Z is the share of their last-checkpoint arm readings converged over the three calibration scales (18 readings); Z=1 is required. Confirmation uses their ×1e6 readings whose labels are true there. `geo_decay_0.99` fails the label filter at ×1e3; `damped_osc_0.99` is not labelled converged at its final checkpoint.
- `K`: the three requested bits at checkpoints 10 and 60 of the released **typed exact** `int64_count`, unscaled: `converged=false`, `stable=false`, `diverging=true`, six bits total, requiring 6/6. INC47's missing capability is disclosed. Because S5/S7 and exact N1 are unchanged, K is the same for every policy and checks preservation rather than selecting a floor.

**Bounds come from the frozen judge as a program.** Its resampler and difference bound are local to `judge.py`'s `main`; do not import them, copy them, edit that file, monkey-patch globals, or invent a fake STD arm. Stage the specified ×1 sets with their certificate/label gates and manifests, then run the unchanged program with two real binaries as arms (provisional build and F0), `--diff`, **10,000 paired resamples and seed 175833**. Read the bound and number of set-aside resamples from what the program prints. The cluster is the original trajectory carrying all its checkpoints; paired arms use the judge's own procedure. A required undefined bound is INCOMPLETE. Demonstrate the program on F0 versus F0 before relying on this interface. If it cannot print the required difference bound and count without a frozen-file change, stop under R30R-1 item 1.

**Analytical feasibility disclosed before data (R33-1 item 9).** At `geo_decay_0.5@60`, the window is 2^-50 through 2^-60. STD-rel's S6 requirement becomes `1023 <= 0.001`, which fails. Each C^win grid fraction fails the same window because its peak is still in the window. Every C^hist grid fraction can meet this Z roster (the ruling gives a minimum needed f of about 2.8e-8, below the grid's 1e-6). Thus STD-rel and C^win remain reported comparators but cannot win; this experiment can choose C^hist or retain F0. No U, BA or winner follows from that fact.
```

## 18. Section d, additive files, manifests and plants

Authority: R33-1 items 1, 3, 8, 14; section 8; R3.3-1a outcomes 3, 5 and 6.

Old words:

```text
**New files only.** Proposed implementation adds `tools/observer_oracle/r33_port.py`, `r33_population.py`, `r33_metrics.py`, `r33_run.py`, `r33_identity.py`, `r33_seal.py`, a small `r33_selftest.py`, `r33_protocol.json`, and data directories `r33_cal/`, `r33_zero/`, `r33_counter/`, `r33_confirm/`, `r33_float/`. Generated logs/manifests/results go to a versioned results directory, not into frozen modules. Each manifest pins the original code, all new code/data/emitted programs, arm source/recipe/library stamps, Python version, seeds and its own hash. Use the frozen tool functions from outside; do not monkey-patch their globals or manufacture a fake STD arm to enter judge.py. The #1580 decision table lives in the new metric/driver layer; Round 3's stays in the frozen judge. Dedicated selftests plant wrong vector order, bad exactness, a skipped exclusion, a missing comparison, an unpaired CI and a changed manifest, and show each named check red before green.

`families.py`, `standard.py`, `judge.py`, `score.py`, `certify.py`, `derive.py` and `reference.py` remain byte-identical to the hashes in `work/corpus_inventory.txt`; likewise keep seal.py and the original calibration data unchanged. The new float corpus is an extension directory, not a replacement for canonical calibration. If a future builder discovers this cannot be implemented additively, stop under R30R-1 item 1 with the smallest necessary diff. No such necessity was found by this source inspection.
```

New words:

```text
**New files only.** The additive instrument contains the port, population generator/scaler, metrics/decision layer, run driver, identity harness, protocol/data manifests, posted-choice confirmation mechanism and a small enrolled selftest. There is no confirmation beacon/seal implementation and no float-twin extension. Generated logs, inputs, manifests and results are retained as evidence. Each manifest pins original and new code/data, emitted programs, binary recipe/source/library identities, Python version and seeds. Use frozen tools from outside.

`families.py`, `standard.py`, `judge.py`, `score.py`, `certify.py`, `derive.py`, `reference.py`, `seal.py`, `corpus.json`, `labels.json`, `certificate.json` and everything under `hcal/` remain byte-identical to `54008422`. If any requirement needs one of these changed, stop with the file, smallest diff and reason. No count, certificate acceptance, identity or bound is established by this design text.

For R3.3-1a, the manifest records the recipe script/hash/commit, every fixture and population hash, every instrument-file hash, and all ruling-derived population/support counts. Write it before F0's binary first reads a fixture; the first commit holds fixtures and manifest before the identity harness first runs them. Its sha256 is posted before any measurement. Plant each intended refusal once: a one-reading port mismatch, a missing reading, a scaled certifier refusal, a ruling-count mismatch, confirmation without the choice file, and empty comparison. Enrol the selftest in `tools/selftests.txt` and show `bash tools/selftests.sh --changed 54008422b7bb4950131f4dd4d15ead942a2ecb2e --list` exits 0. These are the instrument brief's concrete calibration of R33-1's additive instrument, not new experimental criteria.
```

## 19. Section e, confirmation, BA guard, posted order and no retry

Authority: R33-1 items 8 and 11–15, 21.

Old words:

```text
## e. Held-out confirmation without pre-reveal H1 exposure

R30R-1 item 2 prohibits new large-counter draws (family 14) and sampling any H1 family, even under an independent seed or a different filename. H-cal is [11,1,6,5]; H1 is [2,3,4,7,8,9,10,12,13,16,14,15]. Existing explicitly released calibration rows remain available even when their shapes resemble an H1 family. Calling a newly generated counter “for #1580” does not make it available.

The proposed pre-reveal substitute is **held out by sealed selection/scale, not by process family**. It deliberately gives up the registration's unseen-family confirmation here; that test remains the one Round 3 reveal. This changes the strength and possibly the result of #1580's confirmation, and must be ruled. It changes none of H1's rows or rules.

| registered component | can it stand before reveal? | proposed replacement |
|---|---|---|
| large-magnitude counters | no new draw: family 14 is held out | fixed, already released `int64_count`, ×1, checkpoints 10/60; K validation, explicitly **not** a new held-out sample |
| scaled copies ×1e-3,×1e3,×1e6 of 20 rows “from Draft 1's families” | scales and 20 can stand; unrestricted family draw cannot | select 20 distinct existing rows from the 61 eligible canonical bases plus the 32 published H-cal rows, sorted by source-prefixed ID; retain each base and its three scaled copies (80 rows). No `--h1`, no F14 or F15 generator, no novel parameters or further family draws. The comparison measures unit transforms of released trajectories |
| geometric/damped decays to exactly 0 | zero-limit requirement can stand; unspecified new generator/checkpoints cannot | the six fixed released zero-limit rows in (d), at the same three study scales (18 rows), labelled by source; these are validation rows, not independent unseen trajectories |
| phugoid short-period streams “if … recovered” | no supplied stream or raw-data location exists here; optional condition is unsatisfied | no phugoid row is invented or substituted under its name; report consumer confirmation NOT VERIFIED. Re-run real streams at a later consumer pin bump if recovered; they do not enter this sealed roster or change its decision after sealing |

Total **99 rows**: 80 sampled scale rows +18 zero rows +1 exact-counter row. The pool is 93 published sources; sampling without replacement is across the 20 chosen sources, not across their copies. The 20 sampled ×1 rows, six zero ×1 rows and one typed counter supply BA; U uses each component with its matching scale copies, excluding the counter (which has no copies); Z and K keep their named strata. Overlapping components retain their declared weights in point counts, with a shared original-source bootstrap cluster. The number of checkpoint records follows the sealed 20-row draw and is printed in the manifest before any subject runs. Reject rather than silently resize if scaling/certification fails or above-floor comparisons are empty. The 32 H-cal inputs remain the already published draw, not fresh H-cal draws.

Before sealing, commit the complete generator/roster/scaling/exclusion and metric code, all labels derivable without the beacon, all controls, baseline identities, provisional winner's identity and recipe, alternative STD-rel port identity, and the immutable protocol. Post the instrument/confirmation manifest hash and commitment SHA. The proposed beacon is the first drand mainnet round strictly after that commitment's posted timestamp (seal.py's genesis/period and response validation); `r33_seal.py` validates the response with unchanged seal.checked, does **not** call seal.py's H1-writing CLI, and uses `int(sha256(('R33-confirm-v1/'+randomness).encode()).hexdigest(),16)` as the selection seed. `random.Random(seed).sample(sorted_pool,20)` fixes the draw. Pin the Python version. Publish beacon response/round, selected IDs, corpus/certificate/label/program hashes and completed manifest before scoring. No secret local seed or handpicked redraw. The independent critic repeats from the manifest on another machine.

This beacon commits the **#1580 local confirmation only**. It is not S_H and does not start H1. R3.3's final SHA is posted later; S_H remains exactly the first drand round after **that** post as registered. A failed local confirmation permits only the registration's one fresh sealed retry, separately recorded, without grid extension; it grants no H1 preview and no Round 3 H2.

Alternative: retain the registered counter/unrestricted-family confirmation and run it **at the one reveal**, never earlier. That avoids this weaker substitute, but selecting a floor/STD-rel or changing a build after that data would conflict with the fixed-final-SHA/no-tuning rule. It therefore needs a separate, explicitly ruled procedure fixing all candidate SHA(s) and how a precommitted fallback is selected; it is not an executable alternative a builder can improvise. This design proposes the released-material construction above so local selection finishes before the final SHA.
```

New words:

```text
## e. Fixed confirmation before the reveal

R30R-1 item 2 prohibits scoring a Phase 2 build on H1 families before the reveal. No new counter generator, `families.py --h1` call, unrestricted-family draw or renamed family-14/15 sample is allowed. Released calibration and H-cal inputs remain available. H-cal's four families are visible; the local confirmation holds out rows/scale, not process families. Unknown-family unit invariance remains rule 5 of the one Round 3 reveal.

**No source is drawn and no beacon seals this confirmation.** It is:

1. Every one of the 32 released H-cal rows after the same exclusion, regenerated at ×1, ×1e-3, ×1e3 and ×1e6. Compare each nonunit scale against ×1.
2. The eligible calibration bases at ×1e6 against ×1. Their ×1 rows were read in calibration; the new rows are ×1e6 copies.

Require `U_above = 0` over **every** comparison in both components, including ×1e6. Derive and print eligibility before the sweep. R33-1 expects 42 above-floor H-cal comparisons from 14 checkpoints of **five trajectories**, and 80 calibration ×1-versus-×1e6 comparisons. Print those five trajectories; 42 comparisons are not 42 independent trajectories. The masks are the population masks in (d), ×1e-3 for H-cal and ×1 for the two-scale calibration comparison. Stop on any ruling-count disagreement.

The **BA guard** requires the lower 95% bound of `BA_p(arm)-BA_p(F0) > -0.02` for every predicate. For a predicate with both labels on H-cal ×1, use H-cal ×1. If one class is absent there, use the judge's **two released sets together as they stand: all 72 calibration rows plus H-cal**, without replacing 72 by the 61 scaled bases or 63 common rows. R33-1 expects H-cal's missing positive classes to be `diverging` and `equilibrium`; derive and print support for all predicates. Run the frozen judge as a program as specified in (d), with staged/manifests for the required sets and the actual two binaries. Each result states the population used. Z is the roster of (d) at ×1e6 where its derived label is true; K remains the typed exact row.

**The posted choice establishes order (item 14).** Commit and post the calibration choice—arm and sha256 of sweep tables—before any arm other than F0 reads a confirmation row. The confirmation requires that posted choice as a file and writes the file's sha256 into **every output**; it refuses without the file. This records which came first. It is an order people keep and readers check; it does not machine-enforce the posting history. Reused calibration ×1 baselines are identified as reused, and no confirmation-specific new row is read by a non-F0 arm before the post.

**No retry.** There is no new local set to draw. A failed confirmation proceeds to step 4. It grants no H1 preview, new grid value, or Round 3 H2.

The conditional phugoid stream consumer check is outside this experiment: those short-period streams have not been recovered. The owner's Done-when stays open for the pin bump. Do not invent or substitute a phugoid row.
```

## 20. Section f, authority and scope

Authority: R33-1 items 16–18; section 6; section 7.

Old words:

```text
These are the registered four steps with proposed disambiguations; see proposed deviations 2 and 14–20. They decide only #1580's provisional floor on F0, **without the float twin**. They do not decide which predicates ship at the reveal.
```

New words:

```text
These are the four registered steps as completed by R33-1. They decide #1580's provisional floor on F0. The float twin is withdrawn. Local selection does not decide which predicates ship at the reveal.
```

## 21. Section f, calibration tie-break

Authority: R33-1 items 9 and 16.

Old words:

```text
Ties: smaller f, then win before hist if f also ties (the latter is a proposed completion of an unspecified tie).
```

New words:

```text
Ties: smaller f, then win before hist if f also ties. Item 9 makes the latter tie-break unreachable because C^win cannot be feasible; it is retained to make the rule total.
```

## 22. Section f, confirmation population reference

Authority: R33-1 items 12 and 14.

Old words:

```text
On the sealed set in (e),
```

New words:

```text
On the fixed confirmation in (e),
```

## 23. Section f, confirmation strata and bound populations

Authority: R33-1 items 10 and 12.

Old words:

```text
Calibration Z and K use the fixed validation strata; their presence in confirmation is labelled honestly.
```

New words:

```text
Confirmation Z is at ×1e6 for roster rows labelled true there. K uses the unchanged exact row. BA bounds use each predicate's population in (e), through the frozen judge program.
```

## 24. Section f, standard-first magnitude and feasibility

Authority: R33-1 items 9 and 17.

Old words:

```text
BA improvement and U improvement are percentage-point differences, not a percent ratio; the registered phrase “0.02 BA … on U_all” has mixed units and this is the proposed reading.
```

New words:

```text
BA improvement is a 0.02 absolute point estimate on some predicate using that predicate's guard population in (e). U improvement is a 0.02 absolute point estimate pooled over every confirmation comparison, each counted once. Item 9 discloses that STD-rel cannot pass Z, so the branch adopting it cannot be reached; the standard-first rule is nevertheless total.
```

## 25. Section f, distinguish overrule windows

Authority: R33-1 R33-1 closing authority paragraph; R30R-2 closing authority paragraph.

Old words:

```text
Notify the owner if STD-rel supersedes option C; the registered owner overrule remains available before the final SHA.
```

New words:

```text
Notify the owner if STD-rel supersedes option C. The owner can overrule R33-1 until the instrument's first measurement is posted; the separate R30R-2 reveal-outcome overrule window closes when R3.3's final SHA is posted.
```

## 26. Section f, neither passes

Authority: R33-1 item 17; section 6.

Old words:

```text
Do not report option C delivered or assume the float twin repaired the scale experiment. The round can proceed with F0 plus the independently accepted float twin, subject to its own gates and the reveal.
```

New words:

```text
Do not report option C delivered. F0 stays if neither passes, and #1580's Done-when is reopened with the tables and failing rows. No float twin is built.
```

## 27. Section f, fixed arm-order seed

Authority: R33-1 item 20.

Old words:

```text
Every arm runs once after controls, in a logged shuffled order;
```

New words:

```text
Every arm runs once after the A/A, with the order shuffled from logged seed **1580**;
```

## 28. Section f, reveal subject

Authority: R33-1 section 6; section 7.

Old words:

```text
The final R3 includes R3.1, R3.2, the locally chosen floor (possibly F0) and the separate float twin.
```

New words:

```text
The final R3 includes R3.1, R3.2 and the locally chosen floor (possibly F0), with no float twin.
```

## 29. Section f, reveal fallback dependencies

Authority: R33-1 section 6; section 7.

Old words:

```text
including its scale/twin dependencies,
```

New words:

```text
including its scale dependencies,
```

## 30. Section g, work order and instrument-turn boundary

Authority: R33-1 items 1, 7–8, 14–20; sections 6–8; R3.3-1a scope.

Old words:

```text
## g. Sequence for later briefs

1. **Rule on this design first.** Resolve every numbered deviation before generating any new arm/population verdict. Preserve both registrations and the frozen-file hashes. Cut the instrument brief from the complete synthetic-generator specification in (d) and a fixed F0 SHA/recipe, with no subject change.
2. **Build the additive instrument, fixed subject.** Land the new files and eligible scaled datasets, seeded identity input roster and manifests. Certify/derive separately with frozen tools. Recipe-build F0 and historical INC47/ANCHOR serially in their own worktrees. Anchor the port to F0 on the declared identity populations and 512 sequences, with zero mismatches/key gaps/tier findings. Record freshly measured old-method raw-accuracy calibration results beside new U/BA/Z/K for F0 and separately INC47; also label the registered historical 499/600 headline as continuity-only at its original population/pin, never as a result on this new population; do not call F0's score INC47's score. Baseline F0 has no float override.
3. **Controls before sweep.** F0 A/A with identical raw tables; port/binary A/A; planted metric failures red; PRE1045 U_above≥0.10. Publish controls, manifest and counts. Failure fixes the instrument and repeats this step before subject work; a failed positive control stops this experiment. Round 3's frozen controls remain separate and unchanged.
4. **Sweep the eight C policies and STD-rel on the proven port.** Fixed grid, frozen data, seed-logged order. Publish whole-population results. Resolve C ties exactly as ruled; declare the provisional winner or no feasible C. No H1 draw or scoring. Run #1580's local grouped ablation: relative-step sites S1 only; raw guard N1 only; reference/settled/zero sites S2–S8 plus the zero guard as the proposed replacement for stale “ceiling and zero handling”. State baseline F0, components and residual, including rounding effects. Do not invent a ceiling in order to ablate it.
5. **Winner's build at the policy seam.** Implement common policy plumbing and the selected C* (or provisional STD-rel if C* absent) in a scale-only commit, carrying hist state if needed. No grid of real builds. Verify against the port on all calibration/H-cal and typed boundary checks, every declared checkpoint. If the standard-first rule later selects STD-rel instead of the provisionally built C*, build that final selected policy as the sole conditional second candidate and verify it identically; this is an explicit departure from the literal “only winner gets a real build”, not permission to build the sweep.
6. **Seal and confirm locally.** Commit all procedures, provisional SHA(s), fixed baseline and port; obtain the separate future confirmation beacon; materialize exactly (e). First prove winner binary/port identity on every confirmation checkpoint, then compute the pre-specified decision. STD-rel confirmation is on the port; if it wins, build/verify it before accepting it, on the same fixed set with no parameter changes. Publish every failed row and the permitted single retry if used. No Phase 2 build meets any new H1-family draw here. Independent critic reruns on another machine.
7. **Float twin, separate commit.** Add/recertify the three-row extension before its behavioral judgment, using unchanged frozen tools and preserving the calibration pin. Implement precisely the ruled float-run definition. Do not use these rows to retune f or the port. Verify port updated only for the independent twin against the final build on allowed identity/calibration checks. The #2326 extension's oracle scoring on a genuinely new family-14 draw waits for the reveal; direct MAP boundary assertions are ordinary regression acceptance, not a preview of H1 BA. If a ruling treats the three mandated published fixtures themselves as barred until reveal, add/label them first and defer their oracle scoring; do not call a new counter generator calibration.
8. **MAP / round gates.** Add `O2.float-counter-2p53-by2` [R3.3], plus `O2.scale-unit-triplet`, `O2.scale-zero-limit`, and `O2.scale-exact-counter` [R3.3] as precise property rows: identical six-vectors on the ruled above-floor fixtures at ×1,×1e-3,×1e3; all last-checkpoint zero-limit converged bits; and exact SMI/boxed positive/negative counters with false/false/true. If the selected floor is F0 and an intended change row stays base-green, label it invariant with base evidence; do not manufacture tag-fail counts. Add float down-crossing, W−1/run-length, zero-step, sign reversal, mixed-kind and non-finite controls. Run interpreter, JIT, OSR and trace tiers with actual witnesses; add trajectory/snapshot/tape-twice/hist-eviction controls if hist is selected. Add a plant omitting each changed scale site and an exactness plant covering SMI as well as boxed ints. Update the phase2 checker round roster and run `phase2_check --through R3.3`; that command support is absent in tools/phase2_check.py:83–87 (its roster ends at R3.2). Preserve `gate.O1.oracle-floor` / `gate.O2.predicate-floors`, no #1830/R3 declarations, and required release/ASan and tooling gates for the eventual runtime patch. This turn runs none of them.
9. **Prepare reveal scratch builds before finality.** Pin recipes/SHAs for R3, R3-STD, INC47, ANCHOR and controls, and each leave-one-out: O1; #1580 scale (all its sites); #1830 exact path; O2 definition alignments; the float twin independently. #1752 conservative converged is absent from the scheduled subject: record that fact/identity ablation, do not introduce it for the table. Include the ruled R3-STD-without-int comparator (PREDICATES D12). Check every single revert leaves its sibling mechanism present. Scratch builds are acceptance-tested on calibration/H-cal only; H1 scoring waits. The reveal table is required for p when |BA_p(R3)−BA_p(INC47)|≥0.02; print component differences and residual, including interactions rather than attributing them twice.
10. **One Round 3 reveal.** Declare R3.3's final SHA and notify the owner that the overrule window closes at its post. R30R-2 rule-6 preflight first; only then the registered future S_H, H1, frozen judge and R30R-2 mapping. Dry runs use INC47/ANCHOR as subject placeholders on H1 families. Use #2339's accepted reveal driver/CI/replication procedure without changing it here. A selected floor or twin does not bypass per-predicate fallback; implementation of that fallback must restore the appropriate full fold semantics.
```

New words:

```text
## g. Ordered work

1. **Instrument on a fixed subject.** Add the port and policies, fixtures, scaled calibration/H-cal data, metrics, identity harness, posted-choice mechanism, staged ×1 judge sets/manifests, and selftest, preserving frozen files and src/lib. Derive all ruling counts, Z roster labels and H-cal support before running F0. Manifest and first fixtures commit precede the binary's first fixture read and the first identity run. Prove zero mismatches/key gaps on all 72 canonical rows, every scaled calibration row, H-cal at all four scales, 512 seeded sequences at every index and four anchors. F0 twice gives identical output. Demonstrate frozen judge F0 versus F0 on the staged sets and record the printed bound and discarded-resample count. Plant each new refusal once and enroll/list the selftest.
2. **End R3.3-1a before the first measurement.** This builder turn runs no non-F0 policy on a population or fixture and computes no F0 U/BA/Z/K table. Policy unit checks use handwritten windows only. It performs no H1 generation/read, no float twin, no hosted action or push. Deliver its durable bundle, manifest, design/change log, identity evidence, plants, judge receipt, report and current resume. The manifest is posted before the next turn measures.
3. **First measurement and controls, next turn.** Re-measure F0 under the new method; show F0's and INC47's old-method and new-method scores beside one another, with ANCHOR reported as a binary reference. The historical 499/600 headline remains continuity-only at its original pin/population. Run PRE1045's positive control: calibration U_above must be at least 0.10 or the experiment stops. Do not retune or add rows to rescue it. The fixed subject remains F0 until the instrument is validated.
4. **Sweep the proven port.** Run all eight C policies and STD-rel on calibration only, fixed grid, once after A/A, seed-1580 logged order. Publish U per row/per scale, every flipped vector, BA points, Z and K, including analytically infeasible comparators. Choose f* by (f), or report no feasible C. Independent replication remains required; no H1 row exists here.
5. **Post before confirmation.** Commit and post the calibration choice (arm and sweep-table sha256). The confirmation consumes that file and hashes it into every output. There is no local beacon or source draw.
6. **Build provisional choice and confirm.** Implement its policy at the ruled sites; add historical-peak runtime state only if selected. It must match the port on every confirmation checkpoint before judgment. Use the fixed confirmation and predicate-specific frozen-judge BA bounds of (e); no retry. If standard-first selects STD-rel, one conditional second real build is allowed with the same identity requirement, never a grid of real builds.
7. **Local leave-one-out.** For calibration f*, apply its rule alone to S1, to N1, and to its remaining changed sites S2/S3/S4/S6/S8 with the zero guard. Exact S5/S7 stay untouched. Give U_above and BA for each and the residual (total minus the three). No ceiling site is invented and a failed final choice does not replace f* with an F0 identity ablation.
8. **Prepare finality and reveal.** Complete the eventual runtime build's required acceptance gates and prepare the registered mechanism reverts before the final SHA. The registered LOO mechanisms remain O1, #1580 scale, #1752 conservative converged, #1830 int path and O2 alignments; there is no float-twin mechanism. Pin all build/recipe identities and verify each revert independently on released calibration/H-cal only. Post R3.3's final SHA, then the first future drand round supplies S_H for the one reveal. R30R-2 rule-6 preflight happens before reading the beacon or creating H1. The frozen judge and R30R-2 per-predicate mapping in (f) decide shipping; no local scale win bypasses them. Independently replicate the port and chosen build on another machine and require matching tables, as registered.
```

## 31. Closing limits, authority and stops

Authority: R33-1 items 1, 3, 6–9, 11–24; sections 7–8; R3.3-1a Stops.

Old words:

```text
## Contradictions, limits and stops

No unavoidable contradiction is asserted **under the proposed departures**. Literal unrestricted-family pre-reveal confirmation is incompatible with R30R-1; (e) replaces that requirement explicitly for the owner's ruling, instead of asking a builder to reconcile it. If the owner requires that original population unchanged and confirmation before finality, this becomes STOP 2 and both texts must be returned side by side. Changing the frozen instrument is neither proposed nor needed by any arm definition identified here.

This design establishes source facts and proposed procedures, not port identity, control success, a selected f, K/Z/U/BA results, build parity, certificate acceptance, hosted gates or consumer behavior. A future brief must not label any of those “verified” from this document.

**STOPS in this turn: none.** The specified STOPs remain mandatory for the build: frozen-file necessity protects R30R-1 item 1; a remaining irreconcilable registration/ruling conflict protects the registered texts from reconciliation by a builder. No experiment may run until the deviations are ruled.

```

New words:

```text
## Limits, authority and stops

This document states the ruled design and required checks, not a port identity result, successful control, selected fraction, metric table, certificate acceptance, bound, build parity, cross-machine replication or consumer result. Reviewer arithmetic is another party's until independently re-derived; ruling counts are mandatory derivations, and disagreement stops the build.

Stop and report if: a derived ruling count differs or Z is not the six named rows (protecting the bar fixed before data); ruling items cannot both hold or cannot be built as written (protecting the experiment from builder reconciliation); any item requires editing a frozen file, including the judge's bootstrap (protecting R30R-1 item 1); or the port cannot reach zero mismatches against F0 (protecting every later number). Give the conflicting items, file/smallest diff, or exact differing readings/window, as appropriate. For an incompatible-ruling stop, preserve independently completed work. Do not loosen the comparison or change the bar.

R33-1 overrides the pre-ruling design where they differ, as recorded in `design-changes.md`. It withdraws the float twin and replaces the local confirmation draw/seal/retry. All other registered duties stand: fixed grid; whole-population negative results and flipped vectors; old/new F0 and INC47 references; one run after A/A; seed-1580 order; and independent replication. The consumer check stays open at the pin bump. The Round 3 registration, amendment and R30R-2's reveal mapping retain their own authority.

Jon may overrule R33-1 until the instrument's first measurement is posted; after that these experiment rules are frozen with the registration. R33-1 flags exact-path qualification, query-time peaks, fixed confirmation/order/no-retry and float-twin withdrawal as choices made before data. Only C^hist or F0 can be the local outcome under Z; that fact is disclosed rather than treated as a result.

```


## 32. Status and controlling text

Authority: addendum1 preamble and items1–5.

Old words:

```text
This text brings the design of 2026-11-11 into line with RULING R33-1, which controls every change recorded in `design-changes.md`.
```

New words:

```text
This text brings the design of 2026-11-11 into line with RULING R33-1 and its addendum 1, recorded before any binary ran. The ruling and addendum control the exact changes recorded in `design-changes.md`; addendum 1 replaces the confirmation-refusal sentence and the fixed confirmation counts.
```


## 33. Section d, calibration counts versus confirmation counts

Authority: addendum1 items2–4; R33-1 items3,8,9.

Old words:

```text
Drop an entire base row and all copies if **any** assigned x0 through the last checkpoint, in either binding and at any scale, has |x|≥1e305; nonfinite scaled values are excluded by the same recipe. Examine the generated observation prefix, not the oracle's longer label horizon. The instrument must derive the ruling's counts and stop on disagreement: 72 canonical rows/118 checkpoints; 63 runnable common rows/100 checkpoints; after dropping `const_1e308_literal` and `huge_conv`, 61 bases/97 checkpoints. The three calibration scales give 183 rows/291 checkpoints and 194 base/checkpoint/nonunit-scale comparisons. The ×1e6 copies serve confirmation rather than enlarging calibration. All 32 H-cal rows are expected to survive the same exclusion. Counts are required derivations, not measured subject results. The design's retained calibration IDs, in corpus order, are:
```

New words:

```text
Drop an entire base row and all copies if **any** assigned x0 through the last checkpoint, in either binding and at any scale, has |x|≥1e305; nonfinite scaled values are excluded by the same recipe. Examine the generated observation prefix, not the oracle's longer label horizon. Calibration stays untouched under addendum 1 item 2: derive 72 canonical rows/118 checkpoints; 63 runnable common rows/100 checkpoints; after dropping `const_1e308_literal` and `huge_conv`, 61 bases/97 checkpoints. The three calibration scales give 183 rows/291 checkpoints, 194 base/checkpoint/nonunit-scale comparisons, and 50 comparisons above the floor. Stop on a different fixed calibration count or Z roster. The ×1e6 copies serve confirmation rather than enlarging calibration. Confirmation additionally removes each base from its comparison set at every relevant scale if the unchanged certifier refuses any copy, as specified in (e). Derive and publish its resulting counts before any binary runs; the old 42/80 confirmation counts are not final. Counts are required derivations, not measured subject results. The design's retained calibration IDs, in corpus order, are:
```


## 34. Section d, certifier-refusal disposition

Authority: addendum1 items1–3.

Old words:

```text
A certificate/derivation refusal is a harness error to resolve before the sweep, never an extra exclusion.
```

New words:

```text
A certificate/derivation refusal in calibration remains a harness error, never an extra exclusion. In confirmation only, a frozen-certifier refusal removes that base from its comparison set at every relevant scale, and is listed with the certifier message. The certifier remains unchanged, and a row is scored only where the frozen tools certify it. The replacement concerns certifier refusals, not arbitrary errors or missing labels.
```


## 35. Section d, confirmation Z completeness

Authority: R33-1 items8–9,12; continuation requirement preserving six Z rows.

Old words:

```text
Confirmation uses their ×1e6 readings whose labels are true there.
```

New words:

```text
For confirmation, all six named rows must remain present and have a true derived label at ×1e6; verify and print those labels before any binary runs. The confirmation Z check reads those six final checkpoints. A missing or unconfirmed required reading is INCOMPLETE, never a smaller denominator.
```


## 36. Section e, matched confirmation comparison sets

Authority: addendum1 items1–5.

Old words:

```text
1. Every one of the 32 released H-cal rows after the same exclusion, regenerated at ×1, ×1e-3, ×1e3 and ×1e6. Compare each nonunit scale against ×1.
2. The eligible calibration bases at ×1e6 against ×1. Their ×1 rows were read in calibration; the new rows are ×1e6 copies.
```

New words:

```text
1. Begin with the 32 released H-cal rows after the magnitude exclusion, regenerated at ×1, ×1e-3, ×1e3 and ×1e6. Before any binary runs, certify every copy with the unchanged tools. If any copy of a row is refused, leave that row out of (i) at **all four scales**. Compare each surviving nonunit-scale copy against its surviving ×1 base.
2. Begin with the eligible calibration bases at ×1e6 against ×1. Their ×1 rows were read in calibration; the new rows are ×1e6 copies. If the frozen certifier refuses any confirmation copy of a base, leave that base out of (ii) at **both scales**. The registered three-scale calibration remains intact.

List every removed base with its certifier message and the scale(s) refused. `cos_fixed_point` is already known to leave (ii), because its ×1e6 limit fails the certifier's frozen absolute fixed-point tolerance. No neighbour limit, manual block, certifier change, replacement row or extra process draw is substituted. At addendum posting no other refusal was known; certify all populations rather than assuming this is the only one.
```


## 37. Section e, dynamic counts and component emptiness

Authority: addendum1 items3–4.

Old words:

```text
Require `U_above = 0` over **every** comparison in both components, including ×1e6. Derive and print eligibility before the sweep. R33-1 expects 42 above-floor H-cal comparisons from 14 checkpoints of **five trajectories**, and 80 calibration ×1-versus-×1e6 comparisons. Print those five trajectories; 42 comparisons are not 42 independent trajectories. The masks are the population masks in (d), ×1e-3 for H-cal and ×1 for the two-scale calibration comparison. Stop on any ruling-count disagreement.
```

New words:

```text
Require `U_above = 0` over **every** surviving comparison in both components, including ×1e6. Before any binary runs, derive the post-certifier-exclusion counts separately for (i) and (ii), with rows/checkpoints, all comparisons, above-floor comparisons/checkpoints and source trajectories. The previous 42 and 80 are superseded expectations, not fixed thresholds; the orchestrator posts the newly derived counts with the manifest. Compare later inputs against that fixed pre-binary receipt. Print the trajectories, because a comparison count is not an independent-trajectory count. The masks stay those of (d), ×1e-3 for H-cal and ×1 for the two-scale calibration comparison. If **either** component has no comparison above the floor, confirmation is INCOMPLETE and the orchestrator rules again before any arm runs.
```


## 38. Section e, BA guard population unchanged

Authority: addendum1 item3 (comparison set); unchanged R33-1 item12.

Old words:

```text
R33-1 expects H-cal's missing positive classes to be `diverging` and `equilibrium`; derive and print support for all predicates.
```

New words:

```text
Addendum 1 changes comparison-set membership, not this BA guard: its H-cal population is the original released 32 rows at ×1, and the fallback is the original 72 plus those original 32 as they stand. Do not substitute the filtered confirmation comparison rows. R33-1 expects H-cal's missing positive classes to be `diverging` and `equilibrium`; derive and print support for all predicates.
```


## 39. Section e, Z population reference

Authority: R33-1 items9–10,12; continuation six-row Z requirement.

Old words:

```text
Z is the roster of (d) at ×1e6 where its derived label is true; K remains the typed exact row.
```

New words:

```text
Z is all six required rows of (d), present and labelled true at ×1e6; K remains the typed exact row.
```


## 40. Section f, Z confirmation requirement

Authority: R33-1 items9,12; continuation six-row Z requirement.

Old words:

```text
Confirmation Z is at ×1e6 for roster rows labelled true there.
```

New words:

```text
Confirmation Z is at ×1e6 for all six required roster rows, whose presence and true labels are established before binary use.
```


## 41. Section g, certification/count order

Authority: addendum1 items1–5.

Old words:

```text
Derive all ruling counts, Z roster labels and H-cal support before running F0.
```

New words:

```text
Certify every confirmation copy first and apply addendum 1's matched refusal exclusions. Derive fixed calibration counts, new confirmation counts, every excluded row/message, all six ×1e6 Z labels and original H-cal support before running any binary. Stop for another ruling if either confirmation component has no comparison above the floor. Publish the new confirmation counts with the manifest.
```


## 42. Section g, positive-control failure produces no choice

Authority: R33-1 section8; registered positive control.

Old words:

```text
Run PRE1045's positive control: calibration U_above must be at least 0.10 or the experiment stops.
```

New words:

```text
Run PRE1045's positive control: calibration U_above must be at least 0.10 or the experiment stops VOID and no calibration choice is produced.
```


## 43. Closing stop conditions

Authority: addendum1 items2–4; unchanged R33-1 items3,8–9.

Old words:

```text
Stop and report if: a derived ruling count differs or Z is not the six named rows (protecting the bar fixed before data);
```

New words:

```text
Stop and report if: a fixed calibration ruling count differs, Z is not the six named rows with its required labels, or later confirmation counts differ from the pre-binary receipt (protecting the bar fixed before subject data). Under addendum 1, re-derive confirmation counts after matched certifier refusals; if either confirmation component has no above-floor comparison, report INCOMPLETE for another ruling before any arm runs. Also stop if
```


## 44. Closing authority

Authority: addendum1 items3–4.

Old words:

```text
R33-1 overrides the pre-ruling design where they differ, as recorded in `design-changes.md`.
```

New words:

```text
R33-1 overrides the pre-ruling design where they differ; addendum 1 overrides its confirmation-refusal rule and nonfinal confirmation counts, as recorded in `design-changes.md`.
```


## 45. Status and complete authority

Authority: R33-1 addendum2 items1–5; continuation2 Read first.

Old words:

```text
This text brings the design of 2026-11-11 into line with RULING R33-1 and its addendum 1, recorded before any binary ran. The ruling and addendum control the exact changes recorded in `design-changes.md`; addendum 1 replaces the confirmation-refusal sentence and the fixed confirmation counts.
```

New words:

```text
This text brings the design of 2026-11-11 into line with RULING R33-1, addendum 1 (recorded before any binary ran), addendum 2 (recorded before the first measurement), and the binding continuation briefs. The exact changes and their authorities are recorded in `design-changes.md`. Addendum 1 replaces the confirmation-refusal sentence and fixed confirmation counts; addendum 2 adds site-reaching identity, group switches, four detailed rules and a new manifest before measurement.
```


## 46. Section a, portable source anchor and coverage distinction

Authority: R33-1 item4; addendum2 item1; continuation2 outcome3 portability.

Old words:

```text
Evidence: `work/site_search.py` and `work/site_search.txt`. Re-run with `python3 -B work/site_search.py ${WORKTREES}/es-r33-design`. The lexical search is the equivalent of `rg -n '\b(obs_floor_scale|g_obs_scale|obs_scale)\b' src`, followed by expansion of each local `scale` to its uses and inspection of the raw tests. There are **five calls** to `obs_floor_scale`, **eight consumer expressions** (the two D2 branches count separately), and the supplying read at line 989. All line numbers below refer to this exact commit. The script's enclosing-function labels are a heuristic; the function names in this table were checked against the declarations.
```

New words:

```text
The seam inventory is anchored to `src/eigenscript.c` and the state/configuration files at `54008422`. Reproduce its lexical search with `rg -n '\b(obs_floor_scale|g_obs_scale|obs_scale)\b' src`, then expand each local `scale` to its uses and inspect raw tests. There are five calls to `obs_floor_scale`, eight consumer expressions (the two D2 branches count separately), and the supplying read at line 989. All line numbers below refer to this exact commit. The source table states the arm definitions; it is not a substitute for the binary readings that must reach each site.
```


## 47. Section b, PRE1045 and N1 authority

Authority: R33-1 addendum2 item3, first and second bullets.

Old words:

```text
The per-site policy follows. Every arithmetic comparison not named here keeps the F0 code, including strictness, saturation of `since`, finite-window checks, non-vanishing slack and report priority. Exact S5/S7 and N1's exact branch remain unchanged under every policy.
```

New words:

```text
The per-site policy follows. Every arithmetic comparison not named here keeps the F0 code, including strictness, saturation of `since`, finite-window checks, non-vanishing slack and report priority. Exact S5/S7 and N1's exact branch remain unchanged under every policy. Addendum 2 item 3 makes the table's details explicit bar: PRE1045 at S1 uses `1+abs(new)`; its other sites use `1+abs(reference)`. N1 uses `4*eps*(1+abs(last))` for F0/PRE1045, `4*eps*abs(last)` for STD-rel, and `4*eps*max(abs(last),f*peak)` for C. No interpretation of a single scalar replaces those policies.
```


## 48. Section b, group switches before measurement

Authority: R33-1 addendum2 item2; continuation2 outcome2.

Old words:

```text
A context-aware policy seam resolves step denominators, reference tolerances and raw noise thresholds from one arm selector. S5/S7 have an explicit exact-purpose result.
```

New words:

```text
A context-aware policy seam resolves step denominators, reference tolerances and raw noise thresholds from one arm selector. Before the first measurement the port also has an independent switch for each registered leave-one-out group: S1 alone; N1 alone; and S2/S3/S4/S6/S8 with the zero guard. All groups on reproduce the full selected arm, reading for reading; all groups off reproduce F0. Show both on windows written by hand and include the switch machinery in identity. Do not edit the port after the sweep to obtain these ablations. S5/S7 and exact N1 have no experimental switch and retain their exact rule.
```


## 49. Section d, queryable scalars and quiet limitation

Authority: R33-1 addendum2 item1; continuation2 outcome1.

Old words:

```text
Port all scalar outputs with explicit NaN equality/zero-sign rules. Print examined/declared/mismatch counts and the first differing trace; never call an aggregate score identity.
```

New words:

```text
Port and compare each available language-query scalar with explicit NaN equality/zero-sign rules. `quiet` is internal and has no language query at this commit; list it as not compared with the binary and make no identity claim for it. Print examined/declared/mismatch counts and the first differing trace; never call an aggregate score identity.
```


## 50. Section d, site coverage and mutation inventory

Authority: R33-1 addendum2 item1; continuation2 outcome1.

Old words:

```text
**Scaled calibration.** The rule:
```

New words:

```text
**Site-reaching identity and mutation inventory.** The fixed 512 seeded sequences and four anchors remain byte for byte unchanged. Add separate F0 acceptance fixtures, written out in full or generated by a seeded logged rule, until the identity reaches every site the sweep changes. Hash and commit these new fixture definitions/programs in the third manifest before the recipe binary first reads them. Mutate one at a time every comparison operator, constant and choice of reference in S1–S8, N1, D2's running best, raw guards, partial-window rules and the non-finite rule. Include every surviving fault named by the critic. Each mutant belongs to exactly one list: caught by a real binary reading (with the catching reading); equivalent (with a reason); or not reachable through this commit's language (with a reason and the missing capability). Leave none unexplained. Source agreement alone does not establish site coverage.

Where the language can ask, compare non-numeric detours, window override, trajectory export/import and temporal `at`/`when` against the F0 binary. List unqueryable `quiet` separately. These checks establish the instrument; they are not scored calibration samples, scale-policy measurements or new process-family draws.

**Scaled calibration.** The rule:
```


## 51. Section d, non-finite magnitude exclusion authority

Authority: R33-1 addendum2 item3, third bullet.

Old words:

```text
nonfinite scaled values are excluded by the same recipe.
```

New words:

```text
nonfinite scaled values also drop their entire base, now explicitly ruled by addendum 2 item 3.
```


## 52. Section d, distinguish conditional Z definition from user preflight stop

Authority: R33-1 item12; continuation1 added Z stop, retained by continuation2.

Old words:

```text
For confirmation, all six named rows must remain present and have a true derived label at ×1e6; verify and print those labels before any binary runs. The confirmation Z check reads those six final checkpoints. A missing or unconfirmed required reading is INCOMPLETE, never a smaller denominator.
```

New words:

```text
R33-1 item 12 defines confirmation Z on roster rows whose derived label is true at ×1e6. Separately, continuation 1's added stop requires preflight certification of all six named rows with true ×1e6 labels; that continuation still binds. Thus, after that preflight passes, all six are included in confirmation Z. A missing/refused row or a non-true label triggers that preflight stop, rather than silently shrinking the denominator. The six-row preflight requirement is from the user's continuation, not a new clause invented in R33-1 or addendum 2.
```


## 53. Section d, printed-bound threshold

Authority: R33-1 addendum2 item3, fourth bullet.

Old words:

```text
Read the bound and number of set-aside resamples from what the program prints.
```

New words:

```text
Read the bound and number of set-aside resamples from what the program prints. The guard uses the printed bound at four decimals: a printed lower bound of `-0.0200` is not above `-0.02` and fails. Do not reconstruct hidden precision or treat that printed boundary as undecided.
```


## 54. Section d, judge proof and retained outputs

Authority: R33-1 addendum2 item4.

Old words:

```text
Demonstrate the program on F0 versus F0 before relying on this interface.
```

New words:

```text
Demonstrate the program on F0 versus F0 before relying on this interface. Addendum 2 item 4 records what this program proof does: the frozen judge internally computes F0 BA on the two released ×1 sets, while only the zero differences and set-aside counts are retained. This is the registered instrument proof; it does not supply a scale-arm measurement or authorize retaining an F0 experiment metric table in this turn.
```


## 55. Section d, real and portable selftest plants

Authority: continuation2 outcome3; R33-1 addendum2 item1.

Old words:

```text
Plant each intended refusal once: a one-reading port mismatch, a missing reading, a scaled certifier refusal, a ruling-count mismatch, confirmation without the choice file, and empty comparison. Enrol the selftest in `tools/selftests.txt` and show `bash tools/selftests.sh --changed 54008422b7bb4950131f4dd4d15ead942a2ecb2e --list` exits 0. These are the instrument brief's concrete calibration of R33-1's additive instrument, not new experimental criteria.
```

New words:

```text
The selftest plants exercise real derivations: site faults scored against saved real binary readings; a missing reading in a real identity output; a count derived from mutated staged files; parsed confirmation-refusal exclusions that list the refused base and remove it at every relevant scale; confirmation without a choice file; and an empty real comparison. The row uses the portable `python3 -I` standard-library environment of the other oracle rows. It calls no certifier or Sympy process: certifier-dependent facts come from the unchanged program's recorded output and are verified when the manifest is built. Enrol the row in `tools/selftests.txt`, pin its observed plant count, and show `bash tools/selftests.sh --changed 54008422b7bb4950131f4dd4d15ead942a2ecb2e --list` exits 0. Its green control and each actual red detector are retained. These calibrate the instrument rather than add an experimental criterion.
```


## 56. Section d, portable population derivation reference

Authority: continuation2 outcome3 portability; unchanged R33-1 items3,8.

Old words:

```text
`work/corpus_inventory.py` derives 63 runnable common rows /100 checkpoints;
```

New words:

```text
`r33_population.py` derives 63 runnable common rows /100 checkpoints;
```


## 57. Section d, third manifest and earliest measurement

Authority: R33-1 addendum2 item5; continuation2 outcomes5–6.

Old words:

```text
Its sha256 is posted before any measurement.
```

New words:

```text
Its sha256 is posted before any measurement. Addendum 2 requires a new third manifest after the site-coverage/group-switch changes, with the earlier two retained under historical names. The first commit of this continuation holds the new fixtures and the third input manifest before their first binary read. The real binary oracle output is recorded as measured output when obtained; the accepted manifest records its hash and preserves that chronology. Run the full identity again twice, including the A/A, before the first measurement. The earliest permitted first measurement remains **2026-11-12 16:00Z**; publishing a manifest or passing identity does not advance that time.
```


## 58. Section g, extended full identity

Authority: R33-1 addendum2 items1,2,5; continuation2 outcomes1,5.

Old words:

```text
Prove zero mismatches/key gaps on all 72 canonical rows, every scaled calibration row, H-cal at all four scales, 512 seeded sequences at every index and four anchors.
```

New words:

```text
Prove zero mismatches/key gaps on all 72 canonical rows, every certified scaled calibration/confirmation row, released H-cal and matched H-cal copies, the unchanged 512 seeded sequences at every index, four anchors, and the new site/query-surface fixtures. Re-run the full identity twice under the new manifest; the mutation inventory must account for every ruled site and every named surviving fault.
```


## 59. Section g, first measurement time

Authority: R33-1 addendum2 item5.

Old words:

```text
The manifest is posted before the next turn measures.
```

New words:

```text
The new manifest is posted before the next turn measures, and measurement must not begin before 2026-11-12 16:00Z.
```


## 60. Closing site-table stop

Authority: continuation2 added stop and explicit non-stop.

Old words:

```text
Also stop if ruling items cannot both hold or cannot be built as written
```

New words:

```text
Also stop if a new reading shows that the binary differs from the ruled site table's expression, reference or comparison at a site an arm changes: report the window, binary reading and site row, change no arm policy, and end (continuation 2's added stop, protecting the ruled arm definitions). A newly exposed F0-port mismatch is instead corrected against the binary and the full identity repeated. Also stop if ruling items cannot both hold or cannot be built as written
```


## 61. Section d, enrolled real-plant sample

Authority: continuation2 outcome3; the portable selftest's ten site plants and seven input-path plants.

Old words:

```text
The row uses the portable `python3 -I` standard-library environment of the other oracle rows.
```

New words:

```text
The enrolled row samples 17 plants: one recorded-reading fault for each of S1–S8, N1 and D2, plus seven real input-path plants (one changed reading, a missing reading, an empty comparison, a staged count, an unlisted refusal, a refused row restored at one scale, and confirmation without a choice). The row uses the portable `python3 -I` standard-library environment of the other oracle rows.
```


## 62. Section d, distinguish hand-unit depth from binary window query

Authority: addendum2 item1 and continuation2 outcome1, where the language can ask; frozen trajectory import supports depths4–64.

Old words:

```text
Window-override values 1 and 64, reset/copy and historical-peak carry are additional direct acceptance checks after the baseline identity proof, not substitutes for any of its 512 inputs.
```

New words:

```text
Handwritten port unit checks may use depths 1 and 64. Binary window override is queried through trajectory import at the language-supported depths 4 and 64; the language has no ordinary setter and cannot import depth 1 at this commit. Make no binary-identity claim for depth 1. Reset/copy and historical-peak carry checks supplement the baseline identity rather than replace any of its 512 inputs; each available language surface is separately compared as specified below.
```


## 63. Authority and fourth instrument

Authority: R33-1 addendum3 items1–7.

Old words:

```text
addendum 2 (recorded before the first measurement), and the binding continuation briefs.
```

New words:

```text
addendum 2 and addendum 3 (both recorded before the first measurement).
```


## 64. New programs before measurement

Authority: R33-1 addendum3 items1–7.

Old words:

```text
It restates the registered scale experiment and its implementation definitions in one text.
```

New words:

```text
Addendum 3 seals the programs for every registered step before measurement, fixes the binary-subject reading path, attaches the zero rule to each switched relative step, scopes the inventory, includes trajectory import and marks faults caught by an error. It restates the registered scale experiment and its implementation definitions in one text.
```


## 65. Relative-step zero rule and group setting

Authority: R33-1 addendum3 item3.

Old words:

```text
C also needs a 0/0 guard when its peak is zero: return zero for a finite zero→zero step.
```

New words:

```text
C also needs a 0/0 guard when its peak is zero: return zero for a finite zero→zero step. Every site switched to an arm forms its relative step with that arm's zero rule, including S1 alone. The reference-site group has no zero rule of its own: its sites use the arm's magnitude as it stands, and STD-rel gives a zero tolerance for a zero reference. No group setting divides zero by zero. Addendum 3 item 3 explicitly departs from the registration's group-list wording to keep this rule with the relative step; it changes no calibration leave-one-out checkpoint, since none holds a 0→0 step.
```


## 66. Three groups

Authority: R33-1 addendum3 item3.

Old words:

```text
and S2/S3/S4/S6/S8 with the zero guard.
```

New words:

```text
and S2/S3/S4/S6/S8. The arm's zero rule travels with its relative step, rather than with the reference group.
```


## 67. Inventory scope and four lists

Authority: R33-1 addendum3 items4–6.

Old words:

```text
Each mutant belongs to exactly one list: caught by a real binary reading (with the catching reading); equivalent (with a reason); or not reachable through this commit's language (with a reason and the missing capability). Leave none unexplained.
```

New words:

```text
Include Slot.from_trajectory in this census and a sealed import fixture that catches the since-restore fault; classify the critic's best-ignored import fault too. The port is claimed at the default configuration, with live bindings and imported trajectories at windows 4, 6, 10 and 64. Each mutant belongs to exactly one list: caught (with the binary reading or an explicit caught-by-error witness); equivalent (with a reason); outside the experiment's configuration (with the nondefault configuration or live-window-change premise, reachable through tape O records); or not reachable by any program or legal tape at this commit (with a reason). State the caught-by-error count. Quiet remains unqueried and unclaimed. Leave none unexplained.
```


## 68. Confirmation Z follows the ruling

Authority: R33-1 item12; addendum3 item1(c) (supersedes the stricter continuation reading).

Old words:

```text
R33-1 item 12 defines confirmation Z on roster rows whose derived label is true at ×1e6. Separately, continuation 1's added stop requires preflight certification of all six named rows with true ×1e6 labels; that continuation still binds. Thus, after that preflight passes, all six are included in confirmation Z. A missing/refused row or a non-true label triggers that preflight stop, rather than silently shrinking the denominator. The six-row preflight requirement is from the user's continuation, not a new clause invented in R33-1 or addendum 2.
```

New words:

```text
R33-1 item 12 and addendum 3 item 1(c) define confirmation Z on the item-9 roster rows whose derived label is true at ×1e6. Retain and print every roster label; use only the true-label rows in that confirmation denominator. A missing/refused roster row remains a stop; a certified false label is reported and does not enter confirmation Z. The roster itself remains the six rows derived from the three calibration scales.
```


## 69. Fourth manifest chronology

Authority: R33-1 addendum3 items1,2,5,7.

Old words:

```text
Run the full identity again twice, including the A/A, before the first measurement.
```

New words:

```text
Addendum 3 requires the fourth manifest, preserving all three earlier manifests under descriptive historical names. This continuation's first commit holds the new import fixture and fourth input manifest before the binary first reads that fixture; the accepted manifest subsequently records the actual F0 evidence. All programs for the registered procedure, the binary-subject recipes and the three exact old-scorer commands are sealed now. Run the full identity again twice, including the A/A, before the first measurement.
```


## 70. Selftest leaves the tree clean

Authority: Continuation3 outcome5; R33-1 addendum3 item1.

Old words:

```text
The row uses the portable `python3 -I` standard-library environment of the other oracle rows.
```

New words:

```text
The row uses the portable `python3 -I` standard-library environment of the other oracle rows, disables bytecode-cache writes before local imports, and leaves no file behind in the tree.
```


## 71. Confirmation Z criterion

Authority: R33-1 item12; addendum3 item1(c).

Old words:

```text
Z is all six required rows of (d), present and labelled true at ×1e6; K remains the typed exact row.
```

New words:

```text
Z uses the item-9 roster rows whose certified label is true at ×1e6 (R33-1 item12; addendum3 item1(c)); K remains the typed exact row.
```


## 72. STD port eligibility before bound

Authority: R33-1 addendum3 item1(c); R33-1 items17,18.

Old words:

```text
Standard-arm confirmation uses these same conditions with STD-rel in C*'s place.
```

New words:

```text
STD-rel is judged first on its port U_above, Z and K. Only if all three meet, and C* fails or lacks the item-17 advantage, is its conditional second build made and its bound taken. It cannot meet Z by item9. The program nevertheless carries the total decision rule.
```


## 73. Confirmation Z denominator in decision step

Authority: R33-1 item12; addendum3 item1(c).

Old words:

```text
Confirmation Z is at ×1e6 for all six required roster rows, whose presence and true labels are established before binary use.
```

New words:

```text
Confirmation Z is at ×1e6 over roster rows whose label is true there, retaining the complete roster and labels in the output.
```


## 74. Execution provenance and single-subject tables

Authority: R33-1 addendum3 item1(a,b,g).

Old words:

```text
Every arm runs once after the A/A, with the order shuffled from logged seed **1580**;
```

New words:

```text
The single-subject entry point writes the complete items8–10 tables without choosing. The positive control is a separate step before the sweep. Every collector for an arm other than F0 or PRE1045 requires the posted first measurement as a file and hashes it into every reading; the sweep refuses a missing or different hash. Every arm runs once after the A/A; the collecting tool logs the actual execution order beside the order drawn from seed **1580**;
```


## 75. New instrument includes future steps now

Authority: R33-1 addendum3 item1.

Old words:

```text
Add the port and policies, fixtures, scaled calibration/H-cal data, metrics, identity harness, posted-choice mechanism, staged ×1 judge sets/manifests, and selftest,
```

New words:

```text
Add the port and policies, fixtures, scaled calibration/H-cal data, metrics, identity harness, posted-choice and posted-first-measurement mechanisms, staged ×1 judge sets/manifests, selftest, and code for every step in addendum3 item1(a)–(g), demonstrated on handwritten positive and refusal inputs,
```


## 76. Binary hand demonstrations before measurement

Authority: R33-1 addendum3 item2.

Old words:

```text
Policy unit checks use handwritten windows only.
```

New words:

```text
Policy unit checks use handwritten windows only. INC47 and ANCHOR are built one at a time by their frozen recipes and read only on handwritten windows in this turn. No canonical, H-cal, scaled or existing fixture row goes through either, and the old scorer is not run on them before the first measurement.
```


## 77. STD conditional build and build identity

Authority: R33-1 addendum3 item1(c,e); items18,20.

Old words:

```text
If standard-first selects STD-rel, one conditional second real build is allowed with the same identity requirement, never a grid of real builds.
```

New words:

```text
The build identity entry point takes the named build, its declared commit and claimed arm, and compares every confirmation checkpoint in every field compared for F0; replication uses the same path. If STD-rel first meets its port U_above, Z and K and C* fails or lacks the item17 advantage, one conditional second real build is allowed and its bound is taken only after the same identity check, never a grid of real builds.
```


## 78. LOO groups and effect residual

Authority: R33-1 addendum3 item1(f),item3.

Old words:

```text
For calibration f*, apply its rule alone to S1, to N1, and to its remaining changed sites S2/S3/S4/S6/S8 with the zero guard. Exact S5/S7 stay untouched. Give U_above and BA for each and the residual (total minus the three).
```

New words:

```text
For calibration f*, apply its rule alone to S1, to N1, and to its remaining changed sites S2/S3/S4/S6/S8. Each switched relative step carries its arm's zero rule. Exact S5/S7 stay untouched. Give U_above and BA for each. For U_above and each predicate's BA, define a group effect as the group value minus F0, the total effect as f* minus F0, and the residual as the total effect minus the three group effects.
```


## 79. Named binary subjects

Authority: R33-1 addendum3 item2.

Old words:

```text
## c. The exact path and the withdrawn float twin
```

New words:

```text
**Binary subjects and both methods (addendum3 item2).** Build INC47 at v0.47.0 (`3d8a14b4`) with `build_arm.sh` and ANCHOR at v0.46.0 (`4a3a5c19`) with `build_anchor.sh`. Read each as the frozen judge's `run_arms` reads a runtime arm: call frozen `score.measure` one row at a time and use the interpreter's straight reading. A capability probe that skips a row, a row measurement that raises, or a probe that raises (then every row) are the only cannot-run cases; retain the printed reason. A tier split, vacuous run or unwitnessed JIT removes no row: print it beside the binary table. A base unavailable at any calibration scale leaves that binary's comparisons at all three scales. Unavailable Z/K readings are printed not read; print rows and comparison denominators. Their standalone tables use names outside the eleven policies and never reach the choice. The old method is frozen `score.py` as a program on the canonical corpus for F0, INC47 and ANCHOR; the fourth manifest gives each exact command, and its complete output or refusal is kept. Neither historical subject decides the choice. Standing repository oracle CI is outside this experiment and continues unchanged.

## c. The exact path and the withdrawn float twin
```


## 80. Procedure code sealed now

Authority: R33-1 addendum3 item1(a)–(g).

Old words:

```text
## g. Ordered work
```

New words:

```text
**Programs before their data (addendum3 item1).** All of the following are instrument code under the fourth manifest, demonstrated on handwritten inputs and an input that refuses or does not meet the rule: (a) one subject's complete calibration tables, without choice; (b) PRE1045's separate positive-control judgment and posted-first-measurement provenance; (c) each confirmation criterion, using the printed predicate-specific bound and true-label Z subset; (d) standard-first over the two confirmation results; (e) named build/commit/arm confirmation identity; (f) f*'s three group tables and effect residuals; (g) drawn and actual order recorded by the collector. Only the provisional build and permitted conditional second build are new code after the first measurement; no procedure code is deferred to the data-bearing turn.

## g. Ordered work
```


## 81. Additional stops

Authority: Continuation3 Stops.

Old words:

```text
Give the conflicting items, file/smallest diff, or exact differing readings/window, as appropriate.
```

New words:

```text
If a registered step cannot be coded without a choice the ruling and addenda do not make, identify the step, choice and readings of the text, implement up to that choice and continue independent work; the orchestrator rules before measurement. If INC47 or ANCHOR cannot be read by the fixed method into six verdicts even on a handwritten window, show the window and output, leave that binary unchanged and continue the rest. A machine build failure is instead NOT VERIFIED HERE. Give the conflicting items, file/smallest diff, or exact differing readings/window, as appropriate.
```


## 82. Distinguish third site seal and fourth import seal

Authority: R33-1 addendum3 items5,7.

Old words:

```text
Hash and commit these new fixture definitions/programs in the third manifest before the recipe binary first reads them.
```

New words:

```text
The site fixtures were sealed under the third manifest before their first binary read. Seal the new trajectory-import definitions/programs under the fourth manifest before the recipe binary first reads them.
```


## 83. Keep both newly reached import faults in the real CI row

Authority: R33-1 addendum3 item5; continuation3 outcomes4,5.

Old words:

```text
The enrolled row samples 17 plants: one recorded-reading fault for each of S1–S8, N1 and D2, plus seven real input-path plants (one changed reading, a missing reading, an empty comparison, a staged count, an unlisted refusal, a refused row restored at one scale, and confirmation without a choice).
```

New words:

```text
The enrolled row samples 19 plants: one recorded-reading fault for each of S1–S8, N1 and D2, two import faults (since restoration and the restored-best STORE reference), and seven real input-path plants (one changed reading, a missing reading, an empty comparison, a staged count, an unlisted refusal, a refused row restored at one scale, and confirmation without a choice).
```
