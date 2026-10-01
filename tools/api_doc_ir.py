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
import subprocess
import sys
import tempfile
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
            # The first space after ``|`` is markup.  Everything after it is
            # program text: lstrip() here used to corrupt nested blocks.
            code = raw.lstrip()[1:]
            example.append(code[1:] if code.startswith(" ") else code)
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
                body = lines[i].lstrip()[1:]
                rows.append(body[1:] if body.startswith(" ") else body)
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


def declarations(path: Path) -> list[tuple[str, str, int]]:
    """Return public declarations, independently of documentation comments."""
    found = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if match := DEFINE.match(line):
            if not match.group(1).startswith("_"):
                found.append(("library", match.group(1), line_number))
        if match := REGISTER.search(line):
            name = match.group(1)
            if not name.startswith("__"):
                found.append(("builtin", name, line_number))
    return found


def read_allowlist(path: Path | None) -> set[tuple[str, str]]:
    if path is None:
        return set()
    allowed = set()
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            kind, name = line.split()
        except ValueError as exc:
            raise DocError(f"{path}:{number}: malformed allowlist row {line!r}") from exc
        if kind not in ("library", "builtin"):
            raise DocError(f"{path}:{number}: unknown declaration kind {kind!r}")
        allowed.add((kind, name))
    return allowed


def build_ir(paths: list[Path], allowed: set[tuple[str, str]] | None = None) -> list[Record]:
    records = [record for path in sorted(paths, key=str) for record in extract(path)]
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
    documented = set(seen)
    allowed = allowed or set()
    declared: set[tuple[str, str]] = set()
    for path in paths:
        for kind, name, line in declarations(path):
            declared.add((kind, name))
            if (kind, name) not in documented and (kind, name) not in allowed:
                raise fail(path, line, name, "public declaration has no @api documentation")
    stale = sorted(allowed - (declared - documented))
    if stale:
        kind, name = stale[0]
        raise DocError(f"legacy allowlist has stale {kind} entry {name!r}")
    return records


def render_markdown(records: list[Record]) -> str:
    """Render the checked-in reference without hand-maintained API facts."""
    out = [
        "<!-- Generated by tools/api_doc_ir.py; do not edit. -->",
        "# API reference",
        "",
        "This reference is generated from documentation attached to source declarations.",
        "",
    ]
    for kind, title in (("library", "Library functions"), ("builtin", "Builtins")):
        out.extend((f"## {title}", "", "| Name | Signature | Summary | Returns |", "| --- | --- | --- | --- |"))
        selected = [record for record in records if record.kind == kind]
        if not selected:
            out.append("| *(none documented yet)* | | | |")
        for record in selected:
            cells = (record.name, record.signature, record.summary, record.returns)
            out.append("| " + " | ".join(value.replace("|", "\\|").replace("\n", " ") for value in cells) + " |")
        out.append("")
        for record in selected:
            out.extend((f"### `{record.name}`", "", "**Arguments**", ""))
            if record.args:
                out.extend(f"- `{arg['name']}` — {arg['description']}" for arg in record.args)
            else:
                out.append("None.")
            # Pair each generated program with its expected empty stdout.  It
            # is intentionally executed both by the general documentation
            # walker and directly from the source record by the API gate.
            out.extend(("", "**Example**", "",
                        "```eigenscript",
                        record.example, "```", "", "```output", "```", ""))
    return "\n".join(out).rstrip() + "\n"


def generated_region(records: list[Record], kind: str) -> str:
    selected = [record for record in records if record.kind == kind]
    rendered = render_markdown(selected).splitlines()
    # Keep only the requested section; the containing document owns its title.
    heading = "## Library functions" if kind == "library" else "## Builtins"
    start = rendered.index(heading) + 1
    other = "## Builtins" if kind == "library" else None
    end = rendered.index(other) if other and other in rendered else len(rendered)
    return "\n".join(rendered[start:end]).strip() + "\n"


def check_region(path: Path, kind: str, payload: str) -> None:
    begin = f"<!-- BEGIN GENERATED API: {kind} -->"
    end = f"<!-- END GENERATED API: {kind} -->"
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(begin) + r"\n.*?" + re.escape(end), re.DOTALL)
    replacement = f"{begin}\n{payload.rstrip()}\n{end}"
    if not pattern.search(text):
        raise DocError(f"{path}: missing generated region markers for {kind}")
    if pattern.sub(replacement, text, count=1) != text:
        raise DocError(f"{path}: generated {kind} documentation is stale; regenerate it")


def run_examples(records: list[Record], executable: Path) -> None:
    for record in records:
        # Keep the temporary program at the project root so source-tree
        # relative imports resolve exactly as they do for checked-in examples.
        with tempfile.NamedTemporaryFile(
                "w", suffix=".eigs", encoding="utf-8", dir=Path.cwd()) as example:
            example.write(record.example + "\n")
            example.flush()
            result = subprocess.run(
                [str(executable.resolve()), example.name], cwd=Path.cwd(),
                text=True, capture_output=True, check=False,
            )
        if result.returncode or result.stderr:
            detail = (result.stderr or result.stdout).strip()
            reason = "non-empty stderr" if result.stderr and not result.returncode else "failed"
            raise DocError(f"{record.source}:{record.line}: {record.name}: example {reason}: {detail}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("-o", "--output", type=Path)
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--check", type=Path, help="fail unless this file equals generated output")
    parser.add_argument("--run-examples", type=Path, metavar="EIGENSCRIPT")
    parser.add_argument("--allow-undocumented", type=Path)
    parser.add_argument("--check-region", nargs=2, action="append", metavar=("KIND", "PATH"))
    args = parser.parse_args()
    try:
        records = build_ir(args.paths, read_allowlist(args.allow_undocumented))
        payload = (render_markdown(records) if args.format == "markdown" else
                   json.dumps([asdict(record) for record in records], indent=2, ensure_ascii=False) + "\n")
        if args.run_examples:
            run_examples(records, args.run_examples)
        for kind, path in args.check_region or []:
            if kind not in ("library", "builtin"):
                raise DocError(f"unknown generated region kind {kind!r}")
            check_region(Path(path), kind, generated_region(records, kind))
        if args.check:
            current = args.check.read_text(encoding="utf-8")
            if current != payload:
                raise DocError(f"{args.check}: generated documentation is stale; regenerate it")
    except (DocError, OSError) as exc:
        print(f"api_doc_ir: {exc}", file=sys.stderr)
        return 1
    if args.check:
        return 0
    if args.output:
        args.output.write_text(payload, encoding="utf-8")
    else:
        sys.stdout.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
