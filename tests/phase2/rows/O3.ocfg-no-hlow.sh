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

# R32-1: accepting a record must also install each of its four fields.
# A planted reader may crash while folding. Capture the child status and
# shell diagnostic inside that case so the checker names the failed witness.
ulimit -c 0
cat > flat.eigs <<'EOF'
x is 1.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
print of (report of x)
EOF
cat > slow.eigs <<'EOF'
x is 1.0
n is 0
loop while n < 30:
    n is n + 1
    x is 1.0 + 0.003 / n
print of (report of x)
EOF
for program in flat slow; do
    "$bin" --lint --json "$program.eigs" > "$program.lint"
    EIGS_TRACE="$program.tape" "$bin" "$program.eigs" > "$program.record"
done
install_case() {
    name=$1
    program=$2
    record=$3
    { head -2 "$program.tape"
      if [ -n "$record" ]; then printf '%s\n' "$record"; fi
      tail -n +3 "$program.tape"
    } > install.tape
    printf 's 400\np x\nq\n' > commands.in
    rc=0
    { "$bin" --step install.tape "$program.eigs" < commands.in > step.out; } 2> step.err || rc=$?
    label=$(sed -n '/x = /s/.*\[\([^]]*\)\].*/[\1]/p' step.out)
    printf '%s rc=%s label=%s\n' "$name" "$rc" "${label:-<missing>}"
    first=$(head -1 step.err)
    printf '%s first-stderr=%s\n' "$name" "${first:-<empty>}"
}
install_case cfg-install-flat-none flat ''
install_case cfg-install-defaults flat 'O 0 cfg 0.001 0.01 10 0.001'
install_case cfg-install-window flat 'O 0 cfg 0.001 0.01 4 0.001'
install_case cfg-install-scale flat 'O 0 cfg 0.001 0.01 10 1000'
install_case cfg-install-dh-small flat 'O 0 cfg 0.001 0.9 10 0.001'
install_case cfg-install-slow-none slow ''
install_case cfg-install-dh-zero slow 'O 0 cfg 0.0000001 0.01 10 0.001'
