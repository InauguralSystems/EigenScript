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
# A refusal quotes the record. Print a vertical tab as ^ and every byte
# above 0x7f as #, so the transcript stays one ASCII line per case.
visible() { LC_ALL=C tr '\013' '^' | LC_ALL=C tr '\200-\377' '#'; }
cfg_case() {
    label=$1
    record=$2
    { head -2 base.tape; printf '%s\n' "$record"; tail -n +3 base.tape; } > case.tape
    rc=0
    printf 'q\n' | "$bin" --step case.tape p.eigs > step.out 2> step.err || rc=$?
    names=0
    if grep -q 'has [0-9][0-9]* fields, expected 4:' step.err; then names=1; fi
    printf '%s rc=%s names-count=%s\n' "$label" "$rc" "$names"
    first=$(head -1 step.err | visible)
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
    first=$(head -1 step.err | visible)
    printf '%s first-stderr=%s\n' "$name" "${first:-<empty>}"
}
install_case cfg-install-flat-none flat ''
install_case cfg-install-defaults flat 'O 0 cfg 0.001 0.01 10 0.001'
install_case cfg-install-window flat 'O 0 cfg 0.001 0.01 4 0.001'
install_case cfg-install-scale flat 'O 0 cfg 0.001 0.01 10 1000'
install_case cfg-install-dh-small flat 'O 0 cfg 0.001 0.9 10 0.001'
install_case cfg-install-slow-none slow ''
install_case cfg-install-dh-zero slow 'O 0 cfg 0.0000001 0.01 10 0.001'

# R32-1: window syntax stays decimal; a correct field count is not enough.
cfg_case cfg-4-window-hex 'O 0 cfg 0.001 0.01 0x4 0.001'

# R32-2: the no-record fold starts from all four compiled defaults.
cat > tiny.eigs <<'EOF'
x is 1.0
n is 0
loop while n < 30:
    n is n + 1
    x is 0.0005 + 0.0001 / n
print of (report of x)
EOF
cat > p1.eigs <<'EOF'
x is 1.0
x is 1.005
print of (report of x)
EOF
cat > p2.eigs <<'EOF'
x is 0.0
x is 0.00005
print of (report of x)
EOF
for program in tiny p1 p2; do
    "$bin" --lint --json "$program.eigs" > "$program.lint"
    EIGS_TRACE="$program.tape" "$bin" "$program.eigs" > "$program.record"
done
install_case cfg-start-tiny tiny ''
install_case cfg-start-p1 p1 ''
install_case cfg-start-p2 p2 ''

# R32-2: retained range/token refusals and both window boundaries.
cfg_case cfg-dh-zero-0 'O 0 cfg 0 0.01 10 0.001'
cfg_case cfg-dh-zero-negative 'O 0 cfg -1 0.01 10 0.001'
cfg_case cfg-dh-small-negative 'O 0 cfg 0.001 -1 10 0.001'
cfg_case cfg-thresholds-equal 'O 0 cfg 0.01 0.01 10 0.001'
cfg_case cfg-scale-0 'O 0 cfg 0.001 0.01 10 0'
cfg_case cfg-scale-huge 'O 0 cfg 0.001 0.01 10 1e301'
cfg_case cfg-window-65 'O 0 cfg 0.001 0.01 65 0.001'
cfg_case cfg-window-3 'O 0 cfg 0.001 0.01 3 0.001'
cfg_case cfg-window-wide 'O 0 cfg 0.001 0.01 4294967304 0.001'
cfg_case cfg-scale-junk 'O 0 cfg 0.001 0.01 10 0.001x'
cfg_case cfg-window-64 'O 0 cfg 0.001 0.01 64 0.001'

# R32-2: live string entropy, on each side of the fixed 0.1 threshold.
cat > ec_low.eigs <<'EOF'
define run() as:
    local s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    local k is 0
    loop while k < 60:
        s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
cat > ec_high.eigs <<'EOF'
define run() as:
    local s is "ab"
    local k is 0
    loop while k < 60:
        s is "ab"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
cat > es_low.eigs <<'EOF'
define run() as:
    local s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    local k is 0
    loop while k < 14:
        s is s + "aaa"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
cat > es_high.eigs <<'EOF'
define run() as:
    local s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    local k is 0
    loop while k < 14:
        s is s + "a"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
live_case() {
    name=$1
    program=$2
    "$bin" --lint --json "$program.eigs" > "$program.lint"
    rc=0
    # A live run in every tier: no tape is spliced or stepped. The trace
    # tier records it (EIGS_TRACE is inherited), so that tier's leaf
    # differential covers the entropy readers as well.
    { "$bin" "$program.eigs" > live.out; } 2> live.err || rc=$?
    last=$(tail -1 live.out)
    printf '%s rc=%s last=%s\n' "$name" "$rc" "${last:-<missing>}"
    first=$(head -1 live.err)
    printf '%s first-stderr=%s\n' "$name" "${first:-<empty>}"
}
live_case cfg-entropy-ec-low ec_low
live_case cfg-entropy-ec-high ec_high
live_case cfg-entropy-es-low es_low
live_case cfg-entropy-es-high es_high

# R32-2 caller-audit residual: capture/restore has no observable through
# current clients. tape_classify_at returns only the settled literal label;
# step.c print_binding / show_trajectory and eigsdap.c append_binding_value /
# handle_variables serialize labels, then inspect only the tape. DAP evaluate
# resolves recorded names; it executes no program. Every later fold resets
# all four defaults, so leftover reader configuration cannot change it.
# Makefile CLI_ONLY excludes tape_read.c from EMBED_SOURCES/amalgamation;
# the embed API has no TapeTraj caller. No nested or concurrent live fold.
# Future callers mixing tape folds and live evaluation need a restoration
# witness. This row does not claim to test that unreachable observable.
# Also recorded: observer_slot_report_entropy's final h_low condition is
# dead (both its true branch and fallthrough return stable); unchanged here.

# R32-3: the mechanical sweep's witnesses. Every case below is the one input
# that tells a surviving one-token mutant of a line R3.2 wrote from the head
# (briefs/out/r3-2/orch-sweep/um/: 941 mutants, the survivor table).
vt=$(printf '\013')
hi=$(printf '\303\251')

# Each numeric field is one whole token, and the scale is the last one.
cfg_case cfg-dh-zero-junk 'O 0 cfg 0.001+0.9 10 0.001 0.001'
cfg_case cfg-dh-small-junk 'O 0 cfg 0.001 0.01+10 0.001 0.001'
cfg_case cfg-window-dot 'O 0 cfg 0.001 0.01 .5 0.001'
cfg_case cfg-scale-text 'O 0 cfg 0.001 0.01 10 x'
cfg_case cfg-scale-high-byte "O 0 cfg 0.001 0.01 10 0.001$hi"
# dh_small 0 is refused as a threshold, not as an ordering; a window of
# -(2^32 - 4) is refused, not narrowed to 4.
cfg_case cfg-dh-small-0 'O 0 cfg 0.001 0 10 0.001'
cfg_case cfg-window-wide-negative 'O 0 cfg 0.001 0.01 -4294967292 0.001'

# Fields are whitespace-delimited (docs/TRACE.md): runs of spaces, a trailing
# space and a vertical tab all separate: after the keyword, in the count and
# at the end of every field (the second record uses nothing but vertical tabs).
install_case cfg-sep-spaces flat 'O 0 cfg  0.001   0.9 10 0.001 '
install_case cfg-sep-vtab-keyword flat "O 0 cfg${vt}0.001${vt}0.9${vt}10${vt}0.001${vt}"
cfg_case cfg-sep-vtab-field "O 0 cfg 0.001${vt}0.9 10 0.001 0.001"

# Only the exact keyword `cfg` is a configuration record. The four records
# below install nothing: the label is the no-record `[moving]`. (That an
# unknown O sub-record is skipped silently, rc 0, is #2334's residual; the
# pin here is that it is not read as `cfg`.) An `O win` record still applies.
install_case cfg-keyword-cfa flat 'O 0 cfa 0.001 0.9 10 0.001'
install_case cfg-keyword-cfz flat 'O 0 cfz 0.001 0.9 10 0.001'
install_case cfg-keyword-cfgx flat 'O 0 cfgx 0.001 0.9 10 0.001'
install_case cfg-keyword-high-byte flat "O 0 cfg$hi 0.001 0.9 10 0.001"
install_case cfg-win-record flat 'O 0 win x 4'

# The entropy constant, bracketed: a one-`b` string of 78 bytes has entropy
# 0.09896 and one of 77 bytes has 0.100001. Each reader lands on opposite
# sides of 0.1 for the two, so a constant outside (0.09896, 0.100001] is red.
cat > ec_below.eigs <<'EOF'
define run() as:
    local s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    local k is 0
    loop while k < 60:
        s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
cat > ec_above.eigs <<'EOF'
define run() as:
    local s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    local k is 0
    loop while k < 60:
        s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
cat > es_below.eigs <<'EOF'
define run() as:
    local s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    local k is 0
    loop while k < 14:
        s is s + "a"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
cat > es_above.eigs <<'EOF'
define run() as:
    local s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    local k is 0
    loop while k < 14:
        s is s + "a"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
# The third reader's partial-window tail (three steps, entropy above 0.1,
# each step between dh_zero and dh_small): the label is `stable`.
cat > rp_part.eigs <<'EOF'
define run() as:
    local s is "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
    s is s + "a"
    s is s + "a"
    s is s + "a"
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
live_case cfg-entropy-ec-below ec_below
live_case cfg-entropy-ec-above ec_above
live_case cfg-entropy-es-below es_below
live_case cfg-entropy-es-above es_above
live_case cfg-entropy-report-partial rp_part

# R32-3: the fold's start values, bracketed. The trajectory is one value,
# one bump and nine returns, so the 11-value window's diameter is the bump.
# converged needs bump <= dh_zero * max(|x|, scale); stable needs
# bump / 2 <= dh_small * max(|midrange|, scale). The two bumps of each pair
# sit 2e-8 (relative) either side of the threshold the default implies, so
# a start dh_zero, dh_small or scale that is off by more than that, or held
# in a float, is red. The window is pinned exactly: ten repeats do not fill
# an 11-value window, eleven do.
cat > dz_in.eigs <<'EOF'
x is 1.0
x is 1.00099999998
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
print of (report of x)
EOF
cat > dz_out.eigs <<'EOF'
x is 1.0
x is 1.00100000002
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
print of (report of x)
EOF
cat > ds_in.eigs <<'EOF'
x is 1.0
x is 1.02020202
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
print of (report of x)
EOF
cat > ds_out.eigs <<'EOF'
x is 1.0
x is 1.0202020204040405
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
print of (report of x)
EOF
cat > sc_in.eigs <<'EOF'
x is 0.0
x is 9.999999799999999e-07
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
print of (report of x)
EOF
cat > sc_out.eigs <<'EOF'
x is 0.0
x is 1.00000002e-06
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
x is 0.0
print of (report of x)
EOF
cat > w10.eigs <<'EOF'
x is 1.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
print of (report of x)
EOF
cat > w11.eigs <<'EOF'
x is 1.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
x is 2.0
print of (report of x)
EOF
cat > dzx.eigs <<'EOF'
x is 1.0
x is 1.0010000002104689
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
x is 1.0
print of (report of x)
EOF
for program in dz_in dz_out ds_in ds_out sc_in sc_out w10 w11 dzx; do
    "$bin" --lint --json "$program.eigs" > "$program.lint"
    EIGS_TRACE="$program.tape" "$bin" "$program.eigs" > "$program.record"
done
install_case cfg-start-dh-zero-in dz_in ''
install_case cfg-start-dh-zero-out dz_out ''
install_case cfg-start-dh-small-in ds_in ''
install_case cfg-start-dh-small-out ds_out ''
install_case cfg-start-scale-in sc_in ''
install_case cfg-start-scale-out sc_out ''
install_case cfg-start-window-short w10 ''
install_case cfg-start-window-full w11 ''
# A record's value is carried at full double precision: this dh_zero is
# 1e-14 above the bump and 4.6e-11 above the nearest float below it.
install_case cfg-install-exact-none dzx ''
install_case cfg-install-exact dzx 'O 0 cfg 0.0010000002104789019 0.01 10 0.001'
# The smallest thresholds and the largest scale the checks admit.
cfg_case cfg-bounds-accepted 'O 0 cfg 1e-300 1e-299 10 1e300'

# R32-4: the entropy constant to 1e-8 (relative). Two six-letter strings of
# about 5000 bytes: entropy 0.1 - 1.04e-9 and 0.1 + 6.6e-10 (the counts are
# the search result recorded in briefs/out/r3-2/orch-sweep/progs/tight.json).
# A reader comparing against the float 0.1f (0.1 + 1.49e-9) is red on the
# second. The margins are 1e6 times libm's last bit; a string whose entropy
# is the double 0.1 exactly would not be a portable witness (RULING R32-4).
rep() { awk -v c="$1" -v n="$2" 'BEGIN { for (i = 0; i < n; i++) printf "%s", c }'; }
under="$(rep b 38)$(rep c 2)$(rep d 3)$(rep e 4)$(rep f 5)$(rep a 4804)"
over="$(rep b 34)$(rep c 1)$(rep d 9)$(rep e 7)$(rep f 2)$(rep a 4996)"
chunk=$(rep a 150)
near_const() {
    cat > "$1.eigs" <<EOF
define run() as:
    local s is "$2"
    local k is 0
    loop while k < 14:
        s is "$2"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
}
# The growing form reaches the same final string in 14 appends of 150 `a`s;
# every entropy step is between dh_zero and dh_small (0.0026 to 0.0069).
near_grow() {
    start=$(printf '%s' "$2" | cut -c1-$((${#2} - 2100)))
    cat > "$1.eigs" <<EOF
define run() as:
    local s is "$start"
    local k is 0
    loop while k < 14:
        s is s + "$chunk"
        k is k + 1
    return classify of [trajectory of s, "entropy"]
print of (run of null)
EOF
}
near_const ec_under "$under"
near_const ec_over "$over"
near_grow es_under "$under"
near_grow es_over "$over"
live_case cfg-entropy-ec-near-below ec_under
live_case cfg-entropy-ec-near-above ec_over
live_case cfg-entropy-es-near-below es_under
live_case cfg-entropy-es-near-above es_over
