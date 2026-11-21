echo "[0fz] Internal double-to-integer residue (#1758 R2.6, #1746)"
# Under the ASan/UBSan lanes (-fsanitize=float-cast-overflow) the `at`/`when`
# rows are also the witness that no undefined double-to-int cast remains.
check_eigs_suite "at/when, audio counts, pcm16 and gradient selectors" test_phase2_r26_residue.eigs '^Tests: 35 | Pass: 35 | Fail: 0$'
echo ""
