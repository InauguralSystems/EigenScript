#!/usr/bin/env python3
"""Classify Clang's complete floating-to-C-integer conversion population.

The population is every ``FloatingToIntegral`` node emitted by Clang for every
translation unit in the Makefile's hosted release, server, server-db, and zlib
profiles.  ``FloatingToBoolean``, integer-to-integer narrowing, code compiled by
no hosted profile, and values stored in a union then read through an integer
member are deliberately outside this gate.  This program does not parse C.
"""
from __future__ import annotations
import argparse, collections, pathlib, re, shlex, shutil, subprocess, sys, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
PROFILES=("release","server","server-db","zlib")
# Top-level C files which no hosted binary profile compiles.
UNHOSTED={"embed_concurrent.c":"standalone embedding test", "embed_smoke.c":"standalone embedding test", "eigenlsp.c":"LSP executable", "eigsdap.c":"DAP executable", "jit_smoke.c":"standalone JIT test", "embed_roads.c":"standalone embedding test"}
NODE=re.compile(r"(?:^|[-|` ])(FunctionDecl|ConstantExpr|CStyleCastExpr|ImplicitCastExpr|BinaryOperator|CompoundAssignOperator|CallExpr|ReturnStmt|ArraySubscriptExpr)\b")
KIND=re.compile(r"'([^']+)'\s+<FloatingToIntegral>")
FN=re.compile(r"FunctionDecl.*\b([A-Za-z_]\w*)\s+'")
LOC=re.compile(r"(?:(?:[^ <>,]+/)?src/([^:>,]+):)?(?:line:)?(\d+):(\d+)")

def makevar(name):
 p=subprocess.run(["make","--no-print-directory","print-"+name],cwd=ROOT,text=True,capture_output=True)
 if p.returncode: raise RuntimeError(p.stderr.strip() or "make failed")
 return p.stdout.strip()
def commands():
 out=[]
 for profile in PROFILES:
  srcs=makevar("SRC_V_"+profile).split(); flags=shlex.split(makevar("FLAGS_"+profile))
  flags=[('-DEIGENSCRIPT_VERSION="'+x.split("=",1)[1]+'"') if x.startswith("-DEIGENSCRIPT_VERSION=") else x for x in flags]
  for src in srcs:
   if src.startswith("src/vendor/"): continue
   out.append((profile,src,flags))
 compiled={pathlib.Path(s).name for _,s,_ in out}
 actual={p.name for p in (ROOT/"src").glob("*.c")}
 unknown=actual-compiled-set(UNHOSTED)
 stale=set(UNHOSTED)-actual
 if unknown or stale: raise RuntimeError(f"source coverage mismatch: unclassified={sorted(unknown)} stale-exclusions={sorted(stale)}")
 return out

def depth(line):
 i=line.find(next((x for x in ("FunctionDecl","ConstantExpr","CStyleCastExpr","ImplicitCastExpr","BinaryOperator","CompoundAssignOperator","CallExpr","ReturnStmt","ArraySubscriptExpr") if x in line),""))
 return max(0,i//2)
def location(line,parent,src):
 # Prefer an explicit src path; otherwise line:/col: coordinates inherit file/line.
 m=re.search(r"(?:^|[ <,])(?:[^ <>,]+/)?src/([^:>,]+):(\d+):(\d+)",line)
 if m:return (m.group(1),int(m.group(2)),int(m.group(3)))
 ml=re.search(r"\bline:(\d+):(\d+)",line)
 if ml:return (parent[0] if parent else src.removeprefix("src/"),int(ml.group(1)),int(ml.group(2)))
 mc=re.search(r"\bcol:(\d+)",line)
 return ((parent[0],parent[1],int(mc.group(1))) if parent and mc else parent or (src.removeprefix("src/"),1,1))
def ast(profile,src,flags):
 cmd=["clang",*flags,"-Wno-error","-fsyntax-only","-Xclang","-ast-dump",src]
 p=subprocess.Popen(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 stack=[]; raw=0; rows=[]
 assert p.stdout
 for line in p.stdout:
  if "<FloatingToIntegral>" not in line and not NODE.search(line): continue
  d=depth(line)
  while stack and stack[-1][0]>=d:stack.pop()
  parent=stack[-1][2] if stack else None; loc=location(line,parent,src)
  fm=FN.search(line); fn=fm.group(1) if fm else next((x[3] for x in reversed(stack) if x[3]),"<global>")
  constant=any(x[1]=="ConstantExpr" for x in stack)
  km=KIND.search(line)
  compound=("CompoundAssignOperator" in line and "ComputeResultTy='double'" in line and re.search(r"CompoundAssignOperator.*?'([^']+)'",line))
  if compound and compound.group(1) in ("double","float","long double"): compound=None
  if km or compound:
   raw+=1; dest=km.group(1) if km else compound.group(1)
   rows.append({"profile":profile,"file":loc[0],"line":loc[1],"col":loc[2],"function":fn,"dest":dest,"source":"floating","constant":constant})
  nm=NODE.search(line)
  if nm:stack.append((d,nm.group(1),loc,fn if nm.group(1)=="FunctionDecl" else None))
 err=p.stderr.read(); rc=p.wait()
 if rc: raise RuntimeError(f"clang failed for {profile}:{src}: {err.strip().splitlines()[-1] if err.strip() else rc}")
 return rows,raw

def allow_rows(path):
 rows={}; readers={}
 for n,line in enumerate(path.read_text().splitlines(),1):
  if not line or line.startswith("#"):continue
  p=line.split("|",4)
  if p[0]=="reader" and len(p)==4: readers[p[1]]=(int(p[2]),p[3])
  elif p[0]=="guarded" and len(p)==5 and p[4].startswith("guard="): rows[(p[1],p[2])]=(int(p[3]),p[4][6:])
  else:raise RuntimeError(f"malformed allowlist line {n}: {line}")
 return readers,rows

def run(allow):
 if not shutil.which("clang"):print("num-cast: clang is required",file=sys.stderr);return 2
 try: cmds=commands(); readers,guarded=allow_rows(allow)
 except (RuntimeError,ValueError) as e:print("num-cast: FAIL:",e);return 1
 allrows=[]; raw=0
 try:
  for profile,src,flags in cmds:
   rs,n=ast(profile,src,flags);allrows+=rs;raw+=n
 except RuntimeError as e:print("num-cast: FAIL:",e);return 1
 errors=0; classes=collections.Counter(); groups=collections.defaultdict(list)
 for r in allrows:groups[(r["file"],r["function"])].append(r)
 for key,rs in groups.items():
  fn=key[1]
  if all(r["constant"] for r in rs):classes["constant"]+=len(rs);continue
  table=readers.get(fn); guard=guarded.get(key)
  if table:
   want,text=table; source=(ROOT/"src"/key[0]).read_text()
   if len(rs)!=want or text not in source:print(f"  FAIL: stale reader row: {fn} expected={want} actual={len(rs)} test={text!r}");errors+=1
   else:classes["reader"]+=len(rs)
  elif guard:
   want,text=guard; source=(ROOT/"src"/key[0]).read_text(); first=min(r["line"] for r in rs); before="\n".join(source.splitlines()[:first-1])
   if len(rs)!=want or text not in before:print(f"  FAIL: stale guarded row: {key[0]}|{fn} expected={want} actual={len(rs)} guard={text!r}");errors+=1
   else:classes["guarded"]+=len(rs)
  else:
   for r in rs:print(f"  VIOLATION: src/{r['file']}:{r['line']}:{r['col']}: {fn}: {r['source']} -> {r['dest']}")
   classes["violation"]+=len(rs);errors+=len(rs)
 for key,(want,_) in guarded.items():
  if len(groups.get(key,[]))!=want:print(f"  FAIL: stale guarded row: {key[0]}|{key[1]} expected={want} actual={len(groups.get(key,[]))}");errors+=1
 for fn,(want,_) in readers.items():
  got=sum(len(v) for k,v in groups.items() if k[1]==fn)
  if got!=want:print(f"  FAIL: stale reader row: {fn} expected={want} actual={got}");errors+=1
 if raw!=len(allrows):print(f"  FAIL: independent raw count={raw} parsed={len(allrows)}");errors+=1
 print(f"num-cast: translation-units={len(cmds)} conversions={len(allrows)} raw={raw} reader={classes['reader']} guarded={classes['guarded']} constant={classes['constant']} violations={classes['violation']}")
 print("num-cast: PASS" if not errors else "num-cast: FAIL");return 0 if not errors else 1

def selftest():
 plants=[
  ("second-declarator","double f(void); void planted(void){double z=0,y=f(); int c=(int)y;(void)z;(void)c;}",1),
  ("libc-argument","#include <stdlib.h>\ndouble f(void); void planted(void){exit(f());}",1),
  ("compound","double f(void); void planted(void){int c=0;c+=f();}",1),
  ("double-parameter","static int helper(double x){return (int)x;}",1),
  ("implicit-return","double f(void); static int planted(void){return f();}",1),
  ("second-cast","double f(void); void planted(void){int c=(int)f()+(int)f();(void)c;}",2),
  ("after-comment-string","double f(void); void planted(void){const char*s=\"// /*\";char q='\"';int c=(int)f();(void)s;(void)q;(void)c;}",1),
  ("shadow-no-conversion","double f(void); void planted(void){int n=0;{double n=f();(void)n;}(void)n;}",0)]
 with tempfile.TemporaryDirectory(prefix="num_cast_ast.") as td:
  d=pathlib.Path(td); caught=0;clean=0
  for name,body,expect in plants:
   for src,want in (("int main(void){return 0;}\n",0),(body+"\n",expect)):
    p=d/"x.c";p.write_text(src);cp=subprocess.run(["clang","-fsyntax-only","-Xclang","-ast-dump",str(p)],text=True,capture_output=True)
    n=cp.stdout.count("<FloatingToIntegral>")+sum("CompoundAssignOperator" in x and "ComputeResultTy='double'" in x for x in cp.stdout.splitlines())
    if n!=want:print(f"SELFTEST FAILED: {name} wanted={want} got={n}");return 1
   clean+=1;caught+=expect
 print(f"SELFTEST OK: {clean} clean controls; {caught} conversion plants red at compiler nodes; 1 shadow control clean; ledger mutations NOT-REACHED")
 return 0

def main():
 ap=argparse.ArgumentParser();ap.add_argument("--selftest",action="store_true");ap.add_argument("--allow",type=pathlib.Path,default=ROOT/"tools/num_cast_allowlist.txt");a=ap.parse_args();return selftest() if a.selftest else run(a.allow)
if __name__=="__main__":raise SystemExit(main())
