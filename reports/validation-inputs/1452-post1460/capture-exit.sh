#!/usr/bin/env bash
# Operator-only wrapper: preserve the sourced runner's $0 and intercept exit
# only in its top-level Bash process. Never export the exit function.
runner=$1
capture=$2
exec bash -c '
    readonly __counter_capture_pid=$BASHPID
    readonly __counter_capture_file=$2
    readonly __counter_capture_runner=$1
    shift 2
    __counter_capture() {
        printf "FINAL_COUNTERS rc=%s PASS=%s TOTAL=%s FAIL=%s SKIPPED=%s LEAKED=%s\n" \
            "$1" "${PASS-unset}" "${TOTAL-unset}" "${FAIL-unset}" \
            "${SKIPPED-unset}" "${LEAKED-unset}" >> "$__counter_capture_file"
    }
    exit() {
        local __counter_exit_status=$?
        if [ "$#" -gt 0 ]; then
            __counter_exit_status=$1
        fi
        if [ "$BASHPID" = "$__counter_capture_pid" ]; then
            __counter_capture "$__counter_exit_status"
        fi
        if [ "$#" -gt 0 ]; then
            builtin exit "$@"
        else
            builtin exit "$__counter_exit_status"
        fi
    }
    source "$__counter_capture_runner" "$@"
    __counter_source_status=$?
    __counter_capture "$__counter_source_status"
    builtin exit "$__counter_source_status"
' "$runner" "$runner" "$capture" "${@:3}"
