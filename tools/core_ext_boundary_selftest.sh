#!/usr/bin/env bash
# Calibration for core_ext_boundary_check.sh: prove the compile leg is parallel
# and that a forbidden private-header edge still makes the gate fail.
set -u
cd "$(dirname "$0")/.." || exit 2
[ "${1:-}" = "--selftest" ] || { echo "usage: tools/core_ext_boundary_selftest.sh --selftest" >&2; exit 2; }
ROOT=$PWD
T=$(mktemp -d "$(dirname "$ROOT")/eigs-core-boundary.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

git archive HEAD | tar -x -C "$T" || { echo "core-ext selftest: archive failed"; exit 2; }
cp tools/core_ext_boundary_check.sh "$T/tools/core_ext_boundary_check.sh" || exit 2

cat > "$T/cc-witness" <<'EOF'
#!/usr/bin/env bash
state=${CORE_EXT_WITNESS:?}
if mkdir "$state/active" 2>/dev/null; then
    sleep 0.10
    rmdir "$state/active" 2>/dev/null || :
else
    : > "$state/overlap"
fi
exec gcc "$@"
EOF
chmod +x "$T/cc-witness"
mkdir "$T/witness"

run_gate() {
    (cd "$T" && CORE_EXT_JOBS="${SELFTEST_CORE_EXT_JOBS:-2}" CORE_EXT_WITNESS="$T/witness" CC="$T/cc-witness" \
        bash tools/core_ext_boundary_check.sh) > "$T/$1.log" 2>&1
}

run_gate green || { cat "$T/green.log"; echo "core-ext selftest: clean gate did not pass"; exit 1; }
grep -q 'leg A: 28 core TUs scanned' "$T/green.log" &&
grep -q 'leg B: 28 core TUs compile' "$T/green.log" &&
grep -q 'OK: no core -> extension-private include edge' "$T/green.log" || {
    cat "$T/green.log"; echo "core-ext selftest: clean populations/verdict changed"; exit 1;
}
[ -f "$T/witness/overlap" ] || {
    cat "$T/green.log"; echo "core-ext selftest: RED: compiler invocations never overlapped"; exit 1;
}

cp "$T/src/arena.c" "$T/arena.c.saved"
printf '\n#include "ext_http_internal.h"\n' >> "$T/src/arena.c"
if run_gate planted; then
    cat "$T/planted.log"; echo "core-ext selftest: planted private-header edge passed"; exit 1
fi
grep -q 'FAIL\[A\]: core TU src/arena.c includes extension private header "ext_http_internal.h"' "$T/planted.log" || {
    cat "$T/planted.log"; echo "core-ext selftest: planted failure was not attributed"; exit 1;
}
cp "$T/arena.c.saved" "$T/src/arena.c"
run_gate restored || { cat "$T/restored.log"; echo "core-ext selftest: restored gate did not pass"; exit 1; }

echo "PASS: core-ext boundary: 28 TUs and poisoned-header verdict preserved; parallel overlap observed; planted edge rejected; restore green"
