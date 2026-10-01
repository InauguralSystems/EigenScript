#!/usr/bin/env python3
import importlib.util, json, os, subprocess, tempfile, unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("ai_benchmark",ROOT/"tools/ai_benchmark.py")
bench=importlib.util.module_from_spec(spec); spec.loader.exec_module(bench)

class BenchmarkTest(unittest.TestCase):
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

    def test_snapshot_ignores_host_commit_policy(self):
        with tempfile.TemporaryDirectory() as td:
            hooks=Path(td)/"hooks"; hooks.mkdir()
            hook=hooks/"pre-commit"; hook.write_text("#!/bin/sh\nexit 99\n"); hook.chmod(0o755)
            template=Path(td)/"template"; (template/"hooks").mkdir(parents=True)
            hook=template/"hooks"/"post-commit"; hook.write_text("#!/bin/sh\nexit 98\n"); hook.chmod(0o755)
            source=Path(td)/"source"; source.mkdir()
            injected={"GIT_CONFIG_COUNT":"3", "GIT_CONFIG_KEY_0":"core.hooksPath",
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
