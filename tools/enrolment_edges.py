#!/usr/bin/env python3
"""Derive executable-enrolment edges from repository source files.

The output is ``source<TAB>destination``.  It deliberately describes a graph,
rather than merely grepping for names: only nodes reachable from a suite or CI
root are enrolled.
"""

from __future__ import annotations

import ast
import re
import sys
from functools import lru_cache
from pathlib import Path

import yaml

from _python_execution import EXECUTION_CALL_NAMES, name_of
from _shell_tokens import (TokenizerGap, function_definitions, simple_commands,
                           tokenize_file, tokenize_prefix, unquote)


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


def shell_commands(text: str):
    """Yield fresh command lists: every simple command TEXT runs, substitution
    bodies included, read by the shared tokenizer (tools/_shell_tokens.py,
    checked against bash by tools/shell_oracle.py).  Here-document bodies,
    comments and redirection targets are not command words."""
    for words in _commands(text):
        yield list(words)


@lru_cache(maxsize=8192)
def _commands(text: str) -> tuple[tuple[str, ...], ...]:
    """Cache only pure parsing, never filesystem lookups or mutable generators.

    Suite recovery windows overlap and repeat command text; the same text
    always parses identically.  Callers receive fresh lists so removing
    launcher options cannot mutate a later cache hit.
    """
    commands = []
    tokens = tokenize_prefix(text)
    # A substitution body is shell wherever it sits, quoted or not.
    for tok in tokens:
        for body in tok.subst:
            commands.extend(_commands(body))
    for cmd in simple_commands(tokens):
        words = [unquote(t.text) for t in cmd]
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
            commands.append(tuple(words))
    return tuple(commands)


def normalized_command_index(words: list[str], defined: frozenset[str]) -> int:
    """Return the command position after the suite's recognized wrappers.

    The suite has a small set of launch helpers whose leading operands are
    metadata rather than commands.  Walk only those documented shapes; never
    search arbitrary arguments, since diagnostics may mention both EIGS and a
    test without executing either.
    """
    metadata = {
        "suite_program_run": 1,
        "suite_capture_diagnostic": 1,
        "run_bounded": 1,
        "gfx_headless_run": 1,
    }
    # A helper is a launcher only where it is DEFINED (hq#58): [1a7] called
    # `run_test`, a name on this table that nothing defines, so the edge was
    # emitted while bash printed "command not found" and the program never ran.
    if words[0] in metadata and words[0] not in defined:
        return 0
    i = 1 + metadata.get(words[0], -1)
    # Phase 2 launchers may be nested. Apply main's definition-scope rule to
    # each further wrapper rather than treating its metadata as a command.
    while i < len(words) and words[i] in metadata:
        if words[i] not in defined:
            return i
        i += 1 + metadata[words[i]]
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


_file_info: dict[Path, tuple[frozenset[str], tuple[Path, ...]]] = {}
_sourced_by: dict[Path, set[Path]] | None = None
_scope: dict[Path, frozenset[str]] = {}


def _info(path: Path) -> tuple[frozenset[str], tuple[Path, ...]]:
    """(functions PATH defines, files PATH sources), each file parsed once."""
    if path not in _file_info:
        defs: set[str] = set()
        sourced: list[Path] = []
        if (ROOT / path).is_file():
            text = (ROOT / path).read_text(errors="replace")
            # Definitions the shell executes: not ones inside a here-document,
            # a string or a comment (the line regex this replaced read those).
            defs.update(function_definitions(tokenize_prefix(text)))
            for words in shell_commands(text):
                if len(words) > 1 and words[0] in {".", "source"}:
                    target = executable_path(words[1], path)
                    if target:
                        sourced.append(Path(target))
        # tests/run_all_tests.sh sources every section fragment by glob.
        if path == Path("tests/run_all_tests.sh"):
            sourced.extend(p.relative_to(ROOT) for p in sorted((ROOT / "tests/sections").glob("*.sh")))
        _file_info[path] = (frozenset(defs), tuple(sourced))
    return _file_info[path]


def defined_functions(source: Path) -> frozenset[str]:
    """Shell functions callable from SOURCE (hq#58).  A sourced file runs in its
    sourcer's shell, so definitions flow both ways along `.`/`source`: down
    into everything SOURCE sources, and up into whatever sources SOURCE (a
    section fragment sees the runner and the runner's helpers)."""
    global _sourced_by
    if source in _scope:
        return _scope[source]
    if _sourced_by is None:
        _sourced_by = {}
        shells = [p for p in sources if p.suffix == ".sh"] + [Path("tests/run_all_tests.sh")]
        for parent in shells:
            for child in _info(parent)[1]:
                _sourced_by.setdefault(child, set()).add(parent)
    names: set[str] = set()
    up, seen_up, seen_down = [source], set(), set()
    while up:
        top = up.pop()
        if top in seen_up:
            continue
        seen_up.add(top)
        up.extend(_sourced_by.get(top, ()))
        down = [top]
        while down:
            path = down.pop()
            if path in seen_down:
                continue
            seen_down.add(path)
            defs, sourced = _info(path)
            names.update(defs)
            down.extend(sourced)
    _scope[source] = frozenset(names)
    return _scope[source]


def shell_edges(source: Path, text: str, src_name: str | None = None) -> None:
    src = src_name or source.as_posix()
    defined = defined_functions(source)
    # Newlines and shell control operators delimit commands.  This is a
    # conservative command-word parser, not a claim that comments mentioning a
    # script execute it.
    for words in shell_commands(text):
        # An asserting fixture is invoked only when it is the program operand
        # of EigenScript.  Globs and text passed to a differential are not
        # expanded here, deliberately.
        invocation = list(words)
        command_at = normalized_command_index(invocation, defined)
        command = invocation[command_at] if command_at < len(invocation) else ""
        if command in {"$EIGS", "${EIGS}"} or command.rstrip("/").endswith("/eigenscript"):
            operands = [word for word in invocation[command_at + 1:] if not word.startswith("-")]
            if operands:
                dst = eigs_program_path(operands[0], source)
                if dst:
                    emit(src, dst)
        elif command == "check_eigs_suite" and command in defined:
            # The first operand is the human-readable check description.
            for word in invocation[command_at + 2:]:
                dst = eigs_program_path(word, source)
                if dst:
                    emit(src, dst)
                    break
        if words[0] in {"bash", "sh", "dash", "python", "python3", "source", "."}:
            words = words[1:]
            while words and words[0].startswith("-"):
                option = words.pop(0)
                if option in {"-W", "-X"} and words:
                    words.pop(0)
        if words:
            dst = executable_path(words[0], source)
            if dst:
                emit(src, dst)


def precheck_table_edges(source: Path, text: str) -> None:
    """tools/precheck.sh runs every row of its GATES table ("class|command",
    one row per line) through a loop: the table is a quoted string the shell
    executes indirectly, so its commands are read from the value of the
    top-level GATES assignment.  (The line scanner this replaced read each
    row as a pipeline `class | command` -- the right edges by accident.)"""
    for cmd in simple_commands(tokenize_prefix(text)):
        for tok in cmd:
            if not tok.text.startswith("GATES="):
                continue
            for row in unquote(tok.text[len("GATES="):]).splitlines():
                _cls, sep, command = row.partition("|")
                if sep:
                    shell_edges(source, command)


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

GAPS: list[str] = []
for source in sorted(sources):
    text = (ROOT / source).read_text(errors="replace")
    if source.suffix == ".sh":
        # A whole shell file the tokenizer stops on while bash accepts it
        # would be read only up to that line: refuse instead of passing.
        try:
            tokenize_file(text, source.as_posix())
        except TokenizerGap as gap:
            GAPS.append(str(gap))
    if source.parts and source.parts[0] == ".github":
        for command in yaml_run_commands(source):
            shell_edges(source, command)
    elif source.suffix == ".py":
        # Python is not shell.  The line scanner this replaced read every .py
        # line as a shell command; measured on the tree, the only edges that
        # produced and python_edges() (the AST's exec calls) does not were
        # self-loops and one prose mention in a docstring.  A tokenizer
        # reading a module as shell pairs its apostrophes across lines, so
        # .py files are read only through the AST.
        pass
    else:
        shell_edges(source, text)
        # A malformed/unusual heredoc elsewhere in a large suite driver must
        # not hide later commands from enrolment extraction.  Re-run the same
        # command parser on short source windows; this is intentionally the
        # same matcher, not a filename grep (plain mentions still emit no edge).
        if source == Path("tools/precheck.sh"):
            precheck_table_edges(source, text)
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
        # Only real step uses entries create local-action edges. YAML scalar
        # contents and env mappings are data, even if they spell `uses:`.
        data = yaml.safe_load(text)
        groups = []
        if isinstance(data, dict):
            jobs = data.get("jobs", {})
            if isinstance(jobs, dict):
                groups.extend(job.get("steps", []) for job in jobs.values() if isinstance(job, dict))
            runs = data.get("runs", {})
            if isinstance(runs, dict):
                groups.append(runs.get("steps", []))
        for steps in groups:
            if not isinstance(steps, list):
                continue
            for step in steps:
                action = step.get("uses") if isinstance(step, dict) else None
                if not isinstance(action, str) or not action.startswith("./"):
                    continue
                target = Path(action)
                if ".." in target.parts:
                    continue
                targets = [target / "action.yml", target / "action.yaml"] if (ROOT / target).is_dir() else [target]
                for manifest in targets:
                    if (ROOT / manifest).is_file():
                        emit(source.as_posix(), manifest.as_posix())
                        break

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

if GAPS:
    for gap in GAPS:
        print(f"enrolment-edges: INSTRUMENT ERROR: {gap}", file=sys.stderr)
    sys.exit(2)
