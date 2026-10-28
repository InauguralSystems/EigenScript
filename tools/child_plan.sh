#!/usr/bin/env bash
# Shared child-plan verdict. Callers supply the child's complete output, status,
# and the row's declared extended-regexp markers.
child_plan_ok() { # output rc pass-regexp fail-regexp
    local _out="$1" _rc="$2" _pass_re="$3" _fail_re="$4" _lines
    CHILD_PLAN=""; CHILD_PASS=0; CHILD_FAIL=0; CHILD_PLAN_ERROR=""
    _lines=$(printf '%s\n' "$_out" | sed -n 's/^PLAN: \([0-9][0-9]*\)$/\1/p')
    if [ -z "$_lines" ] || [ "$_lines" != "${_lines%%$'\n'*}" ]; then
        CHILD_PLAN_ERROR="missing or duplicate PLAN: N"; return 1
    fi
    CHILD_PLAN=$_lines
    CHILD_PASS=$(printf '%s\n' "$_out" | grep -cE "$_pass_re" || true)
    CHILD_FAIL=$(printf '%s\n' "$_out" | grep -cE "$_fail_re" || true)
    if [ "$_rc" -ne 0 ]; then CHILD_PLAN_ERROR="exit $_rc"
    elif [ "$CHILD_FAIL" -ne 0 ]; then CHILD_PLAN_ERROR="$CHILD_FAIL failed"
    elif [ "$CHILD_PASS" -ne "$CHILD_PLAN" ]; then CHILD_PLAN_ERROR="$CHILD_PASS/$CHILD_PLAN passed"
    else return 0; fi
    return 1
}
