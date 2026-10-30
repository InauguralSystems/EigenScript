#!/usr/bin/env python3
"""R1.7-D6: derive the frozen re-render population from four live gate runs.

Kinds come from source-bound witnesses, never from legacy text ("3" can be a
float). Numeric position means line and ordinal plus identical separating
bytes; character offsets may move when a rendering grows. The anchor is the
last pre-N6 commit, including earlier accepted frozen-bar amendments.
"""
import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import os

BASE = 'b6f9db3879be5578de787ad6cf0d235b809f0e7c'
BAR = 'tests/phase2/builtins/builtins/'
PROFILES = ('release', 'server', 'server-db', 'zlib')
NUMBER = re.compile(rb'(?<![A-Za-z_0-9.])[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?(?![A-Za-z_0-9.])')
MARKER = b'R17-D2-KINDS-BEGIN\n'
RETIREMENT_ANCHOR = 'ed09f908603a414f77ead78e241fa10aff7f2f38'
RETIREMENTS = {BAR + name + '.branch' for name in ('proc_read_buf', 'proc_read_buf.hi')}
NEAREST_PATH = BAR + 'nearest_in_range_all.branch'
NEAREST_DECISION = 'https://github.com/InauguralSystems/EigenScript/issues/1888#issuecomment-6402855103'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def git(root, *args):
    result = subprocess.run(['git', '-C', str(root), *args], capture_output=True)
    require(result.returncode == 0, 'anchor unavailable: ' + result.stderr.decode(errors='replace'))
    return result.stdout


def anchor_files(root, paths):
    result = subprocess.run(['git', '-C', str(root), 'cat-file', '--batch'],
                            input=''.join(BASE + ':' + p + '\n' for p in paths).encode(), capture_output=True)
    require(result.returncode == 0, 'cannot read anchor files')
    stream, answer = io.BytesIO(result.stdout), {}
    for path in paths:
        header = stream.readline().split()
        require(len(header) == 3 and header[1] == b'blob', 'anchor file unavailable: ' + path)
        answer[path] = stream.read(int(header[2]))
        require(stream.read(1) == b'\n', 'malformed git object stream')
    require(not stream.read(), 'unexpected git object stream tail')
    return answer


def sha(data):
    return hashlib.sha256(data).hexdigest()


def amendments_for(root, paths):
    section = (root / 'tests/phase2/builtins_changes.md').read_text().split('## Frozen .branch amendments\n', 1)
    require(len(section) == 2, 'missing frozen .branch amendment section')
    amendments = {}
    for line in section[1].split('\n## ', 1)[0].splitlines():
        if not line.startswith('|'):
            continue
        fields = [v.strip().strip('`') for v in line.strip('|').split('|')]
        if fields[0] in paths:
            require(len(fields) == 4 and fields[0] not in amendments, 'malformed/duplicate frozen amendment')
            amendments[fields[0]] = fields[1:]
    return amendments


def retired_paths(root, data):
    """S10-D2 alone removes two paths; all other frozen bytes remain covered."""
    retired = data.get('retirements', {})
    require(set(retired) == RETIREMENTS, 'S10-D2 retirement population must be exactly proc_read_buf and proc_read_buf.hi')
    amendments = amendments_for(root, retired)
    for path, entry in retired.items():
        require(entry.get('ruling') == 'S10-D2' and entry.get('anchor') == RETIREMENT_ANCHOR,
                path + ': retirement needs S10-D2 and the immutable R1.8 bank anchor')
        source = path.removesuffix('.branch') + '.eigs'
        for frozen_path, key in ((path, 'branch_sha256'), (source, 'source_sha256')):
            prior = git(root, 'show', RETIREMENT_ANCHOR + ':' + frozen_path)
            require(sha(prior) == entry.get(key), frozen_path + ': retirement prior SHA-256 differs from bank anchor')
            removed = root / frozen_path
            require(not removed.exists() and not removed.is_symlink(), frozen_path + ': retired file still exists')
        waiver = amendments.get(path, [])
        require(len(waiver) == 3 and waiver[:2] == ['DELETED', 'S10-D2'] and bool(waiver[2]),
                path + ': retirement requires an explicit DELETED S10-D2 amendment')
    return set(retired)


def apply_semantic_amendment(root, data, frozen):
    """#1888 changes only the old self-neighbor index; this is not N6 text."""
    entries = data.get('semantic_amendments', {})
    require(set(entries) == {NEAREST_PATH}, 'S10-D2 semantic amendment population must be exactly nearest_in_range_all')
    entry = entries[NEAREST_PATH]
    require(entry.get('ruling') == 'S10-D2' and entry.get('anchor') == RETIREMENT_ANCHOR and
            entry.get('decision') == NEAREST_DECISION, NEAREST_PATH + ': semantic amendment lacks its recorded decision/anchor')
    before = b'[1, "int", "float", "float"]\nrc=0\n'
    after = b'[0, "int", "float", "float"]\nrc=0\n'
    source = NEAREST_PATH.removesuffix('.branch') + '.eigs'
    prior = git(root, 'show', RETIREMENT_ANCHOR + ':' + NEAREST_PATH)
    source_bytes = git(root, 'show', RETIREMENT_ANCHOR + ':' + source)
    require(prior == before == frozen[NEAREST_PATH] and sha(prior) == entry.get('old_sha256') and
            sha(after) == entry.get('new_sha256'), NEAREST_PATH + ': semantic amendment is not exactly the approved index 1 to 0 change')
    require(sha(source_bytes) == entry.get('source_sha256') and (root / source).read_bytes() == source_bytes,
            source + ': semantic amendment changed the frozen source/type witness')
    waiver = amendments_for(root, entries).get(NEAREST_PATH, [])
    require(len(waiver) == 3 and waiver[:2] == [sha(after), 'S10-D2'] and bool(waiver[2]),
            NEAREST_PATH + ': semantic amendment requires its exact SHA-256 S10-D2 amendment')
    require((root / NEAREST_PATH).read_bytes() == after, NEAREST_PATH + ': semantic amendment differs from approved bytes')
    frozen[NEAREST_PATH] = after



def apply_diagnostic_amendment(root, frozen):
    """S10-D3 overlays one exact main diagnostic; float rules stay unchanged."""
    path = BAR + 'read_text.branch'
    source = path.removesuffix('.branch') + '.eigs'
    before = git(root, 'show', RETIREMENT_ANCHOR + ':' + path)
    old_line = b'["over-cap-tail", " is 10485761 bytes, over the 10485760-byte cap"]\n'
    new_line = '["over-cap-tail", " is 10485761 bytes, over the 10485760-byte cap — pass read_text of [path, max_bytes] (hard ceiling 536870912) to raise it"]\n'.encode()
    require(before.count(old_line) == 1, path + ': bank diagnostic anchor changed')
    after = before.replace(old_line, new_line)
    require(frozen[path] == before, path + ': pre-N6 diagnostic differs from bank')
    require((root/path).read_bytes() == after, path + ': not exactly the S10-D3 diagnostic amendment')
    require((root/source).read_bytes() == git(root, 'show', RETIREMENT_ANCHOR + ':' + source),
            source + ': S10-D3 changed the frozen scenario')
    waiver = amendments_for(root, [path]).get(path, [])
    require(len(waiver) == 3 and waiver[:2] == [sha(after), 'S10-D3'] and bool(waiver[2]),
            path + ': exact SHA-256 S10-D3 amendment required')
    frozen[path] = after


def derive(root, observations, output):
    """Compare every gate transcript, against current bytes and the D2 anchor.

    Current differences are new D6 candidates. Anchor differences also include
    the D2 amendments already accepted before this continuation.
    """
    directories = {}
    for arg in observations:
        profile, directory = arg.split('=', 1)
        require(profile in PROFILES and profile not in directories, 'invalid/duplicate profile: ' + profile)
        directories[profile] = Path(directory)
    require(set(directories) == set(PROFILES), 'derive needs all four gate profiles')
    paths = git(root, 'ls-tree', '-r', '--name-only', BASE, '--', BAR).decode().splitlines()
    metadata = json.loads((root / 'tests/phase2/r17_float_text.json').read_text())
    retired = retired_paths(root, metadata)
    paths = [p for p in paths if p.endswith('.branch') and p not in retired]
    frozen = anchor_files(root, paths)
    apply_semantic_amendment(root, metadata, frozen)
    apply_diagnostic_amendment(root, frozen)
    files, current_differences, runs = {}, {}, {}
    for profile in PROFILES:
        directory = directories[profile]
        require({p.name for p in directory.glob('*.branch')} == {Path(p).name for p in paths},
                profile + ': gate transcript population differs from frozen population')
        hashes = {}
        for path in paths:
            live = (directory / Path(path).name).read_bytes()
            require(live.endswith(b'rc=0\n') or live == (root/path).read_bytes(), path + ': failed live probe')
            hashes[path] = sha(live)
            if live != (root / path).read_bytes():
                current_differences.setdefault(path, []).append(profile)
            if live != frozen[path]:
                entry = files.setdefault(path, dict(old_sha256=sha(frozen[path]),
                    current_sha256=sha((root/path).read_bytes()), profiles=[]))
                entry['profiles'].append(profile)
                if 'live_sha256' in entry:
                    require(entry['live_sha256'] == sha(live), path + ': output differs across profiles')
                entry['live_sha256'] = sha(live)
        runs[profile] = dict(directory=str(directory), examined=len(paths), transcripts=hashes)
    require(bool(files), 'derived amendment population is empty')
    result = dict(schema=1, ruling='R1.7-D6', base=BASE, profiles=list(PROFILES),
        current_differences=current_differences, files=files, runs=runs)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print('float-amend: derived profiles=%d examined=%d new=%d cumulative=%d' %
          (len(runs), len(paths), len(current_differences), len(files)))
    return result


def split(line):
    matches = list(NUMBER.finditer(line))
    parts, end = [], 0
    for match in matches:
        parts.append(line[end:match.start()])
        end = match.end()
    return parts + [line[end:]], [m.group() for m in matches]


def double(token):
    value = float(token)
    require(math.isfinite(value), 'non-finite float token')
    return struct.pack('>d', value)


def render(old, kinds, path):
    lines = old.splitlines(keepends=True)
    require(len(lines) == len(kinds), path + ': line count differs from kind metadata')
    result = []
    for number, (line, line_kinds) in enumerate(zip(lines, kinds), 1):
        parts, tokens = split(line)
        require(len(tokens) == len(line_kinds), '%s:%d: numeric population differs from kind metadata' % (path, number))
        out = parts[0]
        for token, kind, suffix in zip(tokens, line_kinds, parts[1:]):
            require(kind in ('int', 'float', 'text'), path + ': unknown numeric kind ' + str(kind))
            if kind == 'text':
                replacement = token
            elif kind == 'int':
                require(re.fullmatch(rb'-?(?:0|[1-9][0-9]*)', token) is not None, path + ': non-integral int token')
                replacement = token
            else:
                double(token)
                replacement = repr(float(token)).encode('ascii')
            out += replacement + suffix
        result.append(out)
    return b''.join(result)


def check_pair(old, new, kinds, path):
    expected = render(old, kinds, path)
    a, b = old.splitlines(keepends=True), new.splitlines(keepends=True)
    require(len(a) == len(b), path + ': line count changed')
    floats = 0
    for number, (left, right, line_kinds) in enumerate(zip(a, b, kinds), 1):
        lp, lt = split(left)
        rp, rt = split(right)
        label = '%s:%d' % (path, number)
        require(len(lt) == len(rt), label + ': numeric token count changed')
        require(lp == rp, label + ': non-float text or numeric position changed')
        for ordinal, (x, y, kind) in enumerate(zip(lt, rt, line_kinds), 1):
            where = label + ' token ' + str(ordinal)
            if kind in ('int', 'text'):
                require(x == y, where + ': integer spelling/value/kind changed')
            else:
                require(double(x) == double(y), where + ': double bits changed')
                require(y.decode('ascii') == repr(float(y)), where + ': float kind/text is not Python repr')
                floats += 1
    require(new == expected, path + ': amendment is not the complete N6 re-render')
    return floats


def load(root, metadata):
    data = json.loads(metadata.read_text())
    require(data.get('schema') == 2 and data.get('ruling') == 'R1.7-D6' and data.get('base') == BASE,
            'unsupported metadata schema/ruling/anchor')
    files = data.get('files', {})
    population = data.get('population', {})
    require(bool(files) and set(files) == set(population), 'metadata file population differs from the derived gate population')
    require(set(data.get('profiles', [])) == set(PROFILES), 'population must cover all four profiles')
    retired = retired_paths(root, data)
    require(not (retired & (set(files) | set(population))), 'retired path remains in the active re-render population')
    for path, profiles in population.items():
        require(path.startswith(BAR) and path.endswith('.branch') and '/' not in path[len(BAR):], 'invalid population path: ' + path)
        require(bool(profiles) and set(profiles) <= set(PROFILES), path + ': invalid profile population')
    paths = git(root, 'ls-tree', '-r', '--name-only', BASE, '--', BAR).decode().splitlines()
    require(retired <= set(paths), 'retirement path was not in the frozen pre-N6 population')
    branch_paths = [path for path in paths if path.endswith('.branch') and path not in retired]
    source_paths = [path.removesuffix('.branch') + '.eigs' for path in files]
    anchored = anchor_files(root, branch_paths + source_paths)
    frozen = {path: anchored[path] for path in branch_paths}
    require(bool(frozen), 'anchor has no frozen files')
    apply_semantic_amendment(root, data, frozen)
    apply_diagnostic_amendment(root, frozen)
    for path, entry in files.items():
        old = frozen.get(path)
        require(old is not None and sha(old) == entry['old_sha256'], path + ': old bytes do not match pinned pre-N6 hash')
        source = path.removesuffix('.branch') + '.eigs'
        baseline = anchored[source]
        require(sha(baseline) == entry['source_sha256'] and (root / source).read_bytes() == baseline,
                source + ': probe source changed; kind provenance must be reviewed')
        source_lines = baseline.decode().splitlines()
        old_lines = old.splitlines(keepends=True)
        require(old_lines[-1] == b'rc=0\n', path + ': missing fixed rc=0 trailer')
        line_kinds = [[None] * len(split(line)[1]) for line in old_lines]
        line_kinds[-1] = ['int']
        require(bool(entry['witnesses']), path + ': no kind witnesses')
        for witness in entry['witnesses']:
            require(witness['expression'] in source_lines[witness['line'] - 1], source + ': kind witness no longer comes from its source line')
            require(witness['kind'] in ('int', 'float', 'text'), source + ': invalid kind witness')
            require(witness.get('reader', 'num_type') == ('type' if witness['kind'] == 'text' else 'num_type'), source + ': invalid kind reader')
            require(witness.get('transform') in (None, 'num'), source + ': invalid witness transform')
            require(all(type(i) is int and i >= 0 for i in witness.get('index_path', [])), source + ': invalid witness index path')
            require(bool(witness['positions']), source + ': kind witness explains no tokens')
            for line, ordinal in witness['positions']:
                require(1 <= line < len(old_lines) and 1 <= ordinal <= len(line_kinds[line - 1]),
                        path + ': kind witness position outside numeric population')
                require(line_kinds[line - 1][ordinal - 1] is None, path + ': duplicate numeric kind witness')
                line_kinds[line - 1][ordinal - 1] = witness['kind']
        require(all(kind is not None for row in line_kinds for kind in row), path + ': numeric token has no kind witness')
        entry['line_kinds'] = line_kinds
        render(old, entry['line_kinds'], path)
    return data, frozen


def run_witnesses(root, binary, data, expected):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('EIGS_') and key not in ('LD_PRELOAD', 'LD_AUDIT')}
    for path, entry in data['files'].items():
        source = (root / (path.removesuffix('.branch') + '.eigs')).read_bytes()
        def expression(w):
            e = '(' + w['expression'] + ')'
            e += ''.join('[' + str(i) + ']' for i in w.get('index_path', []))
            return '(num of ' + e + ')' if w.get('transform') == 'num' else e
        tail = '\nprint of "R17-D2-KINDS-BEGIN"\n' + ''.join(
            'print of (' + w.get('reader', 'num_type') + ' of ' + expression(w) + ')\n' for w in entry['witnesses'])
        with tempfile.TemporaryDirectory(prefix='r17-d2-kind-') as temp:
            probe = Path(temp) / 'witness.eigs'
            probe.write_bytes(source + tail.encode())
            case = Path(path).stem
            rows = [line.split('\t') for line in (root / 'tests/phase2/builtins/cases.tsv').read_text().splitlines()[1:]]
            row = next(r for r in rows if r[0] == case)
            require(row[2] == '-', path + ': kind witness needs an observation hook')
            stdin = b'' if row[3] == '-' else (root / BAR / '_stdin' / row[3]).read_bytes()
            result = subprocess.run([str(binary), str(probe)], cwd=temp, env={**env, 'EIGS_PROBE_TMP':temp},
                                    input=stdin, capture_output=True, timeout=10)
        require(result.returncode == 0 and not result.stderr,
                path + ': kind witness failed rc=%d stderr=%r' % (result.returncode, result.stderr))
        require(result.stdout.count(MARKER) == 1, path + ': kind witness marker missing/duplicated')
        actual, kinds = result.stdout.split(MARKER)
        require(actual + b'rc=0\n' == expected[path], path + ': runtime probe differs from the checked frozen text')
        wanted = ''.join(('str' if w['kind'] == 'text' else w['kind']) + '\n' for w in entry['witnesses']).encode()
        require(kinds == wanted, path + ': runtime kind witness changed: ' + repr(kinds))
    print('float-amend: runtime kind witnesses binary=%s files=%d PASS' % (binary, len(data['files'])))


def check(root, metadata, candidate_dir=None, baseline_binary=None, binary=None):
    data, frozen = load(root, metadata)
    if candidate_dir:
        paths = list(candidate_dir.rglob('*'))
        require({p.relative_to(candidate_dir).as_posix() for p in paths} == {Path(p).name for p in data['files']},
                'candidate file population differs from the derived population')
        actual = {path: (candidate_dir / Path(path).name).read_bytes() for path in data['files']}
    else:
        actual = {p.relative_to(root).as_posix(): p.read_bytes() for p in (root / BAR).rglob('*.branch')}
        require(set(actual) == set(frozen), 'frozen .branch file population changed')
        require(all(actual[p] == frozen[p] for p in frozen if p not in data['files']),
                'a frozen file outside the derived population changed')
    changed, tokens = [], 0
    for path, entry in data['files'].items():
        tokens += check_pair(frozen[path], actual[path], entry['line_kinds'], path)
        if actual[path] != frozen[path]:
            changed.append(path)
            print('float-amend: R1.7-D6 path=%s SHA-256=%s' % (path, sha(actual[path])))
    require(len(changed) == len(data['files']), 'derived population contains an unchanged row')
    if baseline_binary:
        run_witnesses(root, baseline_binary, data, frozen)
    if binary:
        run_witnesses(root, binary, data, actual)
    print('float-amend: examined=%d amended=%d floats=%d PASS' % (len(data['files']), len(changed), tokens))
    return data, actual, changed


def self_test(root, metadata):
    data, frozen = load(root, metadata)
    with tempfile.TemporaryDirectory(prefix='r17-d2-selftest-') as temp:
        directory = Path(temp)
        good = {Path(p).name: render(frozen[p], e['line_kinds'], p) for p, e in data['files'].items()}
        def invoke():
            return subprocess.run([sys.executable, str(Path(__file__).resolve()), '--root', str(root),
                                   '--metadata', str(metadata), '--candidate-dir', str(directory)], capture_output=True)
        def write(files):
            for p in directory.glob('*'):
                p.unlink()
            for name, body in files.items():
                (directory / name).write_bytes(body)
        write(good)
        require(invoke().returncode == 0, 'self-test positive complete Python-repr amendment failed')
        plants = {
            'value': ('fround.branch', lambda b: b.replace(b'0.10000000149011612', b'0.2')),
            'kind': ('str.branch', lambda b: b.replace(b'"3.0"', b'"3"')),
            'integer': ('json_encode.branch', lambda b: b.replace(b'9007199254740993', b'9007199254740992', 1)),
            'integer-kind': ('json_encode.branch', lambda b: b.replace(b'[3,', b'[3.0,', 1)),
            'non-float-text': ('json_build.branch', lambda b: b.replace(b'"a"', b'"z"')),
            'missing-token': ('min.branch', lambda b: b.replace(b'[3, "int"]', b'["int"]', 1)),
            'extra-token': ('max.branch', lambda b: b.replace(b'[3, "int"]', b'[3, 4, "int"]', 1)),
            'float-render': ('str.branch', lambda b: b.replace(b'"3.0"', b'"3.00"')),
            'position': ('json_build.branch', lambda b: b.replace(b'"d": 3.0', b'3.0: "d"')),
        }
        count = 0
        for label, (name, mutate) in plants.items():
            bad = dict(good)
            bad[name] = mutate(bad[name])
            require(bad[name] != good[name], 'self-test plant did not take: ' + label)
            write(bad)
            result = invoke()
            require(result.returncode == 1 and b'FAIL:' in result.stderr, 'self-test plant survived: ' + label)
            print('float-amend-self-test: %s rejected PASS' % label)
            count += 1
        for label, files in [('missing-file', {k: v for k, v in good.items() if k != 'str.branch'}),
                             ('extra-file', dict(good, extra_branch=b'0\n'))]:
            if label == 'extra-file':
                files['extra.branch'] = files.pop('extra_branch')
            write(files)
            result = invoke()
            require(result.returncode == 1 and b'FAIL:' in result.stderr, 'self-test plant survived: ' + label)
            print('float-amend-self-test: %s rejected PASS' % label)
            count += 1
        print('float-amend-self-test: positive=1 rejected=%d PASS' % count)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--metadata', type=Path)
    parser.add_argument('--candidate-dir', type=Path, help='isolated directory containing exactly the derived candidate .branch files')
    parser.add_argument('--observations', action='append', help='derive from PROFILE=DIR gate transcripts; repeat for all four profiles')
    parser.add_argument('--population-output', type=Path, help='write the derived population JSON; never changes expectations')
    parser.add_argument('--baseline-binary', type=Path, help='also execute source-bound kind witnesses on the pre-N6 binary')
    parser.add_argument('--binary', type=Path, help='also execute source-bound kind witnesses on the candidate binary')
    parser.add_argument('--self-test', action='store_true', help='one-time planted-fault calibration; never modifies the checkout')
    args = parser.parse_args()
    metadata = args.metadata or args.root / 'tests/phase2/r17_float_text.json'
    try:
        if args.observations:
            require(args.population_output is not None, 'derive needs --population-output')
            derive(args.root, args.observations, args.population_output)
        elif args.self_test:
            self_test(args.root, metadata)
        else:
            check(args.root, metadata, args.candidate_dir, args.baseline_binary, args.binary)
    except (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.TimeoutExpired) as error:
        print('FAIL: float-amend: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
