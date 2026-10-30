#!/usr/bin/env python3
"""Derive EigenCore declarations and reject axioms outside the allowed set."""
from pathlib import Path
import re,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]; LEAN=ROOT/'spec/lean'
# Explicit theorem/lemma declarations are source-derived. Compiler-generated
# implementation theorems are deliberately excluded from the public proof API.
names=[]
for path in sorted((LEAN/'EigenCore').glob('*.lean'))+[LEAN/'EigenCore.lean']:
 text=re.sub(r'/-.*?-/','',path.read_text(),flags=re.S)
 depth=[]
 for line in text.splitlines():
  if m:=re.match(r'\s*namespace\s+([\w.]+)',line):depth.append(m.group(1));continue
  # `mutual` and `section` are closed by `end` too; without their own scope
  # marker, the `end` of a mutual block popped the enclosing namespace and
  # every later theorem fell outside `EigenCore.`, silently unchecked
  # (runCore_deterministic, 2026-10-28).
  if re.match(r'\s*(?:mutual|section)\b',line):depth.append(None);continue
  if re.match(r'\s*end(?:\s|$)',line):
   if depth:depth.pop()
   continue
  if m:=re.match(r'\s*(?:private\s+)?(?:theorem|lemma)\s+([\w.]+)',line):
   prefix='.'.join(x for x in depth if x); name=m.group(1); full=name if name.startswith('EigenCore.') else '.'.join(x for x in (prefix,name) if x)
   if full.startswith('EigenCore.'):names.append(full)
names=sorted(set(names))
if not names:sys.exit('axiom gate: derived theorem population is empty')
# Both directions: every theorem/lemma written in these sources must be in the
# population. A scope the parser misreads drops theorems silently otherwise.
declared=set()
for path in sorted((LEAN/'EigenCore').glob('*.lean'))+[LEAN/'EigenCore.lean']:
 for m in re.finditer(r'^\s*(?:private\s+)?(?:theorem|lemma)\s+([\w.]+)',re.sub(r'/-.*?-/','',path.read_text(),flags=re.S),re.M):
  declared.add(m.group(1).split('.')[-1])
missing=sorted(declared-{n.split('.')[-1] for n in names})
if missing:sys.exit(f'axiom gate: declared theorem(s) outside the derived population: {missing}')
definitions=['EigenCore.evalExpr','EigenCore.run','EigenCore.tapeSerialize','EigenCore.tapeParse']
with tempfile.NamedTemporaryFile('w',suffix='.lean',dir=LEAN/'Tests',delete=False) as f:
 check=Path(f.name);f.write('import EigenCore\n'+''.join(f'#print axioms {x}\n' for x in names+definitions))
try:p=subprocess.run(['lake','env','lean',str(check.relative_to(LEAN))],cwd=LEAN,text=True,capture_output=True)
finally:check.unlink(missing_ok=True)
out=p.stdout+p.stderr
if p.returncode:print(out,end='',file=sys.stderr);sys.exit(p.returncode)
allowed={'propext','Classical.choice','Quot.sound'}
reports=re.findall(r'(?:depends on )?axioms:\s*\[([^]]*)\]',out)
empty=len(re.findall(r'does not depend on any axioms',out))
if len(reports)+empty!=len(names)+len(definitions):sys.exit(f'axiom gate: expected {len(names)+len(definitions)} reports, got {len(reports)+empty}')
seen={a.strip() for report in reports for a in report.split(',') if a.strip()};unexpected=seen-allowed
if unexpected:sys.exit('axiom gate: unexpected axioms: '+', '.join(sorted(unexpected)))
print(f'axiom gate: {len(names)} derived theorem(s), {len(definitions)} evaluator/serializer definition(s), allowed axioms only')
