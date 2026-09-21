#!/usr/bin/env python3
"""Derive the eigenscript executable names a consumer checkout INVOKES.

Used by tools/consumer_acceptance.sh (milestone M1, #1213). Round 2 derived
the name set from every `eigenscript[-a-z0-9]*` TOKEN in every text file, so
prose, a Dockerfile path, a skill name in CLAUDE.md, a bench JSON key and a
release-asset URL all became declared prerequisites and would have marked
three live consumers UNRUNNABLE for documentation rather than for an
invocation. Measured on 2026-09-21 against the real ecosystem:

    ouroboros   eigenscript-src (a Dockerfile path), eigenscript-aot-compiler-engineer
                (a skill name in CLAUDE.md), eigenscript-probe / -original /
                -missing-reuse (bench JSON)
    iLambdaAi   eigenscript-full-from-env (a comment), eigenscript-full-linux-x86
                (a release-asset URL)
    Tidepool    eigenscript-gfx-binary (a usage line)

A name enters the set only from an INVOCATION POSITION:

  (a) shell text -- `*.sh`, an extensionless file with a `#!` shell line,
      Makefile recipe lines, and the `runCmd` of a workflow -- the first
      word of a simple command, or the word after exec / env / nohup /
      setsid / stdbuf / time / `timeout N` / `xvfb-run ...` / `command -v`,
      or the value of a variable assignment (`EIGS=eigenscript-full`,
      `export EIGENSCRIPT_BIN=eigenscript-full`) or of a `${VAR:-default}`
      expansion. Comments (`#` outside quotes) and heredoc BODIES are
      stripped before tokenising.
  (b) Python -- a string literal that is the first element of a
      `subprocess.*` / `os.system` / `os.exec*` / `shutil.which` argument,
      or the default of `os.environ.get("X", "eigenscript-y")`. A
      shell=True / os.system string is re-scanned as shell text.
  (c) `.eigs` -- the first string literal of an exec-family builtin call:
      `exec_capture of ["cmd", ...]` / `proc_spawn of ["cmd", ...]`
      (docs/BUILTINS.md), including the timeout form
      `exec_capture of [["cmd", ...], seconds]`.

Prose, comments, JSON, YAML values other than runCmd, URLs and any token
containing `/` are NOT invocations. Every rejected occurrence is reported so
the choice is visible rather than silent.

Output, one record per line, on stdout:

    variant|<name>|<relpath>:<line>      an invocation position
    excluded|<name>|<relpath>:<line>     an occurrence that is not one
    examined|<files>|<occurrences>       the enumeration's own witness

`variant` records are emitted in first-seen order, deduplicated by name.
`excluded` records are deduplicated by name and only for names that never
appear in an invocation position (a name invoked somewhere is a variant,
full stop). `eigenscript` itself is never reported as excluded: it is
always a candidate.

    tools/_derive_variants.py DIR
    tools/_derive_variants.py --selftest
"""
import os
import re
import sys

NAME_RE = re.compile(r"eigenscript(?:-[a-z0-9]+)*")
FULL_NAME_RE = re.compile(r"^eigenscript(?:-[a-z0-9]+)*$")

# Command prefixes that pass the command position through to the next word.
PASSTHROUGH = {
    "exec": 0,
    "nohup": 0,
    "setsid": 0,
    "builtin": 0,
    "time": 0,
    "sudo": 0,
    "stdbuf": 0,
    "nice": 0,
    "ionice": 0,
}
# Prefixes whose own flags (and, for timeout, whose budget) come before
# the command word: `timeout -k 5 30 eigenscript-full x`.
OPERAND_PREFIX = ("timeout", "xvfb-run", "env", "command")
DURATION_RE = re.compile(r"^[0-9]+(\.[0-9]+)?[smhd]?$")
ASSIGN_KEYWORD = {"export", "declare", "typeset", "readonly", "local"}
KEYWORDS = {
    "if", "then", "else", "elif", "fi", "while", "until", "do", "done",
    "case", "esac", "for", "select", "function", "in", "!", "{", "}",
    "(", ")", "[[", "]]",
}

SHELL_SHEBANG = re.compile(r"^#!.*\b(ba|da|k|z|a)?sh\b")
DEFAULT_EXPANSION = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*(?::?[-=])([^}]*)\}")
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
EIGS_CALL_RE = re.compile(
    r"\b(?:exec_capture|proc_spawn)\s+of\s*\(?\s*\[\s*\[?\s*[\"']([^\"']*)[\"']"
)


def _unquote(word):
    out = []
    i = 0
    n = len(word)
    while i < n:
        c = word[i]
        if c == "'":
            j = word.find("'", i + 1)
            if j < 0:
                out.append(word[i + 1:])
                break
            out.append(word[i + 1:j])
            i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and word[j] != '"':
                if word[j] == "\\":
                    j += 1
                j += 1
            out.append(word[i + 1:j])
            i = j + 1
        elif c == "\\" and i + 1 < n:
            out.append(word[i + 1])
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _strip_comment(line):
    """Drop a `#` comment outside quotes. A `#` inside a word (foo#bar) is
    not a comment, matching the shell."""
    out = []
    quote = None
    prev = ""
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if quote:
            out.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                out.append(line[i + 1])
                i += 2
                prev = ""
                continue
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
            out.append(c)
        elif c == "\\" and i + 1 < n:
            out.append(c)
            out.append(line[i + 1])
            i += 2
            prev = ""
            continue
        elif c == "#" and (prev == "" or prev in " \t;&|()<>"):
            break
        else:
            out.append(c)
        prev = c
        i += 1
    return "".join(out)


HEREDOC_RE = re.compile(r"<<[-~]?\s*([\"']?)([A-Za-z_][A-Za-z0-9_]*)\1")


def shell_lines(text):
    """Yield (lineno, line) for shell lines with comments and heredoc
    BODIES removed. A heredoc body is data, not commands."""
    lines = text.split("\n")
    i = 0
    n = len(lines)
    while i < n:
        raw = lines[i]
        line = _strip_comment(raw)
        m = HEREDOC_RE.search(line)
        yield (i + 1, line)
        if m:
            delim = m.group(2)
            j = i + 1
            while j < n and lines[j].strip() != delim:
                j += 1
            i = j + 1
            continue
        i += 1


def _split_words(line):
    """Split a shell line into words and separators, respecting quotes."""
    toks = []
    i = 0
    n = len(line)
    cur = ""
    while i < n:
        c = line[i]
        if c in " \t":
            if cur:
                toks.append(cur)
                cur = ""
            i += 1
            continue
        if c in "'\"":
            q = c
            j = i + 1
            while j < n:
                if line[j] == "\\" and q == '"' and j + 1 < n:
                    j += 2
                    continue
                if line[j] == q:
                    break
                j += 1
            cur += line[i:min(j + 1, n)]
            i = j + 1
            continue
        if c == "\\" and i + 1 < n:
            cur += line[i:i + 2]
            i += 2
            continue
        two = line[i:i + 2]
        if two in ("&&", "||", ";;", "$("):
            if cur:
                toks.append(cur)
                cur = ""
            toks.append(two)
            i += 2
            continue
        if c in ";|&()`{}<>":
            if cur:
                toks.append(cur)
                cur = ""
            toks.append(c)
            i += 1
            continue
        cur += c
        i += 1
    if cur:
        toks.append(cur)
    return toks


SEPARATORS = {";", ";;", "|", "||", "&&", "&", "(", ")", "$(", "`", "{", "}"}


def scan_shell(text, hits, path, line_offset=0):
    """Record (name, lineno) for every invocation position in shell text."""
    for lineno, line in shell_lines(text):
        toks = _split_words(line)
        cmdpos = True
        pending_prefix = ""
        for tok in toks:
            if tok in SEPARATORS:
                cmdpos = True
                pending_prefix = ""
                continue
            if tok in ("<", ">", ">>", "<<"):
                cmdpos = False
                continue
            word = _unquote(tok)
            # ${VAR:-eigenscript-x} defaults are invocation-shaped wherever
            # they appear: the value is what a later `$VAR` runs.
            for dflt in DEFAULT_EXPANSION.findall(tok):
                cand = _unquote(dflt).strip()
                if FULL_NAME_RE.match(cand):
                    hits.append((cand, path, lineno + line_offset))
            if not cmdpos:
                continue
            if word in KEYWORDS or word in ASSIGN_KEYWORD:
                # a keyword, or `export`/`local`/..., keeps the command
                # position open for the word or assignment that follows
                continue
            m = ASSIGN_RE.match(word)
            if m:
                val = _unquote(m.group(2)).strip()
                if FULL_NAME_RE.match(val):
                    hits.append((val, path, lineno + line_offset))
                continue  # assignment prefix: still a command position
            if pending_prefix:
                if word.startswith("-"):
                    continue  # a flag of the prefix
                if pending_prefix == "timeout" and DURATION_RE.match(word):
                    continue  # the budget, not the command
                pending_prefix = ""
            elif word.startswith("-"):
                continue
            if word in PASSTHROUGH:
                continue
            if word in OPERAND_PREFIX:
                pending_prefix = word
                continue
            if FULL_NAME_RE.match(word):
                hits.append((word, path, lineno + line_offset))
            cmdpos = False


def scan_python(text, hits, path):
    import ast

    try:
        tree = ast.parse(text)
    except SyntaxError:
        return
    calls = (
        "system", "popen", "run", "call", "check_call", "check_output",
        "Popen", "which", "execv", "execve", "execvp", "execvpe", "execl",
        "execlp", "execle", "spawnv", "spawnvp", "spawnl", "spawnlp",
    )

    def name_of(func):
        if isinstance(func, ast.Attribute):
            return func.attr
        if isinstance(func, ast.Name):
            return func.id
        return ""

    def literal(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        return None

    def record(val, lineno):
        if val is None:
            return
        val = val.strip()
        if FULL_NAME_RE.match(val):
            hits.append((val, path, lineno))
        elif " " in val or "\t" in val:
            # a shell string: re-scan it in command position
            scan_shell(val, hits, path, line_offset=lineno - 1)

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        fname = name_of(node.func)
        if fname == "get" and isinstance(node.func, ast.Attribute):
            # os.environ.get("EIGS", "eigenscript-full")
            if len(node.args) >= 2:
                val = literal(node.args[1])
                if val is not None and FULL_NAME_RE.match(val.strip()):
                    hits.append((val.strip(), path, node.lineno))
            continue
        if fname not in calls:
            continue
        if not node.args:
            continue
        first = node.args[0]
        if isinstance(first, (ast.List, ast.Tuple)):
            if first.elts:
                record(literal(first.elts[0]), node.lineno)
        else:
            record(literal(first), node.lineno)


def scan_eigs(text, hits, path):
    for i, line in enumerate(text.split("\n")):
        for m in EIGS_CALL_RE.finditer(line):
            cand = m.group(1).strip()
            if FULL_NAME_RE.match(cand):
                hits.append((cand, path, i + 1))


def scan_makefile(text, hits, path):
    """Makefile recipe lines (TAB-indented) are shell. Everything else in a
    Makefile is a variable or a prerequisite, not an invocation -- except a
    `VAR = eigenscript-x` assignment, which a recipe then runs."""
    for i, line in enumerate(text.split("\n")):
        if line.startswith("\t"):
            body = line[1:]
            body = body.lstrip("@-+")
            scan_shell(body, hits, path, line_offset=i)
        else:
            m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*[:?+]?=\s*(\S+)", line)
            if m and FULL_NAME_RE.match(m.group(2)):
                hits.append((m.group(2), path, i + 1))


def scan_yaml(text, hits, path):
    """Only the runCmd is a command in a workflow; every other value is
    configuration. Reuses the extractor so the two agree by construction."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        from _extract_runcmd import extract
    except Exception:
        return
    cmd = extract(text)
    if not cmd:
        return
    lineno = 1
    for i, line in enumerate(text.split("\n")):
        if "runCmd" in line:
            lineno = i + 1
            break
    scan_shell(cmd, hits, path, line_offset=lineno - 1)


def kind_of(path, head):
    base = os.path.basename(path)
    ext = os.path.splitext(base)[1]
    if ext in (".sh", ".bash", ".zsh"):
        return "shell"
    if ext == ".py":
        return "python"
    if ext == ".eigs":
        return "eigs"
    if ext in (".yml", ".yaml"):
        return "yaml"
    if ext == ".mk" or base in ("Makefile", "makefile", "GNUmakefile"):
        return "makefile"
    if ext == "" and SHELL_SHEBANG.match(head):
        return "shell"
    if ext == "" and head.startswith("#!") and "python" in head.split("\n")[0]:
        return "python"
    return ""


def derive(root):
    """Return (variants, excluded, files, occurrences)."""
    hits = []
    occurrences = []
    files = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d != ".git")
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            if os.path.islink(full) and not os.path.exists(full):
                continue
            if not os.path.isfile(full):
                continue
            try:
                if os.path.getsize(full) > 4 * 1024 * 1024:
                    continue
                with open(full, "rb") as fh:
                    blob = fh.read()
            except OSError:
                continue
            if b"\0" in blob:
                continue
            if b"eigenscript" not in blob:
                continue
            try:
                text = blob.decode("utf-8")
            except UnicodeDecodeError:
                text = blob.decode("latin-1")
            rel = os.path.relpath(full, root)
            files += 1
            for i, line in enumerate(text.split("\n")):
                for m in NAME_RE.finditer(line):
                    occurrences.append((m.group(0), rel, i + 1))
            head = text[:200]
            kind = kind_of(full, head)
            if kind == "shell":
                scan_shell(text, hits, rel)
            elif kind == "python":
                scan_python(text, hits, rel)
            elif kind == "eigs":
                scan_eigs(text, hits, rel)
            elif kind == "yaml":
                scan_yaml(text, hits, rel)
            elif kind == "makefile":
                scan_makefile(text, hits, rel)
    variants = []
    seen = set()
    for name, path, line in hits:
        if name in seen:
            continue
        seen.add(name)
        variants.append((name, path, line))
    excluded = []
    exseen = set()
    for name, path, line in occurrences:
        if name in seen or name in exseen or name == "eigenscript":
            continue
        exseen.add(name)
        excluded.append((name, path, line))
    return variants, excluded, files, len(occurrences)


def selftest():
    import tempfile
    import shutil

    cases = [
        # (name, {relpath: content}, expected variant set)
        ("real-shapes-are-not-invocations", {
            "Dockerfile": "COPY . /opt/eigenscript-src\n",
            "CLAUDE.md": "route to the eigenscript-aot-compiler-engineer skill\n",
            "bench/out.json": '{"eigenscript-probe": 1, "eigenscript-original": 2,\n'
                              ' "eigenscript-missing-reuse": 3}\n',
            "scripts/note.sh": "# use eigenscript-full-from-env when set\n"
                               "curl -sL https://x/releases/eigenscript-full-linux-x86 -o /tmp/e\n"
                               "echo 'usage: eigenscript-gfx-binary prog.eigs'\n",
        }, set()),
        ("shell-first-word", {"run.sh": "#!/bin/sh\neigenscript-full work.eigs\n"},
         {"eigenscript-full"}),
        ("shell-exec-env-timeout-xvfb", {"run.sh": (
            "#!/bin/bash\n"
            "exec eigenscript-a x\n"
            "env FOO=1 eigenscript-b x\n"
            "timeout 30 eigenscript-c x\n"
            "timeout -k 5 30 eigenscript-d x\n"
            "xvfb-run -a eigenscript-e x\n"
            "command -v eigenscript-f\n"
        )}, {"eigenscript-a", "eigenscript-b", "eigenscript-c", "eigenscript-d",
             "eigenscript-e", "eigenscript-f"}),
        ("shell-assignment-and-default", {"run.sh": (
            "#!/bin/sh\n"
            "EIGS=eigenscript-g\n"
            "export EIGENSCRIPT_BIN=eigenscript-h\n"
            '"${EIGS:-eigenscript-i}" work.eigs\n'
        )}, {"eigenscript-g", "eigenscript-h", "eigenscript-i"}),
        ("shell-comment-and-heredoc", {"run.sh": (
            "#!/bin/sh\n"
            "# eigenscript-comment x\n"
            "echo hi   # eigenscript-trailing x\n"
            "cat <<EOF\n"
            "eigenscript-heredoc x\n"
            "EOF\n"
            "eigenscript-real x\n"
        )}, {"eigenscript-real"}),
        ("shell-path-is-not-a-name", {"run.sh":
            "#!/bin/sh\n./eigenscript-local x\n/usr/bin/eigenscript-abs x\n"},
         set()),
        ("extensionless-shebang", {"acceptance":
            "#!/usr/bin/env bash\neigenscript-ext work.eigs\n"},
         {"eigenscript-ext"}),
        ("makefile-recipe", {"Makefile":
            "run: dep\n\t@eigenscript-mk work.eigs\nVAR = eigenscript-var\n"
            "# eigenscript-mkcomment\n"},
         {"eigenscript-mk", "eigenscript-var"}),
        ("python-subprocess", {"run.py": (
            "import subprocess, os, shutil\n"
            "subprocess.run(['eigenscript-p1', 'x'])\n"
            "os.system('eigenscript-p2 x')\n"
            "shutil.which('eigenscript-p3')\n"
            "os.execvp('eigenscript-p4', ['eigenscript-p4'])\n"
            "E = os.environ.get('EIGS', 'eigenscript-p5')\n"
            "# eigenscript-pcomment\n"
            "DOC = 'see eigenscript-pdoc for details'\n"
        )}, {"eigenscript-p1", "eigenscript-p2", "eigenscript-p3",
             "eigenscript-p4", "eigenscript-p5"}),
        ("eigs-exec-family", {"run.eigs": (
            "let r is exec_capture of [\"eigenscript-e1\", \"x\"]\n"
            "let p is proc_spawn of [\"eigenscript-e2\", \"x\"]\n"
            "let t is exec_capture of [[\"eigenscript-e3\", \"x\"], 5]\n"
            "# eigenscript-ecomment\n"
            "let s is \"eigenscript-estring\"\n"
        )}, {"eigenscript-e1", "eigenscript-e2", "eigenscript-e3"}),
        ("yaml-runcmd-only", {".github/workflows/ci.yml": (
            "name: eigenscript-wfname\n"
            "jobs:\n"
            "  t:\n"
            "    steps:\n"
            "      - uses: devcontainers/ci@v0\n"
            "        with:\n"
            "          runCmd: |\n"
            "            eigenscript-y1 work.eigs\n"
            "          push: never\n"
            "          image: ghcr.io/x/eigenscript-image\n"
        )}, {"eigenscript-y1"}),
    ]
    examined = 0
    failed = 0
    tmp = tempfile.mkdtemp(prefix="ca-dv-")
    try:
        for name, files, want in cases:
            examined += 1
            root = os.path.join(tmp, name)
            for rel, content in files.items():
                dest = os.path.join(root, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "w") as fh:
                    fh.write(content)
            variants, excluded, nfiles, noccur = derive(root)
            got = set(n for n, _, _ in variants)
            if got != want:
                sys.stderr.write(
                    "FAIL %s: got %r want %r\n" % (name, sorted(got), sorted(want))
                )
                failed += 1
            if nfiles == 0:
                sys.stderr.write("FAIL %s: examined ZERO files\n" % name)
                failed += 1
            if noccur == 0:
                sys.stderr.write("FAIL %s: examined ZERO occurrences\n" % name)
                failed += 1
            # every occurrence is either a variant or reported as excluded
            exnames = set(n for n, _, _ in excluded)
            if name == "real-shapes-are-not-invocations" and len(exnames) != 8:
                sys.stderr.write(
                    "FAIL %s: excluded=%r want 8 names\n" % (name, sorted(exnames))
                )
                failed += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if examined != len(cases) or examined == 0:
        sys.stderr.write(
            "FAIL examined=%d len(cases)=%d (want examined == len(table) > 0)\n"
            % (examined, len(cases))
        )
        return 1
    if failed:
        sys.stderr.write("SELFTEST: FAIL %d/%d\n" % (failed, examined))
        return 1
    sys.stdout.write("SELFTEST: PASS examined=%d\n" % examined)
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) == 3 and argv[1] == "--shell":
        # A DECLARED acceptance command is shell text with no file of its
        # own. It goes through the same call-site rule as everything else,
        # so a declared fallback cannot smuggle a name in from a comment.
        hits = []
        try:
            text = open(argv[2]).read()
        except OSError:
            return 1
        scan_shell(text, hits, os.path.basename(argv[2]))
        seen = set()
        out = []
        for name, path, line in hits:
            if name in seen:
                continue
            seen.add(name)
            out.append("variant|%s|%s:%d" % (name, path, line))
        out.append("examined|1|%d" % len(hits))
        sys.stdout.write("\n".join(out) + "\n")
        return 0
    if len(argv) != 2:
        sys.stderr.write("usage: %s DIR | --selftest\n" % argv[0])
        return 2
    root = argv[1]
    if not os.path.isdir(root):
        return 1
    variants, excluded, files, occurrences = derive(root)
    out = []
    for name, path, line in variants:
        out.append("variant|%s|%s:%d" % (name, path, line))
    for name, path, line in excluded:
        out.append("excluded|%s|%s:%d" % (name, path, line))
    out.append("examined|%d|%d" % (files, occurrences))
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
