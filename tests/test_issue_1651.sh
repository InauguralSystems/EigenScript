#!/usr/bin/env bash
set -u
BIN=${1:-./eigenscript}
BIN=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")
D=$(mktemp -d "${TMPDIR:-/tmp}/eigs-1651.XXXXXX")
trap 'rm -rf "$D"' EXIT
mkdir "$D/space dir"
cat > "$D/space dir/module.eigs" <<'EIGS'
define boom() as:
    x is [1] - 2
boom of null
EIGS
printf 'load_file of "space dir/module.eigs"\n' > "$D/main.eigs"
OUT=$(cd "$D" && "$BIN" main.eigs 2>&1); RC=$?
MODULE=$(cd "$D" && realpath "space dir/module.eigs")
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; printf '%s\n' "$OUT"; fail=$((fail+1)); fi; }
check 'uncaught header carries the loaded source file and line' 'grep -Fq "Error $MODULE:2:" <<<"$OUT"'
check 'callee frame carries its source file and line' 'grep -Fq "at boom ($MODULE:2)" <<<"$OUT"'
check 'loaded module frame carries its source file and line' 'grep -Fq "at <module> ($MODULE:3)" <<<"$OUT"'
check 'main frame carries its distinct source file and line' 'grep -Fq "at <module> (main.eigs:1)" <<<"$OUT"'
check 'a source path containing spaces prints intact' 'grep -Fq "space dir/module.eigs:2" <<<"$OUT"'
cat > "$D/caught-runtime.eigs" <<'EIGS'
try:
    x is [1] - 2
catch e:
    print of [e.file, e.line]
    print of e.message
EIGS
RUNTIME_OUT=$(cd "$D" && "$BIN" caught-runtime.eigs 2>&1); RUNTIME_RC=$?
cat > "$D/caught-eval.eigs" <<'EIGS'
try:
    eval of "x is [1] - 2"
catch e:
    print of e.message
EIGS
EVAL_CAUGHT_OUT=$(cd "$D" && "$BIN" caught-eval.eigs 2>&1); EVAL_CAUGHT_RC=$?
cat > "$D/caught-module.eigs" <<'EIGS'
try:
    load_file of "space dir/module.eigs"
catch e:
    print of e.message
EIGS
MODULE_CAUGHT_OUT=$(cd "$D" && "$BIN" caught-module.eigs 2>&1); MODULE_CAUGHT_RC=$?
OUT="$RUNTIME_OUT"
EXPECTED_LOCATION='["caught-runtime.eigs", 2]'
EXPECTED_MESSAGE="cannot apply '-' to list and num"
check 'caught runtime error exposes file beside line' '[ "$(head -n1 <<<"$RUNTIME_OUT")" = "$EXPECTED_LOCATION" ]'
check 'caught runtime error message is byte-identical to main' '[ "$(tail -n1 <<<"$RUNTIME_OUT")" = "$EXPECTED_MESSAGE" ]'
check 'caught eval error message is byte-identical to main' '[ "$EVAL_CAUGHT_OUT" = "$EXPECTED_MESSAGE" ]'
check 'caught loaded-module error message is byte-identical to main' '[ "$MODULE_CAUGHT_OUT" = "$EXPECTED_MESSAGE" ]'
RC2=0
[ "$RUNTIME_RC" -eq 0 ] && [ "$EVAL_CAUGHT_RC" -eq 0 ] && [ "$MODULE_CAUGHT_RC" -eq 0 ] || RC2=1
cat > "$D/sandbox-errors.eigs" <<'EIGS'
loop_cap is sandbox_run of [[1, [63,3,0,30,6,0,40], []], 10]
callable is sandbox_run of [[1, [25,0,0,40], ["len"]], 10]
print of loop_cap.error.file
print of callable.error.file
EIGS
SANDBOX_OUT=$(cd "$D" && "$BIN" sandbox-errors.eigs 2>&1); SANDBOX_RC=$?
OUT="$SANDBOX_OUT"
check 'sandbox loop-cap error has the stable synthesized file' '[ "$(head -n1 <<<"$SANDBOX_OUT")" = "<sandbox>" ]'
check 'sandbox callable-refusal error has the stable synthesized file' '[ "$(tail -n1 <<<"$SANDBOX_OUT")" = "<sandbox>" ]'
cat > "$D/deadlock-after-eval.eigs" <<'EIGS'
try:
    eval of "missing_eval_name"
catch ignored:
    x is 1
define da() as:
    return task_join of db_id
define db() as:
    return task_join of da_id
da_id is task_spawn of da
db_id is task_spawn of db
task_join of da_id
EIGS
DEADLOCK_OUT=$(cd "$D" && "$BIN" deadlock-after-eval.eigs 2>&1); DEADLOCK_RC=$?
OUT="$DEADLOCK_OUT"
check 'deadlock after caught eval reports the script file, not stale eval identity' 'grep -Fq "Error deadlock-after-eval.eigs:11: all tasks are blocked — deadlock" <<<"$DEADLOCK_OUT" && ! grep -Fq "Error <eval>:" <<<"$DEADLOCK_OUT"'
TEST_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SWEEP_OUT=$(cd "$TEST_ROOT" && EIGS_DIFF_NEW="$BIN" EIGS_DIFF_SWEEP_SELFTEST=1 bash tools/strict_differential.sh --no-baseline 2>&1); SWEEP_RC=$?
OUT="$SWEEP_OUT"
check 'strict sweep classifies a planted own-name raise under the source-bearing header' 'grep -Fxq "sweep-verdict-selftest: RAISED-OWN" <<<"$SWEEP_OUT"'
cat > "$D/eval.eigs" <<'EIGS'
eval of "x is [1] - 2"
EIGS
OUT=$(cd "$D" && "$BIN" eval.eigs 2>&1); RC3=$?
check 'eval source uses the stable synthetic name in header and frame' 'grep -Fq "Error <eval>:1:" <<<"$OUT" && grep -Fq "at <module> (<eval>:1)" <<<"$OUT"'
cat > "$D/imported.eigs" <<'EIGS'
define cached_boom() as:
    x is [1] - 2
EIGS
printf 'import imported\nimported.cached_boom of null\n' > "$D/import-main.eigs"
OUT=$(cd "$D" && "$BIN" import-main.eigs 2>&1); RC4=$?
IMPORTED=$(cd "$D" && realpath imported.eigs)
check 'imported module header retains the resolved module identity' 'grep -Fq "Error $IMPORTED:2:" <<<"$OUT"'
check 'imported closure and caller frames retain distinct identities' 'grep -Fq "at cached_boom ($IMPORTED:2)" <<<"$OUT" && grep -Fq "at <module> (import-main.eigs:2)" <<<"$OUT"'
printf 'issue-1651: %d passed, %d failed\n' "$pass" "$fail"
[ "$RC" -eq 1 ] && [ "$RC2" -eq 0 ] && [ "$SANDBOX_RC" -eq 0 ] &&
    [ "$DEADLOCK_RC" -eq 1 ] && [ "$SWEEP_RC" -eq 0 ] && [ "$RC3" -eq 1 ] &&
    [ "$RC4" -eq 1 ] && [ "$fail" -eq 0 ]
