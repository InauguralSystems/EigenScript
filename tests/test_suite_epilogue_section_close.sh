#!/usr/bin/env bash
set -u

runner=${1:-"$(dirname "$0")/run_all_tests.sh"}

check_runner() {
    awk '
        /# Final guard \(#681\)/ { epilogue = 1 }
        epilogue && /__eigs_section_close/ && !close_line { close_line = NR }
        epilogue && /tools\/lsan_baseline_check\.sh/ && !lsan_line { lsan_line = NR }
        END { exit !(close_line && lsan_line && close_line < lsan_line) }
    ' "$1"
}

if [ "${1:-}" = "--selftest" ]; then
    runner="$(dirname "$0")/run_all_tests.sh"
    tmp=$(mktemp "${TMPDIR:-/tmp}/eigs-1589.XXXXXX") || exit 1
    trap 'rm -f "$tmp"' EXIT HUP INT TERM
    if check_runner "$runner"; then
        echo "  PASS: final selected section closes before shared epilogue assertions"
    else
        echo "  FAIL: clean runner counts a shared epilogue assertion in the final section"
        exit 1
    fi
    awk '
        /# Close the timer on the final selected section/ { move = 1 }
        move && /__eigs_section_close/ { saved = $0; move = 0; next }
        { print }
        /rm -f "\$TOLERATED_LSAN_REPORTS"/ { print saved }
    ' "$runner" > "$tmp"
    if check_runner "$tmp"; then
        echo "  FAIL: planted late section close was not rejected"
        exit 1
    fi
    echo "  PASS: planted late section close is rejected"
    echo "SELFTEST: 2 passed, 0 failed"
    exit 0
fi

if check_runner "$runner"; then
    echo "PASS: shared epilogue assertions are outside selected section accounting"
else
    echo "FAIL: final selected section closes after shared epilogue assertions"
    exit 1
fi
