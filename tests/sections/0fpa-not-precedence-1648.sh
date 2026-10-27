echo "[0fpa] not precedence (#1648)"
EIGS_JIT_OFF=1 check_eigs_suite "not precedence: interpreter tier" test_not_precedence.eigs "not precedence tests passed"
check_eigs_suite "not precedence: JIT tier" test_not_precedence.eigs "not precedence tests passed"
EIGS_JIT_OSR_THRESHOLD=1 check_eigs_suite "not precedence: OSR tier" test_not_precedence.eigs "not precedence tests passed"
