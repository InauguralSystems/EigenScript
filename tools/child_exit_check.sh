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
# #1264 — A FLOOR AGAIN, AND THIS TIME THE PLANT CANNOT DRIFT OUT OF REACH.
# Round 11 made this an exact count (`CHILD_SITES_DECLARED`), because the old
# floor (60) had fallen 53 below a population of 113 and its planted shrink —
# a fixed handful of sites — no longer crossed it. The exact pin fixed the
# PLANT, and in exchange turned every added child test into a hand bump of this
# line: PR #1260 (a correct 5-line fix) had to move it 121 -> 122, then hit a
# merge conflict on the same number (main had moved it to 125), which also
# stopped CI from running at all. Adding a child is growth, and growth is not
# a review event (mechanical-gates §5: floors for a growing total, exact counts
# for a declared set). A REMOVAL is the review event, and a floor edit is how
# one is declared.
#
# What round 11 actually diagnosed was a plant CALIBRATED against a constant
# (§74). The selftest below no longer hand-picks a shrink: it DERIVES it from
# the live count, reformatting exactly (found - floor + 1) sites, so it lands
# one below the floor however far the population has grown, and a control
# that lands exactly ON the floor must pass. The floor can go stale-low as the
# suite grows (§175) — the PASS line prints the slack so that is visible, and
# the transverse check for the case that matters most (a child test nobody
# runs any more) is tools/test_enrolment_check.sh, which names the file.
#
# To remove a child deliberately: lower this floor in the same commit.
# To tighten after growth: raise it to the PASS line's count (optional; never
# required by an addition).
#
# The metric is LINES carrying an invocation, not invocations: a few sites run
# two children on one line (`if bash A && bash B --selftest; then`), so the
# true invocation count is higher. Lines are what this is measured in; do not
# "correct" it to invocations without re-measuring.
CHILD_SITES_FLOOR="${CHILD_SITES_FLOOR:-130}"

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

# --- 2. Population, floored ------------------------------------------------
# Every executable line invoking a `.sh` child through the wrapper.
CHILD_SITES=$(runner_code | grep -cE '(^|[^a-zA-Z_])bash[[:space:]]+("?\$(TESTS_DIR|\{TESTS_DIR\})"?[^|;)]*\.sh|"[^"]*\.sh")')
case "$CHILD_SITES_FLOOR" in ''|*[!0-9]*|0) fail "CHILD_SITES_FLOOR='$CHILD_SITES_FLOOR' is not a positive integer — a knob that can turn the verdict green is part of the verdict (§157)" ; CHILD_SITES_FLOOR=1 ;; esac
if [ "$CHILD_SITES" -lt "$CHILD_SITES_FLOOR" ]; then
    fail "$CHILD_SITES child-script invocation sites found, below the floor of $CHILD_SITES_FLOOR — a child test was removed, or a site was reformatted out of this matcher's reach. If the removal is deliberate, lower CHILD_SITES_FLOOR in the same commit"
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
# The population the binding protects GROWS with every child that defaults
# its runtime from the environment, and the binding covers a new one without
# anyone touching it — so it is a floor (#1264), not an exact pin: adding such
# a child needs no edit here, and losing them fails.
ENV_RUNTIME_CHILDREN_FLOOR="${ENV_RUNTIME_CHILDREN_FLOOR:-8}"
if ! grep -qE '^EIGS="\$PWD/\$\{EIGS_BIN#\./\}"$' "$RUNNER"; then
    fail "$RUNNER no longer binds EIGS to \$EIGS_BIN — every child that resolves \${EIGS:-...} now measures whatever the environment says (#1188)"
elif ! grep -qE '^export EIGS$' "$RUNNER"; then
    fail "$RUNNER binds EIGS but does not export it — the binding reaches no child (#1188)"
fi
# The population it protects, floored: a population that silently empties (or
# shrinks) would leave this section guarding less than it claims.
ENV_RUNTIME_CHILDREN=$(grep -lE '^[[:space:]]*EIGS=.?\$\{EIGS:-' tests/test_*.sh 2>/dev/null | grep -c . || true)
if [ "${ENV_RUNTIME_CHILDREN:-0}" -eq 0 ]; then
    fail "found ZERO children resolving \${EIGS:-...} — the scan for them is broken, not the tree (§121)"
elif [ "$ENV_RUNTIME_CHILDREN" -lt "$ENV_RUNTIME_CHILDREN_FLOOR" ]; then
    fail "$ENV_RUNTIME_CHILDREN child test(s) take their runtime from the environment, below the floor of $ENV_RUNTIME_CHILDREN_FLOOR — a child lost its \${EIGS:-...} default or was removed, or the scan for them narrowed; lower ENV_RUNTIME_CHILDREN_FLOOR in the same commit if deliberate"
fi

if [ "$RC" -eq 0 ]; then
    echo "PASS: child-exit accounting present; $CHILD_SITES child-script sites (floor $CHILD_SITES_FLOOR, slack $((CHILD_SITES - CHILD_SITES_FLOOR))), no bypass spellings; EIGS bound for $ENV_RUNTIME_CHILDREN environment-selectable child(ren) (floor $ENV_RUNTIME_CHILDREN_FLOOR)"
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
        out=$(RUNNER="$f" CHILD_SITES_FLOOR="$CHILD_SITES_FLOOR" bash "$0" 2>&1)
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
    # drives the floor rather than planting in a file: a floor one ABOVE the
    # live count must fail, the live count itself must pass (derived, never
    # hand-typed — §177).
    st_env_n=$(grep -lE '^[[:space:]]*EIGS=.?\$\{EIGS:-' tests/test_*.sh 2>/dev/null | grep -c . || true)
    st_pop_out=$(ENV_RUNTIME_CHILDREN_FLOOR=$((st_env_n + 1)) bash "$0" 2>&1)
    if [ "$?" -eq 0 ] || ! printf '%s\n' "$st_pop_out" | grep -qF "below the floor of $((st_env_n + 1))"; then
        echo "SELFTEST FAIL: an environment-selectable-child population below its floor was not caught" >&2
        ST_RC=1
    else
        echo "  selftest ok: an environment-selectable-child population below its floor is caught"
    fi
    if ! ENV_RUNTIME_CHILDREN_FLOOR="$st_env_n" bash "$0" >/dev/null 2>&1; then
        echo "SELFTEST FAIL: a population exactly AT its floor ($st_env_n) failed — the comparison is off by one" >&2
        ST_RC=1
    else
        echo "  selftest ok: an environment-selectable-child population exactly at its floor passes"
    fi

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
    # #1264: the number of sites reformatted is DERIVED from the live count
    # (found - floor + 1), so the plant lands exactly one below the floor
    # however far the suite has grown — the drift round 11 found cannot recur.
    # Its twin reformats (found - floor) sites, lands exactly ON the floor, and
    # must pass: the boundary is witnessed from both sides.
    st_live=$(runner_code | grep -cE '(^|[^a-zA-Z_])bash[[:space:]]+("?\$(TESTS_DIR|\{TESTS_DIR\})"?[^|;)]*\.sh|"[^"]*\.sh")')
    st_reformat() {   # st_reformat <n> <outfile>: split the first n capture sites
        awk -v n="$1" '
            n > 0 && /bash "\$TESTS_DIR\/test_[a-z_]*\.sh" 2>&1\)/ && $0 !~ /^[[:space:]]*#/ {
                sub(/bash "\$TESTS_DIR\//, "bash \\\n        \"$TESTS_DIR/"); n--
            }
            { print }' "$RUNNER" > "$2"
    }
    st_drop=$((st_live - CHILD_SITES_FLOOR + 1))
    st_reformat "$st_drop" "$ST_TMP/below.sh"
    st_below=$(sed 's/[[:space:]]*#.*$//' "$ST_TMP/below.sh" | grep -cE '(^|[^a-zA-Z_])bash[[:space:]]+("?\$(TESTS_DIR|\{TESTS_DIR\})"?[^|;)]*\.sh|"[^"]*\.sh")')
    if [ "$st_below" -ne $((CHILD_SITES_FLOOR - 1)) ]; then
        # Not a survivor (§137): the plant could not be BUILT. With the floor
        # this far below the live count there are not enough reformattable
        # capture sites to reach it — which is itself the staleness alarm
        # §175 asks for, at a slack of roughly fifty sites rather than one.
        echo "SELFTEST BROKEN: the derived shrink plant produced $st_below sites, wanted $((CHILD_SITES_FLOOR - 1)) (live $st_live, floor $CHILD_SITES_FLOOR) — the floor is stale-low; raise CHILD_SITES_FLOOR to $st_live" >&2
        ST_RC=1
    else
        st_out=$(RUNNER="$ST_TMP/below.sh" CHILD_SITES_FLOOR="$CHILD_SITES_FLOOR" bash "$0" 2>&1)
        if [ "$?" -eq 0 ] || ! printf '%s\n' "$st_out" | grep -qF "below the floor of $CHILD_SITES_FLOOR"; then
            echo "SELFTEST FAIL: a population one below the floor ($st_below < $CHILD_SITES_FLOOR) was not caught" >&2
            printf '%s\n' "$st_out" | sed 's/^/    /' >&2
            ST_RC=1
        else
            echo "  selftest ok: population shrunk to floor-1 ($st_below, $st_drop site(s) reformatted) is caught"
        fi
    fi
    st_reformat "$((st_drop - 1))" "$ST_TMP/at.sh"
    if ! RUNNER="$ST_TMP/at.sh" CHILD_SITES_FLOOR="$CHILD_SITES_FLOOR" bash "$0" >/dev/null 2>&1; then
        echo "SELFTEST FAIL: a population exactly AT the floor ($CHILD_SITES_FLOOR) failed — off by one, or the reformat broke something else" >&2
        ST_RC=1
    else
        echo "  selftest ok: population exactly at the floor ($CHILD_SITES_FLOOR) passes"
    fi
    # Growth is free: one more child site, no edit anywhere.
    { cat "$RUNNER"; printf '\nZZ_OUTPUT=$(bash "$TESTS_DIR/test_zz_growth.sh" 2>&1)\n'; } > "$ST_TMP/grown.sh"
    if ! RUNNER="$ST_TMP/grown.sh" CHILD_SITES_FLOOR="$CHILD_SITES_FLOOR" bash "$0" >/dev/null 2>&1; then
        echo "SELFTEST FAIL: ADDING a child site failed the gate — growth must need no edit (#1264)" >&2
        ST_RC=1
    else
        echo "  selftest ok: adding a child site needs no edit"
    fi

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
