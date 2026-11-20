#!/usr/bin/env python3
r"""Refuse a number sign that GNU Make 3.81 reads differently from current make (#2448).

Written against GNU Make 3.81, the make of the macOS runners.  Its answers are
the cases of tools/make381_cases.json, each run through a real 3.81 and through
GNU Make 4.3 by tools/make381_oracle.py; --selftest holds this check to them.
With no argument it reads every tracked makefile of the tree (git ls-files:
Makefile, makefile, GNUmakefile, *.mk) and each file one of them includes by a
literal name, looked up from the tree's root as make run there does; with
arguments, those files and nothing else.  A file it cannot read, a literal
`include` of a file that is not there and a define without its endef are
errors (exit 2), not a pass.

What is a finding: a number sign, with or without a backslash before it,
inside an open $(...) or ${...} reference
  - on a variable assignment (any operator; also after override or export) or
    on a directive (ifeq, ifneq, ifdef, ifndef, also after else; include,
    -include, sinclude; vpath; export; unexport): 3.81 cuts such a line at its
    first unescaped number sign before it reads it;
  - inside an $(eval ...) call, wherever the call stands (a bare line, a rule
    line, a recipe);
  - in the body of a define whose name is referenced inside an $(eval call of
    the same file ($(NAME), ${NAME}, call NAME, value NAME), outside a comment:
    that body is read as makefile text, and $$( and $${ open a reference there.  No other define body is read, and neither
    is a define inside such a body.
What is not: a rule line (targets, prerequisites, a target-specific
assignment), a recipe line, a bare call that is not eval, a comment.

Which lines are recipe lines: a line that starts with a tab while a rule is
open.  A rule line opens a rule; a target-specific assignment does not, and
closes one.  An assignment, an include, a vpath, an export, an unexport or a
bare line closes the rule.  A conditional, an override line, a define and a
comment leave it as it is.

Stricter than the makes: an assignment nothing expands, a line in a branch of
a conditional that is not taken, a number sign inside an $(eval call that both
makes read as a comment, and a $$( in a body that reaches $(eval) only through
$(value ...), which does not expand it first.  Looser: a define body that reaches $(eval)
through another variable, and a sign that a variable carries into text $(eval)
reads.  Not covered: !=, ::=, undefine, private, export define, $(file ...), a
lone $ at the end of a value, a tab line after a define or an override line
that follows a rule (the two makes disagree whether it is a recipe line),
.ONESHELL, --output-sync, an include whose name holds a reference, and other
makefile text that exists only after expansion.

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
DIRECTIVES = {"include", "-include", "sinclude", "vpath", "export", "unexport"}
MODIFIERS = {"override", "export", "private"}
OPENERS = {"(": ")", "{": "}"}
EVAL = re.compile(r"\$[({]eval\s")
# A name in the place of a variable inside an eval call: $(NAME or ${NAME, and
# the first argument of call and of value.
REFERENCED = re.compile(r"\$[({]([A-Za-z_][A-Za-z0-9_.-]*)")
ARGUMENT = re.compile(r"\b(?:call|value)\s+([A-Za-z_][A-Za-z0-9_.-]*)")
MESSAGE = ("a number sign inside a $( or ${ reference: GNU Make 3.81 reads this "
           "line differently (tools/make381_number_sign_check.py)")


def physical_lines(text):
    """The file's lines as make has them: ended by a newline (with or without
    a carriage return before it); a lone carriage return ends nothing."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [line[:-1] if line.endswith("\r") else line for line in lines]


def logical_lines(lines):
    """Return [(text, line_of_each_character)], continuation lines joined."""
    out = []
    i = 0
    while i < len(lines):
        parts, numbers = [], []
        while i < len(lines):
            raw = lines[i]
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


def first_operator(text, doubled):
    """(kind, offset) of the first = or : outside every reference:
    ("assignment", i) for =, :=, +=, ?=; ("rule", i) for another colon;
    ("bare", None) when there is none."""
    for i, c, depth in walk(text, doubled):
        if depth:
            continue
        if c == "=":
            return "assignment", i
        if c == ":":
            return ("assignment", i) if text[i + 1:i + 2] == "=" else ("rule", i)
    return "bare", None


def target_specific(text, colon, doubled):
    """Is the rule line a target-specific assignment (target: [modifiers] VAR op value)?"""
    rest = text[colon + 1:]
    if rest.startswith(":"):
        rest = rest[1:]
    words = rest.split()
    while words and words[0] in MODIFIERS:
        rest = rest.split(words[0], 1)[1]
        words = words[1:]
    kind, at = first_operator(rest, doubled)
    # The operator follows the first word directly: `t: b ; c=1` is a rule.
    return kind == "assignment" and len(rest[:at].rstrip(":+?").split()) == 1


def eval_calls(text):
    """The (start, end) of every $(eval ...) or ${eval ...} call in the text."""
    spans = []
    for m in EVAL.finditer(text):
        opener = text[m.start() + 1]
        depth, j = 1, m.end()
        while j < len(text) and depth:
            if text[j] == opener:
                depth += 1
            elif text[j] == OPENERS[opener]:
                depth -= 1
            j += 1
        spans.append((m.start(), j))
    return spans


def code_part(text):
    """The text before an ordinary comment: up to the first unescaped number
    sign outside every reference (none of it when the line is a comment)."""
    for i, c, depth in walk(text, False):
        if c == "#" and not depth and not escaped(text, i):
            return text[:i]
    return text


def evaluated_names(logical):
    """Every name referenced inside an $(eval call that is not inside a comment."""
    names = set()
    for line, _ in logical:
        text = code_part(line)
        for start, end in eval_calls(text):
            names.update(REFERENCED.findall(text[start + 6:end]))
            names.update(ARGUMENT.findall(text[start + 6:end]))
    return names


def define_name(words):
    """The name a define line defines, or None when the line is not a define."""
    if words[:1] == ["define"]:
        return words[1] if len(words) > 1 else ""
    if words[:2] == ["override", "define"]:
        return words[2] if len(words) > 2 else ""
    return None


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
            with open(path, encoding="utf-8", newline="") as f:
                logical = logical_lines(physical_lines(f.read()))
        except (OSError, UnicodeDecodeError) as exc:
            raise RuntimeError("cannot read %s: %s" % (path, exc))
        evaluated = evaluated_names(logical)
        top, i = [], 0
        while i < len(logical):
            text, numbers = logical[i]
            name = define_name(text.split())
            if name is None:
                top.append((text, numbers))
                i += 1
                continue
            body, i, depth = [], i + 1, 1
            while i < len(logical):               # a define inside a define nests
                inner = logical[i][0].split()
                if define_name(inner) is not None:
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
            i += 1                                # a define leaves an open rule open
        self.scan(path, top, doubled=False, follow=follow)

    def scan(self, path, logical, doubled, follow):
        rule_open = False
        inner = 0                             # inside a define of the body being read
        for text, numbers in logical:
            stripped = text.strip()
            if not stripped:
                continue
            words = stripped.split()
            if define_name(words) is not None:
                inner += 1                    # its body is a define body: not read
                continue
            if inner:
                inner -= words[:1] == ["endef"]
                continue
            if rule_open and text.startswith("\t"):     # a recipe line, whatever it looks like
                self.judge_eval(path, text, numbers)
                continue
            if stripped.startswith("#"):
                continue
            word = words[0]
            if word in CONDITIONALS or (word == "else" and words[1:2] and words[1] in CONDITIONALS):
                self.judge(path, text, numbers, doubled)      # read, and an open rule stays as it is
                continue
            if word in NO_EFFECT:
                continue
            kind, at = first_operator(text, doubled)
            if word in DIRECTIVES or kind == "assignment":
                self.judge(path, text, numbers, doubled)
                if word != "override":        # 3.81 leaves a rule open across an override line
                    rule_open = False
                if follow and word in ("include", "-include", "sinclude"):
                    self.follow_include(path, stripped[len(word):], word)
            elif kind == "rule":
                self.judge_eval(path, text, numbers)
                rule_open = not target_specific(text, at, doubled)
            else:
                self.judge_eval(path, text, numbers)
                rule_open = False

    def judge(self, path, text, numbers, doubled, start=0, end=None):
        pos = sign_in_reference(text[start:end], doubled)
        if pos is not None:
            self.findings.append((path, numbers[min(start + pos, len(numbers) - 1)], MESSAGE))
            return True
        return False

    def judge_eval(self, path, text, numbers):
        """A number sign anywhere inside an $(eval call."""
        for start, end in eval_calls(text):
            if self.judge(path, text, numbers, True, start, end):
                return

    def follow_include(self, path, rest, word):
        for name in code_part(rest).split():
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
    try:
        q = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True)
    except OSError as exc:
        raise RuntimeError("cannot list the tracked files of %s: %s" % (root, exc))
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
    """The tree mode on a small git tree: two tracked makefiles; files reached
    only through an include, a -include and a sinclude; a text file that is
    not a makefile; an untracked makefile; the same folder before it is a git
    tree; and the three errors (a missing literal include, a define without
    its endef, a file that is not text)."""
    faults = []
    with tempfile.TemporaryDirectory() as root:
        def put(name, text):
            path = os.path.join(root, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)
            return path
        bad = "X := $(sort b#x a)\n"
        put("Makefile", "Y := 1\ninclude inc/rules.inc\n-include $(Y).mk\n"
                        "-include inc/optional.inc nosuch.inc\nsinclude inc/s.inc\n")
        try:
            check_tree(root)
            faults.append("a folder that is not a git tree was read")
        except RuntimeError as exc:
            if "tracked files" not in str(exc):
                faults.append("a folder that is not a git tree was refused for another reason: %s" % exc)
        put("inc/rules.inc", "Y := 2\n" + bad)      # reached only through the include
        put("inc/optional.inc", bad)                # only through the -include
        put("inc/s.inc", "\n\n" + bad)              # only through the sinclude
        # Looked up from the root, not from sub/; the sign is on the third line of the file.
        put("sub/other.mk", "include Makefile\nX := $(sort b \\\n  a#x \\\n  c)\n")
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
        want = [("inc/optional.inc", 1), ("inc/rules.inc", 2), ("inc/s.inc", 3), ("sub/other.mk", 3)]
        if got != want:
            faults.append("findings were %r, not %r" % (got, want))
        if len(checker.seen) != 5:
            faults.append("%d file(s) read, not 5" % len(checker.seen))
        errors = [
            ("a missing literal include", put("e1.mk", "include nosuch.mk\n"), "not at the tree's root"),
            ("a define without its endef", put("e2.mk", "define F\nX := 1\n"), "define never ends"),
            ("a file that is not text", None, "cannot read"),
        ]
        with open(os.path.join(root, "e3.mk"), "wb") as f:
            f.write(b"X := \xe9\n")
        for label, path, want_text in errors:
            try:
                Checker(root).check_file(path or os.path.join(root, "e3.mk"), follow=True)
                faults.append("%s was not an error" % label)
            except RuntimeError as exc:
                if want_text not in str(exc):
                    faults.append("%s was refused for another reason: %s" % (label, exc))
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
            with open(path, "w", encoding="utf-8", newline="") as f:
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
