#!/usr/bin/env python3
"""Generate/check PERFORMANCE.md's observer Callgrind measurement block."""

from __future__ import annotations

import argparse
import pathlib
import shutil
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
START = "<!-- observer-ir:start -->"
END = "<!-- observer-ir:end -->"


def counts(path: pathlib.Path) -> tuple[int, int]:
    rows: dict[str, list[int]] = {}
    for line in path.read_text().splitlines():
        name, value = line.split()
        rows.setdefault(name, []).append(int(value))
    try:
        observed = rows["observed_loop"]
        unobserved = rows["unobserved_loop"]
    except KeyError as exc:
        raise SystemExit(f"PERFORMANCE DOCS RED: missing measurement arm {exc.args[0]}") from exc
    if len(observed) != 5 or len(unobserved) != 5:
        raise SystemExit("PERFORMANCE DOCS RED: observer measurements must be n=5 per arm")
    return sorted(observed)[2], sorted(unobserved)[2]


def generated(baseline: pathlib.Path) -> str:
    observed, unobserved = counts(baseline)
    delta = (observed - unobserved) * 100 / unobserved
    return "\n".join(
        [
            START,
            f"| `observed_loop` | {observed:,} |",
            f"| `unobserved_loop` | {unobserved:,} |",
            f"| observed overhead | {delta:+.2f}% |",
            END,
        ]
    )


def replace(doc: pathlib.Path, block: str) -> str:
    text = doc.read_text()
    if text.count(START) != 1 or text.count(END) != 1 or text.index(START) > text.index(END):
        raise SystemExit("PERFORMANCE DOCS RED: expected exactly one ordered observer-ir marker pair")
    return text[: text.index(START)] + block + text[text.index(END) + len(END) :]


def check(doc: pathlib.Path, baseline: pathlib.Path) -> bool:
    expected = replace(doc, generated(baseline))
    if doc.read_text() != expected:
        print("PERFORMANCE DOCS RED: observer Ir block disagrees with Callgrind measurements")
        print("run: python3 tools/performance_observer_docs.py --update")
        return False
    print("PERFORMANCE DOCS OK: observer Ir block matches Callgrind measurements")
    return True


def selftest(doc: pathlib.Path, baseline: pathlib.Path) -> bool:
    with tempfile.TemporaryDirectory(prefix="eigs-perf-docs-") as tmp:
        tmpdir = pathlib.Path(tmp)
        planted_doc = tmpdir / "PERFORMANCE.md"
        planted_base = tmpdir / "baseline.txt"
        shutil.copyfile(doc, planted_doc)
        shutil.copyfile(baseline, planted_base)
        observed, _ = counts(planted_base)
        text = planted_base.read_text().replace(
            f"observed_loop {observed}", f"observed_loop {observed + 1}"
        )
        planted_base.write_text(text)
        if check(planted_doc, planted_base):
            print("PERFORMANCE DOCS SELFTEST RED: changed measurement passed")
            return False
    print("PERFORMANCE DOCS SELFTEST OK: changed measurement is rejected")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--doc", type=pathlib.Path, default=ROOT / "docs/PERFORMANCE.md")
    parser.add_argument(
        "--baseline", type=pathlib.Path, default=ROOT / "bench/observer_callgrind.txt"
    )
    args = parser.parse_args()
    if args.update:
        args.doc.write_text(replace(args.doc, generated(args.baseline)))
        print(f"updated {args.doc}")
        return 0
    if not check(args.doc, args.baseline):
        return 1
    return 0 if not args.selftest or selftest(args.doc, args.baseline) else 1


if __name__ == "__main__":
    sys.exit(main())
