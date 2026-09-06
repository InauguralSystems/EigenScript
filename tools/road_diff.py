#!/usr/bin/env python3
"""Compare a file's prints and declared final bindings on all three roads.

See tests/roads/README.md for the wrapper/fixture contract. No stdout filtering,
no tolerated child errors, no fixture allowlist. All children have a deadline.
"""
import argparse
import contextlib
import difflib
import io
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
        # Presence is a separate field, never a value-domain sentinel. A
        # present value (including null or "<missing>") occupies a third field.
        if module:
            lines += [f'if has_key of [{module}, "{name}"]:',
                      f'    print of ["{name}", 1, {module}.{name}]',
                      'else:', f'    print of ["{name}", 0]']
        else:
            lines += ['try:', f'    print of ["{name}", 1, {name}]',
                      'catch _road_error:', f'    print of ["{name}", 0]']
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


def selftest(binary, bad_binary=None):
    with tempfile.TemporaryDirectory(prefix="eigs-road-plants-") as tmp:
        tree = Path(tmp)

        def require_red(label, fixture_name, missing=None, runner=binary):
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                status = run_gate(runner, tree)
            output = captured.getvalue()
            rows = re.findall(r"^road_diff: FAIL: " + re.escape(fixture_name) +
                              r" (main|load_file|import) cwd=.* rc=(-?\d+)$",
                              output, re.M)
            # Prove the intended missing-value/road disagreement, not a dead
            # binary, timeout, or parse failure that happens to exit nonzero.
            external = runner != binary
            expected_runs = 2 if external else 6
            valid = status != 0 and len(rows) == expected_runs and all(rc == "0" for _, rc in rows)
            if external:
                valid = valid and all(road == "import" for road, _ in rows)
            if missing:
                valid = valid and output.count(f'+["{missing}", 0]\n') == expected_runs
            else:
                valid = valid and f"{fixture_name}: roads/cwds diverge" in output
            if not valid:
                print(f"road_diff selftest: FAIL: {label}\n{output}")
                return False
            print(f"road_diff selftest: RED: {label}")
            return True

        fixture = tree / "planted.eigs"
        fixture.write_text('# road-bind: value\nvalue is 7\n')
        fixture.with_suffix('.out').write_text('["value", 1, 7]\n')
        if run_gate(binary, tree):
            print("road_diff selftest: FAIL: positive control")
            return 1
        # Each road runs in an isolated directory. A cwd-printing fixture is
        # deliberately outside the deterministic fixture contract and MUST
        # produce a named cross-road disagreement (not merely a golden diff).
        fixture.write_text('# road-bind: value\nvalue is getcwd of null\n')
        if not require_red("planted.eigs: roads/cwds diverge", fixture.name):
            return 1
        fixture.unlink()

        fixture = tree / "sentinel.eigs"
        fixture.write_text('# road-bind: from_for\nfor k in range of 1:\n    from_for is "<missing>"\n')
        fixture.with_suffix('.out').write_text('["from_for", 1, "<missing>"]\n')
        if run_gate(binary, tree):
            print('road_diff selftest: FAIL: literal "<missing>" positive control')
            return 1
        print('road_diff selftest: GREEN: literal "<missing>" is present')
        # Default: delete the assignment, retaining the present-value golden.
        # For an actual compiler regression proof, --bad-binary runs the same
        # unmodified fixture against a binary that drops the import binding.
        # The default stays portable and does not depend on a stale checkout.
        if not bad_binary:
            fixture.write_text('# road-bind: from_for\nfor k in range of 1:\n    0\n')
        plant = "known-bad binary, import only" if bad_binary else "assignment deleted"
        if not require_red(f'literal "<missing>" binding dropped ({plant})',
                           fixture.name, "from_for", bad_binary or binary):
            return 1
        fixture.unlink()

        fixture = tree / "missing.eigs"
        fixture.write_text('# road-bind: absent\npresent is 1\n')
        fixture.with_suffix('.out').write_text('["absent", 1, null]\n')
        if not require_red("genuinely missing binding cannot impersonate present null",
                           fixture.name, "absent"):
            return 1
        fixture.unlink()

        if run_gate(binary, tree) == 0:
            print("road_diff selftest: FAIL: zero-fixture plant survived")
            return 1
        print("road_diff selftest: RED: zero fixtures")
    print("road_diff selftest: controls=2 plants=4 failures=0")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(os.environ.get("EIGENSCRIPT", ROOT / "src/eigenscript")))
    parser.add_argument("--fixtures", type=Path, default=ROOT / "tests/roads")
    parser.add_argument("--fixture", help="run one named fixture (diagnostic only)")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--bad-binary", type=Path,
                        help="with --selftest: prove sentinel detection against an import-binding regression")
    args = parser.parse_args()
    if args.bad_binary and not args.selftest:
        parser.error("--bad-binary requires --selftest")
    binary = args.binary.absolute()
    bad_binary = args.bad_binary.absolute() if args.bad_binary else None
    raise SystemExit(selftest(binary, bad_binary) if args.selftest else run_gate(binary, args.fixtures.resolve(), args.fixture))
