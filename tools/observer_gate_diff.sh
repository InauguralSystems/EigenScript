#!/usr/bin/env bash
# observer_gate_diff.sh — full-corpus differential oracle for the #915
# observer-emission gate.
#
# The gate skips observer bookkeeping for programs that can never interrogate
# it. The whole risk of that change is SILENT-WRONG: a program that does reach
# the observer, misclassified as one that does not, still runs and still prints
# something — just with a dead observer channel. No crash, no leak, no failing
# assert unless a test happens to assert on the affected binding. So the bar is
# not "the suite passes", it is "every tracked .eigs program produces
# BYTE-IDENTICAL stdout+stderr+exit code under both builds".
#
# WHY capture/compare INSTEAD OF two binary paths. The runtime resolves its
# stdlib relative to its own executable directory (/proc/self/exe), so a build
# copied or hard-linked outside src/ silently loses `load_file` of lib modules —
# it would still run, and the diff would then be measuring a broken stdlib path
# rather than the gate. `src/eigenscript` is a hard link the Makefile re-points
# per variant, so only ONE build is runnable at a time. This script therefore
# captures one build at a time and diffs the captures afterwards.
#
# Usage:
#   tools/observer_gate_diff.sh capture <label>      # run corpus with src/eigenscript
#   tools/observer_gate_diff.sh compare <base> <gated>
#
# Typical run:
#   make                                    # baseline build
#   tools/observer_gate_diff.sh capture base1
#   tools/observer_gate_diff.sh capture base2     # SAME build, for the determinism pass
#   ...apply the gate, make...
#   tools/observer_gate_diff.sh capture gated
#   tools/observer_gate_diff.sh compare base1 gated
#
# `compare` needs base1 AND base2 to exist: programs that do not match
# themselves across two runs of one FIXED build are nondeterministic (clocks,
# rng, threads, sockets, addresses) and are excluded, by name, with a count.
# Without that pass the diff reports nondeterminism as gate breakage and the
# real signal drowns. The exclusion list is printed in full every run — a
# silently growing skip list is how a gate ends up measuring less than it claims.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 2

CAPROOT="${EIGS_GATE_DIFF_DIR:-$REPO/.observer_gate_captures}"
TIMEOUT="${EIGS_GATE_DIFF_TIMEOUT:-25}"
BIN="$REPO/src/eigenscript"

# Excluded up front, with the reason. Each entry is a decision, not a
# convenience. gfx programs open a real window and would hang or flood a
# headless run; the ulimit is because an unbounded gfx run can freeze this box.
is_denied() {
    case "$1" in
        *gfx*|*paint*|*_game*) return 0 ;;
        # A fixture whose PURPOSE is nondeterminism does not belong in a
        # statistical filter at all (mechanical-gates §10 — a rule this very
        # tool's issue bought, and which this tool then violated). The two-run
        # self-diff below can only exclude programs that DISAGREE with
        # themselves in those two samples; a seeded race can easily agree twice
        # and then diverge in the third capture, which reports as the gate
        # changing observable behaviour.
        #
        # Executed, 2026-08-21: tsan_seeded_race.eigs did exactly that and cost
        # a real investigation of a regression that did not exist. Measured
        # afterwards on ONE fixed build: 8 runs of the gated arm produced stderr
        # of 43/268/43/43/43/43/43/43 bytes, and 8 of the baseline arm
        # 246/43/43/43/43/43/43/166 — nondeterministic in BOTH arms, and it
        # SIGSEGVs under the capture ulimit either way.
        *seeded_race*) return 0 ;;
        *) return 1 ;;
    esac
}

corpus() { git ls-files '*.eigs' | sort; }

slug() { echo "$1" | tr '/.' '__'; }

do_capture() {
    local label="$1"
    [ -x "$BIN" ] || { echo "FAIL: $BIN is not executable — run make first"; exit 2; }
    local dir="$CAPROOT/$label"
    rm -rf "$dir"; mkdir -p "$dir"
    local n=0 skipped=0
    while IFS= read -r f; do
        if is_denied "$f"; then skipped=$((skipped+1)); continue; fi
        (
            ulimit -v 1500000 2>/dev/null
            timeout "$TIMEOUT" "$BIN" "$f"
        ) >"$dir/$(slug "$f")" 2>&1
        printf 'rc=%s\n' "$?" >>"$dir/$(slug "$f")"
        n=$((n+1))
    done < <(corpus)
    echo "captured $n programs into $dir (denied up front: $skipped)"
}

do_compare() {
    local a="$1" b="$2"
    local da="$CAPROOT/$a" db="$CAPROOT/$b"
    # The determinism reference is a SECOND capture of the baseline build. It is
    # not optional: without it this script cannot tell a nondeterministic program
    # from a gate regression, and would report the former as the latter.
    local dref="$CAPROOT/${a}2"
    for d in "$da" "$db" "$dref"; do
        [ -d "$d" ] || { echo "FAIL: missing capture '$d' (need <base>, <base>2 and <gated>)"; exit 2; }
    done

    # Programs that emit NOTHING compare "" == "" — true, and no evidence about
    # the gate. 68 of the 416 in a clean run are silent (63 lib/*.eigs module
    # definitions + 5 fuzz corpus files), i.e. 16% of the headline. Reported
    # rather than hidden: a number that is 16% vacuous should say so (§1/§43).
    local total=0 nondet=0 compared=0 mismatch=0 informative=0 silent=0
    local -a NONDET=() MISMATCH=()
    while IFS= read -r f; do
        is_denied "$f" && continue
        local s; s="$(slug "$f")"
        [ -f "$da/$s" ] && [ -f "$db/$s" ] && [ -f "$dref/$s" ] || continue
        total=$((total+1))
        if ! cmp -s "$da/$s" "$dref/$s"; then
            nondet=$((nondet+1)); NONDET+=("$f"); continue
        fi
        compared=$((compared+1))
        if [ "$(wc -c < "$da/$s")" -le 6 ]; then silent=$((silent+1)); else informative=$((informative+1)); fi
        if ! cmp -s "$da/$s" "$db/$s"; then
            mismatch=$((mismatch+1)); MISMATCH+=("$f")
        fi
    done < <(corpus)

    echo "corpus entries with captures: $total"
    echo "nondeterministic under a FIXED build (excluded): $nondet"
    for f in "${NONDET[@]+"${NONDET[@]}"}"; do echo "    nondet: $f"; done
    echo "compared: $compared (informative: $informative, silent: $silent)"
    echo "mismatches: $mismatch"
    for f in "${MISMATCH[@]+"${MISMATCH[@]}"}"; do
        echo "--- MISMATCH: $f"
        diff "$da/$(slug "$f")" "$db/$(slug "$f")" | head -15 | sed 's/^/        /'
    done

    # ABSOLUTE population floor, not just a ratio. The ratio below divides
    # `compared` by `total`, and `total` is itself derived from "a capture file
    # exists in all three dirs" — so a capture run killed partway (OOM, timeout,
    # thrash: all live hazards on a 2-core/4GB box) drops programs from the
    # numerator AND the denominator together and leaves the ratio perfect.
    # Executed by a blind critic: three EMPTY capture dirs produced
    # `RESULT: PASS — 0 programs byte-identical`, exit 0, and a run truncated
    # after 3 of 444 produced `PASS — 3`. Neither is distinguishable from a real
    # 417 by this tool's exit code, which is the whole job of an exit code.
    # A floor moves only when coverage is REMOVED (mechanical-gates §5/§43).
    CORPUS_FLOOR="${EIGS_GATE_DIFF_FLOOR:-380}"
    if [ "$compared" -lt "$CORPUS_FLOOR" ]; then
        echo "RESULT: FAIL — compared $compared programs, floor is $CORPUS_FLOOR."
        echo "        A capture is truncated or the corpus shrank; this is not a gate result."
        exit 2
    fi

    # A corpus gone mostly nondeterministic means the instrument is unreliable
    # (or the box is thrashing) — not that the gate is clean.
    if [ "$compared" -lt $(( total / 2 )) ]; then
        echo "RESULT: FAIL — under half the corpus is deterministic; instrument unreliable, not a gate result"
        exit 2
    fi
    if [ "$mismatch" -gt 0 ]; then
        echo "RESULT: FAIL — the gate changed observable behaviour on $mismatch program(s)"
        exit 1
    fi
    echo "RESULT: PASS — $compared programs byte-identical"
    echo "NOTE: a clean diff is necessary, not sufficient. It proves nothing unless the"
    echo "      gated build actually gated something — check the gate's own elision"
    echo "      counter, and confirm this harness FAILS against a deliberately broken"
    echo "      build (observer disabled outright) before trusting this PASS."
}

case "${1:-}" in
    capture) shift; do_capture "${1:?usage: capture <label>}" ;;
    compare) shift; do_compare "${1:?usage: compare <base> <gated>}" "${2:?usage: compare <base> <gated>}" ;;
    *) echo "usage: $0 capture <label> | compare <base> <gated>"; exit 2 ;;
esac
