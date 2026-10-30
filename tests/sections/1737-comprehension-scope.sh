echo "[1737] Comprehension and catch lexical binders (#1737; interpreter/default/OSR)"
for tier in "EIGS_JIT_OFF=1" "" "EIGS_JIT_OSR_THRESHOLD=1"; do
    case "$tier" in
        EIGS_JIT_OFF=1)
            EIGS_JIT_OFF=1 check_eigs_suite "interpreter: lexical comprehension/catch binders (#1737)" \
                test_comprehension_scope_1737.eigs "All tests passed" ;;
        EIGS_JIT_OSR_THRESHOLD=1)
            EIGS_JIT_OSR_THRESHOLD=1 check_eigs_suite "OSR: lexical comprehension/catch binders (#1737)" \
                test_comprehension_scope_1737.eigs "All tests passed" ;;
        *)
            check_eigs_suite "default JIT: lexical comprehension/catch binders (#1737)" \
                test_comprehension_scope_1737.eigs "All tests passed" ;;
    esac
done
echo ""
