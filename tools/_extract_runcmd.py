#!/usr/bin/env python3
"""Extract a devcontainer CI job's runCmd — the consumer's OWN acceptance command.

Used by tools/consumer_acceptance.sh (milestone M1). Two forms exist in this
ecosystem's workflows, and matching only the first reported NINE live consumers
as having no acceptance command at all (2026-09-19):

    runCmd: |              block form; the body is preserved VERBATIM, because
      cmd one              joining lines with && mangles for/while/if bodies
      cmd two              into shell that cannot run

    runCmd: cmd one && cmd two          inline form, one line

Block scalars follow YAML 1.2: a `|`, `|-`, `|+`, `>` / `>-` / `>+` header
(optional explicit indent digit, RELATIVE to the parent key); leading blank
lines before the first content line are content (they do not set indent); a
less-indented non-blank line ends the block. Folded (`>`) scalars join
adjacent non-empty lines with a space; a blank line is a paragraph break
(one newline, not two). Chomping: clip (default) one trailing newline,
strip (`-`) none, keep (`+`) all. The command result rstrips trailing
newlines except under `+`, so a typical `runCmd: |\\n  make test\\n` is
`make test` while a leading blank stays as a leading newline.

Exits 0 and prints the command, or exits 1 if this file has no runCmd.

    tools/_extract_runcmd.py FILE
    tools/_extract_runcmd.py --selftest
"""
import re
import sys

# CRLF: the source is normalised to LF in extract() before either regex
# runs, so a \r never reaches the indicator or the body (Fable r2 05: a
# CRLF workflow yielded None because this pattern required \n).
HEADER_RE = re.compile(
    r"^([ \t]*)runCmd:[ \t]*([|>])([+-]?)([1-9][0-9]*)?[ \t]*\n",
    re.M,
)
INLINE_RE = re.compile(
    r"^[ \t]*runCmd:[ \t]*(?![|>])(\S.*?)[ \t]*$",
    re.M,
)


def _leading_spaces(line):
    n = 0
    for ch in line:
        if ch == " ":
            n += 1
        elif ch == "\t":
            # YAML forbids tabs in indentation of block scalars; treat as
            # one column so a tab-indented body still extracts rather than
            # hanging. Real workflows in this ecosystem indent with spaces.
            n += 1
        else:
            break
    return n


def _fold_block_lines(body):
    """YAML folded scalar, line list in / line list out.

    Adjacent non-empty lines become one line joined by a space; one blank
    line is a paragraph break (a single newline); extra blank lines become
    extra newlines. A MORE-INDENTED line (body lines have the block indent
    already stripped, so any remaining leading space is more-indented) is
    NOT folded: YAML keeps the breaks on both sides of it. Fable r2 05
    measured the old code turning `a` / `  b` / `c` into `a   b c` where
    YAML gives `a\n  b\nc\n`; Astra's instance of the same shape folded
    three commands into one and a failing `false` stopped being a command
    at all, so the row read PASS.
    """
    out = []
    buf = []

    def flush():
        if buf:
            out.append(" ".join(buf))
            del buf[:]

    i = 0
    while i < len(body):
        line = body[i]
        if line.strip() == "":
            flush()
            nblank = 1
            while i + 1 < len(body) and body[i + 1].strip() == "":
                nblank += 1
                i += 1
            # Mid-scalar the first break of the run replaces the fold
            # space, so a run of n blanks is n-1 extra newlines. At the
            # END of the scalar there is no line to fold into, so all n
            # are kept -- that is the newline `>+` chomping keeps and the
            # old code dropped.
            trailing = all(b.strip() == "" for b in body[i + 1:])
            extra = nblank if trailing else nblank - 1
            if extra > 0 and out:
                for _ in range(extra):
                    out.append("")
        elif line[:1] in (" ", "\t"):
            # CA-GUARD:folded-more-indented
            flush()
            out.append(line)
        else:
            buf.append(line)
        i += 1
    flush()
    return out


def extract_block(src):
    m = HEADER_RE.search(src)
    if not m:
        return None
    key_indent = _leading_spaces(m.group(1))
    style = m.group(2)  # | or >
    chomp = m.group(3) or ""
    explicit = m.group(4)
    rest = src[m.end():]
    lines = rest.split("\n")
    # split() on a body that ends in a newline yields one trailing ""
    # that is an artefact of the separator, not an empty content line.
    # Dropping it is what makes `+` (keep) chomping count the same
    # trailing newlines YAML does (Fable r2 05: `|+` followed by another
    # key kept one fewer newline than yaml.safe_load).
    if rest.endswith("\n") and lines and lines[-1] == "":
        lines.pop()

    indent = (key_indent + int(explicit)) if explicit else None
    body = []
    for line in lines:
        if indent is None:
            if line.strip() == "":
                # Leading empty lines do not set indent and ARE content.
                body.append("")
                continue
            indent = _leading_spaces(line)
            if indent == 0 or indent <= key_indent:
                break
        if line.strip() == "":
            body.append("")
            continue
        n = _leading_spaces(line)
        if n < indent:
            break
        body.append(line[indent:])

    if not "\n".join(body).strip():
        return None
    if style == ">":
        body = _fold_block_lines(body)
    # Every content line of a block scalar carries its own line break.
    text = "".join(line + "\n" for line in body)
    if chomp == "-":
        text = text.rstrip("\n")
    elif chomp == "+":
        pass
    else:
        # clip: at most one trailing newline; command form drops it.
        text = text.rstrip("\n")
    return text


# CA-GUARD:inline-quoted-scalar
# ROUND 8, finding 7 (measured by /code-review on 21daf05): `runCmd: 'make
# test'` extracted the QUOTES with the text, so the harness ran
# `bash -e -o pipefail -c "'make test'"`, whose command NAME is the
# five-word string `'make test'` -- rc 127, a row that FAILs for a reason
# that has nothing to do with the candidate. A YAML inline scalar may be
# single- or double-quoted; the quotes are syntax, not command text.
def _unquote_scalar(text):
    if len(text) < 2 or text[0] != text[-1] or text[0] not in "'\"":
        return text
    q = text[0]
    inner = text[1:-1]
    if q == "'":
        return inner.replace("''", "'")
    out = []
    i = 0
    n = len(inner)
    while i < n:
        if inner[i] == "\\" and i + 1 < n:
            out.append(inner[i + 1])
            i += 2
            continue
        out.append(inner[i])
        i += 1
    return "".join(out)
# CA-GUARD:end-inline-quoted-scalar


def extract_inline(src):
    m = INLINE_RE.search(src)
    if not m:
        return None
    text = _unquote_scalar(m.group(1).strip())
    return text or None


def extract(src):
    # CA-GUARD:crlf-normalise
    src = src.replace("\r\n", "\n")
    block = extract_block(src)
    if block is not None:
        return block
    return extract_inline(src)


def _find_runcmd(obj):
    if isinstance(obj, dict):
        if "runCmd" in obj:
            return obj["runCmd"]
        for v in obj.values():
            r = _find_runcmd(v)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = _find_runcmd(v)
            if r is not None:
                return r
    return None


def _yaml_oracle(src):
    """Return (status, value). status is 'ok', 'skip', or 'invalid'."""
    try:
        import yaml
    except ImportError:
        return ("skip", None)
    try:
        data = yaml.safe_load(src)
    except Exception:
        return ("invalid", None)
    val = _find_runcmd(data)
    if val is None:
        return ("invalid", None)
    if not isinstance(val, str):
        val = str(val)
    return ("ok", val)


def selftest():
    """Plants: over-consume `|`, folded `>`, leading blank, folded paragraph,
    explicit relative indent, chomping `|-`/`|+`, keep-then-key, a
    more-indented line inside a folded scalar (twice: as text and as three
    commands), CRLF. examined == len(cases) > 0.
    When PyYAML is importable, valid documents are cross-checked against
    yaml.safe_load (trailing clip newline rstripped to match command form)."""
    cases = [
        (
            "literal-stop-at-less-indent",
            "runCmd: |\n  make test\n push: never\n- name: upload\n  run: echo hi\n",
            "make test",
        ),
        (
            "folded-join",
            "runCmd: >\n  make test\n  extra\n",
            "make test extra",
        ),
        (
            "leading-blank",
            "runCmd: |\n\n  make test\n",
            "\nmake test",
        ),
        (
            "folded-paragraph",
            "runCmd: >\n  echo one\n\n  echo two\n",
            "echo one\necho two",
        ),
        (
            "explicit-relative-indent",
            "- name: test\n  with:\n    runCmd: |2\n      echo hi\n    push: never\n",
            "echo hi",
        ),
        (
            "chomp-strip",
            "runCmd: |-\n  make test\n",
            "make test",
        ),
        (
            "chomp-keep",
            "runCmd: |+\n  make test\n\n",
            "make test\n\n",
        ),
        # Fable r2 evidence/05, shape (a): a keep block followed by another
        # key kept one fewer trailing newline than yaml.safe_load.
        (
            "chomp-keep-then-key",
            "runCmd: |+\n  make test\n\npush: never\n",
            "make test\n\n",
        ),
        (
            "chomp-keep-folded-then-key",
            "runCmd: >+\n  a\n  b\n\npush: never\n",
            "a b\n\n",
        ),
        # shape (b): a MORE-INDENTED line in a folded scalar is literal --
        # YAML keeps the breaks on both sides of it.
        (
            "folded-more-indented",
            "runCmd: >\n  a\n    b\n  c\n",
            "a\n  b\nc",
        ),
        # Astra r2 evidence/05: the same shape as THREE COMMANDS. Folding
        # them into one line made a failing `false` stop being a command,
        # and the harness row read PASS.
        (
            "folded-more-indented-commands",
            "runCmd: >\n  eigenscript work.eigs\n    false\n  echo accepted\n",
            "eigenscript work.eigs\n  false\necho accepted",
        ),
        # shape (c): CRLF. HEADER_RE needs \n right after the indicator, so
        # a CRLF workflow used to yield None (no acceptance command at all).
        (
            "crlf-block",
            "runCmd: |\r\n  make test\r\n  make more\r\n",
            "make test\nmake more",
        ),
        # ROUND 8, finding 7 (measured): the quotes of an inline scalar were
        # extracted with the text, so `bash -c "'make test'"` ran a command
        # NAME of `'make test'` and the row read 127.
        (
            "inline-single-quoted",
            "runCmd: 'make test'\n",
            "make test",
        ),
        (
            "inline-double-quoted",
            'runCmd: "make test && echo ok"\n',
            "make test && echo ok",
        ),
        (
            "inline-bare",
            "runCmd: make test\n",
            "make test",
        ),
    ]
    # CA-GUARD:yaml-valid-set
    # DECLARED, not derived: the rows that are a complete YAML document by
    # construction. Every one of them must reach the oracle, or the
    # cross-check examined less than it claims.
    yaml_valid = set(
        name for name, _, _ in cases
    ) - {"literal-stop-at-less-indent"}
    # CA-GUARD:end-yaml-valid-set
    examined = 0
    failed = 0
    yaml_checked = 0
    yaml_skip = 0
    yaml_invalid = 0
    yaml_ok_names = set()
    for name, src, want in cases:
        examined += 1
        got = extract(src)
        if got != want:
            sys.stderr.write(
                "FAIL %s: got %r want %r\n" % (name, got, want)
            )
            failed += 1
        st, oracle = _yaml_oracle(src)
        if st == "skip":
            yaml_skip += 1
        elif st == "invalid":
            yaml_invalid += 1
        elif st == "ok":
            yaml_checked += 1
            yaml_ok_names.add(name)
            oracle_cmd = oracle.rstrip("\n") if not name.startswith("chomp-keep") else oracle
            # keep (`|+`) is compared as the oracle emitted it; clip/strip
            # command form rstrips trailing newlines.
            if name == "chomp-keep":
                if oracle != want:
                    sys.stderr.write(
                        "FAIL %s yaml-oracle: got %r want %r\n" % (name, oracle, want)
                    )
                    failed += 1
            else:
                if oracle_cmd != want:
                    sys.stderr.write(
                        "FAIL %s yaml-oracle: got %r want %r\n"
                        % (name, oracle_cmd, want)
                    )
                    failed += 1
        # invalid: over-consume fixtures are not a complete YAML document
    # CA-GUARD:yaml-floor
    # The oracle's own witness. yaml_checked had no floor, so a change that
    # made every fixture unparseable (or moved runCmd where _find_runcmd
    # cannot see it) left examined=12 yaml_checked=0 and still printed PASS.
    if yaml_skip == 0:
        if yaml_ok_names != yaml_valid:
            sys.stderr.write(
                "FAIL yaml-oracle floor: checked %r declared-valid %r\n"
                % (sorted(yaml_ok_names), sorted(yaml_valid))
            )
            failed += 1
        if yaml_checked < len(yaml_valid) or len(yaml_valid) == 0:
            sys.stderr.write(
                "FAIL yaml-oracle floor: yaml_checked=%d < declared-valid=%d\n"
                % (yaml_checked, len(yaml_valid))
            )
            failed += 1
    elif yaml_skip != len(cases):
        sys.stderr.write(
            "FAIL yaml-oracle: PyYAML skipped %d of %d rows (all or nothing)\n"
            % (yaml_skip, len(cases))
        )
        failed += 1
    if yaml_checked + yaml_skip + yaml_invalid != examined:
        sys.stderr.write(
            "FAIL yaml-oracle accounting: ok=%d skip=%d invalid=%d != examined=%d\n"
            % (yaml_checked, yaml_skip, yaml_invalid, examined)
        )
        failed += 1
    # CA-GUARD:end-yaml-floor
    if examined != len(cases) or examined == 0:
        sys.stderr.write(
            "FAIL examined=%d len(cases)=%d (want examined == len(table) > 0)\n"
            % (examined, len(cases))
        )
        return 1
    if failed:
        sys.stderr.write("SELFTEST: FAIL %d/%d\n" % (failed, examined))
        return 1
    if yaml_skip == len(cases):
        sys.stdout.write(
            "SELFTEST: PASS examined=%d yaml-oracle: SKIP (no PyYAML)\n" % examined
        )
    else:
        sys.stdout.write(
            "SELFTEST: PASS examined=%d yaml-oracle=%d/%d invalid=%d\n"
            % (examined, yaml_checked, len(yaml_valid), yaml_invalid)
        )
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) != 2:
        sys.stderr.write("usage: %s FILE | --selftest\n" % argv[0])
        return 2
    src = open(argv[1]).read()
    text = extract(src)
    if text is None:
        return 1
    sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
