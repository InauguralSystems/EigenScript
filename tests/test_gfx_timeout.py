#!/usr/bin/env python3
"""Exercise the gfx gate's actual timeout and probe paths without gfx or a build."""
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def main():
    source = Path(__file__).with_name("test_asan_gfx.sh").read_text()
    selector = source.split("# BEGIN gfx timeout selector", 1)[1].split("\n", 1)[1]
    selector = selector.split("# END gfx timeout selector", 1)[0]
    # Completion controls need enough room for process-start jitter on busy CI
    # hosts. Timeout controls stay short so they still exercise TERM and KILL.
    completion_selector = selector.replace(" -k 5", " -k 0.2").replace(" 120", " 10")
    timeout_selector = selector.replace(" -k 5", " -k 0.2").replace(" 120", " 0.5")
    runner = source.split("leak_reported() {", 1)[1].split("\n}", 1)[0]
    runner = "leak_reported() {" + runner + "\n}\n"
    startup = source.split("ASAN_OPTIONS=detect_leaks=1 $TMO /tmp/eigs_asan_gfx_probe", 1)
    if len(startup) != 2:
        raise AssertionError("startup probe lost the selected timeout")
    startup = "ASAN_OPTIONS=detect_leaks=1 $TMO /tmp/eigs_asan_gfx_probe" + startup[1]
    startup = startup.split("\nfi\nrm -f /tmp/eigs_asan_gfx_probe", 1)[0] + "\nfi\n"
    sdl = source.split('SDL_OUT="$($TMO', 1)[1]
    sdl = 'SDL_OUT="$($TMO' + sdl.split("\nprintf '%s' \"$SDL_OUT\"", 1)[0]
    positive = source.split("    if leak_reported /tmp/eigs_asan_gfx_leak", 1)[1]
    positive = "    if leak_reported /tmp/eigs_asan_gfx_leak" + positive.split("\n    fi", 1)[0] + "\n    fi\n"
    corpus = source.split("        # Startup failures and signals", 1)[1]
    corpus = "        # Startup failures and signals" + corpus.split("\n    done", 1)[0]
    classifier = Path(__file__).with_name("lsan_classify.sh")
    timer = shutil.which("timeout") or shutil.which("gtimeout")
    if not timer:
        raise AssertionError("timeout controls require timeout or gtimeout")
    checks = 0
    with tempfile.TemporaryDirectory(prefix="eigs-gfx-timeout-") as directory:
        directory = Path(directory)
        # Both command-selection branches run against the installed timer.
        for command in ("timeout", "gtimeout"):
            os.symlink(timer, directory / command)
        child = directory / "child.py"
        pidfile = directory / "child.pid"
        startfile = directory / "child.start"
        child_source = (
            "#!" + sys.executable + "\n"
            "import os,signal,time\n"
            "mode=os.environ['EIGS_TIMEOUT_CONTROL_MODE']\n"
            "open(" + repr(str(startfile)) + ", 'w').write(str(time.monotonic()))\n"
            "time.sleep(float(os.environ.get('EIGS_TIMEOUT_CONTROL_START_DELAY','0')))\n"
            "if mode in ('ignore','leak-ignore'): signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
            "open(" + repr(str(pidfile)) + ", 'w').write(str(os.getpid()))\n"
            "if mode=='clean': print('sdl-present: false'); raise SystemExit(0)\n"
            "if mode=='error': raise SystemExit(7)\n"
            "if mode.startswith('leak-'): print('==123==ERROR: LeakSanitizer: detected memory leaks',flush=True)\n"
            "if mode=='leak-clean': raise SystemExit(1)\n"
            "if mode=='leak-error': raise SystemExit(7)\n"
            "time.sleep(60)\n"
        )
        child.write_text(child_source)
        child.chmod(0o755)
        declarations = (
            "PASS=0; FAIL=0; LAST_RC=0\n"
            "ok() { PASS=$((PASS+1)); }\n"
            "bad() { echo \"FAIL: $*\"; FAIL=$((FAIL+1)); }\n"
            ". " + shlex.quote(str(classifier)) + "\n"
        )
        completion_walls = []

        def run(name, body, mode, expected, *, completion=False,
                selection=None, hide="", watchdog=False):
            nonlocal checks
            pidfile.unlink(missing_ok=True)
            startfile.unlink(missing_ok=True)
            if selection is None:
                selection = completion_selector if completion else timeout_selector
            masking = ""
            if hide:
                # Override only the selector's availability probe.
                masking = "command() { case \"$*\" in " + hide + ") return 1;; esac; builtin command \"$@\"; }\n"
            code = declarations + masking + selection + "\n" + body
            environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                               EIGS_TIMEOUT_CONTROL_MODE=mode)
            if completion:
                environment["EIGS_TIMEOUT_CONTROL_START_DELAY"] = os.environ.get(
                    "EIGS_GFX_TIMEOUT_COMPLETION_DELAY", "0")
            started = time.monotonic()
            proc = subprocess.Popen(["bash", "-c", code], env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True)
            expired = False
            try:
                try:
                    out, err = proc.communicate(timeout=30 if completion else 2)
                except subprocess.TimeoutExpired:
                    expired = True
                    if pidfile.exists():
                        try:
                            os.killpg(os.getpgid(int(pidfile.read_text())), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    out, err = proc.communicate(timeout=1)
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            if expired != watchdog or (not expired and proc.returncode != expected):
                raise AssertionError("%s: watchdog=%s rc=%s stdout=%r stderr=%r"
                                     % (name, expired, proc.returncode, out, err))
            if completion:
                # Measure from launch, not from the child's first line: the
                # suspected macOS cost is process start (#1916), which a
                # child-side clock would leave out. time.monotonic() is the
                # system clock in both processes.
                ended = time.monotonic()
                child_started = float(startfile.read_text()) if startfile.exists() else None
                completion_walls.append((ended - started,
                                         None if child_started is None else child_started - started))
            checks += 1
            return out.decode()

        invoke = runner + "leak_reported " + shlex.quote(str(child)) + '\nexit "$LAST_RC"\n'
        run("clean child", invoke, "clean", 0, completion=True)
        run("ordinary failure", invoke, "error", 7, completion=True)
        run("TERM deadline", invoke, "hang", 124)
        run("TERM-resistant child", invoke, "ignore", 137)
        run("gtimeout branch", invoke, "ignore", 137, hide='"-v timeout"')
        out = run("missing timeout dependency", invoke, "clean", 1, completion=True,
                  hide='"-v timeout"|"-v gtimeout"')
        if "requires timeout or gtimeout" not in out or pidfile.exists():
            raise AssertionError("missing dependency executed an unbounded child")
        run("removed hard-kill mutation", invoke, "ignore", None,
            selection=timeout_selector.replace(" -k 0.2", ""), watchdog=True)
        positive = positive.replace("/tmp/eigs_asan_gfx_leak", str(child))
        positive = runner + "CTRL_OK=1\n" + positive + '\n[ "$CTRL_OK" = 1 ]\n'
        run("completed leak control", positive, "leak-clean", 0, completion=True)
        run("leak then ordinary failure", positive, "leak-error", 1, completion=True)
        run("leak then timeout", positive, "leak-hang", 1)
        run("leak then forced kill", positive, "leak-ignore", 1)
        for status in (124, 137, 7):
            verdict = "base=01.eigs; mode=plain; LEAK=0; LAST_OUT=; LAST_RC=%d\n" % status
            verdict += corpus + '\necho CONTINUED\nexit 0\n'
            out = run("corpus fail-fast status %d" % status, verdict, "clean",
                      0 if status == 7 else 1, completion=True)
            if ("CONTINUED" in out) != (status == 7):
                raise AssertionError("corpus timeout continued to another row")
        startup = startup.replace("/tmp/eigs_asan_gfx_probe", str(child))
        out = run("actual startup probe", startup, "ignore", 1)
        if "rc=137" not in out:
            raise AssertionError("startup timeout diagnostic lost the forced-kill status")
        # The startup failure cleans its executable. Recreate only this tiny
        # generated script for the final probe controls, never a built binary.
        child.write_text(child_source)
        child.chmod(0o755)
        sdl = sdl.replace("/tmp/eigs_asan_gfx_sdl.eigs", str(directory / "sdl.eigs"))
        sdl = "BIN=" + shlex.quote(str(child)) + "\n" + sdl
        run("SDL clean absence", sdl, "clean", 0, completion=True)
        out = run("SDL timeout is a failure", sdl, "ignore", 1)
        if "SDL availability probe failed (rc=137" not in out:
            raise AssertionError("SDL timeout was reported as absent library")
    walls = sorted(w for w, _ in completion_walls)
    starts = sorted(s for _, s in completion_walls if s is not None)
    p50 = walls[(len(walls) - 1) // 2]
    print("gfx-timeout controls: completion wall max=%.3fs p50=%.3fs start max=%s n=%d"
          % (walls[-1], p50, "%.3fs" % starts[-1] if starts else "n/a", len(walls)))
    print("gfx-timeout controls: %d passed, 0 failed" % checks)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, IndexError, OSError) as error:
        print("FAIL: gfx-timeout controls: " + str(error))
        sys.exit(1)
