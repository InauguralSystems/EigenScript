#!/bin/bash
# #865/#1417: sticky flags require one independently compiled program per row.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"
TMP=$(mktemp /tmp/eigs_numeric_flags_XXXXXX.eigs)
trap 'rm -f "$TMP"' EXIT
pass=0; fail=0
run() {
    name="$1"; prog="$2"; printf '%s\n' "$prog" > "$TMP"
    out=$(EIGS_STRICT=0 "$EIGS" "$TMP" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then echo "  PASS: $name"; pass=$((pass+1));
    else echo "  FAIL: $name (rc=$rc: $out)"; fail=$((fail+1)); fi
}
run "NG20-NG21 initial/ordinary flags clean" 'x is (2.5 * 4.0) + (1.0 / 8.0)
assert of [not ((math_flags of null).overflow or (math_flags of null).invalid), "ordinary clean"]'
run "NG22 saturation and NG25 stickiness" 'x is 1e200 * 1e200
assert of [(math_flags of null).overflow, "saturation sets overflow"]
y is 1 + 2
assert of [(math_flags of null).overflow, "overflow sticky"]'
run "NG23 reassociation overflow" 'x is (1e200 * 1e200) / 1e200
assert of [(math_flags of null).overflow, "reassociation sets overflow"]'
run "NG24 other association clean" 'x is 1e200 * (1e200 / 1e200)
assert of [not (math_flags of null).overflow, "other order clean"]'
run "NG30 num nan" 'x is num of "nan"
assert of [x == 0 and (math_flags of null).invalid, "num nan invalid"]'
run "NG30 num inf" 'x is num of "inf"
assert of [(math_flags of null).overflow, "num inf overflow"]'
run "NG30 num abc" 'x is num of "abc"
assert of [x == 0 and not (math_flags of null).invalid, "junk clean"]'
run "NG30 num 42" 'x is num of "42"
assert of [x == 42 and not ((math_flags of null).invalid or (math_flags of null).overflow), "42 clean"]'
run "NG27 log controls/zero" 'a is log of 1e-15
b is log of 1e-10
assert of [not (math_flags of null).invalid, "positive logs clean"]
c is log of 0
assert of [(math_flags of null).invalid, "log zero invalid"]'
run "NG28 sqrt control/negative" 'a is sqrt of 4
assert of [not (math_flags of null).invalid, "sqrt control clean"]
b is sqrt of -1
assert of [(math_flags of null).invalid, "sqrt negative invalid"]'
run "NG29 asin control/out-of-range" 'a is asin of 0.5
assert of [not (math_flags of null).invalid, "asin control clean"]
b is asin of 5
assert of [(math_flags of null).invalid, "asin five invalid"]'
run "NG29 acos control/out-of-range" 'a is acos of 0.5
assert of [not (math_flags of null).invalid, "acos control clean"]
b is acos of -9
assert of [(math_flags of null).invalid, "acos -9 invalid"]'
nan_setup='left is buffer of [1, 2]
left[0] is 1e200
left[1] is 1e200
right is buffer of [2, 1]
right[0] is 1e200
right[1] is 0 - 1e200
raw is matmul of [left, right]'
for spec in \
 'NG32 index|x is raw[0]' \
 'NG33 buf_get|x is buf_get of [raw, 0]' \
 'NG34 get_at|x is get_at of [raw, 0]' \
 'NG35 gather|x is (gather of [raw, [0]])[0]' \
 'NG38 equality|x is raw == raw' \
 'NG42 buf_peak|x is buf_peak of [raw, 0, 1]' \
 'NG50 nested sum|x is sum of ([raw])' \
 'NG50 nested mean|x is mean of ([raw])' \
 'NG50 nested norm|x is norm of ([raw])' \
 'NG52 scatter index|dst is buffer of 1; scatter_add of [dst, raw, 5]' \
 'NG53 gather index|dst is buffer of [1, 1]; x is gather of [dst, raw]' \
 'NG55 str_from_bytes|x is str_from_bytes of raw' \
 'NG56 f64_from_bytes|x is f64_from_bytes of raw' \
 'NG58 PCM encode|x is buf_to_pcm16le of [raw, 0, 1]'; do
 name=${spec%%|*}; op=${spec#*|}; op=$(printf '%s' "$op" | sed 's/; */\n/g')
 run "$name invalid" "$nan_setup
$op
assert of [(math_flags of null).invalid, \"NaN read sets invalid\"]"
done
inf_setup='a is buffer of [1, 2]
a[0] is 1e200
a[1] is 1e200
b is buffer of [2, 2]
b[0] is 1e200
b[1] is 0 - 1e200
b[2] is 1e200
b[3] is 0 - 1e200
raw is matmul of [a, b]'
run "NG57 byte decoder overflow" "$inf_setup
x is str_from_bytes of raw
assert of [(math_flags of null).overflow, \"infinity byte read sets overflow\"]"
run "NG59 PCM decoder overflow" "$inf_setup
x is buf_to_pcm16le of [raw, 0, 2]
assert of [(math_flags of null).overflow, \"infinity PCM read sets overflow\"]"
echo "NUMERIC_FLAGS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
