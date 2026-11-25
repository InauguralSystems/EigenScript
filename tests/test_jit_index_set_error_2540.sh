#!/usr/bin/env bash
set -u
EIGS=${EIGS:-"$(cd "$(dirname "$0")/../src" && pwd)/eigenscript"}
tmp=$(mktemp "${TMPDIR:-/tmp}/eigs-2540.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
run_case() {
  name=$1; body=$2
  printf '%s\n' "$body" > "$tmp"
  on=$("$EIGS" "$tmp" 2>&1); on_rc=$?
  off=$(EIGS_JIT_OFF=1 "$EIGS" "$tmp" 2>&1); off_rc=$?
  if [ "$on_rc" -eq "$off_rc" ] && [ "$on" = "$off" ]; then
    printf '  PASS: %s JIT/interpreter error and effects agree\n' "$name"
  else
    printf '  FAIL: %s differs (JIT rc=%s <%s>; interpreter rc=%s <%s>)\n' "$name" "$on_rc" "$on" "$off_rc" "$off"
    return 1
  fi
}
common='define put(b, x, y) as:
    b[0.0] is x
    b[1.0] is y
    return 0
b is buf_from_list of ([5.0, 6.0])
for k in range of 400:
    put of [b, 7.5, 8.5]'
status=0
run_case 'hot function wrong value' "$common
try:
    put of [b, \"s\", 99.0]
catch e:
    print of [e.kind, e.message, e.line]
print of [b[0], b[1]]" || status=1
run_case 'hot function out of range' 'define put(b, i, x, y) as:
    b[i + 0.0] is x
    b[1.0] is y
    return 0
b is buf_from_list of ([5.0, 6.0])
for k in range of 400:
    put of [b, 0.0, 7.5, 8.5]
try:
    put of [b, 8.0, 7.5, 99.0]
catch e:
    print of [e.kind, e.message, e.line]
print of [b[0], b[1]]' || status=1
run_case 'hot function non-finite at int index' 'define put(b, x, y) as:
    b[0] is x
    b[1] is y
    return 0
b is buf_from_list of ([5.0, 6.0])
for k in range of 400:
    put of [b, 7.5, 8.5]
try:
    put of [b, 1.0 / 0.0, 99.0]
catch e:
    print of [e.kind, e.message, e.line]
print of [b[0], b[1]]' || status=1
run_case 'finite control' "$common
put of [b, 2.5, 3.5]
print of [b[0], b[1]]" || status=1
run_case 'forced OSR wrong value' 'b is buf_from_list of ([5.0, 6.0])
try:
    for k in range of 4:
        b[0.0] is if k < 3 then 7.5 else "s"
        b[1.0] is 99.0
catch e:
    print of [e.kind, e.message, e.line]
print of [b[0], b[1]]' || status=1
exit "$status"
