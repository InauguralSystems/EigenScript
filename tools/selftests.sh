#!/usr/bin/env bash
# Checker calibration: the table owns commands, read dependencies and inherited pins.
# Each command is a separate process: never invoke a shell function under `||`.
set -eu
cd "$(dirname "$0")/.."
. tools/child_plan.sh
export EIGS_CHILD_PLAN_HELPER="$PWD/tools/child_plan.sh"
command -v python3 >/dev/null 2>&1 || { echo 'selftests: INSTRUMENT ERROR: python3 missing'; exit 2; }
exec python3 - "$@" <<'PY'
import fnmatch, json, os, re, resource, shlex, shutil, subprocess, sys, tempfile, time
from pathlib import Path

def error(message):
    print('selftests: INSTRUMENT ERROR: ' + str(message), flush=True)
    raise SystemExit(2)

def git(*args):
    return subprocess.check_output(['git', '-c', 'safe.directory=*', *args]).decode().split('\0')

def git_ref_exists(ref):
    return subprocess.run(['git', '-c', 'safe.directory=*', 'rev-parse', '-q', '--verify', ref],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

PRODUCT_TRIGGER_MAX_S = 60

def child_plan_verdict(output, rc, pass_re, fail_re):
    return subprocess.run(
        ['bash', '-c', '. "$1"; child_plan_ok "$(cat "$2")" "$3" "$4" "$5"',
         'child-plan', os.environ['EIGS_CHILD_PLAN_HELPER'], '/dev/stdin',
         str(rc), pass_re, fail_re], input=output, text=True).returncode

def main():
    args = sys.argv[1:]
    if args == ['--calibrate-plan']:
        plants = [('short', 'PLAN: 3\n  PASS: one\n  PASS: two\n'),
                  ('plan-only', 'PLAN: 49\n')]
        for name, output in plants:
            if child_plan_verdict(output, 0, '^  PASS:', '^  FAIL:') == 0:
                print(f'  FAIL: {name} plant passed selftests child-plan verdict')
                return 1
            print(f'  PASS: {name} plant failed selftests child-plan verdict')
        print('PLAN: 2')
        return 0
    listing = '--list' in args
    if listing:
        args.remove('--list')
        args = args or ['--all']
    if args not in (['--all'],) and not (len(args) == 2 and args[0] == '--changed'):
        error('usage: tools/selftests.sh --all | --changed <base-ref> | --list')
    pending_merge = args[0] == '--changed' and git_ref_exists('MERGE_HEAD')
    if pending_merge:
        unresolved = set(git('diff', '--diff-filter=U', '--no-renames', '--name-only', '-z')) - {''}
        if unresolved:
            error('unresolved merge; resolve candidate paths before changed selection: ' +
                  ' '.join(sorted(unresolved)))
    # Recognise shell/Python dispatch idioms; new language idioms need extending here.
    # Calls/prose are not implementations. mutants tests the product.
    mode = r'(?:--self-?test(?:-paths)?|selftest)'
    dispatch = re.compile(r'(?:==?|\bin\b|add_argument).*?[\'\"]' + mode + r'[\'\"]|(?:^|;;)\s*' + mode + r'\)|[\'\"]' + mode + r'[\'\"]\s+in\b|^\s*if .*?=\s*--selftest\b', re.M)
    implemented = set()
    for directory in ('tools', 'tests', 'bench'):
        for path in Path(directory).rglob('*'):
            if not path.is_file() or path.as_posix() in ('tools/selftests.sh', 'tools/mutants.sh'):
                continue
            try:
                source = path.read_text()
            except UnicodeError:
                continue
            code = '\n'.join(s for s in source.splitlines() if not s.lstrip().startswith('#'))
            if dispatch.search(code):
                implemented.add(path.as_posix())
    # Product files change on most PRs, so a row triggered by one runs on most
    # PRs (#1352). Allowed only when its own timeout bound keeps that cheap:
    # the section_plan row keyed on the runner (bound 1860s) made precheck take
    # 8 minutes for every contribution that added a test (#1347 run 3).
    # The runner and top-level tests/test_* count too: a contribution that
    # adds a test adds tests/test_x.eigs and a runner section. Helpers
    # (suite_plan.sh, lsan_classify.sh) and fixture dirs are checker inputs.
    # A row's own command scripts are exempt for that row.
    product = [f for f in git('ls-files', '-z') if f in ('tests/run_all_tests.sh', 'CHANGELOG.md', 'README.md')
               or f.startswith('tests/sections/')
               or f.startswith(('src/', 'lib/', 'docs/', 'examples/'))
               or (f.startswith('tests/test_') and f.count('/') == 1)]
    if len(product) < 100:
        error(f'product population examined={len(product)} is below 100 (git ls-files failed?)')
    rows, enrolled, product_rows = [], set(), 0
    workflow = Path('.github/workflows/ci.yml').read_text()
    jobs = {m.group(1): m.group(2) for m in re.finditer(r'^  ([A-Za-z0-9_-]+):\n(.*?)(?=^  [A-Za-z0-9_-]+:|\Z)', workflow, re.M | re.S)}
    for n, line in enumerate(Path('tools/selftests.txt').read_text().splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        fields = [s.strip() for s in line.split(' | ')]
        if len(fields) not in (2, 3):
            error(f'selftests.txt:{n}: expected triggers | command | optional JSON pin')
        triggers, command = fields[:2]
        argv = shlex.split(command)
        ci_job = None
        if argv[:1] == ['ci-step']:
            if len(argv) < 3:
                error(f'selftests.txt:{n}: ci-step needs a job id and command')
            ci_job, ci_command = argv[1], ' '.join(argv[2:])
            target = triggers
            if ' ' in target or target not in implemented:
                error(f'selftests.txt:{n}: ci-step trigger must name its self-test script')
            if ci_job not in jobs:
                error(f'selftests.txt:{n}: ci-step CI job {ci_job!r} is missing')
            if not re.search(r'^\s{6,}run:\s*' + re.escape(ci_command) + r'\s*$', jobs[ci_job], re.M):
                error(f'selftests.txt:{n}: ci-step command is missing from CI job {ci_job!r}: {ci_command}')
            gate = jobs.get('gate-selftests', '')
            needs = re.search(r'^\s{4}needs:\s*\[([^]]*)\]', gate, re.M)
            if not needs or ci_job not in [s.strip() for s in needs.group(1).split(',')]:
                error(f'selftests.txt:{n}: gate-selftests does not need CI job {ci_job!r}')
            require_steps = re.findall(r'^\s{6}- name: Require .*? success\n(.*?)(?=^\s{6}- |\Z)', gate, re.M | re.S)
            if not any(f'needs.{ci_job}.result' in step and re.search(r'test\s+"\$[A-Z0-9_]+"\s*=\s*success', step) for step in require_steps):
                error(f'selftests.txt:{n}: gate-selftests has no Require success check for CI job {ci_job!r}')
            argv = []
        else:
            target = None
        if ci_job is None and (len(argv) < 4 or argv[0] != 'timeout' or not argv[1].isdigit() or int(argv[1]) < 1):
            error(f'selftests.txt:{n}: command needs timeout SECONDS')
        scripts = [s for s in argv[2:] if s.startswith(('tools/', 'tests/', 'bench/'))] if argv else [target]
        if not scripts or any(not Path(s).is_file() for s in scripts):
            error(f'selftests.txt:{n}: command does not name an existing script')
        if ci_job is None and not any(re.fullmatch(mode, a) for a in argv):
            error(f'selftests.txt:{n}: command lacks a self-test mode')
        hit = next((f for g in triggers.split() for f in product if f not in scripts and fnmatch.fnmatchcase(f, g)), None)
        if hit and ci_job is None and int(argv[1]) > PRODUCT_TRIGGER_MAX_S:
            error(f'selftests.txt:{n}: trigger matches product file {hit} but the row\'s bound is {argv[1]}s '
                  f'(> {PRODUCT_TRIGGER_MAX_S}s): it would run on most PRs; key it on the checker and its helpers (#1352)')
        product_rows += bool(hit)
        target = scripts[0]
        if target in enrolled or target not in implemented:
            error(f'selftests.txt:{n}: duplicate or non-self-test command: {target}')
        enrolled.add(target)
        pins = json.loads(fields[2]) if len(fields) == 3 and fields[2] not in ('', '-') else []
        if not isinstance(pins, list) or any(not isinstance(p, dict) or not isinstance(p.get('pattern'), str) or not isinstance(p.get('count'), int) for p in pins):
            error(f'selftests.txt:{n}: pins need pattern strings and integer counts')
        for pin in pins:
            re.compile(pin['pattern'])
        plan_pins = [p for p in pins if p['pattern'] == '^PLAN: [0-9]+$']
        if plan_pins and (len(plan_pins) != 1 or not all(isinstance(plan_pins[0].get(k), str) for k in ('pass', 'fail'))):
            error(f'selftests.txt:{n}: PLAN pin needs declared pass and fail marker regexps')
        rows.append((triggers.split(), command, target, pins, ci_job))
    if not rows or enrolled != implemented:
        error('enrolment mismatch: missing=' + repr(sorted(implemented - enrolled)) + ' stale=' + repr(sorted(enrolled - implemented)))
    changed = set()
    if args[0] == '--changed':
        if pending_merge:
            # HEAD is the old side during an uncommitted merge. Compare the
            # resolved index/worktree candidate directly with the requested
            # incoming base so incoming-only staged paths do not become changes.
            changed.update(git('diff', '--no-renames', '--name-only', '-z', args[1]))
            changed.update(git('diff', '--cached', '--no-renames', '--name-only', '-z', args[1]))
        else:
            changed.update(git('diff', '--no-renames', '--name-only', '-z', args[1] + '...HEAD'))
            changed.update(git('diff', '--no-renames', '--name-only', '-z'))
            changed.update(git('diff', '--cached', '--no-renames', '--name-only', '-z'))
        changed.update(git('ls-files', '--others', '--exclude-standard', '-z'))
    all_rows = args[0] != '--changed' or bool(changed & {'tools/selftests.sh', 'tools/selftests.txt'})
    selected = [r for r in rows if all_rows or any(fnmatch.fnmatchcase(f, p) for f in changed for p in r[0])]
    print(f'selftests: enrolment {len(enrolled)}/{len(implemented)}; product-triggered rows {product_rows} (bound <= {PRODUCT_TRIGGER_MAX_S}s each); {len(selected)} self-tests selected', flush=True)
    if listing:
        for _, cmd, _, _, ci_job in selected:
            print(f'{cmd} (covered by CI job {ci_job})' if ci_job else cmd)
        return 0
    failed, total, instrument = 0, 0.0, False
    with tempfile.TemporaryDirectory(prefix='eigs-selftests-') as scratch:
        for _, command, target, pins, ci_job in selected:
            if ci_job:
                print(f'PASS: {target} covered by CI job {ci_job}', flush=True)
                continue
            env = dict(os.environ)
            timeout = shutil.which('timeout') or shutil.which('gtimeout') or error('timeout/gtimeout missing')
            variant = {'tests/test_http_slowloris.sh': 'http'}.get(target)
            cap = (lambda: resource.setrlimit(resource.RLIMIT_AS, (1536000000, 1536000000))) if variant == 'gfx' else None
            try:
                if variant:
                    binary = env.get('SELFTEST_' + variant.upper())
                    if not binary:
                        print(f'selftests: preparing isolated {variant} binary', flush=True)
                        tree = Path(scratch) / variant
                        tree.mkdir()
                        for name in ('src', 'lib', 'tools'):
                            shutil.copytree(name, tree / name, ignore=shutil.ignore_patterns('eigenscript*', '*.o'))
                        for name in ('Makefile', 'VERSION'):
                            shutil.copy(name, tree / name)
                        # The C source/header share the binary prefix; copy those explicitly.
                        for path in Path('src').glob('eigenscript.*'):
                            shutil.copy(path, tree / path)
                        subprocess.run([timeout, '-k', '5', '600', 'make', '-C', str(tree), variant], check=True, stdout=subprocess.DEVNULL, preexec_fn=cap)
                        binary = str(tree / 'src/eigenscript')
                    env['EIGS' if variant == 'http' else 'EIGS_SWEEP_BIN'] = str(Path(binary).resolve())
            except (OSError, subprocess.SubprocessError) as exc:  # this row's setup failed: its FAIL, not the run's
                failed += 1
                print(f'FAIL: {target} setup: {exc}', flush=True)
                continue
            # HTTP readiness's public wrapper uses src/ as cwd; call its implementation there.
            cwd = 'src' if target == 'tests/http_readiness.py' else '.'
            argv = shlex.split(command)
            argv[0] = timeout
            argv[1:1] = ['-k', '5']
            if cwd == 'src':
                argv[argv.index(target)] = '../' + target
            start = time.monotonic()
            result = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, preexec_fn=cap)
            instrument |= result.returncode in (2, 126, 127)
            reasons = [] if result.returncode == 0 else [f'exit {result.returncode}' + (' (timeout)' if result.returncode == 124 else '')]
            plan_pin = next((p for p in pins if p['pattern'] == '^PLAN: [0-9]+$'), None)
            if plan_pin:
                if child_plan_verdict(result.stdout, result.returncode, plan_pin['pass'], plan_pin['fail']) != 0:
                    reasons.append('child plan contract failed')
            for pin in pins:
                pattern, wanted = pin['pattern'], pin['count']
                matches = re.findall(pattern, result.stdout, re.M)
                found = (int(matches[0]) if len(matches) == 1 else -1) if pin.get('value') else len(matches)
                if (found < wanted if pin.get('floor') else found != wanted):
                    reasons.append(f'pin {pattern!r}: found {found}, wanted {wanted}')
            seconds = time.monotonic() - start
            total += seconds
            failed += bool(reasons)
            print(f'{"FAIL" if reasons else "PASS"}: {target} {seconds:.2f}s' + (': ' + '; '.join(reasons) if reasons else ''), flush=True)
            if reasons or 'SKIP' in result.stdout:
                print(result.stdout, end='', flush=True)
    print(f'selftests: {len(selected)-failed} passed, {failed} failed; total {total:.2f}s', flush=True)
    return 2 if instrument else int(bool(failed))

try:
    sys.exit(main())
except Exception as exc:
    error(exc)
PY
