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
# EIGS_OBS_FORCE IS NOT A FULL BASELINE — read this before trusting a PASS.
#
# The force flag is checked in compile_ast ONE LINE BEFORE the eager load-target
# pre-pass, and arming the gate makes that pass not run. So the FORCE arm
# executes a DIFFERENT CODE PATH from the arm under test: it never exercises the
# eager pass at all. A clean diff therefore proves the two arms AGREE, not that
# the pre-pass is inert — anything the pre-pass does to the program's world
# (it runs the real compiler, which has side effects on trace arming) is
# invisible here except as a divergence.
#
# Bought (2026-08-21, blind critic round 5): the pre-pass was arming the trace
# history channel in the PARENT, so a literal `load_file` path and a computed
# one gave different answers to `prev of x`. This tool was green throughout,
# correctly — no corpus program has that shape.
#
# For a real baseline, capture with a PRE-FEATURE BINARY:
#   git worktree add /tmp/wt-base <pre-feature-rev> && (cd /tmp/wt-base && make)
#   EIGS_GATE_DIFF_BIN=/tmp/wt-base/src/eigenscript tools/observer_gate_diff.sh capture truebase
#   tools/observer_gate_diff.sh compare truebase gated
# That arm runs the code that shipped before the gate existed, which is the
# question a user actually has.
#
# Usage:
#   tools/observer_gate_diff.sh capture <label>      # run corpus with $EIGS_GATE_DIFF_BIN
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
BIN="${EIGS_GATE_DIFF_BIN:-$REPO/src/eigenscript}"

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
        # A program that PRINTS a state_at dict is nondeterministic by
        # construction: trace_state_at walks the prev-table in hash-bucket
        # order and the bucket derives from the interned name POINTER, so the
        # key order changes with ASLR (7 distinct orders in 8 runs; `setarch -R`
        # pins it). No corpus program does this today, which is why the
        # exclusion list has never shown one — but the first that does would be
        # silently reclassified as nondeterministic and dropped from this
        # gate's only full-corpus comparison, exactly the §10 laundering this
        # list exists to prevent. Denied by name in advance; remove when the
        # ordering is made deterministic.
        *state_at*|*statedump*) return 0 ;;
        *) return 1 ;;
    esac
}

corpus() { git ls-files '*.eigs' | sort; }

slug() { echo "$1" | tr '/.' '__'; }

# Every capture records WHICH BINARY produced it. Without this the determinism
# reference is a silent laundering channel: `compare <base> <gated>` uses
# `<base>2` to decide which programs are nondeterministic, and it assumed —
# never checked — that <base> and <base>2 came from the same build. Capture
# them with DIFFERENT builds and every genuine divergence fails the self-diff,
# is reclassified as "nondeterministic", excluded, and the run reports PASS.
#
# Executed by a blind critic (2026-08-22): with the round-5 trace-arming fix
# reverted, `lib/test_runner.eigs` really does diverge (667 lines vs 129,
# byte-identical across 5 runs of each build, so genuinely deterministic).
# Comparing with a mismatched reference moved it from MISMATCH to `nondet:`,
# took `compared` from 416 to 415 — far above the 380 floor, so nothing fired —
# and turned `RESULT: FAIL on 1 program(s)` into `RESULT: PASS`, exit 0.
# mechanical-gates §45: the bypass is a SUPERSET of the population, so the count
# does not move while what it counts is destroyed.
capture_manifest() {
    local dir="$1"
    {
        echo "bin=$(realpath "$BIN" 2>/dev/null || echo "$BIN")"
        # NORMALISED with the runtime's own rule (non-empty and not starting
        # "0" arms it), not recorded raw. Raw `${EIGS_OBS_FORCE:-0}` recorded
        # both "unset" and "=0" as force=0 — and while the runtime used a bare
        # getenv those two behaved OPPOSITELY, so a "gated" arm captured with
        # EIGS_OBS_FORCE=0 ran the BASELINE and this manifest said force=0. The
        # runtime is fixed; normalising here also folds the residual (=2 vs =1
        # are the same arm and must not read as two).
        case "${EIGS_OBS_FORCE:-}" in
            ""|0*) echo "force=0" ;;
            *)     echo "force=1" ;;
        esac
        echo "sha=$( (sha256sum "$BIN" 2>/dev/null || shasum -a 256 "$BIN") | awk '{print $1}')"
        echo "rev=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    } > "$dir/.MANIFEST"
}
manifest_field() { sed -n "s/^$2=//p" "$1/.MANIFEST" 2>/dev/null; }

do_capture() {
    local label="$1"
    [ -x "$BIN" ] || { echo "FAIL: $BIN is not executable — run make first"; exit 2; }
    local dir="$CAPROOT/$label"
    rm -rf "$dir"; mkdir -p "$dir"
    capture_manifest "$dir"
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
        [ -f "$d/.MANIFEST" ] || { echo "FAIL: capture '$d' has no .MANIFEST — recapture it (provenance is required)"; exit 2; }
    done

    # PROVENANCE. The determinism reference must be the SAME build as the
    # baseline, or divergences launder into the exclusion list; and the gated
    # arm must be a DIFFERENT build (or a different gate setting) or you are
    # diffing a build against itself and PASS means nothing.
    local sha_a sha_ref sha_b
    sha_a=$(manifest_field "$da" sha); sha_ref=$(manifest_field "$dref" sha); sha_b=$(manifest_field "$db" sha)
    local frc_a frc_b frc_ref
    frc_a=$(manifest_field "$da" force); frc_b=$(manifest_field "$db" force)
    frc_ref=$(manifest_field "$dref" force)
    echo "provenance: base=${sha_a:0:12}(force=${frc_a:-?}) ref=${sha_ref:0:12}(force=${frc_ref:-?}) gated=${sha_b:0:12}(force=${frc_b:-?})"
    # The second half of the claim, now actually implemented: the two arms must
    # DIFFER in something. Same binary AND same gate setting means the run is
    # diffing a build against itself, and PASS carries no information.
    if [ "$sha_a" = "$sha_b" ] && [ "${frc_a:-0}" = "${frc_b:-0}" ]; then
        echo "FAIL: '$a' and '$b' used the SAME binary AND the same EIGS_OBS_FORCE setting."
        echo "      Nothing distinguishes the arms; this would pass trivially."
        exit 2
    fi
    # An arm's identity is (sha, force) — BOTH axes, for the reference too. This
    # guard ranged over sha alone: capturing '<base>2' with the force flag off
    # while '<base>' had it on made the two arms of the SAME binary disagree on
    # three programs, which the filter then excluded as nondeterministic.
    # Executed on a build with `case OP_REPORT_NAME:` deleted from
    # opcode_is_observer_reader(): honest run reports `mismatches: 3` / rc=1,
    # the reference-swapped run reports `nondet:` x3, `compared: 413`,
    # `RESULT: PASS`, rc=0 — 413 is far above the 380 floor, so nothing fired.
    # mechanical-gates §61: the guard was repaired on the narrower axis (sha, on
    # 2026-08-22) and left open on the other; §45: the bypass is a superset of
    # the population, so the count barely moves while what it counts is gone.
    if [ "$sha_a" != "$sha_ref" ] || [ "${frc_a:-0}" != "${frc_ref:-0}" ]; then
        echo "FAIL: '$a' and '${a}2' were captured with DIFFERENT arms."
        echo "      base=${sha_a:0:12}(force=${frc_a:-?})  ref=${sha_ref:0:12}(force=${frc_ref:-?})"
        echo "      The determinism reference must match the baseline on BOTH the"
        echo "      binary and the gate setting, or every real divergence is excluded"
        echo "      as nondeterminism and this run reports PASS."
        exit 2
    fi

    # Programs that emit NOTHING compare "" == "" — true, and no evidence about
    # the gate. 68 of the 416 in a clean run are silent (63 lib/*.eigs module
    # definitions + 5 fuzz corpus files), i.e. 16% of the headline. Reported
    # rather than hidden: a number that is 16% vacuous should say so (§1/§43).
    local total=0 nondet=0 compared=0 mismatch=0 informative=0 silent=0
    local onesided=0
    local -a NONDET=() MISMATCH=() ONESIDED=()
    while IFS= read -r f; do
        is_denied "$f" && continue
        local s; s="$(slug "$f")"
        # MISSING-IN-ONE-ARM is evidence of a broken capture, not a program to
        # skip. The old `|| continue` treated "absent from one arm" identically
        # to "absent from all three" (a program added to the corpus after the
        # captures), so deleting 30 gated-arm files still printed
        # `compared: 410 ... PASS` — above the 380 floor, nothing fired
        # (mechanical-gates §45: the bypass is a subset small enough that the
        # count barely moves). Absent from ALL arms stays a skip; present in
        # some but not others is a hard FAIL after the loop.
        local have=0
        [ -f "$da/$s" ] && have=$((have+1))
        [ -f "$db/$s" ] && have=$((have+1))
        [ -f "$dref/$s" ] && have=$((have+1))
        if [ "$have" -eq 0 ]; then continue; fi
        if [ "$have" -ne 3 ]; then
            onesided=$((onesided+1)); ONESIDED+=("$f"); continue
        fi
        total=$((total+1))
        if ! cmp -s "$da/$s" "$dref/$s"; then
            nondet=$((nondet+1)); NONDET+=("$f"); continue
        fi
        compared=$((compared+1))
        # "Informative" means the program EMITTED something, not that its
        # capture file is large. The file always ends with the appended `rc=N`
        # line, so a byte threshold measures the width of the exit code:
        # `rc=0` is 5 bytes (silent) but `rc=124` is 7 (scored informative).
        # Executed: a binary that only `exit 124` scored 440/440 informative and
        # PASSED — and 124/134/139 are exactly the timeout/OOM/crash codes this
        # floor's own comment names as its motivating hazard. Strip the rc line
        # and ask whether anything else is there.
        if [ -s "$da/$s" ] && [ -n "$(sed '$d' "$da/$s")" ]; then
            informative=$((informative+1))
        else
            silent=$((silent+1))
        fi
        if ! cmp -s "$da/$s" "$db/$s"; then
            mismatch=$((mismatch+1)); MISMATCH+=("$f")
        fi
    done < <(corpus)

    echo "corpus entries with captures: $total"
    echo "nondeterministic under a FIXED build (excluded): $nondet"
    for f in "${NONDET[@]+"${NONDET[@]}"}"; do echo "    nondet: $f"; done
    if [ "$onesided" -gt 0 ]; then
        echo "FAIL: $onesided program(s) have a capture in SOME arms but not all three."
        for f in "${ONESIDED[@]+"${ONESIDED[@]}"}"; do echo "    one-sided: $f"; done
        echo "      A partial capture is a broken run, not a skippable program — recapture."
        exit 2
    fi
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
    # Programs that emit nothing compare "" == "" and are not evidence. Printing
    # the split (added earlier) is not the same as GATING on it (§37): executed,
    # a do-nothing binary captured three times scored
    # `compared: 440 (informative: 0, silent: 440) ... RESULT: PASS`, which is
    # exactly the vacuous pass this tool's own closing NOTE tells the reader to
    # rule out.
    INFO_FLOOR="${EIGS_GATE_DIFF_INFO_FLOOR:-330}"
    if [ "$informative" -lt "$INFO_FLOOR" ]; then
        echo "RESULT: FAIL — only $informative programs produced output, floor is $INFO_FLOOR."
        echo "        The captures are empty or the binary is not running; this is not a gate result."
        exit 2
    fi

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
