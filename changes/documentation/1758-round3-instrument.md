- `docs/PREDICATES.md` states how Phase 2's Round 3 is judged (#1758):
  - the pre-registered standard-test arms (`tools/observer_oracle/standard.py`);
  - the 16 process families and the calibration/held-out split (`families.py`, `hcal/`, the drand seal in `seal.py`);
  - the balanced-accuracy judge with a paired bootstrap and the six decision rules, compared as exact rationals
    (`judge.py`);
  - the reveal-path manifest, derived from the import graph;
  - arms built by recipe under a sanitized environment (`build_arm.sh`);
  - the recorded Deviations D1-D11 from the pre-registration, each with its reason.

  No runtime change.
