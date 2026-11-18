"""Own one trusted subprocess session, including launch-time cancellation.

Linux /proc supplies session membership (process groups may change). This is
not containment for a child deliberately creating a new session. No signal
mask is inherited by the child: handlers defer cancellation until Popen hands
the parent its process handle. Adapted from EigenMiniSat's bounded runner.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

class ProcessCancelled(Exception):
    pass

def session_members(session):
    members=[]
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal(): continue
        try: fields=(entry/'stat').read_text().rsplit(')',1)[1].split()
        except (FileNotFoundError,ProcessLookupError): continue
        if int(fields[3])==session and fields[0] not in ('Z','X'):
            members.append(int(entry.name))
    return members

def stop_session(session):
    deadline=time.monotonic()+5
    signaled=set()
    while True:
        members=session_members(session)
        if not members: return {'session':session,'signaled':sorted(signaled),'remaining':[]}
        for pid in members:
            try: os.kill(pid,signal.SIGSTOP)
            except ProcessLookupError: pass
        for pid in session_members(session):
            try: os.kill(pid,signal.SIGKILL); signaled.add(pid)
            except ProcessLookupError: pass
        if time.monotonic()>=deadline:
            return {'session':session,'signaled':sorted(signaled),'remaining':session_members(session)}
        time.sleep(.005)

def run_owned(command,directory,seconds,environment,cwd):
    if not Path('/proc/self/stat').is_file():
        raise RuntimeError('bounded session cleanup requires Linux /proc')
    directory.mkdir(parents=True,exist_ok=False)
    handled=(signal.SIGINT,signal.SIGTERM,signal.SIGHUP)
    previous={s:signal.getsignal(s) for s in handled}
    process=None; can_raise=False; received=None; cleanup=None; failure=None
    def cancelled(number,_frame):
        nonlocal received
        if received is None: received=number
        if can_raise: raise ProcessCancelled(signal.Signals(number).name)
    try:
        for number in handled: signal.signal(number,cancelled)
        with (directory/'stdout').open('wb') as stdout,(directory/'stderr').open('wb') as stderr:
            try:
                if received is not None: raise ProcessCancelled('cancelled before launch')
                process=subprocess.Popen([str(x) for x in command],cwd=cwd,env=environment,
                                         stdout=stdout,stderr=stderr,start_new_session=True)
                can_raise=True
                if received is not None: raise ProcessCancelled('cancelled during launch')
                process.wait(timeout=seconds)
                can_raise=False
                if session_members(process.pid):
                    raise RuntimeError('child exited with live session descendants')
            except BaseException as exc:
                can_raise=False; failure=exc
                if process is not None:
                    try: cleanup=stop_session(process.pid)
                    finally:
                        try: process.wait(timeout=1)
                        except subprocess.TimeoutExpired: pass
            finally:
                can_raise=False
                record={'command':[str(x) for x in command], 'cwd':str(cwd),
                        'returncode':None if process is None else process.returncode,
                        'timeout_seconds':seconds,'timed_out':isinstance(failure,subprocess.TimeoutExpired),
                        'received_signal':received,'cleanup':cleanup,
                        'exception':None if failure is None else type(failure).__name__,
                        'directory':str(directory)}
                (directory/'process.json').write_text(json.dumps(record,indent=2)+'\n')
    finally:
        can_raise=False
        for number,handler in previous.items(): signal.signal(number,handler)
    if cleanup and cleanup['remaining']:
        raise RuntimeError('owned session cleanup left live children') from failure
    if failure is not None: raise failure
    if received is not None: raise ProcessCancelled(signal.Signals(received).name)
    return record
