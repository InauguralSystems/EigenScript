#!/bin/bash
# #1746 Phase 1 / #1748: every float->integer conversion in the ieee build goes
# through EIGS_DCAST's one checked helper (eigenscript.h eigs_d2ll).
#
#   bash tools/ieee_cast_sites.sh            -> prints every fix_trunc site, then
#   CAST_SITES: helper=<file:line> found=<n> outside=<m>
#
# The population is gcc's own: each hosted source is compiled with the ieee
# flags and -fdump-tree-gimple-raw-lineno, and every `fix_trunc_expr` (the
# GIMPLE node for a float->int conversion, explicit or implicit) is a site.
# Asserts dumps == sources > 0, then that the ONLY site is the helper's own
# conversion line (found to be exactly 1). Exit 0 iff outside == 0.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
O="$(mktemp -d "${TMPDIR:-/tmp}/ieee_casts.XXXXXX")" || exit 2
trap 'rm -rf "$O"' EXIT
SRCS=$(make -s -C "$ROOT" print-HOSTED_SOURCES) || { echo "FAIL: cannot list sources"; exit 2; }
FL=$(make -s -C "$ROOT" print-FLAGS_ieee | sed 's/-O2/-O0/; s/-DEIGENSCRIPT_VERSION=[^ ]*//')
for f in $SRCS; do
    (cd "$O" && gcc $FL '-DEIGENSCRIPT_VERSION="x"' -w -I"$ROOT/src" -c "$ROOT/$f" -o /dev/null \
        -fdump-tree-gimple-raw-lineno) || { echo "FAIL: compile $f"; exit 2; }
done
n_src=$(echo $SRCS | wc -w); n_dump=$(ls "$O"/*.gimple 2>/dev/null | wc -l)
[ "$n_src" -gt 0 ] && [ "$n_dump" = "$n_src" ] || { echo "FAIL: $n_dump dumps for $n_src sources"; exit 2; }
hl=$(grep -n 'return (long long)x;' "$ROOT/src/eigenscript.h" | cut -d: -f1)
[ "$(echo "$hl" | wc -w)" = 1 ] || { echo "FAIL: helper conversion line not unique in eigenscript.h: '$hl'"; exit 2; }
helper="eigenscript.h:$hl"
grep -ho '\[[^]]*\] gimple_assign <fix_trunc_expr' "$O"/*.gimple \
    | sed 's#.*/src/##; s#:[0-9]*\] .*##' | sort -u > "$O/sites"
cat "$O/sites"
found=$(grep -c . "$O/sites"); outside=$(grep -vxc "$helper" "$O/sites")
echo "CAST_SITES: helper=$helper found=$found outside=$outside"
[ "$found" -ge 1 ] && grep -qx "$helper" "$O/sites" && [ "$outside" = 0 ]
