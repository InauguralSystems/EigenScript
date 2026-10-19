echo "[104c] Worker-thread schedulers preserve unobserved task deaths (#1810)"

issue1810_check() {
    local name="$1" file="$2" want_rc="$3" out rc bad=""
    shift 3
    check_binary_fingerprint
    out=$($EIGS_TMO ./eigenscript "../tests/$file" </dev/null 2>&1); rc=$?
    TOTAL=$((TOTAL + 1))
    [ "$rc" -eq "$want_rc" ] || bad="rc=$rc, want $want_rc"
    while [ "$#" -gt 0 ]; do
        grep -qF -- "$1" <<< "$out" || bad="${bad:+$bad; }missing '$1'"
        shift
    done
    grep -qE "Sanitizer|runtime error:" <<< "$out" && bad="${bad:+$bad; }sanitizer diagnostic"
    if [ -z "$bad" ]; then
        PASS=$((PASS + 1)); echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $name ($bad)"
        sed 's/^/      /' <<< "$out"
    fi
}

issue1810_check "unjoined task death on a worker fails the process" \
    task_exit_worker_unjoined_task.eigs 1 \
    "WORKER_AFTER_YIELD" "MAIN_JOINED 1" "MARK_END"
issue1810_check "a worker can join and catch its task's error" \
    task_exit_worker_joined_task.eigs 0 \
    "WORKER_CAUGHT undefined_name" "MAIN_JOINED 1" "MARK_END"

unset -f issue1810_check
echo ""
