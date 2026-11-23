#!/usr/bin/env python3
import json,os,re,subprocess,tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
# Stateful whole-population calls deliberately have no fixture: they can raise for
# missing state rather than type. This gate only classifies calls which answer.
WRONG={'string':'"zz_census_2509"','number':'0','dict':'{"a": 1}','list':'[]'}; MODES=(None,'0','1'); MARK='CENSUS_DONE'
def kind_of(s):
 s=s.strip(); return 'string' if s.startswith('"') else 'dict' if s.startswith('{') else 'list' if s.startswith('[') else 'number' if re.fullmatch(r'-?\d+(\.\d+)?([eE][-+]?\d+)?',s) else 'other'
def program(setup,expr): return setup+'\ntry:\n    answer is '+expr+'\n    print of ("ANSWER:" + (str of answer))\ncatch e:\n    if ((type of e) == "dict") and (has_key of [e, "kind"]):\n        print of ("ERR:" + e.kind)\n        print of ("MSG:" + e.message)\n    else:\n        print of "THROWN"\nprint of "'+MARK+'"\n'
def run(binary,src,mode):
 with tempfile.TemporaryDirectory() as d:
  # Placeholders of tests/strict_shape_cases.json: @TMP@ is the probe's folder, @WAV@ a
  # tiny WAV written there, @DESCRIPTOR@ a source string (sandbox_run's documented
  # [source, ...] form; each limit position is tested the same either way). A placeholder
  # left over means the probe never reached its builtin: UNEXPANDED, never a pass.
  if '@WAV@' in src:
   import wave
   with wave.open(str(Path(d)/'sample.wav'),'wb') as w:
    w.setnchannels(1);w.setsampwidth(2);w.setframerate(44100);w.writeframes(b'\0\0'*32)
  src=src.replace('@TMP@',d).replace('@WAV@',str(Path(d)/'sample.wav')).replace('@DESCRIPTOR@','"return 42"')
  if re.search(r'@[A-Z_]+@',src):return 'UNEXPANDED'
  p=Path(d)/'p.eigs';p.write_text(src);env={k:v for k,v in os.environ.items() if not k.startswith('EIGS_')};env.update(SDL_VIDEODRIVER='dummy',SDL_AUDIODRIVER='dummy',DISPLAY='')
  if mode is not None:env['EIGS_STRICT']=mode
  try:r=subprocess.run([binary,str(p)],cwd=d,env=env,input='',capture_output=True,text=True,timeout=5)
  except subprocess.TimeoutExpired:return 'TIMEOUT'
  combined=r.stdout+'\n'+r.stderr
  hard=re.search(r'AddressSanitizer: (?!.*byte\(s\) leaked)|UndefinedBehaviorSanitizer|runtime error:|ThreadSanitizer|MemorySanitizer',combined)
  match=re.search(r'(ANSWER:|ERR:|THROWN)([^\n]*)',r.stdout)
  x=match.group(0) if match else 'NONE'
  lines=r.stdout.splitlines()
  if hard or ((MARK not in lines or r.returncode != 0) and x.startswith('ANSWER:')):return 'BROKEN'
  if MARK not in lines:return 'UNREACHED'
  if r.returncode != 0:return 'BROKEN'
  # A build without an extension registers stubs that raise one capability message.
  if x.startswith('ERR:') and re.search(r'^MSG:.*(capability unavailable|unavailable in this build)',r.stdout,re.M):return 'STUB'
  return 'ANSWER' if x.startswith('ANSWER:') else x
def main():
 import argparse
 ap=argparse.ArgumentParser()
 ap.add_argument('--check',action='store_true'); ap.add_argument('binary'); ap.add_argument('--out')
 ns=ap.parse_args(); b=str(Path(ns.binary).resolve());api=json.loads(subprocess.run([b,'--api','--json'],capture_output=True,text=True,check=True).stdout);jobs=[]
 for n in sorted(set(api['builtins'])):
  if n!='exit':
   for k,w in WRONG.items():jobs.append((n,'whole','-',k,'',n+' of '+w))
 # A case runs only when its builtin is in this binary (gfx, http and the
 # other extensions are optional builds); allowed rows of absent builtins are not expected.
 present=set(api['builtins'])|{x for v in api.get('extensions',{}).values() for x in v}
 for c in json.loads((ROOT/'tests/strict_shape_cases.json').read_text()):
  if c['name'] not in present: continue
  for i,a in enumerate(c['args']):
   for k,w in WRONG.items():
    if k!=kind_of(a):
     q=list(c['args']);q[i]=w;jobs.append((c['name'],'pos',str(i),k,c.get('setup',''),c['name']+' of '+(q[0] if len(q)==1 else '['+', '.join(q)+']')))
 def one(j):return j,[run(b,program(j[4],j[5]),m) for m in MODES]
 with ThreadPoolExecutor(1) as ex: rr=list(ex.map(one,jobs))
 # A probe that never reached its builtin (UNREACHED: setup failed; UNEXPANDED: a
 # placeholder the census cannot fill) is SKIPPED only for a builtin named, with its
 # reason, in tests/type_errors_2509_fixture_skip.tsv. Anywhere else it fails the gate.
 fixture_skip={l.split('\t')[0] for l in (ROOT/'tests/type_errors_2509_fixture_skip.tsv').read_text().splitlines()[1:] if l}
 never={tuple(j[:4])+(j[5],) for j,v in rr if all(x in ('UNREACHED','UNEXPANDED') for x in v)}
 skipped={k for k in never if k[0] in fixture_skip}
 unreached_bad=sorted(never-skipped)
 required=[]
 for line in (ROOT/'tests/type_errors_2509_required.tsv').read_text().splitlines()[1:]:
  name,setup,expr=line.split('\t'); setup=setup.replace('\\n','\n')
  required.append(((name,'required','-','-',expr),[run(b,program(setup,expr),m) for m in MODES]))
 out=Path(ns.out) if ns.out else None
 rows=[]
 for j,v in rr:
  if any(x=='ANSWER' for x in v): rows.append((*j[:4],j[5],*v))
 assert len(rr)==len(jobs)>0
 if out:
  f=out.open('w')
 else:
  f=open(os.devnull,'w')
 with f:
  f.write('builtin\tpop\tpos\twrong\texpr\tunset\ts0\ts1\n')
  for j,v in rr:f.write('\t'.join([j[0],j[1],j[2],j[3],j[5],*v])+'\n')
 allowed=ROOT/'tests/type_errors_2509_allowed.tsv'
 expected={}; docs=(ROOT/'docs/BUILTINS.md').read_text()
 doc_rows={m.group(1):m.group(0) for m in re.finditer(r'^\| `([^`]+)` \|.*$',docs,re.M)}
 # A reason quotes a recognised part of the builtin's own row: its whole signature cell,
 # one backticked form of that cell, or one whole sentence of its description. A
 # fragment such as '| `usleep` |' or a few words out of a sentence is not a reason.
 def doc_fragments(row):
  cells=[c.strip() for c in row.strip().strip('|').split(' | ')]
  if len(cells)<3: return set()
  sig=cells[1]; desc=' | '.join(cells[2:])
  out={sig}|set(re.findall(r'`[^`]+`',sig))
  out|={x.strip() for x in re.split(r'(?<=[.;])\s+',desc) if x.strip()}
  return out
 reason_ok=True
 for line in allowed.read_text().splitlines()[1:]:
  c=line.split('\t'); key=tuple(c[:5]); reason=c[5] if len(c)>5 else ''
  if reason.startswith(('ANY: ', 'KIND: ')):
   quote=reason.split(': ',1)[1]
   valid=quote in doc_fragments(doc_rows.get(c[0],''))
  elif reason.startswith('IGNORED: '):
   quote=reason.split(': ',1)[1]; valid=quote == c[0]+' of null' and quote in doc_rows.get(c[0],'')
  else: valid=False
  if not valid:
   print('FAIL: invalid allowed-row classification:', *key, reason)
   reason_ok=False
  if c[0] in present: expected[key]=reason
 other={}
 other_path=ROOT/'tests/type_errors_2509_other_kind.tsv'
 for line in other_path.read_text().splitlines()[1:]:
  c=line.split('\t'); key=tuple(c[:5]); kind=c[5]; quote=c[6]
  if not quote or quote not in doc_rows.get(c[0],''):
   print('FAIL: invalid other-kind classification:',*key,kind,quote); reason_ok=False
  other[key]=kind
 broken={tuple(j[:4])+(j[5],) for j,v in rr if any(x=='BROKEN' for x in v)}
 for key in sorted(broken)[:20]: print('FAIL: broken probe:', *key)
 actual={tuple(r[:5]) for r in rows}
 # A builtin that is a stub on every probe is not in this build: its rows are not expected.
 ext_names={x for v in api.get('extensions',{}).values() for x in v}
 stub_names={n for n in {j[0] for j,v in rr} & ext_names if all(x=='STUB' for j,v in rr if j[0]==n for x in v)}
 expected={k:v for k,v in expected.items() if k[0] not in stub_names}
 missing=set(expected)-actual-skipped; extra=actual-set(expected)
 # An allowed answer is never a type error in another EIGS_STRICT state (the
 # IEEE trap, kind value under EIGS_STRICT=1, is the one state-dependent raise).
 mixed=[(tuple(r[:5]),r[5:]) for r in rows if any(x not in ('ANSWER','ERR:value') for x in r[5:])]
 unreached={tuple(j[:4])+(j[5],) for j,v in rr if any(x=='UNREACHED' for x in v)}
 reached_pin={tuple(line.split('\t')) for line in
              (ROOT/'tests/type_errors_2509_reached.tsv').read_text().splitlines()[1:]}
 newly_unreached=(reached_pin & unreached)-skipped
 wrong_kind=[]
 for j,v in rr:
  key=tuple(j[:4])+(j[5],)
  if key in actual or key in unreached or key in never or j[0] in stub_names: continue
  allowed_kind=other.get(key,'type_mismatch')
  wanted='THROWN' if allowed_kind == 'THROWN' else 'ERR:'+allowed_kind
  # type_mismatch is always right for a wrong-typed argument; an other-kind row adds one more
  # accepted kind (a capability stub raises value on a build without the extension).
  if any(x not in (wanted,'ERR:type_mismatch') for x in v): wrong_kind.append((key,v,allowed_kind))
 required_bad=[(j,v) for j,v in required if any(x!='ERR:type_mismatch' for x in v)]
 for key in sorted(extra)[:20]: print('FAIL: unclassified silent answer:', *key)
 for key in sorted(missing)[:20]: print('FAIL: allowed row now raises:', *key)
 for key in sorted((set(expected)&unreached)-skipped)[:20]: print('FAIL: previously reached allowed row is now UNREACHED:',*key)
 for key in sorted(newly_unreached)[:20]: print('FAIL: committed REACHED row is now UNREACHED:',*key)
 for key,v,kind in wrong_kind[:20]: print('FAIL: wrong error kind:',*key,'expected='+kind,'actual='+','.join(v))
 for key,v in mixed[:20]: print('FAIL: answer depends on EIGS_STRICT:',*key,'results='+','.join(v))
 for key in sorted(skipped)[:20]: print('SKIP: fixture unavailable here:',*key)
 for key,v in required_bad: print('FAIL: required type mismatch:',*key,'actual='+','.join(v))
 for key in unreached_bad[:20]: print('FAIL: probe never reached its builtin (not in the fixture list):',*key)
 ok=not unreached_bad and not mixed and not missing and not extra and not broken and not newly_unreached and not wrong_kind and not required_bad and reason_ok
 print(f"{'PASS' if ok else 'FAIL'}: type_errors_2509 examined={len(rr)} population={len(jobs)} answering={len(rows)} allowed={len(expected)} unreached={len(unreached)} skipped={len(skipped)} stub_builtins={len(stub_names)}")
 return int(ns.check and not ok)
raise SystemExit(main())
