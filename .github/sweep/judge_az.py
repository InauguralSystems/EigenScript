#!/usr/bin/env python3
"""The one mutant filed as undefined behaviour, under three judges, on both sides.

R3-DEL-obs_num_bounded_oscillating+11-e6626a deletes the only assignment of `az`, which
the next line reads. Judges: the sanitizer build the bar names (`make asan`); memcheck on
the -O1 `make valgrind` build; clang's MemorySanitizer, if that build links. Each runs the
two cases the base's contract goes red on (`doubling`, `loop-exit`), clean first, then mutated.
"""
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sweep2 as sw  # noqa: E402

MID = "R3-DEL-obs_num_bounded_oscillating+11-e6626a"


def contract(arm):
    p = sw.S / arm / "tests/phase2/stall_contract.py"
    spec = importlib.util.spec_from_file_location("c_" + arm, str(p))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def make(arm, args, log):
    with open(log, "w") as f:
        return subprocess.run(["make", "-j4", "-C", str(sw.S / arm)] + args, stdout=f, stderr=subprocess.STDOUT).returncode


def run(arm, prefix, case, label, env_extra):
    c = contract(arm)
    prog = sw.OUT / ("%s.%s.eigs" % (arm, case))
    prog.write_text(c.program(case))
    env = {k: v for k, v in os.environ.items() if not k.startswith("EIGS_")}
    env.update({"EIGS_JIT_OFF": "1"})
    env.update(env_extra)
    try:
        r = subprocess.run(prefix + [str(sw.S / arm / "src/eigenscript"), str(prog)], cwd=sw.S / arm, env=env,
                           capture_output=True, text=True, timeout=900)
        rc, out, err = r.returncode, r.stdout.strip(), r.stderr
    except subprocess.TimeoutExpired:
        rc, out, err = 124, "", "timeout"
    (sw.OUT / ("%s.%s.%s.stderr.txt" % (label, arm, case))).write_text(err)
    hits = [l.strip() for l in err.splitlines() if "ninitiali" in l or "runtime error" in l or "ERROR: " in l or "WARNING: MemorySanitizer" in l]
    print("%-28s %s %-10s rc=%-3d stdout=%-44s report lines=%d %s" % (label, arm, case, rc, out[:44], len(hits), (hits[:1] or [""])[0][:110]), flush=True)


JUDGES = [
    ("asan", ["asan"], [], {"ASAN_OPTIONS": "detect_leaks=0:halt_on_error=1", "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1"}),
    ("valgrind-O1", ["valgrind"], ["valgrind", "--error-exitcode=9", "--track-origins=yes", "-q"], {}),
    ("msan-clang", ["asan", "CC=clang", "ASAN_FLAGS=-fsanitize=memory -fsanitize-memory-track-origins -fno-omit-frame-pointer -g -O1"],
     [], {"MSAN_OPTIONS": "halt_on_error=1"}),
]

pop = {m["id"]: m for m in sw.population()}
(sw.OUT / "logs").mkdir(parents=True, exist_ok=True)
for name, margs, prefix, env in JUDGES:
    for state in ("clean", "mutant"):
        for arm in ("B", "H"):
            for rel in (sw.VM, sw.ES):
                (sw.S / arm / rel).write_text(sw.orig(arm, rel))
            if state == "mutant":
                sw.apply(arm, pop[MID])
            if name == "msan-clang":
                subprocess.run(["rm", "-rf", str(sw.S / arm / "build" / "asan")])
            rc = make(arm, margs, sw.OUT / "logs" / ("%s.%s.%s.build.log" % (name, state, arm)))
            warn = [l for l in open(sw.OUT / "logs" / ("%s.%s.%s.build.log" % (name, state, arm))).read().splitlines() if "ninitialized" in l]
            print("%s %s %s build rc=%d %s" % (name, state, arm, rc, (warn[:1] or [""])[0][:120]), flush=True)
            if rc:
                continue
            for case in ("doubling", "loop-exit"):
                run(arm, prefix, case, "%s.%s" % (name, state), env)
    if name == "msan-clang":
        for arm in ("B", "H"):
            subprocess.run(["rm", "-rf", str(sw.S / arm / "build" / "asan")])
print("JUDGE-DONE")
