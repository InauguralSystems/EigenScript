#!/usr/bin/env python3
"""#1637: a numeric builtin given a bool RAISES, in every strict mode.

Population: every name `eigenscript --api` lists as a builtin, plus the
extension builtins of a capability the binary implements. For each name the
binary itself says whether it is numeric, by two oracles that do not read the
source:

  A string is REFUSED when it raises a type_mismatch (strict on), or when it
  silently answers null/empty where the number answered a full value
  (`zeros of "s"` is null where `zeros of 1` is a buffer).
  unary     `f of 1` runs and `f of "s"` is refused
            -> `f of true` must raise a type_mismatch with EIGS_STRICT=1 AND
            EIGS_STRICT=0.
  list      `f of ([1, 2])` runs and `f of (["s", "t"])` is a type error ->
            each slot where a string alone is a type error must refuse a bool
            there in both modes.
  tuple     every row of tests/strict_shape_cases.json whose valid call runs:
            an argument slot is numeric when its valid value is a numeric
            literal AND putting a string there raises (strict on) -- a slot
            that takes any value (`send of [ch, v]`) is not numeric. Each
            numeric slot given `true` must raise in both modes.

A probe that raises must raise a catchable error; a crash, a timeout or an
uncaught error is a FAIL, never a pass. Prints one line per violation and a
summary; exit 0 iff no violation and the examined population is the declared
one. Usage: test_bool_numeric.py BINARY   (cwd: anything; runs in a temp dir)
"""
import json, os, re, subprocess, sys, tempfile, wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "src/eigenscript"))
# Never touch a live display; SDL runs headless.
ENV = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "WAYLAND_DISPLAY")}
ENV.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
# Names a probe cannot call: they end the process, block on input, close a
# standard descriptor (`proc_close of 1` is stdout), or are reserved forms
# rather than functions (`report` is E005 outside `report of <name>`), or
# raise by definition (`throw`).
SKIP = {"exit", "raw_key", "read_line", "task_recv", "recv", "thread_join",
        "proc_close", "report", "throw"}
NUMLIT = re.compile(r"^-?[0-9]+(\.[0-9]+)?$|^\(0 - [0-9.]+\)$|^0 - [0-9.]+$")
TMP = tempfile.mkdtemp(prefix="eigs_bool_numeric.")
WAV = os.path.join(TMP, "t.wav")
with wave.open(WAV, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100); w.writeframes(b"\0\0" * 32)


def run(src, strict):
    env = dict(ENV, EIGS_STRICT=strict)
    path = os.path.join(TMP, "p.eigs")
    with open(path, "w") as f:
        f.write(src)
    try:
        p = subprocess.run(["bash", "-c", 'ulimit -v 1500000; exec "$0" "$1"', BIN, path],
                           cwd=TMP, env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    return p.returncode, p.stdout


SHAPE = """define __shape(v) as:
    local t is type of v
    if t == "none":
        return "E"
    if t == "str" or t == "list" or t == "dict" or t == "buffer":
        if (len of v) == 0:
            return "E"
    return "F"
"""


def probe_program(setup, calls):
    """One program, one marker line per call: R:<kind> (raised) or V:E / V:F
    (returned an empty/null value, or a full one)."""
    lines = [SHAPE] + ([setup] if setup else [])
    for i, c in enumerate(calls):
        lines += ["try:", f"    __r{i} is {c}", f'    print of ("@{i}:V:" + (__shape of __r{i}))',
                  "catch __e:", f'    print of ("@{i}:R:" + __e.kind)']
    lines.append('print of "@END"')
    return "\n".join(lines) + "\n"


def verdicts(src, strict, n):
    rc, out = run(src, strict)
    marks = dict(re.findall(r"@(\d+):(V:[EF]|R:\w+)$", out or "", re.M))
    if rc != 0 or "@END" not in (out or "") or len(marks) != n:
        return None
    return [marks[str(i)] for i in range(n)]


def main():
    api = subprocess.run([BIN, "--api"], capture_output=True, text=True).stdout.split("\n")
    names = [l.split()[1] for l in api if l.startswith("builtin ")]
    names += [l.split()[2] for l in api if l.startswith("extension gfx ")]
    declared = len(names)
    examined, violations, unary, listy, broken = 0, [], [], [], []
    for f in names:
        if f in SKIP:
            examined += 1
            continue
        calls = [f"{f} of 1", f'{f} of "s"', f"{f} of ([1, 2])", f'{f} of (["s", "t"])']
        v1 = verdicts(probe_program("", calls), "1", len(calls))
        examined += 1
        if v1 is None:
            broken.append(f)
            continue
        T = "R:type_mismatch"
        # A string is REFUSED when it is a type error, or when it silently
        # answers null/empty where a number answered a full value.
        refused = lambda good, s: s == T or (good == "V:F" and s == "V:E")
        bad = []
        if v1[0].startswith("V") and refused(v1[0], v1[1]):
            unary.append(f)
            bad.append(f"{f} of true")
        if v1[2].startswith("V") and refused(v1[2], v1[3]):
            # Per slot: a slot is numeric when a string THERE is refused.
            per = verdicts(probe_program("", [f'{f} of (["s", 2])', f'{f} of ([1, "s"])']), "1", 2) or []
            slots = [i for i, g in enumerate(per) if refused(v1[2], g)]
            if slots:
                listy.append(f)
            if 0 in slots:
                bad.append(f"{f} of ([true, 2])")
            if 1 in slots:
                bad.append(f"{f} of ([1, true])")
        for strict in ("1", "0"):
            got = verdicts(probe_program("", bad), strict, len(bad)) if bad else []
            for call, g in zip(bad, got or ["?"] * len(bad)):
                if g != T:
                    violations.append(f"{call} (EIGS_STRICT={strict}) did not raise a type error ({g})")
    # Tuple builtins: the reviewed valid calls in strict_shape_cases.json.
    cases = json.load(open(os.path.join(ROOT, "tests/strict_shape_cases.json")))
    avail = set(names)
    tuple_rows = tuple_slots = tuple_skipped = 0
    for c in cases:
        f = c["name"]
        if f not in avail or f in SKIP:
            tuple_skipped += 1
            continue
        sub = lambda s: (s or "").replace("@TMP@", TMP).replace("@WAV@", WAV)
        args = [sub(a) for a in c["args"]]
        setup = sub(c.get("setup", ""))
        lits = [i for i, a in enumerate(args) if NUMLIT.match(a.strip())]
        calls = [f"{f} of [{', '.join(args)}]"]
        for i in lits:
            a = list(args); a[i] = '"s"'
            calls.append(f"{f} of [{', '.join(a)}]")
        got = verdicts(probe_program(setup, calls), "1", len(calls))
        if not got or not got[0].startswith("V"):
            tuple_skipped += 1
            continue
        slots = [i for i, g in zip(lits, got[1:])
                 if g == "R:type_mismatch" or (got[0] == "V:F" and g == "V:E")]
        if not slots:
            tuple_skipped += 1
            continue
        tuple_rows += 1
        bad = []
        for i in slots:
            a = list(args); a[i] = "true"
            bad.append(f"{f} of [{', '.join(a)}]")
        tuple_slots += len(bad)
        for strict in ("1", "0"):
            got = verdicts(probe_program(setup, bad), strict, len(bad))
            for call, g in zip(bad, got or ["?"] * len(bad)):
                if g != "R:type_mismatch":
                    violations.append(f"{call} (EIGS_STRICT={strict}) did not raise a type error ({g})")
    for v in violations:
        print("  FAIL: " + v)
    for b in broken:
        print("  FAIL: probe program for " + b + " did not complete")
    ok = (examined == declared > 0 and not violations and not broken
          and len(unary) > 0 and tuple_rows > 0)
    print(f"BOOL_NUMERIC: examined={examined}/{declared} unary={len(unary)} list={len(listy)} "
          f"tuple_rows={tuple_rows} tuple_slots={tuple_slots} tuple_skipped={tuple_skipped} "
          f"violations={len(violations)} broken={len(broken)} {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        subprocess.run(["rm", "-rf", TMP])
