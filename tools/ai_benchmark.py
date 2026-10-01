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

def snapshot(repo, revision, work):
    archive = subprocess.Popen(["git", "archive", revision], cwd=repo, stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", work], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait(): raise RuntimeError("git archive failed")
    subprocess.run(["git", "init", "-q"], cwd=work, check=True)
    subprocess.run(["git", "config", "user.email", "benchmark@example.invalid"], cwd=work, check=True)
    subprocess.run(["git", "config", "user.name", "AI benchmark"], cwd=work, check=True)
    subprocess.run(["git", "add", "-A"], cwd=work, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "benchmark fixture"], cwd=work, check=True)
    subprocess.run(["git", "remote", "add", "origin", str(work / ".stub-origin")], cwd=work, check=True)
    subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"], cwd=work, check=True)

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
    out.mkdir(parents=True); work=out/"worktree"; work.mkdir()
    supplied=vars(a).copy(); write(out/"inputs.json", supplied)
    shutil.copy2(a.task, out/"task.json"); prompt=Path(fixture["prompt"]).read_text() if Path(fixture["prompt"]).is_absolute() else (ROOT/fixture["prompt"]).read_text()
    (out/"prompt.txt").write_text(prompt, encoding="utf-8"); snapshot(repo,a.revision,work)
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
    except (ValueError, json.JSONDecodeError): telemetry={k:dict(UNAVAILABLE) for k in ("input_tokens","output_tokens","cached_tokens")}
    local=[]
    for i, cmd in enumerate(fixture["validation"]):
        expanded=[x.format(base="origin/main") for x in cmd]
        receipt=run(expanded,work,out,f"validation-{i+1}"); transcript.append(receipt); local.append(receipt)
        if receipt["exit_code"]: break
    diff=subprocess.run(["git","diff","--binary","origin/main"],cwd=work,text=True,capture_output=True).stdout
    (out/"result.diff").write_text(diff,encoding="utf-8")
    commit=subprocess.run(["git","rev-parse","HEAD"],cwd=work,text=True,capture_output=True)
    commits=subprocess.run(["git","rev-list","--count","origin/main..HEAD"],cwd=work,text=True,capture_output=True)
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
    result={"schema_version":"1.0.0","inputs":supplied,"started_at":start,"local_completed_at":completed,"elapsed_seconds":elapsed,
      "remote_first_push":dict(UNAVAILABLE),"environment":{"platform":platform.platform(),"python":platform.python_version(),"env":{k:os.environ[k] for k in sorted(os.environ) if k in ("LANG","LC_ALL","TZ")}},
      "adapter":{"name":a.adapter,"model":a.model,"command":command,"version_command":adapter["version_command"],"version_output":"adapter-version.stdout"},
      "telemetry":telemetry,"pricing":pricing,"computed_cost":cost,"commands":transcript,
      "precheck_rounds":sum(r["argv"][:2]==["make","precheck"] for r in local),
      "changed_test_rounds":sum(r["argv"][:2]==["make","test-changed"] for r in local),"ci_rounds":dict(UNAVAILABLE),
      "commit":{"status":"available","created":commits.stdout.strip() != "0","head":commit.stdout.strip()},
      "changed_plan_receipt":{"file":"validation-2.stdout" if len(local)>1 else None,"not_run_locally":[x for x in plan.splitlines() if "NOT RUN LOCALLY" in x]}}
    write(out/"result.json",result); write(out/"transcript.json",transcript)
    return 0 if local and all(x["exit_code"]==0 for x in local) else 1
if __name__ == "__main__": sys.exit(main())
