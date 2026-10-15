#!/bin/bash
# Shell-only controls: no EigenScript runtime or security workload is run.
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
. "$ROOT/tests/diagnostic_capture.sh" || exit 1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-diagnostic-test.XXXXXX") || exit 1
trap 'suite_diagnostic_cleanup; rm -rf "$WORK"' EXIT
FAIL=0

check() {
    if "$@"; then
        echo "PASS: $CASE"
    else
        echo "FAIL: $CASE"
        FAIL=$((FAIL + 1))
    fi
}

temp_case() (
    local mode="$1" expected first second path
    case "$mode" in
        unset) unset TMPDIR; expected=/tmp ;;
        empty) TMPDIR=; expected=/tmp ;;
        explicit) TMPDIR="$WORK/explicit"; expected=$TMPDIR ;;
        spaces) TMPDIR="$WORK/directory with spaces"; expected=$TMPDIR ;;
    esac
    mkdir -p "$expected" || exit 1
    local paths="$WORK/$mode.paths" calls="$WORK/$mode.calls"
    # Use real mktemp, recording its actual filenames to check ownership,
    # uniqueness and cleanup rather than predicting the random suffix.
    mktemp() {
        local made
        made=$(command mktemp "$@") || return 1
        [ -f "$made" ] && [ -w "$made" ] || return 1
        printf '%s\n' "$made" >> "$paths"
        printf '%s\n' "$made"
    }
    # Passed by name to suite_capture_diagnostic, which invokes its arguments.
    # shellcheck disable=SC2329
    fake_command() {
        # The capture must not leak its extra descriptor or read caller stdin.
        if ( : >&3 ) 2>/dev/null; then return 98; fi
        if IFS= read -r; then return 99; fi
        printf 'ran\n' >> "$calls"
        printf 'stdout %s' "$1"
        printf 'stderr %s' "$2" >&2
        return 7
    }
    exec 3>"$WORK/$mode.fd"
    suite_capture_diagnostic host-frame fake_command 'two words' separate || exit 1
    [ "$SUITE_DIAGNOSTIC_OUT" = 'stdout two words' ] || exit 1
    [ "$SUITE_DIAGNOSTIC_ERR" = 'stderr separate' ] || exit 1
    [ "$SUITE_DIAGNOSTIC_RC" -eq 7 ] || exit 1
    printf 'preserved' >&3
    exec 3>&-
    [ "$(cat "$WORK/$mode.fd")" = preserved ] || exit 1
    suite_capture_diagnostic sandbox-1426 printf next || exit 1
    [ "$SUITE_DIAGNOSTIC_OUT" = next ] || exit 1
    [ -z "$SUITE_DIAGNOSTIC_ERR" ] || exit 1
    [ "$SUITE_DIAGNOSTIC_RC" -eq 0 ] || exit 1
    first=$(sed -n '1p' "$paths")
    second=$(sed -n '2p' "$paths")
    [ -n "$first" ] && [ -n "$second" ] && [ "$first" != "$second" ] || exit 1
    [ "$(wc -l < "$paths")" -eq 2 ] || exit 1
    while IFS= read -r path; do
        case "$path" in "$expected"/eigs-*) ;; *) exit 1 ;; esac
        [ ! -e "$path" ] || exit 1
    done < "$paths"
    [ -z "$SUITE_DIAGNOSTIC_FILE" ] || exit 1
    [ "$(cat "$calls")" = ran ] || exit 1
)

failure_case() (
    local mode="$1" calls="$WORK/$1.calls"
    # Passed by name to suite_capture_diagnostic, which must not invoke it.
    # shellcheck disable=SC2329
    fake_command() { printf 'ran\n' > "$calls"; }
    case "$mode" in
        allocation) mktemp() { return 1; } ;;
        redirection) mktemp() { printf '%s\n' "$WORK/missing-parent/stderr"; } ;;
    esac
    if suite_capture_diagnostic failure fake_command 2>"$WORK/$mode.err"; then exit 1; fi
    [ ! -e "$calls" ] || exit 1
    [ -z "$SUITE_DIAGNOSTIC_RC" ] || exit 1
    grep -q "diagnostic capture (failure): cannot" "$WORK/$mode.err"
)

cleanup_case() (
    local pending="$WORK/pending" ledger="$WORK/ledger" status=0
    : > "$pending"
    : > "$ledger"
    (
        SUITE_DIAGNOSTIC_FILE=$pending
        CHILD_LEDGER=$ledger
        trap 'rm -f "${CHILD_LEDGER:-}"; suite_diagnostic_cleanup' EXIT
        exit 9
    ) || status=$?
    [ "$status" -eq 9 ] && [ ! -e "$pending" ] && [ ! -e "$ledger" ]
)

for mode in unset empty explicit spaces; do
    CASE="TMPDIR $mode: unique owned files, streams/status, fd restoration and cleanup"
    check temp_case "$mode"
done
for mode in allocation redirection; do
    CASE="$mode failure prevents command execution"
    check failure_case "$mode"
done
CASE="EXIT cleanup preserves the original status and child-ledger cleanup"
check cleanup_case
[ "$FAIL" -eq 0 ]
