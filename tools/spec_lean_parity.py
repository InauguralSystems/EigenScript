#!/usr/bin/env python3
"""Drive C/Lean parity and continuously prove that the instrument can fail."""
from pathlib import Path
import argparse,importlib.util,os,shutil,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]; VM=ROOT/'src/eigenscript'
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
   c=subprocess.run([VM,p],capture_output=True,env={**os.environ,'EIGS_JIT_OFF':'1','EIGS_TRACE':str(ct)})
   try:l=subprocess.run([ref,'--trace',lt,p],capture_output=True,timeout=None if enforce else 2)
   except subprocess.TimeoutExpired:
    actual[label]='Lean timeout';continue
   if l.stderr.startswith(b'refused at runtime:'):refusals.append((label,l.stderr.decode().strip().removeprefix('refused at runtime: ')));continue
   mismatch=[]
   if c.stdout!=l.stdout:mismatch.append('stdout')
   if cls(c)!=cls(l):mismatch.append(f'exit({cls(c)}!={cls(l)})')
   if projection(ct)!=projection(lt):mismatch.append('A/N')
   try:replay=subprocess.run([ref,'--replay',lt,'--strict','--trace',rt,p],capture_output=True,timeout=None if enforce else 2)
   except subprocess.TimeoutExpired:
    actual[label]='Lean replay timeout';continue
   if replay.stdout==l.stdout and cls(replay)==cls(l) and projection(rt)==projection(lt):roundtrips+=1
   else:mismatch.append('Lean record/replay')
   if any(k=='N' for k,_ in projection(ct)):cross+=1
   if mismatch:actual[label]=','.join(mismatch)
 ledger={}
 for x in (lean_root/'known_disagreements.txt').read_text().splitlines():
  if x and not x.startswith('#'):label,kind,reason=x.split('\t',2);ledger[label]=(kind,reason)
 if enforce and set(actual)!=set(ledger):raise RuntimeError(f'known-disagreement ledger mismatch\nnew={[(x,actual[x]) for x in sorted(set(actual)-set(ledger))]}\nstale={sorted(set(ledger)-set(actual))}')
 if enforce and any(k not in ('vm bug','model bug') or not r.strip() for k,r in ledger.values()):raise RuntimeError('invalid disagreement triage')
 lines=[f'population / step1-in / modeled-in / examined: {len(ps)} / {old_in} / {new_in} / {examined}',f'agreements / disagreements: {examined-len(actual)-len(refusals)} / {len(actual)}',f'refused at runtime: {len(refusals)}']
 lines += [f'\t{x}: {why}' for x,why in refusals]+[f'Lean record->strict-replay: {roundtrips}/{examined-len(refusals)}',f'cross-implementation N programs: {cross}',f'classifier protocol self-checks: {pc[0]}/{pc[1]}',f'classification moves: {len(moved)}']+['\t'.join(x) for x in moved]
 return ('\n'.join(lines)+'\n').encode(),actual
def replace_once(path,old,new):
 text=path.read_text()
 if text.count(old)!=1:raise RuntimeError(f'mutant anchor count {text.count(old)} in {path}')
 path.write_text(text.replace(old,new))
def selftest():
 base=ROOT/'spec/lean'; mutants=[('swap-add-sub','| .add => match a,b with | .int x,.int y => safeInt (x+y)','| .add => match a,b with | .int x,.int y => safeInt (x-y)'),('string-eq-length','| .eq | .ne => match a, b with','| .eq | .ne => match a, b with\n      | .string x, .string y => pure (.bool (if op == .eq then x.length == y.length else x.length != y.length))'),('drop-assignment-tape','set {w with environments:=environments,tape:=w.tape ++ [s!"A 0 {name}={tapeValue v}"]}','set {w with environments:=environments}')]; killed=0
 standing={x.split('\t',1)[0] for x in (base/'known_disagreements.txt').read_text().splitlines() if x and not x.startswith('#')}
 with tempfile.TemporaryDirectory() as raw:
  for name,old,new in mutants:
   copy=Path(raw)/name;shutil.copytree(base,copy,symlinks=True,ignore=shutil.ignore_patterns('.lake'));replace_once(copy/'EigenCore/Semantics.lean',old,new)
   p=subprocess.run(['lake','build'],cwd=copy,capture_output=True,text=True)
   if p.returncode:raise RuntimeError(f'{name}: mutant did not build\n{p.stdout}{p.stderr}')
   _,found=compare(copy/'.lake/build/bin/eigs-ref',copy,False)
   # A timeout keeps the full population bounded, but is not evidence that a
   # semantic fault was observed: require an actual parity difference.
   found={k:v for k,v in found.items() if k not in standing and 'timeout' not in v}
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
