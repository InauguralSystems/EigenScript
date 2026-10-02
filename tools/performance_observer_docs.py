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


MEASUREMENT_ARMS = (
    "observed_loop",
    "unobserved_loop",
    "conservative_observed_loop",
    "conservative_unobserved_loop",
)


def measurement_counts(path: pathlib.Path) -> dict[str, int]:
    rows: dict[str, list[int]] = {}
    for line in path.read_text().splitlines():
        name, value = line.split()
        rows.setdefault(name, []).append(int(value))
    missing = [name for name in MEASUREMENT_ARMS if name not in rows]
    if missing:
        raise SystemExit(f"PERFORMANCE DOCS RED: missing measurement arm {missing[0]}")
    if any(len(rows[name]) != 5 for name in MEASUREMENT_ARMS):
        raise SystemExit("PERFORMANCE DOCS RED: observer measurements must be n=5 per arm")
    return {name: sorted(rows[name])[2] for name in MEASUREMENT_ARMS}


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
    counts = measurement_counts(measurements)
    observed = counts["observed_loop"]
    unobserved = counts["unobserved_loop"]
    conservative_observed = counts["conservative_observed_loop"]
    conservative_unobserved = counts["conservative_unobserved_loop"]
    baseline_observed, baseline_unobserved = baseline_counts(baseline)
    delta = (observed - unobserved) * 100 / unobserved
    conservative_delta = (
        (conservative_observed - conservative_unobserved) * 100 / conservative_observed
    )
    return "\n".join(
        [
            START,
            "| workload | Callgrind median `Ir` (n=5) |",
            "|---|---:|",
            f"| `observed_loop` | {observed:,} |",
            f"| `unobserved_loop` | {unobserved:,} |",
            f"| observed overhead | {delta:+.2f}% |",
            "<!-- observer-cachegrind-baseline: "
            f"observed_loop={baseline_observed} unobserved_loop={baseline_unobserved} -->",
            "",
            "There remains one narrow use for `unobserved:`. The gate deliberately stays",
            "open when static analysis cannot resolve a computed `load_file` path. In a",
            "constructed conservative case using the same 60,000-iteration loop, the",
            "Callgrind n=5 medians are:",
            "",
            "| workload | Callgrind median `Ir` (n=5) |",
            "|---|---:|",
            f"| `conservative_observed_loop` | {conservative_observed:,} |",
            f"| `conservative_unobserved_loop` | {conservative_unobserved:,} |",
            f"| instruction reduction | {conservative_delta:.1f}% |",
            "",
            "Use the keyword only when profiling identifies observer bookkeeping in such a",
            "conservatively gated program; it is not a default hot-loop optimization.",
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
        for arm in ("observed_loop", "conservative_observed_loop"):
            count = measurement_counts(planted_measurements)[arm]
            text = planted_measurements.read_text().replace(
                f"{arm} {count}", f"{arm} {count + 1}"
            )
            planted_measurements.write_text(text)
            if check(planted_doc, planted_measurements, planted_baseline):
                print(f"PERFORMANCE DOCS SELFTEST RED: changed {arm} measurement passed")
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
    print("PERFORMANCE DOCS SELFTEST OK: ordinary, conservative, and baseline drift rejected")
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
