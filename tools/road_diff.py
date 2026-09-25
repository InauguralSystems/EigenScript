#!/usr/bin/env python3
"""Compare prints and final bindings on main, load_file and import.
JIT stats are field-split, not one anchored expression: a longer stats
line must not read as a missing native mechanism (adf529c, #1057).
"""
import argparse
import difflib
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
ROOT = Path(__file__).resolve().parent.parent
def ident(name):
    if not name or not ("A" <= name[0] <= "Z" or "a" <= name[0] <= "z"):
        return False
    return all(("A" <= c <= "Z") or ("a" <= c <= "z") or ("0" <= c <= "9") or c == "_"
               for c in name)
def metadata(source, tag):
    prefix = "# road-" + tag + ": "
    return [line[len(prefix):] for line in source.splitlines() if line.startswith(prefix)]
def driver_context():
    # Capture driver builtins before the fixture can rebind their names.
    prefix = "_road_" + uuid.uuid4().hex + "_"
    captures = {name: prefix + name for name in
                ("print", "has_key", "load_file", "throw", "result", "error")}
    prelude = "".join(f"{captures[name]} is {name}\n" for name in
                      ("print", "has_key", "load_file", "throw"))
    return captures, prelude
def snapshot(names, captures, module=None):
    lines = []
    for name in names:
        if not ident(name):
            raise ValueError(f"invalid snapshot name: {name}")
        if module:
            lines += [f'if {captures["has_key"]} of [{module}, "{name}"]:',
                      f'    {captures["print"]} of ["{name}", 1, {module}.{name}]',
                      "else:", f'    {captures["print"]} of ["{name}", 0]']
        else:
            lines += ["try:", f'    {captures["print"]} of ["{name}", 1, {name}]',
                      f'catch {captures["error"]}:', f'    {captures["print"]} of ["{name}", 0]']
    return "\n".join(lines) + "\n"
def splice_returns(source, report):
    parts = []
    for line in source.splitlines(True):
        core = line[:-1] if line.endswith("\n") else line
        if core.endswith("\r"):
            core = core[:-1]
        if core == "return" or core.startswith("return ") or core.startswith("return\t"):
            parts.append(report)
        parts.append(line)
    return "".join(parts)
def jit_stats(stderr):
    # (compiled or None, stderr without the line, raw line). Not exactly one
    # [jit] line means the native mechanism is missing. Extra fields ignored.
    lines = stderr.splitlines(keepends=True)
    hits = [i for i, line in enumerate(lines) if line.startswith(b"[jit] ")]
    if len(hits) != 1:
        return None, stderr, b""
    raw = lines[hits[0]]
    compiled = None
    for part in raw.split():
        if part.startswith(b"compiled="):
            try:
                compiled = int(part.split(b"=", 1)[1])
            except ValueError:
                compiled = None
    rest = b"".join(lines[:hits[0]] + lines[hits[0] + 1:])
    return compiled, rest, raw
def run_gate(binary, fixtures, only=None):
    architecture = platform.machine().lower()
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
            invalid = next((name for name in names if not ident(name)), None)
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
                            own.write_text(prelude + splice_returns(source, report) + "\n" + report)
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
                        for key in ("EIGS_TRACE", "EIGS_REPLAY"):
                            env.pop(key, None)
                        env["HOME"] = str(scratch / "empty-home")
                        if native:
                            for key in ("EIGS_JIT_OFF", "EIGENSCRIPT_JIT_FORCE_OFF",
                                        "EIGS_JIT_OSR_THRESHOLD", "EIGS_JIT_OSR_OFF",
                                        "EIGS_JIT_STATS", "EIGS_JIT_STOPS"):
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
                            compiled, stderr, stats_line = jit_stats(stderr)
                            tier_ok = compiled is not None and (
                                compiled == 0 if tier == "ref" else compiled > 0)
                            if stats_line:
                                print(f"road_diff: native {fixture.name} {road} tier={tier} cwd={cwd}: " +
                                      stats_line.decode().strip())
                            if not tier_ok:
                                print(f"road_diff: FAIL: {fixture.name} {road} tier={tier} cwd={cwd}: "
                                      "missing/wrong native mechanism (ref requires compiled=0; jit/osr require compiled>0)")
                        complete = (result.stdout.endswith(marker_bytes) and
                                    result.stdout.count(marker_bytes) == 1)
                        stdout = result.stdout[:-len(marker_bytes)] if complete else result.stdout
                        outputs.append((road, cwd, result.returncode, stdout))
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
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path,
                        default=Path(os.environ.get("EIGENSCRIPT", ROOT / "src/eigenscript")))
    parser.add_argument("--fixtures", type=Path, default=ROOT / "tests/roads")
    parser.add_argument("--fixture", help="run one named fixture (diagnostic only)")
    args = parser.parse_args()
    return run_gate(args.binary.absolute(), args.fixtures.resolve(), args.fixture)
if __name__ == "__main__":
    raise SystemExit(main())
