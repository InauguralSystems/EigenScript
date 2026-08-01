#!/usr/bin/env python3
# Behavioral tests for the EigenScript DAP server (src/eigsdap, #539 v3).
#
# Drives the adapter over the real Content-Length-framed Debug Adapter
# Protocol it speaks on stdin/stdout, against a tape recorded by the
# sibling eigenscript binary, and asserts the responses: initialize
# capabilities (supportsStepBack — the point of a tape debugger),
# launch (including the #411 version refusal), breakpoint verification
# against the tape's L records, stopped events, stack frames from the
# v2 scope chain, the variables pane with trajectory child nodes,
# evaluate, and the reverse commands (stepBack / reverseContinue).
#
# Protocol-pinned like test_lsp.py. Exit 0 if all pass, 1 otherwise.
# The shell wrapper (test_dap.sh) skips cleanly when python3 or the
# binaries are unavailable.

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DAP = os.environ.get("EIGSDAP", os.path.join(HERE, "..", "src", "eigsdap"))
EIGS = os.environ.get("EIGENSCRIPT", os.path.join(HERE, "..", "src", "eigenscript"))

PASS = 0
FAIL = 0


def check(name, cond):
    global PASS, FAIL
    if cond:
        print("  PASS: " + name)
        PASS += 1
    else:
        print("  FAIL: " + name)
        FAIL += 1


def frame(obj):
    body = json.dumps(obj)
    return "Content-Length: %d\r\n\r\n%s" % (len(body), body)


SANITIZER_MARKERS = ("AddressSanitizer", "LeakSanitizer",
                     "UndefinedBehaviorSanitizer", "runtime error:",
                     "detected memory leaks", "SUMMARY: ")
SANITIZER_HITS = []


def converse(messages):
    """Feed framed requests to a fresh adapter, return parsed messages."""
    stream = "".join(frame(m) for m in messages)
    p = subprocess.run([DAP], input=stream, capture_output=True,
                       text=True, timeout=15)
    if p.stderr and any(mk in p.stderr for mk in SANITIZER_MARKERS):
        SANITIZER_HITS.append(p.stderr)
    dec = json.JSONDecoder()
    out, i, s = [], 0, p.stdout
    while True:
        j = s.find("{", i)
        if j < 0:
            break
        try:
            obj, end = dec.raw_decode(s[j:])
        except ValueError:
            break
        out.append(obj)
        i = j + end
    return out, p.returncode


def resp(msgs, request_seq):
    for m in msgs:
        if m.get("type") == "response" and m.get("request_seq") == request_seq:
            return m
    return None


def stops(msgs):
    return [m["body"]["reason"] for m in msgs
            if m.get("type") == "event" and m.get("event") == "stopped"]


# ---- fixture: record a tape with a function call ---------------------
# Line numbers are load-bearing for the breakpoint checks:
#   line 2 = inside double (the local w), line 7 = top-level y.
FIXTURE = """define double(v) as:
    local w is v * 2
    return w
x is 1
x is double of x
x is double of x
y is x + 10
print of y
"""

tmpdir = tempfile.mkdtemp(prefix="eigs_dap_")
src_path = os.path.join(tmpdir, "dapfix.eigs")
tape_path = os.path.join(tmpdir, "dapfix.tape")
with open(src_path, "w") as f:
    f.write(FIXTURE)
env = dict(os.environ, EIGS_TRACE=tape_path)
rec = subprocess.run([EIGS, src_path], env=env, capture_output=True,
                     text=True, timeout=15)
if rec.returncode != 0 or not os.path.exists(tape_path):
    print("  FAIL: could not record fixture tape (rc=%d)" % rec.returncode)
    sys.exit(1)


def req(seq, command, arguments=None):
    m = {"seq": seq, "type": "request", "command": command}
    if arguments is not None:
        m["arguments"] = arguments
    return m


# ---- 1. initialize / capabilities ------------------------------------
msgs, rc = converse([req(1, "initialize"), req(2, "disconnect")])
r = resp(msgs, 1)
check("initialize succeeds", r is not None and r["success"])
check("supportsStepBack advertised", r and r["body"].get("supportsStepBack") is True)
check("supportsConfigurationDoneRequest advertised",
      r and r["body"].get("supportsConfigurationDoneRequest") is True)
check("initialized event sent",
      any(m.get("event") == "initialized" for m in msgs))
check("disconnect exits 0", rc == 0)

# ---- 2. launch failures ----------------------------------------------
msgs, _ = converse([req(1, "initialize"),
                    req(2, "launch", {"tape": tmpdir + "/absent.tape"}),
                    req(3, "launch", {}),
                    req(4, "disconnect")])
r = resp(msgs, 2)
check("launch with missing tape fails", r is not None and not r["success"])
r = resp(msgs, 3)
check("launch without a tape argument fails", r is not None and not r["success"])

# #411: a tampered runtime version must refuse (version-and-reject).
bad_tape = os.path.join(tmpdir, "bad.tape")
with open(tape_path) as f:
    lines = f.read().split("\n")
lines[0] = "V 2 0.0.1-not-this-binary"
with open(bad_tape, "w") as f:
    f.write("\n".join(lines))
msgs, _ = converse([req(1, "initialize"),
                    req(2, "launch", {"tape": bad_tape}),
                    req(3, "disconnect")])
r = resp(msgs, 2)
check("version-mismatched tape refuses to launch",
      r is not None and not r["success"])

# ---- 3. the full session ---------------------------------------------
session = [
    req(1, "initialize"),
    req(2, "launch", {"tape": tape_path, "source": src_path}),
    req(3, "setBreakpoints",
        {"source": {"path": src_path},
         "breakpoints": [{"line": 7}, {"line": 2}, {"line": 999}]}),
    req(4, "configurationDone"),
    req(5, "threads"),
    req(6, "continue"),          # -> first breakpoint hit (line 2, in double)
    req(7, "stackTrace"),
    req(8, "next"),
    req(9, "continue"),          # -> line 2 again (second call)
    req(10, "continue"),         # -> line 7 (top level)
    req(12, "stackTrace"),
    req(13, "scopes", {"frameId": 0}),   # frameId patched below
    req(14, "evaluate", {"expression": "x"}),
    req(15, "evaluate", {"expression": "no_such_name"}),
    req(16, "stepBack"),
    req(17, "reverseContinue"),
    req(18, "stackTrace"),
    req(19, "disconnect"),
]
msgs, rc = converse(session)

r = resp(msgs, 2)
check("launch succeeds", r is not None and r["success"])
check("launch announces the tape",
      any(m.get("event") == "output" and "steps" in m["body"]["output"]
          for m in msgs))

r = resp(msgs, 3)
bps = r["body"]["breakpoints"] if r and r["success"] else []
check("breakpoints on tape lines verify",
      len(bps) == 3 and bps[0]["verified"] and bps[1]["verified"])
check("breakpoint on a line the tape never ran does not verify",
      len(bps) == 3 and not bps[2]["verified"])

check("configurationDone stops at entry", stops(msgs)[:1] == ["entry"])
r = resp(msgs, 5)
check("threads reports the tape thread",
      r and r["body"]["threads"] == [{"id": 1, "name": "tape"}])

check("continue stops on a breakpoint", "breakpoint" in stops(msgs))

# stackTrace at the first breakpoint (line 2, inside double)
r = resp(msgs, 7)
frames = r["body"]["stackFrames"] if r and r["success"] else []
check("breakpoint stop is inside double",
      len(frames) == 2 and frames[0]["name"] == "double"
      and frames[0]["line"] == 2)
check("caller frame is <module>",
      len(frames) == 2 and frames[1]["name"] == "<module>")
check("frames carry the launch source path",
      frames and frames[0].get("source", {}).get("path") == src_path)

# stackTrace after continuing to line 7 (top level)
r = resp(msgs, 12)
tframes = r["body"]["stackFrames"] if r and r["success"] else []
check("later breakpoint stop is at top level, line 7",
      len(tframes) == 1 and tframes[0]["name"] == "<module>"
      and tframes[0]["line"] == 7)

# scopes/variables/trajectory at line 7: x has 3 assigns (1, 2, 4)
fid = tframes[0]["id"] if tframes else 1
msgs2, _ = converse([
    req(1, "initialize"),
    req(2, "launch", {"tape": tape_path}),
    req(3, "setBreakpoints",
        {"source": {"path": src_path}, "breakpoints": [{"line": 7}]}),
    req(4, "configurationDone"),
    req(5, "continue"),
    req(6, "scopes", {"frameId": fid}),
    req(7, "variables", {"variablesReference": 1000000 + fid}),
    req(8, "disconnect"),
])
r = resp(msgs2, 6)
scs = r["body"]["scopes"] if r and r["success"] else []
check("scopes exposes Locals",
      len(scs) == 1 and scs[0]["name"] == "Locals"
      and scs[0]["variablesReference"] == 1000000 + fid)
r = resp(msgs2, 7)
vs = {v["name"]: v for v in (r["body"]["variables"] if r and r["success"] else [])}
check("variables lists x with its folded value",
      "x" in vs and vs["x"]["value"].startswith("4"))
check("variables carries the trajectory label",
      "x" in vs and "[" in vs["x"]["value"])
check("x expands into trajectory children",
      "x" in vs and vs["x"]["variablesReference"] >= 2000000)

traj_ref = vs["x"]["variablesReference"] if "x" in vs else 0
msgs3, _ = converse([
    req(1, "initialize"),
    req(2, "launch", {"tape": tape_path}),
    req(3, "setBreakpoints",
        {"source": {"path": src_path}, "breakpoints": [{"line": 7}]}),
    req(4, "configurationDone"),
    req(5, "continue"),
    req(6, "variables", {"variablesReference": traj_ref}),
    req(7, "disconnect"),
])
r = resp(msgs3, 6)
kids = r["body"]["variables"] if r and r["success"] else []
check("trajectory shows all three assigns of x",
      len(kids) == 3 and all(k["value"].startswith("line ") for k in kids))
check("trajectory values are the assign history",
      len(kids) == 3 and "1" in kids[0]["value"] and "4" in kids[2]["value"])

# evaluate
r = resp(msgs, 14)
check("evaluate resolves a binding",
      r is not None and r["success"] and r["body"]["result"].startswith("4"))
r = resp(msgs, 15)
check("evaluate on an unknown name fails cleanly",
      r is not None and not r["success"])

# reverse: after stepBack + reverseContinue from line 7 we are back on a
# breakpoint (reason) at an earlier position
post = stops(msgs)
check("stepBack/reverseContinue produce stopped events", len(post) >= 6)
r = resp(msgs, 18)
bframes = r["body"]["stackFrames"] if r and r["success"] else []
check("reverseContinue lands on an earlier breakpoint line",
      bframes and bframes[0]["line"] in (2, 7))
check("session exits 0", rc == 0)

# ---- results ----------------------------------------------------------
if SANITIZER_HITS:
    print("  FAIL: sanitizer report in adapter stderr")
    print(SANITIZER_HITS[0][:2000])
    FAIL += 1

print("DAP: %d passed, %d failed" % (PASS, FAIL))
sys.exit(0 if FAIL == 0 else 1)
