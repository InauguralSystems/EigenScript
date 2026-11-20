#!/usr/bin/env python3
"""Exercise every signal/phase cell of the real-X11 regression scripts."""
import os
import queue
import threading
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SCRIPTS = [
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


def descendants(pid):
    """Return {pid: argv0} for the live descendants of pid (Linux fallback)."""
    parents = {}
    commands = {}
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            with open(f"{entry.path}/stat", encoding="ascii") as stat_file:
                stat = stat_file.read()
            # The command in parentheses can contain spaces and parentheses.
            ppid = int(stat[stat.rfind(")") + 2:].split()[1])
            with open(f"{entry.path}/cmdline", "rb") as command_file:
                command = command_file.read().split(b"\0", 1)[0]
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
            continue
        child = int(entry.name)
        parents[child] = ppid
        commands[child] = os.path.basename(os.fsdecode(command))
    result = {}
    frontier = [pid]
    while frontier:
        parent = frontier.pop()
        children = [child for child, ppid in parents.items() if ppid == parent]
        frontier.extend(children)
        result.update((child, commands[child]) for child in children)
    return result


def wait_for_descendant(proc, executable, deadline):
    while time.monotonic() < deadline and proc.poll() is None:
        for child, command in descendants(proc.pid).items():
            if command == executable:
                return child
        time.sleep(0.02)
    return None


def run_cell(script, sig, moment, no_signs=False):
    env = os.environ.copy()
    env["EIGS_SIGNAL_TEST_MOMENT"] = moment
    proc = subprocess.Popen(["bash", script], cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1)
    lines = queue.Queue()
    captured = []

    def read_stdout():
        for line in proc.stdout:
            captured.append(line)
            lines.put(line)

    reader = threading.Thread(target=read_stdout, daemon=True)
    reader.start()
    tmp = None
    server_pid = None
    # Four title cases can each consume two 30-second diagnostic deadlines.
    ready_deadline = time.monotonic() + float(os.environ.get("EIGS_SIGNAL_READY_TIMEOUT", "300"))
    marker = MARKERS[moment]
    found = False
    if no_signs:
        server_pid = wait_for_descendant(proc, "Xvfb", ready_deadline)
        if server_pid is not None:
            found = wait_for_descendant(proc, "eigenscript", ready_deadline) is not None
    else:
        while time.monotonic() < ready_deadline and proc.poll() is None:
            try:
                line = lines.get(timeout=0.2)
            except queue.Empty:
                continue
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
        proc.wait()
        reader.join()
        return False, "case program descendant missing" if no_signs else "readiness sign missing"
    if moment == "case":
        time.sleep(1.0)
    if proc.poll() is not None:
        reader.join()
        return False, "cell not run: the script ended before the signal was sent"
    os.kill(proc.pid, sig)
    exit_timeout = 6
    try:
        proc.wait(timeout=exit_timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        reader.join()
        return False, "still running after 6s"
    reader.join()
    problems = []
    expected = 128 + sig
    if proc.returncode != expected:
        problems.append(f"exit={proc.returncode}, expected={expected}")
    fail_lines = [line.strip() for line in captured if "FAIL:" in line]
    if fail_lines:
        problems.append("printed " + " | ".join(fail_lines))
    if not no_signs and not tmp:
        problems.append("did not disclose temporary directory")
    elif tmp and os.path.exists(tmp):
        problems.append(f"temporary directory remains: {tmp}")
    if server_pid is not None:
        try:
            os.kill(server_pid, 0)
        except ProcessLookupError:
            pass
        else:
            problems.append(f"Xvfb remains: {server_pid}")
    return not problems, "; ".join(problems)


def selftest():
    fixtures = {
        "clean control": "rm -rf \"$tmp\"; exit 143",
        "reviewer FAIL plant": "echo \"FAIL: planted cleanup failure\"; rm -rf \"$tmp\"; exit 143",
        "directory plant": "exit 143",
    }
    failed = 0
    with tempfile.TemporaryDirectory(prefix="gfx-signal-selftest-") as directory:
        for name, action in fixtures.items():
            script = os.path.join(directory, name.replace(" ", "-") + ".sh")
            with open(script, "w", encoding="utf-8") as fixture:
                fixture.write("#!/bin/sh\n"
                              "tmp=$(mktemp -d)\n"
                              f"trap '{action}' TERM\n"
                              "printf 'GFX_SIGNAL_READY tmp=%s\\n' \"$tmp\"\n"
                              "while :; do sleep 1; done\n")
            expect_ok = name == "clean control"
            for attempt in range(1, 11):
                ok, detail = run_cell(script, signal.SIGTERM, "before-server")
                detected = (ok == expect_ok and
                            (expect_ok or ("FAIL: planted cleanup failure" in detail
                                           if "FAIL" in name else
                                           "temporary directory remains:" in detail)))
                if detected:
                    print(f"  PASS: {name} run {attempt}: {detail or 'clean'}")
                else:
                    failed += 1
                    print(f"  FAIL: {name} run {attempt}: ok={ok}: {detail}")
                if "temporary directory remains:" in detail:
                    leftover = detail.split("temporary directory remains: ", 1)[1].split(";", 1)[0]
                    subprocess.run(["rm", "-rf", leftover], check=True)
    print("selftest=30")
    return 1 if failed else 0


def main():
    args = sys.argv[1:]
    if args == ["--selftest"]:
        return selftest()
    no_signs = False
    if "--no-signs" in args:
        no_signs = True
        args.remove("--no-signs")
    scripts = args or DEFAULT_SCRIPTS
    failed = 0
    examined = 0
    for script in scripts:
        for sig in SIGNALS:
            for moment in MOMENTS:
                if no_signs and moment != "case":
                    name = signal.Signals(sig).name.removeprefix("SIG")
                    print(f"  N/A: {os.path.basename(script)} {name} {moment}: not applicable without signs")
                    continue
                examined += 1
                ok, detail = run_cell(os.path.abspath(script), sig, moment, no_signs)
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
