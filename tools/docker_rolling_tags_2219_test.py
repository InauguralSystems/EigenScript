#!/usr/bin/env python3
"""Regression plants for Docker rolling tags (issue #2219)."""

import os
import pathlib
import subprocess
import sys
import tempfile

import yaml


def fail(message):
    print(f"FAIL: {message}")
    raise SystemExit(1)


arguments = sys.argv[1:]
if arguments[:1] == ["--selftest"]:
    arguments.pop(0)
workflow = pathlib.Path(arguments[0] if arguments else ".github/workflows/docker.yml")
document = yaml.safe_load(workflow.read_text(encoding="utf-8"))
steps = document["jobs"]["build"]["steps"]
step = next((item for item in steps if item.get("id") == "rolling-tags"), None)
if step is None:
    fail("docker.yml has no rolling-tags tip/version guard")
script = step.get("run", "")
if not script:
    fail("rolling-tags guard has no executable script")
meta = next((item for item in steps if item.get("id") == "meta"), None)
meta_tags = ((meta or {}).get("with") or {}).get("tags", "")
if "value=latest,enable=${{ steps.rolling-tags.outputs.latest == 'true' }}" not in meta_tags:
    fail("steps.meta.outputs.tags does not gate latest on the checked output")

cases = [
    ("current-main-control", "refs/heads/main", "new", "new", "v0.48.0", {"edge": "true", "latest": "false"}, "main tip new"),
    ("stale-main-plant", "refs/heads/main", "old", "new", "v0.48.0", {"edge": "false", "latest": "false"}, "main has moved to new: edge omitted"),
    ("highest-tag-control", "refs/tags/v0.48.0", "tagsha", "new", "v0.47.0 v0.48.0", {"edge": "false", "latest": "true"}, "highest release v0.48.0"),
    ("older-tag-plant", "refs/tags/v0.47.0", "tagsha", "new", "v0.47.0 v0.48.0", {"edge": "false", "latest": "false"}, "newer release v0.48.0 exists: latest omitted"),
]

with tempfile.TemporaryDirectory(prefix="docker-tags-2219-") as raw:
    tmp = pathlib.Path(raw)
    fakebin = tmp / "bin"
    fakebin.mkdir()
    git = fakebin / "git"
    git.write_text("""#!/bin/sh
if [ "$1 $2 $3" = "ls-remote origin refs/heads/main" ]; then
  printf '%s\\trefs/heads/main\\n' "$TIP"
elif [ "$1 $2 $3" = "ls-remote --tags --refs" ] && [ "$4" = "origin" ] && [ "$5" = "v*" ]; then
  for tag in $TAGS; do printf 'deadbeef\\trefs/tags/%s\\n' "$tag"; done
else
  echo "unexpected git invocation: $*" >&2; exit 97
fi
""", encoding="utf-8")
    git.chmod(0o755)
    for name, ref, sha, tip, tags, expected, marker in cases:
        output = tmp / f"{name}.out"
        env = dict(os.environ, PATH=f"{fakebin}:{os.environ['PATH']}", GITHUB_REF=ref,
                   SHA=sha, TIP=tip, TAGS=tags, GITHUB_OUTPUT=str(output))
        result = subprocess.run(["bash", "-c", script], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            fail(f"{name} guard exited {result.returncode}:\n{result.stdout}")
        values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
        if values != expected or marker not in result.stdout:
            fail(f"{name}: outputs={values!r}, log={result.stdout!r}")
        print(f"PASS: {name}")
print(f"PLAN: {len(cases)}")
