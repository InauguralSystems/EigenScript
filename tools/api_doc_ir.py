#!/usr/bin/env python3
"""Extract the strict, source-local API documentation IR for issue #1269.

This first migration step defines and validates the shared record format.  A
record is a contiguous comment block immediately preceding the declaration:

    # @api
    # signature: clamp of value, low, high -> number
    # summary: Clamp a number to an inclusive range.
    # arg value: The number to clamp.
    # arg low: The lower bound.
    # arg high: The upper bound.
    # returns: The clamped number.
    # example:
    # | print of clamp of [8, 0, 5]
    # | # => 5
    # @end
    define clamp(value, low, high) as:

C records use ``/* @api`` / `` * field`` / `` */`` and must immediately
precede an ``env_set_local_owned`` registration.  The extractor deliberately
does not infer or fall back: incomplete documentation is an error.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


class DocError(Exception):
    pass


@dataclass(frozen=True)
class Record:
    kind: str
    name: str
    source: str
    line: int
    signature: str
    summary: str
    args: list[dict[str, str]]
    returns: str
    example: str


FIELDS = {"signature", "summary", "arg", "returns", "example"}
DEFINE = re.compile(r"^define\s+([A-Za-z_][A-Za-z0-9_]*)")
REGISTER = re.compile(r'env_set_local_owned\([^,]+,\s*"([A-Za-z0-9_]+)"')


def fail(path: Path, line: int, name: str, message: str) -> DocError:
    return DocError(f"{path}:{line}: {name}: {message}")


def parse_fields(path: Path, line: int, name: str, rows: list[str]) -> dict:
    values: dict[str, object] = {"args": []}
    example: list[str] = []
    in_example = False
    for offset, raw in enumerate(rows):
        text = raw.strip()
        if in_example and text.startswith("|"):
            example.append(text[1:].lstrip())
            continue
        in_example = False
        match = re.match(r"([a-z]+)(?:\s+([A-Za-z_][A-Za-z0-9_]*))?:\s*(.*)$", text)
        if not match:
            raise fail(path, line + offset, name, f"malformed field {text!r}")
        field, arg_name, value = match.groups()
        if field not in FIELDS:
            raise fail(path, line + offset, name, f"unknown field {field!r}")
        if field == "arg":
            if not arg_name or not value:
                raise fail(path, line + offset, name, "arg requires a name and description")
            if any(item["name"] == arg_name for item in values["args"]):
                raise fail(path, line + offset, name, f"duplicate arg {arg_name!r}")
            values["args"].append({"name": arg_name, "description": value})
        else:
            if field in values:
                raise fail(path, line + offset, name, f"duplicate field {field!r}")
            if field == "example":
                if value:
                    example.append(value)
                in_example = True
            else:
                values[field] = value
    if example:
        values["example"] = "\n".join(example)
    missing = [key for key in ("signature", "summary", "returns", "example") if not values.get(key)]
    if missing:
        raise fail(path, line, name, "missing field(s): " + ", ".join(missing))
    return values


def extract(path: Path) -> list[Record]:
    lines = path.read_text(encoding="utf-8").splitlines()
    records: list[Record] = []
    i = 0
    while i < len(lines):
        stripped = lines[i].strip()
        if stripped == "# @api":
            start = i + 1
            rows: list[str] = []
            i += 1
            while i < len(lines) and lines[i].strip() != "# @end":
                if not lines[i].lstrip().startswith("#"):
                    raise fail(path, i + 1, "<detached>", "doc-comment block is not contiguous")
                rows.append(lines[i].lstrip()[1:].lstrip())
                i += 1
            if i >= len(lines):
                raise fail(path, start, "<detached>", "unterminated @api block")
            decl_line = i + 1
            if decl_line >= len(lines) or not (decl := DEFINE.match(lines[decl_line])):
                raise fail(path, start, "<detached>", "@api block must immediately precede a define")
            name = decl.group(1)
            if name.startswith("_"):
                raise fail(path, start, name, "private function must not carry public API documentation")
            fields = parse_fields(path, start + 1, name, rows)
            records.append(Record("library", name, str(path), decl_line + 1, **fields))
            i = decl_line
        elif stripped == "/* @api":
            start = i + 1
            rows = []
            i += 1
            while i < len(lines) and lines[i].strip() != "*/":
                rows.append(re.sub(r"^\s*\*\s?", "", lines[i]))
                i += 1
            if i >= len(lines):
                raise fail(path, start, "<detached>", "unterminated @api block")
            decl_line = i + 1
            if decl_line >= len(lines) or not (decl := REGISTER.search(lines[decl_line])):
                raise fail(path, start, "<detached>", "@api block must immediately precede a builtin registration")
            name = decl.group(1)
            fields = parse_fields(path, start + 1, name, rows)
            records.append(Record("builtin", name, str(path), decl_line + 1, **fields))
            i = decl_line
        i += 1
    return records


def build_ir(paths: list[Path]) -> list[Record]:
    records = [record for path in sorted(paths, key=lambda p: str(p)) for record in extract(path)]
    if not records:
        joined = ", ".join(str(path) for path in paths) or "<no input>"
        raise DocError(f"{joined}:0: <none>: extracted zero API documentation entries")
    seen: dict[tuple[str, str], Record] = {}
    for record in records:
        key = (record.kind, record.name)
        if key in seen:
            first = seen[key]
            raise fail(Path(record.source), record.line, record.name,
                       f"duplicate {record.kind} name (first at {first.source}:{first.line})")
        seen[key] = record
    return records


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args()
    try:
        payload = json.dumps([asdict(record) for record in build_ir(args.paths)],
                             indent=2, ensure_ascii=False) + "\n"
    except (DocError, OSError) as exc:
        print(f"api_doc_ir: {exc}", file=sys.stderr)
        return 1
    if args.output:
        args.output.write_text(payload, encoding="utf-8")
    else:
        sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
