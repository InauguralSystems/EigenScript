#!/bin/bash
# #1668: mutating/listing file builtins raise io errors with path + strerror.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs_file_mutation_errors.XXXXXX")
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
chmod 777 "$TMP"
mkdir "$TMP/locked" "$TMP/nonempty"
chmod 000 "$TMP/locked"
printf x > "$TMP/file"; printf x > "$TMP/nonempty/child"

pass=0 fail=0
run_script() {
    local file=$1 out rc
    chmod 644 "$file"
    if [ "$(id -u)" -eq 0 ]; then
        out=$(runuser -u nobody -- "$BIN" "$file" 2>&1); rc=$?
    else
        out=$("$BIN" "$file" 2>&1); rc=$?
    fi
    printf '%s\n%s' "$rc" "$out"
}
expect_error() {
    local builtin=$1 expr=$2 path=$3 reason=$4 label=$5 result rc out
    cat > "$TMP/case.eigs" <<EOF2
try:
    value is $expr
    print of "NO_ERROR"
catch e:
    print of f"{e.kind}|{e.message}"
EOF2
    result=$(run_script "$TMP/case.eigs"); rc=${result%%$'\n'*}; out=${result#*$'\n'}
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "io|$builtin:" &&
       printf '%s\n' "$out" | grep -qF "$path" && printf '%s\n' "$out" | grep -qF "$reason"; then
        echo "  PASS: $builtin $label exposes path and OS reason"; pass=$((pass + 1))
    else
        echo "  FAIL: $builtin $label (rc=$rc, output='$out')"; fail=$((fail + 1))
    fi
}

expect_error write_text "write_text of [\"$TMP/missing/out\", \"x\"]" "$TMP/missing/out" "No such file or directory" "missing parent"
expect_error write_text "write_text of [\"$TMP/locked/out\", \"x\"]" "$TMP/locked/out" "Permission denied" "permission denied"
expect_error write_text "write_text of [\"$TMP/nonempty\", \"x\"]" "$TMP/nonempty" "Is a directory" "directory target"
expect_error write_bytes "write_bytes of [\"$TMP/missing/out\", [1]]" "$TMP/missing/out" "No such file or directory" "missing parent"
expect_error write_bytes "write_bytes of [\"$TMP/locked/out\", [1]]" "$TMP/locked/out" "Permission denied" "permission denied"
expect_error write_bytes "write_bytes of [\"$TMP/nonempty\", [1]]" "$TMP/nonempty" "Is a directory" "directory target"
expect_error remove_file "remove_file of \"$TMP/missing\"" "$TMP/missing" "No such file or directory" "missing path"
expect_error remove_file "remove_file of \"$TMP/nonempty\"" "$TMP/nonempty" "Directory not empty" "nonempty directory"
expect_error rename "rename of [\"$TMP/missing\", \"$TMP/to\"]" "$TMP/missing" "No such file or directory" "missing source"
expect_error rename "rename of [\"$TMP/file\", \"$TMP/missing/to\"]" "$TMP/missing/to" "No such file or directory" "missing destination parent"
expect_error rename "rename of [\"$TMP/file\", \"$TMP/nonempty\"]" "$TMP/nonempty" "Is a directory" "directory destination"
expect_error mkdir "mkdir of \"$TMP/file/child\"" "$TMP/file/child" "Not a directory" "file as parent"
expect_error mkdir "mkdir of \"$TMP/locked/child\"" "$TMP/locked/child" "Permission denied" "permission denied"
expect_error ls "ls of \"$TMP/missing\"" "$TMP/missing" "No such file or directory" "missing path"
expect_error ls "ls of \"$TMP/file\"" "$TMP/file" "Not a directory" "file target"
expect_error ls "ls of \"$TMP/locked\"" "$TMP/locked" "Permission denied" "permission denied"

cat > "$TMP/success.eigs" <<EOF2
ok1 is write_text of ["$TMP/text", "hello"]
ok2 is write_bytes of ["$TMP/bytes", [65, 66]]
ok3 is rename of ["$TMP/text", "$TMP/renamed"]
ok4 is mkdir of "$TMP/new/deep"
entries is ls of "$TMP"
ok5 is remove_file of "$TMP/renamed"
print of f"{ok1}|{ok2}|{ok3}|{ok4}|{len of entries > 0}|{ok5}"
EOF2
result=$(run_script "$TMP/success.eigs"); rc=${result%%$'\n'*}; out=${result#*$'\n'}
if [ "$rc" -eq 0 ] && [ "$out" = "true|2|true|true|true|true" ]; then
    echo "  PASS: successful file builtin results are unchanged"; pass=$((pass + 1))
else
    echo "  FAIL: successful results (rc=$rc, output='$out')"; fail=$((fail + 1))
fi
printf 'FILE MUTATION ERRORS: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
