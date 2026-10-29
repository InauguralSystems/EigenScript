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
import hashlib, itertools, os, re, subprocess, sys, tempfile; from fnmatch import fnmatchcase
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
REQ = set(req); W = {}; PERMS = {}; DOCS = {}
for fn in sorted(os.listdir(os.environ["CT_WF"])):
    if not fn.endswith((".yml", ".yaml")): continue
    try: doc = yaml.safe_load(open(os.path.join(os.environ["CT_WF"], fn), encoding="utf-8"))
    except Exception as e: instrument(f"{fn} does not load ({e.__class__.__name__})")  # noqa: BLE001
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict): instrument(f"{fn} has no jobs: mapping")
    on = doc.get("on", doc.get(True))           # YAML 1.1 reads bare `on` as True
    on = {on: {}} if isinstance(on, str) else {str(k): {} for k in on} if isinstance(on, list) else \
         {str(k): (v if isinstance(v, dict) else {}) for k, v in (on or {}).items()}
    W[fn] = (on, doc["jobs"], doc.get("env") or {})
    PERMS[fn] = doc.get("permissions", "write-all")   # absent: the repository default, which may write
    DOCS[fn] = doc
def triggers(on, ev):
    if ev not in on: return False
    c = on[ev]
    if "paths" in c or "paths-ignore" in c: return False
    if "branches" in c: return any(fnmatchcase("main", str(p)) for p in c["branches"] or [])
    return not any(fnmatchcase("main", str(p)) for p in c.get("branches-ignore") or [])
def cond(x):
    s = str(x).strip(); m = re.fullmatch(r"\$\{\{(.*)\}\}", s, re.S); return (m.group(1) if m else s).strip()
def needs(j): n = j.get("needs") or []; return [n] if isinstance(n, str) else list(n)
def always(j):
    c = PUSH_ATOM.sub("_", cond(j.get("if", "")))
    return "always()" in c
G = r"github\s*(?:\.\s*{0}\b|\[\s*['\"]{0}['\"]\s*\])"
PR_ATOM = re.compile(G.format("event_name") + r"\s*[=!]=\s*['\"]pull_request['\"]|['\"]pull_request['\"]\s*[=!]=\s*" + G.format("event_name"), re.I)
PR_BODY = re.compile(G.format("event") + r"\s*(?:\.\s*pull_request\b|\[\s*['\"]pull_request['\"]\s*\])", re.I)
PUSH_ATOM = re.compile(G.format("event_name") + r"\s*[=!]=\s*['\"]push['\"]|['\"]push['\"]\s*[=!]=\s*" + G.format("event_name"), re.I)
DISPATCH_ATOM = re.compile(
    G.format("event_name") + r"\s*[=!]=\s*['\"]workflow_dispatch['\"]|"
    r"['\"]workflow_dispatch['\"]\s*[=!]=\s*" + G.format("event_name"), re.I)
# An ALLOWLIST (#1787): a condition may read only github fields whose value does not depend
# on the event (push, merge_group, pull_request or workflow_dispatch). Any other field
# (ref_protected, workflow_ref, actor, sha, ...) or a bare `github` can select a lane.
INVARIANT = {"repository", "repository_owner", "repository_id", "repository_owner_id", "server_url",
             "api_url", "graphql_url", "workspace", "workflow", "job", "action", "token", "retention_days"}
GH = re.compile(r"\bgithub\b(?:\s*\.\s*([A-Za-z_][\w-]*)|\s*\[\s*['\"]([^'\"]*)['\"]\s*\])?", re.I)
def reads_event(t):
    return next((m.group(0).strip() for m in GH.finditer(t) if (m.group(1) or m.group(2) or "").lower() not in INVARIANT), None)
IND = re.compile(r"\b(env|vars)\s*(?:\.\s*|\[\s*['\"])([\w-]+)['\"]?\s*\]?|\b(needs|steps)\s*(?:\.\s*|\[\s*['\"])([\w-]+)['\"]?\s*\]?"
                 r"\s*(?:\.\s*|\[\s*['\"])(outputs|result|outcome|conclusion)['\"]?\s*\]?(?:\s*(?:\.\s*|\[\s*['\"])([\w-]+)['\"]?\s*\]?)?", re.I)
# scope/detect re-reviewed for #2114 (a218536a): merge_group AND push both take
# code/spec from --all and `release` from their own candidate diff, so push and
# merge_group select identical lanes (#1264); an unknown verdict exits 1.
WAIVE = {("ci.yml", "scope", "detect"): "a218536a4442faff",
         ("ci.yml", "gate-selftests", "select"): "d1e9f765e40d53d8",
         # Reviewed for #2105: outputs only describe whether the exact cache
         # hit or bounded, pinned provisioning made the toolchain available.
         ("ci.yml", "spec-lean", "toolchain"): "653dcf2522f68246",
         # Reviewed for #2105 fix round: this combines provisioning and the
         # pinned Lake-cache action outcomes, and can only suppress Lean work.
         ("ci.yml", "spec-lean", "prebuild"): "114fa7e323c3f11d",
         # Reviewed for #2105 fix round: cache-hit only avoids a redundant
         # save; it cannot select whether the specification runs.
         ("ci.yml", "spec-lean", "lake-cache"): "4cf2ab867685020a"}
used = set()
def exprs(v): return re.findall(r"\$\{\{(.*?)\}\}", str(v), re.S)
def bad_expr(e, wf, jid, pr_ok, depth=0):
    """Why expression `e` (in wf:jid) may differ between push and merge_group, or None."""; t = DISPATCH_ATOM.sub("_", PR_BODY.sub("_", PR_ATOM.sub("_", e)) if pr_ok else e)
    hit = reads_event(t)
    if hit: return f"`{e.strip()}` reads `{hit}`, not one of the event-invariant github fields"
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
            st = next((s for s in j.get("steps") or [] if isinstance(s, dict) and s.get("id") == job), None); pin = WAIVE.get((wf, jid, job))
            now = None if st is None else hashlib.sha256(yaml.safe_dump(st, sort_keys=True).encode()).hexdigest()[:16]
            if pin and now == pin: used.add((wf, jid, job)); continue
            return (f"`steps.{job}.outputs.{key}` comes from a script that is not waived" if not pin else
                    f"`steps.{job}.outputs.{key}` comes from a waived script that changed (it now hashes to {now}): review it, then re-pin WAIVE")
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
# Every job declares its dispatch population.  This makes the population
# closed: a future job cannot silently join every proof run merely because its
# author forgot that workflow_dispatch is a non-PR event.
dispatch = W["ci.yml"][0].get("workflow_dispatch", {}).get("inputs", {}).get("lanes", {})
LANES = ("all", "asan", "tsan", "fuzz", "linux")
if dispatch.get("type") != "choice" or dispatch.get("default") != "all" or tuple(dispatch.get("options") or ()) != LANES:
    V("dispatch-input", f"ci.yml: workflow_dispatch.inputs.lanes must be the choice {LANES!r} with default 'all'; got {dispatch!r}")
dispatch_jobs = {lane: [] for lane in LANES}
for jid, j in ci.items():
    if jid == "promote-main-image":
        continue                    # push-only badge/publication job, checked below
    raw = (j.get("env") or {}).get("CI_DISPATCH_LANES")
    declared = [] if raw is None else str(raw).split(",")
    if raw is None or not declared or any(x not in LANES for x in declared) or len(set(declared)) != len(declared):
        V("dispatch-declaration", f"ci.yml:{jid}: CI_DISPATCH_LANES must declare one or more unique lanes from {LANES!r}; got {raw!r}")
        continue
    if jid == "scope":
        if tuple(declared) != LANES:
            V("dispatch-scope", f"ci.yml:scope must run for every lane so validation cannot be skipped; got {declared!r}")
    else:
        expected = "github.event_name != 'workflow_dispatch' || inputs.lanes == 'all'" + \
                   "".join(f" || inputs.lanes == '{x}'" for x in declared if x != "all")
        if expected not in cond(j.get("if", "")):
            V("dispatch-gate", f"ci.yml:{jid}: job if does not contain its declared selector `{expected}`")
    for lane in LANES:
        if lane == "all" or lane in declared: dispatch_jobs[lane].append(jid)
for lane in LANES:
    if not dispatch_jobs[lane]: V("dispatch-empty", f"ci.yml: lane {lane!r} selects no jobs")
mac_jobs = [jid for jid, j in ci.items() if "macos" in str(j.get("runs-on", "")).lower() or
            any("macos" in str(row.get("os", "")).lower() for row in ((j.get("strategy") or {}).get("matrix") or {}).get("include", []) if isinstance(row, dict))]
for jid in mac_jobs:
    if (ci[jid].get("env") or {}).get("CI_DISPATCH_LANES") != "all":
        V("dispatch-macos", f"ci.yml:{jid}: macOS runners are dispatchable only in lane 'all'")
# These are deliberately expensive main-lane checks.  Their required jobs must
# report a real, successful check on a PR, but may do no more than print the
# canonical deferral.  Workers behind aggregators are skipped before runner
# allocation on PRs; the aggregator is what owns the required check name.
HEAVY = {"build-and-test-macos", "extensions", "database", "sanitizers",
         "valgrind", "tsan", "tsan-http", "bench"}
HEAVY_WORKERS = {"build-and-test-macos-worker", "extensions-http", "extensions-zlib",
                 "database-worker", "sanitizers-core", "tsan-core"}
if len(ci) != int(os.environ["CT_AWK"]) or not ci:
    V("vacuous", f"ci.yml: the loader sees {len(ci)} jobs, awk sees {os.environ['CT_AWK']}")
counts = {"required": 0, "worker": 0}
for jid, j in ci.items():
    if jid == "promote-main-image":
        continue                    # deliberately not a required merge check
    if all(n in REQ for n in NAMES[("ci.yml", jid)]): counts["required"] += 1; continue
    cons = [k for k, kj in ci.items() if jid in needs(kj)]
    if len(cons) == 1 and always(ci[cons[0]]) and all(n in REQ for n in NAMES[("ci.yml", cons[0])]):
        counts["worker"] += 1; closure("ci.yml", jid, path); continue
    V("uncovered", f"ci.yml:{jid} {NAMES[('ci.yml', jid)]} is not required and not the worker of ONE required `if: always()` job — it can colour main without blocking the queue")
for wf, jid in sorted(path):
    j = W[wf][1][jid]
    jc = cond(j.get("if", ""))
    # Heavy workers are the one safe job-level exception: their sole required
    # consumer is an always() aggregator which prints the PR deferral and, on
    # merge_group, rejects any result other than worker success.
    worker_defer = wf == "ci.yml" and jid in HEAVY_WORKERS and "github.event_name != 'pull_request'" in jc
    # ci.yml's required graph is queue/PR/dispatch-only.  Every incumbent job
    # excludes push; the sole push job is validated separately below.
    queue_condition = PUSH_ATOM.sub("_", jc) if wf == "ci.yml" else jc
    why = None if worker_defer else bad_expr(queue_condition, wf, jid, False)
    if why: V("event-condition", f"{wf}:{jid}: job-level `if:` — {why}; a job skipped in the queue or on a PR is a satisfied check")
    vals = [(k, v) for d in (j.get("env"), j.get("outputs"), W[wf][2]) if isinstance(d, dict) for k, v in d.items()]
    vals += [("strategy", yaml.safe_dump(j.get("strategy") or {}))] + [(k, v) for st in j.get("steps") or []
             if isinstance(st, dict) for k, v in (st.get("env") or {}).items()]
    for k, v in vals:
        for x in exprs(v):
            if reads_event(PR_BODY.sub("_", PR_ATOM.sub("_", x))):
                V("event-condition", f"{wf}:{jid}: `{k}: ${{{{{x}}}}}` derives a value from the event")
    if j.get("continue-on-error") not in (None, False): V("continue-on-error", f"{wf}:{jid} sets continue-on-error: its failure would not fail the check")
    for i, st in enumerate(j.get("steps") or []):
        if not isinstance(st, dict): continue
        why = bad_expr(cond(st.get("if", "")), wf, jid, True)
        if why: V("event-condition", f"{wf}:{jid} step {i} ({st.get('name', st.get('uses', '?'))}): `if:` — {why}; only `github.event_name ==/!= 'pull_request'` may select the lane")
        if st.get("continue-on-error") not in (None, False): V("continue-on-error", f"{wf}:{jid} step {i} ({st.get('name', '?')}) sets continue-on-error")
for jid in sorted(HEAVY):
    if jid not in ci:
        V("heavy-missing", f"ci.yml:{jid}: declared heavy required job is missing")
        continue
    steps = [s for s in ci[jid].get("steps") or [] if isinstance(s, dict)]
    deferred = [s for s in steps if cond(s.get("if", "")) == "github.event_name == 'pull_request'"
                and "deferred to merge queue" in str(s.get("run", ""))]
    if len(deferred) != 1:
        V("heavy-deferral", f"ci.yml:{jid}: expected exactly one pull_request step printing 'deferred to merge queue', found {len(deferred)}")
    merge_work = 0
    for i, st in enumerate(steps):
        if st in deferred: continue
        c = cond(st.get("if", ""))
        # An unguarded checkout/setup silently makes the PR lane expensive;
        # a push-only condition is already rejected by bad_expr above.
        if not PR_ATOM.search(c) or "!=" not in c:
            V("heavy-on-pr", f"ci.yml:{jid} step {i} ({st.get('name', st.get('uses', '?'))}) is not excluded from pull_request")
        else:
            merge_work += 1
    if merge_work == 0:
        V("heavy-no-merge-work", f"ci.yml:{jid}: defers but has no work selected for merge_group")
for jid in sorted(HEAVY_WORKERS):
    if jid not in ci:
        V("heavy-missing", f"ci.yml:{jid}: declared heavy worker is missing")
    elif "github.event_name != 'pull_request'" not in cond(ci[jid].get("if", "")):
        V("heavy-worker", f"ci.yml:{jid}: worker must skip pull_request and run in merge_group")
# workflow_dispatch runs every non-PR path of ci.yml from ANY ref (#1787), so the
# writes are checked by what they do, not pinned by their text:
# [ci-main]  dev-image may write only immutable ci-<sha> tags. The sole push job
#   must verify a successful ci.yml merge_group run for the exact SHA, check that
#   SHA is still main's tip, and only then retag ci-<sha> as ci-main.
# [writer-actions]  a job that can write uses only allowlisted actions (compared
#   without @ref) with the inputs vetted for each (no outputs:, cache-to: only type=gha),
#   no ./ or docker:// actions, and no script but that tag step.
# [secrets]  ci.yml reads no secret but GITHUB_TOKEN, so only permissions: can write.
def writes(p): return p == "write-all" or (isinstance(p, dict) and "write" in p.values())
INPUTS = {"actions/checkout": set(), "docker/setup-buildx-action": set(), "docker/login-action": {"registry", "username", "password"},
          "docker/build-push-action": {"context", "file", "platforms", "push", "tags", "cache-from", "cache-to"}}
EVENTS = ("push", "pull_request", "merge_group", "workflow_dispatch")
REFS = ("refs/heads/main", "refs/heads/a-branch", "refs/pull/1/merge", "refs/heads/gh-readonly-queue/main/pr-1-0123abc")
def env_value(v, fork):
    """A tag-step env value, or None when the matrix cannot evaluate it."""
    known = {"github.repository_owner": "Owner", "github.event.pull_request.head.repo.fork==true": "true" if fork else "false"}
    out = str(v)
    for x in exprs(out):
        if re.sub(r"\s+", "", x) not in known: return None
        out = out.replace("${{" + x + "}}", known[re.sub(r"\s+", "", x)])
    return out
def ci_main(jid, j, tag):
    """Run the tag step across the matrix; returns how many runs it judged."""
    where = f"ci.yml:{jid} step {tag.get('id')!r}"
    if DOCS["ci.yml"].get("defaults") or j.get("defaults") or "shell" in tag or "working-directory" in tag:
        V("ci-main", f"{where}: a custom shell or directory (defaults:, shell:, working-directory:) can change what the step computes; the matrix runs it under bash -e in the checkout"); return 0
    envs = {}   # workflow < job < step, as the runner merges them
    for scope, d in (("workflow", W["ci.yml"][2]), ("job", j.get("env") or {}), ("step", tag.get("env") or {})):
        bad_env = [k for k in d if re.match(r"(PATH|BASH_ENV|ENV|SHELLOPTS|BASHOPTS)$|GITHUB_|GIT_|BASH_FUNC_|LD_", str(k), re.I)]
        if bad_env: V("ci-main", f"{where}: {scope} env sets {bad_env}, which can change what the step or its git computes"); return 0
        envs.update(d)
    script = str(tag.get("run", ""))
    odd = sorted({x.strip() for x in exprs(script)} - {"github.sha"})
    if odd or any(env_value(v, False) is None for v in envs.values()):
        V("ci-main", f"{where}: uses an expression the matrix cannot evaluate ({odd or 'in its workflow, job or step env'})"); return 0
    runs = 0
    with tempfile.TemporaryDirectory() as t:
        with open(os.path.join(t, "git"), "w") as f:   # a git that answers only `ls-remote origin refs/heads/main`
            f.write('#!/bin/sh\n[ "$*" = "ls-remote origin refs/heads/main" ] || { echo "unexpected git $*" >&2; exit 97; }\n'
                    '[ -n "$TIP" ] || exit 128\nprintf "%s\\trefs/heads/main\\n" "$TIP"\n')
        os.chmod(os.path.join(t, "git"), 0o755)
        cases = [(e, r, tip, False) for e in EVENTS for r in REFS for tip in (True, False, None)]
        cases += [("pull_request", r, True, True) for r in REFS]                 # fork pull requests
        for ev, ref, tip, fork in cases:
            sha, out = "1" * 40, os.path.join(t, "out")
            open(out, "w").close()
            env = {"PATH": t + ":" + os.environ["PATH"], "HOME": t, "GITHUB_EVENT_NAME": ev, "GITHUB_REF": ref,
                   "GITHUB_SHA": sha, "GITHUB_OUTPUT": out, "TIP": {True: sha, False: "2" * 40, None: ""}[tip],
                   **{str(k): env_value(v, fork) for k, v in envs.items()}}
            p = subprocess.run(["bash", "-e", "-c", re.sub(r"\$\{\{\s*github\.sha\s*\}\}", sha, script)], env=env,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=20)
            runs += 1
            text = open(out).read()   # output names are case-insensitive; build-push-action strips quotes
            tags = [x.strip().strip("\"'") for line in text.split("\n") if line[:5].lower() == "tags=" for x in line[5:].split(",")]
            has = any(x.endswith(":ci-main") for x in tags)
            want = False             # ci-main is moved only by promote-main-image
            what = f"event={ev} ref={ref} tip={'?' if tip is None else tip}{' fork' if fork else ''}"
            if re.search(r"^tags<<", text, re.M | re.I):
                V("ci-main", f"{where} writes tags as a multi-line output for {what}, which the matrix does not read; write one tags=<comma list> line")
            elif p.returncode != 0 and not (tip is None and ev == "push" and ref == "refs/heads/main"):
                V("ci-main", f"{where} failed for {what}: {p.stderr.strip()[-200:]}")
            elif has != want:
                V("ci-main", f"{where} {'pushes' if has else 'does not push'} ci-main for {what}; ci-main is main's: only a push to refs/heads/main at main's tip may move it")
    return runs
if W["ci.yml"][0].get("push") != {"branches": ["main"]}:
    V("ci-main", f"ci.yml: on.push is {W['ci.yml'][0].get('push')!r}, not exactly branches: [main]")

promote = ci.get("promote-main-image") or {}
promote_steps = [s for s in promote.get("steps") or [] if isinstance(s, dict)]
promote_runs = [s for s in promote_steps if "run" in s]
if cond(promote.get("if", "")) != "github.event_name == 'push'":
    V("ci-main", "ci.yml:promote-main-image must run only on push")
if promote.get("permissions") != {"contents": "read", "actions": "read", "packages": "write"}:
    V("ci-main", f"ci.yml:promote-main-image permissions are {promote.get('permissions')!r}; expected contents/actions read and packages write")
if len(promote_runs) != 1:
    V("ci-main", f"ci.yml:promote-main-image must have exactly one reviewed script, found {len(promote_runs)}")
else:
    ps = str(promote_runs[0]["run"])
    promote_pin = hashlib.sha256(yaml.safe_dump(promote_runs[0], sort_keys=True).encode()).hexdigest()[:16]
    if promote_pin != "666a13a82bad109a":
        V("writer-actions", f"ci.yml:promote-main-image reviewed script changed (now {promote_pin}); review and re-pin it")
    required = [
        "actions/workflows/ci.yml/runs?head_sha=$SHA&event=merge_group&status=completed",
        '.head_sha == $sha and .event == "merge_group" and .conclusion == "success"',
        "$api/git/ref/heads/main", '[ "$tip" != "$SHA" ]',
        'docker buildx imagetools create --tag "$base:ci-main" "$base:ci-$SHA"',
    ]
    missing = [x for x in required if x not in ps]
    positions = [ps.find(x) for x in required]
    if missing or positions != sorted(positions):
        V("ci-main", f"ci.yml:promote-main-image must verify exact-SHA merge_group success, then main tip, then retag ci-<sha>; missing/out-of-order {missing or positions}")
writers, judged = [], 0
for jid, j in ci.items():
    if not writes(j["permissions"] if "permissions" in j else PERMS["ci.yml"]): continue
    writers.append(jid)
    if "uses" in j: V("writer-actions", f"ci.yml:{jid} can write and calls a reusable workflow ({j['uses']}) this check cannot vet")
    steps = [st for st in j.get("steps") or [] if isinstance(st, dict)]
    push = [st for st in steps if re.sub(r"@[^@]*$", "", str(st.get("uses", ""))).lower() == "docker/build-push-action"]
    tag_ids = {m.group(1) for st in push for m in [re.fullmatch(r"\$\{\{\s*steps\.([\w-]+)\.outputs\.tags\s*\}\}", str((st.get("with") or {}).get("tags", "")).strip())] if m}
    if len(tag_ids) != len(push) or len(tag_ids) > 1:
        V("ci-main", f"ci.yml:{jid}: each image push must take its tags from one step (`tags: ${{{{ steps.<id>.outputs.tags }}}}`), the step the matrix runs")
    tag = next((st for st in steps if st.get("id") in tag_ids), None)
    for i, st in enumerate(steps):
        u = str(st.get("uses", "")).strip(); ident = re.sub(r"@[^@]*$", "", u).lower(); w = st.get("with") or {}
        if u and (u.startswith(("./", "docker://")) or ident not in INPUTS):
            V("writer-actions", f"ci.yml:{jid} step {i} uses {u!r}: a job that can write uses only {sorted(INPUTS)} (any @ref), no ./ or docker:// action")
        elif u and (set(map(str, w)) - INPUTS[ident] or any(not l.strip().startswith("type=gha") for l in str(w.get("cache-to", "type=gha")).splitlines() if l.strip())):
            V("writer-actions", f"ci.yml:{jid} step {i} gives {ident} {sorted(map(str, w))}: in a job that can write, an action takes only the inputs vetted for it "
                                f"({sorted(INPUTS[ident])}, cache-to: only type=gha); outputs: or a registry cache can push any name")
        elif "run" in st and st is not tag and not (jid == "promote-main-image" and st in promote_runs):
            V("writer-actions", f"ci.yml:{jid} step {i} ({st.get('name', '?')}) runs a script in a job that can write; only the tag step may, because the matrix runs it")
    if tag is not None: judged += ci_main(jid, j, tag)
if judged == 0: V("ci-main", "no immutable image push in ci.yml took its tags from a step the matrix could run")
def strings(x):
    if isinstance(x, str): yield x
    elif isinstance(x, dict):
        for k, v in x.items(): yield from strings(k); yield from strings(v)
    elif isinstance(x, list):
        for v in x: yield from strings(v)
SECRET = re.compile(r"\bsecrets\b(?:\s*\.\s*([A-Za-z_][\w-]*)|\s*\[\s*['\"]([^'\"]*)['\"]\s*\])?", re.I)
for x in {e for v in strings(DOCS["ci.yml"]) for e in exprs(v)}:
    for m in SECRET.finditer(x):
        if (m.group(1) or m.group(2) or "").upper() != "GITHUB_TOKEN":
            V("secrets", f"ci.yml reads `{m.group(0)}` in `${{{{{x.strip()}}}}}`: only secrets.GITHUB_TOKEN may appear, so permissions: alone decide what ci.yml can write")
for jid, j in ci.items():
    if "secrets" in j: V("secrets", f"ci.yml:{jid} passes secrets ({j['secrets']!r}) to a reusable workflow")
if set(WAIVE) - used: V("event-condition", f"waiver(s) {sorted(set(WAIVE) - used)} matched nothing — stale; remove or re-pin")
if bad: print(f"ci-tier: FAIL — {len(bad)} violation(s): {' '.join(sorted(set(bad)))}"); sys.exit(1)
print(f"ci-tier: OK — ci.yml jobs={len(ci)} (awk={os.environ['CT_AWK']}) required={counts['required']} worker={counts['worker']}; "
      f"{len(req)} required names, each produced once on pull_request+merge_group; {len(path)} jobs on required paths, no push-only condition, no continue-on-error; "
      f"ci-main only after exact-SHA queue success and a main-tip check ({judged} immutable-tag matrix runs); {len(writers)} writing job(s), allowlisted actions and inputs only; no secret but GITHUB_TOKEN")
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
dispatch_table() {
    local file="${1:-$WF_DIR/ci.yml}" label="${2:-current}"
    python3 - "$file" "$label" <<'PY'
import sys, yaml
path, label = sys.argv[1:]
doc = yaml.safe_load(open(path, encoding="utf-8"))
jobs = doc.get("jobs") or {}
if not jobs:
    raise SystemExit("dispatch-table: workflow has no jobs")
on = doc.get("on", doc.get(True)) or {}
dispatch = (on.get("workflow_dispatch") or {}) if isinstance(on, dict) else {}
inputs = dispatch.get("inputs") or {}
choices = ((inputs.get("lanes") or {}).get("options") or ["default"])
def cond(job):
    value = str(job.get("if", ""))
    return value[3:-2].strip() if value.startswith("${{") and value.endswith("}}") else value
def selected(event, lane=None):
    out = []
    for jid, job in jobs.items():
        c = cond(job)
        if event == "push" and "github.event_name != 'push'" in c:
            continue
        if event != "push" and "github.event_name == 'push'" in c:
            continue
        if event == "pull_request" and "github.event_name != 'pull_request'" in c:
            continue
        if event == "workflow_dispatch" and lane not in (None, "default", "all"):
            declared = str((job.get("env") or {}).get("CI_DISPATCH_LANES", "")).split(",")
            if lane not in declared:
                continue
        out.append(jid)
    return out
print(f"| workflow | event / lane | jobs selected | derived job ids |")
print("|---|---|---:|---|")
for event in ("push", "pull_request", "merge_group"):
    picked = selected(event)
    print(f"| {label} | {event} | {len(picked)} | {', '.join(picked)} |")
for lane in choices:
    picked = selected("workflow_dispatch", lane)
    print(f"| {label} | workflow_dispatch / {lane} | {len(picked)} | {', '.join(picked)} |")
PY
}
plant_merge_deferral() {
    local tmp out rc
    tmp=$(mktemp -d); out="$tmp/out"
    trap 'rm -rf "$tmp"' RETURN
    cp -R "$WF_DIR" "$tmp/workflows"
    # Plant the exact regression this gate exists to prevent: the database
    # required check says "deferred" on PR *and merge_group*, while its suite
    # runs on push only.  The mutated copy must be rejected.
    python3 - "$tmp/workflows/ci.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
a = s.index("  database:\n")
b = s.index("\n  sanitizers:\n", a)
job = s[a:b]
job = job.replace("github.event_name == 'pull_request'", "github.event_name != 'push'")
job = job.replace("github.event_name != 'pull_request'", "github.event_name == 'push'")
open(p, "w", encoding="utf-8").write(s[:a] + job + s[b:])
PY
    rc=0
    CI_TIER_PLANT=1 CI_TIER_WF_DIR="$tmp/workflows" bash "$0" >"$out" 2>&1 || rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q 'heavy-deferral' "$out" || ! grep -q 'event-condition' "$out"; then
        cat "$out"
        echo "ci-tier: SELFTEST FAIL — merge_group deferral plant was not rejected as heavy-deferral + event-condition"
        return 1
    fi
    echo "ci-tier: SELFTEST OK — a heavy suite deferred on merge_group/push-only work is rejected"
}
plant_dispatch_contracts() {
    local tmp out rc
    tmp=$(mktemp -d); out="$tmp/out"
    trap 'rm -rf "$tmp"' RETURN
    cp -R "$WF_DIR" "$tmp/workflows"

    # A misspelled choice must be rejected specifically as an input contract
    # violation, rather than producing a green run with no selected worker.
    sed 's/options: \[all, asan, tsan, fuzz, linux\]/options: [all, asna, tsan, fuzz, linux]/' \
        "$WF_DIR/ci.yml" > "$tmp/workflows/ci.yml"
    rc=0
    CI_TIER_PLANT=1 CI_TIER_WF_DIR="$tmp/workflows" bash "$0" >"$out" 2>&1 || rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q 'FAIL \[dispatch-input\]' "$out"; then
        cat "$out"
        echo "ci-tier: SELFTEST FAIL — misspelled dispatch lane was not rejected as dispatch-input"
        return 1
    fi
    echo "ci-tier: SELFTEST OK — planted misspelled dispatch lane is rejected loudly"

    # Every job, not a hand-maintained subset, owns a declaration.  This plant
    # models a newly-added heavy job whose author omitted that declaration.
    cp "$WF_DIR/ci.yml" "$tmp/workflows/ci.yml"
    cat >> "$tmp/workflows/ci.yml" <<'YAML'
  planted-heavy-worker:
    name: planted undeclared heavy worker
    runs-on: ubuntu-latest
    steps:
      - run: echo should-not-run
YAML
    rc=0
    CI_TIER_PLANT=1 CI_TIER_WF_DIR="$tmp/workflows" bash "$0" >"$out" 2>&1 || rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q 'FAIL \[dispatch-declaration\].*planted-heavy-worker' "$out"; then
        cat "$out"
        echo "ci-tier: SELFTEST FAIL — undeclared heavy job was not rejected as dispatch-declaration"
        return 1
    fi
    echo "ci-tier: SELFTEST OK — planted undeclared heavy job is rejected"
}
plant_unverified_ci_main() {
    local tmp out rc
    tmp=$(mktemp -d); out="$tmp/out"
    trap 'rm -rf "$tmp"' RETURN
    cp -R "$WF_DIR" "$tmp/workflows"
    # Clean control is the live check run before self-tests. Plant the exact
    # dangerous variant: retag ci-main without requiring a successful queue
    # conclusion. It must fail specifically as [ci-main].
    sed 's/ and \.conclusion == "success"//' "$WF_DIR/ci.yml" > "$tmp/workflows/ci.yml"
    rc=0
    CI_TIER_PLANT=1 CI_TIER_WF_DIR="$tmp/workflows" bash "$0" >"$out" 2>&1 || rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q 'FAIL \[ci-main\].*verify exact-SHA merge_group success' "$out"; then
        cat "$out"
        echo "ci-tier: SELFTEST FAIL — unverified ci-main retag was not rejected as ci-main"
        return 1
    fi
    echo "ci-tier: SELFTEST OK — planted ci-main retag without verified queue success is rejected"
}
case "${1:-}" in
    "") check && { [ "${CI_TIER_PLANT:-0}" = 1 ] || { plant_merge_deferral && plant_dispatch_contracts && plant_unverified_ci_main; }; } ;;
    --live) live ;;
    --dispatch-table) dispatch_table "${2:-}" "${3:-}" ;;
    *) echo "usage: $0 [--live | --dispatch-table [workflow [label]]]" >&2; exit 2 ;;
esac
