#!/usr/bin/env python3
"""classify.py: is a mutant's red on the base the STALL RULE's, or another predicate's?

For a mutant that the base's contract sees and the head's does not, the question is whether
the head's contract lost a witness of the stall rule, or whether the base's red came through
code the pull request replaces on purpose (the `converged` test in the loop's condition).

Method: the base's tree is built with the mutant and with a wrapper around the stall reader
that writes its decision (0 or 1) to stderr at every call when EIGS_STALL_TRACE is set. Each
case of the base's contract is run, interpreter tier, clean and mutated, and the two decision
strings are compared:
  same     the reader decided the same at every call
  prefix   one string is the start of the other (the loop ended earlier or later for another
           reason; where both ran, the reader decided the same)
  differs  the reader decided otherwise at some call
A mutant is a stall-rule fault seen by the base iff a case that is red on the base `differs`.

Usage: classify.py ID ...      (ids of sweep2.py's population)
Env as sweep2.py. Output: OUT/classify.json and a table on stdout.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sweep2 as sw  # noqa: E402

WRAP_OLD = "static inline int obs_stall_quiet(void) {\n"
WRAP_NEW = "static inline int obs_stall_quiet_impl(void) {\n"
WRAP_ADD = '''static inline int obs_stall_quiet(void) {
    static int tr = -1;
    static FILE *tf;
    int r = obs_stall_quiet_impl();
    if (tr < 0) { const char *p = getenv("EIGS_STALL_TRACE"); tf = p ? fopen(p, "a") : NULL; tr = tf != NULL; }
    if (tr) { fputc(r ? '1' : '0', tf); fflush(tf); }
    return r;
}
'''
ANCHOR = "void vm_obs_slot_dropped(Env *e) {\n"


def wrap(text):
    assert text.count(WRAP_OLD) == 1 and text.count(ANCHOR) == 1
    return text.replace(WRAP_OLD, WRAP_NEW).replace(ANCHOR, WRAP_ADD + ANCHOR)


def base_contract():
    spec = importlib.util.spec_from_file_location("bc", sw.S / "B" / "tests/phase2/stall_contract.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def traces(bc, label):
    """case -> (decision string, stdout) on the B tree as built now, interpreter tier."""
    out = {}
    with tempfile.TemporaryDirectory(prefix="classify-") as tmp:
        for case in bc.CASES:
            p = Path(tmp) / (case + ".eigs")
            t = Path(tmp) / (case + ".trace")
            p.write_text(bc.program(case))
            env = {k: v for k, v in os.environ.items() if not k.startswith("EIGS_")}
            env.update({"EIGS_JIT_OFF": "1", "EIGS_STALL_TRACE": str(t)})
            try:
                r = subprocess.run([str(sw.S / "B" / "src/eigenscript"), str(p)], cwd=sw.S / "B", env=env,
                                   capture_output=True, text=True, timeout=20)
                rc, so = r.returncode, r.stdout.strip()
            except subprocess.TimeoutExpired:
                rc, so = 124, ""
            dec = t.read_text() if t.exists() else ""
            out[case] = (dec[:200000], so, rc)
    return out


def build_b(m, log):
    """The B tree with the mutant (or none) and the wrapper."""
    for rel in (sw.VM, sw.ES):
        (sw.S / "B" / rel).write_text(sw.orig("B", rel))
    if m:
        sw.apply("B", m)
    vm = (sw.S / "B" / sw.VM).read_text()
    (sw.S / "B" / sw.VM).write_text(wrap(vm))
    return sw.build("B", log)


def relation(a, b):
    if a == b:
        return "same"
    if not a or not b:
        return "differs"  # the reader was never called on one side
    if a.startswith(b) or b.startswith(a):
        return "prefix"
    return "differs"


def main(ids):
    (sw.OUT / "logs").mkdir(parents=True, exist_ok=True)
    pop = {m["id"]: m for m in sw.population()}
    state = sw.load_state()
    bc = base_contract()
    assert build_b(None, sw.OUT / "logs" / "classify.clean.build.log") == 0
    clean = traces(bc, "clean")
    # the wrapper must not change what the contract reads
    for case, (dec, out, rc) in clean.items():
        assert rc == 0 and dec and set(dec) <= {"0", "1"}, "clean trace of %s is empty or odd (rc=%s)" % (case, rc)
    # the wrapper must not change what the contract reads: the base's whole contract, four tiers, on the wrapped build
    chk = sw.contract("B", sw.OUT / "logs" / "classify.clean.contract.log")
    assert chk["rc"] == 0 and chk["measured"] == 68 and chk["failures"] == 0, "the wrapped clean build fails the base's contract: %s" % chk
    print("clean traces: " + ", ".join("%s=%d calls/%d ones" % (c, len(d), d.count("1")) for c, (d, o, r) in clean.items()), flush=True)
    res = {}
    for mid in ids:
        m = pop[mid]
        rc = build_b(m, sw.OUT / "logs" / ("classify.%s.build.log" % mid))
        if rc:
            res[mid] = {"status": "no-build"}
            continue
        tr = traces(bc, mid)
        red = (state.get(mid, {}).get("B") or {}).get("red_cases") or []
        rel = {c: relation(clean[c][0], tr[c][0]) for c in bc.CASES}
        # The loop's counter and the gate around the reader's call are the stall rule itself, and the
        # reader does not see them: a mutant there always counts, whatever the strings say.
        always = m.get("region") == "R2" or mid in ("p3-n-skip-iter1", "p3-n-ge101", "p3-n-ge99", "p3-n-noreset")
        res[mid] = {"red_on_base": red, "relation": {c: rel[c] for c in red},
                    "differs_anywhere": sorted(c for c in rel if rel[c] == "differs"),
                    "stall_rule_fault": always or any(rel[c] == "differs" for c in red)}
        print("%s | red on base: %s | reader on those: %s | stall-rule fault seen by the base: %s" % (
            mid, ", ".join(red), ", ".join("%s=%s" % (c, rel[c]) for c in red), res[mid]["stall_rule_fault"]), flush=True)
    (sw.OUT / "classify.json").write_text(json.dumps(res, indent=1))
    for rel in (sw.VM, sw.ES):
        (sw.S / "B" / rel).write_text(sw.orig("B", rel))
    assert sw.build("B", sw.OUT / "logs" / "classify.restore.build.log") == 0
    print("CLASSIFY-DONE %d" % len(ids))


if __name__ == "__main__":
    main(sys.argv[1:])
