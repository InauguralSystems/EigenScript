#!/usr/bin/env bash
# #2473: tensor_save raises `io` when its file cannot be opened, written or closed.
#   test_tensor_save_2473.sh                 the rows that run everywhere (PLAN: 10)
#   test_tensor_save_2473.sh --full-device   the /dev/full row alone (PLAN: 1); its section skips where
#                                            the platform has no /dev/full
# Prints PLAN: N, one PASS:/FAIL: line per row, and under each row that ran the runtime what the
# runtime wrote to stderr, so that the section's classifier sees a sanitizer report from any run.
# A row that expects an error requires exit code 1, the language's error exit. A sanitizer build that
# leaked on one of these paths would exit with the sanitizer's code and fail the row: the error paths
# of tensor_save free what they hold, and a leak there is a finding, not noise.
set -u
tmp=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ts2473.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
eigs=${EIGS:-"$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript"}
failed=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }
show() { [ -s "$1" ] && sed 's/^/    stderr: /' "$1"; return 0; }
# raises NAME FILE.eigs RC-FILE ERR-FILE PATH-IN-MESSAGE: the run exited 1, the language's error exit, and
# its message names tensor_save and the path.
raised() {
    if [ "$(cat "$3")" = 1 ] && grep -q "tensor_save: '$5':" "$4"; then pass "$1"; else
        fail "$1 (exit code $(cat "$3"))"
    fi
    show "$4"
}

if [ "${1:-}" = --full-device ]; then
    echo "PLAN: 1"
    printf 'print of (tensor_save of [[1, 2], "/dev/full"])\n' >"$tmp/full.eigs"
    "$eigs" "$tmp/full.eigs" >"$tmp/full.out" 2>"$tmp/full.err"; echo $? >"$tmp/full.rc"
    raised "tensor_save raises io on a full device" "$tmp/full.eigs" "$tmp/full.rc" "$tmp/full.err" /dev/full
    exit "$failed"
fi

echo "PLAN: 10"
# A 64-byte file-size limit stands in for a full disk on every platform. The child's stderr comes back
# through a pipe: the limit holds for every regular file the child writes, so a stderr sent straight to
# a file was cut at 64 bytes too, and the message was whole only where the scratch path was short.
limited() { # PROGRAM OUT ERR RC
    EIGS_BIN=$eigs CASE_DIR=$tmp PROGRAM=$1 python3 - >"$2" 2>"$3" <<'PY'
import os, resource, signal, subprocess, sys
def limit():
    resource.setrlimit(resource.RLIMIT_FSIZE, (64, 64))
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
p = subprocess.run([os.environ['EIGS_BIN'], os.environ['PROGRAM']], cwd=os.environ['CASE_DIR'],
                   preexec_fn=limit, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
sys.stdout.buffer.write(p.stdout); sys.stderr.buffer.write(p.stderr)
raise SystemExit(p.returncode if 0 <= p.returncode < 126 else 125)
PY
    echo $? >"$4"
}
cat >"$tmp/save.eigs" <<'EOF2'
p is buf_from_list of ([1, 2])
print of (tensor_save of [p, "t.bin"])
EOF2
limited "$tmp/save.eigs" "$tmp/limit.out" "$tmp/limit.err" "$tmp/limit.rc"
raised "tensor_save raises io on a size-limit short write" "$tmp/save.eigs" "$tmp/limit.rc" "$tmp/limit.err" t.bin
if [ -f "$tmp/t.bin" ] && [ "$(wc -c <"$tmp/t.bin" | tr -d ' ')" -eq 64 ]; then pass "tensor_save matches write_text by leaving the partial file"; else fail "tensor_save partial-file policy (t.bin: $(wc -c <"$tmp/t.bin" 2>/dev/null | tr -d ' ') bytes)"; fi
cat >"$tmp/kind.eigs" <<'EOF2'
p is buf_from_list of ([1, 2])
try:
    tensor_save of [p, "k.bin"]
    print of "returned"
catch e:
    print of e.kind
EOF2
limited "$tmp/kind.eigs" "$tmp/kind.out" "$tmp/kind.err" "$tmp/kind.rc"
if [ "$(cat "$tmp/kind.rc")" = 0 ] && [ "$(cat "$tmp/kind.out")" = io ]; then pass "a failed write is caught with kind io"; else fail "a failed write's caught kind (exit code $(cat "$tmp/kind.rc"), printed '$(cat "$tmp/kind.out")')"; fi
show "$tmp/kind.err"
# The two rows above fail when the close flushes: 112 bytes fit the stream's buffer. 48,016 bytes do not,
# so here a write itself comes back short.
cat >"$tmp/big.eigs" <<'EOF2'
p is buffer of 6000
print of (tensor_save of [p, "big.bin"])
EOF2
limited "$tmp/big.eigs" "$tmp/big.out" "$tmp/big.err" "$tmp/big.rc"
raised "tensor_save raises io when a write itself comes back short" "$tmp/big.eigs" "$tmp/big.rc" "$tmp/big.err" big.bin

printf 'print of (tensor_save of [[1], "/nonexistent-dir/x"])\n' >"$tmp/open.eigs"
"$eigs" "$tmp/open.eigs" >"$tmp/open.out" 2>"$tmp/open.err"; echo $? >"$tmp/open.rc"
raised "tensor_save raises io on an unopenable path" "$tmp/open.eigs" "$tmp/open.rc" "$tmp/open.err" /nonexistent-dir/x
cat >"$tmp/catch.eigs" <<'EOF2'
try:
    tensor_save of [[1, 2], "/nonexistent-dir/x"]
    print of "returned"
catch e:
    print of e.kind
EOF2
"$eigs" "$tmp/catch.eigs" >"$tmp/catch.out" 2>"$tmp/catch.err"; echo $? >"$tmp/catch.rc"
if [ "$(cat "$tmp/catch.rc")" = 0 ] && [ "$(cat "$tmp/catch.out")" = io ]; then pass "a failed open is caught with kind io"; else fail "a failed open's caught kind (exit code $(cat "$tmp/catch.rc"), printed '$(cat "$tmp/catch.out")')"; fi
show "$tmp/catch.err"

check_shape() {
    name=$1; expression=$2; dims=$3; data=$4; file=$5
    printf 'print of (tensor_save of [%s, "%s/%s.bin"])\n' "$expression" "$tmp" "$file" >"$tmp/$file.eigs"
    "$eigs" "$tmp/$file.eigs" >"$tmp/$file.out" 2>"$tmp/$file.err"; echo $? >"$tmp/$file.rc"
    if [ "$(cat "$tmp/$file.rc")" = 0 ] && [ "$(cat "$tmp/$file.out")" = true ] &&
       python3 - "$tmp/$file.want" "$dims" "$data" <<'PY'
import ast, struct, sys
dims=ast.literal_eval(sys.argv[2]); data=ast.literal_eval(sys.argv[3])
ndim, rows, cols=dims
with open(sys.argv[1], 'wb') as f:
 f.write(struct.pack('=4I', ndim, rows, cols, 1))
 f.write(struct.pack('=%dd' % len(data), *data))
 f.write(b'\0' * (40 * (cols if ndim == 1 else rows * cols)))
PY
       cmp -s "$tmp/$file.want" "$tmp/$file.bin"; then pass "tensor_save preserves bytes for $name"; else fail "tensor_save bytes for $name (exit code $(cat "$tmp/$file.rc"))"; fi
    show "$tmp/$file.err"
}
check_shape "a 1-D list" '[1, 2]' '(1,1,2)' '[1.0,2.0]' list1
check_shape "a 2-D list" '[[1, 2], [3, 4]]' '(2,2,2)' '[1.0,2.0,3.0,4.0]' list2
check_shape "a buffer" 'buf_from_list of ([1, 2])' '(1,1,2)' '[1.0,2.0]' buf
check_shape "a 2-D zero-column tensor" '[[], []]' '(2,2,0)' '[]' zerocol
exit "$failed"
