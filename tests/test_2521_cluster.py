#!/usr/bin/env python3
"""Regression rows for #2518/#2521/#2522/#2523; every row is its own program."""
import json, os, pathlib, resource, struct, subprocess, sys, tempfile
EIGS = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else os.environ.get("EIGS","src/eigenscript")).resolve()
CLASSIFIER = pathlib.Path(__file__).with_name("lsan_classify.sh")
def hard_diagnostic(output):
 return subprocess.run(["sh","-c",'. "$1"; lsan_classify "$(cat)"; [ "$?" -eq 1 ]',"classify",str(CLASSIFIER)],input=output).returncode==0
def caught(expr): return f"try:\n    {expr}\ncatch e:\n    print of [e.kind, e.message]\n"
with tempfile.TemporaryDirectory() as tmp:
 root=pathlib.Path(tmp); failures=0; serial=0
 # stdin_bytes feeds the child (the legacy-header row reads a pipe)
 def execute(name,source,env_extra=None,stdin_bytes=None):
  global serial
  serial+=1; program=root/f"{serial:02d}-{name}.eigs"; program.write_text(source)
  env=os.environ.copy(); env.pop("EIGS_TRACE",None); env.pop("EIGS_REPLAY",None)
  if env_extra: env.update(env_extra)
  q=subprocess.run([str(EIGS),str(program)],env=env,input=stdin_bytes if stdin_bytes is not None else b"",stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  if hard_diagnostic(q.stdout+q.stderr): q.returncode=125
  return q
 def check(name,condition,detail=""):
  global failures
  if condition: print(f"PASS: {name}")
  else: failures+=1; print(f"FAIL: {name}: {detail}")
 def clean(q): return not hard_diagnostic(q.stdout+q.stderr)
 def strict_error(name,expression,kind,message_part=None,env_extra=None,stdin_bytes=None,stderr_absent=None):
  good=True; details=[]
  for strict in (None,"0","1"):
   env=dict(env_extra or {})
   if strict is not None: env["EIGS_STRICT"]=strict
   q=execute(f"{name}-{strict or 'unset'}",caught(expression),env,stdin_bytes)
   output=q.stdout.decode(errors="replace")
   if q.returncode or not clean(q) or f'["{kind}"' not in output or (message_part and message_part not in output) or (stderr_absent and stderr_absent in q.stderr):
    good=False; details.append(f"strict={strict!r} rc={q.returncode} stdout={output!r} stderr={q.stderr!r}")
  check(name,good,"; ".join(details))
 fixtures={
  "short_header":(b"x","io","short four-word header"), "bad_ndim":(struct.pack("IIII",3,1,1,0),"value","ndim is not 1 or 2"),
  "zero_rows":(struct.pack("IIII",2,0,1,0),"value","zero rows"), "zero_cols":(struct.pack("IIII",2,1,0,0),"value","zero columns"),
  "short_payload":(struct.pack("IIII",2,1,2,0)+struct.pack("d",1.0),"io","short tensor payload")}
 for name,(data,kind,defect) in fixtures.items():
  path=root/name; path.write_bytes(data); source=caught(f'tensor_load of "{path}"'); tape=root/f"{name}.tape"
  strict_error("tensor_load "+name+" names the path and the defect",f'tensor_load of "{path}"',kind,f"{path}': {defect}")
  recorded=execute(name+"-trace",source,{"EIGS_TRACE":str(tape)})
  replayed=execute(name+"-replay",source,{"EIGS_REPLAY":str(tape)})
  tape_text=tape.read_text(errors="replace") if tape.exists() else ""
  check("tensor_load "+name+" traces and replays identically",
   recorded.returncode==replayed.returncode==0 and recorded.stdout==replayed.stdout and recorded.stderr==replayed.stderr and
   f'["{kind}"' in recorded.stdout.decode(errors="replace") and tape_text.count("tensor_load=")==1,
   f"record={recorded.returncode,recorded.stdout,recorded.stderr} replay={replayed.returncode,replayed.stdout,replayed.stderr} tape={tape_text!r}")
 # R1: a fourth word above 1 is refused before any legacy rewind.
 strict_error("tensor_load flags through a pipe",'tensor_load of "/dev/stdin"',"value","'/dev/stdin': flags word is not 0 or 1; the three-word format is not read",stdin_bytes=struct.pack("IIII",2,1,1,7))
 strict_error("tensor_load directory",f'tensor_load of "{root}"',"io",f"{root}': Is a directory")
 alloc=root/"allocation.tensor"; alloc.write_bytes(struct.pack("IIII",2,1,10000000,0))
 def memory_cap(): resource.setrlimit(resource.RLIMIT_AS,(70000000,70000000))
 alloc_program=root/"allocation.eigs"; alloc_program.write_text(caught(f'tensor_load of "{alloc}"'))
 # An ASan binary cannot reserve its shadow memory under an address-space cap, so
 # under ASan the allocator's own cap makes the payload allocation fail instead.
 asan_probe=subprocess.run([str(EIGS),"--version"],env=dict(os.environ,ASAN_OPTIONS="help=1"),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 is_asan=b"AddressSanitizer" in asan_probe.stdout+asan_probe.stderr
 alloc_kwargs=None
 if is_asan:
  asan_env=dict(os.environ); asan_env["ASAN_OPTIONS"]=(asan_env.get("ASAN_OPTIONS","")+":allocator_may_return_null=1:max_allocation_size_mb=16").lstrip(":")
  alloc_kwargs={"env":asan_env}
 elif sys.platform=="darwin":
  # macOS refuses RLIMIT_AS, so no cap can be set there; Linux lanes run the rows.
  print("SKIP: tensor_load allocation rows (macOS has no usable RLIMIT_AS)")
 else: alloc_kwargs={"preexec_fn":memory_cap}
 if alloc_kwargs is not None:
  alloc_q=subprocess.run([str(EIGS),str(alloc_program)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,**alloc_kwargs)
  check("tensor_load payload allocation raises limit naming path and size",alloc_q.returncode==0 and clean(alloc_q) and b'["limit"' in alloc_q.stdout and str(alloc).encode() in alloc_q.stdout and b"80000000" in alloc_q.stdout,repr((alloc_q.returncode,alloc_q.stdout,alloc_q.stderr)))
 # Trace and replay of the three cases that had none (a limit error replayed
 # as io stayed green until these rows; #2526 round 4 plant Z6). The replay
 # runs with no cap and no file change, so only the tape can give the kind.
 # Under ASan the refused allocation prints one allocator warning, which only
 # the recording run makes; it is the instrument's line, not the program's.
 def quiet(err): return b"".join(x for x in err.splitlines(True) if b"WARNING: AddressSanitizer failed to allocate" not in x)
 def traced(name,source,kind,record_kwargs,replay_kwargs):
  tape=root/f"{name}.tape"; program=root/f"{name}.eigs"; program.write_text(source)
  base=dict(os.environ); base.pop("EIGS_TRACE",None); base.pop("EIGS_REPLAY",None)
  rk=dict(record_kwargs); renv=dict(rk.pop("env",base)); renv["EIGS_TRACE"]=str(tape)
  rec=subprocess.run([str(EIGS),str(program)],env=renv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**rk)
  penv=dict(base); penv["EIGS_REPLAY"]=str(tape)
  rep=subprocess.run([str(EIGS),str(program)],env=penv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**replay_kwargs)
  tape_text=tape.read_text(errors="replace") if tape.exists() else ""
  check(f"tensor_load {name} traces and replays identically",
   rec.returncode==rep.returncode==0 and clean(rec) and clean(rep) and rec.stdout==rep.stdout and quiet(rec.stderr)==quiet(rep.stderr) and
   f'["{kind}"'.encode() in rec.stdout and tape_text.count("tensor_load=")==1,
   f"record={rec.returncode,rec.stdout,rec.stderr} replay={rep.returncode,rep.stdout,rep.stderr} tape={tape_text!r}")
 if alloc_kwargs is not None:
  traced("allocation",caught(f'tensor_load of "{alloc}"'),"limit",alloc_kwargs,{})
 traced("directory",caught(f'tensor_load of "{root}"'),"io",{},{})
 traced("flags_pipe",caught('tensor_load of "/dev/stdin"'),"value",{"input":struct.pack("IIII",2,1,1,7)},{"input":b""})
 listing=root/"two-entry-directory"; listing.mkdir(); (listing/"a").write_text(""); (listing/"b").write_text("")
 ls_source=f'print of ls of "{listing}"\n'; ls_tape=root/"ls.tape"
 ls_record=execute("ls-two-trace",ls_source,{"EIGS_TRACE":str(ls_tape)})
 (listing/"a").unlink(); (listing/"b").unlink()
 ls_replay=execute("ls-two-replay",ls_source,{"EIGS_REPLAY":str(ls_tape)})
 check("ls two-string answer is not replayed as an error",ls_record.returncode==ls_replay.returncode==0 and ls_record.stdout==ls_replay.stdout and b'["a", "b"]' in ls_record.stdout,
  f"record={ls_record.returncode,ls_record.stdout,ls_record.stderr} replay={ls_replay.returncode,ls_replay.stdout,ls_replay.stderr}")
 # Generated Cartesian contract: no direction, length or later-row case can be
 # omitted by selecting examples by hand.  Each tuple is (name, source, model).
 shape_cases=[
  ("flat0","[]",("list",[])), ("flat1","[1.0]",("list",["number"])),
  ("flat2","[1.0,2.0]",("list",["number","number"])),
  ("flat3","[1.0,2.0,3.0]",("list",["number","number","number"])),
  ("nested11","[[1.0]]",("list",[["number"]])),
  ("nested12","[[1.0,2.0]]",("list",[["number","number"]])),
  ("nested21","[[1.0],[2.0]]",("list",[["number"],["number"]])),
  ("nested22","[[1.0,2.0],[3.0,4.0]]",("list",[["number","number"],["number","number"]])),
  ("mixed_scalar_list","[1.0,[2.0,3.0]]",("list",["number",["number","number"]])),
  ("mixed_list_scalar","[[1.0,2.0],3.0]",("list",[["number","number"],"number"])),
  ("mixed_three_scalar_list_scalar","[1.0,[2.0],3.0]",("list",["number",["number"],"number"])),
  ("mixed_three_list_scalar_list","[[1.0],2.0,[3.0]]",("list",[["number"],"number",["number"]])),
  ("null_row","[null]",("list",["null"])), ("string_row",'["x"]',("list",["str"])),
  ("bool_row","[true]",("list",["bool"])), ("null_cell","[[1.0,null]]",("list",[["number","null"]])),
  ("string_cell",'[[1.0,"x"]]',("list",[["number","str"]])),
  ("bool_cell","[[1.0,true]]",("list",[["number","bool"]])),
  ("buffer1","buffer of 1",("buffer",1)), ("buffer2","buffer of 2",("buffer",2)),
  ("buffer3","buffer of 3",("buffer",3)),
  ("nested_empty_first","[[],[1.5]]",("list",[[],["number"]])),
  ("nested_empty_last","[[1.5],[]]",("list",[["number"],[]])),
  ("nested_all_empty","[[],[]]",("list",[[],[]])),
  ("deep","[[[1.0]]]",("list",[[["number"]]])),
  ("bufval2","buf_from_list of ([1.5,-2.5])",("buffer",2)),
  ("bufval3","buf_from_list of ([1.5,-2.5,4.0])",("buffer",3))]
 def numbers(src):
  # The operand's cells as Python data; a "buffer of N" holds zeros.
  if src.startswith("buffer of"): return [0.0]*int(src.split()[-1])
  return eval(src.replace("buf_from_list of",""),{"__builtins__":{}})
 def step(p,g,lr): return [step(a,b,lr) for a,b in zip(p,g)] if isinstance(p,list) else p-lr*g
 def first_bad(model):
  if model[0]!="list": return None
  def walk(x,depth):
   if isinstance(x,list):
    if depth==2: return "list"
    for y in x:
     bad=walk(y,depth+1)
     if bad: return bad
   elif x!="number": return x
   return None
  return walk(model[1],0)
 def shape_text(rows):
  if not any(isinstance(x,list) for x in rows): return f"[{len(rows)}]"
  return "["+str(len(rows))+" rows:"+"".join(("," if i else "")+" "+(str(len(x)) if isinstance(x,list) else x) for i,x in enumerate(rows))+"]"
 def model_sgd(pm,gm):
  if pm[0]!=gm[0]:
   pk="a list" if pm[0]=="list" else "a 1-D buffer"; gk="a list" if gm[0]=="list" else "a 1-D buffer"
   return ("type_mismatch",f"sgd_update: expected params and grad of the same kind (a list or a buffer), got {pk} params and {gk} grad")
  for model in (pm,gm):
   bad=first_bad(model)
   if bad: return ("type_mismatch",f"sgd_update: expected a number, got {bad}")
  if pm[0]=="buffer":
   if pm[1]!=gm[1]: return ("value",f"sgd_update: params shape count {pm[1]} does not match grad shape count {gm[1]}")
   return None
  ps,gs=shape_text(pm[1]),shape_text(gm[1])
  if any(isinstance(x,list) for x in pm[1]) and any(not isinstance(x,list) for x in pm[1]):
   return ("type_mismatch",f"sgd_update: params shape {ps} mixes list and number rows")
  if any(isinstance(x,list) for x in gm[1]) and any(not isinstance(x,list) for x in gm[1]):
   return ("type_mismatch",f"sgd_update: grad shape {gs} mixes list and number rows")
  if len(pm[1])!=len(gm[1]): return ("value",f"sgd_update: params shape {ps} does not match grad shape {gs}")
  for i,(p,g) in enumerate(zip(pm[1],gm[1])):
   pl,gl=isinstance(p,list),isinstance(g,list)
   if pl!=gl: return ("type_mismatch",f"sgd_update: params shape {ps} and grad shape {gs} differ at row {i}: {'list' if pl else p} against {'list' if gl else g}")
   if pl and len(p)!=len(g): return ("value",f"sgd_update: params shape {ps} and grad shape {gs} differ at row {i}: {len(p)} against {len(g)}")
  return None
 sgd_rows=0
 for pn,params,pm in shape_cases:
  for gn,grad,gm in shape_cases:
   expected=model_sgd(pm,gm)
   for strict in (None,"0","1"):
    sgd_rows+=1; env={} if strict is None else {"EIGS_STRICT":strict}
    before=execute("sgd-before",f"p is {params}\nprint of p\n").stdout
    q=execute(f"sgd-{pn}-{gn}-{strict or 'unset'}",f"p is {params}\ntry:\n    sgd_update of [p, {grad}, 0.5]\n    print of [\"ok\", p]\ncatch e:\n    print of [e.kind, e.message]\nprint of p\n",env)
    lines=q.stdout.splitlines(); unchanged=bool(lines) and lines[-1]+b"\n"==before
    if expected:
     kind,msg=expected; wanted=f'["{kind}", "{msg}"]'.encode()
     ok=q.returncode==0 and clean(q) and wanted in q.stdout and unchanged
    else:
     # The exact cells after the update, not only that the call answered.
     shown="[v for v in p]"
     q=execute(f"sgd-ok-{pn}-{gn}-{strict or 'unset'}",f"p is {params}\nsgd_update of [p, {grad}, 0.5]\nprint of {shown}\n",env)
     try: got=json.loads(q.stdout)
     except ValueError: got=None
     ok=q.returncode==0 and clean(q) and got==step(numbers(params),numbers(grad),0.5)
    check(f"sgd generated {pn}/{gn} strict={strict or 'unset'}",ok,repr((expected,q.returncode,q.stdout,q.stderr,before)))
 # params and grad the same object: every accepted shape, against the same model.
 for pn,params,pm in shape_cases:
  if model_sgd(pm,pm) is not None: continue
  for strict in (None,"0","1"):
   sgd_rows+=1; env={} if strict is None else {"EIGS_STRICT":strict}
   q=execute(f"sgd-alias-{pn}-{strict or 'unset'}",f"p is {params}\nsgd_update of [p, p, 0.5]\nprint of [v for v in p]\n",env)
   try: got=json.loads(q.stdout)
   except ValueError: got=None
   check(f"sgd aliased {pn} strict={strict or 'unset'}",q.returncode==0 and clean(q) and got==step(numbers(params),numbers(params),0.5),repr((q.returncode,q.stdout,q.stderr)))
 print(f"ROWS: sgd_update generated={sgd_rows}")
 sandbox=execute("sandbox-value",'r is sandbox_run of [1, "code", []]\nprint of r.error.kind\n')
 check("sandbox_run descriptor validation kind is value",sandbox.returncode==0 and b"value" in sandbox.stdout,f"rc={sandbox.returncode} stdout={sandbox.stdout!r} stderr={sandbox.stderr!r}")
 api=subprocess.run([str(EIGS),"--api"],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 check("api probe has no sanitizer diagnostic",clean(api),repr((api.returncode,api.stdout,api.stderr)))
 if b"audio_music_play" in api.stdout:
  # An .ogg, not an .mp3: some mpg123 releases accept any bytes at load and fail
  # only at play, which the ruling on #2522 answers with false, not a raise.
  undecodable=root/"undecodable.ogg"; undecodable.write_text("not an audio stream\n")
  # The undecodable row needs a working mixer and device. Probe that with a
  # VALID file, independent of the code under test: a skip keyed on the row's
  # own `false` answer would also skip the very regression the row exists for.
  wav=root/"probe.wav"; pcm=b"\x00\x00"*64
  wav.write_bytes(b"RIFF"+struct.pack("<I",36+len(pcm))+b"WAVEfmt "+struct.pack("<IHHIIHH",16,1,1,8000,16000,2,16)+b"data"+struct.pack("<I",len(pcm))+pcm)
  probe=execute("music-probe",f'print of audio_music_play of ["{wav}", 0]\n',{"SDL_AUDIODRIVER":"dummy"})
  mixer_ok=probe.stdout.decode(errors="replace").strip()=="true"
  noperm=root/"noperm.mp3"; noperm.write_bytes(wav.read_bytes()); noperm.chmod(0)
  cases=[("missing",root/"missing.mp3"),("directory",root),("undecodable",undecodable)]
  if os.geteuid()==0: print("SKIP: audio_music_play no-permission row (running as root, which can read a mode-0 file)")
  else: cases.append(("no permission",noperm))
  for name,path in cases:
   if name=="undecodable" and not mixer_ok:
    print(f"SKIP: audio_music_play undecodable (a valid WAV did not play here, so no mixer or device: probe stdout={probe.stdout!r} stderr={probe.stderr!r})")
    continue
   # Paths that cannot be opened run with no audio device (bogusdrv): the ruling says
   # a headless box raises the same error as a box with speakers.
   strict_error("audio_music_play "+name+" raises named io without stderr diagnostic",f'audio_music_play of ["{path}", 0]',"io",str(path),
    env_extra={"SDL_AUDIODRIVER":"bogusdrv" if name!="undecodable" else "dummy"},stderr_absent=b"audio_music:")
  refusal_tape=root/"audio-refusal.tape"
  execute("audio-refusal-tape",'print of null\n',{"EIGS_TRACE":str(refusal_tape)})
  refusal=[]
  for strict in (None,"0","1"):
   env={"EIGS_REPLAY":str(refusal_tape)}
   if strict is not None: env["EIGS_STRICT"]=strict
   refusal.append(execute("music-replay-"+(strict or "unset"),caught(f'audio_music_play of ["{root / "missing.mp3"}", 0]'),env))
  check("audio_music_play replay refusal is byte-identical in every strict state",
   all(q.returncode==0 and q.stdout==refusal[0].stdout and q.stderr==refusal[0].stderr for q in refusal) and
   b'not replayable under EIGS_REPLAY' in refusal[0].stdout,
   repr([(q.returncode,q.stdout,q.stderr) for q in refusal]))
 else: print("SKIP: audio_music_play rows skipped (non-gfx binary)")
 sys.exit(1 if failures else 0)
