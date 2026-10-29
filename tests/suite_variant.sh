# tests/suite_variant.sh -- which build the suite binary is (sourced; cwd is
# src/, as for every section).
#
# One predicate for sections that build a C test against the suite binary's
# own variant. They used to look only for build/asan, so CI's asan-server
# shards compiled their RELEASE variant: no ASan, LSan, or UBSan (#1783).
#
# suite_binary_variant: print the build/<variant> whose eigenscript the suite
#   binary ./eigenscript is (a hard link: the same file); print nothing when
#   it is none of them.
# suite_variant_is_asan VARIANT: the Makefile builds VARIANT with
#   AddressSanitizer -- asked of the build system (`make print-FLAGS_<v>`),
#   not inferred from the name.
suite_binary_variant() {
    for sbv_cand in ../build/*/eigenscript; do
        if [ -f "$sbv_cand" ] && [ ./eigenscript -ef "$sbv_cand" ]; then
            basename "$(dirname "$sbv_cand")"
            return 0
        fi
    done
    return 0
}
suite_variant_is_asan() {
    [ -n "$1" ] || return 1
    sva_flags=$(make -s --no-print-directory -C .. "print-FLAGS_$1" 2>/dev/null)
    case "$sva_flags" in
        *sanitize=address*) return 0 ;;
    esac
    return 1
}
