#!/usr/bin/env python3
# Doc-example checker: every ```eigenscript block in the given Markdown files
# is EXECUTED. Opt-OUT, not opt-in.
#
# Why opt-out (measured on main f532c8d, 2026-09-16): under the old opt-in
# rule a fence ran only if an author paired it with an ```output block, and
# README.md carried 9 eigenscript fences of which 3 ran. Across README.md +
# docs/*.md there were 180 eigenscript fences and 98 ran; docs/SYNTAX.md ran
# 0 of 35, docs/PREDICATES.md 0 of 13, and docs/llms.txt — the file every
# agent primes on — 0 of 4. An example nobody executes is a claim, and the
# ones that rot are exactly the ones nobody paired.
#
# THE TAG GRAMMAR (the info string after "eigenscript"):
#
#   (no tag)            a whole program. The next block MUST be an ```output
#                       block; stdout is compared byte-for-byte.
#   check               the same thing. Retained because README.md used it as
#                       the old opt-IN marker; it now marks nothing, because
#                       everything is in.
#   fragment k=v k=v    NOT a whole program: the snippet has free names. The
#                       tag DECLARES them; the checker generates
#                       "k is v" lines ahead of the snippet, runs the result,
#                       and requires a clean run (rc 0, empty stderr) AND a
#                       clean `--lint` E003 pass, so a free name hiding in a
#                       branch that never executes is still caught. Output
#                       is not compared — the point is that it RUNS. A value
#                       may not contain spaces (the tag is whitespace-split);
#                       write [1,2,3], not [1, 2, 3].
#   nocheck <reason>    deliberately not executed. The reason is REQUIRED on
#                       the same line, must contain no backtick or tilde (the
#                       fence walk reserves those), and is printed, so an
#                       exemption cannot be silent. (The old "skip" spelling is gone: it
#                       carried no reason, which is how five unexecuted
#                       examples sat unexamined.)
#
#   Anything else after "eigenscript" is an ERROR — an unknown tag must not
#   decay into "some other language's block".
#
#   An UNTAGGED eigenscript fence with no following ```output block is RED.
#   Non-code content in a fence gets a non-eigenscript info string (text,
#   output, bash), which is what those mean.
#
# Populations are PINNED per file (mechanical-gates §121: "some examples ran"
# is what a gutted gate also prints), and the fence count is CROSS-CHECKED
# against an independent line scanner (§122), so the walk cannot quietly stop
# seeing a document.
#
# Usage: test_doc_examples.py [--list] file.md [file2.md ...]
#        test_doc_examples.py --selftest

import re
import subprocess
import sys
import os
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
EIGS = os.environ.get("EIGENSCRIPT", os.path.join(ROOT, "src", "eigenscript"))

PASS = 0
FAIL = 0
SKIP = 0
ORPHAN = 0

# #946: a fence may be indented, or nested inside a blockquote or list item.
# All of those are valid CommonMark and render normally on GitHub — but the
# old column-zero-only pattern could not see them, so such an example was
# never run and never compared, with no diagnostic. The document looked gated
# while part of it was not. Silence was the bug, not the missing coverage.
# #946: a fence may be indented, nested in a blockquote, or inside a list
# item, and may use tildes or more than three backticks. All of those are
# valid CommonMark and render normally on GitHub — the old column-zero-only
# pattern could see none of them, so such an example was never run, never
# compared, and never mentioned.
#
# Recognising MORE is only half the job. The first cut of this fix matched
# indentation and blockquotes but not list items, and a list-item fence then
# desynchronised the walk: its CLOSING fence was read as an OPENING one,
# every later info string shifted by one, and a plain top-level example that
# the old parser checked was silently dropped. Coverage went DOWN while the
# gate still printed exit 0. Hence the reporter below.
# `args` is the REST OF THE LINE, not one more token: the fragment tag carries
# its bindings there (```eigenscript fragment i=0 n=3) and the old
# single-token pattern could not match such a line at all — it fell through to
# "unreadable info string" and the block went unchecked, which is the failure
# this file exists to prevent.
FENCE = re.compile(
    r"^(?P<prefix>[ \t]*(?:(?:[-*+]|\d+[.)])[ \t]+)?(?:>[ \t]*)*)"
    r"(?P<fence>`{3,}|~{3,})"
    r"[ \t]*(?P<info>[^\s`~]*)[ \t]*(?P<args>[^`~]*?)[ \t]*$")

# The reporter. It must be looser than FENCE on EVERY axis it polices
# (mechanical-gates §12) — the first cut shared the prefix alphabet `[ \t>]`
# with FENCE and hardcoded exactly three backticks, so it could not fire on
# any shape FENCE could not open, which is precisely the set it existed to
# catch. It is therefore built independently: any leading run of whitespace,
# blockquote markers and list markers, then three or more backticks OR
# tildes, with no constraint on what follows.
FENCE_LOOSE = re.compile(r"^[ \t]*(?:[-*+]|\d+[.)])?[ \t>]*(?:`{3,}|~{3,})")

# Info strings we will act on. Anything else that opened a fence is reported
# rather than assumed harmless — a garbage info string (e.g. from a fence the
# regex mis-split) must not pass as "some other language's block".
KNOWN_INFO = ("eigenscript", "output", "")

UNSEEN_FENCES = []   # (path, lineno, raw, why) — reported by main(), never dropped


# RESIDUALS of the dedent, measured rather than assumed:
#
#  * Indentation is counted in CHARACTERS, not display columns. A fence
#    indented with a TAB whose body is indented with SPACES therefore
#    under-strips, leaving the example with spurious leading whitespace. That
#    degrades LOUDLY, not silently — the extracted program hits
#    "Parse error: unexpected indent" and the gate reports a mismatch
#    (verified: `   print of 1` exits 1). Not fixed because no document in the
#    repo mixes them; if one ever does, the failure names the file.
#  * A blank line inside a BLOCKQUOTED fence ends the blockquote for a
#    CommonMark renderer but not for this walk, so the gate can read slightly
#    more than a reader sees. Same direction: any divergence surfaces as a
#    failing example, never as a silent pass.


def _dedent(line, indent, depth):
    """Strip a fence's own prefix from one of its body lines.

    Removes at most `indent` leading whitespace characters and `depth`
    blockquote markers, so the example's OWN indentation survives intact —
    EigenScript is indentation-sensitive, and stripping more than the fence
    carried would silently rewrite the program under test.
    """
    k = 0
    while k < indent and k < len(line) and line[k] in " \t":
        k += 1
    s = line[k:]
    for _ in range(depth):
        s = s.lstrip(" \t")
        if s.startswith(">"):
            s = s[1:]
            if s[:1] in (" ", "\t"):
                s = s[1:]
    return s


def blocks(path):
    """Yield (lineno, info, args, text) for each fenced block."""
    with open(path) as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if m:
            prefix = m.group("prefix")
            marker = m.group("fence")
            depth = prefix.count(">")
            # A list marker's width indents the block's continuation lines,
            # so it counts as indentation for the dedent even though it is
            # not repeated on those lines.
            indent = len(prefix) if depth == 0 else (
                len(prefix) - len(prefix.lstrip(" \t")))
            info = m.group("info")
            start = i + 1
            j = start
            closed = False
            while j < len(lines):
                d = _dedent(lines[j], indent, depth).lstrip(" \t")
                if d.startswith(marker[0] * 3) and len(
                        d) - len(d.lstrip(marker[0])) >= len(marker):
                    closed = True
                    break
                j += 1
            if not closed:
                # An unterminated fence would otherwise swallow the rest of
                # the document, taking every later example with it.
                UNSEEN_FENCES.append(
                    (path, i + 1, lines[i].rstrip("\n"), "never closed"))
            elif info not in KNOWN_INFO:
                # Not an EigenScript example — but say so only for shapes we
                # could plausibly have mis-parsed, never for ordinary ```sh.
                if "`" in info or "~" in info:
                    UNSEEN_FENCES.append(
                        (path, i + 1, lines[i].rstrip("\n"),
                         "unreadable info string %r" % info))
            text = "".join(_dedent(l, indent, depth) for l in lines[start:j])
            yield (i + 1, info, m.group("args"), text)
            i = j + 1
        else:
            if FENCE_LOOSE.match(lines[i]):
                UNSEEN_FENCES.append(
                    (path, i + 1, lines[i].rstrip("\n"), "not recognised"))
            i += 1



def norm(s):
    return "\n".join(line.rstrip() for line in s.rstrip("\n").split("\n"))


LSAN_MARKER_LINE = re.compile(
    r"^(?:==\d+==ERROR: )?LeakSanitizer: detected memory leaks$")
LSAN_SUMMARY_LINE = re.compile(
    r"^SUMMARY: (?:AddressSanitizer|LeakSanitizer): \d+ byte\(s\) "
    r"leaked in \d+ allocation\(s\)\.$")
LSAN_LEAK_KIND_LINE = re.compile(
    r"^(?:Direct|Indirect) leak of \d+ byte\(s\) in \d+ object\(s\) "
    r"allocated from:$")
LSAN_FRAME_LINE = re.compile(
    r"^#\d+\s+0x[0-9A-Fa-f]+(?:\s+in\s+.+|\s+\(.+\))$")
LSAN_OBJECT_HEADER = "Objects leaked above:"
LSAN_OBJECT_ADDRESS_LINE = re.compile(r"^0x[0-9A-Fa-f]+ \(\d+ bytes\)$")
LSAN_SEPARATOR_LINE = re.compile(r"^(?:=+|-+)$")
LSAN_SUPPRESSION_HEADER = "Suppressions used:"
LSAN_SUPPRESSION_COLUMNS = re.compile(r"^count\s+bytes\s+template$")
LSAN_SUPPRESSION_ROW = re.compile(r"^\d+\s+\d+\s+\S.*$")


def is_lsan_only_failure(stderr):
    """Return whether stderr contains only a standalone or full LSan report."""
    lines = [line.strip() for line in stderr.splitlines() if line.strip()]
    markers = [i for i, line in enumerate(lines)
               if LSAN_MARKER_LINE.fullmatch(line) is not None]
    if len(lines) == 1:
        return bool(markers)
    if False:
        return False

    summaries = [i for i, line in enumerate(lines)
                 if LSAN_SUMMARY_LINE.fullmatch(line) is not None]
    if len(summaries) != 1 or summaries[0] != len(lines) - 1:
        return False

    index = 0
    if not LSAN_SEPARATOR_LINE.fullmatch(lines[index]):
        return False
    index += 1
    if (index >= len(lines) or
            LSAN_MARKER_LINE.fullmatch(lines[index]) is None):
        return False
    index += 1

    leak_blocks = 0
    while (index < len(lines) and
           LSAN_LEAK_KIND_LINE.fullmatch(lines[index]) is not None):
        leak_blocks += 1
        index += 1

        frames = 0
        while (index < len(lines) and
               LSAN_FRAME_LINE.fullmatch(lines[index]) is not None):
            frames += 1
            index += 1
        if frames == 0:
            return False

        # #980: the "Objects leaked above:" section is OPTIONAL. compiler-rt
        # emits it only under LSAN_OPTIONS=report_objects=1; CI and the
        # documented local loop both run ASAN_OPTIONS=detect_leaks=1 with no
        # LSAN_OPTIONS, so requiring it rejected ordinary real leak reports —
        # i.e. a genuine leak-only failure was classified as a hard sanitizer
        # error, the inverse of the tolerance #945/#953 added. Captured proof of
        # both shapes lives in tests/fixtures/lsan_classify/leak/ as
        # real-asan-leak-only.txt (default) and real-asan-leak-report-objects.txt.
        #
        # Optional, NOT lax: when the header IS present the section must still
        # be well-formed, and every other constraint in this walk is unchanged.
        # The failure mode on this side is a false TOLERANCE, so nothing else
        # here was relaxed.
        if index < len(lines) and lines[index] == LSAN_OBJECT_HEADER:
            index += 1

            objects = 0
            while (index < len(lines) and
                   LSAN_OBJECT_ADDRESS_LINE.fullmatch(lines[index]) is not None):
                objects += 1
                index += 1
            if objects == 0:
                return False

    if leak_blocks == 0:
        return False

    if index < len(lines) and LSAN_SEPARATOR_LINE.fullmatch(lines[index]):
        index += 1
        if index >= len(lines) or lines[index] != LSAN_SUPPRESSION_HEADER:
            return False
        index += 1
        if (index >= len(lines) or
                LSAN_SUPPRESSION_COLUMNS.fullmatch(lines[index]) is None):
            return False
        index += 1
        while (index < len(lines) and
               LSAN_SUPPRESSION_ROW.fullmatch(lines[index]) is not None):
            index += 1
        if index >= len(lines) or not LSAN_SEPARATOR_LINE.fullmatch(lines[index]):
            return False
        index += 1

    return index == len(lines) - 1


def is_asan_build():
    # Use the same __asan_init probe as test_temporal_memory.sh and
    # test_http_rss_growth.sh to classify the selected binary. Those tests
    # refuse to run on sanitizer builds; this checker uses the classification
    # only to tolerate a nonzero example exit with a standalone or complete
    # LeakSanitizer-only report.
    return subprocess.run(
        ["grep", "-qa", "__asan_init", EIGS],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


# ---------------------------------------------------------------------------
# PINNED POPULATIONS (mechanical-gates §121). Keys are paths relative to the
# repo root; a document under the repo root that carries eigenscript fences
# and is NOT in this table fails the ENROLMENT check below, so a new doc
# cannot join the tree unexamined (§119).
#
# Each row is (fences, paired, fragment, nocheck). Changing one is a
# deliberate edit with a visible diff; a silent shrink — the failure mode a
# "more than zero" floor cannot see — is impossible.
# ---------------------------------------------------------------------------
POPULATION = {
    # file                       fences paired fragment nocheck value-comments
    "README.md":                 (  8,    3,     5,      0,      0),
    "docs/llms.txt":             (  5,    3,     2,      0,      0),
    "docs/SPEC.md":              ( 75,   71,     1,      3,      0),
    "docs/COMPARISON.md":        ( 19,   18,     1,      0,      0),
    "docs/CONCURRENCY.md":       (  7,    7,     0,      0,      0),
    "docs/STDLIB.md":            ( 15,    7,     8,      0,      0),
    "docs/SYNTAX.md":            ( 35,   15,    20,      0,      1),
    "docs/PREDICATES.md":        ( 13,    2,    10,      1,      4),
    "docs/DIAGNOSTICS.md":       (  3,    0,     3,      0,      0),
    "docs/OBSERVER.md":          (  2,    0,     2,      0,      0),
    "docs/BUILTINS.md":          (  1,    1,     0,      0,      0),
    "docs/LANGUAGE_CONTRACT.md": (  1,    0,     1,      0,      0),
}

# §122: the fence count the WALK reports must equal the count a completely
# different mechanism finds — a flat line scan with no fence state at all.
# The walk is the thing under suspicion (a desynchronised walk silently drops
# examples; that is #946's whole history), so its own output cannot be its own
# population.
INDEP_EIGS_FENCE = re.compile(
    r"^[ \t>]*(?:(?:[-*+]|\d+[.)])[ \t]+)?[ \t>]*(?:`{3,}|~{3,})eigenscript\b")

# A fence may legitimately QUOTE the opening line of an eigenscript fence
# while documenting the tag grammar. Such a line is inside another fence, so
# the walk does not see it; the flat scanner does. Rather than teach the
# scanner about fences (which would make it the walk again), a quoted opener
# is written with this marker so both mechanisms agree by construction.
INDEP_SKIP = "docs-gate: quoted fence opener"

TAG_KINDS = ("", "check", "fragment", "nocheck")

# ---------------------------------------------------------------------------
# ROUND 2 (Astra, G4): a comment inside an EXECUTED example that states a
# VALUE is an unchecked claim wearing a checked example's clothes. Measured:
# README.md said `# "converged"  (after 25 steps, loss ~ 1.5e-06)` beside a
# green, byte-compared example whose real answer is 35 steps and
# 1.4551915228366852e-09. The example passed; the sentence next to it was
# wrong by three orders of magnitude.
#
# The detector is deliberately the SAME expression the round-2 brief used to
# enumerate the class, so the gate's population and a hand `grep -nE` cannot
# disagree about what the class IS.
VALUE_COMMENT = re.compile(r"#.*(after|gives|prints|≈|~) *[0-9]")

# Each site is either rewritten so the paired output carries the value, or
# waived here by its EXACT stripped line with a reason (§125). Keyed by
# (basename, stripped line).
VALUE_COMMENT_WAIVERS = {
    ("SYNTAX.md", 'eval of "print of 42"              # prints 42'):
        "the paired output block below prints 42; the comment restates a value "
        "the gate already compares byte-for-byte",
    ("PREDICATES.md", "x is x * 0.999        # genuine motion, but each step is ~0.1%"):
        "0.1% is the multiplier 0.999 restated in words, not a measured result",
    ("PREDICATES.md",
     'report of x               # "converged"  — settled AT THE DEADBAND; x is ~98, not ~0'):
        "the teaching point is WHICH verdict, not the exact x; the verdict "
        "itself is checked by the paired output",
    ("PREDICATES.md", "x is x * 0.7          # 100 → ~1: steps contracting toward a limit"):
        "an order-of-magnitude illustration of the contraction, not a claimed "
        "final value",
    ("PREDICATES.md", "x is x * 1.43         # 1 → ~105: non-vanishing same-sign steps"):
        "an order-of-magnitude illustration of the growth, not a claimed final "
        "value",
}
VALUE_COMMENT_WAIVERS_USED = set()

# The pins above describe THIS repository. tests/test_doc_examples_markers.py
# copies this checker into a throwaway workspace and drives it over synthetic
# documents, and a pin for the real README.md must not fire against those. The
# discriminator is a file only the real tree has — and because a silently
# inactive pin table is exactly the vacuity §121 is about, main() PRINTS
# whether pinning is active and how many rows it applied, and the suite
# section requires that line.
IN_REAL_TREE = os.path.isfile(os.path.join(ROOT, "Makefile")) and \
               os.path.isfile(os.path.join(ROOT, "VERSION"))


def split_bindings(rest):
    """Whitespace-split; single quotes group and are removed."""
    toks, cur, quoted = [], "", False
    for ch in rest:
        if ch == "'":
            quoted = not quoted
            continue
        if ch.isspace() and not quoted:
            if cur:
                toks.append(cur)
                cur = ""
            continue
        cur += ch
    if quoted:
        raise ValueError("unbalanced ' in the fragment tag")
    if cur:
        toks.append(cur)
    return toks


def parse_tag(args):
    """Return (kind, rest, error) for the info-string remainder."""
    args = (args or "").strip()
    if args == "":
        return ("", "", None)
    head = args.split()[0]
    rest = args[len(head):].strip()
    if head in ("", "check"):
        return ("check", rest, None)
    if head == "fragment":
        bindings = []
        # Hand-rolled, because shlex is the wrong tool twice over: in posix
        # mode it EATS the double quotes that must survive into the generated
        # program (x="hi" is an EigenScript string literal), and in non-posix
        # mode it does not group a quote that starts mid-token, which is
        # exactly where a binding's quote lives (f='(v) => v + 1').
        # So: whitespace splits, SINGLE quotes group and are stripped,
        # double quotes are ordinary characters.
        try:
            toks = split_bindings(rest)
        except ValueError as e:
            return ("fragment", rest, "fragment bindings do not parse: %s" % e)
        for tok in toks:
            if "=" not in tok or not tok.split("=", 1)[0]:
                return ("fragment", rest,
                        "fragment binding %r is not name=value" % tok)
            name, value = tok.split("=", 1)
            if not value:
                return ("fragment", rest,
                        "fragment binding %r has an empty value" % tok)
            bindings.append((name, value))
        return ("fragment", bindings, None)
    if head == "nocheck":
        if not rest:
            return ("nocheck", "",
                    "a 'nocheck' fence must state its reason on the same line")
        return ("nocheck", rest, None)
    return (None, rest,
            "unknown eigenscript fence tag %r (known: check, fragment, nocheck)"
            % head)


def report_orphan(path, pending):
    global ORPHAN
    code_line, _ = pending
    ORPHAN += 1
    print("  FAIL: %s:%d (untagged eigenscript fence with no ```output block; "
          "pair it, tag it `eigenscript fragment ...`, or tag it "
          "`eigenscript nocheck <reason>`)" % (path, code_line))


E003_LINE = re.compile(r"error\[E003\]: undefined name '([^']+)'")


def undeclared_names(code):
    """Names the fragment uses that nothing binds — resolved STATICALLY.

    ROUND 2 (Astra, G5): running the fragment only resolves the names on the
    path that EXECUTES. A free name inside `if false:` was never looked up, so
    a fragment with an undeclared binding passed 1/1. `eigenscript --lint`'s
    E003 pass already enumerates "undefined name 'X' — no binding on any path"
    over the whole program, which is the question being asked; use it rather
    than inventing a second name resolver (mechanical-gates §1 — ask the tool).

    Only E003 is read. `--lint` exits nonzero on ordinary W-warnings too
    (W001 unused, W016 bare predicate), and those are style, not a broken
    example — gating on its exit code would reject correct fragments.
    """
    with tempfile.NamedTemporaryFile("w", suffix=".eigs", delete=False) as tf:
        tf.write(code)
        tmp = tf.name
    try:
        try:
            p = subprocess.run([os.path.abspath(EIGS), "--lint", tmp],
                               capture_output=True, text=True, timeout=20,
                               stdin=subprocess.DEVNULL,
                               cwd=os.path.dirname(tmp))
        except subprocess.TimeoutExpired:
            return ["error[E003]: <lint timed out after 20s>"]
        out = p.stdout + p.stderr
        # ROUND 3 (Astra, H4): return the LINT'S OWN LINES, not just the names.
        # The round-2 message said "uses 1 undeclared free name(s): x" and
        # dropped the rule code, so a reader could not grep E003 to find what
        # the gate had actually asked. Quote the instrument (§58).
        return [l.strip() for l in out.splitlines() if E003_LINE.search(l)]
    finally:
        os.unlink(tmp)


def check_value_comments(path, fence_line, text):
    """Count value-bearing comments in one executed fence; FAIL the unwaived.

    Returns how many were found (waived or not) so the per-file population can
    be pinned: a NEW value comment is red until somebody decides what it is.
    """
    global FAIL
    found = 0
    base = os.path.basename(path)
    for k, raw in enumerate(text.split("\n")):
        line = raw.strip()
        if not line or "#" not in line:
            continue
        if not VALUE_COMMENT.search(line):
            continue
        found += 1
        key = (base, line)
        if key in VALUE_COMMENT_WAIVERS:
            VALUE_COMMENT_WAIVERS_USED.add(key)
            continue
        FAIL += 1
        print("  FAIL: %s:%d states a VALUE in a comment inside an executed "
              "example, and nothing checks it: %s"
              % (path, fence_line + 1 + k, line))
        print("    fix: print the value so the paired ```output block compares "
              "it, or add this exact line to VALUE_COMMENT_WAIVERS with a "
              "reason")
    return found


def run_program(code, timeout=20):
    """Run one snippet and return (returncode, stdout, stderr)."""
    with tempfile.NamedTemporaryFile("w", suffix=".eigs", delete=False) as tf:
        tf.write(code)
        tmp = tf.name
    try:
        # cwd = the temp script's directory so cwd-relative and
        # script-relative paths coincide. (On macOS the Python tempdir is
        # /var/folders/..., not /tmp — examples must not assume either.)
        try:
            p = subprocess.run([os.path.abspath(EIGS), tmp],
                               capture_output=True, text=True, timeout=timeout,
                               stdin=subprocess.DEVNULL,
                               cwd=os.path.dirname(tmp))
        except subprocess.TimeoutExpired:
            # A doc example that does not terminate is a failing example, not
            # a crashed harness: rc 124 is the shell's own spelling for it and
            # a hang is the worst thing a gate can do (mechanical-gates §136).
            return (124, "", "the example did not finish within %ds" % timeout)
        return (p.returncode, p.stdout, p.stderr)
    finally:
        os.unlink(tmp)


def clean_run(rc, stderr, asan_build):
    """A fragment must run CLEAN — and clean means stderr too.

    The runtime is fail-soft in places: an undefined variable prints
    "Error line N: undefined variable 'x'" to STDERR and still exits 0
    (measured 2026-09-16). Gating a fragment on the exit code alone would
    therefore accept exactly the fault the fragment tag exists to catch — a
    free name the tag forgot to declare.
    """
    lsan_only = asan_build and rc != 0 and is_lsan_only_failure(stderr)
    if rc != 0 and not lsan_only:
        return False
    if asan_build and is_lsan_only_failure(stderr):
        return True
    # "Warning:" lines are a documented part of some APIs' contract
    # (set_observer_thresholds announces the change). They are tolerated but
    # never hidden — main() prints them beside the PASS line. Everything else
    # on stderr is a hard diagnostic and fails, whatever the exit code says.
    return not hard_stderr_lines(stderr)


def hard_stderr_lines(stderr):
    return [l for l in stderr.splitlines()
            if l.strip() and not l.startswith("Warning:")]


def count_fences(path):
    """Number of ```eigenscript fences in one file.

    ROUND 11 (H1) — THIS FILE IS THE ONE AUTHORITY FOR "WHAT IS A FENCE".
    tools/docs_claims_check.sh used to re-implement the fence grammar as an
    ERE so it could count fences per document. The two implementations
    disagreed the moment they met a different grep: BSD grep rejected the
    shell's ERE outright, every file counted 0, and the DOC ENROLMENT
    population collapsed to zero on macOS. One grammar, in the gate that
    EXECUTES the fences, asked over a documented interface — and Python is
    portable where a platform's grep is not.
    """
    n = 0
    for _lineno, info, _args, _text in blocks(path):
        if info == "eigenscript":
            n += 1
    return n


def count_mode(paths):
    """--count: print `path<TAB>n` per file. Any failure is LOUD.

    Callers derive a population from these lines, so a failure that printed
    nothing would read as "this document has no examples" — the exact
    vacuity this mode exists to remove. Every error goes to stderr AND makes
    the exit code non-zero; a caller that sees either must go red.
    """
    if not paths:
        sys.stderr.write("count: no files given — a count of nothing is not a count\n")
        return 2
    rc = 0
    for p in paths:
        if not os.path.isfile(p):
            sys.stderr.write("count: not a file: %s\n" % p)
            rc = 2
            continue
        try:
            n = count_fences(p)
        except Exception as exc:                      # noqa: BLE001 - reported
            sys.stderr.write("count: %s: %s: %s\n"
                             % (p, type(exc).__name__, exc))
            rc = 2
            continue
        # UNSEEN_FENCES is deliberately NOT consulted here: an unreadable or
        # unclosed fence is section [89]'s verdict to give, and this mode must
        # answer exactly one question (how many eigenscript fences) so its
        # caller cannot mistake a second verdict for the first.
        sys.stdout.write("%s\t%d\n" % (p, n))
    del UNSEEN_FENCES[:]
    return rc


def main():
    global PASS, FAIL, SKIP
    args = [a for a in sys.argv[1:] if a != "--list"]
    listing = "--list" in sys.argv
    # ROUND 8: the same one-line banner the claims gate prints. A platform
    # difference should identify itself in the CI log on the FIRST run, not
    # after two rounds of guessing at a machine nobody here can boot.
    if not listing:
        print("doc-examples env: python %s, %s, EIGS=%s (%s)"
              % (sys.version.split()[0], " ".join(os.uname()[:1] + os.uname()[2:3])
                 if hasattr(os, "uname") else sys.platform,
                 EIGS, "present" if os.path.exists(EIGS) else "ABSENT"))
    coverage_failed = False
    population_failed = False
    asan_build = is_asan_build()

    for path in args:
        rel = os.path.relpath(os.path.realpath(path), os.path.realpath(ROOT))
        pinned = POPULATION.get(rel) if IN_REAL_TREE else None
        is_readme = (os.path.realpath(path) ==
                     os.path.realpath(os.path.join(ROOT, "README.md")))
        pending = None  # (lineno, code) awaiting an output block
        readme_checked = 0
        n_fence = n_paired = n_fragment = n_nocheck = n_valuecomment = 0
        for lineno, info, arg, text in blocks(path):
            if info == "eigenscript":
                if pending is not None:
                    report_orphan(path, pending)
                    pending = None
                n_fence += 1
                kind, payload, err = parse_tag(arg)
                if err is not None:
                    FAIL += 1
                    print("  FAIL: %s:%d %s" % (path, lineno, err))
                    continue
                if kind == "nocheck":
                    n_nocheck += 1
                    SKIP += 1
                    if not listing:
                        print("  NOCHECK: %s:%d — %s"
                              % (os.path.basename(path), lineno, payload))
                    continue
                if kind in ("", "check", "fragment"):
                    n_valuecomment += check_value_comments(path, lineno, text)
                if kind == "fragment":
                    n_fragment += 1
                    if listing:
                        print("would run: %s:%d (fragment)" % (path, lineno))
                        continue
                    prelude = "".join("%s is %s\n" % (k, v) for k, v in payload)
                    program = prelude + text
                    missing = undeclared_names(program)
                    if missing:
                        FAIL += 1
                        names = sorted({m for l in missing
                                        for m in E003_LINE.findall(l)})
                        print("  FAIL: %s:%d (fragment has %d undeclared free "
                              "name(s); declare them in the tag, e.g. "
                              "```eigenscript fragment %s=0)"
                              % (path, lineno, len(missing),
                                 names[0] if names else "NAME"))
                        for l in missing:
                            # The lint's own line, rule code included, so the
                            # reader can grep E003 for the rule that fired.
                            print("    lint: %s" % l)
                        continue
                    rc, out, err_txt = run_program(program)
                    if clean_run(rc, err_txt, asan_build):
                        PASS += 1
                        warns = [l for l in err_txt.splitlines()
                                 if l.startswith("Warning:")]
                        print("  PASS: %s:%d (fragment, %d binding(s)%s)"
                              % (os.path.basename(path), lineno, len(payload),
                                 ", %d warning(s)" % len(warns) if warns else ""))
                        for l in warns:
                            print("    " + l)
                    else:
                        FAIL += 1
                        print("  FAIL: %s:%d (fragment did not run clean, rc=%d)"
                              % (path, lineno, rc))
                        for l in err_txt.strip().split("\n")[:5]:
                            print("    " + l)
                    continue
                pending = (lineno, text)
            elif info == "output":
                if pending is None:
                    continue
                code_line, code = pending
                pending = None
                n_paired += 1
                if listing:
                    print("would run: %s:%d" % (path, code_line))
                    continue
                rc, out, err_txt = run_program(code)
                got = norm(out)
                want = norm(text)
                rc_ok = (rc == 0 or
                         (asan_build and rc > 0 and
                          is_lsan_only_failure(err_txt)))
                example_passed = rc_ok and got == want
                if is_readme and example_passed:
                    readme_checked += 1
                if example_passed:
                    PASS += 1
                    print("  PASS: %s:%d" % (os.path.basename(path), code_line))
                else:
                    FAIL += 1
                    print("  FAIL: %s:%d (rc=%d)" % (path, code_line, rc))
                    print("    --- expected ---")
                    for l in want.split("\n")[:8]:
                        print("    " + l)
                    print("    --- got ---")
                    for l in got.split("\n")[:8]:
                        print("    " + l)
                    if err_txt.strip():
                        print("    --- stderr ---")
                        for l in err_txt.strip().split("\n")[:4]:
                            print("    " + l)
            else:
                if pending is not None:
                    report_orphan(path, pending)
                pending = None

        if pending is not None:
            report_orphan(path, pending)
        if is_readme and not listing and readme_checked == 0:
            coverage_failed = True
            print("  FAIL: %s (README has 0 checked examples)" % path)

        # §122: the walk's own fence count against a flat, stateless scan.
        with open(path) as f:
            indep = sum(1 for line in f
                        if INDEP_EIGS_FENCE.match(line)
                        and INDEP_SKIP not in line)
        if indep != n_fence:
            population_failed = True
            print("  FAIL: %s: the fence WALK saw %d eigenscript fence(s) but "
                  "an independent line scan finds %d — the walk is "
                  "desynchronised or blind to a shape" % (path, n_fence, indep))

        got_pop = (n_fence, n_paired, n_fragment, n_nocheck, n_valuecomment)
        if pinned is None:
            if IN_REAL_TREE and n_fence and os.path.realpath(path).startswith(
                    os.path.realpath(ROOT) + os.sep):
                population_failed = True
                print("  FAIL: %s carries %d eigenscript fence(s) but has no "
                      "POPULATION row in tests/test_doc_examples.py — a new "
                      "document must be enrolled, not merely scanned"
                      % (rel, n_fence))
        else:
            print("  population %s: fences=%d paired=%d fragment=%d nocheck=%d "
                  "value-comments=%d"
                  % (rel, n_fence, n_paired, n_fragment, n_nocheck,
                     n_valuecomment))
            if got_pop != pinned:
                population_failed = True
                print("  FAIL: %s population is %r but the pinned row is %r — "
                      "if this is intended, edit POPULATION deliberately"
                      % (rel, got_pop, pinned))
            if n_fence == 0:
                population_failed = True
                print("  FAIL: %s is enrolled but examined 0 fences "
                      "(mechanical-gates §121)" % rel)

    # #946: a fence the parser could not read is COVERAGE LOSS, and the whole
    # point of that issue is that it used to happen in silence. Report every
    # one and fail — an author who wrote an example that is never executed
    # should hear about it from the gate, not discover it when the example
    # rots. This is stricter than the rest of the suite deliberately: the
    # alternative is a document that reads as gated while part of it is not.
    unseen_failed = False
    if UNSEEN_FENCES and not listing:
        unseen_failed = True
        print("")
        for upath, ulineno, uraw, uwhy in UNSEEN_FENCES:
            print("  FAIL: %s:%d fence %s, so its block is UNCHECKED: %s"
                  % (upath, ulineno, uwhy, uraw.strip()))

    # A value-comment waiver that matches nothing is a review that no longer
    # corresponds to a line — same rule as the claims tool's waiver audit.
    if IN_REAL_TREE and not listing:
        stale = set(VALUE_COMMENT_WAIVERS) - VALUE_COMMENT_WAIVERS_USED
        covered = {f for f, _ in VALUE_COMMENT_WAIVERS} & {
            os.path.basename(a) for a in args}
        stale = {k for k in stale if k[0] in covered}
        for f, line in sorted(stale):
            population_failed = True
            print("  FAIL: a VALUE_COMMENT_WAIVERS entry matched nothing in %s "
                  "— the reviewed line is gone or edited: %s" % (f, line))

    print("")
    if IN_REAL_TREE:
        applied = sum(1 for a in args
                      if os.path.relpath(os.path.realpath(a),
                                         os.path.realpath(ROOT)) in POPULATION)
        print("Doc populations pinned: %d of %d row(s) applied"
              % (applied, len(POPULATION)))
        # A run over ZERO pinned documents is a synthetic one — the selftest's
        # in-process probes and tests/test_doc_examples_markers.py both drive
        # main() over throwaway files — so the coverage rule cannot fire there.
        # That leaves the real hole (the suite quietly passing fewer files)
        # to a SECOND mechanism: the suite section greps for the exact
        # "12 of 12" line, so a dropped file is red at the caller even though
        # it is silent here.
        if applied and applied != len(POPULATION):
            population_failed = True
            print("  FAIL: the run covered %d of the %d pinned documents — a "
                  "pinned document that is not passed is a pin that checks "
                  "nothing (mechanical-gates §121)"
                  % (applied, len(POPULATION)))
    checked = PASS + FAIL
    print("Doc examples: %d checked, %d passed, %d failed, %d skipped, "
          "%d unreadable fence(s)" %
          (checked, PASS, FAIL, SKIP, len(UNSEEN_FENCES)))
    if listing:
        return 0
    return 1 if (FAIL or ORPHAN or coverage_failed or unseen_failed
                 or population_failed or checked == 0) else 0


def selftest():
    """#946: prove the parser sees the fence shapes it used to be blind to,
    and that it reports anything it still cannot read.

    A gate that silently measures less still prints OK, so each case here
    plants the exact shape and requires a specific count — "more than zero"
    is satisfied by a parser that found only the easy one.
    """
    import tempfile as _tf
    rc = 0
    NL = chr(10)

    def case(name, md, want_eigs, want_unseen, want_body=None):
        nonlocal rc
        del UNSEEN_FENCES[:]
        with _tf.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write(md)
            path = f.name
        try:
            got = [(ln, txt) for ln, info, a, txt in blocks(path)
                   if info == "eigenscript"]
            ok = (len(got) == want_eigs and len(UNSEEN_FENCES) == want_unseen)
            # Compare the WHOLE body, never just its first line. An
            # over-stripping dedent leaves line 1 intact and destroys the
            # indentation of line 2 — and EigenScript is indentation
            # sensitive, so that silently rewrites the program under test.
            # A first-line-only assertion certified exactly that fault when
            # it was planted (2026-08-19).
            if ok and want_body is not None:
                ok = got[0][1] == want_body
            if ok:
                print("  selftest ok: %s" % name)
            else:
                body = got[0][1] if got else None
                print("  SELFTEST FAIL: %s -- eigenscript=%d (want %d), "
                      "unreadable=%d (want %d), body=%r (want %r)"
                      % (name, len(got), want_eigs, len(UNSEEN_FENCES),
                         want_unseen, body, want_body))
                rc = 1
        finally:
            os.unlink(path)

    P = "print of 1" + NL
    case("plain top-level fence",
         "```eigenscript" + NL + "print of 1" + NL + "```" + NL, 1, 0, P)
    case("blockquoted fence",
         "> ```eigenscript" + NL + "> print of 1" + NL + "> ```" + NL,
         1, 0, P)
    case("indented fence",
         "  ```eigenscript" + NL + "  print of 1" + NL + "  ```" + NL,
         1, 0, P)
    case("indented fence keeps the example's OWN indentation",
         "  ```eigenscript" + NL + "  if 1 == 1:" + NL +
         "      print of 1" + NL + "  ```" + NL,
         1, 0, "if 1 == 1:" + NL + "    print of 1" + NL)
    case("nested blockquote",
         "> > ```eigenscript" + NL + "> > print of 1" + NL +
         "> > ```" + NL, 1, 0, P)
    # `args` is now the rest of the line (the fragment tag needs it), so a
    # three-token info string IS readable — and must be REJECTED as an unknown
    # tag rather than read as a fence shape nobody understands. The walk sees
    # one eigenscript block and reports no unreadable fence; main() is what
    # must go red, and the main_case below pins that.
    case("a multi-token info string parses as a tag, not as garbage",
         "```eigenscript three tokens here" + NL + "print of 1" + NL +
         "```" + NL, 1, 0, P)
    case("a fragment tag with bindings is readable",
         "```eigenscript fragment i=0 n=3" + NL + "print of (i + n)" + NL +
         "```" + NL, 1, 0, "print of (i + n)" + NL)
    case("tilde fence",
         "~~~eigenscript" + NL + "print of 1" + NL + "~~~" + NL, 1, 0, P)
    case("list-item fence (its close must not read as an open)",
         "- ```eigenscript" + NL + "  print of 1" + NL + "  ```" + NL,
         1, 0, P)
    case("numbered list-item fence",
         "1. ```eigenscript" + NL + "   print of 1" + NL + "   ```" + NL,
         1, 0, P)
    case("four-backtick fence",
         "````eigenscript" + NL + "print of 1" + NL + "````" + NL, 1, 0, P)
    case("unterminated fence is reported, not swallowed to EOF",
         "```eigenscript" + NL + "print of 1" + NL, 1, 1, P)
    case("prose mentioning a fence mid-line is not a fence",
         "Write it as ```eigenscript to open a block." + NL, 0, 0)


    # The containment property, asserted directly rather than trusted.
    # FENCE_LOOSE exists to catch what FENCE cannot open, so every line FENCE
    # REJECTS but that a reader would call a fence must match FENCE_LOOSE. The
    # first cut of this fix failed exactly here: both patterns were built from
    # `[ \t>]` and three literal backticks, so the reporter was blind to the
    # same shapes the matcher was — looser on no axis at all
    # (mechanical-gates §12). A prose rule did not prevent that; this does.
    fenceish = [
        "```eigenscript", "~~~eigenscript", "````eigenscript",
        "  ```eigenscript", "\t```eigenscript", "> ```eigenscript",
        ">```eigenscript", "> > ```eigenscript", "- ```eigenscript",
        "* ```eigenscript", "+ ```eigenscript", "1. ```eigenscript",
        "1) ```eigenscript", "  - ```eigenscript", "```eigenscript a b c",
        "~~~~output", "- ~~~eigenscript",
    ]
    # Assert FENCE_LOOSE covers ALL of them, not merely the ones FENCE
    # currently rejects. Phrasing it as "whatever FENCE rejects" makes the
    # check vacuous the moment FENCE is good — measured: it examined ONE line
    # and passed with the original broken reporter still in place. Pinning
    # LOOSE independently means narrowing FENCE later can never outrun the
    # reporter, which is the only thing standing between a new fence shape
    # and silence.
    leaks = [ln for ln in fenceish if not FENCE_LOOSE.match(ln + "\n")]
    if leaks or len(fenceish) < 17:
        print("  SELFTEST FAIL: FENCE_LOOSE must match every fence-ish line "
              "independently of FENCE; missed %r (examined %d, floor 17)"
              % (leaks, len(fenceish)))
        rc = 1
    else:
        print("  selftest ok: the reporter covers every fence-ish line "
              "independently (%d shapes)" % len(fenceish))

    # blocks() finding a problem is worthless if main() does not ACT on it.
    # Nothing above drives main(), and the real doc set produces zero
    # UNSEEN_FENCES, so the whole report-and-fail path — the half of this fix
    # that delivers "reported, not dropped" — could be deleted with the suite
    # still green. Two mutants proved exactly that. This is its witness.
    def main_case(name, md, want_rc, want_text):
        nonlocal rc
        del UNSEEN_FENCES[:]
        with _tf.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write(md)
            path = f.name
        import io as _io
        import contextlib as _cl
        global PASS, FAIL, SKIP, ORPHAN
        saved = (sys.argv, PASS, FAIL, SKIP, ORPHAN)
        buf = _io.StringIO()
        try:
            # main() reads sys.argv and the module-level counters directly,
            # so the probe swaps both and restores them — a selftest that
            # left PASS/FAIL moved would corrupt any later run in-process.
            sys.argv = ["test_doc_examples.py", path]
            PASS = FAIL = SKIP = ORPHAN = 0
            with _cl.redirect_stdout(buf):
                got_rc = main()
        finally:
            sys.argv, PASS, FAIL, SKIP, ORPHAN = saved
            os.unlink(path)
            del UNSEEN_FENCES[:]
        out = buf.getvalue()
        if got_rc == want_rc and want_text in out:
            print("  selftest ok: %s" % name)
        else:
            print("  SELFTEST FAIL: %s -- rc=%r (want %r), text %r not in "
                  "output:%s" % (name, got_rc, want_rc, want_text, out))
            rc = 1

    # Every row below carries a PASSING example as well as the planted fault.
    # Without it `checked == 0` fails the run on its own and the row passes
    # off a neighbouring guard — measured: a mutant that reported the fence
    # but no longer FAILED on it survived exactly that way
    # (mechanical-gates §41).
    GOOD = ("```eigenscript" + NL + "print of 1" + NL + "```" + NL +
            "```output" + NL + "1" + NL + "```" + NL)

    main_case("main() FAILS on an unreadable fence, and says which line",
              GOOD +
              "```eigenscript" + NL + "print of 1" + NL,
              1, "is UNCHECKED")
    main_case("an unknown tag is REJECTED, not treated as another language",
              GOOD +
              "```eigenscript three tokens here" + NL + "print of 1" + NL +
              "```" + NL,
              1, "unknown eigenscript fence tag")
    # THE opt-out rule itself. Under the old opt-in gate this document was
    # green and the second example simply never ran.
    main_case("an UNTAGGED fence with no output block is RED (opt-out)",
              GOOD +
              "```eigenscript" + NL + "print of 2" + NL + "```" + NL,
              1, "untagged eigenscript fence with no ```output block")
    main_case("a fragment whose free name is NOT declared is RED",
              GOOD +
              "```eigenscript fragment i=0" + NL +
              "print of (i + undeclared_name)" + NL + "```" + NL,
              1, "undeclared free name")
    # The RUNTIME half is a separate mechanism from the static one and needs
    # its own witness: a fragment whose names all resolve but which fails while
    # executing must still be red, or moving to --lint would have quietly
    # replaced one check with another instead of adding to it.
    main_case("a fragment that resolves but FAILS AT RUNTIME is still RED",
              GOOD +
              "```eigenscript fragment xs=[1,2]" + NL +
              "print of xs[99]" + NL + "```" + NL,
              1, "fragment did not run clean")
    main_case("a fragment WITH its free names declared passes",
              GOOD +
              "```eigenscript fragment i=0 n=3" + NL +
              "print of (i + n)" + NL + "```" + NL,
              0, "(fragment, 2 binding(s))")
    # ROUND 2 (Astra, G5): the r1 harness resolved names by RUNNING, so a free
    # name on a branch that never executes was never looked up and the fragment
    # passed 1/1. This is the plant that failed then and must fail now.
    main_case("a fragment free name inside a DEAD branch is RED",
              GOOD +
              "```eigenscript fragment i=0" + NL +
              "if 0 == 1:" + NL +
              "    print of never_declared" + NL +
              "print of i" + NL + "```" + NL,
              1, "undeclared free name")
    # Control: the same shape with the name declared must pass, or the row
    # above would score full marks against a gate that rejected every branch.
    main_case("...and the same fragment with that name DECLARED passes",
              GOOD +
              "```eigenscript fragment i=0 never_declared=7" + NL +
              "if 0 == 1:" + NL +
              "    print of never_declared" + NL +
              "print of i" + NL + "```" + NL,
              0, "(fragment, 2 binding(s))")
    # ROUND 2 (Astra, G4): a value stated in a comment beside a green example.
    main_case("a value-bearing comment in an executed example is RED",
              GOOD +
              "```eigenscript" + NL + "print of 1" + NL +
              "# converged after 25 steps" + NL + "```" + NL +
              "```output" + NL + "1" + NL + "```" + NL,
              1, "states a VALUE in a comment inside an executed example")
    main_case("a fragment binding that is not name=value is RED",
              GOOD +
              "```eigenscript fragment justaname" + NL + "print of 1" + NL +
              "```" + NL,
              1, "is not name=value")
    main_case("a nocheck fence with NO reason is RED",
              GOOD +
              "```eigenscript nocheck" + NL + "print of 1" + NL + "```" + NL,
              1, "must state its reason")
    main_case("a nocheck fence WITH a reason is counted and its reason printed",
              GOOD +
              "```eigenscript nocheck needs a network" + NL + "print of 1" +
              NL + "```" + NL,
              0, "NOCHECK: ")
    # §122: the walk's count against the independent flat scan. Here a
    # four-backtick text fence CONTAINS an eigenscript opener: the walk reads
    # it as content (correctly), the flat scanner counts it, and the
    # disagreement must be LOUD — that is the whole point of having two
    # mechanisms. The escape hatch is a marker on the quoted line, and the
    # control below proves the hatch actually closes the gap rather than
    # disabling the check.
    main_case("walk-vs-independent-scan disagreement is RED",
              GOOD +
              "````text" + NL + "```eigenscript" + NL + "print of 1" + NL +
              "```" + NL + "````" + NL,
              1, "independent line scan finds")
    main_case("a quoted fence opener marked %s is accounted for" % INDEP_SKIP,
              GOOD +
              "````text" + NL + "```eigenscript    <- " + INDEP_SKIP + NL +
              "print of 1" + NL + "```" + NL + "````" + NL,
              0, "1 checked")
    # Control: a clean document must still pass through main() unharmed, or a
    # main() that always failed would score full marks on the row above.
    main_case("main() passes a clean document",
              "```eigenscript" + NL + "print of 1" + NL + "```" + NL +
              "```output" + NL + "1" + NL + "```" + NL,
              0, "1 checked")

    print("SELFTEST: %s" % ("all fence shapes recognised"
                            if rc == 0 else "FAILED"))
    return rc


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if "--count" in sys.argv:
        sys.exit(count_mode([a for a in sys.argv[1:] if a != "--count"]))
    sys.exit(main())
