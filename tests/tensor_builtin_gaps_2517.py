#!/usr/bin/env python3
"""Regression checks for #2517 and #2514 across every strictness state."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EIGS = Path(os.environ.get("EIGS", ROOT / "src/eigenscript"))
CLASSIFIER = ROOT / "tests/lsan_classify.sh"


def hard_diagnostic(output):
    """Use the suite's shared classifier even when the child exits zero."""
    classified = subprocess.run(
        ["sh", "-c", '. "$1"; lsan_classify "$(cat)"; [ "$?" -eq 1 ]',
         "classify", str(CLASSIFIER)], input=output, text=True)
    return classified.returncode == 0


def run(source, strict):
    with tempfile.NamedTemporaryFile("w", suffix=".eigs") as program:
        program.write(source)
        program.flush()
        env = os.environ.copy()
        if strict is None:
            env.pop("EIGS_STRICT", None)
        else:
            env["EIGS_STRICT"] = strict
        return subprocess.run([EIGS, program.name], text=True, capture_output=True, env=env)


def buffer(name, rows=1):
    reshape = f"reshape of [{name}, {rows}, 2]" if rows else name
    return "\n".join((f"{name} is buffer of 2", f"buf_set of [{name}, 0, 1.0]",
                       f"buf_set of [{name}, 1, 2.0]", f"{name} is {reshape}"))


def rejected(builtin, params, grad, indices="[0]", named=False):
    setup = []
    pexpr = "[[1.0, 2.0]]"
    gexpr = "[[1.0, 2.0]]"
    if params.startswith("buffer"):
        setup.append(buffer("p", 0 if params == "buffer1d" else 1))
        pexpr = "p"
    if grad.startswith("buffer"):
        setup.append(buffer("g", 0 if grad == "buffer1d" else 1))
        gexpr = "g"
    before = "[buf_get_bits of [p, 0], buf_get_bits of [p, 1]]" if pexpr == "p" else \
             "[f64_bits of p[0][0], f64_bits of p[0][1]]"
    if pexpr != "p":
        setup.append("p is " + pexpr)
        pexpr = "p"
    args = f"[{pexpr}, {gexpr}, {indices}, 0.5]"
    if builtin == "sgd_update":
        args = f"[{pexpr}, {gexpr}, 0.5]"
    return "\n".join(setup + [f"before is {before}", "caught is false", "try:",
        f"    {builtin} of {args}", "catch e:", "    caught is e.kind == \"type_mismatch\"",
        *([f"    caught is caught and contains of [e.message, \"got {KIND[params]} params and {KIND[grad]} grad\"]"]
          if named else []),
        f"assert of [caught, \"{builtin} rejected mismatched inputs\"]",
        f"assert of [{before} == before, \"{builtin} rejection is atomic\"]"])


# The message names the pairing that was passed (#2517).
KIND = {"list": "a list", "buffer": "a 2-D buffer", "buffer1d": "a 1-D buffer"}

cases = []
for fn in ("sgd_update_rows", "sgd_update_cols"):
    cases.extend(rejected(fn, p, g, named=True) for p, g in
                 (("buffer", "list"), ("list", "buffer"),
                  ("buffer1d", "list"), ("buffer1d", "buffer")))
    cases.append(rejected(fn, "list", "list", "0"))
for p, g in (("buffer", "list"), ("list", "buffer")):
    cases.append(rejected("sgd_update", p, g))

# Both accepted pairings retain their established numerical result.
cases.append("p is [[1.0, 2.0]]\ng is [[0.5, 1.0]]\nsgd_update_rows of [p,g,[0],0.5]\n"
             "assert of [[f64_bits of p[0][0],f64_bits of p[0][1]] == [4604930618986332160,4609434218613702656], \"list/list bits\"]")
cases.append(buffer("p", 1) + "\n" + buffer("g", 1) +
             "\nsgd_update_cols of [p,g,[0,1],0.5]\n"
             "assert of [[buf_get_bits of [p,0],buf_get_bits of [p,1]] == [4602678819172646912,4607182418800017408], \"buffer/buffer bits\"]")
cases.append("caught is false\ntry:\n    tensor_load of \"/nonexistent/zz.bin\"\ncatch e:\n"
             "    caught is e.kind == \"io\" and contains of [e.message, \"/nonexistent/zz.bin\"]\n"
             "assert of [caught, \"tensor_load missing path raises named io\"]")

source = "\n".join(cases) + "\nprint of \"PASS: tensor builtin gaps #2517/#2514\"\n"
for state in (None, "0", "1"):
    result = run(source, state)
    if (result.returncode or hard_diagnostic(result.stdout + result.stderr)
            or "PASS:" not in result.stdout):
        print(result.stdout, end="")
        print(result.stderr, end="")
        raise SystemExit(f"FAIL: EIGS_STRICT={state!r} rc={result.returncode}")
    print(f"PASS: tensor builtin gaps EIGS_STRICT={state if state is not None else 'unset'}")
