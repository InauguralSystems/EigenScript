#!/usr/bin/env python3
"""Keep handle_table_drain's declaration comment aligned with its passes."""

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "src/eigenscript.h").read_text(encoding="utf-8")
BUILTINS = (ROOT / "src/builtins.c").read_text(encoding="utf-8")


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    raise SystemExit(1)


declaration = re.search(
    r"(/\*[^*]*(?:\*(?!/)[^*]*)*\*/)[ \t]*\nvoid[ \t]+handle_table_drain\(",
    HEADER,
)
if declaration is None:
    fail("could not find the comment immediately before handle_table_drain")

definition = re.search(r"void handle_table_drain\(EigsState \*st\) \{", BUILTINS)
if definition is None:
    fail("could not find handle_table_drain's definition")

start = definition.start()
depth = 0
end = None
for offset, char in enumerate(BUILTINS[definition.end() - 1 :], definition.end() - 1):
    if char == "{":
        depth += 1
    elif char == "}":
        depth -= 1
        if depth == 0:
            end = offset + 1
            break
if end is None:
    fail("could not find the end of handle_table_drain's definition")

handle_pattern = r"\bHANDLE_(?:STORE|THREAD|CHANNEL|TASK|NET)\b"
comment_types = set(re.findall(handle_pattern, declaration.group(1)))
body_types = set(re.findall(handle_pattern, BUILTINS[start:end]))
if comment_types != body_types:
    missing = sorted(body_types - comment_types)
    extra = sorted(comment_types - body_types)
    details = []
    if missing:
        details.append("missing " + ", ".join(missing))
    if extra:
        details.append("not drained " + ", ".join(extra))
    fail("handle_table_drain declaration comment is stale (" + "; ".join(details) + ")")

print("PASS: handle_table_drain declaration comment names every drained handle type")
