#!/bin/bash
# Shared discovery/materialisation for tests/sections/*.sh.  Runtime sourcing
# and static gates must use the same bytewise filename order.
test_section_files() {
    local root="$1"
    find "$root/tests/sections" -maxdepth 1 -type f -name '*.sh' -print 2>/dev/null | LC_ALL=C sort
}

materialize_test_runner() { # root output
    local root="$1" out="$2" runner="$1/tests/run_all_tests.sh" line end fragment
    line=$(grep -n '^# EIGS_SECTION_FRAGMENTS$' "$runner" | cut -d: -f1)
    end=$(grep -n '^# EIGS_SECTION_FRAGMENTS_END$' "$runner" | cut -d: -f1)
    [ "$(printf '%s\n' "$line" | grep -c '[0-9]')" = 1 ] &&
        [ "$(printf '%s\n' "$end" | grep -c '[0-9]')" = 1 ] && [ "$end" -gt "$line" ] || {
        echo "test-section-files: expected one ordered fragment marker pair in $runner" >&2; return 1; }
    sed -n "1,${line}p" "$runner" > "$out" || return 1
    while IFS= read -r fragment; do
        [ -n "$fragment" ] || continue
        printf '\n# EIGS_SECTION_FRAGMENT: %s\n' "${fragment#$root/}" >> "$out"
        cat "$fragment" >> "$out" || return 1
    done <<EOF_FRAGMENTS
$(test_section_files "$root")
EOF_FRAGMENTS
    # Drop the runtime discovery loop, retaining the end marker as provenance.
    sed -n "${end},\$p" "$runner" >> "$out" || return 1
}
