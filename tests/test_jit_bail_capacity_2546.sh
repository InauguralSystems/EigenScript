#!/usr/bin/env bash
set -u
EIGS=${EIGS:-"$(cd "$(dirname "$0")/../src" && pwd)/eigenscript"}; status=0
D=$(mktemp -d "${TMPDIR:-/tmp}/eigs-2546.XXXXXX") || exit 1; trap 'rm -rf "$D"' EXIT
row=0
# A sanitizer report that did not change the exit code or the output fails the row.
clean() { ! grep -qE 'runtime error:|Sanitizer' "$@"; }
check_row() {
 op=$1 setup=$2 body=$3 literal=$4; row=$((row+1)); s="$D/$row.eigs" e="$D/$row.err" o="$D/$row.out"
 { echo 'padg is 1.0'; printf '%s\n' "$setup"; echo 'define hot(x) as:'; echo '    pad is padg'; printf '%s\n' "$body"|sed 's/^/    /'; echo 'v is 0.0'; echo 'for k in range of 80:'; echo '    v is hot of 2.0'; echo 'print of v'; } >"$s"
 EIGS_DUMP_BC=1 EIGS_JIT_DUMP_PREFIX=hot EIGS_JIT_HOT=1 EIGS_JIT_OSR_THRESHOLD=1 EIGS_JIT_STOPS=1 "$EIGS" "$s" >"$o" 2>"$e"; a=$?
 off=$(EIGS_JIT_OFF=1 "$EIGS" "$s" 2>&1); b=$?
 pre=$(sed -n "s/.*chunk='hot'.*prefix=\([0-9][0-9]*\).*/\1/p" "$e"|head -1)
 pos=$(awk -v w="$op" '/^=== <module>\.fn\[0\]/{f=1;next}/^=== /&&f{f=0} f&&$3==w{sub(/^0+/,"",$1);print($1==""?0:$1);exit}' "$e")
 stop=$(sed -n "s/.*chunk='hot'.*stop_offset=\([0-9][0-9]*\).*/\1/p" "$e"|sort -n|tail -1)
    comp=$(sed -n 's/^compiled:[[:space:]]*\([0-9][0-9]*\)$/\1/p' "$e"|head -1)
 if clean "$e"&&[ "$a" -eq 0 ]&&[ "$b" -eq 0 ]&&[ "$(cat "$o")" = "$literal" ]&&[ "$off" = "$literal" ]&&[ -n "$pre" ]&&[ -n "$pos" ]&&[ -n "$comp" ]&&[ "$comp" -ge 1 ]&& { [ "$pre" -gt "$pos" ] || { [ -n "$stop" ] && [ "$stop" -gt "$pos" ]; }; }; then echo "PASS: $op literal=$literal JIT-on/off examined=$row"; else echo "FAIL: $op literal=$literal rc=$a/$b prefix=${pre:-none} offset=${pos:-none} compiled=${comp:-none}" >&2; sed -n '/=== <module>\.fn\[0\]/,/^=== /p' "$e" >&2; status=1; fi
}
# 30 ops, one hot function each. MOD, the bitwise ops, BNOT and JUMP_IF_TRUE have
# emitter branches that reserve and no row here.
check_row GET_NAME 'g is 40.0' 'return g + x' 42.0
check_row LOCAL_IDX_GET 'g is [40.0]' $'a is g\nreturn a[0.0] + x' 42.0
check_row LOCAL_DOT_GET 'g is {"v": 40.0}' $'a is g\nreturn a.v + x' 42.0
check_row LOCAL_IDX_DOT_GET 'g is [{"v": 40.0}]' $'a is g\nreturn a[0.0].v + x' 42.0
check_row DOT_GET 'g is {"v": 40.0}' 'return g.v + x' 42.0
check_row DOT_SET 'g is {"v": 0.0}' $'g.v is x\nreturn 42.0' 42.0
check_row LOCAL_DOT_SET 'g is {"v": 0.0}' $'a is g\na.v is x\nreturn 42.0 + 0.0' 42.0
while IFS="|" read -r op body lit; do body=$(printf "%b" "$body"); check_row "$op" "" "$body" "$lit"; done <<'ROWS'
ADD|y is 40.0 + x\nreturn y + 0.0|42.0
SUB|y is 44.0 - x\nreturn y + 0.0|42.0
MUL|y is 21.0 * x\nreturn y + 0.0|42.0
DIV|y is 84.0 / x\nreturn y + 0.0|42.0
EQ|y is x == 2.0\nreturn y or false|true
NE|y is x != 3.0\nreturn y or false|true
LT|y is x < 3.0\nreturn y or false|true
GT|y is x > 1.0\nreturn y or false|true
LE|y is x <= 2.0\nreturn y or false|true
GE|y is x >= 2.0\nreturn y or false|true
NEG|y is -x + 44.0\nreturn y + 0.0|42.0
NOT|y is not (x == 3.0)\nreturn y or false|true
ROWS
check_row JUMP '' $'if x == 2.0:\n    y is 42.0\nelse:\n    y is 1.0\nreturn y' 42.0
check_row JUMP_BACK '' $'y is 40.0\nloop while y < 42.0:\n    y is y + 1.0\nreturn y' 42.0
check_row JUMP_IF_FALSE '' $'if x == 2.0:\n    return 42.0\nreturn 1.0' 42.0
check_row JUMP_IF_FALSE_PEEK '' $'y is (x == 2.0) and (x < 3.0)\nif y:\n    return 42.0\nreturn 1.0' 42.0
check_row JUMP_IF_TRUE_PEEK '' $'y is (x == 2.0) or (x > 3.0)\nif y:\n    return 42.0\nreturn 1.0' 42.0
check_row ITER_NEXT 'g is [1.0, 2.0]' $'y is 40.0\nfor q in g:\n    y is y + 1.0\nreturn y' 42.0
check_row INDEX_GET 'g is [40.0]' $'a is g\ni is x - 2.0\nreturn a[i] + x' 42.0
check_row INDEX_SET 'g is [0.0]' $'a is g\ni is x - 2.0\na[i] is 42.0\nreturn a[i]' 42.0
check_row LOOP_CAP_NAMED '' $'y is 40.0\nloop while y < 42.0:\n    y is y + 1.0\nreturn y' 42.0
check_row LOOP_STALL_NAMED '' $'y is 40.0\nloop while not converged:\n    y is 42.0\nreturn 42.0' 42.0
check_row CALL '' $'y is abs of (-42.0)\nreturn y' 42.0
# 257 statements in one function, which the JIT scans and the code cache does not
# refuse. A statement also reads a name, so the op refused at the table end can be
# GET_NAME.
capacity_row(){ op=$1 init=$2 stmt=$3 first=${4:-}; row=$((row+1)); s="$D/cap-$op.eigs"; { printf '%s\n' "$init"; echo 'define hot(x) as:'; [ -z "$first" ] || printf '    %s\n' "$first"; i=0; while [ $i -lt 257 ];do printf '    %s\n' "$stmt";i=$((i+1));done; echo '    return 42.0';echo 'v is 0.0';echo 'for k in range of 80:';echo '    v is hot of 2.0';echo 'print of v';} >"$s"; EIGS_JIT_HOT=1 EIGS_JIT_STATS=1 "$EIGS" "$s" >"$D/ca" 2>"$D/ce";ar=$?;a=$(cat "$D/ca"); EIGS_JIT_OFF=1 "$EIGS" "$s" >"$D/cb" 2>"$D/cf";br=$?;b=$(cat "$D/cb");if clean "$D/ce" "$D/cf"&&grep -qE "scanned=[1-9][0-9]* .*cache_full_rejects=0" "$D/ce"&&[ $ar -eq 0 ]&&[ $br -eq 0 ]&&[ "$a" = 42.0 ]&&[ "$b" = 42.0 ];then echo "PASS: capacity of 257 $op statements literal=42.0 JIT-on/off examined=$row";else echo "FAIL: capacity $op statements on=<$a> off=<$b>" >&2;status=1;fi;}
capacity_row GET_NAME 'g is 1.0' 'z is g'
capacity_row DOT_GET 'g is {"v": 1.0}' 'z is g.v'
capacity_row DOT_SET 'g is {"v": 0.0}' 'g.v is x'
capacity_row LOCAL_DOT_SET 'g is {"v": 0.0}' 'a.v is x' 'a is g'
exit "$status"
