#!/usr/bin/env bash
# Calibration for the contract that every runner-parsing gate expands fragments.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 2
if [ "${1:-}" = "--no-new-inline" ]; then
    [ "$#" -eq 2 ] || { echo "usage: $0 --no-new-inline <base>" >&2; exit 2; }
    requested_base=$2
    # A dispatch can compare an older branch with a newer main that moved an
    # inherited section into a fragment. Only labels added since the common
    # ancestor are new on this branch (the changelog gate uses the same base).
    case "$requested_base" in -*)
        echo "section_fragments_check: base must name a commit, not an option" >&2
        exit 2 ;;
    esac
    resolved_base=$(git rev-parse --verify "$requested_base^{commit}") || {
        echo "section_fragments_check: cannot resolve base $requested_base as a commit" >&2
        exit 2
    }
    base=$(git merge-base "$resolved_base" HEAD) || {
        echo "section_fragments_check: no merge-base with $requested_base" >&2
        exit 2
    }
    echo "section-fragments base: requested=$requested_base commit=$resolved_base merge_base=$base"
    work=$(mktemp -d "${TMPDIR:-/tmp}/eigs_inline_sections.XXXXXX") || exit 2
    trap 'rm -rf "$work"' EXIT
    if ! git show "$base:tests/run_all_tests.sh" > "$work/base-runner.sh"; then
        echo "section_fragments_check: cannot read tests/run_all_tests.sh at base $base" >&2
        exit 2
    fi
    # Reuse section_plan.sh's SP_HEADER_TEXT_RE: it is the one predicate for
    # printed section headers in source validation, shard bearing and witnesses.
    header_re=$(bash tools/section_plan.sh --header-regex) || exit 2
    labels() {
        awk -v header_re="$header_re" '
            /^[[:space:]]*echo "/ {
                title = $0
                sub(/^[[:space:]]*echo "/, "", title)
                sub(/"$/, "", title)
                if (title ~ header_re) {
                    label = title
                    sub(/^\[/, "", label); sub(/\].*$/, "", label)
                    print label
                }
            }
        ' "$1" | LC_ALL=C sort -u
    }
    labels "$work/base-runner.sh" > "$work/base-labels"
    labels tests/run_all_tests.sh > "$work/tree-labels"
    new=$(comm -13 "$work/base-labels" "$work/tree-labels")
    [ -z "$new" ] && { echo "PASS: no new inline suite section labels relative to $base"; exit 0; }
    while IFS= read -r label; do
        slug=$(printf '%s' "$label-new-section" | tr '[:upper:]' '[:lower:]' \
            | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//')
        echo "FAIL: new inline section label [$label]; use tests/sections/$slug.sh instead"
    done <<< "$new"
    exit 1
fi
if [ "${1:-}" != "--selftest" ]; then
    echo "usage: $0 --selftest | --no-new-inline <base>" >&2; exit 2
fi
fragment=tests/sections/zz-1487-selftest.sh
plant=tests/test_zz_1487_plant.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/eigs_fragments.XXXXXX") || exit 2
trap 'rm -f "$fragment" "$plant"; rm -rf "$work"' EXIT
cat > "$plant" <<'EOF'
#!/usr/bin/env bash
echo 'PASS: fragment enrolment plant'
EOF
# Measure the real gate before enrolment, then require the planted site to
# increase its reported population exactly once. Its aggregate floor alone
# can stay green when fragment expansion disappears.
child_sites() {
    local output sites
    output=$(bash tools/child_exit_check.sh) || return 1
    sites=$(sed -n 's/^PASS: child-exit accounting present; \([0-9][0-9]*\) child-script sites .*$/\1/p' <<< "$output")
    case "$sites" in ''|*[!0-9]*) echo 'child_exit_check did not report one site count' >&2; return 1 ;; esac
    [ "$sites" -gt 0 ] || return 1
    printf '%s\n' "$sites"
}
child_baseline=$(child_sites) || exit 2
cat > "$fragment" <<'EOF'
echo "[zz1487] section fragment selftest plant"
bash "$TESTS_DIR/test_zz_1487_plant.sh"
EOF

bad=0; checks=0
check() { checks=$((checks + 1)); if "$@"; then echo "  PASS: $name"; else echo "  FAIL: $name"; bad=1; fi; }

name='runner_text sees the planted label'
check bash -o pipefail -c 'bash tools/runner_text.sh | grep -F '\''echo "[zz1487] section fragment selftest plant"'\'' >/dev/null'
name='section_plan can select the planted label'
check bash -o pipefail -c 'bash tools/section_plan.sh --sections zz1487 --quiet | grep -q "bearing=1"'
name='suite_label_check counts the planted label'
check bash tools/suite_label_check.sh
child_fragment_count() {
    local sites
    sites=$(child_sites) || return 1
    [ "$sites" -eq "$((child_baseline + 1))" ] || {
        echo "child sites: baseline=$child_baseline planted=$sites expected=$((child_baseline + 1))" >&2
        return 1
    }
    echo "child sites: baseline=$child_baseline planted=$sites"
}
name='child_exit_check counts the planted child invocation'
check child_fragment_count
name='enrolment_check reaches a test invoked only by the fragment'
check bash tools/enrolment_check.sh

# Mutation witness: make the fragment invalid by duplicating its label. The
# real gate must reject it, while an otherwise-working copy with expansion
# removed stays green. Root the copy in this checkout so a missing helper can
# never masquerade as the expected mutation result.
cat >> "$fragment" <<'EOF'
echo "[zz1487] duplicate section fragment selftest plant"
EOF
if bash tools/suite_label_check.sh > "$work/expanded.out" 2>&1; then
    checks=$((checks + 1)); echo '  FAIL: expanded label gate accepted a duplicate fragment label'; bad=1
else
    checks=$((checks + 1)); echo '  PASS: expanded label gate rejects an invalid fragment'
fi
sed -e "s|^ROOT=.*|ROOT='$ROOT'|" \
    -e '/RUNNER_TEXT=$(mktemp/,/RUNNER="$RUNNER_TEXT"/d' \
    tools/suite_label_check.sh > "$work/ignores-sections.sh"
if out=$(bash "$work/ignores-sections.sh" 2>&1); then
    checks=$((checks + 1)); echo '  PASS: rooted mutation stays green only because it ignores tests/sections'
else
    checks=$((checks + 1)); echo '  FAIL: mutation failed for a reason other than fragment blindness'
    printf '%s\n' "$out" | sed 's/^/    /'; bad=1
fi
# A section inherited from the common ancestor is not newly introduced by
# this branch when a later main has moved it out of the inline runner.
fixture="$work/ancestry"
mkdir -p "$fixture/tools" "$fixture/tests/sections" || exit 2
cp tools/section_fragments_check.sh tools/section_plan.sh tools/runner_text.sh "$fixture/tools/" || exit 2
printf '%s\n' 'echo "[inherited] existing section"' > "$fixture/tests/run_all_tests.sh"
git -C "$fixture" init -q || exit 2
git -C "$fixture" config user.name 'Section gate selftest' || exit 2
git -C "$fixture" config user.email 'selftest@example.invalid' || exit 2
git -C "$fixture" add . || exit 2
git -C "$fixture" commit -qm 'common ancestor has inline section' || exit 2
ancestor=$(git -C "$fixture" rev-parse HEAD) || exit 2
printf '%s\n' '# section moved into a fragment on later main' > "$fixture/tests/run_all_tests.sh"
git -C "$fixture" commit -qam 'main moved the inherited section' || exit 2
main_tip=$(git -C "$fixture" rev-parse HEAD) || exit 2
git -C "$fixture" checkout -q --detach "$ancestor" || exit 2
printf '%s\n' '# independent branch work' >> "$fixture/tests/run_all_tests.sh"
git -C "$fixture" commit -qam 'branch retains inherited section' || exit 2
name='ancestry: later main removal does not invent a new branch label'
check bash "$fixture/tools/section_fragments_check.sh" --no-new-inline "$main_tip"
printf '%s\n' 'echo "[newinline] genuinely new inline section"' >> "$fixture/tests/run_all_tests.sh"
inline_rejected() {
    local output rc
    output=$(bash "$fixture/tools/section_fragments_check.sh" --no-new-inline "$main_tip" 2>&1); rc=$?
    [ "$rc" -eq 1 ] && printf '%s\n' "$output" | grep -qF 'FAIL: new inline section label [newinline]'
}
name='ancestry: a genuinely new inline label is still rejected'
check inline_rejected
bad_base_rejected() {
    local output rc
    output=$(bash "$fixture/tools/section_fragments_check.sh" --no-new-inline nonexistent-selftest-ref 2>&1); rc=$?
    [ "$rc" -eq 2 ] && printf '%s\n' "$output" | grep -qF 'cannot resolve base nonexistent-selftest-ref as a commit'
}
name='ancestry: an unreadable base is a loud failure'
check bad_base_rejected
tree=$(git -C "$fixture" rev-parse 'HEAD^{tree}') || exit 2
unrelated=$(git -C "$fixture" commit-tree "$tree" -m 'unrelated root') || exit 2
unrelated_base_rejected() {
    local output rc
    output=$(bash "$fixture/tools/section_fragments_check.sh" --no-new-inline "$unrelated" 2>&1); rc=$?
    [ "$rc" -eq 2 ] && printf '%s\n' "$output" | grep -qF 'no merge-base with'
}
name='ancestry: unrelated histories fail loudly'
check unrelated_base_rejected
option_base_rejected() {
    local output rc
    output=$(bash "$fixture/tools/section_fragments_check.sh" --no-new-inline --all 2>&1); rc=$?
    [ "$rc" -eq 2 ] && printf '%s\n' "$output" | grep -qF 'base must name a commit, not an option'
}
name='ancestry: option-like base is rejected'
check option_base_rejected
echo "section fragments selftest: checks=$checks failures=$bad"
exit "$bad"
