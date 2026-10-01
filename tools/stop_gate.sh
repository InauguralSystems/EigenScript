#!/bin/bash
# Stop-hook gate: Claude Code may not end a turn with UNCOMMITTED source
# changes that don't build and pass the smoke check. Scope is deliberate:
#  - clean tree (or non-source changes only) -> exit 0 immediately, so
#    conversational stops and doc work cost nothing;
#  - dirty src/lib/tests -> incremental build + one self-asserting suite
#    file (~seconds), exit 2 with the failure on stderr so Claude keeps
#    working instead of stopping on red.
# Escape hatch if the gate itself misbehaves: touch /tmp/eigs_stop_gate_off
# (or disable via /hooks).
if [ "${1:-}" = --selftest ]; then
exec python3 - "$0" <<'PY'
import pathlib, shutil, subprocess, sys, tempfile

script = pathlib.Path(sys.argv[1]).resolve()

def run(*args, cwd, check=True, **kwargs):
    return subprocess.run(args, cwd=cwd, check=check, text=True, **kwargs)

with tempfile.TemporaryDirectory(prefix="eigs-stop-gate-") as td:
    root = pathlib.Path(td)
    (root / "tools").mkdir()
    (root / "src").mkdir()
    (root / "changes" / "internal").mkdir(parents=True)
    shutil.copy2(script, root / "tools" / "stop_gate.sh")
    (root / "Makefile").write_text("all:\n\t@:\n")
    (root / "src" / "eigenscript").write_text("#!/bin/sh\nexit 0\n")
    (root / "src" / "eigenscript").chmod(0o755)
    (root / "src" / "vm.c").write_text("base\n")
    run("git", "init", "-q", cwd=root)
    run("git", "config", "user.name", "stop-gate-test", cwd=root)
    run("git", "config", "user.email", "stop-gate@example.invalid", cwd=root)
    run("git", "add", ".", cwd=root)
    run("git", "commit", "-qm", "base", cwd=root)
    run("git", "branch", "origin/main", cwd=root)

    # A fragment committed earlier on the branch satisfies a later dirty edit.
    fragment = root / "changes" / "internal" / "1-test.md"
    fragment.write_text("- test\n")
    run("git", "add", str(fragment), cwd=root)
    run("git", "commit", "-qm", "document branch", cwd=root)
    (root / "src" / "vm.c").write_text("documented edit\n")
    passed = run("bash", "tools/stop_gate.sh", cwd=root, check=False,
                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if passed.returncode:
        print("stop_gate selftest: committed branch fragment did not satisfy gate")
        print(passed.stdout, end="")
        raise SystemExit(1)

    # The same dirty semantics edit on a branch with no docs delta must block.
    run("git", "reset", "--hard", "-q", "origin/main", cwd=root)
    (root / "src" / "vm.c").write_text("undocumented edit\n")
    blocked = run("bash", "tools/stop_gate.sh", cwd=root, check=False,
                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if blocked.returncode != 2 or "NO changes/docs delta" not in blocked.stdout:
        print("stop_gate selftest: undocumented branch edit was not blocked")
        print(blocked.stdout, end="")
        raise SystemExit(1)

print("stop_gate selftest: committed-fragment PASS; no-fragment BLOCK")
PY
fi
[ -f /tmp/eigs_stop_gate_off ] && exit 0
cd "$(dirname "$0")/.." || exit 0
git diff --quiet HEAD -- src lib 2>/dev/null && exit 0

LOG=/tmp/eigs_stop_gate.log
if ! make -s >"$LOG" 2>&1; then
    { echo "STOP GATE: build FAILED with uncommitted src changes:"; tail -15 "$LOG"; } >&2
    exit 2
fi
if ! ./src/eigenscript tests/test_hex_literals.eigs >>"$LOG" 2>&1; then
    { echo "STOP GATE: smoke suite FAILED (test_hex_literals):"; tail -10 "$LOG"; } >&2
    exit 2
fi

# Doc-delta check: a change to the semantics surface or stdlib with NO
# movement in changes/docs is either missing its documentation or is
# doc-neutral — and doc-neutrality must be DECLARED, not defaulted
# (touch /tmp/eigs_doc_neutral; consumed per stop, like the abort flag).
SEMSURF="src/lexer.c src/parser.c src/builtins.c src/vm.c src/compiler.c src/vm.h src/eigs_embed.h src/eigs_embed.c lib"
if ! git diff --quiet HEAD -- $SEMSURF 2>/dev/null; then
    # Count documentation committed anywhere on this branch as well as dirty
    # work. A follow-up round must not forget the fragment from its first
    # commit merely because HEAD now contains it (#1440).
    BASE=${STOP_GATE_BASE:-origin/main}
    MB=$(git merge-base "$BASE" HEAD 2>/dev/null || printf '%s' HEAD)
    if git diff --quiet "$MB" -- changes docs 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard -- changes docs)" ]; then
        if [ -f /tmp/eigs_doc_neutral ]; then
            rm -f /tmp/eigs_doc_neutral
        else
            { echo "STOP GATE: semantics-surface/lib changed with NO changes/docs delta."
              echo "Add a changes/<category>/<issue>-<slug>.md fragment (+ SPEC/COMPARISON if semantics moved,"
              echo "STDLIB.md for lib modules), or declare the change doc-neutral:"
              echo "  touch /tmp/eigs_doc_neutral    (consumed by this stop)"; } >&2
            exit 2
        fi
    fi
fi
exit 0
