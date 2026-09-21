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
(optional explicit indent digit); the first non-empty content line sets the
indent; a less-indented non-blank line ends the block. Folded (`>`) scalars
join adjacent non-empty lines with a space.

Exits 0 and prints the command, or exits 1 if this file has no runCmd.

    tools/_extract_runcmd.py FILE
    tools/_extract_runcmd.py --selftest
"""
import re
import sys

HEADER_RE = re.compile(
    r"^[ \t]*runCmd:[ \t]*([|>])([+-]?)([1-9][0-9]*)?[ \t]*\n",
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
    by a space; a blank line becomes a real newline."""
    raw_lines = text.split("\n")
    out = []
    buf = []

    def flush():
        if buf:
            out.append(" ".join(buf))
            buf.clear()

    for line in raw_lines:
        if line.strip() == "":
            flush()
            if out and out[-1] != "":
                out.append("")
        else:
            buf.append(line)
    flush()
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out)


def extract_block(src):
    m = HEADER_RE.search(src)
    if not m:
        return None
    style = m.group(1)  # | or >
    chomp = m.group(2) or ""
    explicit = m.group(3)
    rest = src[m.end():]
    lines = rest.split("\n")
    # Keep the last empty split so a file ending in newline is uniform;
    # a final line without newline is still a content line.
    if rest.endswith("\n"):
        lines = rest.split("\n")
    else:
        lines = rest.split("\n")

    indent = int(explicit) if explicit else None
    body = []
    for line in lines:
        if indent is None:
            if line.strip() == "":
                # Leading empty lines before the first content line do not
                # set indent and are not part of the body.
                continue
            indent = _leading_spaces(line)
            if indent == 0:
                break
        if line.strip() == "":
            body.append("")
            continue
        n = _leading_spaces(line)
        if n < indent:
            break
        body.append(line[indent:])

    # Clip (default): strip final newlines to a single trailing newline
    # then we strip for the command. Strip (`-`): strip all. Keep (`+`):
    # keep. For a shell command we always strip surrounding whitespace;
    # chomping only affects interior trailing blanks, which no consumer
    # command relies on.
    while body and body[-1] == "":
        body.pop()
    text = "\n".join(body)
    if not text.strip():
        return None
    if style == ">":
        text = _fold_block(text)
    if chomp == "-":
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


def selftest():
    """Plants: the over-consume input (literal `|`) and a folded `>` scalar.
    examined == 2 > 0."""
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
    ]
    examined = 0
    failed = 0
    for name, src, want in cases:
        examined += 1
        got = extract(src)
        if got != want:
            sys.stderr.write(
                "FAIL %s: got %r want %r\n" % (name, got, want)
            )
            failed += 1
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
