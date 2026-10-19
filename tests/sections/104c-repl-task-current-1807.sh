# [104c] #1807: each REPL line is a separate outermost evaluation.  A worker
# that ended the preceding line must not remain the scheduler's current task.
echo "[104c] REPL task identity resets between evaluations (#1807)"

repl1807_out=$(printf '%s\n' \
    'w is task_spawn of (() => 7)' \
    'task_yield of null' \
    'print of f"joined={task_join of w}"' \
    'print of f"self={task_self of null}"' \
    'define detached_worker() as:' \
    '    task_detach of (task_self of null)' \
    '    return 11' \
    'd is task_spawn of detached_worker' \
    'task_yield of null' \
    'print of f"detached_self={task_self of null}"' |
    $EIGS_TMO ./eigenscript 2>&1)
repl1807_rc=$?
TOTAL=$((TOTAL + 1))
repl1807_bad=""
[ "$repl1807_rc" -eq 0 ] || repl1807_bad="exit $repl1807_rc"
grep -qF 'joined=7' <<< "$repl1807_out" || repl1807_bad="${repl1807_bad:+$repl1807_bad; }join did not return 7"
grep -qF 'self=0' <<< "$repl1807_out" || repl1807_bad="${repl1807_bad:+$repl1807_bad; }task_self was not main"
grep -qF 'detached_self=0' <<< "$repl1807_out" || repl1807_bad="${repl1807_bad:+$repl1807_bad; }main did not survive yield after detached reap"
grep -qE 'Sanitizer|runtime error:' <<< "$repl1807_out" && repl1807_bad="${repl1807_bad:+$repl1807_bad; }sanitizer diagnostic"
if [ -z "$repl1807_bad" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: join, task_self, and detached reap preserve main across REPL evals"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: REPL scheduler current leaked across evals ($repl1807_bad)"
    printf '%s\n' "$repl1807_out" | sed 's/^/      /'
fi
unset repl1807_out repl1807_rc repl1807_bad
echo ""
