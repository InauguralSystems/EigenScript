#!/usr/bin/env python3
"""Prove the real-X11 regression scripts stop cleanly on signals (#2411)."""

import glob
import os
import signal
import subprocess
import sys
import time


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = (
    ("tests/test_gfx_utf8_title.sh", "eigs-1681-title."),
    ("tests/test_gfx_ctype_locale.sh", "eigs-1681-ctype."),
)
SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)


def children(pid):
    result = subprocess.run(
        ["ps", "-o", "pid=", "--ppid", str(pid)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return [int(value) for value in result.stdout.split()]


def run_case(script, prefix, sig):
    before = set(glob.glob(f"/tmp/{prefix}*"))
    proc = subprocess.Popen(
        ["bash", os.path.join(ROOT, script)],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    deadline = time.monotonic() + 10
    owned_tmp = set()
    owned_children = []
    while time.monotonic() < deadline and proc.poll() is None:
        owned_tmp = set(glob.glob(f"/tmp/{prefix}*")) - before
        owned_children = children(proc.pid)
        if owned_tmp and owned_children:
            break
        time.sleep(0.02)
    if not owned_tmp or not owned_children:
        proc.kill()
        output, _ = proc.communicate()
        return False, f"server did not start: {output.strip()}"

    started = time.monotonic()
    os.kill(proc.pid, sig)
    try:
        output, _ = proc.communicate(timeout=1)
    except subprocess.TimeoutExpired:
        proc.kill()
        output, _ = proc.communicate()
        return False, "still running after one second"

    expected = 128 + sig
    problems = []
    if proc.returncode != expected:
        problems.append(f"exit={proc.returncode}, expected={expected}")
    if "FAIL:" in output:
        problems.append("printed FAIL:")
    if any(os.path.exists(path) for path in owned_tmp):
        problems.append("temporary directory remains")
    if any(os.path.exists(f"/proc/{pid}") for pid in owned_children):
        problems.append("Xvfb child remains")
    if time.monotonic() - started >= 1:
        problems.append("did not end within one second")
    return not problems, "; ".join(problems)


def main():
    failed = 0
    for script, prefix in CASES:
        for sig in SIGNALS:
            ok, detail = run_case(script, prefix, sig)
            name = signal.Signals(sig).name.removeprefix("SIG")
            if ok:
                print(f"  PASS: {script} stops cleanly on {name}")
            else:
                failed += 1
                print(f"  FAIL: {script} on {name}: {detail}")
    print(f"GFX signal cleanup: {6 - failed} passed, {failed} failed")
    return bool(failed)


if __name__ == "__main__":
    sys.exit(main())
