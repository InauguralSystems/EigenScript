#!/usr/bin/env bash
# Calibration for the contract that every runner-parsing gate expands fragments.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 2
if [ "${1:-}" != "--selftest" ]; then echo "usage: $0 --selftest" >&2; exit 2; fi
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
echo "section fragments selftest: checks=$checks failures=$bad"
exit "$bad"
