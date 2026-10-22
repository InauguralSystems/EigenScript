#!/usr/bin/env bash
set -eu
EIGS=${EIGS:-${EIGENSCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }; ok() { echo "PASS: $*"; }

python3 - "$(dirname "$0")/../src/ext_http.c" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text().split('Value* builtin_http_early_bind',1)[1]
body=s.split('Value* builtin_http_serve',1)[0]
assert body.index('g_replay_enabled') < body.index('getenv("PORT")') < body.index('socket(AF_INET')
PY
ok "http_early_bind is refused before host work"

cat >"$T/write.eigs" <<EOF
write_text of ["$T/victim", "changed"]
EOF
echo original >"$T/victim"
EIGS_TRACE="$T/write.tape" "$EIGS" "$T/write.eigs" >/dev/null
sed 's/write_text=true/write_text=<heap>/' "$T/write.tape" > "$T/write.edited"
mv "$T/write.edited" "$T/write.tape"
echo original >"$T/victim"
if EIGS_REPLAY="$T/write.tape" "$EIGS" "$T/write.eigs" >/dev/null 2>"$T/e"; then fail "marker replay succeeded"; fi
[ "$(cat "$T/victim")" = original ] || fail "marker fell through to live write"
ok "unservable filesystem records cannot mutate live files"

echo 'tensor_load of "missing"' >"$T/tensor.eigs"
for bad in '[]' '[1]' '["x", 2]'; do
  EIGS_TRACE="$T/tensor.tape" "$EIGS" "$T/tensor.eigs" >/dev/null
  sed "s/tensor_load=null/tensor_load=$bad/" "$T/tensor.tape" > "$T/tensor.edited"
  mv "$T/tensor.edited" "$T/tensor.tape"
  if EIGS_REPLAY="$T/tensor.tape" "$EIGS" "$T/tensor.eigs" >/dev/null 2>"$T/e"; then fail "tensor verdict $bad succeeded"; fi
  grep -F 'tensor_load: malformed replay verdict' "$T/e" >/dev/null || fail "tensor verdict $bad lacked diagnostic"
done
ok "malformed tensor verdict shapes are refused"

echo 'print of "x"' >"$T/unit.eigs"
echo "load_file of \"$T/unit.eigs\"" >"$T/load.eigs"
EIGS_TRACE="$T/source.base" "$EIGS" "$T/load.eigs" >/dev/null
for bad in 1.9 1e300; do
  cp "$T/source.base" "$T/source.tape"
  python3 - "$T/source.tape" "$bad" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(r'(load_file_source=\[true, .*?, )\d+(\])',r'\g<1>'+sys.argv[2]+r'\2',s,count=1)
assert n==1; p.write_text(s)
PY
  if EIGS_REPLAY="$T/source.tape" "$EIGS" "$T/load.eigs" >/dev/null 2>"$T/e"; then fail "source size $bad succeeded"; fi
  grep -F 'invalid source size' "$T/e" >/dev/null || fail "source size $bad lacked diagnostic"
done
ok "fractional and overflowing taped source sizes are refused before cast"

mkdir "$T/mod"
echo 'load_file of "b.eigs"' >"$T/mod/a.eigs"
echo 'print of "from tape"' >"$T/mod/b.eigs"
echo "load_file of \"$T/mod/a.eigs\"" >"$T/tree.eigs"
EIGS_TRACE="$T/tree.tape" "$EIGS" "$T/tree.eigs" >"$T/want"
mv "$T/mod/b.eigs" "$T/mod/b.saved"; ln -s a.eigs "$T/mod/b.eigs"
EIGS_REPLAY="$T/tree.tape" "$EIGS" "$T/tree.eigs" >"$T/got" 2>"$T/e" || fail "symlink-swapped replay failed"
cmp "$T/want" "$T/got" >/dev/null || fail "symlink-swapped replay output changed"
ok "taped load_file identity and directory do not consult host symlinks"
