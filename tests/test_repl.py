#!/usr/bin/env python3
"""PTY-driven tests for the #392 interactive REPL line editor (src/repl.c).

Drives the real binary on a pseudo-terminal — arrows, history, editing,
tab completion, Ctrl-keys — and asserts on the transcript. The piped
(non-tty) path is covered separately in test_repl.sh; this file is only
about the editor, which never activates without a tty.

Assertion discipline: the editor repaints the line on every keystroke, so
the transcript contains many copies of the typed text. Tests therefore
assert on *evaluation results* (`=> N` strings that can't appear in an
echo) and use expect_count when the same result must appear again.

Prints "PASS: name" / "FAIL: name — detail" lines (run_all_tests.sh greps).
"""
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time

EIGS = os.environ.get("EIGS", os.path.join(os.path.dirname(__file__), "..", "src", "eigenscript"))

PASS = 0
FAIL = 0


def report(ok, name, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"PASS: {name}")
    else:
        FAIL += 1
        print(f"FAIL: {name} — {detail}")


class Repl:
    """An interactive REPL session on a pty."""

    def __init__(self, env_extra=None):
        env = dict(os.environ)
        env["TERM"] = "xterm"
        env.pop("EIGS_REPL_PLAIN", None)
        env.pop("EIGS_TRACE", None)
        env.pop("EIGS_REPLAY", None)
        # keep the default session out of the runner's history file
        env.setdefault("EIGS_HISTORY", "/dev/null")
        if env_extra:
            env.update(env_extra)
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen(
            [EIGS], stdin=slave, stdout=slave, stderr=slave,
            env=env, close_fds=True)
        os.close(slave)
        self.buf = b""

    def send(self, data: bytes):
        os.write(self.master, data)

    def expect_count(self, needle: bytes, n: int, timeout=10.0):
        """Read until the transcript holds >= n copies of needle."""
        deadline = time.monotonic() + timeout
        while self.buf.count(needle) < n:
            remain = deadline - time.monotonic()
            if remain <= 0:
                return False
            r, _, _ = select.select([self.master], [], [], remain)
            if not r:
                return False
            try:
                chunk = os.read(self.master, 4096)
            except OSError:
                return False
            if not chunk:
                return False
            self.buf += chunk
        return True

    def expect(self, needle: bytes, timeout=10.0):
        return self.expect_count(needle, 1, timeout)

    def close(self, timeout=10.0):
        try:
            rc = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            rc = None
        os.close(self.master)
        return rc


UP = b"\x1b[A"
DOWN = b"\x1b[B"
LEFT = b"\x1b[D"
RIGHT = b"\x1b[C"
CTRL_A, CTRL_C, CTRL_D, CTRL_E, CTRL_K, CTRL_U, CTRL_W = (
    b"\x01", b"\x03", b"\x04", b"\x05", b"\x0b", b"\x15", b"\x17")


def test_banner_and_eval():
    r = Repl()
    ok = r.expect(b"eigs> ")
    r.send(b"40 + 2\r")
    ok = ok and r.expect(b"=> 42")
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "editor evaluates a typed line", f"rc={rc}")


def test_arrow_editing():
    r = Repl()
    ok = r.expect(b"eigs> ")
    # type '40 - 2', arrow back to the '-', replace it with '+'
    r.send(b"40 - 2")
    r.send(LEFT * 2)      # cursor lands just after the '-'
    r.send(b"\x7f")       # backspace removes the '-'
    r.send(b"+")          # '40 + 2'
    r.send(b"\r")
    ok = ok and r.expect(b"=> 42")   # '42' never appears in any echo
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "arrow-key cursor editing fixes the line in place", f"rc={rc}")


def test_ctrl_u_and_kill():
    r = Repl()
    ok = r.expect(b"eigs> ")
    r.send(b"garbage that would not parse ((((")
    r.send(CTRL_U)                       # wipe the line
    r.send(b"70 + 7\r")
    ok = ok and r.expect(b"=> 77")       # fails if any garbage survived
    r.send(b"more junk")
    r.send(CTRL_A)                       # home
    r.send(CTRL_K)                       # kill to end -> empty line
    r.send(b"80 + 8\r")
    ok = ok and r.expect(b"=> 88")
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "Ctrl-U/Ctrl-A/Ctrl-K line editing", f"rc={rc}")


def test_history_recall():
    r = Repl()
    ok = r.expect(b"eigs> ")
    r.send(b"40 + 1\r")
    ok = ok and r.expect(b"=> 41")
    r.send(b"40 + 2\r")
    ok = ok and r.expect(b"=> 42")
    r.send(UP + UP + b"\r")              # two back: recall '40 + 1'
    ok = ok and r.expect_count(b"=> 41", 2)
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "up-arrow history recall re-evaluates an older line", f"rc={rc}")


def test_history_draft_parking():
    r = Repl()
    ok = r.expect(b"eigs> ")
    r.send(b"parked is 7\r")
    ok = ok and r.expect(b"=> 7")
    r.send(b"draft_te")                  # a draft, not submitted
    r.send(UP)                           # park it, show 'parked is 7'
    r.send(DOWN)                         # come back to the draft
    r.send(b"xt is 123\r")               # finish it: 'draft_text is 123'
    ok = ok and r.expect(b"=> 123")      # parse error instead if parking failed
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "down-arrow restores the parked draft", f"rc={rc}")


def test_tab_completion_binding():
    r = Repl()
    ok = r.expect(b"eigs> ")
    r.send(b"completion_target_binding is 5\r")
    ok = ok and r.expect(b"=> 5")
    r.send(b"completion_targ\t")         # unique prefix -> full completion
    r.send(b" + 1\r")
    ok = ok and r.expect(b"=> 6")
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "tab completes a session binding", f"rc={rc}")


def test_tab_completion_builtin():
    r = Repl()
    ok = r.expect(b"eigs> ")
    # builtins are env bindings; 'floo' is uniquely 'floor'
    r.send(b"floo\t of 9.7\r")
    ok = ok and r.expect(b"=> 9\r\n")
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "tab completes a builtin name", f"rc={rc}")


def test_ctrl_c_cancels():
    r = Repl()
    ok = r.expect(b"eigs> ")
    r.send(b"junk that would not parse ((((")
    r.send(CTRL_C)
    ok = ok and r.expect(b"^C")
    r.send(b"50 + 5\r")
    ok = ok and r.expect(b"=> 55")
    # Ctrl-C must also abandon an open block: with the false `if` gone,
    # the next line runs standalone; if the block survived, the unindented
    # line would fold into it and print nothing.
    r.send(b"if 1 > 2:\r")
    ok = ok and r.expect(b"...   ")
    r.send(CTRL_C)
    r.send(b"60 + 6\r")
    ok = ok and r.expect(b"=> 66")
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "Ctrl-C cancels the line and an open block", f"rc={rc}")


def test_ctrl_d_eof():
    r = Repl()
    ok = r.expect(b"eigs> ")
    r.send(CTRL_D)
    rc = r.close()
    report(ok and rc == 0, "Ctrl-D on an empty line exits cleanly", f"rc={rc}")


def test_multiline_block():
    r = Repl()
    ok = r.expect(b"eigs> ")
    r.send(b"if 2 > 1:\r")
    ok = ok and r.expect(b"...   ")
    r.send(b"    bm is 30 + 3\r")
    r.send(b"\r")                        # blank line runs the block
    r.send(b"bm\r")
    ok = ok and r.expect(b"=> 33")
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "':' opens a block, blank line runs it", f"rc={rc}")


def test_temporal_on_session_bindings():
    r = Repl()
    ok = r.expect(b"eigs> ")
    r.send(b"tq is 10\r")
    ok = ok and r.expect(b"=> 10")
    r.send(b"tq is 20\r")
    ok = ok and r.expect(b"=> 20")
    r.send(b"prev of tq\r")
    ok = ok and r.expect_count(b"=> 10", 2)   # history recorded from session start
    r.send(b"exit\r")
    rc = r.close()
    report(ok and rc == 0, "prev-of works on session bindings (#392 observer touch)",
           f"rc={rc}")


def test_history_file():
    with tempfile.TemporaryDirectory() as d:
        hist = os.path.join(d, "hist")
        r = Repl(env_extra={"EIGS_HISTORY": hist})
        ok = r.expect(b"eigs> ")
        r.send(b"90 + 9\r")
        ok = ok and r.expect(b"=> 99")
        r.send(b"exit\r")
        rc = r.close()
        try:
            with open(hist, "rb") as f:
                data = f.read()
        except OSError:
            data = b""
        persisted = b"90 + 9\n" in data
        # a second session must see the first session's history
        r2 = Repl(env_extra={"EIGS_HISTORY": hist})
        ok2 = r2.expect(b"eigs> ")
        r2.send(UP + UP + b"\r")         # skip the trailing 'exit', recall '90 + 9'
        ok2 = ok2 and r2.expect(b"=> 99")
        r2.send(b"exit\r")
        rc2 = r2.close()
        report(ok and rc == 0 and persisted and ok2 and rc2 == 0,
               "history persists to EIGS_HISTORY across sessions",
               f"rc={rc}/{rc2} persisted={persisted}")


def test_plain_mode_hook():
    r = Repl(env_extra={"EIGS_REPL_PLAIN": "1"})
    ok = r.expect(b"eigs> ")
    r.send(b"20 + 2\r")
    ok = ok and r.expect(b"=> 22")
    r.send(b"exit\r")
    rc = r.close()
    escapes = b"\x1b[0K" in r.buf        # editor repaints never happen in plain mode
    report(ok and rc == 0 and not escapes,
           "EIGS_REPL_PLAIN forces the plain loop on a tty",
           f"rc={rc} escapes={escapes}")


def main():
    if not os.path.exists(EIGS):
        print(f"FAIL: repl tests — binary not found at {EIGS}")
        sys.exit(1)
    signal.alarm(300)                    # belt-and-braces: no wedged suite
    for t in (test_banner_and_eval, test_arrow_editing, test_ctrl_u_and_kill,
              test_history_recall, test_history_draft_parking,
              test_tab_completion_binding, test_tab_completion_builtin,
              test_ctrl_c_cancels, test_ctrl_d_eof, test_multiline_block,
              test_temporal_on_session_bindings, test_history_file,
              test_plain_mode_hook):
        try:
            t()
        except Exception as e:  # a harness bug must read as a FAIL, not a crash
            report(False, t.__name__, f"exception: {e}")
    print(f"repl editor: {PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
