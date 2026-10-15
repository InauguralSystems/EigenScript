# #1758 R1.1: the C slot test (docs/design/phase2-numbers.md 2.5). Nothing
# produces an int before R1.3, so this is the only witness of what every slot
# classifier does with one; tests/phase2/slot_layer.sh also checks that it
# examined exactly the population tools/phase2_inventory.py derives.
echo "[0fk] Phase 2 slot layer: every slot classifier against an SMI (#1758)"
TOTAL=$((TOTAL + 1))
# #1783: an ASan suite binary (asan, or asan-server in the CI shards) runs
# the slot test under ASan/UBSan; anything else runs the release flavour.
. "$TESTS_DIR/suite_variant.sh"
slot_variant=release
suite_variant_is_asan "$(suite_binary_variant)" && slot_variant=asan
slot_rc=0
bash ../tests/phase2/slot_layer.sh "$slot_variant" > /tmp/eigs-slot-layer.$$ 2> /tmp/eigs-slot-layer-err.$$ || slot_rc=$?
slot_last=$(tail -1 /tmp/eigs-slot-layer.$$)
if [ "$slot_rc" -eq 0 ] && [ "$slot_last" = "slot-layer: PASS" ] && [ ! -s /tmp/eigs-slot-layer-err.$$ ]; then
    PASS=$((PASS + 1))
    echo "  slot test variant: $slot_variant"
    grep '^slot-layer' /tmp/eigs-slot-layer.$$ | sed 's/^/  /'
else
    FAIL=$((FAIL + 1)); echo "  FAIL: slot layer ($slot_variant) rc=$slot_rc"
    sed 's/^/  | /' /tmp/eigs-slot-layer.$$
    sed 's/^/  | stderr: /' /tmp/eigs-slot-layer-err.$$
fi
rm -f /tmp/eigs-slot-layer.$$ /tmp/eigs-slot-layer-err.$$
echo ""
