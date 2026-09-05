#!/usr/bin/env python3
"""Compare a file's prints and declared final bindings on all three roads.

See tests/roads/README.md for the wrapper/fixture contract. No stdout filtering,
no tolerated child errors, no fixture allowlist. All children have a deadline.
"""
import argparse
import difflib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def metadata(source, tag):
    return re.findall(r"^# road-" + tag + r": (.*)$", source, re.M)


def snapshot(names, module=None):
    lines = []
    for name in names:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name):
            raise ValueError(f"invalid snapshot name: {name}")
        # An absent namespace key is null; a missing bare binding raises.
        # Preserve that distinction by checking membership before reading.
        if module:
            lines += [f'if has_key of [{module}, "{name}"]:',
                      f'    print of ["{name}", {module}.{name}]',
                      'else:', f'    print of ["{name}", "<missing>"]']
        else:
            lines += ['try:', f'    print of ["{name}", {name}]',
                      'catch _road_error:', f'    print of ["{name}", "<missing>"]']
    return "\n".join(lines) + "\n"


def run_gate(binary, fixtures, only=None):
    paths = sorted(fixtures.glob("*.eigs"))
    if only:
        paths = [p for p in paths if p.stem == only]
    if not paths:
        print("road_diff: FAIL: zero fixtures", flush=True)
        return 1
    failures = runs = 0
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="eigs-roads-") as tmp:
        scratch = Path(tmp)
        for fixture in paths:
            source = fixture.read_text()
            bindings = metadata(source, "bind")
            if len(bindings) != 1 or not bindings[0].split():
                print(f"road_diff: FAIL: {fixture.name}: missing/nonunique road-bind")
                failures += 1
                continue
            names = bindings[0].split()
            expected = fixture.with_suffix(".out")
            if not expected.is_file() or not expected.read_bytes():
                print(f"road_diff: FAIL: {fixture.name}: missing/empty expected stdout")
                failures += 1
                continue
            outputs = []
            cwds = metadata(source, "cwd") or [".", "__unrelated_cwd"]
            for road in ("main", "load_file", "import"):
                for ci, cwd in enumerate(cwds):
                    tree = scratch / f"{fixture.stem}-{road}-{ci}"
                    shutil.copytree(fixtures, tree)
                    for pair in metadata(source, "hardlink"):
                        src, dst = pair.split()
                        (tree / dst).unlink()
                        os.link(tree / src, tree / dst)
                    own = tree / fixture.name
                    report = snapshot(names, fixture.stem if road == "import" else None)
                    if road == "main":
                        # A top-level return bypasses a suffix. Snapshot just before
                        # each unindented return, and at normal end of the file.
                        body = re.sub(r"(?m)^(return(?:\s.*)?)$", lambda m: report + m[0], source)
                        own.write_text(body + "\n" + report)
                        entry = own
                    else:
                        entry = tree / "_road_driver.eigs"
                        if road == "import":
                            body = f"import {fixture.stem}\n"
                        else:
                            body = f'_road_result is load_file of "{fixture.name}"\n'
                            returns = metadata(source, "return")
                            if returns:
                                body += (f'if _road_result != ({returns[0]}):\n'
                                         '    throw of "road return value mismatch"\n')
                        entry.write_text(body + report)
                    workdir = tree / cwd
                    workdir.mkdir(parents=True, exist_ok=True)
                    if ci == 1:
                        alias = tree / "__entry_alias" / "entry.eigs"
                        alias.parent.mkdir()
                        alias.symlink_to(entry)
                        entry = alias
                    env = os.environ.copy()
                    # Do not inherit a tape from the caller. These are deterministic
                    # fixtures; sanitizers and execution-tier flags remain enabled.
                    for key in ("EIGS_TRACE", "EIGS_REPLAY"):
                        env.pop(key, None)
                    env["HOME"] = str(scratch / "empty-home")
                    runs += 1
                    try:
                        result = subprocess.run([str(binary), str(entry)], cwd=workdir,
                                                env=env, capture_output=True, timeout=30)
                    except (OSError, subprocess.TimeoutExpired) as err:
                        print(f"road_diff: FAIL: {fixture.name} {road} cwd={cwd}: {err}")
                        failures += 1
                        continue
                    outputs.append((road, cwd, result.returncode, result.stdout))
                    # Strictly require clean stderr as well: an ASan/UBSan warning
                    # at exit 0 must never get hidden behind a matching stdout.
                    if result.returncode or result.stderr or result.stdout != expected.read_bytes():
                        failures += 1
                        print(f"road_diff: FAIL: {fixture.name} {road} cwd={cwd} rc={result.returncode}")
                        print(result.stderr.decode(errors="replace"), end="")
                        print("".join(difflib.unified_diff(
                            expected.read_text().splitlines(True),
                            result.stdout.decode(errors="replace").splitlines(True),
                            fromfile="expected", tofile=f"{road} stdout")), end="")
            if outputs and any(row[2:] != outputs[0][2:] for row in outputs[1:]):
                failures += 1
                print(f"road_diff: FAIL: {fixture.name}: roads/cwds diverge")
            elif len(outputs) == 3 * len(cwds):
                print(f"road_diff: compared {fixture.name} ({len(outputs)} runs)")
    print(f"road_diff: fixtures={len(paths)} runs={runs} failures={failures} "
          f"seconds={time.monotonic() - started:.2f}", flush=True)
    return int(failures != 0)


def selftest(binary):
    with tempfile.TemporaryDirectory(prefix="eigs-road-plants-") as tmp:
        tree = Path(tmp)
        fixture = tree / "planted.eigs"
        fixture.write_text('# road-bind: value\nvalue is 7\n')
        (tree / "planted.out").write_text('["value", 7]\n')
        if run_gate(binary, tree):
            print("road_diff selftest: FAIL: positive control")
            return 1
        # Each road runs in an isolated directory. A cwd-printing fixture is
        # deliberately outside the deterministic fixture contract and MUST
        # produce a named cross-road disagreement (not merely a golden diff).
        fixture.write_text('# road-bind: value\nvalue is getcwd of null\n')
        import contextlib
        import io
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            status = run_gate(binary, tree)
        if status == 0 or "planted.eigs: roads/cwds diverge" not in captured.getvalue():
            print("road_diff selftest: FAIL: divergence plant was not detected\n" + captured.getvalue())
            return 1
        print("road_diff selftest: RED: planted.eigs: roads/cwds diverge")
        fixture.unlink()
        if run_gate(binary, tree) == 0:
            print("road_diff selftest: FAIL: zero-fixture plant survived")
            return 1
        print("road_diff selftest: RED: zero fixtures")
    print("road_diff selftest: controls=1 plants=2 failures=0")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(os.environ.get("EIGENSCRIPT", ROOT / "src/eigenscript")))
    parser.add_argument("--fixtures", type=Path, default=ROOT / "tests/roads")
    parser.add_argument("--fixture", help="run one named fixture (diagnostic only)")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    binary = args.binary.absolute()
    raise SystemExit(selftest(binary) if args.selftest else run_gate(binary, args.fixtures.resolve(), args.fixture))
