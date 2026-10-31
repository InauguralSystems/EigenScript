#!/usr/bin/env python3
"""Regression plants for issue #2290's widened executable-doc claim gate."""
import importlib.util
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKER = os.path.join(ROOT, "tests", "test_doc_examples.py")


def run_doc(body):
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(body)
        path = f.name
    try:
        return subprocess.run([sys.executable, CHECKER, path], text=True,
                              capture_output=True, cwd=ROOT)
    finally:
        os.unlink(path)


def main():
    failures = 0
    def check(ok, label):
        nonlocal failures
        print(("PASS: " if ok else "FAIL: ") + label)
        failures += not ok

    wrong = run_doc("```eigenscript fragment\nx is 1\nx  # 2\n```\n")
    check(wrong.returncode != 0 and "states a VALUE" in wrong.stdout,
          "planted bare numeric claim turns the gate red")
    true = run_doc("```eigenscript fragment\nx is 1\nx  # 1\n```\n")
    check(true.returncode != 0 and "states a VALUE" in true.stdout,
          "an unpaired true claim is still unchecked and red")
    paired = run_doc("```eigenscript\nprint of 1  # 1\n```\n```output\n1\n```\n")
    check(paired.returncode == 0 and "1 claim(s) examined" in paired.stdout,
          "a real output block checks the claim")
    swapped = run_doc(
        "```eigenscript\nprint of 1  # 2\nprint of 2  # 1\n```\n"
        "```output\n1\n2\n```\n")
    check(swapped.returncode != 0 and swapped.stdout.count("states a VALUE") == 2,
          "each swapped claim fails against the value from its own line")
    fake_pair = run_doc("```eigenscript fragment\nx is 1  # 1\n```\n"
                        "```output\n1\n```\n")
    check(fake_pair.returncode != 0 and "states a VALUE" in fake_pair.stdout,
          "an output block cannot pretend to check a fragment")
    empty = run_doc("```eigenscript fragment\nx is 1\n```\n")
    check(empty.returncode != 0 and "examined 0 value comments" in empty.stdout,
          "zero examined claims is red")

    spec = importlib.util.spec_from_file_location("docgate", CHECKER)
    gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
    probes = ['x # 1', 'x # "improving"', 'x # true', 'x # [1, 2]',
              'x # {"a": 1}', 'x # null', 'x # gives 2',
              'x # result gives 999', '# settles after 25 steps']
    check(all(gate.VALUE_COMMENT.search(x) for x in probes),
          "matcher retains legacy claims and recognizes bare value forms")

    legacy = re.compile(r"#.*(after|gives|prints|≈|~) *[0-9]")
    old_count = new_count = 0
    for relative in gate.POPULATION:
        for _line, info, _args, text in gate.blocks(os.path.join(ROOT, relative)):
            if info != "eigenscript":
                continue
            for source_line in text.splitlines():
                old_count += bool(legacy.search(source_line))
                new_count += bool(gate.VALUE_COMMENT.search(source_line))
    print("examined counts on pinned docs: old=%d new=%d" %
          (old_count, new_count))
    check(new_count >= old_count,
          "widened matcher examines at least every legacy match on the same docs")
    return 1 if failures else 0

if __name__ == "__main__":
    if "--selftest" in sys.argv:
        pass
    sys.exit(main())
