#!/usr/bin/env bash
set -u
EIGS=${EIGS:-"$(cd "$(dirname "$0")/../src" && pwd)/eigenscript"}
tmp=$(mktemp "${TMPDIR:-/tmp}/eigs-2540.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
examined=0
status=0
run_case() {
  name=$1 expected=$2 body=$3 tier=$4
  examined=$((examined + 1))
  printf '%s\n' "$body" > "$tmp"
  if [ "$tier" = loop ]; then
    on=$(EIGS_JIT_OSR_THRESHOLD=1 "$EIGS" "$tmp" 2>&1); on_rc=$?
    off=$(EIGS_JIT_OFF=1 EIGS_JIT_OSR_THRESHOLD=1 "$EIGS" "$tmp" 2>&1); off_rc=$?
  else
    on=$("$EIGS" "$tmp" 2>&1); on_rc=$?
    off=$(EIGS_JIT_OFF=1 "$EIGS" "$tmp" 2>&1); off_rc=$?
  fi
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
print of b[1]' hot
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
print of b[1]' hot
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
print of b[1]' hot
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
print of f of []' loop
run_case 'OSR dot get raises with its kind and line' '["type_mismatch", "cannot access field '\''x'\'' on num", 9]
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
print of f of []' loop
run_case 'hot index set wrong value stops before global assignment' '["type_mismatch", 2]
8.5' 'define f(b, v, y) as:
    b[1.0] is v
    changed is y
    return 0.0
changed is 8.5
b is buf_from_list of ([5.0, 6.0])
for k in range of 400:
    f of [b, 8.5, 8.5]
try:
    f of [b, "bad", 99.0]
catch e:
    print of [e.kind, e.line]
print of changed' hot
run_case 'OSR index set out of range stops before print' '["index_range", 9]
3.0' 'define f() as:
    b is buf_from_list of ([5.0, 6.0])
    k is 0.0
    try:
        loop while k < 4.0:
            i is 1.0
            if k == 3.0:
                i is 9.0
            b[i] is k
            if k == 3.0:
                print of "BAD"
            k is k + 1.0
    catch e:
        print of [e.kind, e.line]
    return k
print of f of []' loop
run_case 'hot get name stops before append' '["undefined_name", 3]
400' 'define f(c) as:
    if c > 0.0:
        z is nosuchname
    append of [out, "BAD"]
    return 0.0
out is []
for k in range of 400:
    f of 0.0
try:
    f of 1.0
catch e:
    print of [e.kind, e.line]
print of len of out' hot
run_case 'OSR get name raises with its kind and line' '["undefined_name", 7]
8.5' 'define f() as:
    b is buf_from_list of ([5.0, 8.5])
    k is 0.0
    try:
        loop while k < 4.0:
            if k == 3.0:
                z is nosuchname
            b[1.0] is 8.5
            k is k + 1.0
    catch e:
        print of [e.kind, e.line]
    print of b[1]
f of []' loop
run_case 'hot dot set stops before buffer store' '["type_mismatch", 3]
8.5' 'g is {"x": 1.0}
define f(v, b, y) as:
    g.x is v
    b[1.0] is y
    return 0.0
b is buf_from_list of ([5.0, 8.5])
for k in range of 400:
    f of [2.0, b, 8.5]
g is 3.0
try:
    f of [4.0, b, 99.0]
catch e:
    print of [e.kind, e.line]
print of b[1]' hot
run_case 'OSR dot set stops before append' '["type_mismatch", 9]
3' 'g is {"x": 1.0}
define f() as:
    out is []
    k is 0.0
    try:
        loop while k < 4.0:
            if k == 3.0:
                g is 3.0
            g.x is 7.0
            append of [out, 9.0]
            k is k + 1.0
    catch e:
        print of [e.kind, e.line]
    return len of out
print of f of []' loop
run_case 'OSR index set wrong value raises in the last iteration' '["type_mismatch", 7]
3.0' 'define f(b) as:
    k is 0.0
    loop while k < 4.0:
        v is 8.5
        if k == 3.0:
            v is "bad"
        b[1.0] is v
        k is k + 1.0
    return k
b is buf_from_list of ([5.0, 6.0])
try:
    print of f of b
catch e:
    print of [e.kind, e.line]
print of 3.0' loop
run_case 'OSR local dot set raised stops before append' '["type_mismatch", 6]
3' 'define f(d, out) as:
    k is 0.0
    loop while k < 4.0:
        if k == 3.0:
            d is 3.0
        d.x is 7.0
        append of [out, 9.0]
        k is k + 1.0
out is []
try:
    f of [{"x": 1.0}, out]
catch e:
    print of [e.kind, e.line]
print of len of out' loop
run_case 'OSR get name raised stops before global assignment' '["undefined_name", 6]
2.0' 'changed is 3.0
define f() as:
    k is 0.0
    loop while k < 4.0:
        if k == 3.0:
            z is nosuchname
        changed is k
        k is k + 1.0
try:
    f of []
catch e:
    print of [e.kind, e.line]
print of changed' loop
run_case 'OSR dot get raised stops before append' '["type_mismatch", 7]
3' 'g is {"x": {"x": 1.0}}
define f(out) as:
    k is 0.0
    loop while k < 4.0:
        if k == 3.0:
            g.x is 3.0
        z is g.x.x
        append of [out, 99.0]
        k is k + 1.0
out is []
try:
    f of out
catch e:
    print of [e.kind, e.line]
print of len of out' loop
run_case 'OSR index set wrong value stops before buffer store' '["type_mismatch", "cannot store str in a buffer (buffers hold numbers)", 4]
1.0' 'define f(b, xs, n) as:
    k is 0.0
    loop while k < n:
        b[0.0] is xs[k]
        b[1.0] is k
        k is k + 1.0
    return 0
b is buf_from_list of ([5.0, 6.0])
try:
    f of [b, [7.5, 7.5, "s"], 3.0]
catch e:
    print of [e.kind, e.message, e.line]
print of b[1]' loop
run_case 'hot throw stops before buffer store' 'boom
8.5' 'define f(c, b, y) as:
    if c > 0.0:
        throw of "boom"
    b[1.0] is y
    return 0.0
b is buf_from_list of ([5.0, 6.0])
for k in range of 400:
    f of [0.0, b, 8.5]
try:
    f of [1.0, b, 99.0]
catch e:
    print of e
print of b[1]' hot
run_case 'hot raising builtin stops before append' '["type_mismatch", "sqrt/exp/log/negative: expected a number, a list or a buffer", 2]
400' 'define f(x, out) as:
    z is sqrt of x
    append of [out, 9.0]
    return 0.0
out is []
for k in range of 400:
    f of [4.0, out]
try:
    f of ["s", out]
catch e:
    print of [e.kind, e.message, e.line]
print of len of out' hot
run_case 'OSR raising builtin stops before buffer store' '["type_mismatch", "sqrt/exp/log/negative: expected a number, a list or a buffer", 4]
1.0' 'define f(b, xs, n) as:
    k is 0.0
    loop while k < n:
        z is sqrt of xs[k]
        b[1.0] is k
        k is k + 1.0
    return 0
b is buf_from_list of ([5.0, 6.0])
try:
    f of [b, [1.0, 1.0, "s"], 3.0]
catch e:
    print of [e.kind, e.message, e.line]
print of b[1]' loop
many=$(for k in $(seq 300); do printf '    b[1.0] is %s.0\n' "$k"; done)
run_case 'three hundred indexed stores in one function' '3.0
300.0' "define f(b) as:
    local i is 0.0
    local s is 0.0
    loop while i < 3.0:
        if i > 5.0:
            s is s + 100.0
        s is s + 1.0
        i is i + 1.0
$many
    return s
b is buf_from_list of ([5.0, 6.0])
for k in range of 400:
    f of b
print of f of b
print of b[1]" hot
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
print of d.x' hot
printf 'examined=%s\n' "$examined"
[ "$examined" -eq 21 ] || status=1
exit "$status"
