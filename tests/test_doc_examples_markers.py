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
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory) / "workspace"
            tests = directory / "tests"
            tests.mkdir(parents=True)
            checker = tests / "test_doc_examples.py"
            checker.write_text(CHECKER.read_text())
            doc = directory / "README.md"
            doc.write_text(textwrap.dedent(markdown))
            eigenscript = directory / "eigenscript"
            eigenscript.write_text(FAKE_EIGENSCRIPT)
            eigenscript.chmod(eigenscript.stat().st_mode | stat.S_IXUSR)
            env = os.environ.copy()
            env["EIGENSCRIPT"] = str(eigenscript)
            return subprocess.run(
                [sys.executable, str(checker), *flags, str(doc)],
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


if __name__ == "__main__":
    unittest.main()
