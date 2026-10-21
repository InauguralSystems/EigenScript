#!/bin/bash
# Display-only regressions: use captured diagnostics, without running a sanitizer.
set -o pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
. "$ROOT/tests/failure_output.sh" || exit 1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-failure-output.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
FAIL=0

check() {
    local name="$1"
    shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

long_report() {
    awk -v marker="$1" 'BEGIN {
        for (i = 1; i <= 25; i++) print "preamble " i
        print marker
        print "READ of size 8"
        for (i = 0; i < 12; i++)
            printf "    #%d 0x1234 in %s runtime.c:42\n", i, (i == 2 ? "slot_decref" : "frame_" i)
        for (i = 1; i <= 140; i++) print "shadow detail " i
        print "ABORTING"
    }'
}

long_case() {
    long_report "$1" > "$WORK/input" || return 1
    eigs_failure_output < "$WORK/input" > "$WORK/output" || return 1
    # The eighth frame is input line 35; the last 20 start at 161.
    # Keep the complete first trace, omit its later frames, and count the gap.
    awk '
        /ERROR: .*Sanitizer|WARNING: ThreadSanitizer/ { error++; error_line = NR }
        /#[0-7] 0x1234/ { frames++; if (NR < error_line) bad = 1 }
        /slot_decref/ { owner++ }
        /#8 0x1234/ { bad = 1 }
        /--- 125 captured lines elided ---/ { gap++; gap_line = NR }
        /^shadow detail 122$/ { tail++; if (NR < gap_line) bad = 1 }
        /^ABORTING$/ { ending++ }
        /captured 180 lines; 0 assertion matches; displayed 0 assertions/ { summary++ }
        END { exit !(error == 1 && frames == 8 && owner == 1 && gap == 1 &&
                     tail == 1 && ending == 1 && summary == 1 && !bad) }
    ' "$WORK/output"
}

ordinary_case() {
    {
        printf 'FAIL: one\n MISMATCH: two\nAssertionError: three\nFAIL: four\nFAIL: five\nFAIL: six\n'
        for ((i = 1; i <= 25; i++)); do printf 'ordinary %d\n' "$i"; done
    } > "$WORK/input"
    {
        printf '  --- assertion excerpts (first 5; complete lines) ---\n'
        printf 'FAIL: one\n MISMATCH: two\nAssertionError: three\nFAIL: four\nFAIL: five\n'
        printf '  --- captured tail (last 20 complete lines) ---\n'
        for ((i = 6; i <= 25; i++)); do printf 'ordinary %d\n' "$i"; done
        printf '  --- captured 31 lines; 6 assertion matches; displayed 5 assertions ---\n'
    } > "$WORK/expected"
    eigs_failure_output < "$WORK/input" > "$WORK/output" &&
        cmp -s "$WORK/expected" "$WORK/output"
}

empty_case() {
    cat > "$WORK/expected" <<'EOF'
  --- assertion excerpts (first 5; complete lines) ---
  --- captured tail (last 20 complete lines) ---
  --- captured 0 lines; 0 assertion matches; displayed 0 assertions ---
EOF
    eigs_failure_output < /dev/null > "$WORK/output" &&
        cmp -s "$WORK/expected" "$WORK/output"
}

complete_line_case() {
    # A long, colored ordinary line must remain byte-for-byte unchanged.
    awk 'BEGIN {
        printf "\033[31mFAIL: "
        for (i = 0; i < 10000; i++) printf "x"
        printf "\033[0m\n"
    }' > "$WORK/input"
    {
        printf '  --- assertion excerpts (first 5; complete lines) ---\n'
        printf '  --- captured tail (last 20 complete lines) ---\n'
        cat "$WORK/input"
        printf '  --- captured 1 lines; 0 assertion matches; displayed 0 assertions ---\n'
    } > "$WORK/expected"
    eigs_failure_output < "$WORK/input" > "$WORK/output" &&
        cmp -s "$WORK/expected" "$WORK/output"
}

overlap_case() {
    {
        printf '==42==ERROR: AddressSanitizer: example\n'
        for ((i = 0; i < 8; i++)); do printf '    #%d in frame_%d\n' "$i" "$i"; done
        for ((i = 1; i <= 15; i++)); do printf 'detail %d\n' "$i"; done
    } > "$WORK/input"
    eigs_failure_output < "$WORK/input" > "$WORK/output" || return 1
    # The first trace and tail overlap: their union is the entire input, once.
    awk '!/^  ---/' "$WORK/output" > "$WORK/payload"
    cmp -s "$WORK/input" "$WORK/payload" &&
        grep -Fxq '  --- 0 captured lines elided ---' "$WORK/output"
}

short_report_case() {
    {
        for ((i = 1; i <= 25; i++)); do printf 'preamble %d\n' "$i"; done
        printf 'ERROR: LeakSanitizer: example\n    #0 in slot_decref\nABORTING\n'
    } > "$WORK/input"
    eigs_failure_output < "$WORK/input" > "$WORK/output" || return 1
    # When the whole report is already in the tail, retain the preceding tail
    # lines too; adding a diagnostic head must not hide or duplicate them.
    tail -n 20 "$WORK/input" > "$WORK/expected"
    awk '!/^  ---/' "$WORK/output" > "$WORK/payload"
    cmp -s "$WORK/expected" "$WORK/payload"
}

no_frames_case() {
    {
        printf 'FATAL: ThreadSanitizer: example\n'
        for ((i = 1; i <= 199; i++)); do printf 'detail %d\n' "$i"; done
    } > "$WORK/input"
    eigs_failure_output < "$WORK/input" > "$WORK/output" || return 1
    # A malformed/frame-free report still has bounded head and tail windows.
    head -n 40 "$WORK/input" > "$WORK/expected"
    tail -n 20 "$WORK/input" >> "$WORK/expected"
    awk '!/^  ---/' "$WORK/output" > "$WORK/payload"
    cmp -s "$WORK/expected" "$WORK/payload" &&
        grep -Fxq '  --- 140 captured lines elided ---' "$WORK/output"
}

drain_case() {
    # More than a pipe buffer follows the useful frames. Under pipefail an
    # early reader exit fails this check, even if its displayed head was right.
    awk 'BEGIN {
        print "==42==ERROR: AddressSanitizer: example"
        for (i = 0; i < 8; i++) print "    #" i " in frame_" i
        for (i = 1; i <= 50000; i++) print "body " i
        print "end-of-stream witness"
    }' | eigs_failure_output > "$WORK/output" || return 1
    grep -Fxq 'end-of-stream witness' "$WORK/output" &&
        grep -Fxq '  --- captured 50010 lines; 0 assertion matches; displayed 0 assertions ---' "$WORK/output"
}

check 'ordinary assertions and tail are unchanged' ordinary_case
check 'empty capture is unchanged' empty_case
check 'complete colored ordinary lines are unchanged' complete_line_case
check 'long AddressSanitizer report keeps its first eight frames' long_case '==42==ERROR: AddressSanitizer: example'
check 'long LeakSanitizer report keeps its first eight frames' long_case '==42==ERROR: LeakSanitizer: example'
check 'long ThreadSanitizer error keeps its first eight frames' long_case 'ERROR: ThreadSanitizer: example'
check 'ThreadSanitizer warning keeps its first eight frames' long_case 'WARNING: ThreadSanitizer: example'
check 'colored sanitizer report keeps its first eight frames' long_case $'\033[1m\033[31m==42==ERROR: AddressSanitizer: example\033[0m'
check 'overlapping diagnostic and tail lines appear once' overlap_case
check 'a short report preserves the complete tail' short_report_case
check 'frame-free sanitizer reports have a bounded head' no_frames_case
check 'the formatter consumes the entire producer stream' drain_case
[ "$FAIL" -eq 0 ]
