#!/usr/bin/env bash
# #1885/#1890: replay is an rr-style, side-effect-free filesystem view.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EIG="$ROOT/src/eigenscript"
T=$(mktemp -d "${TMPDIR:-/tmp}/eigs_rr.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0 fail=0

cat > "$T/program.eigs" <<EOF
print of mkdir of "$T/work"
print of write_text of ["$T/module.eigs", "answer is 42"]
import module
print of module.answer
print of write_text of ["$T/from", "payload"]
print of rename of ["$T/from", "$T/to"]
print of remove_file of "$T/module.eigs"
EOF
EIGS_TRACE="$T/run.tape" "$EIG" "$T/program.eigs" >"$T/record.out" 2>"$T/record.err"; rrc=$?
rm -rf "$T/work"; rm -f "$T/to" "$T/module.eigs"
printf 'untouched' > "$T/sentinel"
snapshot() {
    python3 - "$T" <<'PY'
import os, sys
root=sys.argv[1]
skip={'before','after','replay.out','replay.err'}
for base, dirs, files in os.walk(root):
    dirs.sort(); files.sort()
    for name in dirs+files:
        rel=os.path.relpath(os.path.join(base,name),root)
        if rel in skip: continue
        s=os.lstat(os.path.join(base,name))
        print(rel, s.st_size, s.st_mtime_ns)
PY
}
snapshot > "$T/before"
EIGS_REPLAY="$T/run.tape" "$EIG" "$T/program.eigs" >"$T/replay.out" 2>"$T/replay.err"; prc=$?
snapshot > "$T/after"
if [ "$rrc" -eq 0 ] && [ "$prc" -eq 0 ] &&
   cmp -s "$T/record.out" "$T/replay.out" && cmp -s "$T/record.err" "$T/replay.err" &&
   cmp -s "$T/before" "$T/after"; then
    echo "  PASS: fresh replay serves module and mutation results without filesystem effects"
    pass=$((pass+1))
else
    echo "  FAIL: fresh replay (record=$rrc replay=$prc)"
    diff -u "$T/record.out" "$T/replay.out" || true
    diff -u "$T/record.err" "$T/replay.err" || true
    diff -u "$T/before" "$T/after" || true
    fail=$((fail+1))
fi

truncate -s $((10*1024*1024+1)) "$T/large"
for reader in read_text read_bytes; do
    cat > "$T/cap.eigs" <<EOF
try:
    x is $reader of "$T/large"
catch e:
    print of f"{e.kind}|{e.message}"
EOF
    EIGS_TRACE="$T/cap.tape" "$EIG" "$T/cap.eigs" >"$T/cap.record" 2>&1; crc=$?
    rm -f "$T/large"
    EIGS_REPLAY="$T/cap.tape" "$EIG" "$T/cap.eigs" >"$T/cap.replay" 2>&1; cpc=$?
    if [ "$crc" -eq 0 ] && [ "$cpc" -eq 0 ] && cmp -s "$T/cap.record" "$T/cap.replay" &&
       grep -q "10485760-byte cap" "$T/cap.replay"; then
        echo "  PASS: $reader over-cap io error replays with cap message"
        pass=$((pass+1))
    else
        echo "  FAIL: $reader over-cap replay (record=$crc replay=$cpc)"
        fail=$((fail+1))
    fi
    truncate -s $((10*1024*1024+1)) "$T/large"
done
printf 'FILESYSTEM RR: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
