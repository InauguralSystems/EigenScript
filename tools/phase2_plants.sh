#!/usr/bin/env bash
# tools/phase2_plants.sh [--ref REF] [--selftest] -- #1758: Phase 2's planted
# faults (docs/design/phase2-numbers.md 9.3). A check proves it fires when it
# is written or changed (docs/PRINCIPLES.md 5), so this runs as a
# tools/selftests.txt row keyed on the checks the plants name, never on every
# suite or CI run; `--selftest` is that row's spelling of the same run. Each
# plant:
#   1. `git archive REF` (default HEAD) into a scratch tree with no .git;
#   2. applies one replacement, refusing unless the original text occurs
#      exactly once before and the planted text after (else BROKEN);
#   3. builds what its named check needs (plain make, one at a time);
#   4. runs the named check and requires the check's OWN failure line naming
#      the row (keyed on the message, not on a nonzero exit) -> KILLED.
# Then, once per plant, the transverse run (9.3, "deleting its named check's
# assertion must let the plant through"): the same planted tree with the
# check's assertion removed must NOT print that line -> the plant survives
# exactly the deletion of the assertion that names it.
#
# Plants land with their named checks: plant 1 with R1.1 (the C slot test);
# 2-7 name MAP rows that land in R1.3-R2.2 and join this table then. The R1.1
# fix round added three instrument plants on the slot test: an operator arm
# that lost its int refusal (Part D), and a population scan that writes noise
# to stderr or an unparsed line to stdout (the critic's class); and #1775's
# plant, the missing return that makes the -O0 amalgamation warn.
# Prints one line per plant and `plants=N killed=N survived=0 broken=0
# transverse=N`; exit 0 only for exactly that, with N > 0. About 3 minutes
# per plant on the 4 GB box (two -O0 compiles of the amalgamated slot test).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF=HEAD
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) REF="$2"; shift 2 ;;
        --selftest) shift ;;
        *) echo "phase2-plants: FAIL: unknown argument $1"; exit 2 ;;
    esac
done
TMO=""
if command -v timeout >/dev/null 2>&1; then TMO="timeout 1500"
elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout 1500"; fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-phase2-plants.XXXXXX") || { echo "phase2-plants: FAIL: mktemp"; exit 2; }
VERDICT_DONE=0
# A run that ends without its verdict line is a FAIL, named with the command
# it was running (the #988 rule).
trap 'rc=$?; [ "$VERDICT_DONE" = 1 ] || echo "phase2-plants: FAIL: exited ($rc) before a verdict, at: $BASH_COMMAND"; rm -rf "$WORK"' EXIT

# replace FILE OLD NEW: exactly one OLD before, NEW present after.
replace() {
    python3 -W error - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding='utf-8') as f:
    text = f.read()
n = text.count(old)
if n != 1:
    print('replace: %s: the original occurs %d times, want exactly 1' % (path, n))
    sys.exit(1)
text = text.replace(old, new)
if new not in text:
    print('replace: %s: the planted text is absent after the replacement' % path)
    sys.exit(1)
with open(path, 'w', encoding='utf-8') as f:
    f.write(text)
PY
}

plants=0; killed=0; survived=0; broken=0; transverse=0

# run_plant ID FILE OLD NEW CHECK_FILE CHECK_OLD CHECK_NEW FAIL_RE CHECK_CMD...
run_plant() {
    local id="$1" file="$2" old="$3" new="$4" cfile="$5" cold="$6" cnew="$7" re="$8"
    shift 8
    plants=$((plants + 1))
    local verdict="" trans=""
    for mode in plant transverse; do
        local dir="$WORK/$id-$mode"
        mkdir -p "$dir"
        if ! git -C "$ROOT" archive "$REF" | tar -x -C "$dir"; then verdict=BROKEN; echo "  $id: archive of $REF failed"; break; fi
        if ! replace "$dir/$file" "$old" "$new"; then verdict=BROKEN; break; fi
        if [ "$mode" = transverse ] && ! replace "$dir/$cfile" "$cold" "$cnew"; then trans=BROKEN; break; fi
        local log="$WORK/$id-$mode.log"
        (cd "$dir" && $TMO "$@") > "$log" 2> "$log.err"
        local rc=$?
        if [ -s "$log.err" ]; then      # the check's own stderr: unexpected, shown, BROKEN
            sed 's/^/    check stderr: /' "$log.err"
            [ "$mode" = plant ] && verdict=BROKEN || trans=BROKEN
            break
        fi
        if [ "$mode" = plant ]; then
            if grep -Eq "$re" "$log"; then verdict=KILLED
            elif [ "$rc" -eq 124 ] || grep -q 'build: \|make phase2-slot-test exited' "$log"; then
                verdict=BROKEN; echo "  $id: the check did not run (rc=$rc):"; tail -20 "$log" | sed 's/^/    | /'
            else verdict=SURVIVED; echo "  $id: no failure line matching /$re/ (rc=$rc):"; tail -20 "$log" | sed 's/^/    | /'; fi
            grep -E "$re" "$log" | head -3 | sed 's/^/    red: /'
            [ "$verdict" = KILLED ] || break
        else
            if grep -Eq "$re" "$log"; then trans=NOT-TRANSVERSE; echo "  $id: the line still fired with its assertion deleted"
            elif [ "$rc" -eq 124 ]; then trans=BROKEN
            else trans=TRANSVERSE; fi
            tail -2 "$log" | sed 's/^/    assertion deleted: /'
        fi
    done
    case "$verdict" in
        KILLED) killed=$((killed + 1)) ;;
        SURVIVED) survived=$((survived + 1)) ;;
        *) broken=$((broken + 1)); verdict=BROKEN ;;
    esac
    [ "$trans" = TRANSVERSE ] && transverse=$((transverse + 1))
    echo "plant $id: $verdict transverse=${trans:-not-run}"
}

# Plant 1 (9.3): an int that fits inline stored boxed. slot_from_int, the one
# int writer, skips the small-int rule and tags the int as a heap pointer.
# Named check: the C slot test's slot_from_int rows (Part C).
run_plant 1 src/value_slot.h \
    'EigsSlot s; s.u = TAG_SMI | ((uint64_t)i & SLOT_PAYLOAD_MASK); return s;' \
    'EigsSlot s; s.u = TAG_HEAP | ((uint64_t)i & SLOT_PAYLOAD_MASK); return s;' \
    tests/phase2/slot_layer.c \
    '        if (s.u != smi(v).u)' \
    '        if (0)' \
    '^slot-layer-test: FAIL slot_from_int\(0\): bits 0x' \
    bash tests/phase2/slot_layer.sh release

# An operator arm that lost its int refusal: NUM_CMP raises a type error for
# an SMI again (a `try` turns it into a wrong value). Named check: the slot
# test's Part D row for `<`.
run_plant arm-refusal src/vm.c \
    "        if (slot_type(_as) == VAL_INT) \\
            eigs_int_unwired(\"compare '\" OPNAME \"'\", _as.u); \\
        if (slot_type(_bs) == VAL_INT) \\
            eigs_int_unwired(\"compare '\" OPNAME \"'\", _bs.u); \\
" \
    "" \
    tests/phase2/slot_layer.c \
    '        if (strcmp(got, want) != 0) { FAILF("arm %s with an int: got %s, want %s", g_arm->name, got, want); bad++; }' \
    '        if (0) { FAILF("arm %s with an int: got %s, want %s", g_arm->name, got, want); bad++; }' \
    "^slot-layer-test: FAIL arm lt with an int: got " \
    bash tests/phase2/slot_layer.sh release

# The critic's class: a population scan whose diagnostics reach the parser.
# Named checks: the runner's stderr refusal, and its grammar whitelist.
run_plant stderr-noise tools/phase2_inventory.py \
    "    out, bad = [], []
    for (rel, k), (cls, c) in sorted(slots.items()):" \
    "    print('phase2-plant: noise on stderr', file=sys.stderr)
    out, bad = [], []
    for (rel, k), (cls, c) in sorted(slots.items()):" \
    tests/phase2/slot_layer.sh \
    'show_stderr "$TMP/pop.err" "the population scan"' \
    ':' \
    "^slot-layer: FAIL: the population scan wrote to stderr" \
    bash tests/phase2/slot_layer.sh release
run_plant stdout-noise tools/phase2_inventory.py \
    "    out, bad = [], []
    for (rel, k), (cls, c) in sorted(slots.items()):" \
    "    print('phase2-plant: an unparsed line')
    out, bad = [], []
    for (rel, k), (cls, c) in sorted(slots.items()):" \
    tests/phase2/slot_layer.sh \
    'if [ -s "$TMP/pop.bad" ]; then' \
    'if false; then' \
    "^slot-layer: FAIL: the population scan printed lines outside its grammar" \
    bash tests/phase2/slot_layer.sh release

# #1775: the missing return comes back. -O0 does not fold ARG_GUARD's
# constant test, so the amalgamation warns (-Wreturn-type). Named check: the
# runner's build-warning refusal.
run_plant return-type src/builtins_tensor.c \
    "    return make_null();   /* unreachable: the guard above always returns, but
                           * -O0 does not fold its constant test (#1775) */
" \
    "" \
    tests/phase2/slot_layer.sh \
    "if grep -q 'warning:' \"\$TMP/build.txt\"; then" \
    'if false; then' \
    "^slot-layer: FAIL: the slot test build printed [0-9]+ warning" \
    bash tests/phase2/slot_layer.sh release

echo "plants=$plants killed=$killed survived=$survived broken=$broken transverse=$transverse"
VERDICT_DONE=1
if [ "$plants" -gt 0 ] && [ "$killed" -eq "$plants" ] && [ "$transverse" -eq "$plants" ]; then
    echo "phase2-plants: PASS"; exit 0
fi
echo "phase2-plants: FAIL"; exit 1
