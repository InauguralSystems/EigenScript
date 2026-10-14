#!/usr/bin/env bash
# tests/phase2/slot_layer.sh [release|asan] -- #1758 R1.1: the C slot test
# (docs/design/phase2-numbers.md 2.5), with its population checked.
#
# 1. Derive the population: `tools/phase2_inventory.py --slot-population`
#    lists every slot classifier whose first parameter is an EigsSlot.
# 2. Build tests/phase2/slot_layer.c against the amalgamation
#    (make phase2-slot-test) and run it.
# 3. The set of `ENTRY` lines it printed must equal the derived population,
#    both ways, and its examined count must equal the population's size,
#    which must be above zero. The test's own verdict must be PASS.
# Prints the test's whole output, then `slot-layer-population: ...` and a
# final `slot-layer: PASS|FAIL` line. Exit 0 only for PASS.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VARIANT="${1:-release}"
case "$VARIANT" in release|asan) ;; *) echo "slot-layer: FAIL: unknown variant $VARIANT"; exit 2 ;; esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-slot-layer.XXXXXX") || { echo "slot-layer: FAIL: mktemp"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
fail() { echo "slot-layer: FAIL: $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 is required (the population and the amalgamation need it)"
python3 "$ROOT/tools/phase2_inventory.py" --no-write --slot-population > "$TMP/pop.txt" 2>&1
prc=$?
if [ "$prc" -ne 0 ]; then
    sed 's/^/  inventory: /' "$TMP/pop.txt"
    fail "the population scan exited $prc"
fi
grep -v "^slot-population:" "$TMP/pop.txt" | LC_ALL=C sort > "$TMP/want"
n_want=$(grep -c . "$TMP/want")
[ "$n_want" -gt 0 ] || fail "the population scan listed no entry (grep -c gave $n_want)"

make -s -C "$ROOT" PHASE2_SLOT_VARIANT="$VARIANT" phase2-slot-test > "$TMP/build.txt" 2>&1
brc=$?
if [ "$brc" -ne 0 ]; then
    sed 's/^/  build: /' "$TMP/build.txt"
    fail "make phase2-slot-test exited $brc"
fi
BIN="$ROOT/build/phase2/slot_layer_$VARIANT"
[ -x "$BIN" ] || fail "no binary at $BIN after the build"

"$BIN" > "$TMP/out.txt" 2>&1
trc=$?
cat "$TMP/out.txt"
awk '$1 == "ENTRY" { print $2 }' "$TMP/out.txt" | LC_ALL=C sort > "$TMP/got"
n_got=$(grep -c . "$TMP/got")
examined=$(awk '/^slot-layer-test: examined=/ { sub(/^slot-layer-test: examined=/, ""); sub(/ .*/, ""); print }' "$TMP/out.txt")
LC_ALL=C comm -23 "$TMP/want" "$TMP/got" > "$TMP/missing"
LC_ALL=C comm -13 "$TMP/want" "$TMP/got" > "$TMP/extra"
n_missing=$(grep -c . "$TMP/missing")
n_extra=$(grep -c . "$TMP/extra")
sed 's/^/  MISSING (a slot classifier the test never called): /' "$TMP/missing"
sed 's/^/  EXTRA (a test entry that is not a derived slot classifier): /' "$TMP/extra"
echo "slot-layer-population: derived=$n_want examined=${examined:-none} entries=$n_got missing=$n_missing extra=$n_extra test_rc=$trc"
[ "$trc" -eq 0 ] || fail "the test exited $trc"
grep -q '^slot-layer-test: PASS$' "$TMP/out.txt" || fail "the test printed no PASS verdict"
[ "${examined:-x}" = "$n_want" ] || fail "examined=${examined:-none} differs from the derived population ($n_want)"
[ "$n_got" -eq "$n_want" ] && [ "$n_missing" -eq 0 ] && [ "$n_extra" -eq 0 ] ||
    fail "the examined entries differ from the derived population"
echo "slot-layer: PASS"
