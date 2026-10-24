#!/usr/bin/env bash
# tests/phase2/slot_layer.sh [release|asan] -- #1758 R1.1: the C slot test
# (docs/design/phase2-numbers.md 2.5), with its population checked.
#
# 1. Derive the population: `tools/phase2_inventory.py --slot-population`
#    lists every slot classifier whose first parameter is an EigsSlot.
# 2. Build tests/phase2/slot_layer.c against the amalgamation
#    (make phase2-slot-test; -O0 for release, -O1 for asan, both -Wall
#    -Wextra) and run it. Under gcc, the reference toolchain for #1775's
#    class, a build warning is a FAIL. Under any other compiler (clang on
#    macOS) the slot test follows the main build's policy there: warnings
#    print, and only the -Werror set fails (the compile itself stops).
# 3. The ENTRY lines (Part A) and the MATRIX lines (Part B) must each equal
#    the derived population, both ways; the examined count must equal its
#    size, which must be above zero; the test's own verdict must be PASS.
#
# Every output this script PARSES is read on its own channel and against its
# own grammar (the R1.1 critic: a Python DeprecationWarning on the scan's
# stderr was read as two classifiers). A tool that writes to stderr, or a line
# outside the grammar, is a FAIL that prints the line; nothing is skipped.
# Python runs with `-W error`, so a new warning fails here, loudly.
# Prints the test's whole output, then `slot-layer-population: ...` and a
# final `slot-layer: PASS|FAIL` line. Exit 0 only for PASS.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VARIANT="${1:-release}"
case "$VARIANT" in release|asan) ;; *) echo "slot-layer: FAIL: unknown variant $VARIANT"; exit 2 ;; esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-slot-layer.XXXXXX") || { echo "slot-layer: FAIL: mktemp"; exit 2; }
trap 'rm -rf "$TMP"' EXIT
fail() { echo "slot-layer: FAIL: $*"; exit 1; }
# show_stderr FILE WHO: a tool that wrote to stderr is a FAIL, with its words
show_stderr() {
    if [ -s "$1" ]; then
        sed "s/^/  $2 stderr: /" "$1"
        fail "$2 wrote to stderr (a population read beside its diagnostics is not trusted)"
    fi
}

command -v python3 >/dev/null 2>&1 || fail "python3 is required (the population and the amalgamation need it)"
python3 -W error "$ROOT/tools/phase2_inventory.py" --no-write --slot-population > "$TMP/pop.txt" 2> "$TMP/pop.err"
prc=$?
show_stderr "$TMP/pop.err" "the population scan"
if [ "$prc" -ne 0 ]; then
    sed 's/^/  inventory: /' "$TMP/pop.txt"
    fail "the population scan exited $prc"
fi
# The scan's grammar: `file:function` lines, then one `slot-population: entries=N`.
ENTRY_RE='^[A-Za-z0-9_]+[.][ch]:[A-Za-z_][A-Za-z0-9_]*$'
grep -Ev "$ENTRY_RE" "$TMP/pop.txt" | grep -Ev '^slot-population: entries=[0-9]+$' > "$TMP/pop.bad"
if [ -s "$TMP/pop.bad" ]; then
    sed 's/^/  UNPARSED population line: /' "$TMP/pop.bad"
    fail "the population scan printed lines outside its grammar"
fi
grep -E "$ENTRY_RE" "$TMP/pop.txt" | LC_ALL=C sort > "$TMP/want"
n_want=$(grep -c . "$TMP/want")
declared=$(awk '/^slot-population: entries=/ { sub(/^slot-population: entries=/, ""); print }' "$TMP/pop.txt")
[ -n "$declared" ] && [ "$(grep -c '^slot-population:' "$TMP/pop.txt")" -eq 1 ] ||
    fail "the population scan printed no single summary line"
[ "$declared" = "$n_want" ] || fail "the population scan declared $declared entries and listed $n_want"
[ "$n_want" -gt 0 ] || fail "the population scan listed no entry"

make -s -C "$ROOT" PHASE2_SLOT_VARIANT="$VARIANT" phase2-slot-test > "$TMP/build.txt" 2>&1
brc=$?
BIN="$ROOT/build/phase2/slot_layer_$VARIANT"
if [ "$brc" -ne 0 ]; then
    sed 's/^/  build: /' "$TMP/build.txt"
    fail "make phase2-slot-test exited $brc"
fi
# #1775: the amalgamation compiles warning-free at the slot test's level (-O0
# for release, ASan's -O1 for asan, both with -Wall -Wextra). The rule was
# established on gcc, the reference toolchain for that class, and holds only
# there: R1.1's macOS lane failed it with 103 clang-only warnings
# (-Wdefault-const-init-field-unsafe on EigsView) that the main clang build
# prints too. The compiler is asked, not guessed: gcc defines __GNUC__ and
# not __clang__. Under gcc a warning fails and the binary is removed, so the
# next run compiles, and warns, again; under another compiler it prints.
SLOT_CC=$(make -s -C "$ROOT" --no-print-directory print-CC)
SLOT_CC_MACROS=$(printf '' | $SLOT_CC -dM -E -x c - 2> /dev/null)
case "$SLOT_CC_MACROS" in
    *"#define __clang__"*) SLOT_CC_KIND=clang ;;
    *"#define __GNUC__"*) SLOT_CC_KIND=gcc ;;
    *) SLOT_CC_KIND=other ;;
esac
if grep -q 'warning:' "$TMP/build.txt"; then
    if [ "$SLOT_CC_KIND" = gcc ]; then
        grep 'warning:' "$TMP/build.txt" | sed 's/^/  build warning: /'
        rm -f "$BIN"
        fail "the slot test build printed $(grep -c 'warning:' "$TMP/build.txt") warning(s) (#1775)"
    fi
    grep 'warning:' "$TMP/build.txt" | sed "s/^/  build warning ($SLOT_CC_KIND: printed, not failing): /"
fi
[ -x "$BIN" ] || fail "no binary at $BIN after the build"

"$BIN" > "$TMP/out.txt" 2> "$TMP/out.err"
trc=$?
cat "$TMP/out.txt"
show_stderr "$TMP/out.err" "the slot test"
# The test's grammar (its header comment); anything else is refused.
NAME_RE='[A-Za-z0-9_]+[.][ch]:[A-Za-z_][A-Za-z0-9_]*'
grep -Ev "^ENTRY $NAME_RE [A-Za-z_]+ values=[0-9]+ (ok|FAIL)$" "$TMP/out.txt" |
    grep -Ev "^MATRIX $NAME_RE kinds=[0-9]+ (ok|FAIL)$" |
    grep -Ev '^ARM [a-z_]+ (ok|FAIL)$' |
    grep -Ev '^slot-layer-test: (FAIL .+|examined=[0-9]+ .*failures=[0-9]+|PASS|FAIL)$' > "$TMP/out.bad"
if [ -s "$TMP/out.bad" ]; then
    sed 's/^/  UNPARSED slot test line: /' "$TMP/out.bad"
    fail "the slot test printed lines outside its grammar"
fi
awk '$1 == "ENTRY" { print $2 }' "$TMP/out.txt" | LC_ALL=C sort > "$TMP/got"
awk '$1 == "MATRIX" { print $2 }' "$TMP/out.txt" | LC_ALL=C sort > "$TMP/gotm"
n_got=$(grep -c . "$TMP/got")
n_gotm=$(grep -c . "$TMP/gotm")
examined=$(awk '/^slot-layer-test: examined=/ { sub(/^slot-layer-test: examined=/, ""); sub(/ .*/, ""); print }' "$TMP/out.txt")
LC_ALL=C comm -23 "$TMP/want" "$TMP/got" > "$TMP/missing"
LC_ALL=C comm -13 "$TMP/want" "$TMP/got" > "$TMP/extra"
LC_ALL=C comm -3 "$TMP/want" "$TMP/gotm" > "$TMP/mdiff"
n_missing=$(grep -c . "$TMP/missing")
n_extra=$(grep -c . "$TMP/extra")
n_mdiff=$(grep -c . "$TMP/mdiff")
sed 's/^/  MISSING (a slot classifier the test never called): /' "$TMP/missing"
sed 's/^/  EXTRA (a test entry that is not a derived slot classifier): /' "$TMP/extra"
sed 's/^/  MATRIX differs from the population: /' "$TMP/mdiff"
echo "slot-layer-population: derived=$n_want examined=${examined:-none} entries=$n_got matrix=$n_gotm missing=$n_missing extra=$n_extra matrix_diff=$n_mdiff test_rc=$trc"
[ "$trc" -eq 0 ] || fail "the test exited $trc"
grep -q '^slot-layer-test: PASS$' "$TMP/out.txt" || fail "the test printed no PASS verdict"
[ "${examined:-x}" = "$n_want" ] || fail "examined=${examined:-none} differs from the derived population ($n_want)"
[ "$n_got" -eq "$n_want" ] && [ "$n_missing" -eq 0 ] && [ "$n_extra" -eq 0 ] ||
    fail "the examined entries differ from the derived population"
[ "$n_gotm" -eq "$n_want" ] && [ "$n_mdiff" -eq 0 ] ||
    fail "the matrix entries differ from the derived population"
echo "slot-layer: PASS"
