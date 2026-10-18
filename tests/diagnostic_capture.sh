# Capture the two suite diagnostics without sharing a fixed stderr filename.
# The caller's EXIT cleanup must call suite_diagnostic_cleanup as well.
SUITE_DIAGNOSTIC_FILE=

suite_diagnostic_cleanup() {
    if [ -n "${SUITE_DIAGNOSTIC_FILE:-}" ]; then
        rm -f "$SUITE_DIAGNOSTIC_FILE" || return 1
        SUITE_DIAGNOSTIC_FILE=
    fi
}

# Return setup/read/cleanup failure separately from the command's exit code.
# Command results are in SUITE_DIAGNOSTIC_OUT, _ERR and _RC on success.
# These result variables are read by the caller that sources this helper.
# shellcheck disable=SC2034
suite_capture_diagnostic() {
    local label="$1"
    shift
    suite_diagnostic_cleanup || return 1
    SUITE_DIAGNOSTIC_OUT=
    SUITE_DIAGNOSTIC_ERR=
    SUITE_DIAGNOSTIC_RC=
    SUITE_DIAGNOSTIC_FILE=$(mktemp "${TMPDIR:-/tmp}/eigs-${label}.XXXXXX") || {
        echo "diagnostic capture ($label): cannot create temporary stderr file" >&2
        return 1
    }

    # Opening the file belongs to the group, not to the captured command.
    # Thus a redirection failure cannot become a supposed runtime exit code.
    # The group restores the caller's fd 3; the child inherits only stderr.
    if {
        SUITE_DIAGNOSTIC_OUT=$("$@" </dev/null 2>&3 3>&-)
        SUITE_DIAGNOSTIC_RC=$?
    } 3>"$SUITE_DIAGNOSTIC_FILE"; then
        if ! SUITE_DIAGNOSTIC_ERR=$(cat "$SUITE_DIAGNOSTIC_FILE"); then
            echo "diagnostic capture ($label): cannot read temporary stderr file" >&2
            suite_diagnostic_cleanup
            return 1
        fi
    else
        echo "diagnostic capture ($label): cannot open temporary stderr file" >&2
        suite_diagnostic_cleanup
        return 1
    fi
    if ! suite_diagnostic_cleanup; then
        echo "diagnostic capture ($label): cannot remove temporary stderr file" >&2
        return 1
    fi
}
