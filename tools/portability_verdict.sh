#!/bin/bash
# Shared caller-side verdict for portability_parse_check.sh.  The producer's
# rc is not sufficient: its identity and exactly one terminal verdict are part
# of the receipt (#1355).  Sets PORT_VERDICT and PORT_VERDICT_REASON.
PORT_OLD_MAJOR_MAX=3
portability_verdict() { # <rc> <captured output> [kernel-name]
    local rc="$1" out="$2" kernel="${3:-$(uname -s)}" major ok skip
    ok=$(printf '%s\n' "$out" | grep -c '^portability: OK:' || true)
    skip=$(printf '%s\n' "$out" | grep -c '^portability-parse: SKIPPED' || true)
    major=$(printf '%s\n' "$out" | sed -n 's/^portability-parse: oracle-major=\([0-9][0-9]*\)$/\1/p' | head -1)
    PORT_VERDICT=FAIL; PORT_VERDICT_REASON="portability gate exited $rc"
    if [ "$rc" -ne 0 ]; then return; fi
    if [ "$ok" -eq 0 ] && [ "$skip" -eq 0 ]; then
        PORT_VERDICT_REASON="portability gate exited 0 without a verdict line"
    elif [ "$ok" -ne 0 ] && [ "$skip" -ne 0 ]; then
        PORT_VERDICT_REASON="portability gate printed both completed and skipped verdicts"
    elif { [ "$ok" -gt 0 ] && [ "$ok" -ne 1 ]; } || { [ "$skip" -gt 0 ] && [ "$skip" -ne 1 ]; }; then
        PORT_VERDICT_REASON="portability gate printed a duplicate verdict"
    elif [ "$ok" -eq 1 ] && [ -z "$major" ]; then
        PORT_VERDICT_REASON="completed portability audit omitted oracle-major identity"
    elif [ "$ok" -eq 1 ] && [ "$major" -gt "$PORT_OLD_MAJOR_MAX" ]; then
        PORT_VERDICT_REASON="portability gate measured under bash $major, not bash <= $PORT_OLD_MAJOR_MAX"
    elif [ "$skip" -eq 1 ] && [ "$kernel" = Darwin ]; then
        PORT_VERDICT_REASON="portability gate skipped on Darwin, where /bin/bash is the old-shell oracle"
    elif [ "$skip" -eq 1 ]; then
        PORT_VERDICT=SKIP; PORT_VERDICT_REASON="portability audit announced no old-shell oracle"
    else
        PORT_VERDICT=PASS; PORT_VERDICT_REASON="portability audit receipt accepted"
    fi
}
