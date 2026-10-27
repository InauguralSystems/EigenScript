#!/usr/bin/env python3
"""Derive executable-enrolment edges from repository source files.

The output is ``source<TAB>destination``.  It deliberately describes a graph,
rather than merely grepping for names: only nodes reachable from a suite or CI
root are enrolled.
"""

from __future__ import annotations

import ast
import re
import shlex
import sys
from pathlib import Path


ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()


def rel(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def emit(src: str, dst: str) -> None:
    print(f"{src}\t{dst}")


def executable_path(word: str, source: Path) -> str | None:
    word = word.strip("'\"").replace("${PWD}", ".").replace("$PWD", ".")
    word = re.sub(r"^\$\{?(?:TESTS_DIR|TOOLS_DIR)\}?/", lambda m: "tests/" if "TEST" in m.group() else "tools/", word)
    if not word.endswith((".sh", ".py")):
        return None
    if word.startswith("./"):
        word = word[2:]
    if word.startswith("../") and source.parent.as_posix() != ".":
        word = (source.parent / word).as_posix()
    word = re.sub(r"^.*/(?=(?:tests|tools|bench)/)", "", word)
    if word.startswith(("tests/", "tools/", "bench/")) and (ROOT / word).is_file():
        return word
    # A bare path in a script resolves beside that script; a workflow resolves
    # at repository root.
    beside = source.parent / word
    if source.parts and source.parts[0] != ".github" and (ROOT / beside).is_file():
        return beside.as_posix()
    if (ROOT / word).is_file():
        return word
    if "/" not in word:
        matches = [p for base in ("tests", "tools", "bench") for p in (ROOT / base).rglob(word)]
        if len(matches) == 1:
            return rel(matches[0])
    return None


def shell_edges(source: Path, text: str, src_name: str | None = None) -> None:
    src = src_name or source.as_posix()
    # Newlines and shell control operators delimit commands.  This is a
    # conservative command-word parser, not a claim that comments mentioning a
    # script execute it.
    logical = re.sub(r"\\\n\s*", " ", text)
    for raw in logical.splitlines():
        raw = re.sub(r"^\s*(?:-\s*)?run:\s*", "", raw)
        try:
            parts = re.split(r"(?:&&|\|\||[;|`])", raw)
            for part in parts:
                words = shlex.split(part, comments=True)
                while words and (re.match(r"^[A-Za-z_]\w*=", words[0]) or words[0] in {"if", "then", "elif", "else", "do", "while", "until", "time", "!", "{", "env", "command", "exec", "nohup", "sudo", "xvfb-run"}):
                    words.pop(0)
                if words and words[0] == "timeout":
                    words.pop(0)
                    while words and (words[0].startswith("-") or re.match(r"^\d+(?:\.\d+)?[smhd]?$", words[0])):
                        words.pop(0)
                if not words:
                    continue
                if words[0] in {"bash", "sh", "dash", "python", "python3", "source", "."}:
                    words.pop(0)
                    while words and words[0].startswith("-"):
                        words.pop(0)
                if words:
                    dst = executable_path(words[0], source)
                    if dst:
                        emit(src, dst)
        except ValueError:
            continue


def python_edges(source: Path, text: str) -> None:
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return
    src = source.as_posix()
    for node in ast.walk(tree):
        names: list[str] = []
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module:
            names = [node.module]
        for name in names:
            path = name.replace(".", "/") + ".py"
            init = name.replace(".", "/") + "/__init__.py"
            if (ROOT / path).is_file():
                emit(src, path)
            elif (ROOT / init).is_file():
                emit(src, init)
            else:
                matches = list((ROOT / "tools").glob(name.rsplit(".", 1)[-1] + ".py"))
                if len(matches) == 1:
                    emit(src, rel(matches[0]))
        # subprocess argv is conventionally a literal sequence.  Following
        # only calls (not arbitrary strings) avoids enrolling documentation.
        if isinstance(node, ast.Call):
            # Includes importlib.spec_from_file_location(ROOT / "tools/x.py")
            # as well as subprocess argv literals.
            for item in ast.walk(node):
                if isinstance(item, ast.Constant) and isinstance(item.value, str):
                    dst = executable_path(item.value, source)
                    if dst:
                        emit(src, dst)


def expand(value: str, variables: dict[str, str]) -> str:
    old = None
    while old != value:
        old = value
        value = re.sub(r"\$\(([^)]+)\)", lambda m: variables.get(m.group(1), m.group(0)), value)
    return value


def make_edges(path: Path) -> None:
    logical: list[str] = []
    carry = ""
    for line in path.read_text(errors="replace").splitlines():
        carry += line
        if carry.endswith("\\"):
            carry = carry[:-1] + " "
        else:
            logical.append(carry)
            carry = ""
    variables: dict[str, str] = {}
    for line in logical:
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*(.*)$", line)
        if match:
            variables[match.group(1)] = expand(match.group(2).strip(), variables)
    current: list[str] = []
    for line in logical:
        if line.startswith("\t") and current:
            for target in current:
                shell_edges(path, line[1:], f"@make:{target}")
            continue
        if line.startswith((" ", "#")) or ":" not in line or re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*:?=", line):
            current = []
            continue
        lhs, rhs = line.split(":", 1)
        current = expand(lhs.strip(), variables).split()
        prereqs = expand(rhs.split(";", 1)[0], variables).split()
        for target in current:
            for dep in prereqs:
                if "%" not in dep:
                    emit(f"@make:{target}", f"@make:{dep}")
        if ";" in rhs:
            for target in current:
                shell_edges(path, rhs.split(";", 1)[1], f"@make:{target}")


sources: set[Path] = set()
for directory in ("tests", "tools", "bench"):
    base = ROOT / directory
    if base.exists():
        sources.update(p.relative_to(ROOT) for p in base.rglob("*") if p.is_file() and p.suffix in {".sh", ".py"})
workflows = ROOT / ".github/workflows"
if workflows.exists():
    sources.update(p.relative_to(ROOT) for p in workflows.glob("*.yml"))
    sources.update(p.relative_to(ROOT) for p in workflows.glob("*.yaml"))
github = ROOT / ".github"
if github.exists():
    sources.update(p.relative_to(ROOT) for p in github.rglob("*.yml"))
    sources.update(p.relative_to(ROOT) for p in github.rglob("*.yaml"))

for source in sorted(sources):
    text = (ROOT / source).read_text(errors="replace")
    shell_edges(source, text)
    if source.suffix == ".py":
        python_edges(source, text)
    if source.parts[:1] == ("tools",) and len(source.parts) > 2:
        # A tools/<dir>/ package is enrolled when one of its executable
        # members is reached.  The package directory itself is the candidate.
        emit(source.as_posix(), "/".join(source.parts[:2]))
    if source.parts and source.parts[0] == ".github":
        for action in re.findall(r"uses:\s*\./([^\s#]+)", text):
            target = Path(action)
            if (ROOT / target).is_dir():
                target /= "action.yml"
            if (ROOT / target).is_file():
                emit(source.as_posix(), target.as_posix())

makefile = ROOT / "Makefile"
if makefile.is_file():
    make_edges(makefile)

# A workflow make command enters the corresponding Make dependency graph.
for workflow in sorted(p for p in sources if p.parts[:2] == (".github", "workflows")):
    for line in (ROOT / workflow).read_text(errors="replace").splitlines():
        match = re.search(r"(?:^|[;&|]\s*|run:\s*)make(?:\s+-[A-Za-z]+)*\s+([^#;&|]+)", line)
        if not match:
            continue
        for word in shlex.split(match.group(1)):
            if "=" not in word and not word.startswith("-"):
                emit(workflow.as_posix(), f"@make:{word}")
