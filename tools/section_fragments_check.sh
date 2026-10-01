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
cat > "$fragment" <<'EOF'
echo "[zz1487] section fragment selftest plant"
bash "$TESTS_DIR/test_zz_1487_plant.sh"
EOF

bad=0; checks=0
check() { checks=$((checks + 1)); if "$@"; then echo "  PASS: $name"; else echo "  FAIL: $name"; bad=1; fi; }

name='runner_text sees the planted label'
check bash -c 'bash tools/runner_text.sh | grep -qF '\''echo "[zz1487] section fragment selftest plant"'\'''
name='section_plan can select the planted label'
check bash -c 'bash tools/section_plan.sh --sections zz1487 --quiet | grep -q "bearing=1"'
name='suite_label_check counts the planted label'
check bash -c 'bash tools/suite_label_check.sh | grep -q "PASS: 263 labelled"'
name='child_exit_check counts the planted child invocation'
check bash -c 'bash tools/child_exit_check.sh | grep -q "90 child-script sites"'
name='enrolment_check reaches a test invoked only by the fragment'
check bash tools/enrolment_check.sh

# Mutation witness: this is the old label gate with fragment expansion removed.
# It stays superficially green, but the pinned planted population makes that a
# red result here. Thus removing fragment awareness from any one gate cannot
# leave this calibration green.
sed '/RUNNER_TEXT=$(mktemp/,/RUNNER="$RUNNER_TEXT"/d' tools/suite_label_check.sh > "$work/ignores-sections.sh"
if out=$(bash "$work/ignores-sections.sh" 2>&1) && ! grep -q 'PASS: 263 labelled' <<< "$out"; then
    checks=$((checks + 1)); echo '  PASS: negative plant is red when one gate ignores tests/sections'
else
    checks=$((checks + 1)); echo '  FAIL: negative plant did not expose a gate ignoring tests/sections'; bad=1
fi
echo "section fragments selftest: checks=$checks failures=$bad"
exit "$bad"
