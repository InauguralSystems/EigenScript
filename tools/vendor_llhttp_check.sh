#!/usr/bin/env bash
# #2370: the parser in the tree is llhttp's release v9.4.4, unchanged. The five
# files under src/vendor/llhttp/ must have the sha256 the issue gives; a file
# that differs or is missing fails by its name. A later release replaces the
# five files and this table together (SECURITY.md).
#
# What holds src/vendor/llhttp/, in one place: the five hashes of this script;
# the builds' flags (the Makefile compiles each vendored .c file with the
# command of src/ext_http.c in the same build, plus -Wno-unused-parameter: see
# `make -n -B http`, `make -n -B asan-http`, `make -n -B tsan-http`); and suite
# section 45j (tests/sections/45j-http-door.sh), which runs the parser through
# the server. The checks written for the runtime's own sources are not relied
# on for this folder, whether or not one of them reads it.
#
# Usage: tools/vendor_llhttp_check.sh [--selftest]
set -u
cd "$(dirname "$0")/.." || exit 2

TABLE='llhttp.c f3ef756529b7444630717fa5540d4a1c9a1256874bda823c49c5a99c37f89429
api.c 0f8590206fe2f264db2825401b5fb856b979ee1363dc88b06f36dc9577afb941
http.c a1f2b23168f8e9b5bfa464c89027d3ca259fc649ae3d7e72bfff997d1aeb5d72
llhttp.h 52a7011f979b31f761403c1a333bf7fc26dc70f5745d8488eed1609c92097100
LICENSE-MIT ebca854e0134cd256d673627c20499f42577eb74bacf08b9f25b626a73c91277'

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'
    else shasum -a 256 < "$1" | awk '{print $1}'; fi
}

# check_dir DIR: one line for each file, then a verdict; exit 1 on any failure.
check_dir() {
    local dir="$1" name want got bad=0 seen=0
    while read -r name want; do
        seen=$((seen + 1))
        if [ ! -f "$dir/$name" ]; then
            echo "FAIL: src/vendor/llhttp/$name is missing"; bad=$((bad + 1)); continue
        fi
        got=$(sha256_of "$dir/$name")
        if [ "$got" = "$want" ]; then echo "PASS: src/vendor/llhttp/$name"
        else echo "FAIL: src/vendor/llhttp/$name has sha256 $got, not llhttp v9.4.4's $want"; bad=$((bad + 1)); fi
    done <<< "$TABLE"
    [ "$seen" -eq 5 ] || { echo "FAIL: the table holds $seen files, not 5"; bad=$((bad + 1)); }
    if [ "$bad" -eq 0 ]; then echo "vendor-llhttp: OK: 5 of 5 files are llhttp v9.4.4's"
    else echo "vendor-llhttp: FAIL: $bad file(s)"; fi
    [ "$bad" -eq 0 ]
}

if [ "${1:-}" = --selftest ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/eigs_vendor_llhttp.XXXXXX") || exit 2
    trap 'rm -rf "$tmp"' EXIT
    fail=0 cases=0
    cp src/vendor/llhttp/* "$tmp/" || exit 2
    out=$(check_dir "$tmp"); rc=$?
    cases=$((cases + 1))
    if [ "$rc" -eq 0 ]; then echo "  PASS: control: the unchanged copy passes"
    else echo "  FAIL: control: the unchanged copy fails"; printf '%s\n' "$out"; fail=$((fail + 1)); fi
    while read -r name _; do
        # One byte changed: the first byte of the file, plus one.
        cp src/vendor/llhttp/* "$tmp/"
        python3 -c 'import sys; p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[0] = (b[0] + 1) % 256; open(p, "wb").write(b)' "$tmp/$name"
        out=$(check_dir "$tmp"); rc=$?
        cases=$((cases + 1))
        if [ "$rc" -ne 0 ] && grep -q "^FAIL: src/vendor/llhttp/$name has sha256 " <<< "$out" &&
           [ "$(grep -c '^FAIL: ' <<< "$out")" -eq 1 ]; then echo "  PASS: plant: one byte of $name changed fails by its name"
        else echo "  FAIL: plant: one byte of $name changed (rc=$rc)"; printf '%s\n' "$out"; fail=$((fail + 1)); fi
        cp src/vendor/llhttp/* "$tmp/"
        rm -f "$tmp/$name"
        out=$(check_dir "$tmp"); rc=$?
        cases=$((cases + 1))
        if [ "$rc" -ne 0 ] && grep -qxF "FAIL: src/vendor/llhttp/$name is missing" <<< "$out"; then
            echo "  PASS: plant: $name missing fails by its name"
        else echo "  FAIL: plant: $name missing (rc=$rc)"; printf '%s\n' "$out"; fail=$((fail + 1)); fi
    done <<< "$TABLE"
    echo "vendor-llhttp selftest: $((cases - fail)) passed, $fail failed"
    [ "$fail" -eq 0 ] && [ "$cases" -eq 11 ]; exit
fi

[ -z "${1:-}" ] || { echo "usage: tools/vendor_llhttp_check.sh [--selftest]" >&2; exit 2; }
check_dir src/vendor/llhttp
