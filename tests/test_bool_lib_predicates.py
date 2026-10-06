#!/usr/bin/env python3
"""#1637: every lib/ predicate returns a bool on every path -- measured, not read.

Population: the lib functions `eigenscript --api` lists whose name is
predicate-shaped (is_*, has_*, *_has, *_empty, *_equal, *_intersect*,
point_in_*, polygon_is_*, any, all, ...). Each is called on a fixed battery of
argument tuples (numbers, strings, lists, points, polygons, dicts, null, bools,
a lambda), every call in its own try. A call that RAISES is not an answer and
is ignored; a call that RETURNS must return a `bool`. Prints `type of` per
function (which types it returned, and how often true / false) and exits 0
iff no predicate returned a non-bool, the examined population equals the
declared one, every predicate answered at least once, and each answered both
true and false (except the ONE_SIDED list, each with its reason).

Usage: test_bool_lib_predicates.py BINARY [--table]
"""
import os, re, subprocess, sys, tempfile, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--")
                      else os.path.join(ROOT, "src/eigenscript"))
TABLE = "--table" in sys.argv
PRED = re.compile(r"^(is_|has_|can_)|_has$|_empty$|_equal$|s_intersect$|^point_in_|^polygon_is_|"
                  r"^(any|all|collinear|on_segment|in_range|eq_near|get_flag|"
                  r"is_one_of|utf8_validate|sm_can_send|sm_is|json_has|map_has|set_has|"
                  r"is_subset|is_superset|set_equal|git_worktree_clean|check_openai)$|"
                  r"^functional\.complement$")
# Predicates the battery cannot reach, each with its reason.
SKIP = {"wait_until": "sleeps between polls by design",
        "git_worktree_clean": "lib/pkg.eigs is a CLI script: loading it runs the dispatcher",
        "is_valid_name_part": "lib/pkg.eigs is a CLI script: loading it runs the dispatcher"}
SQ = "[[0, 0], [1, 0], [1, 1], [0, 1]]"
# Per-predicate cases that reach the answer the generic battery misses, keyed
# "module.name": (setup lines, [argument tuples]). Every predicate must be
# seen answering BOTH true and false, unless it is in ONE_SIDED with a reason.
EXTRA = {
    "complex.eq_near": ("", [["[1, 2]", "[1, 2]", "0.001"], ["[1, 2]", "[3, 2]", "0.001"]]),
    "experiment.is_measurement_stable": ("", [["[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]", "3"],
                                              ["[1, 9, 2, 8, 3, 7, 4, 6, 5, 5]", "3"]]),
    "args.get_flag": ("", [['[["--v", 1]]', '"--v"']]),
    "args.has_flag": ("", [['[["--v", 1]]', '"--v"']]),
    "functional.complement": ("", [["(x) => x > 1", "0"], ["(x) => x > 1", "5"]]),
    "geometry.collinear": ("", [["[0, 0]", "[1, 1]", "[3, 1]"]]),
    "geometry.on_segment": ("", [["[0, 0]", "[5, 5]", "[1, 1]"]]),
    "geometry.segments_intersect": ("", [["[0, 0]", "[1, 0]", "[0, 1]", "[1, 1]"]]),
    "geometry.point_in_triangle": ("", [["[5, 5]", "[0, 0]", "[1, 0]", "[0, 1]"]]),
    "geometry.point_in_polygon": ("", [["[0.5, 0.5]", SQ], ["[2, 2]", SQ]]),
    "geometry.polygon_is_clockwise": ("", [["[[0, 0], [0, 1], [1, 1], [1, 0]]"]]),
    "geometry.point_in_circle": ("", [["5", "5", "0", "0", "1"]]),
    "json.json_has": ("", [['"{\\"a\\": 1}"', '"a"'], ['"{\\"a\\": 1}"', '"b"']]),
    "lab.is_stable": ('__x is new_experiment of "t"\nfor __i in range of 12:\n    record of [__x, "v", 1.0]',
                      [["__x", '"v"']]),
    "list.any": ("", [["[1, 2, 3]", "(x) => x > 1"]]),
    "list.all": ("", [["[1, 2, 3]", "(x) => x > 1"]]),
    "map.map_has": ('__m is map_set of [map_new of null, "k", 1]', [["__m", '"k"']]),
    "observer_slots.is_stable": ("for __i in range of 12:\n    feed of [0, 5]", [["0"]]),
    "set.set_has": ("__s is set_from of ([1, 2])", [["__s", "1"]]),
    "state.sm_can_send": ('__sm is sm_add_transition of [sm_new of "idle", "idle", "go", "run"]',
                          [["__sm", '"go"']]),
    "state.sm_is": ('__sm is sm_new of "idle"', [["__sm", '"idle"']]),
    "test_runner.is_test_file": ("", [['"test_x.eigs"']]),
    "utf8.utf8_validate": ("", [["(str_from_bytes of ([255]))"]]),
}
ONE_SIDED = {
    "json.json_has": "pre-existing bug, not #1637: it tests `type of val == \"null\"` but that type is \"none\", so it always answers true",
    "observer.is_converged": "the argument is a fresh parameter binding with no trajectory (#262)",
    "observer.is_stable": "the argument is a fresh parameter binding with no trajectory (#262)",
    "observer.is_improving": "the argument is a fresh parameter binding with no trajectory (#262)",
    "observer.is_diverging": "the argument is a fresh parameter binding with no trajectory (#262)",
    "observer.is_oscillating": "the argument is a fresh parameter binding with no trajectory (#262)",
    "observer_slots.is_diverging": "a slot fed a bounded constant cannot read diverging",
    "sanitize.check_openai": "true only with an OpenAI key in the environment",
}
POOL = ["0", "1", "-1", "2.5", "10", '""', '"abc"', '"a@b.co"', '"http://x.y/z"', '"123"',
        "[]", "[1, 2, 3]", "[3, 1, 2]", "[0, 0]", "[1, 1]", "[2, 2]",
        "[[0, 0], [4, 0], [0, 4]]", "[[0, 0], [4, 0], [4, 4], [0, 4]]",
        "{}", '{"a": 1}', "null", "true", "false", "(x) => x > 1"]
ENV = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "WAYLAND_DISPLAY")}
ENV.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy", EIGS_STRICT="1")


def tuples(k):
    n = len(POOL)
    if k == 0:
        return ["null"]
    out = []
    for i in range(n):
        out.append([POOL[(i + j * 3) % n] for j in range(k)])
        out.append([POOL[i]] * k)
    return out


def main():
    api = subprocess.run([BIN, "--api"], capture_output=True, text=True).stdout.split("\n")
    fns = []
    for l in api:
        m = re.match(r"^lib (\w+)\.(\w+)\(([^)]*)\)", l)
        if m and (PRED.search(m.group(2)) or PRED.search(m.group(1) + "." + m.group(2))):
            params = [p for p in m.group(3).split(",") if p.strip()]
            fns.append((m.group(1), m.group(2), len(params)))
    declared = len(fns)
    tmp = tempfile.mkdtemp(prefix="eigs_bool_libpred.")
    examined, bad, silent, table = 0, [], [], []
    try:
        for mod, name, k in fns:
            if name in SKIP:
                examined += 1
                table.append(f"{mod}.{name}: skipped ({SKIP[name]})")
                continue
            setup, extra = EXTRA.get(f"{mod}.{name}", ("", []))
            lines = [f'load_file of "{ROOT}/lib/{mod}.eigs"'] + ([setup] if setup else [])
            for i, t in enumerate(tuples(k) + extra):
                call = f"{name} of [{', '.join(t)}]" if k >= 2 else f"{name} of ({t[0]})"
                lines += ["try:", f"    __r is {call}",
                          f'    print of ("@" + (type of __r) + ":" + (str of __r))',
                          "catch __e:", '    print of "@raised"']
            lines.append('print of "@END"')
            prog = os.path.join(tmp, "p.eigs")
            open(prog, "w").write("\n".join(lines) + "\n")
            try:
                p = subprocess.run(["bash", "-c", 'ulimit -v 1500000; exec "$0" "$1"', BIN, prog],
                                   cwd=tmp, env=ENV, stdin=subprocess.DEVNULL,
                                   capture_output=True, text=True, timeout=60)
                out = p.stdout
            except subprocess.TimeoutExpired:
                out = ""
            examined += 1
            if "@END" not in out:
                bad.append(f"{mod}.{name}: probe program did not complete")
                continue
            got = collections.Counter(re.findall(r"^@(\w+:\S*?|raised)$", out, re.M))
            types = collections.Counter(t.split(":")[0] for t in got.elements() if t != "raised")
            tf = (got["bool:true"], got["bool:false"])
            table.append(f"{mod}.{name}: types={dict(types)} true={tf[0]} false={tf[1]} raised={got['raised']}")
            nonbool = {t: c for t, c in types.items() if t != "bool"}
            if nonbool:
                bad.append(f"{mod}.{name}: returned non-bool {nonbool}")
            if not types:
                silent.append(f"{mod}.{name}")
            elif (0 in tf) and f"{mod}.{name}" not in ONE_SIDED:
                bad.append(f"{mod}.{name}: answered only {'false' if tf[0] == 0 else 'true'}; "
                           "add a case for the other answer")
    finally:
        subprocess.run(["rm", "-rf", tmp])
    if TABLE:
        print("\n".join(table))
    for b in bad:
        print("  FAIL: " + b)
    for s in silent:
        print("  FAIL: " + s + ": every battery call raised; nothing measured")
    ok = examined == declared > 0 and not bad and not silent
    print(f"BOOL_LIB_PREDICATES: examined={examined}/{declared} nonbool={len(bad)} "
          f"unmeasured={len(silent)} {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
