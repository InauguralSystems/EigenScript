#!/usr/bin/env python3
"""Parallel semantic half of test_fmt.sh's jit_diff-derived corpus gate."""
import concurrent.futures, glob, os, subprocess, sys, tempfile

eigs, tests = map(os.path.abspath, sys.argv[1:3])
excluded = ("gfx", "paint", "_game", "seeded_race", "userrace", "state_at", "statedump")
files = [p for p in glob.glob(os.path.join(tests, "test_*.eigs"))
         if not any(word in p for word in excluded)]

def run(path, formatted, env=None):
    try:
        p = subprocess.run([eigs, path], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=25, env=env)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        return 124, b""

def check(path):
    fd, formatted = tempfile.mkstemp(prefix=".fmt-corpus-", suffix=".eigs",
                                    dir=os.path.dirname(path))
    os.close(fd)
    tape = formatted + ".tape"
    try:
        with open(formatted, "wb") as out:
            f = subprocess.run([eigs, "--fmt", path], stdout=out,
                               stderr=subprocess.DEVNULL, timeout=25)
        if f.returncode: return os.path.basename(path) + ":formatter-refused"
        with open(path, "rb") as original, open(formatted, "rb") as result:
            if original.read() == result.read():
                return (None, False)
        a, b = run(path, formatted), run(formatted, formatted)
        if a[0] == 124 or b[0] == 124: return os.path.basename(path) + ":timeout"
        if a == b: return (None, True)
        env = os.environ.copy(); env["EIGS_TRACE"] = tape
        a = run(path, formatted, env)
        env = os.environ.copy(); env["EIGS_REPLAY"] = tape
        b = run(formatted, formatted, env)
        if a[0] == 124 or b[0] == 124: return os.path.basename(path) + ":timeout"
        return (None, True) if a == b else (os.path.basename(path) + ":behaviour", True)
    except subprocess.TimeoutExpired:
        return os.path.basename(path) + ":timeout"
    finally:
        for name in (formatted, tape):
            try: os.unlink(name)
            except FileNotFoundError:
                pass  # A failed formatter may not have created every artifact.

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(check, files))
failures = [x if isinstance(x, str) else x[0] for x in results
            if (x if isinstance(x, str) else x[0])]
compared = sum(not isinstance(x, str) and x[1] for x in results)
print("Formatter deterministic semantics: examined=%d compared=%d failures=%d%s" %
      (len(files), compared, len(failures),
       " (" + " ".join(failures) + ")" if failures else ""))
sys.exit(bool(failures))
