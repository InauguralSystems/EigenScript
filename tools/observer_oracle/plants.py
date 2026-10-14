#!/usr/bin/env python3
"""Planted faults for the observer oracle (#1746, #1758): each one must turn
the check it names red.

usage: python3 plants.py TAG_BINARY IEEE_BINARY [--only NAME,...]
       plants.py wrap PROG          (the wrapper observer, run through a shim)

Every plant runs in a scratch copy of this directory (the tree is never
edited) and states the exit code and output line that must appear. The
wrapper observer runs the real binary (OBS_WRAP_REAL) and rewrites only the
CK predicate readings (OBS_WRAP_MODE: perfect, const_false, intblind, spec;
or error/silent/jit_off for the harness plants); probes pass through.
Exit 0 only when every plant went red, printing `plants: N examined, N red`.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
VENV = os.path.expanduser("~/.local/venvs/oracle/bin/python")
PREDS = ["converged", "stable", "improving", "oscillating", "diverging", "equilibrium"]


def wrap(prog):
    real, mode = os.environ["OBS_WRAP_REAL"], os.environ.get("OBS_WRAP_MODE", "pass")
    if not prog.endswith(".eigs"):
        os.execv(real, [real] + sys.argv[2:])
    env = {**os.environ, **({"EIGS_JIT_OFF": "1"} if mode == "jit_off" else {})}
    if mode == "error":
        with open(prog, "a") as f:
            f.write("print of undefined_q\n")
    if mode == "silent":
        sys.exit(0)
    p = subprocess.run([real, prog], capture_output=True, text=True, env=env)
    d = os.environ.get("OBS_WRAP_DIR", HERE)
    labels = json.load(open(os.path.join(d, "labels.json")))
    rows = {r["id"]: r for r in json.load(open(os.path.join(d, "corpus.json")))["rows"]}
    spec = json.loads(os.environ.get("OBS_WRAP_SPEC", "{}"))
    head, tier, form = os.path.basename(prog)[:-5].rsplit(".", 2)
    rid = head.rsplit("@", 1)[0]
    if os.environ.get("OBS_WRAP_ONLY", f"{tier}/{form}") != f"{tier}/{form}":
        spec = {}
    out = []
    for ln in p.stdout.splitlines():
        f = ln.split()
        if f[:1] == ["CK"]:
            lab = labels[f"{rid}@{f[1]}"]
            for i, q in enumerate(PREDS):
                if mode == "perfect":
                    f[2 + i] = str(lab[q][1]).lower()
                elif mode == "const_false":
                    f[2 + i] = "false"
                elif mode == "intblind" and rows[rid]["gen"].get("int"):
                    f[2 + i] = str(not lab[q][1]).lower()
                key = f"{rid}@{f[1]}:{q}"
                if key in spec:
                    f[2 + i] = str(spec[key]).lower()
            ln = " ".join(f)
        out.append(ln)
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))
    sys.stderr.write(p.stderr)
    sys.exit(p.returncode)


# --- scratch-copy edits ---------------------------------------------------------

def edit_text(d, name, old, new):
    path = os.path.join(d, name)
    text = open(path).read()
    if old not in text:
        raise SystemExit(f"plant setup: {name} has no {old!r}")
    open(path, "w").write(text.replace(old, new, 1))


def edit_json(d, name, fn):
    path = os.path.join(d, name)
    data = json.load(open(path))
    fn(data)
    open(path, "w").write(json.dumps(data, indent=1) + "\n")


def row(c, rid):
    return next(r for r in c["rows"] if r["id"] == rid)


def keep_rows(*ids, extra=None):
    """A one-plant corpus: only these rows (and an extra row dict), so the certifier is quick."""
    def fn(c):
        c["rows"] = [r for r in c["rows"] if r["id"] in ids] + ([json.loads(json.dumps(extra))] if extra else [])
    return fn


def forge(d):
    """A certifier that vouches for anything: re-key every certificate to the
    rows as they stand, then regenerate labels from them."""
    sys.path.insert(0, d)
    try:
        import importlib
        import derive as dv
        importlib.reload(dv)
        corpus = dv.load_corpus(os.path.join(d, "corpus.json"))
        code = dv.code_hash()
        def fn(cert):
            for r in corpus["rows"]:
                cert["rows"][r["id"]]["hash"] = dv.row_hash(r, code)
        edit_json(d, "certificate.json", fn)
    finally:
        sys.path.remove(d)
        sys.modules.pop("derive", None)
        sys.modules.pop("gen", None)
    subprocess.run([sys.executable, os.path.join(d, "derive.py"), "--write"], check=True)


def shim(d, mode, real, **env):
    path = os.path.join(d, f"obs_{mode}")
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\nexec {sys.executable} {os.path.join(d, 'plants.py')} wrap \"$@\"\n")
    os.chmod(path, 0o755)
    os.environ.update({"OBS_WRAP_REAL": real, "OBS_WRAP_MODE": mode, "OBS_WRAP_DIR": d,
                       **{k: v for k, v in env.items()}})
    return path


def swap_spec(d):
    """Count-preserving: per predicate p, one floor verdict made wrong and one
    wrong tag verdict made right, both labelled true, in every arm."""
    floor = set(json.load(open(os.path.join(d, "floor.json")))["verdicts"])
    labels = json.load(open(os.path.join(d, "labels.json")))
    spec = {}
    for q in ("converged", "oscillating"):
        right = [k for k, v in labels.items() if v[q][1] and f"interp/straight {k} {q} {v[q][0]}" in floor
                 and not k.startswith(("ieee", "int64"))]
        wrong = [k for k, v in labels.items() if v[q][1] and f"interp/straight {k} {q} {v[q][0]}" not in floor
                 and not k.startswith(("ieee", "int64"))]
        spec[f"{right[0]}:{q}"], spec[f"{wrong[0]}:{q}"] = False, True
    return json.dumps(spec)


# --- the plants -----------------------------------------------------------------

def plants(tag, ieee):
    F = ["--floor", "{d}/floor.json"]
    sc = lambda *a: ["python3", "{d}/score.py", *a]
    cf = ["{venv}", "{d}/certify.py"]
    return [
        # name, what is planted, setup(d), argv, expected rc, line that must appear
        ("SWAP", "count-preserving swap: one floor verdict wrong, one wrong verdict right, per predicate",
         lambda d: shim(d, "spec", tag, OBS_WRAP_SPEC=swap_spec(d)), sc("{d}/obs_spec", *F), 1, r"FLOOR VIOLATION .*"),
        ("INTBLIND", "every scored verdict on int rows reversed",
         lambda d: shim(d, "intblind", tag), sc("{d}/obs_intblind", *F), 1, r"FLOOR VIOLATION \S+ int_.*"),
        ("perfect-tag", "an observer answering every scored label (must PASS)",
         lambda d: shim(d, "perfect", tag), sc("{d}/obs_perfect", *F), 0, r"exit 0: no gate failed.*"),
        ("perfect-ieee", "the same on the IEEE prototype, capability rows run (must PASS)",
         lambda d: shim(d, "perfect", ieee), sc("{d}/obs_perfect", *F), 0, r"CAPABILITY ROWS .*: 5 run, 2 skipped, 0 wrong.*"),
        ("capability-wrong", "the perfect observer with one ieee verdict reversed",
         lambda d: shim(d, "perfect", ieee, OBS_WRAP_SPEC='{"ieee_nan@30:diverging": true}'),
         sc("{d}/obs_perfect", *F), 1, r"CAPABILITY WRONG \S+ ieee_nan@30 diverging.*"),
        ("const-false", "every predicate reads false", lambda d: shim(d, "const_false", tag),
         sc("{d}/obs_const_false", *F), 1, r"floor: 1612 verdicts checked, \d+ lost.*"),
        ("FINDING", "one reading reversed in osr/loop only",
         lambda d: shim(d, "spec", tag, OBS_WRAP_SPEC='{"geo_decay_0.5@60:converged": false}', OBS_WRAP_ONLY="osr/loop"),
         sc("{d}/obs_spec"), 1, r"FINDING geo_decay_0.5@60 converged.*"),
        ("floor-zeroed", "floor.json verdict list emptied by hand",
         lambda d: edit_json(d, "floor.json", lambda f: f.update(verdicts=[])), sc(tag, *F), 2,
         r"does not match its own measurement.*"),
        ("floor-edited", "one verdict removed from floor.json by hand",
         lambda d: edit_json(d, "floor.json", lambda f: f["verdicts"].pop(7)), sc(tag, *F), 2,
         r"\d+ listed .*1 right one\(s\) missing.*"),
        ("floor-binary", "floor.json names a binary whose sha256 differs",
         lambda d: edit_json(d, "floor.json", lambda f: f["binary"].update(sha256="0" * 64)), sc(tag, *F), 2,
         r"no longer has sha256.*"),
        ("waiver-no-reason", "a waiver without a reason",
         lambda d: edit_json(d, "waivers.json", lambda w: w["waivers"].append(
             {"verdict": json.load(open(os.path.join(d, "floor.json")))["verdicts"][0], "reason": " "})),
         sc(tag, *F), 2, r"waiver .* has no reason.*"),
        ("waiver-unused", "a reasoned waiver for a verdict the binary still gets right",
         lambda d: edit_json(d, "waivers.json", lambda w: w["waivers"].append(
             {"verdict": json.load(open(os.path.join(d, "floor.json")))["verdicts"][0], "reason": "test"})),
         sc(tag, *F), 2, r"waiver for .* which this binary gets right.*"),
        ("double-scored", "converged scored against MATH and CONVENTION (the reported flag removed)",
         lambda d: edit_json(d, "corpus.json", lambda c: [x.pop("reported", None) for x in c["definitions"]]),
         sc(tag), 2, r"two scored definitions.*"),
        ("wrong-class", "derive.py labels converged with the MATH class, labels regenerated",
         lambda d: (edit_text(d, "derive.py", "v = {q: entry(q, scored[q]) for q in PREDS}",
                              "v = {q: entry(q, 'MATH' if q == 'converged' else scored[q]) for q in PREDS}"),
                    subprocess.run(["python3", f"{d}/derive.py", "--write"], capture_output=True)),
         sc(tag), 2, r"converged: \['MATH', (True|False)\] is not one CONVENTION verdict.*"),
        ("vacuous-jit", "no warm-up calls: the jit tier never compiles run_row",
         lambda d: edit_text(d, "score.py", 'WARMUP = {"interp": 0, "jit": 50,', 'WARMUP = {"interp": 0, "jit": 0,'),
         sc(tag), 2, r"VACUOUS tier\(s\): jit.*"),
        ("vacuous-osr", "EIGS_JIT_OSR_OFF=1 in the osr tier: no OSR thunk",
         lambda d: edit_text(d, "score.py", '"osr": {"EIGS_JIT_OSR_THRESHOLD": "1"}',
                             '"osr": {"EIGS_JIT_OSR_THRESHOLD": "1", "EIGS_JIT_OSR_OFF": "1"}'),
         sc(tag), 2, r"VACUOUS tier\(s\): osr.*"),
        ("jit-off-wrapper", "the binary ignores the tier and runs with EIGS_JIT_OFF=1",
         lambda d: shim(d, "jit_off", tag), sc("{d}/obs_jit_off"), 2, r"cannot measure the native share.*"),
        ("G1", "geo_decay_0.5 stated as tending to +inf, certificate forged, labels regenerated",
         lambda d: (edit_json(d, "corpus.json", lambda c: row(c, "geo_decay_0.5")["props"].update(
             limit=None, tends_to="+inf", bounded=False)), forge(d)), sc(tag, *F), 2,
         r"does not match its own measurement.*"),
        ("G3", "bare predicate read (the harness change also moves the tag's re-measured floor)",
         lambda d: edit_text(d, "score.py", 'return f"{pred} of x"', 'return f"{pred}"'),
         sc(tag, *F), 2, r"does not match its own measurement.*"),
        ("G3-nofloor", "bare predicate read, no floor: the loop form's last assignment is i, not x",
         lambda d: edit_text(d, "score.py", 'return f"{pred} of x"', 'return f"{pred}"'),
         sc(tag), 1, r"FINDING \S+ .*"),
        ("G4a", "missing binary", None, sc("/nonexistent/eigenscript"), 2, r"binary not found.*"),
        ("G4b", "/bin/false", None, sc("/bin/false"), 2, r"number probe.*"),
        ("G4c", "a program that errors (probes pass)", lambda d: shim(d, "error", tag), sc("{d}/obs_error"), 2,
         r"program failed \(rc=1\).*"),
        ("G4d", "a binary that prints nothing (probes pass)", lambda d: shim(d, "silent", tag), sc("{d}/obs_silent"), 2,
         r"program failed \(rc=0\).*"),
        ("G4e", "empty corpus", lambda d: edit_json(d, "corpus.json", lambda c: c.update(rows=[])), sc(tag), 2,
         r"corpus has no rows.*"),
        ("P-exact", "a .10g literal emitter", lambda d: edit_text(d, "score.py", "    return repr(v)\n",
                                                                 "    return format(v, '.10g')\n"),
         sc(tag), 2, r"values must agree in every bit.*"),
        ("P-off", "straight-form read emitted before x_i is assigned",
         lambda d: (edit_text(d, "score.py", "        if i in cks:\n            out.append(ck_line(i, ys))\n", ""),
                    edit_text(d, "score.py", "        out.append(f\"x is {literal(s[1])}\"",
                              "        out += [ck_line(i, ys)] if i in cks else []\n        out.append(f\"x is {literal(s[1])}\"")),
         sc(tag), 2, r"read after value.*"),
        ("late-read-straight", "a checkpoint c < n read after x_{c+1} is assigned, before its V line",
         lambda d: (edit_text(d, "score.py", "        if i in cks:\n", "        if i in cks and i == row[\"n\"]:\n"),
                    edit_text(d, "score.py", "        out.append(f'print of f\"V {i} {{x}}\"')",
                              "        out += [ck_line(i - 1, ys)] if i - 1 in cks and i - 1 < row[\"n\"] else []\n"
                              "        out.append(f'print of f\"V {i} {{x}}\"')")),
         sc(tag), 2, r"\S+: checkpoint \d+ read after \['\d+'\] assignments,\s+not \d+.*"),
        ("late-read-loop", "loop-form read after one assignment too many",
         lambda d: (edit_text(d, "score.py", "st = steps(row, xs, c)", "st = steps(row, generate(row[\"gen\"], c + 1), c + 1)"),
                    edit_text(d, "score.py", 'f"r is run_row of {c + 1}"', 'f"r is run_row of {c + 2}"')),
         sc(tag), 2, r"\S+: checkpoint \d+ read after \['\d+'\] assignments,\s+not \d+.*"),
        ("L1", "a label flipped by hand in labels.json",
         lambda d: edit_text(d, "labels.json", '"geo_decay_0.5@60": {"converged": ["CONVENTION", true',
                             '"geo_decay_0.5@60": {"converged": ["CONVENTION", false'),
         sc(tag), 2, r"labels.json differs from derive.py at 1 checkpoint.*"),
        ("L2", "a label's class replaced by EIGS-DEFINED in labels.json",
         lambda d: edit_text(d, "labels.json", '"geo_decay_0.5@60": {"converged": ["CONVENTION"',
                             '"geo_decay_0.5@60": {"converged": ["EIGS-DEFINED"'),
         sc(tag), 2, r"labels.json differs from derive.py at 1 checkpoint.*"),
        ("G2", "the reference model's converged ignores the window (reported arm: its table cell moves)",
         lambda d: edit_text(d, "reference.py", "    return max(w) - min(w) <= tau(w[-1])\n",
                             "    return abs(w[-1] - w[-2]) <= tau(w[-1])\n"),
         sc(tag), 0, r"DIFF:^  converged .*"),
        ("floor-inputs-moved", "CONTROL: corpus `about` text edited; the re-measured verdicts still match (accepted)",
         lambda d: edit_json(d, "corpus.json", lambda c: c.update(about=c["about"] + " (edited)")),
         sc(tag, *F), 0, r"recorded before edits to corpus.json.*"),
        ("lattice", "settling band narrower than eps, labels regenerated",
         lambda d: (edit_text(d, "derive.py", "BAND = 1e-2", "BAND = 1e-4"),
                    subprocess.run(["python3", f"{d}/derive.py", "--write"], capture_output=True)),
         ["python3", "{d}/derive.py"], 2, r"lattice broken.*"),
        ("improving-bounded", "the boundedness clause of improving dropped",
         lambda d: edit_text(d, "derive.py", "return (ok and bounded), why", "return ok, why"),
         sc(tag), 2, r"labels.json differs from derive.py.*"),
        ("stale-cert", "a row edited without re-certifying",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "geo_decay_0.5")["gen"].update(a=0.6)),
         sc(tag), 2, r"geo_decay_0.5: stale certificate.*"),
        ("ENV-step", "gen.ENV['step'] redefined", lambda d: edit_text(d, "gen.py", "1.0 if n >= c else 0.0",
                                                                   "1.0 if n > c else 0.0"),
         sc(tag), 2, r"stale certificate.*"),
        ("numbers", "--numbers ieee on the clamp binary", None, sc(tag, "--numbers", "ieee"), 2,
         r"contradicts the binary.*"),
        ("P-crash", "the reference model raises OverflowError",
         lambda d: edit_text(d, "reference.py", '    w = values[max(0, at - W):at + 1]\n',
                             '    w = values[max(0, at - W):at + 1]\n    math.exp(1000)\n'),
         sc(tag), 2, r"internal OverflowError.*"),
        ("capability-name", "a row with an unknown capability",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "ieee_nan").update(capability="quantum")),
         sc(tag), 2, r"unknown capability.*"),
        # certifier plants: a one-row corpus copy, certify.py run with the sympy venv
        ("cert-harmonic", "harmonic stated -> 14.39", lambda d: edit_json(d, "corpus.json", lambda c: (
            keep_rows("harmonic")(c), row(c, "harmonic")["props"].update(limit=14.39, tends_to=None, bounded=True))),
         cf, 1, r"REFUSED harmonic: stated limit=14.39.*"),
        ("cert-log", "log_n stated -> 27.63", lambda d: edit_json(d, "corpus.json", lambda c: (
            keep_rows("log_n")(c), row(c, "log_n")["props"].update(limit=27.63, tends_to=None, bounded=True))),
         cf, 1, r"REFUSED log_n: stated limit=27.63.*"),
        ("cert-float-degenerate", "(1.0 + 1e-17)**n stated -> +inf (the runtime is fed 1.0 forever)",
         lambda d: edit_json(d, "corpus.json", keep_rows(extra=dict(row(json.load(open(os.path.join(d, "corpus.json"))), "const_5"),
             id="one_plus_tiny", gen={"kind": "closed", "expr": "(1.0 + 1e-17) ** n"},
             props={"limit": None, "tends_to": "+inf", "bounded": False, "deterministic": True}))),
         cf, 1, r"REFUSED one_plus_tiny: float-degenerate.*"),
        ("cert-parity", "1/ln(n+2) + 0.001 (-1)^(n^2+n) stated as having no limit",
         lambda d: edit_json(d, "corpus.json", keep_rows(extra=dict(row(json.load(open(os.path.join(d, "corpus.json"))), "inv_log"),
             id="parity_inv_log", gen={"kind": "closed", "expr": "1.0 / math.log(n + 2) + 0.001 * (-1.0) ** (n * n + n)"},
             props={"limit": None, "tends_to": None, "bounded": True, "deterministic": True}))),
         cf, 1, r"REFUSED parity_inv_log: .*symbolic gives \{'limit': 1/1000.*"),
        ("cert-midpoint", "sin_n stated -> 0 (its manual block claims no limit)",
         lambda d: edit_json(d, "corpus.json", lambda c: (keep_rows("sin_n")(c), row(c, "sin_n")["props"].update(limit=0.0))),
         cf, 1, r"REFUSED sin_n: stated limit=0.0.*"),
        ("cert-noise-trend", "noise_below_s2.has_trend: true",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "noise_below_s2")["props"].update(has_trend=True)),
         cf, 2, r"noise_below_s2: flags .* contradict the noise process.*"),
        ("cert-walk-variance", "random_walk variance_changes: false",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "random_walk")["props"].update(variance_changes=False)),
         cf, 2, r"random_walk: flags .* contradict the walk process.*"),
        ("cert-repelling", "logistic_3.9 stated -> 29/39 with a manual block claiming it",
         lambda d: edit_json(d, "corpus.json", lambda c: (keep_rows("logistic_3.9")(c),
             row(c, "logistic_3.9")["props"].update(limit=29 / 39),
             row(c, "logistic_3.9")["manual"].update(argument="x* = 1 - 1/r is the fixed point of the map",
                                                     claims={"limit": 29 / 39, "tends_to": None, "bounded": True}))),
         cf, 1, r"REFUSED logistic_3.9: \|f'\(L\)\| = 1.9 > 1: .* repelling.*"),
        ("cert-sympy-crash", "sin(n)^2 + cos(n)^2 + 1/ln(n+2): sympy raises inside limit",
         lambda d: edit_json(d, "corpus.json", keep_rows(extra=dict(row(json.load(open(os.path.join(d, "corpus.json"))), "inv_log"),
             id="pyth_inv_log", gen={"kind": "closed", "expr": "math.sin(n) ** 2 + math.cos(n) ** 2 + 1.0 / math.log(n + 2)"},
             props={"limit": 1.0, "tends_to": None, "bounded": True, "deterministic": True},
             manual={"argument": "sin^2 + cos^2 = 1", "cite": ["HARDY_58"],
                     "claims": {"limit": 1.0, "tends_to": None, "bounded": True}}))),
         cf, 2, r"OBSERVER_ORACLE_ERROR: internal.*"),
        ("cert-level-shift", "level shift moved past the horizon (n = 25000)",
         lambda d: edit_json(d, "corpus.json", lambda c: (keep_rows("level_shift")(c),
                                                          row(c, "level_shift")["gen"].update(expr="1.0 + step(n, 25000)"))),
         cf, 1, r"REFUSED level_shift: float-degenerate.*"),
    ]


def run_plants(tag, ieee, only):
    table, red = plants(tag, ieee), 0
    if only:
        table = [p for p in table if p[0] in only]
    names = [p[0] for p in table]
    if not table or len(set(names)) != len(names):
        raise SystemExit(f"plant table empty or with duplicate names: {names}")
    for name, what, setup, argv, rc_want, line in table:
        with tempfile.TemporaryDirectory(prefix=f"plant_{name}_") as tmp:
            d = os.path.join(tmp, "oracle")
            shutil.copytree(HERE, d, ignore=shutil.ignore_patterns("__pycache__"))
            saved = dict(os.environ)
            try:
                if setup:
                    setup(d)
                cmd = [a.format(d=d, venv=VENV) for a in argv]
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=900, cwd=d)
            finally:
                os.environ.clear()
                os.environ.update(saved)
            out = p.stdout + p.stderr
            if line.startswith("DIFF:"):            # red iff the selected line moved from the unplanted run
                base = subprocess.run([a.format(d=HERE, venv=VENV) for a in argv], capture_output=True,
                                      text=True, timeout=900, cwd=HERE).stdout
                m, b = re.search(line[5:], out, re.M), re.search(line[5:], base, re.M)
                m = m if m and b and m.group(0) != b.group(0) else None
            else:
                m = re.search(line, out)
            ok = p.returncode == rc_want and m is not None
            red += ok
            shown = m.group(0) if m else (out.strip().splitlines() or [""])[-1][:160]
            print(f"{'RED ' if ok else 'MISS'} {name:22} rc={p.returncode} (want {rc_want})  {what}\n"
                  f"     {shown}", flush=True)
    print(f"plants: {len(table)} examined, {red} red")
    return 0 if red == len(table) else 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["wrap"]:
        wrap(sys.argv[2])
    args = sys.argv[1:]
    only = set()
    if "--only" in args:
        i = args.index("--only")
        only = set(args[i + 1].split(","))
        del args[i:i + 2]
    if len(args) != 2:
        raise SystemExit(__doc__)
    sys.exit(run_plants(os.path.abspath(args[0]), os.path.abspath(args[1]), only))
