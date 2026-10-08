#!/usr/bin/env python3
"""Exercise the actual CLI's executable anchor across launch forms and working directories.

Runs the host platform's resolver; macOS behavior is exercised on macOS CI.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "src" / "eigenscript"


def main():
    passed = failed = 0
    with tempfile.TemporaryDirectory(prefix="eigs-exe-path-") as temporary:
        work = Path(temporary).resolve()
        elsewhere = work / "elsewhere"
        elsewhere.mkdir()
        linked = work / "linked-eigenscript"
        linked.symlink_to(BINARY)
        inner = json.dumps('import log\nhas_key of [log, "log_info"]')
        program = f'''load_file of {json.dumps(str(ROOT / "lib" / "eigen.eigs"))}
print of ("path=" + (exe_path of null))
print of ("cwd=" + (getcwd of null))
print of ("meta=" + (str of (eigen_run of {inner})))
print of ("vm=" + (str of (eval of {inner})))
'''
        # subprocess's bare executable invokes PATH lookup, including a relative
        # PATH component. No shell rewrites argv[0] into an absolute path.
        cases = [
            ("relative", "src/eigenscript", ROOT, None),
            ("absolute", str(BINARY), work, None),
            ("PATH absolute", "eigenscript", work, str(BINARY.parent)),
            ("PATH relative", "eigenscript", ROOT, "src"),
            ("symlink", str(linked), work, None),
        ]
        for label, executable, cwd, path in cases:
            env = os.environ.copy()
            env.pop("EIGS_TRACE", None)
            env.pop("EIGS_REPLAY", None)
            if path is not None:
                env["PATH"] = path
            expected = [
                f"path={BINARY}", f"cwd={cwd}", "meta=true", "vm=true",
            ]
            try:
                result = subprocess.run(
                    [executable, "-e", program], cwd=cwd, env=env,
                    text=True, capture_output=True, timeout=30,
                )
                if result.returncode == 0 and result.stdout.splitlines() == expected and not result.stderr:
                    print(f"PASS: {label}: absolute stable path and both imports from the launch directory")
                    passed += 1
                else:
                    print(f"FAIL: {label}: rc={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}")
                    failed += 1
            except (OSError, subprocess.TimeoutExpired) as error:
                print(f"FAIL: {label}: {error}")
                failed += 1
    print(f"EXE PATH: {passed} passed, {failed} failed")
    return int(failed != 0)


if __name__ == "__main__":
    raise SystemExit(main())
