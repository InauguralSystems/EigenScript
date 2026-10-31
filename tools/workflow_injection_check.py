#!/usr/bin/env python3
"""Reject untrusted Actions expressions interpolated into privileged scripts."""

import os
from pathlib import Path
import re
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"workflow-injection: INSTRUMENT ERROR: PyYAML unavailable: {exc}")


ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = Path(os.environ.get("WORKFLOW_INJECTION_WORKFLOWS", ROOT / ".github/workflows"))
ACTIONS = Path(os.environ.get("WORKFLOW_INJECTION_ACTIONS", ROOT / ".github/actions"))
EXPRESSION = re.compile(r"\$\{\{\s*(inputs\.|steps\.[\w-]+\.outputs\.|github\.event(?:\.|\[))", re.I)


def can_write(permissions):
    if permissions is None or permissions == "write-all":
        return True  # Repository defaults are not mechanically knowable.
    return isinstance(permissions, dict) and "write" in permissions.values()


def run_scalars(node, path=()):
    """Yield (path, scalar) for YAML run keys, preserving source marks."""
    if isinstance(node, yaml.MappingNode):
        for key, value in node.value:
            name = key.value
            if name == "run" and isinstance(value, yaml.ScalarNode):
                yield path + (name,), value
            yield from run_scalars(value, path + (name,))
    elif isinstance(node, yaml.SequenceNode):
        for index, value in enumerate(node.value):
            yield from run_scalars(value, path + (str(index),))


def inspect_file(path, only_jobs=None):
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        syntax = yaml.compose(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        print(f"workflow-injection: INSTRUMENT ERROR: cannot load {path}: {exc}")
        return 2, 0
    bad = 0
    for keys, scalar in run_scalars(syntax):
        if only_jobs is not None:
            if len(keys) < 2 or keys[0] != "jobs" or keys[1] not in only_jobs:
                continue
        for offset, line in enumerate(scalar.value.splitlines()):
            hit = EXPRESSION.search(line)
            if hit:
                # Block-scalar content starts on the line after the YAML `run:` key.
                line_number = scalar.start_mark.line + 2 + offset
                print(f"RED: {path}:{line_number}: privileged run interpolates {hit.group(1)} free text: {line.strip()}")
                bad += 1
    return (1 if bad else 0), bad


def main():
    if len(sys.argv) != 1:
        print("usage: tools/workflow_injection_check.py", file=sys.stderr)
        return 2
    workflow_files = sorted((*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")))
    action_files = sorted((*ACTIONS.glob("**/action.yml"), *ACTIONS.glob("**/action.yaml")))
    if not workflow_files or not ACTIONS.is_dir():
        print("workflow-injection: INSTRUMENT ERROR: workflow/action population is missing")
        return 2
    total_bad = 0
    for path in workflow_files:
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except (OSError, yaml.YAMLError) as exc:
            print(f"workflow-injection: INSTRUMENT ERROR: cannot load {path}: {exc}")
            return 2
        jobs = doc.get("jobs") or {}
        workflow_permissions = doc.get("permissions")
        writers = {
            str(job_id) for job_id, job in jobs.items()
            if isinstance(job, dict) and can_write(job.get("permissions", workflow_permissions))
        }
        rc, count = inspect_file(path, writers)
        if rc == 2:
            return rc
        total_bad += count
    # Composite actions inherit their caller's token and can be called by a writer;
    # reject the dangerous boundary in every local action rather than maintaining a
    # fallible hand-written caller list.
    for path in action_files:
        rc, count = inspect_file(path)
        if rc == 2:
            return rc
        total_bad += count
    examined = len(workflow_files) + len(action_files)
    if total_bad:
        print(f"workflow-injection: FAIL: {total_bad} violation(s), {examined} YAML files examined")
        return 1
    print(f"workflow-injection: OK: {len(workflow_files)} workflows and {len(action_files)} actions examined; no privileged run interpolates untrusted free text")
    return 0


if __name__ == "__main__":
    sys.exit(main())
