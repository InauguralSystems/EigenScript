#!/usr/bin/env python3
"""Inventory floating-point to C-integer conversions in ``src/`` recursively.

``src/vendor`` is excluded because it is imported, separately maintained code.  Integer
types, readers, fields and parameter types are derived from the scanned tree.  Within a
function the gate lexically follows float/double locals and values assigned from a
reader.  It records casts (including rounded expressions), integer initialisers and
assignments, and calls to tree-declared integer parameters.

This is a review ledger, not a range-proof heuristic: every (file,function) needs an
exact count and a reason describing its source bounds.  Lexical analysis cannot follow
a value passed through a pointer/aggregate to another function, or a cast hidden in an
unavailable macro body.
"""
from __future__ import annotations
import argparse,pathlib,re,subprocess,sys,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
BASE={"char","short","int","long","long long","signed","unsigned","signed char","unsigned char","signed short","unsigned short","signed int","unsigned int","signed long","unsigned long","signed long long","unsigned long long","size_t","ssize_t"}
SOURCES={"vm_number_f64","eigs_value_as_num","eigs_value_buffer_get","VAL_F64_RAW","SLOT_F64_RAW","eigs_number_read"}
def scrub(s):
 s=re.sub(r"/\*.*?\*/",lambda m:"\n"*m.group().count("\n"),s,flags=re.S);s=re.sub(r"//[^\n]*","",s);return re.sub(r'"(?:\\.|[^"\\])*"','""',s)
def source_files(src):return [p for p in src.rglob("*") if p.suffix in (".c",".h") and "vendor" not in p.relative_to(src).parts]
def split(s):
 out=[];st=d=0
 for i,c in enumerate(s):
  if c in "([{":d+=1
  elif c in ")]}":d-=1
  elif c=="," and d==0:out.append(s[st:i]);st=i+1
 out.append(s[st:]);return out
def closing(s,op):
 d=0
 for i in range(op,len(s)):
  d += (s[i]=="(")-(s[i]==")")
  if d==0:return i
 return -1
def populations(src):
 text="\n".join(scrub(p.read_text(errors="replace")) for p in source_files(src)); readers=set(SOURCES)
 readers|={n for _,n in re.findall(r"\b(double|float)\s+([A-Za-z_]\w*)\s*\(",text) if "float" in n}
 ints=set(BASE)|set(re.findall(r"\b(?:u?int\d+_t|intptr_t|uintptr_t|time_t|nfds_t|tcflag_t|useconds_t|Sint\d+|Uint\d+)\b",text));changed=True
 while changed:
  changed=False
  for body,name in re.findall(r"\btypedef\s+([^;{}]+?)\s+([A-Za-z_]\w*)\s*;",text):
   if "*" not in body and not re.search(r"\b(?:double|float)\b",body) and any(re.search(r"\b"+re.escape(t)+r"\b",body) for t in ints) and name not in ints:ints.add(name);changed=True
 return readers,ints,text
def funcs(text):
 pat=re.compile(r"(?m)^[ \t]*(?:static\s+|inline\s+|extern\s+)*[A-Za-z_]\w*(?:[ \t*]+[A-Za-z_]\w*)*[ \t*]+([A-Za-z_]\w*)\s*\([^;{}]*\)\s*\{")
 for m in pat.finditer(text):
  d=0
  for i in range(m.end()-1,len(text)):
   d += (text[i]=="{")-(text[i]=="}")
   if d==0:yield m.group(1),m.end(),i+1,text[m.end():i];break
def tp(ints):return "(?:"+"|".join(re.escape(x).replace(r"\ ",r"\s+") for x in sorted(ints,key=len,reverse=True))+")"
def isfloat(expr,floats,readers):return bool(set(re.findall(r"\b[A-Za-z_]\w*\b",expr))&(floats|readers))
def scan(src):
 readers,ints,alltext=populations(src);t=tp(ints)
 fields={n for _,n in re.findall(r"\b("+t+r")\s+([A-Za-z_]\w*)\s*(?:[;:,\[])",alltext)};params={};keywords={"if","while","for","switch","return","sizeof","defined"}
 for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\(([^{};]*)\)\s*[;{]",alltext):
  ix={i for i,p in enumerate(split(m.group(2))) if re.search(r"\b"+t+r"\b",p) and "*" not in p}
  if ix and m.group(1) not in keywords:params.setdefault(m.group(1),set()).update(ix)
 rows=[]
 for p in sorted(source_files(src)):
  if p.suffix!=".c":continue
  text=scrub(p.read_text(errors="replace"));rel=str(p.relative_to(src))
  for fn,bo,end,body in funcs(text):
   floats=set(re.findall(r"\b(?:double|float)\s+([A-Za-z_]\w*)",body));ilocal={n for _,n in re.findall(r"\b("+t+r")\s+([A-Za-z_]\w*)",body)};changed=True
   while changed:
    changed=False
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*=\s*([^;]+);",body):
     if isfloat(m.group(2),floats,readers) and m.group(1) not in floats|ilocal:floats.add(m.group(1));changed=True
   seen=set();cast_ranges=[]
   def add(m,kind,dest):
    key=(m.start(),kind)
    if key not in seen:seen.add(key);rows.append((rel,fn,text.count("\n",0,bo+m.start())+1,kind,dest))
   for m in re.finditer(r"\(\s*("+t+r")\s*\)\s*([^;,}]+)",body,re.S):
    if isfloat(m.group(2),floats,readers):add(m,"explicit cast",m.group(1));cast_ranges.append((m.start(),m.end()))
   for m in re.finditer(r"\b("+t+r")\s+([A-Za-z_]\w*)\s*=\s*([^;]+);",body,re.S):
    if isfloat(m.group(3),floats,readers) and not re.search(r"\(\s*"+t+r"\s*\)",m.group(3)):add(m,"integer initialisation",m.group(1))
   for m in re.finditer(r"(?<![=!<>])\b([A-Za-z_]\w*)(?:\s*(?:\.|->)\s*([A-Za-z_]\w*))?\s*=\s*([^;]+);",body,re.S):
    dest=m.group(2) or m.group(1)
    valid=(m.group(2) in fields) if m.group(2) else (dest in ilocal)
    # A declaration/initialiser and an explicit cast are already one conversion.
    prefix=body[max(0,m.start()-80):m.start()]
    if valid and not re.search(r"\b"+t+r"\s+$",prefix) and isfloat(m.group(3),floats,readers) and not re.search(r"\(\s*"+t+r"\s*\)",m.group(3)):add(m,"integer assignment",dest)
   for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\(",body):
    if m.group(1) not in params:continue
    close=closing(body,m.end()-1)
    if close<0:continue
    for i,a in enumerate(split(body[m.end():close])):
     if i in params[m.group(1)] and isfloat(a,floats,readers):add(m,"integer parameter",m.group(1))
 return readers,ints,rows
def run(src,allow):
 readers,ints,rows=scan(src);groups={}
 for r in rows:groups.setdefault((r[0],r[1]),[]).append(r)
 allowed={};errors=0
 if not allow.exists():print(f"num-cast: FAIL: allowlist {allow} missing");return 1
 for line in allow.read_text().splitlines():
  if not line or line.startswith("#"):continue
  ps=line.split("|",3)
  if len(ps)!=4 or not ps[3].strip():print("  FAIL: malformed allowlist row: "+line);errors+=1;continue
  try:allowed[(ps[0],ps[1])]=(int(ps[2]),ps[3])
  except ValueError:print("  FAIL: malformed allowlist count: "+line);errors+=1
 for key,rs in groups.items():
  if key not in allowed or allowed[key][0]!=len(rs):
   for r in rs:print(f"  VIOLATION: src/{r[0]}:{r[2]}: {r[1]}: {r[3]} to {r[4]}")
   errors+=1
 for key,(want,_) in allowed.items():
  got=len(groups.get(key,[]))
  if got!=want:print(f"  FAIL: stale allowlist row: {key[0]}|{key[1]} expected={want} actual={got}");errors+=1
 print(f"num-cast: examined={len(rows)} rows={len(groups)} readers={len(readers)} integer-types={len(ints)} violations={errors}");print("num-cast: PASS" if rows and not errors else "num-cast: FAIL");return 0 if rows and not errors else 1
PLANTS=[("direct","int n=(int)eigs_float_arg(a,\"\");"),("space","int n=(int) eigs_float_arg(a,\"\");"),("parentheses","int n=(int)(eigs_float_arg(a,\"\"));"),("expression","int n=(int)(eigs_float_arg(a,\"\")*2);"),("round","int n=(int)round(eigs_float_arg(a,\"\"));"),("floor","int n=(int)floor(eigs_float_arg(a,\"\"));"),("long-long","long long n=(long long)eigs_float_arg(a,\"\");"),("unsigned-int","unsigned int n=(unsigned int)eigs_float_arg(a,\"\");"),("raw","int n=(int)VAL_F64_RAW(a);"),("stored","double x=eigs_float_arg(a,\"\");int n=(int)x;"),("implicit","int n=eigs_float_arg(a,\"\");"),("parameter","take(eigs_float_arg(a,\"\"));")]
def selftest():
 with tempfile.TemporaryDirectory(prefix="num_cast_selftest.") as x:
  d=pathlib.Path(x);allow=d/"allow";allow.write_text("base.c|baseline|1|fixture value is bounded by its constant 1.0 source.\n");(d/"x.h").write_text("double eigs_float_arg(void*,const char*); void take(int);\n#define VAL_F64_RAW(x) (0.0)\n");(d/"base.c").write_text("void baseline(void){double x=1.0;int n=(int)x;(void)n;}\n")
  for name,plant in PLANTS:
   (d/"plant.c").write_text("void planted(void *a){(void)a;}\n")
   if run(d,allow):print(f"SELFTEST FAILED: {name} clean control rejected");return 1
   (d/"plant.c").write_text(f"void planted(void *a){{{plant}}}\n");cp=subprocess.run([sys.executable,__file__,"--src",str(d),"--allow",str(allow)],text=True,capture_output=True)
   if cp.returncode==0 or "src/plant.c:1: planted:" not in cp.stdout:print(f"SELFTEST FAILED: {name} plant not attributable\n{cp.stdout}");return 1
 print(f"SELFTEST OK: {len(PLANTS)} clean controls passed and plants failed at their planted lines; every detection form has a dedicated plant");return 0
def main():
 ap=argparse.ArgumentParser();ap.add_argument("--selftest",action="store_true");ap.add_argument("--src",type=pathlib.Path,default=ROOT/"src");ap.add_argument("--allow",type=pathlib.Path,default=ROOT/"tools/num_cast_allowlist.txt");a=ap.parse_args();return selftest() if a.selftest else run(a.src,a.allow)
if __name__=="__main__":raise SystemExit(main())
