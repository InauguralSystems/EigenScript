#!/bin/bash
# Stdlib / builtin discoverability gate (#393).
#
# Undiscoverable breadth is zero breadth: `regex_*` were registered but
# documented nowhere; `ord`/`chr`/`hex-of` were rediscovered late; `hex4`/`pad2`
# got hand-rolled downstream twice. This gate makes that failure class loud.
#
# Enforced (mechanically, cheap greps — the tractable, always-green-able core):
#   1. Every builtin registered in src/builtins.c is documented as a backticked
#      token in the reference docs (BUILTINS.md / SPEC.md / STDLIB.md).
#   2. Every lib/*.eigs MODULE has a heading in docs/STDLIB.md.
#
# NOT enforced: per-public-function coverage of every lib module. Many modules
# (physics, chemistry, geometry, ...) document their functions in the module
# header rather than a STDLIB.md table by deliberate convention; requiring a
# STDLIB.md row per public define would gate on ~500 rows and never go green.
# Module-level discoverability (rule 2) is the enforced floor there.
#
# Usage: tools/stdlib_index_check.sh [--selftest]
#   --selftest : inject a fake undocumented builtin and confirm the gate flags
#                it (proves the checker isn't vacuously green).
# Exit 0 = all documented; 1 = a gap (or selftest failure).

set -u
cd "$(dirname "$0")/.."

DOCS="docs/BUILTINS.md docs/SPEC.md docs/STDLIB.md"
drift=0

# --- backticked tokens across the reference docs (the "documented" set) ---
doc_tokens() { grep -rhoE '`[a-zA-Z_][a-zA-Z0-9_]*`' $DOCS | tr -d '`' | sort -u; }

# --- registered core builtins (the "must be documented" set) ---
registered_builtins() {
    grep -oE 'env_set_local_owned\(env, "[a-zA-Z_][a-zA-Z0-9_]*", make_builtin' src/builtins.c \
        | sed -E 's/.*"([^"]+)".*/\1/' | sort -u
}

check_builtins() {  # arg: optional extra (fake) builtin name for selftest
    local extra="${1:-}"
    local documented registered missing
    documented=$(doc_tokens)
    registered=$(registered_builtins)
    [ -n "$extra" ] && registered=$(printf '%s\n%s\n' "$registered" "$extra" | sort -u)
    missing=$(comm -23 <(printf '%s\n' "$registered") <(printf '%s\n' "$documented"))
    if [ -n "$missing" ]; then
        echo "UNDOCUMENTED BUILTINS (registered in src/builtins.c, absent from $DOCS):"
        echo "$missing" | sed 's/^/  - /'
        return 1
    fi
    return 0
}

check_lib_modules() {
    local rc=0 stem
    for m in lib/*.eigs; do
        stem=$(basename "$m" .eigs)
        if ! grep -q "lib/$stem" docs/STDLIB.md; then
            echo "UNDOCUMENTED MODULE: lib/$stem has no docs/STDLIB.md heading"
            rc=1
        fi
    done
    # No module may have more than one '### lib/<name>' heading — the index was
    # once assembled from two overlapping regions and four modules shipped twice.
    local dups
    dups=$(grep -oE '^### lib/[a-zA-Z0-9_]+\.eigs' docs/STDLIB.md | sort | uniq -d)
    if [ -n "$dups" ]; then
        echo "DUPLICATE STDLIB.md entries (each module heading must appear once):"
        echo "$dups" | sed 's/^### /  - /'
        rc=1
    fi
    return $rc
}

# --- selftest: the gate MUST catch a deliberately-undocumented builtin ---
if [ "${1:-}" = "--selftest" ]; then
    if check_builtins "zz_selftest_undocumented_probe" >/dev/null 2>&1; then
        echo "SELFTEST FAILED: gate did not flag an injected undocumented builtin"
        exit 1
    fi
    echo "SELFTEST OK: gate flags an injected undocumented builtin"
    exit 0
fi

check_builtins || drift=1
check_lib_modules || drift=1

if [ "$drift" -eq 0 ]; then
    echo "stdlib index OK: $(registered_builtins | wc -l | tr -d ' ') builtins + $(ls lib/*.eigs | wc -l | tr -d ' ') modules all documented"
fi
exit $drift
