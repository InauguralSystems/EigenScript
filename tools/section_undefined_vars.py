#!/usr/bin/env python3
"""Reject undefined upper-case variables in sourced suite fragments.

This is deliberately a shell *lexer*, not a collection of line regular
expressions.  It understands the quoting constructs which decide whether a
dollar is active and emits words, separators, and parameter reads.  It is not
a complete bash parser (notably, function call order is not modelled).
"""
from __future__ import annotations

import random
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UPPER = re.compile(r"[A-Z][A-Z0-9_]*\Z")
ASSIGN = re.compile(r"([A-Z][A-Z0-9_]*)\+?=.*\Z", re.S)
SAFE = (":-", "-", ":+", "+", ":=", "=")


@dataclass
class Read:
    line: int
    name: str
    operator: str = ""


@dataclass
class Tok:
    text: str
    line: int
    depth: int
    kind: str = "word"


class Lexer:
    """One-character lexer. Context is carried by recursive stack frames."""
    def __init__(self, text: str):
        self.s, self.i, self.line = text, 0, 1
        self.tokens: list[Tok] = []
        self.reads: list[Read] = []
        self.word = ""
        self.word_line = 1
        self.word_depth = 0
        self.depth = 0              # assignments at nonzero depth do not escape
        self.heredocs: list[tuple[str, bool, bool]] = []

    def flush(self):
        if self.word:
            self.tokens.append(Tok(self.word, self.word_line, self.word_depth))
            self.word = ""

    def add(self, c: str):
        if not self.word:
            self.word_line = self.line
            self.word_depth = self.depth
        self.word += c

    def param(self):
        """Consume the dollar at i, recording reads and scanning safe WORDs."""
        start = self.line
        if self.s.startswith("$(('", self.i):  # impossible sentinel; keep ordering clear
            return
        if self.s.startswith("$((", self.i):
            self.add("$(("); self.i += 3; self.depth += 1
            self.scan(stop="))", arithmetic=True); self.depth -= 1
            return
        if self.s.startswith("$(", self.i):
            self.add("$("); self.i += 2; self.depth += 1
            self.scan(stop=")"); self.depth -= 1
            return
        if self.s.startswith("${", self.i):
            self.add("${"); self.i += 2
            if self.i < len(self.s) and self.s[self.i] in "#!":
                self.add(self.s[self.i]); self.i += 1
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", self.s[self.i:])
            if not m:
                self.scan(stop="}"); return
            name = m.group(); self.add(name); self.i += len(name)
            tail = self.s[self.i:]
            op = next((x for x in (":-", ":+", ":=", "%%", "##", "//", "-", "+", "=", "?", "%", "#", "/") if tail.startswith(x)), "")
            if UPPER.fullmatch(name): self.reads.append(Read(start, name, op))
            if op:
                self.add(op); self.i += len(op)
            self.scan(stop="}")       # SAFE operators still scan their WORD
            return
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", self.s[self.i + 1:])
        if m:
            name = m.group(); self.add("$" + name); self.i += len(name) + 1
            if UPPER.fullmatch(name): self.reads.append(Read(start, name))
        else:
            self.add("$"); self.i += 1

    def quote(self, q: str):
        self.add(q); self.i += 1
        while self.i < len(self.s):
            c = self.s[self.i]
            if c == "\n": self.line += 1
            if c == q:
                self.add(c); self.i += 1; return
            if q == '"' and c == "\\" and self.i + 1 < len(self.s):
                pair=self.s[self.i:self.i+2]; self.add(pair); self.i += 2
                if pair.endswith("\n"): self.line += 1
                continue
            if q == '"' and c == "$": self.param(); continue
            if q == '"' and c == "`": self.backtick(); continue
            self.add(c); self.i += 1

    def dollar_quote(self):
        self.add("$'"); self.i += 2
        while self.i < len(self.s):
            if self.s[self.i] == "\\" and self.i + 1 < len(self.s):
                pair=self.s[self.i:self.i+2]; self.add(pair); self.i += 2
                if pair.endswith("\n"): self.line += 1
                continue
            c = self.s[self.i]; self.add(c); self.i += 1
            if c == "\n": self.line += 1
            if c == "'": return

    def backtick(self):
        self.add("`"); self.i += 1; self.depth += 1
        self.scan(stop="`"); self.depth -= 1

    def scan(self, stop: str = "", arithmetic: bool = False):
        word_start = not self.word
        while self.i < len(self.s):
            if stop and self.s.startswith(stop, self.i):
                self.add(stop); self.i += len(stop); return
            c = self.s[self.i]
            if c == "\\" and self.i + 1 < len(self.s):
                pair=self.s[self.i:self.i+2]; self.add(pair); self.i += 2
                if pair.endswith("\n"): self.line += 1
                word_start = False; continue
            if c == "'": self.quote("'"); word_start = False; continue
            if c == '"': self.quote('"'); word_start = False; continue
            if self.s.startswith("$'", self.i): self.dollar_quote(); word_start = False; continue
            if c == "`": self.backtick(); word_start = False; continue
            if c == "$": self.param(); word_start = False; continue
            if arithmetic and (c.isalpha() or c == "_"):
                m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", self.s[self.i:])
                assert m
                name = m.group(); self.add(name); self.i += len(name)
                if UPPER.fullmatch(name): self.reads.append(Read(self.line, name))
                word_start = False; continue
            if c == "#" and word_start and not arithmetic:
                while self.i < len(self.s) and self.s[self.i] != "\n": self.i += 1
                continue
            if stop and c == "\n":
                self.add(c); self.i += 1; self.line += 1; word_start = True; continue
            if stop and c.isspace():
                self.add(c); self.i += 1; word_start = True; continue
            if c == "\n":
                self.flush(); self.tokens.append(Tok("\n", self.line, self.depth, "sep")); self.i += 1; self.line += 1; word_start = True
                if not stop and self.heredocs: self.heredoc_bodies()
                continue
            if c.isspace(): self.flush(); self.i += 1; word_start = True; continue
            if self.s.startswith("<<<", self.i) and not arithmetic:
                self.add("<<<"); self.i += 3; word_start = False; continue
            if self.s.startswith("<<", self.i) and not arithmetic:
                self.flush(); dash = self.s.startswith("<<-", self.i); self.i += 3 if dash else 2
                while self.i < len(self.s) and self.s[self.i] in " \t": self.i += 1
                quoted = self.i < len(self.s) and self.s[self.i] in "'\""
                q = self.s[self.i] if quoted else ""; self.i += bool(q); begin = self.i
                while self.i < len(self.s) and (self.s[self.i] != q if q else self.s[self.i] not in " \t\n;&|") : self.i += 1
                delim = self.s[begin:self.i]; self.i += bool(q and self.i < len(self.s))
                self.heredocs.append((delim, not quoted, dash)); word_start = False; continue
            op = next((x for x in ("&&", "||", ";;", "|&", ";", "|", "&", "(", ")") if self.s.startswith(x, self.i)), "")
            if op == "(" and self.word and ASSIGN.match(self.word + "x"):
                self.add(op); self.i += 1; word_start = False; continue
            if stop and op:
                self.add(op); self.i += len(op); word_start = True; continue
            if op and not arithmetic:
                self.flush(); d = self.depth
                if op == "(": self.depth += 1
                elif op == ")": self.depth = max(0, self.depth - 1); d = self.depth
                self.tokens.append(Tok(op, self.line, d, "sep")); self.i += len(op); word_start = True; continue
            self.add(c); self.i += 1; word_start = False
        self.flush()

    def heredoc_bodies(self):
        while self.heredocs:
            delim, expand, dash = self.heredocs.pop(0)
            while self.i < len(self.s):
                end = self.s.find("\n", self.i); end = len(self.s) if end < 0 else end
                raw = self.s[self.i:end]; compare = raw.lstrip("\t") if dash else raw
                if compare == delim:
                    self.i = end + (end < len(self.s)); self.line += end < len(self.s); break
                if expand:
                    # Heredocs expand parameters/substitutions but quotes are ordinary.
                    while self.i < end:
                        if self.s[self.i] == "\\": self.i += min(2, end-self.i); continue
                        if self.s[self.i] == "$": self.param(); continue
                        if self.s[self.i] == "`": self.backtick(); continue
                        self.i += 1
                else: self.i = end
                if self.i < len(self.s): self.i += 1; self.line += 1

    def run(self):
        self.scan(); return self.tokens, self.reads


def lex(text: str): return Lexer(text).run()


def commands(tokens: list[Tok]):
    cur: list[Tok] = []
    for t in tokens + [Tok("\n", 0, 0, "sep")]:
        if t.kind == "sep" and t.text in ("\n", ";", ";;", "&&", "||", "|", "|&", "&", "(", ")"):
            if cur: yield cur, t.text; cur = []
        else: cur.append(t)


def definitions_text(text: str) -> set[str]:
    toks, reads = lex(text); out: set[str] = set()
    for words, terminator in commands(toks):
        if not words or words[0].depth or terminator in ("|", "|&", "&"): continue
        plain = [w.text.strip("'\"") for w in words]
        while plain and plain[0] in ("!", "if", "then", "elif", "while", "until", "do"):
            plain.pop(0); words.pop(0)
        assigns = []
        k = 0
        while k < len(plain) and ASSIGN.fullmatch(plain[k]): assigns.append(ASSIGN.fullmatch(plain[k]).group(1)); k += 1
        if k == len(plain): out.update(assigns)
        cmd = plain[k] if k < len(plain) else ""
        args = plain[k+1:]
        if cmd in ("export", "local", "declare", "typeset", "readonly"):
            out.update(m.group(1) for a in args if (m := ASSIGN.match(a)))
            out.update(a for a in args if UPPER.fullmatch(a))
        elif cmd == "read": out.update(a for a in args if UPPER.fullmatch(a))
        elif cmd in ("mapfile", "readarray"):
            candidates = [a for a in args if not a.startswith("-")]; out.add(candidates[-1] if candidates and UPPER.fullmatch(candidates[-1]) else "MAPFILE")
        elif cmd == "printf" and "-v" in args:
            j=args.index("-v")+1
            if j < len(args) and UPPER.fullmatch(args[j]): out.add(args[j])
        elif cmd == "getopts" and len(args) > 1 and UPPER.fullmatch(args[1]): out.add(args[1])
        elif cmd in ("for", "select") and args and UPPER.fullmatch(args[0]): out.add(args[0])
        elif cmd == "let":
            out.update(m.group(1) for a in args if (m := ASSIGN.match(a)))
        if cmd == "[[" and "=~" in plain: out.add("BASH_REMATCH")
        # A read following while/if and optional assignment words is still a
        # command-position binder (``while IFS= read -r NAME``).
        for j, item in enumerate(plain):
            if item == "read": out.update(a for a in plain[j+1:] if UPPER.fullmatch(a))
    out.update(r.name for r in reads if r.operator in (":=", "="))
    return out


def tracked_sections(root):
    p=subprocess.check_output(["git","ls-files","tests/sections/*.sh"],cwd=root,text=True)
    return [root/x for x in p.splitlines()]


def documented_environment(root):
    out=set()
    for p in [root/"README.md", *sorted((root/"docs").glob("*.md"))]:
        for line in p.read_text(errors="replace").splitlines():
            if "environment variable" in line.lower(): out.update(re.findall(r"`([A-Z][A-Z0-9_]*)",line))
    return out


def runner_context(root):
    queue=[root/"tests/run_all_tests.sh"]; seen=set(); out=set()
    while queue:
        p=queue.pop()
        if p in seen or not p.is_file(): continue
        seen.add(p); text=p.read_text(); out |= definitions_text(text)
        for m in re.finditer(r"(?m)^\s*(?:source|\.)\s+['\"]?([^'\" ;|]+)", text):
            v=m.group(1).replace("${TESTS_DIR}",str(root/"tests")).replace("$TESTS_DIR",str(root/"tests")); q=Path(v)
            if q.is_file(): queue.append(q.resolve())
    built=subprocess.check_output(["env","-i","bash","--noprofile","--norc","-c","compgen -A variable"],text=True)
    out.update(x for x in built.splitlines() if UPPER.fullmatch(x)); return out


def scan(root, sections):
    available=runner_context(root)|documented_environment(root); bad=[]
    for p in sections:
        text=p.read_text(); toks, reads=lex(text); defs=definitions_text(text)
        events=[]
        for ws, _ in commands(toks):
            if ws and not ws[0].depth:
                names=definitions_text(" ".join(w.text for w in ws))
                events.extend((ws[0].line,n) for n in names)
        # Definitions are ordered approximately by prefix; this avoids letting a later
        # assignment satisfy an earlier read while retaining shell fragment ordering.
        for r in reads:
            prior={n for line,n in events if line <= r.line}
            # An assignment's RHS is expanded before that assignment exists.
            own = re.search(rf"(?m)^\s*{re.escape(r.name)}\+?=.*\${{?{re.escape(r.name)}(?:\W|$)", text)
            if own and text.count("\n",0,own.start())+1 == r.line: prior.discard(r.name)
            if r.name not in available|prior and r.operator not in SAFE: bad.append((p,r.line,r.name))
        available |= defs
    return bad


def population_ok(root, sections): return bool(sections) and not scan(root,sections)


def selftest():
    cases={
      "apostrophe in double quotes":('echo "don\'t use $TEST_DIR"\n',False), "after multiline single quote":("awk '\n{print}\n' \"$TEST_DIR/x\"\n",False),
      "assignment text string":('echo "TEST_DIR=unset"\ncat "$TEST_DIR"\n',False), "env prefix":('TEST_DIR=x true\ncat "$TEST_DIR"\n',False), "env command":('env TEST_DIR=x true\ncat "$TEST_DIR"\n',False),
      "hash in string":('echo "a # $TEST_DIR"\n',False), "nested default":('echo "${A:-$TEST_DIR}"\n',False), "nested substitution":('echo "$(cat "$TEST_DIR/x")"\n',False),
      "length":('echo "${#TEST_DIR}"\n',False), "suffix":('echo "${TEST_DIR%/*}"\n',False), "arithmetic":('echo $((TEST_DIR+1))\n',False), "same line self":('TEST_DIR="$TEST_DIR/x"\n',False),
      "python heredoc":("python3 - <<'PY'\nTEST_DIR=1\nPY\necho $TEST_DIR\n",False), "comparison":('[ "x" = "TEST_DIR=1" ]; echo $TEST_DIR\n',False), "subshell":('( TEST_DIR=1 )\necho $TEST_DIR\n',False),
      "quoted dash heredoc":('cat <<-"EOF"\n\t$Q\n\tEOF\necho "$TEST_DIR"\n',False), "here string":('cat <<<"$TEST_DIR"\n',False), "continuation":('echo a \\\n "$TEST_DIR"\n',False),
      "two heredocs":("cat <<'X' <<'Y'\n$a\nX\n$b\nY\necho $TEST_DIR\n",False), "escaped":('echo "\\$TEST_DIR"\n',True), "multiline literal":("awk '\n $TEST_DIR\n' f\n",True), "dollar quote":("X=$'a\\'b'; echo \"$TEST_DIR\"\n",False),
      "assignment":('VALUE=ok\necho "$VALUE"\n',True), "safe word scanned":('echo "${A:-$TEST_DIR}"\n',False), "assign default":(': "${VALUE:=x}"\necho "$VALUE"\n',True),
    }
    failed=0
    with tempfile.TemporaryDirectory() as td:
      root=Path(td); subprocess.run(["git","init","-q"],cwd=root,check=True); (root/"tests/sections").mkdir(parents=True); (root/"docs").mkdir(); (root/"README.md").write_text(""); (root/"tests/run_all_tests.sh").write_text("A=1\n")
      for name,(body,want) in cases.items():
        p=root/"tests/sections/o.sh"; p.write_text("echo ok\n"); control=not scan(root,[p]); p.write_text(body); got=not scan(root,[p])
        if control and got==want: print("PASS:",name)
        else: print(f"FAIL: {name} control={control} green={got}"); failed+=1
      a=root/"tests/sections/a.sh"; b=root/"tests/sections/b.sh"; a.write_text("SHARED=x\n"); b.write_text("echo $SHARED\n")
      if not scan(root,[a,b]) and scan(root,[b,a]): print("PASS: fragment order")
      else: print("FAIL: fragment order"); failed+=1
      if not population_ok(root,[]): print("PASS: vacuous run")
      else: print("FAIL: vacuous run"); failed+=1
      real=ROOT/"tests/sections/73x-jit-index-set-error-2540.sh"; p=root/"tests/sections/plant.sh"; p.write_text(real.read_text()+'\necho "$TEST_DIR"\n')
      if any(x[2]=="TEST_DIR" for x in scan(root,[p])): print("PASS: planted real fragment")
      else: print("FAIL: planted real fragment"); failed+=1
      # Seeded nested expansions use bash itself as the expectation oracle.
      rng=random.Random(2544); generated_ok=True
      for i in range(200):
        red='echo "$TEST_DIR"'
        for _ in range(rng.randrange(4)):
          red=rng.choice(['echo "$('+red+')"', 'echo "${A:-$('+red+')}"', '{ '+red+'; }'])
        green=red.replace('$TEST_DIR', '\\$TEST_DIR')
        for body,want in ((red,False),(green,True)):
          run=subprocess.run(["env","-i","TEST_DIR=MARKER_2544","bash","--noprofile","--norc","-c",body],text=True,capture_output=True)
          bash_expands="MARKER_2544" in run.stdout
          p.write_text(body+"\n"); scanner_green=not scan(root,[p])
          if run.returncode or bash_expands == want or scanner_green != want: generated_ok=False; break
        if not generated_ok: break
      if generated_ok: print("PASS: 200 seeded nested expansion/literal pairs (bash oracle)")
      else: print(f"FAIL: generated nesting {i}"); failed+=1
    total=len(cases)+4; print(f"section-undefined-vars selftest: {total-failed}/{total} passed, {failed} failed"); return bool(failed)


def main():
    if sys.argv[1:]==["--selftest"]: return selftest()
    if sys.argv[1:]: print("usage: tools/section_undefined_vars.py [--selftest]",file=sys.stderr); return 2
    sections=tracked_sections(ROOT); failures=scan(ROOT,sections) if sections else []
    for p,line,name in failures: print(f"{p.relative_to(ROOT)}:{line}: undefined upper-case variable {name}")
    ok=bool(sections) and not failures; print(f"section-undefined-vars: {'PASS' if ok else 'FAIL'}: examined={len(sections)} undefined={len(failures)}"); return not ok

if __name__=="__main__": raise SystemExit(main())
