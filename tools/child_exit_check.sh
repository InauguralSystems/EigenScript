#!/bin/bash
# Child-script exit status is discarded by a command substitution unless
# run_all_tests.sh's bash() wrapper records it (#988). A launcher in front of
# bash execs the real binary and the section goes back to marker-only. The
# invocation count is floored: growth is free, a drop is a review. Zero is red.
set -u
cd "$(dirname "$0")/.." || exit 1
RUNNER="${RUNNER:-tests/run_all_tests.sh}"
CHILD_SITES_FLOOR="${CHILD_SITES_FLOOR:-87}"
fail() { echo "GATE ERROR: $*" >&2; RC=1; }
RC=0
runner_code() { sed 's/[[:space:]]*#.*$//' "$RUNNER"; }
if ! grep -qE '^bash\(\)[[:space:]]*\{' <<< "$(runner_code)"; then
    fail "$RUNNER does not define the bash() accounting wrapper — every child's exit status is discarded again"
fi
if ! grep -qF 'CHILD_LEDGER"' "$RUNNER"; then
    fail "$RUNNER no longer appends to CHILD_LEDGER — the end-of-suite roster cannot fire"
fi
if ! grep -qF 'without completing — section verdict is not trustworthy (#988)' "$RUNNER"; then
    fail "$RUNNER no longer emits the synthetic FAIL: marker — sections go back to deciding on markers alone"
fi
if ! grep -qF '[99p] Child-script exit-status ledger' "$RUNNER"; then
    fail "$RUNNER no longer runs the [99p] ledger section — nonzero children would be recorded and never reported"
fi
CHILD_SITES=$(runner_code | grep -cE '(^|[^a-zA-Z_])bash[[:space:]]+("?\$(TESTS_DIR|\{TESTS_DIR\})"?[^|;)]*\.sh|"[^"]*\.sh")')
if [ "$CHILD_SITES" -lt "$CHILD_SITES_FLOOR" ]; then
    fail "$CHILD_SITES child-script invocation sites found, below the floor of $CHILD_SITES_FLOOR — a child test was removed, or a site was reformatted out of this matcher's reach; lower CHILD_SITES_FLOOR in the same commit if deliberate"
fi
BADWORD=$(runner_code | awk '
    {
        line = $0
        gsub(/\$\(/, "\n", line)
        gsub(/[();`]|&&|\|\||\|/, "\n", line)
        n = split(line, seg, "\n")
        for (i = 1; i <= n; i++) {
            s = seg[i]
            if (s !~ /\.sh/) continue
            sub(/^[[:space:]]+/, "", s)
            while (s ~ /^(if|then|elif|else|do|while|until|!)[[:space:]]+/)
                sub(/^(if|then|elif|else|do|while|until|!)[[:space:]]+/, "", s)
            while (s ~ /^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:space:]]+/)
                sub(/^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:space:]]+/, "", s)
            first = s; sub(/[[:space:]].*$/, "", first)
            if (first == "bash" || first == "command") continue
            if (first ~ /^(sh|dash|zsh|ksh|\/bin\/sh|\/bin\/bash|\/usr\/bin\/bash|\/usr\/bin\/sh)$/) {
                printf "%d:%s\n", NR, $0
                continue
            }
            if (s ~ /(^|[[:space:]])bash[[:space:]]/) {
                printf "%d:%s\n", NR, $0
                continue
            }
        }
    }' || true)
if [ -n "$BADWORD" ]; then
    fail "child script(s) reached through something other than the bash() wrapper (bash must be the COMMAND WORD — a launcher in front of it execs the real binary and leaves the mechanism entirely):"
    printf '%s\n' "$BADWORD" | sed 's/^/    /' >&2
fi
CMD_BASH=$(runner_code | grep -cE '(^|[^a-zA-Z_])command[[:space:]]+bash' || true)
if [ "$CMD_BASH" -ne 3 ]; then
    fail "expected exactly 3 'command bash' (the wrapper's own call-throughs), found $CMD_BASH — an extra one bypasses accounting"
fi
NO_MARKER_LIST=$(sed -n 's/^CHILD_NO_MARKERS="\(.*\)"$/\1/p' "$RUNNER")
if [ -z "$NO_MARKER_LIST" ]; then
    fail "$RUNNER no longer declares CHILD_NO_MARKERS — the vacuity rule's waiver list is gone"
else
    for entry in $NO_MARKER_LIST; do
        if [ ! -f "tests/$entry" ]; then
            fail "CHILD_NO_MARKERS waives '$entry', which does not exist — stale waiver"
        elif grep -qE '(PASS|FAIL):' "tests/$entry"; then
            fail "CHILD_NO_MARKERS waives '$entry', but it DOES emit PASS:/FAIL: markers — the waiver is no longer needed and now hides real vacuity"
        fi
    done
fi
ENV_RUNTIME_CHILDREN_FLOOR="${ENV_RUNTIME_CHILDREN_FLOOR:-8}"   # a floor (#1264): the binding covers new ones
if ! grep -qE '^EIGS="\$PWD/\$\{EIGS_BIN#\./\}"$' "$RUNNER"; then
    fail "$RUNNER no longer binds EIGS to \$EIGS_BIN — every child that resolves \${EIGS:-...} now measures whatever the environment says (#1188)"
elif ! grep -qE '^export EIGS$' "$RUNNER"; then
    fail "$RUNNER binds EIGS but does not export it — the binding reaches no child (#1188)"
fi
ENV_RUNTIME_CHILDREN=$(grep -lE '^[[:space:]]*EIGS=.?\$\{EIGS:-' tests/test_*.sh 2>/dev/null | grep -c . || true)
if [ "${ENV_RUNTIME_CHILDREN:-0}" -eq 0 ]; then
    fail "found ZERO children resolving \${EIGS:-...} — the scan for them is broken, not the tree (§121)"
elif [ "$ENV_RUNTIME_CHILDREN" -lt "$ENV_RUNTIME_CHILDREN_FLOOR" ]; then
    fail "$ENV_RUNTIME_CHILDREN child test(s) take their runtime from the environment, below the floor of $ENV_RUNTIME_CHILDREN_FLOOR — a child lost its \${EIGS:-...} default; lower the floor if deliberate"
fi
if [ "$RC" -eq 0 ]; then
    echo "PASS: child-exit accounting present; $CHILD_SITES child-script sites (floor $CHILD_SITES_FLOOR), no bypass spellings; EIGS bound for $ENV_RUNTIME_CHILDREN environment-selectable child(ren)"
fi
exit "$RC"
