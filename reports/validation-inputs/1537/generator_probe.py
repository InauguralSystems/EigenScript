"""Run the real wrapper with a mock generator and mock Python child."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

candidate = Path(sys.argv[1]).resolve()
mode = sys.argv[2] if len(sys.argv) > 2 else 'hard'
with tempfile.TemporaryDirectory(prefix='1537-generator-critic-') as scratch:
    root=Path(scratch)
    for directory in ('tests','src','bin'):
        (root/directory).mkdir()
    shutil.copyfile(candidate,root/'tests/test_native_train_gradcheck.sh')
    shutil.copyfile(candidate.parent/'gen_tiny_model.eigs',root/'tests/gen_tiny_model.eigs')
    shutil.copyfile(candidate.parent/'lsan_classify.sh',root/'tests/lsan_classify.sh')
    fake_native=root/'src/eigenscript'
    diagnostic={'clean':'', 'hard':'gen.eigs:2:3: runtime error: signed integer overflow',
                'leak':'==17==ERROR: LeakSanitizer: detected memory leaks'}[mode]
    fake_native.write_text('#!/bin/bash\nprintf \'{}\\n\'\nprintf \'%s\\n\' '+repr(diagnostic)+' >&2\nexit 0\n')
    fake_native.chmod(0o755)
    fake_python=root/'bin/python3'
    fake_python.write_text('''#!/bin/bash
if [ "${EIGS_GRADCHECK_FAULT_SCALE:-1}" = "1.02" ]; then
    echo '  FAIL: NG01 mocked 2% derivative rejected'
    exit 1
fi
echo '  PASS: NG01 mocked normal derivative accepted'
echo 'NATIVE_GRADCHECK: 1 passed, 0 failed'
''')
    fake_python.chmod(0o755)
    env=dict(os.environ,PATH=str(root/'bin')+os.pathsep+os.environ['PATH'])
    result=subprocess.run(['/bin/bash',str(root/'tests/test_native_train_gradcheck.sh')],
                          text=True,capture_output=True,env=env,timeout=10)
    print('generator_mode=%s wrapper_rc=%d'%(mode,result.returncode))
    print(result.stdout+result.stderr,end='')
