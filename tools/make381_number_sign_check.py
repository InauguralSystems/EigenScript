#!/usr/bin/env python3
r"""Refuse a number sign that GNU Make 3.81 reads differently from current make (#2448).

Written against GNU Make 3.81, the make of the macOS runners.  Its answers are
the cases of tools/make381_cases.json, each run through a real 3.81 and through
GNU Make 4.3 by tools/make381_oracle.py; --selftest holds this check to them.

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

Stricter than the makes: an assignment nothing expands, and any number sign
inside a reference on a bare line or a recipe line that calls $(eval.  Looser:
a define body that reaches $(eval) through another variable, and a sign that a
variable carries into text $(eval) reads.  Not covered: !=, ::=, undefine,
private, $(file ...), .ONESHELL, --output-sync, an include whose name holds a
reference, and other makefile text that exists only after expansion.

To write the sign inside a call: H := \# at the top level and $H in the call
($$H in text that $(eval) reads again), or the tool's own escape (printf '\043').
"""

import argparse
import json
import os
import re
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
    def __init__(self):
        self.findings = []
        self.seen = set()

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
                body, i = [], i + 1
                while i < len(logical) and logical[i][0].split()[:1] != ["endef"]:
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
            child = os.path.join(os.path.dirname(path), name)
            if os.path.exists(child):
                self.check_file(child, follow=True)
            elif word == "include":
                raise RuntimeError("%s includes %s, which is not there" % (path, name))


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
    print("MAKE381_NUMBER_SIGN_SELFTEST: examined=%d declared=%d finding=%d clean=%d failures=%d" %
          (examined, declared, finding, clean, failures))
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    here = os.path.dirname(os.path.abspath(__file__))
    files = args.files or [os.path.join(here, "..", "Makefile")]
    checker = Checker()
    try:
        for path in files:
            checker.check_file(path, follow=not args.files)
    except RuntimeError as exc:
        print("make381-number-sign: ERROR: %s" % exc, file=sys.stderr)
        return 2
    root = os.getcwd()
    for path, line, what in checker.findings:
        print("%s:%d: %s" % (os.path.relpath(path, root), line, what))
    if checker.findings:
        print("make381-number-sign: FAIL: %d finding(s) in %d file(s) read" % (
            len(checker.findings), len(checker.seen)))
        return 1
    print("make381-number-sign: OK: %d file(s) read, no finding" % len(checker.seen))
    return 0


if __name__ == "__main__":
    sys.exit(main())
