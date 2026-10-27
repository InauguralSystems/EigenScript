#!/usr/bin/env bash
# Calibration for the changelog fragment gate (#1420). Each case constructs a
# real git history because deletion and release-cut classification are diff based.
set -u
cd "$(dirname "$0")/.." || exit 2
[ "${1:-}" = "--selftest" ] || { echo "usage: tests/test_changelog_fragments.sh --selftest" >&2; exit 2; }

ROOT=$PWD
SCRATCH=$(mktemp -d -p "$(dirname "$ROOT")" eigs-changelog-selftest.XXXXXX) || exit 2
trap 'rm -rf "$SCRATCH"' EXIT
passed=0 failed=0

case_run() { # name setup-function expected diagnostic
    local name=$1 setup=$2 expected=$3 tree=$SCRATCH/$1 base out rc setup_out setup_rc caller_errexit=0
    case $- in *e*) caller_errexit=1;; esac
    git clone -q --shared "$ROOT" "$tree" || exit 2
    cd "$tree" || exit 2
    git config user.email selftest@example.invalid
    git config user.name selftest
    base=$(git rev-parse HEAD)
    set +e
    setup_out=$tree/.git/selftest-setup-output
    "$setup" >"$setup_out" 2>&1; setup_rc=$?
    if [ "$setup_rc" -ne 0 ]; then
        cd "$ROOT" || exit 2
        echo "  FAIL: $name (setup failed: $setup, rc=$setup_rc)"
        cat "$setup_out"
        failed=$((failed + 1))
        [ "$caller_errexit" -eq 0 ] || set -e
        return 0
    fi
    out=$(bash tools/changelog_fragments.sh check "$base" 2>&1); rc=$?
    cd "$ROOT" || exit 2
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "$expected"; then
        echo "  PASS: $name"
        passed=$((passed + 1))
    else
        echo "  FAIL: $name (wanted nonzero and /$expected/, got rc=$rc)"
        printf '%s\n' "$out"
        failed=$((failed + 1))
    fi
    [ "$caller_errexit" -eq 0 ] || set -e
}

symlink_fragment() {
    mkdir -p changes/fixed
    printf '%s\n' '- linked entry' > target
    ln -s ../../target changes/fixed/1420-link.md
}
empty_fragment() {
    mkdir -p changes/fixed
    printf '%s\n' '- ' > changes/fixed/1420-empty.md
}
deleted_fragment() {
    mkdir -p changes/fixed
    printf '%s\n' '- existing entry' > changes/fixed/999-existing.md
    git add changes/fixed/999-existing.md && git commit -qm 'add prior fragment'
    # The gate's base must include the fragment being deleted.
    base=$(git rev-parse HEAD)
    git rm -q changes/fixed/999-existing.md && git commit -qm 'delete prior fragment'
}
cut_deletes_readme() {
    find changes -mindepth 2 -type f -delete
    git add -A && git commit -qm 'remove pre-existing fragments'
    base=$(git rev-parse HEAD)
    bash tools/changelog_fragments.sh cut 99.99.99 2099-01-01 >/dev/null
    rm changes/README.md
    git add -A && git commit -qm 'release cut plus README deletion'
}

case_run symlink symlink_fragment 'FAIL changes/fixed/1420-link.md'
case_run empty-bullet empty_fragment 'FAIL changes/fixed/1420-empty.md'
case_run deleted deleted_fragment 'existing changelog fragment(s) deleted'
case_run cut-readme cut_deletes_readme 'release cut PR carries only the cut'
echo "SELFTEST: $((passed + failed)) case(s) run, $passed passed, $failed failed"
[ "$failed" -eq 0 ]
