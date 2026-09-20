# Consumer-acceptance wave records

One file per wave, written by `tools/consumer_acceptance.sh run <CANDIDATE>`
(`CA_RECORD=` names the path). The record is the milestone-M1 DONE artifact: it
names the candidate (path, tree, version, gfx), the inventory and how many
were examined, one `row|` per consumer with verdict / rc / duration / candidate
call accounting, and a final `VERDICT:` line. A record is never edited by hand;
a re-run writes a new file.

| Record | Candidate | Result | Findings |
|---|---|---|---|
| `2026-09-20-main-fed280f.record` | main `fed280f` (93 commits past v0.43.0), headless `src/eigenscript` 0.43.0 | FAIL — 7 PASS, 3 UNRUNNABLE by name, 6 FAIL, 1422 s | #1212 #1213 #1214, DMG#74, phugoid#8, DeslanStudio#40, ouroboros#243 |
