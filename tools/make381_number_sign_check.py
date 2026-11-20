#!/usr/bin/env python3
"""Guard the GNU make 3.81 number-sign rule in Makefiles.

GNU make 3.81's manual, section "What Makefiles Contain", says that a number
sign starts a comment unless escaped with a backslash; a recipe line (one that
starts with a tab) is instead passed to the shell.  In particular, 3.81 applies
that rule inside function arguments where newer GNU make accepts some uses.
Within a reference, only plain delimiters of the same kind as its opener are counted.

Covered calls: shell, if, foreach, call, subst, patsubst, filter, wildcard,
eval, info, warning, and error, with both $(...) and ${...} spelling.  This
check deliberately only names, rather than detects, other post-3.81 features:
$(file ...), .ONESHELL, --output-sync, != assignments, ::=, $(guile ...),
undefine, and private.  Those have different grammars and compatibility rules.
"""

from __future__ import annotations

import argparse
import glob
import re
import sys
import tempfile
from pathlib import Path


FUNCTIONS = {
    "shell", "if", "foreach", "call", "subst", "patsubst", "filter",
    "wildcard", "eval", "info", "warning", "error",
}
INCLUDE_RE = re.compile(r"^\s*(include|-include|sinclude)\s+(.+)$")


def logical_lines(path: Path):
    """Yield (first line, text), excluding recipes and define bodies."""
    parts: list[str] = []
    first = 0
    defining = False
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not parts:
            if re.match(r"^\s*define(?:\s|$)", raw):
                defining = True
                continue
            if defining:
                if re.match(r"^\s*endef(?:\s*(?:#.*)?)?$", raw):
                    defining = False
                continue
            if raw.startswith("\t"):
                continue
            first = number
        parts.append(raw)
        # An odd trailing backslash escapes the newline.
        trailing = len(raw) - len(raw.rstrip("\\"))
        if trailing % 2:
            parts[-1] = parts[-1][:-1]
            continue
        yield first, "".join(parts)
        parts = []
    if parts:
        yield first, "".join(parts)


def unescaped_hash_in_call(text: str) -> bool:
    # Each entry is [opener, closer, covered, plain-delimiter depth].
    stack: list[list[str | bool | int]] = []
    i = 0
    while i < len(text):
        char = text[i]
        if char == "#":
            slashes = 0
            j = i - 1
            while j >= 0 and text[j] == "\\":
                slashes += 1
                j -= 1
            if slashes % 2 == 0:
                return any(bool(entry[2]) for entry in stack)
        if char == "$" and i + 1 < len(text) and text[i + 1] in "({":
            opener = text[i + 1]
            closer = ")" if opener == "(" else "}"
            j = i + 2
            while j < len(text) and text[j].isspace():
                j += 1
            start = j
            while j < len(text) and text[j] not in " \t,)}":
                j += 1
            stack.append([opener, closer, text[start:j] in FUNCTIONS, 0])
            i += 2
            continue
        if stack and char == stack[-1][0]:
            stack[-1][3] += 1
        elif stack and char == stack[-1][1]:
            if stack[-1][3]:
                stack[-1][3] -= 1
            else:
                stack.pop()
        i += 1
    return False


def strip_comment(text: str) -> str:
    for i, char in enumerate(text):
        if char != "#":
            continue
        slashes = 0
        j = i - 1
        while j >= 0 and text[j] == "\\":
            slashes += 1
            j -= 1
        if slashes % 2 == 0:
            return text[:i]
    return text


def included_paths(path: Path, root: Path):
    for _, line in logical_lines(path):
        match = INCLUDE_RE.match(strip_comment(line))
        if not match:
            continue
        for word in match.group(2).split():
            # Generated dependency includes commonly contain make variables;
            # they name no concrete file in the source tree to inspect.
            if "$" in word:
                continue
            pattern = root / word
            for name in glob.glob(str(pattern)):
                candidate = Path(name)
                if candidate.is_file():
                    yield candidate.resolve()


def inspect(root_makefile: Path):
    root = root_makefile.parent.resolve()
    pending = [root_makefile.resolve()]
    seen: set[Path] = set()
    findings: list[tuple[Path, int]] = []
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        for number, line in logical_lines(path):
            if unescaped_hash_in_call(line):
                findings.append((path, number))
        pending.extend(p for p in included_paths(path, root) if p not in seen)
    return root, seen, findings


def run_check(makefile: Path) -> int:
    root, files, findings = inspect(makefile)
    for path, number in findings:
        try:
            shown = path.relative_to(root)
        except ValueError:
            shown = path
        print(f"make-3.81-number-sign: FAIL: {shown}:{number}: "
              "unescaped number sign inside function call")
    print(f"make-3.81-number-sign: examined {len(files)} file(s); "
          f"findings={len(findings)}")
    return int(not files or bool(findings))


def selftest() -> int:
    cases = [
        ("recipe", "all:\n\t@echo # passed to shell\n", 0),
        ("comment", "# ordinary comment\n", 0),
        ("assignment-comment", "X := 1 # note\n", 0),
        ("escaped", r"X := $(shell echo \#)" + "\n", 0),
        ("recipe-define", "define BODY\n\t@echo # recipe data\nendef\nall:\n$(BODY)\n", 0),
        ("real-shell", r"X := $(shell sed -n 's/^\([^#]*\)$/\1/p' input)" + "\n", 1),
        ("if", "X := $(if yes,#bad,good)\n", 1),
        ("continued", "X := $(foreach x,one two,\\\n  $(if $x,\\\n  #bad))\n", 1),
        ("plain-parens-if", "X := $(if (ok),#bad,good)\n", 1),
        ("multiple-plain-parens", "X := $(shell echo (a) (b) #c)\n", 1),
        ("plain-braces-if", "X := ${if {ok},#bad,good}\n", 1),
        ("continued-plain-paren", "X := $(if (ok\\\n),#bad,good)\n", 1),
        ("comment-after-call", "X := $(if (ok),good) # a real comment after the call\n", 0),
        ("other-kind-reference", "X := $(if ${X},a,b) # comment\n", 0),
        ("recipe-unbalanced-paren", "all:\n\t@echo unexpected ) # shell comment\n", 0),
    ]
    passed = 0
    with tempfile.TemporaryDirectory(prefix="make381-selftest-") as tmp:
        work = Path(tmp)
        for name, body, want in cases:
            fixture = work / "Makefile"
            fixture.write_text(body, encoding="utf-8")
            _, _, findings = inspect(fixture)
            got = len(findings)
            if got == want:
                print(f"PASS: {name}")
                passed += 1
            else:
                print(f"FAIL: {name}: wanted {want} finding(s), got {got}")
        (work / "child.mk").write_text("include grandchild.mk\n", encoding="utf-8")
        (work / "grandchild.mk").write_text("Y := ${warning #included}\n", encoding="utf-8")
        fixture.write_text("include child.mk\n", encoding="utf-8")
        _, files, findings = inspect(fixture)
        if (len(files) == 3 and len(findings) == 1 and
                findings[0][0].name == "grandchild.mk"):
            print("PASS: recursively included file")
            passed += 1
        else:
            print(f"FAIL: recursively included file: files={len(files)} findings={len(findings)}")
    print(f"MAKE381_NUMBER_SIGN_SELFTEST: {passed}/16 passed")
    return int(passed != 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("makefile", nargs="?", type=Path, default=Path("Makefile"))
    args = parser.parse_args()
    return selftest() if args.selftest else run_check(args.makefile)


if __name__ == "__main__":
    sys.exit(main())
