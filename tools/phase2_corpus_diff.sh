#!/usr/bin/env bash
# tools/phase2_corpus_diff.sh <baseline-binary> <branch-binary> -- #1758: the
# behaviour differential of a mechanical round (docs/design/phase2-numbers.md
# 8, R1.1 and R1.2): "unchanged" is measured, not inferred from a green suite.
#
# Every .eigs file under the BRANCH tree's tests/ runs once with each binary,
# both from the branch tree's src/ (the suite's cwd) as `../tests/<file>`, so
# a file and everything it loads by a relative path are the same bytes for
# both; only the binary and the stdlib next to it differ. stdin /dev/null,
# a 60 s bound, under
# `env -u XAUTHORITY DISPLAY=:99` and a 2 GiB address-space limit. stdout,
# stderr and the exit code must all be byte-identical after one
# normalisation: each tree's absolute root is replaced by `<ROOT>`, so a test
# that prints its own path compares equal.
#
# A file whose outputs differ is re-run: the baseline a second time (if it
# disagrees with itself the file is NONDET -- timing, randomness, scheduling),
# then the branch a second time (if it now agrees, the branch side is NONDET
# too). Only a difference that both re-runs keep is a DIFF row.
# A NONDET file is then adjudicated on a tape (docs/TRACE.md: a tape recorded
# by one binary replays on another): the baseline records it once, and the
# baseline replays it twice and the branch once. Two baseline replays that
# agree make the tape an oracle; the branch's replay must then match it
# (`same-under-replay`) or it is a DIFF. Replays that disagree with each
# other (threads, subprocesses: the documented boundary) stay NONDET.
# A crash or timeout both binaries agree on is named in its own counter,
# never silently "same".
#
# A file only the branch tree has (a new fixture) is counted as `new`; a
# file only the baseline tree has is a DELETED row, a failure: a deleted test
# would hide a behaviour change.
# Prints `.. <n>/<N> <file> <verdict> <seconds>s` per file as it goes, a
# DIFF/DELETED row per failure, the NONDET and crash lists, and
# `corpus-diff: examined=N same=S same_under_replay=R nondet=K diff=D new=W
# deleted=X crash_both=C timeout_both=T`. Exit 0 only for diff=0 deleted=0
# and examined equal to the number of files listed (> 0).
set -u
[ $# -eq 2 ] || { echo "usage: tools/phase2_corpus_diff.sh <baseline-binary> <branch-binary>"; exit 2; }
abspath() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }
BASE_BIN=$(abspath "$1") || exit 2
BR_BIN=$(abspath "$2") || exit 2
BASE_ROOT=$(cd "$(dirname "$BASE_BIN")/.." && pwd -P)
BR_ROOT=$(cd "$(dirname "$BR_BIN")/.." && pwd -P)
for b in "$BASE_BIN" "$BR_BIN"; do [ -x "$b" ] || { echo "corpus-diff: FAIL: $b is not executable"; exit 2; }; done
command -v timeout >/dev/null 2>&1 || { echo "corpus-diff: FAIL: needs coreutils timeout (local tool)"; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-corpus-diff.XXXXXX") || exit 2
DONE=0
trap 'rc=$?; [ "$DONE" = 1 ] || echo "corpus-diff: FAIL: exited ($rc) before a verdict, at: $BASH_COMMAND"; rm -rf "$TMP"' EXIT

(cd "$BR_ROOT" && find tests -name '*.eigs' -type f | LC_ALL=C sort) > "$TMP/files"
listed=$(grep -c . "$TMP/files")
[ "$listed" -gt 0 ] || { echo "corpus-diff: FAIL: no .eigs file under $BR_ROOT/tests"; exit 1; }
echo "corpus-diff: baseline $BASE_BIN ($("$BASE_BIN" --version 2>&1 | head -1)) sha256 $(sha256sum "$BASE_BIN" | cut -c1-16)"
echo "corpus-diff: branch   $BR_BIN ($("$BR_BIN" --version 2>&1 | head -1)) sha256 $(sha256sum "$BR_BIN" | cut -c1-16)"
echo "corpus-diff: files=$listed"

# run BIN ROOT REL OUT [VAR=value] -> OUT.out OUT.err OUT.rc (ROOT is the
# binary's own tree, which only its stdlib comes from), root paths
# normalised
run() {
    local bin="$1" root="$2" rel="$3" out="$4" extra="${5:-PHASE2_DIFF=1}" rc
    (
        cd "$BR_ROOT/src" || exit 99
        ulimit -v 2097152
        exec env -u XAUTHORITY DISPLAY=:99 "$extra" timeout 60 "$bin" "../$rel"
    ) < /dev/null > "$out.rawout" 2> "$out.rawerr"
    rc=$?
    echo "$rc" > "$out.rc"
    sed "s|$BASE_ROOT|<ROOT>|g; s|$BR_ROOT|<ROOT>|g" "$out.rawout" > "$out.out"
    sed "s|$BASE_ROOT|<ROOT>|g; s|$BR_ROOT|<ROOT>|g" "$out.rawerr" > "$out.err"
}
same() { cmp -s "$1.out" "$2.out" && cmp -s "$1.err" "$2.err" && cmp -s "$1.rc" "$2.rc"; }

examined=0; nsame=0; nreplay=0; nondet=0; ndiff=0; new=0; crash_both=0; timeout_both=0
: > "$TMP/new"
(cd "$BASE_ROOT" && find tests -name '*.eigs' -type f | LC_ALL=C sort) > "$TMP/basefiles"
LC_ALL=C comm -23 "$TMP/basefiles" "$TMP/files" > "$TMP/deleted"
deleted=$(grep -c . "$TMP/deleted")
sed 's/^/DELETED (in the baseline tree, not the branch): /' "$TMP/deleted"
# replay_adjudicate REL: 0 same under replay, 1 a DIFF, 2 still NONDET
replay_adjudicate() {
    local rel="$1"
    rm -f "$TMP/tape"
    run "$BASE_BIN" "$BASE_ROOT" "$rel" "$TMP/t0" "EIGS_TRACE=$TMP/tape"
    [ -s "$TMP/tape" ] || return 2
    run "$BASE_BIN" "$BASE_ROOT" "$rel" "$TMP/p1" "EIGS_REPLAY=$TMP/tape"
    run "$BASE_BIN" "$BASE_ROOT" "$rel" "$TMP/p2" "EIGS_REPLAY=$TMP/tape"
    same "$TMP/p1" "$TMP/p2" || return 2
    [ "$(cat "$TMP/p1.rc")" -lt 124 ] || return 2
    run "$BR_BIN" "$BR_ROOT" "$rel" "$TMP/q1" "EIGS_REPLAY=$TMP/tape"
    same "$TMP/p1" "$TMP/q1" && return 0
    return 1
}
: > "$TMP/nondet"; : > "$TMP/crash"
while IFS= read -r rel; do
    examined=$((examined + 1))
    t0=$(date +%s)
    [ -f "$BASE_ROOT/$rel" ] || { new=$((new + 1)); echo "$rel" >> "$TMP/new"; }
    run "$BASE_BIN" "$BASE_ROOT" "$rel" "$TMP/b1"
    run "$BR_BIN" "$BR_ROOT" "$rel" "$TMP/r1"
    if same "$TMP/b1" "$TMP/r1"; then
        nsame=$((nsame + 1))
        rc=$(cat "$TMP/b1.rc")
        if [ "$rc" -eq 124 ]; then timeout_both=$((timeout_both + 1)); echo "$rel rc=124" >> "$TMP/crash"
        elif [ "$rc" -ge 128 ]; then crash_both=$((crash_both + 1)); echo "$rel rc=$rc" >> "$TMP/crash"; fi
        echo ".. $examined/$listed $rel same rc=$rc $(( $(date +%s) - t0 ))s"
        continue
    fi
    run "$BASE_BIN" "$BASE_ROOT" "$rel" "$TMP/b2"
    if ! same "$TMP/b1" "$TMP/b2"; then
        replay_adjudicate "$rel"; ra=$?
        if [ "$ra" -eq 0 ]; then
            nreplay=$((nreplay + 1))
            echo ".. $examined/$listed $rel same-under-replay $(( $(date +%s) - t0 ))s"; continue
        elif [ "$ra" -eq 1 ]; then
            ndiff=$((ndiff + 1))
            echo ".. $examined/$listed $rel DIFF-under-replay $(( $(date +%s) - t0 ))s"
            echo "DIFF $rel: replaying the baseline's tape, rc baseline=$(cat "$TMP/p1.rc") branch=$(cat "$TMP/q1.rc")"
            diff "$TMP/p1.out" "$TMP/q1.out" | head -8 | sed 's/^/    stdout: /'
            diff "$TMP/p1.err" "$TMP/q1.err" | head -8 | sed 's/^/    stderr: /'
            continue
        fi
        nondet=$((nondet + 1)); echo "$rel (the baseline disagrees with itself, and its replays too)" >> "$TMP/nondet"
        echo ".. $examined/$listed $rel nondet $(( $(date +%s) - t0 ))s"; continue
    fi
    run "$BR_BIN" "$BR_ROOT" "$rel" "$TMP/r2"
    if same "$TMP/b1" "$TMP/r2"; then
        nondet=$((nondet + 1)); echo "$rel (the branch disagreed once, then agreed)" >> "$TMP/nondet"
        echo ".. $examined/$listed $rel nondet $(( $(date +%s) - t0 ))s"; continue
    fi
    ndiff=$((ndiff + 1))
    echo ".. $examined/$listed $rel DIFF $(( $(date +%s) - t0 ))s"
    echo "DIFF $rel: rc baseline=$(cat "$TMP/b1.rc") branch=$(cat "$TMP/r2.rc")"
    diff "$TMP/b1.out" "$TMP/r2.out" | head -8 | sed 's/^/    stdout: /'
    diff "$TMP/b1.err" "$TMP/r2.err" | head -8 | sed 's/^/    stderr: /'
done < "$TMP/files"

sed 's/^/NEW (only the branch tree has it) /' "$TMP/new"
sed 's/^/NONDET /' "$TMP/nondet"
sed 's/^/BOTH-CRASH-OR-TIMEOUT /' "$TMP/crash"
echo "corpus-diff: examined=$examined same=$nsame same_under_replay=$nreplay nondet=$nondet diff=$ndiff new=$new deleted=$deleted crash_both=$crash_both timeout_both=$timeout_both"
DONE=1
if [ "$examined" -eq "$listed" ] && [ "$examined" -gt 0 ] && [ "$ndiff" -eq 0 ] && [ "$deleted" -eq 0 ]; then
    echo "corpus-diff: PASS"; exit 0
fi
echo "corpus-diff: FAIL"; exit 1
