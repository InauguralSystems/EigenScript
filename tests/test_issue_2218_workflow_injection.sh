#!/bin/bash
# Regression/self-test for issue #2218: a clean fixture must pass before the
# exact release.yml inline-input fault is planted and specifically rejected.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" != --selftest ] || [ "$#" -ne 1 ]; then
    echo "usage: tests/test_issue_2218_workflow_injection.sh --selftest" >&2
    exit 2
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/issue-2218.XXXXXX") || exit 2
trap 'rm -rf "$scratch"' EXIT

# Exercise the real release step with the audit payload. Expressions have
# already been resolved into env by Actions at this boundary; bash must see the
# value only as data, reject it, and emit neither a tag nor payload output.
python3 - "$ROOT/.github/workflows/release.yml" > "$scratch/determine-tag.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
print(next(step for step in doc["jobs"]["tag"]["steps"]
           if step.get("name") == "Determine release tag")["run"])
PY
payload='0.99.0"; echo INJECTED-as-$(id -un) >&2; VER="0.99.0'
GITHUB_OUTPUT="$scratch/payload.output" EVENT_NAME=workflow_dispatch VERSION_INPUT="$payload" \
    bash "$scratch/determine-tag.sh" > "$scratch/payload.log" 2>&1
payload_rc=$?
if [ "$payload_rc" -ne 1 ] || ! grep -q '^::error::release version must match ' "$scratch/payload.log" \
        || grep -q INJECTED "$scratch/payload.log" || [ -s "$scratch/payload.output" ]; then
    cat "$scratch/payload.log"
    echo "FAIL: issue 2218 dispatch payload was not safely rejected"
    exit 1
fi
echo "PASS: issue 2218 dispatch payload exits 1 with ::error and no injection"

GITHUB_OUTPUT="$scratch/valid.output" EVENT_NAME=workflow_dispatch VERSION_INPUT=v1.23.456 \
    bash "$scratch/determine-tag.sh" > "$scratch/valid.log" 2>&1
valid_rc=$?
if [ "$valid_rc" -ne 0 ] || [ "$(cat "$scratch/valid.output")" != tag=v1.23.456 ]; then
    cat "$scratch/valid.log"; cat "$scratch/valid.output"
    echo "FAIL: issue 2218 valid semantic version was rejected"
    exit 1
fi
echo "PASS: issue 2218 valid v-prefixed semantic version emits its tag"

mkdir -p "$scratch/workflows" "$scratch/actions/example"
cat > "$scratch/workflows/release.yml" <<'YAML'
name: fixture
permissions: {contents: read}
jobs:
  tag:
    permissions: {contents: write}
    steps:
      - name: Determine release tag
        env:
          VERSION_INPUT: ${{ inputs.version }}
        run: printf '%s\n' "$VERSION_INPUT"
YAML
cat > "$scratch/actions/example/action.yml" <<'YAML'
name: fixture action
runs:
  using: composite
  steps:
    - shell: bash
      run: printf '%s\n' "$SAFE_VALUE"
YAML
run_gate() {
    WORKFLOW_INJECTION_WORKFLOWS="$scratch/workflows" \
    WORKFLOW_INJECTION_ACTIONS="$scratch/actions" \
        python3 "$ROOT/tools/workflow_injection_check.py"
}
control=$(run_gate 2>&1); control_rc=$?
if [ "$control_rc" -ne 0 ] || ! printf '%s\n' "$control" | grep -q 'workflow-injection: OK:'; then
    printf '%s\n' "$control"
    echo "FAIL: issue 2218 clean env-bound control was rejected"
    exit 1
fi
echo "PASS: issue 2218 clean env-bound control passes"

python3 - "$scratch/workflows/release.yml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('run: printf \'%s\\n\' "$VERSION_INPUT"', 'run: |\n          VER="${{ inputs.version }}"\n          printf \'%s\\n\' "$VER"')
p.write_text(s)
PY
plant=$(run_gate 2>&1); plant_rc=$?
if [ "$plant_rc" -ne 1 ] || ! printf '%s\n' "$plant" | grep -q 'privileged run interpolates inputs\. free text'; then
    printf '%s\n' "$plant"
    echo "FAIL: issue 2218 planted release input interpolation was not specifically rejected"
    exit 1
fi
printf '%s\n' "$plant"
echo "PASS: issue 2218 planted release line 37 turns the gate red"
