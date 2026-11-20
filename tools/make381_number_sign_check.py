#!/usr/bin/env python3
r"""Refuse a number sign that GNU Make 3.81 reads differently from current make (#2448).

Written against GNU Make 3.81, the make of the macOS runners.  Its answers are
the cases of tools/make381_cases.json, each run through a real 3.81 and through
GNU Make 4.3 by tools/make381_oracle.py; --selftest holds this check to them.
With no argument it reads every tracked makefile of the tree (git ls-files:
Makefile, makefile, GNUmakefile, *.mk) and each file one of them includes by a
literal name, looked up from the tree's root as make run there does; with
arguments, those files and nothing else.

3.81 cuts a variable assignment or a directive at its first unescaped number
sign before it reads the line, also when the sign stands inside an open $(...)
or ${...}.  So on such a line a number sign inside a reference is a finding,
with or without a backslash before it (3.81 and 4.3 disagree on the backslash).
A rule line is read from the uncut text and a recipe line is not read by make:
no finding there.  A line that starts with a tab is a recipe line only while a
rule is open; an assignment, a directive other than a conditional, or a bare
line closes the rule, and a define does not.  The body of a define is read as makefile text, with $$(
and $${ opening a reference too, only when the define's name is written inside
an $(eval call of the same file; no other body is read.

Stricter than the makes: an assignment nothing expands, a line in a branch of
a conditional that is not taken, and any number sign inside a reference on a
bare line or a recipe line that calls $(eval.  Looser:
a define body that reaches $(eval) through another variable, and a sign that a
variable carries into text $(eval) reads.  Not covered: !=, ::=, undefine,
private, $(file ...), a lone $ at the end of a value, .ONESHELL, --output-sync,
an include whose name holds a reference, and other makefile text that exists
only after expansion.

To write the sign inside a call: H := \# at the top level and $H in the call
($$H in text that $(eval) reads again), or the tool's own escape (printf '\043').
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

CONDITIONALS = {"ifeq", "ifneq", "ifdef", "ifndef"}
NO_EFFECT = {"else", "endif"}
DIRECTIVES = {"include", "-include", "sinclude", "vpath", "export", "unexport", "override"}
OPENERS = {"(": ")", "{": "}"}
EVAL = re.compile(r"\$[({]eval\s")


def logical_lines(lines):
    """Return [(text, line_of_each_character)], continuation lines joined."""
    out = []
    i = 0
    while i < len(lines):
        parts, numbers = [], []
        while i < len(lines):
            raw = lines[i].rstrip("\n")
            i += 1
            # An odd number of final backslashes continues the logical line.
            if (len(raw) - len(raw.rstrip("\\"))) % 2 and i < len(lines):
                raw = raw[:-1] + " "
                parts.append(raw)
                numbers.extend([i] * len(raw))
                continue
            parts.append(raw)
            numbers.extend([i] * (len(raw) + 1))
            break
        out.append(("".join(parts), numbers))
    return out


def walk(text, doubled):
    """Yield (offset, character, depth) for the text outside and inside references.

    depth is the number of open $( or ${ references at that character.  A
    plain bracket of the same kind as the innermost opener nests, as in make.
    $$ is a literal dollar, except that with `doubled` a $$( or $${ opens a
    reference (text that $(eval) expands once more).
    """
    stack = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "$" and i + 1 < n:
            nxt = text[i + 1]
            if nxt == "$":
                if doubled and i + 2 < n and text[i + 2] in OPENERS:
                    stack.append((text[i + 2], OPENERS[text[i + 2]]))
                    i += 3
                    continue
                i += 2
                continue
            if nxt in OPENERS:
                stack.append((nxt, OPENERS[nxt]))
                i += 2
                continue
        if stack:
            if c == stack[-1][0]:
                stack.append(stack[-1])
            elif c == stack[-1][1]:
                stack.pop()
                i += 1
                continue
        yield i, c, len(stack)
        i += 1


def escaped(text, i):
    """Is the character at i preceded by an odd number of backslashes?"""
    j = i
    while j and text[j - 1] == "\\":
        j -= 1
    return (i - j) % 2 == 1


def sign_in_reference(text, doubled):
    """Offset of the first number sign inside an open reference, or None.

    The scan ends at an unescaped number sign outside every reference: that
    one starts an ordinary comment.
    """
    for i, c, depth in walk(text, doubled):
        if c != "#":
            continue
        if depth:
            return i
        if not escaped(text, i):
            return None
    return None


def line_kind(text, doubled):
    """assignment, rule or bare, as 3.81 decides it: on the text cut at the
    first unescaped number sign, the first = (also :=, +=, ?=) or : met
    outside every reference."""
    cut = len(text)
    for i, c in enumerate(text):
        if c == "#" and not escaped(text, i):
            cut = i
            break
    head = text[:cut]
    for i, c, depth in walk(head, doubled):
        if depth:
            continue
        if c == "=":
            return "assignment"
        if c == ":":
            return "assignment" if head[i + 1:i + 2] == "=" else "rule"
    return "bare"


def evaluated_names(text):
    """Every name written inside an $(eval ...) or ${eval ...} call."""
    names = set()
    for m in EVAL.finditer(text):
        close = OPENERS[text[m.start() + 1]]
        depth, j = 1, m.end()
        while j < len(text) and depth:
            if text[j] == text[m.start() + 1]:
                depth += 1
            elif text[j] == close:
                depth -= 1
            j += 1
        names.update(re.findall(r"[A-Za-z_][A-Za-z0-9_.-]*", text[m.end():j]))
    return names


class Checker:
    def __init__(self, root=None):
        self.findings = []
        self.seen = set()
        self.root = root                      # where an include's name is looked up

    def check_file(self, path, follow=False):
        path = os.path.abspath(path)
        if path in self.seen:
            return
        self.seen.add(path)
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.readlines()
        except (OSError, UnicodeDecodeError) as exc:
            raise RuntimeError("cannot read %s: %s" % (path, exc))
        evaluated = evaluated_names("".join(lines))
        logical = logical_lines(lines)
        top, i = [], 0
        while i < len(logical):
            text, numbers = logical[i]
            words = text.split()
            if words[:1] == ["define"] or words[:2] == ["override", "define"]:
                name = words[1] if words[0] == "define" else (words[2] if len(words) > 2 else "")
                body, i, depth = [], i + 1, 1
                while i < len(logical):               # a define inside a define nests
                    inner = logical[i][0].split()
                    if inner[:1] == ["define"] or inner[:2] == ["override", "define"]:
                        depth += 1
                    elif inner[:1] == ["endef"]:
                        depth -= 1
                        if not depth:
                            break
                    body.append(logical[i])
                    i += 1
                if i == len(logical):
                    raise RuntimeError("%s:%d: define never ends" % (path, numbers[0]))
                if name in evaluated:
                    self.scan(path, body, doubled=True, follow=False)
                # 3.81 leaves a rule open across a define (case tab-assign-after-define).
            else:
                top.append((text, numbers))
            i += 1
        self.scan(path, top, doubled=False, follow=follow)

    def scan(self, path, logical, doubled, follow):
        rule_open = False
        for text, numbers in logical:
            stripped = text.strip()
            if not stripped:
                continue
            if rule_open and text.startswith("\t"):     # a recipe line, whatever it looks like
                if EVAL.search(text):
                    self.judge(path, text, numbers, True)
                continue
            if stripped.startswith("#"):
                continue
            word = stripped.split()[0]
            if word in NO_EFFECT:
                continue
            if word in CONDITIONALS:          # read, and an open rule stays open
                self.judge(path, text, numbers, doubled)
                continue
            kind = line_kind(text, doubled)
            if word in DIRECTIVES or kind == "assignment":
                self.judge(path, text, numbers, doubled)
                rule_open = False
                if follow and word in ("include", "-include", "sinclude"):
                    self.follow_include(path, stripped[len(word):], word)
            elif kind == "rule":
                rule_open = True
            else:
                if EVAL.search(text):
                    self.judge(path, text, numbers, True)
                rule_open = False

    def judge(self, path, text, numbers, doubled):
        pos = sign_in_reference(text, doubled)
        if pos is not None:
            self.findings.append((path, numbers[min(pos, len(numbers) - 1)],
                                  "a number sign inside a $( or ${ reference: GNU Make 3.81 "
                                  "reads this line differently (tools/make381_number_sign_check.py)"))

    def follow_include(self, path, rest, word):
        names = rest.split("#", 1)[0].split()
        for name in names:
            if "$" in name:
                continue                      # a computed name: not followed (header)
            # make looks an include up from its working directory: the tree's root here.
            child = os.path.join(self.root, name)
            if os.path.exists(child):
                self.check_file(child, follow=True)
            elif word == "include":
                raise RuntimeError("%s includes %s, which is not at the tree's root "
                                   "(names are looked up from there, as make run at the root does)"
                                   % (path, name))


def tracked_makefiles(root):
    """Every tracked makefile of the tree at root, by git's own list."""
    q = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True)
    if q.returncode != 0:
        raise RuntimeError("cannot list the tracked files of %s: %s" % (
            root, q.stderr.decode("utf-8", "replace").strip()))
    names = [n for n in q.stdout.decode("utf-8", "replace").split("\0") if n]
    picked = [n for n in names
              if os.path.basename(n) in ("Makefile", "makefile", "GNUmakefile") or n.endswith(".mk")]
    if not picked:
        raise RuntimeError("%s has no tracked makefile" % root)
    return [os.path.join(root, n) for n in picked]


def check_tree(root):
    """Read every tracked makefile of the tree and what each includes by a literal name."""
    checker = Checker(root)
    for path in tracked_makefiles(root):
        checker.check_file(path, follow=True)
    return checker


def tree_selftest():
    """The tree mode on a small git tree: two tracked makefiles, a file reached
    only through an include, a text file that is not a makefile, an untracked
    makefile; and the same folder before it is a git tree."""
    faults = []
    with tempfile.TemporaryDirectory() as root:
        def put(name, text):
            path = os.path.join(root, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        bad = "X := $(sort b#x a)\n"
        put("Makefile", "Y := 1\ninclude inc/rules.inc\n-include $(Y).mk\n")
        try:
            check_tree(root)
            faults.append("a folder that is not a git tree was read")
        except RuntimeError as exc:
            if "tracked files" not in str(exc):
                faults.append("a folder that is not a git tree was refused for another reason: %s" % exc)
        put("inc/rules.inc", "Y := 2\n" + bad)      # reached only through the include
        put("sub/other.mk", "include Makefile\n" + bad)      # looked up from the root, not from sub/
        put("sub/notes.txt", bad)
        git = ["git", "-C", root, "-c", "user.name=selftest", "-c", "user.email=selftest@example.invalid"]
        for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"]):
            if subprocess.run(git + args, capture_output=True).returncode != 0:
                return ["git %s failed in the fixture" % args[0]]
        put("stray.mk", bad)                  # not tracked: not read
        try:
            checker = check_tree(root)
        except RuntimeError as exc:
            return faults + ["the fixture tree was refused: %s" % exc]
        got = sorted((os.path.relpath(p, root), n) for p, n, _ in checker.findings)
        if got != [("inc/rules.inc", 2), ("sub/other.mk", 2)]:
            faults.append("findings were %r" % (got,))
        if len(checker.seen) != 3:
            faults.append("%d file(s) read, not 3" % len(checker.seen))
    return faults


def selftest():
    cases_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "make381_cases.json")
    try:
        with open(cases_path, encoding="utf-8") as f:
            cases = json.load(f)["cases"]
    except (OSError, ValueError, KeyError) as exc:
        print("MAKE381_NUMBER_SIGN_SELFTEST: ERROR: %s" % exc)
        return 2
    failures = finding = clean = examined = 0
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "case.mk")
        for case in cases:
            examined += 1
            name, expect = case.get("name", "<unnamed>"), case.get("expect")
            if expect not in ("finding", "clean") or "text" not in case:
                print("FAIL: %s has no text or no valid expect" % name)
                failures += 1
                continue
            finding += expect == "finding"
            clean += expect == "clean"
            with open(path, "w", encoding="utf-8") as f:
                f.write(case["text"])
            checker = Checker()
            try:
                checker.check_file(path)
                got = "finding" if checker.findings else "clean"
            except RuntimeError as exc:
                got = "error (%s)" % exc
            print("%s: %s expected %s, got %s" % ("PASS" if got == expect else "FAIL", name, expect, got))
            failures += got != expect
    declared = len(cases)
    if not examined or examined != declared:
        failures += 1
    tree_faults = tree_selftest()
    for fault in tree_faults:
        print("FAIL: tree mode: %s" % fault)
    print("MAKE381_NUMBER_SIGN_SELFTEST: examined=%d declared=%d finding=%d clean=%d failures=%d tree-mode=%s" %
          (examined, declared, finding, clean, failures, "FAIL" if tree_faults else "ok"))
    return 1 if failures or tree_faults else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        if args.files:
            checker = Checker()
            for path in args.files:
                checker.check_file(path)
        else:
            checker = check_tree(os.path.normpath(os.path.join(here, "..")))
    except RuntimeError as exc:
        print("make381-number-sign: ERROR: %s" % exc, file=sys.stderr)
        return 2
    root = os.getcwd()
    for path, line, what in checker.findings:
        print("%s:%d: %s" % (os.path.relpath(path, root), line, what))
    if checker.findings:
        # precheck shows a failing row's last line: it names the first place.
        path, line, _ = checker.findings[0]
        print("make381-number-sign: FAIL: %d finding(s) in %d file(s) read, the first at %s:%d" % (
            len(checker.findings), len(checker.seen), os.path.relpath(path, root), line))
        return 1
    print("make381-number-sign: OK: %d file(s) read (%s), no finding" % (
        len(checker.seen), " ".join(sorted(os.path.relpath(p, root) for p in checker.seen))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
