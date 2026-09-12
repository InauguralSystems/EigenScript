# Small Bash 3-compatible helpers for test_sigusr1_dump.sh's owned child.
# No process-name searches, new session, or timeout utility dependency.
sigusr1_replace_sentinel() {
    local file=$1 marker=$2 sentinel=$3
    if ! sed -i.bak "s|$marker|$sentinel|g" "$file"; then
        echo "FAIL: sigusr1: sentinel substitution failed" >&2
        return 1
    fi
    rm -f "$file.bak"
    if grep -qF "$marker" "$file"; then
        echo "FAIL: sigusr1: sentinel placeholder remains" >&2
        return 1
    fi
}

sigusr1_running() {
    local wanted=$1 child
    # Bash retains the status for wait even after reaping. Consult our job
    # table, not kill -0 on a PID that might already have been reused.
    for child in $(jobs -pr; jobs -ps); do [ "$child" = "$wanted" ] && return 0; done
    return 1
}

sigusr1_stop() {
    local child=$1 i
    if sigusr1_running "$child"; then kill -TERM "$child" 2>/dev/null || true; fi
    for ((i=0; i<20; i++)); do
        sigusr1_running "$child" || { wait "$child" 2>/dev/null; return 0; }
        sleep 0.1
    done
    if sigusr1_running "$child"; then kill -KILL "$child" 2>/dev/null || true; fi
    for ((i=0; i<20; i++)); do
        sigusr1_running "$child" || { wait "$child" 2>/dev/null; return 0; }
        sleep 0.1
    done
    echo "FAIL: sigusr1: owned child did not stop after KILL" >&2
    return 1
}

sigusr1_wait() {
    local child=$1 tenths=$2 i
    for ((i=0; i<tenths; i++)); do
        if ! sigusr1_running "$child"; then wait "$child"; return $?; fi
        sleep 0.1
    done
    echo "FAIL: sigusr1: child did not exit after DONE" >&2
    sigusr1_stop "$child" || return 125
    return 124
}

sigusr1_result_check() {
    local output=$1 status=$2 closed second
    SIGUSR1_PASS=$(printf '%s\n' "$output" | grep -c '^PASS: ' || true)
    SIGUSR1_FAIL=$(printf '%s\n' "$output" | grep -c '^FAIL: ' || true)
    if [ "$status" -ne 0 ]; then echo "sigusr1 result: child exit $status" >&2; return 1; fi
    if [ "$SIGUSR1_FAIL" -ne 0 ]; then echo "sigusr1 result: failed assertions" >&2; return 1; fi
    closed=$(printf '%s\n' "$output" | grep -c '^PASS: sigusr1: gated first dump declares absence of data (not equilibrium)$' || true)
    second=$(printf '%s\n' "$output" | grep -c '^PASS: sigusr1: second dump arrived after the gate armed$' || true)
    local expected matches clean leak
    while IFS= read -r expected; do
        matches=$(printf '%s\n' "$output" | grep -cFx "PASS: $expected" || true)
        if [ "$matches" -ne 1 ]; then echo "sigusr1 result: missing/duplicate assertion: $expected" >&2; return 1; fi
    done <<'CHECKS'
sigusr1: child reached its loop (READY barrier)
sigusr1: dump arrived at a loop safepoint
sigusr1: module row shape (name|value|when|entropy|dH|trajectory) with settled when
sigusr1: live-frame row with fresh when=1 binding (distinguishable from settled)
sigusr1: fn-local row carries its accumulated when count
sigusr1: program completed (DONE) after the dump
sigusr1: exit code 0 after the dump
sigusr1: no sanitizer report (single-thread run)
sigusr1-mt: child reached its loop with a task live
sigusr1-mt: dump arrived under a live task
sigusr1-mt: module row shape with settled when
sigusr1-mt: program completed (DONE) after the dump
CHECKS
    clean=$(printf '%s\n' "$output" | grep -cFx 'PASS: sigusr1-mt: clean exit after the dump' || true)
    leak=$(printf '%s\n' "$output" | grep -cFx 'PASS: sigusr1-mt: LeakSanitizer nonzero exit (known spawn-thread leak shape; tolerated like rc_ok)' || true)
    if [ "$((clean+leak))" -ne 1 ]; then echo "sigusr1 result: missing/duplicate task exit assertion" >&2; return 1; fi
    # Source has eight unconditional single-thread + five task-live checks;
    # a closed observer gate adds exactly these two first/second-dump checks.
    if ! { [ "$closed" -eq 0 ] && [ "$second" -eq 0 ] && [ "$SIGUSR1_PASS" -eq 13 ]; } &&
       ! { [ "$closed" -eq 1 ] && [ "$second" -eq 1 ] && [ "$SIGUSR1_PASS" -eq 15 ]; }; then
        echo "sigusr1 result: incomplete check population" >&2
        return 1
    fi
}
