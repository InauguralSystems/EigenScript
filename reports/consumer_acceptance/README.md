# Consumer-acceptance wave records

One file per wave, written by `tools/consumer_acceptance.sh run <TREE-OR-BINARY>`
to `<UTC date>-candidate.record` in this
directory (`CA_RECORD=` overrides the path). The record is the milestone-M1
DONE artifact: it names the candidate (`candidate_path=`, `candidate_tree=`,
`candidate_tree_override=`, `candidate_git_sha=`, `candidate_version=`,
`candidate_full=`, `candidate_gfx=`, `candidate_sha256=`, `full_sha256=`,
`gfx_sha256=`), the prior completed-record floor (`record_floor=`), the inventory and how many
were examined, one `row|` per consumer with verdict / rc / duration / candidate
call accounting, and a final `VERDICT:` line. A record is never edited by hand;
a re-run on the same UTC day replaces that day's record atomically. The
previous completed record's floor is read before replacement, and the target
is marked `INCOMPLETE` before the first candidate hash, git metadata or setup.
Set `CA_RECORD` to retain
separate runs.

The current runner keeps `inventory=`, `examined=`, `row|` verdict/rc/duration/
candidate-call counts, and the final `VERDICT:` line. Older records also have
`path_farm=`, `path_dropped=`, `home_scratch=`, `overlay_shimmed=`,
`path_edit=`, and `env_passthrough=` fields from the retired confinement
machinery. Their presence is historical; new records omit them. A wave driver
must read the command exit status as well as the record: an argument error can
leave an earlier record on disk.

The row receives a private, dereferenced copy of the candidate tree's
`src/`, `lib/` and top-level regular files through `EIGS_DIR`. Only
extensionless runtime executable slots are replaced with counting shims;
source files such as `eigenscript.c` and `eigenscript.h` remain source.
No `build/` directory is linked back to the candidate tree. The shims execute
the original resolved binary paths, preserving executable-relative library
loading. Candidate, full and gfx hashes are recorded before rows and checked
after each row; a changed binary makes that row `FAIL` with
`candidate-mutated:<name>`. An inferred source tree must contain the resolved
binary in `src/` or `build/release/`; a standalone binary gets a minimal
overlay. `CA_TREE` records an explicit tree override.
Named prerequisites are checked before the row and reported as
`UNRUNNABLE|prereq=<name>` when unavailable.

| Record | Candidate | Result | Findings |
|---|---|---|---|
| `2026-09-20-main-fed280f.record` | main `fed280f` (93 commits past v0.43.0), headless `src/eigenscript` 0.43.0 | FAIL — 7 PASS, 3 UNRUNNABLE by name, 6 FAIL, 1422 s | #1212 #1213 #1214, DMG#74, phugoid#8, DeslanStudio#40, ouroboros#243 |
