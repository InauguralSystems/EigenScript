#!/usr/bin/env bash
# #2320: section [137] (ext_gfx.c under ASan+UBSan+LSan, #1007) runs ONCE per
# CI run -- in linux / gcc -- and every other Linux lane defers it through the
# reviewed allowlist. This file proves the arrangement cannot go quietly wrong.
#
#   tests/test_gfx137_once_2320.sh             check the tree
#   tests/test_gfx137_once_2320.sh --selftest  control + planted faults
#
# Checks (each reads the REAL file: ci.yml via PyYAML and a small evaluator for
# its `${{ }}` expressions, the allowlist, tools/gfx137_once.sh by running it,
# and the runner's own [137] block by executing it against a stub corpus):
#   C1 merge queue: exactly ONE Linux container lane runs [137] undeferred, and
#      it is the owner the allowlist names (absence is red; two is red).
#   C2 every deferral id ci.yml can produce is on the allowlist, every
#      allowlist id is produced somewhere (no stale waivers), and the
#      allowlist parses (three non-empty fields, unique ids).
#   C3 native lanes (macOS, release dry-runs: other toolchains) never defer,
#      and no other workflow or action file sets EIGS_GFX137_DEFER.
#   C4 pull request: the owner runs [137] when scope says gfx137=true AND when
#      the verdict is missing (fail closed); it defers, allowlisted, only on
#      gfx137=false; no other container lane runs it undeferred on a PR.
#   C5 every dispatch lane that runs a [137]-bearing Linux suite runs [137]
#      undeferred exactly once.
#   C6 the scope job exports gfx137 from `tools/gfx137_once.sh scope`, and the
#      owner job needs the scope job.
#   C7 the owner job checks its receipt (`tools/gfx137_once.sh receipt`) on the
#      log its suite step tees, under the suite step's own `if:`.
#   C8 `defer`: a listed id passes and names its owner; an unlisted id, a row
#      with no reason and a duplicate id each fail.
#   C9 the runner's [137] block, executed with a stub test_asan_gfx.sh: a
#      listed deferral is one counted skip that never runs the corpus; an
#      unlisted one is a FAIL; a clean run prints the `GFX137: ran` receipt; a
#      skipped or failed corpus prints no receipt.
#   C10 `scope`: an ext_gfx.c edit, a corpus file, a rename away from
#      ext_gfx.c and a Makefile edit run [137]; a docs edit, a vm.c edit and a
#      lib/ui*.eigs edit do not.
#   C11 `receipt`: the owner needs exactly one `ran` line and no deferral; a
#      deferring lane needs exactly its own deferral line and no run.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null 2>&1 || { echo "gfx137_once: INSTRUMENT ERROR: python3 missing"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "gfx137_once: INSTRUMENT ERROR: PyYAML missing"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "gfx137_once: INSTRUMENT ERROR: git missing"; exit 2; }
BASH_BIN=$(command -v bash)
W=$(mktemp -d "${TMPDIR:-/tmp}/gfx137_once.XXXXXX"); trap 'rm -rf "$W"' EXIT

# static_checks CI ALLOW -> "ok Cn ..." / "bad Cn: why" lines for C1-C7.
static_checks() {
    python3 - "$1" "$2" <<'PY'
import itertools, os, re, sys, yaml
ci_path, allow_path = sys.argv[1:3]
OWNER_JOB, OWNER_COMBO = "build-and-test-linux", {"cc": "gcc"}
out = {f"C{i}": [] for i in range(1, 8)}
def bad(c, m): out[c].append(m)
wf = yaml.safe_load(open(ci_path))
jobs, wenv = wf["jobs"], wf.get("env") or {}

allow, owners = {}, set()
for n, line in enumerate(open(allow_path), 1):
    if re.match(r"^\s*(#|$)", line): continue
    f = [x.strip() for x in line.rstrip("\n").split("|", 2)]
    if len(f) < 3 or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", f[0]) or not f[1] or not f[2]:
        bad("C2", f"allowlist line {n} is not `id | owner | reason` with all three non-empty"); continue
    if f[0] in allow: bad("C2", f"allowlist id {f[0]} is listed twice"); continue
    allow[f[0]] = f[1]; owners.add(f[1])
if not allow: bad("C2", "allowlist has no entries")

# --- a small evaluator for the expressions these jobs use -------------------
TOK = re.compile(r"\s*(?:('[^']*')|(==|!=|&&|\|\||\(|\)|!)|([A-Za-z_][\w.-]*\(\))|([A-Za-z_][\w.-]*))")
def ev(expr, ctx):
    py, pos, s = [], 0, expr.strip()
    while pos < len(s):
        m = TOK.match(s, pos)
        if not m or m.end() == pos: raise ValueError(f"cannot tokenise {s[pos:]!r}")
        pos = m.end(); lit, op, fn, name = m.groups()
        if lit is not None: py.append(repr(lit[1:-1]))
        elif op: py.append({"&&": " and ", "||": " or ", "!": " not "}.get(op, op))
        elif fn:
            if fn not in ("always()", "success()"): raise ValueError(f"unsupported function {fn}")
            py.append("True")
        elif name in ("true", "false", "null"): py.append({"true": "True", "false": "False", "null": "None"}[name])
        else:
            if name not in ctx: raise ValueError(f"unknown context {name}")
            py.append(repr(ctx[name]))
    return eval("".join(py), {"__builtins__": {}}, {})
def value(v, ctx):
    s = str(v).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", s, re.S)
    if m: return ev(m.group(1), ctx)
    if "${{" in s: raise ValueError(f"mixed expression {s!r}")
    return s
def cond(v, ctx):
    if v is None or v == "": return True
    return bool(value(v if "${{" in str(v) else "${{ " + str(v) + " }}", ctx))
def combos(j):
    m = (j.get("strategy") or {}).get("matrix")
    if not isinstance(m, dict): return [{}]
    keys = [k for k in m if k not in ("include", "exclude")]
    cs = [dict(zip(keys, v)) for v in itertools.product(*[m[k] for k in keys])] if keys else []
    return cs + [dict(i) for i in m.get("include") or [] if not keys]
def name(jid, j, c):
    return re.sub(r"\$\{\{\s*matrix\.([\w-]+)\s*\}\}", lambda mo: str(c.get(mo.group(1), "?")), str(j.get("name", jid)))

suite = []   # (jid, combo, step, job) for every step that runs the full suite
for jid, j in jobs.items():
    for st in j.get("steps") or []:
        if isinstance(st, dict) and "run_all_tests.sh" in str(st.get("run", "")):
            secs = (st.get("env") or {}).get("EIGS_SUITE_SECTIONS")
            if secs is not None and "137" not in str(secs).split(): continue
            for c in combos(j): suite.append((jid, c, st, j))
if not any(jid == OWNER_JOB for jid, *_ in suite): bad("C1", f"no suite step in {OWNER_JOB}")

def scenario(event, lanes=None, gfx=None):
    """[(jid, combo, sharded, container, defer)] for each suite run in this event."""
    rows = []
    for jid, c, st, j in suite:
        ctx = {"github.event_name": event, "inputs.lanes": lanes, "needs.scope.outputs.code": "true",
               "needs.scope.outputs.gfx137": gfx, **{f"matrix.{k}": v for k, v in c.items()}}
        if not cond(j.get("if"), ctx) or not cond(st.get("if"), ctx): continue
        env = {**wenv, **(j.get("env") or {}), **(st.get("env") or {})}
        d = value(env["EIGS_GFX137_DEFER"], ctx) if "EIGS_GFX137_DEFER" in env else ""
        rows.append((jid, c, "EIGS_SUITE_SHARD" in (st.get("env") or {}), "container" in j, d or ""))
    return rows
def runners(rows):   # a sharded job runs [137] in ONE of its shards: count the job once
    seen = []
    for jid, c, sh, cont, d in rows:
        if cont and not d:
            k = (jid,) if sh else (jid, tuple(sorted(c.items())))
            if k not in seen: seen.append(k)
    return seen
produced = set()
def note(rows):
    for jid, c, sh, cont, d in rows:
        if d:
            produced.add(d)
            if d not in allow: bad("C2", f"{name(jid, jobs[jid], c)} defers [137] as {d!r}, which the allowlist does not list")

try:
    # C1 / C3: the merge queue
    rows = scenario("merge_group"); note(rows)
    r = runners(rows)
    if len(r) != 1: bad("C1", f"merge queue: {len(r)} Linux container lane(s) run [137] undeferred, want exactly 1: {r}")
    elif r[0] != (OWNER_JOB, tuple(sorted(OWNER_COMBO.items()))): bad("C1", f"merge queue: [137] runs in {r[0]}, not the owner {OWNER_JOB} {OWNER_COMBO}")
    want_owner = name(OWNER_JOB, jobs.get(OWNER_JOB, {}), OWNER_COMBO)
    if owners and owners != {want_owner}: bad("C1", f"allowlist names owner(s) {sorted(owners)}, but the queue's runner is {want_owner!r}")
    for jid, c, sh, cont, d in rows:
        if not cont and d: bad("C3", f"native lane {name(jid, jobs[jid], c)} defers [137] ({d!r}); its toolchain is not covered anywhere else")
    for jid, j in jobs.items():
        if "container" not in j:
            envs = [j.get("env") or {}] + [s.get("env") or {} for s in j.get("steps") or [] if isinstance(s, dict)]
            if any("EIGS_GFX137_DEFER" in e for e in envs): bad("C3", f"native job {jid} sets EIGS_GFX137_DEFER")
    for base, _, files in os.walk(os.path.dirname(os.path.dirname(ci_path))):
        for fn in files:
            p = os.path.join(base, fn)
            if fn.endswith((".yml", ".yaml")) and os.path.basename(p) != os.path.basename(ci_path) and "EIGS_GFX137_DEFER" in open(p, errors="replace").read():
                bad("C3", f"{os.path.relpath(p, os.path.dirname(os.path.dirname(ci_path)))} sets EIGS_GFX137_DEFER (only ci.yml's Linux lanes may)")
    if not out["C1"]: out["C1"].insert(0, f"ok:merge queue runs [137] once, in {want_owner}")
    # C4: pull requests
    for gfx, want_run in (("true", True), (None, True), ("", True), ("false", False)):
        rows = scenario("pull_request", gfx=gfx); note(rows)
        own = [d for jid, c, sh, cont, d in rows if jid == OWNER_JOB and c == OWNER_COMBO]
        if len(own) != 1: bad("C4", f"PR gfx137={gfx!r}: the owner's suite step ran {len(own)} time(s)"); continue
        if want_run and own[0]: bad("C4", f"PR gfx137={gfx!r}: the owner defers [137] as {own[0]!r}; it must run it (fail closed)")
        if not want_run and not own[0]: bad("C4", f"PR gfx137={gfx!r}: the owner runs [137]; a scoped-out PR must defer it, named")
        if not want_run and own[0] and own[0] not in allow: bad("C4", f"PR gfx137=false: deferral {own[0]!r} is not allowlisted")
        extra = [x for x in runners(rows) if x[0] != OWNER_JOB]
        if extra: bad("C4", f"PR gfx137={gfx!r}: other lanes run [137] undeferred: {extra}")
    # C5: dispatch
    for lanes in ("all", "linux", "asan", "fuzz", "tsan"):
        rows = scenario("workflow_dispatch", lanes=lanes); note(rows)
        if any(cont for *_, cont, d in rows) and len(runners(rows)) != 1:
            bad("C5", f"dispatch lanes={lanes}: {len(runners(rows))} Linux lane(s) run [137] undeferred, want 1: {runners(rows)}")
except Exception as e:  # noqa: BLE001
    bad("C1", f"cannot evaluate ci.yml: {e.__class__.__name__}: {e}")
stale = sorted(set(allow) - produced)
if stale: bad("C2", f"allowlist ids no ci.yml lane ever produces (stale waivers): {stale}")

# C6: scope exports gfx137 from the tool, the owner needs scope
sc = jobs.get("scope") or {}
ref = re.fullmatch(r"\$\{\{\s*steps\.([\w-]+)\.outputs\.gfx137\s*\}\}", str((sc.get("outputs") or {}).get("gfx137", "")).strip())
st = next((s for s in sc.get("steps") or [] if ref and isinstance(s, dict) and s.get("id") == ref.group(1)), None)
if not st: bad("C6", "scope job has no gfx137 output backed by a step")
elif "tools/gfx137_once.sh scope" not in str(st.get("run", "")) or "GITHUB_OUTPUT" not in str(st.get("run", "")):
    bad("C6", "scope's gfx137 step does not write `tools/gfx137_once.sh scope` to GITHUB_OUTPUT")
nd = jobs.get(OWNER_JOB, {}).get("needs") or []
if "scope" not in ([nd] if isinstance(nd, str) else nd): bad("C6", f"{OWNER_JOB} does not need scope, so needs.scope.outputs.gfx137 is empty")
# C7: the owner checks its receipt on the log its suite step writes
steps = [s for s in jobs.get(OWNER_JOB, {}).get("steps") or [] if isinstance(s, dict)]
si = next((i for i, s in enumerate(steps) if "run_all_tests.sh" in str(s.get("run", ""))), None)
ri = next((i for i, s in enumerate(steps) if "tools/gfx137_once.sh receipt" in str(s.get("run", ""))), None)
if si is None or ri is None: bad("C7", f"{OWNER_JOB}: no {'suite' if si is None else 'receipt'} step")
else:
    tee = re.search(r"tee\s+(\S+)", str(steps[si].get("run", "")))
    if ri < si: bad("C7", "the receipt step runs before the suite")
    elif not tee or tee.group(1) not in str(steps[ri].get("run", "")): bad("C7", "the receipt step does not read the log the suite step tees")
    elif str(steps[ri].get("if", "")) != str(steps[si].get("if", "")): bad("C7", "the receipt step's if: differs from the suite step's")
    elif "pipefail" not in str(steps[si].get("run", "")): bad("C7", "the suite step pipes into tee without pipefail: a red suite would read green")
    elif any("EIGS_GFX137_DEFER" in (s.get("env") or {}) for s in (steps[si], steps[ri])): bad("C7", "a step overrides the job's EIGS_GFX137_DEFER: suite and receipt could disagree")
for c in sorted(out, key=lambda k: int(k[1:])):
    ms = [m for m in out[c] if not m.startswith("ok:")]
    print(f"bad {c}: " + "; ".join(ms) if ms else f"ok {c}" + (f" ({out[c][0][3:]})" if out[c] else ""))
PY
}

# defer_checks TOOL ALLOW -> C8
defer_checks() {
    local tool=$1 allow=$2 out rc why="" id
    id=$(awk -F'|' '!/^[[:space:]]*(#|$)/ {gsub(/[[:space:]]/, "", $1); print $1; exit}' "$allow")
    out=$(GFX137_ALLOWLIST="$allow" "$BASH_BIN" "$tool" defer "$id" 2>&1); rc=$?
    [ "$rc" -eq 0 ] && [[ $out == "[137] deferred in lane $id to "* ]] || why="$why listed '$id' -> rc=$rc '$out';"
    out=$(GFX137_ALLOWLIST="$allow" "$BASH_BIN" "$tool" defer no-such-lane 2>&1); rc=$?
    [ "$rc" -ne 0 ] || why="$why unlisted id accepted;"
    printf 'lane-a | linux / gcc |\n' > "$W/noreason.txt"
    out=$(GFX137_ALLOWLIST="$W/noreason.txt" "$BASH_BIN" "$tool" defer lane-a 2>&1); rc=$?
    [ "$rc" -ne 0 ] || why="$why row without a reason accepted;"
    printf 'lane-a | linux / gcc | r1\nlane-a | linux / gcc | r2\n' > "$W/dup.txt"
    out=$(GFX137_ALLOWLIST="$W/dup.txt" "$BASH_BIN" "$tool" defer lane-a 2>&1); rc=$?
    [ "$rc" -ne 0 ] || why="$why duplicate id accepted;"
    if [ -z "$why" ]; then echo "ok C8 (listed id passes; unlisted, reasonless and duplicate refused)"; else echo "bad C8:$why"; fi
}

# runner_checks RUNNER TOOL ALLOW -> C9: execute the runner's real [137] block.
runner_checks() {
    local runner=$1 tool=$2 allow=$3 d="$W/rb" why="" out
    rm -rf "$d"; mkdir -p "$d/tests" "$d/tools"
    cp "$tool" "$d/tools/gfx137_once.sh"
    awk '/^echo "\[137\] /{on=1} on{print} on && /^echo ""$/{exit}' "$runner" > "$d/block.sh"
    grep -q 'test_asan_gfx.sh' "$d/block.sh" || { echo "bad C9: cannot find the [137] block in $runner"; return; }
    cat > "$d/tests/test_asan_gfx.sh" <<'EOF'
echo corpus-ran >> "$STUB_LOG"
case "$STUB_MODE" in
  pass) echo "ASan gfx: 16 passed, 0 failed" ;;
  skip) echo "  SKIP: AddressSanitizer not available"; echo "ASan gfx: 0 passed, 0 failed (skipped)" ;;
  fail) echo "  FAIL: planted"; echo "ASan gfx: 15 passed, 1 failed"; exit 1 ;;
esac
EOF
    cat > "$d/harness.sh" <<'EOF'
TESTS_DIR=$1; TOTAL=0; PASS=0; FAIL=0; SKIPPED=0
section_skip() { echo "  SKIP: $1"; SKIPPED=$((SKIPPED + 1)); }
. "$2"
echo "COUNTS total=$TOTAL pass=$PASS fail=$FAIL skipped=$SKIPPED"
EOF
    # case MODE DEFER WANT-COUNTS WANT-RECEIPT CORPUS-RAN
    rcase() {
        local mode=$1 defer=$2 counts=$3 receipt=$4 ran=$5 got
        : > "$d/stub.log"
        out=$(cd "$d" && STUB_LOG="$d/stub.log" STUB_MODE=$mode EIGS_GFX137_DEFER=$defer GFX137_ALLOWLIST="$allow" \
              "$BASH_BIN" harness.sh "$d/tests" "$d/block.sh" 2>&1)
        got=$(printf '%s\n' "$out" | sed -n 's/^COUNTS //p')
        [ "$got" = "$counts" ] || why="$why mode=$mode defer='$defer': counts '$got', want '$counts';"
        case "$receipt" in
            -) ! printf '%s\n' "$out" | grep -q '^  GFX137: ' || why="$why mode=$mode defer='$defer': printed a receipt;" ;;
            *) [ "$(printf '%s\n' "$out" | grep -c '^  GFX137: ')" = 1 ] && printf '%s\n' "$out" | grep -qxF "  GFX137: $receipt" \
                   || why="$why mode=$mode defer='$defer': no single '  GFX137: $receipt' line;" ;;
        esac
        [ "$(grep -c corpus-ran "$d/stub.log")" = "$ran" ] || why="$why mode=$mode defer='$defer': corpus ran $(grep -c corpus-ran "$d/stub.log")x, want $ran;"
    }
    local listed
    listed=$(awk -F'|' '!/^[[:space:]]*(#|$)/ {gsub(/[[:space:]]/, "", $1); print $1; exit}' "$allow")
    rcase pass "$listed"      "total=0 pass=0 fail=0 skipped=1" "deferred lane=$listed" 0
    rcase pass no-such-lane   "total=1 pass=0 fail=1 skipped=0" - 0
    rcase pass ""             "total=1 pass=1 fail=0 skipped=0" "ran" 1
    rcase skip ""             "total=0 pass=0 fail=0 skipped=1" - 1
    rcase fail ""             "total=1 pass=0 fail=1 skipped=0" - 1
    if [ -z "$why" ]; then echo "ok C9 (listed deferral = 1 counted skip, corpus not run; unlisted = FAIL; pass prints the receipt; skip/fail print none)"
    else echo "bad C9:$why"; fi
}

# scope_checks TOOL -> C10, on a tiny history.
scope_checks() {
    local tool=$1 d="$W/git" why="" n=0
    rm -rf "$d"; mkdir -p "$d"
    git -C "$d" init -q; git -C "$d" symbolic-ref HEAD refs/heads/base
    mkdir -p "$d/src" "$d/docs" "$d/lib" "$d/tests/gfx_asan_corpus"
    echo 'int g;' > "$d/src/ext_gfx.c"; echo 'int v;' > "$d/src/vm.c"; echo doc > "$d/docs/x.md"
    echo 'x is 1' > "$d/lib/ui_w_basic.eigs"; echo 'all:' > "$d/Makefile"
    git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m base
    sc() {   # sc WANT MUTATION
        local want=$1 got; shift
        n=$((n + 1)); git -C "$d" checkout -q -B "t$n" base
        ( cd "$d" && eval "$*" )
        git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m "t$n"
        got=$(cd "$d" && "$BASH_BIN" "$tool" scope HEAD~1 HEAD 2>/dev/null)
        [ "$got" = "gfx137=$want" ] || why="$why '$*' -> '$got', want gfx137=$want;"
    }
    sc true  'echo "int h;" >> src/ext_gfx.c'
    sc true  'echo "print of 1" > tests/gfx_asan_corpus/07_new.eigs'
    sc true  'git mv src/ext_gfx.c src/gfx_moved.c'
    sc true  'echo "x:" >> Makefile'
    sc false 'echo more >> docs/x.md'
    sc false 'echo "int w;" >> src/vm.c'
    sc false 'echo "y is 2" >> lib/ui_w_basic.eigs'
    if [ -z "$why" ]; then echo "ok C10 ($n diffs classified)"; else echo "bad C10:$why"; fi
}

# receipt_checks TOOL -> C11
receipt_checks() {
    local tool=$1 why="" rc
    printf '[137] x\n  PASS: ok\n  GFX137: ran\n' > "$W/ran.log"
    printf '[137] x\n  SKIP: [137] deferred\n  GFX137: deferred lane=extensions-zlib\n' > "$W/def.log"
    printf '[137] x\n  SKIP: AddressSanitizer not available\n' > "$W/none.log"
    printf '  GFX137: ran\n  GFX137: ran\n' > "$W/two.log"
    rck() {   # rck WANT-RC DEFER LOG
        env EIGS_GFX137_DEFER="$2" "$BASH_BIN" "$tool" receipt "$3" >/dev/null 2>&1; rc=$?
        [ "$rc" -eq "$1" ] || why="$why defer='$2' $(basename "$3") -> rc=$rc, want $1;"
    }
    rck 0 ""              "$W/ran.log"
    rck 1 ""              "$W/def.log"
    rck 1 ""              "$W/none.log"
    rck 1 ""              "$W/two.log"
    rck 0 extensions-zlib "$W/def.log"
    rck 1 linux-clang     "$W/def.log"
    rck 1 extensions-zlib "$W/ran.log"
    rck 1 ""              "$W/no-such.log"
    if [ -z "$why" ]; then echo "ok C11 (owner needs one ran line; a deferring lane needs its own deferral)"; else echo "bad C11:$why"; fi
}

run_checks() {   # run_checks CI ALLOW TOOL RUNNER [CHECK] -- CHECK limits the run to its group
    local only=${5:-all}
    case "$only" in all|C[1-7]) static_checks "$1" "$2" ;; esac
    case "$only" in all|C8) defer_checks "$3" "$2" ;; esac
    case "$only" in all|C9) runner_checks "$4" "$3" "$2" ;; esac
    case "$only" in all|C10) scope_checks "$3" ;; esac
    case "$only" in all|C11) receipt_checks "$3" ;; esac
}

CI="$ROOT/.github/workflows/ci.yml" ALLOWF="$ROOT/tests/gfx137_defer_allowlist.txt"
TOOL="$ROOT/tools/gfx137_once.sh" RUNNER="$ROOT/tests/run_all_tests.sh"
NCHECKS=11

case "${1:-}" in
    "")
        res=$(run_checks "$CI" "$ALLOWF" "$TOOL" "$RUNNER")
        echo "PLAN: $NCHECKS"
        printf '%s\n' "$res" | sed -e 's/^ok /  PASS: /' -e 's/^bad /  FAIL: /'
        [ "$(printf '%s\n' "$res" | grep -c '^ok ')" -eq "$NCHECKS" ] || exit 1
        exit 0 ;;
    --selftest) ;;
    *) echo "usage: tests/test_gfx137_once_2320.sh [--selftest]" >&2; exit 2 ;;
esac

# plant NAME FILE(ci|allow|tool|runner) CHECK OLD NEW -- OLD must occur once.
# The planted copy lands in a scratch tree; the other three files are the real
# ones. The C3 scan of sibling workflow files then sees only the planted ci.yml.
n=0 fail=0
plant() {
    local name=$1 which=$2 want=$3 old=$4 new=$5 ci=$CI allow=$ALLOWF tool=$TOOL runner=$RUNNER src dst res
    case "$which" in ci) src=$CI ;; allow) src=$ALLOWF ;; tool) src=$TOOL ;; runner) src=$RUNNER ;; esac
    rm -rf "$W/p"; mkdir -p "$W/p/.github/workflows"
    cp "$CI" "$W/p/.github/workflows/ci.yml"; ci="$W/p/.github/workflows/ci.yml"
    dst="$W/p/planted.$which"; [ "$which" = ci ] && dst=$ci
    python3 - "$src" "$dst" "$old" "$new" <<'PY' || { echo "gfx137_once selftest: INSTRUMENT ERROR, plant '$name' did not apply"; exit 2; }
import sys
s = open(sys.argv[1]).read()
if s.count(sys.argv[3]) != 1: sys.exit(1)
open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4]))
PY
    case "$which" in allow) allow=$dst ;; tool) tool=$dst ;; runner) runner=$dst ;; esac
    res=$(run_checks "$ci" "$allow" "$tool" "$runner" "$want"); n=$((n + 1))
    if printf '%s\n' "$res" | grep -q "^bad $want:"; then echo "  PASS: plant $name caught by $want"
    else echo "  FAIL: plant $name NOT caught by $want"; printf '%s\n' "$res" | sed 's/^/    /'; fail=$((fail + 1)); fi
}

res=$(run_checks "$CI" "$ALLOWF" "$TOOL" "$RUNNER"); n=$((n + 1))
if [ "$(printf '%s\n' "$res" | grep -c '^ok ')" -eq "$NCHECKS" ]; then echo "  PASS: control: the tree passes all $NCHECKS checks"
else echo "  FAIL: control: the tree fails a check"; printf '%s\n' "$res" | sed 's/^/    /'; fail=$((fail + 1)); fi

plant "two owners: zlib stops deferring" ci C1 \
    "      EIGS_GFX137_DEFER: extensions-zlib
" ""
plant "absence: the owner defers in the queue too" ci C1 \
    "matrix.cc == 'clang' && 'linux-clang' ||" "'linux-clang' ||"
plant "a native macOS lane defers" ci C3 \
    "    name: macos suite / \${{ matrix.os }}
    env:
      CI_DISPATCH_LANES: all
" "    name: macos suite / \${{ matrix.os }}
    env:
      CI_DISPATCH_LANES: all
      EIGS_GFX137_DEFER: database
"
plant "a lane defers under an unlisted id" ci C2 \
    "EIGS_GFX137_DEFER: extensions-zlib" "EIGS_GFX137_DEFER: extensions-zlib-2"
plant "stale allowlist entry" allow C2 \
    "linux-gcc-pr |" "old-lane | linux / gcc | gone
linux-gcc-pr |"
plant "allowlist entry without a reason" allow C2 \
    "$(grep '^linux-gcc-pr ' "$ALLOWF")" "linux-gcc-pr | linux / gcc |"
plant "PR scope fails open (unknown verdict defers)" ci C4 \
    "needs.scope.outputs.gfx137 == 'false'" "needs.scope.outputs.gfx137 != 'true'"
plant "fuzz-only dispatch defers to an owner that is not running" ci C5 \
    "\${{ inputs.lanes != 'fuzz' && 'extensions-server' || '' }}" "extensions-server"
plant "scope job loses its gfx137 output" ci C6 \
    "      gfx137: \${{ steps.gfx137.outputs.gfx137 }}
" ""
plant "owner job no longer checks its receipt" ci C7 \
    "        run: bash tools/gfx137_once.sh receipt \"\$RUNNER_TEMP/suite.log\"" "        run: echo receipt"
plant "suite step tees without pipefail" ci C7 \
    "          set -o pipefail
          cd tests && bash run_all_tests.sh 2>&1 | tee \"\$RUNNER_TEMP/suite.log\"" \
    "          cd tests && bash run_all_tests.sh 2>&1 | tee \"\$RUNNER_TEMP/suite.log\""
plant "defer accepts any lane id" tool C8 \
    "        if [ -z \"\$row\" ]; then" "        if false; then"
plant "runner skips on any EIGS_GFX137_DEFER" runner C9 \
    'if [ "$AG_DEFER_RC" = "0" ]; then' 'if true; then'
plant "runner prints no ran receipt" runner C9 \
    '            echo "  GFX137: ran"
' ""
plant "scope drops src/ext_gfx" tool C10 \
    "^(src/ext_gfx[^/]*|" "^("
plant "scope counts lib/ui as an input" tool C10 \
    "tests/gfx137_defer_allowlist\\.txt)\$'" "tests/gfx137_defer_allowlist\\.txt|lib/ui.*)\$'"
plant "receipt: the owner accepts a deferral" tool C11 \
    "if [ \"\$ran\" = 1 ] && [ \"\$deferred\" = 0 ]; then" "if [ \"\$ran\" = 1 ] || [ \"\$deferred\" = 1 ]; then"

[ "$n" -eq 18 ] || { echo "gfx137_once selftest: ran $n cases, want 18"; exit 1; }
echo "PLAN: $n"
echo "gfx137_once selftest: $((n - fail)) of $n passed"
[ "$fail" -eq 0 ]
