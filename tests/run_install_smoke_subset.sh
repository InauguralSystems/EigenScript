#!/bin/bash
# Focused installed-layout slice of the suite for install-smoke (#905).
# Keep this list to sections whose assertions load modules, resolve a module
# path, or build/run a bundle. The full suite remains in run_all_tests.sh.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGENSCRIPT:-$HOME/.local/bin/eigenscript}"
SUITE_ROOT=$(mktemp -d /tmp/eigs_install_subset_suite.XXXXXX)
external_home=""
external_dir=""
cleanup() {
    rm -rf "$SUITE_ROOT"
    [ -z "$external_home" ] || rm -rf "$external_home"
    [ -z "$external_dir" ] || rm -rf "$external_dir"
}
trap cleanup EXIT

# The normal runner starts in src/, where ../lib is deliberately available.
# That would let an installed-layout run silently fall back to the checkout's
# stdlib. Give the selected .eigs sections their expected src/tests/lib shape
# without a checkout lib, forcing stdlib imports through the installed binary's
# executable-relative root (and HOME's installed root).
mkdir -p "$SUITE_ROOT/src" "$SUITE_ROOT/tests" "$SUITE_ROOT/lib"
for fixture in test_import.eigs test_import_errors.eigs test_module_cache.eigs modcache_fixture.eigs; do
    ln -s "$TESTS_DIR/$fixture" "$SUITE_ROOT/tests/$fixture"
done

if [ ! -x "$EIGS" ]; then
    echo "FAIL: installed-layout binary is not executable: $EIGS"
    exit 1
fi

PASS=0
FAIL=0

record_eigs_suite() {
    local label="$1" file="$2"
    shift 2
    local output rc=0 marker ok=1
    output=$(cd "$SUITE_ROOT/src" && "$EIGS" "../tests/$file" </dev/null 2>&1) || rc=$?
    for marker in "$@"; do
        if ! grep -Fq "$marker" <<<"$output"; then
            ok=0
            break
        fi
    done
    if [ "$rc" -eq 0 ] && [ "$ok" -eq 1 ]; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label (rc=$rc)"
        printf '%s\n' "$output"
        FAIL=$((FAIL + 1))
    fi
}

record_shell_suite() {
    local label="$1" script="$2"
    shift 2
    local output rc=0 marker ok=1
    output=$(EIGENSCRIPT="$EIGS" bash "$TESTS_DIR/$script" 2>&1) || rc=$?
    for marker in "$@"; do
        if ! grep -Fq "$marker" <<<"$output"; then
            ok=0
            break
        fi
    done
    if [ "$rc" -eq 0 ] && [ "$ok" -eq 1 ]; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label (rc=$rc)"
        printf '%s\n' "$output"
        FAIL=$((FAIL + 1))
    fi
}

record_external_stdlib() {
    local ext_script output rc=0
    external_home=$(mktemp -d /tmp/eigs_install_subset_home.XXXXXX)
    external_dir=$(mktemp -d /tmp/eigs_install_subset_project.XXXXXX)
    ext_script="$external_dir/external_stdlib.eigs"
    printf '%s\n' \
        'load_file of "lib/text_builder.eigs"' \
        'b is text_builder_new of null' \
        'text_builder_append_line of [b, "external stdlib ok"]' \
        'print of (text_builder_to_string of b)' > "$ext_script"
    output=$(cd "$external_dir" && HOME="$external_home" "$EIGS" "$ext_script" </dev/null 2>&1) || rc=$?
    rm -rf "$external_home" "$external_dir"
    external_home=""
    external_dir=""
    if [ "$rc" -eq 0 ] && grep -Fq "external stdlib ok" <<<"$output"; then
        echo "PASS: [42e] executable-relative stdlib"
        PASS=$((PASS + 1))
    else
        echo "FAIL: [42e] executable-relative stdlib (rc=$rc)"
        printf '%s\n' "$output"
        FAIL=$((FAIL + 1))
    fi
}

echo "Installed-layout suite subset: $EIGS"

# [36] Import System: stdlib, project-first, user-module, and error imports.
record_eigs_suite "[36] Import System" test_import.eigs "All tests passed."

# [42g] Bundle: bundled eigs_modules + stdlib, replay, and damaged archives.
record_shell_suite "[42g] Bundle" test_bundle.sh "BUNDLE:"

# [42e] Executable-relative stdlib from a project outside the checkout.
record_external_stdlib

# [59] Import Error Paths: not-found, parse-error, and load_file failures.
record_eigs_suite "[59] Import Error Paths" test_import_errors.eigs "All tests passed."

# [91] Module Cache: repeated imports share one module body and namespace.
record_module_cache() {
    local output rc=0 runs ok=1
    output=$(cd "$SUITE_ROOT/src" && "$EIGS" "../tests/test_module_cache.eigs" </dev/null 2>&1) || rc=$?
    runs=$(grep -Fc "FIXTURE_RAN" <<<"$output" || true)
    for marker in "PASS: greeting bound" "PASS: fn from cached module works"; do
        if ! grep -Fq "$marker" <<<"$output"; then
            ok=0
            break
        fi
    done
    if [ "$rc" -eq 0 ] && [ "$runs" -eq 1 ] && [ "$ok" -eq 1 ]; then
        echo "PASS: [91] Module Cache"
        PASS=$((PASS + 1))
    else
        echo "FAIL: [91] Module Cache (rc=$rc, fixture_runs=$runs)"
        printf '%s\n' "$output"
        FAIL=$((FAIL + 1))
    fi
}
record_module_cache

# [92] Module Resolve Base: nested imports anchor at their module directory.
record_shell_suite "[92] Module Resolve Base" test_module_resolve_base.sh \
    "PASS: module resolves its own peer"

# [93] eigs_modules Resolver: walk-up and project-root halt.
record_shell_suite "[93] eigs_modules Resolver" test_eigs_modules_resolve.sh \
    "PASS: eigs_modules walk-up finds project-root package" \
    "PASS: eigs.json halts the walk"

# [95] --pkg fetch: cloned packages land in eigs_modules and are importable.
record_shell_suite "[95] --pkg fetch" test_pkg_fetch.sh \
    "PASS: import greeting resolves through eigs_modules"

echo "Installed-layout subset: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
