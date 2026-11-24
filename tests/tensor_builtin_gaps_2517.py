#!/usr/bin/env python3
"""Regression checks for #2517 and #2514 across every strictness state.

Each case runs as its own program in each EIGS_STRICT state (unset, 0, 1), so
one failing case cannot hide the others. `--report` prints one line per case
and state (PASS or FAIL) and exits 0; it is how the cases are run against a
base binary to show which are red there. Without it, any FAIL exits 1.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EIGS = Path(os.environ.get("EIGS", ROOT / "src/eigenscript"))
CLASSIFIER = ROOT / "tests/lsan_classify.sh"
STATES = (None, "0", "1")
MARK = "CASE_DONE"


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


# The message names the pairing that was passed (#2517).
KIND = {"list": "a list", "flatlist": "a list", "buffer": "a 2-D buffer", "buffer1d": "a 1-D buffer"}


def operands(params, grad):
    setup, pexpr, gexpr = [], "[[1.0, 2.0]]", "[[1.0, 2.0]]"
    if params.startswith("buffer"):
        setup.append(buffer("p", 0 if params == "buffer1d" else 1))
        pexpr = "p"
    if grad.startswith("buffer"):
        setup.append(buffer("g", 0 if grad == "buffer1d" else 1))
        gexpr = "g"
    if params == "flatlist":
        pexpr = "[1.0, 2.0]"
    if grad == "flatlist":
        gexpr = "[1.0, 2.0]"
    before = "[buf_get_bits of [p, 0], buf_get_bits of [p, 1]]" if pexpr == "p" else \
             ("[f64_bits of p[0], f64_bits of p[1]]" if params == "flatlist" else
              "[f64_bits of p[0][0], f64_bits of p[0][1]]")
    if pexpr != "p":
        setup.append("p is " + pexpr)
        pexpr = "p"
    return setup, pexpr, gexpr, before


def raises(builtin, params, grad, kind, phrase, lr="0.5"):
    """The call raises `kind` with `phrase` in its message, and params' bits are unchanged."""
    setup, pexpr, gexpr, before = operands(params, grad)
    args = f"[{pexpr}, {gexpr}, {lr}]" if builtin == "sgd_update" else f"[{pexpr}, {gexpr}, [0], {lr}]"
    return "\n".join(setup + [f"before is {before}", "caught is false", "try:",
        f"    {builtin} of {args}", "catch e:",
        f"    caught is (e.kind == \"{kind}\") and (contains of [e.message, \"{phrase}\"])",
        f"assert of [caught, \"{builtin} {params}/{grad} raises {kind}\"]",
        f"assert of [{before} == before, \"{builtin} {params}/{grad} writes nothing\"]"])


def pair(params, grad):
    return f"got {KIND[params]} params and {KIND[grad]} grad"


cases = []
for fn in ("sgd_update_rows", "sgd_update_cols"):
    # Every pairing of different kinds, and a 1-D buffer params, names both kinds.
    for p, g in (("buffer", "list"), ("list", "buffer"), ("list", "buffer1d"),
                 ("buffer1d", "list"), ("buffer1d", "buffer"), ("buffer1d", "buffer1d"),
                 ("flatlist", "buffer"), ("flatlist", "buffer1d"),
                 ("buffer", "flatlist"), ("buffer1d", "flatlist")):
        cases.append((f"{fn} {p}/{g}", raises(fn, p, g, "type_mismatch", pair(p, g))))
    # The pairing is refused before the learning rate is read. A string lr raises
    # its own error when it is read (the list/list control); with a mixed pairing
    # the pairing error comes first.
    cases.append((f"{fn} list/list string lr control",
                  raises(fn, "list", "list", "type_mismatch", "expected a number", lr='"x"')))
    cases.append((f"{fn} list/buffer before lr",
                  raises(fn, "list", "buffer", "type_mismatch", pair("list", "buffer"), lr='"x"')))
    # A list whose elements are not lists is the list-rows type error, as on main.
    cases.append((f"{fn} list/flatlist list rows",
                  raises(fn, "list", "flatlist", "type_mismatch",
                         "expected parameter and gradient matrices with list rows")))
    # A 2-D buffer params with a 1-D buffer grad is the index case, as on main.
    cases.append((f"{fn} buffer/buffer1d index",
                  raises(fn, "buffer", "buffer1d", "index_range", "out of range")))
for p, g in (("buffer", "list"), ("list", "buffer")):
    cases.append((f"sgd_update {p}/{g}", raises("sgd_update", p, g, "type_mismatch", pair(p, g))))

# The accepted pairings keep their established numerical results.
cases.append(("sgd_update_rows list/list bits",
              "p is [[1.0, 2.0]]\ng is [[0.5, 1.0]]\nsgd_update_rows of [p,g,[0],0.5]\n"
              "assert of [[f64_bits of p[0][0],f64_bits of p[0][1]] == [4604930618986332160,4609434218613702656], \"list/list bits\"]"))
cases.append(("sgd_update_cols buffer/buffer bits",
              buffer("p", 1) + "\n" + buffer("g", 1) +
              "\nsgd_update_cols of [p,g,[0,1],0.5]\n"
              "assert of [[buf_get_bits of [p,0],buf_get_bits of [p,1]] == [4602678819172646912,4607182418800017408], \"buffer/buffer bits\"]"))
for p, g in (("buffer1d", "buffer1d"), ("buffer1d", "buffer")):
    cases.append((f"sgd_update {p}/{g} elementwise",
                  buffer("p", 0) + "\n" + buffer("g", 0 if g == "buffer1d" else 1) +
                  "\nsgd_update of [p, g, 0.5]\n"
                  "assert of [[buf_get_bits of [p,0],buf_get_bits of [p,1]] == [4602678819172646912,4607182418800017408], \"elementwise bits\"]"))
cases.append(("tensor_load missing path",
              "caught is false\ntry:\n    tensor_load of \"/nonexistent/zz.bin\"\ncatch e:\n"
              "    caught is e.kind == \"io\" and contains of [e.message, \"/nonexistent/zz.bin\"]\n"
              "assert of [caught, \"tensor_load missing path raises named io\"]"))


def verdict(source, state):
    result = run(source + f"\nprint of \"{MARK}\"\n", state)
    ok = (result.returncode == 0 and not hard_diagnostic(result.stdout + result.stderr)
          and MARK in result.stdout.splitlines())
    return ok, result


def main():
    report = "--report" in sys.argv[1:]
    failed = 0
    assert len(cases) == len({name for name, _ in cases}) > 0
    for name, source in cases:
        for state in STATES:
            label = "unset" if state is None else state
            ok, result = verdict(source, state)
            if report:
                print(f"{'PASS' if ok else 'FAIL'}\t{label}\t{name}")
            elif not ok:
                failed += 1
                print(f"FAIL: {name} EIGS_STRICT={label} rc={result.returncode}")
                print(result.stdout + result.stderr, end="")
    if report:
        return 0
    if failed:
        return 1
    for state in STATES:
        print(f"PASS: tensor builtin gaps EIGS_STRICT={'unset' if state is None else state} cases={len(cases)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
