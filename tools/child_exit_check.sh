#!/bin/bash
# Child-script exit-status accounting gate (#988).
#
# tests/run_all_tests.sh runs ~45 child `.sh` tests as
#     FOO_OUTPUT=$(bash "$TESTS_DIR/test_foo.sh" 2>&1)
# A command substitution keeps the child's stdout and DISCARDS its exit
# status, so the section's verdict came from `grep -c "FAIL:"` alone. A child
# that printed two PASS: lines and then segfaulted reported a PASSING section;
# a child that did not exist reported "0/0 passed, 0 failed", also a pass.
# Reproduced at exit 139, 127 and 1 before the fix.
#
# The fix is a `bash` shell FUNCTION in run_all_tests.sh that emits a synthetic
# FAIL: line and appends to $CHILD_LEDGER whenever a child script exits
# nonzero. It is central precisely so no call site has to remember anything —
# which means the whole mechanism dies silently if someone routes around the
# function. This gate is what makes that loud.
#
# Usage: tools/child_exit_check.sh [--selftest]
#   --selftest : plant each fault this gate exists to catch in a temporary
#                copy and require the matching assertion to fire.
# Exit 0 = the accounting is present and unbypassed.

set -u
cd "$(dirname "$0")/.." || exit 1

RUNNER="${RUNNER:-tests/run_all_tests.sh}"

# Declared population. The sites are DERIVED by matching invocations in the
# runner, so the population can shrink without anything failing
# (mechanical-gates §43): a site reformatted beyond the matcher's reach simply
# leaves the set. `[ -z ]` is an emptiness test, not a guard — it only catches
# losing ALL of them.
#
# ROUND 11 — FOUND == DECLARED, NOT A FLOOR (mechanical-gates §129).
# This was `CHILD_SITE_FLOOR=60`, and its own planted "population shrunk below
# the floor" case stopped firing: the plant removes a fixed handful of sites,
# the population had grown to 113, and a fixed shrink can no longer cross a
# floor 53 below. The selftest said so honestly — but the gate had been unable
# to see a shrink for however long the two had been drifting apart, and a
# floor plus a plant calibrated against it will drift apart again every time
# the population grows. An exact count cannot: ANY movement, in either
# direction, is a review event, and the plant needs no calibration at all.
#
# Adding or removing a child dispatch therefore means bumping this number in
# the same commit — deliberately, the way every other population in this
# suite's gates is pinned.
#
# The metric is LINES carrying an invocation, not invocations: a few sites run
# two children on one line (`if bash A && bash B --selftest; then`), so the
# true invocation count is higher. Lines are what this is measured in; do not
# "correct" it to invocations without re-measuring.
CHILD_SITES_DECLARED="${CHILD_SITES_DECLARED:-125}"

fail() { echo "GATE ERROR: $*" >&2; RC=1; }
RC=0

# ---------------------------------------------------------------------------
# Strip comments before enumerating (mechanical-gates §24). This gate reads a
# file that DOCUMENTS the very pattern it searches for — the runner's #988
# comment block contains a literal `$(bash "$TESTS_DIR/test_foo.sh" 2>&1)`
# example. Counting that would inflate the population with the gate's own
# reflection, and worse, would keep the floor satisfied after every real site
# was gone. Only executable text is enumerated.
# ---------------------------------------------------------------------------
runner_code() { sed 's/[[:space:]]*#.*$//' "$RUNNER"; }

# --- 1. The mechanism exists at all ---------------------------------------
# Anchored on the three parts that make it work: the function, the ledger
# append, and the synthetic marker. Any one missing is a dead mechanism.
if ! runner_code | grep -qE '^bash\(\)[[:space:]]*\{'; then
    fail "$RUNNER does not define the bash() accounting wrapper — every child's exit status is discarded again"
fi
if ! grep -qF 'CHILD_LEDGER"' "$RUNNER"; then
    fail "$RUNNER no longer appends to CHILD_LEDGER — the end-of-suite roster cannot fire"
fi
if ! grep -qF 'without completing — section verdict is not trustworthy (#988)' "$RUNNER"; then
    fail "$RUNNER no longer emits the synthetic FAIL: marker — sections go back to deciding on markers alone"
fi
# The ledger block must be CONSUMED, or the append is write-only.
if ! grep -qF '[99p] Child-script exit-status ledger' "$RUNNER"; then
    fail "$RUNNER no longer runs the [99p] ledger section — nonzero children would be recorded and never reported"
fi

# --- 2. Population, pinned exactly -----------------------------------------
# Every executable line invoking a `.sh` child through the wrapper.
CHILD_SITES=$(runner_code | grep -cE '(^|[^a-zA-Z_])bash[[:space:]]+("?\$(TESTS_DIR|\{TESTS_DIR\})"?[^|;)]*\.sh|"[^"]*\.sh")')
if [ "$CHILD_SITES" -ne "$CHILD_SITES_DECLARED" ]; then
    fail "$CHILD_SITES child-script invocation sites found, $CHILD_SITES_DECLARED declared — a child test was added or removed, or a site was reformatted out of this matcher's reach; bump CHILD_SITES_DECLARED deliberately after reviewing which"
fi

# --- 3. `bash` must be the COMMAND WORD, not merely present ----------------
# This is the check the obvious design gets wrong. The wrapper is a shell
# FUNCTION, and a function is consulted only when `bash` is the command word of
# a simple command. Put ANY external launcher in front of it —
#     env bash "$TESTS_DIR/test_x.sh"
#     timeout 60 bash "$TESTS_DIR/test_x.sh"
#     $EIGS_TMO bash "$TESTS_DIR/test_x.sh"
# — and the real /usr/bin/bash is exec'd: no synthetic FAIL:, no ledger row,
# section silently back to marker-only. Every one of those spellings still
# matches the population matcher above, so the declared count stays satisfied
# and nothing else notices.
#
# A denylist of known-bad launchers cannot work (the list is unbounded, and
# `env` and `$EIGS_TMO` both already appear in this runner for other reasons).
# So the check is ALLOWLIST-shaped and positive: split each population line on
# command separators, and require the segment carrying the `.sh` to begin with
# `bash` — optionally preceded only by VAR=value assignment prefixes, which is
# the one thing the shell still treats as the same simple command.
#
# Being positive also removes a false-alarm class the denylist had: a
# diagnostic like `echo "reproduce with: sh tests/test_cli.sh"` is a segment
# whose first word is `echo`, so it carries no invocation and is not judged.
BADWORD=$(runner_code | awk '
    {
        line = $0
        # Split on command separators into candidate simple commands.
        gsub(/\$\(/, "\n", line)
        gsub(/[();`]|&&|\|\||\|/, "\n", line)
        n = split(line, seg, "\n")
        for (i = 1; i <= n; i++) {
            s = seg[i]
            if (s !~ /\.sh/) continue
            # Strip leading whitespace, shell keywords, and VAR=value prefixes
            # (a VAR=value prefix is still the SAME simple command).
            sub(/^[[:space:]]+/, "", s)
            while (s ~ /^(if|then|elif|else|do|while|until|!)[[:space:]]+/)
                sub(/^(if|then|elif|else|do|while|until|!)[[:space:]]+/, "", s)
            # The value may be quoted (`EIGENSCRIPT="./eigenscript" bash ...`),
            # so the unquoted form alone leaves a real call site looking like a
            # launcher — a false alarm in the check whose whole value is that
            # its failures are believed.
            while (s ~ /^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:space:]]+/)
                sub(/^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)[[:space:]]+/, "", s)
            first = s; sub(/[[:space:]].*$/, "", first)

            # (a) The correct shape: the wrapper is the command word.
            if (first == "bash" || first == "command") continue

            # (b) A non-bash shell reaching a .sh — the wrapper is a `bash`
            #     function, so these are invisible to it by construction.
            if (first ~ /^(sh|dash|zsh|ksh|\/bin\/sh|\/bin\/bash|\/usr\/bin\/bash|\/usr\/bin\/sh)$/) {
                printf "%d:%s\n", NR, $0
                continue
            }

            # (c) Some OTHER command word with `bash` after it — a launcher
            #     (env / timeout / $EIGS_TMO / …) that execs the real binary.
            #     This is the case a denylist of names cannot bound.
            if (s ~ /(^|[[:space:]])bash[[:space:]]/) {
                printf "%d:%s\n", NR, $0
                continue
            }

            # Otherwise this segment merely MENTIONS a .sh (a case pattern, a
            # variable holding filenames, an echo of a reproduce hint). Not an
            # invocation, so not judged — this is what keeps the check from
            # crying wolf on the next error-message edit.
        }
    }' || true)
if [ -n "$BADWORD" ]; then
    fail "child script(s) reached through something other than the bash() wrapper (bash must be the COMMAND WORD — a launcher in front of it execs the real binary and leaves the mechanism entirely):"
    printf '%s\n' "$BADWORD" | sed 's/^/    /' >&2
fi
# `command bash` is legitimate exactly 3 times — the wrapper's call-through
# sites (non-script passthrough, captured test_*, uncaptured tools). Pinned so an
# extra one is a review event.
CMD_BASH=$(runner_code | grep -cE '(^|[^a-zA-Z_])command[[:space:]]+bash' || true)
if [ "$CMD_BASH" -ne 3 ]; then
    fail "expected exactly 3 'command bash' (the wrapper's own call-throughs), found $CMD_BASH — an extra one bypasses accounting"
fi

# --- 4. The vacuity waiver list is pinned to the tree ----------------------
# CHILD_NO_MARKERS exempts children that legitimately print no PASS:/FAIL:.
# An exemption that no longer fires must FAIL, not pass quietly: if a listed
# child gains markers, or disappears, the waiver is covering something nobody
# agreed to.
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

# --- 5. Every child measures the binary UNDER TEST (#1188) -----------------
# A child that resolves its runtime as `${EIGS:-<default>}` lets the
# ENVIRONMENT choose which binary it measures. A blind critic exported EIGS at
# a healthy build, ran the suite's own string-scaling section against the
# pre-fix quadratic tree, and got a clean PASS -- the section was measuring a
# different program than the one under test and could not tell.
#
# The fix is central, like the wrapper above: the runner binds EIGS to
# $EIGS_BIN once and exports it, so no dispatch site has to remember. Central
# also means it dies silently if someone removes it, which is what this
# section is for. Both halves are required -- the binding must be DERIVED from
# $EIGS_BIN (a hard-coded path would drift from the variant under test) and it
# must be EXPORTED (an unexported binding reaches no child at all).
ENV_RUNTIME_CHILDREN_DECLARED="${ENV_RUNTIME_CHILDREN_DECLARED:-8}"
if ! grep -qE '^EIGS="\$PWD/\$\{EIGS_BIN#\./\}"$' "$RUNNER"; then
    fail "$RUNNER no longer binds EIGS to \$EIGS_BIN — every child that resolves \${EIGS:-...} now measures whatever the environment says (#1188)"
elif ! grep -qE '^export EIGS$' "$RUNNER"; then
    fail "$RUNNER binds EIGS but does not export it — the binding reaches no child (#1188)"
fi
# The population it protects, pinned exactly in both directions: a new child
# with an environment-selectable runtime is a review event, and a population
# that silently empties would leave this section guarding nothing.
ENV_RUNTIME_CHILDREN=$(grep -lE '^[[:space:]]*EIGS=.?\$\{EIGS:-' tests/test_*.sh 2>/dev/null | grep -c . || true)
if [ "${ENV_RUNTIME_CHILDREN:-0}" -eq 0 ]; then
    fail "found ZERO children resolving \${EIGS:-...} — the scan for them is broken, not the tree (§121)"
elif [ "$ENV_RUNTIME_CHILDREN" -ne "$ENV_RUNTIME_CHILDREN_DECLARED" ]; then
    fail "$ENV_RUNTIME_CHILDREN child test(s) take their runtime from the environment, $ENV_RUNTIME_CHILDREN_DECLARED declared — a child gained or lost an \${EIGS:-...} default; confirm the runner's binding still covers it and bump the number"
fi

if [ "$RC" -eq 0 ]; then
    echo "PASS: child-exit accounting present; $CHILD_SITES child-script sites ($CHILD_SITES_DECLARED declared), no bypass spellings; EIGS bound for $ENV_RUNTIME_CHILDREN environment-selectable child(ren)"
fi

# ---------------------------------------------------------------------------
# --selftest: plant each fault and require the matching assertion to fire.
# Every fault REPLACES text rather than deleting a line (mechanical-gates §41),
# so no length- or count-based neighbour can reject on the target's behalf.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
    ST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs_childgate.XXXXXX") || exit 1
    trap 'rm -rf "$ST_TMP"' EXIT
    ST_RC=0
    st_case() {   # st_case <name> <sed-program> <expected-substring>
        local name="$1" prog="$2" want="$3"
        local f="$ST_TMP/runner.sh"
        sed "$prog" "$RUNNER" > "$f"
        if cmp -s "$f" "$RUNNER"; then
            echo "SELFTEST BROKEN: '$name' did not modify the runner — the fault never existed" >&2
            ST_RC=1; return
        fi
        local out
        out=$(RUNNER="$f" CHILD_SITES_DECLARED="$CHILD_SITES_DECLARED" "$0" 2>&1)
        if [ "$?" -eq 0 ]; then
            echo "SELFTEST FAIL: '$name' was not caught (gate passed a broken runner)" >&2
            ST_RC=1
        elif ! printf '%s\n' "$out" | grep -qF "$want"; then
            # Attribution matters (mechanical-gates §19): a nonzero exit for
            # some OTHER reason is not this case passing.
            echo "SELFTEST FAIL: '$name' failed for the wrong reason; wanted '$want', got:" >&2
            printf '%s\n' "$out" | sed 's/^/    /' >&2
            ST_RC=1
        else
            echo "  selftest ok: $name"
        fi
    }

    st_case "wrapper removed" \
            's/^bash() {/bash_disabled() {/' \
            "does not define the bash() accounting wrapper"
    st_case "synthetic marker reworded away" \
            's/without completing — section verdict is not trustworthy (#988)/completed fine/' \
            "no longer emits the synthetic FAIL: marker"
    st_case "ledger section removed" \
            's/\[99p\] Child-script exit-status ledger/[99p] something else/' \
            "no longer runs the [99p] ledger section"
    st_case "bypass spelling introduced" \
            's|LG_OUTPUT=$(bash "$TESTS_DIR/test_leak_guard.sh" 2>\&1)|LG_OUTPUT=$(/bin/bash "$TESTS_DIR/test_leak_guard.sh" 2>\&1)|' \
            "reached through something other than the bash() wrapper"
    # #1188: the central runtime binding, both halves and its population.
    st_case "runtime binding removed" \
            's|^EIGS="\$PWD/\${EIGS_BIN#\./}"$|EIGS="/some/other/eigenscript"|' \
            "no longer binds EIGS to \$EIGS_BIN"
    st_case "runtime binding not exported" \
            's/^export EIGS$/: EIGS is not exported/' \
            "does not export it"
    # The population is derived from tests/, not from the runner, so this one
    # drives the declared count rather than planting in a file.
    ST_RC_BEFORE=$ST_RC
    st_pop_out=$(ENV_RUNTIME_CHILDREN_DECLARED=99 "$0" 2>&1)
    if [ "$?" -eq 0 ] || ! printf '%s\n' "$st_pop_out" | grep -qF "99 declared"; then
        echo "SELFTEST FAIL: a wrong environment-selectable-child count was not caught" >&2
        ST_RC=1
    else
        echo "  selftest ok: a wrong environment-selectable-child count is caught"
    fi
    : "$ST_RC_BEFORE"

    st_case "second command-bash added" \
            's|CLI_OUTPUT=$(bash "$TESTS_DIR/test_cli.sh" 2>\&1)|CLI_OUTPUT=$(command bash "$TESTS_DIR/test_cli.sh" 2>\&1)|' \
            "an extra one bypasses accounting"

    # Two-sided loss (mechanical-gates §43): the site count is the ONLY thing
    # that sees a site reformatted beyond the matcher's reach, so it gets its
    # own planted fault rather than resting on the one-sided cases above.
    # The realistic shape: an ordinary reformat puts the interpreter and the
    # script path on different lines, so a line-based matcher stops seeing the
    # site.
    #
    # ROUND 11: this plant used to have to shrink the population past a floor
    # 53 sites below it, and had silently stopped doing so. Against an exact
    # declared count it only has to move the number AT ALL — which is the
    # point of the change: the plant is now calibration-free and cannot drift
    # out of reach as the suite grows.
    st_case "population shrunk below the declared count" \
            's|bash "\$TESTS_DIR/\(test_[a-z_]*\.sh\)" 2>&1)|bash \\\
        "$TESTS_DIR/\1" 2>\&1)|' \
            "declared — a child test was added or removed"

    # Positive control (mechanical-gates §15): an UNMODIFIED runner must pass,
    # or a gate that always fails would score 6/6 above.
    if ! RUNNER="$RUNNER" "$0" >/dev/null 2>&1; then
        echo "SELFTEST FAIL: the unmodified runner does not pass — gate fails open-loop" >&2
        ST_RC=1
    else
        echo "  selftest ok: clean control passes"
    fi

    [ "$ST_RC" -eq 0 ] && echo "SELFTEST: all planted faults caught"
    exit "$ST_RC"
fi

exit "$RC"
