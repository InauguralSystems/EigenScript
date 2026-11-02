#!/bin/bash
# #2306: a row that decides on a program's exit code must not pass a sanitizer
# report. The plant is a fake-sanitizer wrapper standing in for src/eigenscript.
# It runs the REAL binary, then prints a sanitizer report after the program's
# own output and exits the way the sanitizer would. That puts the report where
# a teardown-time defect puts it: after the expected marker or diagnostic.
#   ubsan  UBSan's recoverable "runtime error:" line; the program's exit code
#          is kept, so only the classifier can reject the row
#   leak   a leak-only LeakSanitizer report; exit 23
#
# The section code is the REAL runner's, run in a mirror tree whose
# src/eigenscript is the wrapper. tools/section_plan.sh emits the plan runner
# for the sections #2306 changed, once. [9/15] and [16/16] have '/' in their
# labels, which the planner refuses, so their chunks (header to the next
# header) are cut out of run_all_tests.sh verbatim and run in a harness that
# defines the runner's own check/rc_ok/rc_expect (also cut out verbatim).
#  - leak:  the control. A leak-only report is tolerated through the ledger,
#           so every row passes EXCEPT the strict ones (check_task_exit, [87],
#           [90]),
#           which must fail; any other failure means the mirror is broken.
#           The number of passing rows is pinned. Each expected-exit section
#           must record its leak, and the reviewed-baseline gate refuses it.
#  - ubsan: every row that passed the control fails, except rows named, each
#           with a reason, in the reviewed allowlist
#           tests/san_report_sweep_2306.allow. An entry that no longer passes
#           is stale and fails the sweep.
set -u
case "${1:-}" in
    --selftest) ;;
    *) echo "usage: $0 --selftest   (a tools/selftests.txt row)" >&2; exit 2 ;;
esac
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
REAL="$ROOT/src/eigenscript"
ALLOW="$TESTS_DIR/san_report_sweep_2306.allow"
SECTIONS='0g 103b 104 105b 114 114b 115 120 87 90 99f 99h 99j'
# The sections whose rows this sweep judges: the ones #2306 changed. The
# planner also selects a chunk-mate ([115b]); it runs but is not judged here.
JUDGED='[0g] [9/15] [16/16] [114] [114b] [120] [103b] [104] [105b] [87] [90] [115] [99f] [99h] [99j]'
# Exact count of rows in JUDGED that pass the leak control. Update this pin in
# the same change when a judged section gains or loses a row.
WANT_CONTROL_ROWS=84

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -x "$REAL" ] || { echo "FAIL: no binary at $REAL"; exit 1; }
[ -f "$ALLOW" ] || { echo "FAIL: allowlist $ALLOW missing"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/eigs_san2306.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# ---- the plant --------------------------------------------------------------
# Mirror tree: every top-level entry is a symlink to the real one, except
# src/, whose entries are symlinks except eigenscript, the wrapper. The real
# binary still runs from $ROOT/src, so its /proc/self/exe stdlib lookup holds.
M="$tmp/root"
mkdir -p "$M/src"
for e in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$e" ] || continue
    [ "$(basename "$e")" = src ] && continue
    ln -s "$e" "$M/$(basename "$e")"
done
for e in "$ROOT"/src/*; do
    [ "$(basename "$e")" = eigenscript ] && continue
    ln -s "$e" "$M/src/$(basename "$e")"
done
cat > "$M/src/eigenscript" <<'WRAP'
#!/bin/bash
"$EIGS_PLANT_REAL" "$@"; rc=$?
case "${EIGS_PLANT:-none}" in
  ubsan)
    printf '%s\n' "src/vm.c:123:45: runtime error: signed integer overflow: 9223372036854775807 + 1 cannot be represented in type 'long int'" >&2
    exit "$rc" ;;
  leak)
    printf '%s\n' '' '=================================================================' \
      '==4242==ERROR: LeakSanitizer: detected memory leaks' '' \
      'Direct leak of 16 byte(s) in 1 object(s) allocated from:' \
      '    #0 0x7f00 in malloc' '    #1 0x55d0 in xmalloc src/alloc.c:10' '' \
      'SUMMARY: AddressSanitizer: 16 byte(s) leaked in 1 allocation(s).' >&2
    exit 23 ;;
  *) exit "$rc" ;;
esac
WRAP
chmod +x "$M/src/eigenscript"
export EIGS_PLANT_REAL="$REAL"

PLAN="$tmp/plan.sh"
if ! bash "$M/tools/section_plan.sh" --emit-sections "$SECTIONS" "$PLAN" > "$tmp/plan.out" 2>&1; then
    cat "$tmp/plan.out"; echo "FAIL: could not emit the section plan"; exit 1
fi
# Section headers are the planner's own (a program can print "[jit] ..." too).
HEADERS="$(sed -n 's/^# EIGS-EXPECT	[0-9]*	1	\(\[[^]]*\]\).*/\1/p' "$PLAN" | tr '\n' ' ')[9/15] [16/16]"
miss=""
for s in $JUDGED; do case " $HEADERS " in *" $s "*) ;; *) miss="$miss $s" ;; esac; done
if [ -z "$miss" ]; then
    ok "plan: every judged section is selected ($HEADERS)"
else
    bad "plan: judged section(s) not selected:$miss (selected: $HEADERS)"
fi

# rows LOG — "SECTION|PASS-or-FAIL|row text" for each row of a judged section.
rows() {
    awk -v headers=" $HEADERS " -v judged=" $JUDGED " '
        /^\[[^]]*\] / { h = $0; sub(/\].*/, "]", h); if (index(headers, " " h " ")) sec = h; next }
        /^  (PASS|FAIL): / && index(judged, " " sec " ") {
            v = substr($1, 1, 4); t = $0; sub(/^  (PASS|FAIL): /, "", t); print sec "|" v "|" t }
    ' "$1"
}

# The [9/15] and [16/16] chunks and the helpers they call, verbatim.
RUNNER="$TESTS_DIR/run_all_tests.sh"
chunk() { sed -n "/^echo \"\\[$1\\] /,/^echo \"\\[/p" "$RUNNER" | sed '$d'; }
fn() { sed -n "/^$1() {\$/,/^}\$/p" "$RUNNER"; }
H="$tmp/slash.sh"
{ for f in check rc_ok rc_expect; do fn "$f"; done
  echo 'check_binary_fingerprint() { :; }'
  echo 'EIGS_SUITE_SECTION="[9/15]"'; chunk '9\/15'
  echo 'EIGS_SUITE_SECTION="[16/16]"'; chunk '16\/16'
  echo 'echo "HARNESS: PASS=$PASS FAIL=$FAIL TOTAL=$TOTAL LEAKED=$LEAKED"'; } > "$H"
for f in check rc_ok rc_expect; do
    grep -q "^$f() {\$" "$H" || bad "harness: could not cut $f() out of run_all_tests.sh"
done
for c in '\[9/15\] Assert' '\[16/16\] Error Messages'; do
    grep -q "^echo \"$c" "$H" || bad "harness: could not cut the chunk headed $c out of run_all_tests.sh"
done

nested() {   # nested PLANT LOG — the emitted plan runner, then the harness, in the mirror
    env -u EIGS_SUITE_SHARD -u EIGS_SUITE_CHANGED -u EIGS_SUITE_SECTIONS \
        -u EIGS_SUITE_SECTION -u TOLERATED_LSAN_REPORTS \
        EIGS_PLANT="$1" bash "$PLAN" > "$2" 2>&1
    rc=$?
    : > "$tmp/hledger.$1"
    ( cd "$M/src" && EIGS_PLANT="$1" TOLERATED_LSAN_REPORTS="$tmp/hledger.$1" bash -c '
        . "$1/lsan_classify.sh"; . "$1/failure_output.sh"
        PASS=0; FAIL=0; TOTAL=0; LEAKED=0
        . "$2"' harness "$TESTS_DIR" "$H" ) >> "$2" 2>&1
    return $rc
}

# ---- leak plant: the control, the strict rows, the ledger ---------------------
nested leak "$tmp/leak.log"; rc_leak=$?
rows "$tmp/leak.log" > "$tmp/leak.rows"
grep '|PASS|' "$tmp/leak.rows" | sort -u > "$tmp/ctl.pass"
n_ctl=$(wc -l < "$tmp/ctl.pass")
# Only the strict rows may fail: [104]'s check_task_exit rows, [87] and [90]
# (its summary row and the per-example lines it echoes) refuse any report, and
# [104]'s seeded-scheduling row compares the whole 2>&1 capture byte for byte,
# so any appended report changes it.
other_fail=$(grep '|FAIL|' "$tmp/leak.rows" | grep -vF '[104]|FAIL|task exit contract — ' \
             | grep -vF '[90]|FAIL|' | grep -vF '[87]|FAIL|' | grep -vF '[104]|FAIL|seeded scheduling diverged')
if [ -z "$other_fail" ]; then
    ok "control (leak plant): only the strict rows fail"
else
    bad "control (leak plant): rows other than the strict ones failed — the mirror or the tolerance is broken:"
    printf '%s\n' "$other_fail" | head -10
fi
if [ "$n_ctl" -eq "$WANT_CONTROL_ROWS" ]; then
    ok "control (leak plant): $n_ctl rows pass (pinned)"
else
    bad "control (leak plant): $n_ctl rows pass, pinned $WANT_CONTROL_ROWS"
fi
if [ "$(grep -cF '[104]|FAIL|task exit contract — ' "$tmp/leak.rows")" -eq 6 ] \
   && ! grep -qF '[104]|PASS|task exit contract — ' "$tmp/leak.rows" \
   && grep -qF '[90]|FAIL|' "$tmp/leak.rows" && ! grep -qF '[90]|PASS|' "$tmp/leak.rows" \
   && grep -qF '[87]|FAIL|' "$tmp/leak.rows" && ! grep -qF '[87]|PASS|' "$tmp/leak.rows"; then
    ok "leak plant: the strict rows (6 check_task_exit rows, [87], [90]) fail on a leak-only report"
else
    bad "leak plant: a strict row passed a leak-only report"
    grep -E '^\[(104|87|90)\]\|PASS\|' "$tmp/leak.rows"
fi
if [ "$rc_leak" -ne 0 ] && grep -q 'FAIL: new tolerated LeakSanitizer report' "$tmp/leak.log"; then
    miss=""
    for s in '[0g]' '[103b]' '[105b]' '[114]' '[114b]' '[115]' '[120]' '[99f]' '[99h]' '[99j]'; do
        grep -qF "$s — leak-only nonzero exit" "$tmp/leak.log" || miss="$miss $s"
    done
    # The harness keeps its own ledger; the plan runner's gate never sees it.
    for s in '[9/15]' '[16/16]'; do
        grep -qF "$s — leak-only nonzero exit" "$tmp/hledger.leak" || miss="$miss $s"
    done
    if [ -z "$miss" ]; then
        ok "leak plant: each expected-exit section records its leak, and the reviewed baseline refuses it"
    else
        bad "leak plant: no tolerated-leak record for$miss"
    fi
else
    bad "leak plant: the run stayed green or the baseline gate did not fire (rc=$rc_leak)"
fi

# ---- ubsan plant: every row fails unless allowlisted --------------------------
grep -v '^[[:space:]]*#' "$ALLOW" | grep -v '^[[:space:]]*$' > "$tmp/allow.raw"
cut -d'|' -f1-3 "$tmp/allow.raw" | sort -u > "$tmp/allow"
if awk -F'|' 'NF < 4 || $4 ~ /^[[:space:]]*$/ { bad = 1 } END { exit bad }' "$tmp/allow.raw"; then
    ok "allowlist: every entry names a reason"
else
    bad "allowlist: an entry has no reason (want SECTION|PASS|row|reason)"
fi
not_in_control=$(comm -23 "$tmp/allow" "$tmp/ctl.pass")
if [ -z "$not_in_control" ]; then
    ok "allowlist: every entry is a row the control passes"
else
    bad "allowlist: entries that are not control rows:"; printf '%s\n' "$not_in_control"
fi

nested ubsan "$tmp/ubsan.log"; rc_ubsan=$?
rows "$tmp/ubsan.log" | grep '|PASS|' | sort -u > "$tmp/ubsan.pass"
unallowed=$(comm -23 "$tmp/ubsan.pass" "$tmp/allow")
n_flip=$(comm -23 "$tmp/ctl.pass" "$tmp/ubsan.pass" | wc -l)
if [ "$rc_ubsan" -ne 0 ] && [ -z "$unallowed" ]; then
    ok "ubsan plant: $n_flip of $n_ctl control rows fail; $(wc -l < "$tmp/ubsan.pass") allowlisted rows still pass"
else
    bad "ubsan plant: rows passed a planted sanitizer report (rc=$rc_ubsan):"
    printf '%s\n' "$unallowed"
fi
# [120] is ONE counted row whose display sub-lines print PASS on their own;
# its verdict must fail through the exit-status sub-line.
if grep -qF '[120]|FAIL|exit status/sanitizer' < <(rows "$tmp/ubsan.log"); then
    ok "ubsan plant: [120]'s counted row fails through its exit-status line"
else
    bad "ubsan plant: [120]'s exit-status line did not fail"
fi
stale=$(comm -13 "$tmp/ubsan.pass" "$tmp/allow")
if [ -z "$stale" ]; then
    ok "allowlist: no stale entry (each still passes the plant)"
else
    bad "allowlist: stale entries no longer pass the plant; delete them:"
    printf '%s\n' "$stale"
fi

echo ""
echo "san report sweep: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
