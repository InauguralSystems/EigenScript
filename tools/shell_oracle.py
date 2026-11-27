#!/usr/bin/env python3
"""Differential oracle for tools/_shell_tokens.py: bash and dash supply the
expected answers, never the tokenizer itself.

    python3 tools/shell_oracle.py [--json] [FILE...]   # default: tracked *.sh
    python3 tools/shell_oracle.py --selftest           # plants + A/A + corpus
    python3 tools/shell_oracle.py --execution 4,5,6 2000   # O7 on more programs

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
  O5 composed every construct inside every wrapper, a marker command after
              it: a syntax error planted before the marker tells whether bash
              reads the marker line as code, and the tokenizer must agree.
  O6 openers  a syntax error planted right after every `$(`, `<(`, `>(`:
              bash parses a substitution there  <=>  we recorded a body there.
  O7 execution bash RUNS seeded generated programs (tools/_shell_exec.py)
              whose commands are names no machine has; the names bash tried
              to run are the expected answer.  The words we give role
              'command' must be exactly those names, and the three consumers
              (tools/_derive_variants.py, tools/enrolment_edges.py, the
              GNU-flag scanner in tools/portability_parse_check.sh) must
              report every one.  This is the only oracle that reaches the
              consumers' own command-position rules.
  H  incidents hand-checked expected tokens for the shapes that bit the line
              scanners before (CA-GUARD rounds in tools/_derive_variants.py,
              hq#58) and for constructs the tree does not contain; each row
              about what RUNS was first put to bash (O7's harness).

RESOLUTION is stated, not assumed: --selftest applies source mutations
(PLANTS) to a copy of the tokenizer and requires each to be caught by the
oracle(s) listed for it, applies source mutations to copies of the three
consumers (CONSUMER_PLANTS, one of them the regression a review found in
61d65f6) and requires O7 to catch each, and runs the whole oracle twice (and
under a second locale) requiring byte-identical findings (A/A; for O7, the
same names run in a second execution of the same programs).

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
    redirections, here-document continuations, a here-document read below
    the substitution that opened it) and does not compare redirection
    targets; a file whose reprint misplaces a here-document from an
    `if`/`while` header is counted as o3_reprint_unusable, not compared.
  * not modelled, and not in the tree: an operator split by a line
    continuation (`<\\<newline><EOF`), posix-mode quoting inside ${...}
    (`${x:?it's}` in a dash file), a `<<-` delimiter that itself holds a
    tab, and the ANSI-C edge cases `\\x{}`, `\\c\\'` and `\\UFFFFFFFF`, which
    were not checked against bash.  `$'\\U110000'` and `$'\\uD800'` are kept
    as written; bash 5.2 under C.UTF-8 emits bytes for them.
  * the dialect is bash's: in a `#!/bin/sh` file dash reads `((cmd))` as
    two subshells, the tokenizer as an arithmetic command (dash corpus of
    the r5 review: 1 such miss in 501).
  * a function defined in a pipeline element or a backgrounded group
    (subshells bash discards) is read differently from bash; none occurs in
    the tree.  `!(` at a command position is read as negation (extglob off,
    as in scripts); elsewhere as an extglob group.
  * a here-document opened inside a $( ) that closes first (`$(cat <<EOF)`)
    is read from the lines below, as bash 5.2 reads it (with a warning);
    where that line ends inside a quoted string or another multi-line word
    the tokenizer stops (ShellLexError) -- a refusal, not a reading.
  * O7 runs what its generator can write: no aliases, `eval`, traps,
    `select`, extglob, or a command named by an expansion's VALUE (`$cmd x`
    with cmd set, `${x:-cmd} y`); the wrappers `env`, `sudo`, `nohup` and
    `exec` are shell functions that run their operand -- the consumers'
    contract, not the real programs -- and the wrappers one consumer knows
    and another does not (`timeout`, `xvfb-run`, `nice`) are not generated,
    so those rules have no oracle here; no dead code (every command is live
    by construction, so O7 says nothing about an `else` arm not taken --
    O1-O6 read those).  A substitution bash parses but this program never
    expands (`a[1]=$(c) cmd`: bash rejects the assignment first; the unused
    side of `${set:-$(c)}`) may be reported; running one is a finding.  bash
    5.2 only.
  * measured on bash 5.2 and NOT modelled (tools/_shell_exec.py says how
    each was seen): a `$( )` body is run from bash's own reprint of it, so a
    command NAMED like a reserved word after a leading redirection is the
    reserved word again there (`$(> f else x)`); arithmetic is expanded as
    if in double quotes, so `$(( '$(c)' ))`, `a['$(c)']=1` and `${v:'$(c)'}`
    run c; a here-document read below its substitution that ends on a line
    going on as shell text, and one read from inside a multi-line word, are
    refused (ShellLexError), not read.
  * dialect quirks measured and not modelled: a `((` that is not arithmetic
    and spans lines is a syntax error when its file is SOURCED, though
    `bash -n` and running the file accept it (read as the script runs);
    `$[ ... ]` holding an unbalanced `]` inside a `$( )` fails when expanded.
  * the plants are judged on the incidents and the programs composed into
    every 8th wrapper, never on tracked files (a verdict that rests on which
    files the tree holds changes when an unrelated file is added); the
    locale A/A reads every 8th tracked file as well; O7's plants are judged
    against one execution of its programs.
"""
from __future__ import annotations

import concurrent.futures
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

import _shell_exec as EX    # noqa: E402
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
        if words[:2] == ["coproc", "{"]:
            pieces.append((words[:1], subs[:1]))   # `coproc {`: reprinted on two lines
            words, subs = words[1:], subs[1:]
        if words[:2] == ["coproc", "COPROC"]:
            words, subs = words[:1] + words[2:], subs[:1] + subs[2:]   # bash names it
        if words[:1] == ["coproc"] and len(words) > 1 \
                and words[1] in ("while", "until", "for", "select", "if", "case", "[["):
            # #2586: unnamed compounds share a command with `coproc`; bash's
            # reprint adds COPROC, whose name role splits that command in two.
            pieces.append((words[:1], subs[:1]))
            words, subs = words[1:], subs[1:]
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
        # A here-document read BELOW the substitution that opened it is
        # recorded in line (as bash's reprint lays it out): in the original
        # only the body's first line(s) stand inside the word.
        cuts = [len(body)]
        if "<<" in body and body not in skeleton:
            cuts += [i for i in range(len(body) - 1, 0, -1) if body[i] == "\n"]
        for cut in cuts:
            if body[:cut] and body[:cut] in skeleton:
                skeleton = skeleton.replace(body[:cut], "", 1)
                break
        bodies.append(shape(body, mod, depth + 1))
    skeleton = _ansi_as_single(skeleton, mod)
    if not subst:
        return skeleton
    return ("word", re.sub(r"\s+", " ", skeleton), tuple(bodies))


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
        _substitution_probes(name, text, mod, heredocs, locale, F, C)
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


def _substitution_probes(name, text, mod, heredocs, locale, F, C):
    """O6 (DevBox's suggestion on #2559): every $( / <( / >( that bash parses
    as a substitution has a recorded body, and none that bash reads as text
    does.  bash decides by a syntax error planted right after the opener.
    Not asked: `$((` (arithmetic or not, bash's answer would mix the two),
    and openers inside here-document bodies and backquotes, which bash -n
    does not parse (bash expands them at run time; incidents cover them)."""
    if not hasattr(mod, "scan_full"):
        return
    ours = set(mod.scan_full(text)[3])
    inside_doc = [(a, b) for a, b, _ in heredocs]
    cands = []
    for opener in ("$(", "<(", ">("):
        p = text.find(opener)
        while p >= 0:
            if not text.startswith("$((", p) and \
                    not any(a <= p < b for a, b in inside_doc):
                cands.append(p)
            p = text.find(opener, p + 1)
    cands = _sample(sorted(cands), None if FULL else 4 * PROBE_CAP)
    if not cands:
        return
    verdicts = bash_accepts_many(text, [p + 2 for p in cands], locale)
    if not verdicts or not verdicts[0]:
        C["o6_fallback_files"] = C.get("o6_fallback_files", 0) + 1
        verdicts = [True] + [bash_accepts(text[:p + 2] + MARK + text[p + 2:], locale)
                             for p in cands]
    for p, accepted in zip(cands, verdicts[1:]):
        C["o6_probes"] = C.get("o6_probes", 0) + 1
        code = not accepted
        if code and p not in ours:
            F.append(f"{name}:{_line(text, p)}: O6 bash parses a substitution at "
                     f"{text[p:p + 2]!r}; the tokenizer recorded no body there")
        elif not code and p in ours:
            F.append(f"{name}:{_line(text, p)}: O6 the tokenizer recorded a body at "
                     f"{text[p:p + 2]!r}; bash reads it as text")


# Each eval runs in a subshell: a syntax error inside a $( ) is fatal to the
# shell that parses it, and must not end the loop for the probes after it.
_PARSE_MANY = r"""
while IFS= read -r -d '' src; do
  if ( eval "__oracle_probe() {
$src
}" ); then printf 1; else printf 0; fi
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
    except BrokenPipeError:
        pass                              # bash exited early; the length check below decides
    finally:
        try:
            p.stdin.close()
        except BrokenPipeError:
            pass                          # same: an early exit is decided by the length check
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
    # #2586: while body executes once; the following line starts a command.
    ("coproc QZV while :; do c1; break; done\nc3\n",
     [["coproc", "QZV"], ["while", ":"], ["do", "c1"], ["break"], ["done"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: until body executes once (false condition).
    ("coproc QZV until false; do c1; break; done\nc3\n",
     [["coproc", "QZV"], ["until", "false"], ["do", "c1"], ["break"], ["done"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: word-list for body executes.
    ("coproc QZV for x in a; do c1; done\nc3\n",
     [["coproc", "QZV"], ["for", "x", "in", "a"], ["do", "c1"], ["done"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: select receives input so its body is reached, unlike O7's generator.
    ("coproc QZV select x in a; do c1; break; done <<<1\nc3\n",
     [["coproc", "QZV"], ["select", "x", "in", "a"], ["do", "c1"], ["break"], ["done"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: the if branch executes.
    ("coproc QZV if :; then c1; fi\nc3\n",
     [["coproc", "QZV"], ["if", ":"], ["then", "c1"], ["fi"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: the matching case arm executes.
    ("coproc QZV case a in a) c1;; esac\nc3\n",
     [["coproc", "QZV"], ["case", "a", "in"], ["c1"], ["esac"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: [[ ]] expands its substitution; && c2 follows the coproc launch.
    ("coproc QZV [[ -z $(c1) ]] && c2\nc3\n",
     [["coproc", "QZV"], ["[[", "-z", "$(c1)", "]]"], ["c2"], ["c3"]], [], ["c1"], {"c1", "c2", "c3"}),
    # #2586: (( )) expands its substitution (the arithmetic token is not a command).
    ("coproc QZV (( $(c1) + 1 ))\nc3\n",
     [["coproc", "QZV"], ["c3"]], [], ["c1"], {"c1", "c3"}),
    # #2586: arithmetic for is a compound too, including without a space before ((.
    ("coproc QZV for((i=0;i<1;i++)); do c1; done\nc3\n",
     [["coproc", "QZV"], ["for"], ["do", "c1"], ["done"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: continuation before a compound is removed before recognition.
    ("coproc QZV \\\nwhile :; do c1; break; done\nc3\n",
     [["coproc", "QZV"], ["while", ":"], ["do", "c1"], ["break"], ["done"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: multiline [[ ]] permits newlines around a complete test.
    ("coproc QZV [[\n -z $(c1)\n ]] && c2\nc3\n",
     [["coproc", "QZV"], ["[[", "-z", "$(c1)", "]]"], ["c2"], ["c3"]], [], ["c1"], {"c1", "c2", "c3"}),
    # #2586: a nonidentifier name parses, but bash refuses to execute its compound.
    ("coproc a-b while :; do c1; break; done\nc3\n",
     [["coproc", "a-b"], ["while", ":"], ["do", "c1"], ["break"], ["done"], ["c3"]], [], [], {"c3"}),
    # #2586: a reserved word starts an unnamed coproc, even before another compound.
    ("coproc while if :; then :; fi; do c1; break; done\nc3\n",
     [["coproc", "while", "if", ":"], ["then", ":"], ["fi"], ["do", "c1"], ["break"], ["done"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: a quoted reserved word can instead be the coprocess name.
    ("coproc 'while' if :; then c1; fi\nc3\n",
     [["coproc", "'while'"], ["if", ":"], ["then", "c1"], ["fi"], ["c3"]], [], [], {"c1", "c3"}),
    # #2586: keyword suffixes are ordinary arguments.
    ("coproc QZV whilex\nc3\n", [["coproc", "QZV", "whilex"], ["c3"]], [], [], {"QZV", "c3"}),
    # #2586: assignment-like suffixes are ordinary arguments.
    ("coproc QZV while=1\nc3\n", [["coproc", "QZV", "while=1"], ["c3"]], [], [], {"QZV", "c3"}),
    # #2586: single quotes suppress compound recognition.
    ("coproc QZV 'while'\nc3\n", [["coproc", "QZV", "'while'"], ["c3"]], [], [], {"QZV", "c3"}),
    # #2586: double quotes suppress compound recognition.
    ('coproc QZV "if"\nc3\n', [["coproc", "QZV", '"if"'], ["c3"]], [], [], {"QZV", "c3"}),
    # #2586: a plain argument leaves QZV as the command.
    ("coproc QZV arg\nc3\n", [["coproc", "QZV", "arg"], ["c3"]], [], [], {"QZV", "c3"}),
    # #2586: a physical newline ends the unnamed simple coproc.
    ("coproc QZV\nwhile :; do c1; break; done\nc3\n",
     [["coproc", "QZV"], ["while", ":"], ["do", "c1"], ["break"], ["done"], ["c3"]], [], [], {"QZV", "c1", "c3"}),
    # #2586: bash rejects the unmatched fi before it runs either name.
    ("coproc QZV ifx; fi\nc3\n", [["coproc", "QZV", "ifx"], ["fi"], ["c3"]], [], [], set()),
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
    # DevBox r4: `for NAME do`, `(v=1) then`, `f+()`, a newline inside [[ ]].
    ("for x do (( n << 1 )); done\nreal\n", [["for", "x", "do"], ["done"], ["real"]], []),
    ("if (v=1) then (( n << 1 )); fi\nreal\n",
     [["if"], ["v=1"], ["then"], ["fi"], ["real"]], []),
    ("f+() { (( n << 1 )); }\nreal\n", [["f+"], ["{"], ["}"], ["real"]], []),
    ("[[ -n $a &&\n -n $b ]] && go\n", [["[[", "-n", "$a", "&&", "-n", "$b", "]]"], ["go"]], []),
    # DevBox r5: a subscript's and an array value's substitutions run.
    ("seen[$(eigenscript-full a.eigs)]=1\n", [["seen[$(eigenscript-full a.eigs)]=1"]], [],
     ["eigenscript-full a.eigs"]),
    ("arr=(<(eigenscript-full a.eigs) b)\n", [["arr=(<(eigenscript-full a.eigs) b)"]], [],
     ["eigenscript-full a.eigs"]),
    # DevBox r6: a process substitution inside an element, not only a whole one.
    ("m=([k]=<(c1 a) x<(c2 b) y)\n", [["m=([k]=<(c1 a) x<(c2 b) y)"]], [], ["c1 a", "c2 b"]),
    ('cat <<-"E"ND_X\n\tbody\n\tEND_X\nc2\n', [["cat"], ["c2"]], ["\tbody\n"]),
    # DevBox r5: `(#` in an =~ group and `@(#` in [[ ]] are pattern text.
    ("[[ $line =~ (#.*)$ ]] && bash tests/strip.sh\n",
     [["[[", "$line", "=~", "(#.*)$", "]]"], ["bash", "tests/strip.sh"]], []),
    ("[[ $x == @(#*|y) ]] && z\n", [["[[", "$x", "==", "@(#*|y)", "]]"], ["z"]], []),
    # DevBox r5 mutants: `$((` that does not close as `))` is a $( ) of a
    # subshell; `!` keeps the command position for `((`.
    ("x=$((cd tests && bash a.sh) || true)\n", [["x=$((cd tests && bash a.sh) || true)"]], [],
     ["(cd tests && bash a.sh) || true"]),
    ("if ! (( n << 1 )); then :; fi\nreal\n", [["if", "!"], ["then", ":"], ["fi"], ["real"]], []),
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
    # ---- each row below was put to bash first: the comment says what RAN.
    # NAME[ at a command position is matched to its `]` whatever follows:
    # bash ran a command named `x[1 d1 ]`, then `real`.
    ("x[1 d1 ]\nreal\n", [["x[1 d1 ]"], ["real"]], []),
    ("a[ ( ]=3 :\n", [["a[ ( ]=3", ":"]], []),
    # the LEXER matches a `<(` inside the subscript as parentheses, the
    # ASSIGNMENT test does not: bash ran `c2 ]` and a command named
    # `m[/dev/fd/63]=1`, never c1.
    ("m[<(c2 ])]=1 c1 x\n", [["m[<(c2 ])]=1", "c1", "x"]], [], ["c2 ]"]),
    # ... and where the word IS an assignment bash parses the `<( )` (a
    # syntax error inside it is one) and never runs it: bash ran c1 only.
    ("m[<(c2)]=1 c1 x\n", [["m[<(c2)]=1", "c1", "x"]], [], ["c2"]),
    # that `<( )` is a command list: a case pattern's `)` does not end it and
    # a `[` inside it is not the subscript's.  bash ran c1.
    ("x[<(case p in p) c1 x[1;; esac)]\nreal\n",
     [["x[<(case p in p) c1 x[1;; esac)]"], ["real"]], [], ["case p in p) c1 x[1;; esac"]),
    # DevBox on 61d65f6: a subscript that holds a `]`.  bash ran `real x`.
    ("m[${k[1]}]=<(c) real x\n", [["m[${k[1]}]=<(c)", "real", "x"]], [], ["c"]),
    ("m[$[ 1 ]]=<(c) real x\n", [["m[$[ 1 ]]=<(c)", "real", "x"]], [], ["c"]),
    ("m[$(a ${k[1]})]=<(c) real x\n", [["m[$(a ${k[1]})]=<(c)", "real", "x"]], [],
     ["a ${k[1]}", "c"]),
    # a here-document still pending when its $( ) closes is read from the
    # lines below (bash 5.2 warns): bash ran `cat` and `real`, never d.
    ("x=$(cat <<'E')\n$(d) `d` it's\nE\nreal\n", [["x=$(cat <<'E')"], ["real"]], [],
     ["cat <<'E'\n$(d) `d` it's\nE\n"]),
    # ... the substitution's own document first, then the line's: bash ran
    # c1 (the unquoted body) and `real`, never d.
    (": $(cat <<E) <<'F'\n$(c1)\nE\n$(d)\nF\nreal\n", [[":", "$(cat <<E)"], ["real"]],
     ["$(d)\n"], ["cat <<E\n$(c1)\nE\n"]),
    # in double quotes the word of ${x:-word} is expanded with its single
    # quotes as plain characters -- except after a pattern operator.  bash
    # ran c1 and c2, never d.
    (": \"${u:-'$(c1)'}\" ${u:-'$(d)'} \"${s%'$(d)'}\" \"${s/'$(d)'/x}\" \"${s:+'`c2`'}\"\n",
     [[":", "\"${u:-'$(c1)'}\"", "${u:-'$(d)'}", "\"${s%'$(d)'}\"", "\"${s/'$(d)'/x}\"",
       "\"${s:+'`c2`'}\""]], [], ["c1", "c2"]),
    ("cat <<E\n${u:-'$(c1)'} ${s%'$(d)'}\nE\n", [["cat"]], ["${u:-'$(c1)'} ${s%'$(d)'}\n"],
     ["c1"]),
    # `for (( ))` has no NAME: the first word of its body is a command
    # position, where `a[1<<2]=x` is an assignment.  bash ran `real`.
    ("for ((i=0;i<1;i++)); do a[1<<2]=x; real; done\n",
     [["for"], ["do", "a[1<<2]=x"], ["real"], ["done"]], []),
    ("for ((i=0;i<1;i++))\ndo\na[1<<2]=x\nreal\ndone\n",
     [["for"], ["do"], ["a[1<<2]=x"], ["real"], ["done"]], []),
    # a case pattern is not a place for a subscript: `x[*` is a pattern.
    ("case $v in\n  x[*) c1 ;;\nesac\n", [["case", "$v", "in"], ["c1"], ["esac"]], []),
    # bash takes ANY word before a lone `{` for a coproc's name.
    ("coproc a-b { c1; }\n", [["coproc", "a-b"], ["{"], ["c1"], ["}"]], []),
    # Inside a substitution a here-document also ends at a line that BEGINS
    # with its delimiter and has a `)` further on (`E)`); the rest of that
    # line is shell text.  The recorded body gets a newline there, so that it
    # reads the same on its own.  bash ran c1, c2 and c3 in the first and
    # third rows, c1 and c3 in the second.
    ("x=$(c1 <<E\nbody $(c2)\nE)\nc3\n",
     [["x=$(c1 <<E\nbody $(c2)\nE\n)"], ["c3"]], [], ["c1 <<E\nbody $(c2)\nE\n"]),
    ("x=$(c1 <<'E'\n$(d1) it's\nE ) ; c3\n",
     [["x=$(c1 <<'E'\n$(d1) it's\nE\n )"], ["c3"]], [], ["c1 <<'E'\n$(d1) it's\nE\n "]),
    ("x=$(c1 <<E\nbody\nEc2) ; c3\n",
     [["x=$(c1 <<E\nbody\nE\nc2)"], ["c3"]], [], ["c1 <<E\nbody\nE\nc2"]),
    (": <(c1 <<-E\n\tbody\n\tE) ; c3\n",
     [[":", "<(c1 <<-E\n\tbody\n\tE\n)"], ["c3"]], [], ["c1 <<-E\n\tbody\n\tE\n"]),
    # ... what follows the delimiter may be a comment that hides the `)`
    (": $(c1 <<E\nx\nE#) d1\nc2 ) ; c3\n",
     [[":", "$(c1 <<E\nx\nE\n#) d1\nc2 )"], ["c3"]], [], ["c1 <<E\nx\nE\n#) d1\nc2 "]),
    # ... not at top level, and not after a leading blank
    ("c1 <<E\nE)\nbody2\nE\nc3\n", [["c1"], ["c3"]], ["E)\nbody2\n"], []),
    ("x=$(c1 <<E\nbody\n E)\nE\n); c3\n",
     [["x=$(c1 <<E\nbody\n E)\nE\n)"], ["c3"]], [], ["c1 <<E\nbody\n E)\nE\n"]),
    # `$((` that is not arithmetic ends where its parentheses do: bash -n
    # never parses what is inside (the first row cannot run, and bash ran
    # c2 after it), and quotes count.
    (": $((c1); if) ; c2\n", [[":", "$((c1); if)"], ["c2"]], [], ["(c1); if"]),
    (": $((c1) ; c2 ; ) d3\n", [[":", "$((c1) ; c2 ; )", "d3"]], [], ["(c1) ; c2 ; "]),
    (": $((c1) ; : ')' ; c2 )\n", [[":", "$((c1) ; : ')' ; c2 )"]], [], ["(c1) ; : ')' ; c2 "]),
    # A line continuation inside double quotes is removed (bash: the value is
    # `arm_set occ_set trace_shutdown`).  The plant double-quote-escape-ignored
    # needs O3 to see this, and its only witness was a tracked file.
    ('SITES="arm_set occ_set \\\ntrace_shutdown"\nafter\n',
     [['SITES="arm_set occ_set trace_shutdown"'], ["after"]], []),
]


# (text, [(word, role), ...] over its word and pattern tokens).  Each row was
# put to bash: the 'command' words are the commands bash ran.
ROLE_INCIDENTS = [
    # #2586 critic: a word inside `coproc { ... }` is a command, never the
    # coprocess name, even before a keyword (bash ran echo/X, c3).
    ("coproc { echo case; }\nc3\n",
     [("coproc", "reserved"), ("{", "reserved"), ("echo", "command"), ("case", "argument"),
      ("}", "reserved"), ("c3", "command")]),
    ("coproc { echo [[ x; }\nc3\n",
     [("coproc", "reserved"), ("{", "reserved"), ("echo", "command"), ("[[", "argument"),
      ("x", "argument"), ("}", "reserved"), ("c3", "command")]),
    # #2586 critic: an assignment is not a name; bash runs `while` as a command.
    ("coproc x=1 while\nc3\n",
     [("coproc", "reserved"), ("x=1", "assignment"), ("while", "command"), ("c3", "command")]),
    # #2586 critic: tabs around the keyword (bash ran c1, c3).
    ("coproc QZV\twhile\t:; do c1; break; done\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("while", "reserved"), (":", "command"),
      ("do", "reserved"), ("c1", "command"), ("break", "command"), ("done", "reserved"), ("c3", "command")]),
    # #2586 critic: after an unnamed for/select/case/[[ a keyword is their
    # operand, not a compound (bash ran c1, c3 / c2).
    ("coproc for if in a; do c1; done\nc3\n",
     [("coproc", "reserved"), ("for", "reserved"), ("if", "name"), ("in", "reserved"), ("a", "list"),
      ("do", "reserved"), ("c1", "command"), ("done", "reserved"), ("c3", "command")]),
    ("coproc select if in a; do c1; break; done <<<1\nc3\n",
     [("coproc", "reserved"), ("select", "reserved"), ("if", "name"), ("in", "reserved"), ("a", "list"),
      ("do", "reserved"), ("c1", "command"), ("break", "command"), ("done", "reserved"),
      ("1", "target"), ("c3", "command")]),
    ("coproc case if in if) c1;; esac\nc3\n",
     [("coproc", "reserved"), ("case", "reserved"), ("if", "subject"), ("in", "reserved"),
      ("if", "pattern"), ("c1", "command"), ("esac", "reserved"), ("c3", "command")]),
    ("coproc [[ if ]] && c2\n",
     [("coproc", "reserved"), ("[[", "reserved"), ("if", "test"), ("]]", "reserved"), ("c2", "command")]),
    # #2586 critic r2: `#` and a quote do not end a keyword (bash ran QZV, c3).
    ("coproc QZV while#x\nc3\n",
     [("coproc", "reserved"), ("QZV", "command"), ("while#x", "argument"), ("c3", "command")]),
    ("coproc QZV if'x'\nc3\n",
     [("coproc", "reserved"), ("QZV", "command"), ("if'x'", "argument"), ("c3", "command")]),
    # #2586 critic r2: a backslash-newline before `{` keeps NAME the name
    # (bash ran c1, c3; the base tokenizer read QZV as a command).
    ("coproc QZV \\\n{ c1; }\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("{", "reserved"), ("c1", "command"),
      ("}", "reserved"), ("c3", "command")]),
    # #2586 critic r3: `time` is no reserved word after `coproc`; bash makes
    # the array `time` and reprints `coproc time while` (bash ran c1, c3 / c2, c3).
    ("coproc time while :; do c1; break; done\nc3\n",
     [("coproc", "reserved"), ("time", "name"), ("while", "reserved"), (":", "command"),
      ("do", "reserved"), ("c1", "command"), ("break", "command"), ("done", "reserved"), ("c3", "command")]),
    ("coproc time [[ -n x ]] && c2\nc3\n",
     [("coproc", "reserved"), ("time", "name"), ("[[", "reserved"), ("-n", "test"), ("x", "test"),
      ("]]", "reserved"), ("c2", "command"), ("c3", "command")]),
    # #2586 critic r3: a double quote or a backslash does not end a keyword (bash ran QZV, c3).
    ('coproc QZV if"x"\nc3\n',
     [("coproc", "reserved"), ("QZV", "command"), ('if"x"', "argument"), ("c3", "command")]),
    ("coproc QZV while\\x\nc3\n",
     [("coproc", "reserved"), ("QZV", "command"), ("while\\x", "argument"), ("c3", "command")]),
    # #2586 Codex: a process substitution glued to a keyword is one argument
    # (bash ran QZV, c1, c3); a plain redirection still ends it (bash ran c1, c3).
    ("coproc QZV while<(c1)\nc3\n",
     [("coproc", "reserved"), ("QZV", "command"), ("while<(c1)", "argument"), ("c3", "command")]),
    ("coproc QZV if>f c1; then :; fi\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("if", "reserved"), ("f", "target"), ("c1", "command"),
      ("then", "reserved"), (":", "command"), ("fi", "reserved"), ("c3", "command")]),
    # #2586: names, every reserved word and body/next-line commands are pinned.
    ("coproc QZV while :; do c1; break; done\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("while", "reserved"), (":", "command"),
      ("do", "reserved"), ("c1", "command"), ("break", "command"), ("done", "reserved"), ("c3", "command")]),
    ("coproc QZV until false; do c1; break; done\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("until", "reserved"), ("false", "command"),
      ("do", "reserved"), ("c1", "command"), ("break", "command"), ("done", "reserved"), ("c3", "command")]),
    ("coproc QZV for x in a; do c1; done\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("for", "reserved"), ("x", "name"), ("in", "reserved"),
      ("a", "list"), ("do", "reserved"), ("c1", "command"), ("done", "reserved"), ("c3", "command")]),
    ("coproc QZV select x in a; do c1; break; done <<<1\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("select", "reserved"), ("x", "name"), ("in", "reserved"),
      ("a", "list"), ("do", "reserved"), ("c1", "command"), ("break", "command"), ("done", "reserved"),
      ("1", "target"), ("c3", "command")]),
    ("coproc QZV if :; then c1; fi\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("if", "reserved"), (":", "command"),
      ("then", "reserved"), ("c1", "command"), ("fi", "reserved"), ("c3", "command")]),
    ("coproc QZV case a in a) c1;; esac\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("case", "reserved"), ("a", "subject"), ("in", "reserved"),
      ("a", "pattern"), ("c1", "command"), ("esac", "reserved"), ("c3", "command")]),
    ("coproc QZV [[ -z $(c1) ]] && c2\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("[[", "reserved"), ("-z", "test"),
      ("$(c1)", "test"), ("]]", "reserved"), ("c2", "command"), ("c3", "command")]),
    ("coproc QZV (( $(c1) + 1 ))\nc3\n",
     [("coproc", "reserved"), ("QZV", "name"), ("c3", "command")]),
    ("x=1 <f y=2 cmd a\n", [("x=1", "assignment"), ("f", "target"), ("y=2", "assignment"),
                             ("cmd", "command"), ("a", "argument")]),
    ('"A=1" cmd\n', [('"A=1"', "command"), ("cmd", "argument")]),
    ("< f if x\n", [("f", "target"), ("if", "command"), ("x", "argument")]),
    ("time -p c1 a\n", [("time", "reserved"), ("-p", "reserved"), ("c1", "command"),
                         ("a", "argument")]),
    ("coproc c1 a\n", [("coproc", "reserved"), ("c1", "command"), ("a", "argument")]),
    ("coproc CP { c1; }\n", [("coproc", "reserved"), ("CP", "name"), ("{", "reserved"),
                              ("c1", "command"), ("}", "reserved")]),
    ("for v in a b; do c1; done\n",
     [("for", "reserved"), ("v", "name"), ("in", "reserved"), ("a", "list"), ("b", "list"),
      ("do", "reserved"), ("c1", "command"), ("done", "reserved")]),
    ("for ((i=0;i<1;i++)); do c1; done\n",
     [("for", "reserved"), ("do", "reserved"), ("c1", "command"), ("done", "reserved")]),
    ("fn () { c1; }; fn a\n", [("fn", "name"), ("{", "reserved"), ("c1", "command"),
                               ("}", "reserved"), ("fn", "command"), ("a", "argument")]),
    ("function fn { c1; }\n", [("function", "reserved"), ("fn", "name"), ("{", "reserved"),
                               ("c1", "command"), ("}", "reserved")]),
    ("case $w in a|b) c1 x;; esac\n",
     [("case", "reserved"), ("$w", "subject"), ("in", "reserved"), ("a", "pattern"),
      ("b", "pattern"), ("c1", "command"), ("x", "argument"), ("esac", "reserved")]),
    ("m[<(c2 ])]=1 c1 x\n", [("m[<(c2 ])]=1", "command"), ("c1", "argument"), ("x", "argument")]),
    ("m[k]=1 v+=2 c1 w=3\n", [("m[k]=1", "assignment"), ("v+=2", "assignment"),
                              ("c1", "command"), ("w=3", "argument")]),
    ("[[ -n $x ]] && c1\n", [("[[", "reserved"), ("-n", "test"), ("$x", "test"),
                             ("]]", "reserved"), ("c1", "command")]),
    ("local v=1 w\n", [("local", "command"), ("v=1", "argument"), ("w", "argument")]),
    ("c1 <<E a\nbody\nE\n", [("c1", "command"), ("E", "delimiter"), ("a", "argument")]),
    ("if c1; then c2; elif c3; then c4; else c5; fi\n",
     [("if", "reserved"), ("c1", "command"), ("then", "reserved"), ("c2", "command"),
      ("elif", "reserved"), ("c3", "command"), ("then", "reserved"), ("c4", "command"),
      ("else", "reserved"), ("c5", "command"), ("fi", "reserved")]),
    ("! c1 | c2 a\n", [("!", "reserved"), ("c1", "command"), ("c2", "command"),
                       ("a", "argument")]),
    # A command word that is nothing but expansions and expands to no word:
    # bash ran c1.  (x, y unset; a an empty array.)
    ("$x c1 a\n", [("$x", "command"), ("c1", "command"), ("a", "argument")]),
    ("$(c2) `c3` c1 a\n", [("$(c2)", "command"), ("`c3`", "command"), ("c1", "command"),
                            ("a", "argument")]),
    ('"${a[@]}" c1\n', [('"${a[@]}"', "command"), ("c1", "command")]),
    ('"${!a[@]}" c1\n', [('"${!a[@]}"', "command"), ("c1", "command")]),
    ('"$x$@" c1\n', [('"$x$@"', "command"), ("c1", "command")]),
    # ... a quoted scalar is always a word: bash ran a command named ''
    ('"$x" c1\n', [('"$x"', "command"), ("c1", "argument")]),
    ('"${a[*]}" c1\n', [('"${a[*]}"', "command"), ("c1", "argument")]),
    ('"$@""" c1\n', [('"$@"""', "command"), ("c1", "argument")]),
    ('$x "$y" c1\n', [("$x", "command"), ('"$y"', "command"), ("c1", "argument")]),
    # ... and so is an expansion that always has a value: bash ran `0`, `0`, `1`
    ("$? c1\n", [("$?", "command"), ("c1", "argument")]),
    ("${#x} c1\n", [("${#x}", "command"), ("c1", "argument")]),
    ("$(( 1 )) c1\n", [("$(( 1 ))", "command"), ("c1", "argument")]),
    # After a word that vanished the next word is the command whatever it
    # looks like: bash ran `v=1`, `w=2` and `time`, with c1 as the argument.
    ("$x v=1 c1\n", [("$x", "command"), ("v=1", "command"), ("c1", "argument")]),
    ("v=1 $x w=2 c1\n", [("v=1", "assignment"), ("$x", "command"), ("w=2", "command"),
                         ("c1", "argument")]),
    ("$x time c1\n", [("$x", "command"), ("time", "command"), ("c1", "argument")]),
    ("${x}c1 a\n", [("${x}c1", "command"), ("a", "argument")]),
    # `$((` that is not arithmetic ends where its parentheses do, comment or
    # not (a `$( (` would read on to the next line): bash -n accepts this,
    # cannot run the first line ("bad substitution") and ran c2.
    (": $((c1) # x)\nc2\n", [(":", "command"), ("$((c1) # x)", "argument"), ("c2", "command")]),
]


# (word, emptied(word)): the word with its expansions taken as empty -- what
# bash ran for the first seven with every variable unset -- or None where
# there is no such reading.
EMPTIED_INCIDENTS = [
    ("${T:+$T }c1", "c1"), ("$(Q)c1", "c1"), ("c1${EXE}", "c1"), ('"$V"c1', "c1"), ("`:`c1", "c1"),
    ('"${V}c1"', "c1"), ('"$@"c1', "c1"), ("x${V}c1", "xc1"), ("c${a[$(d)]}1", "c1"),
    ("$'c'$V", "c"), ("$V", ""), ('"$V"', ""), ("${V}${W}", ""),
    # no expansion, or an expansion that always has a value
    ("c1", None), ("'$V'c1", None), ("a\\$Vb", None), ("$?c1", None), ("${#v}c1", None),
    ("$((1))c1", None),
    # ... `${?%0}` can be empty: bash ran c1
    ("${?%0}c1", "c1"),
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
    ("f+() { :; }\n", ["f+"]),
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
    for text, want in ROLE_INCIDENTS:
        try:
            got = [(t.text, t.role) for t in mod.tokenize(text) if t.kind in ("word", "pattern")]
        except Exception as e:
            F.append(f"H {text!r}: tokenizer raised {e}")
            continue
        if got != want:
            F.append(f"H {text!r}: roles {got!r}, want {want!r}")
    for word, want in EMPTIED_INCIDENTS:
        got = mod.emptied(word)
        if got != want:
            F.append(f"H emptied {word!r}: {got!r}, want {want!r}")
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
     '            self.dbracket = True\n            self.cmdpos = False\n            return "reserved"',
     '            self.dbracket = False\n            self.cmdpos = False\n            return "reserved"',
     {"H"}),
    ("arith-expansion-read-as-command-substitution",
     '            if self.arith_closes(j + 3):\n                return self.arith(j + 3, j, subst)',
     '            if False:\n                return self.arith(j + 3, j, subst)', {"H"}),
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
    ("extglob-at-command-position",
     "                                                 and not self.cmdpos):",
     "                                                 ):", {"H"}),
    ("subscript-bodies-dropped",
     "                close = lx.match_subscript(j, subst, lexer=True)\n"
     "                if close is None:\n                    lx.err(",
     "                close = lx.match_subscript(j, [], lexer=True)\n"
     "                if close is None:\n                    lx.err(", {"H", "O7"}),
    ("array-process-substitution-dropped",
     '            if array and c in "<>" and self.text[j + 1:j + 2] == "(":',
     '            if False and self.text[j + 1:j + 2] == "(":', {"H", "O6"}),
    ("array-process-substitution-only-at-element-start",
     '            if array and c in "<>" and self.text[j + 1:j + 2] == "(":',
     '            if array and c in "<>" and self.text[j + 1:j + 2] == "(" '
     'and self.text[j - 1] in " \\t\\n(":', {"H", "O6"}),
    ("arith-probe-not-memoized",
     "        if j in self.arith_memo:\n            return self.arith_memo[j]",
     "        if False:\n            pass", {"R"}),
    ("quoted-heredoc-delimiter-not-unquoted",
     "            self.pending.append((idx, unquote(word), strip, quoted))",
     "            self.pending.append((idx, word, strip, quoted))", {"H", "O1", "O3", "O4"}),
    # ---- the rules O7 bought (each is a shape bash was asked about)
    ("subscript-process-substitution-not-parsed",
     '            if c == "(" and gtlt and lexer:',
     '            if False:', {"H", "O6", "O7"}),
    ("assignment-test-matches-like-the-lexer",
     "            i = _Lexer(word, roles=False).match_subscript(i, [])",
     "            i = _Lexer(word, roles=False).match_subscript(i, [], lexer=True)", {"H", "O7"}),
    ("subscript-matched-only-before-equals",
     'lx.err("unterminated [ subscript", j)\n                j = close\n',
     'lx.err("unterminated [ subscript", j)\n'
     '                j = close if t[close:close + 1] in ("=", "+") else j + 1\n', {"H"}),
    ("pending-heredoc-not-read-after-its-substitution",
     "        if sub.pending:\n            # `$(cat <<E)` closing",
     "        if False:\n            # `$(cat <<E)` closing", {"H", "O7"}),
    ("heredoc-read-below-is-read-again-as-code",
     "        resume = self.lx.skips.get(self.i)",
     "        resume = None", {"H", "O7"}),
    ("every-word-is-a-command",
     '        if self.has_command:\n            return "argument"',
     '        if False:\n            return "argument"', {"H", "O7"}),
    ("function-name-is-a-command",
     '            if prev is not None and prev.kind == "word" and prev.role == "command" \\',
     '            if False and prev.kind == "word" and prev.role == "command" \\', {"H"}),
    ("arithmetic-for-keeps-waiting-for-its-name",
     "                self.for_header = 0           # `for ((...))` has no NAME: `do` comes next\n",
     "", {"H"}),
    ("time-option-is-the-command",
     '        if self.after_time and (word == "--" or (word == "-p" and self.after_time == 1)):',
     '        if False:', {"H", "O7"}),
    ("single-quotes-quote-in-a-double-quoted-expansion",
     '                if in_double and state != "quote":\n                    literal_quotes = True',
     '                if False:\n                    literal_quotes = True', {"H", "O7"}),
    ("pattern-operator-quotes-are-plain",
     '            if state == "param" and c in "%#/^," and j > start:',
     '            if False:', {"H", "O7"}),
    ("reserved-word-after-a-leading-redirection",
     "            self.redir_only = True\n        self.cmdpos = False\n",
     "            self.redir_only = True\n", {"H"}),
    ("coproc-name-must-be-an-identifier",
     '            if rest[:1] == "(" or (rest[:1] == "{" and rest[1:2] in ("", " ", "\\t", "\\n"))',
     '            if _plain_ident(word) and rest[:1] in ("{", "(")', {"H"}),
    # #2586: restore the old brace/paren-only rule; H must see every new compound.
    ("coproc-compound-name-read-as-command",
     '                    or compound:', '                    or False:', {"H"}),
    ("coproc-group-word-read-as-name",
     '            self.after_coproc = False         # #2586: `coproc { WORD while` names nothing\n',
     '', {"H"}),
    ("coproc-assignment-read-as-name",
     '                        and assignment_split(word) is None\n', '', {"H"}),
    ("coproc-time-read-as-reserved",
     '(RESERVED_OPENERS - {"time"}) | COMPOUND_CLOSERS', 'RESERVED_OPENERS | COMPOUND_CLOSERS', {"H"}),
    # ---- the rules the mutants bought (tools/_shell_exec.py --mutants)
    ("expansion-only-command-word-never-vanishes",
     "        self.vanishing = self.lx.roles and may_vanish(word)\n"
     "        self.has_command = not self.vanishing",
     "        self.vanishing = False\n        self.has_command = True", {"H", "O7"}),
    ("quoted-scalar-vanishes",
     "        if quoted and not any(_LIST_EXPANSION.match(t) for t in texts):\n            return False",
     "        if False:\n            return False", {"H", "O7"}),
    ("always-valued-expansion-vanishes",
     "        if any(_ALWAYS_VALUED.match(t) for t in texts):\n            return False\n    return True",
     "        if False:\n            return False\n    return True", {"H", "O7"}),
    ("assignment-after-a-vanished-word",
     "        if not self.vanishing and assignment_split(word) is not None:",
     "        if assignment_split(word) is not None:", {"H", "O7"}),
    ("no-empty-expansion-reading",
     "    if not found or any(_ALWAYS_VALUED.match(x) for x in found):\n        return None\n    return text",
     "    return None", {"H", "O7"}),
    ("empty-expansion-reading-of-a-valued-expansion",
     "    if not found or any(_ALWAYS_VALUED.match(x) for x in found):",
     "    if not found:", {"H", "O7"}),
    ("heredoc-never-ends-at-delimiter-and-paren",
     '                if self.closer == ")" and cmp.startswith(delim) and ")" in cmp[len(delim):]:',
     '                if False:', {"H", "O7"}),
    ("heredoc-ends-at-delimiter-and-paren-at-top-level-too",
     '                if self.closer == ")" and cmp.startswith(delim) and ")" in cmp[len(delim):]:',
     '                if cmp.startswith(delim) and ")" in cmp[len(delim):]:', {"H", "O7"}),
    ("no-line-break-after-a-delimiter-that-shares-its-line",
     "                    lx.breaks.add(self.i)\n", "", {"H", "O7"}),
    ("assignment-test-not-remembered",
     "@functools.lru_cache(maxsize=8192)\ndef assignment_split(word: str):",
     "def assignment_split(word: str):", {"R"}),
    ("vanishing-probe-asks-for-roles-again",
     "    lx = _Lexer(word, roles=False)\n    n, i, group, out = len(word), 0, None, []",
     "    lx = _Lexer(word)\n    n, i, group, out = len(word), 0, None, []", {"R"}),
    ("non-arithmetic-double-paren-parsed-as-commands",
     "            end = self.paren_group(j + 2, [], j)\n"
     "            subst.append(self.clean(j + 2, end - 1))\n"
     "            self.openers.append(j)\n            return end\n", "", {"H"}),
]

# Source mutations of the CONSUMERS: (name, module, [(old, new), ...], the
# O7 check that must catch it).  The second is the regression a review found
# in 61d65f6, re-planted: an assignment regex that stops at the first `]`.
_OLD_ASSIGN = ('(lambda m: m and (m.group(1), m.group(2)))(re.match('
               'r"^([A-Za-z_][A-Za-z0-9_]*)(?:\\[[^]]*\\])?\\+?=(.*)$", word))')
_NO_NET = ('        if t.kind == "word" and t.role == "command":\n            name = _command_name(t.text)',
           '        if False:\n            name = _command_name(t.text)')
_ONE_READING = ("        for start in sorted({0} | runs):", "        for start in (0,):")
CONSUMER_PLANTS = [
    ("deriver-without-the-command-word-net", "_derive_variants", [_NO_NET], "deriver"),
    ("deriver-assignment-regex-stops-at-the-first-bracket", "_derive_variants",
     [_NO_NET, ("        assigned = assignment_split(tok) or assignment_split(word)",
                "        assigned = " + _OLD_ASSIGN)], "deriver"),
    ("deriver-reads-quotes-its-own-way-only", "_derive_variants",
     [("    for reading in (_unquote(raw), unquote(raw)):",
       "    for reading in (_unquote(raw),):")], "deriver"),
    ("deriver-skips-a-here-document-body's-substitutions", "_derive_variants",
     [("            for body in t.subst:\n                scan_shell_tokens(",
       '            for body in (() if t.kind == "redir" else t.subst):\n'
       "                scan_shell_tokens(")], "deriver"),
    ("deriver-takes-an-expansion-only-word-for-the-command", "_derive_variants",
     [("        if expansion_only(tok):\n            # `$TIMEOUT cmd`",
       "        if False:\n            # `$TIMEOUT cmd`")], "deriver"),
    ("deriver-without-the-empty-expansion-reading", "_derive_variants",
     [('    bare = (emptied(raw) or "").strip()', '    bare = ""'),
      ("        if emptied(tok):\n            # `${TMO:+$TMO }eigenscript-full`",
       "        if False:\n            # `${TMO:+$TMO }eigenscript-full`")], "deriver"),
    ("edges-without-the-command-word-reading", "enrolment_edges", [_ONE_READING], "edges"),
    ("edges-assignment-regex-stops-at-the-first-bracket", "enrolment_edges",
     [_ONE_READING, ("        elif (word in _KEYWORDS or assignment_split(raws[0]) is not None",
                     '        elif (word in _KEYWORDS or re.match(r"^[A-Za-z_]\\w*(?:\\[[^]]*\\])?\\+?=", word)')],
     "edges"),
    ("edges-takes-an-expansion-only-word-for-the-command", "enrolment_edges",
     [('        elif emptied(raws[0]) == "":', "        elif False:")], "edges"),
    ("edges-without-the-empty-expansion-reading", "enrolment_edges",
     [("            for bare in (False, True):", "            for bare in (False,):")], "edges"),
    ("edges-wrappers-in-one-order-only", "enrolment_edges",
     [('        elif word in ("env", "timeout"):\n'
       '            wrapped, operands = wrapped or word == "env", word\n            drop()',
       '        elif word in ("env", "timeout"):\n'
       '            wrapped, operands = wrapped or word == "env", word\n            drop()\n'
       "            while words and (words[0].startswith(\"-\") or re.match(_ASSIGNMENT, words[0])):\n"
       "                drop()\n"
       "            readings.append(tuple(words))\n            return readings")], "edges"),
    ("edges-env-operands-not-skipped", "enrolment_edges",
     [('        if operands == "env" and (word.startswith("-")',
       '        if False and (word.startswith("-")')], "edges"),
    ("flags-quotes-removed-its-own-way", "portability_flags",
     [("    seg = [unquote(x) for x in raw]",
       "    seg = [x[1:-1] if len(x) >= 2 and x[0] == x[-1] and x[0] in \"'\\\"\" else x for x in raw]")],
     "flags"),
    ("flags-takes-an-expansion-only-word-for-the-command", "portability_flags",
     [('reading == "" or assignment_split', "False or assignment_split")], "flags"),
    ("flags-without-the-empty-expansion-reading", "portability_flags",
     [("        if reading:\n            seg[0] = reading", "        if False:\n            seg[0] = reading")],
     "flags"),
    ("flags-redirection-target-is-a-word", "portability_flags",
     [('                if toks[i].kind == "word" and toks[i].role not in ("target", "delimiter")]',
       '                if toks[i].kind == "word"]')], "flags"),
    ("flags-without-the-command-word-reading", "portability_flags",
     [("        if runs:\n            second", "        if False:\n            second")], "flags"),
]
O7_SEEDS, O7_N = (1, 2, 3), 500


def mutated_source(module, edits):
    """MODULE's source with every (old, new) of EDITS applied; each old text
    must occur exactly once, so a plant cannot go stale unnoticed."""
    # (the GNU-flag scanner is Python inside tools/portability_parse_check.sh)
    src = EX.flags_source() if module == "portability_flags" else (HERE / f"{module}.py").read_text()
    for old, new in edits:
        if src.count(old) != 1:
            raise SystemExit(f"INSTRUMENT ERROR: plant text occurs {src.count(old)} times "
                             f"in {module}:\n{old}")
        src = src.replace(old, new)
    return src


def stale_plants():
    """Names of the plants whose text to replace is not found exactly once:
    asked before anything is run, so that a plant gone stale is reported at
    once and with the others, not after minutes of the run."""
    tokens = (HERE / "_shell_tokens.py").read_text()
    stale = [name for name, old, _new, _expect in PLANTS if tokens.count(old) != 1]
    for name, module, edits, _check in CONSUMER_PLANTS:
        src = EX.flags_source() if module == "portability_flags" else (HERE / f"{module}.py").read_text()
        if any(src.count(old) != 1 for old, _new in edits):
            stale.append(name)
    return stale


def load_mutant(old, new):
    spec = importlib.util.spec_from_loader("_shell_tokens_mutant", loader=None)
    mod = importlib.util.module_from_spec(spec)
    exec(compile(mutated_source("_shell_tokens", [(old, new)]), "_shell_tokens_mutant", "exec"),
         mod.__dict__)
    mod.ShellLexError = ST.ShellLexError     # one exception class for the harness
    return mod


def _oracles_of(findings):
    tags = set()
    for f in findings:
        m = re.search(r"\b(O[1-7]|CRASH)\b", f)
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
    # DevBox r4: `for NAME do`, `(v=1) then`, `f+()`, and the other
    # separator-less reserved-word positions bash accepts.
    "for x do\n{C}\ndone\n", "if (v=1) then\n{C}\nfi\n", "f+() {\n{C}\n}\n",
    "for ((i=0;i<1;i++)) {\n{C}\n}\n", "for i in a; {\n{C}\n}\n",
    "for ((i=0;i<1;i++))\ndo\n{C}\ndone\n", "while (( 0 )) do\n{C}\ndone\n",
    "while [[ '' ]] do\n{C}\ndone\n", "if { :; } then\n{C}\nfi\n",
    "if ( : ) then :; else\n{C}\nfi\n", "function f() {\n{C}\n}\n",
    "function f (\n{C}\n)\n", "select i in a; do\n{C}\ndone\n", "coproc {\n{C}\n}\n",
    "x=\"$(\n{C}\n)\"\n", "cat <(\n{C}\n)\n", "x=`\n{C}\n`\n",
    "echo ${v:-$(\n{C}\n)}\n", "echo $(( $(\n{C}\n) + 1 ))\n",
    "cat <<E1\n$( : )\nE1\n{C}\n", "{\n{C}\n} >/dev/null 2>&1 <<E2\nit's\nE2\n",
    "time -p {\n{C}\n}\n", "! (\n{C}\n)\n",
]
O5_CONSTRUCTS = [
    "(( n = n << 1 ))", "[[ a < b && c ]]", "!(true)", "a[1<<3]=x", "echo $[1<<3]",
    "tmp=x.$$'\\'", "cat <<EOF\nbody $(x)\nEOF", "cat <<-'E'\n\tbody\n\tE",
    "tr a b <<< c", "echo \"a\n#b\" # c", "case y in z) : ;; esac", "x=$(( 1 << 2 ))",
    "echo `echo a`", "arr=(a 'b c')", "for ((j=0;j<1;j++)); do :; done",
    "echo ${x:-'}'}", "coproc QP { cat; }", "time -p (( 1 << 2 ))", "echo a \\\n b",
    "if (( 1 )) then (( n << 1 )); fi", "function h { (( n << 1 )); }",
    "for y do (( n << 1 )); done", "if (w=1) then (( n << 1 )); fi",
    "g+() { (( n << 1 )); }", "echo \"it's\"", "cat <<E\nit's\nE",
    "x=$(cat <<'E'\nit's )\nE\n)", "time -p [[ a < b ]]", "v=1 :",
    "arr=( a # it's\n 'b' )", "echo <( : )a", "[[ $a =~ ^(a|b)#c$ ]]",
    "echo $'it\\'s'", "echo $$'a'", "[[ -n $a &&\n -n $b ]]",
    "trap 'echo \"it'\\''s\"' EXIT", "case $a in (x|y) :;; *) :;; esac",
    "seen[$(echo k)]=1", "arr=(<(echo a) b)", "[[ $(echo a) == a ]]",
    "m=([k]=<(echo a) x<(echo b) y)",
    "case $(echo a) in $(echo a)) :;; esac", "echo \"${x:-$(echo d)}\" >$(echo f)",
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
    (a crash would take a whole gate down instead of reading a prefix), and
    nesting must not make it exponential."""
    import random
    import time
    rng = random.Random(20261125)
    bad = []
    # Work that doubles with each level of nesting does not finish: the
    # clock is an alarm, so the check fails instead of hanging.
    def too_slow(*_):
        raise TimeoutError

    for deep in ("x=" + "$(( $(" * 18 + "echo 1" + ") ))" * 18,
                 "$(" * 24 + ":" + ")" * 24 + " x",
                 "a[" + "$(a[" * 16 + "0" + "]=1)" * 16 + "]=1 x"):
        old = signal.signal(signal.SIGALRM, too_slow)
        signal.setitimer(signal.ITIMER_REAL, 3.0)
        t0 = time.monotonic()
        try:
            mod.tokenize(deep)
            took = time.monotonic() - t0
        except TimeoutError:
            took = None
        except ST.ShellLexError:
            took = time.monotonic() - t0
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, old)
        if took is None or took > 1.0:
            bad.append((deep[:40] + "...", "deep nesting " + (
                "did not finish in 3s" if took is None else f"took {took:.1f}s")))
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


def coproc_execution():
    """#2586: execute the fifth-field H rows, including select with real input.

    Unlike O7's generator these cover each named compound and its near misses.
    Expected sets were collected from bash before the tokenizer rule changed.
    """
    findings, rows, names = [], 0, 0
    with tempfile.TemporaryDirectory(prefix="shell-coproc-") as work:
        Path(work, "bin").mkdir()
        for row in INCIDENTS:
            if len(row) < 5:
                continue
            text, want = row[0], row[4]
            got = EX.execute(text, work)
            rows += 1
            names += len(got or ())
            if got != want:
                findings.append(f"O7 coproc {text!r}: bash ran {got!r}, want {want!r}")
    print(f"coproc execution: rows={rows} names_run={names}")
    return findings


def selftest():
    sys.stdout.reconfigure(line_buffering=True)   # a timed-out run still shows its progress
    if not BASH or not DASH:
        print("INSTRUMENT ERROR: shell_oracle needs bash and dash "
              f"(bash={BASH}, dash={DASH})")
        return 2
    stale = stale_plants()
    if stale:
        print("INSTRUMENT ERROR: the text of these plants is not found exactly once in the "
              "source they mutate: " + ", ".join(stale))
        return 2
    tree = load_items(tracked_shell_files())
    items = tree + incident_items() + composed_items()
    rc = 0
    print(f"PLAN: {7 + len(PLANTS) + len(CONSUMER_PLANTS)}")

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

    # O7: bash runs the generated programs once; every later judgement (the
    # A/A, the plants) is against these executions or a fresh one.
    ran = {}
    derived, edges, flags = EX.deriver_reader(), EX.edges_reader(), EX.flags_reader()
    o7, o7_counts = EX.run(O7_SEEDS, O7_N, derived=derived, edges=edges, flags=flags, cache=ran)
    o7 += coproc_execution()
    print(f"execution: bash={EX.bash_version()} "
          + " ".join(f"{k}={v}" for k, v in sorted(o7_counts.items())))
    if o7:
        rc = 1
        print(f"  FAIL: execution: {len(o7)} finding(s)")
        for f in o7[:20]:
            print("    " + f)
    else:
        print(f"  PASS: execution: bash ran {o7_counts['names_run']} names in "
              f"{o7_counts['executed']} generated programs; the tokenizer's command words are "
              "exactly those names, and the deriver, the enrolment reader and the GNU-flag "
              "scanner report every one")
    ran_again = {}
    EX.run(O7_SEEDS, O7_N, role=False, cache=ran_again)
    if ran_again == ran:
        print("  PASS: execution A/A: a second run of the same programs ran the same names")
    else:
        rc = 1
        differ = sorted(k for k in ran if ran_again.get(k) != ran[k])
        print(f"  FAIL: execution A/A: {len(differ)} program(s) ran different names: {differ[:5]}")

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
    # The incidents and every construct composed into every 8th wrapper (each
    # construct, in several contexts): the plants are judged on these, and on
    # nothing that depends on which files the tree holds.  They used to be
    # judged on every 8th tracked file too.  The plant double-quote-escape-
    # ignored had its only O3 witness there (tests/test_arming_mt.sh); main
    # gained one shell file, the sample shifted, and this self-test went red
    # in CI on a merge that touched neither (PR #2559 at 9dbfcf5).
    fixed = incident_items() + [
        it for it in composed_items() if int(it[0].split("#")[1].split(".")[0]) % 8 == 0]
    # the locale A/A reads every 8th tracked file as well, to bound the selftest
    subset = tree[::8] + fixed
    sub_base, _ = run_corpus(subset)
    other, _ = run_corpus(subset, locale="C.UTF-8")
    if other == sub_base:
        print("  PASS: A/A under LC_ALL=C.UTF-8 identical")
    else:
        rc = 1
        print("  FAIL: locale changes the findings")

    for name, old, new, expect in PLANTS:
        mod = load_mutant(old, new)
        found = check_incidents(mod)
        found += [f"R {t!r}: {e}" for t, e in robustness(mod)]
        found += EX.run(O7_SEEDS, O7_N, mod=mod, cache=ran)[0]
        if not expect <= _oracles_of(found):
            # the quick oracles did not show every one named: ask the corpus
            # and the composed programs too (each asks bash thousands of times)
            found += run_corpus(fixed, mod=mod)[0]
            found += composed_findings(mod)[0]
        tags = _oracles_of(found)
        if found and expect <= tags:
            print(f"  PASS: plant {name} caught by {','.join(sorted(tags))} "
                  f"({len(found)} findings)")
        else:
            rc = 1
            print(f"  FAIL: plant {name} caught by {sorted(tags) or 'nothing'}; "
                  f"expected at least {sorted(expect)}")
    for name, module, edits, check in CONSUMER_PLANTS:
        source = mutated_source(module, edits)
        readers = {"deriver": lambda: {"derived": EX.deriver_reader(source)},
                   "edges": lambda: {"edges": EX.edges_reader(source)},
                   "flags": lambda: {"flags": EX.flags_reader(source)}}[check]()
        found = [f for f in EX.run(O7_SEEDS, O7_N, role=False, cache=ran, **readers)[0]
                 if f" O7 {check}: " in f]
        if found:
            print(f"  PASS: consumer plant {name} caught by O7 ({len(found)} findings)")
        else:
            rc = 1
            print(f"  FAIL: consumer plant {name}: O7 found nothing")
    print(f"shell-oracle selftest: {'OK' if rc == 0 else 'FAILED'}")
    return rc


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if not BASH:
        print("INSTRUMENT ERROR: bash not found")
        return 2
    if "--execution" in argv:
        # O7 alone, over more programs: --execution SEED[,SEED...] N
        rest = argv[argv.index("--execution") + 1:]
        seeds = [int(x) for x in rest[0].split(",")] if rest else list(O7_SEEDS)
        n = int(rest[1]) if len(rest) > 1 else O7_N
        findings, counts = EX.run(seeds, n, derived=EX.deriver_reader(), edges=EX.edges_reader(),
                                  flags=EX.flags_reader())
        for f in findings:
            print(f)
        print(f"shell-oracle execution: bash={EX.bash_version()} "
              + " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
              + f" findings={len(findings)}")
        return 1 if findings else 0
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
