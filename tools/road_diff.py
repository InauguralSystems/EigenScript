#!/usr/bin/env python3
"""Compare a file's prints and declared final bindings on all three roads.

See tests/roads/README.md for the wrapper/fixture contract. Only the driver's
completion marker is removed from stdout. No tolerated child errors or fixture
allowlist. All children have a deadline.
"""
import argparse
import contextlib
import difflib
import io
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
BINDING_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]*")


def metadata(source, tag):
    return re.findall(r"^# road-" + tag + r": (.*)$", source, re.M)


def driver_context():
    # Every generated binding gets a fresh, private name, including temporaries.
    # Capture all driver builtins BEFORE the fixture can rebind their names.
    prefix = "_road_" + uuid.uuid4().hex + "_"
    captures = {name: prefix + name for name in
                ("print", "has_key", "load_file", "throw", "result", "error")}
    prelude = "".join(f"{captures[name]} is {name}\n" for name in
                      ("print", "has_key", "load_file", "throw"))
    return captures, prelude


def snapshot(names, captures, module=None):
    lines = []
    for name in names:
        if not BINDING_NAME.fullmatch(name):
            raise ValueError(f"invalid snapshot name: {name}")
        # An absent namespace key is null; a missing bare binding raises.
        # Presence is a separate field, never a value-domain sentinel. A
        # present value (including null or "<missing>") occupies a third field.
        if module:
            lines += [f'if {captures["has_key"]} of [{module}, "{name}"]:',
                      f'    {captures["print"]} of ["{name}", 1, {module}.{name}]',
                      'else:', f'    {captures["print"]} of ["{name}", 0]']
        else:
            lines += ['try:', f'    {captures["print"]} of ["{name}", 1, {name}]',
                      f'catch {captures["error"]}:', f'    {captures["print"]} of ["{name}", 0]']
    return "\n".join(lines) + "\n"


def run_gate(binary, fixtures, only=None, *, architecture=None):
    # Explicit architecture is for the selftest of the ARM64 CI policy.
    architecture = architecture or platform.machine().lower()
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
            invalid = next((name for name in names if not BINDING_NAME.fullmatch(name)), None)
            if invalid is not None:
                print(f"road_diff: FAIL: {fixture.name}: invalid snapshot name: {invalid}")
                failures += 1
                continue
            expected = fixture.with_suffix(".out")
            if not expected.is_file() or not expected.read_bytes():
                print(f"road_diff: FAIL: {fixture.name}: missing/empty expected stdout")
                failures += 1
                continue
            native_tags = metadata(source, "native")
            if native_tags and native_tags != ["required"]:
                print(f"road_diff: FAIL: {fixture.name}: invalid road-native metadata")
                failures += 1
                continue
            native = bool(native_tags)
            outputs = []
            cwds = metadata(source, "cwd") or [".", "__unrelated_cwd"]
            tiers = ("ref", "jit", "osr") if native else ("ambient",)
            if native and architecture in ("arm64", "aarch64"):
                # jit.h has no ARM64 emitter. Still run all roads, explicitly
                # interpreter-only; no non-running native arm is called green.
                tiers = ("ref",)
                print(f"road_diff: {fixture.name}: native tiers unavailable on ARM64; interpreter only")
            for tier in tiers:
                for road in ("main", "load_file", "import"):
                    for ci, cwd in enumerate(cwds):
                        tree = scratch / f"{fixture.stem}-{tier}-{road}-{ci}"
                        shutil.copytree(fixtures, tree)
                        for pair in metadata(source, "hardlink"):
                            src, dst = pair.split()
                            (tree / dst).unlink()
                            os.link(tree / src, tree / dst)
                        own = tree / fixture.name
                        captures, prelude = driver_context()
                        report = snapshot(names, captures, fixture.stem if road == "import" else None)
                        marker = "__road_complete_" + uuid.uuid4().hex + "__"
                        marker_bytes = (marker + "\n").encode()
                        report += f'{captures["print"]} of "{marker}"\n'
                        if road == "main":
                            # A top-level return bypasses a suffix. Snapshot just before
                            # each unindented return, and at normal end of the file.
                            body = re.sub(r"(?m)^(return(?:\s.*)?)$", lambda m: report + m[0], source)
                            own.write_text(prelude + body + "\n" + report)
                            entry = own
                        else:
                            entry = tree / "_road_driver.eigs"
                            if road == "import":
                                body = f"import {fixture.stem}\n"
                            else:
                                body = f'{captures["result"]} is {captures["load_file"]} of "{fixture.name}"\n'
                                returns = metadata(source, "return")
                                if returns:
                                    body += (f'if {captures["result"]} != ({returns[0]}):\n'
                                             f'    {captures["throw"]} of "road return value mismatch"\n')
                            entry.write_text(prelude + body + report)
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
                        if native:
                            for key in ("EIGS_JIT_OFF", "EIGENSCRIPT_JIT_FORCE_OFF",
                                        "EIGS_JIT_OSR_THRESHOLD", "EIGS_JIT_OSR_OFF", "EIGS_JIT_STATS", "EIGS_JIT_STOPS"):
                                env.pop(key, None)
                            env["EIGS_JIT_STATS"] = "1"
                            if tier == "ref":
                                env["EIGS_JIT_OFF"] = "1"
                            elif tier == "osr":
                                env["EIGS_JIT_OSR_THRESHOLD"] = "1"
                        runs += 1
                        try:
                            result = subprocess.run([str(binary), str(entry)], cwd=workdir,
                                                    env=env, capture_output=True, timeout=30)
                        except (OSError, subprocess.TimeoutExpired) as err:
                            print(f"road_diff: FAIL: {fixture.name} {road} cwd={cwd}: {err}")
                            failures += 1
                            continue
                        stderr = result.stderr
                        tier_ok = True
                        if native:
                            stats = re.findall(rb"(?m)^\[jit\] scanned=(\d+) compiled=(\d+) cache_used=(\d+)\n", stderr)
                            tier_ok = len(stats) == 1 and (int(stats[0][1]) == 0 if tier == "ref" else int(stats[0][1]) > 0)
                            if len(stats) == 1:
                                stats_line = b"[jit] scanned=%s compiled=%s cache_used=%s\n" % stats[0]
                                stderr = stderr.replace(stats_line, b"", 1)
                                print(f"road_diff: native {fixture.name} {road} tier={tier} cwd={cwd}: " +
                                      stats_line.decode().strip())
                            if not tier_ok:
                                print(f"road_diff: FAIL: {fixture.name} {road} tier={tier} cwd={cwd}: "
                                      "missing/wrong native mechanism (ref requires compiled=0; jit/osr require compiled>0)")
                        complete = (result.stdout.endswith(marker_bytes) and
                                    result.stdout.count(marker_bytes) == 1)
                        stdout = result.stdout[:-len(marker_bytes)] if complete else result.stdout
                        outputs.append((road, cwd, result.returncode, stdout))
                        # Strictly require clean stderr as well: an ASan/UBSan warning
                        # at exit 0 must never get hidden behind a matching stdout.
                        if result.returncode or stderr or not complete or not tier_ok or stdout != expected.read_bytes():
                            failures += 1
                            print(f"road_diff: FAIL: {fixture.name} {road} cwd={cwd} rc={result.returncode}" +
                                  (f" tier={tier}" if native else ""))
                            if not complete:
                                print("missing driver completion marker")
                            print(stderr.decode(errors="replace"), end="")
                            print("".join(difflib.unified_diff(
                                expected.read_text().splitlines(True),
                                stdout.decode(errors="replace").splitlines(True),
                                fromfile="expected", tofile=f"{road} stdout")), end="")
            if outputs and any(row[2:] != outputs[0][2:] for row in outputs[1:]):
                failures += 1
                print(f"road_diff: FAIL: {fixture.name}: roads/cwds diverge")
            elif len(outputs) == len(tiers) * 3 * len(cwds):
                print(f"road_diff: compared {fixture.name} ({len(outputs)} runs)")
    print(f"road_diff: fixtures={len(paths)} runs={runs} failures={failures} "
          f"seconds={time.monotonic() - started:.2f}", flush=True)
    return int(failures != 0)


def selftest(binary, bad_binary=None):
    controls = plants = 0
    with tempfile.TemporaryDirectory(prefix="eigs-road-plants-") as tmp:
        tree = Path(tmp)

        def require_green(label):
            nonlocal controls
            if run_gate(binary, tree):
                print(f"road_diff selftest: FAIL: {label}")
                return False
            controls += 1
            print(f"road_diff selftest: GREEN: {label}")
            return True

        def require_red(label, fixture_name, missing=None, runner=binary, *,
                        roads=("main", "load_file", "import"), rc=0,
                        divergence=False, actual_line=None, stdout_matches=False,
                        diagnostic=None):
            nonlocal plants
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                status = run_gate(runner, tree)
            output = captured.getvalue()
            rows = re.findall(r"^road_diff: FAIL: " + re.escape(fixture_name) +
                              r" (main|load_file|import) cwd=.* rc=(-?\d+)$",
                              output, re.M)
            # Require the exact road/status/diagnostic pattern of the plant,
            # not a dead binary, timeout, or unrelated parse failure.
            expected_rows = sorted((road, str(rc)) for road in roads for _ in range(2))
            expected_runs = len(expected_rows)
            valid = status != 0 and sorted(rows) == expected_rows
            if missing:
                actual_line = f'["{missing}", 0]'
            if actual_line:
                valid = valid and output.count(f'+{actual_line}\n') == expected_runs
            if divergence:
                valid = valid and f"{fixture_name}: roads/cwds diverge" in output
            if stdout_matches:
                valid = valid and "--- expected\n" not in output
                valid = valid and "roads/cwds diverge" not in output
            if diagnostic:
                valid = valid and output.count(diagnostic + "\n") == expected_runs
            if not valid:
                print(f"road_diff selftest: FAIL: {label}\n{output}")
                return False
            print(f"road_diff selftest: RED: {label}")
            plants += 1
            return True

        fixture = tree / "planted.eigs"
        fixture.write_text('# road-bind: value\nvalue is 7\n')
        fixture.with_suffix('.out').write_text('["value", 1, 7]\n')
        if not require_green("numeric binding"):
            return 1
        # Each road runs in an isolated directory. A cwd-printing fixture is
        # deliberately outside the deterministic fixture contract and MUST
        # produce a named cross-road disagreement (not merely a golden diff).
        fixture.write_text('# road-bind: value\nvalue is getcwd of null\n')
        if not require_red("planted.eigs: roads/cwds diverge", fixture.name, divergence=True):
            return 1
        fixture.unlink()

        fixture = tree / "sentinel.eigs"
        fixture.write_text('# road-bind: from_for\nfor k in range of 1:\n    from_for is "<missing>"\n')
        fixture.with_suffix('.out').write_text('["from_for", 1, "<missing>"]\n')
        if not require_green('literal "<missing>" is present'):
            return 1
        # Default: delete the assignment, retaining the present-value golden.
        # For an actual compiler regression proof, --bad-binary runs the same
        # unmodified fixture against a binary that drops the import binding.
        # The default stays portable and does not depend on a stale checkout.
        if not bad_binary:
            fixture.write_text('# road-bind: from_for\nfor k in range of 1:\n    0\n')
        plant = "known-bad binary, import only" if bad_binary else "assignment deleted"
        bad_roads = ("import",) if bad_binary else ("main", "load_file", "import")
        if not require_red(f'literal "<missing>" binding dropped ({plant})',
                           fixture.name, "from_for", bad_binary or binary, roads=bad_roads):
            return 1
        fixture.unlink()

        fixture = tree / "rebind_print.eigs"
        fixture.write_text('# road-bind: print\nemit is print\nfor k in range of 1:\n'
                           '    print is (args) => emit of ["print", 0]\n')
        fixture.with_suffix('.out').write_text('["print", 1, <fn <lambda>>]\n')
        if not require_green("rebinding print cannot forge readback"):
            return 1
        if bad_binary:
            valid = require_red("print rebinding: dropped import binding (known-bad binary)",
                                fixture.name, "print", bad_binary, roads=("import",))
        else:
            fixture.with_suffix('.out').write_text('["print", 0]\n')
            valid = require_red("print rebinding: forged absence golden", fixture.name,
                                actual_line='["print", 1, <fn <lambda>>]')
        if not valid:
            return 1
        fixture.unlink()

        fixture = tree / "rebind_membership.eigs"
        captures, prelude = driver_context()
        # Exercise the SAME namespace-readback emitter in a scope where the
        # fixture owns has_key/keys. Import isolation itself must not be what
        # makes this control green: reverting the has_key capture must fail.
        fixture.write_text('# road-bind: marker\n' + prelude +
                           'subject is {"bound": 7}\n'
                           'has_key is (args) => 0\nkeys is (args) => []\n'
                           'for k in range of 1:\n    marker is 7\n' +
                           snapshot(["bound"], captures, "subject"))
        fixture.with_suffix('.out').write_text('["bound", 1, 7]\n["marker", 1, 7]\n')
        if not require_green("rebinding has_key/keys cannot forge readback"):
            return 1
        if bad_binary:
            valid = require_red("has_key/keys rebinding: dropped import binding (known-bad binary)",
                                fixture.name, "marker", bad_binary, roads=("import",))
        else:
            fixture.with_suffix('.out').write_text('["bound", 1, 7]\n["marker", 0]\n')
            valid = require_red("has_key/keys rebinding: forged absence golden", fixture.name,
                                actual_line='["marker", 1, 7]')
        if not valid:
            return 1
        fixture.unlink()

        fixture = tree / "rebind_throw.eigs"
        source = ('# road-bind: value\n# road-return: 8\nvalue is 7\n'
                  'throw is (args) => 0\nreturn 8\n')
        fixture.write_text(source)
        fixture.with_suffix('.out').write_text('["value", 1, 7]\n')
        if not require_green("rebinding throw preserves return validation"):
            return 1
        fixture.write_text(source.replace('# road-return: 8', '# road-return: 9'))
        if not require_red("throw rebinding cannot suppress a return mismatch", fixture.name,
                           roads=("load_file",), rc=1, divergence=True,
                           diagnostic="road return value mismatch"):
            return 1
        fixture.unlink()

        fixture = tree / "missing.eigs"
        fixture.write_text('# road-bind: absent\npresent is 1\n')
        fixture.with_suffix('.out').write_text('["absent", 1, null]\n')
        if not require_red("genuinely missing binding cannot impersonate present null",
                           fixture.name, "absent"):
            return 1
        fixture.unlink()

        fixture = tree / "process_status.eigs"
        fixture.write_text('# road-bind: value\nvalue is 7\n')
        fixture.with_suffix('.out').write_text('["value", 1, 7]\n')
        # Run a real successful child, then perturb ONLY its process envelope.
        # All six rc-plant exits are identical, so cross-road comparison cannot
        # conceal a deleted absolute rc check. No mock of run_gate is involved.
        for symptom in ("returncode", "stderr"):
            wrapper = tree / f"plant_{symptom}"
            warning = "road selftest planted stderr warning"
            wrapper.write_text(f'#!{sys.executable}\n'
                               'import subprocess, sys\n'
                               f'r = subprocess.run([{str(binary)!r}, *sys.argv[1:]], capture_output=True, timeout=20)\n'
                               'sys.stdout.buffer.write(r.stdout)\n'
                               'sys.stderr.buffer.write(r.stderr)\n'
                               'if r.returncode or r.stderr:\n'
                               '    raise SystemExit(99)\n' +
                               ('raise SystemExit(17)\n' if symptom == "returncode" else
                                f'sys.stderr.write({warning!r} + "\\n")\n'))
            wrapper.chmod(0o755)
            if not require_red("nonzero rc with matching stdout" if symptom == "returncode" else
                               "stderr only with matching stdout and rc=0", fixture.name,
                               runner=wrapper, rc=17 if symptom == "returncode" else 0,
                               stdout_matches=True,
                               diagnostic=warning if symptom == "stderr" else None):
                return 1
        fixture.unlink()

        fixture = tree / "native_control.eigs"
        fixture.write_text('# road-bind: count\n# road-native: required\n'
                           'count is 0\nloop while count < 20000:\n    count is count + 1\n')
        fixture.with_suffix('.out').write_text('["count", 1, 20000]\n')
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            status = run_gate(binary, tree)
        output = captured.getvalue()
        supported = platform.machine().lower() not in ("arm64", "aarch64")
        tier_names = ('ref', 'jit', 'osr') if supported else ('ref',)
        if (status or f'fixtures=1 runs={6 * len(tier_names)} failures=0 ' not in output or
                any(output.count(f' tier={tier} ') != 6 for tier in tier_names)):
            print('road_diff selftest: FAIL: reference and native configurations\n' + output)
            return 1
        controls += 1
        print('road_diff selftest: GREEN: ' + ('reference and two native configurations (18 runs)' if supported
                                              else 'ARM64 interpreter arm (6 runs; no native emitter)'))
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            status = run_gate(binary, tree, architecture="arm64")
        output = captured.getvalue()
        if (status or 'fixtures=1 runs=6 failures=0 ' not in output or
                'native tiers unavailable on ARM64; interpreter only' not in output or
                output.count(' tier=ref ') != 6):
            print('road_diff selftest: FAIL: ARM64 policy\n' + output)
            return 1
        controls += 1
        print('road_diff selftest: GREEN: ARM64 policy explicitly runs only the interpreter')
        if supported:
            # Measure the configuration, not an OSR-entry count. The default
            # JIT can already enter the same chunk through OSR; stats do not
            # distinguish that from the lowered-threshold configuration.
            for drop in (False, True):
                wrapper = tree / 'threshold_guard'
                wrapper.write_text(f'#!{sys.executable}\n'
                                   'import os, pathlib, subprocess, sys\n'
                                   'env = os.environ.copy()\n' +
                                   ('env.pop("EIGS_JIT_OSR_THRESHOLD", None)\n' if drop else '') +
                                   f'r = subprocess.run([{str(binary)!r}, *sys.argv[1:]], env=env, capture_output=True, timeout=20)\n'
                                   'sys.stdout.buffer.write(r.stdout)\n'
                                   'sys.stderr.buffer.write(r.stderr)\n'
                                   'lowered = any(p.startswith("native_control-osr-") for p in pathlib.Path(sys.argv[1]).parts)\n'
                                   'if lowered and env.get("EIGS_JIT_OSR_THRESHOLD") != "1":\n'
                                   '    sys.stderr.write("missing lowered OSR threshold\\n")\n'
                                   '    raise SystemExit(19)\n'
                                   'raise SystemExit(r.returncode)\n')
                wrapper.chmod(0o755)
                captured = io.StringIO()
                with contextlib.redirect_stdout(captured):
                    status = run_gate(wrapper, tree)
                output = captured.getvalue()
                if not drop:
                    valid = status == 0 and 'fixtures=1 runs=18 failures=0 ' in output
                else:
                    valid = (status != 0 and 'fixtures=1 runs=18 failures=7 ' in output and
                             output.count('missing lowered OSR threshold') == 6 and
                             output.count('rc=19 tier=osr') == 6 and '--- expected' not in output and
                             'missing/wrong native mechanism' not in output)
                if not valid:
                    print('road_diff selftest: FAIL: lowered-threshold configuration\n' + output)
                    return 1
                if drop:
                    plants += 1
                    print('road_diff selftest: RED: lowered OSR threshold removed (stdout still matches)')
                else:
                    controls += 1
                    print('road_diff selftest: GREEN: lowered OSR threshold reaches the child')
        for symptom in (('force_off', 'drop_stats') if supported else ('drop_stats',)):

            wrapper = tree / symptom
            wrapper.write_text(f'#!{sys.executable}\n'
                               'import os, re, subprocess, sys\n'
                               'env = os.environ.copy()\n' +
                               ('env["EIGS_JIT_OFF"] = "1"\n' if symptom == 'force_off' else '') +
                               f'r = subprocess.run([{str(binary)!r}, *sys.argv[1:]], env=env, capture_output=True, timeout=20)\n'
                               'sys.stdout.buffer.write(r.stdout)\n' +
                               ('sys.stderr.buffer.write(re.sub(rb"(?m)^\\[jit\\] scanned=.*\\n", b"", r.stderr))\n'
                                if symptom == 'drop_stats' else 'sys.stderr.buffer.write(r.stderr)\n') +
                               'raise SystemExit(r.returncode)\n')
            wrapper.chmod(0o755)
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                status = run_gate(wrapper, tree)
            output = captured.getvalue()
            expected_failures = 12 if symptom == 'force_off' else 6 * len(tier_names)
            if (status == 0 or
                    f'fixtures=1 runs={6 * len(tier_names)} failures={expected_failures} ' not in output or
                    output.count('missing/wrong native mechanism') != expected_failures or
                    '--- expected' in output or 'roads/cwds diverge' in output):
                print(f'road_diff selftest: FAIL: native {symptom} plant\n' + output)
                return 1
            plants += 1
            print('road_diff selftest: RED: ' + ('native tiers compiled nothing' if symptom == 'force_off'
                                              else 'native mechanism statistics missing'))
        healthy_native = fixture.read_text()
        for label, header in (('invalid value', 'maybe'),
                              ('duplicate header', 'required\n# road-native: required')):
            fixture.write_text(healthy_native.replace('# road-native: required', '# road-native: ' + header))
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                status = run_gate(binary, tree)
            output = captured.getvalue()
            if (status == 0 or 'FAIL: native_control.eigs: invalid road-native metadata' not in output or
                    'fixtures=1 runs=0 failures=1 ' not in output or 'Traceback' in output):
                print(f'road_diff selftest: FAIL: native metadata {label}\n' + output)
                return 1
            plants += 1
            print(f'road_diff selftest: RED: native metadata {label}')
        fixture.unlink()

        fixture = tree / "exit_forge.eigs"
        fixture.write_text('# road-bind: value\nprint of ["value", 1, 7]\nexit of 0\n')
        fixture.with_suffix('.out').write_text('["value", 1, 7]\n')
        if not require_red("exit before readback cannot forge completion", fixture.name,
                           stdout_matches=True, diagnostic="missing driver completion marker"):
            return 1
        fixture.unlink()

        fixture = tree / "invalid_name.eigs"
        fixture.write_text('# road-bind: x.y\nvalue is 7\n')
        fixture.with_suffix('.out').write_text('["value", 1, 7]\n')
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            status = run_gate(binary, tree)
        output = captured.getvalue()
        if (status == 0 or
                "road_diff: FAIL: invalid_name.eigs: invalid snapshot name: x.y\n" not in output or
                "fixtures=1 runs=0 failures=1 " not in output or "Traceback" in output):
            print(f"road_diff selftest: FAIL: invalid binding name is a named failure\n{output}")
            return 1
        print("road_diff selftest: RED: invalid binding name is a named failure")
        plants += 1
        fixture.unlink()

        if run_gate(binary, tree) == 0:
            print("road_diff selftest: FAIL: zero-fixture plant survived")
            return 1
        print("road_diff selftest: RED: zero fixtures")
        plants += 1
    print(f"road_diff selftest: controls={controls} plants={plants} failures=0")
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
