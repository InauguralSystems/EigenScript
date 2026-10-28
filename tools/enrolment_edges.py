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

import yaml

from _python_execution import EXECUTION_CALL_NAMES, name_of
from _derive_variants import shell_lines


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


def eigs_program_path(word: str, source: Path) -> str | None:
    """Resolve a literal .eigs program operand, without treating mentions as runs."""
    word = word.strip("'\"")
    word = re.sub(r"^\$\{?(?:TESTS_DIR)\}?/", "tests/", word)
    word = re.sub(r"^\$\{?(?:ROOT)\}?/", "", word)
    word = re.sub(r"^.*/(?=tests/)", "", word)
    if word.startswith("./"):
        word = word[2:]
    if not word.endswith(".eigs"):
        return None
    candidates = [Path(word), source.parent / word]
    if "/" not in word:
        candidates.append(Path("tests") / word)
    for candidate in candidates:
        if (ROOT / candidate).is_file():
            return candidate.as_posix()
    return None


def _substitutions(words):
    """Commands run by a `$(...)` embedded in the words of one command.

    `x=$("$TESTS_DIR/../tools/t.sh" arg)` is one shlex word starting with an
    assignment, so the caller would discard it as an env prefix; the command it
    substitutes still executes and is an edge (#1679's resolver call)."""
    for i, w in enumerate(words):
        if "$(" not in w:
            continue
        sub = [w.split("$(")[-1]] + list(words[i + 1:])
        for j, x in enumerate(sub):
            if x.endswith(")"):
                sub = sub[:j + 1]
                sub[-1] = sub[-1].rstrip(")")
                break
        sub = [x for x in sub if x]
        if sub:
            yield sub


def shell_commands(text: str):
    """Yield shell simple commands with wrappers removed."""
    logical = re.sub(r"\\\n\s*", " ", text)
    for _, raw in shell_lines(logical):
        try:
            parts, start, quote, escaped = [], 0, None, False
            i = 0
            while i < len(raw):
                char = raw[i]
                if escaped:
                    escaped = False
                elif char == "\\" and quote != "'":
                    escaped = True
                elif quote:
                    if char == quote:
                        quote = None
                elif char in "'\"":
                    quote = char
                elif char in ";|`" or raw[i:i + 2] == "&&":
                    parts.append(raw[start:i]); i += 1 if raw[i:i + 2] == "&&" else 0; start = i + 1
                i += 1
            parts.append(raw[start:])
            for part in parts:
                words = shlex.split(part, comments=True)
                yield from _substitutions(words)
                while words and (re.match(r"^[A-Za-z_]\w*=", words[0]) or words[0] in {"if", "then", "elif", "else", "do", "while", "until", "time", "!", "{", "command", "exec", "nohup", "sudo", "xvfb-run"}):
                    words.pop(0)
                if words and words[0] == "env":
                    words.pop(0)
                    while words and (words[0].startswith("-")
                                     or re.match(r"^[A-Za-z_]\w*=", words[0])
                                     or (re.match(r'^\$\{?[A-Za-z_]\w*(?:\[@\])?\}?$', words[0])
                                         and words[0] not in {"$EIGS", "${EIGS}"})):
                        words.pop(0)
                if words and words[0] == "timeout":
                    words.pop(0)
                    while words and (words[0].startswith("-") or re.match(r"^\d+(?:\.\d+)?[smhd]?$", words[0])):
                        words.pop(0)
                if words:
                    yield words
        except ValueError:
            continue


def normalized_command_index(words: list[str]) -> int:
    """Return the command position after the suite's recognized wrappers.

    The suite has a small set of launch helpers whose leading operands are
    metadata rather than commands.  Walk only those documented shapes; never
    search arbitrary arguments, since diagnostics may mention both EIGS and a
    test without executing either.
    """
    metadata = {
        "suite_program_run": 1,
        "suite_capture_diagnostic": 1,
        "run_test": 1,
        "run_clean": 2,
        "run_bounded": 1,
        "gfx_headless_run": 1,
    }
    i = 1 + metadata.get(words[0], -1)
    while i < len(words) and re.match(r"^[A-Za-z_]\w*=", words[i]):
        i += 1
    if i < len(words) and words[i] == "$EIGS_TMO":
        i += 1
    if i < len(words) and words[i] == "env":
        i += 1
        while i < len(words) and (
            words[i].startswith("-")
            or re.match(r"^[A-Za-z_]\w*=", words[i])
            or (words[i].startswith("$") and "[@]" in words[i])
            or (re.match(r'^\$[A-Za-z_]\w*$', words[i])
                and words[i] not in {"$EIGS", "${EIGS}"})
        ):
            i += 1
    return i


def shell_edges(source: Path, text: str, src_name: str | None = None) -> None:
    src = src_name or source.as_posix()
    # Newlines and shell control operators delimit commands.  This is a
    # conservative command-word parser, not a claim that comments mentioning a
    # script execute it.
    for words in shell_commands(text):
        # An asserting fixture is invoked only when it is the program operand
        # of EigenScript.  Globs and text passed to a differential are not
        # expanded here, deliberately.
        invocation = list(words)
        command_at = normalized_command_index(invocation)
        command = invocation[command_at] if command_at < len(invocation) else ""
        if command in {"$EIGS", "${EIGS}"} or command.rstrip("/").endswith("/eigenscript"):
            operands = [word for word in invocation[command_at + 1:] if not word.startswith("-")]
            if operands:
                dst = eigs_program_path(operands[0], source)
                if dst:
                    emit(src, dst)
        elif command == "check_eigs_suite":
            # The first operand is the human-readable check description.
            for word in invocation[command_at + 2:]:
                dst = eigs_program_path(word, source)
                if dst:
                    emit(src, dst)
                    break
        if words[0] in {"bash", "sh", "dash", "python", "python3", "source", "."}:
            words = words[1:]
            while words and words[0].startswith("-"):
                words.pop(0)
        if words:
            dst = executable_path(words[0], source)
            if dst:
                emit(src, dst)


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
        if isinstance(node, ast.Call):
            fname = name_of(node.func)
            args = []
            if fname in EXECUTION_CALL_NAMES and node.args:
                first = node.args[0]
                if isinstance(first, (ast.List, ast.Tuple)):
                    # Every element is an argv position.  This includes the
                    # script after sys.executable/a Python name or bash, and
                    # operands consumed by `bash -c` snippets.
                    args = list(first.elts)
                elif isinstance(first, ast.Constant) and isinstance(first.value, str):
                    shell_edges(source, first.value, src)
            elif fname == "spec_from_file_location" and len(node.args) >= 2:
                args = [node.args[1]]
            elif fname == "run_path" and node.args:
                args = [node.args[0]]
            for arg in args:
                for item in ast.walk(arg):
                    if isinstance(item, ast.Constant) and isinstance(item.value, str):
                        dst = executable_path(item.value, source)
                        if dst:
                            emit(src, dst)


def yaml_run_commands(source: Path):
    """Yield only YAML values of `run` keys, as parsed by YAML."""
    data = yaml.safe_load((ROOT / source).read_text(errors="replace"))

    def walk(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "run" and isinstance(child, str):
                    yield child
                else:
                    yield from walk(child)
        elif isinstance(value, list):
            for child in value:
                yield from walk(child)

    yield from walk(data)


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
    if source.parts and source.parts[0] == ".github":
        for command in yaml_run_commands(source):
            shell_edges(source, command)
    else:
        shell_edges(source, text)
        # A malformed/unusual heredoc elsewhere in a large suite driver must
        # not hide later commands from enrolment extraction.  Re-run the same
        # command parser on short source windows; this is intentionally the
        # same matcher, not a filename grep (plain mentions still emit no edge).
        if source == Path("tests/run_all_tests.sh"):
            source_lines = text.splitlines()
            for i in range(len(source_lines)):
                shell_edges(source, "\n".join(source_lines[i:i + 3]))
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
    for command in yaml_run_commands(workflow):
        for words in shell_commands(command):
            if not words or words[0] != "make":
                continue
            for word in words[1:]:
                if "=" not in word and not word.startswith("-"):
                    emit(workflow.as_posix(), f"@make:{word}")
