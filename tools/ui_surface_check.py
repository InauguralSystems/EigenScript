#!/usr/bin/env python3
"""Assertion-linked UI source enrollment, separate from runtime evidence."""
import argparse
import hashlib
import json
import re
import sys
import tempfile
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

# Reviewed adapters must retain their invocation and assertion bodies.
HELPERS = {'assert_ui_transition3': '40ac5a75488ea2bc09d3c036e9a76e08bb1d9d061e88a73630dc5d66b00b1988', 'assert_ui_fields': '31c7251ad69f86302546c599ffe547cd2e5d59e03d120a3e96c668c29a3fd1ae', 'assert_ui_result1': '634023d4a178045b51b9b5b40dd574bf9e3ce32b2d60dadccc4e93755a4c7e99', 'assert_ui_transition1': '5266e2be5f24ed958cea019ee2742f88810ee14a85e933c1d93a1b25ed2e202b', 'assert_ui_transition5': 'ee81ef57ed0b025ae519f7d35b823e5cd882845ce69c60b3410ab8c0858a52eb', 'assert_ui_render': 'c62fc89d9d8e76f2b0c8858fb1881d7ad4d7d3ccbbf141c2be4bba9cb683a003', 'assert_ui_transition2': 'f0ab7c58069e5f238f0a3f5ee4c55ea77a24a673f7fc9148a6fbb1bfde801afa', 'assert_ui_transition4': '11c1c6bf7685660ab3e58c42ee666b5fb2476f6b21cbe8ec42c79d777b53b2af', 'assert_ui_render1': 'd79d9c0202a707b46b7d06a9426212c8926e15d659ae826a600970626c57743f'}
STANDARD = {"assert_eq": 3, "assert_near": 4, "assert_true": 2, "assert_false": 2}
ADAPTERS = {"assert_ui_result1": (4, None), "assert_ui_transition1": (4, 2),
            "assert_ui_transition3": (6, 4), "assert_ui_transition2": (5, 3), "assert_ui_transition4": (7, 5),
            "assert_ui_transition5": (8, 6), "assert_ui_render": (5, None),
            "assert_ui_render1": (5, None)}

def tokens(source):
    result, i = [], 0
    while i < len(source):
        c = source[i]
        if c.isspace():
            i += 1
        elif c == "#":
            end = source.find("\n", i)
            i = len(source) if end < 0 else end
        elif c == '"':
            start = i
            i += 1
            while i < len(source):
                if source[i] == "\\":
                    i += 2
                elif source[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
            else:
                raise ValueError("unclosed string")
            result.append(("string", source[start:i]))
        else:
            match = re.match(r"[A-Za-z_]\w*|[0-9]+(?:\.[0-9]+)?", source[i:])
            text = match[0] if match else c
            result.append(("code", text))
            i += len(text)
    return result

def digest(source):
    return hashlib.sha256(json.dumps(tokens(source), separators=(",", ":")).encode()).hexdigest()

def top_blocks(source):
    starts = list(re.finditer(r"^(?=[^\s#])", source, re.M))
    return [(source.count("\n", 0, m.start()) + 1,
             source[m.start():starts[i+1].start() if i+1 < len(starts) else len(source)])
            for i,m in enumerate(starts)]

def split_args(items):
    if not items or items[0] != ("code", "[") or items[-1] != ("code", "]"):
        raise ValueError("assertion requires an explicit bracket argument list")
    args, current, stack = [], [], []
    pairs = {"]": "[", ")": "(", "}": "{"}
    for token in items[1:-1]:
        if token[0] == "code":
            text = token[1]
            if text in "[({":
                stack.append(text)
            elif text in "])}":
                if not stack or stack.pop() != pairs[text]:
                    raise ValueError("unbalanced assertion")
            elif text == "," and not stack:
                args.append(current); current = []; continue
        current.append(token)
    args.append(current)
    if stack or any(not arg for arg in args):
        raise ValueError("unbalanced or empty assertion argument")
    return args

def calls(items, names):
    # Credit only the unconditionally evaluated prefix. A function name in a
    # deferred lambda or the short-circuited side of a boolean is not a call
    # witness. Runtime assertions remain the behavioral oracle.
    if any(items[i:i+2] == [("code", "="), ("code", ">")]
           for i in range(len(items)-1)):
        return set()
    for i, item in enumerate(items):
        if item in {("code", "and"), ("code", "or")}:
            items = items[:i]
            break
    return {items[i][1] for i in range(len(items)-1)
            if items[i][0] == "code" and items[i][1] in names
            and items[i+1] == ("code", "of")}

def inventory(root):
    found = {}
    for path in sorted((root/"lib").glob("ui*.eigs")):
        for line, block in top_blocks(path.read_text()):
            if not block.startswith("define"): continue
            header = block.splitlines()[0].split("#",1)[0].rstrip()
            match = re.fullmatch(r"define ([A-Za-z_]\w*)\(([^()]*)\) as:", header)
            if not match: raise ValueError(f"{path}:{line}: unparsed definition")
            name = match[1]
            if name in found: raise ValueError(f"duplicate definition {name}: {found[name]} and {path}:{line}")
            found[name] = f"{path.relative_to(root)}:{line}"
    if not found: raise ValueError("empty definition population")
    return found

def check(root):
    definitions = inventory(root)
    names, covered = set(definitions), {}
    blocks = top_blocks((root/"tests/test_ui.eigs").read_text())
    bodies = {}
    for line, block in blocks:
        match = re.match(r"define (assert_ui_\w+)\(", block)
        if match:
            if match[1] in bodies: raise ValueError("duplicate assertion helper "+match[1])
            bodies[match[1]] = digest(block)
    if bodies != HELPERS: raise ValueError("assertion helper bodies changed or missing; review invocation/assertion contract")
    for line, block in blocks:
        ts = tokens(block)
        if not ts or ts[0][0] != "code": continue
        adapter = ts[0][1]
        if adapter not in STANDARD and not adapter.startswith("assert_ui_"): continue
        if len(ts)<3 or ts[1] != ("code","of"): raise ValueError(f"test_ui:{line}: unparsed assertion")
        args = split_args(ts[2:])
        credited = set()
        if adapter in STANDARD:
            if len(args)!=STANDARD[adapter]: raise ValueError(f"test_ui:{line}: wrong assertion arity")
            credited = calls(args[0], names)
            if adapter in {"assert_eq","assert_near"} and credited and args[0]==args[1]:
                raise ValueError(f"test_ui:{line}: self-comparison is not coverage")
        elif adapter == "assert_ui_fields":
            if len(args)!=3 or args[1][0]!=("code","{") or len(args[1])<=2:
                raise ValueError(f"test_ui:{line}: nonempty expected fields required")
            credited = calls(args[0], names)
        elif adapter in ADAPTERS:
            count, fields = ADAPTERS[adapter]
            if len(args)!=count or len(args[0])!=1 or args[0][0][0]!="code":
                raise ValueError(f"test_ui:{line}: unparsed function assertion")
            name=args[0][0][1]
            if name not in names: raise ValueError(f"test_ui:{line}: unknown UI function {name}")
            if fields is not None and (args[fields][0]!=("code","{") or len(args[fields])<=2):
                raise ValueError(f"test_ui:{line}: nonempty expected transition fields required")
            if adapter.startswith("assert_ui_render") and (args[2][0][0]!="string" or args[3][0]!=("code","[") or len(args[3])<=2):
                raise ValueError(f"test_ui:{line}: primitive and explicit operands required")
            credited.add(name)
        else: raise ValueError(f"test_ui:{line}: unknown assertion adapter {adapter}")
        for name in credited: covered.setdefault(name,[]).append(line)
    docs=set()
    document=(root/"docs/STDLIB.md").read_text()
    begin, end="<!-- ui-surface-contracts:start -->", "<!-- ui-surface-contracts:end -->"
    if document.count(begin)!=1 or document.count(end)!=1:
        raise ValueError("exactly one UI contract documentation region required")
    region=document.split(begin,1)[1].split(end,1)[0]
    for line in region.splitlines():
        match=re.fullmatch(r"\|\s*\x60([A-Za-z_]\w*)\([^\x60]*\)\x60\s*\|\s*([^|]+)\s*\|",line)
        if match and len(match[2].split())>=4:
            if match[1] in docs: raise ValueError("duplicate UI documentation "+match[1])
            docs.add(match[1])
    if docs-names: raise ValueError("unknown documented UI functions: "+", ".join(sorted(docs-names)))
    missing_tests, missing_docs=sorted(names-covered.keys()),sorted(names-docs)
    for name in missing_tests: print(f"UNTESTED UI FUNCTION: {name} ({definitions[name]})")
    for name in missing_docs: print(f"UNDOCUMENTED UI FUNCTION: {name} ({definitions[name]})")
    print(f"UI surface: {len(names)} definitions; {len(covered)} assertion-linked; {len(names & docs)} documented; "
          f"{len(missing_tests)} test gaps; {len(missing_docs)} doc gaps")
    return 1 if missing_tests or missing_docs else 0

def selftest(root):
    """Inert source controls; never compile or execute a UI fixture."""
    helpers="\n".join(block for _,block in top_blocks((root/"tests/test_ui.eigs").read_text())
                      if re.match(r"define assert_ui_\w+\(",block))
    with tempfile.TemporaryDirectory(prefix="ui-source-controls-") as temp:
        scratch=Path(temp)
        for directory in ("lib","tests","docs"): (scratch/directory).mkdir()
        sources={
            "lib/ui.eigs":"define ui_probe(x) as:\n    return x + 1\n",
            "lib/ui_extra.eigs":"define _ui_private_probe(x) as:\n    return x * 2\n",
            "tests/test_ui.eigs":helpers+"\nassert_eq of [ui_probe of 2, 3, \"public\"]\n"
                                "assert_ui_result1 of [_ui_private_probe, 2, 4, \"private\"]\n",
            "docs/STDLIB.md":"<!-- ui-surface-contracts:start -->\n"
                             "| "+chr(96)+"ui_probe(x)"+chr(96)+" | Returns the incremented input number. |\n"
                             "| "+chr(96)+"_ui_private_probe(x)"+chr(96)+" | Returns twice the input number. |\n"
                             "<!-- ui-surface-contracts:end -->\n"}
        def evaluate(changes):
            for path,body in sources.items(): (scratch/path).write_text(changes.get(path,body))
            capture=StringIO()
            try:
                with redirect_stdout(capture): rc=check(scratch)
            except ValueError as error:
                rc=2;capture.write(str(error))
            return rc,capture.getvalue()
        test="tests/test_ui.eigs"; lib="lib/ui_extra.eigs"; doc="docs/STDLIB.md"
        baseline=sources[test]
        public='assert_eq of [ui_probe of 2, 3, "public"]'
        private='assert_ui_result1 of [_ui_private_probe, 2, 4, "private"]'
        cases=[
            ("positive",{},0,""),
            ("public missing",{test:baseline.replace(public,'# ui_probe mentioned only')},1,"ui_probe"),
            ("private missing",{test:baseline.replace(private,'note is "_ui_private_probe of 2"')},1,"_ui_private_probe"),
            ("binding only",{test:baseline.replace(public,'fake_surface_exports is [ui_probe]')},1,"ui_probe"),
            ("unasserted call",{test:baseline.replace(public,'ui_probe of 2')},1,"ui_probe"),
            ("short-circuited call",{test:baseline.replace(public,'assert_true of [1 or (ui_probe of 2), "public"]')},1,"ui_probe"),
            ("deferred lambda",{test:baseline.replace(public,'assert_true of [(type of (() => ui_probe of 2)) == "fn", "public"]')},1,"ui_probe"),
            ("missing docs",{doc:sources[doc].replace("| "+chr(96)+"ui_probe(x)"+chr(96)+" | Returns the incremented input number. |\n","")},1,"ui_probe"),
            ("private added",{lib:sources[lib]+"define _new_private(x) as:\n    return x\n"},1,"_new_private"),
            ("public added",{lib:sources[lib]+"define new_public(x) as:\n    return x\n"},1,"new_public"),
            ("duplicate definition",{lib:sources[lib]+sources["lib/ui.eigs"]},2,"duplicate"),
            ("unparsed definition",{lib:sources[lib]+"define unusual as:\n    return null\n"},2,"unparsed definition"),
            ("adapter invocation removed",{test:baseline.replace("actual is fn of arg","actual is expected")},2,"helper bodies"),
            ("unparsed adapter",{test:baseline.replace(private,'assert_ui_unknown of [_ui_private_probe, 2, 4, "private"]')},2,"unknown assertion"),
            ("self comparison",{test:baseline.replace(public,'assert_eq of [ui_probe of 2, ui_probe of 2, "public"]')},2,"self-comparison"),
            ("restored",{},0,"")]
        for label,changes,expected,needle in cases:
            rc,output=evaluate(changes)
            if rc!=expected or needle not in output:
                print(f"SELFTEST FAIL: {label}: rc={rc}, expected={expected}\n{output}")
                return 1
            print(f"SELFTEST PASS: {label}")
    print(f"UI source controls: {len(cases)} passed, 0 failed")
    return 0

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root",type=Path,default=Path(__file__).resolve().parents[1])
    parser.add_argument("--selftest",action="store_true")
    args=parser.parse_args()
    try: return selftest(args.root.resolve()) if args.selftest else check(args.root.resolve())
    except (ValueError,OSError) as error:
        print(f"UI SURFACE ERROR: {error}",file=sys.stderr); return 2
if __name__=="__main__": sys.exit(main())
