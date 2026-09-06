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
# LOCATION NORMALISATION (#1115) — what `compare` canonicalises, and only that.
#
# An out-of-tree baseline (the flow above) runs a binary whose executable
# directory is NOT this checkout's src/, and the runtime echoes that directory
# into two pieces of text:
#   1. `eigs_file_resolve_error` (src/builtins_host.c) prints the stdlib roots
#      it tried as '<exe-dir>/../<path>' and '<exe-dir>/../lib/eigenscript' —
#      so every "cannot read" error line carries the arm's own exe-dir.
#   2. The project-vs-stdlib import-shadow warning (src/vm.c, `import`) fires
#      only when the project hit and the stdlib hit are DIFFERENT files. In
#      tree, `lib/engineering.eigs` importing `complex` resolves both to this
#      checkout's lib/complex.eigs and stays silent; out of tree the stdlib arm
#      is <arm-tree>/lib/complex.eigs, a different inode with the same bytes,
#      and the warning fires — in that arm only.
# Bought (#1038, both blind critics, three rounds): 7 programs mismatched on
# exactly these two shapes and a clean run read as a 7-program regression.
#
# Before diffing, each arm's capture is passed through ONE normaliser driven by
# that arm's .MANIFEST (`bin=` is the binary's realpath; its dirname is the
# exe-dir the runtime echoes, because /proc/self/exe resolves the same way):
#   - every occurrence of the arm's exe-dir string becomes `<EXE_DIR>`;
#   - a warning line of the EXACT shape
#       Warning: import 'N' ... using '<corpus-tree>/lib/N.eigs', shadowing
#       '<arm-tree>/lib/N.eigs' (project-first; ...)
#     — this checkout's own copy of stdlib module N shadowing the arm's copy of
#     the SAME module — is dropped. Any other collision (a different module in
#     the two paths, a project file outside lib/, a shadowed path not under the
#     arm's tree) is left in place and mismatches.
# Nothing else is touched. Programs whose ONLY difference is one of those two
# shapes are reported by name as `location-only`, and `residual mismatches`
# (the count the RESULT gates on) is what is left after normalisation. The
# normaliser is switched OFF for an arm whose manifest exe-dir is not an
# absolute path with at least one component ('/', '.', '' would rewrite every
# line) — announced on the provenance line, and the arm then compares raw.
#
# Residuals — what compare still CANNOT canonicalise across (each is a real
# axis, not a location artifact, so it deliberately stays a mismatch):
#   - $HOME: the same error line prints '$HOME/.local/lib/eigenscript', and a
#     different HOME can genuinely change resolution (an installed stdlib
#     there wins some lookups). Capture both arms under one HOME.
#   - the corpus tree's own path: 'tried containing directory <checkout>/…'
#     names THIS checkout, so captures must come from one checkout (`capture`
#     always cds here, so this holds unless a capture dir is copied between
#     checkouts).
#   - an argv[0] fallback: without /proc/self/exe the runtime echoes the
#     UNRESOLVED argv[0] directory; the manifest records the realpath. A
#     symlinked binary on such a platform escapes normalisation — loudly, as a
#     mismatch, never silently.
#   - two arms of the SAME build (same sha, same force) at different paths are
#     accepted, but the verdict is `RESULT: LOCATION-CLEAN`, never PASS: that
#     run proves the captures are location-independent, not that a gate did
#     anything. Same build, same force AND same path is still refused.
# `selftest` (below) plants each of these shapes into synthetic captures and
# drives the real `compare` entry point: the location-only shapes must be
# absorbed, and a genuinely different error message, a differently-named
# shadow, a project-file shadow, a corpus-path difference, and the
# root-exe-dir guard must each still FAIL.
#
# Usage:
#   tools/observer_gate_diff.sh capture <label>      # run corpus with $EIGS_GATE_DIFF_BIN
#   tools/observer_gate_diff.sh compare <base> <gated>
#   tools/observer_gate_diff.sh selftest             # synthetic captures, no corpus run (~5s)
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
# The runtime realpath()s the paths it prints in the import-shadow warning, so
# the corpus tree must be matched in resolved form too.
REPO_REAL="$(pwd -P)"

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

# Pure bash: this runs once per corpus entry per compare (520 x 9 in the
# selftest); with a `tr` subprocess each time the selftest took 12.6s, pure
# bash 4.6s (#1115). Same output: `/` and `.` both become `_`.
slug() { local s="${1//\//_}"; echo "${s//./_}"; }

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

# The exe-dir the runtime echoed for this arm: dirname of the manifest's
# realpath'd binary. /proc/self/exe resolves symlinks the same way realpath
# does, and `src/eigenscript` is a HARD link, so the two agree byte-for-byte.
arm_exe_dir() {
    local bin; bin="$(manifest_field "$1" bin)"
    case "$bin" in
        */*) echo "${bin%/*}" ;;
        *)   echo "" ;;
    esac
}

# Is this exe-dir safe to rewrite? An absolute path with at least one
# component. '/', '.', '' or a relative dir would match inside every line.
exe_dir_usable() {
    case "$1" in
        ""|/|.|./*|../*) return 1 ;;
        /*) return 0 ;;
        *)  return 1 ;;
    esac
}

# Normalise ONE capture file of ONE arm to stdout (see the header). $1 = the
# arm's exe-dir ("" disables both rules), $2 = the file. Portable awk only
# (mawk / BSD awk: no gensub, no 3-arg match) — literal index/substr
# replacement, no regex built from a path.
normalise_capture() {
    local exe="$1" file="$2"
    if ! exe_dir_usable "$exe"; then cat "$file"; return; fi
    local tree="${exe%/*}"
    awk -v exe="$exe" -v tree="$tree" -v repo="$REPO_REAL" \
        -v w_pre="Warning: import " \
        -v w_mid=" matches both a project file and a stdlib module — using " \
        -v w_sep=", shadowing " \
        -v w_tail=" (project-first; rename the file to use the stdlib module)" '
    function replace_all(s, from, to,    out, i) {
        out = ""
        while ((i = index(s, from)) > 0) {
            out = out substr(s, 1, i - 1) to
            s = substr(s, i + length(from))
        }
        return out s
    }
    {
        line = $0
        # Rule 2: the location-induced import-shadow warning, exact shape only.
        # Split on the single quotes: 7 fields for the 3 quoted operands.
        if (index(line, w_pre) == 1) {
            n = split(line, f, "\047")
            if (n == 7 && f[1] == w_pre && f[3] == w_mid && f[5] == w_sep && f[7] == w_tail) {
                name = f[2]; used = f[4]; shadowed = f[6]
                if (name != "" && used == repo "/lib/" name ".eigs" &&
                    shadowed == tree "/lib/" name ".eigs" && used != shadowed)
                    next
            }
        }
        # Rule 1: the exe-dir string itself, wherever the runtime echoed it.
        print replace_all(line, exe, "<EXE_DIR>")
    }' "$file"
}

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
    local bin_a bin_b bin_ref exe_a exe_b
    bin_a=$(manifest_field "$da" bin); bin_b=$(manifest_field "$db" bin)
    bin_ref=$(manifest_field "$dref" bin)
    exe_a=$(arm_exe_dir "$da"); exe_b=$(arm_exe_dir "$db")
    echo "provenance: base=${sha_a:0:12}(force=${frc_a:-?}) ref=${sha_ref:0:12}(force=${frc_ref:-?}) gated=${sha_b:0:12}(force=${frc_b:-?})"
    echo "exe-dir: base=${exe_a:-?} gated=${exe_b:-?}"
    # #1115: an arm whose exe-dir cannot be rewritten safely compares RAW.
    # Said out loud (mechanical-gates §11) rather than silently degraded.
    local norm_a="$exe_a" norm_b="$exe_b"
    if ! exe_dir_usable "$exe_a"; then norm_a=""; echo "NOTE: base exe-dir '${exe_a}' is not normalisable — base arm compares raw"; fi
    if ! exe_dir_usable "$exe_b"; then norm_b=""; echo "NOTE: gated exe-dir '${exe_b}' is not normalisable — gated arm compares raw"; fi
    # The second half of the claim, now actually implemented: the two arms must
    # DIFFER in something. Same binary AND same gate setting AND same path means
    # the run is diffing a build against itself, and PASS carries no
    # information. Same binary at a DIFFERENT path is admitted (#1115) — that
    # run is the location-independence check and gets its own verdict word
    # below, never PASS.
    if [ "$sha_a" = "$sha_b" ] && [ "${frc_a:-0}" = "${frc_b:-0}" ] && [ "$bin_a" = "$bin_b" ]; then
        echo "FAIL: '$a' and '$b' used the SAME binary AND the same EIGS_OBS_FORCE setting."
        echo "      Nothing distinguishes the arms; this would pass trivially."
        exit 2
    fi
    local same_build=0
    if [ "$sha_a" = "$sha_b" ] && [ "${frc_a:-0}" = "${frc_b:-0}" ]; then
        same_build=1
        echo "NOTE: '$a' and '$b' are the SAME build (same sha, same force) at two paths:"
        echo "      this run measures location-independence of the captures, not the gate."
    fi
    # An arm's identity is (sha, force, path) — every axis, for the reference
    # too. This guard ranged over sha alone: capturing '<base>2' with the force
    # flag off while '<base>' had it on made the two arms of the SAME binary
    # disagree on three programs, which the filter then excluded as
    # nondeterministic. Executed on a build with `case OP_REPORT_NAME:` deleted
    # from opcode_is_observer_reader(): honest run reports `mismatches: 3` /
    # rc=1, the reference-swapped run reports `nondet:` x3, `compared: 413`,
    # `RESULT: PASS`, rc=0 — 413 is far above the 380 floor, so nothing fired.
    # mechanical-gates §61: the guard was repaired on the narrower axis (sha, on
    # 2026-08-22) and left open on the other; §45: the bypass is a superset of
    # the population, so the count barely moves while what it counts is gone.
    # The path axis (#1115): the self-diff runs RAW, so a reference captured
    # from the same build at another path would exclude every program that
    # echoes the exe-dir as "nondeterministic" — the same laundering, one axis
    # over.
    if [ "$sha_a" != "$sha_ref" ] || [ "${frc_a:-0}" != "${frc_ref:-0}" ] || [ "$bin_a" != "$bin_ref" ]; then
        echo "FAIL: '$a' and '${a}2' were captured with DIFFERENT arms."
        echo "      base=${sha_a:0:12}(force=${frc_a:-?}) at ${bin_a:-?}"
        echo "      ref =${sha_ref:0:12}(force=${frc_ref:-?}) at ${bin_ref:-?}"
        echo "      The determinism reference must match the baseline on the binary,"
        echo "      the gate setting AND the path, or every real divergence is excluded"
        echo "      as nondeterminism and this run reports PASS."
        exit 2
    fi

    # Programs that emit NOTHING compare "" == "" — true, and no evidence about
    # the gate. 68 of the 416 in a clean run are silent (63 lib/*.eigs module
    # definitions + 5 fuzz corpus files), i.e. 16% of the headline. Reported
    # rather than hidden: a number that is 16% vacuous should say so (§1/§43).
    local total=0 nondet=0 compared=0 mismatch=0 informative=0 silent=0
    local onesided=0 loconly=0
    local -a NONDET=() MISMATCH=() ONESIDED=() LOCONLY=()
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
            # Raw bytes differ. Location-only if the normalised texts agree
            # (#1115); residual otherwise. Both arms go through the SAME
            # normaliser, each with its own exe-dir.
            if cmp -s <(normalise_capture "$norm_a" "$da/$s") \
                      <(normalise_capture "$norm_b" "$db/$s"); then
                loconly=$((loconly+1)); LOCONLY+=("$f")
            else
                mismatch=$((mismatch+1)); MISMATCH+=("$f")
            fi
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
    # Every program the normaliser absorbed is named, with the first raw
    # difference, so a reader can see WHAT was canonicalised — a silently
    # absorbed diff is the laundering this tool exists to refuse.
    echo "location-only differences (normalised away: exe-dir, import-shadow): $loconly"
    for f in "${LOCONLY[@]+"${LOCONLY[@]}"}"; do
        echo "    location-only: $f"
        diff "$da/$(slug "$f")" "$db/$(slug "$f")" | grep '^[<>]' | head -2 | cut -c1-160 | sed 's/^/        /'
    done
    echo "residual mismatches: $mismatch"
    for f in "${MISMATCH[@]+"${MISMATCH[@]}"}"; do
        echo "--- MISMATCH: $f"
        diff <(normalise_capture "$norm_a" "$da/$(slug "$f")") \
             <(normalise_capture "$norm_b" "$db/$(slug "$f")") | head -15 | sed 's/^/        /'
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
    if [ "$same_build" -eq 1 ]; then
        # Deliberately NOT the word PASS: nothing about the gate was measured.
        echo "RESULT: LOCATION-CLEAN — $compared programs byte-identical modulo exe-dir"
        echo "NOTE: both arms are the SAME build at two paths. This proves the captures are"
        echo "      location-independent (the #1115 normaliser did its job); it says NOTHING"
        echo "      about the gate. Rebuild the gated arm and compare again for a gate verdict."
        exit 0
    fi
    echo "RESULT: PASS — $compared programs byte-identical"
    echo "NOTE: a clean diff is necessary, not sufficient. It proves nothing unless the"
    echo "      gated build actually gated something — check the gate's own elision"
    echo "      counter, and confirm this harness FAILS against a deliberately broken"
    echo "      build (observer disabled outright) before trusting this PASS."
}

# ---------------------------------------------------------------------------
# selftest — proves the #1115 normaliser absorbs ONLY the two location shapes,
# by driving the REAL `compare` entry point (a subprocess of this script, so
# there is one code path to regress — verify-and-fix: a guard that re-spells
# the command under test is not a guard). Synthetic capture dirs, three
# real corpus names, floors lowered to the synthetic population by the same
# env knobs a user has. No corpus run: ~5s (9 compares x 520 corpus names).
#
# Both halves of every control are present (mechanical-gates §15): the shapes
# that MUST be absorbed (1) and the shapes that MUST still mismatch (2-6), plus
# the provenance guards that must still refuse (7-8) and the normal PASS
# verdict for genuinely different builds (9).
# ---------------------------------------------------------------------------
st_pass=0; st_fail=0
st_ok()   { st_pass=$((st_pass+1)); echo "  ok:   $1"; }
st_bad()  { st_fail=$((st_fail+1)); echo "  FAIL: $1"; printf '%s\n' "$2" | sed 's/^/        /' | head -12; }

# st_arm <dir> <bin> <sha> <force>
st_arm() {
    rm -rf "$1"; mkdir -p "$1"
    printf 'bin=%s\nforce=%s\nsha=%s\nrev=selftest\n' "$2" "$4" "$3" > "$1/.MANIFEST"
}
# st_write <dir> <corpus-name> <content...>  (rc line appended, like capture)
st_write() { local d="$1" f="$2"; shift 2; { printf '%s\n' "$@"; printf 'rc=0\n'; } > "$d/$(slug "$f")"; }

st_compare() {  # prints output; returns compare's rc
    EIGS_GATE_DIFF_DIR="$ST_ROOT" EIGS_GATE_DIFF_FLOOR=1 EIGS_GATE_DIFF_INFO_FLOOR=1 \
        bash "${BASH_SOURCE[0]}" compare "$1" "$2"
}

# The error line the runtime prints, with the exe-dir of the given arm.
st_err() {  # $1 = exe-dir, $2 = missing file name
    printf "Error line 5: import: cannot read '%s.eigs and lib/%s.eigs' (not found or unreadable); tried containing directory '%s/tests', eigs_modules walk, no eigs.json above %s/tests; stdlib roots '%s/../<path>', '%s/../lib/eigenscript', '/home/someone/.local/lib/eigenscript' (also stripping lib/; absolute paths are used as-is)" \
        "$2" "$2" "$REPO_REAL" "$REPO_REAL" "$1" "$1"
}
st_shadow() {  # $1 = name, $2 = using path, $3 = shadowed path
    printf "Warning: import '%s' matches both a project file and a stdlib module — using '%s', shadowing '%s' (project-first; rename the file to use the stdlib module)" "$1" "$2" "$3"
}

do_selftest() {
    ST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ogd_selftest.XXXXXX")"
    trap 'rm -rf "${ST_ROOT:-}"' EXIT
    local -a names=()
    local f
    while IFS= read -r f; do
        is_denied "$f" && continue
        names+=("$f"); [ "${#names[@]}" -ge 3 ] && break
    done < <(corpus)
    if [ "${#names[@]}" -ne 3 ]; then echo "FAIL: selftest needs 3 corpus names, found ${#names[@]}"; exit 2; fi
    local p1="${names[0]}" p2="${names[1]}" p3="${names[2]}"
    local A="$ST_ROOT/fakeA/src" B="$ST_ROOT/fakeB/src"   # two exe-dirs, never created
    local SHA1=1111111111111111111111111111111111111111111111111111111111111111
    local SHA2=2222222222222222222222222222222222222222222222222222222222222222
    local out rc

    # Common fixture: base/base2 at A, gated at B, same sha. p1 echoes the
    # exe-dir; p2 carries the out-of-tree shadow warning in the base arm only
    # (exactly the two #1038 shapes); p3 is plain identical output.
    fixture() {  # $1 = gated sha
        st_arm "$ST_ROOT/base"  "$A/eigenscript" "$SHA1" 0
        st_arm "$ST_ROOT/base2" "$A/eigenscript" "$SHA1" 0
        st_arm "$ST_ROOT/gated" "$B/eigenscript" "$1"    0
        for d in base base2; do
            st_write "$ST_ROOT/$d" "$p1" "hello" "$(st_err "$A" tmp_mod)"
            st_write "$ST_ROOT/$d" "$p2" "$(st_shadow complex "$REPO_REAL/lib/complex.eigs" "$ST_ROOT/fakeA/lib/complex.eigs")" "42"
            st_write "$ST_ROOT/$d" "$p3" "plain"
        done
        st_write "$ST_ROOT/gated" "$p1" "hello" "$(st_err "$B" tmp_mod)"
        st_write "$ST_ROOT/gated" "$p2" "42"
        st_write "$ST_ROOT/gated" "$p3" "plain"
    }

    echo "selftest: observer_gate_diff.sh #1115 location normalisation"

    # 1. The two location-only shapes, same build at two paths: absorbed, and
    #    the verdict is LOCATION-CLEAN (never PASS), rc 0, both programs named.
    fixture "$SHA1"
    out=$(st_compare base gated); rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^residual mismatches: 0$' \
       && printf '%s\n' "$out" | grep -q '^location-only differences.*: 2$' \
       && printf '%s\n' "$out" | grep -q "^    location-only: $p1\$" \
       && printf '%s\n' "$out" | grep -q "^    location-only: $p2\$" \
       && printf '%s\n' "$out" | grep -q '^RESULT: LOCATION-CLEAN' \
       && ! printf '%s\n' "$out" | grep -q '^RESULT: PASS'; then
        st_ok "exe-dir echo + out-of-tree import-shadow warning are absorbed (rc=0, LOCATION-CLEAN, 2 named)"
    else st_bad "location-only shapes not absorbed as specified (rc=$rc)" "$out"; fi

    # 2. A genuinely different error MESSAGE (same exe-dir shape, different
    #    missing file) must survive normalisation: residual 1, rc 1, named.
    fixture "$SHA1"
    st_write "$ST_ROOT/gated" "$p1" "hello" "$(st_err "$B" other_mod)"
    out=$(st_compare base gated); rc=$?
    if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^residual mismatches: 1$' \
       && printf '%s\n' "$out" | grep -q "^--- MISMATCH: $p1\$" \
       && printf '%s\n' "$out" | grep -q '^RESULT: FAIL'; then
        st_ok "a different error message behind the same exe-dir still mismatches (rc=1)"
    else st_bad "real error-text divergence was absorbed (rc=$rc)" "$out"; fi

    # 3. A shadow warning naming a DIFFERENT module in the shadowed path than
    #    in the used path is not the location shape: must survive.
    fixture "$SHA1"
    st_write "$ST_ROOT/base" "$p2" "$(st_shadow complex "$REPO_REAL/lib/complex.eigs" "$ST_ROOT/fakeA/lib/linalg.eigs")" "42"
    cp "$ST_ROOT/base/$(slug "$p2")" "$ST_ROOT/base2/$(slug "$p2")"
    out=$(st_compare base gated); rc=$?
    if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^residual mismatches: 1$' \
       && printf '%s\n' "$out" | grep -q "^--- MISMATCH: $p2\$"; then
        st_ok "a shadow warning naming a different module is NOT absorbed (rc=1)"
    else st_bad "mismatched-module shadow warning was absorbed (rc=$rc)" "$out"; fi

    # 4. A genuine PROJECT-file shadow (used path outside <corpus>/lib/) is a
    #    real diagnostic, not location: must survive.
    fixture "$SHA1"
    st_write "$ST_ROOT/base" "$p2" "$(st_shadow complex "$REPO_REAL/tests/complex.eigs" "$ST_ROOT/fakeA/lib/complex.eigs")" "42"
    cp "$ST_ROOT/base/$(slug "$p2")" "$ST_ROOT/base2/$(slug "$p2")"
    out=$(st_compare base gated); rc=$?
    if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^residual mismatches: 1$' \
       && printf '%s\n' "$out" | grep -q "^--- MISMATCH: $p2\$"; then
        st_ok "a project-file shadow warning (outside lib/) is NOT absorbed (rc=1)"
    else st_bad "project-file shadow warning was absorbed (rc=$rc)" "$out"; fi

    # 5. A path that is NOT the exe-dir (the corpus tree in "tried containing
    #    directory") differing between arms must survive: the normaliser is
    #    specific to the exe-dir string.
    fixture "$SHA1"
    st_write "$ST_ROOT/gated" "$p1" "hello" "$(st_err "$B" tmp_mod | sed "s|containing directory '$REPO_REAL/tests'|containing directory '/elsewhere/tests'|")"
    out=$(st_compare base gated); rc=$?
    if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^residual mismatches: 1$' \
       && printf '%s\n' "$out" | grep -q "^--- MISMATCH: $p1\$"; then
        st_ok "a non-exe-dir path difference is NOT absorbed (rc=1)"
    else st_bad "corpus-path difference was absorbed (rc=$rc)" "$out"; fi

    # 6. Root exe-dir guard: an arm whose binary sits in '/' must compare RAW
    #    (rewriting '/' would erase every path), announced by NOTE.
    fixture "$SHA1"
    st_arm "$ST_ROOT/gated" "/eigenscript" "$SHA1" 0
    st_write "$ST_ROOT/gated" "$p1" "hello" "$(st_err "" tmp_mod)"
    st_write "$ST_ROOT/gated" "$p2" "42"
    st_write "$ST_ROOT/gated" "$p3" "plain"
    out=$(st_compare base gated); rc=$?
    if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^NOTE: gated exe-dir .* not normalisable' \
       && printf '%s\n' "$out" | grep -q '^residual mismatches: 1$'; then
        st_ok "an unusable exe-dir disables normalisation loudly and the arm compares raw (rc=1)"
    else st_bad "root exe-dir guard did not hold (rc=$rc)" "$out"; fi

    # 7. Same build, same force, SAME path is still refused (rc 2).
    fixture "$SHA1"
    st_arm "$ST_ROOT/gated" "$A/eigenscript" "$SHA1" 0
    st_write "$ST_ROOT/gated" "$p1" "x"; st_write "$ST_ROOT/gated" "$p2" "x"; st_write "$ST_ROOT/gated" "$p3" "x"
    out=$(st_compare base gated); rc=$?
    if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'SAME binary AND the same EIGS_OBS_FORCE'; then
        st_ok "same build at the same path is still refused (rc=2)"
    else st_bad "same-build-same-path was not refused (rc=$rc)" "$out"; fi

    # 8. A determinism reference from the same build at ANOTHER path is refused
    #    (the self-diff runs raw, so it would launder exe-dir echoes as nondet).
    fixture "$SHA2"
    st_arm "$ST_ROOT/base2" "$B/eigenscript" "$SHA1" 0
    for p in "$p1" "$p2" "$p3"; do cp "$ST_ROOT/base/$(slug "$p")" "$ST_ROOT/base2/$(slug "$p")"; done
    out=$(st_compare base gated); rc=$?
    if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'captured with DIFFERENT arms'; then
        st_ok "a reference from another path is refused (rc=2)"
    else st_bad "path-mismatched reference was accepted (rc=$rc)" "$out"; fi

    # 9. Genuinely different builds, location-only differences: the normal
    #    gate verdict PASS, rc 0, with the 2 absorbed programs still named.
    fixture "$SHA2"
    out=$(st_compare base gated); rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^RESULT: PASS' \
       && printf '%s\n' "$out" | grep -q '^location-only differences.*: 2$' \
       && printf '%s\n' "$out" | grep -q '^residual mismatches: 0$'; then
        st_ok "different builds, location-only differences: PASS with the 2 absorbed programs named"
    else st_bad "different-build clean run did not PASS as specified (rc=$rc)" "$out"; fi

    echo "SELFTEST: $st_pass ok, $st_fail failed (of 9)"
    [ "$st_fail" -eq 0 ] && [ "$st_pass" -eq 9 ]
}

case "${1:-}" in
    capture) shift; do_capture "${1:?usage: capture <label>}" ;;
    compare) shift; do_compare "${1:?usage: compare <base> <gated>}" "${2:?usage: compare <base> <gated>}" ;;
    selftest) do_selftest ;;
    *) echo "usage: $0 capture <label> | compare <base> <gated> | selftest"; exit 2 ;;
esac
