#!/bin/bash
# Every .github/workflows file must LOAD as YAML with a top-level jobs:
# mapping, and every present workflow, job, and step name must be a string
# (#1207). No PyYAML, or zero files, is RED — a skip is not a pass.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF_DIR="${WORKFLOW_CHECK_DIR:-$ROOT/.github/workflows}"
exec 0</dev/null
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "workflow-yaml: RED: PyYAML is not importable, so nothing in $WF_DIR was loaded. This is not a pass. Install it: apt install python3-yaml, or python3 -m pip install --user pyyaml."
    exit 1
fi
out=$(WF_DIR="$WF_DIR" python3 - <<'PY'
import glob, os, sys, yaml
d = os.environ["WF_DIR"]
files = sorted(set(glob.glob(os.path.join(d, "*.yml")) + glob.glob(os.path.join(d, "*.yaml"))))
sys.stdout.write("EXAMINED %d\n" % len(files))
bad = 0
def note(f, path, val):
    global bad
    if isinstance(val, str): return
    sys.stdout.write("RED: %s: %s is %s, not a string\n" % (f, path, type(val).__name__)); bad += 1
for f in files:
    try:
        with open(f, encoding="utf-8") as fh: doc = yaml.safe_load(fh)
    except Exception as exc:
        sys.stdout.write("RED: %s: %s\n" % (f, str(exc).replace("\n", " ")[:200])); bad += 1; continue
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
        sys.stdout.write("RED: %s: loaded, but no top-level jobs: mapping\n" % f); bad += 1; continue
    if "name" in doc: note(f, "name", doc.get("name"))
    for jid, job in doc["jobs"].items():
        if not isinstance(job, dict): continue
        if "name" in job: note(f, "jobs.%s.name" % jid, job.get("name"))
        steps = job.get("steps") if isinstance(job.get("steps"), list) else []
        for i, st in enumerate(steps):
            if isinstance(st, dict) and "name" in st:
                note(f, "jobs.%s.steps[%d].name" % (jid, i), st.get("name"))
sys.exit(1 if bad else 0)
PY
)
pyrc=$?
examined=$(printf '%s\n' "$out" | sed -n 's/^EXAMINED //p' | head -1); examined=${examined:-0}
printf '%s\n' "$out" | grep '^RED:' || true
if [ "$pyrc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q '^RED:'; then
    echo "workflow-yaml: RED: the YAML loader failed on $WF_DIR"; exit 1
fi
if [ "$examined" -eq 0 ]; then
    echo "workflow-yaml: RED: examined 0 workflow files in $WF_DIR — an empty population loaded nothing"; exit 1
fi
if [ "$pyrc" -ne 0 ]; then
    echo "workflow-yaml: FAIL (examined=$examined file(s), loader=pyyaml, problems=$(printf '%s\n' "$out" | grep -c '^RED:'))"
    exit 1
fi
echo "workflow-yaml: OK (examined=$examined file(s), loader=pyyaml)"
exit 0
