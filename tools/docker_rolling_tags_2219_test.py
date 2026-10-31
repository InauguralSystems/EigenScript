#!/usr/bin/env python3
"""Regression plants for Docker rolling tags (issue #2219)."""

import os
import pathlib
import subprocess
import sys
import tempfile

def fail(message):
    print(f"FAIL: {message}")
    raise SystemExit(1)


arguments = sys.argv[1:]
if arguments[:1] == ["--selftest"]:
    arguments.pop(0)
workflow = pathlib.Path(arguments[0] if arguments else ".github/workflows/docker.yml")
workflow_text = workflow.read_text(encoding="utf-8")
lines = workflow_text.splitlines()


def step_lines(step_id):
    """Return one workflow step using only the small YAML shape we inspect."""
    id_line = next((index for index, line in enumerate(lines)
                    if line.strip() == f"id: {step_id}"), None)
    if id_line is None:
        return []
    start = id_line
    while start and not lines[start].lstrip().startswith("- "):
        start -= 1
    indent = len(lines[start]) - len(lines[start].lstrip())
    end = start + 1
    while end < len(lines):
        stripped = lines[end].lstrip()
        if stripped.startswith("- ") and len(lines[end]) - len(stripped) == indent:
            break
        end += 1
    return lines[start:end]


rolling_step = step_lines("rolling-tags")
if not rolling_step:
    fail("docker.yml has no rolling-tags tip/version guard")
run_line = next((index for index, line in enumerate(rolling_step)
                 if line.strip() in ("run: |", "run: |-", "run: |+")), None)
if run_line is None:
    fail("rolling-tags guard has no executable script")
run_indent = len(rolling_step[run_line]) - len(rolling_step[run_line].lstrip())
script_lines = []
for line in rolling_step[run_line + 1:]:
    indent = len(line) - len(line.lstrip())
    if line.strip() and indent <= run_indent:
        break
    script_lines.append(line[run_indent + 2:] if line.strip() else "")
script = "\n".join(script_lines)

meta_text = "\n".join(step_lines("meta"))
for output, tag in (("minor", "type=semver,pattern={{major}}.{{minor}}"),
                    ("major", "type=semver,pattern={{major}}"),
                    ("latest", "type=raw,value=latest")):
    expected = f"{tag},enable=${{{{ steps.rolling-tags.outputs.{output} == 'true' }}}}"
    if expected not in meta_text:
        fail(f"steps.meta.outputs.tags does not gate {output} on its checked output")

cases = [
    ("current-main-control", "refs/heads/main", "new", "new", "v0.48.0", {"edge": "true", "minor": "false", "major": "false", "latest": "false"}, "main tip new"),
    ("stale-main-plant", "refs/heads/main", "old", "new", "v0.48.0", {"edge": "false", "minor": "false", "major": "false", "latest": "false"}, "main has moved to new: edge omitted"),
    ("highest-tag-control", "refs/tags/v1.48.0", "tagsha", "new", "v0.47.0 v1.47.0 v1.48.0", {"edge": "false", "minor": "true", "major": "true", "latest": "true"}, "rolling tags enabled: 1.48 1 latest"),
    ("older-line-patch-plant", "refs/tags/v1.47.5", "tagsha", "new", "v0.47.0 v1.47.4 v1.47.5 v1.48.0", {"edge": "false", "minor": "true", "major": "false", "latest": "false"}, "rolling tags enabled: 1.47"),
    ("out-of-order-older-plant", "refs/tags/v1.47.4", "tagsha", "new", "v0.47.0 v1.47.4 v1.47.5 v1.48.0", {"edge": "false", "minor": "false", "major": "false", "latest": "false"}, "newer releases exist: rolling tags omitted"),
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


def named_step_run(name):
    """The run: script of the step whose name is `name` (no id needed)."""
    start = next((i for i, line in enumerate(lines)
                  if line.strip() == f"- name: {name}"), None)
    if start is None:
        return None
    indent = len(lines[start]) - len(lines[start].lstrip())
    end = start + 1
    while end < len(lines):
        stripped = lines[end].lstrip()
        if stripped.startswith("- ") and len(lines[end]) - len(stripped) == indent:
            break
        end += 1
    step = lines[start:end]
    run_at = next((i for i, line in enumerate(step) if line.strip() == "run: |"), None)
    if run_at is None:
        return None
    body = [line for line in step[run_at + 1:]]
    pad = min(len(l) - len(l.lstrip()) for l in body if l.strip())
    return "\n".join(l[pad:] for l in body) + "\n"


# #2278: the promote step hands a raw image reference to `docker buildx
# imagetools create`, which rejects uppercase (repository_owner is
# "InauguralSystems"). A fake docker enforces that rule like the real one.
promote = named_step_run("Promote rolling image tag")
if promote is None:
    fail("promote-image-case: could not find the 'Promote rolling image tag' run script")
with tempfile.TemporaryDirectory() as raw_case:
    case_tmp = pathlib.Path(raw_case)
    case_bin = case_tmp / "bin"
    case_bin.mkdir()
    fake_docker = case_bin / "docker"
    fake_docker.write_text("""#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *@sha256:*)
      repo=${arg%%@*}
      lower=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
      if [ "$repo" != "$lower" ]; then
        echo "ERROR: invalid reference format: repository name ($repo) must be lowercase" >&2
        exit 1
      fi
      echo "promoted $arg" ;;
  esac
done
""", encoding="utf-8")
    fake_docker.chmod(0o755)
    env = dict(os.environ, PATH=f"{case_bin}:{os.environ['PATH']}",
               DIGEST="sha256:" + "0" * 64,
               IMAGE="ghcr.io/InauguralSystems/eigenscript",
               TAGS="ghcr.io/inauguralsystems/eigenscript:edge")
    result = subprocess.run(["bash", "-c", promote], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode or "promoted ghcr.io/inauguralsystems/eigenscript@sha256:" not in result.stdout:
        fail(f"promote-image-case: promote failed for a mixed-case owner:\n{result.stdout}")
    print("PASS: promote-image-case")
print(f"PLAN: {len(cases) + 1}")
