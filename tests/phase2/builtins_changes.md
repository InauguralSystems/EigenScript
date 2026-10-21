# Builtin bar changes

## Author-applied rulings, second import

The first import d2437d6d is unchanged. This second import copies the author-applied rulings byte for byte. The orchestrator ruled:

> R1.6a-D1: read_text gets a row: class other, round c, profile release, no R1.6 change, and no over-cap REPLAY case (open bug #1890). Its pre/tag were recorded before #1841; re-record pre on 1fd4422c because #1668 changed it upstream; changes_vs_pre then reads no.

> R1.6a-D2: net_port compares instead of printing an ephemeral port; net_listen, net_dial and net_accept likewise avoid socket handles. exec_capture prints the TYPE of its answer because pre-R1.6 (time_t)1e300 overflow made it nondeterministic. Re-record the changed probes on matched builds.

| File | Ruling |
|---|---|
| `BAR.md` | R1.6a-D1 and R1.6a-D2 |
| `RULINGS.draft.md` | R1.6a-D1 and R1.6a-D2 |
| `builtins/exec_capture.eigs` | R1.6a-D2 |
| `builtins/exec_capture.pre` | R1.6a-D2 |
| `builtins/exec_capture.tag` | R1.6a-D2 |
| `builtins/net_accept.eigs` | R1.6a-D2 |
| `builtins/net_dial.eigs` | R1.6a-D2 |
| `builtins/net_listen.eigs` | R1.6a-D2 |
| `builtins/net_port.eigs` | R1.6a-D2 |
| `builtins/read_text.branch` | R1.6a-D1 |
| `builtins/read_text.eigs` | R1.6a-D1 |
| `builtins/read_text.pre` | R1.6a-D1 |
| `builtins/read_text.tag` | R1.6a-D1 |
| `builtins.tsv` | R1.6a-D1 and R1.6a-D2 |
| `cases.tsv` | R1.6a-D1 and R1.6a-D2 |
| `determinism.sh` | R1.6a-D2 |
| `make_table.py` | R1.6a-D1 and R1.6a-D2 |
| `plants.sh` | R1.6a-D1 and R1.6a-D2 |
| `rowmeta.tsv` | R1.6a-D1 and R1.6a-D2 |
