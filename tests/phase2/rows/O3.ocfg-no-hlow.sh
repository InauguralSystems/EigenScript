# ROW: O3.ocfg-no-hlow
# ITEMS: O3
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS:
# TIERS: off default osr trace
# Count witnesses deliberately use an old h_low that is also a legal window.
# Each stderr first line is part of the exact MAP transcript, including the
# old parser refusal for a four-field record with a non-integer window.
set -eu
bin=$1
scratch=$(mktemp -d "${TMPDIR:-/tmp}/eigs-r32-cfg.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
cat > p.eigs <<'EOF'
x is 1.0
x is 2.0
print of (report of x)
EOF
"$bin" --lint --json p.eigs > lint.out
EIGS_TRACE=base.tape "$bin" p.eigs > record.out
cfg_case() {
    label=$1
    record=$2
    { head -2 base.tape; printf '%s\n' "$record"; tail -n +3 base.tape; } > case.tape
    rc=0
    printf 'q\n' | "$bin" --step case.tape p.eigs > step.out 2> step.err || rc=$?
    names=0
    if grep -q 'has [0-9][0-9]* fields, expected 4:' step.err; then names=1; fi
    printf '%s rc=%s names-count=%s\n' "$label" "$rc" "$names"
    first=$(head -1 step.err)
    printf '%s first-stderr=%s\n' "$label" "${first:-<empty>}"
}
cfg_case cfg-4-fields 'O 0 cfg 0.001 0.01 10 0.001'
cfg_case cfg-5-fields 'O 0 cfg 0.001 0.01 8 10 0.001'
cfg_case cfg-6-fields 'O 0 cfg 0.001 0.01 10 0.001 99 7'
cfg_case cfg-3-fields 'O 0 cfg 0.001 0.01 10'
cfg_case cfg-0-fields 'O 0 cfg'
cfg_case cfg-5-text 'O 0 cfg 0.001 0.01 10 0.001 extra'
cfg_case cfg-4-window-text 'O 0 cfg 0.001 0.01 eight 0.001'
cfg_case cfg-4-window-fraction 'O 0 cfg 0.001 0.01 10.5 0.001'
