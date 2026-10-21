#!/usr/bin/env bash
# tools/phase2_corpus_diff.sh <baseline-binary> <branch-binary> -- #1758: the
# behaviour differential of a mechanical round (docs/design/phase2-numbers.md
# 8, R1.1 and R1.2): "unchanged" is measured, not inferred from a green suite.
#
# Every non-excluded .eigs file under the BRANCH tree's tests/ runs twice with each binary,
# tests/phase2/corpus_exclude.txt declares directory ownership, with an owning
# harness and reason. The same exclusions filter both inventories. Empty,
# stale, overlapping, unsafe or ownerless declarations fail; each is reported.
# all four runs from the branch tree's src/ (the suite's cwd) as
# `../tests/<file>`, so a file and whatever it loads by a relative path are the
# same bytes for both; only the binary and the stdlib next to it differ.
# stdin /dev/null, a 60 s bound, `env -u XAUTHORITY DISPLAY=:99
# SDL_AUDIODRIVER=dummy` (the X server is Xvfb; SDL's dummy audio device
# because a real capture device delivers samples or not by timing, so
# test_audio.eigs printed a SKIP on some runs and two agreeing baseline runs
# did not make it deterministic: a branch run that differed read as a DIFF).
# stdout, stderr and the exit code are compared byte for byte after one
# normalisation: each tree's absolute root becomes `<ROOT>`.
#
# RUN CONDITIONS. Each file runs under its conditions from the ONE loader the
# suite, tools/jit_diff.sh and tools/replay_diff.sh use
# (tests/suite_program_env.sh, policy tests/suite_program_env.txt): a
# fail-soft test runs with EIGS_STRICT=0 as the suite runs it, instead of
# dying at its first strict raise on both binaries and comparing two early
# deaths (the R1.1 critic's plants C and B2 passed that way). A file with
# conditions must complete (rc 0) on both baseline runs, jit_diff's rule; if
# it does not it is INCOMPLETE, never compared, and the run fails.
#
# DECLARED NONZERO EXITS. A file whose baseline exits nonzero (the same code
# on both runs) compares little or nothing, so it must be declared with that
# code and a reason in tests/phase2/corpus_nonzero.txt (a deliberate error, a
# fixture of another host, a capability the release build lacks, the runaway
# guard's own fixture). An undeclared one is UNDECLARED-NONZERO, and a row
# whose file now exits otherwise is STALE: either fails the run. So a file
# that loses its run conditions, or a new test that dies early, is red here.
# Every declared file is listed with its code.
#
# THE SEED PIN. The runtime has no seed flag or variable. An LD_PRELOAD shim,
# built here, pins what the runtime seeds from the clock:
# - drand48 (random, random_int, random_normal, the samplers): the self-seed
#   is srand48(ts.tv_sec ^ ts.tv_nsec ^ getpid()) from a CLOCK_MONOTONIC
#   reading taken just before (src/builtins.c, random_seed_once). The shim
#   records each thread's last CLOCK_MONOTONIC reading and pins an srand48
#   seed that equals that formula, whatever its value; a script's
#   `seed_random of N` reaches srand48 unchanged (an explicit seed equal to
#   the formula by chance would be pinned too).
# - libc rand() (audio_noise): main() seeds it with srand(time(NULL)); every
#   srand call is pinned (main's are its only callers).
# random_hex reads /dev/urandom by design (cryptographic) and stays unpinned:
# the shim marks each run that opens /dev/urandom, and those files are listed
# as UNPINNED with their verdict. The run checks its precondition first: two
# pinned `random` draws must agree. That the pin makes a random file
# comparable live is calibrated once (phase2_check.py --selftest, plant D).
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
# A timeout (rc 124) or a crash (rc >= 128) that all four runs agree on is
# counted as timeout_both or crash_both, never as same.
#
# MEMORY. No blanket cap (a 2 GiB `ulimit -v` made handles_full.eigs's 300
# spawns fail at 134-214, which read as nondeterminism -- the R1.1 critic).
# Only a file that drives the gfx/ui/audio surface runs under
# `ulimit -v 1500000` (an unbounded GUI run can freeze the 4 GB box); the
# capped files are listed.
#
# A file only the branch tree has (a new fixture) is counted as `new`; a file
# only the baseline tree has is a DELETED row (a deleted test hides a change).
# Prints `.. <n>/<N> <file> <verdict> <s>s` per file, the named rows, then
# `corpus-diff: examined=N ...` and `corpus-diff: PASS|FAIL`. Exit 0 only for
# examined equal to the files listed (> 0), diff=0, deleted=0, incomplete=0,
# undeclared=0, stale=0, and a seed pin that proved itself.
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
[ -f "$BR_ROOT/tests/suite_program_env.sh" ] || { echo "corpus-diff: FAIL: no run-condition loader in the branch tree"; exit 2; }
LEDGER="$BR_ROOT/tests/phase2/corpus_nonzero.txt"
[ -f "$LEDGER" ] || { echo "corpus-diff: FAIL: no ledger $LEDGER"; exit 2; }
export EIGS_TEST_DIR="$BR_ROOT/tests"
. "$BR_ROOT/tests/suite_program_env.sh" || { echo "corpus-diff: FAIL: the run-condition loader did not load"; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-corpus-diff.XXXXXX") || exit 2
DONE=0
trap 'rc=$?; [ "$DONE" = 1 ] || echo "corpus-diff: FAIL: exited ($rc) before a verdict, at: $BASH_COMMAND"; rm -rf "$TMP"' EXIT

# ---- the seed pin --------------------------------------------------------
cat > "$TMP/seedpin.c" <<'CSRC'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
/* phase2_corpus_diff.sh's seed pin (the tool's header says what it pins). */
static __thread struct timespec last_mono;
static __thread int have_mono;
int clock_gettime(clockid_t id, struct timespec *ts) {
    static int (*real)(clockid_t, struct timespec *);
    if (!real) real = (int (*)(clockid_t, struct timespec *))dlsym(RTLD_NEXT, "clock_gettime");
    int r = real(id, ts);
    if (r == 0 && id == CLOCK_MONOTONIC) { last_mono = *ts; have_mono = 1; }
    return r;
}
void srand48(long seed) {
    static void (*real)(long);
    if (!real) real = (void (*)(long))dlsym(RTLD_NEXT, "srand48");
    if (have_mono && seed == (long)(last_mono.tv_sec ^ last_mono.tv_nsec ^ (long)getpid())) seed = 0x5EEDL;
    real(seed);
}
void srand(unsigned int seed) {
    static void (*real)(unsigned int);
    if (!real) real = (void (*)(unsigned int))dlsym(RTLD_NEXT, "srand");
    (void)seed;
    real(0x5EEDu);
}
FILE *fopen(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *);
    if (!real) real = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
    const char *mark = getenv("PHASE2_URANDOM_MARK");
    if (mark && path && strcmp(path, "/dev/urandom") == 0) {
        int fd = open(mark, O_WRONLY | O_CREAT, 0644);
        if (fd >= 0) close(fd);
    }
    return real(path, mode);
}
CSRC
WERROR_FLAGS_FILE="$(dirname "$0")/werror_flags.txt"
. "$(dirname "$0")/read_werror_flags.sh" 2>&1 || exit 2
# shellcheck disable=SC2086  # the shared flags are one word each
if ! cc -Wall -Wextra $WERROR_FLAGS -shared -fPIC -O2 -o "$TMP/seedpin.so" "$TMP/seedpin.c" -ldl > "$TMP/seedpin.log" 2>&1 \
        || [ -s "$TMP/seedpin.log" ]; then
    sed 's/^/  seedpin cc: /' "$TMP/seedpin.log"
    echo "corpus-diff: FAIL: the seed pin did not build cleanly"; DONE=1; exit 1
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

# ---- the ledger of declared nonzero exits --------------------------------
# A row: `<tests/...eigs> <code 1-255> <reason...>`; `#` lines and blank lines
# are prose. Any other line is refused by name (a whitelist, not a skip).
: > "$TMP/ledger"
lnum=0; ledger_bad=0
while IFS= read -r line || [ -n "$line" ]; do
    lnum=$((lnum + 1))
    case "$line" in ''|'#'*) continue ;; esac
    lpath=${line%% *}; rest=${line#* }; lrc=${rest%% *}; why=${rest#* }
    if ! grep -Eq '^tests/[A-Za-z0-9_./-]+[.]eigs$' <<< "$lpath" || ! grep -Eq '^[1-9][0-9]{0,2}$' <<< "$lrc" \
            || [ "$lrc" -gt 255 ] || [ "$why" = "$rest" ] || [ -z "$why" ]; then
        echo "LEDGER-REFUSED corpus_nonzero.txt:$lnum: not '<tests/...eigs> <code> <reason>': $line"
        ledger_bad=$((ledger_bad + 1)); continue
    fi
    if grep -q "^$lpath " "$TMP/ledger"; then
        echo "LEDGER-REFUSED corpus_nonzero.txt:$lnum: $lpath declared twice"; ledger_bad=$((ledger_bad + 1)); continue
    fi
    if [ -n "$(suite_program_env "$lpath" 2>/dev/null)" ]; then
        echo "LEDGER-REFUSED corpus_nonzero.txt:$lnum: $lpath has run conditions, so it must complete; it cannot be declared nonzero"
        ledger_bad=$((ledger_bad + 1)); continue
    fi
    printf '%s %s\n' "$lpath" "$lrc" >> "$TMP/ledger"
done < "$LEDGER"
declared=$(grep -c . "$TMP/ledger")

# ---- the population ------------------------------------------------------
if [ -n "${PHASE2_DIFF_FILES:-}" ]; then
    LC_ALL=C sort "$PHASE2_DIFF_FILES" > "$TMP/files"
    while IFS= read -r rel; do
        [ -f "$BR_ROOT/$rel" ] || { echo "corpus-diff: FAIL: restricted list names $rel, absent from the branch tree"; DONE=1; exit 1; }
    done < "$TMP/files"
else
    (cd "$BR_ROOT" && find tests -name '*.eigs' -type f | LC_ALL=C sort) > "$TMP/files"
fi
# The exclusion ledger owns the population policy; fixtures run through their
# named harness instead of being launched bare by a second implementation.
(cd "$BASE_ROOT" && find tests -name '*.eigs' -type f | LC_ALL=C sort) > "$TMP/basefiles"
printf '0\n' > "$TMP/excluded-count"
if [ -f "$BR_ROOT/tests/phase2/corpus_exclude.txt" ]; then
    python3 "$BR_ROOT/tools/phase2_corpus_exclude.py" "$BR_ROOT" "$TMP/files" "$TMP/basefiles" "$TMP/excluded-count" \
        || { echo "corpus-diff: FAIL: declared exclusions"; DONE=1; exit 1; }
fi
excluded=$(cat "$TMP/excluded-count")
listed=$(grep -c . "$TMP/files")
[ "$listed" -gt 0 ] || { echo "corpus-diff: FAIL: no .eigs file to run"; DONE=1; exit 1; }
echo "corpus-diff: baseline $BASE_BIN ($("$BASE_BIN" --version 2>&1 | head -1)) sha256 $(sha256sum "$BASE_BIN" | cut -c1-16)"
echo "corpus-diff: branch   $BR_BIN ($("$BR_BIN" --version 2>&1 | head -1)) sha256 $(sha256sum "$BR_BIN" | cut -c1-16)"
echo "corpus-diff: files=$listed excluded=$excluded declared_nonzero=$declared${PHASE2_DIFF_FILES:+ (RESTRICTED by PHASE2_DIFF_FILES)}"

# run BIN REL OUT CAP [VAR=value] -> OUT.out OUT.err OUT.rc (and OUT.urandom
# when the run opened /dev/urandom), root paths normalised; CAP=1 runs under
# the GUI memory cap. The file's run conditions come from the shared loader.
run() {
    local bin="$1" rel="$2" out="$3" cap="$4" extra="${5:-PHASE2_DIFF=1}" rc
    rm -f "$out.urandom"
    # The run's stderr is its file. The brace group's 2>/dev/null takes only
    # bash's own report of a run killed by a signal ("line N: PID Aborted"),
    # which would otherwise reach this tool's stderr, where a gate refuses it.
    {
        (
            cd "$BR_ROOT/src" || exit 99
            [ "$cap" = 1 ] && ulimit -v 1500000
            suite_program_run "$rel" env -u XAUTHORITY DISPLAY=:99 SDL_AUDIODRIVER=dummy LD_PRELOAD="$SHIM" \
                PHASE2_URANDOM_MARK="$out.urandom" "$extra" timeout 60 "$bin" "../$rel"
        ) < /dev/null > "$out.rawout" 2> "$out.rawerr"
        rc=$?
    } 2> /dev/null
    echo "$rc" > "$out.rc"
    sed "s|$BASE_ROOT|<ROOT>|g; s|$BR_ROOT|<ROOT>|g" "$out.rawout" > "$out.out"
    sed "s|$BASE_ROOT|<ROOT>|g; s|$BR_ROOT|<ROOT>|g" "$out.rawerr" > "$out.err"
}
same() { cmp -s "$1.out" "$2.out" && cmp -s "$1.err" "$2.err" && cmp -s "$1.rc" "$2.rc"; }
show_diff() {
    diff "$1.out" "$2.out" | head -8 | sed 's/^/    stdout: /'
    diff "$1.err" "$2.err" | head -8 | sed 's/^/    stderr: /'
}

examined=0; nsame=0; same_nonzero=0; nreplay=0; nondet=0; ndiff=0; new=0; crash_both=0; timeout_both=0
capped=0; conditioned=0; incomplete=0; undeclared=0; stale=0; unpinned=0
for f in new nondet crash replayed capped samenz urandom used; do : > "$TMP/$f"; done
# Baseline inventory was filtered with the branch inventory above.
if [ -n "${PHASE2_DIFF_FILES:-}" ]; then
    : > "$TMP/deleted"
else
    LC_ALL=C comm -23 "$TMP/basefiles" "$TMP/files" > "$TMP/deleted"
fi
deleted=$(grep -c . "$TMP/deleted")
sed 's/^/DELETED (in the baseline tree, not the branch): /' "$TMP/deleted"
took() { echo $(( $(date +%s) - t0 )); }
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
    if ! cond=$(suite_program_check "$rel" 2> "$TMP/cond.err"); then
        sed 's/^/  /' "$TMP/cond.err"
        echo "corpus-diff: FAIL: the run conditions of $rel were refused"; DONE=1; exit 1
    fi
    [ -n "$cond" ] && conditioned=$((conditioned + 1))
    cap=0
    if grep -Eq '(gfx|ui|audio)_[a-z_]+' "$BR_ROOT/$rel"; then
        cap=1; capped=$((capped + 1)); echo "$rel" >> "$TMP/capped"
    fi
    run "$BASE_BIN" "$rel" "$TMP/b1" "$cap"
    run "$BASE_BIN" "$rel" "$TMP/b2" "$cap"
    run "$BR_BIN" "$rel" "$TMP/r1" "$cap"
    run "$BR_BIN" "$rel" "$TMP/r2" "$cap"
    rb1=$(cat "$TMP/b1.rc"); rb2=$(cat "$TMP/b2.rc")
    # The runs that opened /dev/urandom (random_hex): its values are live.
    urand=0
    for a in b1 b2 r1 r2; do [ -e "$TMP/$a.urandom" ] && urand=1; done
    # jit_diff's rule: a file with run conditions completes, or it is never compared.
    if [ -n "$cond" ] && { [ "$rb1" != 0 ] || [ "$rb2" != 0 ]; }; then
        incomplete=$((incomplete + 1))
        echo ".. $examined/$listed $rel INCOMPLETE $(took)s"
        echo "INCOMPLETE $rel: the baseline exits $rb1/$rb2 under its run conditions ($cond); a file with conditions must complete (rc 0), so it was not compared"
        sed -n '1,6p' "$TMP/b1.err" | sed 's/^/    baseline stderr: /'
        continue
    fi
    # A nonzero exit the baseline repeats must be declared with that code.
    if [ "$rb1" = "$rb2" ] && [ "$rb1" != 0 ]; then
        want=$(awk -v p="$rel" '$1 == p { print $2 }' "$TMP/ledger")
        if [ -z "$want" ]; then
            undeclared=$((undeclared + 1))
            echo "UNDECLARED-NONZERO $rel rc=$rb1: the baseline exits $rb1 and tests/phase2/corpus_nonzero.txt does not declare it (an early exit compares nothing: give it run conditions in tests/suite_program_env.txt, or declare it with a reason)"
            sed -n '1,4p' "$TMP/b1.err" | sed 's/^/    baseline stderr: /'
        elif [ "$want" = "$rb1" ]; then
            echo "$rel" >> "$TMP/used"
        fi
    fi
    if same "$TMP/b1" "$TMP/b2"; then
        if same "$TMP/b1" "$TMP/r1" && same "$TMP/b1" "$TMP/r2"; then
            if [ "$rb1" -eq 124 ]; then
                timeout_both=$((timeout_both + 1)); echo "$rel rc=124" >> "$TMP/crash"; verdict=timeout-both
            elif [ "$rb1" -ge 128 ]; then
                crash_both=$((crash_both + 1)); echo "$rel rc=$rb1" >> "$TMP/crash"; verdict=crash-both
            else
                nsame=$((nsame + 1)); verdict=same
                if [ "$rb1" != 0 ]; then same_nonzero=$((same_nonzero + 1)); echo "$rel rc=$rb1" >> "$TMP/samenz"; fi
            fi
            echo ".. $examined/$listed $rel $verdict rc=$rb1 $(took)s"
            [ "$urand" = 1 ] && echo "$rel $verdict" >> "$TMP/urandom"
            continue
        fi
        ndiff=$((ndiff + 1))
        echo ".. $examined/$listed $rel DIFF $(took)s"
        if same "$TMP/b1" "$TMP/r1"; then wrong=r2; else wrong=r1; fi
        echo "DIFF $rel: the baseline is deterministic (two runs agree); branch run $wrong differs: rc baseline=$rb1 branch=$(cat "$TMP/$wrong.rc")"
        show_diff "$TMP/b1" "$TMP/$wrong"
        [ "$urand" = 1 ] && echo "$rel DIFF" >> "$TMP/urandom"
        continue
    fi
    replay_adjudicate "$rel" "$cap"; ra=$?
    if [ "$ra" -eq 0 ]; then
        nreplay=$((nreplay + 1)); echo "$rel" >> "$TMP/replayed"; verdict=same-under-replay
        echo ".. $examined/$listed $rel same-under-replay $(took)s"
    elif [ "$ra" -eq 1 ]; then
        ndiff=$((ndiff + 1)); verdict=DIFF-under-replay
        echo ".. $examined/$listed $rel DIFF-under-replay $(took)s"
        echo "DIFF $rel: replaying the baseline's tape, rc baseline=$(cat "$TMP/p1.rc") branch=$(cat "$TMP/q1.rc")"
        show_diff "$TMP/p1" "$TMP/q1"
    else
        nondet=$((nondet + 1)); echo "$rel" >> "$TMP/nondet"; verdict=nondet
        echo ".. $examined/$listed $rel nondet $(took)s"
    fi
    [ "$urand" = 1 ] && echo "$rel $verdict" >> "$TMP/urandom"
done < "$TMP/files"

# A declared row must be examined and must still exit with its code.
while IFS=' ' read -r lpath lrc; do
    if ! grep -qxF "$lpath" "$TMP/files"; then
        [ -n "${PHASE2_DIFF_FILES:-}" ] && continue
        stale=$((stale + 1)); echo "STALE $lpath: declared rc=$lrc in tests/phase2/corpus_nonzero.txt, but no such corpus file was examined"
    elif ! grep -qxF "$lpath" "$TMP/used"; then
        stale=$((stale + 1)); echo "STALE $lpath: declared rc=$lrc in tests/phase2/corpus_nonzero.txt, but the baseline does not exit with it (correct or remove the row)"
    fi
done < "$TMP/ledger"
unpinned=$(grep -c . "$TMP/urandom")
sed 's/^/NEW (only the branch tree has it) /' "$TMP/new"
sed 's/^/REPLAYED (compared on the baseline tape; its nondeterministic builtins did not run live) /' "$TMP/replayed"
sed 's/^/NONDET (the baseline disagrees with itself, and its tape replays too) /' "$TMP/nondet"
sed 's/^/BOTH-CRASH-OR-TIMEOUT /' "$TMP/crash"
sed 's/^/SAME-NONZERO (declared: both binaries exit so; compared up to the exit) /' "$TMP/samenz"
sed 's/^/UNPINNED (opened \/dev\/urandom: random_hex values are live, by design) /' "$TMP/urandom"
sed 's/^/CAPPED (gfx\/ui\/audio: ulimit -v 1500000) /' "$TMP/capped"
summary="examined=$examined excluded=$excluded same=$nsame same_nonzero=$same_nonzero same_under_replay=$nreplay nondet=$nondet diff=$ndiff new=$new deleted=$deleted crash_both=$crash_both timeout_both=$timeout_both conditioned=$conditioned incomplete=$incomplete undeclared=$undeclared stale=$stale ledger_refused=$ledger_bad unpinned=$unpinned capped=$capped"
DONE=1
if [ -n "${PHASE2_DIFF_FILES:-}" ]; then
    echo "corpus-diff: RESTRICTED $summary"
    exit 3
fi
echo "corpus-diff: $summary"
if [ "$examined" -eq "$listed" ] && [ "$examined" -gt 0 ] && [ "$ndiff" -eq 0 ] && [ "$deleted" -eq 0 ] \
        && [ "$incomplete" -eq 0 ] && [ "$undeclared" -eq 0 ] && [ "$stale" -eq 0 ] && [ "$ledger_bad" -eq 0 ]; then
    echo "corpus-diff: PASS"; exit 0
fi
echo "corpus-diff: FAIL"; exit 1
