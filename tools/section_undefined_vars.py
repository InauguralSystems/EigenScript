#!/usr/bin/env python3
"""Refuse a suite fragment that reads an upper-case variable nothing sets (#2544).

A LEXICAL check, not a shell parser. A name counts as set when the text of the
fragment, of a helper it sources by a literal $TESTS_DIR path, or of
tests/run_all_tests.sh and its sourced helpers holds an assignment or a binder
(for, read, local, ...) of that name; when bash sets it itself; or when src/ asks
the environment for it and README.md or docs/ names it. Any `$NAME` or `${NAME}`
that is not escaped and not in a comment line is a read, inside every kind of
quote and heredoc too; `${NAME:-x}` and its -, =, + forms are safe.

An assignment before a command (`NAME=x cmd`) sets nothing for later lines.
Not modelled: order, scopes, branches and function calls (a name set anywhere in
those texts counts), and text a child program reads: `awk '{print $NF}'` is
refused, write `$(NF)`. Bare names in `(( ))` are not reads.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
N = r"[A-Z][A-Z0-9_]*"
END = r"(?![A-Za-z0-9_])"
WORD = r"""(?:"(?:\\.|[^"\\\n])*"|'[^'\n]*'|[^\s;|&"'()<>`])*"""
ASSIGN = re.compile(r"(?<![A-Za-z0-9_$\{-])(" + N + r")(?:\[[^\]\n]*\])?\+?=(?!=)")
PREFIX = re.compile(WORD + r"[ \t]+(?![;|&#<>)}\s]|\d?>|" + N + r"\+?=|\\\n|$)", re.M)
BINDER = re.compile(r"\b(?:for|select|export|local|declare|typeset|readonly|read|mapfile"
                    r"|readarray|getopts|printf[ \t]+-v)\b([^;|&\n]*)")
OTHER = re.compile(r"\b(?:coproc|let)[ \t]+[\"']?(" + N + r")" + END + r"|\{(" + N + r")\}[<>]|\(\([^)\n]*?(?<![A-Za-z0-9_$])("
                   + N + r")[ \t]*=(?!=)")
HEREDOC = re.compile(r"<<(-?)[ \t]*(?:\\(\w+)|'(\w+)'|\"(\w+)\")")
DEFAULT = re.compile(r"\$\{(" + N + r"):?=")
READ = re.compile(r"(?<![\\$])\$(?:\{[#!]?(" + N + r")" + END + r"(?:\[[^\]\n]*\])?(:?[-+=])?|(" + N + r")" + END + ")")
SOURCE = re.compile(r"(?m)(?:^|[;&|{]|\bthen\b)[ \t]*(?:\.|source)[ \t]+\"?\$\{?TESTS_DIR\}?/([^\"\s;]+)")


def code(text):
    """The lines, with comment lines and the bodies of quoted heredocs blanked."""
    lines = text.splitlines()
    out, until = [], []
    for number, line in enumerate(lines):
        if until:
            dash, word = until[0]
            if (line.lstrip("\t") if dash else line) == word:
                until.pop(0)
            out.append("")
            continue
        out.append("" if line.lstrip().startswith("#") else line)
        for m in HEREDOC.finditer(out[-1]):
            word = m.group(2) or m.group(3) or m.group(4)
            # Only when its end is there: text that only looks like a heredoc hides nothing.
            if any((x.lstrip("\t") if m.group(1) else x) == word for x in lines[number + 1:]):
                until.append((m.group(1), word))
    return out


def definitions(text):
    body = "\n".join(code(text))
    found = set(DEFAULT.findall(body))
    for match in ASSIGN.finditer(body):
        line_start = body.rfind("\n", 0, match.start()) + 1
        before = body[line_start:match.start()]
        if re.search(r"(?:^|[;&|({]|\b(?:if|elif|while|until|then|do|else|env)|!)[ \t]*(?:" + N + r"=\S*[ \t]+)*$",
                     before) and PREFIX.match(body, match.end()):
            continue
        found.add(match.group(1))
    for match in BINDER.finditer(body):
        found.update(re.findall(r"(?<![A-Za-z0-9_$\{])" + N + END, match.group(1)))
    for match in OTHER.finditer(body):
        found.update(x for x in match.groups() if x)
    return found


def with_helpers(text, tests, seen):
    found = definitions(text)
    for name in SOURCE.findall("\n".join(code(text))):
        helper = tests / name
        if helper.is_file() and helper not in seen:
            seen.add(helper)
            found |= with_helpers(helper.read_text(), tests, seen)
    return found


def reads(text):
    for number, line in enumerate(code(text), 1):
        for match in READ.finditer(line):
            if not match.group(2):
                yield number, match.group(1) or match.group(3)


def ambient(root):
    """What bash sets itself, and what src/ asks the environment for and a document names."""
    out = subprocess.check_output(
        ["env", "-i", "bash", "--noprofile", "--norc", "-c",
         "f() { compgen -A variable; }; [[ a =~ a ]]; read <<< x; mapfile <<< x; OLDPWD=x;"
         " getopts a: O -a b; true | true; f; echo FUNCNAME"], text=True)
    names = set(out.split())
    asked = set()
    for path in sorted((root / "src").glob("*.[ch]")):
        asked |= set(re.findall(r"\w*(?:getenv|env_flag)\w*\(\s*\"(" + N + r")\"", path.read_text(errors="replace")))
    documents = "\n".join(p.read_text() for p in [root / "README.md", *sorted((root / "docs").glob("*.md"))] if p.is_file())
    return names | {n for n in asked if re.search(r"\b" + n + r"\b", documents)}


def scan(root, sections):
    tests = root / "tests"
    runner = with_helpers((tests / "run_all_tests.sh").read_text(), tests, set()) | ambient(root)
    bad = []
    for path in sections:
        text = path.read_text()
        known = runner | with_helpers(text, tests, set())
        bad += [(path, n, name) for n, name in reads(text) if name not in known]
    return bad


def run(root):
    # The runner globs the directory, so the check does too (an unadded file is run).
    sections = sorted((root / "tests/sections").glob("*.sh"))
    bad = scan(root, sections) if sections else []
    for path, number, name in bad:
        print(f"{path.relative_to(root)}:{number}: ${name} is read and nothing sets it")
    ok = bool(sections) and not bad
    print(f"section-undefined-vars: {'PASS' if ok else 'FAIL'}: examined={len(sections)} undefined={len(bad)}")
    return 0 if ok else 1


# (name, fragment, red?). Every red one is also run with its read removed: green.
CASES = [
    ("plain", 'echo "$TEST_DIR"', True), ("braces", 'echo "${TEST_DIR%/*}"', True),
    ("length", 'echo "${#TEST_DIR}"', True), ("required", 'echo "${TEST_DIR?no}"', True),
    ("apostrophe", 'echo "don\'t $TEST_DIR"', True), ("trap", "trap 'rm -rf \"$TEST_DIR\"' EXIT", True),
    ("heredoc in substitution", "X=$(cat <<'EOF'\nhello\nEOF\n)\ncat \"$TEST_DIR\"", True),
    ("after awk program", "awk '\n{print}\n' \"$TEST_DIR\"", True),
    ("heredoc body", "cat <<EOF\n$TEST_DIR\nEOF", True),
    ("word of a default", 'echo "${A:-$TEST_DIR}"', True),
    ("prefix", 'TEST_DIR=x true\necho "$TEST_DIR"', True),
    ("quoted prefix", 'TEST_DIR="./a b" bash x.sh\necho "$TEST_DIR"', True),
    ("env", 'env TEST_DIR=x true\necho "$TEST_DIR"', True),
    ("prefix in substitution", 'O=$(TEST_DIR="x" bash y)\necho "$TEST_DIR"', True),
    ("prefix after if", 'if TEST_DIR=./x bash y; then :; fi\necho "$TEST_DIR"', True),
    ("comparison", '[ "$A" == TEST_DIR ]; echo "$TEST_DIR"', True),
    ("comment", '# TEST_DIR=x\necho "$TEST_DIR"', True),
    ("escaped", 'echo "\\$TEST_DIR"', False), ("comment read", '# $TEST_DIR', False),
    ("colon minus", 'echo "${TEST_DIR:-x}"', False), ("minus", 'echo "${TEST_DIR-x}"', False),
    ("colon plus", 'echo "${TEST_DIR:+x}"', False), ("plus", 'echo "${TEST_DIR+x}"', False),
    ("assign default", ': "${Q:=x}"\necho "$Q"', False), ("assign", 'Q=x\necho "$Q"', False),
    ("self", 'Q=a\nQ="$Q b"\necho "$Q"', False), ("append", 'Q+=x\necho "$Q"', False),
    ("array", 'Q=(--a --b)\necho "${Q[@]}"', False), ("element", 'Q[0]=x\necho "${Q[0]}"', False),
    ("substitution", 'Q=$( (cd / && pwd) 2>&1 ); R=$?\necho "$Q$R"', False),
    ("redirected", 'Q=$(true) 2>/dev/null\necho "$Q"', False), ("two", 'Q=1 R=2\necho "$Q$R"', False),
    ("group", '{ Q=1; }; echo "$Q"', False), ("else", 'if true; then Q=1; else Q=2; fi\necho "$Q"', False),
    ("or", 'true || { Q=$?; }\necho "$Q"', False), ("arithmetic", '(( Q=5 ))\necho "$Q"', False),
    ("for", 'for Q in a; do echo "$Q"; done', False), ("read", 'while IFS= read -r Q R; do echo "$Q$R"; done', False),
    ("mapfile", 'mapfile -t Q < <(echo a)\necho "${Q[0]}"', False), ("local", 'f() { local Q; echo "$Q"; }', False),
    ("export", 'export Q\necho "$Q"', False), ("declare", 'declare -a Q\necho "$Q"', False),
    ("typeset", 'typeset Q\necho "$Q"', False), ("readonly", 'readonly Q\necho "$Q"', False),
    ("printf", 'printf -v Q %s x\necho "$Q"', False), ("getopts", 'getopts ab Q\necho "$Q"', False),
    ("select", 'select Q in a; do echo "$Q"; done', False), ("readarray", 'readarray Q\necho "$Q"', False),
    ("runner", 'echo "$SUITE_DEFINED"', False), ("runner helper", 'echo "$HELPED"', False),
    ("own helper", '. "$TESTS_DIR/own.sh"\necho "$OWNED"', False),
    ("helper not sourced", 'echo "$OWNED"', True), ("bash", 'echo "$PWD${BASH_REMATCH[0]}"', False),
    ("documented", 'echo "$EIGS_DOC"', False), ("read by src only", 'echo "$EIGS_NODOC"', True),
    ("documented only", 'echo "$ONLYDOC"', True), ("array default", 'echo "${Q[0]:-x}${Q[@]+y}"', False), ("pid prefix", 'echo $$Q', False),
    ("fd variable", 'exec {Q}>/dev/null\necho "$Q"', False), ("coproc", 'coproc Q { true; }\necho "${Q[0]}"', False),
    ("let", 'let "Q = 5"\necho "$Q"', False), ("arithmetic spaced", '(( Q = 5 ))\necho "$Q"', False),
    ("case in substitution", 'Q=$(case a in a) echo b;; esac)\necho "$Q"', False),
    ("quoted heredoc", "cat <<'EOF'\n$Q\nEOF", False), ("escaped heredoc", "cat <<\\EOF\n$Q\nEOF", False),
    ("after a quoted heredoc", "cat <<'EOF'\nx\nEOF\necho $TEST_DIR", True),
    ("a heredoc with no end hides nothing", "echo \"<<'EOF'\"\necho $TEST_DIR", True),
    ("set only in a quoted heredoc", "cat <<'EOF'\nTEST_DIR=1\nEOF\necho $TEST_DIR", True),
    ("bash specials", 'echo "$OPTARG$FUNCNAME$REPLY${MAPFILE[0]}${PIPESTATUS[0]}$OLDPWD"', False),
    *[("prefix after " + w, w + " TEST_DIR=x a; then b\necho $TEST_DIR", True) for w in ("elif", "while", "until", "then", "do", "else", "!")],
    ("prefix then set", 'Q=x true\nQ=y\necho "$Q"', False),
]


def selftest():
    failed = total = 0

    def check(name, ok):
        nonlocal failed, total
        total += 1
        failed += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {name}")

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        for d in ("tests/sections", "docs", "src"):
            (root / d).mkdir(parents=True)
        (root / "README.md").write_text("`EIGS_DOC` `ONLYDOC`\n")
        (root / "src/a.c").write_text('getenv("EIGS_DOC"); eigs_env_flag("EIGS_NODOC");\n')
        (root / "tests/run_all_tests.sh").write_text('TESTS_DIR=x\nA=1\nSUITE_DEFINED=x\n. "$TESTS_DIR/help.sh"\n')
        (root / "tests/help.sh").write_text("HELPED=1\n")
        (root / "tests/own.sh").write_text("OWNED=1\n")
        one = root / "tests/sections/one.sh"
        for name, body, red in CASES:
            control = re.sub(r"(?<!\\)\$\{?[#]?(?:TEST_DIR|OWNED|EIGS_NODOC|ONLYDOC)[^}\"'\n]*\}?", "x", body) if red else body
            one.write_text(control + "\n")
            clean = not scan(root, [one])
            one.write_text(body + "\n")
            found = scan(root, [one])
            check(name, clean and bool(found) == red)
        real = ROOT / "tests/sections/73x-jit-index-set-error-2540.sh"
        lines = real.read_text().splitlines()
        one.write_text("\n".join(lines + ['cat "$TEST_DIR/x"']) + "\n")
        check("a plant in a copy of a real fragment is named", scan(ROOT, [one]) == [(one, len(lines) + 1, "TEST_DIR")])
        one.write_text("\n".join(lines) + "\n")
        check("its control is clean", scan(ROOT, [one]) == [])
        one.write_text('echo "$A"\n')
        check("run: green", run(root) == 0)
        one.write_text('echo "$TEST_DIR"\n')
        check("run: red", run(root) == 1)
        one.unlink()
        check("run: no fragments is red", run(root) == 1)
    print(f"section-undefined-vars selftest: {total - failed}/{total} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        raise SystemExit(selftest())
    if sys.argv[1:]:
        raise SystemExit("usage: section_undefined_vars.py [--selftest]")
    raise SystemExit(run(ROOT))
