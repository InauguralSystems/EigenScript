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
# The step calls the reviewed-baseline comparator by its repo-relative path
# (#1725), and the step runs here with cwd "$d": give it the same layout.
mkdir -p "$d/tools" "$d/tests"
cp "$ROOT/tools/lsan_baseline_check.sh" "$d/tools/" &&
cp "$ROOT/tests/lsan_tolerated_reports.txt" "$d/tests/" ||
    { echo "asan_receipts selftest: INSTRUMENT ERROR, baseline comparator not staged"; exit 2; }
fail=0 n=0
case_() {   # case_ NAME WANT_RC WANT_TEXT FAULT BEARING... (shard 1 claims the extras)
    local name=$1 want=$2 text=$3 fault=$4 k=1 b out rc; shift 4
    rm -rf "$d/shard-receipts"; mkdir "$d/shard-receipts"
    for b in "$@"; do
        { echo "PLAN: shard=$k/3 bearing=$b chunks=$b predicted=1s unmeasured=0"; echo "leaked=0"
          if [ "$k" = 1 ]; then printf 'gc_traversal=yes\nlsp_asan=yes\n'; else printf 'gc_traversal=no\nlsp_asan=no\n'; fi
        } > "$d/shard-receipts/shard-$k.txt"; k=$((k + 1))
    done
    case "$fault" in
        none) ;;
        missing) rm "$d/shard-receipts/shard-3.txt" ;;
        extra) : > "$d/shard-receipts/unexpected.txt" ;;
        hidden) : > "$d/shard-receipts/.unexpected.txt" ;;
        *) echo "asan_receipts selftest: unknown fault '$fault'"; exit 2 ;;
    esac
    out=$(cd "$d" && bash step.sh 2>&1); rc=$?; n=$((n + 1))
    if [ "$rc" = "$want" ] && [[ $out == *"$text"* ]]; then echo "  PASS: $name"
    else echo "  FAIL: $name (rc=$rc, want $want and '$text')"; printf '%s\n' "$out" | tail -3; fail=$((fail + 1)); fi
}
case_ "control: a full split (1+126+122) passes" 0 "Sanitizer coverage complete" none 1 126 122
case_ "three one-chunk shards are not the suite (#1313)" 1 "expected >= 200" none 1 1 1
case_ "a zero-chunk shard is refused" 1 "no header-bearing chunks" none 0 126 122
case_ "a missing receipt is refused" 1 "expected 3 shard receipts, found 2" missing 1 126 122
case_ "an extra file is refused" 1 "expected 3 shard receipts, found 4" extra 1 126 122
case_ "an extra hidden file is refused" 1 "expected 3 shard receipts, found 4" hidden 1 126 122
[ "$n" -eq 6 ] || { echo "asan_receipts selftest: ran $n cases, want 6"; exit 1; }
echo "PLAN: $n"
echo "asan_receipts selftest: $((n - fail)) of $n passed"
[ "$fail" -eq 0 ]
