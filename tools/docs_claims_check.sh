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
        'docs/BUILTINS.md docs/CONCURRENCY.md ROADMAP.md docs/CI.md docs/INSTRUMENTS.md').split()
POP = Path('tools/docs_claims_populations.txt')
EXEMPT_FLAGS = {'docs/CI.md', 'docs/INSTRUMENTS.md'}  # This page documents other command-line tools.
SEGMENTS = ('src lib tests tools docs examples editors bench fuzz web reports changes spec evidence '
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
    ('docs/BUILTINS.md', 'drain. UDP is not yet exposed.'),
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


def strict_default_wording():
    """Keep builtin error rows and graphics/audio strict-by-default."""
    text = Path('docs/BUILTINS.md').read_text(encoding='utf-8')
    conditional = re.compile(
        r'\braises?\s+under\s+(?:strict\b|`EIGS_STRICT=1`)|'
        r'\bunder\s+`EIGS_STRICT=1`\s+(?:(?:it|both|they)\s+)?raises?\b', re.I)
    lines = text.splitlines()
    for lineno, line in enumerate(lines, 1):
        if conditional.search(line):
            red(f'docs/BUILTINS.md:{lineno}: describes strict errors as conditional; '
                'state the default first and the EIGS_STRICT=0 fallback second (#1396)')
    print(f'  STRICT DEFAULT ROWS: examined {len(lines)} line(s)')
    if not lines:
        red('STRICT DEFAULT ROWS examined 0 lines')
    headings = ('Graphics (SDL2) Extension', 'Audio (additional)')
    sections = collections.defaultdict(list)
    for match in re.finditer(r'^## ([^\n]+)\n(.*?)(?=^## |\Z)', text, re.M | re.S):
        if match[1] in headings:
            sections[match[1]].append(match[2])
    examined = 0
    for heading in headings:
        if len(sections[heading]) != 1:
            red(f'docs/BUILTINS.md: strict-default section {heading!r} must exist exactly once')
            continue
        examined += 1
        section = sections[heading][0]
        stale = re.findall(r'(?:under|with)\s+`EIGS_STRICT=1`|with the flag off', section, re.I)
        if stale:
            red(f'docs/BUILTINS.md: {heading} describes strict as opt-in: ' + ', '.join(stale))
        if heading == headings[0]:
            paragraph = re.search(r'\*\*Wrong-typed and wrong-arity arguments \(#1007\)\.\*\*(.*?)(?=\nTwo shapes are deliberately|\Z)', section, re.S)
            if not paragraph:
                red('docs/BUILTINS.md: gfx wrong-argument paragraph is missing')
            elif not re.search(r'\bby default\b', paragraph[1], re.I) or '`EIGS_STRICT=0`' not in paragraph[1]:
                red('docs/BUILTINS.md: gfx paragraph must name the strict default and '
                    'EIGS_STRICT=0 compatibility mode (#1428)')
    print(f'  STRICT DEFAULT: examined {examined} section(s), declared {len(headings)}')


def bool_result_wording():
    """Reject numeric result prose for builtins whose C constructors are bool.

    The implementation, rather than a second hand-maintained type list, owns
    the classification: a builtin is in the population when its function body
    constructs bool values and constructs no numeric values.  This deliberately
    narrow rule does not guess about helpers with mixed/dynamic return kinds.
    """
    sources = sorted(Path('src').glob('*.c'))
    bools = set()
    function_re = re.compile(r'Value\*\s+builtin_([A-Za-z0-9_]+)\s*\([^)]*\)\s*\{')
    for path in sources:
        source = path.read_text(encoding='utf-8')
        for match in function_re.finditer(source):
            depth = 1
            end = match.end()
            while end < len(source) and depth:
                depth += (source[end] == '{') - (source[end] == '}')
                end += 1
            body = source[match.end():end]
            # make_float too: phase 2 (#1758) replaces make_num with make_int/make_float.
            if 'make_bool(' in body and not re.search(r'make_(?:num|int|float)\s*\(', body):
                bools.add(match[1])

    # Result verbs keep numeric examples/ranges out of the claim population.
    numeric_result = re.compile(
        r'\b(?:returns?|answers?)\s+`?[01]`?\b|'
        r'(?:→|->)\s*`?[01]`?\b|'
        r'`?[01]`?\s+(?:if|while|on\s+(?:success|failure))\b', re.I)
    examined = hits = 0
    for file in ('docs/BUILTINS.md', 'src/lsp_builtin_index.h'):
        for lineno, line in enumerate(Path(file).read_text(encoding='utf-8').splitlines(), 1):
            if file.endswith('.md'):
                match = re.match(r'^\|\s*`([A-Za-z0-9_]+)`\s*\|', line)
            else:
                match = re.match(r'^\s*\{"([A-Za-z0-9_]+)",', line)
            if not match or match[1] not in bools:
                continue
            examined += 1
            claim = numeric_result.search(line)
            if claim:
                hits += 1
                red(f'{file}:{lineno}: bool builtin {match[1]} has numeric result claim '
                    f'{claim.group()!r}; say true/false (#1945)')
    print(f'  BOOL RESULT WORDING: {len(bools)} constructor-derived bool builtin(s), '
          f'{examined} documented row/hover entrie(s), {hits} hit(s)')
    if not bools or not examined:
        red('BOOL RESULT WORDING population is empty')


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


def name_vocabulary(api):
    """Return the one vocabulary used for every documented `name of` call."""
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
    known.update(('host_add', 'host_fn', 'fn',
                  'trajectory', 'observe', 'report', 'report_value', 'prev'))
    if not known:
        red('--api returned no names')
    return known


CALL_CLAIM = re.compile(r'`([a-z_][a-z_0-9.]*) of(?=[ `]|$)')


def names(docs, known, record_population=True):
    """Check document sets through one call matcher and one name vocabulary."""
    for file in docs:
        text = Path(file).read_text()
        local = set(re.findall(r'define ([a-z_][a-z_0-9]*)', text))
        local.update(re.findall(r'^ *([a-z_][a-z_0-9]*) is ', text, re.M))
        local.update(re.findall(r'`(?:local )?([a-z_][a-z_0-9]*) is ', text))
        local.update(re.findall(r'([a-z_][a-z_0-9]*)\(', text))
        n = 0
        for lineno, line in enumerate(text.splitlines(), 1):
            for match in CALL_CLAIM.finditer(line):
                name = match[1]
                n += 1
                # A qualified callee is a member of a runtime namespace, not
                # a global API claim, so its base cannot be checked here.
                if ('.' not in name and name not in known and name not in local and
                    not (file == 'CLAUDE.md' and line in META_LINES and
                         name in {'f', 'one'})):
                    red(f'{file}:{lineno} calls {name} of, absent from --api and local definitions')
        if record_population:
            record('NAMES', file, n)

def source_call_claims(known):
    """Check call claims in C comments and compiler comparisons."""
    examined = 0
    # A leading C signature/Usage comment asserts a builtin surface. A compiler
    # comparison against a call callee gives that surface special semantics.
    usage = re.compile(r'^\s*/\*\s*(?:Usage:\s*)?([a-z_][a-z_0-9]*) of(?:[ `]|$)')
    for path in (Path('src/builtins.c'), Path('src/compiler.c')):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            for name in usage.findall(line):
                examined += 1
                if name not in known:
                    red(f'{path}:{lineno} documents {name} of, absent from public API')
    compiler = Path('src/compiler.c').read_text()
    for match in re.finditer(
            r'strcmp\((?:fn|callee)(?:_node)?->[^,]+, "([a-z_][a-z_0-9]*)"\)',
            compiler):
        name = match[1]
        examined += 1
        if name not in known:
            lineno = compiler.count('\n', 0, match.start()) + 1
            red(f'src/compiler.c:{lineno} scans for {name}, absent from public API')
    print(f'  SOURCE CALL CLAIMS: examined {examined} call claim(s)')
    if not examined:
        red('SOURCE CALL CLAIMS examined 0 call claims')


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


def stale_concurrency_claims():
    """Keep shipped cooperative-task scheduling documented as available."""
    file = 'docs/BUILTINS.md'
    in_concurrency = False
    examined = 0
    for lineno, line in enumerate(Path(file).read_text().splitlines(), 1):
        if line == '## Concurrency':
            in_concurrency = True
            continue
        if in_concurrency and line.startswith('## '):
            break
        if in_concurrency and 'later increment' in line:
            examined += 1
            red(f'{file}:{lineno} describes shipped task scheduling as a later increment')
    print(f'  STALE CONCURRENCY CLAIMS: examined {examined} suspect line(s)')


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
                'src/builtins.c', 'src/compiler.c', 'src/eigenscript.c',
                'src/lexer.c'}
    # bool_result_wording derives its population from implementation sources
    # and checks the generated hover index, so its isolated selftest needs the
    # same inputs as a real checkout rather than a hand-maintained subset.
    content |= {p for p in tracked if Path(p).match('src/*.c')}
    content.add('src/lsp_builtin_index.h')
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
                ('contract-name', 'docs/PREDICATES.md',
                 '\n`no_such_contract_1944 of\n', 'no_such_contract_1944'),
                ('count', 'docs/ARCHITECTURE.md', '\nThe 77\n`lib/` modules and a 47-widget toolkit.\n',
                 'hand-typed count "77 `lib/` modules"'),
                ('stale-concurrency', 'docs/BUILTINS.md',
                 '\n## Concurrency\nScheduling lands in a later increment.\n## End selftest\n',
                 'describes shipped task scheduling as a later increment'),
            ]:
                p = tree / file
                original = p.read_text()
                if label == 'stale-concurrency':
                    p.write_text(original.replace('## Concurrency\n',
                                                  '## Concurrency\n' + plant, 1))
                else:
                    p.write_text(original + plant)
                result = gate()
                ok = result.returncode != 0 and witness in result.stdout
                passed += ok
                print(f'SELFTEST: {label}: {"PASS" if ok else "FAIL"}')
                p.write_text(original)
            p = tree / 'docs/BUILTINS.md'
            original = p.read_text()
            p.write_text(original.replace('Returns `true` on success or `false` when libSDL2 is unavailable.',
                                          'Returns 1 on success or `false` when libSDL2 is unavailable.', 1))
            result = gate()
            ok = result.returncode != 0 and 'bool builtin gfx_open has numeric result claim' in result.stdout
            passed += ok
            print(f'SELFTEST: bool-result: {"PASS" if ok else "FAIL"}')
            p.write_text(original)
            p = tree / 'docs/BUILTINS.md'
            original = p.read_text()
            for label, anchor, replacement, witness in [
                ('strict-intro', '**Wrong-typed and wrong-arity arguments (#1007).**',
                 '**Wrong-typed and wrong-arity arguments (#1007).** Under `EIGS_STRICT=1` invalid input raises.', 'describes strict as opt-in'),
                ('strict-later-gfx', '**Text rendering and fonts (#593).**',
                 '**Text rendering and fonts (#593).** With `EIGS_STRICT=1` invalid input raises.', 'describes strict as opt-in'),
                ('strict-audio', '## Audio (additional)',
                 '## Audio (additional)\nUnder `EIGS_STRICT=1` invalid input raises.', 'describes strict as opt-in'),
                ('strict-core-row', '## Core Language',
                 '## Core Language\nA bad argument answers `0`; under `EIGS_STRICT=1` it raises.', 'describes strict errors as conditional'),
                ('strict-audio-short', 'A **short or non-list** argument also raises by default;',
                 'A **short or non-list** argument also raises under strict;', 'describes strict errors as conditional'),
                ('strict-section-missing', '## Audio (additional)',
                 '## Removed audio heading', "strict-default section 'Audio (additional)' must exist exactly once"),
                ('strict-gfx-section-missing', '## Graphics (SDL2) Extension',
                 '## Removed graphics heading', "strict-default section 'Graphics (SDL2) Extension' must exist exactly once"),
            ]:
                assert original.count(anchor) == 1, (label, anchor)
                p.write_text(original.replace(anchor, replacement, 1))
                result = gate()
                ok = result.returncode != 0 and witness in result.stdout
                passed += ok
                print(f'SELFTEST: {label}: {"PASS" if ok else "FAIL"}')
                p.write_text(original)
            p.write_text(original + '\nAn explicit `EIGS_STRICT=1` setting keeps the default strict mode.\n')
            result = gate()
            ok = result.returncode == 0
            passed += ok
            print(f'SELFTEST: strict-explicit-setting: {"PASS" if ok else "FAIL"}')
            if not ok:
                print(result.stdout)
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
            print(f'SELFTEST: 19 case(s) run, {passed} passed, {19-passed} failed')
            return 0 if passed == 19 else 1
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
    known = name_vocabulary(api)
    names(docs, known)
    names(('docs/SPEC.md', 'docs/PREDICATES.md', 'docs/OBSERVER.md'), known,
          record_population=False)
    source_call_claims(known)
    builtin_families(docs, api)
    stale_concurrency_claims()
    enrolment()
    stdlib_headings()
    changelog_version()
    derived_counts()
    strict_default_wording()
    bool_result_wording()
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
