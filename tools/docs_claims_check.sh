#!/usr/bin/env bash
# Front-door documentation references, checked against the sources that own them.
cd "$(dirname "$0")/.." || exit 1
exec python3 - "$@" <<'PY'
import collections
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

DOCS = ('README.md docs/llms.txt CLAUDE.md docs/ARCHITECTURE.md '
        'docs/BUILTINS.md docs/CONCURRENCY.md ROADMAP.md docs/CI.md').split()
POP = Path('tools/docs_claims_populations.txt')
EXEMPT_FLAGS = {'docs/CI.md'}  # This page documents other command-line tools.
SEGMENTS = ('src lib tests tools docs examples editors bench fuzz web reports '
            '.github .claude .devcontainer').split()
TARGET_PROSE = {'sure', 'it', 'them', 'the', 'a', 'an', 'this', 'that', 'your',
                'no', 'sense', 'one', 'more', 'up', 'do', 'for', 'use', 'room'}
META_LINES = {
    '  EVERY count — `f of []` zero args, `f of [x]` one arg (the element,',
    '  not the list), `f of [a, b]` two. To pass a literal list whole,',
    '  parenthesise (#355): `f of ([x])`. Lint W017 flags the 1-element bare',
    '  callee re-collects a 2+-element arg list WHOLE (`one of [5, 6]` binds',
}
NEGATIVE_FAMILY_LINES = {
    ('docs/BUILTINS.md', 'drain. UDP is not yet exposed (#414 tracks it).'),
    ('ROADMAP.md', "  shipped: #414's title says TCP/UDP, and UDP is not exposed — see"),
}
errors = []
counts = collections.Counter()
found = {}


def red(message):
    errors.append(message)
    print('RED:', message)


def run(*argv, timeout=45):
    p = subprocess.run(argv, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=timeout)
    if p.returncode or p.stderr:
        red(f"{' '.join(argv)} failed (rc={p.returncode}): {p.stderr.strip()}")
    return p.stdout


def matches(pattern, line):
    # Equivalent to the old dc_extract loop, including multiple hits per line.
    return [m.group() for m in re.finditer(pattern, line)]


def record(kind, file, n):
    found[kind, Path(file).name] = n
    counts[kind] += n
    print(f'  population {file}: {n} {kind.lower()} reference(s)')


# #1051: a hand-typed inventory count ("The 76 modules in `lib/`") went stale.
# #1309 took counts out of these pages; this keeps them out. The text is
# scanned with line breaks folded, so a count wrapped across lines is seen.
# Two+ digits: an inventory count, not semantics ("a 1-parameter function").
# History pages (ROADMAP Completed, docs/CI.md, CLAUDE.md's DMG incident) keep
# their measurements.
COUNT_DOCS = 'README.md docs/llms.txt docs/SPEC.md docs/COMPARISON.md docs/ARCHITECTURE.md'.split()
COUNT_RE = re.compile(r'(?<![\w.])\**~?\d[\d,]*\d\+?\**(?:-| +)(?:[\w`/()*.+-]+ +){0,2}?'
                      r'(?:modules?|builtins?|widgets?|node types?|opcodes?|functions?|librar(?:y|ies)'
                      r'|examples?|tests?|checks?|files?|rows?|diagnostic codes?|lint rules?)\b', re.I)


def derived_counts():
    examined = 0
    for file in COUNT_DOCS:
        text = Path(file).read_text(encoding='utf-8')
        examined += 1
        for m in COUNT_RE.finditer(re.sub(r'\s', ' ', text)):
            line = text.count('\n', 0, m.start()) + 1
            red(f'{file}:{line}: hand-typed count "{" ".join(m.group().split())}"; point to its '
                'source (eigenscript --api, CHANGELOG.md) instead (#1051)')
    print(f'  COUNTS: examined {examined} front-door page(s)')
    if examined == 0:
        red('COUNTS examined 0')


def check_floors():
    declared = {}
    for row in POP.read_text().splitlines():
        if not row or row.startswith('#'):
            continue
        kind, file, floor = row.split('|')
        key = kind, Path(file).name
        if key in declared:
            red(f'duplicate population row {kind}/{file}')
        declared[key] = int(floor)
    for key, floor in declared.items():
        if key not in found:
            red(f'declared population {key} was never visited')
        elif found[key] < floor:
            red(f'{key} found {found[key]}, below floor {floor}')
    for key in found:
        if key not in declared:
            red(f'{key} has no population row')
    if not declared:
        red('population table is empty')


def source_and_products():
    tracked = set(run('git', '-c', 'safe.directory=*', 'ls-files').splitlines())
    if not tracked:
        red('git ls-files returned no source paths')
    top = {p.split('/')[0] for p in tracked if '/' in p}
    for name in sorted(top - set(SEGMENTS)):
        red(f'top-level source directory {name} is outside PATHS scan')
    # GNU Make versions may warn while still producing a usable database.
    probe = subprocess.run(('make', '-p', '-n', '--no-builtin-rules'),
                           text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=45)
    db = probe.stdout
    if not db:
        red(f'make produced no database: {probe.stderr.strip()}')
    elif probe.stderr:
        print(f'  NOTE: make database warning: {probe.stderr.strip()[:300]}')
    products = set()
    for line in db.splitlines():
        m = re.match(r'^([^ \t#.=][^ \t=]*):(?:[^=]|$)', line)
        if m and '/' in m[1] and not re.search(r'[$%]', m[1]):
            products.add(m[1])
    variables = dict(re.findall(r'^([A-Za-z_][A-Za-z0-9_]*) := ([^ ]+)$',
                                db, re.M))
    if not variables:
        variables = dict(re.findall(r'^([A-Za-z_][A-Za-z0-9_]*) := ([^ ]+)$',
                                    Path('Makefile').read_text(), re.M))
    for m in re.finditer(r'-o +[^ ]+|ln -f +[^ ]+ +[^ ]+|cp +[^ ]+ +[^ ]+',
                         Path('Makefile').read_text()):
        output = m.group().split()[-1]
        output = re.sub(r'\$\(([A-Za-z_][A-Za-z0-9_]*)\)',
                        lambda v: variables.get(v[1], v[0]), output)
        if '/' in output and not re.search(r'[$%]', output):
            products.add(output)
    if len(products) < 20:
        red(f'make producer set has only {len(products)} paths')
    return tracked, products


def paths(docs, tracked, products):
    pat = r'`(?:' + '|'.join(map(re.escape, SEGMENTS)) + r')/[A-Za-z0-9_.*/-]*`'
    inline = r'\]\([A-Za-z0-9_./#-]+\)'
    reference = r'^\[[A-Za-z0-9_.-]+\]: +[A-Za-z0-9_./#-]+'
    for file in docs:
        n = 0
        for lineno, line in enumerate(Path(file).read_text().splitlines(), 1):
            refs = [(x[1:-1], False) for x in matches(pat, line)]
            refs += [(x[2:-1], True) for x in matches(inline, line)]
            refs += [(x.split(':', 1)[1].strip(), True)
                     for x in matches(reference, line)]
            for path, link in refs:
                if link:
                    path = path.split('#', 1)[0]
                if not path or path.startswith(('http://', 'https://', 'mailto:')):
                    continue
                n += 1
                resolved = str(Path(file).parent / path) if link else path
                resolved = resolved.removeprefix('./')
                if '*' in resolved:
                    glob = re.compile('^' + re.escape(resolved).replace(r'\*', '[^/]*') + '$')
                    ok = any(glob.match(p) for p in tracked)
                else:
                    ok = ((resolved in tracked and Path(resolved).exists()) or
                          resolved in products or
                          any(p.startswith(resolved.rstrip('/') + '/') for p in tracked))
                if not ok:
                    red(f'{file}:{lineno} references {resolved}, absent from git and make')
        record('PATHS', file, n)


def flags(docs, help_text):
    for file in docs:
        if file in EXEMPT_FLAGS:
            continue
        n = 0
        for lineno, line in enumerate(Path(file).read_text().splitlines(), 1):
            for flag in matches(r'--[a-z][a-z0-9-]*', line):
                n += 1
                if flag == '--rm' and 'docker run' in line:
                    continue
                if not re.search(r'(?<![a-z0-9-])' + re.escape(flag) +
                                 r'(?![a-z0-9-])', help_text):
                    red(f'{file}:{lineno} documents {flag}, absent from eigenscript --help')
        record('FLAGS', file, n)


def targets(docs):
    rules = set(re.findall(r'^([a-z][a-z0-9-]*):', Path('Makefile').read_text(), re.M))
    for file in docs:
        n = 0
        for lineno, line in enumerate(Path(file).read_text().splitlines(), 1):
            for token in matches(r'make [a-z][a-z0-9-]*', line):
                target = token.split()[1]
                if target in TARGET_PROSE:
                    continue
                n += 1
                if target not in rules:
                    red(f'{file}:{lineno} documents make {target}, absent from Makefile')
        record('TARGETS', file, n)


def names(docs, api):
    known = set()
    for line in api.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == 'builtin' and len(fields) > 1:
            known.add(fields[1])
        elif fields[0] == 'extension' and len(fields) > 2:
            known.add(fields[2])
        elif fields[0] == 'lib' and len(fields) > 1:
            name = fields[1].split('(', 1)[0]
            known.update((name, name.split('.', 1)[-1]))
    source = Path('src/eigenscript.c').read_text()
    pred = re.search(r'EIGS_PREDICATE_NAMES\[.*?\{(.*?)\};', source, re.S)
    if not pred:
        red('predicate vocabulary is missing')
    else:
        known.update(re.findall(r'"([a-z_]+)"', pred[1]))
    keywords = re.findall(r'strcmp\(word, "([a-z_]+)"\)', Path('src/lexer.c').read_text())
    if len(keywords) < 10:
        red('lexer keyword resolver has no population')
    known.update(keywords)
    known.update(('host_add', 'host_fn', '__borrow_guard_selftest', 'fn',
                  'trajectory', 'observe', 'report', 'report_value'))
    for file in docs:
        text = Path(file).read_text()
        local = set(re.findall(r'define ([a-z_][a-z_0-9]*)', text))
        local.update(re.findall(r'^ *([a-z_][a-z_0-9]*) is ', text, re.M))
        local.update(re.findall(r'([a-z_][a-z_0-9]*)\(', text))
        n = 0
        for lineno, line in enumerate(text.splitlines(), 1):
            for token in matches(r'`[a-z_][a-z_0-9.]* of[ `]', line):
                name = token[1:].split(' of', 1)[0]
                n += 1
                if (name not in known and name not in local and
                    not (file == 'CLAUDE.md' and line in META_LINES and
                         name in {'f', 'one'})):
                    red(f'{file}:{lineno} calls {name} of, absent from --api and local definitions')
        record('NAMES', file, n)
    if not known:
        red('--api returned no names')


def builtin_families(docs, api):
    # A family mentioned in prose must have a public API marker. Negative
    # statements about an absent family are allowed only when they say so.
    names = set(api.split())
    families = {'udp': ('udp', re.compile(r'udp', re.I)),
                'tcp': ('net_', re.compile(r'tcp', re.I))}
    examined = 0
    for file in docs:
        for lineno, line in enumerate(Path(file).read_text().splitlines(), 1):
            for family, (marker, pattern) in families.items():
                hits = list(pattern.finditer(line))
                examined += len(hits)
                if hits and not any(marker in name for name in names):
                    if (file, line) not in NEGATIVE_FAMILY_LINES:
                        red(f'{file}:{lineno} names absent builtin family {family}')
    counts['BUILTIN FAMILIES'] = examined
    if examined < 9:
        red(f'BUILTIN FAMILIES examined {examined}, below floor 9')
    print(f'  BUILTIN FAMILIES: examined {examined}')


def enrolment():
    table = Path('tests/test_doc_examples.py').read_text()
    population = re.search(r'^POPULATION = \{(.*?)^\}', table, re.M | re.S)
    if not population:
        red('doc example POPULATION table missing')
        return
    rows = set(re.findall(r'^ *"([^"]+)":', population[1], re.M))
    declared = {row.split('|')[1] for row in POP.read_text().splitlines()
                if row.startswith('DOC ENROLMENT|')}
    files = sorted(set(['README.md', 'docs/llms.txt', *map(str, Path('docs').glob('*.md')),
                        *rows, *declared]))
    output = run('python3', 'tests/test_doc_examples.py', '--count', *files)
    answer = dict(row.split('\t') for row in output.splitlines())
    if len(answer) != len(files):
        red(f'doc fence count answered {len(answer)} of {len(files)} files')
    fenced = set()
    for file in files:
        if file not in answer:
            red(f'no doc fence count for {file}')
        elif int(answer[file]):
            fenced.add(file)
    for file in sorted(rows | declared | fenced):
        if file not in declared:
            red(f'{file} has no DOC ENROLMENT declaration')
        if file not in rows:
            red(f'{file} has no POPULATION row')
        if file not in fenced:
            red(f'{file} has no eigenscript fences')
        if file in fenced:
            record('DOC ENROLMENT', file, 1)
    if not fenced:
        red('DOC ENROLMENT examined 0 files')
    print(f'  DOC ENROLMENT: examined {len(fenced)}, declared {len(declared)}')


def stdlib_headings():
    text = Path('docs/STDLIB.md').read_text()
    modules = list(Path('lib').glob('*.eigs'))
    if not modules:
        red('stdlib heading check examined 0 modules')
    for module in modules:
        if str(module) not in text:
            red(f'{module} has no docs/STDLIB.md entry')
    print(f'  STDLIB headings: examined {len(modules)}')


def changelog_version():
    version = Path('VERSION').read_text().strip()
    if not version:
        red('VERSION is empty')
    elif not re.search(r'^## \[' + re.escape(version) + r'\]',
                       Path('CHANGELOG.md').read_text(), re.M):
        red(f'CHANGELOG.md has no [{version}] section for VERSION')
    print('  VERSION → CHANGELOG: examined 1')


def selftest():
    root = Path.cwd()
    index = run('git', '-c', 'safe.directory=*', 'ls-files', '--stage')
    tracked = {row.split('\t', 1)[1] for row in index.splitlines()}
    content = set(DOCS) | {str(p) for p in Path('docs').glob('*.md')}
    content |= {str(p) for p in Path('lib').glob('*.eigs')}
    content |= {'Makefile', 'VERSION', 'CHANGELOG.md',
                'tools/docs_claims_check.sh', 'tools/docs_claims_populations.txt',
                'tools/werror_flags.txt', 'tests/test_doc_examples.py',
                'src/eigenscript.c', 'src/lexer.c'}
    # PATHS reads existence, not contents, of referenced tracked paths.
    refs = set()
    pat = r'`(?:' + '|'.join(map(re.escape, SEGMENTS)) + r')/[A-Za-z0-9_.*/-]*`'
    for file in DOCS:
        for line in Path(file).read_text().splitlines():
            refs.update(x[1:-1] for x in matches(pat, line))
            links = [x[2:-1] for x in matches(r'\]\([A-Za-z0-9_./#-]+\)', line)]
            links += [x.split(':', 1)[1].strip() for x in
                      matches(r'^\[[A-Za-z0-9_.-]+\]: +[A-Za-z0-9_./#-]+', line)]
            refs.update(str(Path(file).parent / x.split('#', 1)[0]) for x in links if x)
    refs = {x.removeprefix('./') for x in refs} & tracked
    files = content | refs
    previous = signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        with tempfile.TemporaryDirectory(prefix='es-docs-claims-') as scratch:
            tree = Path(scratch) / 'tree'
            tree.mkdir()
            for file in sorted(files):
                dst = tree / file
                dst.parent.mkdir(parents=True, exist_ok=True)
                if file in content:
                    shutil.copy2(root / file, dst)
                else:
                    dst.touch()
            shutil.copy2(root / 'src/eigenscript', tree / 'src/eigenscript')
            subprocess.run(['git', '-c', 'safe.directory=*', 'init', '-q', str(tree)], check=True)
            subprocess.run(['git', '-C', str(tree), '-c', 'safe.directory=*',
                            'update-index', '--index-info'], input=index, text=True, check=True)
            def gate():
                return subprocess.run(['bash', 'tools/docs_claims_check.sh'], cwd=tree,
                                      text=True, stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT, timeout=90)
            passed = 0
            result = gate()
            ok = result.returncode == 0
            passed += ok
            print(f'SELFTEST: control: {"PASS" if ok else "FAIL"}')
            if not ok:
                print('\n'.join(x for x in result.stdout.splitlines() if x.startswith(('RED:', 'docs-claims:'))))
            for label, file, plant, witness in [
                ('path', 'README.md', '\n`docs/NO_SUCH_1275.md`\n', 'references'),
                ('flag', 'docs/llms.txt', '\n`eigenscript --no-such-1275`\n', '--no-such-1275'),
                ('target', 'CLAUDE.md', '\n`make no-such-1275`\n', 'make no-such-1275'),
                ('name', 'README.md', '\n`no_such_1275 of null`\n', 'no_such_1275'),
                ('count', 'docs/ARCHITECTURE.md', '\nThe 77\n`lib/` modules and a 47-widget toolkit.\n',
                 'hand-typed count "77 `lib/` modules"'),
            ]:
                p = tree / file
                original = p.read_text()
                p.write_text(original + plant)
                result = gate()
                ok = result.returncode != 0 and witness in result.stdout
                passed += ok
                print(f'SELFTEST: {label}: {"PASS" if ok else "FAIL"}')
                p.write_text(original)
            p = tree / 'tests/test_doc_examples.py'
            original = p.read_text()
            p.write_text(original.replace('"README.md":', '# "README.md":', 1))
            result = gate()
            ok = result.returncode != 0 and 'README.md has no POPULATION row' in result.stdout
            passed += ok
            print(f'SELFTEST: enrolment: {"PASS" if ok else "FAIL"}')
            p.write_text(original)
            p = tree / 'docs/PREDICATES.md'
            original = p.read_text()
            p.write_text(original.replace('```eigenscript', '```text'))
            p = tree / 'tests/test_doc_examples.py'
            table_text = p.read_text()
            p.write_text(table_text.replace('"docs/PREDICATES.md":', '# "docs/PREDICATES.md":', 1))
            result = gate()
            ok = result.returncode != 0 and 'docs/PREDICATES.md has no' in result.stdout
            passed += ok
            print(f'SELFTEST: declared-set: {"PASS" if ok else "FAIL"}')
            print('\n'.join(x for x in result.stdout.splitlines()
                            if x.startswith('RED: docs/PREDICATES.md')))
            print(f'SELFTEST: 8 case(s) run, {passed} passed, {8-passed} failed')
            return 0 if passed == 8 else 1
    finally:
        signal.signal(signal.SIGTERM, previous)


def main():
    if sys.argv[1:] == ['--selftest']:
        return selftest()
    docs = os.environ.get('DOCS_CLAIMS_DOCS', '').split() or DOCS
    for file in docs:
        if not Path(file).is_file():
            red(f'document {file} does not exist')
    binary = next((p for p in ('src/eigenscript', 'build/release/eigenscript')
                   if Path(p).is_file() and os.access(p, os.X_OK)), None)
    if not binary:
        red('no eigenscript binary; build with make')
        return 1
    tracked, products = source_and_products()
    paths(docs, tracked, products)
    flags(docs, run(binary, '--help'))
    targets(docs)
    api = run(binary, '--api')
    names(docs, api)
    builtin_families(docs, api)
    enrolment()
    stdlib_headings()
    changelog_version()
    derived_counts()
    check_floors()
    for kind in ('PATHS', 'FLAGS', 'TARGETS', 'NAMES', 'DOC ENROLMENT'):
        if counts[kind] == 0:
            red(f'{kind} examined 0')
    if not errors:
        print('docs-claims: OK — PATHS {PATHS}, FLAGS {FLAGS}, MAKE TARGETS {TARGETS}, '
              'NAMES {NAMES}, DOC ENROLMENT {DOC ENROLMENT}'.format(**counts))
    else:
        print(f'docs-claims: FAILED ({len(errors)} reference error(s))')
    return int(bool(errors))


try:
    sys.exit(main())
except Exception as exc:
    print(f'docs-claims: ABORTED: {type(exc).__name__}: {exc}', file=sys.stderr)
    sys.exit(1)
PY
