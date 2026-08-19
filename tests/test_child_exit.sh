#!/bin/bash
# #988 — a child .sh test that exits nonzero, or that runs no checks at all,
# must fail its section.
#
# tools/child_exit_check.sh proves the accounting mechanism is PRESENT and
# unbypassable (a static gate over run_all_tests.sh). This proves it WORKS:
# it runs the real wrapper against the three failure modes the issue
# reproduced — exit 139 (SEGV), exit 127 (missing child), exit 1 — plus the
# zero-check mode, and requires a failure in each.
#
# The wrapper is extracted from run_all_tests.sh rather than restated here
# (mechanical-gates §26: read the declared home, never a copy — a second
# implementation would drift and this test would then certify itself).
#
# The two SECTION idioms below ARE restated deliberately. That makes them
# oracles rather than mirrors: they are independent statements of the two call
# shapes the suite uses (capture-and-grep, and `if bash …; then`), so if
# run_all_tests.sh drifts away from them that is a finding rather than
# something this file silently follows.

set -u
cd "$(dirname "$0")" || exit 1

RUNNER="${RUNNER:-run_all_tests.sh}"
PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_childexit.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# --- extract the real wrapper + its waiver list ---------------------------
sed -n '/^CHILD_NO_MARKERS=/p' "$RUNNER"            > "$WORK/wrapper.sh"
sed -n '/^bash() {$/,/^}$/p'   "$RUNNER"           >> "$WORK/wrapper.sh"
# Sanity-start the probe before trusting any result (mechanical-gates §19).
# Anchored on `command bash` — the call-through, which no single mechanism
# under test supplies. Anchoring on CHILD_LEDGER would be satisfied by the
# very ledger-append line one of the mutations removes, so that mutation
# would go red here as a "harness bug" instead of at its own assertion.
if ! grep -q 'command bash' "$WORK/wrapper.sh" || ! grep -q '^bash() {' "$WORK/wrapper.sh"; then
    echo "  FAIL: could not extract a runnable bash() wrapper from $RUNNER — harness bug, not a verdict"
    echo "RESULTS: 0/1 passed, 1 failed"
    exit 1
fi

# Idiom A — capture the child, count markers, decide. This is verbatim the
# shape that was unsound before #988, and it is what ~45 sites use.
run_capture_section() {   # <child-path>
    (
        CHILD_LEDGER="$WORK/ledger"; : > "$CHILD_LEDGER"
        . "$WORK/wrapper.sh"
        OUT=$(bash "$1" 2>&1)
        F=$(printf '%s\n' "$OUT" | grep -c "FAIL:")
        P=$(printf '%s\n' "$OUT" | grep -c "PASS:")
        if [ "$F" -gt 0 ]; then echo "SECTION=FAIL pass=$P fail=$F"
        else echo "SECTION=PASS pass=$P fail=$F"; fi
        echo "LEDGER=$(wc -l < "$CHILD_LEDGER" | tr -d ' ')"
    )
}

# Idiom B — decide purely on the child's RETURN STATUS. Roughly ten sites use
# this (`if bash tools/doc_drift_check.sh; then`, the four --selftest gates,
# test_lint_linkage.sh, test_module_resolve_base.sh, and [99o] itself). It has
# a different witness: the wrapper must PROPAGATE the status, not just print.
run_status_section() {   # <child-path>
    (
        CHILD_LEDGER="$WORK/ledger"; : > "$CHILD_LEDGER"
        . "$WORK/wrapper.sh"
        if bash "$1" >/dev/null 2>&1; then echo "SECTION=PASS"; else echo "SECTION=FAIL"; fi
    )
}

expect_capture_fail() {   # <label> <child>
    local out; out=$(run_capture_section "$2")
    case "$out" in
        *SECTION=FAIL*) ok "$1 — capture-idiom section fails" ;;
        *) bad "$1 — capture-idiom section reported a pass ($out)" ;;
    esac
    case "$out" in
        *LEDGER=0*) bad "$1 — child not recorded in the ledger ($out)" ;;
        *) ok "$1 — child recorded in the ledger" ;;
    esac
}

# --- case 1: child prints PASS markers, then SEGVs (issue's exit 139) ------
cat > "$WORK/test_segv.sh" <<'EOF'
#!/bin/bash
echo "  PASS: TP01 output produced"
echo "  PASS: TP02 output well-formed"
kill -SEGV $$
EOF
expect_capture_fail "segv after clean markers" "$WORK/test_segv.sh"

# --- case 2: child is MISSING (issue's exit 127, "0/0 passed") -------------
expect_capture_fail "missing child script" "$WORK/test_absent.sh"

# --- case 3: child exits 1 silently ---------------------------------------
cat > "$WORK/test_exit1.sh" <<'EOF'
#!/bin/bash
echo "  PASS: something"
exit 1
EOF
expect_capture_fail "silent exit 1" "$WORK/test_exit1.sh"

# --- case 4: STATUS PROPAGATION through the `if bash …; then` idiom -------
# Without this, a wrapper that printed the synthetic marker but returned 0
# would score full marks while ~10 real sites silently went green. (That
# mutation — `return $__rc` -> `return 0` — survived the first version of
# this file.)
if [ "$(run_status_section "$WORK/test_exit1.sh")" = "SECTION=FAIL" ]; then
    ok "status-idiom section fails (wrapper propagates the exit status)"
else
    bad "status-idiom section passed — the wrapper swallowed the child's status"
fi

# --- case 5: ZERO CHECKS on a clean exit ----------------------------------
# The bar's second sentence. A child can exit 0 having done nothing, and the
# section then prints "all 0 checks" as a pass and contributes 0 to TOTAL.
cat > "$WORK/test_vacuous.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
VAC=$(run_capture_section "$WORK/test_vacuous.sh")
case "$VAC" in
    *SECTION=FAIL*) ok "child exiting 0 with zero checks fails its section" ;;
    *) bad "child exiting 0 with zero checks reported a pass ($VAC)" ;;
esac

# --- case 6: the vacuity WAIVER actually fires ----------------------------
# CHILD_NO_MARKERS exempts children that legitimately print no markers. If the
# waiver did not work, those two real sections would fail every run.
WAIVED=$(run_capture_section "$WORK/test_lsp.sh" 2>/dev/null)
cat > "$WORK/test_lsp.sh" <<'EOF'
#!/bin/bash
echo "some prose the python driver printed"
exit 0
EOF
WAIVED=$(run_capture_section "$WORK/test_lsp.sh")
case "$WAIVED" in
    *SECTION=PASS*) ok "waived child (test_lsp.sh) is exempt from the vacuity rule" ;;
    *) bad "waived child was failed by the vacuity rule ($WAIVED)" ;;
esac

# --- positive control: a clean child must still PASS ----------------------
cat > "$WORK/test_clean.sh" <<'EOF'
#!/bin/bash
echo "  PASS: genuinely fine"
exit 0
EOF
CLEAN=$(run_capture_section "$WORK/test_clean.sh")
case "$CLEAN" in
    *SECTION=PASS*) ok "clean child still passes (no false alarm)" ;;
    *) bad "clean child was failed by the wrapper ($CLEAN)" ;;
esac
case "$CLEAN" in
    *LEDGER=0*) ok "clean child leaves the ledger empty" ;;
    *) bad "clean child was recorded in the ledger ($CLEAN)" ;;
esac

# --- the wrapper must REPLAY the captured output verbatim -----------------
# Capture is an implementation detail of the vacuity rule; if it swallowed or
# mangled a child's output, every section's marker counting would shift.
REPLAY=$(
    CHILD_LEDGER="$WORK/ledger3"; : > "$CHILD_LEDGER"
    . "$WORK/wrapper.sh"
    bash "$WORK/test_clean.sh" 2>&1
)
if [ "$REPLAY" = "  PASS: genuinely fine" ]; then
    ok "captured child output is replayed verbatim"
else
    bad "captured output was altered: got '$REPLAY'"
fi

# --- `bash -c` must stay unaccounted (section [99f] depends on it) --------
INLINE=$(
    CHILD_LEDGER="$WORK/ledger4"; : > "$CHILD_LEDGER"
    . "$WORK/wrapper.sh"
    bash -c 'exit 3' >/dev/null 2>&1
    echo "rc=$? ledger=$(wc -l < "$CHILD_LEDGER" | tr -d ' ')"
)
if [ "$INLINE" = "rc=3 ledger=0" ]; then
    ok "bash -c inline program stays unaccounted, status still propagates"
else
    bad "bash -c was accounted for or lost its status ($INLINE)"
fi

# …and specifically when the inline PROGRAM TEXT ends in `.sh`. Without this
# the `-c` handling has no witness of its own: for an ordinary command string
# the `.sh` filter rejects it anyway, so the two guards cover each other and
# either can be deleted with this file still green (mechanical-gates §42 —
# a surviving mutation is either redundancy or a missing witness; this case
# decides which).
# The input is deliberately contrived — a command string whose TEXT ends in
# `.sh` — because that is the only shape where the two guards disagree, and
# a witness that does not discriminate is not a witness. The realistic form
# it stands in for is `bash -c 'some_helper.sh'`.
INLINE_SH=$(
    CHILD_LEDGER="$WORK/ledger7"; : > "$CHILD_LEDGER"
    . "$WORK/wrapper.sh"
    bash -c 'exit 6  # trailing.sh' >/dev/null 2>&1
    echo "rc=$? ledger=$(wc -l < "$CHILD_LEDGER" | tr -d ' ')"
)
if [ "$INLINE_SH" = "rc=6 ledger=0" ]; then
    ok "bash -c whose program text ends in .sh is still not treated as a child"
else
    bad "bash -c with .sh-ending program text was accounted for ($INLINE_SH)"
fi

# --- a NON-.sh argument must stay unaccounted -----------------------------
# Separate witness from the `-c` case above. Previously the two guards masked
# each other: removing either alone left the file green, so neither was
# actually tested (mechanical-gates §41).
NONSH=$(
    CHILD_LEDGER="$WORK/ledger5"; : > "$CHILD_LEDGER"
    . "$WORK/wrapper.sh"
    printf '#!/bin/bash\nexit 4\n' > "$WORK/plainfile"
    bash "$WORK/plainfile" >/dev/null 2>&1
    echo "rc=$? ledger=$(wc -l < "$CHILD_LEDGER" | tr -d ' ')"
)
if [ "$NONSH" = "rc=4 ledger=0" ]; then
    ok "non-.sh argument stays unaccounted, status still propagates"
else
    bad "non-.sh argument was accounted for or lost its status ($NONSH)"
fi

# --- option-taking flags must not steal the script path -------------------
# `bash -o pipefail t.sh` bound the OPTION VALUE as the script path, so the
# `.sh` filter dropped a real child and it escaped accounting entirely.
OPTARG=$(
    CHILD_LEDGER="$WORK/ledger6"; : > "$CHILD_LEDGER"
    . "$WORK/wrapper.sh"
    bash -o pipefail "$WORK/test_exit1.sh" >/dev/null 2>&1
    echo "rc=$? ledger=$(wc -l < "$CHILD_LEDGER" | tr -d ' ')"
)
if [ "$OPTARG" = "rc=1 ledger=1" ]; then
    ok "option-taking flag (-o) does not hide the script path"
else
    bad "child behind '-o pipefail' escaped accounting ($OPTARG)"
fi

echo "RESULTS: $PASS/$((PASS + FAIL)) passed, $FAIL failed"

# ---------------------------------------------------------------------------
# --selftest: mutation-test the WRAPPER. Neuter one mechanism at a time in a
# copy of the runner and require this file to go red — a mechanism no
# assertion witnesses is untested however many checks pass above.
#
# This train is why several of the cases above exist. Its first run scored
# 7/9: `return $__rc` -> `return 0` survived (status propagation had no
# witness at all, while ~10 real sites decide purely on it), and the `-c`
# exemption survived because the `.sh` filter rejected the same inputs — the
# two guards covered each other, so either could be deleted with the file
# still green.
#
# This train needs `python3`, which the surrounding suite treats as OPTIONAL
# (sections [89]/[90] skip without it). Here a missing python3 makes every
# mutation fail to apply, which is reported as SELFTEST BROKEN and fails the
# section — deliberately stricter, and stated rather than assumed. The reason
# is that the alternative is worse: a mutation train that silently does not
# run leaves the section green while proving nothing, which is the
# shrink-without-a-source-edit failure this whole file exists to prevent. An
# unrunnable instrument is BROKEN, never a verdict.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
    [ "$FAIL" -eq 0 ] || { echo "SELFTEST SKIPPED: base run is already red"; exit 1; }
    ST_RC=0
    mutate() {   # mutate <name> <python-expr-on-s>
        local name="$1" prog="$2"
        cp "$RUNNER" "$WORK/mut.sh"
        python3 - "$WORK/mut.sh" "$prog" <<'PY'
import sys
p, prog = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8').read()
s = eval(prog, {'s': s})
open(p, 'w', encoding='utf-8').write(s)
PY
        if cmp -s "$WORK/mut.sh" "$RUNNER"; then
            echo "  SELFTEST BROKEN: '$name' changed nothing — the fault never existed"
            ST_RC=1; return
        fi
        if RUNNER="$WORK/mut.sh" "$0" >/dev/null 2>&1; then
            echo "  SELFTEST FAIL: '$name' survived — that mechanism has no witness"
            ST_RC=1
        else
            echo "  mutation caught: $name"
        fi
    }

    mutate "ledger append removed" \
      "s.replace('        printf \'%s\\\\t%s\\\\n\' \"\$__rc\" \"\$__what\" >> \"\$CHILD_LEDGER\"\n', '', 1)"
    mutate "exit status swallowed (return 0)" \
      "s.replace('        return \$__rc\n    fi', '        return 0\n    fi', 1)"
    mutate "synthetic FAIL marker removed" \
      "s.replace('        echo \"  FAIL: \$__base \$__why without completing', '        : \"  FAIL: \$__base \$__why without completing', 1)"
    mutate "-c exemption removed" \
      "s.replace('            -c) __what=\"\"; break ;;\n', '', 1)"
    mutate ".sh filter removed" \
      "s.replace('    case \"\$__what\" in\n        *.sh) ;;\n        *) command bash \"\$@\"; return \$? ;;\n    esac\n', '', 1)"
    mutate "vacuity rule removed" \
      "s.replace('            if ! printf \'%s\\\\n\' \"\$__out\" | grep -q -E \'(PASS|FAIL):\'; then', '            if false; then', 1)"
    mutate "no-marker waiver removed" \
      "s.replace('            case \"\$CHILD_NO_MARKERS\" in\n                *\" \$__base \"*) return 0 ;;\n            esac\n', '', 1)"
    mutate "option-argument skip removed" \
      "s.replace('            -o|-O|--rcfile|--init-file) __skipnext=1 ;;\n', '', 1)"
    mutate "captured output not replayed" \
      "s.replace('            [ -n \"\$__out\" ] && printf \'%s\\\\n\' \"\$__out\"\n', '', 1)"

    [ "$ST_RC" -eq 0 ] && echo "SELFTEST: every wrapper mechanism has a witness"
    exit "$ST_RC"
fi

[ "$FAIL" -eq 0 ]
