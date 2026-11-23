#!/usr/bin/env python3
import json,os,re,subprocess,sys,tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
# Stateful whole-population calls deliberately have no fixture: they can raise for
# missing state rather than type. This gate only classifies calls which answer.
WRONG={'string':'"zz_census_2509"','number':'0','dict':'{"a": 1}','list':'[]'}; MODES=(None,'0','1'); MARK='CENSUS_DONE'
def kind_of(s):
 s=s.strip(); return 'string' if s.startswith('"') else 'dict' if s.startswith('{') else 'list' if s.startswith('[') else 'number' if re.fullmatch(r'-?\d+(\.\d+)?([eE][-+]?\d+)?',s) else 'other'
def program(setup,expr): return setup+'\ntry:\n    answer is '+expr+'\n    print of ("ANSWER:" + (str of answer))\ncatch e:\n    if ((type of e) == "dict") and (has_key of [e, "kind"]):\n        print of ("ERR:" + e.kind)\n    else:\n        print of "THROWN"\nprint of "'+MARK+'"\n'
def run(binary,src,mode):
 with tempfile.TemporaryDirectory() as d:
  p=Path(d)/'p.eigs';p.write_text(src);env={k:v for k,v in os.environ.items() if not k.startswith('EIGS_')};env.update(SDL_VIDEODRIVER='dummy',SDL_AUDIODRIVER='dummy',DISPLAY='')
  if mode is not None:env['EIGS_STRICT']=mode
  try:r=subprocess.run([binary,str(p)],cwd=d,env=env,input='',capture_output=True,text=True,timeout=5)
  except subprocess.TimeoutExpired:return 'TIMEOUT'
  if MARK not in r.stdout.splitlines():return 'BROKEN'
  x=next((x for x in r.stdout.splitlines() if x.startswith(('ANSWER:','ERR:','THROWN'))),'NONE');return 'ANSWER' if x.startswith('ANSWER:') else x
def main():
 import argparse
 ap=argparse.ArgumentParser()
 ap.add_argument('--check',action='store_true'); ap.add_argument('binary'); ap.add_argument('--out')
 ns=ap.parse_args(); b=str(Path(ns.binary).resolve());api=json.loads(subprocess.run([b,'--api','--json'],capture_output=True,text=True,check=True).stdout);jobs=[]
 for n in sorted(set(api['builtins'])):
  if n!='exit':
   for k,w in WRONG.items():jobs.append((n,'whole','-',k,'',n+' of '+w))
 for c in json.loads((ROOT/'tests/strict_shape_cases.json').read_text()):
  for i,a in enumerate(c['args']):
   for k,w in WRONG.items():
    if k!=kind_of(a):
     q=list(c['args']);q[i]=w;jobs.append((c['name'],'pos',str(i),k,c.get('setup',''),c['name']+' of '+(q[0] if len(q)==1 else '['+', '.join(q)+']')))
 def one(j):return j,[run(b,program(j[4],j[5]),m) for m in MODES]
 with ThreadPoolExecutor(2) as ex: rr=list(ex.map(one,jobs))
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
 expected={}
 for line in allowed.read_text().splitlines()[1:]:
  c=line.split('\t'); expected[tuple(c[:5])]=c[5]
 actual={tuple(r[:5]) for r in rows}
 missing=set(expected)-actual; extra=actual-set(expected)
 for key in sorted(extra)[:20]: print('FAIL: unclassified silent answer:', *key)
 for key in sorted(missing)[:20]: print('FAIL: allowed row now raises:', *key)
 ok=not missing and not extra
 print(f"{'PASS' if ok else 'FAIL'}: type_errors_2509 examined={len(rr)} population={len(jobs)} answering={len(rows)} allowed={len(expected)}")
 return int(ns.check and not ok)
raise SystemExit(main())
