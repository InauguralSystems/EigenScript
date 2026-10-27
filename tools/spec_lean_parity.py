#!/usr/bin/env python3
"""Drive (never implement) C/Lean EigenCore parity on the derived corpus."""
from pathlib import Path
import importlib.util, os, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]; REF=ROOT/'spec/lean/.lake/build/bin/eigs-ref'; VM=ROOT/'src/eigenscript'
spec=importlib.util.spec_from_file_location('doc_examples',ROOT/'tests/test_doc_examples.py'); docs=importlib.util.module_from_spec(spec); spec.loader.exec_module(docs)
programs=[]
for rel in docs.POPULATION:
  for line,info,args,source in docs.blocks(str(ROOT/rel)):
    kind,_payload,error=docs.parse_tag(args)
    if error: raise SystemExit(f'{rel}:{line}: {error}')
    if info=='eigenscript' and kind in ('','check'): programs.append((f'{rel}:{line}',source))
tracked=subprocess.check_output(['git','ls-files','tests','examples'],cwd=ROOT,text=True).splitlines()
for rel in tracked:
  if rel.endswith('.eigs'): programs.append((rel,(ROOT/rel).read_text()))
# Review regressions are a source-derived population too: every tracked case
# is enrolled automatically, so adding a case cannot forget a hand-maintained
# manifest entry.
parity_cases=subprocess.check_output(['git','ls-files','spec/lean/parity_cases/*.eigs'],cwd=ROOT,text=True).splitlines()
for rel in parity_cases: programs.append((rel,(ROOT/rel).read_text()))

def cls(p):
  if p.returncode==0:return 'success'
  err=p.stderr.decode(errors='replace') if isinstance(p.stderr,bytes) else p.stderr
  if 'Parse error' in err or 'parse error' in err:return 'parse/compile error'
  return 'runtime error'
def classifier_verdict(p,label,command):
  output=p.stdout.strip()
  if p.returncode != 0:
    raise SystemExit(f'{command} failed for {label} (exit {p.returncode}): {p.stderr.strip()}')
  if output == 'in-subset': return True
  if output.startswith('out: ') and ' at line ' in output: return False
  raise SystemExit(f'{command} produced malformed verdict for {label}: {output!r}')
def classifier_protocol_selfcheck():
  bad=[subprocess.CompletedProcess([],1,'','crash'),
       subprocess.CompletedProcess([],0,'',''),
       subprocess.CompletedProcess([],0,'maybe','')]
  rejected=0
  for result in bad:
    try: classifier_verdict(result,'self-check','--classify-runtime')
    except SystemExit: rejected+=1
  if rejected != len(bad): raise SystemExit('classifier protocol self-check failed')
  return rejected
protocol_checks=classifier_protocol_selfcheck()
def projection(path):
  if not path.exists(): return []
  out=[]
  for line in path.read_text(errors='replace').splitlines():
    fields=line.split(' ',2)
    if fields and fields[0] in ('A','N'): out.append((fields[0],fields[-1]))
  return out
ledger={}
for raw in (ROOT/'spec/lean/known_disagreements.txt').read_text().splitlines():
  if raw and not raw.startswith('#'):
    label,kind,reason=raw.split('\t',2); ledger[label]=(kind,reason)
actual={}; examined=roundtrips=cross=0; old_in=0; new_in=0; moved=[]; refusals=[]
with tempfile.TemporaryDirectory() as td:
  td=Path(td)
  for i,(label,source) in enumerate(programs):
    p=td/f'{i}.eigs'; p.write_text(source)
    old=subprocess.run([REF,'--classify',p],capture_output=True,text=True)
    was=classifier_verdict(old,label,'--classify'); old_in+=was
    new=subprocess.run([REF,'--classify-runtime',p],capture_output=True,text=True)
    now=classifier_verdict(new,label,'--classify-runtime'); new_in+=now
    if was != now: moved.append((label,'in' if was else 'out','in' if now else 'out',new.stdout.strip()))
    if not now: continue
    examined+=1; ct=td/f'c{i}.tape'; lt=td/f'l{i}.tape'; rt=td/f'r{i}.tape'
    env={**os.environ,'EIGS_JIT_OFF':'1','EIGS_TRACE':str(ct)}
    c=subprocess.run([VM,p],capture_output=True,env=env)
    l=subprocess.run([REF,'--trace',lt,p],capture_output=True)
    if l.stderr.startswith(b'refused at runtime:'):
      refusals.append((label,l.stderr.decode().strip().removeprefix('refused at runtime: ')))
      continue
    mismatch=[]
    if c.stdout!=l.stdout:mismatch.append('stdout')
    if cls(c)!=cls(l):mismatch.append(f'exit({cls(c)}!={cls(l)})')
    if projection(ct)!=projection(lt):mismatch.append('A/N')
    replay=subprocess.run([REF,'--replay',lt,'--strict','--trace',rt,p],capture_output=True)
    if replay.stdout==l.stdout and cls(replay)==cls(l) and projection(rt)==projection(lt): roundtrips+=1
    else:mismatch.append('Lean record/replay')
    if any(k=='N' for k,_ in projection(ct)):
      cross+=1
    if mismatch: actual[label]=','.join(mismatch)
if set(actual)!=set(ledger):
  missing=sorted(set(actual)-set(ledger)); stale=sorted(set(ledger)-set(actual))
  raise SystemExit(f'known-disagreement ledger mismatch\nnew={[(x,actual[x]) for x in missing]}\nstale={stale}')
for label,(kind,reason) in ledger.items():
  if kind not in ('vm bug','model bug') or not reason.strip():
    raise SystemExit(f'invalid disagreement triage: {label}: {kind}: {reason}')
print(f'population / step1-in / modeled-in / examined: {len(programs)} / {old_in} / {new_in} / {examined}')
print(f'agreements / disagreements: {examined-len(actual)-len(refusals)} / {len(actual)}')
print(f'refused at runtime: {len(refusals)}')
for label, reason in refusals: print(f'\t{label}: {reason}')
print(f'Lean record->strict-replay: {roundtrips}/{examined-len(refusals)}')
print(f'cross-implementation N programs: {cross}')
print(f'classifier protocol self-checks: {protocol_checks}/{protocol_checks}')
print(f'classification moves: {len(moved)}')
for row in moved: print('\t'.join(row))
