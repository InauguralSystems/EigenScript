#!/usr/bin/env python3
"""Round 3 reveal driver (#2330, #1758; RULING R30R-2).

First matching row, independently for each predicate, using the frozen judge:
 R3 verdict PASS     -> R3:     "All six criteria pass: R3's band ships."
 R3-STD verdict PASS -> R3-STD: "Otherwise R3-STD ships for that predicate."
 otherwise           -> INC:    "INC's band stays for p, R3's change to p is
                                reverted, and the table is posted."
Additive duties from R3: rule 4 FAIL -> silent-wrong issue + measured BA in
PREDICATES.md; rules 2..5 PASS and rule 1 FAIL -> STD_p replacement on fresh H2.
Rule 2 against R3-STD stays exactly where the frozen judge puts it.
No outcome on REFUSED, INCOMPLETE, FINDING or VOID. VOID repeats step 1.

Raw format r3-reveal/1: raw.json is a JSON object, sorted keys, UTF-8, newline.
 metadata: dry, seed (run order AND bootstrap), resamples, runtime arm stamps,
           manifests (sha256 + full instrument manifest), driver file hashes.
 preflight: per subject floor exit, relevant declaration lines and capabilities.
 populations: calibration and H1 (or hcal in dry calibration mode). Each holds
  rows: id -> full corpus row; labels: row@checkpoint -> derive label objects;
  order: ordered [runtime arm, row] pairs; capabilities; skipped; findings;
  readings: [arm,row,checkpoint,predicate,boolean] for interp/straight and Python
            arms; absence is explicit in skipped, partial Python arm domains
            are ROSTER below. tiers: [arm,tier,form,row,checkpoint,predicate,bool].
  decisions: subject -> predicate -> {verdict,rules}; rules is an ordered list
             [rule-name,PASS|FAIL|NOT EVALUATED,judge's explanation].
  points: [arm,predicate,BA rational or null]; diffs: [A,B,p,d,lo,hi,left_out]
          d is exact rational; CI endpoints are floats as printed by judge.
  judge_rc; judge_text is an informational transcript, NOT extraction input.
 controls: a,c1,c2 booleans; b is true, false or "undefined". When b is
  undefined, b_undefined lists the predicates without BA. False takes priority
  over undefined if a defined predicate fails. status is rechecked on extraction.

Canonical decision.json is derived ONLY from raw.json: status, dry, seed,
resamples, exact family confusion tables / disagreements / absences and (if COMPLETE) for each predicate both subjects' ordered rule names
and statuses, verdicts, ship and additive duties. No paths, binary hashes,
hostname, Python version, timestamps or rounded explanatory text enter it.
Recompute via --extract RAW --out DIR. To replicate statistics independently,
use labels + readings to form TP FP FN TN; use rows as bootstrap clusters,
random.Random(seed), 10000 shared draws as judge.py specifies (D9 shared-row
subsets have their own stream). Whole-population JSON files are also extracted
only from raw, with explicit null readings and every disagreement.

CLI: --r3 SHA --r3-std SHA --round N --out DIR [--dry] [--calibration]
     --calibration is allowed only with --dry (calibration + H-cal, no beacon).
Runtime paths are never CLI inputs. Recipes build serially into build/ beneath
this checkout. --resamples defaults to registered 10000; lower is DRY only.
Manual review verdicts must be recorded by the orchestrator before H1 scoring.
Before unsealing, reveal_commitment.json must match the accepted hashes of this
driver, reveal_selftest.py and reveal_fixtures.json (the named fixture inventory).
"""
import argparse
import contextlib
import hashlib
import io
import importlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.error
from fractions import Fraction

sys.path.insert(0, str(Path(__file__).resolve().parent))
import judge as J
import seal
import manual_review

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
INC = '3d8a14b4'
ANCHOR = '4a3a5c1941568e9bc562c7c8221cff22dc8ba697'
R3STD = '3eed5caf'
SCORE_SHA256 = 'e74b1c84d5e2e7f019e946d4cd4807fd418c67d7541ee5c1bde1063d1bc267e4'
# One roster, domains are intentional: STD'' and D2 are not all-predicate arms.
ROSTER = {
    'R3': tuple(J.PREDS), 'R3-STD': tuple(J.PREDS),
    'INC': tuple(J.PREDS), 'ANCHOR': tuple(J.PREDS),
    'STD': tuple(J.PREDS), "STD'": tuple(J.PREDS), "STD''": ('equilibrium',),
    'D2': ('improving',), 'REF': tuple(J.PREDS), 'C0': tuple(J.PREDS),
    'C1': tuple(J.PREDS), 'PERSIST': tuple(J.S.SETTLED),
    'CF': tuple(J.PREDS), 'W4': tuple(J.PREDS), 'T001': ('converged',),
}
RUNTIME = ('R3', 'R3-STD', 'INC', 'ANCHOR', 'CF', 'W4')


class Refusal(Exception):
    """No scored decision may be published."""


def diagnostic_line(text):
    """Display one line; raw JSON retains the original diagnostic text."""
    return ascii(text)[1:-1]


def dump(path, obj):
    Path(path).write_text(json.dumps(obj, indent=1, sort_keys=True, ensure_ascii=False) + '\n')


def rational(x):
    return None if x is None else str(x)


def outcome(r3, std):
    """R30R-2's first-match shipping table plus its two additive duties."""
    ship = 'R3' if r3['verdict'] == 'PASS' else 'R3-STD' if std['verdict'] == 'PASS' else 'INC'
    rules = r3['rules']
    failed4 = any(n.startswith('4 ') and v == 'FAIL' for n, v, _ in rules)
    fail1 = any(n.startswith('1 ') and v == 'FAIL' for n, v, _ in rules)
    pass2to5 = all(v == 'PASS' for n, v, _ in rules if n[0] in '2345')
    return {'ship': ship, 'silent_wrong': failed4, 'STD_p_on_H2': fail1 and pass2to5}


def preflight_ok(facts):
    caps = facts.get('capabilities', {})
    return J.rule6(str(facts['floor_exit']), facts['declarations']) is True and set(caps) == set(J.derive.CAPABILITIES) and all(type(v) is bool and v for v in caps.values())


def dry_guard(dry, calibration, subjects, allowed):
    if dry and not calibration and not set(subjects).issubset(set(allowed)):
        raise Refusal('DRY: Phase 2 subjects cannot read H1 families before the reveal; use INC/ANCHOR stand-ins or calibration/H-cal')


def check_roster(records, scored, sealed):
    if set(records) != set(RUNTIME) or set(sealed) != set(RUNTIME):
        raise Refusal('INCOMPLETE: runtime roster missing or unsealed')
    if set(scored) != set(ROSTER) or any(set(scored[a]) != set(ps) for a, ps in ROSTER.items()):
        raise Refusal('INCOMPLETE: scored comparator roster or predicate domain missing')


def controls_ok(a, points, verdicts, degradation):
    undefined = sorted(p for p in J.PREDS if points.get(p) is None)
    failed = any(points.get(p) is not None and (points[p] != J.Fraction(1, 2) or verdicts['CF'][p]['verdict'] != 'FAIL') for p in J.PREDS)
    controls = {
        'a': a,
        'b': False if failed else 'undefined' if undefined else True,
        'c1': any(n[0] in '12345' and v == 'FAIL' for n, v, _ in verdicts['W4']['converged']['rules']),
        'c2': J.rule2('converged', degradation[0], J.ci_bound(degradation[1])) is True,
    }
    if undefined:
        controls['b_undefined'] = undefined
    return controls


def check_d14(corpus):
    """R30R-4: exact finite-burn bound, including F15 copies and F15b bases."""
    checked = []
    rows = {r['id']: r for r in corpus['rows']}
    for row in corpus['rows']:
        gen = row['gen']
        seen = set()
        base_row = row
        while base_row.get('family', '').startswith('F15 ') and 'base' in base_row:
            base_id = base_row['base']
            if not isinstance(base_id, str) or base_id in seen or base_id not in rows:
                raise Refusal(f"INCOMPLETE: {row['id']}: D14 unresolved base")
            seen.add(base_id)
            base_row = rows[base_id]
        base_family = base_row.get('family', '')
        if base_row is not row or base_family.startswith('F15b '):
            family_match = re.search(r'from F(\d+) ', base_family) if base_family.startswith('F15b ') else re.match(r'^F(\d+) ', base_family)
            if not family_match or int(family_match[1]) not in J.F.NAMES or int(family_match[1]) == 15:
                raise Refusal(f"INCOMPLETE: {row['id']}: D14 unresolved base")
        # Frozen F15 copies carry a transformed generator and a base row id;
        # also resolve explicit wrappers, refusing an unknown/missing base.
        seen = set()
        while isinstance(gen, dict) and gen.get('kind') == 'scaled':
            base = gen.get('base')
            if isinstance(base, str):
                if base in seen or base not in rows:
                    raise Refusal(f"INCOMPLETE: {row['id']}: D14 unresolved base")
                seen.add(base)
                base = rows[base]['gen']
            if not isinstance(base, dict):
                raise Refusal(f"INCOMPLETE: {row['id']}: D14 unresolved base")
            if id(base) in seen:
                raise Refusal(f"INCOMPLETE: {row['id']}: D14 unresolved base")
            seen.add(id(base))
            if 'gen' in base:
                base = base['gen']
            gen = base
        if not isinstance(gen, dict):
            raise Refusal(f"INCOMPLETE: {row['id']}: D14 unresolved base")
        if row.get('family', '').startswith(('F15 ', 'F15b ')) and gen.get('kind') not in ('affine', 'pieces', 'closed', 'recur', 'cycle', 'noise', 'walk', 'uwalk', 'ar1'):
            raise Refusal(f"INCOMPLETE: {row['id']}: D14 unresolved base")
        if gen.get('kind') != 'ar1':
            if re.search(r'(?:^F9 |from F9 )', base_family):
                raise Refusal(f"INCOMPLETE: {row['id']}: D14 unresolved base")
            continue
        phi, burn = Fraction(str(gen['phi'])), gen['burn']
        if type(burn) is not int or burn < 0 or abs(phi) ** (2 * burn) >= Fraction(1, 2 ** 53):
            raise Refusal(f"INCOMPLETE: {row['id']}: D14 |phi|^(2*burn) must be < 2^-53")
        checked.append(row['id'])
    return checked


def incomplete_reasons(raw):
    """Name every unavailable subject rule and control; never substitute a BA."""
    pop = raw['populations'][raw['primary']]
    no15 = not any(r['family'].startswith('F15 ') for r in pop['rows'].values())
    undefined = {p for a, p, v in pop['points'] if a == 'CF' and v is None}
    reasons = set()
    for arm in ('R3', 'R3-STD'):
        for pred, dec in pop['decisions'][arm].items():
            for name, result, _ in dec['rules']:
                if result != 'NOT EVALUATED':
                    continue
                if name.startswith('5 ') and no15:
                    reasons.add('no-family-15')
                elif pred in undefined and name[0] in '124':
                    reasons.add('undefined-BA:' + ','.join(sorted(undefined)))
                else:
                    reasons.add(f'unevaluated:{arm}:{pred}:{name}')
    for control in ('a', 'b', 'c1', 'c2'):
        ok = raw['controls'][control]
        if ok is False:
            reasons.add('control:' + control)
    return sorted(reasons)


def dry_a_ok(raw):
    """The PR job accepts only R30R-4's two known H-cal diagnostic gaps."""
    if raw.get('status') != 'INCOMPLETE' or raw.get('dry') is not True or raw.get('primary') != 'hcal' or raw.get('error'):
        return False
    if set(raw.get('populations', {})) != {'calibration', 'hcal'}:
        return False
    if any(pop['judge_rc'] != 0 or pop['findings'] for pop in raw['populations'].values()):
        return False
    if raw['controls'] != {'a': True, 'b': 'undefined', 'b_undefined': ['diverging', 'equilibrium'], 'c1': True, 'c2': True}:
        return False
    if not all(preflight_ok(raw['preflight'][a]) for a in ('R3', 'R3-STD')):
        return False
    pop = raw['populations']['hcal']
    points = {p: None if v is None else J.Fraction(v) for a, p, v in pop['points'] if a == 'CF'}
    if any(points.get(p) != J.Fraction(1, 2) or pop['decisions']['CF'][p]['verdict'] != 'FAIL' for p in ('converged', 'stable', 'improving', 'oscillating')):
        return False
    if sorted(p for p in J.PREDS if points.get(p) is None) != ['diverging', 'equilibrium']:
        return False
    for pred in ('diverging', 'equilibrium'):
        if any(labels[pred][1] for labels in pop['labels'].values()):
            return False
    expected = ['no-family-15', 'undefined-BA:diverging,equilibrium']
    return raw.get('reasons') == expected and incomplete_reasons(raw) == expected


def control_diff(row):
    """Point is exact; CI must re-enter ci_bound from its original float."""
    return (None if row[3] is None else J.Fraction(row[3]),
            None if row[4] is None else float(row[4]))


def status_for(rc, verdicts, controls):
    if rc == 2:
        return 'INCOMPLETE'
    if rc == 1:
        return 'FINDING'
    if rc != 0:
        return 'INCOMPLETE'
    if set(verdicts) != {'R3', 'R3-STD', 'CF', 'W4'} or any(set(ps) != set(J.PREDS) for ps in verdicts.values()):
        return 'INCOMPLETE'
    if not {'a', 'b', 'c1', 'c2'}.issubset(controls) or any(controls[c] is False for c in ('a', 'b', 'c1', 'c2')):
        return 'VOID'
    if any(d.get('verdict') not in ('PASS', 'FAIL') or not d.get('rules') for ps in verdicts.values() for d in ps.values()):
        return 'INCOMPLETE'
    if controls['b'] == 'undefined':
        return 'INCOMPLETE'
    if set(controls) != {'a', 'b', 'c1', 'c2'} or any(v is not True for v in controls.values()):
        return 'VOID'
    return 'COMPLETE'


def registered_rules(subject, pred):
    """Names emitted by frozen decide(), including the amendment's domain."""
    return (['1 standard parity', '2 vs INC']
            + (['2 vs R3-STD'] if subject != 'R3-STD' and pred in ('converged', 'stable') else [])
            + (['3 safety'] if pred in ('converged', 'stable', 'equilibrium', 'diverging') else [])
            + ['4 trivial floor', '5 unit invariance', '6 existing gates'])


def validate_decisions(decisions):
    if set(decisions) != {'R3', 'R3-STD', 'CF', 'W4'}:
        raise Refusal('recorded subject roster incomplete')
    for subject in ('R3', 'R3-STD', 'CF', 'W4'):
        if set(decisions.get(subject, {})) != set(J.PREDS):
            raise Refusal('recorded subject/predicate roster incomplete')
        for pred, decision in decisions[subject].items():
            rules = decision['rules']
            if [r[0] for r in rules] != registered_rules(subject, pred) or any(len(r) != 3 or r[1] not in ('PASS', 'FAIL', 'NOT EVALUATED') for r in rules):
                raise Refusal(f'recorded rules incomplete: {subject} {pred}')
            results = [r[1] for r in rules]
            verdict = 'FAIL' if 'FAIL' in results else 'INCOMPLETE' if 'NOT EVALUATED' in results else 'PASS'
            if decision['verdict'] != verdict:
                raise Refusal(f'recorded verdict disagrees with rules: {subject} {pred}')


def extract(raw):
    """A malformed record refuses, including through the CLI (exit 2)."""
    try:
        return extract_checked(raw)
    except (KeyError, TypeError, IndexError, ValueError) as error:
        raise Refusal('malformed raw evidence: ' + str(error)) from error


def extract_checked(raw):
    if not raw.get('controls') or set(raw.get('preflight', {})) != {'R3', 'R3-STD'}:
        raise Refusal('raw requires controls and subject preflight records')
    if raw['primary'] != 'H1' and not (raw['dry'] is True and raw['primary'] == 'hcal'):
        raise Refusal('decisions require H1 (or H-cal in DRY calibration mode)')
    if 'H1' in raw['populations'] and not raw['populations']['H1']['rows']:
        raise Refusal('raw requires nonempty H1 rows')
    pop = raw['populations'][raw['primary']]
    if not pop['rows']:
        raise Refusal('raw requires nonempty primary population')
    for facts in raw['preflight'].values():
        if not {'floor_exit', 'declarations', 'capabilities'}.issubset(facts) or any(type(v) is not bool for v in facts['capabilities'].values()):
            raise Refusal('raw requires typed preflight evidence')
    for population in raw['populations'].values():
        validate_decisions(population['decisions'])
    derived_status = status_for(max(p['judge_rc'] for p in raw['populations'].values()), pop['decisions'], raw['controls'])
    if raw['status'] != derived_status:
        raise Refusal(f"recorded status {raw['status']} disagrees with evidence {derived_status}")
    table = {k: raw[k] for k in ('status', 'dry', 'seed', 'resamples')}
    table['population_tables'] = {name: whole_population(pop) for name, pop in raw.get('populations', {}).items()}
    if raw['status'] == 'COMPLETE':
        decisions = raw['populations'][raw['primary']]['decisions']
        table['predicates'] = {}
        for p in J.PREDS:
            r3, std = decisions['R3'][p], decisions['R3-STD'][p]
            table['predicates'][p] = outcome(r3, std) | {'subjects': {
                a: {'verdict': decisions[a][p]['verdict'],
                    'rules': [[n, v] for n, v, _ in decisions[a][p]['rules']]}
                for a in ('R3', 'R3-STD')}}
    return table


def whole_population(pop):
    labels, rows = pop['labels'], pop['rows']
    readings = {(a, r, t, p): v for a, r, t, p, v in pop['readings']}
    confusion, disagreements, absent = {}, [], []
    for a, preds in ROSTER.items():
        for rid, row in sorted(rows.items()):
            for t in row['checkpoints']:
                for p in preds:
                    kind, label = labels[f'{rid}@{t}'][p][:2]
                    if kind == 'REPORTED':
                        continue
                    value = readings.get((a, rid, t, p))
                    key = json.dumps([a, p, row['family']], ensure_ascii=False)
                    c = confusion.setdefault(key, [0, 0, 0, 0])
                    if value is None:
                        absent.append([a, rid, t, p])
                        continue
                    c[J.CELL[(label, value)]] += 1
                    if value != label:
                        disagreements.append([a, rid, t, p, label, value])
    return {'confusion': confusion, 'disagreements': disagreements, 'absent': absent}


def write_outputs(raw, out):
    dump(out / 'raw.json', raw)
    table = extract(json.loads((out / 'raw.json').read_text()))
    dump(out / 'decision.json', table)
    for name, pop in raw['populations'].items():
        dump(out / f'{name}-population.json', whole_population(pop))
    for p, v in table.get('predicates', {}).items():
        print(f"{'DRY ' if raw['dry'] else ''}OUTCOME {p}: {v['ship']}; silent-wrong={v['silent_wrong']}; STD_p/H2={v['STD_p_on_H2']}")
    print(raw['status'])
    for reason in raw.get('reasons', []):
        print(diagnostic_line('reason: ' + reason))
    if raw['status'] == 'VOID':
        print(diagnostic_line('failed controls: ' + ', '.join(k for k, v in raw['controls'].items() if not v) + '; step 1 is repeated'))


def command(argv, log):
    """Subprocess exits are evidence. No shell interpolation or caller binary."""
    p = subprocess.run(list(map(str, argv)), cwd=ROOT, env=build_env(), stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=3600)
    Path(log).write_text(p.stdout)
    return p


def build_env():
    return {'HOME': os.environ['HOME'], 'PATH': '/usr/bin:/bin', 'LANG': 'C',
            'XDG_CACHE_HOME': str(ROOT / 'build/observer-reveal/cache')}


def resolve(sha):
    if not re.fullmatch(r'[0-9a-f]{8,40}', sha):
        raise Refusal('arm identity must be a hexadecimal commit SHA')
    args = ['git', 'rev-parse', '--verify', sha + '^{commit}']
    p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if p.returncode:
        subprocess.run(['git', 'fetch', '--no-tags', 'origin', sha], cwd=ROOT, check=True)
        p = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, check=True)
    return p.stdout.strip()


def build(name, sha, out):
    recipe = {'ANCHOR': 'build_anchor.sh', 'W4': 'build_w4.sh'}.get(name, 'build_arm.sh')
    p = command(['bash', HERE / recipe] + ([] if name in ('ANCHOR', 'W4') else [sha]), out / f'build-{name}.log')
    if p.returncode:
        raise Refusal(f'INCOMPLETE: {name} recipe failed; see build-{name}.log')
    stamp = json.loads(p.stdout)
    rec = J.F.arm_record(stamp['binary'])
    if (rec['source_sha'], rec['recipe_id'], rec['binary_sha256']) != (sha, J.F.sha(HERE / recipe), stamp['binary_sha256']):
        raise Refusal(f'INCOMPLETE: {name} recipe stamp mismatch')
    return stamp


def install_instrument(std_stamp, out):
    """Isolate the unchanged instrument, substituting only D13's frozen scorer.

    Fresh imports and manifest subprocesses see the same tools tree. No source
    file in this checkout or in an arm checkout is rewritten.
    """
    global J, seal
    scorer = Path(J.F.arm_root(std_stamp['binary'])) / 'tools/observer_oracle/score.py'
    if J.F.sha(scorer) != SCORE_SHA256:
        raise Refusal('pinned score.py sha256 mismatch (R30R-3)')
    tools = out / 'instrument/tools'
    shutil.copytree(ROOT / 'tools', tools, ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copyfile(scorer, tools / 'observer_oracle/score.py')
    shutil.copyfile(ROOT / 'Makefile', tools.parent / 'Makefile')
    subprocess.run(['git', 'clone', '--shared', '--no-checkout', str(ROOT), str(tools.parent / 'repository')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    (tools.parent / '.git').write_text('gitdir: ' + str(tools.parent / 'repository/.git') + '\n')
    for name, module in list(sys.modules.items()):
        path = getattr(module, '__file__', None)
        if path and Path(path).is_relative_to(ROOT / 'tools') and name not in (__name__, 'reveal', 'reveal_selftest', 'manual_review'):
            del sys.modules[name]
    sys.path.insert(0, str(tools / 'observer_oracle'))
    J = importlib.import_module('judge')
    seal = importlib.import_module('seal')
    return {'source_sha': resolve(R3STD), 'score_sha256': J.F.sha(J.score.__file__)}


def stand_in(dry, sha, allowed):
    return dry and sha in allowed


def verify_commitment():
    """A1: the acceptance post and this file carry the same three identities."""
    root = Path(__file__).resolve().parent
    try:
        commitment = json.loads((root / 'reveal_commitment.json').read_text())
        expected = commitment['sha256']
        valid = isinstance(expected, dict) and commitment['format'] == 'r3-reveal-commitment/1' and set(expected) == {'reveal.py', 'reveal_selftest.py', 'reveal_fixtures.json'}
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise Refusal('accepted reveal commitment unavailable or malformed') from error
    if not valid:
        raise Refusal('accepted reveal commitment is malformed')
    for name, wanted in expected.items():
        path = root / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != wanted:
            raise Refusal('accepted reveal commitment mismatch: ' + name)


def floor(binary, out, name):
    root = Path(J.F.arm_root(binary))
    declpath = root / 'tests/phase2/oracle_expect.txt'
    lines = declpath.read_text().splitlines() if declpath.exists() else ['missing declaration file']
    p = command([sys.executable, J.score.__file__, binary, '--floor',
                 root / 'tools/observer_oracle/floor.json', '--declared', declpath], out / f'floor-{name}.log')
    return {'floor_exit': p.returncode, 'declarations': [l for l in lines if l.strip() and not l.lstrip().startswith('#')],
            'capabilities': J.score.capabilities(binary)[1], 'declaration_sha256': J.F.sha(declpath) if declpath.exists() else None}


def sealed_set(round_number, out, retries=6, delay=30):
    """Only HTTP 425 is retried, with a finite bound; all other errors propagate."""
    for attempt in range(retries):
        try:
            beacon = seal.fetch(str(round_number))
            try:
                rnd, rand = seal.checked(beacon, round_number)
            except SystemExit as error:
                raise Refusal(str(error)) from error
            J.F.write(J.F.build(J.F.H1, int(rand, 16)), str(out))
            J.F.write_manifest(str(out), {})
            return {'round': rnd, 'randomness': rand, 'beacon': beacon}
        except urllib.error.HTTPError as e:
            if e.code != 425 or attempt == retries - 1:
                raise Refusal(f'beacon unavailable: HTTP {e.code}; retry bound {retries}') from e
            print(f'beacon HTTP 425; retry {attempt + 1}/{retries}', flush=True)
            time.sleep(delay)
    raise Refusal('beacon retry bound exhausted')


def prepare_set(path, binaries, out):
    corpus = json.loads((path / 'corpus.json').read_text())
    check_d14(corpus)
    manual_review.check_manual_reviews(corpus)
    for script, opts in [('certify.py', []), ('derive.py', ['--write'])]:
        p = command([sys.executable, Path(J.HERE) / script, '--corpus', path / 'corpus.json', *opts], out / (path.name + '-' + script + '.log'))
        if p.returncode:
            raise Refusal(f'INCOMPLETE: {script} exit {p.returncode}')
    p = command([sys.executable, '-I', Path(J.HERE) / 'judge.py', '--write-manifest', path,
                 *[v for a, b in binaries.items() for v in ('--arm', a + '=' + b)]], out / (path.name + '-seal.log'))
    if p.returncode:
        raise Refusal('INCOMPLETE: manifest writer failed')
    manifest = json.loads((path / 'manifest.json').read_text())
    print(f"manifest {path.name}: sha256 {J.F.sha(path / 'manifest.json')}; derived files {len(manifest['code'])}")
    return {'sha256': J.F.sha(path / 'manifest.json'), 'manifest': manifest}


def judge_population(paths, binaries, facts, seed, resamples, out, name):
    """Observe the frozen public functions without replacing a test or rule.

    Wrappers delegate unchanged arguments/results. The rule-6 inputs are per
    subject (each build owns its floor + declaration file); judge's CLI shares
    one pair, so supply each pair when it calls decide().
    """
    pop = {'rows': {}, 'labels': {}, 'tiers': [], 'decisions': {}, 'diffs': [], 'points': []}
    for path in paths:
        corpus, labels = J.load(str(path))
        pop['rows'].update((r['id'], r) for r in corpus['rows'])
        pop['labels'].update(labels)
    original_run, original_measure, original_decide = J.run_arms, J.score.measure, J.decide
    measurements = []
    def measure(binary, corpus, caps):
        result = original_measure(binary, corpus, caps)
        measurements.append(result)
        return result
    def run_arms(bs, rows, s):
        J.score.measure = measure
        try:
            result = original_run(bs, rows, s)
        finally:
            J.score.measure = original_measure
        got, split, skipped, order, caps = result
        measured_order = [(a, r) for a, r in order if not any(aa == a and rr == r for aa, rr, cap in skipped)]
        if len(measured_order) != len(measurements):
            raise Refusal('INCOMPLETE: measurement/order accounting differs')
        for (arm, rid), measured in zip(measured_order, measurements):
            pop['tiers'].extend([arm, *k, v] for k, v in sorted(measured['read'].items()))
        pop.update(findings=split, skipped=sorted(skipped), order=order, capabilities=caps)
        pop['readings'] = [[a, r, t, p, v] for a, rs in got.items() for r, vs in rs.items() for (t, p), v in vs.items()]
        return result
    def decide(opt, subject, arms, point, fpr, diff, *rest):
        opts = dict(opt)
        fact = facts.get(subject, facts['R3'])
        decl = out / f'{subject}-declarations.txt'
        decl.write_text('\n'.join(fact['declarations']))
        opts.update({'floor-exit': str(fact['floor_exit']), 'declarations': str(decl)})
        caps = dict(rest[-1])
        caps[subject] = {c: caps.get(subject, {}).get(c, False) for c in J.derive.CAPABILITIES}
        if any(type(v) is not bool for v in caps[subject].values()):
            raise Refusal('capability values must be boolean')
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            original_decide(opts, subject, arms, point, fpr, diff, *rest[:-1], caps)
        text = buf.getvalue()
        print(text, end='')
        decisions = {p: {'rules': []} for p in J.PREDS}
        for line in text.splitlines():
            match = re.fullmatch(r'\s+(\w+)\s+=> (PASS|FAIL|INCOMPLETE)', line)
            if match:
                decisions[match[1]]['verdict'] = match[2]
                continue
            match = re.fullmatch(r'\s+(\w+)\s+([1-6] .+?)\s+(PASS|FAIL|NOT EVALUATED): (.*)', line)
            if match:
                decisions[match[1]]['rules'].append([match[2], match[3], match[4]])
        pop['decisions'][subject] = decisions
        if subject == 'R3':
            pop['points'] = [[a, p, rational(v)] for (a, p), v in sorted(point.items())]
            pop['diffs'].append(['STD', 'T001', 'converged', *map(rational, diff('STD', 'T001', 'converged'))])
    argv = ['judge.py', *[v for p in paths for v in ('--corpus', str(p))],
            *[v for a, b in binaries.items() if a != 'CF' for v in ('--arm', a + '=' + b)],
            '--const-false', 'CF=' + binaries['CF'], '--tol-converged', 'T001=0.01',
            *[v for a in ('R3', 'R3-STD', 'CF', 'W4') for v in ('--subject', a)],
            '--resamples', str(resamples), '--seed', str(seed)]
    buf = io.StringIO()
    J.run_arms, J.decide = run_arms, decide
    try:
        with contextlib.redirect_stdout(buf):
            rc = J.main(argv)
    finally:
        J.run_arms, J.score.measure, J.decide = original_run, original_measure, original_decide
        (out / (name + '-judge.log')).write_text(buf.getvalue())
    held = {r: J.generate(row['gen'], row['n']) for r, row in pop['rows'].items()}
    py = dict(J.S.ARMS) | {'T001': {'converged': J.S.tol_converged(0.01)}}
    pop['readings'] += [[a, r, t, p, f(held[r], t)] for a, ps in py.items() for p, f in ps.items()
                        for r, row in pop['rows'].items() for t in row['checkpoints'] ]
    pop.update(judge_rc=rc, judge_text=buf.getvalue())
    return pop


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selftest', action='store_true')
    parser.add_argument('--extract', type=Path)
    parser.add_argument('--check-dry-a', type=Path)
    parser.add_argument('--out', type=Path)
    parser.add_argument('--r3')
    parser.add_argument('--r3-std', default=R3STD)
    parser.add_argument('--round', type=int)
    parser.add_argument('--dry', action='store_true')
    parser.add_argument('--calibration', action='store_true')
    parser.add_argument('--resamples', type=int, default=10000)
    parser.add_argument('--seed', type=int, default=1758)
    args = parser.parse_args(argv)
    if args.selftest:
        import reveal_selftest
        return reveal_selftest.run(sys.modules[__name__])
    if args.check_dry_a:
        ok = dry_a_ok(json.loads(args.check_dry_a.read_text()))
        print('Dry A diagnostic ' + ('accepted' if ok else 'REJECTED'))
        return 0 if ok else 1
    if not args.out:
        parser.error('--out required')
    args.out.mkdir(parents=True, exist_ok=False)
    if args.extract:
        raw = json.loads(args.extract.read_text())
        write_outputs(raw, args.out)
        return 0
    if not args.r3 or (not args.calibration and args.round is None):
        parser.error('--r3 and --round required (or --dry --calibration)')
    if args.calibration and not args.dry:
        raise Refusal('calibration mode is DRY only')
    if args.resamples <= 0 or (not args.dry and args.resamples != 10000):
        raise Refusal('registered reveal requires 10000 resamples; reduced resamples are DRY only')
    raw = {'format': 'r3-reveal/1', 'dry': args.dry, 'seed': args.seed,
           'resamples': args.resamples, 'populations': {}, 'manifests': {}}
    try:
        return execute(args, raw)
    except (Refusal, ValueError, J.HarnessError, OSError, subprocess.SubprocessError) as error:
        raw['status'] = 'INCOMPLETE' if isinstance(error, (J.HarnessError, OSError, subprocess.SubprocessError)) or str(error).startswith('INCOMPLETE:') else 'REFUSED'
        raw['error'] = str(error)
        dump(args.out / 'raw.json', raw)
        print(raw['status'])
        print(diagnostic_line(f"{raw['status']}: {error}"), file=sys.stderr)
        return 2


def execute(args, raw):
    shas = {a: resolve(s) for a, s in [('R3', args.r3), ('R3-STD', args.r3_std), ('INC', INC), ('ANCHOR', ANCHOR), ('W4', INC)]}
    dry_guard(args.dry, args.calibration, [shas['R3'], shas['R3-STD']], [shas['INC'], shas['ANCHOR']])
    if not args.dry and shas['R3-STD'] != resolve(R3STD):
        raise Refusal('R3-STD must be the registered 3eed5caf commit')
    std_stamp = build('R3-STD', resolve(R3STD), args.out)
    instrument = install_instrument(std_stamp, args.out)
    stamps = {a: build(a, s, args.out) for a, s in shas.items()}
    stamps['CF'] = stamps['INC']
    binaries = {a: s['binary'] for a, s in stamps.items()}
    facts = {}
    for a in ('R3', 'R3-STD'):
        if stand_in(args.dry, shas[a], (shas['INC'], shas['ANCHOR'])):
            facts[a] = {'floor_exit': 0, 'declarations': [],
                        'capabilities': J.score.capabilities(binaries[a])[1],
                        'rule6': 'NOT APPLICABLE (stand-in)', 'capability_check': 'NOT APPLICABLE (stand-in)'}
        else:
            facts[a] = floor(binaries[a], args.out, a)
        if any(type(v) is not bool for v in facts[a].get('capabilities', {}).values()):
            raise Refusal('capability values must be boolean in preflight')
    raw.update({'format': 'r3-reveal/1', 'dry': args.dry, 'seed': args.seed, 'resamples': args.resamples,
           'instrument': instrument, 'stamps': stamps, 'preflight': facts, 'populations': {}, 'manifests': {},
           'driver': {p.name: J.F.sha(p) for p in [Path(__file__), HERE / 'manual_review.py', HERE / 'manual_review.json', HERE / 'verified_sources.json', HERE / 'seal.py', HERE / 'build_w4.sh']}})
    # R30R-2: this MUST precede sealed_set (even reading the round is too late).
    if not stand_in(args.dry, shas['R3'], (shas['INC'], shas['ANCHOR'])) and not preflight_ok(facts['R3']):
        raw['status'] = 'REFUSED'
        raise Refusal('rule 6 preflight failed; no beacon read, SHA is not final')
    sets = []
    for name, src in [('calibration', HERE), ('hcal', HERE / 'hcal')]:
        dst = args.out / name
        dst.mkdir()
        for f in J.F.SET:
            shutil.copyfile(src / f, dst / f)
        # Existing visible labels were reviewed with the frozen instrument.
        J.F.write_manifest(str(dst), binaries)
        raw['manifests'][name] = {'sha256': J.F.sha(dst / 'manifest.json'), 'manifest': json.loads((dst / 'manifest.json').read_text())}
        sets.append(dst)
    if not args.calibration:
        verify_commitment()
        h1 = args.out / 'H1'
        raw['beacon'] = sealed_set(args.round, h1)
        raw['manifests']['H1'] = prepare_set(h1, binaries, args.out)
        primary_paths, raw['primary'] = [h1], 'H1'
    else:
        primary_paths, raw['primary'] = [sets[1]], 'hcal'
    primary = judge_population(primary_paths, binaries, facts, args.seed, args.resamples, args.out, raw['primary'])
    raw['populations'][raw['primary']] = primary
    raw['populations']['calibration'] = judge_population([sets[0]], binaries, facts, args.seed, args.resamples, args.out, 'calibration')
    if not args.calibration:
        raw['populations']['hcal'] = judge_population([sets[1]], binaries, facts, args.seed, args.resamples, args.out, 'hcal')
    scored = {a: set(p for aa, r, t, p, v in primary['readings'] if aa == a) for a in {r[0] for r in primary['readings']}}
    check_roster(stamps, scored, raw['manifests']['calibration']['manifest']['arms'])
    p = command([sys.executable, Path(J.HERE) / 'plants.py', '--selftest'], args.out / 'plants.log')
    a = p.returncode == 0 and bool(re.search(r'^RED  floor-each ', p.stdout, re.M)) and 'plants: 1 examined, 1 red ' in p.stdout
    points = {pr: J.Fraction(v) for arm, pr, v in primary['points'] if arm == 'CF' and v is not None}
    degradation = control_diff(primary['diffs'][0])
    raw['controls'] = controls_ok(a, points, primary['decisions'], degradation)
    raw['control_c1_rule6'] = [r for r in primary['decisions']['W4']['converged']['rules'] if r[0].startswith('6 ')]
    rc = max(pop['judge_rc'] for pop in raw['populations'].values())
    raw['status'] = status_for(rc, primary['decisions'], raw['controls'])
    raw['reasons'] = incomplete_reasons(raw)
    write_outputs(raw, args.out)
    return 0 if raw['status'] == 'COMPLETE' else 2



def cli_entrypoint():
    try:
        sys.exit(main())
    except (Refusal, ValueError, J.HarnessError, OSError, subprocess.SubprocessError) as error:
        print(diagnostic_line(f'REFUSED: {error}'), file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    cli_entrypoint()
