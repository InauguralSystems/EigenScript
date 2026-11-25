#!/usr/bin/env bash
set -u
EIGS=${EIGS:-"$(cd "$(dirname "$0")/../src" && pwd)/eigenscript"}
tmp=$(mktemp "${TMPDIR:-/tmp}/eigs-2540.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
examined=0
status=0
run_case() {
  name=$1 expected=$2 body=$3
  examined=$((examined + 1))
  printf '%s\n' "$body" > "$tmp"
  on=$(EIGS_JIT_OSR_THRESHOLD=1 "$EIGS" "$tmp" 2>&1); on_rc=$?
  off=$(EIGS_JIT_OFF=1 EIGS_JIT_OSR_THRESHOLD=1 "$EIGS" "$tmp" 2>&1); off_rc=$?
  if [ "$on_rc" -eq 0 ] && [ "$off_rc" -eq 0 ] && [ "$on" = "$expected" ] && [ "$off" = "$expected" ]; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s expected rc=0 <%s>; JIT rc=%s <%s>; off rc=%s <%s>\n' "$name" "$expected" "$on_rc" "$on" "$off_rc" "$off"
    status=1
  fi
}
run_case 'hot local dot set stops before store' '["type_mismatch", "cannot set field '\''x'\'' on num", 2]
8.5' 'define f(d, b, y) as:
    d.x is y
    b[1.0] is y
    return 0.0
b is buf_from_list of ([5.0, 6.0])
d is {"x": 1.0}
for k in range of 400:
    f of [d, b, 8.5]
try:
    f of [3.0, b, 99.0]
catch e:
    print of [e.kind, e.message, e.line]
print of b[1]'
run_case 'hot dot get stops before store' '["type_mismatch", "cannot access field '\''x'\'' on num", 2]
8.5' 'define f(d, b, y) as:
    b[1.0] is d.x.x
    b[1.0] is y
    return 0.0
b is buf_from_list of ([5.0, 6.0])
d is {"x": {"x": 1.0}}
for k in range of 400:
    f of [d, b, 8.5]
try:
    f of [{"x": 3.0}, b, 99.0]
catch e:
    print of [e.kind, e.message, e.line]
print of b[1]'
run_case 'hot indexed local dot get stops before store' '["type_mismatch", "cannot access field '\''x'\'' on num", 2]
8.5' 'define f(l, i, b, y) as:
    z is l[i].x
    b[1.0] is y
    return 0.0
b is buf_from_list of ([5.0, 6.0])
d is {"x": 1.0}
for k in range of 400:
    f of [[d], 0.0, b, 8.5]
try:
    f of [[3.0], 0.0, b, 99.0]
catch e:
    print of [e.kind, e.message, e.line]
print of b[1]'
run_case 'OSR local dot set stops before print' '["type_mismatch", "cannot set field '\''x'\'' on num", 8]
3.0' 'define f() as:
    d is {"x": 1.0}
    k is 0.0
    try:
        loop while k < 4.0:
            if k == 3.0:
                d is 3.0
            d.x is 7.0
            if k == 3.0:
                print of "BAD"
            k is k + 1.0
    catch e:
        print of [e.kind, e.message, e.line]
    return k
print of f of []'
run_case 'OSR dot get stops before append' '["type_mismatch", "cannot access field '\''x'\'' on num", 9]
3' 'define f() as:
    d is {"x": {"x": 1.0}}
    out is []
    k is 0.0
    try:
        loop while k < 4.0:
            if k == 3.0:
                d is {"x": 3.0}
            z is d.x.x
            append of [out, 9.0]
            k is k + 1.0
    catch e:
        print of [e.kind, e.message, e.line]
    return len of out
print of f of []'
run_case 'finite controls' '3.5
3.5' 'define f(d, b, y) as:
    d.x is y
    b[1.0] is y
b is buf_from_list of ([5.0, 6.0])
d is {"x": 1.0}
for k in range of 400:
    f of [d, b, 8.5]
f of [d, b, 3.5]
print of b[1]
print of d.x'
printf 'examined=%s\n' "$examined"
[ "$examined" -eq 6 ] || status=1
exit "$status"
