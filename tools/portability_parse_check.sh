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
# docs_claims_check.sh --selftest is deliberately NOT here. Measured: ~3 min
# under 3.2 against ~17 s for the gate itself, and what those 3 minutes add is
# the SELFTEST DRIVER's own body under 3.2 — its children are spawned through
# `bash`, the modern one, so the extra coverage is one file's second half.
# Set PORTABILITY_RUN_SELFTEST=1 to include it when that half is what changed.
RUN_TARGETS="tools/docs_claims_check.sh tools/child_exit_check.sh tools/suite_label_check.sh tools/doc_drift_check.sh"
RUN_TARGETS_DECLARED=4

# Candidates, oldest first. $PORTABILITY_BASH overrides for a test.
OLD_BASH=""
for cand in "${PORTABILITY_BASH:-}" "$HOME/.local/bin/bash32" /usr/local/bin/bash32; do
    [ -n "$cand" ] || continue
    [ -x "$cand" ] || continue
    OLD_BASH="$cand"; break
done

files=$(git -c safe.directory='*' ls-files '*.sh' 2>/dev/null)
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
[ -n "${PORTABILITY_RUN_SELFTEST:-}" ] && run_list="$run_list tools/docs_claims_check.sh|--selftest"
run_declared=$RUN_TARGETS_DECLARED
[ -n "${PORTABILITY_RUN_SELFTEST:-}" ] && run_declared=$((run_declared + 1))

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
