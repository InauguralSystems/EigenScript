#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$ROOT/tests/lsan_classify.sh"
unset EIGS_TRACE EIGS_REPLAY EIGS_OBS_FORCE PORT
EIGS=${EIGENSCRIPT:-$ROOT/src/eigenscript}
variant=
for candidate in "$ROOT"/build/*/eigenscript; do
    if [ "$EIGS" -ef "$candidate" ]; then
        variant=$(basename "$(dirname "$candidate")")
        break
    fi
done
if [ -n "${SIGPIPE_VARIANT:-}" ] && [ "$SIGPIPE_VARIANT" != "$variant" ]; then
    echo "FAIL: SIGPIPE_VARIANT=$SIGPIPE_VARIANT does not own the selected CLI $EIGS" >&2
    exit 1
fi
if [ -z "$variant" ]; then
    variant=release
    echo "SIGPIPE contract: no matching CLI variant (build.sh layout); using release"
fi
case "$variant" in
    asan*) http_variant=asan-http ;;
    tsan*) http_variant=tsan-http ;;
    full|http) http_variant=$variant ;;
    *) http_variant=http ;;
esac
echo "SIGPIPE contract: runtime=$variant HTTP=$http_variant"
# File/auxiliary targets never repoint src/eigenscript or auxiliary aliases.
make --no-print-directory -C "$ROOT" "build/$variant/eigenscript" \
    "SIGPIPE_VARIANT=$variant" sigpipe-contract-test sigpipe-partial-test || exit 1
make --no-print-directory -C "$ROOT" "SIGPIPE_VARIANT=$http_variant" \
    sigpipe-contract-test || exit 1

pass=0; fail=0
row() {
    local name=$1 output rc classification
    shift
    output=$("$@" 2>&1); rc=$?
    if [ "$name" = 'positive partial write uses the real production helper' ] &&
       ! grep -q '^SIGPIPE partial: 9/9 passed, 0 failed$' <<< "$output"; then
        rc=1
    fi
    classification=0
    lsan_classify "$output" || classification=$?
    if [ "$rc" -eq 0 ] && [ "$classification" -eq 2 ]; then
        pass=$((pass + 1)); echo "PASS: $name"
    else
        fail=$((fail + 1)); echo "FAIL: $name (rc=$rc sanitizer=$classification)"
    fi
    if [ -n "$output" ]; then printf '%s\n' "$output" | sed 's/^/    /'; fi
}
row 'proc_spawn preserves the host SIGPIPE handler' "$ROOT/build/$variant/test_sigpipe_contract" proc
row 'pipe writes preserve handler, mask, pending state and errno' "$ROOT/build/$variant/test_sigpipe_contract" write
row 'socket sends preserve handler, mask, pending state and errno' "$ROOT/build/$variant/test_sigpipe_contract" send
row 'positive partial write uses the real production helper' "$ROOT/build/$variant/test_sigpipe_partial"
row 'http_early_bind preserves the host SIGPIPE handler' "$ROOT/build/$http_variant/test_sigpipe_contract" early
row 'http_serve preserves the host SIGPIPE handler after a real response' "$ROOT/build/$http_variant/test_sigpipe_contract" serve

# A reader closed BEFORE launching the program makes one ordinary print
# sufficient. Python itself ignores SIGPIPE; restore_signals selects the Unix
# default or the inherited ignored disposition without a pipeline timing race.
for mode in positive plain-default spawn-default spawn-ignore; do
    row "bounded print control: $mode" python3 - "$EIGS" "$mode" <<'PY'
import os
import signal
import subprocess
import sys

binary, mode = sys.argv[1:]
source = ('p is proc_spawn of (["true"])\n' if mode != 'plain-default' else '')
source += 'print of "ok"\n'
if mode == 'positive':
    result = subprocess.run([binary, '-e', source], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=10)
    ok = result.returncode == 0 and result.stdout == b'ok\n' and not result.stderr
else:
    reader, writer = os.pipe()
    os.close(reader)
    try:
        result = subprocess.run([binary, '-e', source], stdout=writer,
                                stderr=subprocess.PIPE, timeout=10,
                                restore_signals=mode != 'spawn-ignore')
    finally:
        os.close(writer)
    if mode == 'spawn-ignore':
        ok = result.returncode > 0 and b'print: stdout write failed:' in result.stderr
    else:
        ok = result.returncode == -signal.SIGPIPE
sys.stdout.write('print control rc=%d\n' % result.returncode)
sys.stdout.flush()
sys.stdout.buffer.write(result.stderr)
sys.exit(0 if ok else 1)
PY
done
echo "SIGPIPE contract: $pass passed, $fail failed (10 declared)"
[ "$pass" -eq 10 ] && [ "$fail" -eq 0 ]
