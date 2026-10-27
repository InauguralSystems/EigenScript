#!/usr/bin/env bash
# Bounded regression test for the per-tree make lock and the stop gate's
# non-blocking use of it (#1940). Each case fails if its mechanism is removed.
set -u
[ "${1:-}" = "--selftest" ] && [ "$#" -eq 1 ] || {
    echo "usage: tools/make_lock_check.sh --selftest" >&2
    exit 2
}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# This test controls the tree lock itself. Run from inside a make recipe (for
# example `make precheck`, whose selftests reach this row), it inherits the
# Makefile's flag; clear it so the independent fixture makes exercise locking.
# Case 3 sets the flag explicitly for the one make that needs it.
unset EIGS_TREE_LOCK_HELD
if ! command -v flock >/dev/null 2>&1; then
    echo "make-lock selftest: SKIP: flock is unavailable"
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-make-lock.XXXXXX") || exit 1
HOLDERS=()
SUITE_TREE=
cleanup() {
    rm -f "$WORK"/hold-* 2>/dev/null
    rm -f "$WORK"/hold-* 2>/dev/null
    for p in "${HOLDERS[@]}"; do wait "$p" 2>/dev/null; done
    [ -z "$SUITE_TREE" ] || rm -rf "$SUITE_TREE"
    rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "make-lock selftest: FAIL: $*"; exit 1; }
# The lock tools/tree_lock.sh takes, as this independent oracle knows it.
LOCK=.make.lock

# A full Makefile parse takes about a second on a loaded box, so waits are
# bounded at 10 s rather than tuned to an idle machine.
wait_for() { local _; for _ in $(seq 100); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
wait_for_suite() { local _; for _ in $(seq 300); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
# hold_lock TREE NAME: hold TREE's lock independently of tools/tree_lock.sh
# (an oracle must not borrow the implementation it checks) until release NAME,
# at most 20 s. The holder is the process that owns the lock, so releasing it
# frees the lock; killing a flock(1) parent would leave its child holding it.
hold_lock() {
    flock "$1/$LOCK" sh -c ': >"$1"; i=0; while [ -e "$1" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done' \
        sh "$WORK/hold-$2" &
    HOLDERS+=("$!")
    wait_for "$WORK/hold-$2" || fail "lock holder $2 did not start"
}
release() { rm -f "$WORK/hold-$1"; }
NOTICE='make: waiting for the build lock (another make in this tree)'

TREE="$WORK/tree"
mkdir -p "$TREE/tools"
cp "$ROOT/Makefile" "$ROOT/VERSION" "$TREE/"
cp "$ROOT/tools/werror_flags.txt" "$ROOT/tools/tree_lock.sh" "$TREE/tools/"
smoke() { (cd "$TREE" && make --no-print-directory tree-lock-smoke "$@"); }

# 1. Two makes in one tree serialize, and both succeed.
smoke EIGS_LOCK_SMOKE_MARKER="$WORK/first" EIGS_LOCK_SMOKE_SLEEP=2 \
    EIGS_LOCK_SMOKE_DONE="$WORK/first-done" >"$WORK/first.log" 2>&1 &
first=$!
wait_for "$WORK/first" || fail "the first make did not enter its target"
smoke EIGS_LOCK_SMOKE_AFTER="$WORK/first-done" >"$WORK/second.log" 2>&1 &
second=$!
wait "$first" || fail "the first concurrent make failed"
wait "$second" || fail "the second make ran while the first held the tree (did not wait): $(cat "$WORK/second.log")"
[ "$(grep -Fxc "$NOTICE" "$WORK/second.log")" -eq 1 ] || fail "the waiting notice was not printed exactly once"
grep -Fq "$NOTICE" "$WORK/first.log" && fail "the uncontended make printed the waiting notice"
echo "  PASS: concurrent makes serialized and both succeeded"

# 2. A contended stop gate skips at once and never runs make.
# The production lock pathname must also remain owned by that one helper (and
# by .gitignore, which is not executable logic).
# One implementation takes the lock (#1952): among the tools, only
# tree_lock.sh names its path. This test names it too, as the independent
# oracle, so it is excluded.
mapfile -t lock_scripts < <(grep -lF "$LOCK" "$ROOT"/tools/*.sh | grep -vxF "$ROOT/tools/make_lock_check.sh" || true)
[ "${#lock_scripts[@]}" -eq 1 ] && [ "${lock_scripts[0]}" = "$ROOT/tools/tree_lock.sh" ] \
    || fail "the lock path is named by scripts other than tree_lock.sh: ${lock_scripts[*]}"
grep -Fxq "/$LOCK" "$ROOT/.gitignore" || fail "the tree lock is not ignored"
GATE="$WORK/gate"
mkdir -p "$GATE/tools" "$GATE/src" "$GATE/fakebin"
cp "$ROOT/tools/stop_gate.sh" "$ROOT/tools/tree_lock.sh" "$GATE/tools/"
printf 'all:\n\t@:\n' >"$GATE/Makefile"
printf 'base\n' >"$GATE/src/vm.c"
printf '#!/bin/sh\n: >"$MAKE_WAS_RUN"\nexit 0\n' >"$GATE/fakebin/make"
chmod +x "$GATE/fakebin/make"
(cd "$GATE" && git init -q && git -c user.name=t -c user.email=t@example.invalid add . &&
 git -c user.name=t -c user.email=t@example.invalid commit -qm base) || fail "gate repo setup"
printf 'dirty\n' >"$GATE/src/vm.c"
hold_lock "$GATE" gate
# The helper's public non-blocking mode has a distinct contention status.
sh "$GATE/tools/tree_lock.sh" --try "$GATE" $$
try_rc=$?
[ "$try_rc" -eq 75 ] || fail "tree_lock.sh --try returned $try_rc for a held lock (want 75)"
MAKE_WAS_RUN="$WORK/make-ran" PATH="$GATE/fakebin:$PATH" \
    timeout 5 bash "$GATE/tools/stop_gate.sh" >"$WORK/gate.log" 2>&1
gate_rc=$?
release gate
[ "$gate_rc" -eq 0 ] || fail "the contended stop gate did not exit 0 (rc=$gate_rc)"
grep -Fxq "stop-gate: SKIP: a build holds this tree's lock; not racing it" "$WORK/gate.log" \
    || fail "the stop gate did not print its skip notice"
[ ! -e "$WORK/make-ran" ] || fail "the contended stop gate invoked make"
echo "  PASS: contended stop gate skipped without invoking make"

# 3. A make that inherits the held flag does not lock again (a recursive make
# would otherwise deadlock on its parent's lock).
hold_lock "$TREE" nested
(cd "$TREE" && timeout 5 env EIGS_TREE_LOCK_HELD=1 make --no-print-directory tree-lock-smoke) \
    >"$WORK/inherited.log" 2>&1
inherited_rc=$?
release nested
[ "$inherited_rc" -eq 0 ] || fail "a make with EIGS_TREE_LOCK_HELD=1 tried to take the held lock (rc=$inherited_rc)"
echo "  PASS: inherited lock flag bypassed lock acquisition"

# 4. `make clean` removes build/. The lock must not live there, or a waiter
# and a newcomer would each hold a lock on a different file.
mkdir -p "$TREE/build"
smoke EIGS_LOCK_SMOKE_MARKER="$WORK/clean" EIGS_LOCK_SMOKE_SLEEP=2 \
    EIGS_LOCK_SMOKE_DONE="$WORK/clean-done" >"$WORK/clean-first.log" 2>&1 &
first=$!
wait_for "$WORK/clean" || fail "the clean-case make did not enter its target"
rm -rf "$TREE/build"
smoke EIGS_LOCK_SMOKE_AFTER="$WORK/clean-done" >"$WORK/clean-second.log" 2>&1 &
second=$!
wait "$first" || fail "the clean-case first make failed"
wait "$second" || fail "a make started after build/ was removed did not wait: $(cat "$WORK/clean-second.log")"
echo "  PASS: the lock survives removal of build/"
# 5. Question mode answers as an unlocked make: an existing file with no rule is
# up to date. (A make that re-ran itself under a phony lock target answered
# "out of date" for everything, which broke the LSP and DAP freshness checks.)
(cd "$TREE" && timeout 10 make -q VERSION) >"$WORK/question.log" 2>&1
q_rc=$?
[ "$q_rc" -eq 0 ] || fail "make -q on an up-to-date file exited $q_rc: $(cat "$WORK/question.log")"
echo "  PASS: make -q answers as an unlocked make"

# 6. An extra makefile that includes the Makefile still works. (A re-run make
# loses -f, which MAKEFLAGS does not carry: tests/test_missing_capability.sh.)
printf 'include Makefile\n.PHONY: extra-goal\nextra-goal:\n\t@echo extra-goal-ran\n' >"$TREE/extra.mk"
(cd "$TREE" && timeout 10 make --no-print-directory -f extra.mk extra-goal) >"$WORK/extra.log" 2>&1 \
    || fail "make -f extra.mk failed: $(cat "$WORK/extra.log")"
grep -Fxq extra-goal-ran "$WORK/extra.log" || fail "make -f extra.mk did not run its own goal"
echo "  PASS: an extra -f makefile that includes the Makefile works"
# 7. make leaves nothing in its session: the lock holder runs in its own. The
# ownership check that gc_traversal_check runs make under
# (tools/bounded_process.py) refused a holder that outlived make by one poll.
# Two parts: the real harness, and a structural check that does not depend on
# timing (while make runs, its session holds no holder).
(cd "$TREE" && make --no-print-directory tree-lock-smoke EIGS_LOCK_SMOKE_SESSION="$WORK/session") \
    >"$WORK/session.log" 2>&1 || fail "the session-witness make failed: $(cat "$WORK/session.log")"
grep -q 'tree_lock.sh hold' "$WORK/session" && fail "the lock holder runs inside make's session: $(cat "$WORK/session")"
python3 - "$ROOT/tools" "$TREE" "$WORK/owned" <<'PY' || fail "make under tools/bounded_process.py left a live session member"
import os, pathlib, sys
sys.path.insert(0, sys.argv[1])
from bounded_process import run_owned
record = run_owned(['make', '--no-print-directory', '-s', 'tree-lock-smoke'],
                   pathlib.Path(sys.argv[3]), 20, dict(os.environ), sys.argv[2])
sys.exit(0 if record.get('returncode') == 0 else 1)
PY
echo "  PASS: make leaves nothing in its session (bounded_process accepts it)"
# 8. A try right after a make exits is not a running build. A holder keeps the
# lock up to one poll (0.05 s) after its make's PID exits, so a try with no
# grace read that trailing poll as a build and skipped: the stop gate's own
# back-to-back selftest runs hit it. Five rounds: take the lock for a
# short-lived owner, let the owner exit, try at once; every try must succeed.
mkdir -p "$WORK/trailing"
for round in 1 2 3 4 5; do
    sleep 0.2 & owner=$!
    sh "$ROOT/tools/tree_lock.sh" "$WORK/trailing" "$owner" || fail "round $round: the first holder did not start"
    wait "$owner" 2>/dev/null
    sleep 5 & owner2=$!
    sh "$ROOT/tools/tree_lock.sh" --try "$WORK/trailing" "$owner2"; try_rc=$?
    kill "$owner2" 2>/dev/null; wait "$owner2" 2>/dev/null
    [ "$try_rc" -eq 0 ] || fail "round $round: a try right after the owner exited answered $try_rc (want 0): the trailing poll read as a build"
done
echo "  PASS: a try just after a make exits takes the lock"

# 9. Cases 1--8 already prove that a held lock makes plain make wait and makes
# --try answer busy.  This case proves only the missing lifetime property: the
# suite keeps its lock across section seams, then releases it when it exits.
# Use a sibling copy with its own lock inode so this runs even when an enclosing
# `make precheck` owns ROOT's lock.  Hard links make the copy cheap; the printed
# fallback is deliberately visible rather than turning a failed copy into skip.
COPY_PARENT=$(dirname "$ROOT")
SUITE_TREE=$(mktemp -d "$COPY_PARENT/eigs-lock-suite.XXXXXX") \
    || fail "could not create sibling suite tree"
rm -rf "$SUITE_TREE"
mkdir "$SUITE_TREE" || fail "could not initialize sibling suite tree"
# These are all the roots used by the runner preamble and inert sections.
# Naming them avoids copying unrelated untracked directories (for example an
# editor's node_modules).
SUITE_COPY_ITEMS='Makefile VERSION src tests tools'
# shellcheck disable=SC2086
if ! (cd "$ROOT" && cp -al $SUITE_COPY_ITEMS "$SUITE_TREE/") 2>/dev/null; then
    echo "    NOTE: hard-link scratch copy failed; falling back to cp -a"
    rm -rf "$SUITE_TREE"
    mkdir "$SUITE_TREE" || fail "could not reinitialize sibling suite tree"
    # shellcheck disable=SC2086
    (cd "$ROOT" && cp -a $SUITE_COPY_ITEMS "$SUITE_TREE/") || fail "could not copy suite fixture"
fi
# Never share the source tree's lock inode (cp -al copied it if it existed).
rm -f "$SUITE_TREE/$LOCK"
# Make an inert runner from the production preamble: lock acquisition and the
# real section-seam implementation are preserved, while product tests and the
# section planner are irrelevant to this lifetime-only assertion.  Write then
# rename so a hard-linked source runner is never modified.
awk '/^# Runaway guard/{exit} {print}' "$SUITE_TREE/tests/run_all_tests.sh" >"$SUITE_TREE/tests/runner.new"
cat >>"$SUITE_TREE/tests/runner.new" <<'SUITE_FIXTURE'
echo "[lock-a] lifetime fixture"
:
echo "[lock-b] lifetime fixture"
:
echo "[lock-c] lifetime fixture"
__eigs_section_close
exit 0
SUITE_FIXTURE
mv "$SUITE_TREE/tests/runner.new" "$SUITE_TREE/tests/run_all_tests.sh"
SEAMS="$WORK/seams"
mkdir -p "$SEAMS"
: >"$SEAMS/hold-2"
(
    cd "$SUITE_TREE/tests" || exit 1
    EIGS_LOCK_TEST_SEAMS="$SEAMS" bash run_all_tests.sh
) >"$WORK/suite.log" 2>&1 &
suite=$!
HOLDERS+=("$suite")
wait_for_suite "$SEAMS/seam-1" || fail "suite did not reach its first section seam: $(tail -20 "$WORK/suite.log")"
wait_for_suite "$SEAMS/seam-2" || fail "suite did not reach its second section seam: $(tail -20 "$WORK/suite.log")"
sleep 5 & probe_owner=$!
sh "$SUITE_TREE/tools/tree_lock.sh" --try "$SUITE_TREE" "$probe_owner" >/dev/null 2>&1
try_rc=$?
kill "$probe_owner" 2>/dev/null; wait "$probe_owner" 2>/dev/null
rm -f "$SEAMS/hold-2"
[ "$try_rc" -eq 75 ] || fail "--try answered $try_rc between suite section seams (want busy=75)"
wait "$suite" || fail "locked suite failed: $(tail -20 "$WORK/suite.log")"
sleep 5 & probe_owner=$!
sh "$SUITE_TREE/tools/tree_lock.sh" --try "$SUITE_TREE" "$probe_owner" >/dev/null 2>&1
try_rc=$?
kill "$probe_owner" 2>/dev/null; wait "$probe_owner" 2>/dev/null
[ "$try_rc" -eq 0 ] || fail "--try answered $try_rc after suite exit (want free=0)"
rm -rf "$SUITE_TREE"
echo "  PASS: suite lock was busy across section seams and free after exit"
echo "make-lock selftest: 9/9 passed"
