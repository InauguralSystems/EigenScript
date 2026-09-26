#!/bin/bash
# Plan dispatch for tests/run_all_tests.sh (#1160, #1275, #1347), sourced by its
# preamble. It is its own file so the planner's self-test (tools/selftests.txt)
# triggers on THIS code, not on every new test section added to the runner.
# Needs TESTS_DIR; a plan run exits here with the plan's verdict.
# ---- Full-suite shard mode (#1160, #1275) ----------------------------------
#   EIGS_SUITE_SHARD=k/N bash run_all_tests.sh
#       run shard k of the weight-balanced full suite. The sanitizer
#       aggregator checks that the shards cover every chunk exactly once.
#   EIGS_SUITE_CHANGED=origin/main bash run_all_tests.sh   (make test-changed)
#       run only the sections the diff against that base touches (#1347):
#       the contributor's fast local gate. CI runs the whole suite.
verify_shard_chunks() {
    # The wrapper's metadata is fixed before execution. The stdout log contains
    # its boundary sentinels and the headers each chunk actually printed.
    local header_re
    header_re=$(bash "$TESTS_DIR/../tools/section_plan.sh" --header-regex) || return 1
    awk -F '\t' -v header_re="$header_re" -v want_bearing="$3" -v want_chunks="$4" '
        function refuse(msg) { print "ERROR: " msg > "/dev/stderr"; bad = 1; exit 1 }
        FNR == NR {
            if ($1 == "# EIGS-EXPECT") {
                n++; start[n] = $2; bearing[n] = $3; first[n] = $4
                declared += $3
            }
            next
        }
        /^@@EIGS-CHUNK [0-9]+@@$/ {
            if (i > 0 && bearing[i] == 1 && !saw)
                refuse("header-bearing chunk at start line " start[i] " printed no header (first source header: " first[i] ")")
            observed = $0
            sub(/^@@EIGS-CHUNK /, "", observed); sub(/@@$/, "", observed)
            i++
            if (i > n) refuse("extra chunk sentinel " observed " after " n " selected chunks")
            if (observed != start[i])
                refuse("chunk sentinel missing or out of order at start line " start[i] " (first source header: " first[i] "; observed " observed ")")
            saw = 0
            next
        }
        $0 ~ header_re { if (i > 0) saw = 1 }
        END {
            if (bad) exit 1
            if (n < 1 || n != want_chunks || declared != want_bearing || want_bearing < 1)
                refuse("chunk witness metadata examined=" n " bearing=" declared " but PLAN promised chunks=" want_chunks " bearing=" want_bearing)
            if (i < n)
                refuse("chunk sentinel missing at start line " start[i + 1] " (first source header: " first[i + 1] ")")
            if (bearing[i] == 1 && !saw)
                refuse("header-bearing chunk at start line " start[i] " printed no header (first source header: " first[i] ")")
            print "CHUNK WITNESS: chunks=" i " bearing=" declared
        }
    ' "$1" "$2"
}
if [ -z "${EIGS_PLAN_ACTIVE:-}" ]; then
    if [ -n "${EIGS_SUITE_SHARD:-}" ] && [ -n "${EIGS_SUITE_CHANGED:-}" ]; then
        echo "ERROR: EIGS_SUITE_SHARD and EIGS_SUITE_CHANGED are exclusive -- set one (#1347)"; exit 1
    fi
    if [ -n "${EIGS_SUITE_SHARD:-}" ] || [ -n "${EIGS_SUITE_CHANGED:-}" ]; then
        __plan_runner=$(mktemp "${TMPDIR:-/tmp}/eigs_plan_runner.XXXXXX")
      if [ -n "${EIGS_SUITE_CHANGED:-}" ]; then
        __plan_line=$(bash "$TESTS_DIR/../tools/section_plan.sh" --emit-changed "$EIGS_SUITE_CHANGED" "$__plan_runner")
        __plan_emit_rc=$?
      else
            # EIGS_SUITE_SHARD=k/N (#1160 round 4). A shard is a subset of the
            # chunk list; the aggregator pins the union to the whole list.
            #
            # THE SHARD NUMBER IS NEVER INFERRED (#1160 round 6). `${v%%/*}`
            # and `${v##*/}` both return the WHOLE string when there is no
            # slash, so `EIGS_SUITE_SHARD=1` used to parse as k=1, n=1 — and a
            # job still named "shard 1/3" would then run the ENTIRE suite while
            # every check stayed green and the wall-time win silently vanished.
            # A malformed value dies here rather than becoming a plausible one.
            case "$EIGS_SUITE_SHARD" in
                *[!0-9/]*|*/*/*|/*|*/)
                    echo "ERROR: EIGS_SUITE_SHARD='$EIGS_SUITE_SHARD' is malformed — it must be k/N with integers (#1160)"
                    rm -f "$__plan_runner"; exit 1 ;;
                */*) ;;
                *)  echo "ERROR: EIGS_SUITE_SHARD='$EIGS_SUITE_SHARD' has no '/N' — a shard number is never inferred; use k/N (#1160)"
                    rm -f "$__plan_runner"; exit 1 ;;
            esac
            __shard_k=${EIGS_SUITE_SHARD%%/*}
            __shard_n=${EIGS_SUITE_SHARD##*/}
            if [ -z "$__shard_k" ] || [ -z "$__shard_n" ] \
               || [ "$__shard_n" -lt 1 ] 2>/dev/null || [ "$__shard_k" -lt 1 ] 2>/dev/null \
               || [ "$__shard_k" -gt "$__shard_n" ] 2>/dev/null; then
                echo "ERROR: EIGS_SUITE_SHARD='$EIGS_SUITE_SHARD' is out of range — need 1 <= k <= N (#1160)"
                rm -f "$__plan_runner"; exit 1
            fi
        __plan_line=$(bash "$TESTS_DIR/../tools/section_plan.sh" --emit-shard "$__shard_k" "$__shard_n" "$__plan_runner")
        __plan_emit_rc=$?
      fi
        # Both conditions: a floor failure prints a PLAN: line on its way out,
        # so "non-empty output" alone would let a refused plan run anyway.
        if [ "$__plan_emit_rc" -ne 0 ] || [ -z "$__plan_line" ]; then
            echo "ERROR: could not derive plan ${EIGS_SUITE_SHARD:-}${EIGS_SUITE_CHANGED:-} -- refusing to run a suite that would measure nothing (#1160)"
            rm -f "$__plan_runner"
            exit 1
        fi
        __plan_bearing=${__plan_line#*bearing=}; __plan_bearing=${__plan_bearing%% *}
        __plan_chunks=${__plan_line#*chunks=}; __plan_chunks=${__plan_chunks%% *}
        case "$__plan_bearing:$__plan_chunks" in
            *[!0-9:]*|:*|*:) echo "ERROR: planner gave invalid chunk counts: $__plan_line"
                            rm -f "$__plan_runner"; exit 1 ;;
        esac
        __plan_log=$(mktemp "${TMPDIR:-/tmp}/eigs_plan_log.XXXXXX")
        # Sentinels stay visible: tee is the only display path, so a failed
        # filter cannot silently hide the LeakSanitizer tally from CI logs.
        bash "$__plan_runner" | tee "$__plan_log"
        __plan_rc=${PIPESTATUS[0]}
        verify_shard_chunks "$__plan_runner" "$__plan_log" "$__plan_bearing" "$__plan_chunks"
        __witness_rc=$?
        # A selected section that SKIPPED here (an extension this build lacks:
        # http, db, gfx...) measured nothing for the change that selected it,
        # and RESULTS shows only a count. Name each one beside the verdict.
        if [ -n "${EIGS_SUITE_CHANGED:-}" ]; then
            __plan_skips=$(awk -v hre="$(bash "$TESTS_DIR/../tools/section_plan.sh" --header-regex)" '
                $0 ~ hre { h = $0; sub(/\].*/, "]", h) }
                /^  SKIP: / { r = $0; sub(/^  SKIP: /, "", r); print "    " h " " r }' "$__plan_log")
            [ -z "$__plan_skips" ] || printf '  NOT RUN LOCALLY (skipped on this build; CI runs them):\n%s\n' "$__plan_skips"
        fi
        rm -f "$__plan_runner" "$__plan_log"
        [ "$__witness_rc" -eq 0 ] || exit 1
        echo "  SECTION PLAN: $__plan_line"
        exit $__plan_rc
    fi
fi
