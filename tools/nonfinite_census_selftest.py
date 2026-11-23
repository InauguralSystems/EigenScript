#!/usr/bin/env python3
"""Planted-fault self-test for nonfinite_census.py."""
import os, subprocess, sys, tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
if sys.argv[1:] not in ([], ["--selftest"]):
    raise SystemExit("usage: nonfinite_census_selftest.py [--selftest]")
def check(ok,msg):
    if not ok: print("FAIL:",msg); raise SystemExit(1)
    print("PASS:",msg)

with tempfile.TemporaryDirectory() as d:
    d=Path(d); (d/"tools").mkdir(); (d/"docs").mkdir(); (d/"tests").mkdir()
    tool=d/"tools/nonfinite_census.py"; tool.write_text((ROOT/"tools/nonfinite_census.py").read_text())
    (d/"docs/BUILTINS.md").write_text("| `abs` | x | test |\n| `clock_unix` | x | excluded |\n")
    (d/"tests/strict_shape_cases.json").write_text('''[{"name":"fakebuf","args":["b"],"setup":"b is buffer of 2"}]''')
    fake=d/"fake.py"; log=d/"log"
    fake.write_text('''#!/usr/bin/env python3
import json,os,sys,time
if "--api" in sys.argv: print(json.dumps({"builtins":[{"name":"fakebuf","args":["buffer"]}]})); raise SystemExit
s=open(sys.argv[1]).read(); open(os.environ["CENSUS_LOG"],"a").write(s+"\\n---\\n")
if os.environ.get("EMPTY"): print("Error fake:1: no"); raise SystemExit(1)
if os.environ.get("SLOW"): time.sleep(1)
if "buf_get_bits" in s: print("true"); raise SystemExit
if os.environ.get("CONTROL_ERROR") and "fakebuf of b" in s and "nf is" not in s:
 print("Error fake:1: planted control error"); raise SystemExit(1)
if "of 2.5" in s or "of 2)" in s: print("ok"); raise SystemExit
print("fault" if os.environ.get("FAULT") else "ok")
'''); fake.chmod(0o755)
    env=dict(os.environ,CENSUS_LOG=str(log))
    base=d/"base.tsv"; head=d/"head.tsv"
    cmd=[sys.executable,str(tool),"one-number",str(fake),"--out"]
    control=subprocess.run(cmd+[str(base)],env=env,capture_output=True,text=True)
    check(control.returncode==0 and "examined=" in control.stdout,"clean control produces a non-empty census")
    planted=subprocess.run(cmd+[str(head)],env=dict(env,FAULT="1"),capture_output=True,text=True)
    delta=subprocess.run([sys.executable,str(ROOT/"tools/nonfinite_census.py"),"--diff",str(base),str(head)],capture_output=True,text=True)
    check(planted.returncode==0 and "differ=0" not in delta.stdout,"changed answer appears in --diff")
    empty=subprocess.run(cmd+[str(d/"empty.tsv")],env=dict(env,EMPTY="1"),capture_output=True,text=True)
    check(empty.returncode!=0 and "examined=0" in empty.stdout,"examined=0 fails")
    slow=subprocess.run(cmd+[str(d/"slow.tsv"),"--timeout","0.01"],env=dict(env,SLOW="1"),capture_output=True,text=True)
    check(slow.returncode!=0 and "TIMEOUT=" in slow.stdout,"timeout is counted and fails")
    buffer=d/"buffer.tsv"
    controlled=subprocess.run([sys.executable,str(tool),"buffer-forms",str(fake),"--out",str(buffer)],
                              env=dict(env,CONTROL_ERROR="1"),capture_output=True,text=True)
    buffer_text=buffer.read_text()
    check(controlled.returncode!=0 and "CONTROL_ERR(" in buffer_text and "examined=1" in controlled.stdout,
          "a failing control is CONTROL_ERR, is not probed, and fails clean-control coverage")
    text=log.read_text()
    check(not any((name+" of") in text for name in ("clock_unix","mktemp","monotonic_ms","monotonic_ns","random","random_hex","exe_path","getcwd")),"excluded builtins are not probed")
print("NONFINITE_CENSUS_SELFTEST: 6 passed, 0 failed")
