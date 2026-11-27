echo "[0f9b] sandbox_run: a caught error does not fix later errors' kind (#2538; EIGS_STRICT unset/0/1)"
check_eigs_suite "sandbox caught error: EIGS_STRICT unset" test_sandbox_caught_error_2538.eigs "All tests passed."
EIGS_STRICT=0 check_eigs_suite "sandbox caught error: EIGS_STRICT=0" test_sandbox_caught_error_2538.eigs "All tests passed."
EIGS_STRICT=1 check_eigs_suite "sandbox caught error: EIGS_STRICT=1" test_sandbox_caught_error_2538.eigs "All tests passed."
