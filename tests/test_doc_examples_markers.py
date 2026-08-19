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


def emit_compiler_rt_report(with_objects=True):
    # with_objects=False reproduces DEFAULT compiler-rt output: the
    # "Objects leaked above:" section appears only under
    # LSAN_OPTIONS=report_objects=1, which CI does not set (#980).
    lines = [
        "",
        "=================================================================",
        "==123==ERROR: LeakSanitizer: detected memory leaks",
        "",
        "Direct leak of 32 byte(s) in 1 object(s) allocated from:",
        "    #0 0x7f0000000000 in malloc fake.c:10:1",
        "    #1 0x7f0000000010 in main fake.c:20:1",
    ]
    if with_objects:
        lines.extend([
            "Objects leaked above:",
            "0x602000000010 (32 bytes)",
        ])
    lines.extend([
        "",
    ])
    lines.extend([
        "Indirect leak of 16 byte(s) in 1 object(s) allocated from:",
        "    #0 0x7f0000000000 in malloc fake.c:30:1",
        "    #1 0x7f0000000020 in helper fake.c:40:1",
    ])
    if with_objects:
        lines.extend([
            "Objects leaked above:",
            "0x602000000030 (16 bytes)",
        ])
    lines.extend([
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


if "default-leak-report" in code:
    print("marked")
    lines = emit_compiler_rt_report(with_objects=False)
    report = "\\n".join(lines) + "\\n"
    print(report, end="", file=sys.stderr)
    sys.exit(23)
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



class LsanReportWalkTests(unittest.TestCase):
    """Pin the STRUCTURE is_lsan_only_failure() walks, guard by guard.

    Why this exists (blind review, 2026-08-19): the `misplaced_cases` battery
    below inserts every one of its entries at position 0, so all of them are
    rejected by the FIRST check in the function (line 0 must be a separator)
    and none ever enters the leak-block walk. Eleven tests of one branch.
    Measured consequence: 13 of 16 mutations to the walk — including deleting
    the `objects == 0` guard that #980's own comment promises is preserved —
    left the whole suite green.

    So each case here inserts at a position the walk actually reaches, and each
    NAMES the guard it pins. A mutation that removes that guard must turn
    exactly the corresponding case red.

    Two traps this class had to be rewritten around, both worth knowing before
    adding a case: a malformed report is usually rejected by a NEIGHBOURING
    guard, so the test passes with the intended guard removed. Deleting a line
    shortens the report and the final `index == len(lines) - 1` check rejects it
    for you; inserting a second SUMMARY trips `len(summaries) != 1` instead of
    the summary regex. The cases below therefore REPLACE lines rather than
    delete or insert them, wherever the guard would otherwise be covered for.

    Mutation score, measured (2026-08-19): 10 of 11 mutations of the walk are
    caught. The one that survives — dropping `summaries[0] != len(lines) - 1` —
    was checked over 271,440 generated line-sequences and produced NO behavioural
    difference: a SUMMARY line matches no element the walk consumes, so if it is
    not last, `index` cannot reach `len(lines) - 1` and the final check rejects
    anyway. That guard is REDUNDANT, not untested; a case for it would pass for
    the wrong reason, so none is written.
    """

    @staticmethod
    def _load():
        import importlib.util
        import sys as _sys
        _sys.dont_write_bytecode = True   # never litter tests/__pycache__
        spec = importlib.util.spec_from_file_location("_doc_examples", CHECKER)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.is_lsan_only_failure

    SEP = "================================================================="
    DASH = "-----------------------------------------------------"

    @classmethod
    def _report(cls, blocks=1, objects=True, suppressions=False):
        """A well-formed report. objects=False is the DEFAULT compiler-rt shape."""
        lines = [cls.SEP, "==123==ERROR: LeakSanitizer: detected memory leaks"]
        for i in range(blocks):
            kind = "Direct" if i == 0 else "Indirect"
            lines.append(
                "%s leak of 32 byte(s) in 1 object(s) allocated from:" % kind)
            lines.append("    #0 0x7f0000000000 in malloc fake.c:%d:1" % (i + 10))
            if objects:
                lines += ["Objects leaked above:", "0x60200000001%d (32 bytes)" % i]
        if suppressions:
            lines += [cls.DASH, "Suppressions used:",
                      "  count      bytes template",
                      "      1         32 my_suppression", cls.DASH]
        lines.append(
            "SUMMARY: AddressSanitizer: 32 byte(s) leaked in 1 allocation(s).")
        return "\n".join(lines) + "\n"

    def setUp(self):
        self.is_lsan_only = self._load()

    def test_wellformed_shapes_certify(self):
        """Positive control. Without this the negatives below are satisfied by
        a function that returns False unconditionally."""
        for kw in ({"objects": False}, {"objects": True},
                   {"objects": False, "blocks": 2},
                   {"objects": True, "blocks": 2},
                   {"objects": False, "suppressions": True},
                   {"objects": True, "suppressions": True}):
            with self.subTest(**kw):
                self.assertTrue(self.is_lsan_only(self._report(**kw)),
                                "well-formed report rejected: %r" % (kw,))

    def _assert_rejected(self, lines, guard):
        text = "\n".join(lines) + "\n"
        self.assertFalse(self.is_lsan_only(text),
                         "accepted malformed report; guard not enforced: " + guard)

    def test_object_header_with_no_addresses_is_rejected(self):
        """Pins `objects == 0`. #980 made the section optional; the comment
        claims it stays well-formed WHEN PRESENT. This is that claim."""
        lines = self._report(objects=True).rstrip("\n").split("\n")
        lines.remove("0x602000000010 (32 bytes)")
        self._assert_rejected(lines, "objects == 0")

    def test_leak_block_with_no_frames_is_rejected(self):
        """Pins `frames == 0`."""
        lines = self._report(objects=False).rstrip("\n").split("\n")
        lines = [l for l in lines if not l.startswith("    #0 ")]
        self._assert_rejected(lines, "frames == 0")

    def test_trailing_content_after_summary_is_rejected(self):
        """Pins the final `index == len(lines) - 1`."""
        lines = self._report(objects=False).rstrip("\n").split("\n")
        lines.append("fatal execution failure")
        self._assert_rejected(lines, "index == len(lines) - 1")

    def test_summary_not_last_is_rejected(self):
        """Pins `summaries[0] != len(lines) - 1`."""
        lines = self._report(objects=False).rstrip("\n").split("\n")
        summary = lines.pop()
        lines.insert(2, summary)
        self._assert_rejected(lines, "summary must be the last line")

    def test_two_markers_rejected(self):
        """Pins `len(markers) != 1`."""
        lines = self._report(objects=False).rstrip("\n").split("\n")
        lines.insert(2, "==123==ERROR: LeakSanitizer: detected memory leaks")
        self._assert_rejected(lines, "len(markers) != 1")

    def test_missing_leading_separator_is_rejected(self):
        lines = self._report(objects=False).rstrip("\n").split("\n")[1:]
        self._assert_rejected(lines, "report must open with a separator")

    def test_suppression_block_without_closing_separator_is_rejected(self):
        lines = self._report(objects=False, suppressions=True).rstrip("\n").split("\n")
        lines.remove(self.DASH)   # removes the FIRST (opening) one
        self._assert_rejected(lines, "suppression block structure")

    def test_leading_junk_instead_of_separator_is_rejected(self):
        """Pins the mandatory opening separator, in isolation.

        REPLACES line 0 rather than deleting it: deleting shifts the marker to
        line 0, where the very next check rejects it, so a deleting test passes
        even with this guard removed.
        """
        lines = self._report(objects=False).rstrip("\n").split("\n")
        lines[0] = "some unrelated program output"
        self._assert_rejected(lines, "opening separator")

    def test_bogus_leak_kind_line_is_rejected(self):
        """Pins LSAN_LEAK_KIND_LINE's shape, not just its suffix.

        Loosened to `^.*allocated from:$` the walk accepts any line ending in
        that suffix, so a leak block can be introduced by arbitrary text.
        """
        lines = self._report(objects=False).rstrip("\n").split("\n")
        lines[2] = "Some unrelated sentence allocated from:"
        self._assert_rejected(lines, "LSAN_LEAK_KIND_LINE shape")

    def test_suppression_header_must_be_the_header(self):
        """Pins `lines[index] != LSAN_SUPPRESSION_HEADER`, in isolation.

        The line after the opening separator is REPLACED, keeping the block's
        length intact, so the trailing `index == len(lines) - 1` check still
        lands and cannot reject on its behalf.
        """
        lines = self._report(objects=False, suppressions=True).rstrip("\n").split("\n")
        lines[lines.index("Suppressions used:")] = "Not the suppression header"
        self._assert_rejected(lines, "LSAN_SUPPRESSION_HEADER")

    def test_hard_summary_as_the_only_summary_is_rejected(self):
        """Pins LSAN_SUMMARY_LINE's shape.

        REPLACES the summary rather than inserting one — inserting leaves two
        SUMMARY lines and is rejected by `len(summaries) != 1`, i.e. by a
        neighbouring guard, so an inserting test passes even when this regex is
        loosened to `^SUMMARY: .*$`. A leak report whose only summary announces
        a double-free must not be certified.
        """
        lines = self._report(objects=False).rstrip("\n").split("\n")
        lines[-1] = "SUMMARY: AddressSanitizer: double-free fake.c:1:1 in free"
        self._assert_rejected(lines, "LSAN_SUMMARY_LINE shape")

    def test_suppression_block_without_CLOSING_separator_is_rejected(self):
        """Pins the suppression block's trailing separator specifically.

        Removing the OPENING separator is caught by a different branch, so that
        variant does not test this guard.
        """
        lines = self._report(objects=False, suppressions=True).rstrip("\n").split("\n")
        # REPLACE the closing separator, do not delete it. Deleting shortens the
        # report so the final `index == len(lines) - 1` check rejects it anyway,
        # and the test then passes with this guard removed.
        last = len(lines) - 1 - lines[::-1].index(self.DASH)
        lines[last] = "not a separator at all"
        self._assert_rejected(lines, "suppression closing separator")

    def test_hard_error_at_every_walk_position_is_rejected(self):
        """The severe direction: a hard diagnostic anywhere inside an otherwise
        well-formed report must not be certified. Inserted at EVERY position,
        not just position 0 — which is the flaw this class was written for."""
        for shape in ({"objects": False}, {"objects": True},
                      {"objects": False, "suppressions": True}):
            base = self._report(**shape).rstrip("\n").split("\n")
            for hard in ("==123==ERROR: AddressSanitizer: heap-use-after-free",
                         "fake.c:1:1: runtime error: signed integer overflow",
                         "SUMMARY: AddressSanitizer: double-free fake.c:1 in f"):
                for pos in range(len(base) + 1):
                    with self.subTest(shape=shape, hard=hard[:28], pos=pos):
                        lines = base[:pos] + [hard] + base[pos:]
                        self.assertFalse(
                            self.is_lsan_only("\n".join(lines) + "\n"),
                            "hard diagnostic tolerated at position %d" % pos)


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

    def test_asan_default_lsan_report_is_tolerated(self):
        """#980: the DEFAULT compiler-rt shape — no "Objects leaked above:".

        That section is emitted only under LSAN_OPTIONS=report_objects=1, which
        CI does not set, so requiring it meant a genuine leak-only failure was
        classified as a hard sanitizer error. This is the shape that actually
        occurs; test_asan_full_lsan_report_is_tolerated covers the opt-in one.
        """
        result = self.run_checker(
            """
            ```eigenscript check
            default-leak-report
            ```
            ```output
            marked
            ```
            """,
            asan=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: README.md", result.stdout)

    def test_default_lsan_report_does_not_hide_failure(self):
        """The same shape must still FAIL on a non-sanitizer build."""
        result = self.run_checker(
            """
            ```eigenscript check
            default-leak-report
            ```
            ```output
            marked
            ```
            """
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL: ", result.stdout)
        self.assertIn("rc=23", result.stdout)

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
