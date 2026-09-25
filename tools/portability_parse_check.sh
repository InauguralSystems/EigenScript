#!/bin/bash
# Parse every tracked *.sh under bash <= 3, and run the macOS shell gates
# under it. bash 3.2 scans <( ) without honouring comments, so -n is not
# enough. No old bash is an announced SKIP, not a pass. Callers read
# portability-parse: oracle-major=N from BASH_VERSINFO, not the banner.
set -u
cd "$(dirname "$0")/.." || { echo "portability-parse: ABORTED: cannot cd" >&2; exit 1; }
FILE_FLOOR=110
RUN_TARGETS="tools/docs_claims_check.sh tools/child_exit_check.sh tools/suite_label_check.sh"
RUN_N=3
MAX=3
OLD=""; MAJOR=""; TRIED=""; REJ=""
for cand in "${PORTABILITY_BASH:-}" "$HOME/.local/bin/bash32" /usr/local/bin/bash32 /bin/bash /usr/bin/bash; do
    [ -n "$cand" ] || continue
    TRIED="$TRIED $cand"
    [ -x "$cand" ] || continue
    m=$("$cand" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || m=""
    case "$m" in
        ''|*[!0-9]*) REJ="$REJ $cand(no-BASH_VERSINFO)"; continue ;;
    esac
    if [ "$m" -gt "$MAX" ]; then REJ="$REJ $cand(major=$m)"; continue; fi
    OLD="$cand"; MAJOR="$m"; break
done
indexed=$(git -c safe.directory='*' ls-files '*.sh' 2>/dev/null) || indexed=""
n=0; files=""
for f in $indexed; do
    if [ -f "$f" ]; then files="$files$f "; n=$((n + 1)); fi
done
if [ "${n:-0}" -lt "$FILE_FLOOR" ]; then
    echo "portability-parse: FAIL: git listed $n tracked *.sh (floor $FILE_FLOOR) — the audit is scanning almost nothing"
    exit 1
fi
if [ -z "$OLD" ]; then
    echo "portability-parse: NO OLD BASH ON THIS MACHINE — $n tracked *.sh were NOT parsed by an old shell,"
    echo "portability-parse: and $RUN_N gate(s) were NOT executed under one either."
    echo "portability-parse: looked for, in order:$TRIED"
    echo "portability-parse: rejected by their own version:${REJ:- (none)}"
    echo "portability-parse: every candidate qualifies only when its own BASH_VERSINFO[0] is <= $MAX."
    echo "portability-parse: this machine's /bin/bash reports major version $(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo '?')."
    echo "portability-parse: this run proves nothing about bash 3.2. Install one at ~/.local/bin/bash32."
    echo "portability-parse: SKIPPED (announced, not silent): files=$n checked=0 gates-run=0"
    exit 0
fi
ver=$("$OLD" --version 2>/dev/null | head -1)
bad=0; checked=0
err="${TMPDIR:-/tmp}/portability_parse_err.$$"
for f in $files; do
    checked=$((checked + 1))
    if ! "$OLD" -n "$f" 2>"$err"; then
        bad=$((bad + 1))
        echo "portability-parse: FAIL: $f does not parse under $ver"
        sed 's/^/    | /' "$err" | head -4
    fi
done
rm -f "$err"
if [ "$checked" -ne "$n" ]; then
    echo "portability-parse: FAIL: examined $checked of $n files — the walk dropped some"
    exit 1
fi
echo "portability-parse: oracle=$OLD ($ver)"
echo "portability-parse: oracle-major=$MAJOR"
if [ "$bad" -eq 0 ]; then echo "portability-parse: OK: files=$n checked=$checked failures=0"
else echo "portability-parse: FAIL: files=$n checked=$checked failures=$bad"; fi
run_done=0; run_bad=0
log="${TMPDIR:-/tmp}/portability_run.$$"
for tgt in $RUN_TARGETS; do
    if [ ! -f "$tgt" ]; then
        echo "portability-run: FAIL: $tgt is in the run list and is not a file — the list names a gate this tree does not have"
        run_bad=$((run_bad + 1)); continue
    fi
    run_done=$((run_done + 1))
    t0=$(date +%s)
    "$OLD" "$tgt" >"$log" 2>&1
    rc=$?; t1=$(date +%s)
    if [ "$rc" -eq 0 ]; then
        echo "portability-run: ok: $tgt  exited 0 under $ver ($((t1 - t0))s)"
    else
        run_bad=$((run_bad + 1))
        echo "portability-run: FAIL: $tgt  exited $rc under $ver — this is what the macOS lane will do"
        sed 's/^/    | /' "$log"
    fi
done
rm -f "$log"
if [ "$run_done" -ne "$RUN_N" ]; then
    echo "portability-run: FAIL: executed $run_done gate(s), $RUN_N declared — the run list shrank"
    exit 1
fi
if [ "$run_bad" -ne 0 ] || [ "$bad" -ne 0 ]; then
    echo "portability: FAIL: files=$n checked=$checked parse-failures=$bad; gates-run=$run_done run-failures=$run_bad"
    exit 1
fi
echo "portability: OK: files=$n checked=$checked parse-failures=0; gates-run=$run_done/$RUN_N run-failures=0 (oracle $ver)"
exit 0
