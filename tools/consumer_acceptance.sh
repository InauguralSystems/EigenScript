#!/usr/bin/env bash
# consumer_acceptance.sh -- run every consumer's OWN acceptance command against
# a release candidate, and refuse to report success on a partial run.
#
# Milestone M1. The failures that bought it:
#   - a documented migration left three consumer suites unable to start (#1123)
#   - 93 commits sat beyond the released pin while all consumers stayed on it
#   - hq's hand-listed board never contained phugoid or polymethod, so two
#     live consumers were invisible to every release check
#   - primitives shipped for a consumer sat unused in that consumer's own code
#
# The rule that follows from those: a consumer that is MISSING, whose command
# cannot be found, whose command is SKIPPED, or whose command never reaches
# the candidate must fail the run. A release gate that can quietly examine
# fewer consumers than last time is the failure mode this whole file exists
# to prevent (mechanical-gates 15, 165, 113, 170).
#
#   tools/consumer_acceptance.sh plan            what would run, and coverage
#   tools/consumer_acceptance.sh run <tree-or-binary> [--full <binary>] [--gfx <binary>]
#     Candidate SET: eigenscript is always shimmed from the first argument.
#     --full shims eigenscript-full; --gfx shims eigenscript-gfx. A name a
#     consumer invokes that the set does not cover is UNRUNNABLE|prereq:variant:<name>
#     and a 127-shim of that name sits on PATH (never a stale PATH fall-through).
#     The name set is DERIVED, never typed, and only from INVOCATION
#     POSITIONS (tools/_derive_variants.py): the first word of a simple
#     command in shell text (*.sh, an extensionless #! script, Makefile
#     recipe lines, a workflow runCmd, a DECLARED command via --shell), the
#     word after exec/env/nohup/setsid/`timeout N`/`xvfb-run`/`command -v`,
#     the value of an assignment or a ${VAR:-default}, the first element of
#     a Python subprocess/os.system/os.exec*/shutil.which call or an
#     os.environ.get default, and the first string of an .eigs
#     exec_capture/proc_spawn call. Comments, heredoc bodies, prose, JSON,
#     YAML values other than runCmd and anything with a / are NOT
#     invocations, and every rejected occurrence is printed by `plan` as
#     variants|<consumer>|excluded:<name>|<file>:<line>. The check runs in
#     run_one too, not only at plan time, so a name reached from a script
#     the consumer CALLS is refused before the stale binary is.
#     At EXECUTION time the class is closed independently of the
#     derivation, by CONFINEMENT rather than by shadowing. A 127-shim
#     earlier on PATH is only as good as PATH ORDER, and PATH order
#     belongs to the CONSUMER: one `export PATH="$HOME/.local/bin:$PATH"`
#     -- the ordinary CI idiom EigenGauntlet and EigenMiniSat already use
#     via $GITHUB_PATH -- put a stale runtime back in front of $SHIM and
#     the row still read PASS (Fable/Astra r3). So each row runs with
#       PATH=$SHIM:$FARM   and nothing else,
#     where $FARM holds, for every executable found on the INHERITED
#     PATH (find -L, first occurrence wins) EXCEPT every name matching
#     eigenscript*, a two-line EXEC WRAPPER
#       #!/bin/sh
#       exec "<absolute original path>" "$@"
#     so the tool RUNS IN PLACE. A symlink farm ran the tool from the
#     farm instead, and that BROKE consumers: relocating a
#     virtualenv's python3 moves sys.prefix to /usr (venv detection
#     reads pyvenv.cfg beside the executable's OWN path), so a
#     dependency installed in the selected virtualenv vanished and the
#     row FAILed after the candidate call succeeded (Astra r4). Hard
#     links and copies are worse still. The wrapper keeps
#     sys.executable, $0, pyvenv.cfg and every sibling data file at the
#     tool's original location, and keeps first-occurrence-wins.
#     No inherited directory is on the row's PATH, so there is no `.`,
#     no empty entry and no $HOME/.local/bin to prepend in front of;
#     HOME is an empty per-row scratch directory (home_scratch=yes,
#     with empty .local/bin and bin) and XDG_* is unset, while the
#     named build/tool CACHE variables pass through (env_passthrough=).
#     Header: path_farm=<n executables>, path_dropped=<names>,
#     home_scratch=, overlay_shimmed=, env_passthrough=, path_edit=.
#     Farm construction is FAIL-CLOSED: a farm directory that cannot be
#     written exits 2 by name, and path_farm=N must be >= the number of
#     non-eigenscript* executables the enumeration found.
#     A consumer PATH EDIT that adds an ABSOLUTE directory which exists
#     on this box and whose RESOLVED form is outside $SHIM/$FARM/the
#     row's $HOME/the consumer's own checkout is refused BEFORE the row
#     runs: FAIL|path-edit:<resolved dir>, with a log|<name>|preflight:
#     line that also carries the WRITTEN form.
#     Names outside the candidate set still get their 127-shims in $SHIM
#     (path_masked=) -- those work for ANY shell, so they are what turns a
#     computed name invoked from a `sh` script into a named failure -- and
#     a name that resolves NOWHERE is recorded the same way by the block
#     shell's command_not_found_handle rather than being a bare 127 the
#     consumer can swallow with `|| true`. The row's own call log is then
#     read back and any argv[0] basename outside the candidate set makes
#     the row FAIL|undeclared-variant:<name>.
#     EIGS_DIR is the TWIN of that PATH: it is a cp -rL copy of the
#     candidate tree, so every eigenscript* file in the overlay is a shim
#     too -- the candidate's counting shim when the set covers the name, a
#     127-shim when it does not.
#     Scratch creation is FAIL-CLOSED: every mktemp/mkdir whose result the
#     harness writes into is checked, an unusable $TMPDIR exits 2 with
#     `cannot create scratch under <dir> (<why>)` BEFORE any shim is
#     written, and a shim is never written outside the run scratch.
#     PATH shim logs argv0+rc+argv to a scratch file under a directory the
#     consumer is never told about (not the shim dir, not $EIGS_DIR, not their parents);
#     the path is baked into the shim (not exported; not named CA_*). cand_calls
#     counts NON-TRIVIAL invocations (a .eigs path or a non-flag positional).
#     --version/--api/--help/bare are `probe` and do not count. cand_calls=0
#     cannot be PASS (UNEXERCISED). Command rc 0 with cand_ok=0 cand_fail>0 is
#     SWALLOWED. EIGS_DIR is a COPY overlay (src/, lib/, top-level files; never
#     .git; src/eigenscript is the shim; dirs copied with cp -rL; a partial
#     copy's per-entry retry rm -rf's the destination first).
#     EIGENSCRIPT_BIN points at the shim; EIGENSCRIPT_GFX is exported only
#     when CAND_HAS_GFX=1 or --gfx was given. consumer_skips counts ^SKIP lines
#     in the consumer's combined output; a PASS with skips is PASS|skips=N, not
#     a bare PASS. Every non-PASS row is followed by log|<name>|<line> (last 60
#     lines of combined output). CA_LOGS=<dir> copies those logs before cleanup.
#   tools/consumer_acceptance.sh --self-test     plant a fault, prove it fires
#     As uid 0 it re-execs itself as an unprivileged user (see the root
#     residual below) so every plant runs in a world that can refuse it.
#   tools/consumer_acceptance.sh --plant-total N M
#     Self-test accounting probe: prints OK when N+M equals the declared
#     plant total, MISMATCH otherwise. Exists so the comparison can be
#     mutated and observed without re-running the whole self-test.
#
# Isolation (mechanical-gates §168): this script never mutates a sibling repo.
# Consumer commands run in the checkout as-is. Overrides, resolved per call:
#   CA_ECO      fixture or real ecosystem root (default: parent of this repo,
#               which is the sibling checkout only when this tree IS
#               EigenScriptEcosystem/EigenScript -- a git worktree must set
#               CA_ECO, otherwise the inventory is the worktree parent). The
#               resolved root is printed in the record header as eco_root=.
#   CA_TIMEOUT  per-consumer budget in seconds (default: 1800). Also bounds
#               the candidate --version probe.
#   CA_RECORD   record path (default: a temp file; the path is printed)
#   CA_DROP_BEFORE  self-test only: BEFORE the inventory scan, remove this
#                   consumer's checkout so the declared-set floor fires.
#                   Honoured ONLY if $CA_ECO/.ca_fixture exists, so it cannot
#                   reach a real sibling.
#   CA_FAULT    self-test only, same .ca_fixture gate:
#                 stop_after=N       break the wave after N examined rows
#                                    (the completed-record path for
#                                    examined < inventory; interrupt is plant D)
#                 empty_skip_reason  append a SKIP row with an empty reason
#                 foreign_record     replace the record with a different
#                                    run_id before the first row (plant O)
#                 fail_footer        make the final footer write fail after
#                                    planting a FAIL body (plant P)
#                 pause_before_rename sleep after writing the footer temp and
#                                    before mv (plant J2); INT/TERM/HUP then
#                                    is INCOMPLETE
#                 show_tmp           print record_tmp_dir=<dir> of the replace
#                                    temp (must equal the record's directory)
#                 overlay_partial    force the first cp -rL of src/ to fail
#                                    after creating dst/src/data, so the
#                                    per-entry retry runs (plant overlay-partial)
#                 record_floor=N     fixture-gated record floor of N (plant B3)
#                 pretend_root       self-test: take the uid-0 decision branch
#                                    of plant stale-unwritable (on a non-root
#                                    box no drop tool applies, so the plant
#                                    SKIPs by name and is counted)
#
# Record lifecycle (the class, fail-closed):
#   ONCE THE RUN HAS TAKEN THE RECORD PATH -- that is, from the moment it
#   takes the record lock and invalidates the previous file, to exit --
#   the file at CA_RECORD is either THIS run's record in a truthful state,
#   or absent: never a previous run's PASS, never a foreign PASS.
#   BEFORE that point the previous record is left BYTE-IDENTICAL, on
#   purpose. A usage error (candidate missing or not executable,
#   CA_TIMEOUT non-numeric, no timeout(1)), a second invocation on the
#   same CA_RECORD, and a scratch refusal (an unusable $TMPDIR) all exit 2
#   having touched no record path at all -- so if a previous run left a
#   VERDICT: PASS there, that PASS is still there, unchanged, after the
#   exit-2 run. Plant scratch-fail-closed ASSERTS record_unchanged=yes;
#   this is the designed behaviour, not a gap. THE CONSEQUENCE FOR A
#   CALLER: a wave driver must read the EXIT STATUS. Reading only the file
#   can read a stale PASS from an earlier run that this run never
#   replaced. rc 0 with VERDICT: PASS in the file is the only green.
#   Every write that
#   participates goes through write_record, which returns nonzero on any
#   failure and is checked (write_record || die_record "why"). No || true
#   on a record write. write_record append refuses unless the file's
#   header carries run_id=$RUN_ID (empty files, used by in-place clobber,
#   are the one exception).
#
#   Exclusive ownership: a mkdir lock on <record>.lock.d is taken BEFORE
#   invalidating the previous record and held through cleanup. A second
#   invocation on the same CA_RECORD refuses immediately (exit 2, touches
#   nothing). A stale lock (holder pid dead) is reclaimed with a note in
#   the header.
#
#   First actions of run_mode, before the inventory scan, before the
#   shim, before the candidate: install traps, take the record lock,
#   create the scratch dir, invalidate the previous record, write the
#   INCOMPLETE header (inventory=PENDING until the scan finishes -- that
#   is truthful). Invalidating fails closed: if the previous file cannot
#   be moved aside, it is truncated / overwritten in place so it is
#   unreadable as PASS, then the run FAILS immediately, exit 1.
#   VERDICT: PASS is printed only after the final record is written to a
#   temp next to the record (same directory, then mv). RECORD_FINISHED=1
#   is set only after that rename returns 0. The INT/TERM/HUP/EXIT trap
#   re-reads the record's VERDICT: line (and status=COMPLETE) rather than
#   trusting the variable, so HUP-after-rename is still a completed run
#   and a signal between footer-write and rename is INCOMPLETE. Exactly
#   one VERDICT: line can ever exist in the footer writer's output.
#   Static argument validation (candidate present and executable,
#   CA_TIMEOUT numeric, timeout(1) present) happens BEFORE any record
#   path is touched; a usage error exits 2 and leaves a previous record's
#   bytes unchanged.
#   die_record leaves RECORD_FINISHED=0 when its FAIL footer did not
#   land, so finish_incomplete still runs (append INCOMPLETE, or clobber
#   a foreign file in place).
#
# Consumers run as a background job (setsid + timeout, wait in this shell)
# so a trap can kill the in-flight process group without waiting out the
# consumer budget. Block bodies run under bash -e -o pipefail -c.
# The consumer inherits EIGS/EIGENSCRIPT/EIGS_DIR/EIGENSCRIPT_DIR/
# EIGENSCRIPT_BIN (and EIGENSCRIPT_GFX only when the candidate actually
# has gfx) and the shim PATH; every CA_* name is unset in that
# environment. run_cleanup removes the run's scratch on every exit path.
#
# Residuals stated in the record header (not fixed here):
#   - any same-uid consumer that finds the shim script and reads it can
#     still recover the call-log path; the evidence is non-accidental,
#     not adversary-proof.
#   - a missing tool referenced inside a called script (not in PREREQS
#     and not a top-level token) still shows as a generic FAIL.
#   - ouroboros aot/build.sh keys libeigsrt.a on pwd -P of $EIGS_DIR/src,
#     so every run rebuilds against the per-run overlay path and leaves
#     aot/build/.libsrc stamped with a dead path. Known cost of the
#     overlay; not a bug. DMG#73 (hard-coded sibling path) is visible
#     via sibling_binary_present=, not worked around.
#   - SWALLOWED on an all-negative suite: a suite whose every candidate
#     call expects rc≠0 must include one positive invocation.
#   - a row-wide cand_calls count cannot certify WHICH work the candidate
#     did when an absolute-path subprocess then accepts with another
#     runtime after one candidate setup call.
#   - stdin-fed programs and `eigenscript --test` count as probe; no
#     real consumer uses them.
#   - a consumer that resolves the runtime by a path IT COMPUTES --
#     ./eigenscript-full inside its own checkout, or a glob over one --
#     is not on PATH, so neither the farm nor the sweep can reach it. Such
#     a row reads UNEXERCISED (cand_calls=0), never PASS; plant
#     variant-glob-residual pins exactly that behaviour, so closing this
#     residual turns that plant red on purpose.
#   - PATH-EDIT RULE AND ITS RESIDUAL (round 6, the class change). Round
#     5 matched a PATH assignment by SYNTACTIC POSITION and claimed "a
#     LITERAL absolute component is no longer a residual". That claim was
#     FALSE as written: Fable r5 walked through six positions the list
#     did not name -- `env PATH=/abs:$PATH cmd`, `exec env PATH=...`,
#     `bash -c 'PATH=/abs:$PATH cmd'`, a heredoc BODY fed to bash, a
#     Makefile TOP-LEVEL `export PATH := /abs:$(PATH)`, and
#     `export PATH=~user/...` -- all six PASS while the stale binary ran.
#     So the rule is now the
#     SUBSTRING: any occurrence of PATH= / PATH+= / PATH := / PATH ?=
#     (word-bounded on the left) ANYWHERE in a scanned text line --
#     comments and heredoc bodies included, Makefiles in FULL, .eigs
#     string literals, a workflow runCmd -- is a PATH edit; each RHS
#     component that is a LITERAL absolute directory (after ~ and ~user
#     expansion via getent passwd) existing on this box outside $SHIM,
#     $FARM, the row's scratch $HOME and the checkout is
#     FAIL|path-edit:<dir> by name before the row runs.
#     THE PRICE, stated: the rule is over-broad in the SAFE direction. A
#     line that merely NAMES a PATH edit -- a comment, a usage string, a
#     README example inside a .sh, a make variable holding one -- refuses
#     that consumer's row BY NAME. It refuses a row it could have run; it
#     never runs a row it should have refused. All 16 real consumers
#     report ZERO edits under the new rule (plan prints the scan's own
#     witness, pathexamined|<consumer>|<files>|<edits>).
#     WHAT IS STILL A RESIDUAL -- stated as MEASURED, not as "none".
#     The substring rule did not remove the hole; it MOVED it from line
#     position to FILE KIND and COMPONENT PARSE. The scan sees every
#     SCANNED FILE KIND -- .sh, .bash, .zsh, an extensionless file with a
#     #! line, a .yml at its runCmd, Makefile and .mk, and .eigs -- and,
#     inside those, every literal component it can PARSE. Three residual
#     SHAPES are left (ledger: issue #1229):
#       (a) FILE KINDS OUTSIDE THAT LIST: a PATH edit in a shell string
#           inside a .py file (subprocess.run("PATH=/abs:$PATH ...",
#           shell=True)), a Makefile.in the row itself copies to
#           Makefile, and an extensionless file with no shebang that the
#           row sources.
#       (b) COMPONENTS THE SPLITTER CANNOT PARSE:
#           PATH="/abs${PATH:+:$PATH}" (the first component reads as
#           /abs${PATH, which holds a $ and is taken as computed), a
#           value continued onto the next physical line with a trailing
#           backslash, and $'...' ANSI-C quoting.
#       (c) COMPUTED COMPONENTS: $(cat dir.txt), a $VAR other than
#           $HOME/$PWD/$PATH, or an edit made through a non-shell API
#           (python os.environ["PATH"]). Plant path-edit-computed pins
#           this one.
#     NONE of the 16 real consumers has any of those shapes: measured
#     over all 16 checkouts, every file kind, .git excluded, the only
#     PATH= lines in the ecosystem are five .devcontainer/Dockerfile
#     `ENV PATH=` lines (DMG, dynamics, eddy, phugoid, Tidepool), and a
#     Dockerfile is not the acceptance command.
#     CONTAINMENT IS THE RESOLVED FORM ONLY (round 7, Astra r6): round 6
#     kept the allowance when EITHER the written or the resolved form was
#     under an allowed prefix, so <checkout>/../../<absdir> and a symlink
#     inside the checkout pointing outside it both read PASS while the
#     stale binary ran. Every allowed prefix is resolved on the same
#     terms, so a checkout or scratch reached THROUGH a symlink is still
#     allowed, and the offender is NAMED by its resolved directory (the
#     written form rides along in the preflight log line).
#     The round-4 wording ("outside $HOME") was wrong in effect too: with
#     HOME scratched, the developer's REAL home is an absolute directory
#     outside the row's $HOME, and Fable r4 reached
#     ~/.local/bin/eigenscript-full.stale (0.21.0) under a PASS row.
#   - FARM-WRAPPER RESIDUAL: each farm entry EXECS the tool at its
#     original absolute location, so a farmed, inherited wrapper that
#     resolves its own location -- exec "$(dirname "$(readlink -f
#     "$0")")/eigenscript" -- still reaches the stale eigenscript
#     sitting beside it in the inherited directory (Fable r4 p2). This
#     is the price of running tools in place, and running them in place
#     is what keeps a virtualenv working. No consumer ships such a
#     wrapper. The only closures are an execve WITNESS (an LD_PRELOAD
#     interposer that logs every execve and fails the row on an
#     eigenscript* target) or a MOUNT NAMESPACE that unmounts the
#     inherited directories; both are deferred, and plant
#     farm-wrapper-sibling PINS the residual -- it FIRES only while the
#     stale sibling is still reachable, and goes red on purpose the day
#     one of those closures lands.
#   - a PATH directory that is executable but not READABLE (mode 0111)
#     cannot be enumerated: nothing from it is farmed and nothing from it
#     is on the row's PATH either -- fail closed, not fall through.
#   - a Dockerfile RUN line is not scanned for invocations: it builds the
#     image, it is not the acceptance command.
#   - the unwritable-directory plants cannot be planted as uid 0. The
#     WHOLE self-test therefore re-runs itself as an unprivileged user
#     when it starts as root (runuser/setpriv + nobody, a drop root it
#     chowns, TMPDIR inside it, stdout and exit status propagated). With
#     no drop tool, or when the probe under that user fails, BOTH
#     unwritable plants SKIP BY NAME and the final line reports
#     skipped=2 -- never a silent OK.
#
# examined != inventory on a COMPLETED record is unreachable without a
# broken loop: the production path that stops early is an interrupt, and
# that writes INCOMPLETE (plant D). The completed-record clause is planted
# by CA_FAULT=stop_after=N under .ca_fixture (plant early-stop). The
# honest control also pins inventory=2 examined=2 by grep.
#
# CA-GUARD: comments name the checks the self-test guts in isolation.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

# CA-GUARD:stderr-capture
# Self-test only. Every invocation of this script duplicates its OWN stderr
# into the capture file the self-test names, so a plant that discards both
# streams (`>/dev/null 2>&1`) cannot hide a diagnostic from the
# no-unbound-variable check. Astra r2 01: plant E discarded stderr, an
# unbound variable on the rc-124 path printed `critic_probe: unbound
# variable`, and the self-test still read unbound=0. The duplication
# happens INSIDE the child, after it starts, so no caller redirection can
# defeat it. CA_* names are stripped from every consumer environment, so a
# consumer never inherits this.
if [ -n "${CA_STDERR_CAP:-}" ]; then
  exec 2> >(tee -a "$CA_STDERR_CAP" >&2)
fi

# Repos that pin this runtime but are deliberately NOT acceptance-gated. Each
# needs a reason -- an unexplained exclusion is how a consumer goes missing.
declare -A EXCLUDED=(
  [EigenAttention]="parked (see ecosystem-public notes)"
  [EigenAttic]="parked"
  [tmp]="scratch directory, not a repo"
  [legibility-experiment]="experiment, no acceptance suite"
  [awesome-eigenscript]="link list, nothing to run"
  [eigs-package-template]="template, exercised by the package tests upstream"
  [homebrew-eigenscript]="tap; exercised by the release workflow"
  [EigenOS]="deliberately unpinned sibling -- its own boot gates apply"
)

# Consumers whose CI does NOT use devcontainers/ci, so no runCmd exists to
# derive from: they build the runtime in a plain `run:` step. Declared here
# with the reason, because the alternative -- scraping arbitrary `run:` steps --
# would happily pick up a setup step and call it acceptance. Derive where
# derivable, declare where not, never silently skip.
declare -A DECLARED=(
  [eigen-edit]="bash tests/test_smoke.sh"
  [eigen-sheet]="bash tests/test_smoke.sh"
  [EigenMiniSat]="python3 -m unittest discover -s benchmarks -p 'test_*.py' && bash tests/run_smoke.sh && bash tests/run_proof_check.sh && eigenscript minisat.eigs --proof-bench --size 1"
  [EigenGauntlet]="bash tests/run_smoke.sh"
)

# Tools a consumer's command needs that are not the candidate. Keyed by
# repo name; also unioned with top-level tokens of the command itself
# (go/java/python3/make). A missing tool is UNRUNNABLE|prereq:<tool>,
# not a candidate regression (mechanical-gates §170).
declare -A PREREQS=(
  [eddy]="go java"
  [EigenMiniSat]="drat-trim"
  [dynamics]="gfx"
)

# Declared consumer set. plan and run FAIL by name when a member is absent
# from the scanned inventory, or when a pinning repo is present but not
# in this list (the declaration must be updated deliberately). Fixtures
# skip this list unless $ECO/.ca_expected names one. The previous
# committed record's row count is a second floor (reports/consumer_acceptance/*.record,
# newest).
EXPECTED_CONSUMERS=(
  DeslanStudio
  DMG
  dynamics
  eddy
  eigen-edit
  EigenGauntlet
  EigenMiniSat
  EigenRegex
  eigen-sheet
  iLambdaAi
  liferaft
  ouroboros
  phugoid
  polymethod
  tidelog
  Tidepool
)

say() { printf '%s\n' "$*"; }

# CA-GUARD:scratch-tag
# Every scratch directory this script creates in the OUTER tmp carries an
# optional tag so a scan can tell ENTRIES CREATED BY THIS RUN from a
# concurrent tenant's. Production leaves it empty; the self-test exports a
# per-run token (Fable/Astra r3: a concurrent self-test's /tmp/ca-st.* was
# read as this run's leftover and the self-test printed a false FAIL).
# Sanitised, because it lands in a mktemp template.
scratch_tag() {
  local raw="${CA_SCRATCH_TAG:-}"
  raw="$(printf '%s' "$raw" | tr -cd 'A-Za-z0-9._-')"
  printf '%s' "$raw"
}

# A scratch path the harness will WRITE INTO must exist and be non-empty.
# Fable r3 (critical): `WORK="$(mktemp -d ...)"` was unchecked under
# `set -uo pipefail` (no -e), so an unusable $TMPDIR gave WORK="" and
# SHIM="/bin" -- and a round-2 run as root wrote stub shims into /usr/bin
# on the dev box. Fail closed, by name, before any shim is written.
scratch_die() {
  say "consumer_acceptance: cannot create scratch under ${TMPDIR:-/tmp} ($1)"
  RUN_RC=2
  exit 2
}

# CA-GUARD:scratch-fail-closed
# $1 = path, $2 = why. Non-empty, a real directory, and (when $WORK is
# already known) under $WORK's realpath. A shim is never written anywhere
# else.
# The resolved path is handed back in SCRATCH_REAL, never on stdout: this
# function EXITS the process when the check fails, and a command
# substitution would exit only the subshell (and swallow the diagnostic).
WORK_REAL=""
SCRATCH_REAL=""
assert_scratch_dir() {
  local d="${1:-}" why="${2:-}" dr=""
  SCRATCH_REAL=""
  [ -n "$d" ] || scratch_die "$why: empty path"
  [ -d "$d" ] || scratch_die "$why: not a directory ($d)"
  dr="$(cd -P -- "$d" 2>/dev/null && pwd)"
  [ -n "$dr" ] || scratch_die "$why: unresolvable ($d)"
  if [ -n "${WORK_REAL:-}" ]; then
    case "$dr" in
      "$WORK_REAL"|"$WORK_REAL"/*) ;;
      *) scratch_die "$why: $dr is outside the run scratch $WORK_REAL" ;;
    esac
  fi
  SCRATCH_REAL="$dr"
}
# CA-GUARD:end-scratch-fail-closed

# Per-call: CA_ECO must be read HERE, not once at file load, so a self-test
# child with an override is not silently aimed at the real siblings.
resolve_eco() {
  if [ -n "${CA_ECO:-}" ]; then
    ECO="$(cd "$CA_ECO" && pwd)" || { say "consumer_acceptance: CA_ECO is not a directory: $CA_ECO"; exit 2; }
  else
    ECO="$(cd "$HERE/.." && pwd)"
  fi
}

# A repo counts as a consumer if it pins the runtime, in EITHER form: the
# devcontainer ARG, or a --branch clone in CI. Two forms, because using only
# the first is precisely how the hand-listed board lost two consumers.
pin_of() {
  local r="$1" p=""
  p="$(grep -ho 'ARG EIGS_REF=[^ ]*' "$ECO/$r/.devcontainer/Dockerfile" 2>/dev/null | head -1 | cut -d= -f2)"
  [ -n "$p" ] && { printf '%s' "$p"; return; }
  p="$(grep -rho -- '--branch v[0-9][0-9.]*' "$ECO/$r/.github/workflows/" 2>/dev/null | head -1 | awk '{print $2}')"
  printf '%s' "$p"
}

# The acceptance command is whatever CI actually runs -- derived, never typed,
# so it cannot drift from the thing the consumer considers passing.
# First-workflow-wins: prefer ci.yml, then tests.yml, then test.yml. If none
# of those has a runCmd and MORE THAN ONE other workflow does, the row is
# UNRUNNABLE|ambiguous-workflow:<names> (ACCEPT_AMBIGUOUS is set, rc 1).
ACCEPT_WF=""
ACCEPT_CMD=""
ACCEPT_AMBIGUOUS=""
accept_cmd_of() {
  local r wfdir f p cmd base
  r="$1"
  wfdir="$ECO/$r/.github/workflows"
  local -a others
  ACCEPT_WF=""
  ACCEPT_CMD=""
  ACCEPT_AMBIGUOUS=""
  # CA-GUARD:workflow-prefer
  for p in ci.yml tests.yml test.yml; do
    f="$wfdir/$p"
    [ -f "$f" ] || continue
    if cmd="$(python3 "$HERE/tools/_extract_runcmd.py" "$f")"; then
      ACCEPT_WF="$p"
      ACCEPT_CMD="$cmd"
      return 0
    fi
  done
  others=()
  for f in "$wfdir"/*.y*ml; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      ci.yml|tests.yml|test.yml) continue ;;
    esac
    if python3 "$HERE/tools/_extract_runcmd.py" "$f" >/dev/null 2>&1; then
      others+=("$base")
    fi
  done
  if [ "${#others[@]}" -eq 1 ]; then
    ACCEPT_WF="${others[0]}"
    ACCEPT_CMD="$(python3 "$HERE/tools/_extract_runcmd.py" "$wfdir/${others[0]}")" || return 1
    return 0
  fi
  if [ "${#others[@]}" -gt 1 ]; then
    local IFS=','
    ACCEPT_AMBIGUOUS="${others[*]}"
    ACCEPT_WF=""
    return 1
  fi
  return 1
}

# Executable names this consumer INVOKES. Derived by
# tools/_derive_variants.py from INVOCATION POSITIONS only -- the first word
# of a simple command in shell text (`*.sh`, an extensionless `#!` script,
# Makefile recipe lines, a workflow's runCmd), the word after
# exec/env/nohup/setsid/`timeout N`/`xvfb-run ...`/`command -v`, the value of
# a variable assignment or a `${VAR:-default}`, the first element of a
# Python subprocess/os.system/os.exec*/shutil.which call or an
# os.environ.get default, and the first string of an .eigs
# exec_capture/proc_spawn call. Round 2 took every TOKEN in every text file
# and so declared a Dockerfile path, a skill name, bench JSON keys, a comment
# and a release-asset URL as prerequisites of three live consumers (#1213).
#
# Sets DERIVED_NAMES (space separated, deduplicated, first-seen order),
# DERIVED_EXCLUDED (one `<name>|<file>:<line>` per line, every occurrence
# that is NOT an invocation) and DERIVED_EXAMINED (files|occurrences, the
# enumeration's own witness). Fails CLOSED: if the deriver cannot run, or
# emits no `examined|` witness, DERIVED_RC is nonzero and the row is
# UNRUNNABLE|prereq:variant-derivation rather than an empty set.
DERIVED_NAMES=""
DERIVED_EXCLUDED=""
DERIVED_EXAMINED=""
DERIVED_RC=0

# stdin-free: prints the space-separated names of the variant| records in $1.
parse_variant_names() {
  local raw="${1:-}" line n out="" 
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      variant\|*) ;;
      *) continue ;;
    esac
    n="${line#variant|}"
    n="${n%%|*}"
    case " $out " in
      *" $n "*) continue ;;
    esac
    out="${out:+$out }$n"
  done <<< "$raw"
  printf '%s' "$out"
}

# CA-GUARD:path-edit-scan
# Fable r4 check 3 (the residual whose wording was wrong in effect): one
# `export PATH=/home/jon/.local/bin:$PATH` inside a consumer's own command
# reached the developer's REAL stale eigenscript-full.stale (0.21.0) while
# the row read PASS. The farm takes the stale files off the PATH the
# HARNESS hands the row; it cannot stop the row naming an absolute
# directory. So a literal absolute component that EXISTS on this box and is
# outside $SHIM, $FARM, the row's scratch $HOME and the consumer's own
# checkout is refused BY NAME, before the row runs.
# ROUND 6 (Fable r5): the deriver now matches the SUBSTRING `PATH=` /
# `PATH+=` / `PATH :=` / `PATH ?=` anywhere in a scanned line -- comments
# and heredoc bodies included, Makefiles in full, `.eigs` string literals
# too -- instead of a list of syntactic positions. That did not remove the
# hole, it MOVED it to file kind and component parse; the three residual
# shapes that remain are enumerated in the header (ledger #1229). This
# side resolves what the deriver reports RAW:
# `~` / `~/x` is the ROW's scratch HOME (allowed, exactly like $HOME), and
# `~user/x` resolves from the PASSWD DATABASE, which is how Fable r5
# reached an absolute directory through `~jon/../..` under a PASS row.
# THE PRICE, stated: a line that merely NAMES a PATH edit (a comment, a
# usage string) refuses its row by name. Over-broad in the SAFE direction.
# Prints `<component>|<file>:<line>` for the first offender, rc 0 when there
# is one, and NOTHING else on stdout (the caller reads it back).
# Residual (narrowed): a component computed at runtime -- `$(cat dir.txt)`,
# `$SOMEVAR` -- is not a literal, so it is not seen. Pinned by plant
# path-edit-computed.
path_edit_offender() {
  local repo="$1" home="$2" edits="$3" comp loc
  local _rest _user _real _skip _cand _croot
  while IFS= read -r comp || [ -n "$comp" ]; do
    [ -n "$comp" ] || continue
    loc="${comp#*|}"
    comp="${comp%%|*}"
    # CA-GUARD:path-edit-tilde
    case "$comp" in
      '~'|'~/'*) continue ;;    # the ROW's scratch HOME: allowed
      '~'*)
        _rest="${comp#\~}"
        _user="${_rest%%/*}"
        case "$_rest" in
          */*) _rest="/${_rest#*/}" ;;
          *)   _rest="" ;;
        esac
        _real="$(getent passwd "$_user" 2>/dev/null | cut -d: -f6)"
        [ -n "$_real" ] || continue   # no such user: nothing to resolve
        comp="$_real$_rest"
        ;;
    esac
    # CA-GUARD:end-path-edit-tilde
    case "$comp" in
      /*) ;;
      *) continue ;;            # relative, $HOME-rooted or computed
    esac
    case "$comp" in
      *'$'*|*'`'*) continue ;;  # a runtime-computed component: the residual
    esac
    [ -d "$comp" ] || continue   # not a directory ON THIS BOX
    # CA-GUARD:path-edit-containment
    # ROUND 7 (Astra r6 check 2, the false PASS): containment is decided on
    # the RESOLVED form ONLY. Round 6 kept the allowance if EITHER the
    # written OR the resolved form was under an allowed prefix, so
    # `<checkout>/../../<absdir>` and a symlink INSIDE the checkout pointing
    # outside it both read PASS while the stale eigenscript in <absdir> ran.
    # The written form now grants nothing. Each allowed prefix ($SHIM,
    # $FARM, the row's scratch $HOME, the consumer's checkout) is resolved
    # on the same terms, so a checkout or scratch reached THROUGH a symlink
    # is still allowed -- containment must not become a spelling test in the
    # other direction either. The offender is reported by its RESOLVED name,
    # because that is the directory the row would actually reach; the
    # written form rides along in the preflight log line.
    _real="$(cd -P -- "$comp" 2>/dev/null && pwd)" || _real=""
    [ -n "$_real" ] || _real="$comp"
    _skip=0
    for _cand in "${SHIM:-}" "${FARM:-}" "$home" "$repo"; do
      [ -n "$_cand" ] || continue
      _croot="$(cd -P -- "$_cand" 2>/dev/null && pwd)" || _croot=""
      [ -n "$_croot" ] || _croot="$_cand"
      case "$_real" in
        "$_croot"|"$_croot"/*) _skip=1 ;;
      esac
    done
    [ "$_skip" -eq 0 ] || continue
    printf '%s|%s|%s' "$_real" "$loc" "$comp"
    # CA-GUARD:end-path-edit-containment
    return 0
  done <<< "$edits"
  return 1
}
# CA-GUARD:end-path-edit-scan

derive_variants() {
  local r dir raw line n rc=0
  r="${1:-}"
  dir="${ECO:-}/$r"
  DERIVED_NAMES=""
  DERIVED_EXCLUDED=""
  DERIVED_EXAMINED=""
  DERIVED_PATHEDITS=""
  DERIVED_PATHEXAMINED=""
  DERIVED_RC=0
  [ -d "$dir" ] || return 0
  raw="$(python3 "$HERE/tools/_derive_variants.py" "$dir" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    DERIVED_RC="$rc"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      variant\|*)
        n="${line#variant|}"
        n="${n%%|*}"
        case " $DERIVED_NAMES " in
          *" $n "*) ;;
          *) DERIVED_NAMES="${DERIVED_NAMES:+$DERIVED_NAMES }$n" ;;
        esac
        ;;
      excluded\|*)
        DERIVED_EXCLUDED="${DERIVED_EXCLUDED}${line#excluded|}"$'\n'
        ;;
      pathedit\|*)
        DERIVED_PATHEDITS="${DERIVED_PATHEDITS}${line#pathedit|}"$'\n'
        ;;
      pathexamined\|*)
        DERIVED_PATHEXAMINED="${line#pathexamined|}"
        ;;
      examined\|*)
        DERIVED_EXAMINED="${line#examined|}"
        ;;
    esac
  done <<< "$raw"
  # CA-GUARD:derive-examined
  if [ -z "$DERIVED_EXAMINED" ]; then
    DERIVED_RC=3
  fi
  return 0
}

# For a DECLARED command, every bash/sh/python3/python file token must
# exist, not only the first token of each segment. `python3 -m unittest
# discover -s DIR` checks DIR as a directory. Compound commands (&& / ;)
# are checked segment by segment. Prints the first missing path (relative
# to the repo) or nothing. Mechanical-gates §170: a declared fallback is
# a hand-typed claim and is verified like a derived one.
_declared_missing_one() {
  local repo="$1" file="$2" want="${3:-file}"
  [ -n "$file" ] || return 1
  case "$file" in
    /*)
      if [ "$want" = dir ]; then
        [ -d "$file" ] || { printf '%s' "$file"; return 0; }
      else
        [ -f "$file" ] || { printf '%s' "$file"; return 0; }
      fi
      ;;
    *)
      if [ "$want" = dir ]; then
        [ -d "$repo/$file" ] || { printf '%s' "$file"; return 0; }
      else
        [ -f "$repo/$file" ] || { printf '%s' "$file"; return 0; }
      fi
      ;;
  esac
  return 1
}

declared_missing_file() {
  local repo="$1" cmd="$2"
  local norm piece tok nxt rest i
  local -a toks
  norm="${cmd//&&/$'\n'}"
  norm="${norm//;/$'\n'}"
  while IFS= read -r piece || [ -n "$piece" ]; do
    piece="${piece#"${piece%%[![:space:]]*}"}"
    piece="${piece%"${piece##*[![:space:]]}"}"
    [ -z "$piece" ] && continue
    # CA-GUARD:noglob-split
    local glob_off=0
    case "$-" in *f*) glob_off=1 ;; esac
    set -f
    # shellcheck disable=SC2086
    set -- $piece
    toks=("$@")
    [ "$glob_off" -eq 0 ] && set +f
    i=0
    while [ "$i" -lt "${#toks[@]}" ]; do
      tok="${toks[$i]}"
      nxt=""
      [ $((i + 1)) -lt "${#toks[@]}" ] && nxt="${toks[$((i + 1))]}"
      case "$tok" in
        bash|sh)
          case "$nxt" in
            ''|-*) ;;
            *)
              if _declared_missing_one "$repo" "$nxt" file; then
                return 0
              fi
              ;;
          esac
          ;;
        python3|python)
          if [ "$nxt" = "-m" ]; then
            rest=$((i + 2))
            if [ "$rest" -lt "${#toks[@]}" ] && [ "${toks[$rest]}" = "unittest" ]; then
              rest=$((rest + 1))
              while [ "$rest" -lt "${#toks[@]}" ]; do
                if [ "${toks[$rest]}" = "-s" ] && [ $((rest + 1)) -lt "${#toks[@]}" ]; then
                  if _declared_missing_one "$repo" "${toks[$((rest + 1))]}" dir; then
                    return 0
                  fi
                  break
                fi
                rest=$((rest + 1))
              done
            fi
          else
            case "$nxt" in
              ''|-*) ;;
              *)
                if _declared_missing_one "$repo" "$nxt" file; then
                  return 0
                fi
                ;;
            esac
          fi
          ;;
        *)
          case "$tok" in
            */*|*.sh|*.py|*.eigs)
              if _declared_missing_one "$repo" "$tok" file; then
                return 0
              fi
              ;;
          esac
          ;;
      esac
      i=$((i + 1))
    done
  done <<< "$norm"
  return 0
}

# First missing tool from PREREQS[name], fixture .ca_prereqs, and top-level
# command tokens (go/java/python3/python/make). `gfx` is a candidate
# capability (not a PATH tool): missing it is prereq:gfx-build. Prints
# the tool; rc 0 if something is missing, 1 if every named tool is present.
missing_prereq() {
  local name="$1" cmd="$2"
  local tools="" t piece first
  tools="${PREREQS[$name]:-}"
  if [ -f "${ECO:-}/.ca_fixture" ] && [ -f "$ECO/$name/.ca_prereqs" ]; then
    tools="$tools $(tr '\n' ' ' < "$ECO/$name/.ca_prereqs")"
  fi
  case "$cmd" in
    *gfx*) tools="$tools gfx" ;;
  esac
  local norm="${cmd//&&/$'\n'}"
  norm="${norm//;/$'\n'}"
  while IFS= read -r piece || [ -n "$piece" ]; do
    piece="${piece#"${piece%%[![:space:]]*}"}"
    [ -z "$piece" ] && continue
    # CA-GUARD:noglob-split
    local glob_off=0
    case "$-" in *f*) glob_off=1 ;; esac
    set -f
    # shellcheck disable=SC2086
    set -- $piece
    first="${1:-}"
    [ "$glob_off" -eq 0 ] && set +f
    case "$first" in
      go|java|python3|python|make) tools="$tools $first" ;;
    esac
  done <<< "$norm"
  for t in $tools; do
    [ -z "$t" ] && continue
    if [ "$t" = gfx ]; then
      # CA-GUARD:gfx-prereq
      if [ "${CAND_HAS_GFX:-0}" != 1 ]; then
        if [ "${CAND_HAS_GFX:-0}" = unknown ]; then
          printf 'gfx-build (probe rc %s)' "${CAND_GFX_RC:-?}"
        else
          printf 'gfx-build'
        fi
        return 0
      fi
      continue
    fi
    if ! command -v "$t" >/dev/null 2>&1; then
      printf '%s' "$t"
      return 0
    fi
  done
  return 1
}

# Walk up from the candidate until a directory whose src/eigenscript is
# that same file (-ef). Empty CAND_TREE is a bare binary: if $ECO/EigenScript
# also exists, run refuses (exit 2) rather than letting EIGS_DIR-fallback
# consumers do their tree work against the sibling.
derive_candidate_tree() {
  local cand="$1" dir
  CAND_TREE=""
  dir="$(cd "$(dirname "$cand")" && pwd)" || return 1
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -e "$dir/src/eigenscript" ] && [ "$dir/src/eigenscript" -ef "$cand" ]; then
      CAND_TREE="$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# Executable regular file, distinct from the candidate. Used before the
# wave (header) and after (footer); no→yes when a consumer created one.
sibling_is_present() {
  local p="${ECO:-}/EigenScript/src/eigenscript"
  if [ -f "$p" ] && [ -x "$p" ] && [ ! "$p" -ef "${CAND_ABS:-/}" ]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# Overlay of the candidate tree under the run scratch: a COPY of src/,
# lib/, and top-level files (including dotfiles a build may read, e.g.
# .gitignore; never .git). Dirs are copied with cp -rL so writes through
# a symlink cannot reach outside the overlay. A link that cannot be
# dereferenced is skipped and noted (overlay_skipped=). src/eigenscript
# is replaced by the counting shim. Never mutates the real tree.
# CA-GUARD:overlay-variant-shim
# The TWIN SITE of the PATH farm (Fable r3): EIGS_DIR is a cp -rL COPY of
# the candidate tree's src/, so with a tree candidate and no --full the
# consumer's "$EIGS_DIR/src/eigenscript-full" ran the copied sibling
# binary and the row read PASS. Every eigenscript* file the overlay hands
# out is therefore replaced: a covered candidate gets the same counting
# shim $SHIM carries, an uncovered name gets the same 127-shim, so the
# row is FAIL|undeclared-variant:<name> instead of a silent stale run.
OVERLAY_SHIMMED=""
overlay_shim_variants() {
  local dir="$1" f b
  [ -d "$dir" ] || return 0
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in
      eigenscript|eigenscript-*) ;;
      *) continue ;;
    esac
    rm -f "$f"
    if is_candidate_name "$b"; then
      cp "$SHIM/$b" "$f" || continue
    else
      write_127_shim "$f" "$b"
    fi
    chmod +x "$f"
    case " $OVERLAY_SHIMMED " in
      *" $b "*) ;;
      *) OVERLAY_SHIMMED="${OVERLAY_SHIMMED:+$OVERLAY_SHIMMED }$b" ;;
    esac
  done <<< "$(find "$dir" -maxdepth 1 ! -type d -name 'eigenscript*' 2>/dev/null || true)"
  return 0
}
# CA-GUARD:end-overlay-variant-shim

build_candidate_overlay() {
  local src="$1" dst="$2" item base s
  CAND_OVERLAY=""
  OVERLAY_SKIPPED=""
  OVERLAY_SHIMMED=""
  [ -n "$src" ] && [ -d "$src" ] || return 1
  mkdir -p "$dst"
  # CA-GUARD:overlay-copy
  overlay_copy_dir() {
    local from="$1" to="$2" tag="$3" s base first_ok=1
    if fixture_fault && [ "${CA_FAULT:-}" = overlay_partial ] && [ "$tag" = src ]; then
      mkdir -p "$to/data"
      first_ok=0
    elif cp -rL "$from" "$to" 2>/dev/null; then
      return 0
    else
      first_ok=0
    fi
    if [ "$first_ok" -eq 0 ]; then
      mkdir -p "$to"
      for s in "$from"/*; do
        [ -e "$s" ] || { OVERLAY_SKIPPED="${OVERLAY_SKIPPED:+$OVERLAY_SKIPPED }$tag/$(basename "$s")"; continue; }
        base="$(basename "$s")"
        # CA-GUARD:overlay-retry-rm
        rm -rf "$to/$base"
        cp -rL "$s" "$to/$base" 2>/dev/null || \
          OVERLAY_SKIPPED="${OVERLAY_SKIPPED:+$OVERLAY_SKIPPED }$tag/$base"
      done
    fi
  }
  if [ -d "$src/src" ]; then
    overlay_copy_dir "$src/src" "$dst/src" src
  else
    mkdir -p "$dst/src"
  fi
  rm -f "$dst/src/eigenscript"
  cp "$SHIM/eigenscript" "$dst/src/eigenscript"
  chmod +x "$dst/src/eigenscript"
  overlay_shim_variants "$dst/src"
  if [ -d "$src/lib" ]; then
    overlay_copy_dir "$src/lib" "$dst/lib" lib
  fi
  local nullglob_was=0 dotglob_was=0
  shopt -q nullglob && nullglob_was=1
  shopt -q dotglob && dotglob_was=1
  shopt -s nullglob dotglob
  for item in "$src"/*; do
    base="$(basename "$item")"
    case "$base" in
      .|..|.git|src|lib) continue ;;
    esac
    if [ -f "$item" ]; then
      cp -a "$item" "$dst/$base"
    elif [ -L "$item" ]; then
      cp -L "$item" "$dst/$base" 2>/dev/null || cp -a "$item" "$dst/$base"
    fi
  done
  if [ "$dotglob_was" -eq 0 ]; then
    shopt -u dotglob
  fi
  if [ "$nullglob_was" -eq 0 ]; then
    shopt -u nullglob
  fi
  overlay_shim_variants "$dst"
  overlay_shim_variants "$dst/lib"
  CAND_OVERLAY="$dst"
}

# Declared expected names for this ECO. Fixtures skip EXPECTED_CONSUMERS
# unless $ECO/.ca_expected lists them. Production always uses the table.
# Record floor: lexically greatest YYYY-MM-DD-… filename, never mtime.
# Fixtures read $ECO/reports/consumer_acceptance when that dir exists so
# plant B3 can reach the floor; CA_FAULT=record_floor=N overrides.
load_expected_list() {
  EXPECTED_LIST=()
  RECORD_FLOOR=0
  RECORD_STRAY=""
  if [ -f "${ECO:-}/.ca_expected" ]; then
    local n
    while IFS= read -r n || [ -n "$n" ]; do
      n="${n#"${n%%[![:space:]]*}"}"
      n="${n%"${n##*[![:space:]]}"}"
      [ -z "$n" ] && continue
      EXPECTED_LIST+=("$n")
    done < "$ECO/.ca_expected"
  elif [ ! -f "${ECO:-}/.ca_fixture" ]; then
    EXPECTED_LIST=("${EXPECTED_CONSUMERS[@]}")
  fi
  local rec_dir="" f newest="" rows b nb
  if fixture_fault; then
    case "${CA_FAULT:-}" in
      record_floor=*)
        rec_dir="__fault__"
        rows="${CA_FAULT#record_floor=}"
        ;;
    esac
  fi
  if [ -z "$rec_dir" ]; then
    if [ -f "${ECO:-}/.ca_fixture" ] && [ -d "${ECO:-}/reports/consumer_acceptance" ]; then
      rec_dir="$ECO/reports/consumer_acceptance"
    elif [ ! -f "${ECO:-}/.ca_fixture" ]; then
      rec_dir="$HERE/reports/consumer_acceptance"
    fi
  fi
  local computed=0
  RECORD_STRAY=""
  if [ "$rec_dir" = "__fault__" ]; then
    computed="${rows:-0}"
  elif [ -n "$rec_dir" ]; then
    newest=""
    for f in "$rec_dir"/*.record; do
      [ -f "$f" ] || continue
      b="$(basename "$f")"
      # CA-GUARD:record-dated-name
      # Only a DATED record counts. Round 2 iterated every *.record, so a
      # zzz.record raised the floor and a non-dated smoke.record LOWERED it
      # to its own row count and the run still said PASS (Fable r2 03). A
      # stray file in this directory is a FAIL by name, never a new floor.
      case "$b" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.record) ;;
        *)
          RECORD_STRAY="${RECORD_STRAY:+$RECORD_STRAY }$b"
          continue
          ;;
      esac
      if [ -z "$newest" ]; then
        newest="$f"
      else
        nb="$(basename "$newest")"
        if [ "$b" \> "$nb" ]; then
          newest="$f"
        fi
      fi
    done
    if [ -n "$newest" ]; then
      rows="$(grep -c '^row|' "$newest" 2>/dev/null || true)"
      computed="${rows:-0}"
    fi
  fi
  # CA-GUARD:record-floor
  RECORD_FLOOR="$computed"
}

# Scan ECO into GATE_* / SKIP_* arrays. Prints the plan listing iff $1=print.
# Does not print a verdict -- callers do. Diagnostics never go through stdout
# of a function whose result is captured (mechanical-gates: no $(( $(fn) ))).
# Globals: GATE_NAMES/PINS/CMDS/KINDS/WFS/VARS, SKIP_NAMES/PINS/REASONS, INVENTORY, GAPS.
scan_inventory() {
  local verbose=0
  [ "${1:-}" = print ] && verbose=1
  # Self-test plant B: drop a snapshotted consumer's checkout BEFORE the
  # scan so the declared-set floor fires (not only a later UNRUNNABLE).
  # The .ca_fixture marker is the only thing that unlocks this, so a
  # stray env var cannot delete a sibling (mechanical-gates §168).
  if [ -n "${CA_DROP_BEFORE:-}" ] && [ -f "${ECO:-}/.ca_fixture" ]; then
    rm -rf "$ECO/$CA_DROP_BEFORE"
  fi
  # Fixture-only pause so plant H can INT inside the scan window. The
  # production cost is one python fork per workflow; this sleep is the
  # deterministic stand-in under .ca_fixture, not a production delay.
  if [ -f "${ECO:-}/.ca_fixture" ] && [ -n "${CA_SCAN_PAUSE:-}" ]; then
    if [ -n "${CA_SCAN_READY:-}" ]; then
      printf 'ready\n' > "$CA_SCAN_READY"
    fi
    # Background + wait, not a foreground sleep: a trapped INT/TERM is
    # delivered during wait, matching run_bounded. A foreground sleep
    # swallows the signal until it exits and the trap never runs.
    sleep "$CA_SCAN_PAUSE" &
    wait $! || true
  fi
  GATE_NAMES=(); GATE_PINS=(); GATE_CMDS=(); GATE_KINDS=(); GATE_WFS=(); GATE_VARS=()
  SKIP_NAMES=(); SKIP_PINS=(); SKIP_REASONS=()
  INVENTORY=0
  GAPS=0
  FLOOR_FAIL=0
  FLOOR_WHY=""
  load_expected_list
  local r pin cmd d kind gap_why miss vnames wf vexcl vexam exline vpedits peline
  local vpexam
  local nullglob_was=0
  shopt -q nullglob && nullglob_was=1
  shopt -s nullglob
  for d in "$ECO"/*/; do
    r="$(basename "$d")"
    [ "$r" = "EigenScript" ] && continue
    pin="$(pin_of "$r")"
    if [ -z "$pin" ]; then
      # Not a consumer. Only complain if it is also unexplained AND looks live.
      if [ "$verbose" -eq 1 ]; then
        [ -n "${EXCLUDED[$r]:-}" ] || [ ! -d "$d/.git" ] || say "  note   $r: pins nothing, not excluded -- not gated"
      fi
      continue
    fi
    if [ -n "${EXCLUDED[$r]:-}" ]; then
      SKIP_NAMES+=("$r")
      SKIP_PINS+=("$pin")
      SKIP_REASONS+=("${EXCLUDED[$r]}")
      if [ "$verbose" -eq 1 ]; then
        say "  skip   $r  ($pin) -- ${EXCLUDED[$r]}"
      fi
      continue
    fi
    cmd=""
    kind=""
    gap_why=""
    wf=""
    # GATE_VARS feeds the PLAN listing only; run mode re-derives per row
    # in run_one (freshly, so a tree that changes between the scan and the
    # row is caught), so deriving here as well would be one python walk of
    # every checkout for nothing.
    vnames=""
    vpedits=""
    vexcl=""
    vexam=""
    vpexam=""
    if [ "$verbose" -eq 1 ]; then
      derive_variants "$r"
      vnames="$DERIVED_NAMES"
      vexcl="$DERIVED_EXCLUDED"
      vexam="$DERIVED_EXAMINED"
      vpedits="$DERIVED_PATHEDITS"
      vpexam="$DERIVED_PATHEXAMINED"
      if [ "${DERIVED_RC:-0}" -ne 0 ]; then
        GAPS=$((GAPS + 1))
        gap_why="${gap_why:+$gap_why; }variant derivation failed (rc=$DERIVED_RC)"
        kind=gap
      fi
    fi
    if accept_cmd_of "$r"; then
      cmd="$ACCEPT_CMD"
      kind=derived
      wf="$ACCEPT_WF"
    elif [ -n "$ACCEPT_AMBIGUOUS" ]; then
      kind=ambiguous
      GAPS=$((GAPS + 1))
      gap_why="ambiguous-workflow:${ACCEPT_AMBIGUOUS}"
      wf="$ACCEPT_AMBIGUOUS"
    elif [ -n "${DECLARED[$r]:-}" ]; then
      cmd="${DECLARED[$r]}"
      kind=declared
    elif [ -f "${ECO:-}/.ca_fixture" ] && [ -f "$ECO/$r/.ca_declared" ]; then
      IFS= read -r cmd < "$ECO/$r/.ca_declared" || true
      kind=declared
    else
      kind=gap
      GAPS=$((GAPS + 1))
      gap_why="pins the runtime but no acceptance command could be derived"
    fi
    if [ "$kind" = declared ]; then
      miss=""
      # CA-GUARD:declared-file
      miss="$(declared_missing_file "$ECO/$r" "$cmd")"
      if [ -n "$miss" ]; then
        kind=gap
        cmd=""
        GAPS=$((GAPS + 1))
        gap_why="declared command's file does not exist: $miss"
      fi
    fi
    GATE_KINDS+=("$kind")
    GATE_NAMES+=("$r")
    GATE_PINS+=("$pin")
    GATE_CMDS+=("$cmd")
    GATE_WFS+=("$wf")
    GATE_VARS+=("$vnames")
    INVENTORY=$((INVENTORY + 1))
    if [ "$verbose" -eq 1 ]; then
      if [ "$kind" = declared ]; then
        say "  gate   $r  ($pin)  [declared -- CI has no runCmd to derive]"
        say "         $ $cmd"
      elif [ "$kind" = gap ] || [ "$kind" = ambiguous ]; then
        say "  GAP    $r  ($pin) -- ${gap_why:-pins the runtime but no acceptance command could be derived}"
      else
        local lines
        lines="$(printf '%s' "$cmd" | wc -l)"
        say "  gate   $r  ($pin)"
        if [ "$lines" -gt 0 ]; then
          say "         $ $(printf '%s' "$cmd" | head -1 | cut -c1-100) ... (+$lines lines)"
        else
          say "         $ $(printf '%s' "$cmd" | cut -c1-110)"
        fi
      fi
      if [ -n "$wf" ] && [ "$kind" = derived ]; then
        say "  workflow|$r|$wf"
      fi
      say "  variants|$r|${vnames:-eigenscript}"
      say "  variants|$r|examined:${vexam:-none}"
      # Every occurrence that did NOT enter the set, with its file:line, so
      # the derivation's choice is visible rather than silent.
      if [ -n "$vexcl" ]; then
        while IFS= read -r exline || [ -n "$exline" ]; do
          [ -n "$exline" ] || continue
          say "  variants|$r|excluded:$exline"
        done <<< "$vexcl"
      fi
      # CA-GUARD:pathexamined-witness
      # The PATH scan's OWN witness, <files>|<edits>, per consumer. It was
      # parsed and never printed before round 6, so "0 path_edit| lines"
      # could not be told apart from "the scan examined nothing" -- a
      # duration budget, not a witness (mechanical-gates 120-121).
      say "  pathexamined|$r|${vpexam:-none}"
      # CA-GUARD:end-pathexamined-witness
      # Every directory this consumer ADDS to PATH, with its file:line. A
      # literal absolute one that exists on this box outside the row's own
      # scratch is FAIL|path-edit:<dir> at run time.
      if [ -n "${vpedits:-}" ]; then
        while IFS= read -r peline || [ -n "$peline" ]; do
          [ -n "$peline" ] || continue
          say "  path_edit|$r|$peline"
        done <<< "$vpedits"
      fi
    fi
  done
  if [ "$nullglob_was" -eq 0 ]; then
    shopt -u nullglob
  fi
  # CA-GUARD:expected-floor
  # Declared names absent from disk, and pinning names not in the declared
  # set, are FAILs. Missing declared consumers are added as UNRUNNABLE rows
  # so examined == inventory still holds and the name is in the record.
  if [ "${#EXPECTED_LIST[@]}" -gt 0 ]; then
    local e found gi extra
    for e in "${EXPECTED_LIST[@]}"; do
      found=0
      for gi in "${GATE_NAMES[@]+"${GATE_NAMES[@]}"}" "${SKIP_NAMES[@]+"${SKIP_NAMES[@]}"}"; do
        [ "$gi" = "$e" ] && found=1 && break
      done
      if [ "$found" -eq 0 ]; then
        GATE_KINDS+=("missing-declared")
        GATE_NAMES+=("$e")
        GATE_PINS+=("absent")
        GATE_CMDS+=("")
        GATE_WFS+=("")
        GATE_VARS+=("")
        INVENTORY=$((INVENTORY + 1))
        GAPS=$((GAPS + 1))
        FLOOR_FAIL=1
        FLOOR_WHY="${FLOOR_WHY:+$FLOOR_WHY; }declared consumer absent: $e"
        if [ "$verbose" -eq 1 ]; then
          say "  GAP    $e  -- declared consumer absent"
        fi
      fi
    done
    gi=0
    while [ "$gi" -lt "${#GATE_NAMES[@]}" ]; do
      extra="${GATE_NAMES[$gi]}"
      found=0
      for e in "${EXPECTED_LIST[@]}"; do
        [ "$e" = "$extra" ] && found=1 && break
      done
      if [ "$found" -eq 0 ] && [ "${GATE_KINDS[$gi]}" != "missing-declared" ]; then
        GAPS=$((GAPS + 1))
        FLOOR_FAIL=1
        FLOOR_WHY="${FLOOR_WHY:+$FLOOR_WHY; }undeclared consumer present: $extra"
        GATE_KINDS[$gi]=undeclared
        if [ "$verbose" -eq 1 ]; then
          say "  GAP    $extra  -- present on disk but not declared"
        fi
      fi
      gi=$((gi + 1))
    done
  fi
  # CA-GUARD:record-stray
  if [ -n "${RECORD_STRAY:-}" ]; then
    local sname
    local stray_glob_off=0
    case "$-" in *f*) stray_glob_off=1 ;; esac
    set -f
    for sname in $RECORD_STRAY; do
      FLOOR_FAIL=1
      FLOOR_WHY="${FLOOR_WHY:+$FLOOR_WHY; }stray record file: $sname"
      GAPS=$((GAPS + 1))
    done
    [ "$stray_glob_off" -eq 0 ] && set +f
  fi
  if [ "${RECORD_FLOOR:-0}" -gt 0 ] && [ "$INVENTORY" -lt "$RECORD_FLOOR" ]; then
    FLOOR_FAIL=1
    FLOOR_WHY="${FLOOR_WHY:+$FLOOR_WHY; }inventory $INVENTORY < record floor $RECORD_FLOOR"
    GAPS=$((GAPS + 1))
  fi
  if [ "$verbose" -eq 1 ]; then
    say "inventory_floor expected=${#EXPECTED_LIST[@]} scanned=$INVENTORY record_floor=${RECORD_FLOOR:-0}"
  fi
}

inventory() {
  scan_inventory print
  say ""
  if [ "$INVENTORY" -eq 0 ]; then
    say "VERDICT: FAIL -- the inventory examined ZERO consumers"; FAILED=1; return
  fi
  # CA-GUARD:plan-gap
  if [ "$GAPS" -gt 0 ]; then
    if [ "${FLOOR_FAIL:-0}" -ne 0 ]; then
      say "VERDICT: FAIL -- inventory floor: ${FLOOR_WHY:-gaps}"
    else
      say "VERDICT: FAIL -- $GAPS of $INVENTORY consumers have no derivable acceptance command"
    fi
    FAILED=1; return
  fi
  say "VERDICT: PASS -- $INVENTORY consumers, every one with a derived acceptance command"
}

# --- run mode -------------------------------------------------------------

TMO_BIN=""
BUDGET=1800
KILL_AFTER=10
SHIM=""
FARM=""
HOME_SCRATCH=no
WORK=""
RECORD=""
RECORD_FINISHED=0
RECORD_WRITE_ERR=""
RECORD_LOCKED=0
RECORD_LOCKDIR=""
RECORD_LOCK_NOTE=""
HEADER_WRITTEN=0
STDOUT_VERDICT_EMITTED=0
EXAMINED=0
INVENTORY=0
CAND_ABS=""
CAND_VER=""
CAND_TREE=""
CAND_OVERLAY=""
RESOLVED=""
CALL_LOG=""
PRIV=""
CAND_HAS_GFX=0
CAND_GFX_RC=""
OVERLAY_SKIPPED=""
SIBLING_BEFORE=no
SIBLING_AFTER=no
SIBLING_PRESENT=no
LAST_CALLS=0
LAST_OK=0
LAST_FAIL=0
LAST_PREREQ=""
LAST_UNDECLARED=""
RUN_RC=1
ANY_BAD=0
SKIP_MISSING_REASON=0
CA_INFLIGHT_PID=""
RUN_ID=""
STARTED=""
PROBE_RC="-"

probe_timeout() {
  TMO_BIN=""
  if command -v timeout >/dev/null 2>&1; then
    TMO_BIN=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    TMO_BIN=gtimeout
  fi
}

abs_path() {
  local d b
  d="$(cd "$(dirname "$1")" && pwd)" || return 1
  b="$(basename "$1")"
  printf '%s/%s' "$d" "$b"
}

# One printf, so a mutation that appends text is a single site. Used for both
# the record footer and stdout -- PASS is exact-match grepped in the self-test.
verdict_line() {
  # CA-GUARD:exact-verdict
  printf 'VERDICT: %s\n' "$1"
}

# Idempotent stdout verdict. Every run-mode exit path that has a record
# lifecycle (PASS/FAIL/INCOMPLETE) goes through here once. The VERDICT
# line stays EXACT ("VERDICT: FAIL"); a floor failure is named on its own
# `inventory floor: <why>` line before the verdict and in the footer.
emit_stdout_verdict() {
  [ "${STDOUT_VERDICT_EMITTED:-0}" -eq 1 ] && return 0
  verdict_line "$1"
  STDOUT_VERDICT_EMITTED=1
}

# HUP-after-rename lands here: RECORD_FINISHED was set before mv, so the
# trap treats the run as complete and must still print VERDICT.
emit_stdout_verdict_for_rc() {
  # CA-GUARD:stdout-verdict
  case "${RUN_RC:-1}" in
    0) emit_stdout_verdict PASS ;;
    1) emit_stdout_verdict FAIL ;;
    *) emit_stdout_verdict INCOMPLETE ;;
  esac
}

fixture_fault() {
  [ -f "${ECO:-}/.ca_fixture" ] || return 1
  [ -n "${CA_FAULT:-}" ] || return 1
  return 0
}

# Exclusive lock on the record path. mkdir is the portable atomic; the
# holder file names the live pid so a dead holder's dir is reclaimed.
acquire_record_lock() {
  local lockdir="${RECORD}.lock.d" holder_pid="" holder_id="" tries=0
  RECORD_LOCKDIR="$lockdir"
  RECORD_LOCK_NOTE=""
  RECORD_LOCKED=0
  while [ "$tries" -lt 5 ]; do
    if mkdir "$lockdir" 2>/dev/null; then
      printf 'pid=%s\nrun_id=%s\n' "$$" "${RUN_ID:-unknown}" > "$lockdir/holder" || true
      RECORD_LOCKED=1
      return 0
    fi
    if [ ! -d "$lockdir" ]; then
      # Parent unwritable / missing -- not "busy". Later writes fail closed.
      RECORD_LOCKDIR=""
      return 0
    fi
    if [ ! -f "$lockdir/holder" ]; then
      sleep 0.05 2>/dev/null || sleep 1
    fi
    holder_pid=""
    holder_id=""
    if [ -f "$lockdir/holder" ]; then
      holder_pid="$(grep '^pid=' "$lockdir/holder" 2>/dev/null | head -1 | cut -d= -f2-)"
      holder_id="$(grep '^run_id=' "$lockdir/holder" 2>/dev/null | head -1 | cut -d= -f2-)"
    fi
    if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
      say "consumer_acceptance: record busy (held by run ${holder_id:-unknown}, pid $holder_pid)"
      RECORD_LOCKDIR=""
      return 1
    fi
    RECORD_LOCK_NOTE="reclaimed stale lock (held by run ${holder_id:-unknown}, pid ${holder_pid:-dead})"
    rm -rf "$lockdir"
    tries=$((tries + 1))
  done
  say "consumer_acceptance: record busy (held by run ${holder_id:-unknown}, pid ${holder_pid:-unknown})"
  RECORD_LOCKDIR=""
  return 1
}

release_record_lock() {
  if [ "${RECORD_LOCKED:-0}" -eq 1 ] && [ -n "${RECORD_LOCKDIR:-}" ]; then
    rm -rf "$RECORD_LOCKDIR"
  fi
  RECORD_LOCKED=0
  RECORD_LOCKDIR=""
}

# The single writer. Reads stdin. Returns 1 on any failure; sets
# RECORD_WRITE_ERR. mode is append | replace; optional tag names the
# temp file (footer uses "rewrite" so a PATH-shim can target the final
# rename). Callers check: write_record ... || die_record "why".
# Replace temps live in the record's own directory (mktemp next to
# $RECORD, then mv). run_cleanup removes a leftover rewrite temp if a
# signal arrives in the pause-before-rename window.
write_record() {
  local mode="${1:-}" tag="${2:-tmp}" dir tmp
  RECORD_WRITE_ERR=""
  if [ -z "${RECORD:-}" ]; then
    RECORD_WRITE_ERR="write_record: RECORD is unset"
    return 1
  fi
  case "$mode" in
    append)
      if [ ! -f "$RECORD" ]; then
        RECORD_WRITE_ERR="cannot append, $RECORD missing"
        return 1
      fi
      # CA-GUARD:append-owned
      # The ONLY file we may append to without our run_id is a ZERO-BYTE one
      # (the in-place clobber after truncate). A nonempty file with no run_id
      # line is somebody else's content (round-4 residual R11: a replacement
      # INCOMPLETE record with no run_id was accepted and the final record read
      # PASS with rows missing). And never through a symlink (R7).
      if [ -L "$RECORD" ]; then
        RECORD_WRITE_ERR="record path is a symlink"
        return 1
      fi
      if [ -s "$RECORD" ] \
         && ! grep -Fx "run_id=${RUN_ID}" "$RECORD" >/dev/null 2>&1; then
        RECORD_WRITE_ERR="record not ours"
        return 1
      fi
      if ! cat >> "$RECORD"; then
        RECORD_WRITE_ERR="cannot append to $RECORD"
        return 1
      fi
      return 0
      ;;
    replace)
      # CA-GUARD:tmp-beside-record
      dir="$(dirname "$RECORD")"
      tmp="$(mktemp "$dir/.$(basename "$RECORD").${tag}.XXXXXX")" || {
        RECORD_WRITE_ERR="cannot create record temp next to $RECORD"
        return 1
      }
      RECORD_REWRITE_TMP="$tmp"
      if fixture_fault && [ "${CA_FAULT:-}" = show_tmp ]; then
        say "record_tmp_dir=$(dirname "$tmp")"
      fi
      if ! cat > "$tmp"; then
        RECORD_WRITE_ERR="cannot write record temp at $tmp"
        rm -f "$tmp"
        RECORD_REWRITE_TMP=""
        return 1
      fi
      if fixture_fault && [ "${CA_FAULT:-}" = pause_before_rename ] && [ "$tag" = rewrite ]; then
        sleep 30 &
        wait $! || true
      fi
      if ! mv "$tmp" "$RECORD"; then
        RECORD_WRITE_ERR="cannot rename record temp onto $RECORD"
        rm -f "$tmp"
        RECORD_REWRITE_TMP=""
        return 1
      fi
      RECORD_REWRITE_TMP=""
      if [ "$tag" = rewrite ]; then
        # CA-GUARD:finished-before-rename
        RECORD_FINISHED=1
      fi
      return 0
      ;;
    *)
      RECORD_WRITE_ERR="write_record: unknown mode ${mode:-empty}"
      return 1
      ;;
  esac
}

die_record() {
  local why="$1" footer_ok=0
  say "consumer_acceptance: $why${RECORD_WRITE_ERR:+ ($RECORD_WRITE_ERR)}"
  if [ -n "${RECORD:-}" ] && [ -f "${RECORD:-}" ] && [ "${RECORD_FINISHED:-0}" -eq 0 ]; then
    if [ -n "${RUN_ID:-}" ] && grep -Fx "run_id=${RUN_ID}" "$RECORD" >/dev/null 2>&1; then
      if write_record_footer FAIL COMPLETE; then
        footer_ok=1
      else
        say "consumer_acceptance: also failed to write FAIL footer"
      fi
    fi
  fi
  emit_stdout_verdict FAIL
  # CA-GUARD:die-record-flag
  # Leave RECORD_FINISHED=0 when the footer did not land, so the EXIT
  # trap's finish_incomplete still appends INCOMPLETE or clobbers a
  # foreign file. Never a foreign PASS at the path.
  if [ "$footer_ok" -eq 1 ]; then
    RECORD_FINISHED=1
  fi
  exit 1
}

# EXIT/INT/TERM/HUP: a record that never got a footer is INCOMPLETE. Guard
# every expansion -- under set -u a trap abort skips the rest of cleanup.
# Foreign (previous-run) files are clobbered, never appended-to, so a PASS
# from another run cannot survive this run's trap. This run's own file
# already carries VERDICT: INCOMPLETE from the header; we only append when
# the footer has already written PASS/FAIL and RECORD_FINISHED is still 0
# (the finalization race the finished-before-rename guard exists to close).
finish_incomplete() {
  # CA-GUARD:finish-incomplete
  # CA-GUARD:verdict-from-file
  # Re-read the file rather than trusting RECORD_FINISHED: a signal after
  # a successful footer mv is a completed run even if the flag was not
  # yet stored; a signal before the mv is INCOMPLETE.
  if [ -n "${RECORD:-}" ] && [ -f "${RECORD:-}" ]; then
    # Trust a COMPLETE footer only if it carries probe_rc= (the real
    # write_record_footer). fail_footer forges PASS without that field.
    if grep -q '^status=COMPLETE$' "$RECORD" 2>/dev/null \
       && grep -q '^probe_rc=' "$RECORD" 2>/dev/null; then
      if grep -qx 'VERDICT: PASS' "$RECORD"; then
        RECORD_FINISHED=1
        RUN_RC=0
        return
      fi
      if grep -qx 'VERDICT: FAIL' "$RECORD"; then
        RECORD_FINISHED=1
        RUN_RC=1
        return
      fi
    fi
  fi
  [ "${RECORD_FINISHED:-0}" -eq 1 ] && return
  [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] || return
  if [ -n "${RUN_ID:-}" ] && grep -Fx "run_id=${RUN_ID}" "$RECORD" >/dev/null 2>&1; then
    if grep -q '^VERDICT: INCOMPLETE$' "$RECORD" \
       && ! grep -q '^VERDICT: PASS$' "$RECORD" \
       && ! grep -q '^VERDICT: FAIL$' "$RECORD"; then
      emit_stdout_verdict INCOMPLETE
      RECORD_FINISHED=1
      return
    fi
    write_record append <<EOF || say "consumer_acceptance: failed to write INCOMPLETE footer"
status=INCOMPLETE
examined=${EXAMINED:-0}
inventory=${INVENTORY:-0} examined=${EXAMINED:-0}
VERDICT: INCOMPLETE
EOF
    emit_stdout_verdict INCOMPLETE
  elif [ "${HEADER_WRITTEN:-0}" -eq 1 ]; then
    # We claimed the path, then lost it: clobber so a foreign PASS cannot
    # survive. If we never wrote a header, leave the previous file (the
    # invalidate guard is what destroys a stale PASS before we start).
    clobber_record_in_place || say "consumer_acceptance: failed to clobber stale record at $RECORD"
    emit_stdout_verdict INCOMPLETE
  fi
  RECORD_FINISHED=1
}

kill_inflight() {
  local p="${CA_INFLIGHT_PID:-}"
  [ -n "$p" ] || return 0
  # Process-group first so timeout's grandchildren die; fall back to the pid
  # if this child is not a group leader (no setsid on the host).
  kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
  kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
}

run_cleanup() {
  kill_inflight
  finish_incomplete
  if [ -n "${RECORD_REWRITE_TMP:-}" ]; then
    rm -f "$RECORD_REWRITE_TMP"
    RECORD_REWRITE_TMP=""
  fi
  if [ -n "${CA_LOGS:-}" ] && [ -n "${WORK:-}" ] && [ -d "${WORK:-}/logs" ]; then
    mkdir -p "$CA_LOGS"
    cp -a "$WORK/logs/." "$CA_LOGS/" 2>/dev/null || true
  fi
  if [ -n "${WORK:-}" ] && [ -d "${WORK:-}" ]; then
    # CA-GUARD:scratch-cleanup
    rm -rf "$WORK"
    WORK=""
  fi
  if [ -n "${PRIV:-}" ] && [ -d "${PRIV:-}" ]; then
    rm -rf "$PRIV"
    PRIV=""
  fi
  release_record_lock
}

install_run_traps() {
  # Snapshot RECORD_FINISHED before cleanup: finish_incomplete sets the
  # flag after writing INCOMPLETE, which is not a completed run. When
  # the flag was already 1 (HUP-after-rename), emit the stdout verdict
  # the finalizer did not reach.
  trap 'run_cleanup
    if [ "${RECORD_FINISHED:-0}" -eq 1 ]; then
      emit_stdout_verdict_for_rc
      if [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] && grep -qx "VERDICT: PASS" "$RECORD"; then
        exit 0
      fi
      if [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] && grep -qx "VERDICT: FAIL" "$RECORD"; then
        exit 1
      fi
      exit 2
    else
      exit 2
    fi' INT TERM HUP
  trap 'run_cleanup' EXIT
}

stash_previous_record() {
  [ -e "$RECORD" ] || return 0
  local aside n
  aside="${RECORD}.prev"
  n=1
  while [ -e "$aside" ]; do
    aside="${RECORD}.prev.$n"
    n=$((n + 1))
  done
  mv "$RECORD" "$aside"
}

# Truncate/overwrite in place. The file itself is writable even when the
# directory is not; this is how a stale PASS is destroyed before we FAIL.
# Never truncate THROUGH a symlink (R7): unlink the link first and create
# a regular file, so a victim at the other end keeps its bytes.
clobber_record_in_place() {
  # CA-GUARD:clobber-no-follow
  if [ -L "$RECORD" ]; then
    rm -f "$RECORD" || {
      RECORD_WRITE_ERR="cannot unlink symlink at $RECORD"
      return 1
    }
  fi
  if ! : > "$RECORD"; then
    RECORD_WRITE_ERR="cannot truncate $RECORD in place"
    return 1
  fi
  write_record append <<EOF
# consumer_acceptance record
run_id=${RUN_ID:-unknown}
started=${STARTED:-}
eco_root=${ECO:-}
status=INCOMPLETE
note=clobbered in place; directory would not allow stash
VERDICT: INCOMPLETE
EOF
}

# Fail closed: move aside, or destroy PASS in place and still return 1.
invalidate_previous_record() {
  [ -e "$RECORD" ] || return 0
  if stash_previous_record; then
    return 0
  fi
  clobber_record_in_place
  RECORD_WRITE_ERR="${RECORD_WRITE_ERR:-cannot move aside $RECORD}"
  return 1
}

write_record_header() {
  write_record replace tmp <<EOF
# consumer_acceptance record
# Residual: any same-uid consumer that finds the shim script and reads it
# can still recover the call-log path; the evidence is non-accidental, not
# adversary-proof.
# Residual: a missing tool referenced inside a called script (not in
# PREREQS / top-level tokens) still shows as a generic FAIL.
# Overlay is a COPY of src/, lib/, and top-level files (never .git);
# directories are copied with cp -rL. A symlink that cannot be
# dereferenced is skipped (overlay_skipped=).
# ouroboros aot/build.sh keys libeigsrt.a on pwd -P of \$EIGS_DIR/src, so
# every run rebuilds against the per-run overlay path and leaves
# aot/build/.libsrc stamped with a dead path (the next local build
# rebuilds again). Known cost of the overlay, not a bug.
# When sibling_binary_present=yes, consumers with hard-coded sibling
# paths (DMG#73) may have used \$ECO/EigenScript/src/eigenscript; that is
# visible here, not worked around. sibling_binary_present is the value
# before the wave; sibling_binary_present_after is after. Counted only
# when \$ECO/EigenScript/src/eigenscript is an executable regular file
# distinct from the candidate.
# A bare candidate is refused (exit 2) when \$ECO/EigenScript exists;
# pass a tree candidate so EIGS_DIR is an overlay of the candidate.
# Residual: SWALLOWED on an all-negative suite -- a suite whose every
# candidate call expects rc≠0 must include one positive invocation.
# Residual: a row-wide cand_calls count cannot certify WHICH work the
# candidate did when an absolute-path subprocess then accepts with
# another runtime after one candidate setup call.
# Residual: stdin-fed programs and eigenscript --test count as probe;
# no real consumer uses them.
# Variant names are derived from INVOCATION POSITIONS only
# (tools/_derive_variants.py); every occurrence that did not enter the
# set is listed by \`plan\` as variants|<consumer>|excluded:<name>|<file>:<line>.
# At execution time the row runs with PATH=\$SHIM:\$FARM and nothing else:
# \$FARM carries, for every executable on the INHERITED PATH except every
# name matching eigenscript*, a two-line EXEC WRAPPER
# (#!/bin/sh + exec "<absolute original path>" "\$@"), so every tool runs
# AT ITS ORIGINAL LOCATION with its original environment -- a relocated
# virtualenv python3 loses its own sys.prefix and its dependencies
# (Astra r4). path_farm= is the wrapper count and must be >= the number
# of executables the enumeration found; a farm that cannot be written
# exits 2 by name, and so does a \$SHIM that cannot be written.
# COST of the farm, measured on this box (Fable r5): +2-7 ms per farmed
# call (1000 \`git --version\`: direct 9.99 s / farmed 16.83 s, then
# 15.82 s / 17.72 s), so a consumer like ouroboros that makes hundreds of
# \`cc\` calls pays seconds. WRAPPER-QUOTING LIMIT, stated rather than
# fixed: the wrapper is #!/bin/sh but the original path is bash-%q
# quoted, so an inherited PATH directory whose name holds a TAB or (under
# LC_ALL=C) a non-ASCII byte yields \`exec: \$/...: not found\` and the row
# reads FAIL|127 -- fail-closed, never PASS, and no such directory is on
# this box's or CI's PATH. HOME is an empty per-row scratch directory
# (home_scratch=) and the named cache/tool variables pass through
# (env_passthrough=). No stale eigenscript* file is on the row's PATH at
# all, so a consumer's own PATH prepend cannot re-order one in front of
# the shims, and a PATH edit that names an absolute directory existing on
# this box outside \$SHIM/\$FARM/\$HOME/the checkout is refused before the
# row runs (FAIL|path-edit:<dir>). Names outside the candidate set keep
# their 127-shims (path_masked=), the overlay's own eigenscript* files
# are shimmed (overlay_shimmed=), and a row whose call log shows a
# blocked| hit is FAIL|undeclared-variant:<name>.
# Residual: a consumer that resolves the runtime by a PATH IT COMPUTES --
# ./eigenscript-full inside its own checkout, or a glob over one -- is not
# on PATH at all; such a row reads UNEXERCISED (cand_calls=0), never PASS.
# The PATH-edit scan matches the SUBSTRING PATH= / PATH+= / PATH := /
# PATH ?= anywhere in a scanned text line -- comments and heredoc bodies
# included, Makefiles in full, .eigs string literals, a workflow runCmd --
# and refuses BY NAME any RHS component that is a literal absolute
# directory on this box (after ~ / ~user expansion) outside
# \$SHIM/\$FARM/\$HOME/the checkout. Price, stated: a line that merely
# NAMES a PATH edit refuses its row too -- over-broad in the safe
# direction. Residual: a component COMPUTED at runtime
# (PATH="\$(cat dir.txt):\$PATH") or an edit made through a non-shell API
# is still invisible; plant path-edit-computed pins it.
# Residual: a farm entry EXECS its tool at the tool's ORIGINAL location,
# so an inherited wrapper that resolves its own location
# (exec "\$(dirname "\$(readlink -f "\$0")")/eigenscript") still reaches
# the stale eigenscript beside it. Running tools in place is what keeps a
# virtualenv working; the closures (an LD_PRELOAD execve witness, or a
# mount namespace) are deferred. Plant farm-wrapper-sibling pins it.
# Trust root of the dropped self-test: the drop TOOL the harness itself
# chooses (runuser, then setpriv). CA_DROP_CMD is a fixture-gated
# self-test lever, never a trust root: it is honoured only when
# \$CA_ECO/.ca_fixture exists.
# Residual: a Dockerfile RUN line is not scanned for invocations: it builds
# the image, it is not the acceptance command.
run_id=$RUN_ID
started=$STARTED
eco_root=${ECO:-PENDING}
block_shell=bash -e -o pipefail -c
candidate_path=${CAND_ABS:-PENDING}
candidate_version=PENDING
candidate_sha256=PENDING
candidate_tree=PENDING
candidate_full_path=${CAND_FULL_ABS:-}
candidate_full_version=PENDING
candidate_full_sha256=PENDING
candidate_gfx_path=${CAND_GFX_ABS:-}
candidate_gfx_version=PENDING
candidate_gfx_sha256=PENDING
eigenscript_resolved=${RESOLVED:-PENDING}
path_masked=PENDING
path_farm=PENDING
path_dropped=PENDING
home_scratch=PENDING
env_passthrough=PENDING
path_edit=PENDING
overlay_shimmed=PENDING
overlay=copy
overlay_skipped=PENDING
sibling_binary_present=PENDING
logs_dir=${CA_LOGS:-}
inventory=PENDING
examined=PENDING
status=INCOMPLETE
${RECORD_LOCK_NOTE:+note=$RECORD_LOCK_NOTE
}# row|name|pin|verdict|rc|duration_s|cand_calls=N|cand_ok=N|cand_fail=M|consumer_skips=N|sibling_binary_present=yes/no
VERDICT: INCOMPLETE
EOF
}

write_record_footer() {
  local verdict="$1" status="$2" line content n
  if [ ! -f "$RECORD" ]; then
    RECORD_WRITE_ERR="footer: $RECORD missing"
    return 1
  fi
  if fixture_fault && [ "${CA_FAULT:-}" = fail_footer ]; then
    printf '%s\n' \
      "run_id=$RUN_ID" \
      "status=COMPLETE" \
      "inventory=${INVENTORY:-0} examined=${EXAMINED:-0}" \
      "VERDICT: PASS" > "$RECORD"
    RECORD_WRITE_ERR="planted footer failure"
    return 1
  fi
  content="$(
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        inventory=PENDING)         printf 'inventory=%s\n' "${INVENTORY:-0}" ;;
        examined=PENDING)          printf 'examined=%s\n' "${EXAMINED:-0}" ;;
        status=INCOMPLETE|status=RUNNING) printf 'status=%s\n' "$status" ;;
        candidate_path=PENDING)    printf 'candidate_path=%s\n' "${CAND_ABS:-}" ;;
        candidate_version=PENDING) printf 'candidate_version=%s\n' "${CAND_VER:-}" ;;
        candidate_sha256=PENDING)  printf 'candidate_sha256=%s\n' "${CAND_SHA:-}" ;;
        candidate_tree=PENDING)    printf 'candidate_tree=%s\n' "${CAND_TREE:-}" ;;
        candidate_full_version=PENDING) printf 'candidate_full_version=%s\n' "${CAND_FULL_VER:-}" ;;
        candidate_full_sha256=PENDING)  printf 'candidate_full_sha256=%s\n' "${CAND_FULL_SHA:-}" ;;
        candidate_gfx_version=PENDING)  printf 'candidate_gfx_version=%s\n' "${CAND_GFX_VER:-}" ;;
        candidate_gfx_sha256=PENDING)   printf 'candidate_gfx_sha256=%s\n' "${CAND_GFX_SHA:-}" ;;
        eigenscript_resolved=PENDING) printf 'eigenscript_resolved=%s\n' "${RESOLVED:-}" ;;
        path_masked=PENDING)       printf 'path_masked=%s\n' "${PATH_MASKED:-none}" ;;
        path_farm=PENDING)         printf 'path_farm=%s\n' "${PATH_FARM_N:-0}" ;;
        path_dropped=PENDING)      printf 'path_dropped=%s\n' "${PATH_DROPPED:-none}" ;;
        home_scratch=PENDING)      printf 'home_scratch=%s\n' "${HOME_SCRATCH:-no}" ;;
        env_passthrough=PENDING)   printf 'env_passthrough=%s\n' "${ENV_PASSTHROUGH:-none}" ;;
        path_edit=PENDING)         printf 'path_edit=%s\n' "${PATH_EDIT_SEEN:-none}" ;;
        overlay_shimmed=PENDING)   printf 'overlay_shimmed=%s\n' "${OVERLAY_SHIMMED:-none}" ;;
        sibling_binary_present=PENDING) printf 'sibling_binary_present=%s\n' "${SIBLING_BEFORE:-${SIBLING_PRESENT:-no}}" ;;
        overlay_skipped=PENDING)   printf 'overlay_skipped=%s\n' "${OVERLAY_SKIPPED:-}" ;;
        "VERDICT: INCOMPLETE")     verdict_line "$verdict" ;;
        VERDICT:*)                 ;; # drop any other verdict; we emit one
        *)                         printf '%s\n' "$line" ;;
      esac
    done < "$RECORD"
    printf 'probe_rc=%s\n' "${PROBE_RC:--}"
    printf 'sibling_binary_present_after=%s\n' "${SIBLING_AFTER:-${SIBLING_PRESENT:-no}}"
    if [ "${SIBLING_BEFORE:-no}" != "${SIBLING_AFTER:-${SIBLING_PRESENT:-no}}" ]; then
      printf 'sibling_binary_present_changed=%s→%s\n' "${SIBLING_BEFORE:-no}" "${SIBLING_AFTER:-${SIBLING_PRESENT:-no}}"
    fi
    printf 'inventory=%s examined=%s\n' "${INVENTORY:-0}" "${EXAMINED:-0}"
    if [ "${FLOOR_FAIL:-0}" -ne 0 ] && [ -n "${FLOOR_WHY:-}" ]; then
      printf 'inventory floor: %s\n' "$FLOOR_WHY"
    fi
    printf 'status=%s\n' "$status"
  )"
  n="$(grep -c '^VERDICT:' <<< "$content" || true)"
  if [ "$n" != 1 ]; then
    RECORD_WRITE_ERR="footer would write $n VERDICT lines (want 1)"
    return 1
  fi
  write_record replace rewrite <<<"$content"
}

append_row() {
  local extra="cand_calls=${LAST_CALLS:-0}|cand_ok=${LAST_OK:-0}|cand_fail=${LAST_FAIL:-0}|consumer_skips=${LAST_SKIPS:-0}|sibling_binary_present=${SIBLING_PRESENT:-no}"
  if [ -n "${LAST_PREREQ:-}" ]; then
    extra="$extra|prereq=$LAST_PREREQ"
  fi
  write_record append <<<"row|$1|$2|$3|$4|$5|$extra" || die_record "cannot append row to $RECORD"
}

# Last 60 lines of a non-PASS consumer's combined output, as log|<name>|<line>
# immediately after the row. CA-GUARD:log-tail is the append itself.
# A preflight UNRUNNABLE (no consumer output) still gets one log| line so
# every non-PASS row has at least one (#1214).
append_log_tail() {
  local name="$1" log="$2" line tailf reason
  if [ ! -f "$log" ] || [ ! -s "$log" ]; then
    reason="${LAST_PREREQ:+prereq:$LAST_PREREQ}"
    [ -n "$reason" ] || reason="${LAST_AMBIGUOUS:+ambiguous-workflow:$LAST_AMBIGUOUS}"
    [ -n "$reason" ] || reason="${LAST_VERDICT:-UNRUNNABLE}"
    write_record append <<<"log|$name|preflight: $reason" || die_record "cannot append preflight log to $RECORD"
    return 0
  fi
  # CA-GUARD:log-tail
  tailf="$WORK/tail.$name"
  tail -n 60 "$log" > "$tailf" 2>/dev/null || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    write_record append <<<"log|$name|$line" || die_record "cannot append log tail to $RECORD"
  done < "$tailf"
}

append_skip() {
  # CA-GUARD:skip-reason
  if [ -z "$3" ]; then
    SKIP_MISSING_REASON=1
    ANY_BAD=1
  fi
  write_record append <<<"skip|$1|$2|$3" || die_record "cannot append skip to $RECORD"
}

# Bounded background job: wait in THIS shell so INT/TERM/HUP can fire and
# kill the process group without waiting out the consumer budget.
run_bounded() {
  local log="$1"
  shift
  CA_INFLIGHT_PID=""
  if command -v setsid >/dev/null 2>&1; then
    setsid "$TMO_BIN" --kill-after="$KILL_AFTER" "$BUDGET" "$@" < /dev/null > "$log" 2>&1 &
  else
    "$TMO_BIN" --kill-after="$KILL_AFTER" "$BUDGET" "$@" < /dev/null > "$log" 2>&1 &
  fi
  CA_INFLIGHT_PID=$!
  wait "$CA_INFLIGHT_PID"
  LAST_RC=$?
  local pid="$CA_INFLIGHT_PID"
  CA_INFLIGHT_PID=""
  # Reap the setsid group so a background child cannot keep the call-log
  # fd and write into the next row's slice.
  if [ -n "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
}

LAST_VERDICT=""
LAST_RC=""
LAST_DUR=""

run_one() {
  local name="$1" pin="$2" cmd="$3"
  local repo="$ECO/$name" log start end cd_cmd eigs_exports prereq_tool
  LAST_VERDICT=""
  LAST_RC="-"
  LAST_DUR="0"
  LAST_CALLS=0
  LAST_OK=0
  LAST_FAIL=0
  LAST_SKIPS=0
  LAST_PREREQ=""
  LAST_UNDECLARED=""

  if [ ! -d "$repo" ]; then
    LAST_VERDICT=UNRUNNABLE
    LAST_RC="-"
    LAST_DUR="0"
    return
  fi
  # CA-GUARD:missing-command
  if [ -z "$cmd" ]; then
    LAST_VERDICT=UNRUNNABLE
    LAST_RC="-"
    LAST_DUR="0"
    return
  fi

  # CA-GUARD:prereq
  if prereq_tool="$(missing_prereq "$name" "$cmd")"; then
    LAST_VERDICT=UNRUNNABLE
    LAST_PREREQ="$prereq_tool"
    LAST_RC="-"
    LAST_DUR="0"
    return
  fi

  # CA-GUARD:variant-mask
  local need v
  # CA-GUARD:derive-fail-closed
  # Same pre-filter as for the command text, and sound for the same
  # reason: a checkout with no `eigenscript-` substring anywhere cannot
  # yield a name other than `eigenscript`, which is always a candidate.
  # grep rc 1 is "no match"; any other rc means the filter itself failed
  # and the derivation runs (fail closed).
  DERIVED_NAMES=""
  DERIVED_PATHEDITS=""
  DERIVED_RC=0
  local _grep_rc=0 _path_rc=0
  grep -rqI --exclude-dir=.git -e 'eigenscript-' "$repo" 2>/dev/null || _grep_rc=$?
  # The PATH-edit scan has its OWN pre-filter: a checkout with no
  # `eigenscript-` in it can still edit PATH, and that edit is a finding.
  grep -rqI --exclude-dir=.git -e 'PATH' "$repo" 2>/dev/null || _path_rc=$?
  if [ "$_grep_rc" -ne 1 ] || [ "$_path_rc" -ne 1 ]; then
    derive_variants "$name"
  fi
  if [ "${DERIVED_RC:-0}" -ne 0 ]; then
    LAST_VERDICT=UNRUNNABLE
    LAST_PREREQ="variant-derivation"
    LAST_RC="-"
    LAST_DUR="0"
    return
  fi
  # The command text is NOT scanned for raw tokens: a runCmd is already
  # derived from its workflow by call site, and a DECLARED command goes
  # through the same rule via --shell. Round 2 split $cmd on whitespace and
  # took any eigenscript-* word, so `eigenscript-$V` -- a name the consumer
  # computes at runtime -- became a literal prerequisite named
  # `variant:eigenscript-$V`. Runtime-computed names are closed at
  # EXECUTION time instead (CA-GUARD:path-variant-sweep).
  # Pre-filter, strictly broader than what it gates: every variant name
  # other than `eigenscript` itself contains the substring `eigenscript-`
  # (the name grammar is eigenscript(-[a-z0-9]+)*), and a bare
  # `eigenscript` is always a candidate and is skipped by the loop below.
  # So a command with no `eigenscript-` in it cannot contribute a name --
  # this skips a python fork, it does not skip a decision.
  local cmd_names="" cfile cmd_raw="" cmd_edits=""
  if [ -n "${WORK:-}" ] && [ -d "${WORK:-}" ] \
     && { [ "${cmd#*eigenscript-}" != "$cmd" ] || [ "${cmd#*PATH}" != "$cmd" ]; }; then
    cfile="$WORK/declared_cmd.txt"
    printf '%s\n' "$cmd" > "$cfile"
    cmd_raw="$(python3 "$HERE/tools/_derive_variants.py" --shell "$cfile" 2>/dev/null || true)"
    cmd_names="$(parse_variant_names "$cmd_raw")"
    cmd_edits="$(grep '^pathedit|' <<< "$cmd_raw" | sed 's/^pathedit|//' || true)"
  fi
  need="$DERIVED_NAMES $cmd_names"
  # CA-GUARD:noglob-split
  local glob_off=0
  case "$-" in *f*) glob_off=1 ;; esac
  set -f
  for v in $need; do
    case "$v" in
      eigenscript) continue ;;
      eigenscript-full)
        if [ -z "${CAND_FULL_ABS:-}" ]; then
          [ -n "${SHIM:-}" ] && write_127_shim "$SHIM/$v" "$v"
          LAST_VERDICT=UNRUNNABLE
          LAST_PREREQ="variant:eigenscript-full"
          LAST_RC="-"
          LAST_DUR="0"
          [ "$glob_off" -eq 0 ] && set +f
          return
        fi
        ;;
      eigenscript-gfx)
        if [ -z "${CAND_GFX_ABS:-}" ]; then
          [ -n "${SHIM:-}" ] && write_127_shim "$SHIM/$v" "$v"
          LAST_VERDICT=UNRUNNABLE
          LAST_PREREQ="variant:eigenscript-gfx"
          LAST_RC="-"
          LAST_DUR="0"
          [ "$glob_off" -eq 0 ] && set +f
          return
        fi
        ;;
      eigenscript-*)
        [ -n "${SHIM:-}" ] && write_127_shim "$SHIM/$v" "$v"
        LAST_VERDICT=UNRUNNABLE
        LAST_PREREQ="variant:$v"
        LAST_RC="-"
        LAST_DUR="0"
        [ "$glob_off" -eq 0 ] && set +f
        return
        ;;
    esac
  done
  [ "$glob_off" -eq 0 ] && set +f
  # CA-GUARD:end-variant-mask

  log="$WORK/logs/$name.log"
  mkdir -p "$WORK/logs" || scratch_die "cannot create the row log directory"
  # Arm this row's slice of the private log (new inode, so a straggler
  # holding the previous fd cannot append here). The harness
  # --version/--api probes ran before any row log existed and used
  # CAND_ABS, not the shim.
  if [ -n "${CALL_LOG:-}" ]; then
    rm -f "$CALL_LOG"
    : > "$CALL_LOG"
  fi

  eigs_exports=""
  # CA-GUARD:eigs-dir
  if [ -n "${CAND_OVERLAY:-}" ]; then
    eigs_exports="$(printf 'export EIGS_DIR=%q\nexport EIGENSCRIPT_DIR=%q\n' "$CAND_OVERLAY" "$CAND_OVERLAY")"
  fi
  # CA-GUARD:eigenscript-bin
  if true; then
    if [ -n "$eigs_exports" ]; then
      eigs_exports="${eigs_exports}"$'\n'
    fi
    eigs_exports="${eigs_exports}$(printf 'export EIGENSCRIPT_BIN=%q\n' "$SHIM/eigenscript")"
    if [ "${CAND_HAS_GFX:-0}" = 1 ]; then
      eigs_exports="${eigs_exports}"$'\n'"$(printf 'export EIGENSCRIPT_GFX=%q\n' "$SHIM/eigenscript")"
    fi
  fi
  # CA-GUARD:private-log-export
  true
  # XDG_* goes with CA_*: the row's HOME is a scratch directory, and an
  # inherited XDG_DATA_HOME/XDG_CONFIG_HOME would point a consumer's
  # "user install" back at the developer's real home. (The strip_ca
  # assignment must stay on the line directly after the guard marker: the
  # private-log mutation replaces exactly that line.)
  # CA-GUARD:strip-ca-env
  strip_ca='for _ca_k in $(env | awk -F= '\''$1 ~ /^(CA_|XDG_)/ {print $1}'\''); do unset "$_ca_k"; done'

  # CA-GUARD:home-scratch
  # A scratch HOME per row, created empty (with the two bin directories a
  # consumer usually prepends), so `export PATH="$HOME/.local/bin:$PATH"`
  # adds an EMPTY directory instead of the developer's stale runtimes.
  local row_home
  row_home="$WORK/home/$name"
  mkdir -p "$row_home/.local/bin" "$row_home/bin" \
    || scratch_die "cannot create the row HOME $row_home"
  assert_scratch_dir "$row_home" "row HOME"
  row_home="$SCRATCH_REAL"
  HOME_SCRATCH=yes
  local home_export
  home_export="$(printf 'export HOME=%q' "$row_home")"
  # CA-GUARD:env-passthrough-row
  # The named build/tool CACHE variables survive the scratch HOME; nothing
  # else does.
  local env_pass="${ENV_PASS_EXPORTS:-}"
  # CA-GUARD:end-home-scratch

  # CA-GUARD:path-edit-preflight
  # BEFORE the row runs: a literal absolute PATH component that exists on
  # this box and is outside $SHIM/$FARM/the row's $HOME/this checkout is a
  # named refusal, not a residual (Fable r4 check 3).
  local _pe _pe_dir _pe_where _pe_written _pe_rest _all_edits _has_edit=0
  _all_edits="$DERIVED_PATHEDITS"
  # ${cmd_edits:-}, not $cmd_edits: `cmd_edits` is declared INSIDE the
  # variant-mask block, and the variant-mask transverse mutation deletes
  # that whole block. The round-5 witness caught exactly that --
  # `mutants/variant-mask/...: line 1961: cmd_edits: unbound variable` --
  # which is why a count without a witness is not a gate.
  if [ -n "${cmd_edits:-}" ]; then
    _all_edits="${_all_edits}${cmd_edits}"$'\n'
  fi
  # A record is `<component>|<file>:<line>`; blank lines are not records.
  # (`$'\n'` inside double quotes is NOT ANSI-C quoting, so the emptiness
  # test is a case pattern, which is unquoted and therefore is.)
  case "$_all_edits" in
    *[![:space:]]*) _has_edit=1 ;;
  esac
  # CA-GUARD:path-edit-guard
  if true && [ "$_has_edit" -eq 1 ]; then
    if _pe="$(path_edit_offender "$repo" "$row_home" "$_all_edits")"; then
      # `<resolved>|<file>:<line>|<written>` -- the offender is named by the
      # directory it RESOLVES to (round 7); the written form is kept in the
      # log line so the record still says what the consumer actually wrote.
      _pe_dir="${_pe%%|*}"
      _pe_rest="${_pe#*|}"
      _pe_where="${_pe_rest%%|*}"
      _pe_written="${_pe_rest#*|}"
      printf 'preflight: path-edit %s added to PATH at %s -- an absolute directory on this box, outside $SHIM, $FARM, the row scratch $HOME and the checkout %s; written as %s; the row is refused before it runs\n' \
        "$_pe_dir" "$_pe_where" "$repo" "$_pe_written" > "$log"
      PATH_EDIT_SEEN="${PATH_EDIT_SEEN:+$PATH_EDIT_SEEN }$name:$_pe_dir"
      LAST_VERDICT="FAIL|path-edit:$_pe_dir"
      LAST_RC="-"
      LAST_DUR="0"
      return
    fi
  fi
  # CA-GUARD:end-path-edit-preflight

  # CA-GUARD:not-found-variant
  # With the farm there is no stale eigenscript* on the row's PATH at all,
  # so a name the consumer COMPUTES that no candidate covers is simply NOT
  # FOUND -- a bare 127 the consumer can swallow with `|| true`. The block
  # shell's command_not_found_handle turns that into the same blocked|
  # record a 127-shim writes, so the row is FAIL|undeclared-variant:<name>
  # by name instead of a silent PASS (Fable r3 dot-PATH probe). Defined in
  # the block, never exported: the call-log path stays out of the
  # consumer's environment.
  local nf_handler=""
  # CA-GUARD:not-found-guard
  if true; then
    nf_handler="$(printf 'command_not_found_handle() {\n  case "${1:-}" in\n    eigenscript|eigenscript-*)\n      printf "blocked|rc=127|%%s|%%s\\n" "$1" "${*:2}" >> %q 2>/dev/null || true\n      printf "consumer_acceptance: no candidate for %%s\\n" "$1" >&2 ;;\n    *) printf "%%s: command not found\\n" "$1" >&2 ;;\n  esac\n  return 127\n}' "${CALL_LOG:-/dev/null}")"
  fi
  # CA-GUARD:end-not-found-variant

  # CA-GUARD:path-farm-row
  # EXACTLY $SHIM:$FARM. No inherited directory, so no stale eigenscript*
  # file is on the row's PATH at all -- a prepend cannot re-order what is
  # not there.
  local path_export
  path_export="$(printf 'export PATH=%q:%q' "$SHIM" "$FARM")"
  # CA-GUARD:end-path-farm-row

  cd_cmd="$(printf '%s\nexport EIGS=eigenscript\nexport EIGENSCRIPT=eigenscript\n%s\n%s\n%s\n%s\n%s\ncd %q || exit 125\n%s\n' "$path_export" "$eigs_exports" "$strip_ca" "$home_export" "$env_pass" "$nf_handler" "$repo" "$cmd")"

  start="$(date +%s)"
  # CA-GUARD:block-pipefail
  run_bounded "$log" bash -e -o pipefail -c "$cd_cmd"
  end="$(date +%s)"
  LAST_DUR=$((end - start))
  if [ "$LAST_DUR" -lt 0 ]; then LAST_DUR=0; fi

  LAST_CALLS="$(grep -c '^call|' "${CALL_LOG:-/dev/null}" 2>/dev/null || true)"
  LAST_CALLS="${LAST_CALLS:-0}"
  LAST_OK="$(grep -c '^call|rc=0|' "${CALL_LOG:-/dev/null}" 2>/dev/null || true)"
  LAST_OK="${LAST_OK:-0}"
  LAST_FAIL=$((LAST_CALLS - LAST_OK))
  if [ "$LAST_FAIL" -lt 0 ]; then LAST_FAIL=0; fi
  LAST_SKIPS="$(grep -c '^SKIP' "$log" 2>/dev/null || true)"
  LAST_SKIPS="${LAST_SKIPS:-0}"
  # CA-GUARD:probe-not-attributed
  # The harness --version/--api/bind probes ran against CAND_ABS (not the
  # shim) before this log was armed; the per-row recreate drops them.

  case "$LAST_RC" in
    0)   LAST_VERDICT=PASS ;;
    124) LAST_VERDICT=HANG ;;
    137) LAST_VERDICT=KILLED ;;
    125) LAST_VERDICT=UNRUNNABLE ;;
    *)   LAST_VERDICT=FAIL ;;
  esac
  # CA-GUARD:cand-calls
  # A PASS that never reached the candidate is UNEXERCISED (mechanical-gates
  # §113: every arm must prove it RAN). HANG/KILLED/UNRUNNABLE/FAIL keep
  # their names -- cand_calls=0 cannot be PASS.
  if [ "$LAST_VERDICT" = PASS ] && [ "$LAST_CALLS" -eq 0 ]; then
    LAST_VERDICT=UNEXERCISED
  fi
  # CA-GUARD:swallowed
  # Command exited 0 AND no nontrivial candidate invocation succeeded:
  # the candidate never once worked and the consumer still reported success.
  # A nonzero candidate rc is not by itself a failure (lint/fail-soft).
  if [ "$LAST_VERDICT" = PASS ] && [ "${LAST_OK:-0}" -eq 0 ] && [ "${LAST_FAIL:-0}" -gt 0 ]; then
    LAST_VERDICT=SWALLOWED
  fi
  if [ "$LAST_VERDICT" = PASS ] && [ "${LAST_SKIPS:-0}" -gt 0 ]; then
    LAST_VERDICT="PASS|skips=$LAST_SKIPS"
  fi
  # CA-GUARD:undeclared-variant
  # Read our OWN call log back: every logged argv[0] basename must be in
  # the candidate set. A blocked| hit is a name the consumer computed at
  # runtime and the derivation never saw -- that row is FAIL BY NAME, not
  # UNEXERCISED and certainly not PASS.
  LAST_UNDECLARED=""
  local _ln _nm
  while IFS= read -r _ln || [ -n "$_ln" ]; do
    [ -n "$_ln" ] || continue
    _nm="${_ln#*|}"
    _nm="${_nm#*|}"
    _nm="${_nm%%|*}"
    case "$_nm" in
      eigenscript|eigenscript-*) ;;
      *) continue ;;
    esac
    is_candidate_name "$_nm" && continue
    LAST_UNDECLARED="$_nm"
    break
  done < "${CALL_LOG:-/dev/null}"
  if [ -n "$LAST_UNDECLARED" ]; then
    LAST_VERDICT="FAIL|undeclared-variant:$LAST_UNDECLARED"
  fi
  # CA-GUARD:end-undeclared-variant
}

finalize_run() {
  local final=FAIL
  RUN_RC=1
  # CA-GUARD:nonempty-inventory
  if [ "$INVENTORY" -eq 0 ]; then
    final=FAIL
    RUN_RC=1
  # CA-GUARD:examined-eq-inventory
  elif [ "$EXAMINED" -ne "$INVENTORY" ]; then
    final=FAIL
    RUN_RC=1
  elif [ "${FLOOR_FAIL:-0}" -ne 0 ]; then
    final=FAIL
    RUN_RC=1
    if [ -n "${FLOOR_WHY:-}" ]; then
      say "inventory floor: ${FLOOR_WHY}"
    fi
  elif [ "${SKIP_MISSING_REASON:-0}" -ne 0 ]; then
    final=FAIL
    RUN_RC=1
  elif [ "$ANY_BAD" -eq 0 ]; then
    final=PASS
    RUN_RC=0
  else
    final=FAIL
    RUN_RC=1
  fi

  if ! write_record_footer "$final" COMPLETE; then
    die_record "failed to write final record"
  fi
  say "inventory=$INVENTORY examined=$EXAMINED"
  emit_stdout_verdict "$final"
  RECORD_FINISHED=1
  exit "$RUN_RC"
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}

# CA-GUARD:shim-inside-work
# A shim file is only ever created under $WORK. Without this, a fall-open
# $SHIM ("/bin" after an unchecked mktemp) had the harness writing stub
# shims into system directories (Fable r3, observed on this box).
assert_shim_dest() {
  local dest="${1:-}" dir=""
  [ -n "$dest" ] || scratch_die "shim destination is empty"
  dir="$(dirname "$dest")"
  assert_scratch_dir "$dir" "shim destination"
}
# CA-GUARD:end-shim-inside-work

# CA-GUARD:shim-fail-closed
# Fable r5 / Astra r4 `readonly-bin`: the row's $SHIM directory exists but
# is mode 555, so every `> "$SHIM/<name>"` failed, no shim was written, and
# the row read FAIL|127 cand_calls=0 -- a generic failure, while the
# fail-closed claim says an unusable scratch is refused BY NAME. A shim
# that cannot be written is now named and exits 2, exactly like the farm's
# farm_die.
shim_die() {
  say "consumer_acceptance: cannot write the shim ${1:-<unset>} ($2)"
  RUN_RC=2
  exit 2
}
# CA-GUARD:end-shim-fail-closed

write_counting_shim() {
  local dest="$1" target="$2" name="${3:-}"
  [ -n "$name" ] || name="$(basename "$dest")"
  assert_shim_dest "$dest"
  {
    printf '%s\n' '#!/bin/sh'
    printf 'target=%s\n' "$(printf '%q' "$target")"
    printf 'log=%s\n' "$(printf '%q' "$CALL_LOG")"
    printf 'name=%s\n' "$(printf '%q' "$name")"
    printf '%s\n' \
      'log="$log"' \
      'kind=probe' \
      'for _a in "$@"; do' \
      '  case "$_a" in' \
      '    --version|--api|--help|-h|-v) ;;' \
      '    -*) ;;' \
      '    *) kind=call ;;' \
      '  esac' \
      'done' \
      '"$target" "$@"' \
      'rc=$?' \
      '# CA-GUARD:log-argv0' \
      'printf "%s|rc=%s|%s|%s\n" "$kind" "$rc" "$name" "$*" >> "$log"' \
      'exit "$rc"'
  } > "$dest" || shim_die "$dest" "write failed"
  chmod +x "$dest" || shim_die "$dest" "chmod failed"
  [ -x "$dest" ] || shim_die "$dest" "not executable after write"
}

# A name with no candidate must not reach a stale binary of that name on
# the inherited PATH. The shim refuses by name AND logs the hit, so the row
# can be FAILed as undeclared-variant instead of silently reading PASS.
write_127_shim() {
  local dest="$1" name="$2"
  assert_shim_dest "$dest"
  {
    printf '%s\n' '#!/bin/sh'
    printf 'name=%s\n' "$(printf '%q' "$name")"
    printf 'log=%s\n' "$(printf '%q' "${CALL_LOG:-/dev/null}")"
    printf '%s\n' \
      'echo "consumer_acceptance: no candidate for $name" >&2' \
      '# CA-GUARD:log-argv0' \
      'printf "blocked|rc=127|%s|%s\n" "$name" "$*" >> "$log" 2>/dev/null || true' \
      'exit 127'
  } > "$dest" || shim_die "$dest" "write failed"
  chmod +x "$dest" || shim_die "$dest" "chmod failed"
  [ -x "$dest" ] || shim_die "$dest" "not executable after write"
}

# CA-GUARD:drop-sha-readback
# Fix 4 (Fable/Astra r3, drop TOCTOU): the uid-0 self-test cmp/sha256s the
# copy of itself it is about to run, then hands the path to $drop -- and a
# drop tool that rewrites the copy in that window ran a DIFFERENT script
# while the outer printed "byte-identical". The dropped process therefore
# prints its OWN script's sha256 as its first line and the outer compares
# that. Pure: prints exactly one verdict word, no diagnostics.
drop_sha_verdict() {
  local want="${1:-}" f="${2:-}" got=""
  [ -n "$want" ] || { printf '%s' MISSING-EXPECTED; return; }
  [ -f "$f" ] || { printf '%s' MISSING; return; }
  got="$(grep -m1 '^dropped_script_sha256=' "$f" 2>/dev/null || true)"
  got="${got#dropped_script_sha256=}"
  got="${got%% *}"
  if [ -z "$got" ]; then printf '%s' MISSING; return; fi
  if [ "$got" = "$want" ]; then printf '%s' OK; return; fi
  printf 'MISMATCH:%s' "$got"
}
# CA-GUARD:end-drop-sha-readback

# CA-GUARD:outer-tmp-token
# Fix 5 (both critics r3): the self-test's outer-tmp hygiene scan read a
# CONCURRENT self-test's /tmp/ca-st.* as this run's leftover and printed a
# false SELF-TEST: FAIL. Every scratch name this script creates in the
# outer tmp carries CA_SCRATCH_TAG, so the scan can ask only about entries
# CREATED BY THIS RUN. OUTER_TMP_EXAMINED is the enumeration's own witness
# (>0 always, because $keep itself matches): a pattern that matched
# nothing would otherwise print a clean OK.
OUTER_TMP_EXAMINED=0
OUTER_TMP_STRAYS=""
outer_tmp_strays() {
  local dir="$1" token="$2" keep="$3" pat tf
  pat="ca-*"
  [ -n "$token" ] && pat="ca-*${token}*"
  OUTER_TMP_EXAMINED=0
  OUTER_TMP_STRAYS=""
  while IFS= read -r tf || [ -n "$tf" ]; do
    [ -n "$tf" ] || continue
    OUTER_TMP_EXAMINED=$((OUTER_TMP_EXAMINED + 1))
    case "$tf" in
      "$keep"|"$keep"/*) continue ;;
    esac
    OUTER_TMP_STRAYS="${OUTER_TMP_STRAYS:+$OUTER_TMP_STRAYS }$tf"
  done <<< "$(find "$dir" -maxdepth 1 -name "$pat" 2>/dev/null || true)"
}
# CA-GUARD:end-outer-tmp-token

# The candidate SET: which names have a real binary behind them.
is_candidate_name() {
  case "${1:-}" in
    eigenscript) return 0 ;;
    eigenscript-full) [ -n "${CAND_FULL_ABS:-}" ] && return 0 ;;
    eigenscript-gfx)  [ -n "${CAND_GFX_ABS:-}" ] && return 0 ;;
  esac
  return 1
}

# Close the class at EXECUTION time (#1213, Fable/Astra r2): the derivation
# decides which names are DECLARED prerequisites, and it cannot see a name
# the consumer computes at runtime (`eigenscript-$V`). So before any row
# runs, every executable named eigenscript* on the INHERITED PATH that is
# not in the candidate set gets a 127-shim in $SHIM, which is first on the
# row's PATH -- the stale binary is unreachable BY NAME from any script.
# Residual, stated in the header: a consumer that resolves the runtime by a
# path it computes (`./eigenscript-full`, a glob inside its own checkout)
# is outside PATH and is not masked.
PATH_MASKED=""
PATH_DROPPED=""
PATH_EDIT_SEEN=""
DERIVED_PATHEDITS=""
DERIVED_PATHEXAMINED=""
mask_path_variants() {
  local d b f
  local -a dirs=()
  PATH_MASKED=""
  PATH_DROPPED=""
  [ -n "${SHIM:-}" ] || return 0
  local oldifs="$IFS"
  local glob_off=0
  case "$-" in *f*) glob_off=1 ;; esac
  set -f
  IFS=:
  # shellcheck disable=SC2206
  dirs=($PATH)
  IFS="$oldifs"
  [ "$glob_off" -eq 0 ] && set +f
  for d in "${dirs[@]+"${dirs[@]}"}"; do
    [ -n "$d" ] || d="."
    [ -d "$d" ] || continue
    case "$d" in "$SHIM") continue ;; esac
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      [ -x "$f" ] || continue
      b="$(basename "$f")"
      case "$b" in
        eigenscript|eigenscript-*) ;;
        *) continue ;;
      esac
      case " $PATH_DROPPED " in
        *" $b "*) ;;
        *) PATH_DROPPED="${PATH_DROPPED:+$PATH_DROPPED }$b" ;;
      esac
      is_candidate_name "$b" && continue
      [ -e "$SHIM/$b" ] && continue
      write_127_shim "$SHIM/$b" "$b"
      PATH_MASKED="${PATH_MASKED:+$PATH_MASKED }$b"
      # -L so a PATH entry that is a SYMLINK to a directory is enumerated
      # too (Astra r3: a symlinked PATH dir escaped the sweep entirely).
    done <<< "$(find -L "$d" -maxdepth 1 -name 'eigenscript*' 2>/dev/null || true)"
  done
}

# CA-GUARD:path-farm
# The class closure (#1213, Fable/Astra r3). Shadowing is only as good as
# PATH ORDER, and PATH order belongs to the CONSUMER: one
# `export PATH="$HOME/.local/bin:$PATH"` -- the ordinary CI idiom two real
# consumers already use -- puts a stale binary back in front of $SHIM.
# So the stale files are taken OUT OF REACH instead of out-ordered: the
# row runs with PATH=$SHIM:$FARM and nothing else, where $FARM holds one
# symlink per executable found on the INHERITED PATH EXCEPT every name
# matching eigenscript*, which is never linked. No inherited directory is
# on the row's PATH at all, so there is no `.`, no empty entry and no
# $HOME/.local/bin to prepend in front of.
# Enumeration is -L (a symlinked PATH directory is followed) and first
# occurrence wins (ln without -f refuses an existing name), so the farm
# preserves the inherited PATH's own precedence.
# Residual, stated in the record header: a consumer that prepends an
# ABSOLUTE directory outside $HOME that it did not create inside the row
# (e.g. /opt/foo/bin) can still reach a binary there; nothing short of a
# mount namespace closes that, and CI has no such directory. A PATH
# directory that is executable but not READABLE (mode 0111) cannot be
# enumerated, so nothing from it is farmed and nothing from it is
# reachable either -- fail closed, not fall through.
PATH_FARM_N=0
PATH_FARM_WANT=0
# CA-GUARD:farm-fail-closed
# Astra r4 check 7: a farm directory that cannot be WRITTEN swallowed every
# link failure, the header read path_farm=0, and the row read PASS with the
# whole inherited PATH effectively gone. Farm construction fails closed BY
# NAME like scratch creation, and the count in the header is checked against
# the enumeration's own witness.
farm_die() {
  say "consumer_acceptance: cannot build the PATH farm under ${FARM:-<unset>} ($1)"
  RUN_RC=2
  exit 2
}
# CA-GUARD:end-farm-fail-closed
build_path_farm() {
  local d dabs f b q
  local -a dirs=()
  PATH_FARM_N=0
  PATH_FARM_WANT=0
  [ -n "${WORK:-}" ] || scratch_die "path farm: run scratch is unset"
  FARM="$WORK/farm"
  mkdir -p "$FARM" || scratch_die "cannot create the PATH farm $FARM"
  assert_scratch_dir "$FARM" "PATH farm"
  FARM="$SCRATCH_REAL"
  local oldifs="$IFS"
  local glob_off=0
  case "$-" in *f*) glob_off=1 ;; esac
  set -f
  IFS=:
  # shellcheck disable=SC2206
  dirs=($PATH)
  IFS="$oldifs"
  local -a keep=()
  for d in "${dirs[@]+"${dirs[@]}"}"; do
    [ -n "$d" ] || d="."
    case "$d" in "$SHIM"|"$FARM") continue ;; esac
    [ -d "$d" ] || continue
    # An ABSOLUTE original path is what the wrapper has to exec, so a
    # relative PATH entry (`.`) is resolved here, once.
    dabs="$(cd -P -- "$d" 2>/dev/null && pwd)" || continue
    [ -n "$dabs" ] || continue
    case "$dabs" in "$SHIM"|"$FARM") continue ;; esac
    keep+=("$dabs")
  done
  if [ "${#keep[@]}" -gt 0 ]; then
    while IFS= read -r f || [ -n "$f" ]; do
      [ -n "$f" ] || continue
      b="${f##*/}"
      [ -n "$b" ] || continue
      # First occurrence wins, exactly as the inherited PATH resolves it.
      [ -e "$FARM/$b" ] && continue
      PATH_FARM_WANT=$((PATH_FARM_WANT + 1))
      # CA-GUARD:farm-exec-wrapper
      if true; then
        # printf -v, not $(printf ...): a command substitution per entry is
        # 2144 forks and 4.5 s of farm build on this box; -v is 0.57 s.
        printf -v q '%q' "$f"
        printf '#!/bin/sh\nexec %s "$@"\n' "$q" > "$FARM/$b" \
          || farm_die "cannot write the exec wrapper $b"
      else
        # The round-4 symlink farm, kept only as the transverse mutation's
        # target: it RELOCATES the tool and breaks a virtualenv.
        ln -s -- "$f" "$FARM/$b" 2>/dev/null || true
      fi
    done <<< "$(find -L "${keep[@]}" -maxdepth 1 -type f -perm -u+x \
                     ! -name 'eigenscript*' -print 2>/dev/null || true)"
  fi
  [ "$glob_off" -eq 0 ] && set +f
  if [ "$PATH_FARM_WANT" -gt 0 ]; then
    find "$FARM" -maxdepth 1 -mindepth 1 -type f -exec chmod 755 {} + 2>/dev/null \
      || farm_die "cannot make the exec wrappers executable"
  fi
  PATH_FARM_N="$(find "$FARM" -maxdepth 1 -mindepth 1 -type f -perm -u+x 2>/dev/null | wc -l | tr -d ' ')"
  PATH_FARM_N="${PATH_FARM_N:-0}"
  # CA-GUARD:farm-witness
  # The enumeration's own witness (mechanical-gates 120): the farm must hold
  # at least as many runnable entries as the enumeration found names for.
  # path_farm=0 with a non-empty inherited PATH is a BROKEN farm, not a
  # quiet one.
  if [ "$PATH_FARM_N" -lt "$PATH_FARM_WANT" ]; then
    farm_die "path_farm=$PATH_FARM_N < enumerated $PATH_FARM_WANT executables"
  fi
  # CA-GUARD:end-farm-witness
}
# CA-GUARD:end-path-farm

# CA-GUARD:env-passthrough
# Fable r4 check 4b: the scratch HOME also drops every TOOL CACHE that
# lives under the real home. Measured on eddy:
#   HOME=<scratch> GOPROXY=off go list -m all -> "module lookup disabled"
#   (real HOME: rc 0)
# so an eddy row re-downloads its modules on every run and FAILS with no
# network. The cache is not the developer's stale runtime -- it is the
# consumer's declared dependency set -- so these names pass through when
# the harness has them, and GOPATH/GOMODCACHE/GOCACHE are DERIVED from the
# REAL home when it does not. Exactly this list, printed as
# env_passthrough= in the header; anything else still sees the scratch HOME.
ENV_PASS_NAMES="GOPATH GOMODCACHE GOCACHE GOFLAGS JAVA_HOME ELLE_JAR CARGO_HOME RUSTUP_HOME PIP_CACHE_DIR npm_config_cache"
ENV_PASSTHROUGH=""
ENV_PASS_EXPORTS=""
REAL_HOME=""
build_env_passthrough() {
  local n v derived
  ENV_PASSTHROUGH=""
  ENV_PASS_EXPORTS=""
  REAL_HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
  [ -n "$REAL_HOME" ] || REAL_HOME="${HOME:-}"
  for n in $ENV_PASS_NAMES; do
    v=""
    eval 'v="${'"$n"':-}"'
    derived=""
    if [ -z "$v" ] && [ -n "$REAL_HOME" ]; then
      case "$n" in
        GOPATH)     v="$REAL_HOME/go"; derived=1 ;;
        GOMODCACHE) v="$REAL_HOME/go/pkg/mod"; derived=1 ;;
        GOCACHE)    v="$REAL_HOME/.cache/go-build"; derived=1 ;;
      esac
    fi
    [ -n "$v" ] || continue
    ENV_PASS_EXPORTS="${ENV_PASS_EXPORTS}$(printf 'export %s=%q\n' "$n" "$v")"$'\n'
    ENV_PASSTHROUGH="${ENV_PASSTHROUGH:+$ENV_PASSTHROUGH }$n${derived:+(derived)}"
  done
  [ -n "$ENV_PASSTHROUGH" ] || ENV_PASSTHROUGH=none
}
# CA-GUARD:end-env-passthrough

run_mode() {
  # CA-GUARD:not-crash
  local cand="" arg
  CAND_FULL=""
  CAND_GFX=""
  CAND_FULL_ABS=""
  CAND_GFX_ABS=""
  CAND_SHA=""
  CAND_FULL_VER=""
  CAND_FULL_SHA=""
  CAND_GFX_VER=""
  CAND_GFX_SHA=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --full)
        [ $# -ge 2 ] || { say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"; exit 2; }
        CAND_FULL="$2"; shift 2 ;;
      --gfx)
        [ $# -ge 2 ] || { say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"; exit 2; }
        CAND_GFX="$2"; shift 2 ;;
      -*)
        say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"
        exit 2 ;;
      *)
        if [ -z "$cand" ]; then cand="$1"; shift
        else
          say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"
          exit 2
        fi ;;
    esac
  done
  resolve_eco
  probe_timeout
  # Unset → default 1800. Empty / 0 / 00 / non-integer → exit 2 below.
  if [ "${CA_TIMEOUT+set}" = set ]; then
    BUDGET="$CA_TIMEOUT"
  else
    BUDGET=1800
  fi
  KILL_AFTER="${CA_KILL_AFTER:-10}"

  # CA-GUARD:usage-before-record
  # Static argument validation happens BEFORE any record path is touched.
  # CA-GUARD:timeout-positive
  case "$BUDGET" in
    ''|*[!0-9]*)
      say "consumer_acceptance: CA_TIMEOUT must be a positive integer (got ${CA_TIMEOUT:-})"
      exit 2
      ;;
  esac
  if [ "$((10#$BUDGET))" -lt 1 ]; then
    say "consumer_acceptance: CA_TIMEOUT must be a positive integer (got ${CA_TIMEOUT:-})"
    exit 2
  fi
  # CA-GUARD:end-timeout-positive

  if [ -z "$TMO_BIN" ]; then
    say "consumer_acceptance: no timeout(1)/gtimeout(1) on PATH -- refusing to run unbounded"
    exit 2
  fi
  if [ -z "$cand" ]; then
    say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"
    exit 2
  fi
  if [ ! -f "$cand" ] || [ ! -x "$cand" ]; then
    say "consumer_acceptance: candidate is not an executable file: $cand"
    exit 2
  fi
  CAND_ABS="$(abs_path "$cand")" || { say "consumer_acceptance: cannot resolve candidate path: $cand"; exit 2; }
  if [ -n "$CAND_FULL" ]; then
    if [ ! -f "$CAND_FULL" ] || [ ! -x "$CAND_FULL" ]; then
      say "consumer_acceptance: --full is not an executable file: $CAND_FULL"
      exit 2
    fi
    CAND_FULL_ABS="$(abs_path "$CAND_FULL")" || { say "consumer_acceptance: cannot resolve --full path: $CAND_FULL"; exit 2; }
  fi
  if [ -n "$CAND_GFX" ]; then
    if [ ! -f "$CAND_GFX" ] || [ ! -x "$CAND_GFX" ]; then
      say "consumer_acceptance: --gfx is not an executable file: $CAND_GFX"
      exit 2
    fi
    CAND_GFX_ABS="$(abs_path "$CAND_GFX")" || { say "consumer_acceptance: cannot resolve --gfx path: $CAND_GFX"; exit 2; }
  fi
  # CA-GUARD:end-usage-before-record

  RUN_ID="$(date +%s).$$.${RANDOM:-0}"
  STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"

  if [ -n "${CA_RECORD:-}" ]; then
    RECORD="$CA_RECORD"
  else
    RECORD="$(mktemp "${TMPDIR:-/tmp}/ca-record.$(scratch_tag)XXXXXX")" \
      || scratch_die "mktemp ca-record failed"
    # mktemp creates an empty file; do not stash it as .prev on a fresh run.
    rm -f "$RECORD"
  fi

  # First actions -- before the inventory scan, before the shim, before
  # the candidate. A previous PASS must not outlive this point. The lock
  # is taken BEFORE invalidate so a second invocation refuses without
  # touching the live record.
  # CA-GUARD:traps-before-scan
  install_run_traps
  # CA-GUARD:record-lock
  if ! acquire_record_lock; then
    RECORD_FINISHED=1
    RUN_RC=2
    exit 2
  fi
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/ca-run.$(scratch_tag)XXXXXX")" \
    || scratch_die "mktemp -d ca-run failed"
  assert_scratch_dir "$WORK" "run scratch"
  WORK_REAL="$SCRATCH_REAL"
  # CA-GUARD:invalidate-fail-closed
  invalidate_previous_record || die_record "cannot invalidate previous record at $RECORD"
  write_record_header || die_record "cannot initialise record at $RECORD"
  HEADER_WRITTEN=1
  # CA-GUARD:end-traps-before-scan

  SHIM="$WORK/bin"
  mkdir -p "$SHIM" || scratch_die "cannot create the shim directory $SHIM"
  assert_scratch_dir "$SHIM" "shim directory"
  SHIM="$SCRATCH_REAL"
  # Private call log: a directory the consumer is never told about (not
  # the shim dir, not $EIGS_DIR, not their parents). Path baked into the
  # shim. Residual: any same-uid consumer that finds the shim script and
  # reads it can still recover the path.
  PRIV="$(mktemp -d "${TMPDIR:-/tmp}/ca-priv.$(scratch_tag)XXXXXX")" \
    || scratch_die "mktemp -d ca-priv failed"
  [ -n "$PRIV" ] && [ -d "$PRIV" ] || scratch_die "private log root is not a directory ($PRIV)"
  local _hid
  _hid="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$_hid" ] || _hid="c${RANDOM}${RANDOM}"
  mkdir -p "$PRIV/.$_hid" || scratch_die "cannot create the private call-log directory"
  CALL_LOG="$PRIV/.$_hid/log"
  : > "$CALL_LOG"
  # Counting wrapper, not a symlink: records argv+rc then runs the
  # candidate (cannot exec -- we need the rc). Probe argv does not count.
  {
    printf '%s\n' '#!/bin/sh'
    printf 'target=%s\n' "$(printf '%q' "$CAND_ABS")"
    printf 'log=%s\n' "$(printf '%q' "$CALL_LOG")"
    printf 'name=%s\n' eigenscript
    printf '%s\n' \
      '# CA-GUARD:private-log' \
      'log="$log"' \
      '# CA-GUARD:nontrivial-calls' \
      'kind=probe' \
      'for _a in "$@"; do' \
      '  case "$_a" in' \
      '    --version|--api|--help|-h|-v) ;;' \
      '    -*) ;;' \
      '    *) kind=call ;;' \
      '  esac' \
      'done' \
      '"$target" "$@"' \
      'rc=$?' \
      '# CA-GUARD:log-argv0' \
      'printf "%s|rc=%s|%s|%s\n" "$kind" "$rc" "$name" "$*" >> "$log"' \
      'exit "$rc"'
  } > "$SHIM/eigenscript" || shim_die "$SHIM/eigenscript" "write failed"
  chmod +x "$SHIM/eigenscript" || shim_die "$SHIM/eigenscript" "chmod failed"
  [ -x "$SHIM/eigenscript" ] || shim_die "$SHIM/eigenscript" "not executable after write"
  RESOLVED="$SHIM/eigenscript"
  # CA-GUARD:variant-mask
  if [ -n "${CAND_FULL_ABS:-}" ]; then
    write_counting_shim "$SHIM/eigenscript-full" "$CAND_FULL_ABS"
  else
    write_127_shim "$SHIM/eigenscript-full" eigenscript-full
  fi
  if [ -n "${CAND_GFX_ABS:-}" ]; then
    write_counting_shim "$SHIM/eigenscript-gfx" "$CAND_GFX_ABS"
  else
    write_127_shim "$SHIM/eigenscript-gfx" eigenscript-gfx
  fi
  # CA-GUARD:path-variant-sweep
  mask_path_variants
  # CA-GUARD:end-path-variant-sweep
  build_path_farm
  build_env_passthrough
  # CA-GUARD:end-variant-mask
  derive_candidate_tree "$CAND_ABS" || true
  if [ -z "${CAND_TREE:-}" ] && [ -e "$ECO/EigenScript" ]; then
    say "consumer_acceptance: refusing a bare candidate ($CAND_ABS) while sibling tree $ECO/EigenScript exists; pass a tree candidate (.../src/eigenscript) so EIGS_DIR is an overlay of the candidate"
    RUN_RC=2
    exit 2
  fi
  CAND_OVERLAY=""
  if [ -n "${CAND_TREE:-}" ]; then
    build_candidate_overlay "$CAND_TREE" "$WORK/cand_tree" || true
  fi
  SIBLING_BEFORE="$(sibling_is_present)"
  SIBLING_PRESENT="$SIBLING_BEFORE"
  SIBLING_AFTER="$SIBLING_BEFORE"

  # CA-GUARD:scan-inventory
  scan_inventory
  # CA-GUARD:end-scan-inventory

  if fixture_fault && [ "${CA_FAULT:-}" = "empty_skip_reason" ]; then
    SKIP_NAMES+=("planted_empty_skip")
    SKIP_PINS+=("v0.43.0")
    SKIP_REASONS+=("")
  fi

  say "consumer_acceptance run  bash=$BASH_VERSION  uname=$(uname -s)  timeout=$TMO_BIN  budget=${BUDGET}s"
  say "record: $RECORD"
  say "run_id: $RUN_ID"
  say "eco_root: $ECO"
  say "candidate: $CAND_ABS"
  if [ -n "${CAND_TREE:-}" ]; then
    say "candidate_tree: $CAND_TREE"
  else
    say "candidate_tree: (bare binary, no src/eigenscript tree)"
  fi
  say "eigenscript_resolved: $RESOLVED"
  say "path_masked: ${PATH_MASKED:-none}"
  say "path_farm: ${PATH_FARM_N:-0} executables"
  say "path_dropped: ${PATH_DROPPED:-none}"
  say "home_scratch: yes"
  say "env_passthrough: ${ENV_PASSTHROUGH:-none}"
  say "overlay_shimmed: ${OVERLAY_SHIMMED:-none}"
  say "sibling_binary_present: $SIBLING_BEFORE"
  if [ "$SIBLING_BEFORE" = yes ]; then
    say "note: \$ECO/EigenScript/src/eigenscript exists and differs from the candidate; consumers with hard-coded sibling paths (DMG#73) may have used it"
  fi
  say "inventory=$INVENTORY examined=PENDING"

  # --version is a candidate exec: same timeout, same background wait.
  local probe_log
  probe_log="$WORK/probe.log"
  run_bounded "$probe_log" "$CAND_ABS" --version
  PROBE_RC="$LAST_RC"
  if [ "$PROBE_RC" -ne 0 ]; then
    CAND_VER=""
    say "candidate_version: UNRUNNABLE (probe rc=$PROBE_RC)"
    ANY_BAD=1
    finalize_run
  fi
  CAND_VER="$(head -1 "$probe_log" 2>/dev/null || true)"
  CAND_VER="${CAND_VER:-}"
  CAND_SHA="$(file_sha256 "$CAND_ABS")"
  say "candidate_version: $CAND_VER"
  say "candidate_sha256: $CAND_SHA"
  if [ -n "${CAND_FULL_ABS:-}" ]; then
    run_bounded "$WORK/full_ver.log" "$CAND_FULL_ABS" --version
    CAND_FULL_VER="$(head -1 "$WORK/full_ver.log" 2>/dev/null || true)"
    CAND_FULL_SHA="$(file_sha256 "$CAND_FULL_ABS")"
    say "candidate_full: $CAND_FULL_ABS version=${CAND_FULL_VER:-} sha256=$CAND_FULL_SHA"
  fi
  if [ -n "${CAND_GFX_ABS:-}" ]; then
    run_bounded "$WORK/gfx_ver.log" "$CAND_GFX_ABS" --version
    CAND_GFX_VER="$(head -1 "$WORK/gfx_ver.log" 2>/dev/null || true)"
    CAND_GFX_SHA="$(file_sha256 "$CAND_GFX_ABS")"
    say "candidate_gfx_bin: $CAND_GFX_ABS version=${CAND_GFX_VER:-} sha256=$CAND_GFX_SHA"
  fi

  # Capability probe: --api --json is the language-surface index. gfx_open
  # listed there is necessary but not sufficient (a real binary always
  # lists the gfx group even when built headless); a bind probe confirms
  # the name is actually defined. Stubs that omit gfx_open skip the bind.
  CAND_HAS_GFX=0
  CAND_GFX_RC=""
  local api_log gfx_bind_log gfx_bind_src
  api_log="$WORK/api.log"
  run_bounded "$api_log" "$CAND_ABS" --api --json
  if [ ! -s "$api_log" ]; then
    run_bounded "$api_log" "$CAND_ABS" --api
  fi
  if grep -q 'gfx_open' "$api_log" 2>/dev/null; then
    gfx_bind_src="$WORK/gfx_bind.eigs"
    gfx_bind_log="$WORK/gfx_bind.log"
    printf 'print of gfx_open\n' > "$gfx_bind_src"
    run_bounded "$gfx_bind_log" "$CAND_ABS" "$gfx_bind_src"
    CAND_GFX_RC="$LAST_RC"
    # A defined gfx_open prints <fn gfx_open> (named native) or <builtin>
    # (older unnamed native). rc 0 with neither is not gfx. Any nonzero
    # is unknown (segfault, undefined variable, …).
    if [ "$LAST_RC" -eq 0 ] \
       && grep -qE '<fn gfx_open>|<builtin>' "$gfx_bind_log" 2>/dev/null \
       && ! grep -q "undefined variable" "$gfx_bind_log" 2>/dev/null; then
      CAND_HAS_GFX=1
    elif [ "$LAST_RC" -ne 0 ]; then
      CAND_HAS_GFX=unknown
    else
      CAND_HAS_GFX=0
    fi
  fi
  if [ -n "${CAND_GFX_ABS:-}" ]; then
    CAND_HAS_GFX=1
  fi
  say "candidate_gfx: $CAND_HAS_GFX"

  local i name pin cmd verdict STOP_AFTER kind
  STOP_AFTER=0
  if fixture_fault; then
    case "${CA_FAULT:-}" in
      stop_after=*)
        STOP_AFTER="${CA_FAULT#stop_after=}"
        case "$STOP_AFTER" in
          ''|*[!0-9]*) STOP_AFTER=0 ;;
        esac
        ;;
    esac
  fi

  i=0
  while [ "$i" -lt "${#SKIP_NAMES[@]}" ]; do
    append_skip "${SKIP_NAMES[$i]}" "${SKIP_PINS[$i]}" "${SKIP_REASONS[$i]}"
    say "  SKIP       ${SKIP_NAMES[$i]}  pin=${SKIP_PINS[$i]}  -- ${SKIP_REASONS[$i]}"
    i=$((i + 1))
  done

  EXAMINED=0
  i=0
  while [ "$i" -lt "$INVENTORY" ]; do
    if [ "$i" -eq 0 ] && fixture_fault && [ "${CA_FAULT:-}" = foreign_record ]; then
      printf '%s\n' '# foreign' 'run_id=FOREIGN_RUN' 'status=INCOMPLETE' 'inventory=PENDING' 'examined=PENDING' 'VERDICT: INCOMPLETE' > "$RECORD"
    fi
    name="${GATE_NAMES[$i]}"
    pin="${GATE_PINS[$i]}"
    cmd="${GATE_CMDS[$i]}"
    kind="${GATE_KINDS[$i]}"
    LAST_AMBIGUOUS=""
    if [ "$kind" = ambiguous ]; then
      LAST_VERDICT=UNRUNNABLE
      LAST_RC="-"; LAST_DUR="0"
      LAST_CALLS=0; LAST_OK=0; LAST_FAIL=0; LAST_SKIPS=0
      LAST_PREREQ=""
      LAST_AMBIGUOUS="${GATE_WFS[$i]}"
    else
      run_one "$name" "$pin" "$cmd"
    fi
    verdict="$LAST_VERDICT"
    append_row "$name" "$pin" "$verdict" "$LAST_RC" "$LAST_DUR"
    case "$verdict" in
      PASS|PASS\|*) ;;
      *)
        append_log_tail "$name" "$WORK/logs/$name.log"
        ;;
    esac
    EXAMINED=$((EXAMINED + 1))
    if [ -n "${LAST_AMBIGUOUS:-}" ]; then
      say "  UNRUNNABLE|ambiguous-workflow:${LAST_AMBIGUOUS}  $name  pin=$pin rc=$LAST_RC ${LAST_DUR}s cand_calls=${LAST_CALLS:-0} cand_ok=${LAST_OK:-0} cand_fail=${LAST_FAIL:-0} consumer_skips=${LAST_SKIPS:-0} sibling_binary_present=${SIBLING_PRESENT:-no}"
    elif [ -n "${LAST_PREREQ:-}" ]; then
      say "  UNRUNNABLE|prereq:${LAST_PREREQ}  $name  pin=$pin rc=$LAST_RC ${LAST_DUR}s cand_calls=${LAST_CALLS:-0} cand_ok=${LAST_OK:-0} cand_fail=${LAST_FAIL:-0} consumer_skips=${LAST_SKIPS:-0} sibling_binary_present=${SIBLING_PRESENT:-no}"
    else
      say "  $verdict  $name  pin=$pin rc=$LAST_RC ${LAST_DUR}s cand_calls=${LAST_CALLS:-0} cand_ok=${LAST_OK:-0} cand_fail=${LAST_FAIL:-0} consumer_skips=${LAST_SKIPS:-0} sibling_binary_present=${SIBLING_PRESENT:-no}"
    fi
    if [ "$verdict" != PASS ]; then
      ANY_BAD=1
    fi
    if [ "$STOP_AFTER" -gt 0 ] && [ "$EXAMINED" -ge "$STOP_AFTER" ]; then
      break
    fi
    i=$((i + 1))
  done

  SIBLING_AFTER="$(sibling_is_present)"
  SIBLING_PRESENT="$SIBLING_AFTER"
  if [ "$SIBLING_AFTER" != "$SIBLING_BEFORE" ]; then
    say "sibling_binary_present_after: $SIBLING_AFTER"
    say "sibling_binary_present_changed: ${SIBLING_BEFORE}→${SIBLING_AFTER}"
  else
    say "sibling_binary_present_after: $SIBLING_AFTER"
  fi

  finalize_run
}

# --- self-test ------------------------------------------------------------

mk_consumer() {
  local eco="$1" name="$2" runcmd="${3:-}"
  mkdir -p "$eco/$name/.devcontainer" "$eco/$name/.git"
  printf 'ARG EIGS_REF=v0.43.0\n' > "$eco/$name/.devcontainer/Dockerfile"
  if [ -n "$runcmd" ]; then
    mkdir -p "$eco/$name/.github/workflows"
    printf 'runCmd: %s\n' "$runcmd" > "$eco/$name/.github/workflows/ci.yml"
  fi
}

# Extra workflow files without runCmd so accept_cmd_of forks python more
# than once per consumer -- plant H needs the scan to outlast a 0.5s INT.
mk_consumer_padded() {
  mk_consumer "$1" "$2" "$3"
  mkdir -p "$1/$2/.github/workflows"
  printf '# no runCmd\n' > "$1/$2/.github/workflows/00-a.yml"
  printf '# no runCmd\n' > "$1/$2/.github/workflows/00-b.yml"
  printf '# no runCmd\n' > "$1/$2/.github/workflows/00-c.yml"
}

mk_consumer_block() {
  local eco="$1" name="$2"
  shift 2
  mkdir -p "$eco/$name/.devcontainer" "$eco/$name/.git" "$eco/$name/.github/workflows"
  printf 'ARG EIGS_REF=v0.43.0\n' > "$eco/$name/.devcontainer/Dockerfile"
  {
    printf 'runCmd: |\n'
    local line
    for line in "$@"; do
      printf '  %s\n' "$line"
    done
  } > "$eco/$name/.github/workflows/ci.yml"
}

mk_stub() {
  local path="$1" rc="$2"
  # --version is a separate probe and must succeed for a "runs, but the
  # consumer command fails" stub. A hanging/failing probe is mk_stub_hang_version
  # (plant E), not this helper -- sharing the run rc with --version was how
  # round 1 hid the unbounded probe.
  printf '%s\n' "#!/bin/sh" \
    "if [ \"\${1:-}\" = --version ]; then echo 'eigenscript stub'; exit 0; fi" \
    "if [ \"\${1:-}\" = --api ]; then echo '{\"builtins\":[]}'; exit 0; fi" \
    "exit $rc" > "$path"
  chmod +x "$path"
}

mk_stub_hang_version() {
  local path="$1"
  printf '%s\n' "#!/bin/sh" "if [ \"\${1:-}\" = --version ]; then sleep 30; echo hang-version; exit 0; fi" "exit 0" > "$path"
  chmod +x "$path"
}

# --api lists gfx_open so the harness bind probe (a positional .eigs) runs.
mk_stub_gfx() {
  local path="$1"
  printf '%s\n' '#!/bin/sh' \
    'if [ "${1:-}" = --version ]; then echo "eigenscript stub"; exit 0; fi' \
    'if [ "${1:-}" = --api ]; then echo "{\"builtins\":[\"gfx_open\"]}"; exit 0; fi' \
    'exit 0' > "$path"
  chmod +x "$path"
}

plant_line() {
  local name="$1" st="$2" detail="${3:-}"
  ST_PLANTS=$((${ST_PLANTS:-0} + 1))
  if [ "$st" -eq 0 ]; then
    say "plant $name: FIRES${detail:+ -- $detail}"
  else
    say "plant $name: SILENT${detail:+ -- $detail}"
    ST_FAIL=1
  fi
}

exact_verdict() {
  local src="$1" v="$2" n
  n="$(grep -c '^VERDICT:' <<< "$src" || true)"
  [ "$n" = 1 ] && grep -qx "VERDICT: $v" <<< "$src"
}

exact_verdict_file() {
  local f="$1" v="$2" n
  [ -f "$f" ] || return 1
  n="$(grep -c '^VERDICT:' "$f" || true)"
  [ "$n" = 1 ] && grep -qx "VERDICT: $v" "$f"
}

# 0=FIRES 1=SILENT. LAST_PLANT_DETAIL for the SILENT line.
# LAST_PLANT_OUT/REC/RC feed mutant_not_fires_kind: a mutant that did not
# FIRE is SILENT only if it printed exactly VERDICT: PASS (the fault
# genuinely read as success). Anything else is BROKEN-MUTANT.
LAST_PLANT_DETAIL=""
LAST_PLANT_OUT=""
LAST_PLANT_REC=""
LAST_PLANT_RC=""

note_plant() {
  LAST_PLANT_OUT="${1:-}"
  LAST_PLANT_REC="${2:-}"
  LAST_PLANT_RC="${3:-}"
  ST_RUNS=$((${ST_RUNS:-0} + 1))
  # CA-GUARD:unbound-witness
  # A COUNT is not a witness (mechanical-gates 120): round 5 run 2 read
  # `unbound=1 cap_hits=0` and there was nothing in the log to say WHICH
  # invocation produced it. The offending line names the script by path,
  # which is how a mutant under $st_root/mutants/<kind>/ is told apart
  # from the production script.
  local _ub
  _ub="$(grep -m1 'unbound variable' <<< "${1:-}" || true)"
  if [ -n "$_ub" ]; then
    if [ "${ST_IN_MUTANT:-0}" = 1 ]; then
      # A MUTANT is deliberately broken; its own diagnostics are not
      # evidence about the production script (that is why transverse_one
      # redirects its stderr capture too). Counted and PRINTED separately,
      # never dropped.
      ST_UNBOUND_MUTANT=$((${ST_UNBOUND_MUTANT:-0} + 1))
      ST_UNBOUND_MUTANT_WITNESS="${ST_UNBOUND_MUTANT_WITNESS:-$_ub}"
    else
      ST_UNBOUND=$((${ST_UNBOUND:-0} + 1))
      ST_UNBOUND_WITNESS="${ST_UNBOUND_WITNESS:-$_ub}"
    fi
  fi
  # CA-GUARD:end-unbound-witness
}

mutant_not_fires_kind() {
  local rec="${LAST_PLANT_REC:-}" out="${LAST_PLANT_OUT:-}"
  # "exactly VERDICT: PASS" means the fault read as success: a PASS
  # verdict line (run mode) or "VERDICT: PASS -- ..." (plan mode).
  # A mutant that emitted no PASS is BROKEN-MUTANT, not a catch.
  if [ -n "$rec" ] && [ -f "$rec" ] && grep -q '^VERDICT: PASS' "$rec"; then
    printf '%s' SILENT
    return
  fi
  if grep -q '^VERDICT: PASS' <<< "$out"; then
    printf '%s' SILENT
    return
  fi
  printf '%s' BROKEN-MUTANT
}

plant_plan_gap() {
  local sh="$1" eco="$2"
  local out rc
  out="$("$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  note_plant "$out" "" "$rc"
  if [ "$rc" -ne 0 ] && grep -q "GAP    zz-planted-consumer" <<< "$out" \
     && grep -q '^VERDICT: FAIL' <<< "$out"; then
    return 0
  fi
  return 1
}

plant_honest_good() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && exact_verdict_file "$rec" PASS \
     && exact_verdict "$out" PASS \
     && grep -q 'inventory=2 examined=2' "$rec" \
     && grep -q 'row|good_a|v0.43.0|PASS|' "$rec" \
     && grep -q 'row|good_b|v0.43.0|PASS|' "$rec" \
     && grep -q '^run_id=' "$rec" \
     && grep -q '^eco_root=' "$rec"; then
    return 0
  fi
  return 1
}

plant_early_stop() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=stop_after=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E 'inventory=|VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'inventory=3 examined=1' "$rec" \
     && exact_verdict_file "$rec" FAIL \
     && exact_verdict "$out" FAIL; then
    return 0
  fi
  return 1
}

plant_empty_inventory() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'inventory=0 examined=0' "$rec" \
     && exact_verdict_file "$rec" FAIL \
     && exact_verdict "$out" FAIL; then
    return 0
  fi
  return 1
}

plant_missing_command() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|no_wf|v0.43.0|UNRUNNABLE|-|' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

plant_skip_no_reason() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=empty_skip_reason CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q '^skip|planted_empty_skip|' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Trailing-text plant: FIRES when a VERDICT: PASS substring exists but the
# line is not exactly VERDICT: PASS (the extra-mutant case).
plant_trailing_verdict() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc verdict=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'VERDICT: PASS' "$rec" \
     && ! grep -qx 'VERDICT: PASS' "$rec"; then
    return 0
  fi
  if [ "$rc" -eq 0 ] \
     && grep -q 'VERDICT: PASS' <<< "$out" \
     && ! grep -qx 'VERDICT: PASS' <<< "$out"; then
    return 0
  fi
  return 1
}

# D / D2: SIGTERM/SIGHUP mid-wave. FIRE: exit 2, record INCOMPLETE, and
# exactly one `VERDICT: INCOMPLETE` line on stdout (the record header
# already says INCOMPLETE, so stdout is what finish_incomplete does).
plant_interruption() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local sig="${5:-TERM}"
  local pid waited rc t0 t1 elapsed n_out outf
  outf="${rec}.stdout"
  rm -f "$outf"
  CA_ECO="$eco" CA_TIMEOUT=20 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" >"$outf" 2>&1 &
  pid=$!
  waited=0
  while [ "$waited" -lt 20 ]; do
    if [ -f "$rec" ] && grep -q 'status=INCOMPLETE' "$rec" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  sleep 1
  t0="$(date +%s)"
  kill -"$sig" "$pid" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 8 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid"
  rc=$?
  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  n_out="$(grep -c '^VERDICT: INCOMPLETE$' "$outf" 2>/dev/null || true)"
  LAST_PLANT_DETAIL="rc=$rc elapsed=${elapsed}s n_out=$n_out rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$(cat "$outf" 2>/dev/null || true)" "$rec" "$rc"
  if [ "$rc" -eq 2 ] \
     && [ "$n_out" = 1 ] \
     && grep -q '^VERDICT: INCOMPLETE$' "$rec" \
     && grep -q 'status=INCOMPLETE' "$rec" \
     && [ "$elapsed" -le 5 ]; then
    return 0
  fi
  return 1
}

# H: INT in the pre-scan window over a stale PASS. FIRE: record is not
# PASS, exit 2. The 16-consumer skeleton makes scan_inventory take ~1s+
# (one python fork per workflow file) so 0.5s lands inside the scan.
#
# bash `&` sets SIGINT to SIG_IGN in the child, and a signal ignored on
# entry cannot be trapped (POSIX). Spawn via python so SIGINT is SIG_DFL
# and install_run_traps' INT trap actually fires.
plant_prescan_int() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local pid waited rc mark leftover
  mark="$(mktemp "${TMPDIR:-/tmp}/ca-hmark.XXXXXX")"
  local ready="${rec}.ready"
  rm -f "$ready"
  printf '%s\n' '# stale' 'run_id=OLD_RUN' 'status=COMPLETE' 'inventory=1 examined=1' 'VERDICT: PASS' > "$rec"
  CA_ECO="$eco" CA_TIMEOUT=20 CA_KILL_AFTER=1 CA_RECORD="$rec" CA_SCAN_PAUSE=2 CA_SCAN_READY="$ready" \
    python3 -c 'import os,signal,sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp("bash", ["bash"] + sys.argv[1:])' "$sh" run "$stub" >/dev/null 2>&1 &
  pid=$!
  # Wait for the CONDITION (the scan reached its pause), with a cap that
  # exists only so a broken harness cannot hang the self-test. Round 5: the
  # cap was 4 s, and the PATH farm added ~0.6 s of startup to every run
  # (2144 exec wrappers) -- on a loaded 2-core box the scan had not reached
  # the pause yet and the plant read SILENT for a reason that had nothing to
  # do with the guard it tests. A duration is not a witness; the `ready`
  # file is, so wait for it properly.
  waited=0
  while [ ! -f "$ready" ] && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ ! -f "$ready" ]; then
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$mark"
    note_plant "" "$rec" 98
    LAST_PLANT_DETAIL="scan never reached pause (ready missing after ${waited}00 ms)"
    return 1
  fi
  sleep 0.2
  kill -INT "$pid" 2>/dev/null
  waited=0
  while [ "$waited" -lt 8 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rc=99
  else
    wait "$pid"
    rc=$?
  fi
  leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "ca-run.$(scratch_tag)*" -newer "$mark" 2>/dev/null || true)"
  rm -f "$mark"
  if [ -n "$leftover" ]; then
    # Mutant without traps leaks scratch; do not leave it.
    # shellcheck disable=SC2086
    rm -rf $leftover
  fi
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "" "$rec" "$rc"
  if [ "$rc" -eq 2 ] && { [ ! -f "$rec" ] || ! grep -q '^VERDICT: PASS$' "$rec"; }; then
    return 0
  fi
  return 1
}

# I: stale PASS + unwritable directory. FIRE: record not readable as PASS, exit 1.
# The passed rec path is a unique prefix; the plant owns a sibling directory
# so chmod a-w cannot land on the self-test root (or any shared dir).
#
# uid 0 writes THROUGH a chmod a-w directory, so as root the fault cannot be
# planted at all (measured: PR #1224's `gate self-tests` job runs as root in
# the devcontainer and this row read intact=SILENT mutant=SILENT FAIL). As
# root the plant drops to an unprivileged user (runuser/setpriv + nobody) and
# opens the path so that user can reach the fixture. When no such user or
# tool exists, or a positive precondition PROBE under that user fails, the
# plant returns 3 = SKIP and the caller names it; the self-test's final line
# reports skipped=N so the count is never a silent OK.
# CA_FAULT=pretend_root (fixture-gated) takes the same decision branch on a
# non-root box, where no drop tool applies, so the SKIP path is exercised.
plant_stale_unwritable() {
  local sh="$1" eco="$2" stub="$3" rec_hint="$4"
  local dir rec out rc as_root=0 why=""
  [ "$(id -u)" = 0 ] && as_root=1
  # Gated on the FIXTURE's own marker (the self-test's ECO is the repo, not
  # a fixture, so fixture_fault would not see it). The pretend_root fault
  # takes the SAME decision branch as a real uid 0 with no usable drop.
  if [ -f "${eco:-}/.ca_fixture" ] && [ "${CA_FAULT:-}" = pretend_root ]; then
    as_root=1
  fi
  if [ "$as_root" -eq 1 ]; then
    # The whole self-test drops to an unprivileged user at entry when it
    # can (CA-GUARD:root-drop). Reaching here means it could not: root
    # writes through a 0555 directory, so "cannot write" is not plantable
    # and the plant SKIPs BY NAME and is counted -- never a silent OK.
    why="uid 0 and the self-test could not drop privileges; cannot plant an unwritable directory as root"
    LAST_PLANT_DETAIL="SKIP (root: $why)"
    note_plant "plant stale-unwritable: SKIP (root: $why)" "" 0
    return 3
  fi
  dir="${rec_hint}.rodir"
  mkdir -p "$dir"
  rec="$dir/record"
  printf '%s\n' 'run_id=OLD_RUN' 'status=COMPLETE' 'inventory=1 examined=1' 'VERDICT: PASS' > "$rec"
  chmod a-w "$dir"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  chmod u+w "$dir"
  LAST_PLANT_DETAIL="rc=$rc uid=$(id -u) rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] && { [ ! -f "$rec" ] || ! grep -q '^VERDICT: PASS$' "$rec"; }; then
    return 0
  fi
  return 1
}

# J / Q: signal during finalization (PATH shim for mv). FIRE: exactly one
# VERDICT line in the record, rc 0, and exactly one stdout VERDICT: PASS.
plant_footer_signal() {
  local sh="$1" eco="$2" stub="$3" rec="$4" shim="${5:-}"
  local out rc n env_path n_out
  env_path="$PATH"
  [ -n "$shim" ] && env_path="$shim:$PATH"
  out="$(PATH="$env_path" CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  n=0
  [ -f "$rec" ] && n="$(grep -c '^VERDICT:' "$rec" || true)"
  n_out="$(grep -c '^VERDICT:' <<< "$out" || true)"
  LAST_PLANT_DETAIL="rc=$rc n=$n n_out=$n_out rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$n" = 1 ] && [ "$rc" -eq 0 ] && [ "$n_out" = 1 ] && exact_verdict "$out" PASS; then
    return 0
  fi
  return 1
}

# K: CA_TIMEOUT=0 / 00 must exit 2.
plant_timeout_zero() {
  local sh="$1" eco="$2" stub="$3" rec="$4" val="$5"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT="$val" CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="val=$val rc=$rc"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 2 ] && grep -q 'positive integer' <<< "$out"; then
    return 0
  fi
  return 1
}

# L: false | true is a FAIL row (pipefail).
plant_pipefail() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|pipe_fail|v0.43.0|FAIL|' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# N: second invocation on the same CA_RECORD is refused. FIRE: run 2 exits 2
# with the busy message; run 1 finishes PASS with exactly one VERDICT.
plant_record_busy() {
  local sh="$1" eco1="$2" eco2="$3" stub_ok="$4" stub_bad="$5" rec="$6"
  local log1 pid1 rc1 rc2 out2 waited n
  log1="${rec}.log1"
  rm -f "$rec" "$log1"
  rm -rf "${rec}.lock.d"
  CA_ECO="$eco1" CA_TIMEOUT=10 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub_ok" >"$log1" 2>&1 &
  pid1=$!
  waited=0
  while [ "$waited" -lt 50 ]; do
    if [ -d "${rec}.lock.d" ]; then
      break
    fi
    # Mutant with no lock: start run 2 as soon as run 1 has a header,
    # so the two actually interleave rather than waiting out the sleep.
    if [ -f "$rec" ] && grep -q '^run_id=' "$rec" 2>/dev/null; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  # Run 2 uses the same passing stub: without the lock it completes PASS
  # (the interleaving the plant exists to stop). A failing stub would
  # make the gutted mutant BROKEN-MUTANT rather than SILENT.
  out2="$(CA_ECO="$eco2" CA_TIMEOUT=10 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub_ok" 2>&1)"
  rc2=$?
  wait "$pid1"
  rc1=$?
  n=0
  [ -f "$rec" ] && n="$(grep -c '^VERDICT:' "$rec" || true)"
  LAST_PLANT_DETAIL="rc1=$rc1 rc2=$rc2 n=$n busy=$(grep -c 'record busy' <<< "$out2" || true)"
  note_plant "$out2" "$rec" "$rc2"
  if [ "$rc2" -eq 2 ] \
     && grep -q 'record busy (held by run' <<< "$out2" \
     && [ "$rc1" -eq 0 ] \
     && [ "$n" = 1 ] \
     && exact_verdict_file "$rec" PASS \
     && ! grep -q '|FAIL|' "$rec"; then
    return 0
  fi
  return 1
}

# O: mid-run foreign file is refused. FIRE: FAIL by name (record not ours),
# foreign file clobbered in place, exit 1.
plant_foreign_record() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=foreign_record CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E 'run_id=|VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'record not ours' <<< "$out" \
     && [ -f "$rec" ] \
     && ! grep -q '^VERDICT: PASS$' "$rec" \
     && ! grep -q '^run_id=FOREIGN_RUN$' "$rec" \
     && grep -q '^VERDICT: INCOMPLETE$' "$rec"; then
    return 0
  fi
  return 1
}

# P: FAIL footer write fails; finish_incomplete still lands INCOMPLETE.
plant_fail_footer() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=fail_footer CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q '^VERDICT: INCOMPLETE$' "$rec"; then
    return 0
  fi
  return 1
}

# M: after a run, no /tmp/ca-run.* newer than the run's start remains.
plant_scratch_cleanup() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local mark leftover out rc
  mark="$(mktemp "${TMPDIR:-/tmp}/ca-mark.$(scratch_tag)XXXXXX")"
  sleep 0.05
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ca-run.*' -newer "$mark" 2>/dev/null || true)"
  rm -f "$mark"
  LAST_PLANT_DETAIL="rc=$rc leftover=$(printf '%s' "$leftover" | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ -z "$leftover" ]; then
    return 0
  fi
  # Mutant leftover must not escape the self-test.
  if [ -n "$leftover" ]; then
    # shellcheck disable=SC2086
    rm -rf $leftover
  fi
  return 1
}

# R: command `true` never calls the candidate. FIRE: UNEXERCISED, FAIL.
plant_unexercised() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|r_true|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# S: tree consumer invokes "$EIGS_DIR/src/eigenscript". FIRE: PASS cand_calls=1
# and candidate_tree= the dir containing that src/eigenscript. stub is the
# tree-shaped candidate (.../src/eigenscript).
plant_tree_consumer() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc tree
  tree="$(cd "$(dirname "$stub")/.." && pwd)" || return 1
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E 'candidate_tree=|^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && exact_verdict_file "$rec" PASS \
     && grep -q "^candidate_tree=$tree$" "$rec" \
     && grep -q 'row|tree_user|v0.43.0|PASS|' "$rec" \
     && grep -q 'cand_calls=1' "$rec"; then
    return 0
  fi
  return 1
}

# T: DECLARED command names a file that does not exist. FIRE: plan GAP + FAIL.
plant_declared_missing() {
  local sh="$1" eco="$2"
  local out rc
  out="$(CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  note_plant "$out" "" "$rc"
  if [ "$rc" -ne 0 ] \
     && grep -q "declared command's file does not exist" <<< "$out" \
     && grep -q '^VERDICT: FAIL' <<< "$out"; then
    return 0
  fi
  return 1
}

# U: PREREQS names a tool that is not on PATH. FIRE: UNRUNNABLE|prereq:<tool>.
plant_prereq_missing() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|u_prereq|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'prereq=nonexistent-tool' "$rec" \
     && grep -q 'UNRUNNABLE|prereq:nonexistent-tool' <<< "$out" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# V: consumer writes call| lines into CA_CAND_COUNT_FILE. FIRE: UNEXERCISED
# (the log is not that env var).
plant_forged_counter() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|v_forge|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# W: eigenscript --version only. FIRE: UNEXERCISED (probe, not a call).
plant_version_only() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|w_ver|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# X: eigenscript bad.eigs || true. FIRE: SWALLOWED (cand_ok=0 cand_fail>0).
plant_swallowed() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|x_swall|v0.43.0|SWALLOWED|' "$rec" \
     && grep -q 'cand_ok=0' "$rec" \
     && grep -q 'cand_fail=1' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Y: overlay write does not touch the candidate lib/; realpath stays in
# the overlay and is counted. stub is the tree-shaped candidate.
plant_overlay_write() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc tree before after
  tree="$(cd "$(dirname "$stub")/.." && pwd)" || return 1
  before="$(cksum "$tree/lib/marker" 2>/dev/null || echo missing)"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  after="$(cksum "$tree/lib/marker" 2>/dev/null || echo missing)"
  LAST_PLANT_DETAIL="rc=$rc before=$before after=$after rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && [ "$before" = "$after" ] \
     && grep -q 'row|y_ov|v0.43.0|PASS|' "$rec" \
     && grep -q 'cand_calls=1' "$rec" \
     && exact_verdict_file "$rec" PASS; then
    return 0
  fi
  return 1
}

# Z: consumer runs nothing. FIRE: cand_calls=0 (pre-run probe not attributed).
plant_probe_not_attributed() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|z_idle|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# AA: script prefers sibling over PATH but honours EIGENSCRIPT_BIN first.
# FIRE: PASS cand_calls=1 and the sibling log is empty.
plant_bin_routing() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc slog
  slog="$eco/../aa-sibling.log"
  rm -f "$slog"
  : > "$slog"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc slog=$(wc -c < "$slog" 2>/dev/null || echo 0) rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && exact_verdict_file "$rec" PASS \
     && grep -q 'row|aa_route|v0.43.0|PASS|' "$rec" \
     && grep -q 'cand_calls=1' "$rec" \
     && [ ! -s "$slog" ]; then
    return 0
  fi
  return 1
}

# AB: gfx in PREREQS, candidate --api omits gfx_open. FIRE: UNRUNNABLE|prereq:gfx-build.
plant_gfx_prereq() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|ab_gfx|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'prereq=gfx-build' "$rec" \
     && grep -q 'UNRUNNABLE|prereq:gfx-build' <<< "$out" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# AC: consumer swaps the record for a symlink to a victim. FIRE: victim
# keeps its bytes (clobber unlinks, never truncates through the link).
# The swap command bakes THIS rec path (CA_RECORD is unset in the consumer).
plant_clobber_symlink() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc victim
  victim="${rec}.victim"
  printf 'VICTIM DATA -- 1234567890\n' > "$victim"
  mk_consumer_block "$eco" ac_swap \
    "eigenscript work.eigs" \
    "rm -f $rec" \
    "ln -s $victim $rec"
  LAST_PLANT_DETAIL=""
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc victim=$(wc -c < "$victim" 2>/dev/null || echo missing) rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ -f "$victim" ] \
     && grep -q 'VICTIM DATA -- 1234567890' "$victim"; then
    return 0
  fi
  return 1
}

# Straggler from row N must not land in row N+1. FIRE: b_never_calls UNEXERCISED.
plant_straggler() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=8 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if grep -q 'row|b_never_calls|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec"; then
    return 0
  fi
  return 1
}

# Export-block join: EIGENSCRIPT_DIR equals EIGS_DIR and ends in cand_tree.
plant_exports_join() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'row|exp_join|v0.43.0|PASS|' "$rec" \
     && exact_verdict_file "$rec" PASS; then
    return 0
  fi
  return 1
}

# Find every regular file under the shim dir's parent and $EIGS_DIR; forging
# them must leave the row UNEXERCISED.
plant_private_find() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|priv_find|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Overlay symlink: write through $EIGS_DIR/lib/link must not change the
# outside file. stub is the tree-shaped candidate.
plant_overlay_symlink() {
  local sh="$1" eco="$2" stub="$3" rec="$4" outside="$5"
  local out rc before after
  before="$(cat "$outside" 2>/dev/null || echo missing)"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  after="$(cat "$outside" 2>/dev/null || echo missing)"
  LAST_PLANT_DETAIL="rc=$rc before=$before after=$after rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$before" = "$after" ] \
     && [ "$before" = "ORIGINAL" ] \
     && grep -q 'row|ov_link|v0.43.0|PASS|' "$rec"; then
    return 0
  fi
  return 1
}

# Bind probe segfaults → candidate_gfx unknown, gfx prereq missing with rc.
plant_gfx_crash() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc gfx=$(grep '^candidate_gfx:' <<< "$out" | tr '\n' ' ') rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'candidate_gfx: unknown' <<< "$out" \
     && grep -q 'row|ab_crash|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'prereq=gfx-build (probe rc 139)' "$rec"; then
    return 0
  fi
  return 1
}

# DMG-shaped self-skip: consumer_skips=1 and not a bare PASS.
plant_gfx_selfskip() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if grep -q 'row|dmg_like|v0.43.0|PASS|skips=1|' "$rec" \
     && grep -q 'consumer_skips=1' "$rec" \
     && ! grep -q 'row|dmg_like|v0.43.0|PASS|0|' "$rec"; then
    return 0
  fi
  return 1
}

# Bare candidate + sibling tree present → exit 2 before any row.
plant_bare_sibling() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc out=$(grep -E 'refusing a bare|VERDICT:|^row|' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 2 ] \
     && grep -q 'refusing a bare candidate' <<< "$out" \
     && grep -F -q "$stub" <<< "$out" \
     && grep -F -q "$eco/EigenScript" <<< "$out" \
     && ! grep -q '^row|' "$rec" 2>/dev/null; then
    return 0
  fi
  return 1
}

# sibling_binary_present computed after the wave; no→yes when it changed.
plant_sibling_late() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E 'sibling_binary_present' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if grep -q '^sibling_binary_present=no$' "$rec" \
     && grep -q '^sibling_binary_present_after=yes$' "$rec" \
     && grep -q 'sibling_binary_present_changed=no→yes' "$rec"; then
    return 0
  fi
  return 1
}

apply_mutation() {
  local src="$1" dest="$2" kind="$3"
  python3 - "$src" "$dest" "$kind" << 'PY'
import sys
src, dest, kind = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
repls = {
    "farm-exec-wrapper": (
        '      # CA-GUARD:farm-exec-wrapper\n'
        '      if true; then',
        '      # CA-GUARD:farm-exec-wrapper\n'
        '      if false; then',
    ),
    "farm-fail-closed": (
        'farm_die() {\n'
        '  say "consumer_acceptance: cannot build the PATH farm under ${FARM:-<unset>} ($1)"\n'
        '  RUN_RC=2\n'
        '  exit 2\n'
        '}',
        'farm_die() {\n'
        '  : "fall open on $1"\n'
        '  return 0\n'
        '}',
    ),
    "shim-fail-closed": (
        'shim_die() {\n'
        '  say "consumer_acceptance: cannot write the shim ${1:-<unset>} ($2)"\n'
        '  RUN_RC=2\n'
        '  exit 2\n'
        '}',
        'shim_die() {\n'
        '  : "fall open on $1 $2"\n'
        '  return 0\n'
        '}',
    ),
    "path-edit-scan": (
        '  # CA-GUARD:path-edit-guard\n'
        '  if true && [ "$_has_edit" -eq 1 ]; then',
        '  # CA-GUARD:path-edit-guard\n'
        '  if false && [ "$_has_edit" -eq 1 ]; then',
    ),
    "drop-fixture-gate": (
        '  # CA-GUARD:drop-fixture-gate\n'
        '  if [ -z "${CA_ECO:-}" ] || [ ! -f "$CA_ECO/.ca_fixture" ]; then return 1; fi',
        '  # CA-GUARD:drop-fixture-gate\n'
        '  :',
    ),
    "env-passthrough": (
        '  local env_pass="${ENV_PASS_EXPORTS:-}"\n'
        '  # CA-GUARD:end-home-scratch',
        '  local env_pass=""\n'
        '  # CA-GUARD:end-home-scratch',
    ),
    "path-farm": (
        '  path_export="$(printf \'export PATH=%q:%q\' "$SHIM" "$FARM")"',
        '  path_export="$(printf \'export PATH=%q:"$PATH"\' "$SHIM")"',
    ),
    "home-scratch": (
        '  home_export="$(printf \'export HOME=%q\' "$row_home")"',
        '  home_export=""',
    ),
    "not-found-guard": (
        '  # CA-GUARD:not-found-guard\n'
        '  if true; then',
        '  # CA-GUARD:not-found-guard\n'
        '  if false; then',
    ),
    "scratch-fail-closed": (
        'scratch_die() {\n'
        '  say "consumer_acceptance: cannot create scratch under ${TMPDIR:-/tmp} ($1)"\n'
        '  RUN_RC=2\n'
        '  exit 2\n'
        '}',
        'scratch_die() {\n'
        '  : "fall open on $1"\n'
        '  return 0\n'
        '}',
    ),
    "overlay-variant-shim": (
        '    case "$b" in\n'
        '      eigenscript|eigenscript-*) ;;\n'
        '      *) continue ;;\n'
        '    esac\n'
        '    rm -f "$f"',
        '    case "$b" in\n'
        '      eigenscript) ;;\n'
        '      *) continue ;;\n'
        '    esac\n'
        '    rm -f "$f"',
    ),
    "drop-sha-readback": (
        '  if [ "$got" = "$want" ]; then printf \'%s\' OK; return; fi',
        '  if [ -n "$got" ]; then printf \'%s\' OK; return; fi',
    ),
    "outer-tmp-token": (
        '  [ -n "$token" ] && pat="ca-*${token}*"',
        '  [ -n "$token" ] && pat="ca-*"',
    ),
    "examined-eq": (
        '  # CA-GUARD:examined-eq-inventory\n'
        '  elif [ "$EXAMINED" -ne "$INVENTORY" ]; then',
        '  # CA-GUARD:examined-eq-inventory\n'
        '  elif false && [ "$EXAMINED" -ne "$INVENTORY" ]; then',
    ),
    "nonempty": (
        '  # CA-GUARD:nonempty-inventory\n'
        '  if [ "$INVENTORY" -eq 0 ]; then',
        '  # CA-GUARD:nonempty-inventory\n'
        '  if false && [ "$INVENTORY" -eq 0 ]; then',
    ),
    "missing-command": (
        '  # CA-GUARD:missing-command\n'
        '  if [ -z "$cmd" ]; then\n'
        '    LAST_VERDICT=UNRUNNABLE',
        '  # CA-GUARD:missing-command\n'
        '  if [ -z "$cmd" ]; then\n'
        '    LAST_VERDICT=PASS',
    ),
    "skip-reason": (
        '  # CA-GUARD:skip-reason\n'
        '  if [ -z "$3" ]; then\n'
        '    SKIP_MISSING_REASON=1\n'
        '    ANY_BAD=1\n'
        '  fi',
        '  # CA-GUARD:skip-reason\n'
        '  if false && [ -z "$3" ]; then\n'
        '    SKIP_MISSING_REASON=1\n'
        '    ANY_BAD=1\n'
        '  fi',
    ),
    "exact-verdict": (
        "  # CA-GUARD:exact-verdict\n"
        "  printf 'VERDICT: %s\\n' \"$1\"",
        "  # CA-GUARD:exact-verdict\n"
        "  printf 'VERDICT: %s extra\\n' \"$1\"",
    ),
    "plan-gap": (
        '  # CA-GUARD:plan-gap\n'
        '  if [ "$GAPS" -gt 0 ]; then',
        '  # CA-GUARD:plan-gap\n'
        '  if false && [ "$GAPS" -gt 0 ]; then',
    ),
    "invalidate-fail-closed": (
        '  # CA-GUARD:invalidate-fail-closed\n'
        '  invalidate_previous_record || die_record "cannot invalidate previous record at $RECORD"',
        '  # CA-GUARD:invalidate-fail-closed\n'
        '  true',
    ),
    "no-pipefail": (
        '  # CA-GUARD:block-pipefail\n'
        '  run_bounded "$log" bash -e -o pipefail -c "$cd_cmd"',
        '  # CA-GUARD:block-pipefail\n'
        '  run_bounded "$log" bash -e -c "$cd_cmd"',
    ),
    "no-cleanup": (
        '    # CA-GUARD:scratch-cleanup\n'
        '    rm -rf "$WORK"',
        '    # CA-GUARD:scratch-cleanup\n'
        '    :',
    ),
    "path-variant-sweep": (
        '  # CA-GUARD:path-variant-sweep\n'
        '  mask_path_variants\n',
        '  # CA-GUARD:path-variant-sweep\n'
        '  true\n',
    ),
    "undeclared-variant": (
        '  if [ -n "$LAST_UNDECLARED" ]; then\n'
        '    LAST_VERDICT="FAIL|undeclared-variant:$LAST_UNDECLARED"\n'
        '  fi',
        '  if false && [ -n "$LAST_UNDECLARED" ]; then\n'
        '    LAST_VERDICT="FAIL|undeclared-variant:$LAST_UNDECLARED"\n'
        '  fi',
    ),
    "record-dated-name": (
        '      case "$b" in\n'
        '        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.record) ;;\n'
        '        *)\n'
        '          RECORD_STRAY="${RECORD_STRAY:+$RECORD_STRAY }$b"\n'
        '          continue\n'
        '          ;;\n'
        '      esac',
        '      case "$b" in\n'
        '        *) ;;\n'
        '      esac',
    ),
    "stderr-capture": (
        'if [ -n "${CA_STDERR_CAP:-}" ]; then\n'
        '  exec 2> >(tee -a "$CA_STDERR_CAP" >&2)\n'
        'fi',
        'if false; then\n'
        '  exec 2> >(tee -a "${CA_STDERR_CAP:-/dev/null}" >&2)\n'
        'fi',
    ),
    "plant-total": (
        '  # CA-GUARD:plant-total\n'
        '  if [ "$((plants + skipped))" -eq "$ST_DECLARED_PLANTS" ]; then',
        '  # CA-GUARD:plant-total\n'
        '  if true; then',
    ),
    "timeout-unbound": (
        '    124) LAST_VERDICT=HANG ;;',
        '    124) LAST_VERDICT=HANG; printf \'%s\' "$critic_probe" ;;',
    ),
    "crash-early": (
        '  # CA-GUARD:not-crash\n'
        '  local cand="" arg\n',
        '  # CA-GUARD:not-crash\n'
        '  exit 7\n'
        '  local cand="" arg\n',
    ),
    "record-lock": (
        '  # CA-GUARD:record-lock\n'
        '  if ! acquire_record_lock; then\n'
        '    RECORD_FINISHED=1\n'
        '    RUN_RC=2\n'
        '    exit 2\n'
        '  fi',
        '  # CA-GUARD:record-lock\n'
        '  true',
    ),
    "append-owned": (
        '      # CA-GUARD:append-owned\n'
        '      # The ONLY file we may append to without our run_id is a ZERO-BYTE one\n'
        '      # (the in-place clobber after truncate). A nonempty file with no run_id\n'
        '      # line is somebody else\'s content (round-4 residual R11: a replacement\n'
        '      # INCOMPLETE record with no run_id was accepted and the final record read\n'
        '      # PASS with rows missing). And never through a symlink (R7).\n'
        '      if [ -L "$RECORD" ]; then\n'
        '        RECORD_WRITE_ERR="record path is a symlink"\n'
        '        return 1\n'
        '      fi\n'
        '      if [ -s "$RECORD" ] \\\n'
        '         && ! grep -Fx "run_id=${RUN_ID}" "$RECORD" >/dev/null 2>&1; then\n'
        '        RECORD_WRITE_ERR="record not ours"\n'
        '        return 1\n'
        '      fi',
        '      # CA-GUARD:append-owned\n'
        '      true',
    ),
    "die-record-flag": (
        '  # CA-GUARD:die-record-flag\n'
        '  # Leave RECORD_FINISHED=0 when the footer did not land, so the EXIT\n'
        '  # trap\'s finish_incomplete still appends INCOMPLETE or clobbers a\n'
        '  # foreign file. Never a foreign PASS at the path.\n'
        '  if [ "$footer_ok" -eq 1 ]; then\n'
        '    RECORD_FINISHED=1\n'
        '  fi',
        '  # CA-GUARD:die-record-flag\n'
        '  RECORD_FINISHED=1',
    ),
    "stdout-verdict": (
        '  # CA-GUARD:stdout-verdict\n'
        '  case "${RUN_RC:-1}" in\n'
        '    0) emit_stdout_verdict PASS ;;\n'
        '    1) emit_stdout_verdict FAIL ;;\n'
        '    *) emit_stdout_verdict INCOMPLETE ;;\n'
        '  esac',
        '  # CA-GUARD:stdout-verdict\n'
        '  :',
    ),
    "cand-calls": (
        '  # CA-GUARD:cand-calls\n'
        '  # A PASS that never reached the candidate is UNEXERCISED (mechanical-gates\n'
        '  # §113: every arm must prove it RAN). HANG/KILLED/UNRUNNABLE/FAIL keep\n'
        '  # their names -- cand_calls=0 cannot be PASS.\n'
        '  if [ "$LAST_VERDICT" = PASS ] && [ "$LAST_CALLS" -eq 0 ]; then\n'
        '    LAST_VERDICT=UNEXERCISED\n'
        '  fi',
        '  # CA-GUARD:cand-calls\n'
        '  # A PASS that never reached the candidate is UNEXERCISED (mechanical-gates\n'
        '  # §113: every arm must prove it RAN). HANG/KILLED/UNRUNNABLE/FAIL keep\n'
        '  # their names -- cand_calls=0 cannot be PASS.\n'
        '  if false && [ "$LAST_VERDICT" = PASS ] && [ "$LAST_CALLS" -eq 0 ]; then\n'
        '    LAST_VERDICT=UNEXERCISED\n'
        '  fi',
    ),
    "eigs-dir": (
        '  # CA-GUARD:eigs-dir\n'
        '  if [ -n "${CAND_OVERLAY:-}" ]; then',
        '  # CA-GUARD:eigs-dir\n'
        '  if false && [ -n "${CAND_OVERLAY:-}" ]; then',
    ),
    "declared-file": (
        '      # CA-GUARD:declared-file\n'
        '      miss="$(declared_missing_file "$ECO/$r" "$cmd")"\n'
        '      if [ -n "$miss" ]; then',
        '      # CA-GUARD:declared-file\n'
        '      miss="$(declared_missing_file "$ECO/$r" "$cmd")"\n'
        '      if false && [ -n "$miss" ]; then',
    ),
    "prereq": (
        '  # CA-GUARD:prereq\n'
        '  if prereq_tool="$(missing_prereq "$name" "$cmd")"; then',
        '  # CA-GUARD:prereq\n'
        '  if false && prereq_tool="$(missing_prereq "$name" "$cmd")"; then',
    ),
    "eigenscript-bin": (
        '  # CA-GUARD:eigenscript-bin\n'
        '  if true; then',
        '  # CA-GUARD:eigenscript-bin\n'
        '  if false; then',
    ),
    "nontrivial-calls": (
        '      \'# CA-GUARD:nontrivial-calls\' \\\n'
        '      \'kind=probe\' \\',
        '      \'# CA-GUARD:nontrivial-calls\' \\\n'
        '      \'kind=call\' \\',
    ),
    "swallowed": (
        '  # CA-GUARD:swallowed\n'
        '  # Command exited 0 AND no nontrivial candidate invocation succeeded:\n'
        '  # the candidate never once worked and the consumer still reported success.\n'
        '  # A nonzero candidate rc is not by itself a failure (lint/fail-soft).\n'
        '  if [ "$LAST_VERDICT" = PASS ] && [ "${LAST_OK:-0}" -eq 0 ] && [ "${LAST_FAIL:-0}" -gt 0 ]; then\n'
        '    LAST_VERDICT=SWALLOWED\n'
        '  fi',
        '  # CA-GUARD:swallowed\n'
        '  if false && [ "$LAST_VERDICT" = PASS ] && [ "${LAST_OK:-0}" -eq 0 ] && [ "${LAST_FAIL:-0}" -gt 0 ]; then\n'
        '    LAST_VERDICT=SWALLOWED\n'
        '  fi',
    ),

    "gfx-prereq": (
        '      # CA-GUARD:gfx-prereq\n'
        '      if [ "${CAND_HAS_GFX:-0}" != 1 ]; then',
        '      # CA-GUARD:gfx-prereq\n'
        '      if false && [ "${CAND_HAS_GFX:-0}" != 1 ]; then',
    ),
    "finish-incomplete": (
        'finish_incomplete() {\n'
        '  # CA-GUARD:finish-incomplete\n',
        'finish_incomplete() {\n'
        '  # CA-GUARD:finish-incomplete\n'
        '  return 0\n',
    ),
    "clobber-no-follow": (
        '  # CA-GUARD:clobber-no-follow\n'
        '  if [ -L "$RECORD" ]; then\n'
        '    rm -f "$RECORD" || {\n'
        '      RECORD_WRITE_ERR="cannot unlink symlink at $RECORD"\n'
        '      return 1\n'
        '    }\n'
        '  fi',
        '  # CA-GUARD:clobber-no-follow\n'
        '  true',
    ),
    "log-tail": (
        '  # CA-GUARD:log-tail\n'
        '  tailf="$WORK/tail.$name"\n',
        '  # CA-GUARD:log-tail\n'
        '  return 0\n'
        '  tailf="$WORK/tail.$name"\n',
    ),
    "noglob-split": (
        '    # CA-GUARD:noglob-split\n'
        '    local glob_off=0\n'
        '    case "$-" in *f*) glob_off=1 ;; esac\n'
        '    set -f\n',
        '    # CA-GUARD:noglob-split\n'
        '    local glob_off=0\n'
        '    case "$-" in *f*) glob_off=1 ;; esac\n'
        '    set +f\n',
    ),
    "expected-floor": (
        '  # CA-GUARD:expected-floor\n',
        '  # CA-GUARD:expected-floor\n'
        '  EXPECTED_LIST=()\n',
    ),
    "record-floor": (
        '  # CA-GUARD:record-floor\n'
        '  RECORD_FLOOR="$computed"\n',
        '  # CA-GUARD:record-floor\n'
        '  RECORD_FLOOR=0\n',
    ),
    "overlay-retry-rm": (
        '        # CA-GUARD:overlay-retry-rm\n'
        '        rm -rf "$to/$base"\n',
        '        # CA-GUARD:overlay-retry-rm\n'
        '        :\n',
    ),
    "tmp-beside-record": (
        '      # CA-GUARD:tmp-beside-record\n'
        '      dir="$(dirname "$RECORD")"\n',
        '      # CA-GUARD:tmp-beside-record\n'
        '      dir="${WORK:-${TMPDIR:-/tmp}}"\n',
    ),
    "workflow-prefer": (
        '  # CA-GUARD:workflow-prefer\n'
        '  for p in ci.yml tests.yml test.yml; do\n',
        '  # CA-GUARD:workflow-prefer\n'
        '  for p in __none__; do\n',
    ),
    "pause-before-rename": (
        '      if fixture_fault && [ "${CA_FAULT:-}" = pause_before_rename ] && [ "$tag" = rewrite ]; then\n'
        '        sleep 30 &\n'
        '        wait $! || true\n'
        '      fi\n',
        '      if fixture_fault && [ "${CA_FAULT:-}" = pause_before_rename ] && [ "$tag" = rewrite ]; then\n'
        '        RECORD_FINISHED=1\n'
        '        sleep 30 &\n'
        '        wait $! || true\n'
        '      fi\n',
    ),
}
if kind == "traps-after-scan":
    start = "  # CA-GUARD:traps-before-scan\n"
    end = "  # CA-GUARD:end-traps-before-scan\n"
    scan_end = "  # CA-GUARD:end-scan-inventory\n"
    i = text.find(start)
    j = text.find(end)
    if i < 0 or j < 0 or j < i:
        sys.stderr.write("mutation traps-after-scan: block not found\n")
        sys.exit(2)
    j += len(end)
    block = text[i:j]
    text = text[:i] + text[j:]
    k = text.find(scan_end)
    if k < 0:
        sys.stderr.write("mutation traps-after-scan: scan end not found\n")
        sys.exit(2)
    k += len(scan_end)
    text = text[:k] + block + text[k:]
elif kind == "timeout-zero":
    start = "  # CA-GUARD:timeout-positive\n"
    end = "  # CA-GUARD:end-timeout-positive\n"
    i = text.find(start)
    j = text.find(end)
    if i < 0 or j < 0 or j < i:
        sys.stderr.write("mutation timeout-zero: block not found\n")
        sys.exit(2)
    j += len(end)
    text = text[:i] + start + "  : # gutted timeout validation\n" + end + text[j:]
elif kind == "finished-after-rename":
    # Gut the file re-read so HUP-after-successful-mv is treated as
    # INCOMPLETE (RECORD_FINISHED still 0 until mv returns to write_record).
    a = (
        '  # CA-GUARD:verdict-from-file\n'
    )
    b = (
        '  # CA-GUARD:verdict-from-file\n'
        '  true\n'
        '  if false; then\n'
    )
    if a not in text:
        sys.stderr.write("mutation finished-after-rename: verdict-from-file not found\n")
        sys.exit(2)
    text = text.replace(a, b, 1)
    # Close the if false so the rest of finish_incomplete still parses.
    needle = (
        '  [ "${RECORD_FINISHED:-0}" -eq 1 ] && return\n'
    )
    repl = (
        '  fi\n'
        '  [ "${RECORD_FINISHED:-0}" -eq 1 ] && return\n'
    )
    if needle not in text:
        sys.stderr.write("mutation finished-after-rename: RECORD_FINISHED early-return not found\n")
        sys.exit(2)
    text = text.replace(needle, repl, 1)
elif kind == "private-log":
    a = (
        "      '# CA-GUARD:private-log' \\\n"
        "      'log=\"$log\"' \\\n"
    )
    b = (
        "      '# CA-GUARD:private-log' \\\n"
        "      'log=\"${CA_CAND_COUNT_FILE:-$log}\"' \\\n"
    )
    if a not in text:
        sys.stderr.write("mutation private-log: shim log needle not found\n")
        sys.exit(2)
    text = text.replace(a, b, 1)
    a2 = (
        '  # CA-GUARD:private-log-export\n'
        '  true\n'
    )
    b2 = (
        '  # CA-GUARD:private-log-export\n'
        '  eigs_exports="${eigs_exports}$(printf \'export CA_CAND_COUNT_FILE=%q\\n\' "$CALL_LOG")"\n'
    )
    if a2 not in text:
        sys.stderr.write("mutation private-log: export needle not found\n")
        sys.exit(2)
    text = text.replace(a2, b2, 1)
    start = "  # CA-GUARD:strip-ca-env\n"
    i = text.find(start)
    if i < 0:
        sys.stderr.write("mutation private-log: strip-ca-env guard not found\n")
        sys.exit(2)
    line_end = text.find("\n", i + len(start))
    if line_end < 0 or "strip_ca=" not in text[i:line_end + 1]:
        sys.stderr.write("mutation private-log: strip_ca assignment not found\n")
        sys.exit(2)
    text = text[:i] + start + "  strip_ca=true" + text[line_end:]
elif kind == "probe-not-attributed":
    pairs = [
        ('run_bounded "$probe_log" "$CAND_ABS" --version',
         'run_bounded "$probe_log" "$SHIM/eigenscript" --version'),
        ('run_bounded "$api_log" "$CAND_ABS" --api --json',
         'run_bounded "$api_log" "$SHIM/eigenscript" --api --json'),
        ('run_bounded "$api_log" "$CAND_ABS" --api',
         'run_bounded "$api_log" "$SHIM/eigenscript" --api'),
        ('run_bounded "$gfx_bind_log" "$CAND_ABS" "$gfx_bind_src"',
         'run_bounded "$gfx_bind_log" "$SHIM/eigenscript" "$gfx_bind_src"'),
        ('    rm -f "$CALL_LOG"\n    : > "$CALL_LOG"\n',
         '    :\n'),
    ]
    for a, b in pairs:
        if a not in text:
            sys.stderr.write("mutation probe-not-attributed: needle not found: %r\n" % (a[:60],))
            sys.exit(2)
        text = text.replace(a, b, 1)
elif kind == "overlay-copy":
    a = (
        '  # CA-GUARD:overlay-copy\n'
        '  overlay_copy_dir() {\n'
    )
    if a not in text:
        sys.stderr.write("mutation overlay-copy: overlay_copy_dir not found\n")
        sys.exit(2)
    # Replace the copy helper with symlink overlay (the original plant Y
    # mechanism): writes through lib/ go to the real tree.
    start = text.find(a)
    end = text.find('  if [ -d "$src/lib" ]; then\n    overlay_copy_dir "$src/lib" "$dst/lib" lib\n  fi\n', start)
    if end < 0:
        sys.stderr.write("mutation overlay-copy: lib copy call not found\n")
        sys.exit(2)
    end = text.find('\n', end + len('  if [ -d "$src/lib" ]; then\n    overlay_copy_dir "$src/lib" "$dst/lib" lib\n  fi'))
    b = (
        '  # CA-GUARD:overlay-copy\n'
        '  mkdir -p "$dst/src"\n'
        '  if [ -d "$src/src" ]; then\n'
        '    for s in "$src/src"/*; do\n'
        '      sb="$(basename "$s")"\n'
        '      if [ "$sb" = eigenscript ]; then\n'
        '        ln -s "$SHIM/eigenscript" "$dst/src/eigenscript"\n'
        '      else\n'
        '        ln -s "$s" "$dst/src/$sb"\n'
        '      fi\n'
        '    done\n'
        '  else\n'
        '    ln -s "$SHIM/eigenscript" "$dst/src/eigenscript"\n'
        '  fi\n'
        '  if [ -d "$src/lib" ]; then\n'
        '    ln -s "$src/lib" "$dst/lib"\n'
        '  fi\n'
    )
    text = text[:start] + b + text[end+1:]
elif kind == "variant-mask":
    start = "  # CA-GUARD:variant-mask\n"
    end = "  # CA-GUARD:end-variant-mask\n"
    # Two blocks (shim install + run_one check). Gut both.
    count = 0
    pos = 0
    while True:
        i = text.find(start, pos)
        j = text.find(end, i if i >= 0 else pos)
        if i < 0 or j < 0 or j < i:
            break
        j += len(end)
        repl = start + "  true\n" + end
        text = text[:i] + repl + text[j:]
        pos = i + len(repl)
        count += 1
        if count > 5:
            break
    if count < 2:
        sys.stderr.write("mutation variant-mask: expected 2 blocks, found %d\n" % count)
        sys.exit(2)
elif kind == "usage-before-record":
    start = "  # CA-GUARD:usage-before-record\n"
    end = "  # CA-GUARD:end-usage-before-record\n"
    i = text.find(start)
    j = text.find(end)
    if i < 0 or j < 0 or j < i:
        sys.stderr.write("mutation usage-before-record: block not found\n")
        sys.exit(2)
    j += len(end)
    text = text[:i] + start + "  : # gutted usage validation\n" + end + text[j:]
elif kind in repls:
    a, b = repls[kind]
    if a not in text:
        sys.stderr.write("mutation %s: needle not found\n" % kind)
        sys.exit(2)
    if kind == "noglob-split":
        text = text.replace(a, b)
        if a in text:
            sys.stderr.write("mutation noglob-split: leftover needle\n")
            sys.exit(2)
    else:
        text = text.replace(a, b, 1)
else:
    sys.stderr.write("unknown mutation %s\n" % kind)
    sys.exit(2)
open(dest, "w").write(text)
sys.exit(0)
PY
}

# $3: the script to mutate (default: this one). A plant that mutates the
# script it was HANDED can be run transversely -- the transverse mutant is
# the source, and the plant's own mutation stacks on top of it.
prep_mutant() {
  local d="$1" kind="$2" src="${3:-$HERE/tools/consumer_acceptance.sh}"
  mkdir -p "$d/tools"
  cp "$src" "$d/tools/consumer_acceptance.sh.orig"
  cp "$HERE/tools/_extract_runcmd.py" "$d/tools/_extract_runcmd.py"
  cp "$HERE/tools/_derive_variants.py" "$d/tools/_derive_variants.py"
  case "$kind" in
    any-token)
      # The DERIVER, not the harness: put every occurrence back in the set,
      # exactly as round 2 did.
      python3 - "$HERE/tools/_derive_variants.py" "$d/tools/_derive_variants.py" << 'PYD' || return 1
import sys
src, dest = sys.argv[1], sys.argv[2]
text = open(src).read()
old = """    variants = []
    seen = set()
    for name, path, line in hits:"""
new = """    variants = []
    seen = set()
    hits = list(occurrences)
    for name, path, line in hits:"""
if old not in text:
    sys.exit(1)
open(dest, "w").write(text.replace(old, new, 1))
PYD
      cp "$d/tools/consumer_acceptance.sh.orig" "$d/tools/consumer_acceptance.sh"
      chmod +x "$d/tools/consumer_acceptance.sh"
      return 0
      ;;
    path-edit-substring)
      # The DERIVER, not the harness: put round 5's POSITIONAL regex back,
      # so `env PATH=/abs:$PATH cmd` is invisible again. The `env` row then
      # runs and reads PASS, and the plant goes SILENT.
      python3 - "$HERE/tools/_derive_variants.py" "$d/tools/_derive_variants.py" << 'PYP' || return 1
import sys
src, dest = sys.argv[1], sys.argv[2]
text = open(src).read()
old = 'PATH_EDIT_RE = re.compile(r"(?:^|[^A-Za-z0-9_])PATH\\s*(?:\\+=|:=|\\?=|=)")'
new = ('PATH_EDIT_RE = re.compile(r"(?:^|[;&|(]|\\bexport\\s+|\\bdeclare\\s+-x\\s+'
       '|\\btypeset\\s+-x\\s+)\\s*PATH\\s*(?:\\+=|=)")')
if old not in text:
    sys.exit(1)
open(dest, "w").write(text.replace(old, new, 1))
PYP
      cp "$d/tools/consumer_acceptance.sh.orig" "$d/tools/consumer_acceptance.sh"
      chmod +x "$d/tools/consumer_acceptance.sh"
      return 0
      ;;
    folded-more-indented)
      # The extractor, not the harness: gut the more-indented rule so a
      # folded scalar's three commands fold back into one line.
      python3 - "$HERE/tools/_extract_runcmd.py" "$d/tools/_extract_runcmd.py" << 'PYX' || return 1
import sys
src, dest = sys.argv[1], sys.argv[2]
text = open(src).read()
old = """            # CA-GUARD:folded-more-indented
            flush()
            out.append(line)"""
new = """            # CA-GUARD:folded-more-indented
            buf.append(line)"""
if old not in text:
    sys.exit(1)
open(dest, "w").write(text.replace(old, new, 1))
PYX
      cp "$d/tools/consumer_acceptance.sh.orig" "$d/tools/consumer_acceptance.sh"
      chmod +x "$d/tools/consumer_acceptance.sh"
      return 0
      ;;
  esac
  if ! apply_mutation "$d/tools/consumer_acceptance.sh.orig" "$d/tools/consumer_acceptance.sh" "$kind"; then
    return 1
  fi
  chmod +x "$d/tools/consumer_acceptance.sh"
  if cmp -s "$d/tools/consumer_acceptance.sh.orig" "$d/tools/consumer_acceptance.sh"; then
    return 1
  fi
  return 0
}

# Variant (a): eigenscript-full in a called script AND as a runCmd token,
# stale binary on PATH, no --full. FIRE: both rows UNRUNNABLE|prereq:variant:eigenscript-full,
# stale log empty, each non-PASS row has a log| preflight line.
plant_variant_missing() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5" stale_bin="$6"
  local out rc
  : > "$stale_log"
  out="$(PATH="$(dirname "$stale_bin"):$PATH" CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc stale=$(wc -c < "$stale_log" 2>/dev/null || echo 0) rec=$(grep -E 'row|UNRUNNABLE|^log' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'UNRUNNABLE|prereq:variant:eigenscript-full' <<< "$out" \
     && grep -q 'row|script_user|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'row|token_user|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q '^log|script_user|preflight: prereq:variant:eigenscript-full' "$rec" \
     && grep -q '^log|token_user|preflight: prereq:variant:eigenscript-full' "$rec" \
     && [ ! -s "$stale_log" ]; then
    return 0
  fi
  return 1
}

# Variant (b): same fixture with --full stub. FIRE: PASS, cand_calls counts the full call.
plant_variant_full() {
  local sh="$1" eco="$2" stub="$3" rec="$4" full="$5"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub" --full "$full" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'row|script_user|v0.43.0|PASS|' "$rec" \
     && grep -q 'row|token_user|v0.43.0|PASS|' "$rec" \
     && grep -q 'cand_calls=1' "$rec" \
     && exact_verdict_file "$rec" PASS; then
    return 0
  fi
  return 1
}

# A consumer whose variant name lives in an unusual file. FIRE:
# UNRUNNABLE|prereq:variant:<name>, stale unreached.
plant_variant_named() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5" stale_bin="$6" cname="$7" vname="$8"
  local out rc
  : > "$stale_log"
  out="$(PATH="$(dirname "$stale_bin"):$PATH" CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc name=$vname stale=$(wc -c < "$stale_log" 2>/dev/null || echo 0) rec=$(grep -E 'row|UNRUNNABLE|^log' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q "UNRUNNABLE|prereq:variant:${vname}" <<< "$out" \
     && grep -q "row|${cname}|v0.43.0|UNRUNNABLE|" "$rec" \
     && grep -q "^log|${cname}|preflight: prereq:variant:${vname}" "$rec" \
     && [ ! -s "$stale_log" ]; then
    return 0
  fi
  return 1
}

# B3: 2 consumers, committed-record floor of 3. FIRE: FAIL naming the floor,
# in plan AND in the run record. Discriminates lexical newest (floor 3)
# from mtime (the older-named record is touched newer and has 99 rows).
plant_b3_record_floor() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="plan rc=$rc $(grep -E 'inventory_floor|VERDICT' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "" "$rc"
  if [ "$rc" -eq 0 ] || ! grep -q 'inventory 2 < record floor 3' <<< "$out"; then
    return 1
  fi
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)" || true
  LAST_PLANT_DETAIL="$LAST_PLANT_DETAIL run=$(grep -E 'inventory floor|VERDICT' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" 0
  if grep -q '^inventory floor: inventory 2 < record floor 3' "$rec" \
     && grep -q '^inventory floor: inventory 2 < record floor 3' <<< "$out" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# FAIL row carries log|<name>|<line> immediately after the row.
plant_log_tail() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E '^row|^log' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|log_fail|v0.43.0|FAIL|' "$rec" \
     && grep -q '^log|log_fail|' "$rec"; then
    return 0
  fi
  return 1
}

# B2: declared consumer absent from disk. FIRE: FAIL naming it, in plan
# AND in the run record (the same named line).
plant_b2_missing_declared() {
  local sh="$1" eco="$2" stub="${3:-/bin/true}"
  local out rc rec
  out="$(CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="plan rc=$rc"
  note_plant "$out" "" "$rc"
  if [ "$rc" -eq 0 ] \
     || ! grep -q 'declared consumer absent: missing_one' <<< "$out" \
     || ! grep -q '^VERDICT: FAIL' <<< "$out"; then
    return 1
  fi
  rec="${eco}.b2.run.record"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)" || true
  LAST_PLANT_DETAIL="$LAST_PLANT_DETAIL run=$(grep -E 'inventory floor|VERDICT|row' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" 0
  if grep -q '^inventory floor: declared consumer absent: missing_one' "$rec" \
     && grep -q '^inventory floor: declared consumer absent: missing_one' <<< "$out" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Globbing off: declared token tests/*.eigs is literal (plan), AND a runCmd
# with *.eigs in the variant scan does not expand to a variant name (run).
plant_noglob() {
  local sh="$1" eco="$2" cwd="$3" stub="$4"
  local out rc rec
  out="$(cd "$cwd" && CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="plan rc=$rc out=$(grep -E 'GAP|VERDICT:|does not exist' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "" "$rc"
  if [ "$rc" -eq 0 ] \
     || ! grep -Fq 'tests/*.eigs' <<< "$out" \
     || ! grep -q '^VERDICT: FAIL' <<< "$out"; then
    return 1
  fi
  rec="${cwd}/ng-run.record"
  printf 'x\n' > "$cwd/eigenscript-full.eigs"
  out="$(cd "$cwd" && CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub" 2>&1)" || true
  LAST_PLANT_DETAIL="$LAST_PLANT_DETAIL run=$(grep -E 'row|UNRUNNABLE|VERDICT' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" 0
  # Positive witness first: the glob_run row exists (the run really ran).
  # Then the negative: the variant loop did not expand *.eigs into a name.
  grep -q '^row|glob_run|' "$rec" 2>/dev/null || return 1
  grep -q '^VERDICT:' "$rec" 2>/dev/null || return 1
  if grep -q 'prereq:variant:eigenscript-full.eigs' "$rec" 2>/dev/null \
     || grep -q 'prereq:variant:eigenscript-full.eigs' <<< "$out"; then
    return 1
  fi
  return 0
}

# J2: signal between footer-write and rename. FIRE: INCOMPLETE, exit 2, file=stdout.
plant_j2_pause_rename() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local pid waited rc n_out outf
  outf="${rec}.stdout"
  rm -f "$outf" "$rec"
  CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=pause_before_rename CA_RECORD="$rec" \
    "$sh" run "$stub" >"$outf" 2>&1 &
  pid=$!
  waited=0
  while [ "$waited" -lt 40 ]; do
    if ls "$(dirname "$rec")"/.$(basename "$rec").rewrite.* >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  sleep 0.2
  kill -TERM "$pid" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 8 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid"
  rc=$?
  n_out="$(grep -c '^VERDICT: INCOMPLETE$' "$outf" 2>/dev/null || true)"
  LAST_PLANT_DETAIL="rc=$rc n_out=$n_out rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$(cat "$outf" 2>/dev/null || true)" "$rec" "$rc"
  local leftover
  leftover="$(ls "$(dirname "$rec")"/.$(basename "$rec").rewrite.* 2>/dev/null || true)"
  LAST_PLANT_DETAIL="rc=$rc n_out=$n_out leftover=$( [ -n "$leftover" ] && echo yes || echo no ) rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  if [ "$rc" -eq 2 ] \
     && [ "$n_out" = 1 ] \
     && grep -q '^VERDICT: INCOMPLETE$' "$rec" \
     && grep -q 'status=INCOMPLETE' "$rec" \
     && [ -z "$leftover" ]; then
    return 0
  fi
  return 1
}

# Usage error does not touch the committed record.
plant_usage_no_candidate() {
  local sh="$1" eco="$2" rec="$3"
  local out rc sha1 sha2
  printf '%s\n' '# committed' 'run_id=OLD' 'status=COMPLETE' 'inventory=1 examined=1' 'VERDICT: PASS' > "$rec"
  sha1="$(file_sha256 "$rec")"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_RECORD="$rec" "$sh" run 2>&1)"
  rc=$?
  sha2="$(file_sha256 "$rec")"
  LAST_PLANT_DETAIL="rc=$rc sha1=$sha1 sha2=$sha2 prev=$( [ -e "${rec}.prev" ] && echo yes || echo no )"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 2 ] \
     && [ "$sha1" = "$sha2" ] \
     && [ ! -e "${rec}.prev" ]; then
    return 0
  fi
  return 1
}

# Temp path's directory equals the record's directory.
plant_show_tmp() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc recdir
  recdir="$(cd "$(dirname "$rec")" && pwd)"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=show_tmp CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc out=$(grep 'record_tmp_dir=' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if grep -q "^record_tmp_dir=$recdir$" <<< "$out"; then
    return 0
  fi
  return 1
}

# Prefer tests.yml over bench.yml.
plant_workflow_prefer() {
  local sh="$1" eco="$2"
  local out rc
  out="$(CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc wf=$(grep '^  workflow|' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "" "$rc"
  if grep -q 'workflow|pref_user|tests.yml' <<< "$out" \
     && ! grep -q 'workflow|pref_user|bench.yml' <<< "$out"; then
    return 0
  fi
  return 1
}

# a.yml + b.yml, no preferred name → UNRUNNABLE by name.
plant_workflow_ambiguous() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc out=$(grep -E 'UNRUNNABLE|ambiguous' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'UNRUNNABLE|ambiguous-workflow:' <<< "$out" \
     && grep -q 'a.yml' <<< "$out" \
     && grep -q 'b.yml' <<< "$out"; then
    return 0
  fi
  return 1
}

# Partial overlay retry does not nest src/data/data/x.
plant_overlay_partial() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=overlay_partial CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'row|ovp_user|v0.43.0|PASS|' "$rec" \
     && exact_verdict_file "$rec" PASS; then
    return 0
  fi
  return 1
}

# --- round-3 plants ---------------------------------------------------

# Fix 1 (#1213): the six REAL shapes that round 2 turned into declared
# prerequisites. FIRE: the row PASSes and the derived set is eigenscript
# alone. Gutting the call-site rule (mutation any-token) makes every one of
# them a prerequisite again and the row goes UNRUNNABLE.
plant_variant_prose() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc plan_out
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  plan_out="$(CA_ECO="$eco" "$sh" plan 2>&1)" || true
  LAST_PLANT_DETAIL="rc=$rc rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ') variants=$(grep 'variants|prose_user|' <<< "$plan_out" | head -1)"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'row|prose_user|v0.43.0|PASS|' "$rec" \
     && ! grep -q 'prereq:variant:' "$rec" \
     && grep -qx '  variants|prose_user|eigenscript' <<< "$plan_out"; then
    return 0
  fi
  return 1
}

# Fix 1 shape (c): an .eigs exec-family call IS an invocation position.
plant_variant_eigs_call() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5" stale_dir="$6"
  local out rc
  : > "$stale_log"
  out="$(PATH="$stale_dir:$PATH" CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ') stale=$(wc -c < "$stale_log")"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|eigs_user|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'prereq:variant:eigenscript-eigs' <<< "$out" \
     && [ ! -s "$stale_log" ]; then
    return 0
  fi
  return 1
}

# Fix 1b: a RUNTIME-COMPUTED name (eigenscript-$V). The derivation cannot
# see it, so the PATH sweep must make it unreachable BY NAME and the row
# must be FAIL|undeclared-variant:<name> -- not PASS, not UNEXERCISED.
# The consumer swallows the 127 with `|| true`, so the ONLY thing that can
# fail this row is the call-log assertion: gutting either guard yields
# VERDICT: PASS.
plant_variant_computed() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5" stale_dir="$6"
  local out rc
  : > "$stale_log"
  out="$(PATH="$stale_dir:$PATH" CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ') stale=$(wc -c < "$stale_log")"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|computed_user|v0.43.0|FAIL|undeclared-variant:eigenscript-jit|' "$rec" \
     && [ ! -s "$stale_log" ] \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Fix 1b, the RESIDUAL, pinned: a path the consumer COMPUTES inside its own
# checkout (./eigenscript-* glob over a symlink) is not on PATH and is not
# masked. FIRE: the stale binary IS reached and the row is UNEXERCISED --
# never PASS. If someone closes this residual, this plant goes red and the
# header sentence must be updated in the same commit.
plant_variant_glob_residual() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5"
  local out rc
  : > "$stale_log"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ') stale=$(wc -c < "$stale_log")"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|glob_user|v0.43.0|UNEXERCISED|' "$rec" \
     && [ -s "$stale_log" ] \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# --- round 4 plants -------------------------------------------------------

# Fix 1 (class closure): the row's PATH is EXACTLY $SHIM:$FARM, so no
# inherited directory -- not `.`, not an empty entry, not $HOME/.local/bin --
# is on it. The discriminating row is Fable r3's dot-PATH shape: the harness
# inherits `.` on PATH, the consumer's OWN checkout holds a stale
# eigenscript-jit, and with the inherited PATH in the row (round 3) `.`
# resolves inside the consumer's repo and the stale binary RUNS under PASS.
# The control row proves the farm still hands out the real toolchain.
plant_path_farm() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5" cwd="$6"
  local out rc
  : > "$stale_log"
  out="$(cd "$cwd" && PATH=".:$PATH" CA_ECO="$eco" CA_TIMEOUT=10 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')stale=$(wc -c < "$stale_log" 2>/dev/null || echo 0) $(grep -E '^(path_farm|home_scratch)' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  local farm_n
  farm_n="$(grep -m1 '^path_farm: ' <<< "$out" || true)"
  farm_n="${farm_n#path_farm: }"
  farm_n="${farm_n%% *}"
  farm_n="${farm_n:-0}"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|farm_dot|v0.43.0|FAIL|undeclared-variant:eigenscript-jit|' "$rec" \
     && grep -q 'row|farm_control|v0.43.0|PASS|' "$rec" \
     && [ ! -s "$stale_log" ] \
     && [ "$farm_n" -gt 0 ] \
     && grep -q '^home_scratch: yes' <<< "$out" \
     && grep -q '^path_farm=' "$rec"; then
    return 0
  fi
  return 1
}

# Fix 1 (second half): HOME is a scratch directory per row, so the ordinary
# CI idiom `export PATH="$HOME/.local/bin:$PATH"` prepends an EMPTY
# directory. With the developer's real HOME (round 3) that one line put a
# stale runtime back in front of $SHIM and the row read PASS.
plant_home_scratch() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5" fake_home="$6"
  local out rc
  : > "$stale_log"
  out="$(HOME="$fake_home" PATH="$fake_home/.local/bin:$PATH" CA_ECO="$eco" CA_TIMEOUT=10 \
    CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')stale=$(wc -c < "$stale_log" 2>/dev/null || echo 0)"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|home_prepend|v0.43.0|FAIL|undeclared-variant:eigenscript-jit|' "$rec" \
     && grep -q 'row|home_empty|v0.43.0|PASS|' "$rec" \
     && [ ! -s "$stale_log" ] \
     && grep -q '^home_scratch=yes' "$rec"; then
    return 0
  fi
  return 1
}

# A computed name that NO candidate covers and that is nowhere on the row's
# PATH is not found at all -- a bare 127 the consumer swallows with
# `|| true`. command_not_found_handle turns it into the same blocked|
# record a 127-shim writes, so the row FAILs BY NAME.
# Round 5 fix 3 (Fable r4 check 5): the fixture used the name
# `eigenscript-jit`, which is ENVIRONMENT-DEPENDENT -- on a box with a
# stale eigenscript-jit anywhere on the inherited PATH the 127-shim sweep
# answers first, the handler is never reached, and the INTACT transverse
# read `mutant=FIRES`: a RED self-test blaming a guard that is whole. The
# name now carries the run token, so it exists NOWHERE by construction, and
# the plant asserts that before planting. A decoy `eigenscript-jit` is
# prepended to the harness's own PATH so the plant PROVES it no longer
# depends on that name.
plant_not_found_variant() {
  local sh="$1" eco="$2" stub="$3" rec="$4" nfname="$5" decoy="$6" decoy_log="$7"
  local out rc
  if command -v "$nfname" >/dev/null 2>&1; then
    LAST_PLANT_DETAIL="the token-carrying fixture name $nfname EXISTS on PATH ($(command -v "$nfname")) -- the plant cannot mean what it says"
    return 1
  fi
  : > "$decoy_log"
  out="$(PATH="$decoy:$PATH" CA_ECO="$eco" CA_TIMEOUT=10 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc nfname=$nfname decoy_ran=$(wc -c < "$decoy_log" 2>/dev/null || echo 0) rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q "row|nf_user|v0.43.0|FAIL|undeclared-variant:$nfname|" "$rec" \
     && [ ! -s "$decoy_log" ] \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Fix 2 (Fable r3, critical): an unusable $TMPDIR used to give WORK="" and
# SHIM="/bin" under `set -uo pipefail`, and a round-2 run as root wrote stub
# shims into /usr/bin on this box. Exit 2 BY NAME before any shim is
# written, the previous record's bytes untouched, and nothing created in any
# system bin directory.
plant_scratch_fail_closed() {
  local sh="$1" eco="$2" stub="$3" rec="$4" bad="$5"
  local out rc mark before after created
  printf 'previous record bytes\nVERDICT: PASS\n' > "$rec"
  before="$(file_sha256 "$rec")"
  mark="$(mktemp "${TMPDIR:-/tmp}/ca-mark.$(scratch_tag)XXXXXX")"
  sleep 0.05
  out="$(TMPDIR="$bad/does-not-exist" CA_ECO="$eco" CA_TIMEOUT=10 CA_KILL_AFTER=1 \
    CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  after="$(file_sha256 "$rec")"
  created="$(find /usr/bin /bin /usr/local/bin "$HOME/.local/bin" -maxdepth 1 \
    -name 'eigenscript*' -newer "$mark" 2>/dev/null || true)"
  rm -f "$mark"
  LAST_PLANT_DETAIL="rc=$rc record_unchanged=$( [ "$before" = "$after" ] && echo yes || echo no ) created=$(printf '%s' "$created" | tr '\n' ' ') out=$(grep -m1 'cannot create scratch' <<< "$out" || true)"
  note_plant "$out" "" "$rc"
  if [ "$rc" -eq 2 ] \
     && grep -q '^consumer_acceptance: cannot create scratch under ' <<< "$out" \
     && [ "$before" = "$after" ] \
     && [ -z "$created" ]; then
    return 0
  fi
  return 1
}

# --- round 5 -------------------------------------------------------------

# Fix 1 (Astra r4, the blocking gap): the farm holds EXEC WRAPPERS, so a
# tool runs AT ITS ORIGINAL LOCATION. A symlink farm moved a virtualenv's
# python3 into $FARM, sys.prefix became /usr, and a dependency installed in
# the selected virtualenv vanished -- the row FAILed after the candidate
# call succeeded. The fixture is a real venv with one module in it.
plant_farm_exec_wrapper() {
  local sh="$1" eco="$2" stub="$3" rec="$4" venv="$5" marker="$6"
  local out rc want_prefix
  want_prefix="$(cd -P -- "$venv" && pwd)"
  : > "$marker"
  out="$(PATH="$venv/bin:/usr/bin:/bin" CA_ECO="$eco" CA_TIMEOUT=20 CA_KILL_AFTER=1 \
    CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc marker=$(tr '\n' ' ' < "$marker" 2>/dev/null) rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'row|venv_user|v0.43.0|PASS|' "$rec" \
     && grep -q '^venv dependency loaded$' "$marker" \
     && grep -qxF "prefix=$want_prefix" "$marker"; then
    return 0
  fi
  return 1
}

# Fix 1's stated RESIDUAL, pinned (Fable r4 p2): running a tool in place is
# exactly what lets an inherited, farmed, SELF-LOCATING wrapper reach the
# stale eigenscript beside it. This plant FIRES while that is still true.
# The day an execve witness or a mount namespace closes it, the plant goes
# red ON PURPOSE and the header sentence changes with it (mechanical-gates
# 100: a pinned residual is a plant, not a sentence).
plant_farm_wrapper_sibling() {
  local sh="$1" eco="$2" stub="$3" rec="$4" wrapbin="$5" stale_log="$6"
  local out rc
  : > "$stale_log"
  out="$(PATH="$wrapbin:$PATH" CA_ECO="$eco" CA_TIMEOUT=10 CA_KILL_AFTER=1 \
    CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc stale=$(tr '\n' ' ' < "$stale_log" 2>/dev/null) rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  # FIRES == the residual still holds: the stale sibling RAN and the row is PASS.
  if grep -q 'row|wrap_user|v0.43.0|PASS|' "$rec" \
     && grep -q 'STALE-RAN' "$stale_log"; then
    return 0
  fi
  return 1
}

# Fix 6 (Astra r4 check 7): a farm directory that cannot be written used to
# swallow every failure -- path_farm=0, VERDICT: PASS, and the row ran with
# no inherited tool at all. Now exit 2 BY NAME. The fixture wraps mktemp so
# the run scratch comes back with a read-only farm/ already in it.
plant_farm_fail_closed() {
  local sh="$1" eco="$2" stub="$3" rec="$4" inject="$5"
  local out rc
  rm -f "$rec"
  out="$(PATH="$inject:$PATH" CA_ECO="$eco" CA_TIMEOUT=10 CA_KILL_AFTER=1 \
    CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc recV=$(grep -h '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')out=$(grep -m1 'cannot build the PATH farm' <<< "$out" || true)"
  note_plant "$out" "$rec" "$rc"
  # The farm is built after the record lock, so the record exists and says
  # INCOMPLETE -- truthful, and never PASS. The named refusal is the plant.
  if [ "$rc" -eq 2 ] \
     && grep -q '^consumer_acceptance: cannot build the PATH farm under ' <<< "$out" \
     && ! grep -q 'VERDICT: PASS' <<< "$out" \
     && ! grep -q '^VERDICT: PASS' "$rec" 2>/dev/null \
     && ! grep -q '^row|' "$rec" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ROUND 6 fix 3 (Fable r5, Astra r4 check 7 `readonly-bin`): the row's
# $SHIM directory exists but cannot be WRITTEN. Round 5 swallowed every
# shim write and the row read FAIL|127 cand_calls=0 -- generic, while the
# fail-closed claim promises a named exit 2. Now it is named.
plant_shim_fail_closed() {
  local sh="$1" eco="$2" stub="$3" rec="$4" inject="$5"
  local out rc
  rm -f "$rec"
  out="$(PATH="$inject:$PATH" CA_ECO="$eco" CA_TIMEOUT=10 CA_KILL_AFTER=1 \
    CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc recV=$(grep -h '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')out=$(grep -m1 'cannot write the shim' <<< "$out" || true)"
  note_plant "$out" "$rec" "$rc"
  # The shim is written after the record lock, so the record exists and
  # says INCOMPLETE -- truthful, and never PASS. The named refusal is the
  # plant, and no row runs at all.
  if [ "$rc" -eq 2 ] \
     && grep -q '^consumer_acceptance: cannot write the shim ' <<< "$out" \
     && ! grep -q 'VERDICT: PASS' <<< "$out" \
     && ! grep -q '^VERDICT: PASS' "$rec" 2>/dev/null \
     && ! grep -q '^row|' "$rec" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Fix 2 (Fable r4 check 3): a consumer PATH edit that adds an ABSOLUTE
# directory existing on this box is refused BY NAME before the row runs.
# Three rows in one fixture: an absolute scratch bin (FAIL by name), the
# developer's REAL home by absolute path (FAIL by name -- this is the row
# that reached eigenscript-full.stale 0.21.0 under PASS in round 4), and
# the ordinary `$HOME/.local/bin` prepend, which is fine (scratch HOME).
plant_path_edit_absolute() {
  local sh="$1" eco="$2" stub="$3" rec="$4" absbin="$5" stale_log="$6" realdir="$7"
  local tildedir="${8:-}"
  local out rc r _r
  # ROUND 7: the offender is now named by its RESOLVED directory, so the
  # expected names are resolved on exactly the same terms (a private
  # TMPDIR that is itself a symlink must not silently make this vacuous).
  _r="$(cd -P -- "$absbin" 2>/dev/null && pwd)"; [ -z "$_r" ] || absbin="$_r"
  _r="$(cd -P -- "$realdir" 2>/dev/null && pwd)"; [ -z "$_r" ] || realdir="$_r"
  if [ -n "$tildedir" ]; then
    _r="$(cd -P -- "$tildedir" 2>/dev/null && pwd)"; [ -z "$_r" ] || tildedir="$_r"
  fi
  : > "$stale_log"
  out="$(CA_ECO="$eco" CA_TIMEOUT=20 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc stale=$(wc -c < "$stale_log" 2>/dev/null || echo 0) rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  [ "$rc" -eq 1 ] || return 1
  grep -qF "row|pe_absbin|v0.43.0|FAIL|path-edit:$absbin|" "$rec" || return 1
  grep -qF "row|pe_realhome|v0.43.0|FAIL|path-edit:$realdir|" "$rec" || return 1
  grep -q 'row|pe_home|v0.43.0|PASS|' "$rec" || return 1
  grep -qF "log|pe_absbin|preflight: path-edit $absbin added to PATH at " "$rec" || return 1
  # ROUND 6: one row per shape Fable r5 walked through. Every one of these
  # read PASS at ba74be3 while the stale eigenscript in $absbin RAN.
  for r in pe_env pe_execenv pe_bashc pe_heredoc pe_make; do
    grep -qF "row|$r|v0.43.0|FAIL|path-edit:$absbin|" "$rec" || return 1
  done
  if [ -n "$tildedir" ]; then
    grep -qF "row|pe_tilde|v0.43.0|FAIL|path-edit:$tildedir|" "$rec" || return 1
  fi
  # ROUND 7 (Astra r6 check 2): written under the checkout, resolved
  # outside it -- through `..` and through a symlink in the checkout.
  # Refused BY THE RESOLVED NAME, which is the directory the row reaches.
  for r in pe_dotdot pe_symlink; do
    grep -qF "row|$r|v0.43.0|FAIL|path-edit:$absbin|" "$rec" || return 1
  done
  grep -qF "log|pe_dotdot|preflight: path-edit $absbin added to PATH at " "$rec" || return 1
  # ...and the controls: a directory that really is inside the checkout is
  # still allowed, in both spellings.
  grep -q 'row|pe_relbin|v0.43.0|PASS|' "$rec" || return 1
  grep -q 'row|pe_inrepo|v0.43.0|PASS|' "$rec" || return 1
  [ ! -s "$stale_log" ] || return 1
  return 0
}

# Fix 2's stated RESIDUAL, pinned: a component the scanner cannot see
# because the consumer COMPUTES it at run time still reaches. FIRES while
# that holds.
plant_path_edit_computed() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5"
  local out rc
  : > "$stale_log"
  out="$(CA_ECO="$eco" CA_TIMEOUT=10 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc stale=$(tr '\n' ' ' < "$stale_log" 2>/dev/null) rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if grep -q 'row|pe_computed|v0.43.0|' "$rec" \
     && ! grep -q 'row|pe_computed|v0.43.0|FAIL|path-edit' "$rec" \
     && grep -q 'STALE-RAN' "$stale_log"; then
    return 0
  fi
  return 1
}

# Fix 4 (Fable r4 check 4b): the scratch HOME must not drop the TOOL CACHES
# a consumer's dependency set lives in. A farmed `go` in the row must name
# the REAL module cache, not one under the row's scratch HOME.
plant_env_passthrough_go() {
  local sh="$1" eco="$2" stub="$3" rec="$4" marker="$5" gobin="$6"
  local out rc got want
  want="${GOMODCACHE:-$REAL_HOME/go/pkg/mod}"
  : > "$marker"
  out="$(PATH="$gobin:$PATH" CA_ECO="$eco" CA_TIMEOUT=30 CA_KILL_AFTER=1 \
    CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  got="$(head -1 "$marker" 2>/dev/null || true)"
  LAST_PLANT_DETAIL="rc=$rc go_env_GOMODCACHE=$got want=$want rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'row|go_user|v0.43.0|PASS|' "$rec" \
     && [ "$got" = "$want" ] \
     && grep -q '^env_passthrough=.*GOMODCACHE' "$rec"; then
    return 0
  fi
  return 1
}

# Fix 5 (Fable r4 check 6, Astra r4 check 6): CA_DROP_CMD is a fixture-gated
# self-test lever, never the trust root. Without $CA_ECO/.ca_fixture it is
# IGNORED and the harness names the tool it chose itself.
plant_drop_trust_root() {
  local sh="$1" fixture_eco="$2"
  local ungated gated own
  own="$("$sh" --drop-tool 2>/dev/null || true)"
  ungated="$(CA_DROP_CMD=/bin/echo-not-a-trust-root "$sh" --drop-tool 2>/dev/null || true)"
  gated="$(CA_ECO="$fixture_eco" CA_DROP_CMD=/bin/echo-not-a-trust-root "$sh" --drop-tool 2>/dev/null || true)"
  LAST_PLANT_DETAIL="own=$own ungated=$ungated gated=$gated"
  if [ "$ungated" = "$own" ] \
     && [ "$ungated" != "drop=/bin/echo-not-a-trust-root" ] \
     && [ "$gated" = "drop=/bin/echo-not-a-trust-root" ]; then
    return 0
  fi
  return 1
}

# Fix 3 (Fable r3 twin site): EIGS_DIR is a cp -rL COPY of the candidate
# tree, so "$EIGS_DIR/src/eigenscript-full" used to run the copied sibling
# binary under a PASS row. Every eigenscript* the overlay hands out is now
# a shim. stub is the tree-shaped candidate (.../src/eigenscript).
plant_overlay_variant() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5"
  local out rc
  : > "$stale_log"
  out="$(CA_ECO="$eco" CA_TIMEOUT=10 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')stale=$(wc -c < "$stale_log" 2>/dev/null || echo 0)"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|twin_user|v0.43.0|FAIL|undeclared-variant:eigenscript-full|' "$rec" \
     && [ ! -s "$stale_log" ] \
     && grep -q '^overlay_shimmed=.*eigenscript-full' "$rec"; then
    return 0
  fi
  return 1
}

# Fix 4: the dropped self-test prints its OWN script's sha256; the outer
# compares. Three arms, so neither a rewritten copy nor a copy that never
# announced itself can read as OK.
plant_drop_sha() {
  local sh="$1" d="$2"
  local ok mis none
  mkdir -p "$d"
  printf 'dropped_script_sha256=AAA path=/x\nSELF-TEST: PASS\n' > "$d/honest.out"
  printf 'dropped_script_sha256=BBB path=/x\nSELF-TEST: PASS\n' > "$d/rewritten.out"
  printf 'self-test: MUTATED COPY RAN\nSELF-TEST: PASS plants=0\n' > "$d/absent.out"
  ok="$("$sh" --drop-sha AAA "$d/honest.out" 2>/dev/null || true)"
  mis="$("$sh" --drop-sha AAA "$d/rewritten.out" 2>/dev/null || true)"
  none="$("$sh" --drop-sha AAA "$d/absent.out" 2>/dev/null || true)"
  LAST_PLANT_DETAIL="honest=$ok rewritten=$mis absent=$none"
  note_plant "$ok $mis $none" "" 0
  [ "$ok" = OK ] && [ "$mis" = "MISMATCH:BBB" ] && [ "$none" = MISSING ]
}

# Fix 5 (both critics r3): the outer-tmp hygiene scan read a CONCURRENT
# self-test's /tmp/ca-st.* as this run's leftover and printed a false
# SELF-TEST: FAIL. The scan asks only about entries tagged with THIS run's
# token. Control arm: with no token the same scan DOES name both decoys, so
# the tagged arm is not passing because it looked at nothing.
plant_outer_tmp_decoy() {
  local sh="$1" dir="$2" keep="$3" token="$4"
  local d1="$dir/ca-st.OTHER-DECOY.$$" d2="$dir/ca-run.OTHER-DECOY.$$"
  local tagged untagged tag_ex tag_str un_str
  mkdir -p "$d1" "$d2"
  tagged="$("$sh" --outer-tmp-strays "$dir" "$token" "$keep" 2>/dev/null || true)"
  untagged="$("$sh" --outer-tmp-strays "$dir" "" "$keep" 2>/dev/null || true)"
  tag_ex="${tagged#examined=}"
  tag_ex="${tag_ex%% *}"
  tag_str="${tagged#*strays=}"
  un_str="${untagged#*strays=}"
  LAST_PLANT_DETAIL="tagged=[$tagged] untagged_control=[$un_str]"
  note_plant "$tagged $untagged" "" 0
  local ok=0
  if [ -d "$d1" ] && [ -d "$d2" ] \
     && [ "${tag_ex:-0}" -gt 0 ] \
     && [ "$tag_str" = none ] \
     && [ "${un_str#*ca-st.OTHER-DECOY}" != "$un_str" ] \
     && [ "${un_str#*ca-run.OTHER-DECOY}" != "$un_str" ]; then
    ok=0
  else
    ok=1
  fi
  rm -rf "$d1" "$d2"
  return "$ok"
}

# Fix 5 / Astra r2 05: a folded scalar whose more-indented line is a
# command. Under YAML these are THREE commands and the block exits 1;
# folded into one line the `false` stops being a command and the row read
# PASS. FIRE: the derived command has three lines and the row is FAIL.
plant_folded_commands() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc plan_out derived lines
  local ex_root
  ex_root="$(cd "$(dirname "$(dirname "$sh")")" && pwd)"
  derived="$(python3 "$ex_root/tools/_extract_runcmd.py" "$eco/fold_user/.github/workflows/ci.yml" 2>/dev/null || true)"
  lines="$(printf '%s' "$derived" | wc -l)"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc derived_lines=$((lines + 1)) rows=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && [ "$lines" -eq 2 ] \
     && grep -q 'row|fold_user|v0.43.0|FAIL|1|' "$rec" \
     && ! grep -q 'accepted' "$rec"; then
    return 0
  fi
  return 1
}

# Fix 6 / Fable r2 03: only a DATED record raises or lowers the floor. A
# stray file is a FAIL by name. $5 is the stray basename, $6 its row count.
plant_record_stray() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stray="$5" rows="$6"
  local out rc i
  mkdir -p "$eco/reports/consumer_acceptance"
  rm -f "$eco/reports/consumer_acceptance/$stray"
  i=1
  while [ "$i" -le "$rows" ]; do
    printf 'row|s%02d|v|PASS|0|0\n' "$i"
    i=$((i + 1))
  done > "$eco/reports/consumer_acceptance/$stray"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  rm -f "$eco/reports/consumer_acceptance/$stray"
  LAST_PLANT_DETAIL="rc=$rc stray=$stray floor=$(grep -o 'inventory floor: [^|]*' "$rec" 2>/dev/null | head -1)"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q "stray record file: $stray" "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Fix 7 / Astra r2 01: a plant that discards BOTH streams must not be able
# to hide an unbound variable. Mutate the rc-124 path of the script it was
# handed, run it with >/dev/null 2>&1, and require the message in the
# capture file. Gutting the capture (mutation stderr-capture) silences it.
plant_unbound_capture() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local md mutant cap n_intact n_mutant
  md="$ST_ROOT/mutants/timeout-unbound.$$"
  rm -rf "$md"
  if ! prep_mutant "$md" timeout-unbound "$sh"; then
    LAST_PLANT_DETAIL="timeout-unbound mutation did not land"
    note_plant "" "" 1
    return 1
  fi
  mutant="$md/tools/consumer_acceptance.sh"
  cap="$ST_ROOT/unbound-probe.cap"
  : > "$cap"
  CA_ECO="$eco" CA_TIMEOUT=1 CA_KILL_AFTER=1 CA_RECORD="$rec" CA_STDERR_CAP="$cap" \
    "$sh" run "$stub" >/dev/null 2>&1
  n_intact="$(grep -c 'unbound variable' "$cap" 2>/dev/null || true)"
  n_intact="${n_intact:-0}"
  : > "$cap"
  CA_ECO="$eco" CA_TIMEOUT=1 CA_KILL_AFTER=1 CA_RECORD="$rec" CA_STDERR_CAP="$cap" \
    "$mutant" run "$stub" >/dev/null 2>&1
  n_mutant="$(grep -c 'unbound variable' "$cap" 2>/dev/null || true)"
  n_mutant="${n_mutant:-0}"
  LAST_PLANT_DETAIL="intact_unbound=$n_intact mutant_unbound=$n_mutant (both runs discarded stderr)"
  note_plant "" "" 0
  rm -rf "$md"
  if [ "$n_intact" -eq 0 ] && [ "$n_mutant" -gt 0 ]; then
    return 0
  fi
  return 1
}

# Fix 4 / Fable r2: plants + skipped is pinned to a declared constant, so a
# gutted SKIP counter (plants=N-2 skipped=0) and a deleted plant
# (plants=N-1 skipped=0) are both red. Gutting the comparison makes every
# input read OK.
plant_plant_total() {
  local sh="$1"
  local ok removed gutted
  ok="$("$sh" --plant-total "$ST_DECLARED_PLANTS" 0 2>/dev/null || true)"
  removed="$("$sh" --plant-total "$((ST_DECLARED_PLANTS - 1))" 0 2>/dev/null || true)"
  gutted="$("$sh" --plant-total "$((ST_DECLARED_PLANTS - 2))" 0 2>/dev/null || true)"
  LAST_PLANT_DETAIL="honest=$ok removed-plant=$removed gutted-skip=$gutted declared=$ST_DECLARED_PLANTS"
  note_plant "$ok $removed $gutted" "" 0
  if [ "$ok" = OK ] && [ "$removed" = MISMATCH ] && [ "$gutted" = MISMATCH ]; then
    return 0
  fi
  return 1
}

# Declared plant total. plants + skipped must equal it, or the self-test
# FAILs by name: gutting both ST_SKIP increments left `plants=67 skipped=0
# SELF-TEST: PASS` (Fable r2), and a deleted plant is the same shape. Bump
# this in the same commit as any plant change.
ST_DECLARED_PLANTS=94
# This run's scratch token: every ca-* name the self-test and its children
# create in the OUTER tmp carries it, so the hygiene scan can tell THIS
# run's leftovers from a concurrent tenant's (both critics, r3).
ST_TOKEN=""

plant_total_verdict() {
  local plants="${1:-0}" skipped="${2:-0}"
  # CA-GUARD:plant-total
  if [ "$((plants + skipped))" -eq "$ST_DECLARED_PLANTS" ]; then
    printf 'OK'
  else
    printf 'MISMATCH'
  fi
}

# Drop to an unprivileged user for the WHOLE self-test. Two plants depend
# on "cannot write" (F unwritable-record, I stale-unwritable) and as uid 0
# neither is plantable: root writes through a 0555 directory, so the record
# said PASS and the plants were SILENT in CI. Per-plant drops were the
# wrong layer -- as root EVERY plant runs in a world it cannot be refused
# in. Returns 0 having re-run itself as nobody (the caller exits with that
# status), or 1 when no drop is possible and the caller must SKIP the two
# plants by name.
# CA-GUARD:drop-trust-root
# THE TRUST ROOT of the dropped self-test is the drop TOOL THIS SCRIPT
# CHOOSES -- runuser, then setpriv -- never a command handed in from the
# environment. CA_DROP_CMD exists only so the fixture-gated self-test can
# drive the drop path on a non-root box, and it is honoured ONLY when
# $CA_ECO/.ca_fixture exists. Fable r4 check 6 and Astra r4 check 6 both
# built a CA_DROP_CMD wrapper that produced the expected first line and ran
# a SUBSTITUTE verdict producer; a read-back of a LINE can never
# authenticate a PROCESS, so the claim is narrowed to what is true: the
# sha read-back catches a copy that was rewritten or never announced
# itself, and the drop tool is what makes the process trustworthy.
# Prints the chosen drop tool; empty when none applies.
ca_drop_override() {
  [ -n "${CA_DROP_CMD:-}" ] || return 1
  # CA-GUARD:drop-fixture-gate
  if [ -z "${CA_ECO:-}" ] || [ ! -f "$CA_ECO/.ca_fixture" ]; then return 1; fi
  printf '%s' "$CA_DROP_CMD"
  return 0
}
drop_tool() {
  local d
  if d="$(ca_drop_override)"; then
    printf '%s' "$d"
    return 0
  fi
  if getent passwd nobody >/dev/null 2>&1; then
    if command -v runuser >/dev/null 2>&1; then
      printf '%s' "runuser -u nobody --"
      return 0
    elif command -v setpriv >/dev/null 2>&1; then
      printf '%s' "setpriv --reuid=nobody --regid=nogroup --clear-groups"
      return 0
    fi
  fi
  printf '%s' none
  return 0
}
# CA-GUARD:end-drop-trust-root

selftest_drop_privileges() {
  local sh="$1" drop="" root="" rc=0 run_sh="" sha_src="" sha_copy=""
  if drop="$(ca_drop_override)"; then
    :
  elif getent passwd nobody >/dev/null 2>&1; then
    if command -v runuser >/dev/null 2>&1; then
      drop="runuser -u nobody --"
    elif command -v setpriv >/dev/null 2>&1; then
      drop="setpriv --reuid=nobody --regid=nogroup --clear-groups"
    fi
  fi
  if [ -z "$drop" ]; then
    ST_DROP_WHY="no runuser/setpriv with a nobody user"
    return 1
  fi
  root="$(mktemp -d "${TMPDIR:-/tmp}/ca-stdrop.$(scratch_tag)XXXXXX")" || {
    ST_DROP_WHY="cannot create a drop root under ${TMPDIR:-/tmp}"
    return 1
  }
  # The dropped user must reach the script, the deriver, the extractor and
  # a writable TMPDIR. A repo under a 0750 home is unreachable to nobody,
  # so the self-test runs a BYTE-IDENTICAL COPY of its own tool tree inside
  # the drop root -- one path on every box, and cmp pins that the copy is
  # the file in the tree. reports/ comes along because plan_eco is not a
  # fixture and reads the committed record floor from $HERE.
  mkdir -p "$root/tmp" "$root/repo/tools" "$root/repo/reports"
  cp "$HERE/tools/consumer_acceptance.sh" "$HERE/tools/_extract_runcmd.py" \
     "$HERE/tools/_derive_variants.py" "$root/repo/tools/" || {
    rm -rf "$root"
    ST_DROP_WHY="cannot copy the tool tree into the drop root"
    return 1
  }
  cp -r "$HERE/reports/consumer_acceptance" "$root/repo/reports/" 2>/dev/null || true
  run_sh="$root/repo/tools/consumer_acceptance.sh"
  chmod -R a+rX "$root/repo"
  chmod 755 "$root"
  chmod 1777 "$root/tmp"
  if [ "$(id -u)" = 0 ]; then
    chown -R nobody "$root" 2>/dev/null || true
  fi
  # CA-GUARD:drop-copy-identical
  if ! cmp -s "$sh" "$run_sh"; then
    rm -rf "$root"
    ST_DROP_WHY="the copied script differs from $sh"
    return 1
  fi
  sha_src="$(file_sha256 "$sh")"
  sha_copy="$(file_sha256 "$run_sh")"
  if [ -z "$sha_src" ] || [ "$sha_src" != "$sha_copy" ]; then
    rm -rf "$root"
    ST_DROP_WHY="sha256 of the copied script does not match ($sha_src vs $sha_copy)"
    return 1
  fi
  if ! $drop sh -c 'test -r "$1" && test -x "$1" && test -r "$2" && test -r "$3" && test -d "$4" && : > "$4/probe"' \
       _ "$run_sh" "$root/repo/tools/_derive_variants.py" "$root/repo/tools/_extract_runcmd.py" "$root/tmp" >/dev/null 2>&1; then
    rm -rf "$root"
    ST_DROP_WHY="unprivileged probe failed (cannot read the copied tree as the dropped user)"
    return 1
  fi
  # CA-GUARD:drop-freeze-tree
  # The DIRECTORIES of the copied tree go read-only, so the checked script
  # cannot be swapped for a different inode between the check and the run.
  # An in-place rewrite of the file itself is deliberately still possible:
  # that is what the sha read-back below has to catch, and a drop tool
  # running as root could do it whatever the mode says.
  find "$root/repo" -type d -exec chmod a-w {} + 2>/dev/null || true
  # CA-GUARD:end-drop-freeze-tree
  say "self-test: trust root = the drop tool this script chooses (runuser, then setpriv); CA_DROP_CMD is a fixture-gated self-test lever, never a trust root, and a read-back of a LINE cannot authenticate a PROCESS"
  say "self-test: uid $(id -u) -- re-running the WHOLE self-test unprivileged via: $drop"
  say "self-test: drop root $root, script sha256=$sha_copy (byte-identical to $sh)"
  local inner_out="$root/inner.out"
  : > "$inner_out"
  $drop env -u CA_FAULT -u CA_DROP_CMD -u CA_STDERR_CAP \
    CA_ST_DROPPED=1 TMPDIR="$root/tmp" HOME="$root" \
    bash "$run_sh" --self-test > "$inner_out" 2>&1
  rc=$?
  cat "$inner_out"
  # CA-GUARD:drop-sha-check
  # What the outer checked and what actually RAN are now tied together:
  # the dropped process printed its own script's sha256 as its first line.
  local sha_verdict
  sha_verdict="$(drop_sha_verdict "$sha_copy" "$inner_out")"
  if [ "$sha_verdict" != OK ]; then
    say "self-test: the dropped copy did NOT run the script that was checked ($sha_verdict, want $sha_copy)"
    say "SELF-TEST: FAIL -- dropped copy identity unverified plants=0 skipped=0 transverse_skipped=0"
    rc=1
  fi
  # CA-GUARD:end-drop-sha-check
  find "$root/repo" -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$root"
  ST_DROP_EXIT="$rc"
  return 0
}

selftest() {
  local st_root rec out rc pid outer_tmp
  # REAL_HOME / ENV_PASS_* are wanted by the round-5 fixtures as well.
  build_env_passthrough
  ST_FAIL=0
  ST_SKIP=0
  ST_TV_SKIP=0
  ST_RUNS=0
  ST_UNBOUND=0
  ST_UNBOUND_WITNESS=""
  ST_UNBOUND_MUTANT=0
  ST_UNBOUND_MUTANT_WITNESS=""
  ST_IN_MUTANT=0
  ST_PLANTS=0
  ST_DROP_WHY=""
  ST_DROP_EXIT=0
  ST_AS_ROOT=0
  local self_sh
  self_sh="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  # CA-GUARD:drop-sha-announce
  # First line out of a DROPPED self-test: the sha256 of the script that is
  # actually executing. The outer compares it with the copy it checked.
  if [ -n "${CA_ST_DROPPED:-}" ]; then
    say "dropped_script_sha256=$(file_sha256 "$self_sh") path=$self_sh"
  fi
  # CA-GUARD:end-drop-sha-announce
  # CA-GUARD:root-drop
  # A CA_DROP_CMD that is NOT fixture-gated is refused loudly rather than
  # silently ignored: whoever set it meant to exercise the drop path, and a
  # seven-minute self-test that quietly did not is worse than a refusal.
  if [ -z "${CA_ST_DROPPED:-}" ] && [ -n "${CA_DROP_CMD:-}" ] && ! ca_drop_override >/dev/null; then
    say "self-test: CA_DROP_CMD is IGNORED without \$CA_ECO/.ca_fixture -- the trust root is the drop tool this script chooses: drop=$(drop_tool)"
    say "SELF-TEST: FAIL -- CA_DROP_CMD set without a fixture gate"
    exit 2
  fi
  if [ -z "${CA_ST_DROPPED:-}" ] \
     && { [ "$(id -u)" = 0 ] || { [ "${CA_FAULT:-}" = pretend_root ] && ca_drop_override >/dev/null; }; }; then
    if selftest_drop_privileges "$self_sh"; then
      exit "$ST_DROP_EXIT"
    fi
    ST_AS_ROOT=1
    say "self-test: uid 0 and no usable drop ($ST_DROP_WHY) -- the two unwritable plants SKIP by name"
  fi
  # CA-GUARD:end-root-drop
  outer_tmp="${TMPDIR:-/tmp}"
  # CA-GUARD:scratch-token
  ST_TOKEN="t$$x${RANDOM:-0}"
  export CA_SCRATCH_TAG="$ST_TOKEN."
  st_root="$(mktemp -d "${outer_tmp}/ca-st.$ST_TOKEN.XXXXXX")"
  ST_ROOT="$st_root"
  mkdir -p "$st_root/tmp"
  : > "$st_root/.stmark"
  ST_CAP="$st_root/stderr.cap"
  : > "$ST_CAP"
  export CA_STDERR_CAP="$ST_CAP"
  export TMPDIR="$st_root/tmp"
  trap 'if [ -n "${st_root:-}" ] && [ -d "${st_root:-}" ]; then find "$st_root" -type d -exec chmod u+w {} + 2>/dev/null || true; rm -rf "$st_root"; fi' EXIT

  local sh
  sh="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  mk_stub "$st_root/stub-ok" 0
  mk_stub "$st_root/stub-bad" 1
  mk_stub_gfx "$st_root/stub-gfx"

  local ex_out=""
  if ex_out="$(python3 "$HERE/tools/_extract_runcmd.py" --selftest)"; then
    plant_line "extract-runcmd" 0 "$ex_out"
  else
    plant_line "extract-runcmd" 1 "extractor --selftest failed"
  fi

  # --- plan plant: ungated consumer must FAIL the plan (GAP + VERDICT: FAIL + nonzero).
  local plan_eco="$st_root/plan-eco"
  mkdir -p "$plan_eco"
  mk_consumer "$plan_eco" zz-planted-consumer ""
  if CA_ECO="$plan_eco" plant_plan_gap "$sh" "$plan_eco"; then
    plant_line "plan-ungated" 0 "GAP named zz-planted-consumer, VERDICT: FAIL, nonzero"
  else
    plant_line "plan-ungated" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- control: two passing fake consumers, stub exits 0.
  local good_eco="$st_root/good-eco"
  mkdir -p "$good_eco"
  printf 'fixture\n' > "$good_eco/.ca_fixture"
  mk_consumer "$good_eco" good_a "eigenscript work.eigs"
  mk_consumer "$good_eco" good_b '$EIGS work.eigs'
  rec="$st_root/good.record"
  if plant_honest_good "$sh" "$good_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "control honest-good" 0 "VERDICT: PASS inventory=2 examined=2"
  else
    plant_line "control honest-good" 1 "$LAST_PLANT_DETAIL"
  fi

  # Plan on the same honest fixture must still PASS (plan mode unchanged).
  out="$(CA_ECO="$good_eco" "$sh" plan 2>&1)" || true
  if grep -q 'VERDICT: PASS -- 2 consumers' <<< "$out"; then
    plant_line "plan-control" 0 "plan still PASSes a 2-consumer fixture"
  else
    plant_line "plan-control" 1 "plan did not PASS the honest fixture"
  fi

  # SKIP rows exist ONLY for EXCLUDED names, and they are not examined.
  local skip_eco="$st_root/skip-eco"
  mkdir -p "$skip_eco"
  printf 'fixture\n' > "$skip_eco/.ca_fixture"
  mk_consumer "$skip_eco" keep "eigenscript work.eigs"
  mk_consumer "$skip_eco" tmp "eigenscript work.eigs"
  rec="$st_root/skip.record"
  out="$(CA_ECO="$skip_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] \
     && exact_verdict_file "$rec" PASS \
     && grep -q 'inventory=1 examined=1' "$rec" \
     && grep -q '^skip|tmp|' "$rec" \
     && grep -q 'row|keep|v0.43.0|PASS|' "$rec"; then
    plant_line "skip-excluded" 0 "tmp SKIP not examined, keep PASS, inventory=1 examined=1"
  else
    plant_line "skip-excluded" 1 "rc=$rc"
  fi

  # --- A: broken candidate, every row FAIL, verdict FAIL.
  local a_eco="$st_root/a-eco"
  mkdir -p "$a_eco"
  printf 'fixture\n' > "$a_eco/.ca_fixture"
  mk_consumer "$a_eco" a_one "eigenscript work.eigs"
  mk_consumer "$a_eco" a_two "eigenscript work.eigs"
  rec="$st_root/a.record"
  out="$(CA_ECO="$a_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-bad" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && exact_verdict_file "$rec" FAIL \
     && grep -q 'row|a_one|v0.43.0|FAIL|' "$rec" \
     && grep -q 'row|a_two|v0.43.0|FAIL|' "$rec" \
     && ! grep -q '|PASS|' "$rec"; then
    plant_line "A broken-candidate" 0 "every row FAIL, VERDICT: FAIL"
  else
    plant_line "A broken-candidate" 1 "rc=$rc"
  fi

  # --- B: shrinkage -- present at plan time, removed before its turn.
  local b_eco="$st_root/b-eco"
  mkdir -p "$b_eco"
  printf 'fixture\n' > "$b_eco/.ca_fixture"
  mk_consumer "$b_eco" keep "eigenscript work.eigs"
  mk_consumer "$b_eco" victim "eigenscript work.eigs"
  printf '%s\n' keep victim > "$b_eco/.ca_expected"
  rec="$st_root/b.record"
  out="$(CA_ECO="$b_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_DROP_BEFORE=victim CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && exact_verdict_file "$rec" FAIL \
     && grep -q 'row|victim|' "$rec" \
     && grep -q '|UNRUNNABLE|' "$rec" \
     && grep -q 'inventory=2 examined=2' "$rec"; then
    plant_line "B shrinkage" 0 "UNRUNNABLE victim (declared-absent before scan), examined=2 inventory=2, VERDICT: FAIL"
  else
    plant_line "B shrinkage" 1 "rc=$rc rec=$(grep -E '^row|inventory=' "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- C: hang -- sleep past budget; HANG by name; run continues.
  local c_eco="$st_root/c-eco"
  mkdir -p "$c_eco"
  printf 'fixture\n' > "$c_eco/.ca_fixture"
  mk_consumer "$c_eco" aaa_sleep "sleep 30"
  mk_consumer "$c_eco" zzz_pass "eigenscript work.eigs"
  rec="$st_root/c.record"
  out="$(CA_ECO="$c_eco" CA_TIMEOUT=1 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && exact_verdict_file "$rec" FAIL \
     && grep -q 'row|aaa_sleep|v0.43.0|HANG|124|' "$rec" \
     && grep -q 'row|zzz_pass|v0.43.0|PASS|' "$rec"; then
    plant_line "C hang" 0 "HANG aaa_sleep rc=124, zzz_pass still PASS, VERDICT: FAIL"
  else
    plant_line "C hang" 1 "rc=$rc record=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- C2: SIGKILL is KILLED by name, never folded into FAIL.
  local k_eco="$st_root/k-eco"
  mkdir -p "$k_eco"
  printf 'fixture\n' > "$k_eco/.ca_fixture"
  mk_consumer "$k_eco" aaa_kill 'kill -9 $$'
  mk_consumer "$k_eco" zzz_ok "eigenscript work.eigs"
  rec="$st_root/k.record"
  out="$(CA_ECO="$k_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && exact_verdict_file "$rec" FAIL \
     && grep -q 'row|aaa_kill|v0.43.0|KILLED|137|' "$rec" \
     && grep -q 'row|zzz_ok|v0.43.0|PASS|' "$rec"; then
    plant_line "C2 killed" 0 "KILLED aaa_kill rc=137, zzz_ok still PASS"
  else
    plant_line "C2 killed" 1 "rc=$rc record=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- D: SIGTERM mid-wave; record INCOMPLETE; exit 2; returns promptly.
  local d_eco="$st_root/d-eco"
  mkdir -p "$d_eco"
  printf 'fixture\n' > "$d_eco/.ca_fixture"
  mk_consumer "$d_eco" aaa_block "sleep 30"
  mk_consumer "$d_eco" zzz_after "eigenscript work.eigs"
  rec="$st_root/d.record"
  if plant_interruption "$sh" "$d_eco" "$st_root/stub-ok" "$rec" TERM; then
    plant_line "D interruption" 0 "record INCOMPLETE, exactly one stdout VERDICT: INCOMPLETE, exit 2"
  else
    plant_line "D interruption" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- D2: SIGHUP is trapped the same way (exit 2, not 129).
  local dh_eco="$st_root/dh-eco"
  mkdir -p "$dh_eco"
  printf 'fixture\n' > "$dh_eco/.ca_fixture"
  mk_consumer "$dh_eco" aaa_block "sleep 30"
  mk_consumer "$dh_eco" zzz_after "eigenscript work.eigs"
  rec="$st_root/dh.record"
  if plant_interruption "$sh" "$dh_eco" "$st_root/stub-ok" "$rec" HUP; then
    plant_line "D2 sighup" 0 "SIGHUP -> INCOMPLETE, exactly one stdout VERDICT: INCOMPLETE, exit 2"
  else
    plant_line "D2 sighup" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- E: hanging --version probe; stale PASS at the record path is gone.
  local e_eco="$st_root/e-eco"
  mkdir -p "$e_eco"
  printf 'fixture\n' > "$e_eco/.ca_fixture"
  mk_consumer "$e_eco" e_one "eigenscript work.eigs"
  mk_stub_hang_version "$st_root/stub-hang-ver"
  rec="$st_root/e.record"
  printf '%s\n' '# stale' 'status=COMPLETE' 'inventory=1 examined=1' 'VERDICT: PASS' > "$rec"
  CA_ECO="$e_eco" CA_TIMEOUT=1 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-hang-ver" >/dev/null 2>&1 &
  pid=$!
  waited=0
  while [ "$waited" -lt 8 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    plant_line "E hanging-probe" 1 "candidate --version still running after ${waited}s"
  else
    wait "$pid"
    rc=$?
    if [ "$rc" -ne 0 ] \
       && ! grep -qx 'VERDICT: PASS' "$rec" \
       && ! grep -q '^VERDICT: PASS$' "$rec" \
       && { grep -q '^run_id=' "$rec" || grep -q 'VERDICT: FAIL' "$rec" || grep -q 'VERDICT: INCOMPLETE' "$rec"; }; then
      plant_line "E hanging-probe" 0 "stale PASS superseded, verdict not PASS, exit=$rc"
    else
      plant_line "E hanging-probe" 1 "rc=$rc record=$(tail -8 "$rec" 2>/dev/null | tr '\n' ' ')"
    fi
  fi

  # --- F: unwritable record directory -- no VERDICT: PASS, exit 1.
  local f_eco="$st_root/f-eco" ro_dir rec_f
  mkdir -p "$f_eco"
  printf 'fixture\n' > "$f_eco/.ca_fixture"
  mk_consumer "$f_eco" f_one "eigenscript work.eigs"
  ro_dir="$st_root/ro"
  mkdir -p "$ro_dir"
  rec_f="$ro_dir/record"
  # CA-GUARD:unwritable-class-skip
  # Same class as plant I: as uid 0 a 0555 directory is still writable, so
  # the plant cannot be planted. It SKIPs BY NAME and is counted.
  if [ "$(id -u)" = 0 ]; then
    say "plant F unwritable-record: SKIP -- uid 0 and the self-test could not drop privileges (${ST_DROP_WHY:-unknown})"
    ST_SKIP=$((ST_SKIP + 1))
  else
  chmod a-w "$ro_dir"
  out="$(CA_ECO="$f_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec_f" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  chmod u+w "$ro_dir"
  note_plant "$out" "$rec_f" "$rc"
  if [ "$rc" -eq 1 ] \
     && ! grep -q 'VERDICT: PASS' <<< "$out" \
     && [ ! -e "$rec_f" ]; then
    plant_line "F unwritable-record" 0 "no VERDICT: PASS, exit 1, record absent (uid=$(id -u))"
  else
    plant_line "F unwritable-record" 1 "rc=$rc exists=$( [ -e "$rec_f" ] && echo yes || echo no ) out=$(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')"
  fi
  fi

  # --- G: two-line block, first line fails, second would succeed -> FAIL row.
  local g_eco="$st_root/g-eco"
  mkdir -p "$g_eco"
  printf 'fixture\n' > "$g_eco/.ca_fixture"
  mk_consumer_block "$g_eco" blk_fail "false" "echo done"
  rec="$st_root/g.record"
  out="$(CA_ECO="$g_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|blk_fail|v0.43.0|FAIL|' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    plant_line "G block-set-e" 0 "false then echo done is a FAIL row"
  else
    plant_line "G block-set-e" 1 "rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- early-stop: examined < inventory on a completed record (CA_FAULT).
  local es_eco="$st_root/es-eco"
  mkdir -p "$es_eco"
  printf 'fixture\n' > "$es_eco/.ca_fixture"
  mk_consumer "$es_eco" aaa "eigenscript work.eigs"
  mk_consumer "$es_eco" bbb "eigenscript work.eigs"
  mk_consumer "$es_eco" ccc "eigenscript work.eigs"
  rec="$st_root/es.record"
  if plant_early_stop "$sh" "$es_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "early-stop" 0 "inventory=3 examined=1, VERDICT: FAIL"
  else
    plant_line "early-stop" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- empty inventory: only an EXCLUDED pinning repo.
  local z_eco="$st_root/z-eco"
  mkdir -p "$z_eco"
  printf 'fixture\n' > "$z_eco/.ca_fixture"
  mk_consumer "$z_eco" tmp "eigenscript work.eigs"
  rec="$st_root/z.record"
  if plant_empty_inventory "$sh" "$z_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "empty-inventory" 0 "inventory=0 examined=0, VERDICT: FAIL"
  else
    plant_line "empty-inventory" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- missing command: pinning consumer, no workflow.
  local m_eco="$st_root/m-eco"
  mkdir -p "$m_eco"
  printf 'fixture\n' > "$m_eco/.ca_fixture"
  mk_consumer "$m_eco" no_wf ""
  rec="$st_root/m.record"
  if plant_missing_command "$sh" "$m_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "missing-command" 0 "row|no_wf|v0.43.0|UNRUNNABLE|-|, VERDICT: FAIL"
  else
    plant_line "missing-command" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- SKIP without a reason (CA_FAULT=empty_skip_reason).
  local sr_eco="$st_root/sr-eco"
  mkdir -p "$sr_eco"
  printf 'fixture\n' > "$sr_eco/.ca_fixture"
  mk_consumer "$sr_eco" keep "eigenscript work.eigs"
  rec="$st_root/sr.record"
  if plant_skip_no_reason "$sh" "$sr_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "skip-no-reason" 0 "empty SKIP reason, VERDICT: FAIL"
  else
    plant_line "skip-no-reason" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- H: INT in the pre-scan window over a stale PASS (16-consumer skeleton).
  local h_eco="$st_root/h-eco" hi
  mkdir -p "$h_eco"
  printf 'fixture\n' > "$h_eco/.ca_fixture"
  hi=1
  while [ "$hi" -le 16 ]; do
    mk_consumer_padded "$h_eco" "c$(printf '%02d' "$hi")" "eigenscript work.eigs"
    hi=$((hi + 1))
  done
  rec="$st_root/h.record"
  if plant_prescan_int "$sh" "$h_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "H prescan-int" 0 "stale PASS gone, exit 2"
  else
    plant_line "H prescan-int" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- I: stale PASS + unwritable directory.
  local i_eco="$st_root/i-eco" i_dir
  mkdir -p "$i_eco" "$st_root/i-ro"
  printf 'fixture\n' > "$i_eco/.ca_fixture"
  mk_consumer "$i_eco" i_one "eigenscript work.eigs"
  rec="$st_root/i-ro/record"
  plant_stale_unwritable "$sh" "$i_eco" "$st_root/stub-ok" "$rec"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    plant_line "I stale-unwritable" 0 "record not PASS, exit 1"
  elif [ "$rc" -eq 3 ]; then
    say "plant I stale-unwritable: SKIP -- $LAST_PLANT_DETAIL"
    ST_SKIP=$((ST_SKIP + 1))
  else
    plant_line "I stale-unwritable" 1 "$LAST_PLANT_DETAIL"
  fi
  # Fixture-gated pretend_root: the plant takes the named SKIP path (or, as
  # real root with a usable drop tool, FIREs under the unprivileged user).
  CA_FAULT=pretend_root plant_stale_unwritable "$sh" "$i_eco" "$st_root/stub-ok" "$st_root/i-ro/pretend"
  rc=$?
  if [ "$rc" -eq 3 ] && [ "${LAST_PLANT_DETAIL#SKIP \(root: }" != "$LAST_PLANT_DETAIL" ]; then
    plant_line "I stale-unwritable-root" 0 "$LAST_PLANT_DETAIL"
  elif [ "$rc" -eq 0 ]; then
    plant_line "I stale-unwritable-root" 0 "unprivileged drop FIRE -- $LAST_PLANT_DETAIL"
  else
    plant_line "I stale-unwritable-root" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- J: signal during finalization -- exactly one VERDICT line, rc, stdout.
  local j_eco="$st_root/j-eco" j_shim="$st_root/j-shim"
  mkdir -p "$j_eco" "$j_shim"
  printf 'fixture\n' > "$j_eco/.ca_fixture"
  mk_consumer "$j_eco" j_one "eigenscript work.eigs"
  printf '%s\n' '#!/bin/bash' '/usr/bin/mv "$@" || exit $?' 'case "$1" in *.rewrite.*) kill -HUP "$PPID" ;; esac' 'exit 0' > "$j_shim/mv"
  chmod +x "$j_shim/mv"
  rec="$st_root/j.record"
  if plant_footer_signal "$sh" "$j_eco" "$st_root/stub-ok" "$rec" "$j_shim"; then
    plant_line "J footer-signal" 0 "exactly one VERDICT line, rc=0, stdout PASS"
  else
    plant_line "J footer-signal" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- N: second invocation on the same CA_RECORD is refused.
  local n_eco_a="$st_root/n-eco-a" n_eco_b="$st_root/n-eco-b"
  mkdir -p "$n_eco_a" "$n_eco_b"
  printf 'fixture\n' > "$n_eco_a/.ca_fixture"
  printf 'fixture\n' > "$n_eco_b/.ca_fixture"
  mk_consumer "$n_eco_a" aa_slow "eigenscript work.eigs; sleep 3"
  mk_consumer "$n_eco_b" aa_bad "eigenscript work.eigs"
  rec="$st_root/n.record"
  if plant_record_busy "$sh" "$n_eco_a" "$n_eco_b" "$st_root/stub-ok" "$st_root/stub-bad" "$rec"; then
    plant_line "N record-busy" 0 "second run exit 2 busy, first PASS one VERDICT"
  else
    plant_line "N record-busy" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- O: foreign-file append refused, clobbered in place.
  local o_eco="$st_root/o-eco"
  mkdir -p "$o_eco"
  printf 'fixture\n' > "$o_eco/.ca_fixture"
  mk_consumer "$o_eco" o_one "eigenscript work.eigs"
  rec="$st_root/o.record"
  if plant_foreign_record "$sh" "$o_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "O foreign-record" 0 "record not ours, foreign PASS clobbered, exit 1"
  else
    plant_line "O foreign-record" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- P: die_record after a failed footer still lands INCOMPLETE.
  local p_eco="$st_root/p-eco"
  mkdir -p "$p_eco"
  printf 'fixture\n' > "$p_eco/.ca_fixture"
  mk_consumer "$p_eco" p_one "eigenscript work.eigs"
  rec="$st_root/p.record"
  if plant_fail_footer "$sh" "$p_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "P fail-footer" 0 "footer fail, finish_incomplete lands INCOMPLETE"
  else
    plant_line "P fail-footer" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- Q: stdout verdict on HUP-after-rename (J's scenario, rc + stdout).
  rec="$st_root/q.record"
  if plant_footer_signal "$sh" "$j_eco" "$st_root/stub-ok" "$rec" "$j_shim"; then
    plant_line "Q stdout-hup" 0 "HUP-after-rename rc=0, one stdout VERDICT: PASS"
  else
    plant_line "Q stdout-hup" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- K: CA_TIMEOUT=0 and 00 both exit 2.
  # Not k_eco: C2 already bound that name to the kill fixture.
  local tz_eco="$st_root/tz-eco"
  mkdir -p "$tz_eco"
  printf 'fixture\n' > "$tz_eco/.ca_fixture"
  mk_consumer "$tz_eco" tz_one "eigenscript work.eigs"
  rec="$st_root/k0.record"
  if plant_timeout_zero "$sh" "$tz_eco" "$st_root/stub-ok" "$rec" 0 \
     && plant_timeout_zero "$sh" "$tz_eco" "$st_root/stub-ok" "$st_root/k00.record" 00 \
     && plant_timeout_zero "$sh" "$tz_eco" "$st_root/stub-ok" "$st_root/kempty.record" ""; then
    plant_line "K timeout-zero" 0 "0, 00 and empty all exit 2"
  else
    plant_line "K timeout-zero" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- L: false | true is a FAIL row (pipefail).
  local l_eco="$st_root/l-eco"
  mkdir -p "$l_eco"
  printf 'fixture\n' > "$l_eco/.ca_fixture"
  mk_consumer_block "$l_eco" pipe_fail "false | true" "eigenscript work.eigs"
  rec="$st_root/l.record"
  if plant_pipefail "$sh" "$l_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "L pipefail" 0 "false | true is a FAIL row"
  else
    plant_line "L pipefail" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- M: scratch dirs do not outlive the run.
  rec="$st_root/m-scratch.record"
  if plant_scratch_cleanup "$sh" "$good_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "M scratch-cleanup" 0 "no ca-run leftover"
  else
    plant_line "M scratch-cleanup" 1 "$LAST_PLANT_DETAIL"
  fi

  # Decoy in the OUTER tmp (a concurrent run's scratch). Must survive plant M.
  # $$ so two concurrent self-tests do not share one path.
  local decoy="$outer_tmp/ca-run.DECOY.$$"
  # ca-run.VICTIM-<pid> is the exact shape a round-6 critic probe used to
  # ask whether plant M deletes a NEIGHBOUR's scratch; both shapes are
  # covered, and both are removed before the outer-tmp hygiene check.
  local victim="$outer_tmp/ca-run.VICTIM-$$"
  mkdir -p "$decoy" "$victim"
  touch "$decoy" "$victim"
  rec="$st_root/m-decoy.record"
  if plant_scratch_cleanup "$sh" "$good_eco" "$st_root/stub-ok" "$rec" \
     && [ -d "$decoy" ] && [ -d "$victim" ]; then
    plant_line "M decoy-tmp-isolation" 0 "outer ca-run.DECOY and ca-run.VICTIM survived plant M"
  else
    plant_line "M decoy-tmp-isolation" 1 "decoy=$( [ -d "$decoy" ] && echo live || echo gone ) victim=$( [ -d "$victim" ] && echo live || echo gone ) $LAST_PLANT_DETAIL"
  fi
  rm -rf "$decoy" "$victim"

  # --- R: `true` never calls the candidate -> UNEXERCISED.
  local r_eco="$st_root/r-eco"
  mkdir -p "$r_eco"
  printf 'fixture\n' > "$r_eco/.ca_fixture"
  mk_consumer "$r_eco" r_true "true"
  rec="$st_root/r.record"
  if plant_unexercised "$sh" "$r_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "R unexercised" 0 "true -> UNEXERCISED cand_calls=0, VERDICT: FAIL"
  else
    plant_line "R unexercised" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- S: tree consumer via EIGS_DIR/src/eigenscript -> PASS cand_calls=1.
  local s_eco="$st_root/s-eco" s_stub="$st_root/s-cand/src/eigenscript"
  mkdir -p "$s_eco" "$st_root/s-cand/src"
  printf 'fixture\n' > "$s_eco/.ca_fixture"
  mk_stub "$s_stub" 0
  mk_consumer "$s_eco" tree_user '"$EIGS_DIR/src/eigenscript" work.eigs'
  rec="$st_root/s.record"
  if plant_tree_consumer "$sh" "$s_eco" "$s_stub" "$rec"; then
    plant_line "S tree-consumer" 0 "EIGS_DIR/src/eigenscript work.eigs PASS cand_calls=1"
  else
    plant_line "S tree-consumer" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- T: DECLARED command names a nonexistent file -> plan GAP.
  local t_eco="$st_root/t-eco"
  mkdir -p "$t_eco"
  printf 'fixture\n' > "$t_eco/.ca_fixture"
  mk_consumer "$t_eco" t_miss ""
  printf 'bash tests/does_not_exist.sh\n' > "$t_eco/t_miss/.ca_declared"
  if CA_ECO="$t_eco" plant_declared_missing "$sh" "$t_eco"; then
    plant_line "T declared-missing" 0 "GAP declared command's file does not exist"
  else
    plant_line "T declared-missing" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- U: PREREQS=nonexistent-tool -> UNRUNNABLE|prereq:nonexistent-tool.
  local u_eco="$st_root/u-eco"
  mkdir -p "$u_eco"
  printf 'fixture\n' > "$u_eco/.ca_fixture"
  mk_consumer "$u_eco" u_prereq "eigenscript work.eigs"
  printf 'nonexistent-tool\n' > "$u_eco/u_prereq/.ca_prereqs"
  rec="$st_root/u.record"
  if plant_prereq_missing "$sh" "$u_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "U prereq-missing" 0 "UNRUNNABLE|prereq:nonexistent-tool"
  else
    plant_line "U prereq-missing" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- V: forged call| lines via CA_CAND_COUNT_FILE -> UNEXERCISED.
  local v_eco="$st_root/v-eco"
  mkdir -p "$v_eco"
  printf 'fixture\n' > "$v_eco/.ca_fixture"
  mk_consumer "$v_eco" v_forge 'printf "call|rc=0|forged\n" >> "${CA_CAND_COUNT_FILE:-/dev/null}"'
  rec="$st_root/v.record"
  if plant_forged_counter "$sh" "$v_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "V forged-counter" 0 "call| write -> UNEXERCISED cand_calls=0"
  else
    plant_line "V forged-counter" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- W: version-only -> UNEXERCISED.
  local w_eco="$st_root/w-eco"
  mkdir -p "$w_eco"
  printf 'fixture\n' > "$w_eco/.ca_fixture"
  mk_consumer "$w_eco" w_ver "eigenscript --version"
  rec="$st_root/w.record"
  if plant_version_only "$sh" "$w_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "W version-only" 0 "--version -> UNEXERCISED cand_calls=0"
  else
    plant_line "W version-only" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- X: swallowed rc (eigenscript bad.eigs || true) -> SWALLOWED.
  local x_eco="$st_root/x-eco"
  mkdir -p "$x_eco"
  printf 'fixture\n' > "$x_eco/.ca_fixture"
  mk_consumer "$x_eco" x_swall "eigenscript bad.eigs || true"
  rec="$st_root/x.record"
  if plant_swallowed "$sh" "$x_eco" "$st_root/stub-bad" "$rec"; then
    plant_line "X swallowed" 0 "bad.eigs || true -> SWALLOWED cand_ok=0 cand_fail=1"
  else
    plant_line "X swallowed" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- Y: overlay COPY -- write does not touch candidate lib/; realpath counted.
  local y_eco="$st_root/y-eco" y_stub="$st_root/y-cand/src/eigenscript"
  mkdir -p "$y_eco" "$st_root/y-cand/src" "$st_root/y-cand/lib"
  printf 'fixture\n' > "$y_eco/.ca_fixture"
  printf 'original\n' > "$st_root/y-cand/lib/marker"
  mk_stub "$y_stub" 0
  mk_consumer_block "$y_eco" y_ov \
    'printf "changed\n" > "$EIGS_DIR/lib/marker"' \
    'rp=$(realpath "$EIGS_DIR/src/eigenscript")' \
    '"$rp" work.eigs'
  rec="$st_root/y.record"
  if plant_overlay_write "$sh" "$y_eco" "$y_stub" "$rec"; then
    plant_line "Y overlay-write" 0 "lib checksum unchanged, realpath cand_calls=1 PASS"
  else
    plant_line "Y overlay-write" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- Z: consumer runs nothing; stub lists gfx_open so the bind probe
  # (a positional) exists to mis-attribute if the mechanism is gutted.
  local z_idle_eco="$st_root/z-idle-eco"
  mkdir -p "$z_idle_eco"
  printf 'fixture\n' > "$z_idle_eco/.ca_fixture"
  mk_consumer "$z_idle_eco" z_idle "true"
  rec="$st_root/z-idle.record"
  if plant_probe_not_attributed "$sh" "$z_idle_eco" "$st_root/stub-gfx" "$rec"; then
    plant_line "Z probe-not-attributed" 0 "true + gfx stub -> cand_calls=0 UNEXERCISED"
  else
    plant_line "Z probe-not-attributed" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- AA: EIGENSCRIPT_BIN beats a sibling hard-path.
  local aa_eco="$st_root/aa-eco" aa_stub="$st_root/aa-cand/src/eigenscript"
  mkdir -p "$aa_eco" "$st_root/aa-cand/src" "$aa_eco/aa_route/tests" \
           "$aa_eco/EigenScript/src"
  printf 'fixture\n' > "$aa_eco/.ca_fixture"
  mk_stub "$aa_stub" 0
  printf '%s\n' '#!/bin/sh' \
    "printf 'sibling:%s\\n' \"\$*\" >> \"$st_root/aa-sibling.log\"" \
    'exit 0' > "$aa_eco/EigenScript/src/eigenscript"
  chmod +x "$aa_eco/EigenScript/src/eigenscript"
  : > "$st_root/aa-sibling.log"
  printf '%s\n' '#!/bin/sh' \
    'ROOT="$(cd "$(dirname "$0")/.." && pwd)"' \
    'if [ -n "${EIGENSCRIPT_BIN:-}" ]; then' \
    '  BIN="$EIGENSCRIPT_BIN"' \
    'elif [ -x "$ROOT/../EigenScript/src/eigenscript" ]; then' \
    '  BIN="$ROOT/../EigenScript/src/eigenscript"' \
    'else' \
    '  BIN=eigenscript' \
    'fi' \
    '"$BIN" work.eigs' > "$aa_eco/aa_route/tests/run.sh"
  chmod +x "$aa_eco/aa_route/tests/run.sh"
  mk_consumer "$aa_eco" aa_route "bash tests/run.sh"
  rec="$st_root/aa.record"
  if plant_bin_routing "$sh" "$aa_eco" "$aa_stub" "$rec"; then
    plant_line "AA eigenscript-bin" 0 "EIGENSCRIPT_BIN routes to shim, sibling log empty, PASS"
  else
    plant_line "AA eigenscript-bin" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- AB: gfx PREREQS, stub --api omits gfx_open -> UNRUNNABLE|prereq:gfx-build.
  local ab_eco="$st_root/ab-eco"
  mkdir -p "$ab_eco"
  printf 'fixture\n' > "$ab_eco/.ca_fixture"
  mk_consumer "$ab_eco" ab_gfx "eigenscript work.eigs"
  printf 'gfx\n' > "$ab_eco/ab_gfx/.ca_prereqs"
  rec="$st_root/ab.record"
  if plant_gfx_prereq "$sh" "$ab_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "AB gfx-prereq" 0 "UNRUNNABLE|prereq:gfx-build"
  else
    plant_line "AB gfx-prereq" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- AC: clobber must not truncate through a symlink. Victim keeps its bytes.
  local ac_eco="$st_root/ac-eco"
  mkdir -p "$ac_eco"
  printf 'fixture\n' > "$ac_eco/.ca_fixture"
  mk_consumer "$ac_eco" ac_swap "eigenscript work.eigs"
  rec="$st_root/ac.record"
  if plant_clobber_symlink "$sh" "$ac_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "AC clobber-symlink" 0 "victim keeps its bytes"
  else
    plant_line "AC clobber-symlink" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- straggler: row N's background call must not land in row N+1.
  local st_eco="$st_root/st-eco"
  mkdir -p "$st_eco"
  printf 'fixture\n' > "$st_eco/.ca_fixture"
  mk_consumer_block "$st_eco" a_leaves_bg \
    'eigenscript work.eigs' \
    '( sleep 2; eigenscript straggler.eigs ) > /dev/null 2>&1 &' \
    'exit 0'
  mk_consumer_block "$st_eco" b_never_calls 'sleep 1' 'true'
  rec="$st_root/straggler.record"
  if plant_straggler "$sh" "$st_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "straggler" 0 "b_never_calls UNEXERCISED"
  else
    plant_line "straggler" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- export-block join: EIGENSCRIPT_DIR equals EIGS_DIR, ends in cand_tree.
  local exp_eco="$st_root/exp-eco" exp_stub="$st_root/exp-cand/src/eigenscript"
  mkdir -p "$exp_eco" "$st_root/exp-cand/src"
  printf 'fixture\n' > "$exp_eco/.ca_fixture"
  mk_stub "$exp_stub" 0
  mk_consumer_block "$exp_eco" exp_join \
    'case "$EIGENSCRIPT_DIR" in "$EIGS_DIR") ;; *) exit 1 ;; esac' \
    'case "$EIGS_DIR" in */cand_tree) ;; *) exit 1 ;; esac' \
    'eigenscript work.eigs'
  rec="$st_root/exp.record"
  if plant_exports_join "$sh" "$exp_eco" "$exp_stub" "$rec"; then
    plant_line "exports-join" 0 "EIGENSCRIPT_DIR equals EIGS_DIR and ends in cand_tree"
  else
    plant_line "exports-join" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- private log: find every regular file under shim parent and EIGS_DIR.
  local pf_eco="$st_root/pf-eco"
  mkdir -p "$pf_eco"
  printf 'fixture\n' > "$pf_eco/.ca_fixture"
  mk_consumer_block "$pf_eco" priv_find \
    'W="$(dirname "$(dirname "$(command -v eigenscript)")")"' \
    'E="${EIGS_DIR:-}"' \
    'find "$W" ${E:+"$E"} -type f 2>/dev/null | while IFS= read -r f; do' \
    '  printf "call|rc=0|x\n" >> "$f" 2>/dev/null || true' \
    'done' \
    'true'
  rec="$st_root/pf.record"
  if plant_private_find "$sh" "$pf_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "private-find" 0 "find+forge under shim parent and EIGS_DIR -> UNEXERCISED"
  else
    plant_line "private-find" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- overlay symlink: write through lib/link must not change the outside file.
  local ovl_eco="$st_root/ovl-eco" ovl_stub="$st_root/ovl-cand/src/eigenscript"
  local ovl_out="$st_root/ovl-outside"
  mkdir -p "$ovl_eco" "$st_root/ovl-cand/src" "$st_root/ovl-cand/lib"
  printf 'fixture\n' > "$ovl_eco/.ca_fixture"
  printf 'ORIGINAL\n' > "$ovl_out"
  ln -s "$ovl_out" "$st_root/ovl-cand/lib/link"
  mk_stub "$ovl_stub" 0
  mk_consumer_block "$ovl_eco" ov_link \
    'printf CHANGED > "$EIGS_DIR/lib/link"' \
    'eigenscript work.eigs'
  rec="$st_root/ovl.record"
  if plant_overlay_symlink "$sh" "$ovl_eco" "$ovl_stub" "$rec" "$ovl_out"; then
    plant_line "overlay-symlink" 0 "outside file unchanged"
  else
    plant_line "overlay-symlink" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- gfx bind probe segfaults -> unknown, gfx prereq missing with rc 139.
  local gc_eco="$st_root/gc-eco" gc_stub="$st_root/stub-segv"
  mkdir -p "$gc_eco"
  printf 'fixture\n' > "$gc_eco/.ca_fixture"
  printf '%s\n' '#!/bin/sh' \
    'if [ "${1:-}" = --version ]; then echo stub; exit 0; fi' \
    'if [ "${1:-}" = --api ]; then echo "{\"builtins\":[\"gfx_open\"]}"; exit 0; fi' \
    'case "$1" in *gfx_bind.eigs) exit 139 ;; esac' \
    'exit 0' > "$gc_stub"
  chmod +x "$gc_stub"
  mk_consumer "$gc_eco" ab_crash "eigenscript work.eigs"
  printf 'gfx\n' > "$gc_eco/ab_crash/.ca_prereqs"
  rec="$st_root/gc.record"
  if plant_gfx_crash "$sh" "$gc_eco" "$gc_stub" "$rec"; then
    plant_line "gfx-crash" 0 "candidate_gfx unknown, UNRUNNABLE prereq:gfx-build (probe rc 139)"
  else
    plant_line "gfx-crash" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- DMG-shaped self-skip: consumer_skips=1, not a bare PASS.
  local gs_eco="$st_root/gs-eco"
  mkdir -p "$gs_eco/dmg_like/tests"
  printf 'fixture\n' > "$gs_eco/.ca_fixture"
  cat > "$gs_eco/dmg_like/tests/run_debug_ui_oracle.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${EIGENSCRIPT_GFX:-}" ]; then E="$EIGENSCRIPT_GFX"; elif command -v eigenscript >/dev/null; then E="$(command -v eigenscript)"; else echo "SKIP: no binary"; exit 0; fi
if ! "$E" tests/probe_ui.eigs >/dev/null 2>&1; then echo "SKIP: dock widget not in this runtime's lib (self-skip, exit 0)"; exit 0; fi
echo "UI ORACLE RAN"; exit 1
EOS
  chmod +x "$gs_eco/dmg_like/tests/run_debug_ui_oracle.sh"
  mk_consumer_block "$gs_eco" dmg_like \
    'eigenscript tests/test_cpu.eigs' \
    'bash tests/run_debug_ui_oracle.sh'
  rec="$st_root/gs.record"
  printf '%s\n' '#!/bin/sh' \
    'if [ "${1:-}" = --version ]; then echo stub; exit 0; fi' \
    'if [ "${1:-}" = --api ]; then echo "{\"builtins\":[]}"; exit 0; fi' \
    'case "$1" in *probe_ui.eigs) echo "undefined variable gfx_open" >&2; exit 1;; esac' \
    'exit 0' > "$st_root/stub-headless"
  chmod +x "$st_root/stub-headless"
  if plant_gfx_selfskip "$sh" "$gs_eco" "$st_root/stub-headless" "$rec"; then
    plant_line "gfx-selfskip" 0 "PASS|skips=1 consumer_skips=1"
  else
    plant_line "gfx-selfskip" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- bare candidate + sibling tree -> exit 2 before any row.
  local bs_eco="$st_root/bs-eco"
  mkdir -p "$bs_eco/tree_user" "$bs_eco/EigenScript/src"
  printf 'fixture\n' > "$bs_eco/.ca_fixture"
  mk_stub "$bs_eco/EigenScript/src/eigenscript" 0
  mk_consumer "$bs_eco" tree_user "eigenscript work.eigs"
  rec="$st_root/bs.record"
  if plant_bare_sibling "$sh" "$bs_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "bare-sibling" 0 "exit 2, names both paths, no row"
  else
    plant_line "bare-sibling" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- sibling_binary_present after the wave; no→yes when a consumer created it.
  local sl_eco="$st_root/sl-eco"
  mkdir -p "$sl_eco"
  printf 'fixture\n' > "$sl_eco/.ca_fixture"
  mk_stub "$st_root/sl-template" 0
  mk_consumer_block "$sl_eco" sib_late \
    'eigenscript work.eigs' \
    'mkdir -p ../EigenScript/src' \
    "cp \"$st_root/sl-template\" ../EigenScript/src/eigenscript"
  rec="$st_root/sl.record"
  if plant_sibling_late "$sh" "$sl_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "sibling-late" 0 "sibling_binary_present no→yes after the wave"
  else
    plant_line "sibling-late" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- variant (a): eigenscript-full in a called script AND as a token.
  local var_eco="$st_root/var-eco" stale_dir="$st_root/stale-bin" stale_log="$st_root/stale-full.log"
  mkdir -p "$var_eco" "$stale_dir"
  printf 'fixture\n' > "$var_eco/.ca_fixture"
  mk_consumer "$var_eco" script_user "bash run.sh"
  printf '%s\n' '#!/bin/sh' 'eigenscript-full work.eigs' > "$var_eco/script_user/run.sh"
  chmod +x "$var_eco/script_user/run.sh"
  mk_consumer "$var_eco" token_user "eigenscript-full work.eigs"
  printf '%s\n' '#!/bin/sh' \
    "printf 'stale:%s\\n' \"\$*\" >> \"$stale_log\"" \
    'echo stale-full-version; exit 0' > "$stale_dir/eigenscript-full"
  chmod +x "$stale_dir/eigenscript-full"
  : > "$stale_log"
  rec="$st_root/var-a.record"
  if plant_variant_missing "$sh" "$var_eco" "$st_root/stub-ok" "$rec" "$stale_log" "$stale_dir/eigenscript-full"; then
    plant_line "variant-missing" 0 "UNRUNNABLE|prereq:variant:eigenscript-full both rows, stale empty, log|"
  else
    plant_line "variant-missing" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- variant (b): --full stub → PASS cand_calls=1.
  rec="$st_root/var-b.record"
  if plant_variant_full "$sh" "$var_eco" "$st_root/stub-ok" "$rec" "$st_root/stub-ok"; then
    plant_line "variant-full" 0 "PASS cand_calls=1 with --full"
  else
    plant_line "variant-full" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- name in a .py and a Makefile; multi-hyphen; extensionless script.
  local py_eco="$st_root/py-eco" mf_eco="$st_root/mf-eco"
  local mh_eco="$st_root/mh-eco" ex_eco="$st_root/ex-eco"
  local stale_jit="$st_root/stale-jit.log" stale_gfx="$st_root/stale-gfx.log"
  local stale_http="$st_root/stale-http.log" stale_dbg="$st_root/stale-dbg.log"
  mkdir -p "$py_eco" "$mf_eco" "$mh_eco" "$ex_eco" "$stale_dir"
  printf 'fixture\n' > "$py_eco/.ca_fixture"
  printf 'fixture\n' > "$mf_eco/.ca_fixture"
  printf 'fixture\n' > "$mh_eco/.ca_fixture"
  printf 'fixture\n' > "$ex_eco/.ca_fixture"
  mk_consumer "$py_eco" py_user "eigenscript work.eigs"
  printf 'os.system("eigenscript-jit x")\n' > "$py_eco/py_user/run.py"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_jit\"" 'exit 0' > "$stale_dir/eigenscript-jit"
  chmod +x "$stale_dir/eigenscript-jit"
  : > "$stale_jit"
  rec="$st_root/var-py.record"
  if plant_variant_named "$sh" "$py_eco" "$st_root/stub-ok" "$rec" "$stale_jit" "$stale_dir/eigenscript-jit" py_user eigenscript-jit; then
    plant_line "variant-py" 0 "UNRUNNABLE|prereq:variant:eigenscript-jit from .py"
  else
    plant_line "variant-py" 1 "$LAST_PLANT_DETAIL"
  fi
  mk_consumer "$mf_eco" mf_user "eigenscript work.eigs"
  printf 'run:\n\teigenscript-gfx x\n' > "$mf_eco/mf_user/Makefile"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_gfx\"" 'exit 0' > "$stale_dir/eigenscript-gfx"
  chmod +x "$stale_dir/eigenscript-gfx"
  : > "$stale_gfx"
  rec="$st_root/var-mf.record"
  if plant_variant_named "$sh" "$mf_eco" "$st_root/stub-ok" "$rec" "$stale_gfx" "$stale_dir/eigenscript-gfx" mf_user eigenscript-gfx; then
    plant_line "variant-makefile" 0 "UNRUNNABLE|prereq:variant:eigenscript-gfx from Makefile"
  else
    plant_line "variant-makefile" 1 "$LAST_PLANT_DETAIL"
  fi
  mk_consumer "$mh_eco" mh_user "bash run.sh"
  printf '%s\n' '#!/bin/sh' 'eigenscript-http-model work.eigs' > "$mh_eco/mh_user/run.sh"
  chmod +x "$mh_eco/mh_user/run.sh"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_http\"" 'exit 0' > "$stale_dir/eigenscript-http-model"
  chmod +x "$stale_dir/eigenscript-http-model"
  : > "$stale_http"
  rec="$st_root/var-mh.record"
  if plant_variant_named "$sh" "$mh_eco" "$st_root/stub-ok" "$rec" "$stale_http" "$stale_dir/eigenscript-http-model" mh_user eigenscript-http-model; then
    plant_line "variant-multi-hyphen" 0 "UNRUNNABLE|prereq:variant:eigenscript-http-model"
  else
    plant_line "variant-multi-hyphen" 1 "$LAST_PLANT_DETAIL"
  fi
  mk_consumer "$ex_eco" ex_user "bash acceptance"
  printf '%s\n' '#!/bin/sh' 'eigenscript-debug work.eigs' > "$ex_eco/ex_user/acceptance"
  chmod +x "$ex_eco/ex_user/acceptance"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_dbg\"" 'exit 0' > "$stale_dir/eigenscript-debug"
  chmod +x "$stale_dir/eigenscript-debug"
  : > "$stale_dbg"
  rec="$st_root/var-ex.record"
  if plant_variant_named "$sh" "$ex_eco" "$st_root/stub-ok" "$rec" "$stale_dbg" "$stale_dir/eigenscript-debug" ex_user eigenscript-debug; then
    plant_line "variant-extensionless" 0 "UNRUNNABLE|prereq:variant:eigenscript-debug from extensionless"
  else
    plant_line "variant-extensionless" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- log tail on a FAIL row.
  local lt_eco="$st_root/lt-eco"
  mkdir -p "$lt_eco"
  printf 'fixture\n' > "$lt_eco/.ca_fixture"
  mk_consumer "$lt_eco" log_fail "eigenscript work.eigs; echo UNIQUE_FAIL_MARKER; false"
  rec="$st_root/lt.record"
  if plant_log_tail "$sh" "$lt_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "log-tail" 0 "FAIL row followed by log|log_fail|"
  else
    plant_line "log-tail" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- B2: declared consumer absent.
  local b2_eco="$st_root/b2-eco"
  mkdir -p "$b2_eco"
  printf 'fixture\n' > "$b2_eco/.ca_fixture"
  printf '%s\n' keep missing_one > "$b2_eco/.ca_expected"
  mk_consumer "$b2_eco" keep "eigenscript work.eigs"
  if CA_ECO="$b2_eco" plant_b2_missing_declared "$sh" "$b2_eco" "$st_root/stub-ok"; then
    plant_line "B2 missing-declared" 0 "FAIL naming missing_one in plan and record"
  else
    plant_line "B2 missing-declared" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- B3: 2 consumers, record floor 3 (lexical newest, not mtime).
  local b3_eco="$st_root/b3-eco"
  mkdir -p "$b3_eco/reports/consumer_acceptance"
  printf 'fixture\n' > "$b3_eco/.ca_fixture"
  printf '%s\n' a b > "$b3_eco/.ca_expected"
  mk_consumer "$b3_eco" a "eigenscript work.eigs"
  mk_consumer "$b3_eco" b "eigenscript work.eigs"
  printf '%s\n' 'row|x|v|PASS|0|0' 'row|y|v|PASS|0|0' 'row|z|v|PASS|0|0' \
    > "$b3_eco/reports/consumer_acceptance/2026-09-21-new.record"
  i=1
  while [ "$i" -le 99 ]; do
    printf 'row|old%02d|v|PASS|0|0\n' "$i"
    i=$((i + 1))
  done > "$b3_eco/reports/consumer_acceptance/2020-01-01-old.record"
  touch -d '2026-12-01' "$b3_eco/reports/consumer_acceptance/2020-01-01-old.record" 2>/dev/null \
    || touch -t 202612010000 "$b3_eco/reports/consumer_acceptance/2020-01-01-old.record"
  rec="$st_root/b3.record"
  if plant_b3_record_floor "$sh" "$b3_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "B3 record-floor" 0 "inventory 2 < record floor 3 (lexical, not mtime)"
  else
    plant_line "B3 record-floor" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- noglob: tests/*.eigs stays literal; variant loop also set -f.
  local ng_eco="$st_root/ng-eco" ng_cwd="$st_root/ng-cwd"
  mkdir -p "$ng_eco" "$ng_cwd/tests" "$ng_eco/glob_user/tests"
  printf 'fixture\n' > "$ng_eco/.ca_fixture"
  printf 'x\n' > "$ng_cwd/tests/a.eigs"
  printf 'x\n' > "$ng_eco/glob_user/tests/a.eigs"
  mk_consumer "$ng_eco" glob_user ""
  printf 'eigenscript tests/*.eigs\n' > "$ng_eco/glob_user/.ca_declared"
  mk_consumer "$ng_eco" glob_run "eigenscript *.eigs"
  if plant_noglob "$sh" "$ng_eco" "$ng_cwd" "$st_root/stub-ok"; then
    plant_line "noglob-split" 0 "literal tests/*.eigs, GAP; variant loop no glob"
  else
    plant_line "noglob-split" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- J2: signal between footer-write and rename.
  rec="$st_root/j2.record"
  if plant_j2_pause_rename "$sh" "$j_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "J2 pause-before-rename" 0 "INCOMPLETE exit 2, file and stdout agree, no .rewrite. leftover"
  else
    plant_line "J2 pause-before-rename" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- usage error does not rewrite a committed record.
  rec="$st_root/usage.record"
  if plant_usage_no_candidate "$sh" "$good_eco" "$rec"; then
    plant_line "usage-no-candidate" 0 "exit 2, sha256 unchanged, no .prev"
  else
    plant_line "usage-no-candidate" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- tmp lives next to the record.
  local td="$st_root/recdir"
  mkdir -p "$td"
  rec="$td/record"
  if plant_show_tmp "$sh" "$good_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "tmp-beside-record" 0 "record_tmp_dir equals record directory"
  else
    plant_line "tmp-beside-record" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- first-workflow-wins: tests.yml over bench.yml.
  local wf_eco="$st_root/wf-eco"
  mkdir -p "$wf_eco"
  printf 'fixture\n' > "$wf_eco/.ca_fixture"
  mk_consumer "$wf_eco" pref_user ""
  mkdir -p "$wf_eco/pref_user/.github/workflows"
  printf 'runCmd: eigenscript from-bench.eigs\n' > "$wf_eco/pref_user/.github/workflows/bench.yml"
  printf 'runCmd: eigenscript from-tests.eigs\n' > "$wf_eco/pref_user/.github/workflows/tests.yml"
  if plant_workflow_prefer "$sh" "$wf_eco"; then
    plant_line "workflow-prefer" 0 "tests.yml chosen over bench.yml"
  else
    plant_line "workflow-prefer" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- ambiguous workflows.
  local amb_eco="$st_root/amb-eco"
  mkdir -p "$amb_eco"
  printf 'fixture\n' > "$amb_eco/.ca_fixture"
  mk_consumer "$amb_eco" amb_user ""
  mkdir -p "$amb_eco/amb_user/.github/workflows"
  printf 'runCmd: eigenscript a.eigs\n' > "$amb_eco/amb_user/.github/workflows/a.yml"
  printf 'runCmd: eigenscript b.eigs\n' > "$amb_eco/amb_user/.github/workflows/b.yml"
  rec="$st_root/amb.record"
  if plant_workflow_ambiguous "$sh" "$amb_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "workflow-ambiguous" 0 "UNRUNNABLE|ambiguous-workflow:a.yml,b.yml"
  else
    plant_line "workflow-ambiguous" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- overlay partial retry does not nest.
  local ovp_eco="$st_root/ovp-eco" ovp_stub="$st_root/ovp-cand/src/eigenscript"
  mkdir -p "$ovp_eco" "$st_root/ovp-cand/src/data"
  printf 'fixture\n' > "$ovp_eco/.ca_fixture"
  printf 'x\n' > "$st_root/ovp-cand/src/data/x"
  mk_stub "$ovp_stub" 0
  mk_consumer_block "$ovp_eco" ovp_user \
    'if [ -e "$EIGS_DIR/src/data/data/x" ]; then exit 11; fi' \
    'if [ ! -e "$EIGS_DIR/src/data/x" ]; then exit 12; fi' \
    'eigenscript work.eigs'
  rec="$st_root/ovp.record"
  if plant_overlay_partial "$sh" "$ovp_eco" "$ovp_stub" "$rec"; then
    plant_line "overlay-partial" 0 "src/data/x present, not nested"
  else
    plant_line "overlay-partial" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- deriver self-test (call-site derivation, its own table).
  if python3 "$HERE/tools/_derive_variants.py" --selftest >/dev/null; then
    plant_line "derive-variants" 0 "SELFTEST: PASS (invocation shapes in, prose/JSON/URL/comment out)"
  else
    plant_line "derive-variants" 1 "deriver --selftest failed"
  fi

  # --- fix 1: the six REAL shapes measured against the ecosystem are NOT
  # prerequisites; the row runs.
  local prose_eco="$st_root/prose-eco"
  mkdir -p "$prose_eco"
  printf 'fixture\n' > "$prose_eco/.ca_fixture"
  mk_consumer "$prose_eco" prose_user "eigenscript work.eigs"
  printf 'COPY . /opt/eigenscript-src\n' > "$prose_eco/prose_user/Dockerfile"
  printf 'route to the eigenscript-aot-compiler-engineer skill\n' > "$prose_eco/prose_user/CLAUDE.md"
  printf '{"a": "eigenscript-probe.c", "b": "eigenscript-original.c",\n "c": "eigenscript-missing-reuse.c"}\n' \
    > "$prose_eco/prose_user/bench.json"
  printf '%s\n' '#!/bin/sh' \
    '# preflight validated eigenscript-full-from-env once' \
    'curl -L https://x/releases/eigenscript-full-linux-x86_64 -o /tmp/e' \
    "echo 'usage: screenshot.sh <eigenscript-gfx-binary> <harness.eigs>'" \
    > "$prose_eco/prose_user/notes.sh"
  chmod +x "$prose_eco/prose_user/notes.sh"
  rec="$st_root/prose.record"
  if plant_variant_prose "$sh" "$prose_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "variant-prose-not-declared" 0 "six real shapes excluded, row PASS, variants|prose_user|eigenscript"
  else
    plant_line "variant-prose-not-declared" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- fix 1 shape (c): an .eigs exec-family call IS an invocation.
  local eigs_eco="$st_root/eigs-eco" stale_eigs="$st_root/stale-eigs.log"
  mkdir -p "$eigs_eco"
  printf 'fixture\n' > "$eigs_eco/.ca_fixture"
  mk_consumer "$eigs_eco" eigs_user "eigenscript work.eigs"
  printf 'let r is exec_capture of ["eigenscript-eigs", "work.eigs"]\n' \
    > "$eigs_eco/eigs_user/driver.eigs"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_eigs\"" 'exit 0' > "$stale_dir/eigenscript-eigs"
  chmod +x "$stale_dir/eigenscript-eigs"
  rec="$st_root/var-eigs.record"
  if plant_variant_eigs_call "$sh" "$eigs_eco" "$st_root/stub-ok" "$rec" "$stale_eigs" "$stale_dir"; then
    plant_line "variant-eigs-call" 0 "UNRUNNABLE|prereq:variant:eigenscript-eigs from exec_capture"
  else
    plant_line "variant-eigs-call" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- fix 1b: a runtime-computed name is unreachable and FAILs by name.
  local comp_eco="$st_root/comp-eco" stale_jit2="$st_root/stale-jit2.log"
  mkdir -p "$comp_eco"
  printf 'fixture\n' > "$comp_eco/.ca_fixture"
  # The computed name is invoked from a `sh` script, not from the block
  # bash: command_not_found_handle is a bash feature, so only the sweep's
  # 127-shim can turn this into a named failure. (With the name reached
  # from the block shell both mechanisms fire and the sweep's transverse
  # row stops discriminating -- measured, round 4.)
  mk_consumer_block "$comp_eco" computed_user \
    'eigenscript work.eigs' \
    'sh ./compute.sh || true'
  printf '%s\n' 'V=jit' '"eigenscript-$V" work.eigs' \
    > "$comp_eco/computed_user/compute.sh"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_jit2\"" 'exit 0' > "$stale_dir/eigenscript-jit"
  chmod +x "$stale_dir/eigenscript-jit"
  rec="$st_root/var-computed.record"
  if plant_variant_computed "$sh" "$comp_eco" "$st_root/stub-ok" "$rec" "$stale_jit2" "$stale_dir"; then
    plant_line "variant-computed" 0 "FAIL|undeclared-variant:eigenscript-jit, stale never ran"
  else
    plant_line "variant-computed" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- fix 1b residual, PINNED: a path computed inside the checkout.
  local glob_eco="$st_root/glob-eco" stale_glob="$st_root/stale-glob.log"
  mkdir -p "$glob_eco"
  printf 'fixture\n' > "$glob_eco/.ca_fixture"
  mk_consumer_block "$glob_eco" glob_user \
    'for b in ./eigenscript-*; do "$b" work.eigs; done' \
    'true'
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_glob\"" 'exit 0' > "$st_root/stale-inside"
  chmod +x "$st_root/stale-inside"
  ln -sf "$st_root/stale-inside" "$glob_eco/glob_user/eigenscript-full"
  rec="$st_root/var-glob.record"
  if plant_variant_glob_residual "$sh" "$glob_eco" "$st_root/stub-ok" "$rec" "$stale_glob"; then
    plant_line "variant-glob-residual" 0 "path inside the checkout reaches the stale binary; row UNEXERCISED (residual pinned)"
  else
    plant_line "variant-glob-residual" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 4 fix 1: the CONFINED PATH FARM. The row's PATH is exactly
  # $SHIM:$FARM, so no inherited directory is on it. Discriminating row:
  # Fable r3's dot-PATH shape -- the harness inherits `.`, the consumer's
  # OWN checkout holds a stale eigenscript-jit, and with the inherited PATH
  # in the row `.` resolves inside the repo and the stale binary runs.
  local farm_eco="$st_root/farm-eco" farm_cwd="$st_root/farm-cwd"
  local stale_farm="$st_root/stale-farm.log"
  mkdir -p "$farm_eco" "$farm_cwd"
  printf 'fixture\n' > "$farm_eco/.ca_fixture"
  mk_consumer_block "$farm_eco" farm_dot \
    'V=jit' \
    'eigenscript-$V work.eigs || true' \
    'eigenscript work.eigs'
  mk_consumer_block "$farm_eco" farm_control \
    'python3 -c "print(1)" >/dev/null' \
    'sed -n 1p /dev/null' \
    'eigenscript work.eigs'
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_farm\"" 'exit 0' \
    > "$farm_eco/farm_dot/eigenscript-jit"
  chmod +x "$farm_eco/farm_dot/eigenscript-jit"
  rec="$st_root/farm.record"
  if plant_path_farm "$sh" "$farm_eco" "$st_root/stub-ok" "$rec" "$stale_farm" "$farm_cwd"; then
    plant_line "path-farm-confined" 0 "farm_dot FAIL|undeclared-variant:eigenscript-jit with \`.\` on the inherited PATH, stale never ran, farm_control PASS through the farm"
  else
    plant_line "path-farm-confined" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 4 fix 1b: a scratch HOME per row, so the ordinary CI idiom
  # `export PATH="$HOME/.local/bin:$PATH"` prepends an EMPTY directory.
  local home_eco="$st_root/home-eco" fake_home="$st_root/fake-home"
  local stale_home="$st_root/stale-home.log"
  mkdir -p "$home_eco" "$fake_home/.local/bin"
  printf 'fixture\n' > "$home_eco/.ca_fixture"
  mk_consumer_block "$home_eco" home_prepend \
    'export PATH="$HOME/.local/bin:$PATH"' \
    'V=jit' \
    'eigenscript-$V work.eigs || true' \
    'eigenscript work.eigs'
  mk_consumer_block "$home_eco" home_empty \
    'test ! -e "$HOME/.local/bin/eigenscript-jit"' \
    'eigenscript work.eigs'
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_home\"" 'exit 0' \
    > "$fake_home/.local/bin/eigenscript-jit"
  chmod +x "$fake_home/.local/bin/eigenscript-jit"
  rec="$st_root/home.record"
  if plant_home_scratch "$sh" "$home_eco" "$st_root/stub-ok" "$rec" "$stale_home" "$fake_home"; then
    plant_line "home-scratch" 0 "home_prepend FAIL|undeclared-variant:eigenscript-jit (the prepended \$HOME/.local/bin is empty), stale never ran, home_empty PASS"
  else
    plant_line "home-scratch" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 4: a computed name nothing covers is NOT FOUND, and that is
  # a named row failure, not a 127 the consumer can swallow.
  local nf_eco="$st_root/nf-eco"
  # The fixture name carries the RUN TOKEN, so no box can already have one.
  local nf_tok nf_name nf_decoy nf_decoy_log
  nf_tok="$(printf '%s' "$ST_TOKEN" | tr -cd 'a-z0-9')"
  [ -n "$nf_tok" ] || nf_tok="x0"
  nf_name="eigenscript-nf-$nf_tok"
  nf_decoy="$st_root/nf-decoy"
  nf_decoy_log="$st_root/stale-nf-decoy.log"
  mkdir -p "$nf_eco" "$nf_decoy"
  printf 'fixture\n' > "$nf_eco/.ca_fixture"
  mk_consumer_block "$nf_eco" nf_user \
    "V=nf-$nf_tok" \
    'eigenscript-$V work.eigs || true' \
    'eigenscript work.eigs'
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$nf_decoy_log\"" 'exit 0' \
    > "$nf_decoy/eigenscript-jit"
  chmod +x "$nf_decoy/eigenscript-jit"
  rec="$st_root/nf.record"
  if plant_not_found_variant "$sh" "$nf_eco" "$st_root/stub-ok" "$rec" "$nf_name" "$nf_decoy" "$nf_decoy_log"; then
    plant_line "not-found-variant" 0 "an uncovered computed name that resolves NOWHERE is FAIL|undeclared-variant:$nf_name, not a swallowed 127 -- with a decoy eigenscript-jit prepended to the harness PATH, which never ran"
  else
    plant_line "not-found-variant" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 5 fix 1: the farm holds EXEC WRAPPERS, so a tool runs AT ITS
  # ORIGINAL LOCATION. Astra r4: relocating a virtualenv's python3 into the
  # farm moved sys.prefix to /usr and its dependency vanished.
  local venv_eco="$st_root/venv-eco" venv_dir="$st_root/venv"
  local venv_marker="$st_root/venv.out" venv_site=""
  mkdir -p "$venv_eco"
  printf 'fixture\n' > "$venv_eco/.ca_fixture"
  if python3 -m venv --without-pip "$venv_dir" >/dev/null 2>&1 \
     && [ -x "$venv_dir/bin/python3" ] \
     && venv_site="$("$venv_dir/bin/python3" -c 'import sysconfig; print(sysconfig.get_path("purelib"))' 2>/dev/null)" \
     && [ -d "$venv_site" ]; then
    printf 'VALUE = "venv dependency loaded"\n' > "$venv_site/critic_dependency.py"
    mk_consumer_block "$venv_eco" venv_user \
      "python3 -c 'import sys,critic_dependency; print(critic_dependency.VALUE); print(\"prefix=\"+sys.prefix)' > $venv_marker" \
      'eigenscript work.eigs'
    rec="$st_root/venv.record"
    if plant_farm_exec_wrapper "$sh" "$venv_eco" "$st_root/stub-ok" "$rec" "$venv_dir" "$venv_marker"; then
      plant_line "farm-exec-wrapper" 0 "the row's python3 is the SELECTED virtualenv's: 'venv dependency loaded' and sys.prefix=$venv_dir INSIDE the harness, row PASS"
    else
      plant_line "farm-exec-wrapper" 1 "$LAST_PLANT_DETAIL"
    fi
  else
    say "plant farm-exec-wrapper: SKIP -- python3 -m venv --without-pip is unavailable here"
    ST_SKIP=$((ST_SKIP + 1))
  fi

  # --- round 5 fix 1, the RESIDUAL it buys, PINNED (Fable r4 p2): a farmed
  # inherited wrapper that resolves its OWN location execs the stale
  # eigenscript beside it. FIRES while that holds; red on purpose the day
  # an execve witness or a mount namespace closes it.
  local wrap_eco="$st_root/wrap-eco" wrapbin="$st_root/wrapbin"
  local stale_wrap="$st_root/stale-wrap.log"
  mkdir -p "$wrap_eco" "$wrapbin"
  printf 'fixture\n' > "$wrap_eco/.ca_fixture"
  printf '%s\n' '#!/bin/sh' "echo \"STALE-RAN \$0 \$*\" >> \"$stale_wrap\"" 'exit 0' \
    > "$wrapbin/eigenscript"
  chmod +x "$wrapbin/eigenscript"
  printf '%s\n' '#!/bin/sh' 'exec "$(dirname "$(readlink -f "$0")")/eigenscript" "$@"' \
    > "$wrapbin/run-eigs-real"
  chmod +x "$wrapbin/run-eigs-real"
  mk_consumer_block "$wrap_eco" wrap_user \
    'eigenscript work.eigs' \
    'run-eigs-real work.eigs'
  rec="$st_root/wrap.record"
  if plant_farm_wrapper_sibling "$sh" "$wrap_eco" "$st_root/stub-ok" "$rec" "$wrapbin" "$stale_wrap"; then
    plant_line "farm-wrapper-sibling" 0 "RESIDUAL PINNED: a farmed self-locating wrapper still execs the stale eigenscript beside it and the row reads PASS -- the price of running tools in place; closures (LD_PRELOAD execve witness, mount namespace) are deferred and named in the header"
  else
    plant_line "farm-wrapper-sibling" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 5 fix 6 (Astra r4 check 7): a farm that cannot be written is
  # exit 2 BY NAME, not path_farm=0 under VERDICT: PASS.
  local ffc_inject="$st_root/ffc-inject"
  mkdir -p "$ffc_inject"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'p=$(/usr/bin/mktemp "$@") || exit $?'
    printf '%s\n' 'case "$p" in */ca-run.*) /usr/bin/mkdir "$p/farm" 2>/dev/null && /usr/bin/chmod 555 "$p/farm";; esac'
    printf '%s\n' 'printf "%s\n" "$p"'
  } > "$ffc_inject/mktemp"
  chmod +x "$ffc_inject/mktemp"
  rec="$st_root/ffc.record"
  if plant_farm_fail_closed "$sh" "$good_eco" "$st_root/stub-ok" "$rec" "$ffc_inject"; then
    plant_line "farm-fail-closed" 0 "a read-only farm directory is exit 2 naming the farm, and the record carries no VERDICT: PASS and no row at all"
  else
    plant_line "farm-fail-closed" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 6 fix 3 (Fable r5 / Astra readonly-bin): a $SHIM directory
  # that cannot be WRITTEN is exit 2 BY NAME, not FAIL|127 cand_calls=0.
  local sfc_inject="$st_root/sfc-inject"
  mkdir -p "$sfc_inject"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'p=$(/usr/bin/mktemp "$@") || exit $?'
    printf '%s\n' 'case "$p" in */ca-run.*) /usr/bin/mkdir "$p/bin" 2>/dev/null && /usr/bin/chmod 555 "$p/bin";; esac'
    printf '%s\n' 'printf "%s\n" "$p"'
  } > "$sfc_inject/mktemp"
  chmod +x "$sfc_inject/mktemp"
  rec="$st_root/sfc.record"
  if plant_shim_fail_closed "$sh" "$good_eco" "$st_root/stub-ok" "$rec" "$sfc_inject"; then
    plant_line "shim-fail-closed" 0 "an unwritable \$SHIM is exit 2 naming the shim, and the record carries no VERDICT: PASS and no row at all"
  else
    plant_line "shim-fail-closed" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 5 fix 2 (Fable r4 check 3): a consumer PATH edit that adds an
  # absolute directory existing on this box is FAIL BY NAME before the row.
  local pe_eco="$st_root/pe-eco" pe_absbin="$st_root/pe-absbin"
  local stale_pe="$st_root/stale-pe.log" pe_real=""
  mkdir -p "$pe_eco" "$pe_absbin"
  printf 'fixture\n' > "$pe_eco/.ca_fixture"
  printf '%s\n' '#!/bin/sh' "echo \"STALE-RAN \$0 \$*\" >> \"$stale_pe\"" 'exit 0' \
    > "$pe_absbin/eigenscript"
  chmod +x "$pe_absbin/eigenscript"
  # The exact shape Fable measured: the developer's REAL ~/.local/bin by
  # absolute path. Under a dropped self-test that home does not exist, so
  # fall back to a directory that always does -- the CLAIM is "an absolute
  # directory on this box outside the row's scratch", not "$HOME".
  pe_real="${REAL_HOME:-$HOME}/.local/bin"
  [ -d "$pe_real" ] || pe_real="/usr/bin"
  mk_consumer_block "$pe_eco" pe_absbin \
    "export PATH=$pe_absbin:\$PATH" \
    'eigenscript work.eigs'
  mk_consumer_block "$pe_eco" pe_realhome \
    "export PATH=$pe_real:\$PATH" \
    'eigenscript work.eigs'
  mk_consumer_block "$pe_eco" pe_home \
    'export PATH="$HOME/.local/bin:$PATH"' \
    'eigenscript work.eigs'
  # --- ROUND 6: one consumer per shape Fable r5 walked through. At ba74be3
  # every one of these read PASS while the stale eigenscript in $pe_absbin
  # RAN; the substring rule refuses all six by name.
  mk_consumer_block "$pe_eco" pe_env \
    "env PATH=$pe_absbin:\$PATH eigenscript work.eigs"
  mk_consumer_block "$pe_eco" pe_execenv \
    "exec env PATH=$pe_absbin:\$PATH eigenscript work.eigs"
  mk_consumer_block "$pe_eco" pe_bashc \
    "bash -c 'PATH=$pe_absbin:\$PATH eigenscript work.eigs'"
  mk_consumer_block "$pe_eco" pe_heredoc \
    'bash <<EOF' \
    "export PATH=$pe_absbin:\$PATH" \
    'eigenscript work.eigs' \
    'EOF'
  # A Makefile TOP-LEVEL `export PATH :=` sets every recipe's PATH; round 5
  # read only TAB-indented recipe lines.
  mk_consumer_block "$pe_eco" pe_make 'make -s stale'
  printf 'export PATH := %s:$(PATH)\nstale:\n\teigenscript work.eigs\n' \
    "$pe_absbin" > "$pe_eco/pe_make/Makefile"
  # `~user` resolves from the PASSWD DATABASE, not from $HOME. Pick a user
  # whose home exists on THIS box (root first, then whoever is running the
  # self-test), so the row works under the dropped re-run as well.
  local pe_tilde_user="" pe_tilde_dir="" _u _h
  for _u in root "$(id -un 2>/dev/null || true)"; do
    [ -n "$_u" ] || continue
    _h="$(getent passwd "$_u" 2>/dev/null | cut -d: -f6)"
    [ -n "$_h" ] || continue
    [ -d "$_h" ] || continue
    case "$_h" in /) continue ;; esac
    pe_tilde_user="$_u"
    pe_tilde_dir="$_h"
    break
  done
  if [ -n "$pe_tilde_user" ]; then
    mk_consumer_block "$pe_eco" pe_tilde \
      "export PATH=~$pe_tilde_user:\$PATH" \
      'eigenscript work.eigs'
  fi
  # --- ROUND 7 (Astra r6 check 2): the two shapes whose WRITTEN form sits
  # under the checkout and whose RESOLVED form is outside it. At c53429f
  # both read PASS while the stale eigenscript in $pe_absbin RAN, because
  # the written form alone bought the allowance.
  mk_consumer_block "$pe_eco" pe_dotdot \
    "export PATH=$pe_eco/pe_dotdot/../../${pe_absbin##*/}:\$PATH" \
    'eigenscript work.eigs'
  mk_consumer_block "$pe_eco" pe_symlink \
    "export PATH=$pe_eco/pe_symlink/bin-link:\$PATH" \
    'eigenscript work.eigs'
  ln -sfn "$pe_absbin" "$pe_eco/pe_symlink/bin-link"
  # The CONTROLS for the same fix: resolving must not refuse a directory
  # that really is inside the checkout. `./bin` is the relative spelling;
  # pe_inrepo is the absolute spelling of the same thing, and it is the row
  # that goes red if the checkout side of the comparison is ever left
  # unresolved while the component side is resolved.
  mk_consumer_block "$pe_eco" pe_relbin \
    'export PATH=./bin:$PATH' \
    'eigenscript work.eigs'
  mkdir -p "$pe_eco/pe_relbin/bin"
  mk_consumer_block "$pe_eco" pe_inrepo \
    "export PATH=$pe_eco/pe_inrepo/bin:\$PATH" \
    'eigenscript work.eigs'
  mkdir -p "$pe_eco/pe_inrepo/bin"
  rec="$st_root/pe.record"
  if plant_path_edit_absolute "$sh" "$pe_eco" "$st_root/stub-ok" "$rec" "$pe_absbin" "$stale_pe" "$pe_real" "$pe_tilde_dir"; then
    plant_line "path-edit-absolute" 0 "pe_absbin, pe_realhome, Fable r5's six shapes (pe_env, pe_execenv, pe_bashc, pe_heredoc, pe_make, pe_tilde) and Astra r6's two escapes (pe_dotdot through '..', pe_symlink through a link in the checkout) are FAIL|path-edit:<resolved dir> by name with a log| preflight line, the stale binary never ran, and the in-checkout controls pe_home, pe_relbin and pe_inrepo still PASS"
  else
    plant_line "path-edit-absolute" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 5 fix 2, the RESIDUAL it leaves, PINNED: a component the
  # scanner cannot see because the consumer computes it at run time.
  local pec_eco="$st_root/pec-eco" stale_pec="$st_root/stale-pec.log"
  local pec_bin="$st_root/pec-bin"
  mkdir -p "$pec_eco" "$pec_bin"
  printf 'fixture\n' > "$pec_eco/.ca_fixture"
  printf '%s\n' '#!/bin/sh' "echo \"STALE-RAN \$0 \$*\" >> \"$stale_pec\"" 'exit 0' \
    > "$pec_bin/eigenscript"
  chmod +x "$pec_bin/eigenscript"
  mk_consumer_block "$pec_eco" pe_computed \
    'eigenscript work.eigs' \
    "D=$pec_bin" \
    'export PATH="$D:$PATH"' \
    'eigenscript work.eigs'
  rec="$st_root/pec.record"
  if plant_path_edit_computed "$sh" "$pec_eco" "$st_root/stub-ok" "$rec" "$stale_pec"; then
    plant_line "path-edit-computed" 0 "RESIDUAL PINNED: PATH=\"\$D:\$PATH\" is not a literal, the scanner cannot see it, and the stale binary is reached -- the day the scanner resolves runtime values this plant goes red on purpose"
  else
    plant_line "path-edit-computed" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 5 fix 4 (Fable r4 check 4b): the scratch HOME must not drop
  # the tool CACHES. A farmed `go` in the row names the REAL module cache.
  local go_eco="$st_root/go-eco" go_marker="$st_root/go.out" go_bin=""
  mkdir -p "$go_eco"
  printf 'fixture\n' > "$go_eco/.ca_fixture"
  if command -v go >/dev/null 2>&1; then
    go_bin="$(dirname "$(command -v go)")"
  elif [ -x "${REAL_HOME:-$HOME}/go-sdk/go/bin/go" ]; then
    go_bin="${REAL_HOME:-$HOME}/go-sdk/go/bin"
  fi
  if [ -n "$go_bin" ]; then
    mk_consumer_block "$go_eco" go_user \
      "go env GOMODCACHE > $go_marker" \
      'eigenscript work.eigs'
    rec="$st_root/go.record"
    if plant_env_passthrough_go "$sh" "$go_eco" "$st_root/stub-ok" "$rec" "$go_marker" "$go_bin"; then
      plant_line "env-passthrough-go" 0 "a farmed go inside the row prints the REAL module cache, not one under the scratch HOME, and env_passthrough= names it"
    else
      plant_line "env-passthrough-go" 1 "$LAST_PLANT_DETAIL"
    fi
  else
    say "plant env-passthrough-go: SKIP -- no go on PATH and no ~/go-sdk/go/bin/go"
    ST_SKIP=$((ST_SKIP + 1))
  fi

  # --- round 5 fix 5 (Fable r4 check 6, Astra r4 check 6): the trust root
  # of the dropped self-test is the drop TOOL the harness chooses.
  if plant_drop_trust_root "$sh" "$nf_eco"; then
    plant_line "drop-trust-root" 0 "$LAST_PLANT_DETAIL"
  else
    plant_line "drop-trust-root" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 4 fix 2: an unusable $TMPDIR is a FAIL-CLOSED by name.
  rec="$st_root/scratch-fc.record"
  if plant_scratch_fail_closed "$sh" "$good_eco" "$st_root/stub-ok" "$rec" "$st_root"; then
    plant_line "scratch-fail-closed" 0 "exit 2 naming the unusable TMPDIR, previous record bytes unchanged, no eigenscript* created in /usr/bin /bin /usr/local/bin \$HOME/.local/bin"
  else
    plant_line "scratch-fail-closed" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 4 fix 3: the overlay must not hand out sibling binaries.
  local twin_eco="$st_root/twin-eco" twin_tree="$st_root/twin-cand"
  local stale_twin="$st_root/stale-twin.log"
  mkdir -p "$twin_eco" "$twin_tree/src"
  printf 'fixture\n' > "$twin_eco/.ca_fixture"
  mk_stub "$twin_tree/src/eigenscript" 0
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_twin\"" 'exit 0' \
    > "$twin_tree/src/eigenscript-full"
  chmod +x "$twin_tree/src/eigenscript-full"
  mk_consumer_block "$twin_eco" twin_user \
    '"$EIGS_DIR/src/eigenscript-full" work.eigs || true' \
    'eigenscript work.eigs'
  rec="$st_root/twin.record"
  if plant_overlay_variant "$sh" "$twin_eco" "$twin_tree/src/eigenscript" "$rec" "$stale_twin"; then
    plant_line "overlay-variant-shim" 0 "the copied sibling eigenscript-full never runs; row FAIL|undeclared-variant:eigenscript-full"
  else
    plant_line "overlay-variant-shim" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- round 4 fix 4: the dropped copy announces the sha of what RAN.
  if plant_drop_sha "$sh" "$st_root/dropsha"; then
    plant_line "drop-sha-readback" 0 "$LAST_PLANT_DETAIL"
  else
    plant_line "drop-sha-readback" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- fix 5: a folded scalar's more-indented line is a COMMAND.
  local fold_eco="$st_root/fold-eco"
  mkdir -p "$fold_eco/fold_user/.devcontainer" "$fold_eco/fold_user/.git" \
           "$fold_eco/fold_user/.github/workflows"
  printf 'fixture\n' > "$fold_eco/.ca_fixture"
  printf 'ARG EIGS_REF=v0.43.0\n' > "$fold_eco/fold_user/.devcontainer/Dockerfile"
  printf '%s\n' 'runCmd: >' '  eigenscript work.eigs' '    false' '  echo accepted' \
    > "$fold_eco/fold_user/.github/workflows/ci.yml"
  rec="$st_root/fold.record"
  if plant_folded_commands "$sh" "$fold_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "folded-more-indented-commands" 0 "three commands, block exits 1, row FAIL"
  else
    plant_line "folded-more-indented-commands" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- fix 6: only a DATED record file is a floor; a stray is a FAIL.
  local stray_eco="$st_root/stray-eco"
  mkdir -p "$stray_eco/reports/consumer_acceptance"
  printf 'fixture\n' > "$stray_eco/.ca_fixture"
  printf '%s\n' sa sb > "$stray_eco/.ca_expected"
  mk_consumer "$stray_eco" sa "eigenscript work.eigs"
  mk_consumer "$stray_eco" sb "eigenscript work.eigs"
  printf '%s\n' 'row|sa|v|PASS|0|0' 'row|sb|v|PASS|0|0' \
    > "$stray_eco/reports/consumer_acceptance/2026-09-21-ok.record"
  rec="$st_root/stray-low.record"
  if plant_record_stray "$sh" "$stray_eco" "$st_root/stub-ok" "$rec" smoke.record 1; then
    plant_line "record-stray-lowers" 0 "non-dated smoke.record (1 row) is a FAIL by name, not a lower floor"
  else
    plant_line "record-stray-lowers" 1 "$LAST_PLANT_DETAIL"
  fi
  rec="$st_root/stray-high.record"
  if plant_record_stray "$sh" "$stray_eco" "$st_root/stub-ok" "$rec" zzz.record 7; then
    plant_line "record-stray-raises" 0 "non-dated zzz.record (7 rows) is a FAIL by name, not a higher floor"
  else
    plant_line "record-stray-raises" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- fix 7: a plant cannot discard a diagnostic.
  rec="$st_root/unbound.record"
  if plant_unbound_capture "$sh" "$c_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "unbound-capture" 0 "$LAST_PLANT_DETAIL"
  else
    plant_line "unbound-capture" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- fix 4: plants + skipped is pinned to a declared constant.
  if plant_plant_total "$sh"; then
    plant_line "plant-total-accounting" 0 "$LAST_PLANT_DETAIL"
  else
    plant_line "plant-total-accounting" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- plant-of-plant: a mutant that exits 7 is BROKEN-MUTANT, not SILENT.
  local cr_md="$st_root/mutants/crash-early" cr_mutant cr_rec
  cr_rec="$st_root/crash.record"
  if ! prep_mutant "$cr_md" crash-early; then
    plant_line "broken-mutant-class" 1 "crash-early mutation did not land"
  else
    cr_mutant="$cr_md/tools/consumer_acceptance.sh"
    plant_early_stop "$cr_mutant" "$es_eco" "$st_root/stub-ok" "$cr_rec" || true
    if [ "$(mutant_not_fires_kind)" = BROKEN-MUTANT ]; then
      plant_line "broken-mutant-class" 0 "exit-7 mutant is BROKEN-MUTANT, not SILENT"
    else
      plant_line "broken-mutant-class" 1 "exit-7 mutant classified as $(mutant_not_fires_kind)"
    fi
  fi

  # --- transversality: gut each guard, require its plant SILENT.
  say ""
  say "transverse: gut each guard, require its plant SILENT (and intact FIRES)"

  run_named_plant() {
    local fn="$1" script="$2" eco="$3" rec="$4" extra="${5:-}"
    case "$fn" in
      early-stop)       plant_early_stop "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      empty-inventory)  plant_empty_inventory "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      missing-command)  plant_missing_command "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      skip-no-reason)   plant_skip_no_reason "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      plan-gap)         CA_ECO="$eco" plant_plan_gap "$script" "$eco" ;;
      trailing-verdict) plant_trailing_verdict "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      prescan-int)      plant_prescan_int "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      stale-unwritable) plant_stale_unwritable "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      footer-signal)    plant_footer_signal "$script" "$eco" "$st_root/stub-ok" "$rec" "$extra" ;;
      timeout-zero)     plant_timeout_zero "$script" "$eco" "$st_root/stub-ok" "$rec" 00 ;;
      pipefail)         plant_pipefail "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      scratch-cleanup)  plant_scratch_cleanup "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      record-busy)      plant_record_busy "$script" "$n_eco_a" "$n_eco_b" "$st_root/stub-ok" "$st_root/stub-bad" "$rec" ;;
      foreign-record)   plant_foreign_record "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      fail-footer)      plant_fail_footer "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      stdout-hup)       plant_footer_signal "$script" "$eco" "$st_root/stub-ok" "$rec" "$extra" ;;
      unexercised)      plant_unexercised "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      tree-consumer)    plant_tree_consumer "$script" "$eco" "$extra" "$rec" ;;
      declared-missing) CA_ECO="$eco" plant_declared_missing "$script" "$eco" ;;
      prereq-missing)   plant_prereq_missing "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      forged-counter)   plant_forged_counter "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      version-only)     plant_version_only "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      swallowed)        plant_swallowed "$script" "$eco" "$st_root/stub-bad" "$rec" ;;
      overlay-write)    plant_overlay_write "$script" "$eco" "$extra" "$rec" ;;
      probe-not-attributed) plant_probe_not_attributed "$script" "$eco" "${extra:-$st_root/stub-gfx}" "$rec" ;;
      interruption)     plant_interruption "$script" "$eco" "$st_root/stub-ok" "$rec" TERM ;;
      bin-routing)      plant_bin_routing "$script" "$eco" "$extra" "$rec" ;;
      gfx-prereq)       plant_gfx_prereq "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      clobber-symlink)  plant_clobber_symlink "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      variant-missing)  plant_variant_missing "$script" "$eco" "$st_root/stub-ok" "$rec" "$stale_log" "$stale_dir/eigenscript-full" ;;
      log-tail)         plant_log_tail "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      missing-declared) CA_ECO="$eco" plant_b2_missing_declared "$script" "$eco" "$st_root/stub-ok" ;;
      noglob-split)     plant_noglob "$script" "$eco" "$ng_cwd" "$st_root/stub-ok" ;;
      record-floor)     plant_b3_record_floor "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      pause-before-rename) plant_j2_pause_rename "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      usage-no-candidate) plant_usage_no_candidate "$script" "$eco" "$rec" ;;
      tmp-beside-record) plant_show_tmp "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      workflow-prefer)  plant_workflow_prefer "$script" "$eco" ;;
      overlay-partial)  plant_overlay_partial "$script" "$eco" "$extra" "$rec" ;;
      variant-prose)    plant_variant_prose "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      variant-computed) plant_variant_computed "$script" "$eco" "$st_root/stub-ok" "$rec" "$st_root/stale-jit2.log" "$stale_dir" ;;
      record-stray)     plant_record_stray "$script" "$eco" "$st_root/stub-ok" "$rec" smoke.record 1 ;;
      folded-commands)  plant_folded_commands "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      unbound-capture)  plant_unbound_capture "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      path-farm)        plant_path_farm "$script" "$eco" "$st_root/stub-ok" "$rec" "$st_root/stale-farm.log" "$st_root/farm-cwd" ;;
      home-scratch)     plant_home_scratch "$script" "$eco" "$st_root/stub-ok" "$rec" "$st_root/stale-home.log" "$st_root/fake-home" ;;
      not-found-variant) plant_not_found_variant "$script" "$eco" "$st_root/stub-ok" "$rec" "$nf_name" "$nf_decoy" "$nf_decoy_log" ;;
      farm-exec-wrapper) plant_farm_exec_wrapper "$script" "$eco" "$st_root/stub-ok" "$rec" "$venv_dir" "$venv_marker" ;;
      farm-fail-closed)  plant_farm_fail_closed "$script" "$eco" "$st_root/stub-ok" "$rec" "$ffc_inject" ;;
      path-edit-absolute) plant_path_edit_absolute "$script" "$eco" "$st_root/stub-ok" "$rec" "$pe_absbin" "$stale_pe" "$pe_real" "$pe_tilde_dir" ;;
      shim-fail-closed)  plant_shim_fail_closed "$script" "$eco" "$st_root/stub-ok" "$rec" "$sfc_inject" ;;
      env-passthrough-go) plant_env_passthrough_go "$script" "$eco" "$st_root/stub-ok" "$rec" "$go_marker" "$go_bin" ;;
      drop-trust-root)   plant_drop_trust_root "$script" "$eco" ;;
      scratch-fail-closed) plant_scratch_fail_closed "$script" "$eco" "$st_root/stub-ok" "$rec" "$st_root" ;;
      overlay-variant)  plant_overlay_variant "$script" "$eco" "$extra" "$rec" "$st_root/stale-twin.log" ;;
      drop-sha)         plant_drop_sha "$script" "$st_root/dropsha-t" ;;
      outer-tmp-decoy)  plant_outer_tmp_decoy "$script" "$outer_tmp" "$st_root" "$ST_TOKEN" ;;
      plant-total)      plant_plant_total "$script" ;;
      *)                return 2 ;;
    esac
  }

  transverse_one() {
    local kind="$1" plant="$2" eco="$3" rec_prefix="$4"
    local extra="${5:-}"
    local md mutant rec_i rec_m
    md="$st_root/mutants/$kind"
    rec_i="$st_root/${rec_prefix}-intact.record"
    rec_m="$st_root/${rec_prefix}-mutant.record"
    rm -f "$rec_i" "$rec_m"
    local intact=SILENT mutant_st=BROKEN intact_rc=0 intact_detail=""
    run_named_plant "$plant" "$sh" "$eco" "$rec_i" "$extra"
    intact_rc=$?
    # CA-GUARD:transverse-intact-witness
    # An intact arm that does NOT fire is a red row the reader cannot act
    # on unless it says WHY (round 5: `intact=SILENT` on scratch-fail-closed
    # appeared in 1 run of 3 and named nothing). Capture the plant's own
    # detail BEFORE the mutant run overwrites it.
    intact_detail="${LAST_PLANT_DETAIL:-none}"
    # CA-GUARD:end-transverse-intact-witness
    if [ "$intact_rc" -eq 0 ]; then
      intact=FIRES
    elif [ "$intact_rc" -eq 3 ]; then
      # The plant cannot be planted in this environment and said so by
      # name. A skipped row is counted, never a silent OK.
      say "transverse $kind / $plant: SKIP -- $LAST_PLANT_DETAIL"
      ST_TV_SKIP=$((ST_TV_SKIP + 1))
      return
    else
      intact=SILENT
    fi
    if ! prep_mutant "$md" "$kind"; then
      say "transverse $kind / $plant: intact=$intact mutant=BROKEN -- mutation did not land; intact_detail=$intact_detail"
      ST_FAIL=1
      return
    fi
    mutant="$md/tools/consumer_acceptance.sh"
    # A MUTANT is deliberately broken, so its diagnostics must not land in
    # the capture file the no-unbound-variable check reads: that check is
    # about the production script under its own plants.
    local prev_cap="${CA_STDERR_CAP:-}"
    export CA_STDERR_CAP="$st_root/mutant-stderr.cap"
    # Sanity-start: the mutant must produce a VERDICT line on plan.
    local start_out
    start_out="$(CA_ECO="$good_eco" "$mutant" plan 2>&1)" || true
    if ! grep -q '^VERDICT:' <<< "$start_out"; then
      export CA_STDERR_CAP="$prev_cap"
      say "transverse $kind / $plant: intact=$intact mutant=BROKEN -- mutant plan emitted no VERDICT"
      ST_FAIL=1
      return
    fi
    ST_IN_MUTANT=1
    if run_named_plant "$plant" "$mutant" "$eco" "$rec_m" "$extra"; then
      mutant_st=FIRES
    else
      mutant_st="$(mutant_not_fires_kind)"
    fi
    ST_IN_MUTANT=0
    export CA_STDERR_CAP="$prev_cap"
    # Success / side-effect plants: gutting the guard makes the plant
    # condition fail, but the mutant often does not print VERDICT: PASS
    # (UNEXERCISED, FAIL after a refused append, etc.). The transverse
    # is that the plant no longer FIRE.
    case "$plant" in
      tree-consumer|bin-routing|overlay-write|clobber-symlink|overlay-partial|usage-no-candidate|log-tail|variant-missing|record-floor|variant-prose|unbound-capture|plant-total|home-scratch|scratch-fail-closed|drop-sha|outer-tmp-decoy|farm-exec-wrapper|farm-fail-closed|shim-fail-closed|path-edit-absolute|drop-trust-root)
        if [ "$intact" = FIRES ] && [ "$mutant_st" != FIRES ]; then
          say "transverse $kind / $plant: intact=FIRES mutant=$mutant_st  OK"
        else
          say "transverse $kind / $plant: intact=$intact mutant=$mutant_st  FAIL (want intact FIRES, mutant not FIRES) intact_detail=$intact_detail"
          ST_FAIL=1
        fi
        return
        ;;
      interruption)
        # finish_incomplete no-op: no stdout VERDICT: INCOMPLETE (plant
        # SILENT) but the record header still says INCOMPLETE, so the
        # mutant is not VERDICT: PASS.
        if [ "$intact" = FIRES ] && [ "$mutant_st" != FIRES ]; then
          say "transverse $kind / $plant: intact=FIRES mutant=SILENT  OK"
        else
          say "transverse $kind / $plant: intact=$intact mutant=$mutant_st  FAIL (want intact FIRES, mutant SILENT) intact_detail=$intact_detail"
          ST_FAIL=1
        fi
        return
        ;;
    esac
    # Trailing-text is inverted: the "guard" is the exact-line check, the
    # plant IS the extra-mutant. Intact production has no extra text so the
    # trailing-text plant is SILENT there; the extra-mutant must FIRE.
    if [ "$plant" = "trailing-verdict" ]; then
      if [ "$intact" = SILENT ] && [ "$mutant_st" = FIRES ]; then
        say "transverse $kind / $plant: intact=SILENT (no extra text) mutant=FIRES  OK"
      else
        say "transverse $kind / $plant: intact=$intact mutant=$mutant_st  FAIL (want intact SILENT, mutant FIRES)"
        ST_FAIL=1
      fi
      return
    fi
    if [ "$mutant_st" = BROKEN-MUTANT ]; then
      say "transverse $kind / $plant: intact=$intact mutant=BROKEN-MUTANT  FAIL (mutant did not print VERDICT: PASS; rc=${LAST_PLANT_RC:-} rec=${LAST_PLANT_REC:-} recV=$(grep '^VERDICT:' "${LAST_PLANT_REC:-/dev/null}" 2>/dev/null | tr '\n' '|') detail=${LAST_PLANT_DETAIL:-} out=$(printf '%s\n' "${LAST_PLANT_OUT:-}" | tail -8 | tr '\n' '|'))"
      ST_FAIL=1
      return
    fi
    if [ "$intact" = FIRES ] && [ "$mutant_st" = SILENT ]; then
      say "transverse $kind / $plant: intact=FIRES mutant=SILENT  OK"
    else
      say "transverse $kind / $plant: intact=$intact mutant=$mutant_st  FAIL (want intact FIRES, mutant SILENT) intact_detail=$intact_detail"
      ST_FAIL=1
    fi
  }

  transverse_one finish-incomplete       interruption     "$d_eco"    t-d
  transverse_one examined-eq             early-stop       "$es_eco"   t-es
  transverse_one nonempty                empty-inventory  "$z_eco"    t-z
  transverse_one missing-command         missing-command  "$m_eco"    t-m
  transverse_one skip-reason             skip-no-reason   "$sr_eco"   t-sr
  transverse_one exact-verdict           trailing-verdict "$good_eco" t-tv
  transverse_one plan-gap                plan-gap         "$plan_eco" t-pg
  transverse_one traps-after-scan        prescan-int      "$h_eco"    t-h
  transverse_one invalidate-fail-closed  stale-unwritable "$i_eco"    t-i
  transverse_one finished-after-rename   footer-signal    "$j_eco"    t-j "$j_shim"
  transverse_one timeout-zero            timeout-zero     "$tz_eco"   t-k
  transverse_one no-pipefail             pipefail         "$l_eco"    t-l
  transverse_one no-cleanup              scratch-cleanup  "$good_eco" t-sc
  transverse_one record-lock             record-busy      "$n_eco_a"  t-n
  transverse_one append-owned            foreign-record   "$o_eco"    t-o
  transverse_one die-record-flag         fail-footer      "$p_eco"    t-p
  transverse_one stdout-verdict          stdout-hup       "$j_eco"    t-q "$j_shim"
  transverse_one cand-calls              unexercised      "$r_eco"    t-r
  transverse_one eigs-dir                tree-consumer    "$s_eco"    t-s "$s_stub"
  transverse_one declared-file           declared-missing "$t_eco"    t-t
  transverse_one prereq                  prereq-missing   "$u_eco"    t-u
  transverse_one private-log             forged-counter   "$v_eco"    t-v
  transverse_one nontrivial-calls        version-only     "$w_eco"    t-w
  transverse_one swallowed               swallowed        "$x_eco"    t-x
  transverse_one overlay-copy            overlay-write    "$y_eco"    t-y "$y_stub"
  transverse_one probe-not-attributed    probe-not-attributed "$z_idle_eco" t-zidle "$st_root/stub-gfx"
  transverse_one eigenscript-bin         bin-routing      "$aa_eco"   t-aa "$aa_stub"
  transverse_one gfx-prereq              gfx-prereq       "$ab_eco"   t-ab
  transverse_one clobber-no-follow       clobber-symlink  "$ac_eco"   t-ac
  transverse_one variant-mask            variant-missing  "$var_eco"  t-var
  transverse_one log-tail                log-tail         "$lt_eco"   t-lt
  transverse_one expected-floor          missing-declared "$b2_eco"   t-b2
  transverse_one record-floor            record-floor     "$b3_eco"   t-b3
  transverse_one noglob-split            noglob-split     "$ng_eco"   t-ng
  transverse_one pause-before-rename     pause-before-rename "$j_eco" t-j2
  transverse_one usage-before-record     usage-no-candidate "$good_eco" t-use
  transverse_one tmp-beside-record       tmp-beside-record "$good_eco" t-tmp
  transverse_one workflow-prefer         workflow-prefer  "$wf_eco"   t-wf
  transverse_one overlay-retry-rm        overlay-partial  "$ovp_eco"  t-ovp "$ovp_stub"
  transverse_one any-token               variant-prose    "$prose_eco" t-prose
  transverse_one path-variant-sweep      variant-computed "$comp_eco" t-vcs
  transverse_one undeclared-variant      variant-computed "$comp_eco" t-vcu
  transverse_one record-dated-name       record-stray     "$stray_eco" t-rs
  transverse_one folded-more-indented    folded-commands  "$fold_eco" t-fc
  transverse_one stderr-capture          unbound-capture  "$c_eco"    t-uc
  transverse_one plant-total             plant-total      "$good_eco" t-pt
  transverse_one path-farm               path-farm        "$farm_eco" t-farm
  transverse_one home-scratch            home-scratch     "$home_eco" t-home
  transverse_one not-found-guard         not-found-variant "$nf_eco"  t-nf
  transverse_one scratch-fail-closed     scratch-fail-closed "$good_eco" t-sfc
  transverse_one overlay-variant-shim    overlay-variant  "$twin_eco" t-twin "$twin_tree/src/eigenscript"
  transverse_one drop-sha-readback       drop-sha         "$good_eco" t-dsha
  transverse_one outer-tmp-token         outer-tmp-decoy  "$good_eco" t-otd
  # --- round 5
  if [ -d "$venv_dir/bin" ]; then
    transverse_one farm-exec-wrapper     farm-exec-wrapper "$venv_eco" t-few
  else
    say "transverse farm-exec-wrapper / farm-exec-wrapper: SKIP -- no venv fixture"
    ST_TV_SKIP=$((ST_TV_SKIP + 1))
  fi
  transverse_one farm-fail-closed        farm-fail-closed "$good_eco" t-ffc
  transverse_one path-edit-scan          path-edit-absolute "$pe_eco" t-pea
  # --- round 6
  transverse_one shim-fail-closed        shim-fail-closed "$good_eco" t-shim
  # Gut the SUBSTRING rule back to round 5's positional regex: the `env`
  # row (and its five siblings) goes SILENT -- the exact hole Fable r5
  # measured, so the class change is what holds the plant up.
  transverse_one path-edit-substring     path-edit-absolute "$pe_eco" t-pes
  transverse_one drop-fixture-gate       drop-trust-root  "$nf_eco"   t-dtr
  if [ -n "$go_bin" ]; then
    transverse_one env-passthrough       env-passthrough-go "$go_eco" t-epg
  else
    say "transverse env-passthrough / env-passthrough-go: SKIP -- no go"
    ST_TV_SKIP=$((ST_TV_SKIP + 1))
  fi

  # --- scratch hygiene: the self-test writes nothing under the OUTER tmp
  # except its own root. Previous rounds left ca-run.* and ca-st*.{time,txt}
  # behind; plant M covers a run's own scratch, this covers the self-test.
  # A concurrent self-test's /tmp/ca-st.* is NOT this run's leftover: scan
  # only entries tagged with this run's token, and pin the enumeration's own
  # witness (>0, because $st_root itself matches the pattern).
  if plant_outer_tmp_decoy "$sh" "$outer_tmp" "$st_root" "$ST_TOKEN"; then
    plant_line "outer-tmp-decoy" 0 "an untagged neighbour ca-st.OTHER-DECOY/ca-run.OTHER-DECOY survives and is not reported; the untagged control names both"
  else
    plant_line "outer-tmp-decoy" 1 "$LAST_PLANT_DETAIL"
  fi
  local stray_tmp=""
  outer_tmp_strays "$outer_tmp" "$ST_TOKEN" "$st_root"
  stray_tmp="$OUTER_TMP_STRAYS"
  if [ "${OUTER_TMP_EXAMINED:-0}" -eq 0 ]; then
    plant_line "scratch-outer-tmp" 1 "the outer-tmp scan examined ZERO entries: pattern ca-*$ST_TOKEN* matched nothing, not even \$st_root"
  elif [ -z "$stray_tmp" ]; then
    plant_line "scratch-outer-tmp" 0 "no ca-* tagged $ST_TOKEN under $outer_tmp outside \$st_root (examined=$OUTER_TMP_EXAMINED)"
  else
    plant_line "scratch-outer-tmp" 1 "left behind: $stray_tmp"
  fi

  # CA-GUARD:unbound-capture-read
  # examined is the number of plant INVOCATIONS; the witness is the capture
  # file every child duplicated its stderr into, so a plant that discarded
  # both streams cannot report unbound=0 falsely (Astra r2 01).
  local cap_unbound
  cap_unbound="$(grep -c 'unbound variable' "$ST_CAP" 2>/dev/null || true)"
  cap_unbound="${cap_unbound:-0}"
  if [ "${ST_RUNS:-0}" -gt 0 ] && [ "${ST_UNBOUND:-0}" -eq 0 ] && [ "$cap_unbound" -eq 0 ]; then
    plant_line "no-unbound-variable" 0 "examined=$ST_RUNS unbound=0 capture=$ST_CAP cap_hits=0 mutant_unbound=${ST_UNBOUND_MUTANT:-0}${ST_UNBOUND_MUTANT_WITNESS:+ (gutted-mutant diagnostic, not the production script: $ST_UNBOUND_MUTANT_WITNESS)}"
  else
    plant_line "no-unbound-variable" 1 "examined=${ST_RUNS:-0} unbound=${ST_UNBOUND:-0} cap_hits=$cap_unbound witness=${ST_UNBOUND_WITNESS:-none} cap=$(grep -m1 'unbound variable' "$ST_CAP" 2>/dev/null || true)"
  fi

  # CA-GUARD:plant-total-check
  # plants + skipped == the declared constant. A gutted SKIP counter or a
  # deleted plant both change this sum (Fable r2: plants=67 skipped=0 PASS).
  local total_verdict
  total_verdict="$(plant_total_verdict "${ST_PLANTS:-0}" "${ST_SKIP:-0}")"
  if [ "$total_verdict" = OK ]; then
    say "plant accounting: plants=${ST_PLANTS:-0} + skipped=${ST_SKIP:-0} == declared=$ST_DECLARED_PLANTS  OK"
  else
    say "plant accounting: plants=${ST_PLANTS:-0} + skipped=${ST_SKIP:-0} != declared=$ST_DECLARED_PLANTS  FAIL (bump ST_DECLARED_PLANTS in the same commit as any plant change)"
    ST_FAIL=1
  fi

  if [ "$ST_FAIL" -ne 0 ]; then
    say "SELF-TEST: FAIL -- one or more plants SILENT or a transverse row failed plants=${ST_PLANTS:-0} skipped=${ST_SKIP:-0} transverse_skipped=${ST_TV_SKIP:-0}"
    exit 1
  fi
  say "SELF-TEST: PASS -- run-mode plants FIRE and each gutted guard silences its plant plants=${ST_PLANTS:-0} skipped=${ST_SKIP:-0} transverse_skipped=${ST_TV_SKIP:-0}"
  exit 0
}

case "${1:-plan}" in
  plan)
    resolve_eco
    say "consumer acceptance -- plan"; say ""; inventory ;;
  run)
    shift
    run_mode "$@" ;;
  --self-test)
    selftest ;;
  --drop-sha)
    # Self-test probe for CA-GUARD:drop-sha-readback. Pure: one word out.
    shift
    printf '%s\n' "$(drop_sha_verdict "${1:-}" "${2:-}")" ;;
  --drop-tool)
    # Self-test probe for CA-GUARD:drop-trust-root. Pure: one line out,
    # naming the drop tool THIS SCRIPT would use. CA_DROP_CMD appears here
    # only under $CA_ECO/.ca_fixture; otherwise it is IGNORED and the
    # harness-chosen tool is named.
    printf 'drop=%s\n' "$(drop_tool)" ;;
  --outer-tmp-strays)
    # Self-test probe for CA-GUARD:outer-tmp-token. <dir> <token> <keep>.
    shift
    outer_tmp_strays "${1:-}" "${2:-}" "${3:-}"
    printf 'examined=%s strays=%s\n' "$OUTER_TMP_EXAMINED" "${OUTER_TMP_STRAYS:-none}" ;;
  --plant-total)
    # Self-test accounting probe (CA-GUARD:plant-total). Reads nothing and
    # writes nothing: it exists so the comparison can be mutated and the
    # mutation observed without re-running the whole self-test.
    shift
    printf '%s\n' "$(plant_total_verdict "${1:-0}" "${2:-0}")" ;;
  *) say "usage: $0 [plan|run|--self-test]"; exit 2 ;;
esac

exit "$FAILED"
