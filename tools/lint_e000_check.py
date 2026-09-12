#!/usr/bin/env python3
"""Missing-file JSON contract independent of the host TMPDIR length."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

def validate(raw, path, clipped):
    rows=json.loads(raw.decode('utf-8'))
    assert len(rows)==1, 'E000 diagnostic population'
    row=rows[0]
    assert row['code']=='E000' and row['severity']=='error' and row['line']==0, 'E000 classification'
    assert row['file']==path, 'E000 file path altered'
    message=row['message']
    assert isinstance(message,str) and len(message.encode('utf-8'))<=255, 'E000 message exceeds 255 bytes'
    full=("cannot read file '%s'" % path).encode('utf-8')
    assert (len(full)>255)==clipped, 'E000 fixture does not exercise intended length'
    # Valid UTF-8 fixture text: the longest complete prefix fitting 252 bytes
    # leaves exactly three bytes for the documented ASCII ellipsis (#1132).
    expected=(full[:252].decode('utf-8', errors='ignore')+'...').encode('utf-8') if clipped else full
    assert message.encode('utf-8')==expected, 'E000 message bytes differ'

def main():
    binary=str(Path(sys.argv[1]).resolve())
    # Resolve the binary's supplied directory entry without following a hard
    # link into build/: callers supply the normal src/eigenscript alias.
    cases=[('short','missing.eigs',False),('ascii','a'*190+'/missing.eigs',True),
           ('multibyte','é'*110+'/missing.eigs',True)]
    completed=[]
    with tempfile.TemporaryDirectory(prefix='e000-') as root:
        for name,suffix,clipped in cases:
            # A fixed long parent makes the cut reproducible on Linux too.
            prefix='' if name=='short' else 'parent-'+'p'*80+'/'
            path=str(Path(root)/(prefix+suffix))
            assert not Path(path).exists()
            p=subprocess.run([binary,'--lint','--json',path],capture_output=True,timeout=10)
            assert p.returncode==1 and p.stderr==b'', (name,'E000 process',p.returncode,p.stderr)
            validate(p.stdout,path,clipped)
            completed.append(name)
    assert completed==['short','ascii','multibyte'], 'E000 case population changed'
    print(f'E000: {len(completed)} cases passed')
if __name__=='__main__':main()
