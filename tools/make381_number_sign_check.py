#!/usr/bin/env python3
r"""Refuse a number sign that GNU Make 3.81 reads differently from current make (#2448).

Written against GNU Make 3.81, the make of the macOS runners.  Its answers are
the cases of tools/make381_cases.json, each run through a real 3.81 and through
GNU Make 4.3 by tools/make381_oracle.py; --selftest holds this check to them.
With no argument it reads every tracked makefile of the tree (git ls-files:
Makefile, makefile, GNUmakefile, *.mk) and each file one of them includes by a
literal name, looked up from the tree's root as make run there does (a
wildcard in the name is expanded; a tilde at its start is the home directory;
a backslash before a blank or a number sign is taken away; an include line in
a body that is read as below is followed too); with arguments, those files
and nothing else.  A file it cannot read, a literal
`include` of a file that is not there and a define whose body never ends are
errors (exit 2), not a pass.

3.81 cuts a line at its first unescaped number sign before it decides whether
the line is a variable assignment or a directive; a rule line, a recipe line
and a bare call it reads as current make does.  This check does not try to
tell every assignment from every rule line.  It passes the lines it is sure
3.81 reads as current make does, and judges every other line.

Lines it passes: an ordinary comment line, whatever it holds: no tab at its
start, and a number sign as its first character after white space.  And, but
for an eval call (below):
  - a recipe line: a tab at its start while a rule is open (below);
  - a rule line: before any ordinary comment it has a colon outside every
    reference and no equals sign outside every reference, and its first word
    is not a directive's (ifeq ifneq ifdef ifndef else endif include -include
    sinclude vpath export unexport override define endef);
  - a bare call: before any ordinary comment it has nothing but references
    and white space.
What is a finding:
  - on every other line, a number sign, with or without a backslash before
    it, inside an open $(...) or ${...} reference, before any ordinary
    comment (an unescaped number sign outside every reference starts one);
  - on every line but an ordinary comment line, a number sign anywhere inside
    an $(eval ...) or $(call eval,...) call (with either kind of bracket),
    wherever on the line the call stands.  A doubled dollar sign before the
    call makes it text and not a call ($$(eval ...) in a recipe is printed),
    except in a body that is read as below, where it is a call again;
  - in the body of a define whose name is written as a word inside such a
    call anywhere in the files read in the same run (the files are read until
    a reading finds no new word in an eval call; an ordinary comment line is
    included, and $$(eval too; a word is what stands between white space,
    dollar signs, brackets, commas and colons; a number sign attached to a
    define's name starts a comment): the body is read by the same rules, with
    $$( and $${ opening a reference as $( and ${ do.  No other define body is
    read, and neither is a define inside such a body;
  - a line that the makes read by what stands around it, in a way this check
    does not follow.  Four kinds: a define line with a tab at its start that
    is not a recipe line; a recipe line whose first word is define or a
    conditional's (ifeq ifneq ifdef ifndef else endif), inside a conditional,
    unless a rule was open at the start of every conditional around it: it
    is a recipe line only if the branch that opened its rule is taken, and
    the directive if it is not; a define inside a
    conditional whose body holds a define of its own or an endef with a tab
    at its start: in a branch that is not taken 3.81 ends it at another line;
    and, wherever it stands, a line whose first word is define or a
    conditional's and whose second word starts with a colon, an equals sign,
    a plus sign or a question mark: it may be a variable or a target of that
    name.

When a rule is open: after a rule line, and after a recipe line.  A blank
line and an ordinary comment line leave it as it is.  After a conditional
(ifeq, ifneq, ifdef or ifndef to its endif) a rule is open only if one was
open before the conditional and one is open at the end of each of its
branches; each branch starts as the conditional was entered.  A line refused
as one of the four kinds leaves it as it is.  Every other line closes it: so
a tab line after a define or an override line that follows
a rule is judged, and there the two makes themselves disagree, whatever the
line holds (3.81 still takes it as a recipe line of that rule; 4.3 does not).
Inside a define's body a line with a tab at its start is neither a define nor
an endef, as in make.

Stricter than the makes (the makes agree, the check refuses; each kind is a
case that says so): a target-specific assignment; a rule line with an equals
sign outside a reference, as in a recipe after a semicolon, and the tab lines
after such a line; the tab lines after a rule that a conditional opened or
may have closed; an else, an endif or an override line with other text after
it; a line of the four kinds above on which the makes happen to agree; an
assignment nothing expands; a line in a branch of a conditional that is not
taken; a line both makes stop on; a number sign inside an eval call that the
makes happen to read alike (as a comment, escaped outside a reference, in
text that is a rule line, in a call after an ordinary comment's sign); a body
read because its name is a word in an eval call that never evaluates it (the
call is in a comment, the word is not a reference, the body reaches eval only
through $(value), the call comes before the define).  Not a case, because a
case is one file: a body is also read when the eval call that names it is in
another file of the same run, whether or not make ever reads the two
together.
Looser (the makes differ, the check passes): a define body that reaches eval
through another variable or a computed name, a define inside an evaluated
body, and a number sign that a variable carries into text eval reads.
Not covered: !=, ::=, undefine, private, export define, $(file ...), a lone $
at the end of a value, .ONESHELL, --output-sync, an include whose name holds a
reference, an include that make finds only in its search directories (-I,
/usr/include), an include written inside an eval call, and other makefile
text that exists only after expansion.

To write the sign inside a call: H := \# at the top level and $H in the call
($$H in text that $(eval) reads again), or the tool's own escape (printf '\043').
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

SPACE = " \t\f\v\r"                     # what make skips at the start of a line
CONDITIONALS = {"ifeq", "ifneq", "ifdef", "ifndef"}
KEYWORDS = CONDITIONALS | {"else", "endif", "include", "-include", "sinclude", "vpath",
                           "export", "unexport", "override", "define", "endef"}
OPENERS = {"(": ")", "{": "}"}
EVAL = re.compile(r"\$[({](?:eval[ \t]|call[ \t]+eval[ \t]*,)")
WORD = re.compile(r"[^\s$(){},:]+")
MESSAGE = ("a number sign inside a $( or ${ reference: GNU Make 3.81 reads this "
           "line differently (tools/make381_number_sign_check.py)")
UNCLEAR = ("a line that the makes read by what stands around it, which this check does not "
           "follow: write it another way (tools/make381_number_sign_check.py)")


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


def line_kind(text, doubled):
    """"rule", "call" or "other", from the text before any ordinary comment:
    "other" with an equals sign outside every reference; else "rule" with a
    colon outside every reference; else "call" with nothing but references
    and blanks; else "other"."""
    colon = equals = more = False
    for i, c, depth in walk(text, doubled):
        if depth:
            continue
        if c == "#" and not escaped(text, i):
            break
        if c == "=":
            equals = True
        elif c == ":":
            colon = True
        elif c not in SPACE:
            more = True
    if equals:
        return "other"
    if colon:
        return "rule"
    return "other" if more else "call"


def eval_calls(text, doubled):
    """The (start, end) of every eval call in the text: $(eval ...), ${eval ...},
    $(call eval,...); it ends at the bracket that closes it.  A dollar sign
    doubled before it makes it text, not a call ($$(eval ...) in a recipe is
    printed); with `doubled`, text that $(eval) expands once more, $$(eval is
    a call again."""
    spans = []
    for m in EVAL.finditer(text):
        dollars = m.start() + 1 - len(text[:m.start() + 1].rstrip("$"))
        if not (dollars % 2 or (doubled and (dollars // 2) % 2)):
            continue
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


def sign_in_eval(text, doubled):
    """Offset of the first number sign inside an eval call, or None."""
    for start, end in eval_calls(text, doubled):
        pos = text.find("#", start, end)
        if pos >= 0:
            return pos
    return None


def code_part(text):
    """The text before an ordinary comment: up to the first unescaped number
    sign outside every reference (none of it when the line is a comment)."""
    for i, c, depth in walk(text, False):
        if c == "#" and not depth and not escaped(text, i):
            return text[:i]
    return text


def evaluated_names(logical):
    """Every word written inside an eval call, on any line of the file (a
    line may be text that $(eval) expands once more: a body's lines are not
    told apart here, so $$(eval counts too)."""
    names = set()
    for text, _ in logical:
        for start, end in eval_calls(text, True):
            names.update(WORD.findall(text[start:end]))
    return names


def blank_words(text):
    return [w for w in re.split("[ \t]+", text.strip(SPACE)) if w]


def first_word(text):
    """The line's first word as 3.81 has it once the comment is cut: up to a
    blank or a number sign."""
    return re.match("[^ \t#]*", text.strip(SPACE)).group(0)


def define_name(text):
    """The name a define line defines, or None when the line is not a define.
    A number sign attached to the name starts a comment, as on any line."""
    words = blank_words(text)
    if first_word(text) == "define":
        return first_word(words[1]) if len(words) > 1 else ""
    if words[:1] == ["override"] and len(words) > 1 and first_word(words[1]) == "define":
        return first_word(words[2]) if len(words) > 2 else ""
    return None


def define_body(logical, i):
    """The lines of the define body that starts at index i, and the index of
    its endef (len(logical) when it never ends).  A line with a tab at its
    start neither nests nor ends, as in make."""
    depth, body = 1, []
    while i < len(logical):
        text = logical[i][0]
        if not text.startswith("\t"):
            words = blank_words(text)
            if words[:1] == ["define"]:
                depth += 1
            elif words[:1] == ["endef"]:
                depth -= 1
                if not depth:
                    return body, i
        body.append(logical[i])
        i += 1
    return body, i


def split_differently(body):
    """Does a define body hold a define of its own, or an endef with a tab
    at its start?  In a branch that is not taken 3.81 ends such a define at
    another line than in a branch that is taken."""
    for text, _ in body:
        words = blank_words(text)
        if words[:1] == ["define"] and not text.startswith("\t"):
            return True
        if words[:1] == ["endef"] and text.startswith("\t"):
            return True
    return False


class Checker:
    def __init__(self, root=None, names=None):
        self.findings = []
        self.seen = set()
        self.root = root                      # where an include's name is looked up
        self.names = names                    # the words of the eval calls of every file read; None: each file's own
        self.words = set()                    # those words, gathered while reading

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
        own = evaluated_names(logical)
        self.words |= own
        self.scan(path, logical, False, follow, own if self.names is None else self.names)

    def scan(self, path, logical, doubled, follow, evaluated):
        is_open = False                       # a rule is open, if every branch around this line is taken
        conditionals = []                     # [open at entry, open at the end of each branch so far, certain at entry]
        i = 0
        while i < len(logical):
            text, numbers = logical[i]
            i += 1
            tab = text.startswith("\t")
            stripped = text.strip(SPACE)
            if not stripped:
                continue
            if stripped.startswith("#") and not tab:
                continue                      # an ordinary comment line
            # Open whether or not the branches around this line are taken.
            certain = is_open and (not conditionals or conditionals[-1][2])
            name = define_name(text)
            word = first_word(text)
            switches = name is not None or word in CONDITIONALS or word in ("else", "endif")
            if switches and blank_words(text)[1:2] and blank_words(text)[1][0] in ":+?=":
                self.findings.append((path, numbers[0], UNCLEAR))   # a variable or a target named like a directive
                continue
            if is_open and tab:               # a recipe line, whatever it looks like
                if switches and not certain:  # ... unless its branch is not taken: then make reads the directive
                    self.findings.append((path, numbers[0], UNCLEAR))
                else:
                    self.judge(path, text, numbers, doubled, strict=False)
                continue
            if name is not None:
                if tab:                       # a define, or a recipe line of a rule not followed here
                    self.findings.append((path, numbers[0], UNCLEAR))
                    continue
                body, end = define_body(logical, i)
                if end == len(logical):
                    raise RuntimeError("%s:%d: define never ends" % (path, numbers[0]))
                if conditionals and split_differently(body):
                    self.findings.append((path, numbers[0], UNCLEAR))
                else:
                    self.judge(path, text, numbers, doubled, strict=True)
                if name in evaluated and not doubled:
                    self.scan(path, body, True, follow, evaluated)
                i = end + 1
                is_open = False
                continue
            if word in CONDITIONALS:
                self.judge(path, text, numbers, doubled, strict=True)
                conditionals.append([is_open, True, certain])
            elif word == "else":
                self.judge(path, text, numbers, doubled, strict=True)
                if conditionals:
                    conditionals[-1][1] = conditionals[-1][1] and is_open
                    is_open = conditionals[-1][0]
                else:
                    is_open = False
            elif word == "endif":
                self.judge(path, text, numbers, doubled, strict=True)
                if conditionals:
                    entry, branches, _ = conditionals.pop()
                    is_open = entry and branches and is_open
                else:
                    is_open = False
            elif word in KEYWORDS:
                self.judge(path, text, numbers, doubled, strict=True)
                is_open = False
                if follow and word in ("include", "-include", "sinclude"):
                    self.follow_include(path, stripped[len(word):], word)
            else:
                kind = line_kind(text, doubled)
                self.judge(path, text, numbers, doubled, strict=kind == "other")
                is_open = kind == "rule"

    def judge(self, path, text, numbers, doubled, strict):
        """At most one finding for the line: a number sign inside an eval
        call, and on a line that is not passed, inside any reference."""
        places = [sign_in_eval(text, doubled)]
        if strict:
            places.append(sign_in_reference(text, doubled))
        places = [p for p in places if p is not None]
        if places:
            self.findings.append((path, numbers[min(min(places), len(numbers) - 1)], MESSAGE))

    def follow_include(self, path, rest, word):
        for name in include_names(rest):
            if "$" in name:
                continue                      # a computed name: not followed (header)
            # make looks an include up from its working directory: the tree's root here.
            child = os.path.join(self.root, os.path.expanduser(name))
            found = [child] if os.path.exists(child) else sorted(glob.glob(child))
            for one in found:
                self.check_file(one, follow=True)
            if not found and word == "include":
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


def include_names(rest):
    """The names on an include line: split at blanks; a backslash before a
    blank, a number sign or a backslash is taken away, as make does."""
    names, name, i, text = [], "", 0, code_part(rest)
    while i < len(text):
        c = text[i]
        if c == "\\" and text[i + 1:i + 2] and text[i + 1] in " \t#\\":
            name += text[i + 1]
            i += 2
            continue
        if c in " \t":
            if name:
                names.append(name)
            name = ""
        else:
            name += c
        i += 1
    return names + ([name] if name else [])


def check_files(paths, root=None, follow=False):
    """Read the files again and again, each time with the words of every eval
    call of every file reached so far, until a reading finds no new word (the
    next one would then be the same): a define in one file is read when
    another file evaluates it, and a file that only an evaluated body
    includes is reached and its eval calls counted.  The last reading's
    findings are the answer."""
    names = set()
    while True:
        checker = Checker(root, names)
        for path in paths:
            checker.check_file(path, follow)
        if checker.words <= names:
            return checker
        names = names | checker.words


def check_tree(root):
    """Read every tracked makefile of the tree and what each includes by a literal name."""
    return check_files(tracked_makefiles(root), root, True)


def tree_selftest():
    """The tree mode on a small git tree: three tracked makefiles; files
    reached only through an include, a -include (the second name of its line)
    and a sinclude, through a wildcard, through a name with an escaped number
    sign, through a tilde and through an include line of an evaluated body; a
    define that another file evaluates; a text file that is
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
                        "-include nosuch.inc inc/optional.inc\nsinclude inc/s.inc\n"
                        "include inc2/*.mk\n-include a\\#b.inc\ninclude defs.inc\n$(eval $(F))\n"
                        "-include ~/t.inc\n")
        try:
            check_tree(root)
            faults.append("a folder that is not a git tree was read")
        except RuntimeError as exc:
            if "tracked files" not in str(exc):
                faults.append("a folder that is not a git tree was refused for another reason: %s" % exc)
        put("inc/rules.inc", "Y := 2\n" + bad)      # reached only through the include
        put("inc/optional.inc", bad)                # only through the -include
        put("inc/s.inc", "\n\n" + bad)              # only through the sinclude
        put("inc2/w.mk.in", bad)                    # not matched by the wildcard
        put("inc2/w.inc", bad)                      # not matched either
        put("inc2/wild.mk", bad)                    # tracked as a makefile too: read once
        put("a#b.inc", bad)                         # only through the escaped name
        # Its body is evaluated by the Makefile, not by itself.
        put("defs.inc", "define F\nX := $$(sort b#x a)\ninclude inc/body.inc\nendef\n"
                        "define G\nZ := $$(sort b#x a)\nendef\n")
        # Reached only through the include line of F's body; it evaluates G,
        # so G's body is read only on a third reading.
        put("inc/body.inc", bad + "$(eval $(G))\n")
        put("home/t.inc", bad)                      # only through the tilde
        # Looked up from the root, not from sub/; the sign is on the third line of the file.
        put("sub/other.mk", "include Makefile\nX := $(sort b \\\n  a#x \\\n  c)\n")
        put("sub/notes.txt", bad)
        git = ["git", "-C", root, "-c", "user.name=selftest", "-c", "user.email=selftest@example.invalid"]
        for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"]):
            if subprocess.run(git + args, capture_output=True).returncode != 0:
                return ["git %s failed in the fixture" % args[0]]
        put("stray.mk", bad)                  # not tracked: not read
        home = os.environ.get("HOME")
        os.environ["HOME"] = os.path.join(root, "home")   # where the fixture's tilde leads
        try:
            checker = check_tree(root)
        except RuntimeError as exc:
            return faults + ["the fixture tree was refused: %s" % exc]
        finally:
            if home is None:
                del os.environ["HOME"]
            else:
                os.environ["HOME"] = home
        got = sorted((os.path.relpath(p, root), n) for p, n, _ in checker.findings)
        want = [("a#b.inc", 1), ("defs.inc", 2), ("defs.inc", 6), ("home/t.inc", 1), ("inc/body.inc", 1),
                ("inc/optional.inc", 1), ("inc/rules.inc", 2), ("inc/s.inc", 3), ("inc2/wild.mk", 1),
                ("sub/other.mk", 3)]
        if got != want:
            faults.append("findings were %r, not %r" % (got, want))
        if len(checker.seen) != 10:
            faults.append("%d file(s) read, not 10" % len(checker.seen))
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
            checker = check_files(args.files)
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
