#!/usr/bin/env python3
"""Exercise every signal/phase cell of the real-X11 regression scripts."""
import os
import queue
import threading
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = sys.argv[1:] or [
    os.path.join(ROOT, "tests/test_gfx_utf8_title.sh"),
    os.path.join(ROOT, "tests/test_gfx_ctype_locale.sh"),
]
MOMENTS = ("before-server", "server", "case", "cleanup")
SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
MARKERS = {
    "before-server": "GFX_SIGNAL_READY ",
    "server": "GFX_SIGNAL_SERVER ",
    "case": "GFX_SIGNAL_CASE ",
    "cleanup": "GFX_SIGNAL_CLEANUP ",
}


def run_cell(script, sig, moment):
    env = os.environ.copy()
    env["EIGS_SIGNAL_TEST_MOMENT"] = moment
    proc = subprocess.Popen(["bash", script], cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1)
    lines = queue.Queue()
    reader = threading.Thread(target=lambda: [lines.put(line) for line in proc.stdout], daemon=True)
    reader.start()
    output = []
    tmp = None
    server_pid = None
    # Four title cases can each consume two 30-second diagnostic deadlines.
    ready_deadline = time.monotonic() + float(os.environ.get("EIGS_SIGNAL_READY_TIMEOUT", "300"))
    marker = MARKERS[moment]
    found = False
    while time.monotonic() < ready_deadline and proc.poll() is None:
        try:
            line = lines.get(timeout=0.2)
        except queue.Empty:
            continue
        output.append(line)
        if line.startswith("GFX_SIGNAL_READY tmp="):
            tmp = line.strip().split("tmp=", 1)[1]
        if line.startswith("GFX_SIGNAL_SERVER pid="):
            server_pid = int(line.strip().split("pid=", 1)[1])
        if line.startswith(marker):
            found = True
        if found:
            break
    if not found:
        proc.kill()
        rest, _ = proc.communicate()
        return False, "readiness sign missing"
    if moment == "case":
        time.sleep(1.0)
    os.kill(proc.pid, sig)
    try:
        rest, _ = proc.communicate(timeout=6)
    except subprocess.TimeoutExpired:
        proc.kill()
        rest, _ = proc.communicate()
        return False, "still running after 6s"
    output.append(rest)
    problems = []
    expected = 128 + sig
    if proc.returncode != expected:
        problems.append(f"exit={proc.returncode}, expected={expected}")
    if "FAIL:" in "".join(output):
        problems.append("printed FAIL:")
    if not tmp:
        problems.append("did not disclose temporary directory")
    elif os.path.exists(tmp):
        problems.append(f"temporary directory remains: {tmp}")
    if server_pid is not None:
        try:
            os.kill(server_pid, 0)
        except ProcessLookupError:
            pass
        else:
            problems.append(f"Xvfb remains: {server_pid}")
    return not problems, "; ".join(problems)


def main():
    failed = 0
    examined = 0
    for script in SCRIPTS:
        for sig in SIGNALS:
            for moment in MOMENTS:
                examined += 1
                ok, detail = run_cell(os.path.abspath(script), sig, moment)
                name = signal.Signals(sig).name.removeprefix("SIG")
                label = f"{os.path.basename(script)} {name} {moment}"
                if ok:
                    print(f"  PASS: {label}")
                else:
                    failed += 1
                    print(f"  FAIL: {label}: {detail}")
    print(f"examined={examined}")
    return 1 if failed or examined == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
