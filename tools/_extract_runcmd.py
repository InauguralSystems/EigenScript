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


def _fold_block(text):
    """YAML folded scalar: adjacent non-empty lines become one line, joined
    by a space; one blank line is a paragraph break (a single newline);
    extra blank lines become extra newlines."""
    raw_lines = text.split("\n")
    out = []
    buf = []

    def flush():
        if buf:
            out.append(" ".join(buf))
            buf.clear()

    i = 0
    while i < len(raw_lines):
        line = raw_lines[i]
        if line.strip() == "":
            flush()
            nblank = 1
            while i + 1 < len(raw_lines) and raw_lines[i + 1].strip() == "":
                nblank += 1
                i += 1
            extra = nblank - 1
            if extra > 0 and out:
                for _ in range(extra):
                    out.append("")
        else:
            buf.append(line)
        i += 1
    flush()
    return "\n".join(out)


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

    text = "\n".join(body)
    if not text.strip():
        return None
    if style == ">":
        text = _fold_block(text)
    if chomp == "-":
        text = text.rstrip("\n")
    elif chomp == "+":
        pass
    else:
        # clip: at most one trailing newline; command form drops it.
        text = text.rstrip("\n")
    return text


def extract_inline(src):
    m = INLINE_RE.search(src)
    if not m:
        return None
    text = m.group(1).strip()
    return text or None


def extract(src):
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
    explicit relative indent, chomping `|-`/`|+`. examined == len(cases) > 0.
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
    ]
    examined = 0
    failed = 0
    yaml_checked = 0
    yaml_skip = 0
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
        elif st == "ok":
            yaml_checked += 1
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
            "SELFTEST: PASS examined=%d yaml-oracle=%d\n" % (examined, yaml_checked)
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
