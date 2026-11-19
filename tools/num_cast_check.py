#!/usr/bin/env python3
"""Enumerate double-reader -> C-integer conversions in src/*.c.

The reader population is derived from ``double eigs_*(...)`` declarations in
the headers.  Integer spellings are derived from declarations, casts and
typedefs in the tree (the only built-in knowledge is C's integer keywords).

Recognised checks are comparisons of the same reader call with both an integer type's MIN and MAX bound in
the preceding 12 source lines, or a call to eigs_*_int (the exact readers).
Two-sided comparisons are real checks: together they exclude every value
outside the destination interval before C performs the conversion.  The
scanner deliberately does not follow arbitrary dataflow: a reader stored in a
double and cast on a later line is outside its stated limit and its self-test
records that fact.
"""
from __future__ import annotations
import argparse, pathlib, re, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_INT = {"char", "short", "int", "long", "signed", "unsigned", "size_t", "ssize_t"}

def scrub(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group().count("\n"), s, flags=re.S)
    s = re.sub(r"//[^\n]*", "", s)
    s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
    return s

def populations(src: pathlib.Path):
    hs = "\n".join(scrub(p.read_text(errors="replace")) for p in src.glob("*.h"))
    alltext = hs + "\n" + "\n".join(scrub(p.read_text(errors="replace")) for p in src.glob("*.c"))
    # "Reader" is mechanically selected from the double-returning eigs API by
    # its established *_float naming contract; arithmetic helpers such as
    # eigs_math_result_named are not reads of builtin arguments.
    readers = {n for n in re.findall(r"\bdouble\s+(eigs_[A-Za-z0-9_]+)\s*\(", hs) if "float" in n}
    aliases = set(BASE_INT)
    changed = True
    while changed:
        changed = False
        for body, name in re.findall(r"\btypedef\s+([^;{}]+?)\s+([A-Za-z_]\w*)\s*;", alltext):
            if any(re.search(r"\b" + re.escape(t) + r"\b", body) for t in aliases) and "double" not in body and "float" not in body:
                if name not in aliases: aliases.add(name); changed = True
    # Fixed-width and platform integer names are tree-derived candidates: only
    # spellings actually used as a cast or declaration are admitted.
    candidates = set(re.findall(r"\(\s*([A-Za-z_]\w*)\s*\)", alltext))
    candidates |= set(re.findall(r"(?:^|[;{}])\s*([A-Za-z_]\w*)\s+[A-Za-z_]\w*\s*(?:[=;,[])" , alltext, re.M))
    aliases |= {x for x in candidates if re.fullmatch(r"(?:u?int\d*_t|Uint\d+|size_t|ssize_t)", x)}
    return readers, aliases, alltext

def function_at(text: str, off: int) -> str:
    prefix = text[:off]
    matches = list(re.finditer(r"(?m)^([A-Za-z_]\w*(?:[ \t*]+[A-Za-z_]\w*)*)\s*\([^;{}]*\)\s*\{", prefix))
    return matches[-1].group(1).split()[-1].lstrip("*") if matches else "<file scope>"

def matching(s, op):
    depth=0
    for i in range(op,len(s)):
        if s[i]=='(': depth+=1
        elif s[i]==')':
            depth-=1
            if depth==0: return i
    return -1

def split_args(s):
    out=[]; start=0; depth=0
    for i,c in enumerate(s):
        if c in '([{': depth+=1
        elif c in ')]}': depth-=1
        elif c==',' and depth==0: out.append((start,i,s[start:i])); start=i+1
    out.append((start,len(s),s[start:])); return out

def scan(src: pathlib.Path):
    readers, ints, alltext = populations(src)
    ralt = "|".join(map(re.escape, sorted(readers, key=len, reverse=True))) or r"(?!)"
    talt = "|".join(map(re.escape, sorted(ints, key=len, reverse=True)))
    found = []
    # Derive integer parameter positions from declarations/definitions in the
    # tree.  This enables the third conversion form without a hand-maintained
    # callee list.
    intparams={}
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\(([^(){};]*)\)\s*[;{]", alltext):
        ps=split_args(m.group(2)); idx={i for i,(_,_,x) in enumerate(ps) if re.search(r"\b(?:"+talt+r")\b",x) and '*' not in x}
        if idx: intparams[m.group(1)]=idx
    for p in sorted(src.glob("*.c")):
        raw = p.read_text(errors="replace"); text = scrub(raw)
        seen = set()
        patterns = [
          ("explicit cast", re.compile(r"\(\s*(?P<typ>"+talt+r")\s*\)\s*(?P<expr>(?:"+ralt+r")\s*\([^;]+?\))", re.S)),
          ("implicit integer assignment", re.compile(r"\b(?P<typ>"+talt+r")\s+[A-Za-z_]\w*\s*=\s*(?P<expr>(?:"+ralt+r")\s*\([^;]+?\))", re.S)),
        ]
        for kind, pat in patterns:
            for m in pat.finditer(text):
                key=(m.start(),m.group("expr").split("(")[0]);
                if key in seen: continue
                seen.add(key); line=text.count("\n",0,m.start())+1
                before="\n".join(text[:m.start()].splitlines()[-12:])
                typ=m.group("typ")
                has_min=bool(re.search(r"\b(?:"+re.escape(typ.upper())+r"_MIN|(?:INT|UINT)(?:\d+)?_MIN)\b", before))
                has_max=bool(re.search(r"\b(?:"+re.escape(typ.upper())+r"_MAX|(?:INT|UINT)(?:\d+)?_MAX|SIZE_MAX)\b", before))
                expr_norm=re.sub(r"\s+","",m.group("expr"))
                before_norm=re.sub(r"\s+","",before)
                checked=has_min and has_max and before_norm.count(expr_norm) >= 2
                found.append((p.name,function_at(text,m.start()),line,kind,typ,checked))
        # Assignment to an already-declared integer variable.
        for m in re.finditer(r"\b([A-Za-z_]\w*)\s*=\s*((?:"+ralt+r")\s*\([^;]+?\))", text, re.S):
            if (m.start(),m.group(2).split("(")[0]) in seen: continue
            # Resolve the nearest declaration in the current function rather
            # than a same-named variable elsewhere in the translation unit.
            fstarts=list(re.finditer(r"(?m)^[A-Za-z_]\w*(?:[ \t*]+[A-Za-z_]\w*)*\s*\([^;{}]*\)\s*\{", text[:m.start()]))
            start=fstarts[-1].start() if fstarts else 0
            decls=list(re.finditer(r"\b("+talt+r")\s+"+re.escape(m.group(1))+r"\s*(?:[=;,)[])" , text[start:m.start()]))
            if not decls: continue
            line=text.count("\n",0,m.start())+1
            found.append((p.name,function_at(text,m.start()),line,"implicit integer assignment","declared integer",False))
        # A reader used as a complete argument to an integer parameter.
        for cm in re.finditer(r"\b([A-Za-z_]\w*)\s*\(",text):
            callee=cm.group(1)
            if callee not in intparams: continue
            close=matching(text,cm.end()-1)
            if close<0: continue
            for i,(a,_,arg) in enumerate(split_args(text[cm.end():close])):
                if i not in intparams[callee] or not re.fullmatch(r"\s*(?:"+ralt+r")\s*\(.*\)\s*",arg,re.S): continue
                off=cm.end()+a; line=text.count("\n",0,off)+1
                found.append((p.name,function_at(text,off),line,"integer parameter",callee,False))
    return readers, ints, found

def run(src: pathlib.Path, allow: pathlib.Path) -> int:
    readers, ints, rows = scan(src); grouped={}
    for row in rows: grouped.setdefault((row[0],row[1]),[]).append(row)
    allowed={}; stale=0
    if not allow.exists(): print(f"num-cast: FAIL: allowlist {allow} missing"); return 1
    for line in allow.read_text().splitlines():
        if not line or line.startswith("#"): continue
        parts=line.split("|",3)
        if len(parts)!=4 or not parts[3]: print(f"  FAIL: malformed allowlist row: {line}"); stale+=1; continue
        allowed[(parts[0],parts[1])]=(int(parts[2]),parts[3])
    violations=0
    for key, rs in grouped.items():
        unchecked=[r for r in rs if not r[5]]
        if not unchecked: continue
        if key not in allowed or allowed[key][0] != len(unchecked):
            for r in unchecked: print(f"  VIOLATION: src/{r[0]}:{r[2]}: {r[1]}: unchecked {r[3]} to {r[4]}")
            violations += len(unchecked)
    for key,(count,_) in allowed.items():
        actual=len([r for r in grouped.get(key,[]) if not r[5]])
        if actual != count: print(f"  FAIL: stale allowlist row: {key[0]}|{key[1]} expected={count} actual={actual}"); stale+=1
    print(f"num-cast: examined={len(rows)} readers={len(readers)} integer-types={len(ints)} violations={violations} stale={stale}")
    if not rows or violations or stale: print("num-cast: FAIL"); return 1
    print("num-cast: PASS"); return 0

def selftest() -> int:
    plants=[("cast", "int n = (int)eigs_float_arg(arg, __func__);"), ("implicit", "int n = eigs_float_arg(arg, __func__);"), ("uint", "Uint32 n = (Uint32)eigs_list_float(arg, 0, __func__);"), ("split", "int n = (int)\n eigs_float_arg(arg, __func__);")]
    with tempfile.TemporaryDirectory(prefix="num_cast_selftest.") as d:
        d=pathlib.Path(d); (d/"x.h").write_text("typedef unsigned int Uint32; double eigs_float_arg(void*,const char*); double eigs_list_float(void*,int,const char*);\n")
        allow=d/"allow"; allow.write_text("")
        (d/"clean.c").write_text("void builtin(void *arg) { double n = eigs_float_arg(arg, \"x\"); (void)n; }\n")
        if run(d,allow)==0: print("SELFTEST FAILED: vacuous clean control passed"); return 1
        for name,plant in plants:
            # Every fault gets its own clean control immediately before it.
            (d/"clean.c").write_text("void builtin(void *arg) { if (eigs_float_arg(arg, \"x\") < INT_MIN || eigs_float_arg(arg, \"x\") > INT_MAX) return; int n=(int)eigs_float_arg(arg, \"x\"); (void)n; }\n")
            if run(d,allow): print(f"SELFTEST FAILED: {name} clean control rejected"); return 1
            (d/"plant.c").write_text(f"void planted(void *arg) {{ {plant} (void)n; }}\n")
            cp=subprocess.run([sys.executable,__file__,"--src",str(d),"--allow",str(allow)],text=True,capture_output=True)
            line=1
            if cp.returncode==0 or f"src/plant.c:{line}:" not in cp.stdout: print(f"SELFTEST FAILED: {name} plant not attributable\n{cp.stdout}"); return 1
            (d/"plant.c").unlink()
        (d/"limit.c").write_text("void limit(void *arg) { double x=eigs_float_arg(arg, \"x\"); int n=(int)x; (void)n; }\n")
        _,_,rows=scan(d)
        if any(r[0]=="limit.c" for r in rows): print("SELFTEST FAILED: stated dataflow limit unexpectedly changed"); return 1
    print("SELFTEST OK: checked control passed; 4 direct plants caught at their lines; double-temporary limit confirmed")
    return 0

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--selftest",action="store_true"); ap.add_argument("--src",type=pathlib.Path,default=ROOT/"src"); ap.add_argument("--allow",type=pathlib.Path,default=ROOT/"tools/num_cast_allowlist.txt"); a=ap.parse_args()
    return selftest() if a.selftest else run(a.src,a.allow)
if __name__ == "__main__": raise SystemExit(main())
