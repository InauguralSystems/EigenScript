- `docs/PREDICATES.md` states how Phase 2's Round 3 is judged (#1758): the pre-registered standard-test arms
  (`tools/observer_oracle/standard.py`), the 16 process families and the calibration/held-out split
  (`families.py`, `hcal/`, the drand seal in `seal.py`), the balanced-accuracy judge with a paired bootstrap, the six
  decision rules and the reveal-path manifest (`judge.py`), arms built by recipe (`build_arm.sh`), and the recorded
  Deviations D1-D11 from the pre-registration, each with its reason. No runtime change.
