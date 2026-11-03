#!/usr/bin/env bash
# R23-1 ordinary runtime proofs, using the real variant and owned persistence.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -ge 2 ] && [ $# -le 3 ] || { echo 'writers: usage: writers.sh VARIANT BINARY [SERVER_BINARY]'; exit 2; }
variant=$1
case "$2" in /*) binary=$2 ;; *) binary="$PWD/$2" ;; esac
server=
if [ $# -eq 3 ]; then
    case "$3" in /*) server=$3 ;; *) server="$PWD/$3" ;; esac
fi
cd "$ROOT" || exit 2
work=$(mktemp -d "${TMPDIR:-/tmp}/eigs-writers.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
. tests/lsan_classify.sh || exit 2
cap=
if command -v timeout >/dev/null 2>&1; then cap='timeout 120'
elif command -v gtimeout >/dev/null 2>&1; then cap='gtimeout 120'; fi
run_case() {
    local name=$1 rc cls
    shift
    $cap "$@" > "$work/$name.log" 2>&1; rc=$?
    cat "$work/$name.log"
    lsan_classify "$(cat "$work/$name.log")"; cls=$?
    if [ "$rc" -ne 0 ] || [ "$cls" -ne 2 ]; then
        echo "writers: FAIL $name rc=$rc sanitizer-class=$cls"
        return 1
    fi
}
c_checks=not-run
if [ "$variant" = build-sh ]; then
    echo "writers: C fixture not run: build.sh binary has no make variant; hosted phase2 release/ASan owns the C proof"
else
    make --no-print-directory "WRITER_JSON_VARIANT=$variant" writer-json-test > "$work/build.log" 2>&1; build_rc=$?
    cat "$work/build.log"
    if [ "$build_rc" -ne 0 ] || grep -q 'warning:' "$work/build.log"; then
        echo "writers: FAIL build rc=$build_rc"; exit 1
    fi
    run_case c-json "build/$variant/test_writer_json" || exit 1
    grep -qx 'writer-json: refused=15 finite=5 checks=78 failures=0' "$work/c-json.log" || exit 1
    c_checks=78
fi
mkdir "$work/store" "$work/legacy" || exit 2
run_case store env EIGS_STRICT=0 EIGS_PROBE_TMP="$work/store" "$binary" tests/phase2/writers/store_refusal.eigs || exit 1
grep -qx 'Tests: 77 | Pass: 77 | Fail: 0' "$work/store.log" || exit 1
cp tests/phase2/fixtures/r23-legacy-buffer-nan.db tests/phase2/fixtures/r23-legacy-buffer-infinity.db "$work/legacy/" || exit 2
run_case legacy env EIGS_STRICT=0 EIGS_PROBE_TMP="$work/legacy" "$binary" tests/phase2/writers/legacy_nonfinite.eigs || exit 1
grep -qx 'Tests: 10 | Pass: 10 | Fail: 0' "$work/legacy.log" || exit 1
if [ -n "$server" ]; then
    for tier in off default osr; do
        run_case "shared-$tier" python3 tests/phase2/writer_shared.py "$server" --tier "$tier" || exit 1
        grep -qx 'writer-shared: cases=24 observed=24 passed=24 failed=0 setup=ok' "$work/shared-$tier.log" || exit 1
    done
fi
echo "writers: PASS variant=$variant c=$c_checks store=77 legacy=10 shared=${server:+72}"
