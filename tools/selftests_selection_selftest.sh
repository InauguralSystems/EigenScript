#!/usr/bin/env bash
set -eu
[ "${1-}" = "--selftest" ] || { echo "usage: $0 --selftest" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/eigs-selftests-selection.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

seed=$tmp/seed
git init -q -b main "$seed"
cd "$seed"
git config user.email selftest@example.invalid
git config user.name selftest
mkdir -p tools docs
cp "$root/tools/selftests.sh" tools/selftests.sh
for name in candidate staged untracked unrelated; do
    cat >"tools/$name.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1-}" = "--selftest" ]; then exit 0; fi
exit 2
EOF
done
cat >tools/selftests.txt <<'EOF'
feature.txt | timeout 5 bash tools/candidate.sh --selftest
staged.txt | timeout 5 bash tools/staged.sh --selftest
untracked.txt | timeout 5 bash tools/untracked.sh --selftest
unrelated.txt | timeout 5 bash tools/unrelated.sh --selftest
EOF
for n in $(seq 1 100); do : >"docs/$n"; done
printf 'base\n' >feature.txt
printf 'base\n' >staged.txt
printf 'base\n' >conflict.txt
git add . && git commit -qm base
git branch topic
printf '# incoming registry comment\n' >>tools/selftests.txt
printf 'main\n' >conflict.txt
git add . && git commit -qm incoming
base=$(git rev-parse HEAD)
git switch -q topic
printf 'topic\n' >feature.txt
printf 'topic\n' >conflict.txt
git add . && git commit -qm topic

passed=0
failed=0
run_case() {
    name=$1 expected_rc=$2 expected_count=$3 expected_text=$4
    shift 4
    work=$tmp/$name
    git clone -q "$seed" "$work"
    cd "$work"
    git config user.email selftest@example.invalid
    git config user.name selftest
    git switch -q topic
    set +e
    "$@" >setup.out 2>&1
    setup_rc=$?
    timeout 20 bash tools/selftests.sh --changed "$base" --list >actual.out 2>&1
    actual_rc=$?
    set -e
    observed_count=$(grep -Ec '^timeout [0-9]+ ' actual.out || :)
    if [ "$setup_rc" -eq 0 ] && [ "$actual_rc" -eq "$expected_rc" ] &&
       [ "$observed_count" -eq "$expected_count" ] && grep -Fq "$expected_text" actual.out; then
        echo "  PASS: $name expected_rc=$expected_rc observed_rc=$actual_rc expected_count=$expected_count observed_count=$observed_count"
        passed=$((passed + 1))
    else
        echo "  FAIL: $name setup_rc=$setup_rc expected_rc=$expected_rc observed_rc=$actual_rc expected_count=$expected_count observed_count=$observed_count reason=receipt-mismatch"
        sed 's/^/    /' setup.out actual.out
        failed=$((failed + 1))
    fi
}

pending_resolved() {
    git merge -q --no-commit "$base" || :
    printf 'topic resolved\n' >conflict.txt && git add conflict.txt
}
pending_unresolved() { git merge -q --no-commit "$base" || :; }
registry_conflict() {
    printf '# topic registry comment\n' >>tools/selftests.txt
    git add tools/selftests.txt && git commit -qm registry-topic
    git merge -q --no-commit "$base" || :
}
pending_staged_restored() {
    pending_resolved
    printf 'staged\n' >staged.txt && git add staged.txt
    git show "$base:staged.txt" >staged.txt
    printf 'new\n' >untracked.txt
}
ordinary_dirty() {
    git reset -q --hard "$base"
    printf 'dirty\n' >feature.txt
    printf 'staged\n' >staged.txt && git add staged.txt
    printf 'new\n' >untracked.txt
}
registry_edit() {
    git merge -q --no-commit "$base" || :
    printf 'topic resolved\n' >conflict.txt && git add conflict.txt
    printf '# candidate registry edit\n' >>tools/selftests.txt
    git add tools/selftests.txt
}
committed_merge() {
    git merge -q --no-commit "$base" || :
    printf 'topic resolved\n' >conflict.txt && git add conflict.txt
    git commit -qm merge
}

run_case pending-resolved 0 1 '1 self-tests selected' pending_resolved
run_case pending-unresolved 2 0 'unresolved merge' pending_unresolved
run_case registry-conflict 2 0 'unresolved merge' registry_conflict
run_case pending-staged-restored 0 3 'tools/staged.sh --selftest' pending_staged_restored
run_case ordinary-dirty 0 3 '3 self-tests selected' ordinary_dirty
run_case candidate-registry-edit 0 4 '4 self-tests selected' registry_edit
run_case committed-merge 0 1 '1 self-tests selected' committed_merge
echo "SELFTEST_SELECTION: $passed passed, $failed failed, 7 declared"
[ "$failed" -eq 0 ]
