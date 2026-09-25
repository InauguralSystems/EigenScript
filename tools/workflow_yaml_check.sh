#!/bin/bash
# Every file under .github/workflows/ must LOAD as YAML and carry a top-level
# jobs: mapping (#1207). Round 1 shipped an unquoted step name containing `: `,
# which GitHub rejects; reading the file is not loading it. A missing PyYAML,
# or zero files, is RED — a skip is not a pass. A load is not GitHub's schema.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF_DIR="${WORKFLOW_CHECK_DIR:-$ROOT/.github/workflows}"
exec 0</dev/null
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "workflow-yaml: RED: PyYAML is not importable, so nothing in $WF_DIR was loaded. This is not a pass."
    exit 1
fi
out=$(WF_DIR="$WF_DIR" python3 - <<'PY'
import glob, os, sys, yaml
d = os.environ["WF_DIR"]
files = sorted(set(glob.glob(os.path.join(d, "*.yml")) + glob.glob(os.path.join(d, "*.yaml"))))
sys.stdout.write("EXAMINED %d\n" % len(files))
bad = 0
for f in files:
    try:
        with open(f, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:
        sys.stdout.write("RED: %s: %s\n" % (f, str(exc).replace("\n", " ")[:200]))
        bad += 1
        continue
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
        sys.stdout.write("RED: %s: loaded, but no top-level jobs: mapping\n" % f)
        bad += 1
sys.exit(1 if bad else 0)
PY
)
pyrc=$?
examined=$(printf '%s\n' "$out" | sed -n 's/^EXAMINED //p' | head -1)
examined=${examined:-0}
printf '%s\n' "$out" | grep '^RED:' || true
if [ "$pyrc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q '^RED:'; then
    echo "workflow-yaml: RED: the YAML loader failed on $WF_DIR"
    exit 1
fi
if [ "$examined" -eq 0 ]; then
    echo "workflow-yaml: RED: examined 0 workflow files in $WF_DIR — an empty population loaded nothing"
    exit 1
fi
if [ "$pyrc" -ne 0 ]; then
    n=$(printf '%s\n' "$out" | grep -c '^RED:')
    echo "workflow-yaml: FAIL (examined=$examined file(s), loader=pyyaml, problems=$n)"
    exit 1
fi
echo "workflow-yaml: OK (examined=$examined file(s), loader=pyyaml)"
exit 0
