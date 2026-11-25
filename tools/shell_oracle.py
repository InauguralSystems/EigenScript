#!/usr/bin/env python3
"""Differential oracle for tools/_shell_tokens.py: bash and dash supply the
expected answers, never the tokenizer itself.

    python3 tools/shell_oracle.py [--json] [FILE...]   # default: tracked *.sh
    python3 tools/shell_oracle.py --selftest           # plants + A/A + corpus

ORACLES (each is an answer the real shell gives, compared with ours)

  O1 accept   `bash -n` (and `dash -n` for a `#!/bin/sh` file) accepts the
              file  =>  tokenize() must not raise.  tokenize() raises  =>
              `bash -n` must reject.  (bash may reject for GRAMMAR reasons a
              lexer does not model; that direction is not a finding.)
  O2 words    bash's own word splitting and quote removal.  Every simple
              command whose words hold no expansion is replayed as the
              arguments of a builtin-only function in a restricted shell
              (`bash -r`, PATH empty, `set -f +B`); bash's argument list must
              equal [unquote(w) for w in our words].  A word we split wrongly
              changes bash's argument count; a quote we read wrongly changes
              the text.
  O3 reprint  bash parses the file as a function body and reprints it
              (`declare -f`): comments and line continuations gone, one
              command per line, spacing and $(...) bodies normalized, case
              patterns and here-documents re-laid.  Our structure (simple
              commands, their words, substitution bodies recursively,
              redirections, here-document bodies) must be identical on the
              original and on bash's reprint.
  O4 regions  a lone `'` planted where we say the text is a COMMENT or a
              HERE-DOCUMENT BODY must leave `bash -n` accepting; planted at
              the start of a line we say is CODE (in a file holding a
              here-document) it must make `bash -n` reject.  This is bash's
              own answer to "is this text shell or data".
  H  incidents hand-checked expected tokens for the shapes that bit the line
              scanners before (CA-GUARD rounds in tools/_derive_variants.py,
              hq#58) and for constructs the tree does not contain.

RESOLUTION is stated, not assumed: --selftest applies source mutations
(PLANTS) to a copy of the tokenizer and requires each to be caught by the
oracle(s) listed for it, and runs the whole oracle twice (and under a second
locale) requiring byte-identical findings (A/A).

BLIND SPOTS (what no oracle here can see):
  * words holding $..., `...`, ~, <(...): O2 does not replay them (that would
    run them); their bodies are still tokenized and replayed on their own.
  * text bash rejects (O1 rejected files skip O2-O4 for that file).
  * consistent errors on both sides of O3 (e.g. a construct we mis-read the
    same way in the original and in bash's reprint) -- H and O4 cover the
    known classes; the plant table shows which.
  * bash-only acceptance: dash is consulted only for `#!/bin/sh` files.
  * runtime-decided commands (eval, bash -c "$v", aliases) are not lexical.
  * O4 samples: at most PROBE_CAP comment and code probes per file, code
    probes only in files holding `<<`, and each here-document's first and
    last body line (--full lifts the caps).
  * O3 normalizes what bash's reprint rewrites (spacing, `-n` inside [[ ]],
    $'...' spelling, `case X in` layout, an implicit `for` list, the order of
    redirections, here-document continuations) and does not compare
    redirection targets; a file whose reprint misplaces a here-document from
    an `if`/`while` header is counted as o3_reprint_unusable, not compared.
  * not modelled, and not in the tree: an operator split by a line
    continuation (`<\\<newline><EOF`), posix-mode quoting inside ${...}
    (`${x:?it's}` in a dash file), a `<<-` delimiter that itself holds a
    tab, and the ANSI-C edge cases `\\x{}`, `\\c\\'` and `\\UFFFFFFFF`, which
    were not checked against bash.
  * a here-document opened inside a $( ) that closes on the same line
    (`$(cat <<EOF)`), and a function defined in a pipeline element or a
    backgrounded group (subshells bash discards), are read differently from
    bash; none occurs in the tree.  `!(` at a command position is read as
    negation (extglob off, as in scripts); elsewhere as an extglob group.  The plants run on every 4th file plus the incidents.
"""
from __future__ import annotations

import concurrent.futures
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

import _shell_tokens as ST  # noqa: E402

RESERVED_LEAD = {"if", "then", "else", "elif", "fi", "do", "done", "while",
                 "until", "{", "}", "!", "case", "esac", "time", "in"}
REPRINT_MISPLACES_HEREDOC = re.compile(r"<<-?\s*\S+;\s*(then|do)\s*$", re.M)
ARRAY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=\(")
BASH = shutil.which("bash")
FULL = "--full" in sys.argv
DASH = shutil.which("dash")


# ----------------------------------------------------------------- structure

def shape(text, mod=ST, depth=0):
    """Our structural reading of TEXT: what O3 compares."""
    toks = mod.tokenize(text)
    cmds, redirs, docs = [], [], []
    for k, tok in enumerate(toks):
        if tok.kind == "redir":
            nxt = toks[k + 1].text if k + 1 < len(toks) else ""
            # bash reprints a close (`<&-` or `>&-`) as `>&-`.
            redirs.append("close" if tok.text in ("<&", ">&") and nxt == "-" else tok.text)
            if tok.heredoc is not None:
                body = tok.heredoc
                if tok.text == "<<-":
                    body = "\n".join(l.lstrip("\t") for l in body.split("\n"))
                if not any(c in nxt for c in "'\"\\"):
                    # unquoted delimiter: bash's reprint has already joined
                    # backslash-newline continuations in the body
                    body = re.sub(r"(?<!\\)((?:\\\\)*)\\\n", r"\1", body)
                docs.append(body)
    pieces = []
    for cmd in mod.simple_commands(toks):
        words = [w.text for w in cmd]
        subs = [w.subst for w in cmd]
        if "[[" in words:             # bash's reprint spells `[[ x ]]` as `[[ -n x ]]`
            keep = [k for k, w in enumerate(words) if w != "-n"]
            words, subs = [words[k] for k in keep], [subs[k] for k in keep]
        while words and words[0] in RESERVED_LEAD - {"case"}:
            words, subs = words[1:], subs[1:]
        if not words:
            continue
        # bash's reprint lays `case X in` on its own line and spells an
        # implicit `for NAME` list as `in "$@"`: normalize both readings.
        if words[0] == "function" and len(words) > 2:
            # bash reprints `function NAME {` as `NAME ()` and `{` on its own line
            pieces.append((words[:2], subs[:2]))
            words, subs = words[2:], subs[2:]
        if words[:2] == ["coproc", "COPROC"]:
            words, subs = words[:1] + words[2:], subs[:1] + subs[2:]   # bash names it
        if words and words[0] == "coproc" and len(words) > 3 and words[2] == "{":
            # bash's reprint lays `coproc NAME {` on its own line
            pieces.append((words[:3], subs[:3]))
            words, subs = words[3:], subs[3:]
        elif words and words[0] == "case" and "in" in words:
            k = words.index("in") + 1
            pieces.append((words[:k], subs[:k]))
            words, subs = words[k:], subs[k:]
        elif words and words[0] in ("for", "select") and len(words) >= 2 \
                and (len(words) == 2 or words[2] != "in"):
            words = words[:2] + ["in", '"$@"']
            subs = subs[:2] + [(), ()]
        pieces.append((words, subs))
    for words, subs in pieces:
        while words and words[0] in RESERVED_LEAD:
            words, subs = words[1:], subs[1:]
        if words and words[0] == "function":
            words, subs = words[1:], subs[1:]
        if not words:
            continue
        cmds.append(tuple(_word_shape(w, s, mod, depth) for w, s in zip(words, subs)))
    funcs = tuple(mod.function_definitions(toks)) if hasattr(mod, "function_definitions") else ()
    # Arithmetic commands, spacing ignored (bash's reprint respaces them),
    # with the shapes of any substitutions inside.
    arith = tuple((re.sub(r"\s+", "", t.text),
                   tuple(shape(b, mod, depth + 1) for b in t.subst))
                  for t in toks if t.kind == "arith")
    funcs = funcs + (("arith",) + arith if arith else ())
    # Redirections as a multiset: bash's reprint may move a compound
    # command's redirections relative to the ones inside it.
    return (tuple(cmds), tuple(sorted(redirs)), tuple(docs), funcs)


def _ansi_as_single(word, mod):
    """bash reprints $'...' as the decoded text in single quotes."""
    if "$'" not in word:
        return word
    out, i, n, dq, braces = [], 0, len(word), False, 0
    while i < n:
        c = word[i]
        if c == "\\" and i + 1 < n:
            out.append(word[i:i + 2]); i += 2; continue
        if c == "$" and word[i + 1:i + 2] == "{":
            braces += 1
            out.append("${"); i += 2; continue
        if c == "}" and braces:
            braces -= 1
        if c == '"':
            dq = not dq
        elif c == "'" and (not dq or braces):
            j = word.find("'", i + 1)
            j = n if j < 0 else j
            out.append(word[i:j + 1]); i = j + 1; continue
        elif c == "$" and word[i + 1:i + 2] == "'" and (not dq or braces):
            j = i + 2
            while j < n and word[j] != "'":
                j += 2 if word[j] == "\\" else 1
            decoded = mod.unquote(word[i:j + 1])
            out.append("'" + decoded.replace("'", "'\\''") + "'")
            i = j + 1
            continue
        out.append(c); i += 1
    return "".join(out)


def _word_shape(text, subst, mod, depth):
    if depth > 6:
        return _ansi_as_single(text, mod)
    m = ARRAY_RE.match(text)
    if m and text.endswith(")"):
        inner = mod.tokenize(text[m.end():-1])
        return ("array", _ansi_as_single(text[:m.end()], mod),
                tuple(_word_shape(t.text, t.subst, mod, depth + 1)
                      for t in inner if t.kind == "word"))
    skeleton = text
    bodies = []
    for body in subst:
        if body and body in skeleton:
            skeleton = skeleton.replace(body, "", 1)
        bodies.append(shape(body, mod, depth + 1))
    skeleton = _ansi_as_single(skeleton, mod)
    skeleton = re.sub(r"\s+", " ", skeleton) if subst else skeleton
    return (skeleton, tuple(bodies)) if subst else skeleton


# ------------------------------------------------------------------- oracles

def _env(locale):
    return {"PATH": "", "LC_ALL": locale, "HOME": "/nonexistent"}


def bash_accepts(text, locale="C"):
    r = subprocess.run([BASH, "--norc", "--noprofile", "-n"], input=text.encode(),
                       capture_output=True, env=_env(locale), timeout=30)
    return r.returncode == 0


def dash_accepts(text, locale="C"):
    r = subprocess.run([DASH, "-n"], input=text.encode(), capture_output=True,
                       env=_env(locale), timeout=30)
    return r.returncode == 0


def bash_reprint(text, locale="C"):
    """bash's own reprint of TEXT parsed as a function body, or None."""
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
        f.write(text)
        path = f.name
    try:
        script = ('src=$(<"$1"); eval "__oracle_fn() {\n$src\n}" '
                  '&& declare -f __oracle_fn')
        r = subprocess.run([BASH, "--norc", "--noprofile", "-r", "-c", script, "x", path],
                           capture_output=True, env=_env(locale), timeout=30,
                           stdin=subprocess.DEVNULL)
    finally:
        os.unlink(path)
    if r.returncode != 0:
        return None
    out = r.stdout.decode(errors="surrogateescape")
    lines = out.split("\n")
    # "__oracle_fn () " / "{ " ... "}"
    if len(lines) < 3 or not lines[1].startswith("{"):
        return None
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines[2:-1]) + "\n"


def _has_expansion(word):
    """True if bash would expand something in WORD (so O2 cannot replay it)."""
    i, n, q = 0, len(word), None
    while i < n:
        c = word[i]
        if q == "'":
            if c == "'":
                q = None
            i += 1
            continue
        if c == "\\":
            i += 2
            continue
        if c == "'" and q is None:
            q = "'"
        elif c == '"':
            q = None if q == '"' else '"'
        elif c == "$":
            if q is None and word[i + 1:i + 2] == "'":
                j = i + 2
                while j < n and word[j] != "'":
                    j += 2 if word[j] == "\\" else 1
                i = j + 1
                continue
            return True
        elif c == "`":
            return True
        elif c in "()" and q is None:
            return True                  # array value / extglob: not an argument
        elif c == "[" and q is None and re.match(r"^[A-Za-z_]\w*\[", word):
            return True                  # an assignment's subscript: not an argument
        i += 1
    return word.startswith("~") or word[:2] in ("<(", ">(")


def replayable(cmd):
    words = [w.text for w in cmd]
    if not words:
        return None
    for w in words:
        if not w or w in ST.OPERATORS or w in ("[[", "]]") or _has_expansion(w):
            return None
    return words


def collect_commands(text, mod=ST, depth=0):
    """Every simple command in TEXT, substitution bodies included."""
    out = []
    toks = mod.tokenize(text)
    out.extend(mod.simple_commands(toks))
    if depth < 6:
        for tok in toks:
            for body in tok.subst:
                try:
                    out.extend(collect_commands(body, mod, depth + 1))
                except ST.ShellLexError:
                    pass                  # a body bash also rejects: O1 covers the file
    return out


def bash_words(commands, locale="C"):
    """bash's argument lists for each replayed command (O2)."""
    script = ["set -f +B", "w() { printf '%s\\0' \"$@\"; printf '\\1'; }"]
    script += ["w " + " ".join(c) for c in commands]
    r = subprocess.run([BASH, "--norc", "--noprofile", "-r"], input="\n".join(script).encode(),
                       capture_output=True, env=_env(locale), timeout=60)
    out = r.stdout.decode(errors="surrogateescape").split("\1")
    return [x.split("\0")[:-1] for x in out[:-1]]


# ------------------------------------------------------------ per-file check

def check_text(name, text, mod=ST, locale="C", posix=False, probes=True):
    """Findings for one shell text. Returns (findings, counters)."""
    F = []
    C = dict(files=1, accepted=0, o2_cmds=0, o2_words=0, o3=0, o4_probes=0,
             skipped_o2_cmds=0)
    ok_bash = bash_accepts(text, locale)
    try:
        toks, comments, heredocs = mod.scan(text)
        lex_err = None
    except ST.ShellLexError as e:
        lex_err = e
    except Exception as e:                      # a crash is a finding, not a skip
        F.append(f"{name}: CRASH tokenizer raised {type(e).__name__}: {e}")
        return F, C
    if lex_err and ok_bash:
        F.append(f"{name}: O1 bash -n accepts but tokenizer raised: {lex_err}")
    if posix and DASH:
        ok_dash = dash_accepts(text, locale)
        if lex_err and ok_dash:
            F.append(f"{name}: O1 dash -n accepts but tokenizer raised: {lex_err}")
    if lex_err or not ok_bash:
        return F, C
    C["accepted"] = 1

    # O2
    cmds, keep = [], []
    for cmd in collect_commands(text, mod):
        words = replayable(cmd)
        if words is None:
            C["skipped_o2_cmds"] += 1
            continue
        cmds.append(words)
    if cmds:
        got = bash_words(cmds, locale)
        if len(got) != len(cmds):
            F.append(f"{name}: O2 bash replayed {len(got)} commands, we split {len(cmds)}")
        for words, theirs in zip(cmds, got):
            ours = [mod.unquote(w) for w in words]
            C["o2_cmds"] += 1
            C["o2_words"] += len(words)
            if ours != theirs:
                F.append(f"{name}: O2 words differ: ours={ours!r} bash={theirs!r}")

    # O3
    canon = bash_reprint(text, locale)
    if canon is not None:
        C["o3"] = 1
        try:
            a, b = shape(text, mod), shape(canon, mod)
            if a != b and REPRINT_MISPLACES_HEREDOC.search(canon):
                # bash's own reprint can lay a here-document opened in an
                # `if`/`while` header after the branch's first command, so
                # that reprint means something else (the body swallows the
                # command).  Such a file is not compared; O4 still probes its
                # here-documents.  Counted, never silent.
                C["o3"] = 0
                C["o3_reprint_unusable"] = C.get("o3_reprint_unusable", 0) + 1
            elif a != b:
                F.append(f"{name}: O3 structure differs from bash's reprint: "
                         + _first_diff(a, b))
        except ST.ShellLexError as e:
            F.append(f"{name}: O3 tokenizer rejects bash's own reprint: {e}")

    # O4
    if probes:
        _region_probes(name, text, mod, comments, heredocs, locale, F, C)
    return F, C


MARK = "&&&& "   # a syntax error wherever bash reads shell; inert in data


PROBE_CAP = 48   # per class per file; --full lifts it (stated in the resolution)


def _sample(seq, cap):
    if cap is None or len(seq) <= cap:
        return list(seq)
    step = len(seq) / cap
    return [seq[int(i * step)] for i in range(cap)]


def _region_probes(name, text, mod, comments, heredocs, locale, F, C):
    """O4: plant MARK where we claim data (must stay accepted) and where we
    claim code (must be rejected); bash decides."""
    cap = None if FULL else PROBE_CAP
    probes = []                       # (position, must_accept, message)
    for start, end in _sample(comments, cap):
        probes.append((start + 1, True, "we call this a comment; bash reads it as shell"))
    body_lines = []
    for start, end, strip in heredocs:
        lines = []
        pos = start
        while pos < end:
            nl = text.find("\n", pos, end)
            stop = end if nl < 0 else nl
            ins = pos
            if strip:
                while ins < stop and text[ins] == "\t":
                    ins += 1
            lines.append(ins)
            pos = stop + 1
        # every body's first and last line: where a wrong boundary shows
        body_lines.extend(sorted({lines[0], lines[-1]}) if lines else [])
    for ins in _sample(body_lines, None if FULL else 4 * PROBE_CAP):
        probes.append((ins, True, "we call this a here-document body; bash reads it as shell"))
    if heredocs or "<<" in text:
        groups = [g for _, g in mod.logical_lines(text)]
        ends = sorted(e for _, e, _ in heredocs)
        after = set()
        for e in ends:                # the first code line after each body
            for g in groups:
                if g[0].start >= e:
                    after.add(g[0].start)
                    break
        others = [g[0].start for g in groups if g[0].start not in after]
        for pos in sorted(after) + _sample(others, cap):
            probes.append((pos, False, "we call this line code; bash reads it as data"))
    if not probes:
        return
    verdicts = bash_accepts_many(text, [p for p, _, _ in probes], locale)
    if not verdicts or not verdicts[0]:   # the wrapper cannot hold this file
        C["o4_fallback_files"] = C.get("o4_fallback_files", 0) + 1
        verdicts = [True] + [bash_accepts(text[:p] + MARK + text[p:], locale)
                             for p, _, _ in probes]
    for (pos, must_accept, msg), ok in zip(probes, verdicts[1:]):
        C["o4_probes"] += 1
        if ok != must_accept:
            F.append(f"{name}:{_line(text, pos)}: O4 {msg}")


_PARSE_MANY = r"""
while IFS= read -r -d '' src; do
  if eval "__oracle_probe() {
$src
}"; then printf 1; else printf 0; fi
  unset -f __oracle_probe
done
"""


def bash_accepts_many(text, positions, locale="C"):
    """Parse TEXT, then TEXT with MARK planted at each position, each as a
    function body, in one restricted bash: nothing is executed, only a
    function is defined.  Probes are streamed, never all held in memory.
    Returns verdicts for [original] + probes."""
    p = subprocess.Popen([BASH, "--norc", "--noprofile", "-r", "-c", _PARSE_MANY],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=_env(locale))
    raw = text.encode(errors="surrogateescape")
    mark = MARK.encode()
    # byte offsets: probes are positions in str; convert once
    offsets = _byte_offsets(text, positions)
    try:
        p.stdin.write(raw + b"\0")
        for off in offsets:
            p.stdin.write(raw[:off] + mark + raw[off:] + b"\0")
        p.stdin.close()
    except BrokenPipeError:
        pass                              # bash exited early; the length check below decides
    out = p.stdout.read().decode()
    p.wait(timeout=300)
    if len(out) != len(positions) + 1:
        return None
    return [c == "1" for c in out]


def _byte_offsets(text, positions):
    out = []
    for pos in positions:
        out.append(len(text[:pos].encode(errors="surrogateescape")))
    return out


def _line(text, pos):
    return text.count("\n", 0, pos) + 1


def _first_diff(a, b):
    ca, cb = a[0], b[0]
    for i, (x, y) in enumerate(zip(ca, cb)):
        if x != y:
            return f"command {i}: ours {x!r} vs reprint {y!r}"
    if len(ca) != len(cb):
        return f"{len(ca)} commands vs reprint {len(cb)}"
    if a[1] != b[1]:
        return f"redirections {a[1]!r} vs {b[1]!r}"
    if a[3] != b[3]:
        return f"function definitions {a[3]!r} vs {b[3]!r}"
    return f"here-documents {a[2]!r} vs {b[2]!r}"


# ------------------------------------------------------------------ corpus

def tracked_shell_files():
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"],
                         capture_output=True, check=True).stdout.decode().split("\0")
    files = []
    for rel in out:
        if not rel:
            continue
        p = ROOT / rel
        if not p.is_file():
            continue
        if rel.endswith(".sh"):
            files.append(rel)
            continue
        if "." not in Path(rel).name:
            try:
                head = p.open("rb").readline(200)
            except OSError:
                continue
            if re.match(rb"^#!.*\b(ba|da)?sh\b", head):
                files.append(rel)
    return sorted(files)


def is_posix(text):
    first = text.split("\n", 1)[0]
    return bool(re.match(r"^#!\s*(/usr)?/bin/(env\s+)?(sh|dash)\b", first))


def run_corpus(items, mod=ST, locale="C", jobs=None, probes=True):
    """items: [(name, text)]. Returns (findings sorted, counters summed)."""
    findings, total = [], {}
    jobs = jobs or min(8, os.cpu_count() or 2)

    def one(item):
        name, text = item
        return check_text(name, text, mod, locale, is_posix(text), probes)

    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for F, C in ex.map(one, items):
            findings.extend(F)
            for k, v in C.items():
                total[k] = total.get(k, 0) + v
    return sorted(findings), total


# ------------------------------------------------------- H: incident cases
# (text, expected simple commands as raw word texts, expected heredoc bodies)
INCIDENTS = [
    # CA-GUARD:heredoc-opener round 8: a here-string is not an opener.
    ("tr a-z A-Z <<< hello\neigenscript-full work.eigs\n",
     [["tr", "a-z", "A-Z"], ["eigenscript-full", "work.eigs"]], []),
    # round 8: `<<` inside quotes is text.
    ('echo "see <<EOF above"\neigenscript-full work.eigs\n',
     [["echo", '"see <<EOF above"'], ["eigenscript-full", "work.eigs"]], []),
    # round 9: a heredoc inside a quoted $( ) is a real opener.
    ('msg="$(cat <<EOF\nusage: eigenscript-prose\nEOF\n)"\nreal-cmd\n',
     [['msg="$(cat <<EOF\nusage: eigenscript-prose\nEOF\n)"'], ["real-cmd"]], []),
    # round 8 finding 5: a substitution inside double quotes is shell.
    ('BIN="$(command -v eigenscript-full)"\n',
     [['BIN="$(command -v eigenscript-full)"']], []),
    # comment only at word start; `a#b` is a word.
    ("echo a#b # gone\n", [["echo", "a#b"]], []),
    # line continuation inside a word and between words.
    ("ec\\\nho a \\\n  b\n", [["echo", "a", "b"]], []),
    # `<<-` strips tabs; quoted delimiter; body is data.
    ("cat <<-'X'\n\techo not-a-command\n\tX\nafter\n",
     [["cat"], ["after"]], ["\techo not-a-command\n"]),
    # case pattern `)` inside $( ) does not close the substitution.
    ("y=$(case $x in a) echo 1;; esac) && w\n",
     [["y=$(case $x in a) echo 1;; esac)"], ["w"]], []),
    # [[ ]] operands are not operators.
    ("[[ $a < $b && -f c ]] && go\n",
     [["[[", "$a", "<", "$b", "&&", "-f", "c", "]]"], ["go"]], []),
    # IO number folds into the redirection; targets are not words.
    ("e 2>&1 >/dev/null f\n", [["e", "f"]], []),
    # a quoted string spanning lines stays one word.
    ("a 'multi\nline' b\nc\n", [["a", "'multi\nline'", "b"], ["c"]], []),
    # array value with quotes and a substitution is one word.
    ("arr=(a 'b c' $(d)) ; e\n", [["arr=(a 'b c' $(d))"], ["e"]], []),
    # here-document with no delimiter line runs to end of file (bash accepts).
    ("cat <<EOF\nbody\n", [["cat"]], ["body\n"]),
    # backquote body: \` is a nested backquote, not the end.
    ("echo `z \\`q\\``\n", [["echo", "`z \\`q\\``"]], []),
    # an escaped double quote does not close the string.
    ('echo "a\\"b" c\n', [["echo", '"a\\"b"', "c"]], []),
    # held out (EigenMiniSat): a named descriptor folds into its redirection.
    ("exec {fd}<&- 3>&-\n", [["exec"]], []),
    # held out (DMG): a `#` inside the =~ regex is not a comment.
    ('[[ "$l" =~ ^[[:space:]]*(#|$) ]] && continue\nnext\n',
     [["[[", '"$l"', "=~", "^[[:space:]]*(#|$)", "]]"], ["continue"], ["next"]], []),
    # critic r1: `<<` inside (( )) is a shift, not a here-document.
    ("(( n = n << 1 ))\neigenscript-full a.eigs\n", [["eigenscript-full", "a.eigs"]], []),
    ("for (( i=0; i<n; i++ )); do x; done\n", [["for"], ["do", "x"], ["done"]], []),
    # critic r1: a $( ) inside $(( )) is run; a quote inside $(( )) is not a $( ).
    ("n=$(( $(eigenscript-full a.eigs) + 1 ))\n",
     [["n=$(( $(eigenscript-full a.eigs) + 1 ))"]], [], ["eigenscript-full a.eigs"]),
    ('x=$(( "1" + 2 ))\n', [['x=$(( "1" + 2 ))']], [], []),
    # critic r1: backquote bodies are recorded (the deriver scans them).
    ("echo `c a` \"$(d)\"\n", [["echo", "`c a`", '"$(d)"']], [], ["c a", "d"]),
    # critic r1: unquoted delimiter -- backslash-newline joins body lines first.
    ("cat <<EOF\nline \\\nEOF\nprose\nEOF\nreal\n", [["cat"], ["real"]],
     ["line \\\nEOF\nprose\n"]),
    ("cat <<'EOF'\nline \\\nEOF\nreal\n", [["cat"], ["real"]], ["line \\\n"]),
    # `<<-` strips leading TABS only: a space-indented delimiter does not end it.
    ("cat <<-X\n\tbody\n  X\n\tX\nreal\n", [["cat"], ["real"]], ["\tbody\n  X\n"]),
    # DevBox on #2559: `coproc NAME { ...; }` -- NAME, then a group.
    ("coproc QP { cat; }\necho x\n", [["coproc", "QP"], ["{"], ["cat"], ["}"], ["echo", "x"]], []),
    # DevBox r3: command position after a compound command, `function NAME`
    # and `for (( ))`, with no separator.
    ("for ((i=0;i<8;i++)) do (( m = m << 1 )); done\neigenscript-full w.eigs\n",
     [["for"], ["do"], ["done"], ["eigenscript-full", "w.eigs"]], []),
    ("function f { (( n << 1 )); }\nreal\n", [["function", "f"], ["{"], ["}"], ["real"]], []),
    ("if [[ x ]] then bash a.sh; fi\n", [["if", "[[", "x", "]]"], ["then", "bash", "a.sh"], ["fi"]], []),
    ("function f { !(cmd); }\nreal\n",
     [["function", "f"], ["{"], ["!"], ["cmd"], ["}"], ["real"]], []),
    ("a[1<<3]=x\nreal\n", [["a[1<<3]=x"], ["real"]], []),
    ("echo $[1<<3]\nreal\n", [["echo", "$[1<<3]"], ["real"]], []),
    ("tmp=/tmp/x.$$'\\'\nreal\n", [["tmp=/tmp/x.$$'\\'"], ["real"]], []),
    ("if a; then b; elif (( n << 1 )); then c; fi\nreal\n",
     [["if", "a"], ["then", "b"], ["elif"], ["then", "c"], ["fi"], ["real"]], []),
    ("until (( n << 1 )); do :; done\nreal\n", [["until"], ["do", ":"], ["done"], ["real"]], []),
    ("case x in a) b;& c) d;; esac\nreal\n", [["case", "x", "in"], ["b"], ["d"], ["esac"], ["real"]], []),
    ("case x in (a|b) c;; esac\nreal\n", [["case", "x", "in"], ["c"], ["esac"], ["real"]], []),
    # an expanded here-document body's $( ) runs; a quoted one's does not.
    ("cat <<EOF\nx $(eigenscript-full a)\nEOF\n", [["cat"]], ["x $(eigenscript-full a)\n"],
     ["eigenscript-full a"]),
    ("cat <<\\EOF\n$(x)\nEOF\n", [["cat"]], ["$(x)\n"], []),
    ("coproc cat file\n", [["coproc", "cat", "file"]], []),
    # critic r2: `!(cmd)` at a command position negates a subshell.
    ("if !(eigenscript-gfx --version); then :; fi\n",
     [["if", "!"], ["eigenscript-gfx", "--version"], ["then", ":"], ["fi"]], []),
    # critic r2: in double quotes a backquote body unescapes \" too.
    ('B="`c -v \\"x y\\"`"\n', [['B="`c -v \\"x y\\"`"']], [], ['c -v "x y"']),
    ("echo `p \\\"a\\\"`\n", [["echo", "`p \\\"a\\\"`"]], [], ['p \\"a\\"']),
    # critic r2: process substitution inside a word stays in the word.
    ("x=a<(w b) c\n", [["x=a<(w b)", "c"]], [], ["w b"]),
    # critic r2: command position after `time -p`, after NAME=value, at `{`.
    ("time -p (( n << 1 ))\nreal\n", [["time", "-p"], ["real"]], []),
    ("time (( n << 1 ))\nreal\n", [["time"], ["real"]], []),
    ("FOO=1 [[ a < b ]]\n", [["FOO=1", "[[", "a", "]]"]], []),
    ("echo {1}>x\n", [["echo", "{1}"]], []),
    # critic r2: a delimiter line with a trailing blank does not end the body.
    ("cat <<EOF\nbody\nEOF \nEOF\nreal\n", [["cat"], ["real"]], ["body\nEOF \n"]),
    # critic r2: a quote inside $(( )) is not a $( ).
    ("y=$(( ')' ))\n", [["y=$(( ')' ))"]], [], []),
    # ${x:-...} with a nested substitution and a `}` in quotes.
    ('echo ${x:-"}"$(y)} t\n', [["echo", '${x:-"}"$(y)}', "t"]], []),
]


FUNC_INCIDENTS = [
    # hq#58's definition scope: only a definition the shell executes counts.
    ("f() { :; }\nfunction g { :; }\nh () {\n:\n}\n", ["f", "g", "h"]),
    ("cat <<E\nx() {\nE\n# y() {\necho 'z() {'\n", []),
    ("if true; then k() { :; }; fi; a && m() { :; }\n", ["k", "m"]),
    # held out (EigenMiniSat): a stub defined in a case branch.
    ("case $p in a) find() { return 7; } ;; esac\n", ["find"]),
    # critic r1: a definition inside a ( ) subshell is gone when it closes.
    ("( f() { :; } )\ng() { :; }\n", ["g"]),
]


UNQUOTE_INCIDENTS = [
    # critic r1: ANSI-C escapes as bash decodes them (bash 5.2, C.UTF-8).
    ("$'\\x41'", "A"), ("$'\\101'", "A"), ("$'\\cA'", "\x01"), ("$'\\c?'", "\x7f"),
    ("$'\\x4g'", "\x04g"), ("$'\\u00e9'", "\u00e9"), ("$'\\777'", "\udcff"),
    ("a\\ b'c'\"d\\\"e\"", 'a bcd"e'),
    # critic r2 (bash 5.2.21): width of \u, NUL ends the word, bare \c, \x{..}.
    ("$'\\u00410'", "A0"), ("$'a\\0b'", "a"), ("$'\\c'", "\\c"), ("$'\\x{41}'", "A"),
]


def check_incidents(mod=ST):
    F = []
    # tokenize_prefix: text the shell rejects is read up to the line where
    # tokenizing stopped -- not dropped whole (DevBox r3 mutant).
    got = [[w.text for w in c] for c in mod.simple_commands(
        mod.tokenize_prefix('bash a.sh\necho "unclosed\nbash b.sh\n'))]
    if got != [["bash", "a.sh"]]:
        F.append(f"H tokenize_prefix: {got!r}, want [['bash', 'a.sh']]")
    for word, want in UNQUOTE_INCIDENTS:
        got = mod.unquote(word)
        if got != want:
            F.append(f"H unquote {word!r}: {got!r}, want {want!r}")
    for text, want in FUNC_INCIDENTS:
        got = mod.function_definitions(mod.tokenize(text))
        if got != want:
            F.append(f"H {text!r}: function definitions {got!r}, want {want!r}")
    for row in INCIDENTS:
        text, want_cmds, want_docs = row[:3]
        try:
            toks = mod.tokenize(text)
        except Exception as e:
            F.append(f"H {text!r}: tokenizer raised {e}")
            continue
        got = [[w.text for w in c] for c in mod.simple_commands(toks)]
        docs = [t.heredoc for t in toks if t.heredoc is not None]
        if got != want_cmds or docs != want_docs:
            F.append(f"H {text!r}: got {got!r} docs {docs!r}")
        if len(row) > 3:
            subs = [b for t in toks for b in t.subst]
            if subs != row[3]:
                F.append(f"H {text!r}: substitution bodies {subs!r}, want {row[3]!r}")
    return F


# ----------------------------------------------------------------- plants
# Source mutations of _shell_tokens.py; each must be caught by the oracles
# named.  The old text must occur exactly once, so a plant cannot go stale.
PLANTS = [
    ("hash-mid-word-is-comment",
     'METACHARS = frozenset(" \\t\\n;&|()<>")',
     'METACHARS = frozenset(" \\t\\n;&|()<>#")', {"H", "O4"}),
    ("heredoc-body-read-as-code",
     "                if self.pending:\n                    self.read_heredocs()",
     "                if False:\n                    self.read_heredocs()", {"H", "O1", "O3", "O4"}),
    ("here-string-read-as-heredoc",
     'OPERATORS = (\n    ";;&", "<<<",', 'OPERATORS = (\n    ";;&",', {"H", "O3", "O4"}),
    ("double-quote-escape-ignored",
     """            if c == "\\\\":
                if self.text[j + 1:j + 2] == "\\n":
                    self.cuts.add(j)
                j += 2
                continue
            if c == '"':
                return j + 1""",
     """            if c == '"':
                return j + 1""", {"H", "O1", "O3"}),
    ("continuation-not-removed",
     "            if i not in self.cuts and i - 1 not in self.cuts)",
     "            if True)", {"H", "O3"}),
    ("case-pattern-closes-substitution",
     "    def in_pattern(self) -> bool:\n        return bool(self.case) and self.case[-1] == \"pattern\"",
     "    def in_pattern(self) -> bool:\n        return False", {"H", "O3"}),
    ("dbracket-operands-as-operators",
     "                self.dbracket = True\n",
     "                self.dbracket = False\n", {"H"}),
    ("arith-expansion-read-as-command-substitution",
     'if t.startswith("$((", j) and self.arith_closes(j + 3):',
     'if False:', {"H"}),
    ("arith-command-read-as-subshells",
     '            if t.startswith("((", self.i) and not self.dbracket and \\',
     '            if False and \\', {"H"}),
    ("backquote-bodies-dropped",
     '                subst.append("".join(body))\n                return j + 1',
     '                return j + 1', {"H"}),
    ("heredoc-delimiter-compared-stripped",
     '                cmp = line.lstrip("\\t") if strip else line',
     '                cmp = line.strip()', {"H"}),
    ("heredoc-continuation-ignored",
     '                while not quoted and nl >= 0 and \\',
     '                while False and \\', {"H"}),
    ("ansi-hex-escape-literal",
     '    if e in "xuU":', '    if False:', {"H"}),
    ("subshell-definitions-counted",
     '        if tok.kind == "word" and at_start and depth == 0:',
     '        if tok.kind == "word" and at_start:', {"H"}),
    ("unicode-escape-out-of-range-crashes",
     "        if value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:",
     "        if False:", {"R"}),
    ("negated-subshell-read-as-extglob",
     '                if prefix == "!" and self.cmdpos:',
     '                if False:', {"H"}),
    ("quoted-heredoc-delimiter-not-unquoted",
     "            self.pending.append((idx, unquote(word), strip, quoted))",
     "            self.pending.append((idx, word, strip, quoted))", {"H", "O1", "O3", "O4"}),
]


def load_mutant(old, new):
    src = (HERE / "_shell_tokens.py").read_text()
    if src.count(old) != 1:
        raise SystemExit(f"INSTRUMENT ERROR: plant text occurs {src.count(old)} times:\n{old}")
    spec = importlib.util.spec_from_loader("_shell_tokens_mutant", loader=None)
    mod = importlib.util.module_from_spec(spec)
    exec(compile(src.replace(old, new), "_shell_tokens_mutant", "exec"), mod.__dict__)
    mod.ShellLexError = ST.ShellLexError     # one exception class for the harness
    return mod


def _oracles_of(findings):
    tags = set()
    for f in findings:
        m = re.search(r"\b(O[1-4]|CRASH)\b", f)
        if f.startswith("H "):
            tags.add("H")
        elif f.startswith("R "):
            tags.add("R")
        elif m:
            tags.add(m.group(1))
    return tags


def load_items(paths):
    items = []
    for rel in paths:
        p = Path(rel) if Path(rel).is_absolute() else ROOT / rel
        items.append((rel, p.read_text(errors="surrogateescape")))
    return items


def incident_items():
    return [(f"incident#{i}", row[0]) for i, row in enumerate(INCIDENTS)]


# O5: composed programs.  Every construct inside every wrapper, followed by
# a marker command.  bash decides whether the marker line is code (a syntax
# error planted there must be rejected); the tokenizer must read it as the
# file's last command.  Command position after a compound command is where
# a lexer goes wrong; this is the population that reaches it (DevBox r3).
O5_WRAPPERS = [
    "{C}\n", "if true; then\n{C}\nfi\n", "if (( 1 )) then\n{C}\nfi\n",
    "if [[ x ]] then\n{C}\nfi\n", "for ((i=0;i<2;i++)) do\n{C}\ndone\n",
    "for x in a b; do\n{C}\ndone\n", "while false; do\n{C}\ndone\n",
    "until true; do\n{C}\ndone\n", "function f {\n{C}\n}\n", "f() {\n{C}\n}\n",
    "g() (\n{C}\n)\n", "{\n{C}\n}\n", "(\n{C}\n)\n",
    "case x in\n  a)\n{C}\n  ;;\n  (b) :\n  ;;\nesac\n", "x=$(\n{C}\n)\n",
    "if a; then :; elif (( 1 )); then\n{C}\nfi\n", "while x; do :; done && {\n{C}\n}\n",
    "! {\n{C}\n}\n", "coproc C1 {\n{C}\n}\n", "for x in a; do :; done\n{C}\n",
    "[[ a ]] && {\n{C}\n}\n", "time {\n{C}\n}\n",
]
O5_CONSTRUCTS = [
    "(( n = n << 1 ))", "[[ a < b && c ]]", "!(true)", "a[1<<3]=x", "echo $[1<<3]",
    "tmp=x.$$'\\'", "cat <<EOF\nbody $(x)\nEOF", "cat <<-'E'\n\tbody\n\tE",
    "tr a b <<< c", "echo \"a\n#b\" # c", "case y in z) : ;; esac", "x=$(( 1 << 2 ))",
    "echo `echo a`", "arr=(a 'b c')", "for ((j=0;j<1;j++)); do :; done",
    "echo ${x:-'}'}", "coproc QP { cat; }", "time -p (( 1 << 2 ))", "echo a \\\n b",
    "if (( 1 )) then (( n << 1 )); fi", "function h { (( n << 1 )); }",
]
O5_MARKER = "eigenscript-full end"


def composed_items():
    return [(f"composed#{w}.{c}", O5_WRAPPERS[w].replace("{C}", O5_CONSTRUCTS[c]) + O5_MARKER + "\n")
            for w in range(len(O5_WRAPPERS)) for c in range(len(O5_CONSTRUCTS))]


def composed_findings(mod=ST, locale="C"):
    """O5 for every composed program bash accepts: bash must read the marker
    line as code, and so must the tokenizer."""
    F, kept = [], 0

    def one(item):
        name, text = item
        if not bash_accepts(text, locale):
            return None
        pos = text.rindex(O5_MARKER)
        bash_code = not bash_accepts(text[:pos] + MARK + text[pos:], locale)
        try:
            lines = list(mod.logical_lines(text))
            ours = lines and [t.text for t in lines[-1][1]] == O5_MARKER.split()
        except Exception as e:                # noqa: BLE001 -- reported as a finding
            return f"{name}: O5 tokenizer raised {type(e).__name__}: {e}"
        if bash_code and not ours:
            return f"{name}: O5 bash runs the marker line; the tokenizer does not read it as a command"
        if not bash_code and ours:
            return f"{name}: O5 the tokenizer reads the marker line as a command; bash reads it as data"
        return ""

    with concurrent.futures.ThreadPoolExecutor(min(8, os.cpu_count() or 2)) as ex:
        for r in ex.map(one, composed_items()):
            if r is None:
                continue
            kept += 1
            if r:
                F.append(r)
    return F, kept


ROBUST_N = 4000
ROBUST_PARTS = ["a", " ", "\n", "'", '"', "\\", "$", "(", ")", "{", "}", "`", "<<", "<<-",
                "<<<", "EOF", "#", ";", "&&", "|", "[[", "]]", "((", "))", "$(", "${", "$((",
                "$'", "\\x", "\\u", "\\U", "\\c", "\\0", "case", "in", "esac", "for",
                "time", "!", "=~", "x=", "<(", ">&", "2>", "{fd}", "\t", "\\\n", "\u00e9",
                "110000", "D800", "41", "?", "0", "777", "'"]


ROBUST_ESCAPES = ["\\U110000", "\\UD800", "\\U41", "\\u", "\\uDFFF", "\\x", "\\x{", "\\x{zz}",
                  "\\x{41}", "\\c", "\\c?", "\\c\\\\", "\\c\u00e9", "\\777", "\\0", "\\'", "a",
                  "\\", "\\q"]


def robustness(mod=ST):
    """Seeded random shell-ish text: the tokenizer may reject it, never crash
    (a crash would take a whole gate down instead of reading a prefix)."""
    import random
    rng = random.Random(20261125)
    bad = []
    for _ in range(ROBUST_N):
        text = "".join(rng.choice(ROBUST_PARTS) for _ in range(rng.randint(1, 40)))
        if rng.random() < 0.5:                # an ANSI-C string of escapes
            text = "echo $'" + "".join(rng.choice(ROBUST_ESCAPES)
                                       for _ in range(rng.randint(1, 6))) + "' " + text
        try:
            for tok in mod.tokenize_prefix(text):
                mod.unquote(tok.text)
            mod.function_definitions(mod.tokenize_prefix(text))
        except ST.ShellLexError:
            pass                          # rejecting is allowed; crashing is not
        except Exception as e:            # noqa: BLE001 -- the finding itself
            bad.append((text, f"{type(e).__name__}: {e}"))
    return bad


def selftest():
    if not BASH or not DASH:
        print("INSTRUMENT ERROR: shell_oracle needs bash and dash "
              f"(bash={BASH}, dash={DASH})")
        return 2
    items = load_items(tracked_shell_files()) + incident_items() + composed_items()
    rc = 0
    print(f"PLAN: {5 + len(PLANTS)}")

    o5, o5_kept = composed_findings()
    if o5:
        rc = 1
        print(f"  FAIL: composed programs: {len(o5)} finding(s) of {o5_kept}")
        for f in o5[:20]:
            print("    " + f)
    else:
        print(f"  PASS: composed programs: the tokenizer reads the marker as bash does in "
              f"{o5_kept} of {o5_kept} programs bash accepts "
              f"({len(O5_WRAPPERS)} wrappers x {len(O5_CONSTRUCTS)} constructs)")

    bad = robustness()
    if bad:
        rc = 1
        print(f"  FAIL: tokenizer raised something other than ShellLexError on {len(bad)} input(s)")
        for text, err in bad[:5]:
            print(f"    {text!r}: {err}")
    else:
        print(f"  PASS: {ROBUST_N} generated inputs: tokenize() and unquote() only ever "
              "return or raise ShellLexError")

    base, counts = run_corpus(items)
    base += check_incidents()
    print("population: " + " ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if base:
        rc = 1
        print(f"  FAIL: corpus has {len(base)} finding(s)")
        for f in base[:40]:
            print("    " + f)
    else:
        print("  PASS: corpus agrees with bash/dash on every oracle")

    again, _ = run_corpus(items)
    again += check_incidents()
    if again == base:
        print("  PASS: A/A rerun identical")
    else:
        rc = 1
        print("  FAIL: A/A rerun differs")
    # Every 4th file (deterministic) plus the incidents: the locale A/A and
    # each plant run on this subset to bound the selftest's time.
    subset = items[::4] + incident_items()
    sub_base, _ = run_corpus(subset)
    other, _ = run_corpus(subset, locale="C.UTF-8")
    if other == sub_base:
        print("  PASS: A/A under LC_ALL=C.UTF-8 identical")
    else:
        rc = 1
        print("  FAIL: locale changes the findings")

    for name, old, new, expect in PLANTS:
        mod = load_mutant(old, new)
        found, _ = run_corpus(subset, mod=mod)
        found += check_incidents(mod)
        found += [f"R {t!r}: {e}" for t, e in robustness(mod)]
        found += composed_findings(mod)[0]
        tags = _oracles_of(found)
        if found and expect <= tags:
            print(f"  PASS: plant {name} caught by {','.join(sorted(tags))} "
                  f"({len(found)} findings)")
        else:
            rc = 1
            print(f"  FAIL: plant {name} caught by {sorted(tags) or 'nothing'}; "
                  f"expected at least {sorted(expect)}")
    print(f"shell-oracle selftest: {'OK' if rc == 0 else 'FAILED'}")
    return rc


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if not BASH:
        print("INSTRUMENT ERROR: bash not found")
        return 2
    want_json = "--json" in argv
    paths = [a for a in argv if not a.startswith("--")] or tracked_shell_files()
    items = load_items(paths)
    findings, counts = run_corpus(items)
    findings += check_incidents()
    if want_json:
        print(json.dumps({"findings": findings, "counts": counts}, indent=1))
    else:
        for f in findings:
            print(f)
        print("shell-oracle: " + " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
              + f" findings={len(findings)}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
