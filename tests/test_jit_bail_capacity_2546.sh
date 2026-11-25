#!/usr/bin/env bash
set -u
EIGS=${EIGS:-"$(cd "$(dirname "$0")/../src" && pwd)/eigenscript"}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
status=0
# Product assertion: the only count-incrementing table writes are inside the
# two accessors. This intentionally examines source, not generated evidence.
direct=$(awk '
  /static inline uint8_t \*\*jit_bail_slot/ {in_b=1}
  /static inline JitPendingPatch \*jit_pending_slot/ {in_p=1; in_b=0}
  in_b && /^}/ {in_b=0}
  in_p && /^}/ {in_p=0}
  !in_b && !in_p && /(bail_patches\[[^]]*(bail_count|bail_table.count)|pending\[[^]]*(pending_count|pending_table.count))/ {print NR ":" $0}
' "$ROOT/src/jit.c")
if [ -z "$direct" ]; then
  echo 'PASS: zero direct reservation-table writes outside slot accessors'
else
  echo "FAIL: direct reservation-table writes: $direct"; status=1
fi
reservations=$(awk '/jit_reserve\(&/ && !/static inline/ {n++} END {print n+0}' "$ROOT/src/jit.c")
if [ "$reservations" -eq 22 ]; then
  echo 'PASS: examined=22 table reservation sites derived from src/jit.c'
else
  echo "FAIL: expected 22 derived table reservation sites, examined=$reservations"; status=1
fi
# Literal result in both lanes; STOPS proves the hot function was considered
# by the JIT without folding the expected value into this test.
tmp=$(mktemp "${TMPDIR:-/tmp}/eigs-2546.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<'EIGS'
answer is 41.0
define hot(x) as:
    return answer + x
v is 0.0
for k in range of 400:
    v is hot of 1.0
print of v
EIGS
on=$(EIGS_JIT_STOPS=1 EIGS_JIT_HOT=1 "$EIGS" "$tmp" 2>&1); on_rc=$?
off=$(EIGS_JIT_OFF=1 "$EIGS" "$tmp" 2>&1); off_rc=$?
if [ "$on_rc" -eq 0 ] && [ "$off_rc" -eq 0 ] &&
   printf '%s\n' "$on" | grep -qxF '42.0' && [ "$off" = '42.0' ]; then
  echo 'PASS: GET_NAME hot literal is 42.0 with JIT on and off'
else
  echo "FAIL: GET_NAME hot literal (on rc=$on_rc <$on>; off rc=$off_rc <$off>)"; status=1
fi
exit "$status"
