#!/usr/bin/env python3
"""#1637: the self-hosted interpreter (lib/eigen.eigs `eigen_run`) agrees with
the VM on every bool-producing form -- comparisons, `not`, the literals, the
predicate builtins and the observer predicates (bare and named) -- and on the
raises (bool vs number). Each snippet runs as its own VM program and through
`eigen_run`; both print `[type of v, v]` or `raised <kind>`, and the two lines
must be identical. Exit 0 iff all SNIPPETS agree and all ran.

Usage: test_bool_meta_diff.py BINARY
"""
import os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "src/eigenscript"))
# (setup lines, final expression)
SNIPPETS = [
    ("", "1 < 2"), ("", "2 <= 1"), ("", "3 > 2"), ("", "3 >= 4"),
    ("", "3 == 3"), ("", "3 != 3"), ('', '"a" < "b"'), ('', '"x" == "x"'),
    ("", "[1, 2] == [1, 2]"), ("", "null == false"), ('', '"true" == true'),
    ("", "not 0"), ("", "not 7"), ("", "not true"), ("", "not false"), ('', 'not ""'),
    ("", "true"), ("", "false"), ("", "type of (1 < 2)"), ("", "type of true"),
    ("", "true and 5"), ("", "false or 6"), ("", "0 or false"),
    ('', 'contains of ["abc", "b"]'), ('', 'starts_with of ["abc", "x"]'),
    ("", "has_key of [{\"a\": 1}, \"a\"]"),
    ("", "converged"), ("", "stable"), ("", "improving"), ("", "diverging"),
    ("", "oscillating"), ("", "equilibrium"), ("", "type of converged"),
    ("x is 5", "converged of x"), ("x is 1\nx is 2\nx is 3", "improving of x"),
    ("x is 1\nx is 2", "equilibrium"), ("x is 4", "type of (stable of x)"),
    ("", "true == 1"), ("", "false != 0"), ("", "1 == true"), ("", "true + 1"),
    ("", "[true] == [1]"), ("", "1 < true"),
]


def run(src):
    with tempfile.NamedTemporaryFile("w", suffix=".eigs", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        p = subprocess.run([BIN, path], capture_output=True, text=True, timeout=30,
                           stdin=subprocess.DEVNULL, cwd=ROOT)
        return p.returncode, p.stdout.strip()
    finally:
        os.unlink(path)


def wrap(body):
    return ("try:\n" + "".join("    " + l + "\n" for l in body.split("\n")) +
            "    print of [type of __v, __v]\ncatch __e:\n    print of (\"raised \" + __e.kind)\n")


def main():
    bad, ran = [], 0
    for setup, expr in SNIPPETS:
        vm_src = wrap((setup + "\n" if setup else "") + f"__v is ({expr})")
        meta_code = (setup + "\n" if setup else "") + expr
        lit = '"' + meta_code.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
        meta_src = 'load_file of "lib/eigen.eigs"\n' + wrap("__v is eigen_run of " + lit)
        rv, ov = run(vm_src)
        rm, om = run(meta_src)
        ran += 1
        if rv != 0 or rm != 0 or not ov or ov != om:
            bad.append(f"{meta_code!r}: VM={ov!r} (rc {rv})  eigen_run={om!r} (rc {rm})")
    for b in bad:
        print("  FAIL: " + b)
    ok = ran == len(SNIPPETS) > 0 and not bad
    print(f"BOOL_META_DIFF: snippets={ran}/{len(SNIPPETS)} disagree={len(bad)} {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
