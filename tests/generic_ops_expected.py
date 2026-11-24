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
 for op,tok in [(x,y) for x,y in OPS if x in ("EQ","NE","LT","GT","LE","GE")]:
  for a,b in [('"a"','"a"'),('"a"','"b"'),('"c"','"a"'),('"d"','"a"')]: r.append(("b",op,f"{a} {tok} {b}"))
 r += [("b","BAND","6 & 3.0"),("b","BOR","6 | 1.0"),("b","BXOR","5 ^ 1.0"),("b","SHL","1 << 2.0"),("b","BAND","6 & 2.5")]
 for op,tok in [(x,y) for x,y in OPS if x in ("EQ","NE","LT","GT")]:
  r += [("b",op,f"9007199254740993 {tok} 9007199254740992.0"),("b",op,f"9007199254740992.0 {tok} 9007199254740993")]
 for op,tok in OPS:
  for a,b in (("generic_nan","1.0"),("-0.0","0.0"),("generic_inf","1.0"),("generic_ninf","1.0")):
   r.append(("b",op,f"{a} {tok} {b}"))
 r += [("b","IDIV","-5 // 2"),("b","LT","2 < 2"),("b","ADD","9223372036854775807 + 1"),("b","SUB","(-9223372036854775807 - 1) - 1"),("b","MUL","9223372036854775807 * 2"),("b","IDIV","(-9223372036854775807 - 1) // -1"),("b","MOD","(-9223372036854775807 - 1) % -1")]
 # Plant oracle: float floor division/modulo in every sign combination, exact
 # int comparisons beyond double precision, and both sides of the boxed-int
 # boundary.  These are deliberately source expressions, not hand answers.
 for op,tok in (("IDIV","//"),("MOD","%")):
  for a,b in (("-7.5","2"),("7.5","-2"),("-7.5","-2"),("7.5","2")): r.append(("b",op,f"{a} {tok} {b}"))
 for op,tok in [(x,y) for x,y in OPS if x in ("EQ","NE","LT","GT","LE","GE")]:
  for a,b in (("9007199254740993","9007199254740992"),("140737488355328","140737488355327"),("-140737488355329","-140737488355328")): r.append(("b",op,f"{a} {tok} {b}"))
 # An int (immediate or boxed) against a NaN is unordered: only != is true.
 for op,tok in [(x,y) for x,y in OPS if x in ("EQ","NE","LT","GT","LE","GE")]:
  for a,b in (("1","generic_nan"),("generic_nan","1"),("9007199254740993","generic_nan"),("generic_nan","9007199254740993")): r.append(("b",op,f"{a} {tok} {b}"))
 for op,tok in [("DIV","/"),("IDIV","//"),("MOD","%")]: r += [("b",op,f"2 {tok} 0"),("b",op,f"2 {tok} 0.0")]
 for op,tok in [("SHL","<<"),("SHR",">>")]: r += [("b",op,f"2 {tok} -1"),("b",op,f"2 {tok} 64")]
 r += [("u","NEG","-2"),("u","NEG","-2.5"),("u","NEG",'-"a"'),("u","NEG","-(-9223372036854775807 - 1)"),("u","NOT","not 2"),("u","NOT","not 2.5"),("u","NOT",'not "a"'),("u","BNOT","~2"),("u","BNOT","~2.0"),("u","BNOT",'~"a"')]
 return r
def run(binary, strict, expr, loop=False):
 body = f"define oracle_expr() as:\n    return {expr}\n"
 # The special operands are built from their IEEE bits, exactly like the C
 # test's eigs_set_global: under EIGS_STRICT=1 `0.0 / 0.0` and `1.0 / 0.0`
 # raise at the setup line, and the row then recorded the setup's error
 # instead of the operator's answer (35 strict=1 rows, round 4).
 if "generic_nan" in expr: body = "generic_nan is f64_from_bits of 9221120237041090560\n" + body
 if "generic_inf" in expr or "generic_ninf" in expr: body = "generic_inf is f64_from_bits of 9218868437227405312\ngeneric_ninf is f64_from_bits of -4503599627370496\n" + body
 if loop: body += "for oracle_i in range of 5001:\n    oracle_value is oracle_expr of []\n"
 else: body += "oracle_value is oracle_expr of []\n"
 src = "try:\n" + "".join("    "+line+"\n" for line in body.splitlines()) + "    print of (\"value\\t\" + (type of oracle_value) + \"\\t-\\t\" + (str of oracle_value))\ncatch oracle_error:\n    print of (\"error\\t\" + oracle_error.kind + \"\\t\" + (str of oracle_error.line) + \"\\t\" + oracle_error.message)\n"
 with tempfile.NamedTemporaryFile("w",suffix=".eigs",delete=False) as f: f.write(src); name=f.name
 env=os.environ.copy(); env.pop("EIGS_STRICT",None)
 if strict != "unset": env["EIGS_STRICT"]=strict
 try: p=subprocess.run([binary,name],text=True,capture_output=True,env=env)
 finally: os.unlink(name)
 if p.returncode: raise SystemExit(f"{expr}: rc={p.returncode}: {p.stderr}{p.stdout}")
 out=p.stdout.rstrip("\n")
 parts=out.split("\t",3)
 if len(parts) != 4: raise SystemExit(f"{expr}: malformed oracle output: {out!r}")
 if parts[0] == "error": return "error",parts[1],parts[2],parts[3]
 return "value",parts[1],parts[2],parts[3]
def generate(binary, loop=False):
 rows=["# state\tform\top\texpression\tresult\tkind\tline\tprinted-or-message"]
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
