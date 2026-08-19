#!/bin/bash
# Gate for tests/lsan_classify.sh — the sanitizer-output classifier that decides
# whether a nonzero exit is a tolerable leak or a masked hard failure.
#
# This gate exists because the thing it guards failed SILENTLY three times
# (#945/#953, #969, #968). A classifier that has never been observed to reject
# has not been shown to work, so this file does seven things:
#
#   1. corpus     — classify every fixture, compare against the directory truth
#   2. floors     — a class that lost fixtures FAILS. "at least one" is not a
#                   floor; coverage that silently shrank must go red (§5).
#   3. tracked    — every fixture is committed. An untracked fixture passes here
#                   and is simply absent in CI, which is coverage loss that
#                   looks like a clean run (§1).
#   4. mutation   — break the classifier on purpose; the corpus MUST go red, AND
#                   the mutant must still START and must break the SPECIFIC
#                   fixture the mutation targets. A mutant that fails to source
#                   is reported BROKEN, never CAUGHT — otherwise a typo in the
#                   sed scores as a successful probe (§19). Covers whole probe
#                   branches AND the names/anchors inside them, because a floor
#                   over fixtures does not count mechanisms.
#   5. differential — cross-check against the independent Python classifier in
#                   tests/test_doc_examples.py, as a one-way implication.
#   6. call sites — drive the real rc_ok in a real exported child shell.
#   7. leavings   — the run must create nothing untracked in the tree it polices.
#
# WHAT THIS GATE DOES NOT COVER (§6 — residuals belong in the code, and a
# residual you did not probe is a claim, not a residual, so these were checked):
#   - test_sigusr1_dump.sh's use of the classifier is NOT exercised here; only
#     suite section [99e], which runs that script, covers it. (rc_ok IS covered,
#     by check 6 — that residual used to be listed here and was where the next
#     bug lived: rc_ok was exported into child shells without the classifier.)
#   - The ThreadSanitizer data-race and MemorySanitizer fixtures are synthetic:
#     TSan would not start on the development machine ("FATAL: ThreadSanitizer:
#     unexpected memory mapping") and MSan needs an instrumented libc, so those
#     shapes are hand-written from the documented format. Everything named
#     "real-*" — and hard/tsan-fatal-startup.txt — is captured output.
#   - A test program whose OWN stdout contains a sanitizer report line is
#     classified as though the sanitizer emitted it. That is deliberate — the
#     alternative is parsing program output — and the "prose-mentioning-marker"
#     fixture pins the boundary: prose mentioning the marker mid-line does not
#     count, a whole marker line does.
#
# Usage: test_lsan_classify.sh [path-to-classifier]

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TESTS_DIR/.." && pwd)
CLASSIFIER="${1:-$TESTS_DIR/lsan_classify.sh}"
CORPUS="$TESTS_DIR/fixtures/lsan_classify"

# Per-class floors. These move only when coverage is deliberately REMOVED, so
# an edit here is always a reviewable act (§5). Adding fixtures needs no edit.
FLOOR_leak=7
FLOOR_hard=20
FLOOR_none=5

PASS=0
FAIL=0

fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }

# All git access goes through here. `-c safe.directory='*'` is required because
# CI runs the suite INSIDE a container (.github/workflows/ci.yml `container:`),
# where the checkout is owned by a different uid than the job user, so every
# plain git call dies with:
#   fatal: detected dubious ownership in repository at '/__w/EigenScript/...'
# actions/checkout does add the path to safe.directory, but on the RUNNER's
# global config, which the container's user does not read. The flag is scoped to
# the single invocation — no global config is mutated — and these calls are all
# read-only.
#
# This is the suite's first use of git; nothing else in run_all_tests.sh shells
# out to it, which is why this failure surfaced only here.
_lc_git() { git -c safe.directory='*' -C "$ROOT" "$@"; }

# Is git usable against this tree? Three outcomes kept distinct, because
# reporting an unrunnable instrument as a benign absence is how a gate goes
# quietly blind:
#   ok      — git works here
#   absent  — no git binary at all; genuinely nothing to check against
#   refused — git exists but will not read this tree. NOT a skip: something is
#             wrong with the environment and the checks that depend on it are
#             unavailable, which must be loud.
_lc_git_state() {
    if ! command -v git >/dev/null 2>&1; then echo absent; return; fi
    if _lc_git rev-parse --git-dir >/dev/null 2>&1; then echo ok; return; fi
    # Distinguish "not a repo" (fine — a tarball) from "repo, but refused".
    if [ -e "$ROOT/.git" ]; then echo refused; else echo absent; fi
}
GIT_STATE=$(_lc_git_state)

# Snapshot the tree's untracked set BEFORE doing anything, so the leavings
# check at the end reports only what THIS RUN created. Comparing against a bare
# "is anything untracked" would fire on a developer's unrelated scratch file —
# a gate that cries wolf gets muted.
UNTRACKED_BEFORE=""
if [ "$GIT_STATE" = ok ]; then
    UNTRACKED_BEFORE=$(_lc_git ls-files --others --exclude-standard -- tests 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# Corpus runner. Prints one of:
#   "SOURCE-ERROR"            classifier file did not load (rc 3)
#   "VACUOUS ..."             population empty or a class below its floor (rc 2)
#   "<n> examined=<m> ..."    n mismatches (rc 0 iff n == 0)
# The mismatching fixture names are printed on stdout after the counts so a
# mutation can assert WHICH fixture it broke (§20/§21) rather than settling for
# "something went red".
# ---------------------------------------------------------------------------
run_corpus() {
    local classifier="$1"
    (
        # shellcheck disable=SC1090
        if ! . "$classifier" 2>/dev/null; then echo "SOURCE-ERROR"; exit 3; fi
        # The mutant must actually provide the entry point. A sed that deletes
        # the function leaves a file that sources fine and classifies nothing.
        if ! command -v lsan_classify_name >/dev/null 2>&1; then
            echo "SOURCE-ERROR"; exit 3
        fi

        local examined=0 mismatches=0 broken=""
        local n_leak=0 n_hard=0 n_none=0
        for class in leak hard none; do
            for fixture in "$CORPUS/$class"/*.txt; do
                [ -e "$fixture" ] || continue
                examined=$((examined + 1))
                case "$class" in
                    leak) n_leak=$((n_leak + 1)) ;;
                    hard) n_hard=$((n_hard + 1)) ;;
                    none) n_none=$((n_none + 1)) ;;
                esac
                local content got
                content=$(cat "$fixture")
                got=$(lsan_classify_name "$content")
                if [ "$got" != "$class" ]; then
                    mismatches=$((mismatches + 1))
                    broken="$broken $class/$(basename "$fixture")->$got"
                fi
            done
        done

        # Vacuity + floors. A run that examined nothing, or a class that lost
        # fixtures, is a FAILURE — never a quiet pass.
        if [ "$examined" -eq 0 ] || [ "$n_leak" -lt "$FLOOR_leak" ] || \
           [ "$n_hard" -lt "$FLOOR_hard" ] || [ "$n_none" -lt "$FLOOR_none" ]; then
            echo "VACUOUS examined=$examined leak=$n_leak/$FLOOR_leak hard=$n_hard/$FLOOR_hard none=$n_none/$FLOOR_none"
            exit 2
        fi

        echo "$mismatches examined=$examined"
        [ -n "$broken" ] && echo "mismatched:$broken"
        [ "$mismatches" -eq 0 ]
    )
}

# ---------------------------------------------------------------------------
# 1 + 2. Corpus and floors.
# ---------------------------------------------------------------------------
echo "[lsan-classify] corpus"
CORPUS_RESULT=$(run_corpus "$CLASSIFIER")
CORPUS_RC=$?
case "$CORPUS_RC" in
    0) pass "corpus: every fixture classified as its directory says (${CORPUS_RESULT%%$'\n'*})" ;;
    2) fail "corpus below floor / vacuous — $CORPUS_RESULT" ;;
    3) fail "classifier '$CLASSIFIER' failed to load" ;;
    *) fail "corpus disagreement — $(echo "$CORPUS_RESULT" | tr '\n' ' ')" ;;
esac

# ---------------------------------------------------------------------------
# 3. Every fixture is committed. An untracked fixture is examined here and
#    absent in CI — coverage loss wearing a green badge (§1).
# ---------------------------------------------------------------------------
echo "[lsan-classify] fixtures tracked"
if [ "$GIT_STATE" = refused ]; then
    fail "git is installed and $ROOT is a repository, but git refuses to read it — the tracked-fixture check cannot run (see _lc_git)"
elif [ "$GIT_STATE" = ok ]; then
    UNTRACKED=$(_lc_git ls-files --others --exclude-standard -- \
        "tests/fixtures/lsan_classify" 2>/dev/null)
    TRACKED_N=$(_lc_git ls-files -- "tests/fixtures/lsan_classify" 2>/dev/null | wc -l)
    if [ -n "$UNTRACKED" ]; then
        fail "untracked fixture(s) — present locally, absent in CI:
$(echo "$UNTRACKED" | sed 's/^/      /')"
    elif [ "$TRACKED_N" -eq 0 ]; then
        # Enumeration vacuity: asking git and getting nothing is not agreement.
        fail "git tracks 0 corpus fixtures — the tracked-check enumerated nothing"
    else
        pass "fixtures tracked: $TRACKED_N committed, 0 untracked"
    fi
else
    echo "  SKIP: not a git checkout — tracked-fixture check skipped"
fi

# ---------------------------------------------------------------------------
# 4. Mutation gate.
#
# Each mutation reintroduces a real historical bug and names the fixture it
# MUST break. Three distinct outcomes, kept distinct on purpose:
#   CAUGHT  — mutant loaded, ran, and broke its named fixture
#   BROKEN  — mutant did not load or the sed matched nothing; the probe is
#             invalid and proves nothing (§19). Reported as a FAILURE of this
#             file, so a rotted sed cannot masquerade as a successful probe.
#   SURVIVED— mutant ran and the corpus stayed green; the gate gates nothing
# ---------------------------------------------------------------------------
echo "[lsan-classify] mutation"
MUTANT_DIR=$(mktemp -d)
trap 'rm -rf "${MUTANT_DIR:-}"' EXIT

run_mutation() {
    local name="$1" sed_prog="$2" must_break="$3" bug="$4"
    local mutant="$MUTANT_DIR/$name.sh"

    if ! sed -E "$sed_prog" "$CLASSIFIER" > "$mutant" 2>/dev/null; then
        fail "mutation '$name' BROKEN — sed failed"
        return
    fi
    if cmp -s "$mutant" "$CLASSIFIER"; then
        fail "mutation '$name' BROKEN — sed matched nothing; it has rotted away from the classifier"
        return
    fi

    local out rc
    out=$(run_corpus "$mutant")
    rc=$?

    if [ "$rc" -eq 3 ]; then
        # The §19 trap: without this branch a mutant that cannot even load
        # scores as a successful probe.
        fail "mutation '$name' BROKEN — mutant does not load; the fault never executed"
        return
    fi
    if [ "$rc" -eq 0 ]; then
        fail "mutation '$name' SURVIVED — corpus stayed green with $bug reintroduced"
        return
    fi
    if [ "$rc" -eq 2 ]; then
        fail "mutation '$name' BROKEN — mutant went vacuous rather than mismatching ($out)"
        return
    fi
    # rc == 1: genuine mismatch. Now check it broke the RIGHT fixture — a
    # mutation that goes red for an unrelated reason proves nothing about the
    # mechanism it was aimed at (§21).
    if echo "$out" | grep -qF "$must_break"; then
        pass "mutation '$name' caught via $must_break ($bug)"
    else
        fail "mutation '$name' went red but NOT on $must_break — wrong mechanism attributed. Got: $(echo "$out" | tr '\n' ' ')"
    fi
}

# #969: drop the hard-diagnostic probe -> mixed output tolerated again.
run_mutation "no-hard-probe" \
    's@^    if printf .%s\\n. "\$_lc_residue".*@    if false; then@' \
    "hard/issue-969-mixed-ubsan.txt" \
    "the #969 masked hard failure"

# #968: stop filtering benign leak summaries -> real leak-only read as hard.
run_mutation "no-benign-filter" \
    's@^    _lc_residue=\$\(printf .*@    _lc_residue="$_lc_out"@' \
    "leak/real-asan-leak-only.txt" \
    "the #968 false hard-failure"

# Blanket tolerance: the exact shape of the original rc_ok bug.
run_mutation "tolerate-everything" \
    's@^        return 1$@        return 0@' \
    "hard/real-asan-heap-use-after-free.txt" \
    "blanket tolerance"

# Unanchor the leak marker -> prose mentioning it counts as a report.
run_mutation "unanchored-marker" \
    "s@^    _lc_marker=.*@    _lc_marker='LeakSanitizer: detected memory leaks'@" \
    "none/prose-mentioning-marker.txt" \
    "an unanchored marker matching prose"

# --- Probe-branch witnesses -------------------------------------------------
# The floors above count FIXTURES, which is not the same as counting
# MECHANISMS: 20 hard fixtures can exercise six probe alternatives, leaving a
# branch whose last witness is gone still "covered" by the floor. Each mutation
# below deletes exactly one alternative and names a fixture where that
# alternative is the SOLE evidence. If any survives, that branch is dead weight
# the corpus cannot see.

# 1. ERROR:-headed reports. stack-overflow.txt carries no SUMMARY, no FATAL and
#    no DEADLYSIGNAL, so only this branch can catch it.
run_mutation "probe-drop-ERROR" \
    's@\(\^\|\[\^A-Za-z\]\)ERROR: \(\$_lc_hard_names\)\|@@' \
    "hard/stack-overflow.txt" \
    "the ERROR:-headed report branch"

# 2. WARNING:-headed reports (TSan races, MSan uninitialised reads). Under
#    print_summary=0 there is no SUMMARY line, so this branch is all there is.
run_mutation "probe-drop-WARNING" \
    's@\(\^\|\[\^A-Za-z\]\)WARNING: \(\$_lc_hard_names\):\|@@' \
    "hard/tsan-race-no-summary.txt" \
    "the WARNING:-headed report branch"

# 3. FATAL:-headed startup failures. No ERROR:, no SUMMARY.
run_mutation "probe-drop-FATAL" \
    's@\(\^\|\[\^A-Za-z\]\)FATAL: \(\$_lc_all_names\)\|@@' \
    "hard/tsan-fatal-startup.txt" \
    "the FATAL:-headed startup-failure branch"

# 4. DEADLYSIGNAL / CHECK failed. deadly-signal-only.txt has nothing else.
run_mutation "probe-drop-deadly" \
    's@\(\$_lc_all_names\): \?\(DEADLYSIGNAL\|CHECK failed\)\|@@' \
    "hard/deadly-signal-only.txt" \
    "the DEADLYSIGNAL/CHECK-failed branch"

# 5. UBSan's per-check line. Recoverable UBSan prints only this and exits 0.
run_mutation "probe-drop-runtime-error" \
    's@runtime error: \|@@' \
    "hard/real-ubsan-signed-overflow.txt" \
    "the UBSan 'runtime error:' branch"

# 6. Non-benign SUMMARY lines. leak-marker-with-hard-summary.txt is headed by
#    ERROR: LeakSanitizer (tolerable), so only the SUMMARY branch condemns it.
run_mutation "probe-drop-SUMMARY" \
    's@\|\^\(==\[0-9\]\+==\)\?SUMMARY: \(\$_lc_all_names\):@@' \
    "hard/leak-marker-with-hard-summary.txt" \
    "the non-benign SUMMARY: branch"

# --- Sub-alternation witnesses ----------------------------------------------
# Whole-branch mutations above still pass while an individual NAME or anchor
# inside a branch has no witness. These delete one name/anchor each.

run_mutation "name-drop-UBSan" \
    's@AddressSanitizer\|ThreadSanitizer\|MemorySanitizer\|UndefinedBehaviorSanitizer@AddressSanitizer|ThreadSanitizer|MemorySanitizer@' \
    "hard/ubsan-error-headed.txt" \
    "UndefinedBehaviorSanitizer dropped from the hard-name list"

run_mutation "name-drop-LSan-from-all" \
    's@^    _lc_all_names=.*@    _lc_all_names="$_lc_hard_names"@' \
    "hard/lsan-check-failed.txt" \
    "LeakSanitizer dropped from the CHECK-failed/SUMMARY names"

run_mutation "probe-drop-pid-prefix" \
    's@\^\(==\[0-9\]\+==\)\?SUMMARY: \(\$_lc_all_names\)@^SUMMARY: ($_lc_all_names)@' \
    "hard/summary-with-pid-prefix.txt" \
    "the ==pid== prefix allowance on the hard SUMMARY branch"

# The pre-filter must be LOOSER than the matcher. Tightening it (dropping the
# "runtime error: " arm) makes it exclude inputs the matcher would have caught —
# the §14 "too tight" failure, which is silent coverage loss.
run_mutation "prefilter-too-tight" \
    's@^        \*Sanitizer\*\|\*"runtime error: "\*\) ;;@        *Sanitizer*) ;;@' \
    "hard/real-ubsan-signed-overflow.txt" \
    "a pre-filter tightened until it excludes real UBSan output"

# The benign filter must not be wide enough to swallow non-leak diagnostics.
# All UBSan fixtures used to say "signed integer overflow", so a filter widened
# to other UBSan kinds went unnoticed.
run_mutation "benign-filter-swallows-ubsan" \
    's@^    _lc_benign_summary=.*@    _lc_benign_summary="runtime error: (shift\|division)"@' \
    "hard/real-ubsan-shift-and-divzero.txt" \
    "a benign filter widened to swallow other UBSan kinds"


# Positive control's second half (§15): an unmodified copy must PASS. Without
# it, a check that always reports red would score four clean CAUGHTs above.
CONTROL="$MUTANT_DIR/control.sh"
cp "$CLASSIFIER" "$CONTROL"
if run_corpus "$CONTROL" >/dev/null 2>&1; then
    pass "control: an unmutated copy passes the same corpus"
else
    fail "control: an UNMUTATED copy failed the corpus — the mutation results above are meaningless"
fi

# ---------------------------------------------------------------------------
# 5. Differential against the independent Python classifier in
#    tests/test_doc_examples.py.
#
#    The two answer DIFFERENT questions, and pretending otherwise is how a
#    differential lies: is_lsan_only_failure() asks "is this entire stderr a
#    well-formed LSan report?", while lsan_classify() sees combined output that
#    legitimately contains the program's own stdout. So the property is a
#    one-way implication, not an equality — Python's answer is the strict
#    subset:
#
#      python says leak-only  =>  shell must say "leak"
#
#    It runs over EVERY fixture, so the corpus cannot drift out from under a
#    hand-maintained list.
#
#    ONLY ONE DIRECTION IS ENFORCEABLE, and saying so is the point. The obvious
#    converse ("shell says hard => python must not certify") is not an
#    independent check: any such fixture has already violated the implication
#    above, so a converse clause is dead code that makes the gate advertise two
#    checks while enforcing one. It was written, observed to be unreachable, and
#    removed rather than left in as decoration.
#
#    CERT_FLOOR: "python certified at least one" is not a floor either — the
#    implication is nearly vacuous at 1. It is pinned so the reference oracle
#    cannot quietly go blind.
#
#    History worth keeping: this floor sat at 2 because is_lsan_only_failure()
#    REQUIRED an "Objects leaked above:" block, which compiler-rt emits only
#    under LSAN_OPTIONS=report_objects=1 — not what CI sets — so it rejected
#    ordinary real leak reports (#980). Fixed: that section is now optional, and
#    the floor rose 2 -> 3 as a result. A floor that moves DOWN is a regression
#    in the oracle, not a number to adjust.
#      certified today: leak/bare-marker.txt              (single-line form)
#                       leak/real-asan-leak-only.txt      (default options — #980)
#                       leak/real-asan-leak-report-objects.txt (report_objects=1)
#    Most remaining leak/ fixtures interleave the program's own stdout, which
#    the whole-stderr Python parser correctly declines to certify — that is the
#    difference in question the implication exists to accommodate, not a gap.
#    One exception, stated rather than glossed: leak/issue-968-asan-leak-summary.txt
#    is entirely sanitizer-emitted yet uncertified, because it is the abbreviated
#    two-line form from #968's bug report (no leading separator, no ==pid==
#    prefix) rather than a captured report. The shell classifier accepts it on
#    purpose — it is the shape the issue documents — and the Python walk requires
#    a full report. Not a defect in either; do not "fix" it by loosening the walk.
# ---------------------------------------------------------------------------
echo "[lsan-classify] differential vs tests/test_doc_examples.py"
if command -v python3 >/dev/null 2>&1; then
    VERDICTS="$MUTANT_DIR/verdicts.tsv"
    (
        # shellcheck disable=SC1090
        . "$CLASSIFIER"
        for class in leak hard none; do
            for fixture in "$CORPUS/$class"/*.txt; do
                [ -e "$fixture" ] || continue
                printf '%s\t%s\n' "$class/$(basename "$fixture")" \
                    "$(lsan_classify_name "$(cat "$fixture")")"
            done
        done
    ) > "$VERDICTS"

    # -B / dont_write_bytecode: importing tests/test_doc_examples.py otherwise
    # drops tests/__pycache__/ into the working tree, which is NOT gitignored —
    # a gate that leaves litter in the tree it checks. The tracked-fixture
    # check above would then also start reporting it as untracked.
    DIFF_OUT=$(python3 -B - "$CORPUS" "$ROOT" "$VERDICTS" <<'PY'
import importlib.util, pathlib, sys
sys.dont_write_bytecode = True

corpus, root, verdicts = (pathlib.Path(a) for a in sys.argv[1:4])
spec = importlib.util.spec_from_file_location(
    "doc_examples", root / "tests" / "test_doc_examples.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

examined = violations = certified = 0
for line in verdicts.read_text().splitlines():
    if not line.strip():
        continue
    rel, shell = line.split("\t")
    path = corpus / rel
    if not path.exists():
        print("MISSING %s" % rel)
        violations += 1
        continue
    examined += 1
    py_leak_only = mod.is_lsan_only_failure(path.read_text())
    if py_leak_only:
        certified += 1
        if shell != "leak":
            print("VIOLATION %s python=leak-only shell=%s" % (rel, shell))
            violations += 1

CERT_FLOOR = 3
if examined == 0:
    print("VACUOUS: no fixtures examined")
    sys.exit(2)
if certified < CERT_FLOOR:
    # The implication holds trivially when python certifies little. A floor,
    # not a "greater than zero" — the latter is satisfied by one single-line
    # fixture and would not notice the reference oracle going blind.
    print("VACUOUS: python certified %d of %d fixtures, floor is %d"
          % (certified, examined, CERT_FLOOR))
    sys.exit(2)
print("examined=%d python-certified=%d violations=%d"
      % (examined, certified, violations))
sys.exit(1 if violations else 0)
PY
    )
    DIFF_RC=$?
    if [ "$DIFF_RC" -eq 0 ]; then
        pass "differential: implications hold ($DIFF_OUT)"
    else
        fail "differential: $(echo "$DIFF_OUT" | tr '\n' ' ')"
    fi
else
    echo "  SKIP: python3 unavailable — differential cross-check skipped"
fi

# ---------------------------------------------------------------------------
# 6. Call sites. The gate used to disclaim this ("does not prove the verdict is
#    ACTED ON") and the disclaimer was where the next bug lived: rc_ok is
#    `export -f`'d into child shells at [99c]/[99d], `export -f` carries only
#    the functions it names, and lsan_classify was not in those lists. In the
#    child, rc_ok got $? = 127 from `command not found` — which is neither 1 nor
#    0, so a hard diagnostic at rc=0 was TOLERATED and genuine leak-only output
#    was FAILED, both silently. A named residual is a claim, not coverage.
#
#    So: drive the real rc_ok, from the real runner, in a child shell carrying
#    the real export set, over real captured fixtures.
# ---------------------------------------------------------------------------
echo "[lsan-classify] call sites (rc_ok, incl. exported child shells)"
RUNNER="$TESTS_DIR/run_all_tests.sh"
if [ ! -r "$RUNNER" ]; then
    fail "call-site check: cannot read $RUNNER"
else
    # Extract the exported-function list the runner actually uses, rather than
    # restating it here — a second hand-written list is what this whole change
    # exists to delete.
    EXPORT_LINES=$(grep -c '^[[:space:]]*export -f ' "$RUNNER" || true)
    MISSING_EXPORTS=$(grep '^[[:space:]]*export -f ' "$RUNNER" \
        | grep 'rc_ok' | grep -vc 'lsan_classify' || true)
    if [ "$EXPORT_LINES" -eq 0 ]; then
        fail "call-site check: found no 'export -f' lines to inspect (enumeration vacuity)"
    elif [ "$MISSING_EXPORTS" -ne 0 ]; then
        fail "call-site check: $MISSING_EXPORTS 'export -f' line(s) ship rc_ok without lsan_classify"
    else
        pass "call-site check: every 'export -f' line carrying rc_ok also carries lsan_classify ($EXPORT_LINES inspected)"
    fi

    # Behavioural half: run rc_ok in a child shell exactly as [99d] does.
    CS_OUT=$(
        set +u
        # shellcheck disable=SC1090
        . "$TESTS_DIR/lsan_classify.sh"
        eval "$(sed -n '/^rc_ok() {$/,/^}$/p' "$RUNNER")"
        LEAKED=0
        export -f rc_ok lsan_classify lsan_classify_name
        export TESTS_DIR
        hard=$(cat "$CORPUS/hard/real-asan-heap-use-after-free.txt")
        leak=$(cat "$CORPUS/leak/real-asan-leak-only.txt")
        export hard leak
        bash -c '
            LEAKED=0
            if rc_ok 0 "$hard"; then echo "hard-at-rc0:TOLERATED"; else echo "hard-at-rc0:REJECTED"; fi
            if rc_ok 1 "$leak"; then echo "leak-at-rc1:TOLERATED"; else echo "leak-at-rc1:REJECTED"; fi
        ' 2>&1
    )
    if echo "$CS_OUT" | grep -q "hard-at-rc0:REJECTED" && \
       echo "$CS_OUT" | grep -q "leak-at-rc1:TOLERATED"; then
        pass "call-site check: rc_ok in an exported child shell rejects hard-at-rc0 and tolerates leak-at-rc1"
    else
        fail "call-site check: rc_ok misbehaves in an exported child shell — $(echo "$CS_OUT" | tr '\n' ' ')"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Leavings. A gate's outputs get checked; its side effects usually do not.
#    This run imports a Python module out of tests/ and writes mutants to a
#    temp dir — neither may leave anything behind in the tree it polices.
# ---------------------------------------------------------------------------
echo "[lsan-classify] leavings"
if [ "$GIT_STATE" = refused ]; then
    fail "git refuses to read $ROOT — the leavings check cannot run (see _lc_git)"
elif [ "$GIT_STATE" = ok ]; then
    UNTRACKED_AFTER=$(_lc_git ls-files --others --exclude-standard -- tests 2>/dev/null)
    NEW_LEAVINGS=$(comm -13 \
        <(printf '%s\n' "$UNTRACKED_BEFORE" | sort) \
        <(printf '%s\n' "$UNTRACKED_AFTER" | sort))
    if [ -n "$(printf '%s' "$NEW_LEAVINGS" | tr -d '[:space:]')" ]; then
        fail "this run created untracked file(s) under tests/:
$(printf '%s\n' "$NEW_LEAVINGS" | sed '/^$/d; s/^/      /')"
    else
        pass "leavings: this run created nothing untracked under tests/"
    fi
else
    echo "  SKIP: not a git checkout — leavings check skipped"
fi

echo
echo "[lsan-classify] $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "All tests passed"
