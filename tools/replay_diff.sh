#!/usr/bin/env bash
# #1072: same-binary tape REPLAY fidelity, the tape's own contract (docs/TRACE.md:
# a tape recorded and replayed by the same binary reproduces stdout+stderr+rc).
# jit_diff.sh leans on this contract to adjudicate nondeterministic programs, so
# every hole in it is a hole in that oracle too.
#
# For every corpus program (JIT off on both sides so the JIT is not the
# variable): record a tape, replay it, normalize, diff. A divergence is one of:
#   BOUNDARY  the replay stderr names the documented subprocess/concurrency
#             boundary ("not replayable under EIGS_REPLAY") -- by design (#148),
#             counted, never a row;
#   ROW       anything else -- a fidelity hole, ledgered in
#             tests/replay_diff_expected.txt (a ledger to work down, never an
#             amnesty; the count only goes down).
# Self-check before comparing: the record arm must WRITE a tape (a run that
# never traced would replay itself trivially green), and the replay arm must
# READ it (EIGS_REPLAY of a missing tape is refused by name).
#
# #1112: a SIGNAL exit (rc >= 128) in EITHER arm is a hard FAIL, whatever the
# arm printed. The boundary branch used to classify a replay arm that printed
# the diagnostic and then died by SIGSEGV as "boundary" and the run said OK
# over a crash; a crash both arms agree on was likewise invisible to the diff.
# The crash check runs before any classification and is the first verdict.
# It is a NUMERIC rc >= 128 test: 120-127 (timeout 124, no-such-command
# 127) are ordinary nonzero exits and still get diffed into rows.
#
# Usage: bash tools/replay_diff.sh [--record | --selftest]
#   --selftest  plant a boundary-plus-crash witness and an identical-crash
#               witness through a wrapper binary (each must FAIL, attributed),
#               and run a clean boundary control (must stay OK). Uses the
#               overrides below; they exist for that and for nothing else.
# Overrides (selftest plumbing; resolved per call, mechanical-gates §66):
#   REPLAY_DIFF_CORPUS=DIR   programs to scan (default: tests/)
#   REPLAY_DIFF_EIG=PATH     binary under test (default: src/eigenscript)
#   REPLAY_DIFF_BASE=FILE    ledger (default: tests/replay_diff_expected.txt)
#   REPLAY_DIFF_FLOOR=N      vacuity floor on the program count (default 100)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SELF="$ROOT/tools/$(basename "$0")"; cd "$ROOT/src" || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# The bound is optional: macOS runners ship no coreutils `timeout`, and a
# suite section runs --selftest there (tests/run_all_tests.sh probes the same
# way). Unbounded is a hang, not a wrong verdict.
TMO=""
if command -v timeout >/dev/null 2>&1; then TMO="timeout 180"
elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout 180"; fi

corpus_dir() { printf '%s' "${REPLAY_DIFF_CORPUS:-$ROOT/tests}"; }
eig_bin()    { printf '%s' "${REPLAY_DIFF_EIG:-./eigenscript}"; }
norm() { sed -E 's/0x[0-9a-f]+/0xADDR/g' "$1"; }
# stdin is pinned to /dev/null: test_terminal's raw_key reads it, and with the
# harness's inherited stdin the record arm hung (rc 124) while the replay arm
# exited 3 -- a phantom row from the environment, not the tape.
run() { local out="$1"; shift; env -u EIGS_JIT_OSR_THRESHOLD EIGS_JIT_OFF=1 "$@" $TMO "$(eig_bin)" "$(corpus_dir)/$b" > "$out" 2>&1 </dev/null; echo "rc=$?" >> "$out"; }
# crash_check ARM FILE: a signal exit is named AND counted; the count is the
# first verdict below. rc is the last line the arm wrote (`rc=N`).
crash=0; prog_crash=0
crash_check() { local r; r=$(tail -1 "$2" | sed 's/rc=//'); case "$r" in ''|*[!0-9]*) return;; esac; [ "$r" -ge 128 ] && { echo "  CRASH $b $1 arm rc=$r"; crash=$((crash + 1)); prog_crash=1; }; }

# ---------------------------------------------------------------- selftest
if [ "${1:-}" = "--selftest" ]; then
    REAL="$ROOT/src/eigenscript"
    [ -x "$REAL" ] || { echo "replay_diff selftest: no binary at $REAL"; exit 1; }
    ST_RC=0
    # The wrapper is the "binary": it forwards to the real one, except for two
    # planted programs. test_boundary_crash: the REPLAY arm prints the real
    # diagnostic text and dies by SIGSEGV (the #1112 shape). test_both_crash:
    # both arms print the same line and die by SIGSEGV (identical output -- the
    # diff cannot see it). Everything else is the real runtime, so the clean
    # boundary control is a genuine replay refusal, not a printed string.
    cat > "$T/eig" <<W
#!/usr/bin/env bash
case "\$1" in
  *test_boundary_crash.eigs) if [ -n "\${EIGS_REPLAY:-}" ]; then echo "Error line 1: recv: not replayable under EIGS_REPLAY (subprocess/concurrency boundary; see docs/TRACE.md)" >&2; kill -SEGV \$\$; fi ;;
  *test_both_crash.eigs) echo same; kill -SEGV \$\$ ;;
  *test_near_crash.eigs) if [ -n "\${EIGS_REPLAY:-}" ]; then echo replay; else echo record; fi; exit 124 ;;
esac
exec "$REAL" "\$@"
W
    chmod +x "$T/eig"
    mk_corpus() {   # mk_corpus DIR members...  (det is always present: the self-check needs one)
        local d="$1"; shift; rm -rf "$d"; mkdir -p "$d"
        printf 'print of 1\n' > "$d/test_a_det.eigs"
        for m in "$@"; do case "$m" in
            clean) printf 'ch is channel of 1\nr is try_recv of ch\nprint of "done"\n' > "$d/test_boundary_clean.eigs" ;;
            bcrash) printf 'print of 1\n' > "$d/test_boundary_crash.eigs" ;;
            both)  printf 'print of 1\n' > "$d/test_both_crash.eigs" ;;
            near)  printf 'print of 1\n' > "$d/test_near_crash.eigs" ;;
        esac; done
    }
    # st_case NAME WANT_RC FLOOR ARGS -- WANT_SUBSTR...   (WANT_SUBSTR must ALL appear)
    st_case() {
        local name="$1" want_rc="$2" floor="$3"; shift 3
        local args=""; if [ "$1" != "--" ]; then args="$1"; shift; fi; shift
        : > "$T/ledger"
        local out rc
        out=$(env REPLAY_DIFF_CORPUS="$T/corpus" REPLAY_DIFF_EIG="$T/eig" REPLAY_DIFF_BASE="$T/ledger" ${floor:+REPLAY_DIFF_FLOOR=$floor} bash "$SELF" $args 2>&1); rc=$?
        if [ "$rc" -ne "$want_rc" ]; then
            echo "SELFTEST FAIL: '$name' exited $rc, want $want_rc:" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; ST_RC=1; return
        fi
        # Attribution (mechanical-gates §19): the verdict must be THIS case's,
        # named by text only the intended path emits -- never a bare filename.
        for want in "$@"; do
            if ! printf '%s\n' "$out" | grep -qF -- "$want"; then
                echo "SELFTEST FAIL: '$name' exited $rc for the wrong reason; wanted '$want', got:" >&2
                printf '%s\n' "$out" | sed 's/^/    /' >&2; ST_RC=1; return
            fi
        done
        echo "  selftest ok: $name"
    }
    # 1. The #1112 witness: diagnostic printed, then a signal -- must FAIL and
    #    name the crash; the clean control in the same corpus is still
    #    counted as a boundary (the crash is not what got it counted).
    mk_corpus "$T/corpus" clean bcrash
    st_case "planted boundary-plus-crash fails, attributed" 1 3 -- \
        "CRASH test_boundary_crash.eigs rep arm rc=139" \
        "replay_diff: FAIL: 1 signal exit(s)" "1 at the documented boundary"
    # 2. A crash both arms AGREE on (identical output) -- invisible to the
    #    diff, must still FAIL, both arms named.
    mk_corpus "$T/corpus" both
    st_case "identical crash in both arms fails" 1 2 -- \
        "CRASH test_both_crash.eigs rec arm rc=139" "CRASH test_both_crash.eigs rep arm rc=139" \
        "replay_diff: FAIL: 2 signal exit(s)"
    # 3. --record must not bake a crash into a ledger.
    mk_corpus "$T/corpus" clean bcrash
    st_case "--record refuses over a crash" 1 3 "--record" \
        "replay_diff: FAIL: 1 signal exit(s)"
    [ -s "$T/ledger" ] && { echo "SELFTEST FAIL: --record wrote a ledger over a crash" >&2; ST_RC=1; }
    # 4. Positive control (both halves, §15): the clean boundary -- a real
    #    replay refusal from the real runtime, rc 1, no signal -- stays OK
    #    and is counted as a boundary. The exact program count also proves
    #    the corpus override took (the real corpus would say 100+).
    mk_corpus "$T/corpus" clean
    st_case "clean boundary control stays OK, counted" 0 2 -- \
        "replay_diff: OK (2 programs record+replay; 1 at the documented boundary; 0 nondeterministic; 0 ledgered)"
    # 5. rc 120-127 is NOT a signal. A divergence there must still become a
    #    row: the first version of this gate skipped on a glob over the rc
    #    text (`rc=1[2-9][0-9]`), which also swallowed 124 (timeout) and 127
    #    (no such command) -- a loud row turned into no row at all.
    mk_corpus "$T/corpus" near
    st_case "non-signal nonzero rc (124) still diffs into a row" 1 2 -- \
        "replay_diff: LEDGER CHANGED" "> test_near_crash.eigs"
    # 6. The vacuity floor is not disabled by the plumbing: with no floor
    #    override the tiny corpus is refused by name.
    st_case "vacuity floor still fires at the default" 1 "" -- \
        "the scan is vacuous"
    [ "$ST_RC" -eq 0 ] && echo "SELFTEST: all planted faults caught"
    exit "$ST_RC"
fi

# ---------------------------------------------------------------- the gate
EIG="$(eig_bin)"; CORPUS="$(corpus_dir)"; BASE="${REPLAY_DIFF_BASE:-$ROOT/tests/replay_diff_expected.txt}"
FLOOR="${REPLAY_DIFF_FLOOR:-100}"
got="$T/got"; : > "$got"; n=0; boundary=0; nondet=0
# self-check on a known-deterministic program
b=test_math_underflow.eigs
[ -f "$CORPUS/$b" ] || b=$(ls "$CORPUS"/test_*.eigs | head -1 | xargs basename)
rm -f "$T/tape0"; run "$T/r0" EIGS_TRACE="$T/tape0"
[ -s "$T/tape0" ] || { echo "replay_diff: FAIL: the record arm wrote no tape for $b -- check EIGS_TRACE"; exit 1; }
run "$T/p0" EIGS_REPLAY="$T/tape0"
crash_check rec "$T/r0"; crash_check rep "$T/p0"
[ "$crash" -eq 0 ] || { echo "replay_diff: FAIL: the self-check program $b died by signal"; exit 1; }
diff -q <(norm "$T/r0") <(norm "$T/p0") >/dev/null || { echo "replay_diff: FAIL: the self-check program $b does not replay its own tape"; diff <(norm "$T/r0") <(norm "$T/p0") | head -5; exit 1; }
for f in "$CORPUS"/test_*.eigs; do
  b=$(basename "$f"); n=$((n + 1))
  rm -f "$T/tape"
  run "$T/rec" EIGS_TRACE="$T/tape"
  run "$T/rep" EIGS_REPLAY="$T/tape"
  # #1112: a signal exit is the first verdict -- named, counted, and never a
  # boundary or a row. A crash that the two arms AGREE on is invisible to the
  # diff, and a replay arm that printed the boundary diagnostic before dying
  # is not "at the boundary"; both used to read as OK.
  prog_crash=0; crash_check rec "$T/rec"; crash_check rep "$T/rep"
  # Skip on the FLAG, not on a glob over the rc text: `rc=1[2-9][0-9]`
  # also matches 120-127, which are not signals -- rc 124 (timeout) and
  # 127 (no such command) would have been silently skipped instead of
  # diffed, turning a loud row into no row at all.
  [ "$prog_crash" -eq 0 ] || continue
  diff -q <(norm "$T/rec") <(norm "$T/rep") >/dev/null && continue
  if grep -q "not replayable under EIGS_REPLAY" "$T/rep"; then boundary=$((boundary + 1)); continue; fi
  # Adjudicate (jit_diff's step 1): a program whose record arm is not even
  # deterministic against itself is NONDET -- counted, reported, not a row.
  rm -f "$T/tape2"; run "$T/rec2" EIGS_TRACE="$T/tape2"; run "$T/rep2" EIGS_REPLAY="$T/tape2"
  if ! diff -q <(norm "$T/rec") <(norm "$T/rec2") >/dev/null; then nondet=$((nondet + 1)); echo "  NONDET $b (record arm differs from itself)"; continue; fi
  if diff -q <(norm "$T/rec2") <(norm "$T/rep2") >/dev/null; then nondet=$((nondet + 1)); echo "  NONDET $b (replay diverged once, then matched)"; continue; fi
  echo "$b" >> "$got"
done
sort -o "$got" "$got"
[ "$n" -ge "$FLOOR" ] || { echo "replay_diff: only $n programs found -- the scan is vacuous (floor $FLOOR)"; exit 1; }
if [ "$crash" -gt 0 ]; then
  echo "replay_diff: FAIL: $crash signal exit(s) -- a crash is never a boundary, whatever the arm printed (#1112); $n programs, $boundary at the documented boundary, $nondet nondeterministic"
  exit 1
fi
if [ "${1:-}" = "--record" ]; then cp "$got" "$BASE"; echo "replay_diff: baseline recorded ($(wc -l < "$BASE") rows, $n programs, $boundary at the documented boundary, $nondet nondeterministic)"; exit 0; fi
[ -f "$BASE" ] || { echo "replay_diff: no baseline at $BASE (run with --record)"; cat "$got"; exit 1; }
if diff <(sort "$BASE") "$got" > "$T/d"; then
  echo "replay_diff: OK ($n programs record+replay; $boundary at the documented boundary; $nondet nondeterministic; $(wc -l < "$BASE") ledgered)"; exit 0
fi
echo "replay_diff: LEDGER CHANGED ($n programs examined)"
echo "  '<' = ledgered and now identical (improvement -- remove it)"
echo "  '>' = newly diverging on replay (REGRESSION)"
cat "$T/d"; exit 1
