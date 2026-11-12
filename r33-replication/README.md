# Scratch: inputs and posted outputs for the replication of the R33-1 experiment

This folder exists only on the scratch branch `r33-replication`. It is not part of
the instrument and is not meant to be merged.

RULING R33-1 item 20 (issue 1580) keeps the registered independent replication:
a blind critic reruns the port on another machine, and the tables must match.
The branch is the instrument at `77b334dd674f1dddf7e577bba2977da587f8c175`
(thirteen commits on `54008422`) with this folder added.

- `inputs/first-measurement.json` and `inputs/choice.json`: the two posted files
  that the collectors and the table programs take as arguments.
- `expected/`: the readings and the tables as posted, for each of the three steps
  (the first measurement, the sweep, the confirmation). None of these files holds
  a path.
- `SHA256SUMS`: the sha256 of every file under `inputs/` and `expected/`.
- `POSTED-HASHES-ONLY.txt`: the posted sha256 of the outputs whose bytes hold the
  absolute path they were written at. Those files are not here.
