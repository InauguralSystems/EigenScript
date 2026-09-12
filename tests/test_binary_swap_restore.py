#!/usr/bin/env python3
"""Use harmless files and the actual [99d] helper/guard; never run EigenScript."""
import hashlib
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

HERE=Path(__file__).resolve().parent
ERROR='ERROR: src/eigenscript changed during the run (rebuilt mid-suite) — results are invalid.'
# A direct child sees the restoration subshell as its parent on Bash 3 too.
# Verify that target differs from the enclosing shell before delivering the
# signal; $$ alone would target that enclosing shell and never test restoration.
SIGNAL_CODE='''import os, signal
parent=os.getppid()
outer=int(os.environ["CONTROL_OUTER_PID"])
if parent<=1 or outer<=1 or parent==outer:
    raise RuntimeError("signal helper did not enter restoration subshell")
name=os.environ["CONTROL_SIGNAL"]
os.kill(parent,getattr(signal,"SIG"+name))
print("binary-swap-signal: "+name+" parent="+str(parent)+" outer="+str(outer),flush=True)
'''
# Original [99d] preservation/restoration operations: deliberately retain this
# broken copy+mv control so an inode-insensitive checker cannot turn green.
OLD='''
SELFTEST_BIN_BAK="${EIGS_BIN}.orig"
SELFTEST_LINK_TARGET=$(readlink "$EIGS_BIN" 2>/dev/null || true)
cp -p "$EIGS_BIN" "$SELFTEST_BIN_BAK"
cp "$EIGS_BIN" "${EIGS_BIN}.tmp"
printf '\\n' >> "${EIGS_BIN}.tmp"
mv "${EIGS_BIN}.tmp" "$EIGS_BIN"
if [ -n "$SELFTEST_LINK_TARGET" ]; then
    rm -f "$EIGS_BIN" "$SELFTEST_BIN_BAK"
    ln -s "$SELFTEST_LINK_TARGET" "$EIGS_BIN"
else
    mv "$SELFTEST_BIN_BAK" "$EIGS_BIN"
fi
'''
def identity(path):
    st=path.lstat()
    return (st.st_dev,st.st_ino,st.st_mode,st.st_mtime_ns,
            os.readlink(path) if path.is_symlink() else None,
            hashlib.sha256(path.read_bytes()).hexdigest())
def main():
    runner=(HERE/'run_all_tests.sh').read_text()
    functions=[]
    for name in ['eigs_binary_fingerprint','record_binary_fingerprint','check_binary_fingerprint']:
        found=re.findall(r'^'+name+r'\(\) \{\n.*?^\}',runner,re.M|re.S)
        assert len(found)==1,name
        functions.append(found[0])
    prelude='\n'.join(functions)+'''
ensure_binary_current() { :; }
check_eigs_suite() { printf 'harmless fixture check\\n'; }
source "$RESTORE_HELPER"
'''
    positives=negatives=0
    with tempfile.TemporaryDirectory(prefix='binary-swap-control-') as tmp:
        for layout in ['hardlink','symlink','standalone']:
            for mode in ['guard','HUP','INT','TERM','old']:
                root=Path(tmp)/(layout+'-'+mode); root.mkdir()
                target=root/'target'; target.write_text('harmless original bytes\n')
                alias=root/'alias'
                if layout=='hardlink': os.link(target,alias)
                elif layout=='symlink': alias.symlink_to('target')
                else: alias.write_bytes(target.read_bytes())
                before=identity(alias); target_before=identity(target)
                command=OLD if mode=='old' else prelude
                if mode in ['HUP','INT','TERM']:
                    command+='\nexport CONTROL_OUTER_PID=$$\ncheck_binary_fingerprint() { "$CONTROL_PYTHON" -c "$CONTROL_SIGNAL_CODE"; }\n'
                if mode!='old': command+='\neigs_binary_swap_selftest\n'
                env=dict(os.environ,EIGS_BIN=str(alias),RESTORE_HELPER=str(HERE/'binary_swap.sh'),
                         CONTROL_SIGNAL=mode,CONTROL_PYTHON=sys.executable,CONTROL_SIGNAL_CODE=SIGNAL_CODE)
                result=subprocess.run(['bash','-c',command],env=env,cwd=root,capture_output=True,text=True,timeout=5)
                unchanged=identity(alias)==before
                detail=(layout,mode,result.returncode,result.stdout,result.stderr)
                assert identity(target)==target_before,('target changed',detail)
                leftovers=list(root.glob('alias.swap.*'))
                assert not leftovers,('scratch not cleaned',[str(p) for p in leftovers],detail)
                if mode=='old':
                    assert result.returncode==0 and not unchanged,(layout,'old defect did not turn red')
                    negatives+=1
                else:
                    expected=1 if mode=='guard' else 128+getattr(signal,'SIG'+mode)
                    assert result.returncode==expected,(layout,mode,result.returncode,result.stdout,result.stderr)
                    assert unchanged,('original inode/layout/bytes not restored',before,identity(alias),detail)
                    if mode=='guard':
                        assert ERROR in result.stdout and 'SELFTEST_REACHED_END' not in result.stdout
                    else:
                        sent=re.findall(r'^binary-swap-signal: '+mode+r' parent=(\d+) outer=(\d+)$',result.stdout,re.M)
                        assert len(sent)==1 and sent[0][0]!=sent[0][1],('signal not delivered to verified subshell',detail)
                    positives+=1
    assert positives==12 and negatives==3
    print(f'binary-swap-controls: positives={positives} old-defect-rejections={negatives}')
if __name__=='__main__': main()
