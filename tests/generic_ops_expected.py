#!/usr/bin/env python3
"""Pinned generic-operator oracle.

The committed tests/generic_ops_expected.tsv was generated from EigenScript
main commit c35118f9 with ``--write``.  Regeneration is intentionally an
explicit review operation; ``--check`` proves a candidate still matches it.
"""
import argparse, os, pathlib, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLE = ROOT / "tests/generic_ops_expected.tsv"
OPS = [("ADD","+"),("SUB","-"),("MUL","*"),("DIV","/"),("IDIV","//"),("MOD","%"),("BAND","&"),("BOR","|"),("BXOR","^"),("SHL","<<"),("SHR",">>"),("EQ","=="),("NE","!="),("LT","<"),("GT",">"),("LE","<="),("GE",">=")]
def specs():
 r=[]
 for op,tok in OPS:
  for a,b in [("2","3"),("2.5","0.5"),("2","0.5"),("0.5","2"),(('"a"'),"1")]: r.append(("b",op,f"{a} {tok} {b}"))
 r += [("b","IDIV","-5 // 2"),("b","LT","2 < 2"),("b","ADD","9223372036854775807 + 1"),("b","SUB","(-9223372036854775807 - 1) - 1"),("b","MUL","9223372036854775807 * 2"),("b","IDIV","(-9223372036854775807 - 1) // -1"),("b","MOD","(-9223372036854775807 - 1) % -1")]
 for op,tok in [("DIV","/"),("IDIV","//"),("MOD","%")]: r += [("b",op,f"2 {tok} 0"),("b",op,f"2 {tok} 0.0")]
 for op,tok in [("SHL","<<"),("SHR",">>")]: r += [("b",op,f"2 {tok} -1"),("b",op,f"2 {tok} 64")]
 r += [("u","NEG","-2"),("u","NEG","-2.5"),("u","NEG",'-"a"'),("u","NEG","-(-9223372036854775807 - 1)"),("u","NOT","not 2"),("u","NOT","not 2.5"),("u","NOT",'not "a"'),("u","BNOT","~2"),("u","BNOT","~2.0"),("u","BNOT",'~"a"')]
 return r
def value_kind(expr, text):
 if text in ("true","false"): return "bool"
 if text == "null": return "null"
 if expr.startswith('"') and " + " in expr: return "str"
 if any(x in expr for x in (" & "," | "," ^ "," << "," >> ")) or expr.startswith("~"): return "int"
 if any(x in expr for x in (" / ",".5",".0","generic_nan")) and not any(x in expr for x in ("==","!=","<",">")): return "float"
 if any(x in expr for x in ("==","!=","<",">")) or expr.startswith("not "): return "bool"
 return "int"
def run(binary, strict, expr, loop=False):
 body = f"define oracle_expr() as:\n    return {expr}\n"
 if "generic_nan" in expr: body = "generic_nan is 0.0 / 0.0\n" + body
 if loop: body += "for oracle_i in range of 5001:\n    oracle_value is oracle_expr of []\n"
 else: body += "oracle_value is oracle_expr of []\n"
 src = "try:\n" + "".join("    "+line+"\n" for line in body.splitlines()) + "    print of (str of oracle_value)\ncatch oracle_error:\n    print of (oracle_error.kind + \"\\t\" + oracle_error.message)\n"
 with tempfile.NamedTemporaryFile("w",suffix=".eigs",delete=False) as f: f.write(src); name=f.name
 env=os.environ.copy(); env.pop("EIGS_STRICT",None)
 if strict != "unset": env["EIGS_STRICT"]=strict
 try: p=subprocess.run([binary,name],text=True,capture_output=True,env=env)
 finally: os.unlink(name)
 if p.returncode: raise SystemExit(f"{expr}: rc={p.returncode}: {p.stderr}{p.stdout}")
 out=p.stdout.rstrip("\n")
 if "\t" in out:
  kind,msg=out.split("\t",1); return "error",kind,msg
 return "value",value_kind(expr,out),out
def generate(binary, loop=False):
 rows=["# state\tform\top\texpression\tresult\tkind\tprinted-or-message"]
 for strict in ("unset","0","1"):
  for form,op,expr in specs(): rows.append("\t".join((strict,form,op,expr,*run(binary,strict,expr,loop))))
 return "\n".join(rows)+"\n"
def main():
 ap=argparse.ArgumentParser(); g=ap.add_mutually_exclusive_group(required=True); g.add_argument("--write",metavar="BINARY"); g.add_argument("--check",metavar="BINARY"); g.add_argument("--program-check",metavar="BINARY"); a=ap.parse_args()
 binary=str(pathlib.Path(a.write or a.check or a.program_check).resolve())
 got=generate(binary, bool(a.program_check))
 if a.write: TABLE.write_text(got); return
 want=TABLE.read_text()
 if got != want: raise SystemExit("generic operator oracle differs (first differing row: "+next((f"{i}: expected {x!r}, got {y!r}" for i,(x,y) in enumerate(zip(want.splitlines(),got.splitlines()),1) if x!=y),"row count")+")")
 print(f"PASS: generic operator {'program ' if a.program_check else ''}oracle rows={len(specs())*3}")
if __name__ == "__main__": main()
