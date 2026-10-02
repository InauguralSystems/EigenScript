"""Execute frozen checker controls in separate scratch files; no candidate edits."""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import sys

package = Path(__file__).resolve().parent
tree = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
candidate = tree / 'tests/native_train_gradcheck.py'
source = candidate.read_text()
shutil.copyfile(tree / 'tests/lsan_classify.sh', out / 'lsan_classify.sh')

diag = out / 'diagnostic_guard_removed.py'
diag.write_text(source.replace('    check_native_diagnostics(result, name)\n', '')
               .replace('    check_native_diagnostics(result, "training")\n', ''))
loss = out / 'loss_guard_removed.py'
begin = source.index('    items = [float(line[10:])')
end = source.index('    return loss', begin)
loss.write_text(source[:begin] + source[end:])
derivative = out / 'derivative_guard_removed.py'
begin = source.index('        if not math.isfinite(fine) or not math.isfinite(numeric):')
end = source.index('        if abs(numeric) < MIN_GRAD:', begin)
derivative.write_text(source[:begin] + source[end:])

old = package / 'old_native_train_gradcheck.py'
shutil.copyfile(tree / 'tests/lsan_classify.sh', package / 'lsan_classify.sh')
rows = [
    ('old_clean', old, 'clean', 0, None, None),
    ('old_ubsan_falsepass', old, 'stderr', 0, None, None),
    ('old_sentinel_falsepass', old, 'invalid_loss', 0, None, None),
    ('fixed_clean', candidate, 'clean', 0, None, None),
    ('fixed_ubsan_training', candidate, 'stderr', 1, 'training hard sanitizer diagnostic', None),
    ('fixed_ubsan_eval', candidate, 'eval_stderr', 1, 'f00p_eval hard sanitizer diagnostic', None),
    ('fixed_asan_eval', candidate, 'asan', 1, 'hard sanitizer diagnostic', None),
    ('fixed_fatal_eval', candidate, 'fatal', 1, 'hard sanitizer diagnostic', None),
    ('fixed_leak_only_rc0', candidate, 'leak', 1, 'training leak sanitizer diagnostic', None),
    ('fixed_sentinel', candidate, 'invalid_loss', 1, 'f08p invalid objective loss', None),
    ('fixed_negative_item_positive_total', candidate, 'invalid_item', 1, 'f08p invalid objective loss', None),
    ('fixed_nan_item', candidate, 'nan_item', 1, 'f08p invalid objective loss', None),
    ('fixed_inf_item', candidate, 'inf_item', 1, 'f08p invalid objective loss', None),
    ('fixed_nan_total', candidate, 'nan_total', 1, 'f08p invalid total objective loss', None),
    ('fixed_fine_overflow_coarse_zero', candidate, 'fine_overflow', 1, 'nonfinite finite difference', None),
    ('fixed_wrong_2pct', candidate, 'clean', 1, 'FAIL: NG01', '1.02'),
    ('diagnostic_guard_removed', diag, 'stderr', 0, None, None),
    ('loss_guard_removed', loss, 'invalid_loss', 0, None, None),
    ('derivative_guard_removed', derivative, 'fine_overflow', 0, None, None),
]
summary = []
for name, path, mode, expected, marker, scale in rows:
    env = os.environ.copy()
    env.pop('EIGS_GRADCHECK_FAULT_SCALE', None)
    if scale:
        env['EIGS_GRADCHECK_FAULT_SCALE'] = scale
    p = subprocess.run(['python3', str(package / 'receipt_probe.py'), str(path), mode],
                       env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    (out / (name + '.log')).write_text(p.stdout)
    actual = re.search(r'^mode=.* rc=(\d+)$', p.stdout, re.M)
    assert p.returncode == 0 and actual and int(actual[1]) == expected, (name, p.returncode, p.stdout)
    assert not marker or marker in p.stdout, (name, p.stdout)
    if expected == 0:
        assert 'inventory groups=22 scalars=352 nominal=44 unique=43' in p.stdout, (name, p.stdout)
    summary.append({'case': name, 'observed_harness_rc': int(actual[1]), 'oracle': 'PASS'})
    print(name, 'observed_harness_rc=' + actual[1], 'calibration PASS', flush=True)

for mode, expected in [('clean', 0), ('hard', 1), ('leak', 1)]:
    name = 'generator_' + mode
    p = subprocess.run(['python3', str(package / 'generator_probe.py'),
                        str(tree / 'tests/test_native_train_gradcheck.sh'), mode],
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    (out / (name + '.log')).write_text(p.stdout)
    actual = re.search(r'^generator_mode=.* wrapper_rc=(\d+)$', p.stdout, re.M)
    assert p.returncode == 0 and actual and int(actual[1]) == expected, (name, p.returncode, p.stdout)
    marker = 'PASS: NG03' if mode == 'clean' else 'FAIL: NG00 generator sanitizer diagnostic'
    assert marker in p.stdout, (name, p.stdout)
    summary.append({'case': name, 'observed_wrapper_rc': int(actual[1]), 'oracle': 'PASS'})
    print(name, 'observed_wrapper_rc=' + actual[1], 'calibration PASS', flush=True)

assert len(summary) == 22
(out / 'calibration-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print('CALIBRATION: examined22 passed22 failed0')
