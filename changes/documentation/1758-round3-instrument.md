- `docs/PREDICATES.md` states how Phase 2's Round 3 is judged (#1758): the pre-registered standard-test arms
  (`tools/observer_oracle/standard.py`), the 16 process families and the calibration/held-out split
  (`families.py`, `hcal/`, the drand seal in `seal.py`), the balanced-accuracy judge with a paired bootstrap and the
  six decision rules (`judge.py`), and the recorded Deviations D1-D4 from the pre-registration. No runtime change.
