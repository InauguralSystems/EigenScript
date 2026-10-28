#!/usr/bin/env python3
"""Drive C/Lean parity and continuously prove that the instrument can fail."""
from pathlib import Path
import argparse,importlib.util,os,shutil,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]; VM=ROOT/'src/eigenscript'
def runtime_version():
 return subprocess.check_output([VM,'--version'],text=True).strip()
def ref_args(ref,*args):
 return [ref,'--version',runtime_version(),*args]
def population():
 s=importlib.util.spec_from_file_location('docs',ROOT/'tests/test_doc_examples.py'); d=importlib.util.module_from_spec(s); s.loader.exec_module(d); out=[]
 for rel in d.POPULATION:
  for line,info,args,source in d.blocks(str(ROOT/rel)):
   kind,_,error=d.parse_tag(args)
   if error: raise RuntimeError(f'{rel}:{line}: {error}')
   if info=='eigenscript' and kind in ('','check'): out.append((f'{rel}:{line}',source))
 for rel in subprocess.check_output(['git','ls-files','tests','examples'],cwd=ROOT,text=True).splitlines():
  if rel.endswith('.eigs'): out.append((rel,(ROOT/rel).read_text()))
 for rel in subprocess.check_output(['git','ls-files','spec/lean/parity_cases/*.eigs'],cwd=ROOT,text=True).splitlines(): out.append((rel,(ROOT/rel).read_text()))
 return out
def cls(p):
 if p.returncode==0:return 'success'
 e=p.stderr.decode(errors='replace') if isinstance(p.stderr,bytes) else p.stderr
 return 'parse/compile error' if 'parse error' in e.lower() else 'runtime error'
def classified(p,label,command):
 o=p.stdout.strip()
 if p.returncode: raise RuntimeError(f'{command} failed for {label} (exit {p.returncode}): {p.stderr.strip()}')
 if o=='in-subset':return True
 if o.startswith('out: ') and ' at line ' in o:return False
 raise RuntimeError(f'{command} produced malformed verdict for {label}: {o!r}')
def classifier_protocol_selfcheck():
 # Negative controls for classified(): a crashed, an empty and a malformed
 # classifier response must each be REJECTED. The reported count is derived
 # from these outcomes, never typed (#2050 review: a literal 3/3 had
 # replaced the measurement).
 bad=[subprocess.CompletedProcess([],1,'','crash'),subprocess.CompletedProcess([],0,'',''),subprocess.CompletedProcess([],0,'maybe','')]
 rejected=0
 for r in bad:
  try:classified(r,'self-check','--classify-runtime')
  except RuntimeError:rejected+=1
 if rejected!=len(bad):raise RuntimeError(f'classifier protocol self-check failed: {rejected}/{len(bad)} rejected')
 return rejected,len(bad)
def projection(p):
 if not p.exists():return []
 return [(f[0],f[-1]) for x in p.read_text(errors='replace').splitlines() if (f:=x.split(' ',2)) and f[0] in ('A','N')]
def validate_medium(ref,lean_root):
 bad=[]
 try:
  if ref.samefile(VM):bad.append('no-delegation: Lean side is the C VM')
 except FileNotFoundError:bad.append('no-delegation: missing executable')
 if ref.exists() and b'lean_initialize_runtime_module' not in ref.read_bytes():bad.append('medium: Lean runtime signature absent')
 forbidden=('IO.Process.spawn','IO.Process.output','@[extern')
 for p in lean_root.rglob('*.lean'):
  if '.lake' not in p.parts and any(x in p.read_text() for x in forbidden):bad.append(f'no-delegation: {p.name}')
 return bad
def replay_refusal_cases(ref):
 with tempfile.TemporaryDirectory() as raw:
  td=Path(raw); source=td/'replay_refusal.eigs'; source.write_text('local x is random_int of [1, 2]\nprint of x\n')
  good=td/'refusal-good.tape'
  subprocess.run([VM,source],capture_output=True,input=b'',check=True,env={**os.environ,'EIGS_JIT_OFF':'1','EIGS_TRACE':str(good)})
  lines=good.read_text().splitlines(); n=next(i for i,x in enumerate(lines) if x.startswith('N '))
  wrong=td/'wrong-kind.tape'; wrong.write_text('\n'.join(lines[:n]+[lines[n].replace('random_int=','env_get=',1)]+lines[n+1:])+'\n')
  short=td/'short.tape'; short.write_text('\n'.join(lines[:n])+'\n')
  checked=0
  for tape,want in ((wrong,'replay divergence'),(short,'runtime error')):
   c=subprocess.run([VM,source],capture_output=True,input=b'',env={**os.environ,'EIGS_JIT_OFF':'1','EIGS_REPLAY':str(tape),'EIGS_REPLAY_STRICT':'1'})
   l=subprocess.run(ref_args(ref,'--replay',tape,'--strict',source),capture_output=True,input=b'')
   cclass='replay divergence' if c.returncode==3 else cls(c)
   lclass='replay divergence' if l.returncode==3 else cls(l)
   if cclass!=want or lclass!=want:raise RuntimeError(f'replay refusal parity: wanted {want}, C={cclass}, Lean={lclass}')
   checked+=1
  # A V header is a hard session boundary.  Neither implementation may scan
  # into the following session for an otherwise matching N record.
  sessions=td/'sessions.tape';sessions.write_text(
   f'V 8 {runtime_version()}\nB 0 1 1 0 root -\nV 8 {runtime_version()}\nB 0 1 1 0 root -\nN 0 random_int=1\n')
  c=subprocess.run([VM,source],capture_output=True,input=b'',env={**os.environ,'EIGS_JIT_OFF':'1','EIGS_REPLAY':str(sessions),'EIGS_REPLAY_STRICT':'1'})
  l=subprocess.run(ref_args(ref,'--replay',sessions,'--strict',source),capture_output=True,input=b'')
  message=b'random_int: replay stream 0 has no matching recorded N value'
  if cls(c)!='runtime error' or cls(l)!='runtime error' or message not in c.stderr or message not in l.stderr:
   raise RuntimeError(f'session-boundary parity: C={c.returncode}/{c.stderr!r}, Lean={l.returncode}/{l.stderr!r}')
  checked+=1

  # Exercise #1816's physical framing with a real VM-produced read_line tape,
  # then require the model both to consume it and to emit replayable C rows.
  large_source=td/'large-read-line.eigs';large_source.write_text('print of (read_line of [])\n')
  large_tape=td/'large-c.tape';large=b'x'*70000+b'\n'
  c_record=subprocess.run([VM,large_source],capture_output=True,input=large,
   env={**os.environ,'EIGS_JIT_OFF':'1','EIGS_TRACE':str(large_tape)})
  lean_tape=td/'large-lean.tape'
  l_replay=subprocess.run(ref_args(ref,'--replay',large_tape,'--strict','--trace',lean_tape,large_source),capture_output=True,input=b'')
  c_reverse=subprocess.run([VM,large_source],capture_output=True,input=b'',
   env={**os.environ,'EIGS_JIT_OFF':'1','EIGS_REPLAY':str(lean_tape),'EIGS_REPLAY_STRICT':'1'})
  if not (c_record.returncode==l_replay.returncode==c_reverse.returncode==0 and
      c_record.stdout==l_replay.stdout==c_reverse.stdout and
      any(x.startswith('C 0 ') for x in lean_tape.read_text().splitlines())):
   raise RuntimeError(f'continuation parity: C={c_record.returncode}, Lean={l_replay.returncode}, reverse={c_reverse.returncode}')
  checked+=1

  # A raw NUL is retained by C's line reader, then truncates the C-string
  # view consumed by unescape_string.  The missing closing quote is a
  # malformed taped value (strict-replay exit 3), not a shortened string.
  raw_nul=td/'raw-nul.tape'
  raw_nul.write_bytes(f'V 8 {runtime_version()}\nB 0 1 1 0 root -\nN 0 read_line="before'.encode()+b'\0'+b'after"\n')
  nul_source=td/'raw-nul.eigs';nul_source.write_text('print of (read_line of [])\n')
  c=subprocess.run([VM,nul_source],capture_output=True,input=b'',env={**os.environ,
   'EIGS_JIT_OFF':'1','EIGS_REPLAY':str(raw_nul),'EIGS_REPLAY_STRICT':'1'})
  l=subprocess.run(ref_args(ref,'--replay',raw_nul,'--strict',nul_source),capture_output=True,input=b'')
  if c.returncode!=3 or l.returncode!=3 or b'malformed' not in c.stderr.lower() or b'kind mismatch' not in l.stderr.lower():
   raise RuntimeError(f'raw-NUL parity: C={c.returncode}/{c.stderr!r}, Lean={l.returncode}/{l.stderr!r}')
  checked+=1
  return checked
def compare(ref,lean_root,enforce=True):
 if bad:=validate_medium(ref,lean_root):raise RuntimeError('; '.join(bad))
 pc=classifier_protocol_selfcheck()
 ps=population(); actual={}; examined=roundtrips=cross=old_in=new_in=0; moved=[]; refusals=[]
 with tempfile.TemporaryDirectory() as raw:
  td=Path(raw)
  for i,(label,source) in enumerate(ps):
   p=td/f'{i}.eigs';p.write_text(source)
   a=subprocess.run([ref,'--classify',p],capture_output=True,text=True); was=classified(a,label,'--classify');old_in+=was
   a=subprocess.run([ref,'--classify-runtime',p],capture_output=True,text=True); now=classified(a,label,'--classify-runtime');new_in+=now
   if was!=now:moved.append((label,'in' if was else 'out','in' if now else 'out',a.stdout.strip()))
   if not now:continue
   examined+=1;ct=td/f'c{i}';lt=td/f'l{i}';rt=td/f'r{i}'
   c=subprocess.run([VM,p],capture_output=True,input=b'',env={**os.environ,'EIGS_JIT_OFF':'1','EIGS_TRACE':str(ct),'EIGS_PARITY_CONTROL':'\t'})
   has_n=any(k=='N' for k,_ in projection(ct))
   lean_command=ref_args(ref,'--replay',ct,'--strict','--trace',lt,p) if has_n else ref_args(ref,'--trace',lt,p)
   try:l=subprocess.run(lean_command,capture_output=True,input=b'',timeout=None if enforce else 2)
   except subprocess.TimeoutExpired:
    actual[label]='Lean timeout';continue
   if l.stderr.startswith(b'refused at runtime:'):refusals.append((label,l.stderr.decode().strip().removeprefix('refused at runtime: ')));continue
   mismatch=[]
   if c.stdout!=l.stdout:mismatch.append('stdout')
   if cls(c)!=cls(l):mismatch.append(f'exit({cls(c)}!={cls(l)})')
   if projection(ct)!=projection(lt):mismatch.append('A/N')
   try:replay=subprocess.run(ref_args(ref,'--replay',lt,'--strict','--trace',rt,p),capture_output=True,timeout=None if enforce else 2)
   except subprocess.TimeoutExpired:
    actual[label]='Lean replay timeout';continue
   if replay.stdout==l.stdout and cls(replay)==cls(l) and projection(rt)==projection(lt):roundtrips+=1
   else:mismatch.append('Lean record/replay')
   if has_n:
    # Reverse direction: the reference records from its seeded oracle and the
    # VM must consume that tape without consulting a live source.
    lean_own=td/f'lo{i}'; c_replay_tape=td/f'cr{i}'
    own=subprocess.run(ref_args(ref,'--seed','2018','--trace',lean_own,p),capture_output=True,input=b'')
    reverse=subprocess.run([VM,p],capture_output=True,input=b'',env={**os.environ,'EIGS_JIT_OFF':'1','EIGS_REPLAY':str(lean_own),'EIGS_REPLAY_STRICT':'1','EIGS_TRACE':str(c_replay_tape)})
    if reverse.stdout!=own.stdout or cls(reverse)!=cls(own) or projection(c_replay_tape)!=projection(lean_own):
     mismatch.append('Lean->C strict replay')
    cross+=1
   if mismatch:actual[label]=','.join(mismatch)
 ledger={}
 for x in (lean_root/'known_disagreements.txt').read_text().splitlines():
  if x and not x.startswith('#'):label,kind,reason=x.split('\t',2);ledger[label]=(kind,reason)
 if enforce and set(actual)!=set(ledger):raise RuntimeError(f'known-disagreement ledger mismatch\nnew={[(x,actual[x]) for x in sorted(set(actual)-set(ledger))]}\nstale={sorted(set(ledger)-set(actual))}')
 if enforce and any(k not in ('vm bug','model bug') or not r.strip() for k,r in ledger.values()):raise RuntimeError('invalid disagreement triage')
 negative=replay_refusal_cases(ref) if enforce else 0
 lines=[f'population / step1-in / modeled-in / examined: {len(ps)} / {old_in} / {new_in} / {examined}',f'agreements / disagreements: {examined-len(actual)-len(refusals)} / {len(actual)}',f'refused at runtime: {len(refusals)}']
 lines += [f'\t{x}: {why}' for x,why in refusals]+[f'Lean record->strict-replay: {roundtrips}/{examined-len(refusals)}',f'cross-implementation N programs: {cross}',f'replay edge-case parity: {negative}/5','seeded oracle: 2018',f'classifier protocol self-checks: {pc[0]}/{pc[1]}',f'classification moves: {len(moved)}']+['\t'.join(x) for x in moved]
 return ('\n'.join(lines)+'\n').encode(),actual
def replace_once(path,old,new):
 text=path.read_text()
 if text.count(old)!=1:raise RuntimeError(f'mutant anchor count {text.count(old)} in {path}')
 path.write_text(text.replace(old,new))
def selftest():
 base=ROOT/'spec/lean'
 mutants=[
  ('swap-add-sub', [('| .add => match a,b with | .int x,.int y => safeInt (x+y)',
    '| .add => match a,b with | .int x,.int y => safeInt (x-y)')]),
  ('string-eq-length', [('| .eq | .ne => match a, b with',
    '| .eq | .ne => match a, b with\n      | .string x, .string y => pure (.bool (if op == .eq then x.length == y.length else x.length != y.length))')]),
  ('drop-assignment-tape', [
    ('[structuralA s!"0 {name}={tapeValue v}"]', '[structuralA s!"0 {name}=null"]'),
    ('[structuralA s!"0 {name}={tapeValue value}"]', '[structuralA s!"0 {name}=null"]')]),
  ('consume-two-n', [('Main.lean',
    '| .ok tape => pure (.replayStrict tape)',
    '| .ok tape => pure (.replayStrict (tape.flatMap fun line => if line.startsWith "N " then [line, line] else [line]))')]),
  ('ignore-oracle', [
    ('private def oracleAnswers (oracle : List OracleValue) : List TapedAnswer :=\n  oracle.zipIdx.map fun (value, position) => .value position "" value',
     'private def oracleAnswers (oracle : List OracleValue) : List TapedAnswer :=\n  (oracle.map fun _ => .int 2).zipIdx.map fun (value, position) => .value position "" value'),
    ('wellPositioned_oracleZipIdx 0 oracle',
     'wellPositioned_oracleZipIdx 0 (oracle.map fun _ => .int 2)')])]
 killed=0
 standing={x.split('\t',1)[0] for x in (base/'known_disagreements.txt').read_text().splitlines() if x and not x.startswith('#')}
 with tempfile.TemporaryDirectory() as raw:
  for name,edits in mutants:
   copy=Path(raw)/name;shutil.copytree(base,copy,symlinks=True,ignore=shutil.ignore_patterns('.lake'))
   for edit in edits:
    if len(edit)==3:relative,old,new=edit
    else:relative=('EigenCore/Semantics.lean');old,new=edit
    replace_once(copy/relative,old,new)
   p=subprocess.run(['lake','build'],cwd=copy,capture_output=True,text=True)
   if p.returncode:
    if name=='ignore-oracle' and 'OracleTests.lean' in p.stderr+p.stdout:
     killed+=1;print(f'{name}: killed by Lean-native oracle regression');continue
    raise RuntimeError(f'{name}: mutant did not build\n{p.stdout}{p.stderr}')
   _,found=compare(copy/'.lake/build/bin/eigs-ref',copy,False)
   # A timeout keeps the full population bounded, but is not evidence that a
   # semantic fault was observed: require an actual parity difference.
   found={k:v for k,v in found.items() if 'timeout' not in v and
     (k not in standing or (name=='consume-two-n' and v!='Lean->C strict replay'))}
   if not found:raise RuntimeError(f'{name}: SURVIVED (coverage hole)')
   killed+=1;print(f'{name}: killed by '+', '.join(f'{k} ({v})' for k,v in sorted(found.items())))
 normal=base/'.lake/build/bin/eigs-ref';a,_=compare(normal,base);b,_=compare(normal,base)
 if a!=b:raise RuntimeError('A/A parity output differs')
 refused=validate_medium(VM,base)
 if not any(x.startswith('no-delegation:') for x in refused) or not any(x.startswith('medium:') for x in refused):raise RuntimeError('C-as-Lean control was not refused by both checks')
 print(f'spec-lean selftest: mutants={len(mutants)} killed={killed} determinism=ok')
def main():
 p=argparse.ArgumentParser();p.add_argument('--selftest',action='store_true');a=p.parse_args()
 try:
  if a.selftest:selftest()
  else:sys.stdout.buffer.write(compare(ROOT/'spec/lean/.lake/build/bin/eigs-ref',ROOT/'spec/lean')[0])
 except RuntimeError as e:raise SystemExit(str(e))
if __name__=='__main__':main()
