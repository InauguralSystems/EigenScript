#!/usr/bin/env python3
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("api_doc_ir", ROOT / "tools/api_doc_ir.py")
api_doc_ir = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = api_doc_ir
SPEC.loader.exec_module(api_doc_ir)


GOOD = """# @api
# signature: identity of value -> any
# summary: Return the supplied value.
# arg value: The value to return.
# returns: The supplied value.
# example:
# | print of identity of 3
# | # => 3
# @end
define identity(value) as:
    return value
"""


class ApiDocIrTests(unittest.TestCase):
    def extract(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.eigs"
            path.write_text(text)
            return api_doc_ir.build_ir([path])

    def test_complete_record_is_deterministic(self):
        record = self.extract(GOOD)[0]
        self.assertEqual((record.kind, record.name), ("library", "identity"))
        self.assertEqual(record.example, "print of identity of 3\n# => 3")

    def test_example_indentation_is_preserved(self):
        text = GOOD.replace(
            "# | print of identity of 3\n# | # => 3",
            "# | define nested(value) as:\n# |     if value:\n# |         return value\n# |     return 0",
        )
        self.assertEqual(
            self.extract(text)[0].example,
            "define nested(value) as:\n    if value:\n        return value\n    return 0",
        )

    def test_markdown_has_separate_reference_tables(self):
        record = self.extract(GOOD)[0]
        rendered = api_doc_ir.render_markdown([record])
        self.assertIn("## Library functions", rendered)
        self.assertIn("| identity | identity of value -> any |", rendered)
        self.assertIn("## Builtins", rendered)
        self.assertIn("```eigenscript\n", rendered)
        self.assertIn("```output\n```", rendered)

    def test_undocumented_public_declaration_fails_by_name(self):
        text = GOOD + "\ndefine newly_public(value) as:\n    return value\n"
        with self.assertRaisesRegex(
                api_doc_ir.DocError,
                r"newly_public: public declaration has no @api documentation"):
            self.extract(text)

    def test_pinned_legacy_declaration_can_be_deferred(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.eigs"
            path.write_text(GOOD + "\ndefine legacy(value) as:\n    return value\n")
            records = api_doc_ir.build_ir([path], {("library", "legacy")})
        self.assertEqual([record.name for record in records], ["identity"])

    def test_missing_field_names_function(self):
        with self.assertRaisesRegex(api_doc_ir.DocError, r"identity: missing field\(s\): returns"):
            self.extract(GOOD.replace("# returns: The supplied value.\n", ""))

    def test_builtin_record_uses_registration_name(self):
        text = """/* @api
 * signature: clock of null -> number
 * summary: Read the current clock.
 * returns: A clock reading.
 * example:
 * | print of clock of null
 */
env_set_local_owned(env, "clock", make_builtin(builtin_clock));
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "builtins.c"
            path.write_text(text)
            record = api_doc_ir.build_ir([path])[0]
        self.assertEqual((record.kind, record.name), ("builtin", "clock"))

    def test_unknown_field_names_source_and_function(self):
        with self.assertRaisesRegex(api_doc_ir.DocError, r"sample\.eigs:\d+: identity: unknown field 'since'"):
            self.extract(GOOD.replace("# summary:", "# since: 1\n# summary:"))

    def test_detached_block_fails(self):
        with self.assertRaisesRegex(api_doc_ir.DocError, r"<detached>.*immediately precede"):
            self.extract(GOOD.replace("# @end\n", "# @end\n\n"))

    def test_zero_entries_fails(self):
        with self.assertRaisesRegex(api_doc_ir.DocError, "extracted zero"):
            self.extract("define identity(value) as:\n    return value\n")

    def test_example_rejects_successful_process_with_stderr(self):
        record = self.extract(GOOD)[0]
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "eigs"
            executable.write_text("#!/bin/sh\necho 'runtime error: ubsan' >&2\nexit 0\n")
            executable.chmod(0o755)
            with self.assertRaisesRegex(api_doc_ir.DocError, "non-empty stderr"):
                api_doc_ir.run_examples([record], executable)


if __name__ == "__main__":
    unittest.main()
