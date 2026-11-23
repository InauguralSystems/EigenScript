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
    tool=d/"tools/nonfinite_census.py"
    tool_source=(ROOT/"tools/nonfinite_census.py").read_text()
    # Two producers cover success and per-mode producer rejection while keeping
    # this many-mutant process-level test inside the self-test driver's timeout.
    first=tool_source.index("PRODUCER_CANDIDATES = {")
    last=tool_source.index("\nBITS=",first)
    tool_source=tool_source[:first]+'''PRODUCER_CANDIDATES = {
 "f64_from_bits_store": "buf_set_bits of [{buffer}, {index}, f64_bits of nf]",
 "buf_scale_range": "buf_set_bits of [{buffer}, {index}, 9214364837600034816]\\nbuf_scale_range of [{buffer}, {index}, 1, 2]",
}'''+tool_source[last:]
    tool.write_text(tool_source)
    (d/"docs/BUILTINS.md").write_text("| `abs` | x | test |\n| `clock_unix` | x | excluded |\n")
    (d/"tests/strict_shape_cases.json").write_text('''[
 {"name":"fakebuf","args":["b"],"setup":"b is buffer of 2"},
 {"name":"listfake","args":["[1, 2]"],"setup":""},
 {"name":"gatedfake","args":["[1]"],"setup":"","requirements":["display"]}
]''')
    fake=d/"fake.py"; log=d/"log"
    fake.write_text('''#!/usr/bin/env python3
import json,os,sys,time
if "--api" in sys.argv: print(json.dumps({"builtins":["fakebuf","listfake"],"extensions":{"gfx":["gatedfake"]}})); raise SystemExit
s=open(sys.argv[1]).read(); open(os.environ["CENSUS_LOG"],"a").write(s+"\\n---\\n")
if os.environ.get("EMPTY"): print("Error fake:1: no"); raise SystemExit(1)
if os.environ.get("SLOW") and "nf is" in s: time.sleep(1)
if "print of (len of b)" in s or "print of (len of __census_buffer)" in s: print("1"); raise SystemExit
if "print of ((buf_get_bits" in s:
 if os.environ.get("EIGS_STRICT") == "1" and "buf_scale_range" in s:
  print("Error fake:1: non-finite arithmetic result",file=sys.stderr); raise SystemExit(1)
 print("true"); raise SystemExit
if os.environ.get("CONTROL_ERROR") and "fakebuf of b" in s and "nf is" not in s:
 print("Error fake:1: planted control error"); raise SystemExit(1)
if "define __census_snapshot" in s:
 print("ok"); print("CENSUS:b:" + ("fault" if os.environ.get("BUFFER_FAULT") and "nf is" in s else ("changed" if "nf is" in s else "stable")) + ":0"); raise SystemExit
if "of 2.5" in s or "of 2)" in s: print("ok"); raise SystemExit
if os.environ.get("DIAGNOSTIC"):
 print("exit-entered"); print("Error fake:1: no integer representation",file=sys.stderr); raise SystemExit(1)
print("fault" if os.environ.get("FAULT") else "ok")
'''); fake.chmod(0o755)
    env=dict(os.environ,CENSUS_LOG=str(log))
    base=d/"base.tsv"; head=d/"head.tsv"
    cmd=[sys.executable,str(tool),"one-number",str(fake),"--out"]
    control=subprocess.run(cmd+[str(base)],env=env,capture_output=True,text=True)
    check(control.returncode==0 and "examined=" in control.stderr,"clean control produces a non-empty census")
    planted=subprocess.run(cmd+[str(head)],env=dict(env,FAULT="1"),capture_output=True,text=True)
    delta=subprocess.run([sys.executable,str(ROOT/"tools/nonfinite_census.py"),"--diff",str(base),str(head)],capture_output=True,text=True)
    check(planted.returncode==0 and "differ=3" in delta.stdout and "MISSING" not in delta.stdout and delta.stdout.count("val(ok)") >= 3 and delta.stdout.count("val(fault)") >= 3,
          "one-number diff pairs three changed answers without MISSING rows")
    empty=subprocess.run(cmd+[str(d/"empty.tsv")],env=dict(env,EMPTY="1"),capture_output=True,text=True)
    check(empty.returncode!=0 and "examined=0" in empty.stderr,"examined=0 fails")
    slow_cmd=cmd+[str(d/"slow.tsv"),"--timeout","0.1"]
    slow=subprocess.run(slow_cmd,env=dict(env,SLOW="1"),capture_output=True,text=True)
    count=int(slow.stderr.split("TIMEOUT=")[1].split()[0]) if "TIMEOUT=" in slow.stderr else 0
    check(slow.returncode!=0 and count>0 and "examined=0" not in slow.stderr,"a non-finite timeout is counted and fails")
    allowed=subprocess.run(slow_cmd+["--allow-timeout"],env=dict(env,SLOW="1"),capture_output=True,text=True)
    check(allowed.returncode!=0 and "measured=0" in allowed.stderr,
          "--allow-timeout does not permit a census with no measured answers")
    buffer=d/"buffer.tsv"
    controlled=subprocess.run([sys.executable,str(tool),"buffer-forms",str(fake),"--out",str(buffer)],
                              env=dict(env,CONTROL_ERROR="1"),capture_output=True,text=True)
    buffer_text=buffer.read_text()
    check(controlled.returncode!=0 and "CONTROL_ERR(" in buffer_text and "examined=0" not in controlled.stderr,
          "a failing control is CONTROL_ERR, is not probed, and fails clean-control coverage")
    produced=subprocess.run([sys.executable,str(tool),"buffer-forms",str(fake),"--out",str(buffer)],
                            env=env,capture_output=True,text=True)
    scale=[line for line in buffer.read_text().splitlines() if "\tbuf_scale_range\t" in line]
    check(produced.returncode==0 and scale and all(line.split("\t")[-1] == "NO_PRODUCER" for line in scale),
          "each mode reports NO_PRODUCER before classifying the target")
    buffer_base=d/"buffer-base.tsv"; buffer_head=d/"buffer-head.tsv"
    subprocess.run([sys.executable,str(tool),"buffer-forms",str(fake),"--out",str(buffer_base)],env=env,check=True)
    subprocess.run([sys.executable,str(tool),"buffer-forms",str(fake),"--out",str(buffer_head)],env=dict(env,BUFFER_FAULT="1"),check=True)
    buffer_delta=subprocess.run([sys.executable,str(tool),"--diff",str(buffer_base),str(buffer_head)],capture_output=True,text=True)
    check("differ=0" not in buffer_delta.stdout,"changed buffer cells change a row when the return value does not")
    check("SKIPPED(display)" in buffer_base.read_text(),"requirement-gated extension cases emit SKIPPED rows")
    subprocess.run(cmd+[str(head)],env=dict(env,DIAGNOSTIC="1"),capture_output=True,text=True)
    check("NOINT" in head.read_text() and "exit-entered" not in head.read_text(),
          "a failing probe is classified from the stderr Error diagnostic")
    streamed=subprocess.run([sys.executable,str(tool),"one-number",str(fake)],env=env,capture_output=True,text=True)
    (d/"streamed.tsv").write_text(streamed.stdout)
    stream_delta=subprocess.run([sys.executable,str(tool),"--diff",str(base),str(d/"streamed.tsv")],capture_output=True,text=True)
    check(streamed.returncode==0 and "summary " not in streamed.stdout and "differ=0" in stream_delta.stdout,
          "the summary is kept out of a TSV written to stdout")
    check("with open(p) as f:" in tool.read_text(),"diff closes each input file")
    # Each mutant has a clean control above; apply one fault and require the same
    # population/touch oracle to reject it.
    original=tool.read_text()
    def mutant(name, old, new, oracle):
        check(old in original, name+" mutation site exists")
        tool.write_text(original.replace(old,new,1))
        out=d/(name+".tsv")
        result=subprocess.run([sys.executable,str(tool),"buffer-forms",str(fake),"--out",str(out)],env=env,capture_output=True,text=True)
        check(not oracle(result,out.read_text() if out.exists() else ""),name+" mutant is red")
        tool.write_text(original)
    mutant("all_untouched",
           'touched={cell for cell,_,_,answers in probes\n                     if any(a not in ("NO_PRODUCER", control[j]) for j,a in enumerate(answers))}',
           'touched=set()',lambda r,t:r.returncode == 0)
    mutant("untouched_shortcut",'answers.append(run.run(prog,m)); used_producers.add(pn)',
           'answers.append(control[len(answers)]); used_producers.add(pn)',lambda r,t:r.returncode == 0)
    mutant("empty_population",
           r'listish=is_existing or var.startswith("[") or bool(re.search(rf"\b{re.escape(var)} is \[",setup))',
           'listish=False',lambda r,t:r.returncode == 0)
    mutant("dropped_skipped",
           'rows.append((n,i,"-","SKIPPED("+requirement+")","control","control",*("SKIPPED("+requirement+")",)*3))',
           'pass # planted dropped SKIPPED row',lambda r,t:"SKIPPED(display)" in t)
    mutant("empty_producers",'PRODUCER_CANDIDATES = {','PRODUCER_CANDIDATES = {} # planted\n_UNUSED_PRODUCER_CANDIDATES = {',
           lambda r,t:r.returncode == 0)
    text=log.read_text()
    check(not any((name+" of") in text for name in ("clock_unix","mktemp","monotonic_ms","monotonic_ns","random","random_hex","exe_path","getcwd")),"excluded builtins are not probed")
print("NONFINITE_CENSUS_SELFTEST: 23 passed, 0 failed")
