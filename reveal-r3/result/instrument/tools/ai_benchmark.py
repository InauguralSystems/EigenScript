#!/usr/bin/env python3
"""Provider-neutral, artifact-first AI contribution benchmark driver."""
import argparse, datetime, json, os, platform, shutil, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "bench" / "ai_contribution"
UNAVAILABLE = {"status": "unavailable"}

def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def load(path):
    with open(path, encoding="utf-8") as f: return json.load(f)
def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
def run(argv, cwd, out, name, stdin=None, env=None):
    started = now(); before = time.monotonic()
    try: p = subprocess.run(argv, cwd=cwd, input=stdin, text=True, capture_output=True, env=env)
    except OSError as exc:
        p = subprocess.CompletedProcess(argv, 127, "", f"{type(exc).__name__}: {exc}\n")
    (out / f"{name}.stdout").write_text(p.stdout, encoding="utf-8")
    (out / f"{name}.stderr").write_text(p.stderr, encoding="utf-8")
    return {"name": name, "argv": argv, "started_at": started, "ended_at": now(),
            "elapsed_seconds": round(time.monotonic()-before, 6), "exit_code": p.returncode,
            "stdout": f"{name}.stdout", "stderr": f"{name}.stderr"}

def clean(repo):
    p = subprocess.run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=repo,
                       text=True, capture_output=True, check=True)
    return not p.stdout

def isolated_git_env():
    """Return an environment that cannot redirect or configure fixture Git."""
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_")}
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    return env

def snapshot(repo, revision, work):
    git_env = isolated_git_env()
    archive = subprocess.Popen(["git", "-c", f"safe.directory={repo}",
                                "archive", revision], cwd=repo,
                               stdout=subprocess.PIPE, env=git_env)
    subprocess.run(["tar", "-x", "-C", work], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait(): raise RuntimeError("git archive failed")
    subprocess.run(["git", "init", "-q"], cwd=work, check=True, env=git_env)
    subprocess.run(["git", "add", "-A"], cwd=work, check=True, env=git_env)
    # Build the fixture commit with plumbing commands.  Unlike ``git commit``,
    # commit-tree does not run hooks or consult commit.gpgSign, so machine
    # policy cannot execute checkout-external code or make the snapshot fail.
    tree = subprocess.check_output(["git", "write-tree"], cwd=work,
                                   text=True, env=git_env).strip()
    identity = dict(git_env,
                    GIT_AUTHOR_NAME="AI benchmark",
                    GIT_AUTHOR_EMAIL="benchmark@example.invalid",
                    GIT_COMMITTER_NAME="AI benchmark",
                    GIT_COMMITTER_EMAIL="benchmark@example.invalid")
    commit = subprocess.check_output(["git", "commit-tree", tree], cwd=work,
                                     input="benchmark fixture\n", text=True,
                                     env=identity).strip()
    subprocess.run(["git", "update-ref", "HEAD", commit], cwd=work,
                   check=True, env=git_env)
    subprocess.run(["git", "remote", "add", "origin", str(work / ".stub-origin")],
                   cwd=work, check=True, env=git_env)
    subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
                   cwd=work, check=True, env=git_env)

def normalize(adapter, raw):
    data = json.loads(raw)
    paths = load(BENCH / "adapters" / f"{adapter}.json")["telemetry"]
    def at(path):
        value = data
        try:
            for key in path.split("."): value = value[int(key)] if key.isdigit() else value[key]
            return {"status": "available", "value": value}
        except (KeyError, IndexError, TypeError): return dict(UNAVAILABLE)
    return {key: at(path) for key, path in paths.items()}

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repository", required=True); ap.add_argument("--task", required=True)
    ap.add_argument("--revision", required=True); ap.add_argument("--adapter", required=True)
    ap.add_argument("--model", required=True); ap.add_argument("--output", required=True)
    ap.add_argument("--pricing")
    a = ap.parse_args(argv); repo=Path(a.repository).resolve(); out=Path(a.output).resolve()
    if not clean(repo): ap.error("source fixture is dirty; refusing benchmark run")
    fixture=load(Path(a.task)); adapter=load(BENCH/"adapters"/f"{a.adapter}.json")
    if fixture.get("revision") and a.revision != fixture["revision"]: ap.error("task requires its pinned bug-present revision")
    out.mkdir(parents=True); work=out/"worktree"; work.mkdir()
    supplied=vars(a).copy(); write(out/"inputs.json", supplied)
    shutil.copy2(a.task, out/"task.json"); prompt=Path(fixture["prompt"]).read_text() if Path(fixture["prompt"]).is_absolute() else (ROOT/fixture["prompt"]).read_text()
    (out/"prompt.txt").write_text(prompt, encoding="utf-8"); snapshot(repo,a.revision,work)
    base=subprocess.check_output(["git","rev-parse","HEAD"],cwd=work,text=True,env=isolated_git_env()).strip()
    start=now(); transcript=[]
    command=[x.format(model=a.model, prompt=str(out/"prompt.txt"), raw=str(out/"raw-result.jsonl")) for x in adapter["command"]]
    env=os.environ.copy(); env["AI_BENCH_RAW_RESULT"]=str(out/"raw-result.jsonl")
    transcript.append(run(command,work,out,"agent",stdin=prompt,env=env))
    raw_path=out/"raw-result.jsonl"
    if not raw_path.exists(): shutil.copy2(out/"agent.stdout", raw_path)
    raw=raw_path.read_text(encoding="utf-8") if raw_path.exists() else "{}"
    # Parsers consume the final JSON event while the byte-for-byte stream remains untouched.
    final=next((line for line in reversed(raw.splitlines()) if line.strip()), "{}")
    try: telemetry=normalize(a.adapter, final)
    except (ValueError, json.JSONDecodeError): telemetry={k:dict(UNAVAILABLE) for k in ("input_tokens","output_tokens","cached_tokens","precheck_rounds","changed_test_rounds","ci_rounds")}
    before_head=run(["git","rev-parse","HEAD"],work,out,"validated-head-before",env=isolated_git_env())
    before_status=run(["git","status","--porcelain","--untracked-files=all"],work,out,"validated-status-before",env=isolated_git_env())
    transcript.extend([before_head,before_status])
    validated_head=(out/"validated-head-before.stdout").read_text().strip()
    validation_input_clean=before_head["exit_code"]==0 and before_status["exit_code"]==0 and not (out/"validated-status-before.stdout").read_text()
    local=[]
    for i, cmd in enumerate(fixture["validation"]):
        expanded=[x.format(base="origin/main") for x in cmd]
        receipt=run(expanded,work,out,f"validation-{i+1}"); transcript.append(receipt); local.append(receipt)
        if receipt["exit_code"]: break
    # Inspect the immutable snapshot commit, never the mutable origin/main ref.
    inspections=[]
    for name, args in (("committed-diff", ["diff","--binary",base,"HEAD"]),
                       ("head", ["rev-parse","HEAD"]),
                       ("validated-status-after", ["status","--porcelain","--untracked-files=all"]),
                       ("commit-count", ["rev-list","--count",f"{base}..HEAD"])):
        receipt=run(["git",*args],work,out,name,env=isolated_git_env())
        inspections.append(receipt); transcript.append(receipt)
    diff=(out/"committed-diff.stdout").read_text()
    (out/"result.diff").write_text(diff,encoding="utf-8")
    inspection_ok=all(r["exit_code"]==0 for r in inspections)
    count=(out/"commit-count.stdout").read_text().strip()
    created=inspection_ok and count.isdigit() and int(count)>0 and bool(diff)
    head=(out/"head.stdout").read_text().strip()
    validated_artifact=validation_input_clean and head==validated_head and not (out/"validated-status-after.stdout").read_text()
    success=validated_artifact and transcript[0]["exit_code"]==0 and created and bool(local) and all(r["exit_code"]==0 for r in local)
    pricing=load(Path(a.pricing)) if a.pricing else dict(UNAVAILABLE)
    version=run(adapter["version_command"],work,out,"adapter-version")
    transcript.insert(0,version)
    plan="\n".join((out/r["stdout"]).read_text() for r in local)
    completed=now(); elapsed=sum(x["elapsed_seconds"] for x in transcript)
    cost=dict(UNAVAILABLE)
    if a.pricing and all(telemetry.get(k,{}).get("status")=="available" for k in ("input_tokens","output_tokens")):
        rates=pricing.get("usd_per_million_tokens",{})
        if "input" in rates and "output" in rates:
            cost={"status":"available","currency":"USD","value":round((telemetry["input_tokens"]["value"]*rates["input"]+telemetry["output_tokens"]["value"]*rates["output"])/1_000_000,8)}
    round_keys=("precheck_rounds","changed_test_rounds","ci_rounds")
    total_rounds=dict(UNAVAILABLE)
    if all(telemetry.get(k,{}).get("status")=="available" and isinstance(telemetry[k].get("value"),int) and not isinstance(telemetry[k]["value"],bool) and telemetry[k]["value"]>=0 for k in round_keys):
        total_rounds={"status":"available","value":sum(telemetry[k]["value"] for k in round_keys)}
    result={"schema_version":"1.0.0","inputs":supplied,"started_at":start,"local_completed_at":completed if success else None,"local_success":success,"elapsed_seconds":elapsed,
      "remote_first_push":dict(UNAVAILABLE),"environment":{"platform":platform.platform(),"python":platform.python_version(),"env":{k:os.environ[k] for k in sorted(os.environ) if k in ("LANG","LC_ALL","TZ")}},
      "adapter":{"name":a.adapter,"model":a.model,"command":command,"version_command":adapter["version_command"],"version_output":"adapter-version.stdout"},
      "telemetry":telemetry,"pricing":pricing,"computed_cost":cost,"commands":transcript,
      "total_rounds":total_rounds,"driver_validation_attempts":{"precheck":sum(r["argv"][:2]==["make","precheck"] for r in local),
      "test_changed":sum(r["argv"][:2]==["make","test-changed"] for r in local)},
      "precheck_rounds":telemetry.get("precheck_rounds",dict(UNAVAILABLE)),
      "changed_test_rounds":telemetry.get("changed_test_rounds",dict(UNAVAILABLE)),"ci_rounds":telemetry.get("ci_rounds",dict(UNAVAILABLE)),
      "commit":{"status":"available" if inspection_ok else "unavailable","created":created,"head":head if inspection_ok else None,"snapshot":base},
      "changed_plan_receipt":{"file":"validation-2.stdout" if len(local)>1 else None,"not_run_locally":[x for x in plan.splitlines() if "NOT RUN LOCALLY" in x]}}
    write(out/"result.json",result); write(out/"transcript.json",transcript)
    return 0 if success else 1
if __name__ == "__main__": sys.exit(main())
