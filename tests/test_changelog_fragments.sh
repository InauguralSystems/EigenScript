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
    # With errexit off a function returns only its LAST command's status, so a
    # failed intermediate step would be overwritten by later successful ones
    # (#2061 review). The ERR trap records the FIRST failing command; errtrace
    # makes it fire inside the setup function. It runs in this shell, so a
    # setup's `base` update survives, and bash does not fire ERR for a test
    # in an if, a && / || list or a pipeline.
    setup_rc=0 setup_cmd=
    set -o errtrace
    trap '__rc=$?; if [ "$setup_rc" -eq 0 ]; then setup_rc=$__rc; setup_cmd=$BASH_COMMAND; fi' ERR
    "$setup" >"$setup_out" 2>&1
    trap - ERR
    set +o errtrace
    if [ "$setup_rc" -ne 0 ]; then
        cd "$ROOT" || exit 2
        echo "  FAIL: $name (setup failed: $setup: $setup_cmd, rc=$setup_rc)"
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
    # The harness's own plant (see the end of this file): an intermediate command fails
    # and later ones succeed, so only per-command tracking can name it.
    [ "${CHANGELOG_SELFTEST_PLANT:-}" != intermediate-setup-failure ] || bash -c 'echo planted-setup-failure >&2; exit 42'
    find changes -mindepth 2 -type f -delete
    # --allow-empty: right after a release cut there are no fragments to remove.
    git add -A && git commit -q --allow-empty -m 'remove pre-existing fragments'
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
if [ -z "${CHANGELOG_SELFTEST_PLANT:-}" ]; then
    # The harness's own plant (#2061 review): re-run with a failing INTERMEDIATE
    # setup command in cut-readme, followed by successful ones. It must be named
    # as a setup failure with its rc and output, and the summary must still print.
    # Root-qualified: $0 may be relative to a directory this script has left,
    # and the planted run's expected rc 1 must not trip an inherited errexit.
    plant_rc=0
    plant_out=$(CHANGELOG_SELFTEST_PLANT=intermediate-setup-failure bash "$ROOT/tests/${0##*/}" --selftest 2>&1) || plant_rc=$?
    if [ "$plant_rc" -eq 1 ] &&
       grep -q "^  FAIL: cut-readme (setup failed: cut_deletes_readme: .*exit 42.*, rc=42)$" <<< "$plant_out" &&
       grep -qx "planted-setup-failure" <<< "$plant_out" &&
       grep -qx "SELFTEST: 4 case(s) run, 3 passed, 1 failed" <<< "$plant_out"; then
        echo "PLANT OK: an intermediate setup failure is named with its rc and output"
    else
        echo "PLANT FAIL: the planted intermediate setup failure was not reported (rc=$plant_rc)"
        printf '%s\n' "$plant_out" | sed 's/^/  | /'
        failed=$((failed + 1))
    fi
fi
[ "$failed" -eq 0 ]
