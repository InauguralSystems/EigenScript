#!/usr/bin/env bash
# tools/phase2_corpus_diff.sh <baseline-binary> <branch-binary> -- #1758: the
# behaviour differential of a mechanical round (docs/design/phase2-numbers.md
# 8, R1.1 and R1.2): "unchanged" is measured, not inferred from a green suite.
#
# Every .eigs file under the BRANCH tree's tests/ runs twice with each binary,
# all four runs from the branch tree's src/ (the suite's cwd) as
# `../tests/<file>`, so a file and whatever it loads by a relative path are the
# same bytes for both; only the binary and the stdlib next to it differ.
# stdin /dev/null, a 60 s bound, `env -u XAUTHORITY DISPLAY=:99`. stdout,
# stderr and the exit code are compared byte for byte after one
# normalisation: each tree's absolute root becomes `<ROOT>`.
#
# THE SEED PIN. The runtime has no seed flag or variable: an unseeded program
# seeds itself from CLOCK_MONOTONIC ^ getpid() (src/builtins.c,
# random_seed_once). An LD_PRELOAD shim, built here, pins every srand48 seed
# of 2^20 or more (the self-seed's range) to one constant and passes smaller
# ones (an explicit `seed_random of 99`) through. So a program that draws
# random numbers runs deterministically and LIVE in both binaries, and a
# branch change to a random builtin shows wherever the corpus observes it
# (test_optimize.eigs prints a genetic search driven by random_int;
# test_system.eigs checks random_int's bounds over 300 draws). The run checks
# its precondition first: two pinned `random` draws must agree, else the shim
# did not load and the run fails. That the pin is what makes such a file
# comparable live is calibrated once (phase2_check.py --selftest, plant D),
# not re-proven here. Blind spot: an explicit seed of 2^20 or more is pinned
# too, so a branch change in how `seed_random` uses such a seed is invisible.
#
# VERDICTS. A file is DETERMINISTIC when the baseline's two runs agree; then
# any branch run that disagrees is a DIFF row (no second chance: a branch
# that is wrong on alternate runs is wrong). When the baseline disagrees with
# itself even with the seed pin (timing, thread scheduling) the file is
# adjudicated on a TAPE, the last resort (docs/TRACE.md: a tape recorded by
# one binary replays on another): the baseline records it and replays it
# twice, the branch replays it once, and the branch must match
# (`same_under_replay`) or it is a DIFF. Replay serves the baseline's
# recorded nondeterministic values, so a builtin's own behaviour is
# INVISIBLE on those files; the report lists them. Replays that disagree
# with each other (the documented thread/subprocess boundary) are NONDET.
# A crash or timeout both binaries agree on is counted by name, never "same".
#
# MEMORY. No blanket cap (a 2 GiB `ulimit -v` made handles_full.eigs's 300
# spawns fail at 134-214, which read as nondeterminism -- the R1.1 critic).
# Only a file that drives the gfx/ui/audio surface runs under
# `ulimit -v 2097152` (an unbounded GUI run can freeze the 4 GB box); the
# capped files are listed.
#
# A file only the branch tree has (a new fixture) is counted as `new`; a file
# only the baseline tree has is a DELETED row (a deleted test hides a change).
# Prints `.. <n>/<N> <file> <verdict> <s>s` per file, DIFF/DELETED rows, the
# replay, NONDET, crash and cap lists, then `corpus-diff: examined=N same=S
# same_under_replay=R nondet=K diff=D new=W deleted=X crash_both=C
# timeout_both=T capped=M` and `corpus-diff: PASS|FAIL`. Exit 0 only for
# diff=0 deleted=0, examined equal to the files listed (> 0), and a seed pin
# that proved itself.
#
# PHASE2_DIFF_FILES=<list file> restricts the corpus to the listed relative
# paths, for the calibration (tools/phase2_check.sh --calibrate). A restricted
# run prints `corpus-diff: RESTRICTED ...` instead of a verdict and exits 3:
# it can never pass for the whole corpus.
set -u
[ $# -eq 2 ] || { echo "usage: tools/phase2_corpus_diff.sh <baseline-binary> <branch-binary>"; exit 2; }
abspath() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }
BASE_BIN=$(abspath "$1") || exit 2
BR_BIN=$(abspath "$2") || exit 2
BASE_ROOT=$(cd "$(dirname "$BASE_BIN")/.." && pwd -P)
BR_ROOT=$(cd "$(dirname "$BR_BIN")/.." && pwd -P)
for b in "$BASE_BIN" "$BR_BIN"; do [ -x "$b" ] || { echo "corpus-diff: FAIL: $b is not executable"; exit 2; }; done
command -v timeout >/dev/null 2>&1 || { echo "corpus-diff: FAIL: needs coreutils timeout (local tool)"; exit 2; }
command -v cc >/dev/null 2>&1 || { echo "corpus-diff: FAIL: needs a C compiler for the seed pin"; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-corpus-diff.XXXXXX") || exit 2
DONE=0
trap 'rc=$?; [ "$DONE" = 1 ] || echo "corpus-diff: FAIL: exited ($rc) before a verdict, at: $BASH_COMMAND"; rm -rf "$TMP"' EXIT

# ---- the seed pin --------------------------------------------------------
cat > "$TMP/seedpin.c" <<'CSRC'
#define _GNU_SOURCE
#include <dlfcn.h>
/* phase2_corpus_diff.sh: pin the runtime's clock^pid self-seed (>= 2^20) to
 * a constant; an explicit small seed passes through. */
void srand48(long seed) {
    static void (*real)(long);
    if (!real) real = (void (*)(long))dlsym(RTLD_NEXT, "srand48");
    real((seed >= (1L << 20) || seed < 0) ? 0x5EEDL : seed);
}
CSRC
WERROR_FLAGS_FILE="$(dirname "$0")/werror_flags.txt"
. "$(dirname "$0")/read_werror_flags.sh" 2>&1 || exit 2
# shellcheck disable=SC2086  # the shared flags are one word each
if ! cc $WERROR_FLAGS -shared -fPIC -O2 -o "$TMP/seedpin.so" "$TMP/seedpin.c" -ldl > "$TMP/seedpin.log" 2>&1; then
    sed 's/^/  seedpin cc: /' "$TMP/seedpin.log"
    echo "corpus-diff: FAIL: the seed pin did not build"; DONE=1; exit 1
fi
SHIM="$TMP/seedpin.so"
printf 'print of (random of null)\n' > "$TMP/seedprobe.eigs"
# Each probe answers one number on stdout and nothing on stderr; anything
# else is shown and fails (the probe's grammar, not a substring of it).
p1=$(cd "$TMP" && LD_PRELOAD="$SHIM" "$BR_BIN" seedprobe.eigs 2> "$TMP/probe1.err" < /dev/null)
p2=$(cd "$TMP" && LD_PRELOAD="$SHIM" "$BR_BIN" seedprobe.eigs 2> "$TMP/probe2.err" < /dev/null)
echo "corpus-diff: seed pin: two pinned draws $p1 / $p2"
sed 's/^/  seed probe stderr: /' "$TMP/probe1.err" "$TMP/probe2.err"
if [ -s "$TMP/probe1.err" ] || [ -s "$TMP/probe2.err" ] || ! grep -Eqx '[0-9]+([.][0-9]+)?(e-[0-9]+)?' <<< "$p1" \
        || [ "$p1" != "$p2" ]; then
    echo "corpus-diff: FAIL: the seed pin did not take (two pinned draws must print one equal number, no stderr)"
    DONE=1; exit 1
fi

# ---- the population ------------------------------------------------------
if [ -n "${PHASE2_DIFF_FILES:-}" ]; then
    LC_ALL=C sort "$PHASE2_DIFF_FILES" > "$TMP/files"
    while IFS= read -r rel; do
        [ -f "$BR_ROOT/$rel" ] || { echo "corpus-diff: FAIL: restricted list names $rel, absent from the branch tree"; DONE=1; exit 1; }
    done < "$TMP/files"
else
    (cd "$BR_ROOT" && find tests -name '*.eigs' -type f | LC_ALL=C sort) > "$TMP/files"
fi
listed=$(grep -c . "$TMP/files")
[ "$listed" -gt 0 ] || { echo "corpus-diff: FAIL: no .eigs file to run"; DONE=1; exit 1; }
echo "corpus-diff: baseline $BASE_BIN ($("$BASE_BIN" --version 2>&1 | head -1)) sha256 $(sha256sum "$BASE_BIN" | cut -c1-16)"
echo "corpus-diff: branch   $BR_BIN ($("$BR_BIN" --version 2>&1 | head -1)) sha256 $(sha256sum "$BR_BIN" | cut -c1-16)"
echo "corpus-diff: files=$listed${PHASE2_DIFF_FILES:+ (RESTRICTED by PHASE2_DIFF_FILES)}"

# run BIN REL OUT CAP [VAR=value] -> OUT.out OUT.err OUT.rc, root paths
# normalised; CAP=1 runs under the GUI memory cap.
run() {
    local bin="$1" rel="$2" out="$3" cap="$4" extra="${5:-PHASE2_DIFF=1}" rc
    (
        cd "$BR_ROOT/src" || exit 99
        [ "$cap" = 1 ] && ulimit -v 2097152
        exec env -u XAUTHORITY DISPLAY=:99 LD_PRELOAD="$SHIM" "$extra" timeout 60 "$bin" "../$rel"
    ) < /dev/null > "$out.rawout" 2> "$out.rawerr"
    rc=$?
    echo "$rc" > "$out.rc"
    sed "s|$BASE_ROOT|<ROOT>|g; s|$BR_ROOT|<ROOT>|g" "$out.rawout" > "$out.out"
    sed "s|$BASE_ROOT|<ROOT>|g; s|$BR_ROOT|<ROOT>|g" "$out.rawerr" > "$out.err"
}
same() { cmp -s "$1.out" "$2.out" && cmp -s "$1.err" "$2.err" && cmp -s "$1.rc" "$2.rc"; }
show_diff() {
    diff "$1.out" "$2.out" | head -8 | sed 's/^/    stdout: /'
    diff "$1.err" "$2.err" | head -8 | sed 's/^/    stderr: /'
}

examined=0; nsame=0; nreplay=0; nondet=0; ndiff=0; new=0; crash_both=0; timeout_both=0; capped=0
: > "$TMP/new"; : > "$TMP/nondet"; : > "$TMP/crash"; : > "$TMP/replayed"; : > "$TMP/capped"
(cd "$BASE_ROOT" && find tests -name '*.eigs' -type f | LC_ALL=C sort) > "$TMP/basefiles"
if [ -n "${PHASE2_DIFF_FILES:-}" ]; then
    : > "$TMP/deleted"
else
    LC_ALL=C comm -23 "$TMP/basefiles" "$TMP/files" > "$TMP/deleted"
fi
deleted=$(grep -c . "$TMP/deleted")
sed 's/^/DELETED (in the baseline tree, not the branch): /' "$TMP/deleted"
# replay_adjudicate REL CAP: 0 same under replay, 1 a DIFF, 2 still NONDET
replay_adjudicate() {
    rm -f "$TMP/tape"
    run "$BASE_BIN" "$1" "$TMP/t0" "$2" "EIGS_TRACE=$TMP/tape"
    [ -s "$TMP/tape" ] || return 2
    run "$BASE_BIN" "$1" "$TMP/p1" "$2" "EIGS_REPLAY=$TMP/tape"
    run "$BASE_BIN" "$1" "$TMP/p2" "$2" "EIGS_REPLAY=$TMP/tape"
    same "$TMP/p1" "$TMP/p2" || return 2
    [ "$(cat "$TMP/p1.rc")" -lt 124 ] || return 2
    run "$BR_BIN" "$1" "$TMP/q1" "$2" "EIGS_REPLAY=$TMP/tape"
    same "$TMP/p1" "$TMP/q1" && return 0
    return 1
}
while IFS= read -r rel; do
    examined=$((examined + 1))
    t0=$(date +%s)
    [ -f "$BASE_ROOT/$rel" ] || { new=$((new + 1)); echo "$rel" >> "$TMP/new"; }
    cap=0
    if grep -Eq '(gfx|ui|audio)_[a-z_]+' "$BR_ROOT/$rel"; then
        cap=1; capped=$((capped + 1)); echo "$rel" >> "$TMP/capped"
    fi
    run "$BASE_BIN" "$rel" "$TMP/b1" "$cap"
    run "$BASE_BIN" "$rel" "$TMP/b2" "$cap"
    run "$BR_BIN" "$rel" "$TMP/r1" "$cap"
    run "$BR_BIN" "$rel" "$TMP/r2" "$cap"
    if same "$TMP/b1" "$TMP/b2"; then
        if same "$TMP/b1" "$TMP/r1" && same "$TMP/b1" "$TMP/r2"; then
            nsame=$((nsame + 1))
            rc=$(cat "$TMP/b1.rc")
            if [ "$rc" -eq 124 ]; then timeout_both=$((timeout_both + 1)); echo "$rel rc=124" >> "$TMP/crash"
            elif [ "$rc" -ge 128 ]; then crash_both=$((crash_both + 1)); echo "$rel rc=$rc" >> "$TMP/crash"; fi
            echo ".. $examined/$listed $rel same rc=$rc $(( $(date +%s) - t0 ))s"
            continue
        fi
        ndiff=$((ndiff + 1))
        echo ".. $examined/$listed $rel DIFF $(( $(date +%s) - t0 ))s"
        if same "$TMP/b1" "$TMP/r1"; then wrong=r2; else wrong=r1; fi
        echo "DIFF $rel: the baseline is deterministic (two runs agree); branch run $wrong differs: rc baseline=$(cat "$TMP/b1.rc") branch=$(cat "$TMP/$wrong.rc")"
        show_diff "$TMP/b1" "$TMP/$wrong"
        continue
    fi
    replay_adjudicate "$rel" "$cap"; ra=$?
    if [ "$ra" -eq 0 ]; then
        nreplay=$((nreplay + 1)); echo "$rel" >> "$TMP/replayed"
        echo ".. $examined/$listed $rel same-under-replay $(( $(date +%s) - t0 ))s"
    elif [ "$ra" -eq 1 ]; then
        ndiff=$((ndiff + 1))
        echo ".. $examined/$listed $rel DIFF-under-replay $(( $(date +%s) - t0 ))s"
        echo "DIFF $rel: replaying the baseline's tape, rc baseline=$(cat "$TMP/p1.rc") branch=$(cat "$TMP/q1.rc")"
        show_diff "$TMP/p1" "$TMP/q1"
    else
        nondet=$((nondet + 1)); echo "$rel" >> "$TMP/nondet"
        echo ".. $examined/$listed $rel nondet $(( $(date +%s) - t0 ))s"
    fi
done < "$TMP/files"

sed 's/^/NEW (only the branch tree has it) /' "$TMP/new"
sed 's/^/REPLAYED (compared on the baseline tape; its nondeterministic builtins did not run live) /' "$TMP/replayed"
sed 's/^/NONDET (the baseline disagrees with itself, and its tape replays too) /' "$TMP/nondet"
sed 's/^/BOTH-CRASH-OR-TIMEOUT /' "$TMP/crash"
sed 's/^/CAPPED (gfx\/ui\/audio: ulimit -v 2097152) /' "$TMP/capped"
summary="examined=$examined same=$nsame same_under_replay=$nreplay nondet=$nondet diff=$ndiff new=$new deleted=$deleted crash_both=$crash_both timeout_both=$timeout_both capped=$capped"
DONE=1
if [ -n "${PHASE2_DIFF_FILES:-}" ]; then
    echo "corpus-diff: RESTRICTED $summary"
    exit 3
fi
echo "corpus-diff: $summary"
if [ "$examined" -eq "$listed" ] && [ "$examined" -gt 0 ] && [ "$ndiff" -eq 0 ] && [ "$deleted" -eq 0 ]; then
    echo "corpus-diff: PASS"; exit 0
fi
echo "corpus-diff: FAIL"; exit 1
