#!/bin/bash
# #354: the parser's fixed caps (16 params, 64 match cases) must fail with
# exactly one diagnostic that NAMES the cap — not a stray-token error cascade.
# Consumers generate EigenScript, so a program past a cap must point at the
# actual limit. At-the-cap programs must still parse clean.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"

fails=0

check() {
    local name="$1" prog="$2" want_rc="$3" want_msg="$4" want_count="$5"
    local f out rc n
    f=$(mktemp /tmp/eigs_caps_XXXXXX.eigs)
    printf '%s\n' "$prog" > "$f"
    out=$("$BIN" "$f" 2>&1); rc=$?
    rm -f "$f"
    if [ "$rc" -ne "$want_rc" ]; then
        echo "  FAIL: $name (rc=$rc, want $want_rc)"; fails=1; return
    fi
    if [ -n "$want_msg" ]; then
        n=$(printf '%s\n' "$out" | grep -c "Parse error")
        if ! printf '%s' "$out" | grep -q "$want_msg"; then
            echo "  FAIL: $name (missing '$want_msg')"; fails=1; return
        fi
        if [ "$n" -ne "$want_count" ]; then
            echo "  FAIL: $name ($n parse errors, want $want_count)"; fails=1; return
        fi
    fi
    echo "  PASS: $name"
}

mk_params() { local n=$1 s="p0"; for i in $(seq 1 $((n-1))); do s="$s, p$i"; done; printf '%s' "$s"; }

mk_match() {
    local n=$1
    printf 'x is 5\nmatch x:\n'
    for i in $(seq 0 $((n-1))); do printf '    case %d:\n        y is %d\n' "$i" "$i"; done
}

# --- params ---
check "17-param define: one error naming the cap" \
    "define f($(mk_params 17)) as:
    return p0
print of (f of [1, 2])" 1 "function exceeds 16 parameters" 1

check "16-param define parses clean" \
    "define f($(mk_params 16)) as:
    return p15
print of (f of [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16])" 0 "" 0

check "17-param lambda: one error naming the cap" \
    "g is ($(mk_params 17)) => p0
print of (g of [1, 2])" 1 "lambda exceeds 16 parameters" 1

# --- match cases ---
check "65-case match: one error naming the cap" \
    "$(mk_match 65)" 1 "match exceeds 64 cases" 1

check "64-case match parses clean" \
    "$(mk_match 64)
print of \"ok\"" 0 "" 0

if [ "$fails" -ne 0 ]; then
    echo "FAIL: parse caps"
    exit 1
fi
echo "PASS: parse caps"
