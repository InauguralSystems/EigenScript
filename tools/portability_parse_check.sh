#!/usr/bin/env bash
# portability_parse_check.sh — PARSE every tracked shell script under the
# OLDEST bash available, and RUN this repo's shell gates under it.
#
# ROUND 14 — PARSING WAS NEVER ENOUGH, AND THAT COST THREE ROUNDS.
# The oracle was built in round 10 and used only as `bash32 -n`. Rounds 11, 12
# and 13 each shipped a fix for a macOS failure that `-n` said was clean, and
# each was diagnosed on CI days later. The failure was a RUNTIME error:
#
#     line 1538: bad substitution: no closing `)' in <( { printf '%s\n' …
#
# bash 3.2 scans a PROCESS SUBSTITUTION for its closing paren without honouring
# comments, so an apostrophe in a comment inside `<( … )` opens a quote that
# never closes — at execution, not at parse. Measured here, both constructs,
# both modes:
#
#     <( { …  # its own file's directory … } )   bash32 -n OK   bash32 RUN FAILS
#     $( { …  # its own file's directory … } )   bash32 -n OK   bash32 RUN OK
#
# A parser cannot see it. Running can, in seconds. So this file does BOTH: the
# parse sweep over every tracked script, and an EXECUTION of the shell gates
# that CI runs on macOS. The whole docs-claims gate runs under 3.2 in ~17 s,
# which is cheaper than one CI round by four orders of magnitude.
#
# WHY THIS EXISTS. macOS ships bash 3.2 (2007). Three CI rounds were spent
# guessing at constructs it rejects, and the guesses were wrong twice:
#   round  7  replaced `declare -A` (correctly) with a construct 3.2 also
#             could not take;
#   round  9  read a syntax error's REPORTED line and blamed an empty inline
#             `case` arm, which 3.2 parses perfectly well;
#   round 10  built a real bash 3.2 and found the true cause in one second —
#             `TABLE=$(cat <<'EOF' …)`, because 3.2 counts parentheses inside a
#             quoted heredoc body and a reviewed-prose row contained one;
#   rounds 11-13  three more macOS rounds, all of them diagnosable on this box
#             the moment anybody RAN the gate under the oracle instead of
#             parsing it.
# An oracle that answers in a second beats any amount of reading. This check is
# that oracle, wired so nobody has to remember to run it.
#
# THE SKIP ANNOUNCES ITSELF. On a machine with no old bash this cannot do its
# job — and a gate that quietly measures nothing still prints OK
# (mechanical-gates §121). So it prints which interpreter it used and how many
# files it parsed EITHER WAY, and says plainly when the answer is weaker than
# it looks.
#
# Building the oracle (dev box, ~4 minutes):
#   curl -O https://ftp.gnu.org/gnu/bash/bash-3.2.tar.gz && tar xf bash-3.2.tar.gz
#   cd bash-3.2 && ./configure --without-bash-malloc --disable-nls && make
#   cp bash ~/.local/bin/bash32
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "portability-parse: ABORTED: cannot cd to '$ROOT'" >&2; exit 1; }

# Calibrate the suite's real receipt classifier without running the suite.
if [ "${1:-}" = "--selftest" ]; then
    PASS=0; FAIL=0
    eval "$(sed -n '/^PORT_OLD_MAJOR_MAX=/p; /^port_identity_verdict() {/,/^}/p' tests/run_all_tests.sh)"
    # THE IDENTITY ARM'S OWN PLANTED FAULTS. The arm above fires only when the
    # gate misbehaves, so on a healthy tree it has never been observed to work —
    # which is the definition of a gate nobody has shown to be a gate
    # (mechanical-gates §19). These three synthetic receipts drive the SAME
    # function the real verdict used, and both halves are present: a receipt that
    # must be refused, and one that must be accepted (§15).
    #
    #   1. bash 5 wearing a bash 3.2 BANNER  -> refused. Round 6 accepted this,
    #      because it read the banner and not the fact.
    #   2. a real bash 3.2 with a VENDOR banner -> accepted. Round 6 refused this.
    #   3. a completed audit with no identity line at all -> refused.
    PORT_CTRL_OK=0
    PORT_CTRL_WHY=""
    PORT_SYNTH_5="portability-parse: oracle=/bin/bash (GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin23))
portability-parse: oracle-major=5
portability: OK: files=128 checked=128 parse-failures=0; gates-run=5/5 run-failures=0"
    PORT_SYNTH_3="portability-parse: oracle=/opt/vendor/bash (Custom Bash 3.2.0, same GNU Bash 3.2 engine)
portability-parse: oracle-major=3
portability: OK: files=128 checked=128 parse-failures=0; gates-run=5/5 run-failures=0"
    PORT_SYNTH_NONE="portability-parse: oracle=/bin/bash (GNU bash, version 3.2.57(1)-release)
portability: OK: files=128 checked=128 parse-failures=0; gates-run=5/5 run-failures=0"
    port_identity_verdict "$PORT_SYNTH_5"
    if [ -n "$PORT_IDENTITY_VERDICT" ]; then
        PORT_CTRL_OK=$((PORT_CTRL_OK + 1))
    else
        PORT_CTRL_WHY="$PORT_CTRL_WHY [a bash-5 oracle wearing a bash 3.2 banner was ACCEPTED]"
    fi
    port_identity_verdict "$PORT_SYNTH_3"
    if [ -z "$PORT_IDENTITY_VERDICT" ]; then
        PORT_CTRL_OK=$((PORT_CTRL_OK + 1))
    else
        PORT_CTRL_WHY="$PORT_CTRL_WHY [a real bash 3.2 with a vendor banner was REFUSED: $PORT_IDENTITY_VERDICT]"
    fi
    port_identity_verdict "$PORT_SYNTH_NONE"
    if [ -n "$PORT_IDENTITY_VERDICT" ]; then
        PORT_CTRL_OK=$((PORT_CTRL_OK + 1))
    else
        PORT_CTRL_WHY="$PORT_CTRL_WHY [a completed audit with no oracle-major line was ACCEPTED]"
    fi
    if [ "$PORT_CTRL_OK" -eq 3 ]; then
        PASS=$((PASS + 1))
        echo "  PASS: portability identity arm, 3/3 synthetic receipts judged correctly (bash-5-in-a-3.2-banner refused, vendor-bannered 3.2 accepted, identity-less audit refused)"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: portability identity arm judged $PORT_CTRL_OK/3 synthetic receipts correctly —$PORT_CTRL_WHY"
    fi
    [ "$FAIL" -eq 0 ]
    exit $?
fi

# The pinned population. A tracked-file count that drops is a shrinking audit,
# which is the failure this whole class of gate exists to refuse; a floor, not
# an exact pin, because adding a script must not require editing this line.
FILE_FLOOR=110

# The gates EXECUTED under the old bash, and how many there must be. These are
# the tracked shell gates the macOS lane runs inside tests/run_all_tests.sh;
# running each under 3.2 exercises ITS OWN body (a child it spawns still uses
# `#!/usr/bin/env bash`, i.e. the modern one — which is the same split CI has).
# The count is PINNED: a run list that quietly empties would leave this file
# printing OK while executing nothing, which is the exact failure the parse
# half was written to refuse (mechanical-gates §121).
#
# Checker calibration belongs to tools/selftests.sh; this audits live gates.
RUN_TARGETS="tools/docs_claims_check.sh tools/child_exit_check.sh tools/suite_label_check.sh"
RUN_TARGETS_DECLARED=3

# Candidates, oldest first. $PORTABILITY_BASH overrides for a test.
#
# THE SYSTEM SHELL IS A CANDIDATE WHEN IT IS OLD. Bought 2026-09-21 (round-5
# blind critic, Fable): until now the list was $PORTABILITY_BASH, the two
# `bash32` oracle paths, and nothing else — so on the ONE platform this whole
# audit exists for, the macOS runner, it found no old bash and skipped with
# "NO OLD BASH ON THIS MACHINE". That reason was FALSE. macOS's default
# /bin/bash IS GNU bash 3.2.57, the exact interpreter the gate is written
# about; the list simply never looked at it. The audit announced a skip on the
# lane it was built to protect and ran only where an oracle had been installed
# by hand.
#
# "Old" here means what the header means by it: MAJOR VERSION 3 or lower —
# bash 3.2 (2007), what Apple still ships.
#
# EVERY CANDIDATE IS ASKED ITS OWN VERSION, INCLUDING THE DECLARED ONES.
# Bought 2026-09-21 (round-5 blind critic, Fable). Until round 6 only
# /bin/bash and /usr/bin/bash were version-checked; $PORTABILITY_BASH and the
# two `bash32` paths were trusted BY NAME, as "declared oracles, named by a
# human who built one". A file called `bash32` is not bash 3.2 — a symlink to
# the system shell, a rebuild that picked up a modern source tree, or a
# $PORTABILITY_BASH typed at a shell that is simply the current one, all
# passed unchecked, and the gate then printed a perfectly truthful
# `oracle=… version 5.x` receipt for an audit that models nothing. The name is
# a hint; `BASH_VERSINFO[0]` is the fact, and it costs one exec to ask.
#
# THE IDENTITY THE CALLER READS IS THE FACT, NOT THE BANNER. Bought 2026-09-21
# (round-6 blind critic, Fable, item 2): `[99zb]` parsed the interpreter's
# major version out of `--version`'s GNU BANNER, so a bash whose banner does
# not begin "GNU bash, version" — a vendor build, a wrapper, a rebuild with a
# changed `RELEASE` string — produced no number at all and the caller failed
# a perfectly good bash 3.2 by name. The gate now PRINTS the selected
# candidate's own `BASH_VERSINFO[0]` on its own line and the caller parses
# THAT; the banner stays display only.
PORTABILITY_OLD_MAJOR_MAX=3
OLD_BASH=""
OLD_BASH_MAJOR=""
PORT_CANDIDATES_TRIED=""
PORT_CANDIDATES_REJECTED=""
for cand in "${PORTABILITY_BASH:-}" "$HOME/.local/bin/bash32" /usr/local/bin/bash32 /bin/bash /usr/bin/bash; do
    [ -n "$cand" ] || continue
    PORT_CANDIDATES_TRIED="$PORT_CANDIDATES_TRIED $cand"
    [ -x "$cand" ] || continue
    # EVERY candidate — declared or system — qualifies only by its own version
    # number, and a candidate that cannot answer at all is not bash.
    cand_major=$("$cand" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)
    case "$cand_major" in
        ''|*[!0-9]*)
            PORT_CANDIDATES_REJECTED="$PORT_CANDIDATES_REJECTED $cand(no-BASH_VERSINFO)"
            continue ;;
    esac
    if [ "$cand_major" -gt "$PORTABILITY_OLD_MAJOR_MAX" ]; then
        PORT_CANDIDATES_REJECTED="$PORT_CANDIDATES_REJECTED $cand(major=$cand_major)"
    fi
    [ "$cand_major" -le "$PORTABILITY_OLD_MAJOR_MAX" ] || continue
    OLD_BASH="$cand"; OLD_BASH_MAJOR="$cand_major"; break
done

# An uncommitted deletion is still in the index; parse the files that exist in
# this worktree. The floor and checked==n assertion still guard lost coverage.
indexed=$(git -c safe.directory='*' ls-files '*.sh' 2>/dev/null)
files=''
for f in $indexed; do
    if [ -f "$f" ]; then
        files="$files$f
"
    fi
done
n=$(printf '%s\n' "$files" | grep -c . || true)

if [ "${n:-0}" -lt "$FILE_FLOOR" ]; then
    echo "portability-parse: FAIL: git listed $n tracked *.sh (floor $FILE_FLOOR) — the audit is scanning almost nothing"
    exit 1
fi

if [ -z "$OLD_BASH" ]; then
    # NOT a silent pass. The counts are printed so the line can never read as a
    # completed audit, and the named path tells a reader how to get the real one.
    echo "portability-parse: NO OLD BASH ON THIS MACHINE — $n tracked *.sh were NOT parsed by an old shell,"
    echo "portability-parse: and $RUN_TARGETS_DECLARED gate(s) were NOT executed under one either."
    # NAME WHAT WAS LOOKED FOR. A skip whose reason cannot be checked is a
    # reason nobody checks: round 4's message said "no old bash on this
    # machine" on a runner whose /bin/bash is 3.2.57, because /bin/bash was
    # never a candidate (round-5 blind critic, Fable).
    echo "portability-parse: looked for, in order:$PORT_CANDIDATES_TRIED"
    echo "portability-parse: rejected by their own version:${PORT_CANDIDATES_REJECTED:- (none)}"
    echo "portability-parse: every candidate qualifies only when its own BASH_VERSINFO[0] is <= $PORTABILITY_OLD_MAJOR_MAX — a name is a hint, the version is the fact."
    echo "portability-parse: this machine's /bin/bash reports major version $(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo '?')."
    echo "portability-parse: this run proves nothing about bash 3.2. Build the oracle (see the header of"
    echo "portability-parse: tools/portability_parse_check.sh) or install one at ~/.local/bin/bash32."
    echo "portability-parse: SKIPPED (announced, not silent): files=$n checked=0 gates-run=0"
    exit 0
fi

ver=$("$OLD_BASH" --version 2>/dev/null | head -1)
bad=0
checked=0
for f in $files; do
    checked=$((checked + 1))
    if ! "$OLD_BASH" -n "$f" 2>/tmp/portability_parse_err.$$; then
        bad=$((bad + 1))
        echo "portability-parse: FAIL: $f does not parse under $ver"
        sed 's/^/    | /' /tmp/portability_parse_err.$$ | head -4
    fi
done
rm -f /tmp/portability_parse_err.$$

if [ "$checked" -ne "$n" ]; then
    echo "portability-parse: FAIL: examined $checked of $n files — the walk dropped some"
    exit 1
fi

echo "portability-parse: oracle=$OLD_BASH ($ver)"
# The line the CALLER reads. `BASH_VERSINFO[0]` as the selected candidate
# itself reported it, on a line of its own, in a fixed shape — so the caller's
# own `<= 3` literal has a number to apply and never has to parse prose.
echo "portability-parse: oracle-major=$OLD_BASH_MAJOR"
if [ "$bad" -eq 0 ]; then
    echo "portability-parse: OK: files=$n checked=$checked failures=0"
else
    echo "portability-parse: FAIL: files=$n checked=$checked failures=$bad"
fi

# ---------------------------------------------------------------------------
# THE HALF A PARSER CANNOT DO. Each gate is EXECUTED under the old bash and
# must exit 0. Its whole output is kept and printed on failure — this is the
# one place a `<( … )`-class runtime break can be seen before CI sees it.
# ---------------------------------------------------------------------------
run_list="$RUN_TARGETS"
run_declared=$RUN_TARGETS_DECLARED

run_done=0
run_bad=0
run_log="${TMPDIR:-/tmp}/portability_run.$$"
for spec in $run_list; do
    tgt="${spec%%|*}"
    arg=""
    case "$spec" in *"|"*) arg="${spec#*|}" ;; esac
    if [ ! -f "$tgt" ]; then
        echo "portability-run: FAIL: $tgt is in the run list and is not a file — the list names a gate this tree does not have"
        run_bad=$((run_bad + 1))
        continue
    fi
    run_done=$((run_done + 1))
    t0=$(date +%s)
    if [ -n "$arg" ]; then
        "$OLD_BASH" "$tgt" "$arg" > "$run_log" 2>&1
    else
        "$OLD_BASH" "$tgt" > "$run_log" 2>&1
    fi
    rc=$?
    t1=$(date +%s)
    if [ "$rc" -eq 0 ]; then
        echo "portability-run: ok: $tgt $arg exited 0 under $ver ($((t1 - t0))s)"
    else
        run_bad=$((run_bad + 1))
        echo "portability-run: FAIL: $tgt $arg exited $rc under $ver — this is what the macOS lane will do"
        sed 's/^/    | /' "$run_log"
    fi
done
rm -f "$run_log"

if [ "$run_done" -ne "$run_declared" ]; then
    echo "portability-run: FAIL: executed $run_done gate(s), $run_declared declared — the run list shrank"
    exit 1
fi
if [ "$run_bad" -ne 0 ] || [ "$bad" -ne 0 ]; then
    echo "portability: FAIL: files=$n checked=$checked parse-failures=$bad; gates-run=$run_done run-failures=$run_bad"
    exit 1
fi
echo "portability: OK: files=$n checked=$checked parse-failures=0; gates-run=$run_done/$run_declared run-failures=0 (oracle $ver)"
exit 0
