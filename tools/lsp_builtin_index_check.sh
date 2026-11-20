#!/usr/bin/env bash
# Keep the committed review artifact identical to its generator (#2387).
set -u
cd "$(dirname "$0")/.." || exit 2

check_index() {
    local generated line
    generated=$(mktemp "${TMPDIR:-/tmp}/eigs_lsp_builtin.XXXXXX") || return 2
    bash tools/gen_lsp_builtin_index.sh "$generated" >/dev/null || { rm -f "$generated"; return 1; }
    if cmp -s "$generated" src/lsp_builtin_index.h; then
        echo "lsp-builtin-index: OK: committed header matches generator"
        rm -f "$generated"
        return 0
    fi
    line=$(cmp "$generated" src/lsp_builtin_index.h 2>&1 | sed -n 's/.* line \([0-9][0-9]*\)$/\1/p')
    echo "FAIL: src/lsp_builtin_index.h differs from generator at first differing line ${line:-unknown}" >&2
    [ -z "$line" ] || {
        sed -n "${line}p" "$generated" | sed 's/^/  generated: /' >&2
        sed -n "${line}p" src/lsp_builtin_index.h | sed 's/^/  committed: /' >&2
    }
    rm -f "$generated"
    return 1
}

if [ "${1:-}" = --selftest ]; then
    [ "$#" -eq 1 ] || exit 2
    original=$(mktemp "${TMPDIR:-/tmp}/eigs_lsp_header.XXXXXX") || exit 2
    cp src/lsp_builtin_index.h "$original" || exit 2
    trap 'cp "$original" src/lsp_builtin_index.h; rm -f "$original"' EXIT
    pass=0
    check_index >/dev/null && { echo "  PASS: clean generated index"; pass=$((pass + 1)); }
    awk '!planted && /\{"/ { sub(/\{"/, "{\"planted_2387_"); planted=1 } { print }' \
        "$original" > src/lsp_builtin_index.h
    out=$(check_index 2>&1); rc=$?
    [ "$rc" -ne 0 ] && case "$out" in *"first differing line"*) echo "  PASS: committed-header plant caught"; pass=$((pass + 1));; esac
    cp "$original" src/lsp_builtin_index.h
    source_file=src/builtins.c
    source_original=$(mktemp "${TMPDIR:-/tmp}/eigs_lsp_source.XXXXXX") || exit 2
    cp "$source_file" "$source_original"
    awk '!removed && /\/\* type of value/ { removed=1; next } { print }' "$source_original" > "$source_file"
    out=$(check_index 2>&1); rc=$?
    cp "$source_original" "$source_file"; rm -f "$source_original"
    [ "$rc" -ne 0 ] && case "$out" in *"first differing line"*) echo "  PASS: signature-comment plant caught"; pass=$((pass + 1));; esac
    echo "lsp-builtin-index selftest: $pass passed, $((3-pass)) failed"
    [ "$pass" -eq 3 ]
    exit
fi
[ "$#" -eq 0 ] || { echo "usage: $0 [--selftest]" >&2; exit 2; }
check_index
