#!/usr/bin/env python3
"""One-time calibration for #1939's method-specific temporary cost bounds."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import phase2_cost_declarations as costs

class CostMethods(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='phase2-cost-methods-')
        self.root = Path(self.temporary.name)
        for name in ('tools', 'tests/phase2', 'bench'):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        for name in ('tools/phase2_cost.sh', 'tools/phase2_cost_declarations.py',
                     'bench/check_regression.sh'):
            source = ROOT / name
            if source.is_file():
                shutil.copy2(source, self.root / name)
        (self.root / 'codspeed.yml').write_text('exec: ./src/eigenscript bench/scalar_loop.eigs\n')
        (self.root / 'bench/scalar_loop.eigs').write_text('')
        subprocess.run(['git', 'init', '-q', self.root], check=True)
        subprocess.run(['git', 'add', 'bench/scalar_loop.eigs'], cwd=self.root, check=True)

    def tearDown(self):
        self.temporary.cleanup()

    def declaration(self, local='27.0', ci='27.3'):
        (self.root / 'tests/phase2/cost_expect.txt').write_text(
            'bench/scalar_loop.eigs\tjit\t%s\t%s\tR5\tmeasured by each gate\n' % (local, ci))

    def run_gate(self, *args):
        return subprocess.run(['bash', self.root / 'tools/phase2_cost.sh', *args],
                              cwd=self.root, capture_output=True, text=True)

    def test_independent_column_export(self):
        self.declaration()
        for method, maximum in (('local', '27.0'), ('ci', '27.3')):
            with self.subTest(method=method):
                result = self.run_gate('--declared', 'jit', '--method', method)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'bench/scalar_loop.eigs\t%s\tR5\n' % maximum)

    def test_all_export_retains_declared_tiers(self):
        self.declaration()
        table = self.root / 'tests/phase2/cost_expect.txt'
        table.write_text(table.read_text() +
                         'bench/scalar_loop.eigs\toff\t9.0\t8.0\tR5\tmeasured off\n')
        result = self.run_gate('--declared', 'all', '--method', 'ci')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'bench/scalar_loop.eigs\tjit\t27.3\tR5\n'
                         'bench/scalar_loop.eigs\toff\t8.0\tR5\n')

    def test_ci_population_is_union_of_existing_and_all_declared_pairs(self):
        workload = 'tests/bench_probe.eigs'
        (self.root / workload).write_text('')
        with (self.root / 'codspeed.yml').open('a') as stream:
            stream.write('exec: ./src/eigenscript ' + workload + '\n')
        subprocess.run(['git', 'add', workload], cwd=self.root, check=True)
        (self.root / 'tests/phase2/cost_expect.txt').write_text(
            'bench/scalar_loop.eigs\toff\t9.0\t8.0\tR5\tmeasured off\n'
            'tests/bench_probe.eigs\tjit\t1.0\t2.0\tR5\tmeasured jit\n'
            'tests/bench_probe.eigs\toff\t3.0\t4.0\tR5\tmeasured off\n')
        result = subprocess.run(['bash', self.root / 'bench/check_regression.sh', '--list-vs'],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.splitlines(), ['bench/scalar_loop.eigs\tjit',
                         'bench/scalar_loop.eigs\toff', 'tests/bench_probe.eigs\tjit',
                         'tests/bench_probe.eigs\toff'])

    def run_row(self, method, base, cand):
        return subprocess.run(['python3', self.root / 'tools/phase2_cost_declarations.py',
                               '--method', method, '--row', 'bench/scalar_loop.eigs',
                               'jit', str(base), str(cand)], cwd=self.root,
                              capture_output=True, text=True)

    def test_local_and_ci_bounds_are_independent(self):
        # The issue's two method readings cannot share one tight maximum.
        for method, local, ci, cand in (('local', '27.0', '0.2', 12672000),
                                         ('ci', '0.2', '27.3', 12704780)):
            with self.subTest(method=method):
                self.declaration(local, ci)
                result = self.run_row(method, 10000000, cand)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('DECLARED:', result.stdout)
                self.assertIn('max_' + method + '=', result.stdout)
                other = 'ci' if method == 'local' else 'local'
                result = self.run_row(other, 10000000, cand)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('REGRESSION:', result.stdout)

    def test_stale_checks_only_own_column(self):
        for method, local, ci in (('local', '10.3', '90'), ('ci', '90', '10.3')):
            with self.subTest(method=method):
                self.declaration(local, ci)
                result = self.run_row(method, 10000, 11000)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                other = 'ci' if method == 'local' else 'local'
                result = self.run_row(other, 10000, 11000)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('STALE DECLARATION:', result.stdout)

    def test_exact_boundaries_and_no_stale_for_undeclared_rows(self):
        self.declaration('10.3', '10.3')
        for method in costs.METHODS:
            for cand, verdict in ((11030, 'DECLARED:'), (11031, 'REGRESSION:'),
                                  (10980, 'DECLARED:'), (10979, 'STALE DECLARATION:')):
                with self.subTest(method=method, cand=cand):
                    result = self.run_row(method, 10000, cand)
                    self.assertEqual(result.returncode, int(verdict != 'DECLARED:'), result.stdout)
                    self.assertIn(verdict, result.stdout)
        (self.root / 'tests/phase2/cost_expect.txt').write_text('')
        for method in costs.METHODS:
            result = self.run_row(method, 10000, 1)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('ok:', result.stdout)
        self.assertEqual(self.run_row('local', 10000, 10400).returncode, 1)
        self.assertEqual(self.run_row('ci', 10000, 10400).returncode, 0)

    def test_shared_predicate_reproduces_issue(self):
        # Exercise the production function with independent columns, both ways.
        table = costs.parse_declarations('bench/scalar_loop.eigs\tjit\t27.0\t27.3\tR5\tmeasured\n')
        self.assertEqual(costs.assess_row(table, 'bench/scalar_loop.eigs', 'jit', 'local',
                                         10000000, 12672000)[2], 'ok')
        self.assertEqual(costs.assess_row(table, 'bench/scalar_loop.eigs', 'jit', 'ci',
                                         10000000, 12704780)[2], 'ok')
        self.assertEqual(costs.assess_row(table, 'bench/scalar_loop.eigs', 'jit', 'local',
                                         10000000, 12704780)[2], 'OVER')
        self.assertEqual(costs.assess_row(table, 'bench/scalar_loop.eigs', 'jit', 'ci',
                                         10000000, 12672000)[2], 'STALE')

    def test_schema_rejects_invalid_columns_and_legacy_shape(self):
        good = 'bench/scalar_loop.eigs\tjit\t27.0\t27.3\tR5\tmeasured\n'
        bad = [good.replace('\t27.3', ''), good + good]
        for column in ('27.0', '27.3'):
            bad.extend(good.replace(column, value) for value in ('-1', 'NaN', 'Infinity', ''))
        for text in bad:
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    costs.parse_declarations(text)
        with self.assertRaises(ValueError):
            costs.parse_declarations(good, {'bench/missing.eigs'})

    def test_method_selection_cannot_change_local_measurement(self):
        self.declaration()
        result = self.run_gate('--method', 'ci', '/bin/true', '/bin/true')
        self.assertEqual(result.returncode, 2)
        self.assertIn('cost runs enforce max_local', result.stderr)

if __name__ == '__main__':
    if '--self-test' in sys.argv:
        sys.argv.remove('--self-test')
    unittest.main(verbosity=2)
