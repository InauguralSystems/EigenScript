#!/usr/bin/env python3
"""Reject untrusted Actions expressions interpolated into privileged scripts."""

import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = Path(os.environ.get("WORKFLOW_INJECTION_WORKFLOWS", ROOT / ".github/workflows"))
ACTIONS = Path(os.environ.get("WORKFLOW_INJECTION_ACTIONS", ROOT / ".github/actions"))
EXPRESSION = re.compile(r"\$\{\{\s*(inputs\.|steps\.[\w-]+\.outputs\.|github\.event(?:\.|\[))", re.I)
KEY = re.compile(r"^( *)(?:- )?([\w-]+):(?:\s*(.*?))?\s*$")
WRITE = re.compile(r"(?:^|[,{\s])(?:[\w-]+\s*:\s*)?write(?:[\s,}]|$)", re.I)


def indentation(line):
    return len(line) - len(line.lstrip(" "))


def permission_writes(lines, start, indent, inherited=True):
    """Return whether the mapping at start has a write-capable permissions key."""
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        current = indentation(line)
        if start >= 0 and current <= indent:
            break
        match = KEY.match(line)
        if not match or current != indent + 2 or match.group(2) != "permissions":
            continue
        value = (match.group(3) or "").split("#", 1)[0].strip()
        if value:
            return value == "write-all" or bool(WRITE.search(value))
        for child in lines[index + 1:]:
            if not child.strip() or child.lstrip().startswith("#"):
                continue
            child_indent = indentation(child)
            if child_indent <= current:
                break
            if child_indent == current + 2 and re.search(r":\s*write(?:\s*#.*)?$", child, re.I):
                return True
        return False
    return inherited


def workflow_writers(lines):
    """Return job ids whose effective token permissions may write."""
    jobs_line = next((i for i, line in enumerate(lines) if re.match(r"^jobs:\s*(?:#.*)?$", line)), None)
    if jobs_line is None:
        return set()
    workflow_write = permission_writes(lines[:jobs_line], -1, -2)
    writers = set()
    for index in range(jobs_line + 1, len(lines)):
        line = lines[index]
        if line.strip() and indentation(line) == 0:
            break
        match = re.match(r"^  ([\w-]+):\s*(?:#.*)?$", line)
        if match and permission_writes(lines, index, 2, workflow_write):
            writers.add(match.group(1))
    return writers


def run_lines(lines):
    """Yield (line number, text, containing job) for inline/block run values."""
    job = None
    in_jobs = False
    for index, line in enumerate(lines):
        if re.match(r"^jobs:\s*(?:#.*)?$", line):
            in_jobs = True
        elif line and not line.startswith(" "):
            in_jobs = False
            job = None
        if in_jobs:
            match = re.match(r"^  ([\w-]+):\s*(?:#.*)?$", line)
            if match:
                job = match.group(1)
        match = re.match(r"^( *)(?:- )?run:\s*(.*)$", line)
        if not match:
            continue
        value = match.group(2).strip()
        if value not in ("|", ">", "|-", ">-", "|+", ">+"):
            yield index + 1, value, job
            continue
        base = len(match.group(1))
        for child_index in range(index + 1, len(lines)):
            child = lines[child_index]
            if child.strip() and indentation(child) <= base:
                break
            yield child_index + 1, child.strip(), job


def inspect_file(path, writers=None):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        print(f"workflow-injection: INSTRUMENT ERROR: cannot read {path}: {exc}")
        return 2, 0
    bad = 0
    for line_number, line, job in run_lines(lines):
        if writers is not None and job not in writers:
            continue
        hit = EXPRESSION.search(line)
        if hit:
            print(f"RED: {path}:{line_number}: privileged run interpolates {hit.group(1)} free text: {line}")
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
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            print(f"workflow-injection: INSTRUMENT ERROR: cannot read {path}: {exc}")
            return 2
        rc, count = inspect_file(path, workflow_writers(lines))
        if rc == 2:
            return rc
        total_bad += count
    # Composite actions inherit their caller's token; inspect every local one.
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
