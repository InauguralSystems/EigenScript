#!/usr/bin/env bash
# Review follow-up for #1885/#1890: hard tape failures, cache ordering, and write refusal.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EIG="$ROOT/src/eigenscript"
T=$(mktemp -d "${TMPDIR:-/tmp}/eigs_1885_followup.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# A source metadata record without its promised chunk is a corrupt tape, not a
# handled replay or permission to fall through to the live source provider.
for loader in import load_file; do
    d="$T/$loader"; mkdir -p "$d"
    printf 'print of "MODULE_RAN"\n' > "$d/module.eigs"
    if [ "$loader" = import ]; then printf 'import module\n' > "$d/program.eigs"
    else printf 'load_file of "module.eigs"\n' > "$d/program.eigs"; fi
    (cd "$d" && EIGS_TRACE=full.tape "$EIG" program.eigs >/dev/null 2>/dev/null)
    sed "/${loader}_source_chunk=/d" "$d/full.tape" > "$d/truncated.tape"
    rm "$d/module.eigs"
    (cd "$d" && EIGS_REPLAY=truncated.tape "$EIG" program.eigs >out 2>err); rc=$?
    if [ "$rc" -ne 0 ] && grep -q "missing source chunk" "$d/err" &&
       ! grep -q 'MODULE_RAN\|not found\|cannot read' "$d/out" "$d/err"; then
        ok "truncated $loader source is loud and never reads live"
    else bad "truncated $loader source (rc=$rc, err=$(cat "$d/err"))"; fi
done

# The second import must return the dictionary before opening the old path.
d="$T/cache"; mkdir -p "$d"
printf 'print of "BODY_ONCE"\nanswer is 42\n' > "$d/module.eigs"
cat > "$d/program.eigs" <<EOF2
import module
print of remove_file of "$d/module.eigs"
print of mkdir of "$d/module.eigs"
import module
print of module.answer
EOF2
(cd "$d" && "$EIG" program.eigs >out 2>err); rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c BODY_ONCE "$d/out")" -eq 1 ] && grep -q '^42$' "$d/out"; then
    ok "module cache precedes source read after path becomes a directory"
else bad "module cache precedes source read (rc=$rc)"; fi

# tensor_save has no payload representation in v8, so replay refuses it before
# xfopen_write rather than fabricating the recorded boolean.
d="$T/tensor"; mkdir -p "$d"
printf 'print of (tensor_save of [[1, 2], "%s/out.tensor"])\n' "$d" > "$d/program.eigs"
EIGS_TRACE="$d/run.tape" "$EIG" "$d/program.eigs" >/dev/null 2>/dev/null
printf sentinel > "$d/out.tensor"
EIGS_REPLAY="$d/run.tape" "$EIG" "$d/program.eigs" >"$d/out" 2>"$d/err"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'tensor_save: not replayable' "$d/err" &&
   [ "$(cat "$d/out.tensor")" = sentinel ]; then
    ok "tensor_save replay refuses before opening its live path"
else bad "tensor_save replay boundary (rc=$rc)"; fi

# A project/stdlib collision warning is an ordered observation even when source
# acquisition then fails. `string` is a shipped stdlib module.
d="$T/warning"; mkdir -p "$d/string.eigs"
printf 'import string\n' > "$d/program.eigs"
(cd "$d" && EIGS_TRACE=run.tape "$EIG" program.eigs >record.out 2>record.err); rrc=$?
rm -rf "$d/string.eigs"
(cd "$d" && EIGS_REPLAY=run.tape "$EIG" program.eigs >replay.out 2>replay.err); prc=$?
if [ "$rrc" -ne 0 ] && [ "$prc" -ne 0 ] && cmp -s "$d/record.err" "$d/replay.err" &&
   grep -q "matches both" "$d/replay.err"; then
    ok "collision warning precedes and replays with import source error"
else bad "collision warning/error ordering (record=$rrc replay=$prc)"; fi

printf 'ISSUE 1885 FOLLOW-UP: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
