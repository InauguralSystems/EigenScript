#!/usr/bin/env python3
"""Deferred lightweight runner controls: tiny child sessions and scratch bytes.
No runtime build, VM or solver execution. Run only with the heavy slot released.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent.parent
sys.dont_write_bytecode=True
sys.path.insert(0,str(ROOT/'tools'))
import bounded_process as owner
from gc_traversal_check import verify_inputs

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args(); a.out.mkdir(parents=True,exist_ok=False)
    rows=[]
    real_popen=subprocess.Popen
    child_code='''import os,sys,time
p=os.fork()
if p==0:
    os.setpgid(0,0)
    with open(sys.argv[1],"w") as f: f.write(str(os.getpid()))
time.sleep(30)
'''
    for sig in [signal.SIGINT,signal.SIGTERM,signal.SIGHUP]:
        label=signal.Signals(sig).name
        ready=a.out/(label+'.ready')
        created=[]
        previous={s:signal.getsignal(s) for s in [signal.SIGINT,signal.SIGTERM,signal.SIGHUP]}
        def interrupted_launch(*args,**kwargs):
            p=real_popen(*args,**kwargs); created.append(p)
            deadline=time.monotonic()+5
            while not ready.exists():
                if time.monotonic()>deadline: raise RuntimeError('tiny child readiness timeout')
                time.sleep(.005)
            # Signal after OS launch but BEFORE the caller receives its handle.
            os.kill(os.getpid(),sig)
            return p
        owner.subprocess.Popen=interrupted_launch
        try:
            try:
                owner.run_owned([sys.executable,'-c',child_code,str(ready)],a.out/label,10,dict(os.environ),ROOT)
            except owner.ProcessCancelled: pass
            else: raise AssertionError('launch cancellation accepted')
        finally:
            owner.subprocess.Popen=real_popen
            # The test itself also owns any deliberately intercepted handle,
            # so a failing assertion cannot strand its diagnostic children.
            for p in created:
                remaining=owner.session_members(p.pid)
                if remaining: owner.stop_session(p.pid)
                p.wait(timeout=2)
        record=json.loads((a.out/label/'process.json').read_text())
        assert record['received_signal']==sig
        assert record['cleanup'] and not record['cleanup']['remaining']
        assert int(ready.read_text()) in record['cleanup']['signaled'],'different-process-group descendant not cleaned'
        assert previous=={s:signal.getsignal(s) for s in previous},'signal handlers not restored'
        rows.append({'case':label,'result':'launch cancellation and descendant cleanup verified'})
    # Source-only drift controls call the same exported inventory verifier.
    for name in ['other_runtime.c','nested/header.h','object.o']:
        p=a.out/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(b'initial bytes')
        frozen={str(p):hashlib.sha256(p.read_bytes()).hexdigest()}
        verify_inputs(frozen)
        p.write_bytes(b'changed after freshness boundary')
        try: verify_inputs(frozen)
        except AssertionError as exc: assert 'input changed during collector test:' in str(exc)
        else: raise AssertionError('changed frozen input accepted')
        rows.append({'case':name,'result':'pristine accepted / drift rejected'})
    (a.out/'result.json').write_text(json.dumps(rows,indent=2)+'\n')
    print('gc-runner-controls: 6 controls passed')

if __name__=='__main__': main()
