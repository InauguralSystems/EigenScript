#!/usr/bin/env bash
set -u
tmp=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ts2473.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
eigs=${EIGS:-"$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript"}

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; }

cat >"$tmp/save.eigs" <<'EOF'
p is buf_from_list of ([1, 2])
print of (tensor_save of [p, "t.bin"])
EOF
EIGS_BIN=$eigs CASE_DIR=$tmp python3 - <<'PY' >"$tmp/limit.out" 2>"$tmp/limit.err"
import os, resource, signal, subprocess
def limited():
    resource.setrlimit(resource.RLIMIT_FSIZE, (64, 64))
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
p = subprocess.run([os.environ['EIGS_BIN'], os.path.join(os.environ['CASE_DIR'], 'save.eigs')],
                   cwd=os.environ['CASE_DIR'], preexec_fn=limited)
raise SystemExit(0 if p.returncode != 0 else 1)
PY
if [ $? -eq 0 ] && grep -q "tensor_save: 't.bin':" "$tmp/limit.err"; then pass "tensor_save raises io on a size-limit short write"; else fail "tensor_save size-limit failure"; fi
if [ -f "$tmp/t.bin" ] && [ "$(wc -c <"$tmp/t.bin" | tr -d ' ')" -eq 64 ]; then pass "tensor_save matches write_text by leaving the partial file"; else fail "tensor_save partial-file policy"; fi

if [ -e /dev/full ]; then
    printf 'print of (tensor_save of [[1, 2], "/dev/full"])\n' >"$tmp/full.eigs"
    if "$eigs" "$tmp/full.eigs" >"$tmp/full.out" 2>"$tmp/full.err"; then fail "tensor_save full-device failure";
    elif grep -q "tensor_save: '/dev/full':" "$tmp/full.err"; then pass "tensor_save raises io on a full device";
    else fail "tensor_save full-device diagnostic"; fi
else
    echo "SKIP: no /dev/full on this platform"
fi

printf 'print of (tensor_save of [[1], "/nonexistent-dir/x"])\n' >"$tmp/open.eigs"
if "$eigs" "$tmp/open.eigs" >"$tmp/open.out" 2>"$tmp/open.err"; then fail "tensor_save unopenable path";
elif grep -q "tensor_save: '/nonexistent-dir/x':" "$tmp/open.err"; then pass "tensor_save raises io on an unopenable path";
else fail "tensor_save unopenable-path diagnostic"; fi

cat >"$tmp/catch.eigs" <<'EOF'
try:
    tensor_save of [[1, 2], "/nonexistent-dir/x"]
catch e:
    print of e.kind
EOF
if [ "$("$eigs" "$tmp/catch.eigs" 2>/dev/null)" = io ]; then pass "tensor_save failures are catchable with kind io"; else fail "tensor_save caught error kind"; fi

check_shape() {
    name=$1; expression=$2; dims=$3; data=$4
    printf 'print of (tensor_save of [%s, "%s/%s.bin"])\n' "$expression" "$tmp" "$name" >"$tmp/$name.eigs"
    if "$eigs" "$tmp/$name.eigs" >"$tmp/$name.out" 2>"$tmp/$name.err" && [ "$(cat "$tmp/$name.out")" = true ] &&
       python3 - "$tmp/$name.want" "$dims" "$data" <<'PY'
import ast, struct, sys
dims=ast.literal_eval(sys.argv[2]); data=ast.literal_eval(sys.argv[3])
ndim, rows, cols=dims
with open(sys.argv[1], 'wb') as f:
 f.write(struct.pack('=4I', ndim, rows, cols, 1))
 f.write(struct.pack('=%dd' % len(data), *data))
 f.write(b'\0' * (40 * (cols if ndim == 1 else rows * cols)))
PY
       cmp -s "$tmp/$name.want" "$tmp/$name.bin"; then pass "tensor_save preserves bytes for $name"; else fail "tensor_save bytes for $name"; fi
}
check_shape "a 1-D list" '[1, 2]' '(1,1,2)' '[1.0,2.0]'
check_shape "a 2-D list" '[[1, 2], [3, 4]]' '(2,2,2)' '[1.0,2.0,3.0,4.0]'
check_shape "a buffer" 'buf_from_list of ([1, 2])' '(1,1,2)' '[1.0,2.0]'
check_shape "a 2-D zero-column tensor" '[[], []]' '(2,2,0)' '[]'
