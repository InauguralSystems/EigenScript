#!/usr/bin/env python3
"""Reject undefined upper-case shell variables in sourced suite fragments."""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME = r"[A-Z][A-Z0-9_]*"
READ = re.compile(r"\$(?:\{(" + NAME + r")(?:([^}]*))\}|(" + NAME + r"))")
ASSIGN = re.compile(r"(?<![A-Za-z0-9_])(" + NAME + r")(\+?=)")
BINDER = re.compile(r"\b(?:local|declare|typeset|export|readonly)\s+(?:-[A-Za-z]+\s+)*(" + NAME + r")(?:\+?=|\b)")
FOR = re.compile(r"\bfor\s+(" + NAME + r")\s+in\b")
READ_CMD = re.compile(r"\bread(?:\s+-[A-Za-z]+)*(?:\s+-p\s+\S+)?\s+([^;|&]+)")
PRINTF_BIND = re.compile(r"\bprintf\s+-v\s+(" + NAME + r")\b")
UNSET = re.compile(r"\bunset(?:\s+-[a-zA-Z]+)*\s+(" + NAME + r")\b")


def tracked_sections(root: Path) -> list[Path]:
    out = subprocess.check_output(
        ["git", "ls-files", "tests/sections/*.sh"], cwd=root, text=True
    )
    return [root / line for line in out.splitlines() if line]


def documented_environment(root: Path) -> set[str]:
    """Derive environment names from prose that actually calls them environment variables."""
    result: set[str] = set()
    for path in [root / "README.md", *sorted((root / "docs").glob("*.md"))]:
        lines = path.read_text(encoding="utf-8").splitlines()
        in_env_table = False
        for line in lines:
            lower = line.lower()
            if "environment variable" in lower:
                result.update(re.findall(r"`(" + NAME + r")(?:=[^`]*)?`", line))
                in_env_table = line.rstrip().endswith(":")
                continue
            if in_env_table and (line.startswith("|") or not line.strip()):
                result.update(re.findall(r"`(" + NAME + r")(?:=[^`]*)?`", line))
                continue
            in_env_table = False
    return result


def strip_shell(line: str) -> str:
    """Blank single-quoted text and comments, retaining columns and double quotes."""
    out = list(line)
    single = False
    escaped = False
    for i, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\" and not single:
            escaped = True
            continue
        if char == "'":
            single = not single
            out[i] = " "
            continue
        if single:
            out[i] = " "
        elif char == "#" and (i == 0 or line[i - 1].isspace()):
            for j in range(i, len(out)):
                out[j] = " "
            break
    return "".join(out)


def iter_code(path: Path):
    pending: list[tuple[str, bool]] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if pending:
            delimiter, expand = pending[0]
            if raw.lstrip("\t") == delimiter:
                pending.pop(0)
            elif expand:
                yield number, raw
            continue
        code = strip_shell(raw)
        # Quoted heredocs are literal; unquoted heredocs perform expansions.
        for match in re.finditer(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", raw):
            pending.append((match.group(2), not bool(match.group(1))))
        yield number, code


def definitions(path: Path) -> set[str]:
    found: set[str] = set()
    for _, code in iter_code(path):
        found.update(m.group(1) for m in ASSIGN.finditer(code))
        for pattern in (BINDER, FOR, PRINTF_BIND):
            found.update(m.group(1) for m in pattern.finditer(code))
        for match in READ_CMD.finditer(code):
            found.update(re.findall(r"\b" + NAME + r"\b", match.group(1)))
    return found


def runner_context(root: Path) -> set[str]:
    # run_all_tests.sh sources these before the fragment loop. Resolve the same
    # literal $TESTS_DIR paths, recursively, rather than maintaining a helper list.
    queue = [root / "tests/run_all_tests.sh"]
    seen: set[Path] = set()
    names: set[str] = set()
    source_re = re.compile(r"^[ \t]*(?:\.|source)[ \t]+[\"']?([^\"' ;|]+)")
    while queue:
        path = queue.pop()
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        names.update(definitions(path))
        for _, code in iter_code(path):
            match = source_re.match(code)
            if not match:
                continue
            value = match.group(1).replace("$TESTS_DIR", str(root / "tests"))
            value = value.replace("${TESTS_DIR}", str(root / "tests"))
            candidate = Path(value)
            if candidate.is_absolute() and candidate.is_file():
                queue.append(candidate.resolve())
    # Ask bash for the variables it creates itself in a clean environment
    # (PWD, BASH_VERSION, ...); this is runtime-derived, not an allowlist.
    builtin = subprocess.check_output(
        ["env", "-i", "bash", "--noprofile", "--norc", "-c", "compgen -A variable"],
        text=True,
    )
    names.update(name for name in builtin.splitlines() if re.fullmatch(NAME, name))
    return names


def safe_parameter_tail(tail: str) -> bool:
    return tail.startswith((":-", "-", ":+", "+", ":="))


def scan(root: Path, sections: list[Path]) -> list[tuple[Path, int, str]]:
    available = runner_context(root) | documented_environment(root)
    failures: list[tuple[Path, int, str]] = []
    for path in sections:
        local_available = set(available)
        for number, code in iter_code(path):
            # Assignment words make their name available to expansions after the
            # word; this conservative ordering also models command environment.
            line_defs = {m.group(1) for m in ASSIGN.finditer(code)}
            positioned_defs: list[tuple[int, str]] = []
            for pattern in (BINDER, FOR, PRINTF_BIND):
                for match in pattern.finditer(code):
                    line_defs.add(match.group(1))
                    positioned_defs.append((match.end(), match.group(1)))
            for match in READ_CMD.finditer(code):
                for name in re.findall(r"\b" + NAME + r"\b", match.group(1)):
                    line_defs.add(name)
                    positioned_defs.append((match.end(), name))
            # [[ string =~ regex ]] assigns bash's BASH_REMATCH array.
            if re.search(r"\[\[.*=~.*\]\]", code):
                line_defs.add("BASH_REMATCH")
                local_available.add("BASH_REMATCH")
            source = re.match(r"^[ \t]*(?:\.|source)[ \t]+[\"']?([^\"' ;|]+)", code)
            if source:
                value = source.group(1).replace("$TESTS_DIR", str(root / "tests"))
                value = value.replace("${TESTS_DIR}", str(root / "tests"))
                helper = Path(value)
                if helper.is_file():
                    line_defs.update(definitions(helper))
            for match in READ.finditer(code):
                name = match.group(1) or match.group(3)
                tail = match.group(2) or ""
                if match.group(1) and safe_parameter_tail(tail):
                    if tail.startswith(":="):
                        line_defs.add(name)
                    continue
                defined_earlier_on_line = any(
                    defined == name and end <= match.start()
                    for end, defined in positioned_defs
                )
                if name not in local_available and not defined_earlier_on_line:
                    failures.append((path, number, name))
            local_available.update(line_defs)
            for match in UNSET.finditer(code):
                local_available.discard(match.group(1))
        # Fragments are sourced, in byte order, by one shell. Only earlier
        # fragment assignments can therefore supply a later fragment.
        available.update(definitions(path))
    return failures


def population_ok(root: Path, sections: list[Path]) -> bool:
    return bool(sections) and not scan(root, sections)


def selftest() -> int:
    cases = {
        "plain-read": ("echo \"$MISSING\"\n", False),
        "assignment": ("VALUE=ok\necho \"$VALUE\"\n", True),
        "single-quote": ("echo '$LITERAL'\n", True),
        "comment": ("# $COMMENT\necho ok\n", True),
        "quoted-heredoc": ("cat <<'EOF'\n$LITERAL\nEOF\n", True),
        "expanded-heredoc": ("cat <<EOF\n$MISSING\nEOF\n", False),
        "default-colon": ("echo \"${OPTIONAL:-x}\"\n", True),
        "default": ("echo \"${OPTIONAL-x}\"\n", True),
        "alternate-colon": ("echo \"${OPTIONAL:+x}\"\n", True),
        "alternate": ("echo \"${OPTIONAL+x}\"\n", True),
        "required": ("echo \"${REQUIRED?no}\"\n", False),
        "array": ("ARRAY=(a b)\necho \"${ARRAY[@]}\"\n", True),
        "local": ("f() { local LOCAL=x; echo \"$LOCAL\"; }\n", True),
        "read": ("read INPUT\necho \"$INPUT\"\n", True),
        "for": ("for ITEM in x; do echo \"$ITEM\"; done\n", True),
        "printf-v": ("printf -v OUTPUT %s x\necho \"$OUTPUT\"\n", True),
        "export-assignment": ("export EXPORTED=x\necho \"$EXPORTED\"\n", True),
        "declare": ("declare DECLARED=x\necho \"$DECLARED\"\n", True),
        "append": ("APPENDED+=x\necho \"$APPENDED\"\n", True),
        "assign-default": (": \"${DEFAULTED:=x}\"\necho \"$DEFAULTED\"\n", True),
        "unset": ("GONE=x\nunset GONE\necho \"$GONE\"\n", False),
    }
    failed = 0
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        (root / "tests/sections").mkdir(parents=True)
        (root / "docs").mkdir()
        (root / "README.md").write_text("`DOCUMENTED` environment variable.\n")
        (root / "tests/run_all_tests.sh").write_text("SUITE_DEFINED=x\n")
        total = 0
        for name, (body, want_green) in cases.items():
            path = root / "tests/sections/one.sh"
            control = "echo ok\n" if not want_green else body
            path.write_text(control)
            control_green = not scan(root, [path])
            path.write_text(body)
            green = not scan(root, [path])
            total += 1
            if control_green and green == want_green:
                print(f"PASS: {name}")
            else:
                print(f"FAIL: {name} control={control_green} green={green}")
                failed += 1
        # Earlier fragments share the shell; later fragments do not travel back.
        first = root / "tests/sections/a.sh"; second = root / "tests/sections/b.sh"
        first.write_text("SHARED=x\n"); second.write_text('echo "$SHARED"\n')
        total += 1
        if not scan(root, [first, second]) and scan(root, [second, first]):
            print("PASS: fragment source order")
        else:
            print("FAIL: fragment source order"); failed += 1
        # The historical typo is planted only in a copy of a real fragment.
        real = ROOT / "tests/sections/73x-jit-index-set-error-2540.sh"
        planted = root / "tests/sections/planted.sh"
        planted.write_text(real.read_text() + '\nprintf "%s\\n" "$TEST_DIR"\n')
        findings = scan(root, [planted])
        total += 1
        if any(p == planted and n > 0 and v == "TEST_DIR" for p, n, v in findings):
            print(f"PASS: planted TEST_DIR named {planted.name}:{findings[-1][1]}:TEST_DIR")
        else:
            print("FAIL: planted TEST_DIR was not attributed"); failed += 1
        total += 1
        if population_ok(root, []):
            print("FAIL: vacuous run was accepted")
            failed += 1
        else:
            print("PASS: vacuous run is refused")
    print(f"section-undefined-vars selftest: {total - failed}/{total} passed, {failed} failed")
    return 1 if failed else 0


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    if sys.argv[1:]:
        print("usage: tools/section_undefined_vars.py [--selftest]", file=sys.stderr)
        return 2
    sections = tracked_sections(ROOT)
    if not sections:
        print("section-undefined-vars: FAIL: examined=0 (no tracked fragments)")
        return 1
    failures = scan(ROOT, sections)
    for path, line, name in failures:
        print(f"{path.relative_to(ROOT)}:{line}: undefined upper-case variable {name}")
    status = "PASS" if not failures else "FAIL"
    print(f"section-undefined-vars: {status}: examined={len(sections)} undefined={len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
