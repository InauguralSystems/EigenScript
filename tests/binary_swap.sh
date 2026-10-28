# [99d] runs in a subshell so its restoration traps cannot replace suite traps.
# Issue #1708 was environmental interference, not a silent #681 guard: before
# #1986 the suite left the build lock free, so another make could re-point the
# alias during this control.  The suite-wide lock now isolates this synchronous
# mutation, the standard deterministic-test pattern.
# Move the original directory entry aside: copying it would lose hard-link
# identity, and recreating a symlink would lose the original symlink inode.
eigs_binary_swap_selftest() (
    # Bash 3 unwinds function locals before running the EXIT trap. This
    # function already has its own subshell, so cleanup state can live there.
    scratch="" status=0
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
    # Signal-path controls need an ordering stronger than a sleep: publish the
    # restoration subshell only after its traps and baseline are in place.
    # The external controller then waits for the replacement marker below
    # before delivering its signal (#2133).
    if [ -n "${EIGS_SWAP_ARMED_FILE:-}" ]; then
        printf '%s\n' "$BASHPID" > "$EIGS_SWAP_ARMED_FILE.tmp" || exit 125
        mv "$EIGS_SWAP_ARMED_FILE.tmp" "$EIGS_SWAP_ARMED_FILE" || exit 125
    fi
    check_eigs_suite "binary-guard self-test block" "test_gen0_baseline.eigs" "T01" 1
    scratch=$(mktemp -d "${EIGS_BIN}.swap.XXXXXX") || exit 125
    cp -p "$EIGS_BIN" "$scratch/modified" || exit 125
    printf '\n' >> "$scratch/modified" || exit 125
    mv "$EIGS_BIN" "$scratch/original" || exit 125
    mv "$scratch/modified" "$EIGS_BIN" || exit 125
    if [ -n "${EIGS_SWAP_REPLACED_FILE:-}" ]; then
        : > "$EIGS_SWAP_REPLACED_FILE" || exit 125
        # The controller creates SENT only after kill(2) has accepted the
        # signal.  Thus reaching the fingerprint check cannot outrun it.
        while [ ! -e "$EIGS_SWAP_SENT_FILE" ]; do sleep 0.01; done
    fi
    # Replacement is deliberately synchronous: the guard observes the same
    # mid-run change without a sleeping background writer racing restoration.
    check_binary_fingerprint
    echo "SELFTEST_REACHED_END"
)
