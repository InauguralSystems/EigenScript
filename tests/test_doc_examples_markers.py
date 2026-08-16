#!/usr/bin/env python3
"""Regression checks for README opt-in and doc-gate count behavior."""

import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "tests" / "test_doc_examples.py"

FAKE_EIGENSCRIPT = """\
#!/usr/bin/env python3
from pathlib import Path
import os
import signal
import sys

code = Path(sys.argv[1]).read_text()
if "asan-leak" in code:
    print("marked")
    print("LeakSanitizer: detected memory leaks", file=sys.stderr)
    sys.exit(7)
if "asan-mismatch" in code:
    print("wrong")
    print("LeakSanitizer: detected memory leaks", file=sys.stderr)
    sys.exit(7)
if "mixed-error" in code:
    print("marked")
    print("fatal execution failure", file=sys.stderr)
    print("LeakSanitizer: detected memory leaks", file=sys.stderr)
    sys.exit(7)
if "no-lsan" in code:
    print("marked")
    print("fatal execution failure", file=sys.stderr)
    sys.exit(7)
if "error-after-marker" in code:
    print("marked")
    print("LeakSanitizer: detected memory leaks", file=sys.stderr)
    print("fatal execution failure", file=sys.stderr)
    sys.exit(7)
if "asan-hard-and-leak" in code:
    print("marked")
    print("==123==ERROR: AddressSanitizer: heap-use-after-free", file=sys.stderr)
    print("LeakSanitizer: detected memory leaks", file=sys.stderr)
    sys.exit(7)
if "multiple-lsan-markers" in code:
    print("marked")
    print("LeakSanitizer: detected memory leaks", file=sys.stderr)
    print("LeakSanitizer: detected memory leaks", file=sys.stderr)
    sys.exit(7)
if "malformed-lsan-report" in code:
    print("marked")
    print("=================================================================", file=sys.stderr)
    print("==123==ERROR: LeakSanitizer: detected memory leaks", file=sys.stderr)
    print("not a compiler-rt leak frame", file=sys.stderr)
    print("SUMMARY: AddressSanitizer: 32 byte(s) leaked in 1 allocation(s).",
          file=sys.stderr)
    sys.exit(7)
if "ubsan-and-leak" in code:
    print("marked")
    print("fake.eigs:1:1: runtime error: signed integer overflow",
          file=sys.stderr)
    print("LeakSanitizer: detected memory leaks", file=sys.stderr)
    sys.exit(7)
if "stdout-leak" in code:
    print("marked")
    print("LeakSanitizer: detected memory leaks")
    sys.exit(7)


def emit_compiler_rt_report():
    lines = [
        "",
        "=================================================================",
        "==123==ERROR: LeakSanitizer: detected memory leaks",
        "",
        "Direct leak of 32 byte(s) in 1 object(s) allocated from:",
        "    #0 0x7f0000000000 in malloc fake.c:10:1",
        "    #1 0x7f0000000010 in main fake.c:20:1",
    ]
    lines.extend([
        "Objects leaked above:",
        "0x602000000010 (32 bytes)",
        "",
    ])
    lines.extend([
        "Indirect leak of 16 byte(s) in 1 object(s) allocated from:",
        "    #0 0x7f0000000000 in malloc fake.c:30:1",
        "    #1 0x7f0000000020 in helper fake.c:40:1",
    ])
    lines.extend([
        "Objects leaked above:",
        "0x602000000030 (16 bytes)",
        "",
        "-----------------------------------------------------",
        "Suppressions used:",
        "  count      bytes template",
        "      1         32 my_suppression",
        "-----------------------------------------------------",
        "",
        "SUMMARY: AddressSanitizer: 48 byte(s) leaked in 2 allocation(s).",
    ])
    return lines


if "full-leak-report" in code:
    print("marked")
    lines = emit_compiler_rt_report()
    report = "\\n".join(lines) + "\\n"
    print(report, end="", file=sys.stderr)
    sys.exit(23)
misplaced_cases = (
    ("misplaced-suppression-row", "1 2 fatal execution failure", False),
    ("misplaced-suppression-header", "Suppressions used:", False),
    ("misplaced-suppression-columns", "count bytes template", False),
    ("misplaced-object-line", "0x602000000040 (8 bytes)", False),
    ("misplaced-frame", "#0 0x7f0000000030 in bad fake.c:50:1", False),
    ("misplaced-separator", "-----------------------------------------------------", False),
    ("misplaced-marker", "==456==ERROR: LeakSanitizer: detected memory leaks", False),
    ("misplaced-summary",
     "SUMMARY: AddressSanitizer: 8 byte(s) leaked in 1 allocation(s).", False),
    ("misplaced-direct-block",
     "Direct leak of 8 byte(s) in 1 object(s) allocated from:", False),
    ("misplaced-indirect-block",
     "Indirect leak of 8 byte(s) in 1 object(s) allocated from:", False),
    ("semantic-before-report", "fatal execution failure", False),
    ("semantic-after-report", "fatal execution failure", True),
)
for token, line, append in misplaced_cases:
    if token in code:
        print("marked")
        lines = emit_compiler_rt_report()
        if append:
            lines.append(line)
        else:
            lines.insert(0, line)
        report = "\\n".join(lines) + "\\n"
        print(report, end="", file=sys.stderr)
        sys.exit(23)
if "signaled" in code:
    print("marked", flush=True)
    print("LeakSanitizer: detected memory leaks", file=sys.stderr)
    os.kill(os.getpid(), signal.SIGTERM)
if "error" in code:
    print("execution error", file=sys.stderr)
    sys.exit(1)
print("unmarked-ran" if "unmarked" in code else "marked")
"""


class DocExampleMarkerTests(unittest.TestCase):
    def run_checker(self, markdown, *flags, asan=False):
        return self.run_checker_files({"README.md": markdown}, *flags,
                                       asan=asan)

    def run_checker_files(self, documents, *flags, asan=False):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory) / "workspace"
            tests = directory / "tests"
            tests.mkdir(parents=True)
            checker = tests / "test_doc_examples.py"
            checker.write_text(CHECKER.read_text())
            paths = []
            for relative_path, markdown in documents.items():
                doc = directory / relative_path
                doc.parent.mkdir(parents=True, exist_ok=True)
                doc.write_text(textwrap.dedent(markdown))
                paths.append(str(doc))
            eigenscript = directory / "eigenscript"
            eigenscript.write_text(
                FAKE_EIGENSCRIPT + ("\n# __asan_init\n" if asan else ""))
            eigenscript.chmod(eigenscript.stat().st_mode | stat.S_IXUSR)
            env = os.environ.copy()
            env["EIGENSCRIPT"] = str(eigenscript)
            return subprocess.run(
                [sys.executable, str(checker), *flags, *paths],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_only_check_marker_runs_a_readme_pair(self):
        result = self.run_checker(
            """
            ```eigenscript
            unmarked
            ```
            ```output
            ignored
            ```

            ```eigenscript check
            marked
            ```
            ```output
            marked
            ```
            """
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("README.md", result.stdout)
        self.assertIn("Doc examples: 1 checked, 1 passed, 0 failed, 0 skipped",
                      result.stdout)
        self.assertNotIn("README.md (README has 0 checked examples)",
                         result.stdout)

    def test_zero_marked_pairs_fail_the_gate(self):
        result = self.run_checker(
            """
            ```eigenscript
            unmarked
            ```
            ```output
            ignored
            ```
            """
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Doc examples: 0 checked, 0 passed, 0 failed, 0 skipped",
                      result.stdout)

    def test_list_mode_keeps_a_successful_exit(self):
        result = self.run_checker(
            """
            ```eigenscript check
            marked
            ```
            ```output
            marked
            ```
            """,
            "--list",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("would run: ", result.stdout)

    def test_unpaired_check_marker_fails_with_its_file_and_line(self):
        result = self.run_checker(
            """
            ```eigenscript check
            marked
            ```
            """
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"FAIL: .*README\.md:2 .*unpaired")
        self.assertIn("Doc examples: 0 checked, 0 passed, 0 failed, 0 skipped",
                      result.stdout)

    def test_fenced_block_between_check_and_output_is_an_orphan(self):
        result = self.run_checker(
            """
            ```eigenscript check
            marked
            ```

            ```
            unrelated prose fence
            ```

            ```output
            marked
            ```
            """
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"FAIL: .*README\.md:2 .*unpaired")
        self.assertIn("Doc examples: 0 checked, 0 passed, 0 failed, 0 skipped",
                      result.stdout)

    def test_execution_error_does_not_count_as_readme_coverage(self):
        result = self.run_checker(
            """
            ```eigenscript check
            error
            ```
            ```output
            marked
            ```
            """
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL: ", result.stdout)
        self.assertIn("rc=1", result.stdout)
        self.assertIn("README.md (README has 0 checked examples)",
                      result.stdout)

    def test_leak_marker_does_not_hide_real_failure(self):
        result = self.run_checker(
            """
            ```eigenscript check
            mixed-error
            ```
            ```output
            marked
            ```
            """
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL: ", result.stdout)
        self.assertIn("rc=7", result.stdout)
        self.assertIn("README.md (README has 0 checked examples)",
                      result.stdout)

    def test_non_asan_nonzero_exit_is_not_tolerated(self):
        result = self.run_checker(
            """
            ```eigenscript check
            asan-leak
            ```
            ```output
            marked
            ```
            """
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL: ", result.stdout)
        self.assertIn("rc=7", result.stdout)
        self.assertIn("README.md (README has 0 checked examples)",
                      result.stdout)

    def test_asan_nonzero_matching_output_is_tolerated_by_binary_probe(self):
        result = self.run_checker(
            """
            ```eigenscript check
            asan-leak
            ```
            ```output
            marked
            ```
            """,
            asan=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: README.md", result.stdout)
        self.assertIn("Doc examples: 1 checked, 1 passed, 0 failed, 0 skipped",
                      result.stdout)
        self.assertNotIn("README.md (README has 0 checked examples)",
                         result.stdout)

    def test_asan_nonzero_mismatched_output_still_fails(self):
        result = self.run_checker(
            """
            ```eigenscript check
            asan-mismatch
            ```
            ```output
            marked
            ```
            """,
            asan=True,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL: ", result.stdout)
        self.assertIn("rc=7", result.stdout)
        self.assertIn("README.md (README has 0 checked examples)",
                      result.stdout)
        self.assertIn(
            "Doc examples: 1 checked, 0 passed, 1 failed, 0 skipped",
            result.stdout)

    def test_asan_nonzero_exit_requires_only_lsan_signal(self):
        """Kills `rc_ok = p.returncode == 0 or asan_build` broadening."""
        cases = (
            "mixed-error",
            "asan-hard-and-leak",
            "no-lsan",
            "signaled",
            "multiple-lsan-markers",
            "malformed-lsan-report",
            "ubsan-and-leak",
        )
        for case in cases:
            with self.subTest(case=case):
                result = self.run_checker(
                    f"""
                    ```eigenscript check
                    {case}
                    ```
                    ```output
                    marked
                    ```
                    """,
                    asan=True,
                )
                self.assertEqual(result.returncode, 1,
                                 result.stdout + result.stderr)
                self.assertIn("FAIL: ", result.stdout)
                self.assertIn("README.md (README has 0 checked examples)",
                              result.stdout)
                self.assertIn(
                    "Doc examples: 1 checked, 0 passed, 1 failed, 0 skipped",
                    result.stdout)

    def test_full_lsan_report_does_not_hide_failure(self):
        result = self.run_checker(
            """
            ```eigenscript check
            full-leak-report
            ```
            ```output
            marked
            ```
            """
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL: ", result.stdout)
        self.assertIn("rc=23", result.stdout)
        self.assertIn("README.md (README has 0 checked examples)",
                      result.stdout)
        self.assertIn("Doc examples: 1 checked, 0 passed, 1 failed, 0 skipped",
                      result.stdout)

    def test_asan_full_lsan_report_is_tolerated(self):
        """The fixture includes a correctly ordered suppression section."""
        result = self.run_checker(
            """
            ```eigenscript check
            full-leak-report
            ```
            ```output
            marked
            ```
            """,
            asan=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: README.md", result.stdout)
        self.assertNotIn("README.md (README has 0 checked examples)",
                          result.stdout)
        self.assertIn("Doc examples: 1 checked, 1 passed, 0 failed, 0 skipped",
                      result.stdout)

    def test_asan_full_lsan_report_rejects_out_of_context_lines(self):
        cases = (
            "misplaced-suppression-row",
            "misplaced-suppression-header",
            "misplaced-suppression-columns",
            "misplaced-object-line",
            "misplaced-frame",
            "misplaced-separator",
            "misplaced-marker",
            "misplaced-summary",
            "misplaced-direct-block",
            "misplaced-indirect-block",
            "semantic-before-report",
            "semantic-after-report",
        )
        for case in cases:
            with self.subTest(case=case):
                result = self.run_checker(
                    f"""
                    ```eigenscript check
                    {case}
                    ```
                    ```output
                    marked
                    ```
                    """,
                    asan=True,
                )
                self.assertEqual(result.returncode, 1,
                                 result.stdout + result.stderr)
                self.assertIn("FAIL: ", result.stdout)
                self.assertIn("rc=23", result.stdout)
                self.assertIn(
                    "Doc examples: 1 checked, 0 passed, 1 failed, 0 skipped",
                    result.stdout)

    def test_mixed_failure_does_not_count_as_readme_coverage(self):
        result = self.run_checker(
            """
            ```eigenscript check
            mixed-error
            ```
            ```output
            marked
            ```
            """
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("README.md (README has 0 checked examples)",
                      result.stdout)
        self.assertIn("Doc examples: 1 checked, 0 passed, 1 failed, 0 skipped",
                      result.stdout)

    def test_nonzero_exit_variants_do_not_pass_or_count_as_readme_coverage(self):
        cases = (
            "error-after-marker",
            "asan-hard-and-leak",
            "stdout-leak",
        )
        for case in cases:
            with self.subTest(case=case):
                result = self.run_checker(
                    f"""
                    ```eigenscript check
                    {case}
                    ```
                    ```output
                    marked
                    ```
                    """
                )
                self.assertEqual(result.returncode, 1,
                                 result.stdout + result.stderr)
                self.assertIn("FAIL: ", result.stdout)
                self.assertIn("README.md (README has 0 checked examples)",
                              result.stdout)
                self.assertIn(
                    "Doc examples: 1 checked, 0 passed, 1 failed, 0 skipped",
                    result.stdout)

    def test_signaled_exit_with_lsan_is_not_tolerated(self):
        result = self.run_checker(
            """
            ```eigenscript check
            signaled
            ```
            ```output
            marked
            ```
            """
        )
        self.assertNotEqual(result.returncode, 0,
                             result.stdout + result.stderr)
        self.assertIn("FAIL: ", result.stdout)
        self.assertIn("rc=-15", result.stdout)
        self.assertIn("README.md (README has 0 checked examples)",
                      result.stdout)

    def test_zero_readme_markers_fail_with_passing_legacy_docs(self):
        result = self.run_checker_files(
            {
                "docs/SPEC.md":
                    """
                    ```eigenscript
                    legacy-spec
                    ```
                    ```output
                    marked
                    ```
                    """,
                "docs/COMPARISON.md":
                    """
                    ```eigenscript
                    legacy-comparison
                    ```
                    ```output
                    marked
                    ```
                    """,
                "README.md":
                    """
                    ```eigenscript
                    unmarked
                    ```
                    ```output
                    ignored
                    ```
                    """,
            }
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("README.md", result.stdout)
        self.assertIn("0 checked", result.stdout)


if __name__ == "__main__":
    unittest.main()
