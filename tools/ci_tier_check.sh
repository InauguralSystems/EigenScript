#!/bin/bash
# Required checks must be produced once, on pull_request and merge_group, and
# a required path must not run work only on push (#1264). A job skipped by its
# if: is a satisfied check. Missing PyYAML is exit 2, never a pass. --live
# diffs the ruleset read-only and is not run in CI.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF_DIR="${CI_TIER_WF_DIR:-$ROOT/.github/workflows}"
REQ_FILE="${CI_TIER_REQUIRED:-$ROOT/.github/required-checks.txt}"
check() {
    [ -f "$WF_DIR/ci.yml" ] && [ -f "$REQ_FILE" ] \
        || { echo "ci-tier: INSTRUMENT ERROR — ci.yml or required-checks.txt missing"; return 2; }
    CT_AWK=$(awk '/^jobs:/ {j=1; next} j && /^[^ #]/ {j=0}
                  j && /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {n++} END {print n+0}' "$WF_DIR/ci.yml") \
    CT_GREP=$(grep -cvE '^(#|$)' "$REQ_FILE") CT_WF="$WF_DIR" CT_REQ="$REQ_FILE" python3 - <<'PY'
import hashlib, itertools, os, re, sys; from fnmatch import fnmatchcase
def instrument(m): print(f"ci-tier: INSTRUMENT ERROR — {m}; nothing was checked"); sys.exit(2)
try:
    import yaml
except Exception as e:  # noqa: BLE001
    instrument(f"PyYAML unavailable ({e})")
bad = []
def V(code, msg): bad.append(code); print(f"FAIL [{code}] {msg}")
req = [l for l in open(os.environ["CT_REQ"], encoding="utf-8").read().split("\n") if l and not l.startswith("#")]
if not req or len(req) != int(os.environ["CT_GREP"]) or len(set(req)) != len(req):
    V("vacuous", f"required-checks.txt: parsed {len(req)} names, {len(set(req))} distinct, grep counts {os.environ['CT_GREP']}")
REQ = set(req); W = {}
for fn in sorted(os.listdir(os.environ["CT_WF"])):
    if not fn.endswith((".yml", ".yaml")): continue
    try: doc = yaml.safe_load(open(os.path.join(os.environ["CT_WF"], fn), encoding="utf-8"))
    except Exception as e: instrument(f"{fn} does not load ({e.__class__.__name__})")  # noqa: BLE001
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict): instrument(f"{fn} has no jobs: mapping")
    on = doc.get("on", doc.get(True))           # YAML 1.1 reads bare `on` as True
    on = {on: {}} if isinstance(on, str) else {str(k): {} for k in on} if isinstance(on, list) else \
         {str(k): (v if isinstance(v, dict) else {}) for k, v in (on or {}).items()}
    W[fn] = (on, doc["jobs"], doc.get("env") or {})
def triggers(on, ev):
    if ev not in on: return False
    c = on[ev]
    if "paths" in c or "paths-ignore" in c: return False
    if "branches" in c: return any(fnmatchcase("main", str(p)) for p in c["branches"] or [])
    return not any(fnmatchcase("main", str(p)) for p in c.get("branches-ignore") or [])
def cond(x):
    s = str(x).strip(); m = re.fullmatch(r"\$\{\{(.*)\}\}", s, re.S); return (m.group(1) if m else s).strip()
def needs(j): n = j.get("needs") or []; return [n] if isinstance(n, str) else list(n)
def always(j): return cond(j.get("if", "")) == "always()"
G = r"github\s*(?:\.\s*{0}\b|\[\s*['\"]{0}['\"]\s*\])"
PR_ATOM = re.compile(G.format("event_name") + r"\s*[=!]=\s*['\"]pull_request['\"]|['\"]pull_request['\"]\s*[=!]=\s*" + G.format("event_name"), re.I)
PR_BODY = re.compile(G.format("event") + r"\s*(?:\.\s*pull_request\b|\[\s*['\"]pull_request['\"]\s*\])", re.I); EVP = r"(?:event_name|event|ref|ref_name|ref_type|head_ref|base_ref)\b"
EV = re.compile(r"\bgithub\b(?!\s*(?:\.\s*(?!" + EVP + r")\w|\[\s*['\"](?!" + EVP + r")\w+['\"]\s*\]))", re.I)
IND = re.compile(r"\b(env|vars)\s*(?:\.\s*|\[\s*['\"])([\w-]+)['\"]?\s*\]?|\b(needs|steps)\s*(?:\.\s*|\[\s*['\"])([\w-]+)['\"]?\s*\]?"
                 r"\s*(?:\.\s*|\[\s*['\"])(outputs|result|outcome|conclusion)['\"]?\s*\]?(?:\s*(?:\.\s*|\[\s*['\"])([\w-]+)['\"]?\s*\]?)?", re.I)
WAIVE = {("ci.yml", "scope", "detect"): "6611d97dc6f0b4e7",
         ("ci.yml", "gate-selftests", "select"): "411e6c561962764a"}
used = set()
def exprs(v): return re.findall(r"\$\{\{(.*?)\}\}", str(v), re.S)
def bad_expr(e, wf, jid, pr_ok, depth=0):
    """Why expression `e` (in wf:jid) may differ between push and merge_group, or None."""; t = PR_BODY.sub("_", PR_ATOM.sub("_", e)) if pr_ok else e
    if EV.search(t): return f"`{e.strip()}` reads the event"
    if re.search(r"\b(env|vars|steps|needs)\b", IND.sub("_", t), re.I): return f"`{e.strip()}` reads a context this gate cannot resolve"
    for m in IND.finditer(t):
        (ctx, name, kind, job, field, key), j = m.groups(), W[wf][1].get(jid, {})
        if ctx == "vars" or depth > 4: return f"`{m.group(0)}` cannot be resolved"
        if ctx == "env":
            vals = [str(d[name]) for d in [s.get("env") for s in j.get("steps") or [] if isinstance(s, dict)] + [j.get("env"), W[wf][2]]
                    if isinstance(d, dict) and name in d]
            if not vals: return f"`env.{name}` is not declared in {wf}:{jid}"
            why = next((w for v in vals for x in exprs(v) for w in [bad_expr(x, wf, jid, pr_ok, depth + 1)] if w), None)
        elif field in ("result", "outcome", "conclusion"): continue
        elif kind == "needs":
            v = (W[wf][1].get(job, {}).get("outputs") or {}).get(key)
            if v is None: return f"`needs.{job}.outputs.{key}` is not declared"
            why = next((w for x in exprs(v) for w in [bad_expr(x, wf, job, pr_ok, depth + 1)] if w), None)
        else:
            src = next((yaml.safe_dump(s, sort_keys=True) for s in j.get("steps") or [] if isinstance(s, dict) and s.get("id") == job), None); pin = WAIVE.get((wf, jid, job))
            if pin and src is not None and hashlib.sha256(src.encode()).hexdigest()[:16] == pin: used.add((wf, jid, job)); continue
            return f"`steps.{job}.outputs.{key}` comes from a script (not waived, or the waived script changed)"
        if why: return f"{m.group(0).strip()} -> {why}"
    return None
def names(jid, j):
    m = (j.get("strategy") or {}).get("matrix") if isinstance(j.get("strategy"), dict) else None; combos = [{}]
    if isinstance(m, dict):
        keys = [k for k in m if k not in ("include", "exclude")]; combos = [dict(zip(keys, v)) for v in itertools.product(*[m[k] for k in keys])] if keys else []
        combos += [i for i in m.get("include") or [] if not keys]
    out = []
    for c in combos:
        n = re.sub(r"\$\{\{\s*matrix\.([\w-]+)\s*\}\}", lambda mo: str(c.get(mo.group(1), "?")), str(j.get("name", jid)))
        if n not in out: out.append(n)
    return out
NAMES = {(wf, jid): names(jid, j) for wf, (_, js, _e) in W.items() for jid, j in js.items()}
PROD = {}
for k, ns in NAMES.items():
    for n in ns: PROD.setdefault(n, []).append(k)
def closure(wf, jid, seen):
    if (wf, jid) in seen or jid not in W[wf][1]: return
    seen.add((wf, jid))
    for n in needs(W[wf][1][jid]): closure(wf, n, seen)
path = set()
for r in req:
    p = PROD.get(r, [])
    if len(p) != 1:
        V("unproduced" if not p else "ambiguous", f"required {r!r} has {len(p)} producing jobs {p} (0 never reports and blocks every merge)"); continue
    wf, jid = p[0]
    if not triggers(W[wf][0], "pull_request"): V("not-on-pr", f"required {r!r}: {wf} does not run on every pull_request to main")
    if not triggers(W[wf][0], "merge_group"): V("not-in-queue", f"required {r!r}: {wf} does not trigger on merge_group — it never reports in the queue")
    closure(wf, jid, path)
ci = W["ci.yml"][1]
if len(ci) != int(os.environ["CT_AWK"]) or not ci:
    V("vacuous", f"ci.yml: the loader sees {len(ci)} jobs, awk sees {os.environ['CT_AWK']}")
counts = {"required": 0, "worker": 0}
for jid, j in ci.items():
    if all(n in REQ for n in NAMES[("ci.yml", jid)]): counts["required"] += 1; continue
    cons = [k for k, kj in ci.items() if jid in needs(kj)]
    if len(cons) == 1 and always(ci[cons[0]]) and all(n in REQ for n in NAMES[("ci.yml", cons[0])]):
        counts["worker"] += 1; closure("ci.yml", jid, path); continue
    V("uncovered", f"ci.yml:{jid} {NAMES[('ci.yml', jid)]} is not required and not the worker of ONE required `if: always()` job — it can colour main without blocking the queue")
for wf, jid in sorted(path):
    j = W[wf][1][jid]; why = bad_expr(cond(j.get("if", "")), wf, jid, False)
    if why: V("event-condition", f"{wf}:{jid}: job-level `if:` — {why}; a job skipped in the queue or on a PR is a satisfied check")
    vals = [(k, v) for d in (j.get("env"), j.get("outputs"), W[wf][2]) if isinstance(d, dict) for k, v in d.items()]
    vals += [("strategy", yaml.safe_dump(j.get("strategy") or {}))] + [(k, v) for st in j.get("steps") or []
             if isinstance(st, dict) for k, v in (st.get("env") or {}).items()]
    for k, v in vals:
        for x in exprs(v):
            if EV.search(PR_BODY.sub("_", PR_ATOM.sub("_", x))):
                V("event-condition", f"{wf}:{jid}: `{k}: ${{{{{x}}}}}` derives a value from the event")
    if j.get("continue-on-error") not in (None, False): V("continue-on-error", f"{wf}:{jid} sets continue-on-error: its failure would not fail the check")
    for i, st in enumerate(j.get("steps") or []):
        if not isinstance(st, dict): continue
        why = bad_expr(cond(st.get("if", "")), wf, jid, True)
        if why: V("event-condition", f"{wf}:{jid} step {i} ({st.get('name', st.get('uses', '?'))}): `if:` — {why}; only `github.event_name ==/!= 'pull_request'` may select the lane")
        if st.get("continue-on-error") not in (None, False): V("continue-on-error", f"{wf}:{jid} step {i} ({st.get('name', '?')}) sets continue-on-error")
if set(WAIVE) - used: V("event-condition", f"waiver(s) {sorted(set(WAIVE) - used)} matched nothing — stale; remove or re-pin")
if bad: print(f"ci-tier: FAIL — {len(bad)} violation(s): {' '.join(sorted(set(bad)))}"); sys.exit(1)
print(f"ci-tier: OK — ci.yml jobs={len(ci)} (awk={os.environ['CT_AWK']}) required={counts['required']} worker={counts['worker']}; "
      f"{len(req)} required names, each produced once on pull_request+merge_group; {len(path)} jobs on required paths, no push-only condition, no continue-on-error")
PY
}
live() {
    local got want
    got=$(gh api repos/InauguralSystems/EigenScript/rulesets/17713865 --jq \
        '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context' 2>&1) && [ -n "$got" ] \
        || { echo "ci-tier --live: INSTRUMENT ERROR — cannot read the ruleset: $got"; return 2; }
    want=$(grep -vE '^(#|$)' "$REQ_FILE")
    local d; d=$(diff <(LC_ALL=C sort <<<"$want") <(LC_ALL=C sort <<<"$got") | sed -n 's/^< /  file only: /p; s/^> /  ruleset only: /p')
    [ -z "$d" ] && { echo "ci-tier --live: OK — the ruleset requires exactly the $(grep -c . <<<"$want") checks in the file"; return 0; }
    echo "$d"; echo "ci-tier --live: DRIFT — sync the ruleset from required-checks.txt"; return 1
}
case "${1:-}" in "") check ;; --live) live ;; *) echo "usage: $0 [--live]" >&2; exit 2 ;; esac
