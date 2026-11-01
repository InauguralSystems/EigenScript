#!/usr/bin/env python3
"""Regression plants for issue #2290's executable-doc value-comment ban."""
import importlib.util
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKER = os.path.join(ROOT, "tests", "test_doc_examples.py")


def run_doc(body, env=None):
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(body)
        path = f.name
    try:
        return subprocess.run([sys.executable, CHECKER, path], text=True,
                              capture_output=True, cwd=ROOT, env=env)
    finally:
        os.unlink(path)


def main():
    failures = 0

    def check(ok, label):
        nonlocal failures
        print(("PASS: " if ok else "FAIL: ") + label)
        failures += not ok

    def rejected(line, output="1"):
        result = run_doc("```eigenscript\n%s\n```\n```output\n%s\n```\n" %
                         (line, output))
        return result.returncode != 0 and "states a VALUE" in result.stdout

    check(rejected("print of 1  # 1"),
          "a bare numeric value comment fails")
    check(rejected('print of "improving"  # "improving"', "improving"),
          "a quoted value comment fails")
    check(rejected("print of 1  # result gives 999"),
          "a legacy anywhere-in-comment claim fails")
    check(rejected("print of 1  # 999"),
          "a value comment fails even beside the correct output block")

    string_hash = run_doc(
        '```eigenscript\nprint of "#1"\n```\n```output\n#1\n```\n')
    check(string_hash.returncode == 0 and
          "0 claim(s) examined" in string_hash.stdout,
          "a hash inside a string is not a comment")

    non_value = run_doc(
        '```eigenscript\nprint of 1  # loop forever\n```\n```output\n1\n```\n')
    check(non_value.returncode == 0 and
          "0 claim(s) examined" in non_value.stdout,
          "a non-value comment passes")

    spec = importlib.util.spec_from_file_location("docgate", CHECKER)
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    legacy = re.compile(r"#.*(after|gives|prints|≈|~) *[0-9]")
    old_count = new_count = 0
    for relative in gate.POPULATION:
        for _line, info, _args, text in gate.blocks(os.path.join(ROOT, relative)):
            if info != "eigenscript" or _args.strip().startswith("nocheck"):
                continue
            for source_line in text.splitlines():
                old_count += bool(legacy.search(source_line))
                new_count += gate.value_comment(source_line) is not None
    print("examined counts on pinned docs: old=%d new=%d" %
          (old_count, new_count))
    check(new_count >= old_count,
          "widened matcher examines at least every legacy match on the same docs")

    listed = subprocess.run(
        [sys.executable, CHECKER, "--list", "README.md"], text=True,
        capture_output=True, cwd=ROOT,
        env={**os.environ, "EIGENSCRIPT": "/does/not/exist"})
    check(listed.returncode == 0,
          "list mode counts claims without executing examples")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
