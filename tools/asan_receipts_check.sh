#!/usr/bin/env bash
# Self-test of the ASan aggregation step in .github/workflows/ci.yml ("Require
# one receipt per shard, and a summed leak tally of zero"). The step lives
# inline in the workflow, so this runs the REAL step body, extracted with
# PyYAML, on generated shard receipts (#1313: nothing exercised its floor).
#   tools/asan_receipts_check.sh --selftest
set -u
case "${1:-}" in
    --selftest) ;;
    *) echo "usage: tools/asan_receipts_check.sh --selftest" >&2; exit 2 ;;
esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
d=$(mktemp -d "${TMPDIR:-/tmp}/asan_receipts.XXXXXX"); trap 'rm -rf "$d"' EXIT
python3 - "$ROOT/.github/workflows/ci.yml" > "$d/step.sh" <<'PY' || { echo "asan_receipts selftest: INSTRUMENT ERROR, step not extracted"; exit 2; }
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
st = [s for j in wf["jobs"].values() for s in j.get("steps") or []
      if s.get("name") == "Require one receipt per shard, and a summed leak tally of zero"]
assert len(st) == 1, f"{len(st)} aggregation steps"
body = st[0]["run"].replace("${{ env.ASAN_SHARDS }}", "3").replace("${{ needs.scope.outputs.code }}", "true")
assert "${{" not in body, "unsubstituted expression"
print(body)
PY
fail=0 n=0
case_() {   # case_ NAME WANT_RC WANT_TEXT BEARING... (one receipt per shard; shard 1 claims the extras)
    local name=$1 want=$2 text=$3 k=1 b out rc; shift 3
    rm -rf "$d/shard-receipts"; mkdir "$d/shard-receipts"
    for b in "$@"; do
        { echo "PLAN: shard=$k/3 bearing=$b chunks=$b predicted=1s unmeasured=0"; echo "leaked=0"
          if [ "$k" = 1 ]; then printf 'gc_traversal=yes\nlsp_asan=yes\n'; else printf 'gc_traversal=no\nlsp_asan=no\n'; fi
        } > "$d/shard-receipts/shard-$k.txt"; k=$((k + 1))
    done
    out=$(cd "$d" && bash step.sh 2>&1); rc=$?; n=$((n + 1))
    if [ "$rc" = "$want" ] && [[ $out == *"$text"* ]]; then echo "  PASS: $name"
    else echo "  FAIL: $name (rc=$rc, want $want and '$text')"; printf '%s\n' "$out" | tail -3; fail=$((fail + 1)); fi
}
case_ "control: a full split (1+126+122) passes" 0 "Sanitizer coverage complete" 1 126 122
case_ "three one-chunk shards are not the suite (#1313)" 1 "expected >= 200" 1 1 1
case_ "a zero-chunk shard is refused" 1 "no header-bearing chunks" 0 126 122
[ "$n" -eq 3 ] || { echo "asan_receipts selftest: ran $n cases, want 3"; exit 1; }
echo "asan_receipts selftest: $((n - fail))/$n passed"
[ "$fail" -eq 0 ]
