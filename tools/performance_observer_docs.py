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


def measurement_counts(path: pathlib.Path) -> tuple[int, int]:
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


def baseline_counts(path: pathlib.Path) -> tuple[int, int]:
    rows: dict[str, int] = {}
    for line in path.read_text().splitlines():
        name, value = line.split()
        rows[name] = int(value)
    try:
        return rows["observed_loop"], rows["unobserved_loop"]
    except KeyError as exc:
        raise SystemExit(f"PERFORMANCE DOCS RED: missing baseline row {exc.args[0]}") from exc


def generated(measurements: pathlib.Path, baseline: pathlib.Path) -> str:
    observed, unobserved = measurement_counts(measurements)
    baseline_observed, baseline_unobserved = baseline_counts(baseline)
    delta = (observed - unobserved) * 100 / unobserved
    return "\n".join(
        [
            START,
            f"| `observed_loop` | {observed:,} |",
            f"| `unobserved_loop` | {unobserved:,} |",
            f"| observed overhead | {delta:+.2f}% |",
            "<!-- observer-cachegrind-baseline: "
            f"observed_loop={baseline_observed} unobserved_loop={baseline_unobserved} -->",
            END,
        ]
    )


def replace(doc: pathlib.Path, block: str) -> str:
    text = doc.read_text()
    if text.count(START) != 1 or text.count(END) != 1 or text.index(START) > text.index(END):
        raise SystemExit("PERFORMANCE DOCS RED: expected exactly one ordered observer-ir marker pair")
    return text[: text.index(START)] + block + text[text.index(END) + len(END) :]


def check(doc: pathlib.Path, measurements: pathlib.Path, baseline: pathlib.Path) -> bool:
    expected = replace(doc, generated(measurements, baseline))
    if doc.read_text() != expected:
        print(
            "PERFORMANCE DOCS RED: observer Ir block disagrees with Callgrind "
            "measurements or Cachegrind baseline"
        )
        print("run: python3 tools/performance_observer_docs.py --update")
        return False
    print("PERFORMANCE DOCS OK: observer Ir block matches measurements and baseline")
    return True


def selftest(doc: pathlib.Path, measurements: pathlib.Path, baseline: pathlib.Path) -> bool:
    with tempfile.TemporaryDirectory(prefix="eigs-perf-docs-") as tmp:
        tmpdir = pathlib.Path(tmp)
        planted_doc = tmpdir / "PERFORMANCE.md"
        planted_measurements = tmpdir / "observer_callgrind.txt"
        planted_baseline = tmpdir / "baseline.txt"
        shutil.copyfile(doc, planted_doc)
        shutil.copyfile(measurements, planted_measurements)
        shutil.copyfile(baseline, planted_baseline)
        observed, _ = measurement_counts(planted_measurements)
        text = planted_measurements.read_text().replace(
            f"observed_loop {observed}", f"observed_loop {observed + 1}"
        )
        planted_measurements.write_text(text)
        if check(planted_doc, planted_measurements, planted_baseline):
            print("PERFORMANCE DOCS SELFTEST RED: changed measurement passed")
            return False
        shutil.copyfile(measurements, planted_measurements)
        baseline_observed, _ = baseline_counts(planted_baseline)
        text = planted_baseline.read_text().replace(
            f"observed_loop {baseline_observed}", f"observed_loop {baseline_observed + 1}", 1
        )
        planted_baseline.write_text(text)
        if check(planted_doc, planted_measurements, planted_baseline):
            print("PERFORMANCE DOCS SELFTEST RED: changed baseline figure passed")
            return False
    print("PERFORMANCE DOCS SELFTEST OK: changed measurement and baseline are rejected")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--doc", type=pathlib.Path, default=ROOT / "docs/PERFORMANCE.md")
    parser.add_argument(
        "--measurements", type=pathlib.Path, default=ROOT / "bench/observer_callgrind.txt"
    )
    parser.add_argument("--baseline", type=pathlib.Path, default=ROOT / "bench/baseline.txt")
    args = parser.parse_args()
    if args.update:
        args.doc.write_text(replace(args.doc, generated(args.measurements, args.baseline)))
        print(f"updated {args.doc}")
        return 0
    if not check(args.doc, args.measurements, args.baseline):
        return 1
    return 0 if not args.selftest or selftest(args.doc, args.measurements, args.baseline) else 1


if __name__ == "__main__":
    sys.exit(main())
