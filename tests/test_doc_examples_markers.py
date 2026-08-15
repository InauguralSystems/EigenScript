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
import sys

code = Path(sys.argv[1]).read_text()
print("unmarked-ran" if "unmarked" in code else "marked")
"""


class DocExampleMarkerTests(unittest.TestCase):
    def run_checker(self, markdown, *flags):
        return self.run_checker_files({"README.md": markdown}, *flags)

    def run_checker_files(self, documents, *flags):
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
            eigenscript.write_text(FAKE_EIGENSCRIPT)
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
