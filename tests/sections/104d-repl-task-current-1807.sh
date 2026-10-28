# [104d] #1807: each REPL line is a separate outermost evaluation.  A worker
# that ended the preceding line must not remain the scheduler's current task.
echo "[104d] REPL task identity resets between evaluations (#1807)"
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
repl1807_results=$(sed 's/.*eigs> //' <<< "$repl1807_out")

repl1807_respawn_out=$(printf '%s\n' \
    'define detached_worker() as:' \
    '    task_detach of (task_self of null)' \
    '    return 11' \
    'd is task_spawn of detached_worker' \
    'task_yield of null' \
    'w2 is task_spawn of (() => 9)' \
    'task_yield of null' \
    'print of f"j2={task_join of w2}"' \
    'print of f"self2={task_self of null}"' |
    $EIGS_TMO ./eigenscript 2>&1)
repl1807_respawn_rc=$?
repl1807_respawn_results=$(sed 's/.*eigs> //' <<< "$repl1807_respawn_out")
TOTAL=$((TOTAL + 1))
repl1807_bad=""
[ "$repl1807_rc" -eq 0 ] || repl1807_bad="exit $repl1807_rc"
[ "$repl1807_respawn_rc" -eq 0 ] || repl1807_bad="${repl1807_bad:+$repl1807_bad; }respawn exit $repl1807_respawn_rc"
grep -qxF 'joined=7' <<< "$repl1807_results" || repl1807_bad="${repl1807_bad:+$repl1807_bad; }join did not return 7"
grep -qxF 'self=0' <<< "$repl1807_results" || repl1807_bad="${repl1807_bad:+$repl1807_bad; }task_self was not main"
grep -qxF 'detached_self=0' <<< "$repl1807_results" || repl1807_bad="${repl1807_bad:+$repl1807_bad; }main did not survive yield after detached reap"
grep -qxF 'j2=9' <<< "$repl1807_respawn_results" || repl1807_bad="${repl1807_bad:+$repl1807_bad; }second join did not return 9"
grep -qxF 'self2=0' <<< "$repl1807_respawn_results" || repl1807_bad="${repl1807_bad:+$repl1807_bad; }task_self was not restored after detached reap and respawn"
grep -qE 'Sanitizer|runtime error:' <<< "$repl1807_out$repl1807_respawn_out" && repl1807_bad="${repl1807_bad:+$repl1807_bad; }sanitizer diagnostic"
if [ -z "$repl1807_bad" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: joins, task_self, and detached reap preserve main across REPL evals"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: REPL scheduler current leaked across evals ($repl1807_bad)"
    printf '%s\n' "$repl1807_out" | sed 's/^/      /'
    printf '%s\n' "$repl1807_respawn_out" | sed 's/^/      /'
fi
unset repl1807_out repl1807_results repl1807_rc repl1807_respawn_out
unset repl1807_respawn_results repl1807_respawn_rc repl1807_bad

# #1806: a cooperative task's exit remains observable until the REPL consumes
# it. Piped stdin deliberately has another line: there must be no prompt for it.
repl1806_out=$(printf '%s\n' \
    'define quitter1806() as:' \
    '    exit of 6' \
    '' \
    'd is task_spawn of quitter1806' \
    'task_yield of null' \
    'print of "SECOND_LINE_RAN"' |
    $EIGS_TMO ./eigenscript 2>&1)
repl1806_rc=$?
repl1806_prompts=$(awk '{ n += gsub(/eigs> /, "") } END { print n + 0 }' <<< "$repl1806_out")
TOTAL=$((TOTAL + 1))
repl1806_bad=""
[ "$repl1806_rc" -eq 6 ] || repl1806_bad="exit $repl1806_rc, want 6"
[ "$repl1806_prompts" -eq 2 ] || repl1806_bad="${repl1806_bad:+$repl1806_bad; }$repl1806_prompts prompts, want 2"
grep -qF 'SECOND_LINE_RAN' <<< "$repl1806_out" && repl1806_bad="${repl1806_bad:+$repl1806_bad; }ran input after exit"
grep -qE 'Sanitizer|runtime error:' <<< "$repl1806_out" && repl1806_bad="${repl1806_bad:+$repl1806_bad; }sanitizer diagnostic"
if [ -z "$repl1806_bad" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: task exit returns status 6 without another REPL prompt"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: task exit was lost at the REPL boundary ($repl1806_bad)"
    printf '%s\n' "$repl1806_out" | sed 's/^/      /'
fi
unset repl1806_out repl1806_rc repl1806_prompts repl1806_bad
echo ""
