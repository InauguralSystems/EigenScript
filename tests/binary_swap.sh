# [99d] runs in a subshell so its restoration traps cannot replace suite traps.
# Move the original directory entry aside: copying it would lose hard-link
# identity, and recreating a symlink would lose the original symlink inode.
eigs_binary_swap_selftest() (
    local scratch="" status
    restore_binary() {
        trap '' HUP INT TERM
        if [ -n "$scratch" ]; then
            if [ -e "$scratch/original" ] || [ -L "$scratch/original" ]; then
                mv -f "$scratch/original" "$EIGS_BIN" || return 1
            fi
            rm -f "$scratch/modified" || return 1
            rmdir "$scratch" || return 1
        fi
    }
    trap 'status=$?; trap - EXIT; restore_binary || status=125; exit "$status"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    record_binary_fingerprint
    check_eigs_suite "binary-guard self-test block" "test_gen0_baseline.eigs" "T01" 1
    scratch=$(mktemp -d "${EIGS_BIN}.swap.XXXXXX") || exit 125
    cp -p "$EIGS_BIN" "$scratch/modified" || exit 125
    printf '\n' >> "$scratch/modified" || exit 125
    mv "$EIGS_BIN" "$scratch/original" || exit 125
    mv "$scratch/modified" "$EIGS_BIN" || exit 125
    # Replacement is deliberately synchronous: the guard observes the same
    # mid-run change without a sleeping background writer racing restoration.
    check_binary_fingerprint
    echo "SELFTEST_REACHED_END"
)
