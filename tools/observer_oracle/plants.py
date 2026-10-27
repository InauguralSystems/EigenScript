#!/usr/bin/env python3
"""Planted faults for the observer oracle (#1746, #1758): each one must turn
the check it names red, and each CONTROL must stay green.

usage: python3 plants.py TAG_BINARY IEEE_BINARY [--only NAME,...]
       plants.py --selftest         (the floor can fail: a tools/selftests.txt row)
       plants.py wrap PROG|-e CODE   (the wrapper observer, run through a shim)
       python plants.py twins DIR     (with sympy: the twin labels, see below)

--selftest is the tools/selftests.txt row that runs when tools/observer_oracle/
changes (#1275, #1777; docs/PRINCIPLES.md section 5: a checker proves it fires
when it is written or changed, not on every run). It builds or reuses the
floor's anchor through `make observer-anchor` and runs floor-each against it.

Every plant runs in a scratch copy of this directory (the tree is never
edited) and states the exit code and output line that must appear (and, for
some, a check of what the run left behind). Counts in expected lines are
derived from the corpus, never typed (rule 177). Each plant command runs in a
session of its own and a timeout kills its process group: a MISS, never a
traceback. The wrapper observer (OBS_WRAP_MODE) runs the real binary
(OBS_WRAP_REAL) in the scored run's own process group, so the scorer's group
kill reaches it:
  twin          the honest "perfect" observer: at checkpoint n it answers the
                labels of the row's TWIN at n, the row as an observer at n can
                know it (its values up to x_n, the law in force at n continued,
                later law changes dropped). A fully online perfect observer
                cannot exist here: settling and whole-sequence questions are
                about values after n. The twin proves no scored label depends
                on a law change after its checkpoint. OBS_WRAP_NAN=1 also
                prints every NaN as -nan.
  const_false, intblind, spec   rewritten CK readings; zero_sign flips the
                runtime's zero sign lines
  osr_bail, jit_bail_body, jit_bail_short, num_body   a string ADD that bails
                at runtime (or a numeric ADD that does not) put into the loop,
                at an anchor that must occur exactly once (else it refuses)
  int64_fake    int64 probes answered yes, int64 rows' values printed exactly,
                readings from the real binary; ieee_split, ieee_reverse  the
                IEEE probe answered half IEEE (overflow clamps but inf * 0 is
                NaN, or the reverse)
  error, silent, jit_off, hang  harness faults (hang: a grandchild that never
                exits, its pid recorded)
Exit 0 only when every plant went red, printing `plants: N examined, N red`.
"""
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from derive import PREDS     # the order score.py prints a CK line's readings in

HERE = os.path.dirname(os.path.abspath(__file__))
VENV = os.path.expanduser("~/.local/venvs/oracle/bin/python")
LOOP_HEAD, GUARD = "        loop while true:\n", "    if m > 0:\n"
INJECT = {"osr_bail": ("osr", "cw is CW_S + CW_S"), "jit_bail_body": ("jit", "cw is CW_S + CW_S"),
          "num_body": (None, "cw is 1.0 + 2.0")}
PROBE_ANSWERS = {"int64_fake": {"9223372036854775806": "true", "num_type": "int"},
                 "ieee_split": {"1e308 * 10": "1e+308 true"}, "ieee_reverse": {"1e308 * 10": "inf false"}}
PLANT_TIMEOUT = 1800


def checked(text, anchor, new):
    """Inject at an anchor that occurs exactly once, or refuse: never run unplanted."""
    if text.count(anchor) != 1:
        sys.exit(f"wrap: refused: the anchor {anchor!r} occurs {text.count(anchor)} time(s), not once")
    return text.replace(anchor, new)


def wrap(args):
    real, mode = os.environ["OBS_WRAP_REAL"], os.environ.get("OBS_WRAP_MODE", "pass")
    d = os.environ.get("OBS_WRAP_DIR", HERE)
    if args[0] == "-e":                       # a probe
        hit = [v for k, v in PROBE_ANSWERS.get(mode, {}).items() if k in args[1]]
        if hit:
            print(hit[0])
            sys.exit(0)
        os.execv(real, [real] + args)
    prog = args[0]
    head, tier, form = os.path.basename(prog)[:-5].rsplit(".", 2)
    rid = head.rsplit("@", 1)[0]
    text = open(prog).read()
    if mode in INJECT and form == "loop" and INJECT[mode][0] in (None, tier) and tier != "interp":
        text = 'CW_S is "s"\n' + checked(text, LOOP_HEAD, LOOP_HEAD + "            " + INJECT[mode][1] + "\n")
    if mode == "jit_bail_short" and tier == "jit" and head != "const_5@60":
        text = 'CW_S is "s"\n' + checked(text, GUARD, GUARD + "        cw is CW_S + CW_S\n")
    if mode == "hang":                        # a grandchild in this run's process group, never exiting
        g = subprocess.Popen(["sleep", "600"])
        open(os.path.join(d, "hang.pid"), "w").write(str(g.pid))
        g.wait()
    if mode == "error":
        text += "print of undefined_q\n"
    if mode == "silent":
        sys.exit(0)
    open(prog, "w").write(text)
    p = subprocess.run([real, prog], capture_output=True, text=True,
                       env={**os.environ, **({"EIGS_JIT_OFF": "1"} if mode == "jit_off" else {})})
    labels = json.load(open(os.path.join(d, "labels.json")))
    twins = json.load(open(os.path.join(d, "twin_labels.json"))) if mode == "twin" else {}
    spec = json.loads(os.environ.get("OBS_WRAP_SPEC", "{}"))
    if os.environ.get("OBS_WRAP_ONLY", f"{tier}/{form}") != f"{tier}/{form}":
        spec = {}
    exact = None
    if mode == "int64_fake" and rid.startswith("int64"):
        sys.path.insert(0, d)
        import gen
        r = next(x for x in json.load(open(os.path.join(d, "corpus.json")))["rows"] if x["id"] == rid)
        exact = gen.generate(r["gen"], r["n"])
    out = []
    for ln in p.stdout.splitlines():
        f = ln.split()
        if f[:1] == ["V"] and exact is not None and len(f) == 3:
            f[2] = str(exact[int(f[1])])
        if f[:1] == ["S"] and mode == "zero_sign" and len(f) == 4:
            f[3] = {"true": "false", "false": "true"}.get(f[3], f[3])
        if f[:1] == ["CK"]:
            key = f"{rid}@{f[1]}"
            for i, q in enumerate(PREDS):
                if mode == "twin":
                    f[2 + i] = str(twins[key][q] if key in twins else labels[key][q][1]).lower()
                elif mode == "const_false":
                    f[2 + i] = "false"
                elif mode == "intblind" and labels[key][q][0] != "REPORTED" and rid.startswith("int"):
                    f[2 + i] = str(not labels[key][q][1]).lower()
                if f"{key}:{q}" in spec:
                    f[2 + i] = str(spec[f"{key}:{q}"]).lower()
        out.append(" ".join(f) if f[:1] in (["CK"], ["V"], ["S"]) else ln)
    text = "\n".join(out) + ("\n" if out else "")
    if os.environ.get("OBS_WRAP_NAN"):
        text, k = re.subn(r"\bnan\b", "-nan", text)
        with open(os.path.join(d, "wrap_nan.count"), "a") as f:
            f.write(f"{k}\n")
    sys.stdout.write(text)
    sys.stderr.write(p.stderr)
    sys.exit(p.returncode)


def twins(d):
    """twin_labels.json: for every checkpoint n before its row's regime, the
    labels of the row's twin at n (needs sympy: certify.decide gives the
    twin's properties). Law changes are found as derive finds them: any
    spelling of step but step(n, <integer literal>) is refused."""
    sys.path.insert(0, d)
    import certify
    import derive
    corpus = derive.load_corpus(os.path.join(d, "corpus.json"))
    defs = derive.definitions(corpus)
    scored, reported = derive.scored_classes(corpus)
    out = {}
    for r in corpus["rows"]:
        for n in [c for c in r["checkpoints"] if c < r["regime"]]:
            g = json.loads(json.dumps(r["gen"]))
            if g["kind"] == "pieces":                  # drop every piece that starts after n
                idx, keep = 0, []
                for q in g["pieces"]:
                    if idx > n:
                        break
                    keep.append(q)
                    idx += (1 if "x0" in q else 0) + q.get("steps", 0)
                keep[-1].pop("steps", None)
                g["pieces"] = keep
            elif g["kind"] in ("closed", "recur"):     # a step that fires after n never fires
                g["expr"] = derive.drop_steps_after(g["expr"], n)
            t = dict(r, id=f"{r['id']}~{n}", gen=g, n=n, checkpoints=[n], regime=derive.structural_regime(g))
            kind, v, _detail = certify.decide(t)
            t["props"] = dict(r["props"], limit=None if v["limit"] is None else float(v["limit"]),
                              tends_to=v["tends_to"], bounded=v["bounded"])
            lab = derive.derive_row(t, {"constant": certify.constant(t)}, defs, scored, reported)[f"{t['id']}@{n}"]
            out[f"{r['id']}@{n}"] = {q: lab[q][1] for q in PREDS}
    json.dump(out, open(os.path.join(d, "twin_labels.json"), "w"), indent=1)
    print(f"twins: {len(out)} checkpoint(s) before a law change: {sorted(out)}")


# --- scratch-copy edits ---------------------------------------------------------

def edit_text(d, name, old, new):
    path = os.path.join(d, name)
    text = open(path).read()
    if text.count(old) != 1:
        raise SystemExit(f"plant setup: {name} has {text.count(old)} of {old!r}, not one")
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


def extra_row(d, base, **upd):
    return dict(row(json.load(open(os.path.join(d, "corpus.json"))), base), **upd)


def forge(d, relabel=True):
    """A certifier that vouches for anything: re-key every certificate to the
    rows as they stand, then (relabel) regenerate labels from them."""
    for m in ("derive", "gen"):
        sys.modules.pop(m, None)
    sys.path.insert(0, d)
    try:
        import derive as dv
        corpus = dv.load_corpus(os.path.join(d, "corpus.json"))
        code = dv.code_hash()
        def fn(cert):
            for r in corpus["rows"]:
                cert["rows"][r["id"]]["hash"] = dv.row_hash(r, code)
        edit_json(d, "certificate.json", fn)
    finally:
        sys.path.remove(d)
        for m in ("derive", "gen"):
            sys.modules.pop(m, None)
    if relabel:
        subprocess.run([sys.executable, os.path.join(d, "derive.py"), "--write"], check=True)


def certify_in(d):
    subprocess.run([VENV, os.path.join(d, "certify.py")], check=True, capture_output=True, timeout=600)


def shim(d, mode, real, **env):
    path = os.path.join(d, f"obs_{mode}")
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\nexec {sys.executable} {os.path.join(d, 'plants.py')} wrap \"$@\"\n")
    os.chmod(path, 0o755)
    os.environ.update({"OBS_WRAP_REAL": real, "OBS_WRAP_MODE": mode, "OBS_WRAP_DIR": d, **env})
    if mode == "twin":
        subprocess.run([VENV, os.path.join(d, "plants.py"), "twins", d], check=True, capture_output=True)
    return path


def swap_spec(d):
    """Count-preserving: per predicate p, one floor verdict made wrong and one
    wrong verdict on a row with no capability made right, both labelled true,
    in every arm."""
    floor = set(json.load(open(os.path.join(d, "floor.json")))["verdicts"])
    labels = json.load(open(os.path.join(d, "labels.json")))
    capped = {r["id"] for r in json.load(open(os.path.join(d, "corpus.json")))["rows"] if r.get("capability")}
    spec = {}
    for q in ("converged", "oscillating"):
        cand = [k for k, v in labels.items() if v[q][1] and k.rsplit("@", 1)[0] not in capped]
        right = [k for k in cand if f"interp/straight {k} {q} {labels[k][q][0]}" in floor]
        wrong = [k for k in cand if f"interp/straight {k} {q} {labels[k][q][0]}" not in floor]
        spec[f"{right[0]}:{q}"], spec[f"{wrong[0]}:{q}"] = False, True
    return json.dumps(spec)


def floor_readings(d):
    """floor-each (#1777): for every (predicate, class, label) the floor holds,
    one reading, from a row not used yet where the floor allows, reversed in
    every arm. Returns the OBS_WRAP_SPEC and the floor verdicts those readings
    carry, in floor order (one per arm). The arms still agree, so no FINDING
    fires. A check_floor that skips a predicate, a class, a label direction or
    an arm leaves some of these losses out of its report."""
    floor = json.load(open(os.path.join(d, "floor.json")))["verdicts"]
    labels = json.load(open(os.path.join(d, "labels.json")))
    combos = {}
    for v in floor:
        _arm, key, pred, cls = v.split()
        combos.setdefault((pred, cls, labels[key][pred][1]), {})[(key, pred)] = None
    picked, used = {}, set()
    for combo in sorted(combos):
        readings = list(combos[combo])
        key, pred = next((r for r in readings if r[0].rsplit("@", 1)[0] not in used), readings[0])
        used.add(key.rsplit("@", 1)[0])
        picked[(key, pred)] = not combo[2]
    return (json.dumps({f"{k}:{p}": flip for (k, p), flip in picked.items()}),
            [v for v in floor if tuple(v.split()[1:3]) in picked])


def floor_block(lost, n):
    """What score.py --floor prints when exactly `lost` (in floor order) is lost
    from a floor of n verdicts and no other check failed: no FINDING, no
    capability verdict wrong, the floor re-measured on its anchor, each loss
    named, the count, exit 1."""
    return (r"^FINDINGS \(.*\): 0\n\nCAPABILITY ROWS .*, 0 wrong verdict\(s\); expected and absent: none\n\n"
            rf"floor: {n} verdicts \(.*: the list matches; .*\n"
            + "".join(rf"  FLOOR VIOLATION {re.escape(k)}\n" for k in lost)
            + rf"floor: {n} verdicts checked, {len(lost)} lost\n\nobserver oracle exit 1: FAIL$")


def stamp_anchor(d, make):
    """A local anchor for the scratch copy's recipe, in a cache inside d
    (XDG_CACHE_HOME): make(path) writes its binary; the stamp is intact."""
    recipe = hashlib.sha256(open(os.path.join(d, "build_anchor.sh"), "rb").read()).hexdigest()
    a = os.path.join(d, "cache", "eigs-oracle-anchor", recipe)
    os.makedirs(a)
    b = os.path.join(a, "eigenscript")
    make(b)
    sha = hashlib.sha256(open(b, "rb").read()).hexdigest()
    json.dump({"tag": "v0.46.0", "binary": b, "binary_sha256": sha, "recipe_sha256": recipe},
              open(os.path.join(a, "anchor.json"), "w"))
    os.environ["XDG_CACHE_HOME"] = os.path.join(d, "cache")


def edit_comment(src):
    """The anchor with another toolchain's .comment section: other bytes, same behaviour."""
    def make(b):
        with open(b + ".comment", "wb") as f:
            f.write(b"GCC: (Debian 14.2.0-19) 14.2.0\0")
        subprocess.run(["objcopy", "--update-section", f".comment={b}.comment", src, b], check=True)
    return make


def const_false_binary(src, d):
    """An 'anchor' whose observer answers false everywhere: changed behaviour."""
    def make(b):
        with open(b, "w") as f:
            f.write(f"#!/bin/sh\nOBS_WRAP_MODE=const_false OBS_WRAP_REAL={src} OBS_WRAP_DIR={d}"
                    f" exec {sys.executable} {os.path.join(d, 'plants.py')} wrap \"$@\"\n")
        os.chmod(b, 0o755)
    return make


def hang_gone(d):
    """None when the hanging run's grandchild is gone (or a zombie), else why."""
    try:
        pid = int(open(os.path.join(d, "hang.pid")).read())
    except (OSError, ValueError):
        return "the hanging wrapper recorded no pid"
    for _ in range(50):
        try:
            cmd, stat = open(f"/proc/{pid}/cmdline", "rb").read(), open(f"/proc/{pid}/stat").read()
        except OSError:
            return None
        if cmd != b"sleep\x00600\x00" or stat.rsplit(")", 1)[1].split()[0] in ("Z", "X"):
            return None
        time.sleep(0.1)
    os.kill(pid, signal.SIGKILL)
    return f"pid {pid} (sleep 600, the hung program's grandchild) survived the scorer's timeout; killed now"


def nan_rewritten(d):
    try:
        n = sum(int(k) for k in open(os.path.join(d, "wrap_nan.count")).read().split())
    except (OSError, ValueError):
        n = 0
    return None if n > 0 else "no NaN was printed as -nan: the control ran unplanted"


def labels_beside(d):
    """None when derive.py --corpus wrote labels for exactly that corpus beside it."""
    try:
        got = list(json.load(open(os.path.join(d, "one", "labels.json"))))
    except (OSError, ValueError) as e:
        return f"no labels.json beside the given corpus: {e}"
    want = [f"const_5@{n}" for n in row(json.load(open(os.path.join(d, "one", "corpus.json"))), "const_5")["checkpoints"]]
    return None if got == want else f"labels for {got}, expected {want}"


def counts():
    """What the expected lines count, derived from the corpus (rule 177): the
    capability-less checkpoints (the runs per JIT tier on the clamp tag
    binary) and the rows per capability."""
    rows = json.load(open(os.path.join(HERE, "corpus.json")))["rows"]
    return (sum(len(r["checkpoints"]) for r in rows if not r.get("capability")),
            {c: sum(1 for r in rows if r.get("capability") == c) for c in ("ieee", "int64")})


# --- the plants -----------------------------------------------------------------

def plants(tag, ieee):
    F = ["--floor", "{d}/floor.json"]
    sc = lambda *a: ["python3", "{d}/score.py", *a]
    cf = ["{venv}", "{d}/certify.py"]
    N, caps = counts()
    capline = rf"CAPABILITY ROWS .*: {caps['ieee']} run, {caps['int64']} skipped, 0 wrong.*"
    gut_regime = lambda d: (edit_text(d, "derive.py", 'if n < row["regime"]:', "if False:"),
                            edit_text(d, "derive.py", 'int(n) < rows[rid]["regime"]', "False"),
                            subprocess.run(["python3", f"{d}/derive.py", "--write"], check=True))
    return [
        # name, what is planted, setup(d), argv, expected rc, line that must appear[, post(d) -> None | why not]
        ("SWAP", "count-preserving swap: one floor verdict wrong, one wrong verdict right, per predicate",
         lambda d: shim(d, "spec", tag, OBS_WRAP_SPEC=swap_spec(d)), sc("{d}/obs_spec", *F), 1, r"FLOOR VIOLATION .*"),
        ("INTBLIND", "every scored verdict on int rows reversed",
         lambda d: shim(d, "intblind", tag), sc("{d}/obs_intblind", *F), 1, r"FLOOR VIOLATION \S+ int_.*"),
        ("floor-each", "one floor reading per (predicate, class, label) reversed in every arm (#1777): no"
         " FINDING, and the floor alone reds the run, losing exactly those readings' verdicts",
         lambda d: shim(d, "spec", tag, OBS_WRAP_SPEC=floor_readings(d)[0]), sc("{d}/obs_spec", *F), 1,
         lambda: floor_block(floor_readings(HERE)[1],
                             len(json.load(open(os.path.join(HERE, "floor.json")))["verdicts"]))),
        ("twin-tag", "CONTROL: the twin (honest perfect) observer, tag binary",
         lambda d: shim(d, "twin", tag), sc("{d}/obs_twin", *F), 0, r"exit 0: no gate failed.*"),
        ("twin-ieee", "CONTROL: the twin observer on the IEEE prototype, capability rows run",
         lambda d: shim(d, "twin", ieee), sc("{d}/obs_twin", *F), 0, capline),
        ("regime-gutted", "derive scores MATH before a row's law change; the twin observer must then FAIL",
         lambda d: (gut_regime(d), shim(d, "twin", ieee)), sc("{d}/obs_twin", *F), 1,
         r"CAPABILITY WRONG \S+ ieee_inf_recover@2 diverging.*"),
        ("regime-understated", "ieee_inf_recover declares regime 0 (its last piece starts at x_3)",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "ieee_inf_recover").update(regime=0)),
         sc(tag), 2, r"ieee_inf_recover: regime 0 must be an index in \[3, n\].*"),
        ("regime-guard", "level_shift read at 50, before its step at 100, certificate re-keyed: a CONVENTION"
         " verdict there would depend on later values",
         lambda d: (edit_json(d, "corpus.json", lambda c: row(c, "level_shift").update(checkpoints=[50, 103, 160])),
                    forge(d, relabel=False)), ["python3", "{d}/derive.py"], 2,
         r"level_shift@50.converged: a CONVENTION verdict before the law changes at x_100 depends on later values.*"),
        ("step-spelling", "level_shift's law change spelled step(n, 100.0): refused, never read as regime 0 (rule 186)",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "level_shift")["gen"].update(expr="1.0 + step(n, 100.0)")),
         sc(tag), 2, r"level_shift: '1.0 \+ step\(n, 100.0\)': a law change must be spelled step\(n, <integer literal>\).*"),
        ("step-spelling-twins", "the same spelling through plants.py twins",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "level_shift")["gen"].update(expr="1.0 + step(n, 100.0)")),
         ["{venv}", "{d}/plants.py", "twins", "{d}"], 2, r"a law change must be spelled step\(n, <integer literal>\).*"),
        ("checkpoint-hash", "checkpoint 2 added to ieee_inf without re-certifying",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "ieee_inf").update(checkpoints=[2, 5, 30])),
         sc(tag), 2, r"ieee_inf: stale certificate.*"),
        ("capability-wrong", "the twin observer with one ieee verdict reversed",
         lambda d: shim(d, "twin", ieee, OBS_WRAP_SPEC='{"ieee_nan@30:diverging": true}'),
         sc("{d}/obs_twin", *F), 1, r"CAPABILITY WRONG \S+ ieee_nan@30 diverging.*"),
        ("capability-int64", "geo_decay_0.5 tagged int64 (it would drop out of scoring and the floor)",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "geo_decay_0.5").update(capability="int64")),
         sc(tag), 2, r"geo_decay_0.5: capability 'int64' declared, but the values it feeds the runtime need None.*"),
        ("minus-nan", "CONTROL: the twin observer on the IEEE prototype printing every NaN as -nan, --expect ieee",
         lambda d: shim(d, "twin", ieee, OBS_WRAP_NAN="1"), sc("{d}/obs_twin", "--expect", "ieee"), 0, capline,
         nan_rewritten),
        ("reported-split", "the twin observer on the IEEE prototype, jit/loop reading a REPORTED verdict"
         " (ieee_inf_recover@2 oscillating) the other arms do not",
         lambda d: shim(d, "twin", ieee, OBS_WRAP_SPEC='{"ieee_inf_recover@2:oscillating": true}',
                        OBS_WRAP_ONLY="jit/loop"),
         sc("{d}/obs_twin"), 1, r"FINDING ieee_inf_recover@2 oscillating: .*jit/loop=true.*"),
        ("ieee-split", "IEEE probe: 1e308 * 10 clamps but inf * 0 is NaN",
         lambda d: shim(d, "ieee_split", tag), sc("{d}/obs_ieee_split"), 2,
         r"mixed IEEE behaviour: the IEEE probe printed '1e\+308 true'.*"),
        ("ieee-reverse", "IEEE probe: 1e308 * 10 is inf but inf * 0 is not NaN",
         lambda d: shim(d, "ieee_reverse", tag), sc("{d}/obs_ieee_reverse"), 2,
         r"mixed IEEE behaviour: the IEEE probe printed 'inf false'.*"),
        ("expect-absent", "--expect ieee on the clamp binary", None, sc(tag, "--expect", "ieee"), 1,
         r"expected and absent: \['ieee'\].*"),
        ("int64-fake", "a float runtime whose int64 probes pass and whose int64 values print exactly",
         lambda d: shim(d, "int64_fake", tag), sc("{d}/obs_int64_fake", "--expect", "int64"), 1,
         r"CAPABILITY WRONG \S+ int64_\S+.*"),
        ("const-false", "every predicate reads false", lambda d: shim(d, "const_false", tag),
         sc("{d}/obs_const_false", *F), 1, r"floor: \d+ verdicts checked, \d+ lost.*"),
        ("self-anchored", "--write-floor from the const-false observer (the critic's G4)",
         lambda d: shim(d, "const_false", tag), sc("{d}/obs_const_false", "--write-floor", "{d}/floor.json"), 2,
         r"--write-floor measures only the anchor build_anchor.sh builds.*"),
        ("anchor-missing", "no anchor built for the recipe (an empty cache)",
         lambda d: os.environ.update(XDG_CACHE_HOME=os.path.join(d, "nocache")),
         sc(tag, *F), 2, r"no floor anchor at \S+: run bash tools/observer_oracle/build_anchor.sh.*"),
        ("recipe-changed", "the recipe edited after the floor was measured",
         lambda d: edit_text(d, "build_anchor.sh", "set -euo pipefail", "set -euo pipefail  # edited"),
         sc(tag, *F), 2, r"was measured on the anchor of another recipe.*"),
        ("anchor-comment", "CONTROL: the anchor rebuilt with another toolchain's .comment (objcopy): other"
         " bytes, the same verdicts",
         lambda d: stamp_anchor(d, edit_comment(tag)), sc(tag, *F), 0,
         r"the list matches; binary sha256 \w+ differs from the floor's .*"),
        ("anchor-behaviour", "an anchor whose observer behaves differently (answers false everywhere)",
         lambda d: stamp_anchor(d, const_false_binary(tag, d)), sc(tag, *F), 2, r"is not its anchor's measurement.*"),
        ("waiver-file", "a hand-added waivers.json", lambda d: open(os.path.join(d, "waivers.json"), "w").write(
            json.dumps({"waivers": [{"verdict": "interp/loop const_5@60 converged CONVENTION", "reason": "x"}]})),
         sc(tag, *F), 2, r"waivers.json: waivers are removed by design.*"),
        ("FINDING", "one reading reversed in osr/loop only",
         lambda d: shim(d, "spec", tag, OBS_WRAP_SPEC='{"geo_decay_0.5@60:converged": false}', OBS_WRAP_ONLY="osr/loop"),
         sc("{d}/obs_spec"), 1, r"FINDING geo_decay_0.5@60 converged.*"),
        ("floor-zeroed", "floor.json verdict list emptied by hand",
         lambda d: edit_json(d, "floor.json", lambda f: f.update(verdicts=[])), sc(tag, *F), 2,
         r"is not its anchor's measurement.*"),
        ("floor-edited", "one verdict removed from floor.json by hand",
         lambda d: edit_json(d, "floor.json", lambda f: f["verdicts"].pop(7)), sc(tag, *F), 2,
         r"0 listed verdict\(s\) the anchor gets wrong .*1 right one\(s\) missing.*"),
        ("floor-inputs-moved", "CONTROL: corpus `about` text edited; the re-measured verdicts still match",
         lambda d: edit_json(d, "corpus.json", lambda c: c.update(about=c["about"] + " (edited)")),
         sc(tag, *F), 0, r"the list matches.*"),
        ("slot-path", "`when is x` back in the loop form's read: x interrogated, so the loop arms grade the"
         " name path", lambda d: edit_text(d, "score.py", '"        " + ck_line(c, ys, "loop")',
                                           '"        " + ck_line(c, ys, "straight")'),
         sc(tag), 2, r"interp/loop: this arm grades x through OBSERVE_ASSIGN_LOCAL and PREDICATE_SLOT, but its"
                     r" EIGS_DUMP_BC listing of run_row reads 6 predicate\(s\) through \['PREDICATE_NAME'\].*"),
        ("osr_bail", "a runtime-bailing string ADD as the osr loop body's first statement (the critic's cwrap)",
         lambda d: shim(d, "osr_bail", tag), sc("{d}/obs_osr_bail"), 2, rf"VACUOUS: {N} JIT-tier run\(s\).*"),
        ("jit_bail_body", "the same in the jit tier", lambda d: shim(d, "jit_bail_body", tag),
         sc("{d}/obs_jit_bail_body"), 2, rf"VACUOUS: {N} JIT-tier run\(s\).*"),
        ("jit_bail_short", "a bailing ADD before the loop in every jit run but one",
         lambda d: shim(d, "jit_bail_short", tag), sc("{d}/obs_jit_bail_short"), 2, rf"VACUOUS: {N - 1} JIT-tier run\(s\).*"),
        ("num_body", "CONTROL: a numeric ADD as the first body statement in both JIT tiers must still witness",
         lambda d: shim(d, "num_body", tag), sc("{d}/obs_num_body"), 0, rf"jit: \d+ of {N} runs witness a native body.*"),
        ("wrap-anchor", "the loop's header respelled, so the bail plants' anchor is gone: wrap must refuse,"
         " not run unplanted", lambda d: (edit_text(d, "score.py", '"        loop while true:"', '"        loop while 1 == 1:"'),
                                          shim(d, "osr_bail", tag)),
         sc("{d}/obs_osr_bail"), 2, r"wrap: refused: the anchor '        loop while true:\\n' occurs 0 time\(s\).*"),
        ("vacuous-jit", "no warm-up calls: the jit tier never compiles run_row",
         lambda d: edit_text(d, "score.py", 'WARMUP = {"interp": 0, "jit": 50,', 'WARMUP = {"interp": 0, "jit": 0,'),
         sc(tag), 2, rf"VACUOUS: {N} JIT-tier run\(s\).*"),
        ("vacuous-osr", "EIGS_JIT_OSR_OFF=1 in the osr tier: no OSR thunk",
         lambda d: edit_text(d, "score.py", '"osr": {"EIGS_JIT_OSR_THRESHOLD": "1"}',
                             '"osr": {"EIGS_JIT_OSR_THRESHOLD": "1", "EIGS_JIT_OSR_OFF": "1"}'),
         sc(tag), 2, rf"VACUOUS: {N} JIT-tier run\(s\).*"),
        ("jit-off-wrapper", "the binary ignores the tier and runs with EIGS_JIT_OFF=1",
         lambda d: shim(d, "jit_off", tag), sc("{d}/obs_jit_off"), 2, r"cannot witness the tier.*"),
        ("env-entry-threshold", "CONTROL: EIGS_JIT_ENTRY_THRESHOLD=1 exported by the caller: the tiers"
         " scrub it, so the scores are the unplanted run's",
         lambda d: os.environ.update(EIGS_JIT_ENTRY_THRESHOLD="1"), sc(tag), 0, r"SAME:^HEADLINE.*"),
        ("env-jit-off", "CONTROL: EIGS_JIT_OFF=1 exported by the caller: scrubbed the same way",
         lambda d: os.environ.update(EIGS_JIT_OFF="1"), sc(tag), 0, r"SAME:^HEADLINE.*"),
        ("hang", "a program whose grandchild never exits, a 3 s row timeout: the run fails, and the scorer"
         " kills the whole process group (no orphan on a 4 GB box)",
         lambda d: (edit_text(d, "score.py", "ROW_TIMEOUT = 120", "ROW_TIMEOUT = 3"), shim(d, "hang", tag)),
         sc("{d}/obs_hang"), 2, r"cannot run \S+: .*timed out after 3 seconds.*", hang_gone),
        ("zero-sign", "the runtime's zero sign lines flipped (it would hold -0.0 where the generator holds 0.0)",
         lambda d: shim(d, "zero_sign", tag), sc("{d}/obs_zero_sign"), 2,
         r"runtime=0 \(sign bit True\) generator=0.0 \(values must agree in every bit\).*"),
        ("intmin-literal", "CONTROL: an int row x <- x * INT64_MIN + 0 from 0: the spliced INT64_MIN literal"
         " must keep its parentheses (x_1 = 0, not -1)",
         lambda d: (edit_json(d, "corpus.json", keep_rows(extra=extra_row(d, "int_counter", id="intmin_a",
             gen={"kind": "affine", "x0": 0, "a": -2 ** 63, "b": 0, "int": True}, n=10, checkpoints=[10],
             props={"limit": 0.0, "tends_to": None, "bounded": True, "deterministic": True}))),
                    certify_in(d), subprocess.run(["python3", f"{d}/derive.py", "--write"], check=True)),
         sc(tag), 0, r"observer oracle exit 0: no gate failed.*"),
        ("double-scored", "converged scored against MATH and CONVENTION (the reported flag removed)",
         lambda d: edit_json(d, "corpus.json", lambda c: [x.pop("reported", None) for x in c["definitions"]]),
         sc(tag), 2, r"two scored definitions.*"),
        ("wrong-class", "derive.py labels converged with the MATH class (past each row's regime, so the"
         " regime guard stays quiet), labels regenerated",
         lambda d: (edit_text(d, "derive.py", "v = {q: entry(q, scored[q]) for q in PREDS}",
                              "v = {q: entry(q, 'MATH' if q == 'converged' and n >= row['regime'] else scored[q])"
                              " for q in PREDS}"),
                    subprocess.run(["python3", f"{d}/derive.py", "--write"], capture_output=True)),
         sc(tag), 2, r"converged: \['MATH', (True|False)\] is not one CONVENTION verdict.*"),
        ("nan-all-false", "restore the old all-false override at a recoverable NaN checkpoint",
         lambda d: edit_text(d, "derive.py", "elif math.isnan(xs[n]) and not nan_recovery:",
                             "elif math.isnan(xs[n]):"),
         sc(tag), 2, r"ieee_nan_recover@3.oscillating: \['CONVENTION', False\] is not one REPORTED verdict.*"),
        ("nan-window-dropped", "drop the NaN observer-window rejection",
         lambda d: edit_text(d, "derive.py",
             '    if any(math.isnan(v) for v in window):\n'
             '        return False, f"NaN lies in the observer window [{max(0, n - PATIENCE + 1)}, {n}]"\n', ""),
         sc(tag), 2, r"labels.json differs from derive.py at 1 checkpoint.*"),
        ("G1", "geo_decay_0.5 stated as tending to +inf, certificate forged, labels regenerated",
         lambda d: (edit_json(d, "corpus.json", lambda c: row(c, "geo_decay_0.5")["props"].update(
             limit=None, tends_to="+inf", bounded=False)), forge(d)), sc(tag, *F), 2,
         r"is not its anchor's measurement.*"),
        ("G2", "the reference model's converged ignores the window (reported arm: its table cell moves)",
         lambda d: edit_text(d, "reference.py", "    return max(w) - min(w) <= tau(w[-1])\n",
                             "    return abs(w[-1] - w[-2]) <= tau(w[-1])\n"),
         sc(tag), 0, r"DIFF:^  converged .*"),
        ("G3", "bare predicate read: the opcode gate sees no PREDICATE_NAME/PREDICATE_SLOT on x",
         lambda d: edit_text(d, "score.py", 'return f"{pred} of x"', 'return f"{pred}"'),
         sc(tag), 2, r"interp/straight: this arm grades x through OBSERVE_ASSIGN and PREDICATE_NAME, but its"
                     r" EIGS_DUMP_BC listing of <module> reads \d+ predicate\(s\) through \['PREDICATE'\].*"),
        ("G4a", "missing binary", None, sc("/nonexistent/eigenscript"), 2, r"binary not found.*"),
        ("G4b", "/bin/false", None, sc("/bin/false"), 2, r"IEEE probe .* printed '', not 'inf true'.*"),
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
         lambda d: (edit_text(d, "score.py", '        if i in cks:\n            out.append(ck_line(i, ys, "straight"))\n', ""),
                    edit_text(d, "score.py", "        out.append(f\"x is {literal(s[1])}\"",
                              "        out += [ck_line(i, ys, 'straight')] if i in cks else []\n"
                              "        out.append(f\"x is {literal(s[1])}\"")),
         sc(tag), 2, r"read after value.*"),
        ("late-read-straight", "a checkpoint c < n read after x_{c+1} is assigned, before its V line",
         lambda d: (edit_text(d, "score.py", "        if i in cks:\n", "        if i in cks and i == row[\"n\"]:\n"),
                    edit_text(d, "score.py", "        out.append(f'print of f\"V {i} {{x}}\"')",
                              "        out += [ck_line(i - 1, ys, 'straight')] if i - 1 in cks and i - 1 < row[\"n\"] else []\n"
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
        ("lattice", "settling band narrower than eps, labels regenerated",
         lambda d: (edit_text(d, "derive.py", "BAND = 1e-2", "BAND = 1e-4"),
                    subprocess.run(["python3", f"{d}/derive.py", "--write"], capture_output=True)),
         ["python3", "{d}/derive.py"], 2, r"lattice broken.*"),
        ("improving-bounded", "the boundedness clause of improving dropped",
         lambda d: edit_text(d, "derive.py", "return (ok and bounded), why", "return ok, why"),
         sc(tag), 2, r"labels.json differs from derive.py.*"),
        ("midpoint", "CONTROL: a cycle of 9.5e307 and 1e308: the tail midpoint must not overflow, so neither"
         " converged nor stable is labelled true",
         lambda d: (edit_json(d, "corpus.json", keep_rows(extra=extra_row(d, "period2_wide", id="huge_cycle",
             gen={"kind": "cycle", "values": [9.5e307, 1e308]}, n=20, checkpoints=[20]))), certify_in(d)),
         ["python3", "{d}/derive.py"], 0,
         r'"huge_cycle@20": \{"converged": \["CONVENTION", false.*"stable": \["CONVENTION", false.*'),
        ("stale-cert", "a row edited without re-certifying",
         lambda d: edit_json(d, "corpus.json", lambda c: row(c, "geo_decay_0.5")["gen"].update(a=0.6)),
         sc(tag), 2, r"geo_decay_0.5: stale certificate.*"),
        ("stale-tolerance", "derive's RTOL retuned (certify.refute reads it) without re-certifying",
         lambda d: edit_text(d, "derive.py", "RTOL = 1e-3 ", "RTOL = 1e-17 "),
         sc(tag), 2, r"stale certificate.*RTOL/SCALE.*"),
        ("ENV-step", "gen.ENV['step'] redefined", lambda d: edit_text(d, "gen.py", "1.0 if n >= c else 0.0",
                                                                   "1.0 if n > c else 0.0"),
         sc(tag), 2, r"stale certificate.*"),
        ("numbers", "--numbers ieee on the clamp binary", None, sc(tag, "--numbers", "ieee"), 2,
         r"contradicts the binary.*"),
        ("P-crash", "the reference model raises OverflowError",
         lambda d: edit_text(d, "reference.py", '    w = values[max(0, at - W):at + 1]\n',
                             '    w = values[max(0, at - W):at + 1]\n    math.exp(1000)\n'),
         sc(tag), 2, r"internal OverflowError.*"),
        ("source-unverified", "a citation's status set back to UNVERIFIED",
         lambda d: edit_json(d, "corpus.json", lambda c: c["sources"]["RUDIN_3_1"].update(
             status="UNVERIFIED: not checked against the text")),
         sc(tag), 2, r"source RUDIN_3_1: needs text and a VERIFIED status.*"),
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
         lambda d: edit_json(d, "corpus.json", keep_rows(extra=extra_row(d, "const_5", id="one_plus_tiny",
             gen={"kind": "closed", "expr": "(1.0 + 1e-17) ** n"},
             props={"limit": None, "tends_to": "+inf", "bounded": False, "deterministic": True}))),
         cf, 1, r"REFUSED one_plus_tiny: float-degenerate.*"),
        ("cert-nan-divergent", "a closed form that simplifies to n but becomes NaN in floating point",
         lambda d: edit_json(d, "corpus.json", keep_rows(extra=extra_row(d, "const_5", id="nan_divergent",
             gen={"kind": "closed", "expr": "n + ((1e150*n*n)*(1e150*n*n) - (1e150*n*n)*(1e150*n*n))"},
             n=150, checkpoints=[150], capability="ieee",
             props={"limit": None, "tends_to": "+inf", "bounded": False, "deterministic": True}))),
         cf, 1, r"REFUSED nan_divergent: float-degenerate: a value fed to the runtime is NaN.*"),
        ("cert-repelling-affine", "x <- 3x - 0.2 from 0.1 (exact decimal fixed point 1/10) stated -> 0.1: the"
         " floats the runtime is fed run away (x_60 = 3.9e11, inf from x_682)",
         lambda d: edit_json(d, "corpus.json", keep_rows(extra=extra_row(d, "halving_to_5", id="repel_fp_0.1",
             gen={"kind": "affine", "x0": 0.1, "a": 3.0, "b": -0.2},
             props={"limit": 0.1, "tends_to": None, "bounded": True, "deterministic": True}))),
         cf, 1, r"REFUSED repel_fp_0.1: \|a\| = 3 > 1: .*repelling fixed point.*"),
        ("cert-parity", "1/ln(n+2) + 0.001 (-1)^(n^2+n) stated as having no limit",
         lambda d: edit_json(d, "corpus.json", keep_rows(extra=extra_row(d, "inv_log", id="parity_inv_log",
             gen={"kind": "closed", "expr": "1.0 / math.log(n + 2) + 0.001 * (-1.0) ** (n * n + n)"},
             props={"limit": None, "tends_to": None, "bounded": True, "deterministic": True}))),
         cf, 1, r"REFUSED parity_inv_log: .*symbolic gives \{'limit': 1/1000.*"),
        ("cert-persistent", "0.001 sin(n) + 1/(n+1) certified by a manual block claiming limit 0",
         lambda d: edit_json(d, "corpus.json", keep_rows(extra=extra_row(d, "inv_log", id="sin_plus_inv",
             gen={"kind": "closed", "expr": "0.001 * math.sin(1.0 * n) + 1.0 / (n + 1)"},
             props={"limit": 0.0, "tends_to": None, "bounded": True, "deterministic": True},
             manual={"argument": "1/(n+1) -> 0 and the 0.001 sin n term is negligible", "cite": ["HARDY_58"],
                     "claims": {"limit": 0.0, "tends_to": None, "bounded": True}}))),
         cf, 1, r"REFUSED sin_plus_inv: the error \|x - L\| does not shrink toward 0.*"),
        ("cert-slow-limit", "CONTROL: 1/ln(n+2) -> 0 alone must still certify",
         lambda d: edit_json(d, "corpus.json", keep_rows("inv_log")), cf, 0, r"certified: symbolic=1,.*refused=0.*"),
        ("cert-bounded-decided", "CONTROL: ieee_inf_recover, eventually bounded (#1758), alone must certify",
         lambda d: edit_json(d, "corpus.json", keep_rows("ieee_inf_recover")), cf, 0, r"certified: symbolic=1,.*refused=0.*"),
        ("cert-timeout", "#1766: decide() slowed past a 1 s alarm on the cert-repelling corpus",
         lambda d: (edit_json(d, "corpus.json", lambda c: (keep_rows("logistic_3.9")(c),
             row(c, "logistic_3.9")["props"].update(limit=29 / 39),
             row(c, "logistic_3.9")["manual"].update(argument="x* = 1 - 1/r is the fixed point of the map",
                                                     claims={"limit": 29 / 39, "tends_to": None, "bounded": True}))),
                    edit_text(d, "certify.py", "\nALARM_S = 120 ", "\nALARM_S = 1 "),
                    edit_text(d, "certify.py", '    """(kind, verdict, detail), or raise Undecided / Refused."""\n',
                              '    """(kind, verdict, detail), or raise Undecided / Refused."""\n    __import__("time").sleep(3)\n')),
         cf, 2, r"logistic_3.9: the certifier took longer than 1 s.*"),
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
         lambda d: edit_json(d, "corpus.json", keep_rows(extra=extra_row(d, "inv_log", id="pyth_inv_log",
             gen={"kind": "closed", "expr": "math.sin(n) ** 2 + math.cos(n) ** 2 + 1.0 / math.log(n + 2)"},
             props={"limit": 1.0, "tends_to": None, "bounded": True, "deterministic": True},
             manual={"argument": "sin^2 + cos^2 = 1", "cite": ["HARDY_58"],
                     "claims": {"limit": 1.0, "tends_to": None, "bounded": True}}))),
         cf, 2, r"OBSERVER_ORACLE_ERROR: internal.*"),
        ("cert-level-shift", "CONTROL: a level shift at n = 25000 (refused in round 3 past the old 20000"
         " horizon) lies inside the 10^6 refutation horizon and certifies as limit 2",
         lambda d: edit_json(d, "corpus.json", lambda c: (keep_rows("level_shift")(c),
                                                          row(c, "level_shift")["gen"].update(expr="1.0 + step(n, 25000)"),
                                                          row(c, "level_shift").update(regime=25000, n=30000, checkpoints=[30000]))),
         cf, 0, r"certified: symbolic=1,.*refused=0.*"),
        ("cert-positional", "certify.py given a corpus path without --corpus: a usage error, the repo's"
         " certificate untouched", None, ["{venv}", "{d}/certify.py", "{d}/corpus.json"], 2,
         r"usage: certify.py \[--corpus PATH\].*",
         lambda d: None if open(os.path.join(d, "certificate.json")).read() == open(os.path.join(HERE, "certificate.json")).read()
         else "certificate.json was rewritten"),
        ("derive-corpus", "derive.py --corpus writes labels beside THAT corpus (a one-row copy here)",
         lambda d: (os.makedirs(os.path.join(d, "one")),
                    edit_json(d, "corpus.json", keep_rows("const_5")),
                    shutil.copy(os.path.join(d, "corpus.json"), os.path.join(d, "one", "corpus.json")),
                    certify_in(d), shutil.copy(os.path.join(d, "certificate.json"), os.path.join(d, "one"))),
         ["python3", "{d}/derive.py", "--corpus", "{d}/one/corpus.json", "--write"], 0, r"^$", labels_beside),
    ]


def run_plants(tag, ieee, only):
    from score import run_group
    table, red, base = plants(tag, ieee), 0, {}
    if only:
        table = [p for p in table if p[0] in only]
    names = [p[0] for p in table]
    if not table or len(set(names)) != len(names) or (only and len(table) != len(only)):
        raise SystemExit(f"plant table empty, with duplicate names, or missing a name asked for: {names}")
    for name, what, setup, argv, rc_want, line, *post in table:
        line = line() if callable(line) else line       # built only for the plants that run
        with tempfile.TemporaryDirectory(prefix=f"plant_{name}_") as tmp:
            d = os.path.join(tmp, "oracle")
            shutil.copytree(HERE, d, ignore=shutil.ignore_patterns("__pycache__"))
            saved = dict(os.environ)
            try:
                if setup:
                    setup(d)
                p = run_group([a.format(d=d, venv=VENV) for a in argv], PLANT_TIMEOUT, cwd=d)
                rc, out = p.returncode, p.stdout + p.stderr
            except subprocess.TimeoutExpired:
                rc, out = "timeout", f"MISS: timed out after {PLANT_TIMEOUT} s; its process group was killed"
            finally:
                os.environ.clear()
                os.environ.update(saved)
            if line.startswith(("DIFF:", "SAME:")):  # red iff the selected line moved (DIFF) or held (SAME)
                key = tuple(argv)
                if key not in base:
                    try:
                        base[key] = run_group([a.format(d=HERE, venv=VENV) for a in argv], PLANT_TIMEOUT, cwd=HERE).stdout
                    except subprocess.TimeoutExpired:
                        base[key] = ""
                m, b = re.search(line[5:], out, re.M), re.search(line[5:], base[key], re.M)
                moved = m is not None and b is not None and m.group(0) != b.group(0)
                m = m if b is not None and (moved if line.startswith("DIFF:") else not moved) else None
            else:
                m = re.search(line, out, re.M)
            try:
                why = post[0](d) if post and rc == rc_want and m is not None else None
            except Exception as e:          # a broken post-check is a MISS, never a crash
                why = f"post-check raised {type(e).__name__}: {e}"
            ok = rc == rc_want and m is not None and why is None
            red += ok
            shown = why or (m.group(0) if m else (out.strip().splitlines() or [""])[-1][:160])
            print(f"{'RED ' if ok else 'MISS'} {name:22} rc={rc} (want {rc_want})  {what}\n"
                  f"     {shown}", flush=True)
    print(f"plants: {len(table)} examined, {red} red (controls included: green is their red)")
    return 0 if red == len(table) else 1


def selftest():
    """The tools/selftests.txt row: build (or reuse) the floor's anchor through
    the hermetic `make observer-anchor`, then run floor-each against it through
    the real score.py --floor. Exit 0 only when the plant goes red."""
    root = os.path.dirname(os.path.dirname(HERE))
    if subprocess.run(["make", "--no-print-directory", "-C", root, "observer-anchor"], stdin=subprocess.DEVNULL).returncode:
        recipe = hashlib.sha256(open(os.path.join(HERE, "build_anchor.sh"), "rb").read()).hexdigest()
        cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
        try:
            sys.stderr.write("".join(open(os.path.join(cache, "eigs-oracle-anchor", recipe + ".log")).readlines()[-50:]))
        except OSError:
            pass
        print("OBSERVER_ORACLE_ERROR: make observer-anchor failed: no anchor to plant against", file=sys.stderr)
        return 2
    from score import anchor
    from gen import HarnessError
    try:
        binary = anchor()["binary"]
    except HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        return 2
    return run_plants(binary, binary, {"floor-each"})


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    if sys.argv[1:2] == ["wrap"]:
        wrap(sys.argv[2:])
    if sys.argv[1:2] == ["twins"]:
        sys.path.insert(0, sys.argv[2])
        from gen import HarnessError
        try:
            sys.exit(twins(sys.argv[2]))
        except HarnessError as e:
            print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
            sys.exit(2)
    args = sys.argv[1:]
    only = set()
    if "--only" in args:
        i = args.index("--only")
        only = set(args[i + 1].split(","))
        del args[i:i + 2]
    if len(args) != 2:
        raise SystemExit(__doc__)
    sys.exit(run_plants(os.path.abspath(args[0]), os.path.abspath(args[1]), only))
