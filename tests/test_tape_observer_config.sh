#!/bin/bash
# Observer configuration on the trace tape (#1044/#1045 follow-up).
#
# A verdict (`report of x`, the predicates, the `--step`/DAP trajectory
# labels) is a function of the ASSIGNMENTS and of the observer configuration:
# the three thresholds (set_observer_thresholds), the window depth
# (set_observer_window, state default and per-binding), and the
# characteristic scale (set_observer_scale). The tape used to carry only the
# assignments, so a stepped tape classified at the state defaults and printed
# a verdict the live run never gave.
#
# Every case here is the SAME assertion: the label `--step` prints equals the
# label the live run printed, for a program that moves a knob. Each case also
# names the label it expects, so a change that makes both sides equally wrong
# is caught too. `O`-stripped copies of the same tapes are the built-in
# discrimination control — they must reproduce the divergence.
#
# Run directly or from run_all_tests.sh. Prints PASS:/FAIL: lines and a
# summary. Exit code: 0 if all pass, 1 if any fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_obscfg.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "OBSCFG: 0 passed, 1 failed"
    exit 1
fi

# step_label <tape> <src> <binding> <commands...> -> the label `p <binding>`
# printed, e.g. "oscillating"
step_label() {
    local tape=$1 src=$2 name=$3; shift 3
    printf '%s\n' "$@" "p $name" q \
        | "$EIGS" --step "$tape" "$src" 2>/dev/null \
        | grep -E "^$name = " | tail -1 \
        | sed -n 's/.*\[\([a-z]*\)\].*/\1/p'
}

# ---- case driver -------------------------------------------------------
# knob_case <label> <binding> <expected> <src-file> <step-commands...>
# Records the tape, compares live vs --step vs EIGS_REPLAY, and proves the
# case discriminates by re-stepping an O-stripped copy of the same tape.
knob_case() {
    local what=$1 name=$2 want=$3 src=$4; shift 4
    local tape="$TMPDIR/$what.tape"
    local live replay stepped stripped
    live=$("$EIGS" "$src" 2>/dev/null | tail -1 | sed 's/.*=//')
    EIGS_TRACE="$tape" "$EIGS" "$src" >/dev/null 2>&1
    replay=$(EIGS_REPLAY="$tape" "$EIGS" "$src" 2>/dev/null | tail -1 | sed 's/.*=//')
    stepped=$(step_label "$tape" "$src" "$name" "$@")

    [ "$live" = "$want" ] \
        && ok "$what: live verdict is $want" \
        || fail "$what: live verdict is $want" "got '$live'"
    [ "$stepped" = "$live" ] \
        && ok "$what: --step agrees with the live run" \
        || fail "$what: --step agrees with the live run" "live=$live step=$stepped"
    [ "$replay" = "$live" ] \
        && ok "$what: EIGS_REPLAY agrees with the live run" \
        || fail "$what: EIGS_REPLAY agrees with the live run" "live=$live replay=$replay"

    grep -v '^O ' "$tape" > "$tape.noO"
    stripped=$(step_label "$tape.noO" "$src" "$name" "$@")
    [ -n "$stripped" ] && [ "$stripped" != "$live" ] \
        && ok "$what: dropping the O records reproduces the divergence" \
        || fail "$what: dropping the O records reproduces the divergence" \
                "stripped=$stripped live=$live"
}

# ---- 1. set_observer_window of ["u", n] — the per-binding override.
# The critic's phugoid reproducer: a 46.9-sample period cannot fold inside
# the default 10-wide window, so the live run widens u's window to 50 and
# reads `oscillating`; a tape that does not carry the override classifies
# the same 200 samples at depth 10 and says `diverging`.
cat > "$TMPDIR/win.eigs" <<'EOF'
u is 0.0
set_observer_window of ["u", 50]
t is 0
loop while t < 200:
    u is 272.4 + 10.0 * (cos of (6.283185307179586 * t / 46.9))
    t is t + 1
print of ("u=" + (report of u))
EOF
knob_case win u oscillating "$TMPDIR/win.eigs" "s 700"

# ---- 2. set_observer_window of n — the state default, same trajectory.
cat > "$TMPDIR/windef.eigs" <<'EOF'
set_observer_window of 50
u is 0.0
t is 0
loop while t < 200:
    u is 272.4 + 10.0 * (cos of (6.283185307179586 * t / 46.9))
    t is t + 1
print of ("u=" + (report of u))
EOF
knob_case windef u oscillating "$TMPDIR/windef.eigs" "s 700"

# ---- 3. set_observer_thresholds — the PRE-EXISTING instance of this class
# (it needs neither #1044 nor #1045). Relative steps of ~0.0044 sit under a
# raised dh_zero of 0.01, so the live run certifies `converged`; at the
# default dh_zero of 0.001 the same steps read `stable`.
cat > "$TMPDIR/thr.eigs" <<'EOF'
set_observer_thresholds of [0.01, 0.02, 0.1]
x is 1000.0
d is 5.0
i is 0
loop while i < 30:
    x is x + d
    d is d * 0.99
    i is i + 1
print of ("x=" + (report of x))
EOF
knob_case thr x converged "$TMPDIR/thr.eigs" "s 400"

# ---- 4. set_observer_scale — a trajectory inside the characteristic scale.
# With scale 0.1 every step is 5e-4 of the scale and the value certifies;
# at the default 1e-3 the same steps are ~4% of |x| and read `moving`.
cat > "$TMPDIR/scale.eigs" <<'EOF'
set_observer_scale of 0.1
x is 0.0
d is 0.00005
i is 0
loop while i < 30:
    x is x + d
    d is d * 0.99
    i is i + 1
print of ("x=" + (report of x))
EOF
knob_case scale x converged "$TMPDIR/scale.eigs" "s 400"

# ---- 5. a MID-RUN knob change: the two phases of one binding classify
# differently, and the stepper must reproduce BOTH. This is what a
# header/snapshot design could not do, and it is why the configuration is
# recorded as an event at the point it takes effect.
MID="$TMPDIR/mid.eigs"
cat > "$MID" <<'EOF'
x is 0.0
d is 0.00005
i is 0
loop while i < 20:
    x is x + d
    d is d * 0.99
    i is i + 1
print of ("phase1 x=" + (report of x))
set_observer_scale of 0.1
j is 0
loop while j < 20:
    x is x + d
    d is d * 0.99
    j is j + 1
print of ("phase2 x=" + (report of x))
EOF
MID_TAPE="$TMPDIR/mid.tape"
MID_LIVE=$("$EIGS" "$MID" 2>/dev/null)
EIGS_TRACE="$MID_TAPE" "$EIGS" "$MID" >/dev/null 2>&1
P1_LIVE=$(echo "$MID_LIVE" | sed -n 's/^phase1 x=//p')
P2_LIVE=$(echo "$MID_LIVE" | sed -n 's/^phase2 x=//p')
P2_STEP=$(step_label "$MID_TAPE" "$MID" x "s 1000")
P1_STEP=$(step_label "$MID_TAPE" "$MID" x "s 1000" "jb 8")

[ "$P1_LIVE" = "moving" ] && [ "$P2_LIVE" = "converged" ] \
    && ok "mid-run: the live run's two phases differ (moving -> converged)" \
    || fail "mid-run: the live run's two phases differ (moving -> converged)" \
            "p1=$P1_LIVE p2=$P2_LIVE"
[ "$P1_STEP" = "$P1_LIVE" ] \
    && ok "mid-run: --step reproduces the pre-change verdict" \
    || fail "mid-run: --step reproduces the pre-change verdict" \
            "live=$P1_LIVE step=$P1_STEP"
[ "$P2_STEP" = "$P2_LIVE" ] \
    && ok "mid-run: --step reproduces the post-change verdict" \
    || fail "mid-run: --step reproduces the post-change verdict" \
            "live=$P2_LIVE step=$P2_STEP"

# ---- 6. the tape says what it carries: the records are on it, and the
# `O cfg` record round-trips the exact doubles (%.17g).
grep -q '^O win u 50$' "$TMPDIR/win.tape" \
    && ok "tape carries the per-binding O win record" \
    || fail "tape carries the per-binding O win record"
grep -q '^O cfg 0.01 0.02 ' "$TMPDIR/thr.tape" \
    && ok "tape carries the state-level O cfg record" \
    || fail "tape carries the state-level O cfg record" \
            "$(grep '^O ' "$TMPDIR/thr.tape" | head -1)"
grep -q '^O cfg .* 50 ' "$TMPDIR/windef.tape" \
    && ok "O cfg carries the state window depth" \
    || fail "O cfg carries the state window depth" \
            "$(grep '^O ' "$TMPDIR/windef.tape" | head -1)"
# a program that touches no knob must not grow a single byte of O records
cat > "$TMPDIR/plain.eigs" <<'EOF'
x is 1
for i in range of 5:
    x is x * 2
EOF
EIGS_TRACE="$TMPDIR/plain.tape" "$EIGS" "$TMPDIR/plain.eigs" >/dev/null 2>&1
grep -q '^O ' "$TMPDIR/plain.tape" \
    && fail "a knobless program records no O records" \
    || ok "a knobless program records no O records"

# ---- 7. #411 version/compat path. The `O` records are an ENCODING change,
# so TRACE_FORMAT_VERSION went 2 -> 3 and the rule is the standing one:
# version-and-reject, never migrate. A v2 tape — one recorded by any earlier
# binary, whose knob calls are simply not on it — is refused loudly by both
# the stepper and replay rather than silently classified at the defaults.
head -1 "$TMPDIR/thr.tape" | grep -q '^V 3 ' \
    && ok "tapes written by this build stamp format v3" \
    || fail "tapes written by this build stamp format v3" \
            "$(head -1 "$TMPDIR/thr.tape")"

V2="$TMPDIR/v2.tape"
sed "1s/^V 3 /V 2 /" "$TMPDIR/thr.tape" > "$V2"
echo q | "$EIGS" --step "$V2" "$TMPDIR/thr.eigs" >/dev/null 2>"$TMPDIR/v2.err"
RC=$?
[ "$RC" -eq 3 ] && grep -q "tape format v2" "$TMPDIR/v2.err" \
    && ok "a v2 (pre-O-record) tape is refused by --step with exit 3" \
    || fail "a v2 (pre-O-record) tape is refused by --step with exit 3" \
            "rc=$RC $(head -1 "$TMPDIR/v2.err")"

EIGS_REPLAY="$V2" "$EIGS" "$TMPDIR/thr.eigs" >/dev/null 2>"$TMPDIR/v2r.err"
RC=$?
[ "$RC" -eq 3 ] && grep -q "format v2" "$TMPDIR/v2r.err" \
    && ok "a v2 (pre-O-record) tape is refused by EIGS_REPLAY with exit 3" \
    || fail "a v2 (pre-O-record) tape is refused by EIGS_REPLAY with exit 3" \
            "rc=$RC $(head -1 "$TMPDIR/v2r.err")"

# The two checks above rewrite this build's own header, which proves the
# refusal but not that a REAL pre-v3 tape looks the way we assume. So the
# suite also carries one: tests/fixtures/tape_v2_baseline.tape was recorded
# by the v0.43.0 release binary (whose tapes carry no `O` records at all) on
# tape_v2_baseline.eigs, which raises dh_zero and certifies `converged`. The
# deviation from "an old tape still steps" is DELIBERATE and is the #411
# rule: a v2 tape cannot carry the configuration, so stepping it would print
# a default-classified verdict the recorded run never gave — the exact
# failure this change removes. Refuse loudly, re-record.
V2REAL="$TESTS_DIR/fixtures/tape_v2_baseline.tape"
V2SRC="$TESTS_DIR/fixtures/tape_v2_baseline.eigs"
head -1 "$V2REAL" | grep -q '^V 2 ' \
    && ok "the checked-in baseline tape really is format v2" \
    || fail "the checked-in baseline tape really is format v2" \
            "$(head -1 "$V2REAL")"
echo q | "$EIGS" --step "$V2REAL" "$V2SRC" >/dev/null 2>"$TMPDIR/v2b.err"
RC=$?
[ "$RC" -eq 3 ] && grep -q "tape format v2" "$TMPDIR/v2b.err" \
    && ok "a REAL baseline-recorded v2 tape is refused by --step with exit 3" \
    || fail "a REAL baseline-recorded v2 tape is refused by --step with exit 3" \
            "rc=$RC $(head -1 "$TMPDIR/v2b.err")"
EIGS_REPLAY="$V2REAL" "$EIGS" "$V2SRC" >/dev/null 2>"$TMPDIR/v2br.err"
RC=$?
[ "$RC" -eq 3 ] && grep -q "format v2" "$TMPDIR/v2br.err" \
    && ok "a REAL baseline-recorded v2 tape is refused by EIGS_REPLAY with exit 3" \
    || fail "a REAL baseline-recorded v2 tape is refused by EIGS_REPLAY with exit 3" \
            "rc=$RC $(head -1 "$TMPDIR/v2br.err")"
# ...and the program it was recorded from is the pre-existing
# set_observer_thresholds instance of the class: re-record on this build and
# the stepped label matches the live one (the baseline's did not).
knob_case v2reg x converged "$V2SRC" "s 400"

# ---- 8. CROSS-SCOPE: an `O win` record is a property of ONE binding, not of
# a NAME. Every case here is a tape on which the same name has more than one
# history, so a reader that matches `O win u 50` by name alone prints a
# verdict the live run never gave — for the binding that never asked to be
# widened. Each program is asserted at its LAST stop (`s 99999`), which needs
# no hard-coded step index, and each pins the OPPOSITE label from its
# neighbour, so a reader that ignores the record and a reader that sprays it
# everywhere are both caught.
#
# The `--step` label and the DAP server's come from the same
# tape_traj_begin/feed, so this covers both surfaces.

# xscope_case <label> <expected> <src-file>
xscope_case() {
    local what=$1 want=$2 src=$3
    local tape="$TMPDIR/$what.tape"
    local live stepped
    live=$("$EIGS" "$src" 2>/dev/null | tail -1 | sed 's/.*=//')
    EIGS_TRACE="$tape" "$EIGS" "$src" >/dev/null 2>&1
    stepped=$(step_label "$tape" "$src" u "s 99999")
    [ "$live" = "$want" ] \
        && ok "$what: live verdict is $want" \
        || fail "$what: live verdict is $want" "got '$live'"
    [ "$stepped" = "$live" ] \
        && ok "$what: --step agrees with the live run at the last stop" \
        || fail "$what: --step agrees with the live run at the last stop" \
                "live=$live step=$stepped"
}

# (a) one function, two invocations, only the FIRST widens its window. The
# second frame's `u` is a different binding with the same name: it must read
# the default-window verdict. Name matching leaks the override forward and
# prints `oscillating` here.
cat > "$TMPDIR/xsleak.eigs" <<'EOF'
define run(m, wide) as:
    local u is 0.0
    local t is 0
    if wide > 0:
        set_observer_window of ["u", 50]
    loop while t < m:
        u is 272.4 + 10.0 * (cos of (6.283185307179586 * t / 46.9))
        t is t + 1
    return report of u
print of ("wide=" + (run of [200, 1]))
print of ("u=" + (run of [200, 0]))
EOF
xscope_case xsleak diverging "$TMPDIR/xsleak.eigs"

# (b) the same program with the order swapped: now the LAST frame is the one
# that widened, so the override must be applied — the control proving (a) is
# not green merely because the reader dropped the record.
cat > "$TMPDIR/xsapply.eigs" <<'EOF'
define run(m, wide) as:
    local u is 0.0
    local t is 0
    if wide > 0:
        set_observer_window of ["u", 50]
    loop while t < m:
        u is 272.4 + 10.0 * (cos of (6.283185307179586 * t / 46.9))
        t is t + 1
    return report of u
print of ("plain=" + (run of [200, 0]))
print of ("u=" + (run of [200, 1]))
EOF
xscope_case xsapply oscillating "$TMPDIR/xsapply.eigs"
XSAPPLY_STRIP=$(grep -v '^O ' "$TMPDIR/xsapply.tape" > "$TMPDIR/xsapply.noO"; \
                step_label "$TMPDIR/xsapply.noO" "$TMPDIR/xsapply.eigs" u "s 99999")
[ "$XSAPPLY_STRIP" = "diverging" ] \
    && ok "xsapply: dropping the O records reproduces the divergence" \
    || fail "xsapply: dropping the O records reproduces the divergence" \
            "stripped=$XSAPPLY_STRIP"

# (c) the override is set on a PARAMETER, before the frame has assigned
# anything, while a module-level `u` of its own is already on the tape. The
# scope transition is stamped by the record itself, so the reader resolves
# the name from the frame that made the call — without it the record carries
# the module's scope and resolves to the module's `u`, and the parameter's
# window is silently lost.
cat > "$TMPDIR/xsparam.eigs" <<'EOF'
define run(u) as:
    set_observer_window of ["u", 50]
    local s is 0
    loop while s < 200:
        u is 272.4 + 10.0 * (cos of (6.283185307179586 * s / 46.9))
        s is s + 1
    return report of u
u is 0.0
t is 0
loop while t < 200:
    u is 272.4 + 10.0 * (cos of (6.283185307179586 * t / 46.9))
    t is t + 1
print of ("mod=" + (report of u))
print of ("u=" + (run of [0.0]))
EOF
xscope_case xsparam oscillating "$TMPDIR/xsparam.eigs"
grep -q '^S run ' "$TMPDIR/xsparam.tape" && \
  [ "$(grep -n '^S run \|^O win u 50$' "$TMPDIR/xsparam.tape" | head -2 | \
       sed -n '1s/:.*//p')" -lt \
    "$(grep -n '^O win u 50$' "$TMPDIR/xsparam.tape" | sed -n '1s/:.*//p')" ] \
    && ok "xsparam: the O win record is preceded by its own frame's S record" \
    || fail "xsparam: the O win record is preceded by its own frame's S record" \
            "$(grep -n '^S \|^O ' "$TMPDIR/xsparam.tape" | head -4 | tr '\n' ' ')"

# (d) a function-local `u` widens its window; a module-level `u` with the
# same trajectory is assigned AFTER the call, so the `O win` record precedes
# its assigns and a name-matching reader applies it to the module binding.
cat > "$TMPDIR/xsouter.eigs" <<'EOF'
define inner() as:
    local u is 0.0
    set_observer_window of ["u", 50]
    local t is 0
    loop while t < 200:
        u is 272.4 + 10.0 * (cos of (6.283185307179586 * t / 46.9))
        t is t + 1
    return report of u
print of ("inner=" + (inner of []))
u is 0.0
t is 0
loop while t < 200:
    u is 272.4 + 10.0 * (cos of (6.283185307179586 * t / 46.9))
    t is t + 1
print of ("u=" + (report of u))
EOF
xscope_case xsouter diverging "$TMPDIR/xsouter.eigs"

# ---- 9. POST-ASSIGN knob changes. The knobs split by when the runtime reads
# them: the window and the scale are consumed while a value is RECORDED, the
# three thresholds (and the window again, for the full-window certifications)
# while a verdict is REPORTED. So a knob moved AFTER a binding's last assign
# and before the stop still changes what `report of x` says there — and a
# reader that folds the configuration only up to the last assign drops
# exactly those and prints a confident wrong label.
#
# stop_label <tape> <src> <binding> <commands...> is step_label; each case
# below asserts the label at a stop BEFORE the knob call and at the LAST
# stop, so a reader that applies every record regardless of position is
# caught by the first assertion and one that applies none by the second.

# post_case <label> <binding> <before> <after> <before-line> <src-file>
post_case() {
    local what=$1 name=$2 want1=$3 want2=$4 line=$5 src=$6
    local tape="$TMPDIR/$what.tape"
    local live1 live2 step1 step2 stripped
    live1=$("$EIGS" "$src" 2>/dev/null | sed -n 's/^before=//p')
    live2=$("$EIGS" "$src" 2>/dev/null | sed -n "s/^$name=//p")
    EIGS_TRACE="$tape" "$EIGS" "$src" >/dev/null 2>&1
    step2=$(step_label "$tape" "$src" "$name" "s 99999")
    step1=$(step_label "$tape" "$src" "$name" "s 99999" "jb $line")

    [ "$live1" = "$want1" ] && [ "$live2" = "$want2" ] \
        && ok "$what: the live run's verdict moves ($want1 -> $want2)" \
        || fail "$what: the live run's verdict moves ($want1 -> $want2)" \
                "before=$live1 after=$live2"
    [ "$step2" = "$live2" ] \
        && ok "$what: --step at the last stop agrees with the live run" \
        || fail "$what: --step at the last stop agrees with the live run" \
                "live=$live2 step=$step2"
    [ "$step1" = "$live1" ] \
        && ok "$what: --step BEFORE the knob call still reads the old verdict" \
        || fail "$what: --step BEFORE the knob call still reads the old verdict" \
                "live=$live1 step=$step1"
    grep -v '^O ' "$tape" > "$tape.noO"
    stripped=$(step_label "$tape.noO" "$src" "$name" "s 99999")
    [ -n "$stripped" ] && [ "$stripped" != "$live2" ] \
        && ok "$what: dropping the O records reproduces the divergence" \
        || fail "$what: dropping the O records reproduces the divergence" \
                "stripped=$stripped live=$live2"
}

# (a) set_observer_thresholds AFTER the loop — the pre-existing instance of
# the class, in the shape that survived the first fix: the record is on the
# tape and precedes the stop, and the thresholds are read at REPORT time.
cat > "$TMPDIR/postthr.eigs" <<'EOF'
x is 1000.0
d is 5.0
i is 0
loop while i < 30:
    x is x + d
    d is d * 0.99
    i is i + 1
print of ("before=" + (report of x))
set_observer_thresholds of [0.01, 0.02, 0.1]
print of ("x=" + (report of x))
EOF
post_case postthr x stable converged 8 "$TMPDIR/postthr.eigs"

# (b) the per-binding window, moved after the last assign: a full 10-window
# certifies `converged`, and widening to 50 leaves the same ten samples a
# PARTIAL window, which can only say `stable`.
cat > "$TMPDIR/postwin.eigs" <<'EOF'
x is 1000.0
d is 0.0001
i is 0
loop while i < 30:
    x is x + d
    d is d * 0.99
    i is i + 1
print of ("before=" + (report of x))
set_observer_window of ["x", 50]
print of ("x=" + (report of x))
EOF
post_case postwin x converged stable 8 "$TMPDIR/postwin.eigs"

# (c) the same through the state default (`O cfg`, not `O win`).
cat > "$TMPDIR/postdef.eigs" <<'EOF'
x is 1000.0
d is 0.0001
i is 0
loop while i < 30:
    x is x + d
    d is d * 0.99
    i is i + 1
print of ("before=" + (report of x))
set_observer_window of 50
print of ("x=" + (report of x))
EOF
post_case postdef x converged stable 8 "$TMPDIR/postdef.eigs"

# The `t` view's rows are per-moment by construction, so the settled label
# gets its own line rather than letting the last row speak for the stop.
TRAJ=$(printf 's 99999\nt x\nq\n' | "$EIGS" --step "$TMPDIR/postthr.tape" \
       "$TMPDIR/postthr.eigs" 2>/dev/null | tail -1)
case "$TRAJ" in
  *"configuration changed after the last assign"*"[converged]"*)
        ok "the t view names the settled label when the knob moved after it" ;;
  *)    fail "the t view names the settled label when the knob moved after it" \
             "$TRAJ" ;;
esac
TRAJ=$(printf 's 99999\nt x\nq\n' | "$EIGS" --step "$TMPDIR/thr.tape" \
       "$TMPDIR/thr.eigs" 2>/dev/null | tail -1)
case "$TRAJ" in
  *"configuration changed"*)
        fail "no such note when the configuration did not move" "$TRAJ" ;;
  *)    ok "no such note when the configuration did not move" ;;
esac

# ---- 10. A CORRUPT `O` record is refused, not installed. The reader
# installs these values into its own observer state, so a window of 0 divides
# by zero sizing the ring and a negative one asks calloc for 2^64-1 bytes.
# Tapes travel in #413 attached-tape bundles, so a record this runtime could
# not have written is refused loudly like a torn archive — clamping would
# classify under a configuration the recording run never had, which is the
# same confident lie in a new costume.
corrupt_case() {
    local what=$1 sedexpr=$2 src=$3 tape=$4
    sed "$sedexpr" "$tape" > "$TMPDIR/corrupt.tape"
    printf 's 99999\np x\nt x\nq\n' \
        | "$EIGS" --step "$TMPDIR/corrupt.tape" "$src" \
          >/dev/null 2>"$TMPDIR/corrupt.err"
    local rc=$?
    [ "$rc" -eq 3 ] && grep -q "observer-configuration record" "$TMPDIR/corrupt.err" \
        && ok "corrupt O record refused with exit 3: $what" \
        || fail "corrupt O record refused with exit 3: $what" \
                "rc=$rc $(head -1 "$TMPDIR/corrupt.err")"
}
corrupt_case "window 0"        's/^O cfg \(.*\) [0-9]* \(.*\)$/O cfg \1 0 \2/'  "$TMPDIR/thr.eigs" "$TMPDIR/thr.tape"
corrupt_case "window -5"       's/^O cfg \(.*\) [0-9]* \(.*\)$/O cfg \1 -5 \2/' "$TMPDIR/thr.eigs" "$TMPDIR/thr.tape"
corrupt_case "window 4000000000" 's/^O cfg \(.*\) [0-9]* \(.*\)$/O cfg \1 4000000000 \2/' "$TMPDIR/thr.eigs" "$TMPDIR/thr.tape"
corrupt_case "scale 0"         's/^O cfg \(.*\) \(.*\)$/O cfg \1 0/'             "$TMPDIR/thr.eigs" "$TMPDIR/thr.tape"
corrupt_case "dh_zero >= dh_small" 's/^O cfg [^ ]* /O cfg 9 /'                    "$TMPDIR/thr.eigs" "$TMPDIR/thr.tape"
corrupt_case "truncated cfg"   's/^O cfg .*/O cfg 0.01/'                          "$TMPDIR/thr.eigs" "$TMPDIR/thr.tape"
corrupt_case "per-binding window -1" 's/^O win u .*/O win u -1/'                    "$TMPDIR/win.eigs" "$TMPDIR/win.tape"
corrupt_case "per-binding window 999" 's/^O win u .*/O win u 999/'                 "$TMPDIR/win.eigs" "$TMPDIR/win.tape"
# ...and a well-formed tape is still accepted after all that (the refusal is
# the record's, not the reader having stopped reading O records at all).
[ "$(step_label "$TMPDIR/win.tape" "$TMPDIR/win.eigs" u "s 700")" = "oscillating" ] \
    && ok "a well-formed O record is still accepted" \
    || fail "a well-formed O record is still accepted"

# `O win <name> 0` is the CLEAR form, not a corrupt window: a program that
# widens a binding and then clears it must step exactly as it ran, and the
# validation above must not refuse the record that expresses it.
cat > "$TMPDIR/clear.eigs" <<'EOF'
u is 0.0
set_observer_window of ["u", 50]
t is 0
loop while t < 200:
    u is 272.4 + 10.0 * (cos of (6.283185307179586 * t / 46.9))
    t is t + 1
print of ("wide=" + (report of u))
set_observer_window of ["u", 0]
print of ("u=" + (report of u))
EOF
CLEAR_LIVE=$("$EIGS" "$TMPDIR/clear.eigs" 2>/dev/null | sed -n 's/^u=//p')
EIGS_TRACE="$TMPDIR/clear.tape" "$EIGS" "$TMPDIR/clear.eigs" >/dev/null 2>&1
CLEAR_STEP=$(step_label "$TMPDIR/clear.tape" "$TMPDIR/clear.eigs" u "s 99999")
grep -q '^O win u 0$' "$TMPDIR/clear.tape" \
    && ok "the per-binding CLEAR is recorded as O win <name> 0" \
    || fail "the per-binding CLEAR is recorded as O win <name> 0" \
            "$(grep '^O ' "$TMPDIR/clear.tape" | tr '\n' ' ')"
[ -n "$CLEAR_STEP" ] && [ "$CLEAR_STEP" = "$CLEAR_LIVE" ] \
    && ok "--step honours the CLEAR record (both $CLEAR_LIVE)" \
    || fail "--step honours the CLEAR record" \
            "live=$CLEAR_LIVE step=$CLEAR_STEP"

echo "OBSCFG: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
