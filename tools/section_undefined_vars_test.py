#!/usr/bin/env python3
"""Bash execution oracles and calibration for section_undefined_vars (#2544).

The generator only runs builtins and our harmless probe/cat functions. Bash
tracing exposes expansions in [[ ]] as well as command arguments. Cases use a
probe substitution in patterns so bash actually prints the expanded argument.
The marker is numeric so arithmetic can preserve it. Default operands with a
read are activated by leaving their *other* parameter unset.
"""
import contextlib
import importlib.util
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile

import section_undefined_vars as gate

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('SECTION_VARS_SCRATCH', '/home/jon/src/wt/briefs/c2544b/out2'))
SEED = 2544
MARKER = '934567891234567'
PRELUDE = '''probe() { builtin printf '%s\\n' "$@"; }
cat() { local line; while IFS= read -r line; do builtin printf '%s\\n' "$line"; done; }
'''


@contextlib.contextmanager
def scratch(label):
    # CI may not have the builder's absolute durable folder.
    parent = OUT if OUT.is_dir() else ROOT.parent
    with tempfile.TemporaryDirectory(prefix='scratch-' + label + '-', dir=parent) as name:
        yield Path(name)


def tree(root, program):
    (root / 'tests/sections').mkdir(parents=True, exist_ok=True)
    (root / 'tests/run_all_tests.sh').write_text('TESTS_DIR=tests\n')
    fragment = root / 'tests/sections/probe.sh'
    fragment.write_text(program)
    return fragment


def bash(program, marker=False, trace=False, parse_only=False, poison=False):
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}
    if marker:
        env['TEST_DIR'] = MARKER + ('+$(probe ' + MARKER + ')' if poison else '')
    result = subprocess.run(['/usr/bin/env', '-i', *[f'{k}={v}' for k, v in env.items()],
                             'bash', '--norc', '--noprofile', *(['-x'] if trace else []), *(['-n'] if parse_only else [])],
                            input=PRELUDE + program, text=True, capture_output=True, timeout=3)
    return result


def read_programs(seed, count=None, rounds=2):
    rng = random.Random(seed)
    leaves = ['TEST_DIR', '$TEST_DIR', '${TEST_DIR}', '${TEST_DIR%nomatch}', '${TEST_DIR/nomatch/replaced}',
              '$((TEST_DIR+0))', '$(( $TEST_DIR + 0 ))', "'$TEST_DIR'", r'\$TEST_DIR',
              "$'literal $TEST_DIR'", '${NO_SUCH:-$TEST_DIR}', '${NO_SUCH-$TEST_DIR}',
              '${NO_SUCH:=$TEST_DIR}', '${NO_SUCH=$TEST_DIR}', '${TEST_DIR:-fallback}',
              '${TEST_DIR-fallback}', '${TEST_DIR:+alternate}', '${TEST_DIR+alternate}',
              '"${NO_SUCH:-\'$TEST_DIR\'}"', '${NO_SUCH:-\'$TEST_DIR\'}']
    # Safe-operator exemptions are a syntactic rule about UNSET variables. For
    # marker execution those six operands instead run with TEST_DIR unset.
    safe = set(leaves[14:18])
    math_operands = ['${NO_SUCH:-TEST_DIR}', '${NO_SUCH-TEST_DIR}', '${NO_SUCH:=TEST_DIR}', '${NO_SUCH=TEST_DIR}', "${NO_SUCH:-'TEST_DIR'}", '${NO_SUCH:-"TEST_DIR"}', "${NO_SUCH:-'$TEST_DIR'}", '${NO_SUCH:-"$TEST_DIR"}', "'${NO_SUCH:-TEST_DIR}'", "'${NO_SUCH:-$TEST_DIR}'", "'TEST_DIR'", '"TEST_DIR"', "'$TEST_DIR'", '\\$TEST_DIR', '\\${NO_SUCH:-$TEST_DIR}', "$'TEST_DIR'", "$'$TEST_DIR'", '${NO_SUCH:-\'$(probe "$TEST_DIR")\'}', '\'$(probe "$TEST_DIR")\'', '${NO_SUCH:+TEST_DIR}', '${NO_SUCH+TEST_DIR}', "'$(probe 'TEST_DIR')'", "${NO_SUCH:-'$(probe 'TEST_DIR')'}", 'TE"ST"_DIR', "$'TE\\x53T_DIR'"]
    safe_math = ['${TEST_DIR:-0}', '${TEST_DIR-0}', '${TEST_DIR:=0}', '${TEST_DIR=0}', '${TEST_DIR:+0}', '${TEST_DIR+0}']
    leaves.extend("$(( " + expr + " +0 ))" for expr in math_operands + safe_math)
    safe.update("$(( " + expr + " +0 ))" for expr in safe_math)
    active = {"$(( " + expr + " +0 ))" for expr in ("${NO_SUCH:+TEST_DIR}", "${NO_SUCH+TEST_DIR}")}
    # Subscripts and offsets occur only within the two claimed math forms.
    index_math = ['arr[TEST_DIR]', '${text:TEST_DIR:1}', '${arr[TEST_DIR]:-0}']
    leaves.extend('$(( ' + expr + ' +0 ))' for expr in index_math)
    wrappers = [lambda x: 'probe ' + x + '\n', lambda x: 'probe "' + x + '"\n',
                lambda x: 'probe "$(probe ' + x + ')"\n',
                lambda x: 'probe `probe ' + x + '`\n',
                lambda x: 'cat <<EOF\n' + x + '\nEOF\n',
                lambda x: "cat <<'EOF'\n" + x + '\nEOF\n',
                lambda x: 'probe "$(cat <<EOF\n' + x + '\nEOF\n)"\n',
                lambda x: 'probe "$(cat <<\'EOF\'\n' + x + '\nEOF\n)"\n',
                lambda x: 'case x in "$(probe ' + x + ')") :;; *) :;; esac\n',
                lambda x: '[[ ' + x + ' == x ]]\n',
                lambda x: 'probe $( (probe ' + x + ') )\n',
                lambda x: 'cat < <(probe ' + x + ')\n',
                lambda x: "cat < <(cat <<'EOF'\n" + x + '\nEOF\n)\n']
    count = len(leaves) * len(wrappers) * rounds if count is None else count
    programs = []
    for i in range(count):
        leaf = leaves[i % len(leaves)]
        wrap = wrappers[(i // len(leaves)) % len(wrappers)]
        # An additional command substitution layer composes independent nesting.
        program = wrap(leaf)
        if leaf in {'$(( ' + expr + ' +0 ))' for expr in index_math}:
            program = 'text=123; arr=(1)\n' + program
        if leaf in active:
            program = 'NO_SUCH=1\n' + program
        if rng.randrange(3) == 0:
            program = 'probe "$(\n' + program + ')"\n'
        programs.append((program, leaf in safe, leaf in {'$(( ' + expr + ' +0 ))' for expr in index_math}))
    for expr in math_operands + safe_math + index_math:
        for wrapper in ('(( %s +0 ))\n', 'for ((i=%s+0;0;)); do :; done\n'):
            program = wrapper % expr
            if expr in index_math:
                program = 'text=123; arr=(1)\n' + program
            if expr in ('${NO_SUCH:+TEST_DIR}', '${NO_SUCH+TEST_DIR}'):
                program = 'NO_SUCH=1\n' + program
            if rng.randrange(3) == 0:
                program = 'probe "$(\n' + program + ')"\n'
            programs.append((program, expr in safe_math, True))
    assert len(programs) == count + 2 * len(math_operands + safe_math + index_math) > 0
    return programs


def reads_oracle(root, count=None, seed=SEED, module=gate, verbose=True, rounds=2):
    programs = read_programs(seed, count, rounds)
    agreed = examined = 0
    for program, safe, poison in programs:
        fragment = tree(root, program)
        result = bash(program, marker=not safe, trace=True, poison=poison)
        parsed = bash(program, parse_only=True)
        if parsed.returncode:
            raise AssertionError(f'oracle generated invalid shell program:\n{program}\n{parsed.stderr}')
        expected = MARKER in result.stdout + result.stderr
        actual = any(n == 'TEST_DIR' for _, _, n in module.scan(root, [fragment]))
        examined += 1
        agreed += actual == expected
        if actual != expected and verbose:
            print(f'DISAGREEMENT reads expected={expected} actual={actual}\n{program}{result.stdout}{result.stderr}')
    assert examined == len(programs) > 0
    if verbose:
        print(f'reads: {agreed}/{examined} seed={seed}')
    return agreed == examined


SET_SHAPES = [
    ('declare -z QZV=1', ''), ('readonly -z QZV=1', ''), ('export -z QZV=1', ''), ('declare QZV=1 -z', ''),
    ('QZV=1', ''), ('QZV=1 probe x', ''), ('env QZV=1 true', ''),
    ('(QZV=1)', 'scope: subshell'), ('probe "$(QZV=1)"', 'scope: substitution'),
    ('QZV=1 | probe x', 'scope: pipeline'), ('{ QZV=1; } & wait', 'scope: background'),
    ('f() { QZV=1; }', 'function body counted as set'),
    ('f() { local QZV=1; }; f', 'scope: local in function'),
    ('declare QZV=1', ''), ('typeset QZV=1', ''), ('export QZV=1', ''),
    ('readonly QZV=1', ''), ('read QZV <<<1', ''), ('read -r QZV <<<1', ''),
    ('read -a QZV <<<1', ''), ('mapfile QZV <<<1', ''), ('readarray QZV <<<1', ''),
    ('for QZV in 1; do :; done', ''), ('select QZV in 1; do break; done <<<1', ''),
    ("printf -v QZV '%s' 1", ''), ('getopts a QZV -a', ''), ('let QZV=1', ''),
    ('(( QZV = 1 ))', ''), ('probe "${QZV:=1}"', ''), ('probe "${QZV=1}"', ''),
    ('probe "QZV=1"', ''), ('# QZV=1', ''), ('cat <<EOF\nQZV=1\nEOF', ''),
    ('[[ QZV=1 == x ]]', ''), ('for x in QZV=1; do :; done', ''),
    ('if false; then QZV=1; fi', 'order: unexecuted branch'),
    ('probe "$QZV"; QZV=1', ''), ('declare -x QZV=1', ''),
    ('read -p prompt QZV <<<1', ''), ('builtin printf -v QZV x', ''),
    ('printf -vQZV x', ''), ("printf -v 'QZV[0]' x", ''),
    ('read QZV[0] <<<1', ''), ('export QZV', ''), ('declare QZV', ''),
    ('readonly QZV', ''), ('export -p QZV=1', ''), ('declare -p QZV=1', ''),
    ('readonly -p QZV=1', ''), ('command -p export QZV=1', ''),
    ('$MISSING_WRAP export QZV=1', ''), ('read -pOn QZV <<<1', ''),
    ('mapfile -d: QZV <<<1', ''), ('read -a OTHER QZV <<<1', ''),
    ('printf -v QZV -v OTHER x', ''), ('read -t0 QZV <<<1', ''),
    ('printf${MISSING_SUFFIX:-} -v QZV x', ''), ('ex${MISSING_MID:+}port QZV=1', ''),
    ("(( 'QZV=1' ))", ''), ('(( "QZV"=1 ))', ''), ('(( Q"Z"V=1 ))', ''),
]


def sets_oracle(root, module=gate, verbose=True):
    agreed = examined = deliberate = 0
    for shape, reason in SET_SHAPES:
        program = shape + '\nprobe "${QZV-UNSET}"\n'
        result = bash(program)
        assert bash(program, parse_only=True).returncode == 0, (program, result.stderr)
        expected = result.stdout.splitlines()[-1] != 'UNSET'
        fragment = tree(root, shape + '\nprobe "$QZV"\n')
        actual = not any(n == 'QZV' for _, _, n in module.scan(root, [fragment]))
        examined += 1
        if actual != expected and actual and reason:
            deliberate += 1
            if verbose:
                print(f'DELIBERATE sets: {reason}\n{program}')
        elif actual != expected:
            if verbose:
                print(f'DISAGREEMENT sets expected={expected} actual={actual}\n{program}{result.stdout}{result.stderr}')
        else:
            agreed += 1
    assert examined == len(SET_SHAPES) > 0
    if verbose:
        print(f'sets: {agreed}/{examined} agreement, {deliberate} deliberate scope/order approximations')
    return agreed + deliberate == examined


def oracles():
    with scratch('oracles') as root:
        reads = reads_oracle(root)
        sets = sets_oracle(root)
        return int(not (reads and sets))


def copy_real_tree(destination):
    destination.mkdir()
    archive = subprocess.run(['git', '-C', str(ROOT), 'archive', 'HEAD'], capture_output=True, check=True)
    subprocess.run(['tar', '-x', '-C', str(destination)], input=archive.stdout, check=True)
    changed = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files'], text=True).splitlines()
    added = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '--others', '--exclude-standard'], text=True).splitlines()
    for name in set(changed + added):
        source = ROOT / name
        target = destination / name
        if source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        elif target.is_file():
            target.unlink()


def run_tool(root, env=None):
    return subprocess.run([sys.executable, str(ROOT / 'tools/section_undefined_vars.py'), '--root', str(root)],
                          text=True, capture_output=True, timeout=15, env=env)


def real_plants(root):
    copy_real_tree(root)
    population = sorted((root / 'tests/sections').glob('*.sh'))
    assert len(population) == len(list((ROOT / 'tests/sections').glob('*.sh'))) > 0
    control = run_tool(root)
    assert control.returncode == 0, control.stdout + control.stderr
    from _shell_tokens import tokenize_file
    chosen = []
    for fragment in population:
        text = fragment.read_text()
        for tok in tokenize_file(text, str(fragment)):
            if tok.subst and '$TESTS_DIR' in tok.text and any('$TESTS_DIR' in b for b in tok.subst):
                chosen.append(('double quote in substitution', fragment, text, text.index('$TESTS_DIR', tok.start)))
                break
        if chosen:
            break
    fragment = root / 'tests/sections/73x-jit-index-set-error-2540.sh'
    text = fragment.read_text()
    chosen.append(('plain command argument', fragment, text, text.index('$TESTS_DIR')))
    fragment = next(p for p in population if p not in {r[1] for r in chosen} and '$TESTS_DIR' in p.read_text())
    original = fragment.read_text()
    # No current expanded heredoc reads TESTS_DIR. Prepare that green shape
    # on a third real fragment's copy, then change ONLY its directory read.
    text = original + '\n: <<SECTION_DIRECTORY_2544\n$TESTS_DIR\nSECTION_DIRECTORY_2544\n'
    fragment.write_text(text)
    assert run_tool(root).returncode == 0
    fragment.write_text(original)
    chosen.append(('unquoted heredoc body', fragment, text, text.rindex('$TESTS_DIR')))
    assert len(chosen) == 3
    for label, fragment, text, pos in chosen:
        original = fragment.read_text()
        fragment.write_text(text[:pos] + '$TEST_DIR' + text[pos + len('$TESTS_DIR'):])
        result = run_tool(root)
        line = text[:pos].count('\n') + 1
        witness = f'{fragment}:{line}: undefined variable TEST_DIR'
        assert result.returncode == 1 and witness in result.stdout, (label, result.stdout, result.stderr)
        print(f'  PASS: plant {label}: precheck tools/section_undefined_vars.py red: {witness}')
        fragment.write_text(original)
    assert run_tool(root).returncode == 0


MUTANTS = [
    ('compound array indices', 'self.array_indices.append((opener, j + 1, close - 1))', 'pass # planted compound index loss',
     "arr=(['$QZV']=one)\n", ''),
    ('source', 'for source in sources:', 'for source in ():',
     'source "$TESTS_DIR/defs.sh"\nprobe "$QZV"\n', 'QZV=1\n'),
    ('builtin setters', 'definitions.update(setter_names(command))', 'definitions.update(())',
     'printf -v QZV x\nprobe "$QZV"\n', ''),
    ('safe operators', "safe = op in (':-', '-', ':=', '=', ':+', '+')", 'safe = False',
     'probe "${QZV:-x}"\n', ''),
    ('heredoc reads', 'if expanded:', 'if False:',
     'cat <<EOF\n$QZV\nEOF\n', ''),
    ('subst recursion', 'for sub in tok.subst:', 'for sub in ():',
     'probe "$(probe $QZV)"\n', ''),
    ('quoted substitution context', 'subst.append(ShellText(body, in_double, self.line_of(body_start)))', 'subst.append(ShellText(body, False, self.line_of(body_start)))',
     'probe "$(probe $(( $\'QZV\'+0 )))"\n', ''),
    ('arithmetic operand context', 'r, s = expansion_effects(exp, arithmetic=not quoted)',
     'r, s = expansion_effects(exp, arithmetic=False)',
     'probe "$(( ${MISSING:-QZV}+0 ))"\n', ''),
]


def load_mutant(folder, index, old, new):
    source = (ROOT / 'tools/section_undefined_vars.py').read_text()
    tokenizer = (ROOT / 'tools/_shell_tokens.py').read_text()
    if MUTANTS[index][0] in ('compound array indices', 'safe operators', 'quoted substitution context', 'arithmetic operand context'):
        assert tokenizer.count(old) == 1
        tokenizer = tokenizer.replace(old, new)
    else:
        assert source.count(old) == 1, (old, source.count(old))
        source = source.replace(old, new)
    name = f'section_mutant_{index}'
    path = folder / (name + '.py')
    token_name = f'section_tokens_mutant_{index}'
    token_path = folder / (token_name + '.py')
    token_path.write_text(tokenizer)
    spec = importlib.util.spec_from_file_location(token_name, token_path)
    tokens = importlib.util.module_from_spec(spec); spec.loader.exec_module(tokens)
    sys.modules[token_name] = tokens
    path.write_text(source.replace('from _shell_tokens import', f'from {token_name} import'))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def calibration(root, module=gate):
    results = []
    for _, _, _, program, helper in MUTANTS:
        fragment = tree(root, program)
        (root / 'tests/defs.sh').write_text(helper)
        expected = program.startswith(('cat ', 'probe "$(', '[[ ', 'arr=('))
        actual = any(n == 'QZV' for _, _, n in module.scan(root, [fragment]))
        results.append(actual == expected)
    assert len(results) == len(MUTANTS) > 0
    return results


def selftest():
    print('PLAN: 17', flush=True)
    with scratch('selftest') as base:
        real_plants(base / 'real')
        fixture = base / 'fixture'; fixture.mkdir()
        tree(fixture, '').unlink()
        result = run_tool(fixture)
        assert result.returncode == 2 and 'empty population' in result.stderr, result
        print('  PASS: vacuity: empty section population exits 2')
        assert reads_oracle(fixture, rounds=1)
        print('  PASS: fixed-seed reads oracle')
        assert sets_oracle(fixture)
        print('  PASS: setter execution oracle')
        fragment = tree(fixture, "let 'result=TEST_DIR'\n")
        assert gate.scan(fixture, [fragment]) == []
        fragment = tree(fixture, "declare -a 'arr[$TEST_DIR]=1'\n")
        assert any(n == 'TEST_DIR' for _, _, n in gate.scan(fixture, [fragment]))
        fragment = tree(fixture, 'probe "$PIPESTATUS $READLINE_LINE $OPTARG $REPLY"\n')
        assert gate.scan(fixture, [fragment]) == []
        fragment = tree(fixture, 'probe "$(probe $TEST_DIR)\n$(probe $TEST_DIR)"\n')
        assert gate.scan(fixture, [fragment]) == [(str(fragment), 1, 'TEST_DIR'), (str(fragment), 2, 'TEST_DIR')]
        fragment = tree(fixture, 'probe "$(probe $(( $\'\nTEST_DIR\' +0 )))"\n')
        assert gate.scan(fixture, [fragment]) == [(str(fragment), 2, 'TEST_DIR')]
        import shlex
        for prefix in ('.', 'source', 'builtin source', 'command -p -- source'):
            program = prefix + ' -- "$TESTS_DIR/defs.sh"\nprintf "%s" "$QZV"\n'
            fragment = tree(fixture, program)
            (fixture / 'tests/defs.sh').write_text('QZV=1\n')
            assert gate.scan(fixture, [fragment]) == []
            native = bash('TESTS_DIR=' + shlex.quote(str(fixture / 'tests')) + '\n' + program)
            assert native.returncode == 0 and native.stdout == '1', native
        print('  PASS: extra arithmetic, source, bash special and line controls')
        assert all(calibration(fixture))
        print('  PASS: fixed calibration controls')
        for index, (label, old, new, _, _) in enumerate(MUTANTS):
            module = load_mutant(base, index, old, new)
            verdicts = calibration(fixture, module)
            assert not verdicts[index], (label, verdicts)
            print(f'  PASS: mutant {label} makes its calibration case red')
        fragment = tree(fixture, 'probe "$TEST_DIR" # GAP_2544\n')
        env = dict(os.environ, SHELL_TOKENS_PLANT_GAP='GAP_2544')
        result = run_tool(fixture, env)
        assert result.returncode == 2 and str(fragment) + ':1:' in result.stderr, result
        print('  PASS: TokenizerGap refuses with file and line')
    print('section-undefined-vars selftest: 17 passed, 0 failed')
    return 0
