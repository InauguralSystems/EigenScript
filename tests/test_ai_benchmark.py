#!/usr/bin/env python3
import importlib.util, json, os, subprocess, sys, tempfile, unittest
from unittest.mock import patch
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("ai_benchmark",ROOT/"tools/ai_benchmark.py")
bench=importlib.util.module_from_spec(spec); spec.loader.exec_module(bench)

class BenchmarkTest(unittest.TestCase):
    def test_main_lifecycle_with_benign_agents(self):
        # Exercise the production entrypoint, real subprocesses and real Git.
        cases=[("missing",False), ("nonzero",False), ("noop",False),
               ("uncommitted",False), ("committed",True), ("validation-failure",False),
               ("retries",True), ("missing-telemetry",True), ("inspection-failure",False),
               ("partial-tracked",False), ("partial-untracked",False), ("partial-inspection",False),
               ("incomplete-telemetry",True)]
        for mode, expected in cases:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as td:
                root=Path(td); repo=root/"repo"; repo.mkdir()
                env=dict(bench.isolated_git_env(), GIT_AUTHOR_NAME="Fixture",
                         GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_NAME="Fixture",
                         GIT_COMMITTER_EMAIL="fixture@example.invalid")
                def git(*args):
                    return subprocess.check_output(["git",*args],cwd=repo,text=True,env=env).strip()
                git("init","-q"); (repo/"tracked").write_text("before\n")
                git("add","-A"); git("commit","--no-gpg-sign","-qm","fixture")
                # Tiny benign fixture Makefile exercises actual driver counters and order.
                (repo/"Makefile").write_text("precheck:\n\t@true\ntest-changed:\n\t@true\n")
                git("add","Makefile"); git("commit","--no-gpg-sign","-qm","validation fixture")
                revision=git("rev-parse","HEAD")
                prompt=root/"prompt.txt"; prompt.write_text("benign fixture change")
                task=root/"task.json"; task.write_text(json.dumps({"prompt":str(prompt),
                    "validation":[["make","precheck","BASE={base}"],["make","test-changed","BASE={base}"]]}))
                fake=root/"agent.py"
                fake.write_text("""import json, os, subprocess, sys
from pathlib import Path
mode=sys.argv[1]
if mode != 'noop':
    Path('tracked').write_text('after\\n')
    if mode == 'partial-tracked':
        Path('Makefile').write_text('precheck:\\n\\t@test \"$$(cat tracked)\" = \"finishing correction\"\\ntest-changed:\\n\\t@true\\n')
    if mode == 'partial-untracked':
        Path('Makefile').write_text('precheck:\\n\\t@test -f finishing\\ntest-changed:\\n\\t@true\\n')
    if mode != 'uncommitted':
        env=dict(os.environ, GIT_AUTHOR_NAME='Agent', GIT_AUTHOR_EMAIL='agent@example.invalid',
                 GIT_COMMITTER_NAME='Agent', GIT_COMMITTER_EMAIL='agent@example.invalid')
        subprocess.run(['git','add','-A'],check=True,env=env)
        subprocess.run(['git','-c','core.hooksPath=/dev/null','commit','--no-gpg-sign','-qm','change'],check=True,env=env)
if mode == 'validation-failure':
    Path('Makefile').write_text('precheck:\\n\\t@false\\ntest-changed:\\n\\t@true\\n')
    subprocess.run(['git','add','Makefile'],check=True,env=env)
    subprocess.run(['git','-c','core.hooksPath=/dev/null','commit','--no-gpg-sign','-qm','validation fixture'],check=True,env=env)
if mode == 'partial-tracked':
    Path('tracked').write_text('finishing correction\\n')
if mode == 'partial-untracked':
    Path('finishing').write_text('finishing correction\\n')
if mode == 'inspection-failure':
    import shutil
    shutil.rmtree('.git')
if mode == 'retries':
    print(json.dumps({'benchmark':{'precheck_rounds':3,'changed_test_rounds':2,'ci_rounds':1}}))
elif mode == 'incomplete-telemetry':
    print(json.dumps({'benchmark':{'precheck_rounds':3,'changed_test_rounds':2}}))
else:
    print('{}')
sys.exit(7 if mode == 'nonzero' else 0)
""")
                adapters=root/"adapters"; adapters.mkdir()
                config={"command":[str(root/"absent")] if mode=="missing" else [sys.executable,str(fake),mode],
                        "version_command":[sys.executable,"--version"],
                        "telemetry":{k:"benchmark."+k for k in ("precheck_rounds","changed_test_rounds","ci_rounds")}}
                (adapters/"fake.json").write_text(json.dumps(config))
                output=root/"out"
                real_run=bench.run
                def inspected_run(*args, **kwargs):
                    receipt=real_run(*args, **kwargs)
                    # Preserve valid diff/count/head while failing one inspection receipt.
                    if mode=="partial-inspection" and receipt["name"]=="head":
                        receipt["exit_code"]=1
                    return receipt
                with patch.object(bench,"BENCH",root), patch.object(bench,"run",inspected_run):
                    rc=bench.main(["--repository",str(repo),"--task",str(task),"--revision",revision,
                                   "--adapter","fake","--model","fixture","--output",str(output)])
                result=json.loads((output/"result.json").read_text())
                self.assertEqual(rc,0 if expected else 1)
                self.assertEqual(result["local_success"],expected)
                self.assertEqual(result["local_completed_at"] is not None,expected)
                self.assertTrue((output/"agent.stderr").exists())
                self.assertTrue((output/"worktree").exists())
                self.assertTrue((output/"transcript.json").exists())
                if mode in ("inspection-failure","partial-inspection"):
                    self.assertEqual(result["commit"]["status"],"unavailable")
                    self.assertFalse(result["commit"]["created"])
                if mode=="retries":
                    self.assertEqual(result["total_rounds"],{"status":"available","value":6})
                    self.assertEqual(result["precheck_rounds"]["value"],3)
                else:
                    self.assertEqual(result["total_rounds"],{"status":"unavailable"})
                self.assertEqual(result["driver_validation_attempts"],{"precheck":1,"test_changed":0 if mode=="validation-failure" else 1})
                if mode=="partial-inspection":
                    self.assertTrue((output/"result.diff").read_text())
                    self.assertGreater(int((output/"commit-count.stdout").read_text()),0)
                if mode=="validation-failure":
                    self.assertFalse((output/"validation-2.stdout").exists())

    def test_dirty_source_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            repo=Path(td); subprocess.run(["git","init","-q"],cwd=repo,check=True)
            subprocess.run(["git","config","user.email","test@example.invalid"],cwd=repo,check=True)
            subprocess.run(["git","config","user.name","Test"],cwd=repo,check=True)
            (repo/"tracked").write_text("clean\n"); subprocess.run(["git","add","tracked"],cwd=repo,check=True)
            subprocess.run(["git","commit","--no-gpg-sign","-qm","fixture"],cwd=repo,check=True)
            self.assertTrue(bench.clean(repo)); (repo/"untracked").write_text("dirty\n")
            self.assertFalse(bench.clean(repo))

    def test_all_adapter_parsers_and_raw_fixtures(self):
        expected={"codex":(111,222,33),"claude":(101,202,30),"gemini":(121,242,36)}
        for name, values in expected.items():
            path=ROOT/"bench/ai_contribution/events"/f"{name}.redacted.json"
            raw=path.read_bytes()
            parsed=bench.normalize(name,raw.decode())
            self.assertEqual(tuple(parsed[x]["value"] for x in ("input_tokens","output_tokens","cached_tokens")),values)
            self.assertEqual(path.read_bytes(),raw, "parser changed the raw event")

    def test_snapshot_has_one_commit_and_stub_base(self):
        with tempfile.TemporaryDirectory() as td:
            work=Path(td)/"work"; work.mkdir(); bench.snapshot(ROOT,"HEAD",work)
            count=subprocess.check_output(["git","rev-list","--count","HEAD"],cwd=work,text=True).strip()
            base=subprocess.check_output(["git","rev-parse","origin/main"],cwd=work,text=True).strip()
            head=subprocess.check_output(["git","rev-parse","HEAD"],cwd=work,text=True).strip()
            self.assertEqual(count,"1"); self.assertEqual(base,head)
            remote=subprocess.check_output(["git","remote","get-url","origin"],cwd=work,text=True).strip()
            self.assertEqual(remote,str(work/".stub-origin"))

    @unittest.skipUnless(os.geteuid() == 0, "requires ownership mismatch")
    def test_snapshot_archives_checkout_owned_by_runner_user(self):
        with tempfile.TemporaryDirectory() as td:
            repo=Path(td)/"repo"; repo.mkdir()
            subprocess.run(["git","init","-q"],cwd=repo,check=True)
            (repo/"tracked").write_text("fixture\n")
            subprocess.run(["git","add","tracked"],cwd=repo,check=True)
            tree=subprocess.check_output(["git","write-tree"],cwd=repo,text=True).strip()
            identity=dict(os.environ, GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                          GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
            commit=subprocess.check_output(["git","commit-tree",tree],cwd=repo,input="fixture\n",
                                           text=True,env=identity).strip()
            subprocess.run(["git","update-ref","HEAD",commit],cwd=repo,check=True)
            for path in [repo, *repo.rglob("*")]:
                os.chown(path, 65534, 65534, follow_symlinks=False)
            work=Path(td)/"work"; work.mkdir()
            bench.snapshot(repo,"HEAD",work)
            self.assertEqual((work/"tracked").read_text(),"fixture\n")

    def test_snapshot_ignores_host_commit_policy(self):
        with tempfile.TemporaryDirectory() as td:
            hooks=Path(td)/"hooks"; hooks.mkdir()
            hook=hooks/"pre-commit"; hook.write_text("#!/bin/sh\nexit 99\n"); hook.chmod(0o755)
            template=Path(td)/"template"; (template/"hooks").mkdir(parents=True)
            hook=template/"hooks"/"post-commit"; hook.write_text("#!/bin/sh\nexit 98\n"); hook.chmod(0o755)
            source=Path(td)/"source"; source.mkdir()
            foreign=Path(td)/"foreign.git"
            injected={"GIT_DIR":str(foreign), "GIT_WORK_TREE":str(source),
                      "GIT_INDEX_FILE":str(Path(td)/"foreign.index"),
                      "GIT_CONFIG_COUNT":"3", "GIT_CONFIG_KEY_0":"core.hooksPath",
                      "GIT_CONFIG_VALUE_0":str(hooks), "GIT_CONFIG_KEY_1":"commit.gpgsign",
                      "GIT_CONFIG_VALUE_1":"true", "GIT_CONFIG_KEY_2":"init.templateDir",
                      "GIT_CONFIG_VALUE_2":str(template)}
            previous={key:os.environ.get(key) for key in injected}
            try:
                os.environ.update(injected); bench.snapshot(ROOT,"HEAD",source)
            finally:
                for key, value in previous.items():
                    if value is None: os.environ.pop(key,None)
                    else: os.environ[key]=value
            self.assertEqual(subprocess.check_output(["git","rev-list","--count","HEAD"],cwd=source,text=True).strip(),"1")
            self.assertFalse((source/".git"/"hooks"/"post-commit").exists())
            self.assertFalse(foreign.exists())

    def test_eigenscript_validation_is_public_contract_in_order(self):
        task=json.loads((ROOT/"bench/ai_contribution/tasks/eigenscript-1236.json").read_text())
        self.assertEqual(task["validation"],[["make","precheck","BASE={base}"],["make","test-changed","BASE={base}"]])
        self.assertNotIn(["make","test"],task["validation"])

    def test_schema_requires_separate_local_and_remote_results(self):
        schema=json.loads((ROOT/"bench/ai_contribution/result-schema-v1.json").read_text())
        self.assertIn("local_completed_at",schema["required"])
        self.assertIn("remote_first_push",schema["required"])
        self.assertIn("computed_cost",schema["required"])

if __name__ == "__main__": unittest.main()
