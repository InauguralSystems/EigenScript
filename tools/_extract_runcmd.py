#!/usr/bin/env python3
"""Extract a devcontainer CI job's runCmd — the consumer's OWN acceptance command.

Used by tools/consumer_acceptance.sh (milestone M1). Two forms exist in this
ecosystem's workflows, and matching only the first reported NINE live consumers
as having no acceptance command at all (2026-09-19):

    runCmd: |              block form; the body is preserved VERBATIM, because
      cmd one              joining lines with && mangles for/while/if bodies
      cmd two              into shell that cannot run

    runCmd: cmd one && cmd two          inline form, one line

Exits 0 and prints the command, or exits 1 if this file has no runCmd.
"""
import re
import sys

src = open(sys.argv[1]).read()

block = re.search(r'^[ \t]*runCmd:[ \t]*[|>][-+]?[ \t]*\n((?:[ \t]+.*\n|[ \t]*\n)+)', src, re.M)
if block:
    body = block.group(1).rstrip("\n").split("\n")
    indents = [len(l) - len(l.lstrip()) for l in body if l.strip()]
    cut = min(indents) if indents else 0
    text = "\n".join(l[cut:] if len(l) >= cut else l for l in body).strip("\n")
    if text.strip():
        print(text)
        sys.exit(0)

inline = re.search(r'^[ \t]*runCmd:[ \t]*(?![|>]\s*$)(\S.*?)[ \t]*$', src, re.M)
if inline and inline.group(1).strip():
    print(inline.group(1).strip())
    sys.exit(0)

sys.exit(1)
