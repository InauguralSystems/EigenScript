#!/usr/bin/env bash
# tools/ci_tier_check.sh — platform tiers (#1264): the main lane's colour means
# something.
#
# THE MODEL (copied from Rust / CPython / Go, owner decision on #1264):
#   TIER 1 — the checks in .github/required-checks.txt. They block a merge
#            (the "Protection" ruleset is synced FROM that file) and they are
#            what decides whether `main` is green.
#   TIER 2 — slow or port lanes (.github/workflows/nightly.yml). They never
#            colour main; a failure opens or appends to a tracking issue.
#
# WHY A GATE. Main CI was red from 2026-09-16 to 2026-09-22 while every
# required check passed: ONE lane that no PR had to pass (macos-15-intel, on
# the main lane only) timed out on nearly every push. The README badge is the
# status of the whole `ci.yml` workflow on main, so ANY ci.yml job that can
# fail there colours it — required or not. The invariant that makes red mean
# "a merge broke something" is therefore structural, and this gate pins it:
#
#   (1) every name in required-checks.txt is produced by EXACTLY ONE job
#       across .github/workflows/, and that job reports on pull_request:
#       its workflow triggers on pull_request for main with no path filter,
#       and neither it nor any job it transitively `needs` is gated on the
#       event (a required check that never reports blocks merges forever);
#   (2) a required job without `if: always()` needs only REQUIRED jobs — a
#       failed prerequisite SKIPS its dependants, and GitHub treats a
#       `skipped` required check as satisfied;
#   (3) every ci.yml job on the main lane is exactly one of
#         (a) required — ALL of its matrix legs (a half-required matrix is red);
#         (b) a worker whose ONLY consumer is a required aggregator that has
#             `if: always()` and, in an unconditional step, compares this
#             worker's `needs.<id>.result` against `success` (so a failed,
#             cancelled or skipped worker fails the aggregator); the worker
#             may not set `continue-on-error`;
#       anything else must move to nightly.yml (tier 2);
#   (4) every nightly.yml job is consumed by an `if: always()` reporter that
#       checks its result and files an issue (`gh issue`) — a silent nightly
#       is not a tier, it is a deletion.
#
# POPULATIONS (mechanical-gates §5/§121/§122). Both are DECLARED sets, so both
# are pinned exactly, each against a count taken by a different mechanism:
#   * ci.yml job ids: the YAML loader's count == an awk count of the two-space
#     keys under `jobs:` > 0;
#   * required names: the parsed count == `grep -cv` of non-comment lines > 0.
#
# WHAT IT DOES NOT PROVE (residuals):
#   * that the LIVE ruleset matches the file — that is `--live` (read-only
#     `gh api`; needs a token that can read rulesets). CI does not run it: the
#     ruleset is synced after merge, so a PR that edits the file is expected to
#     differ from the live ruleset until then;
#   * `if:` expressions are not evaluated. A job-level `if:` that mentions the
#     event (github.event_name / github.event.* / github.ref*) on a required
#     job or its ancestors is RED because it cannot be proven to report on a
#     PR; a ci.yml job is taken off the main lane only by the exact
#     `if: github.event_name == 'pull_request'`;
#   * step-level `if:`s inside a required job are not judged (a required job
#     whose steps all skip on a docs-only PR reports success by design —
#     that is the `scope` job's contract);
#   * checks from GitHub apps outside .github/workflows/ (CodeQL default
#     setup's `Analyze (python)`, CodSpeed's app check) are invisible here; a
#     required name produced only by an app would read as [unproduced].
#
# Usage:
#   tools/ci_tier_check.sh             check the tree (exit 0 OK, 1 violation,
#                                      2 instrument error: no PyYAML, a file
#                                      that does not load — never a verdict)
#   tools/ci_tier_check.sh --selftest  plant each violation class in a copy of
#                                      the workflows and require the NAMED
#                                      check to go red
#   tools/ci_tier_check.sh --live      diff required-checks.txt against the
#                                      live ruleset (read-only)
#
# Env (the selftest points these at its copy): CI_TIER_WF_DIR,
# CI_TIER_REQUIRED, CI_TIER_MAIN (ci.yml), CI_TIER_NIGHTLY (nightly.yml).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/tools/ci_tier_check.sh"
WF_DIR="${CI_TIER_WF_DIR:-$ROOT/.github/workflows}"
REQ_FILE="${CI_TIER_REQUIRED:-$ROOT/.github/required-checks.txt}"
MAIN_WF="${CI_TIER_MAIN:-ci.yml}"
NIGHTLY_WF="${CI_TIER_NIGHTLY:-nightly.yml}"
RULESET_ID="${CI_TIER_RULESET_ID:-17713865}"
REPO="${CI_TIER_REPO:-InauguralSystems/EigenScript}"

check() {
    local main="$WF_DIR/$MAIN_WF"
    [ -f "$main" ] || { echo "ci-tier: INSTRUMENT ERROR — $main does not exist; nothing was checked"; return 2; }
    [ -f "$REQ_FILE" ] || { echo "ci-tier: INSTRUMENT ERROR — $REQ_FILE does not exist; nothing was checked"; return 2; }
    local awk_jobs req_lines
    # Independent count of ci.yml job ids: two-space keys under `jobs:` until
    # the next top-level key.
    awk_jobs=$(awk '
        /^jobs:[[:space:]]*(#.*)?$/ { j = 1; next }
        j && /^[^[:space:]#]/       { j = 0 }
        j && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { n++ }
        END { print n + 0 }' "$main")
    req_lines=$(grep -cvE '^(#|$)' "$REQ_FILE")
    CT_WF_DIR="$WF_DIR" CT_REQ="$REQ_FILE" CT_MAIN="$MAIN_WF" CT_NIGHTLY="$NIGHTLY_WF" \
    CT_AWK_JOBS="$awk_jobs" CT_REQ_LINES="$req_lines" python3 - <<'PY'
import itertools, os, re, sys
from fnmatch import fnmatchcase

def instrument(msg):
    print(f"ci-tier: INSTRUMENT ERROR — {msg}; nothing was checked")
    sys.exit(2)

try:
    import yaml
except Exception as e:  # noqa: BLE001 — any import failure is an instrument failure
    instrument(f"PyYAML unavailable ({e.__class__.__name__}: {e})")

WF_DIR = os.environ["CT_WF_DIR"]; REQ = os.environ["CT_REQ"]
MAIN = os.environ["CT_MAIN"]; NIGHTLY = os.environ["CT_NIGHTLY"]
AWK_JOBS = int(os.environ["CT_AWK_JOBS"]); REQ_LINES = int(os.environ["CT_REQ_LINES"])

viol = []
def V(code, msg):
    viol.append(code)
    print(f"FAIL [{code}] {msg}")

# ---- required-checks.txt ---------------------------------------------------
required = []
with open(REQ, encoding="utf-8") as fh:
    for ln, line in enumerate(fh.read().split("\n"), 1):
        if line == "" or line.startswith("#"):
            continue
        if line != line.strip():
            V("whitespace", f"{os.path.basename(REQ)}:{ln}: leading/trailing blank in {line!r} — a check name is matched EXACTLY")
        required.append(line.strip())
if not required:
    V("vacuous", "required-checks.txt names no check — tier 1 would be empty")
if len(required) != REQ_LINES:
    V("count-mismatch", f"parsed {len(required)} required names, grep counts {REQ_LINES} non-comment lines")
seen = set()
for r in required:
    if r in seen:
        V("dup-required", f"{r!r} is listed twice in required-checks.txt")
    seen.add(r)
REQ_SET = set(required)

# ---- workflows ---------------------------------------------------------------
def norm_on(on):
    if on is None: return {}
    if isinstance(on, str): return {on: {}}
    if isinstance(on, list): return {str(x): {} for x in on}
    if isinstance(on, dict): return {str(k): (v if isinstance(v, dict) else {}) for k, v in on.items()}
    instrument(f"unrecognised `on:` shape {type(on).__name__}")

WFS = {}
for fn in sorted(os.listdir(WF_DIR)):
    if not fn.endswith((".yml", ".yaml")): continue
    path = os.path.join(WF_DIR, fn)
    try:
        with open(path, encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except Exception as e:  # noqa: BLE001
        instrument(f"{fn} does not load as YAML ({e.__class__.__name__})")
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
        instrument(f"{fn} has no top-level `jobs:` mapping")
    # PyYAML (YAML 1.1) reads the bare key `on` as the boolean True.
    on = doc["on"] if "on" in doc else doc.get(True)
    WFS[fn] = {"on": norm_on(on), "jobs": doc["jobs"]}
if MAIN not in WFS: instrument(f"{MAIN} not found among the workflows")
if not WFS: instrument("no workflow files")

def branch_ok(cfg, br="main"):
    if "branches" in cfg:
        return any(fnmatchcase(br, str(p)) for p in (cfg["branches"] or []))
    if "branches-ignore" in cfg:
        return not any(fnmatchcase(br, str(p)) for p in (cfg["branches-ignore"] or []))
    return True

def pr_status(on):
    """(True, '') when every PR to main triggers this workflow."""
    for key in ("pull_request", "pull_request_target"):
        if key not in on: continue
        cfg = on[key]
        if not branch_ok(cfg): return False, f"`{key}` excludes main"
        if "paths" in cfg or "paths-ignore" in cfg:
            return False, f"`{key}` is path-filtered — a PR outside the filter never reports"
        if "types" in cfg and not {"opened", "synchronize"} <= set(cfg["types"] or []):
            return False, f"`{key}` types {cfg['types']} miss opened/synchronize"
        return True, ""
    return False, "the workflow does not trigger on pull_request"

def pushes_main(on):
    if "push" not in on: return False
    cfg = on["push"]
    if "branches" in cfg or "branches-ignore" in cfg: return branch_ok(cfg)
    if "tags" in cfg or "tags-ignore" in cfg: return False
    return True

def if_str(job):
    s = str(job.get("if", "")).strip() if isinstance(job, dict) else ""
    m = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", s, re.S)
    return m.group(1).strip() if m else s

def is_always(job): return if_str(job) == "always()"
EVENT_RE = re.compile(r"github\.(event_name|event\.|ref\b|ref_name|ref_type|head_ref|base_ref)")
PR_ONLY = "github.event_name == 'pull_request'"

def needs(job):
    n = job.get("needs", []) if isinstance(job, dict) else []
    return [n] if isinstance(n, str) else list(n or [])

class Unexpandable(Exception): pass
MATRIX_RE = re.compile(r"\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}")

def names_of(jid, job):
    tmpl = job.get("name")
    strat = job.get("strategy") or {}
    if not isinstance(strat, dict): raise Unexpandable("strategy is an expression")
    m = strat.get("matrix")
    combos = [{}]
    if m is not None:
        if not isinstance(m, dict): raise Unexpandable("matrix is an expression")
        keys = [k for k in m if k not in ("include", "exclude")]
        for k in keys:
            if not isinstance(m[k], list): raise Unexpandable(f"matrix.{k} is an expression")
        combos = [dict(zip(keys, v)) for v in itertools.product(*[m[k] for k in keys])] if keys else []
        for ex in (m.get("exclude") or []):
            combos = [c for c in combos if not all(c.get(k) == v for k, v in ex.items())]
        # GitHub: an include entry extends every ORIGINAL combination whose
        # original values it does not overwrite; if it extends none (always
        # the case for an include-only matrix), it is a new combination.
        base = list(combos)
        for inc in (m.get("include") or []):
            if not isinstance(inc, dict): raise Unexpandable("matrix.include entry is an expression")
            hit = False
            for c in (base if keys else []):
                if all(c.get(k) == v for k, v in inc.items() if k in keys):
                    c.update({k: v for k, v in inc.items() if k not in keys})
                    hit = True
            if not hit: combos.append(dict(inc))
        if not combos: raise Unexpandable("matrix expands to zero legs")
    out = []
    for c in combos:
        if tmpl is None:
            n = jid if not c else f"{jid} ({', '.join(str(v) for v in c.values())})"
        else:
            def sub(mo):
                if mo.group(1) not in c: raise Unexpandable(f"matrix.{mo.group(1)} is not a matrix key")
                return str(c[mo.group(1)])
            n = MATRIX_RE.sub(sub, str(tmpl))
            if "${{" in n: raise Unexpandable(f"name {tmpl!r} carries a non-matrix expression")
        if n not in out: out.append(n)
    return out

NAMES = {}      # (wf, jid) -> [check names]
PRODUCERS = {}  # name -> [(wf, jid)]
for wf, w in WFS.items():
    for jid, job in w["jobs"].items():
        if not isinstance(job, dict):
            instrument(f"{wf}: job {jid} is not a mapping")
        try:
            ns = names_of(jid, job)
        except Unexpandable as e:
            V("unexpandable", f"{wf}:{jid}: cannot derive its check name(s) — {e}")
            ns = []
        NAMES[(wf, jid)] = ns
        for n in ns:
            PRODUCERS.setdefault(n, []).append((wf, jid))

def ancestors(wf, jid, seen=None):
    seen = set() if seen is None else seen
    for n in needs(WFS[wf]["jobs"].get(jid, {})):
        if n not in seen:
            seen.add(n)
            if n in WFS[wf]["jobs"]: ancestors(wf, n, seen)
    return seen

def result_checked(agg, wid):
    """Does an UNCONDITIONAL step of `agg` compare needs.<wid>.result to success?"""
    pat = re.compile(r"\$\{\{\s*needs\." + re.escape(wid) + r"\.result\s*\}\}")
    for st in agg.get("steps") or []:
        if not isinstance(st, dict) or "if" in st: continue
        run = str(st.get("run") or "")
        if not re.search(r"=\s*\"?success\b", run): continue
        if pat.search(run): return True
        for var, val in (st.get("env") or {}).items():
            if pat.fullmatch(str(val).strip()) and f'"${var}"' in run: return True
    return False

# ---- (1) + (2): every required name ------------------------------------------
req_by_wf = {}
for r in required:
    prods = PRODUCERS.get(r, [])
    if not prods:
        V("unproduced", f"required {r!r} is produced by no job in .github/workflows — it never reports, so it blocks every merge")
        continue
    if len(prods) > 1:
        V("ambiguous", f"required {r!r} is produced by {len(prods)} jobs {prods} — either one would satisfy the rule")
        continue
    wf, jid = prods[0]
    req_by_wf[wf] = req_by_wf.get(wf, 0) + 1
    ok, why = pr_status(WFS[wf]["on"])
    if not ok:
        V("not-on-pr", f"required {r!r} ({wf}:{jid}) — {why}; a required check that never reports blocks merges forever")
    for a in [jid] + sorted(ancestors(wf, jid)):
        s = if_str(WFS[wf]["jobs"].get(a, {}))
        if EVENT_RE.search(s):
            V("not-on-pr", f"required {r!r}: {wf}:{a}{' (a job it needs)' if a != jid else ''} is gated on the event (`if: {s}`) — it cannot be shown to report on pull_request")
    if not is_always(WFS[wf]["jobs"][jid]):
        for n in needs(WFS[wf]["jobs"][jid]):
            nn = NAMES.get((wf, n), [])
            if not nn or not all(x in REQ_SET for x in nn):
                V("need-not-required", f"required {r!r} ({wf}:{jid}) needs {n} {nn}, which is not required: when {n} fails, {jid} is SKIPPED and a skipped required check is satisfied")

# ---- (3): the ci.yml main lane -----------------------------------------------
main_jobs = WFS[MAIN]["jobs"]
if len(main_jobs) != AWK_JOBS or AWK_JOBS == 0:
    V("count-mismatch", f"{MAIN}: the YAML loader sees {len(main_jobs)} jobs, the awk key count sees {AWK_JOBS} — a job the classifier examines differs from the job set in the file")
if not pushes_main(WFS[MAIN]["on"]):
    V("vacuous", f"{MAIN} does not run on push to main — no main lane to classify")
counts = {"required": 0, "worker": 0, "pr-only": 0}
examined = 0
print(f"{MAIN} main lane:")
for jid, job in main_jobs.items():
    examined += 1
    ns = NAMES[(MAIN, jid)]
    if if_str(job) == PR_ONLY:
        counts["pr-only"] += 1
        print(f"  pr-only   {jid}")
        continue
    if not ns:
        continue  # already [unexpandable]
    inreq = [n in REQ_SET for n in ns]
    if all(inreq):
        counts["required"] += 1
        print(f"  required  {jid}: {' | '.join(ns)}")
        continue
    if any(inreq):
        V("partial-matrix", f"{MAIN}:{jid}: legs {[n for n in ns if n in REQ_SET]} are required but {[n for n in ns if n not in REQ_SET]} are not — every leg colours main")
        continue
    consumers = [k for k, kj in main_jobs.items() if jid in needs(kj)]
    tag = f"{MAIN}:{jid} {ns}"
    if not consumers:
        V("uncovered", f"{tag} runs on the main lane, is not in required-checks.txt, and no aggregator consumes it: it can turn main red without ever having blocked a merge — require it, make it a worker of a required aggregator, or move it to {NIGHTLY}")
        continue
    if len(consumers) > 1:
        V("multi-consumer", f"{tag} is consumed by {consumers}; a worker is covered only when its ONE consumer is a required aggregator")
        continue
    agg = consumers[0]
    an = NAMES.get((MAIN, agg), [])
    bad = False
    if not an or not all(x in REQ_SET for x in an):
        V("uncovered", f"{tag}: its only consumer {agg} {an} is not required"); bad = True
    elif not is_always(main_jobs[agg]):
        V("agg-not-always", f"{tag}: aggregator {agg} lacks `if: always()` — when the worker fails the aggregator is SKIPPED, and a skipped required check passes"); bad = True
    elif not result_checked(main_jobs[agg], jid):
        V("agg-unchecked", f"{tag}: aggregator {agg} has no unconditional step comparing needs.{jid}.result to success — a failed/cancelled/skipped worker would not fail it"); bad = True
    if job.get("continue-on-error") not in (None, False):
        V("worker-continue-on-error", f"{tag} sets continue-on-error: its result reads success when it failed, so {agg} cannot see the failure"); bad = True
    if not bad:
        counts["worker"] += 1
        print(f"  worker    {jid}: {' | '.join(ns)}  -> {agg}")
if examined != len(main_jobs) or examined == 0:
    V("vacuous", f"examined {examined} of {len(main_jobs)} {MAIN} jobs")

# ---- (4): nightly -------------------------------------------------------------
n_jobs = WFS.get(NIGHTLY, {}).get("jobs", {})
if not n_jobs:
    V("nightly-unreported", f"{NIGHTLY} is missing or has no jobs — tier 2 has nowhere to live")
reporters = [j for j, jb in n_jobs.items() if is_always(jb)]
if n_jobs and not reporters:
    V("nightly-unreported", f"{NIGHTLY} has no `if: always()` reporter job")
for rj in reporters:
    # Code lines only: the reporter's own comments mention `gh issue` (§24).
    runs = [ln for s in (n_jobs[rj].get("steps") or []) if isinstance(s, dict)
            for ln in str(s.get("run") or "").split("\n") if not ln.lstrip().startswith("#")]
    if not any("gh issue" in ln for ln in runs):
        V("nightly-unreported", f"{NIGHTLY}:{rj} is the reporter but files no issue (`gh issue` never appears in its steps)")
tier2 = []
for j in n_jobs:
    if j in reporters: continue
    tier2.append(j)
    owners = [rj for rj in reporters if j in needs(n_jobs[rj])]
    if not owners:
        V("nightly-unreported", f"{NIGHTLY}:{j} is consumed by no reporter — a failure there is read by no one")
    elif not any(result_checked(n_jobs[rj], j) for rj in owners):
        V("nightly-unreported", f"{NIGHTLY}:{j}: its reporter never compares needs.{j}.result to success")

# ---- other workflows: informational ---------------------------------------------
print("other workflows (tier by required-checks.txt; they do not colour the ci.yml badge):")
for (wf, jid), ns in sorted(NAMES.items()):
    if wf in (MAIN, NIGHTLY): continue
    for n in ns:
        print(f"  {'required' if n in REQ_SET else 'advisory'}  {wf}: {n}")

per = " ".join(f"{k}={v}" for k, v in sorted(req_by_wf.items()))
if viol:
    print(f"ci-tier: FAIL — {len(viol)} violation(s): {' '.join(sorted(set(viol)))}")
    sys.exit(1)
print(f"ci-tier: OK — {MAIN}: jobs={examined} (awk={AWK_JOBS}) required={counts['required']} worker={counts['worker']} pr-only={counts['pr-only']}; "
      f"required-checks.txt: {len(required)} names (grep={REQ_LINES}), each produced once and reporting on pull_request [{per}]; "
      f"{NIGHTLY}: {len(tier2)} tier-2 jobs, each reported ({', '.join(reporters)})")
PY
}

live() {
    command -v gh >/dev/null 2>&1 || { echo "ci-tier --live: INSTRUMENT ERROR — no gh CLI"; return 2; }
    local got
    got=$(gh api "repos/$REPO/rulesets/$RULESET_ID" \
            --jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' 2>&1) \
        || { echo "ci-tier --live: INSTRUMENT ERROR — could not read ruleset $RULESET_ID: $got"; return 2; }
    [ -n "$got" ] || { echo "ci-tier --live: INSTRUMENT ERROR — ruleset $RULESET_ID lists no required checks"; return 2; }
    local want
    want=$(grep -vE '^(#|$)' "$REQ_FILE")
    local only_file only_live
    only_file=$(comm -23 <(printf '%s\n' "$want" | LC_ALL=C sort) <(printf '%s\n' "$got" | LC_ALL=C sort))
    only_live=$(comm -13 <(printf '%s\n' "$want" | LC_ALL=C sort) <(printf '%s\n' "$got" | LC_ALL=C sort))
    local nf nl
    nf=$(printf '%s\n' "$want" | grep -c .); nl=$(printf '%s\n' "$got" | grep -c .)
    if [ -z "$only_file" ] && [ -z "$only_live" ]; then
        echo "ci-tier --live: OK — ruleset $RULESET_ID requires exactly the $nf checks in required-checks.txt"
        return 0
    fi
    [ -n "$only_file" ] && printf '  in required-checks.txt, NOT in the ruleset: %s\n' "$only_file" | sed '2,$s/^/  in required-checks.txt, NOT in the ruleset: /'
    [ -n "$only_live" ] && printf '  in the ruleset, NOT in required-checks.txt: %s\n' "$only_live" | sed '2,$s/^/  in the ruleset, NOT in required-checks.txt: /'
    echo "ci-tier --live: DRIFT — file=$nf ruleset=$nl; sync the ruleset from the file"
    return 1
}

selftest() {
    local tmp pass=0 fail=0 broken=0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ci_tier_selftest.XXXXXX") || { echo "selftest: cannot create a temp dir"; return 2; }
    trap 'rm -rf "$tmp"' RETURN
    echo "ci_tier_check selftest (every fault is planted in a copy of .github/)"

    fresh() {
        rm -rf "$tmp/gh"; mkdir -p "$tmp/gh"
        cp -R "$ROOT/.github/workflows" "$tmp/gh/workflows"
        cp "$ROOT/.github/required-checks.txt" "$tmp/gh/required-checks.txt"
    }
    # sub FILE OLD NEW — replace exactly one occurrence, or the plant is BROKEN
    # (a plant that edits nothing proves nothing: mechanical-gates §20/§137).
    sub() {
        python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
n = s.count(old)
if n != 1 or old == new:
    print(f"plant anchor found {n} times in {p} (or edits nothing): {old[:60]!r}")
    sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
    }
    run_gate() {
        CI_TIER_WF_DIR="$tmp/gh/workflows" CI_TIER_REQUIRED="$tmp/gh/required-checks.txt" \
            bash "$SELF" > "$tmp/out" 2>&1
    }
    # expect NAME CODE — run the REAL gate on the planted copy; require rc 1
    # and the named check.
    expect() {
        local name="$1" code="$2" rc=0
        run_gate || rc=$?
        if [ "$rc" -eq 1 ] && grep -qF "FAIL [$code]" "$tmp/out"; then
            pass=$((pass + 1)); echo "  PASS  $name -> red via [$code]"
        else
            fail=$((fail + 1)); echo "  FAIL  $name: expected rc=1 with [$code], got rc=$rc"; sed 's/^/        | /' "$tmp/out" | tail -8
        fi
    }
    brk() { broken=$((broken + 1)); echo "  BROKEN $1: the plant's anchor no longer exists — update the selftest"; }

    local CI="$tmp/gh/workflows/ci.yml" NY="$tmp/gh/workflows/nightly.yml" REQ="$tmp/gh/required-checks.txt"

    # 0. sanity start: the unmodified copy is green (else every red below is noise).
    fresh
    local rc=0; run_gate || rc=$?
    if [ "$rc" -eq 0 ]; then pass=$((pass + 1)); echo "  PASS  unmodified copy is green"
    else fail=$((fail + 1)); echo "  FAIL  unmodified copy: rc=$rc"; tail -8 "$tmp/out"; fi

    # 1. a new ci.yml job nobody requires or aggregates (the macos-15-intel shape)
    fresh; printf '\n  planted-lane:\n    name: planted lane\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' >> "$CI"
    expect "new main-lane job, not required, no aggregator" uncovered

    # 2. rename a required job
    fresh; sub "$CI" "name: tsan (concurrency race gate)" "name: tsan (renamed)" && expect "required job renamed" unproduced || brk rename

    # 3. a required job made push-only
    fresh; sub "$CI" "    name: tsan (concurrency race gate)
" "    name: tsan (concurrency race gate)
    if: github.event_name == 'push'
" && expect "required job made push-only" not-on-pr || brk push-only

    # 4. a required job's PREREQUISITE made push-only (the check would skip on PRs)
    fresh; sub "$CI" "  scope:
    name: scope
" "  scope:
    name: scope
    if: github.ref == 'refs/heads/main'
" && expect "required job's prerequisite made push-only" not-on-pr || brk prereq-push-only

    # 5. another workflow's required check stops triggering on pull_request
    fresh; sub "$tmp/gh/workflows/codeql.yml" "  pull_request:
    branches: [main]
" "" && expect "codeql.yml loses pull_request (Analyze C)" not-on-pr || brk codeql-pr

    # 6. a required workflow gains a path filter (docs-only PRs never report)
    fresh; sub "$tmp/gh/workflows/pages.yml" "  pull_request:
    branches: [main]
" "  pull_request:
    branches: [main]
    paths-ignore: ['**.md']
" && expect "pages.yml path-filtered (playground)" not-on-pr || brk pages-paths

    # 7. an aggregator loses if: always()
    fresh; sub "$CI" "    needs: [scope, extensions-http, extensions-gfx, extensions-zlib, extensions-net]
    if: always()
" "    needs: [scope, extensions-http, extensions-gfx, extensions-zlib, extensions-net]
" && expect "extensions aggregator loses if: always()" agg-not-always || brk agg-always

    # 8. an aggregator stops checking one worker's result
    fresh; sub "$CI" 'for result in "$HTTP_RESULT" "$GFX_RESULT" "$ZLIB_RESULT" "$NET_RESULT"; do' \
                     'for result in "$HTTP_RESULT" "$ZLIB_RESULT" "$NET_RESULT"; do' \
        && expect "extensions aggregator stops checking gfx" agg-unchecked || brk agg-unchecked

    # 9. a worker gains continue-on-error
    fresh; sub "$CI" "    name: extensions / zlib suite
" "    name: extensions / zlib suite
    continue-on-error: true
" && expect "worker sets continue-on-error" worker-continue-on-error || brk coe

    # 10. a worker gains a second consumer
    fresh; sub "$CI" "    name: bench (instruction-count regression gate)
    needs: scope
" "    name: bench (instruction-count regression gate)
    needs: [scope, extensions-net]
" && expect "worker consumed by a second job" multi-consumer || brk multi

    # 11. half a matrix required
    fresh; sub "$REQ" "linux / clang
" "" && expect "linux / clang dropped from the required set" partial-matrix || brk partial

    # 12. a required job's prerequisite dropped from the required set
    fresh; sub "$REQ" "build dev/ci image
" "" && expect "build dev/ci image dropped" need-not-required || brk need

    # 13. a nightly job no reporter reads
    fresh; printf '\n  planted-nightly:\n    name: nightly / planted\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' >> "$NY"
    expect "nightly job outside the reporter's needs" nightly-unreported

    # 14. the nightly reporter stops filing issues
    fresh; sub "$NY" 'gh issue create --repo "$REPO" --title "$TITLE" --body "$BODY" "${LABEL_ARGS[@]}"' 'echo would-create' \
        && sub "$NY" 'gh issue comment "$num" --repo "$REPO" --body "$BODY"' 'echo would-comment' \
        && sub "$NY" 'gh issue comment "$num" --repo "$REPO" \' 'echo \' \
        && sub "$NY" 'gh issue reopen "$num"' 'echo reopen' \
        && sub "$NY" 'num=$(gh issue list' 'num=$(echo' \
        && expect "nightly reporter files no issue" nightly-unreported || brk reporter

    # 15. a duplicated required name
    fresh; printf 'scope\n' >> "$REQ"; expect "required name listed twice" dup-required

    # 16. a second producer of a required name
    fresh; sub "$tmp/gh/workflows/scorecard.yml" "    name: Scorecard analysis" "    name: scope" \
        && expect "two jobs produce a required name" ambiguous || brk ambiguous

    # 17. a job the awk count sees but the loader does not agree on (flow style)
    fresh; printf '\n  planted-flow: {name: planted flow, runs-on: ubuntu-latest, steps: [{run: "true"}]}\n' >> "$CI"
    expect "flow-style job the awk count cannot see" count-mismatch

    # 18. a job name the gate cannot expand
    fresh; sub "$CI" "    name: tsan (concurrency race gate)" '    name: tsan ${{ github.ref }}' \
        && expect "non-matrix expression in a job name" unexpandable || brk unexpandable

    # 19. an empty tier 1
    fresh; grep -E '^#' "$ROOT/.github/required-checks.txt" > "$REQ"
    expect "required-checks.txt with no names" vacuous

    # 20. trailing blank on a name
    # (the blank is built with printf: editors and hooks strip a literal one)
    fresh; sub "$REQ" "tsan (concurrency race gate)" "tsan (concurrency race gate)$(printf ' ')" && expect "trailing blank on a required name" whitespace || brk whitespace

    # 21. no PyYAML -> an INSTRUMENT error (rc 2), never a verdict
    fresh; mkdir -p "$tmp/noyaml"; printf 'raise ImportError("planted: no PyYAML")\n' > "$tmp/noyaml/yaml.py"
    rc=0; PYTHONPATH="$tmp/noyaml" CI_TIER_WF_DIR="$tmp/gh/workflows" CI_TIER_REQUIRED="$REQ" \
        bash "$SELF" > "$tmp/out" 2>&1 || rc=$?
    if [ "$rc" -eq 2 ] && grep -qF 'INSTRUMENT ERROR' "$tmp/out" && ! grep -qF 'ci-tier: OK' "$tmp/out"; then
        pass=$((pass + 1)); echo "  PASS  no PyYAML -> rc 2 INSTRUMENT ERROR"
    else fail=$((fail + 1)); echo "  FAIL  no PyYAML: rc=$rc"; tail -4 "$tmp/out"; fi

    echo "ci_tier_check selftest: checks=$((pass + fail + broken)) failures=$fail broken=$broken"
    [ "$fail" -eq 0 ] && [ "$broken" -eq 0 ]
}

case "${1:-}" in
    "")         check ;;
    --selftest) selftest ;;
    --live)     live ;;
    *) echo "usage: $0 [--selftest|--live]" >&2; exit 2 ;;
esac
