#!/usr/bin/env python3
"""Sibling expressions release chain depth; genuinely deep ASTs remain bounded."""

import re
import subprocess
import tempfile
import unittest
from pathlib import Path


BIN = Path(__file__).resolve().parents[1] / "src" / "eigenscript"
PARSE_ERROR = re.compile(r"Parse error line|parse error\(s\) \[E002\]")


class ParserExpressionDepthTest(unittest.TestCase):
    def run_source(self, source, *, lint=False):
        with tempfile.TemporaryDirectory(prefix="eigs-expression-depth-") as directory:
            path = Path(directory) / "input.eigs"
            path.write_text(source, encoding="utf-8")
            command = [str(BIN)]
            if lint:
                command.append("--lint")
            command.append(str(path))
            result = subprocess.run(command, capture_output=True, text=True, timeout=20)
            # The runtime can report recoverable UB even at exit 0. Use the
            # suite's canonical classifier before checking parser diagnostics.
            classifier = Path(__file__).with_name("lsan_classify.sh")
            verdict = subprocess.run(
                ["bash", "-c", '. "$1"; lsan_classify_name "$(cat)"',
                 "parser-depth", str(classifier)],
                input=result.stdout + result.stderr,
                capture_output=True, text=True, timeout=5, check=True,
            )
            self.assertEqual(verdict.stdout.strip(), "none", result.stderr)
            return result

    def check_flat_list(self, element, expected):
        source = (
            "E is [1]\n"
            "values is [" + ", ".join([element] * 1000) + "]\n"
            "if (len of values) != 1000:\n"
            '    throw of "wrong list length"\n'
            "for value in values:\n"
            f"    if value != {expected}:\n"
            '        throw of "wrong element value"\n'
            'print of "1000 values checked"\n'
        )
        result = self.run_source(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1000 values checked\n")

    def test_flat_subscripts(self):
        self.check_flat_list("E[0]", 1)

    def test_flat_subscript_sums(self):
        self.check_flat_list("E[0] + 1", 2)

    def test_flat_parenthesized_elements(self):
        self.check_flat_list("(E)", "[1]")

    def test_flat_dict_values(self):
        entries = ", ".join(f'"key{i}": E[0] + 1' for i in range(1000))
        result = self.run_source(
            "E is [1]\nvalues is {" + entries + "}\n"
            "if (len of values) != 1000:\n"
            '    throw of "wrong dict length"\n'
            "for i in (range of 1000):\n"
            '    if values[f"key{i}"] != 2:\n'
            '        throw of "wrong dict value"\n'
            'print of "1000 dict values checked"\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1000 dict values checked\n")

    def test_nested_sibling_lists_and_dicts(self):
        expressions = (
            "[" + ", ".join(["[E[0], E[0] + 1]"] * 1000) + "]",
            "[" + ", ".join(['{"a": E[0], "b": E[0] + 1}'] * 1000) + "]",
        )
        for expression, accessor in zip(expressions, ("[1]", '["b"]')):
            with self.subTest(accessor=accessor):
                result = self.run_source(
                    "E is [1]\nvalues is " + expression + "\n"
                    "if (len of values) != 1000:\n"
                    '    throw of "wrong outer length"\n'
                    "for value in values:\n"
                    f"    if value{accessor} != 2:\n"
                    '        throw of "wrong nested value"\n'
                    'print of "1000 nested values checked"\n'
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "1000 nested values checked\n")

    def test_comprehension_children_are_siblings(self):
        total = "1" + "+1" * 100
        result = self.run_source(
            f"values is [{total} for item in (range of ({total})) if ({total}) == 101]\n"
            "if (len of values) != 101:\n"
            '    throw of "wrong comprehension length"\n'
            "for value in values:\n"
            "    if value != 101:\n"
            '        throw of "wrong comprehension value"\n'
            'print of "101 comprehension values checked"\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "101 comprehension values checked\n")

    def test_deep_children_retain_their_chain_budget(self):
        deep_index = "E" + "[0]" * 120
        deep_sum = "1" + "+1" * 120
        expressions = (
            "(" + deep_index + ")" + "[0]" * 140,
            "(" + deep_sum + ")" + "+1" * 140,
            "[" + deep_index + ", E[0]]" + "[0]" * 140,
            '{"deep": ' + deep_index + ', "shallow": E[0]}' + "[0]" * 140,
            "[[" + deep_index + ", E[0]], [E[0]]]" + "[0]" * 140,
            "([" + deep_index + " for item in [1] if true])" + "[0]" * 140,
        )
        for expression in expressions:
            with self.subTest(expression=expression[:30]):
                result = self.run_source("E is [1]\nx is " + expression + "\n", lint=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertRegex(result.stderr, PARSE_ERROR)
                self.assertIn("nest", result.stderr)

    def test_parser_depth_boundaries_unchanged(self):
        # These are parser boundaries, not compiler acceptance promises: the
        # separate compiler depth guard may refuse an AST below the parser cap.
        families = (
            ("parentheses", 128, lambda n: "(" * n + "1" + ")" * n),
            ("postfix", 253, lambda n: "E" + "[0]" * n),
            ("addition", 255, lambda n: "1" + "+1" * n),
        )
        for name, limit, expression in families:
            with self.subTest(family=name, depth=limit - 1):
                result = self.run_source(
                    "E is [1]\nx is " + expression(limit - 1) + "\n", lint=True
                )
                self.assertIn(result.returncode, (0, 1), result.stderr)
                self.assertNotRegex(result.stderr, PARSE_ERROR)
            with self.subTest(family=name, depth=limit):
                result = self.run_source(
                    "E is [1]\nx is " + expression(limit) + "\n", lint=True
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertRegex(result.stderr, PARSE_ERROR)
                self.assertIn("nesting too deep", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
