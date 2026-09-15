#!/bin/bash
# tools/section_plan.sh — derive a per-variant SECTION PLAN for the suite (#1160)
#
# WHY THIS EXISTS
# ---------------
# Ten CI jobs run the SAME ~240-section suite (tests/run_all_tests.sh),
# differing only in the extension surface of the binary they built. Measured on
# PR #1158: 35 min wall, ~200 machine-minutes, 26 checks. A zlib build has
# exactly one section the gcc build does not ([124]); it paid for 240.
#
# So a variant job should run its OWN sections plus a small core smoke. The
# list of "its own sections" must NOT be hand-written: a hand list is a sibling
# list that drifts from the tree and validates nothing (mechanical-gates §1).
#
# WHAT IT IS DERIVED FROM
# -----------------------
# The suite already answers the question itself. Eleven sections are
# PROBE-GATED: the suite writes a tiny .eigs program that names an extension
# builtin, runs it against the binary under test, and skips the section when
# the output says the name is undefined (or, for zlib, when the stub message
# appears). That probe is THE authority on "does this binary have this
# capability", and it is the same code the suite runs.
#
# This tool therefore:
#   1. splits tests/run_all_tests.sh into top-level CHUNKS, asking bash itself
#      where a top-level statement ends (`bash -n` on each candidate prefix) —
#      never a hand-written line table;
#   2. finds every probe site by its STRUCTURE (the <NAME>_PROBE_FILE heredoc,
#      the <NAME>_PROBE_OUT=$(./eigenscript ...) capture, and the `if ! echo
#      ... grep -q "<pattern>"` guard), and refuses to run if a chunk contains
#      a *_PROBE_OUT it cannot parse;
#   3. RUNS each probe program against the binary under test and applies the
#      suite's own predicate;
#   4. emits a filtered runner containing the preamble, the chunks whose
#      capability is present, the fixed core smoke, and the epilogue.
#
# Every count is printed and floored the way [99i] floors its per-target
# examined counts: a plan that SHRINKS is a review event, and a plan of zero
# sections is a hard failure (a job that measured nothing must not be green).
#
# Usage:
#   tools/section_plan.sh --chunks [--runner F]
#       print the derived chunk table (line ranges + section ids)
#   tools/section_plan.sh --probes [--runner F]
#       print the derived probe table (no binary needed)
#   tools/section_plan.sh --print-section-plan <variant> [--binary B]
#       print the plan for <variant>: capabilities, sections, counts, floors
#   tools/section_plan.sh --emit <variant> <outfile> [--binary B]
#       write the filtered runner for <variant>
#   tools/section_plan.sh --selftest
#       planted-fault mutation train (runs against COPIES, never the tree)
#
# Exit 0 = derived and within floors. 1 = a structural failure, an unparsable
# probe, an empty plan, an under-floor plan, or a selftest failure.

set -u

SP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$SP_ROOT/tests/run_all_tests.sh"
BINARY=""
VERBOSE=1

# ---------------------------------------------------------------------------
# Pinned floors. These are the mechanical half of "nothing silently measures
# less": the plan for a variant is DERIVED, and a derived population shrinks
# without anything failing unless a floor watches it (mechanical-gates §43).
#
# ROUND 2 (#1160): the round-1 parser recognised ONE gate spelling — the
# `<X>_PROBE_FILE` / `<X>_PROBE_OUT=$(...)` / `grep -q` block — found 11 of
# them, and pinned a floor of 11. That floor pinned WHAT THE PARSER FOUND, not
# WHAT EXISTS: four more capability gates are spelled differently and were
# dropped from every plan.
#     [97]  an inline `EX_HAS_GFX=0; if ! ./eigenscript "$EX_GFX_PROBE" … ; fi`
#     [138] tools/gfx_pixel_differential.sh self-skips "built without …EXT_GFX"
#     [139] tools/gfx_strict_sweep.sh self-skips the same way
#     [80]  tests/test_replay.sh gates its audio-capture replay checks the same
# A blind critic proved the consequence: plant an undefined builtin in
# examples/ui_dock.eigs, and `EIGS_SUITE_SECTIONS=gfx` was 173/173 GREEN while
# the pre-change gfx job would have failed [97].
#
# So the gates are now DECLARED at the site with a normalised marker,
#     # EIGS-CAP-GATE: <capability>
# and the population is pinned against an INDEPENDENT enumeration (see
# gate_audit below) rather than against the parser's own yield.
CAP_MARKER_FLOOR=15        # markers that must be found in the runner
GATE_HIT_FLOOR=40          # lines the independent enumeration must still find

# Per-variant floors. TWO of them, because each catches a different shrink:
#   caps   - distinct capabilities the binary must actually present. This is
#            what a broken registration trips: `make http` with http_route
#            unregistered still builds and its plan collapses to the smoke.
#   chunks - marked chunks selected. Catches a marker being deleted or a gate
#            losing its marker while the capability is still present.
variant_caps_floor() {
    case "$1" in
        http|asan-http) echo 2 ;;   # http + model
        full)           echo 4 ;;   # http + model + db + net
        db)             echo 1 ;;
        zlib)           echo 1 ;;
        net)            echo 1 ;;
        gfx|asan-gfx)   echo 1 ;;   # gfx is one capability behind nine sections
        core|release)   echo 0 ;;
        *)              echo "" ;;  # unknown variant -> hard error
    esac
}
variant_chunks_floor() {
    case "$1" in
        http|asan-http) echo 3 ;;   # [17] transformer, [44-45] http, [47] model
        full)           echo 5 ;;   # those three + [46] db + [125] net
        db)             echo 1 ;;
        zlib)           echo 1 ;;
        net)            echo 1 ;;
        gfx|asan-gfx)   echo 9 ;;   # [62] [80] [97] [120b] [132] [133] [134] [138] [139]
        core|release)   echo 0 ;;
        *)              echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# The INDEPENDENT enumeration that the marker population is pinned against.
#
# This is the critics' own grep, not the parser's: every line in the runner or
# in a child script the runner dispatches that reads like a capability gate.
# It is deliberately OVER-BROAD (mechanical-gates §12: a cross-check must be
# looser on the axis it polices — here, the SPELLING). Every hit must be either
#   * inside a chunk that carries an EIGS-CAP-GATE marker, or
#   * dispatched from such a chunk (for a child script), or
#   * named in GATE_WAIVERS below, with a reason.
# Anything else is a hard failure: a new gate spelling cannot enter the tree
# without either a marker or a reviewed waiver.
GATE_ENUM_RE='ndefined variable|compiled without zlib|built without|no gfx build'

# Each waiver is "<path>|<16-hex sha256 of the EXACT line>|<reason, with an
# excerpt so a reader can see what was waived>". The hash is the pin: edit the
# line, or add another matching line to the same file, and the waiver stops
# matching and the audit refuses. A waiver that matches nothing is also a hard
# failure. Regenerate candidates with `--gate-audit --print-waivers`, which
# prints paste-ready rows for the UNACCOUNTED lines and writes nothing — the
# reason is a human's to write, never the tool's.
GATE_WAIVERS='
tests/run_all_tests.sh|21a0668fa22c22ae|an ERROR-MESSAGE assertion in [16/16] (EM7), not a capability gate
tests/run_all_tests.sh|ffca76c3b2f07310|the EXPECTED TEXT of that same EM7 assertion
tests/run_all_tests.sh|271a756702672bf6|the expected text of the undefined-name error example
tests/run_all_tests.sh|c29802447b0bdd10|prose in the [124b] header comment, above the marked chunk
tests/run_all_tests.sh|b1537f40d9908ca7|prose in the bytecode-verifier comment about a past wrong answer
tests/run_all_tests.sh|96ebb19b3051ac95|prose in the [99s] header comment describing what must stay quiet
tests/run_all_tests.sh|7412a7c777df1655|[99t] treats an undefined name as a REFUSAL it asserts on, not a skip
tests/run_all_tests.sh|afa1df2cc3c846e7|same section, the token half; still a refusal assertion, not a skip
tests/run_all_tests.sh|caf3ea70e21715df|same section, the closure half; still a refusal assertion, not a skip
tests/test_asan_gfx.sh|898c996c43648e4b|the comment above that same OWN-binary probe in the child
tests/test_asan_gfx.sh|eb3773f2d6a0382a|the child BUILDS its own asan-gfx binary and gates on that, not on the suite binary
tests/test_borrow_guard.sh|f17115887aeaf7e5|gated on __borrow_guard_selftest, an EIGS_BORROW_GUARD env flag, not a build variant
tests/test_borrow_guard.sh|2c7e3d903f4f6f5d|same env-flag gate, second site in the same child
tests/test_dict_keys_mt.sh|b74f84cd4e3496fc|prose in a comment about where the captured fixtures came from
tests/test_lint.sh|f2d9b89115c7dd5b|a lint-MESSAGE assertion (W023), not a skip
tests/test_lint.sh|c42c8f00a9515b79|prose in a comment about what the runtime rejects
tests/test_lint.sh|3e6408ca18e23d87|prose in a comment about scope behaviour
tests/test_repl.sh|54a49b9b9630a18f|a REPL behaviour assertion, not a skip
tests/test_strict_math.sh|4f694e51cff1082a|prose about rc=1 being ambiguous, not a skip
tools/strict_differential.sh|1e2356c877a74dfc|prose explaining why variant-only names probe as undefined
tools/strict_differential.sh|b859e99b63f3b7bb|prose in the same comment about --api vs runtime
tools/strict_differential.sh|21747d00883ebb9a|prose about the sentinel that keeps the probe honest
tools/strict_differential.sh|2d366ac396e7a318|CLASSIFIES variant-only names as absent and still reports; it never skips its section
tools/suite_label_check.sh|4b33c19d8075f5f6|prose describing the twin-label phrasing that check allows
tools/suite_label_check.sh|2cc9024e404127f3|prose listing those twin phrasings
'

# ---------------------------------------------------------------------------
# The fixed core smoke. Each entry is a WAIVER (mechanical-gates §3): it states
# why it is in every plan, and an entry that matches no chunk is a hard failure
# — an exemption that no longer fires must fail, not pass quietly.
#
# Kept deliberately small: its job is "this variant's binary is not broken in a
# way that makes the variant sections meaningless", not "retest the language".
# The gcc full-suite job on the same PR is what covers the core.
CORE_SMOKE_IDS="[0]|[1/15]|[19/19]|[99p]"
core_smoke_reason() {
    case "$1" in
        "[0]")     echo "opcode ABI guard - a variant built against a drifted opcode table invalidates every later section" ;;
        "[1/15]")  echo "Gen 0 baseline - the language itself runs on this binary" ;;
        "[19/19]") echo "string & math builtins (75 checks) - the widest cheap core assertion" ;;
        "[99p]")   echo "child-script exit ledger - the vacuity roster; without it a skipped child is invisible" ;;
        *)         echo "" ;;
    esac
}

die() { echo "section_plan: ERROR: $*" >&2; exit 1; }

# Waivers are pinned to EXACT LINE CONTENT, by hash. Round 2 pinned them by
# SUBSTRING, and a blind critic walked straight through it: the entry
# `tests/test_lint.sh|undefined|lint-message assertions, not a skip` matched
# ANY line in that file containing "undefined", so a real capability gate
# planted into that file inherited a reason that is false for it and the audit
# printed unaccounted=0. A waiver must name the line a human actually reviewed
# (mechanical-gates §3: a named exemption is unbounded unless pinned), so a
# waived FILE gaining a NEW matching line is unaccounted and refused.
if command -v sha256sum >/dev/null 2>&1; then SP_HASHER="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SP_HASHER="shasum -a 256"
else die "no sha256sum and no shasum on PATH — waivers cannot be content-pinned"; fi
sp_line_hash() { printf '%s' "$1" | $SP_HASHER | cut -c1-16; }
note() { [ "$VERBOSE" = "1" ] && echo "$*" >&2; return 0; }

# ---------------------------------------------------------------------------
# Chunk derivation.
#
# A chunk is a whole number of TOP-LEVEL statements. We do not parse shell —
# we ask bash where a top-level statement boundary is: a prefix of the file
# that ends on a boundary parses with `bash -n`; one that ends inside an
# `if`/heredoc/loop does not. Candidates are column-0 section headers, column-0
# `# [nn]` section comments, and column-0 probe-file assignments (the probe
# setup sits BEFORE the header, which is indented inside the probe's `if`).
#
# Outputs, to stdout, one chunk per line:  <start> <end> <ids...>
# Sets globals: SP_PREAMBLE_END, SP_EPILOGUE_START, SP_TOTAL_LINES
derive_chunks() {
    local f="$1"
    SP_TOTAL_LINES=$(wc -l < "$f" | tr -d ' ')

    # Epilogue anchor. Pinned and required to be UNIQUE: if it moves or is
    # duplicated the tool stops rather than guessing (a gate that guesses its
    # own boundary is the gate that silently measures less).
    local anchors
    anchors=$(grep -n '^# Final guard (#681)' "$f" | cut -d: -f1)
    local n_anchor
    n_anchor=$(printf '%s\n' "$anchors" | grep -c '[0-9]')
    [ "$n_anchor" = "1" ] || die "epilogue anchor '# Final guard (#681)' matched $n_anchor times in $f (need exactly 1)"
    SP_EPILOGUE_START="$anchors"

    # The prefix test is incremental, and that is a correctness argument, not
    # only a speed one: once PREV is known to be a top-level boundary, the file
    # up to L-1 parses iff the SEGMENT [PREV, L-1] parses on its own (a valid
    # prefix followed by a complete script is a valid prefix). Testing the
    # segment instead of the whole prefix turns 600 parses of a 7,000-line file
    # into 600 parses of ~15 lines.
    local cand boundaries="" L prev=""
    cand=$(grep -nE '^(echo "\[|# \[[0-9]|[A-Za-z_][A-Za-z0-9_]*_FILE=)' "$f" | cut -d: -f1)
    for L in $cand; do
        [ "$L" -lt "$SP_EPILOGUE_START" ] || continue
        [ "$L" -gt 1 ] || continue
        if [ -z "$prev" ]; then
            # First boundary only: the whole prefix has to be tested, because
            # there is no known-good anchor to measure a segment from.
            if head -n $((L - 1)) "$f" | bash -n 2>/dev/null; then
                boundaries="$L"; prev="$L"
            fi
            continue
        fi
        [ "$L" -gt "$prev" ] || continue
        if sed -n "${prev},$((L - 1))p" "$f" | bash -n 2>/dev/null; then
            boundaries="$boundaries $L"; prev="$L"
        fi
    done
    [ -n "$boundaries" ] || die "no top-level chunk boundary found in $f"

    # shellcheck disable=SC2086
    set -- $boundaries
    SP_PREAMBLE_END=$(( $1 - 1 ))

    local start end ids
    while [ "$#" -gt 0 ]; do
        start="$1"; shift
        if [ "$#" -gt 0 ]; then end=$(( $1 - 1 )); else end=$(( SP_EPILOGUE_START - 1 )); fi
        ids=$(sed -n "${start},${end}p" "$f" \
              | grep -oE 'echo "\[[^]]*\]' \
              | sed 's/^echo "//' \
              | tr '\n' ' ')
        printf '%s %s %s\n' "$start" "$end" "$ids"
    done
}

# Partition control: preamble + every chunk + epilogue must reconstruct the
# file byte-for-byte. Without it a boundary bug silently DROPS sections and
# every surviving assertion still passes.
verify_partition() {
    local f="$1" table="$2" tmp
    tmp=$(mktemp)
    [ "$SP_PREAMBLE_END" -ge 1 ] && sed -n "1,${SP_PREAMBLE_END}p" "$f" > "$tmp"
    local s e
    while read -r s e _rest; do
        [ -n "$s" ] || continue
        sed -n "${s},${e}p" "$f" >> "$tmp"
    done < "$table"
    sed -n "${SP_EPILOGUE_START},\$p" "$f" >> "$tmp"
    if ! cmp -s "$tmp" "$f"; then
        rm -f "$tmp"
        die "chunk table is not a partition of $f (preamble+chunks+epilogue != file)"
    fi
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Marker derivation: which chunks DECLARE a capability gate.
# Emits: <start>\t<capability>
derive_markers() {
    local f="$1" table="$2"
    local s e caps
    while read -r s e _rest; do
        [ -n "$s" ] || continue
        caps=$(sed -n "${s},${e}p" "$f" \
               | sed -nE 's/^[[:space:]]*#[[:space:]]*EIGS-CAP-GATE:[[:space:]]*([a-z][a-z0-9_]*).*/\1/p' \
               | sort -u)
        [ -n "$caps" ] || continue
        # One chunk, one capability. Two would make "is this chunk in the plan"
        # ambiguous, and the ambiguity would resolve silently.
        if [ "$(printf '%s\n' "$caps" | grep -c .)" -ne 1 ]; then
            die "chunk at line $s declares more than one EIGS-CAP-GATE capability ($(printf '%s' "$caps" | tr '\n' ' ')) — split the section or pick one"
        fi
        printf '%s\t%s\n' "$s" "$caps"
    done < "$table"
}

# ---------------------------------------------------------------------------
# The gate audit: the marker population, pinned against an INDEPENDENT
# enumeration (mechanical-gates §1 and §12). Writes its findings to stdout and
# dies on anything unaccounted for.
#
# The enumeration deliberately scans the runner AND every child script the
# runner dispatches, because three of the gates the round-1 parser missed live
# in children (gfx_pixel_differential.sh, gfx_strict_sweep.sh, test_replay.sh).
# The child list itself is derived from the runner, never hand-written.
gate_audit() {
    local f="$1" table="$2" markers="$3" work="$4"
    local hits="$work/gate_hits" acct="$work/gate_accounted" unacct="$work/gate_unaccounted"
    : > "$hits"; : > "$acct"; : > "$unacct"

    # (a) hits in the runner itself
    grep -nE "$GATE_ENUM_RE" "$f" | sed "s|^|tests/run_all_tests.sh:|" >> "$hits"

    # (b) the child scripts the runner dispatches, derived from the runner
    local child rel path
    grep -oE 'bash "\$TESTS_DIR/(\.\./tools/)?[A-Za-z0-9_]+\.sh"' "$f" \
        | sed 's|bash "\$TESTS_DIR/||; s|"$||' | sort -u > "$work/children"
    SP_CHILD_COUNT=$(grep -c . "$work/children")
    [ "$SP_CHILD_COUNT" -ge 50 ] || \
        die "only $SP_CHILD_COUNT dispatched child scripts enumerated from the runner (floor 50) — the dispatch spelling changed and the audit would scan almost nothing"
    while read -r child; do
        [ -n "$child" ] || continue
        case "$child" in
            ../tools/*) rel="tools/${child#../tools/}" ;;
            *)          rel="tests/$child" ;;
        esac
        # SELF-EXCLUSION, and it is load-bearing: this file's own waiver table
        # and documentation necessarily QUOTE the patterns being enumerated, so
        # scanning itself makes the detector read its own reflection
        # (mechanical-gates §24). It declares no capability gate of the suite.
        [ "$rel" = "tools/section_plan.sh" ] && continue
        path="$SP_ROOT/$rel"
        [ -f "$path" ] || continue
        grep -nE "$GATE_ENUM_RE" "$path" | sed "s|^|$rel:|" >> "$hits"
    done < "$work/children"

    SP_GATE_HITS=$(grep -c . "$hits")
    [ "$SP_GATE_HITS" -ge "$GATE_HIT_FLOOR" ] || \
        die "the independent gate enumeration found only $SP_GATE_HITS lines (floor $GATE_HIT_FLOOR) — the scan is vacuous, not the tree clean"

    # Which child scripts are dispatched from a MARKED chunk? Those children's
    # own gates are accounted for by that marker.
    : > "$work/marked_children"
    local ms me mc
    while IFS=$'\t' read -r ms mc; do
        [ -n "$ms" ] || continue
        me=$(awk -v s="$ms" '$1==s {print $2}' "$table")
        sed -n "${ms},${me}p" "$f" \
            | grep -oE 'bash "\$TESTS_DIR/(\.\./tools/)?[A-Za-z0-9_]+\.sh"' \
            | sed 's|bash "\$TESTS_DIR/||; s|"$||' >> "$work/marked_children"
    done < "$markers"
    sort -u "$work/marked_children" -o "$work/marked_children"

    # Classify every hit.
    : > "$work/waivers_used"
    local hit file rest lineno text ok wpath wtext wreason
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        file=${hit%%:*}; rest=${hit#*:}
        lineno=${rest%%:*}; text=${rest#*:}
        ok=""
        if [ "$file" = "tests/run_all_tests.sh" ]; then
            # Inside a marked chunk?
            while IFS=$'\t' read -r ms mc; do
                [ -n "$ms" ] || continue
                me=$(awk -v s="$ms" '$1==s {print $2}' "$table")
                if [ "$lineno" -ge "$ms" ] && [ "$lineno" -le "$me" ]; then ok="marker:$mc@$ms"; break; fi
            done < "$markers"
        else
            # A child dispatched from a marked chunk.
            local base="${file#tests/}"; base="${base#tools/}"
            if grep -qx "$base" "$work/marked_children" || grep -qx "../tools/$base" "$work/marked_children"; then
                ok="marked-dispatcher"
            fi
        fi
        if [ -z "$ok" ]; then
            # Waivers.
            local IFS_SAVE="$IFS" thash
            thash=$(sp_line_hash "$text")
            while IFS='|' read -r wpath wtext wreason; do
                [ -n "${wpath:-}" ] || continue
                [ "$wpath" = "$file" ] || continue
                if [ "$wtext" = "$thash" ]; then
                    ok="waiver"; printf '%s|%s\n' "$wpath" "$wtext" >> "$work/waivers_used"; break
                fi
            done <<EOF
$GATE_WAIVERS
EOF
            IFS="$IFS_SAVE"
        fi
        if [ -n "$ok" ]; then
            printf '%s\t%s\n' "$ok" "$hit" >> "$acct"
        else
            printf '%s\n' "$hit" >> "$unacct"
        fi
    done < "$hits"

    if [ -s "$unacct" ] && [ "${SP_PRINT_WAIVERS:-0}" = "1" ]; then
        echo "# Paste-ready waiver rows for the UNACCOUNTED lines below."
        echo "# Each needs a REASON written by a reviewer; a bare path is not a waiver."
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            file=${hit%%:*}; rest=${hit#*:}; lineno=${rest%%:*}; text=${rest#*:}
            printf '%s|%s|REASON HERE — line %s: %.70s\n' "$file" "$(sp_line_hash "$text")" "$lineno" "$text"
        done < "$unacct"
        die "$(grep -c . "$unacct") unaccounted line(s); rows printed above, nothing was written"
    fi
    if [ -s "$unacct" ]; then
        echo "section_plan: ERROR: capability-gate line(s) that no EIGS-CAP-GATE marker and no waiver accounts for:" >&2
        sed 's/^/    /' "$unacct" >&2
        die "a gate spelled in a way the section plan does not know about would be silently dropped from every variant plan — add an 'EIGS-CAP-GATE: <cap>' marker at that gate, or a GATE_WAIVERS entry with a reason"
    fi

    # An exemption that no longer fires is a review event, not a quiet pass.
    local unused=""
    while IFS='|' read -r wpath wtext wreason; do
        [ -n "${wpath:-}" ] || continue
        grep -qxF "$wpath|$wtext" "$work/waivers_used" || unused="$unused
    $wpath|$wtext"
    done <<EOF
$GATE_WAIVERS
EOF
    if [ -n "$unused" ]; then
        echo "section_plan: ERROR: GATE_WAIVERS entries that matched nothing:$unused" >&2
        die "an unused waiver means the line it waived changed shape — re-review it instead of leaving it in place (mechanical-gates §3)"
    fi
    SP_WAIVERS_USED=$(sort -u "$work/waivers_used" | grep -c .)
}

# ---------------------------------------------------------------------------
# Probe derivation. Structure, not guesswork: a chunk that mentions a
# *_PROBE_OUT must yield all three parts or the tool fails loudly.
# Emits: <start> <outvar> <pattern>\t<program-file>
derive_probes() {
    local f="$1" table="$2" outdir="$3"
    local s e outvar filevar pattern hstart hend
    while read -r s e _rest; do
        [ -n "$s" ] || continue
        local block; block=$(sed -n "${s},${e}p" "$f")
        # The capture line is the anchor: <VAR>=$(./eigenscript "$<VAR2>" 2>&1)
        local capline
        capline=$(printf '%s\n' "$block" | grep -E '^[A-Za-z0-9_]*PROBE_OUT=\$\(\./eigenscript "\$[A-Za-z0-9_]*PROBE_FILE" 2>&1\)$' | head -1)
        if [ -z "$capline" ]; then
            # No capture line. If the chunk still mentions a _PROBE_OUT, the
            # idiom changed shape and this tool would silently under-report.
            # Comments are stripped first: a COMMENT that merely names the
            # idiom (a marker explaining why a gate is spelled differently) is
            # not a probe, and a detector that reads its own documentation is
            # the §24 self-reflection trap.
            if printf '%s\n' "$block" | grep -vE '^[[:space:]]*#' | grep -q 'PROBE_OUT'; then
                die "chunk at line $s mentions a *_PROBE_OUT but has no recognizable '<VAR>=\$(./eigenscript \"\$<VAR>_FILE\" 2>&1)' capture — the probe idiom changed and the derivation would silently under-report"
            fi
            continue
        fi
        outvar=${capline%%=*}
        filevar=$(printf '%s\n' "$capline" | sed 's/.*"\$\([A-Za-z_][A-Za-z0-9_]*\)".*/\1/')
        pattern=$(printf '%s\n' "$block" \
                  | grep -E "^if ! echo \"\\\$$outvar\" \| grep -q \"" \
                  | head -1 | sed 's/.*grep -q "\(.*\)".*/\1/')
        [ -n "$pattern" ] || die "chunk at line $s has $outvar but no 'if ! echo \"\$$outvar\" | grep -q \"...\"' guard"
        hstart=$(printf '%s\n' "$block" | grep -n "^cat > \"\\\$$filevar\" <<'PROBE'$" | head -1 | cut -d: -f1)
        [ -n "$hstart" ] || die "chunk at line $s has $filevar but no \"cat > \\\"\$$filevar\\\" <<'PROBE'\" heredoc"
        hend=$(printf '%s\n' "$block" | awk -v st="$hstart" 'NR>st && $0=="PROBE" {print NR; exit}')
        [ -n "$hend" ] || die "chunk at line $s has an unterminated PROBE heredoc"
        printf '%s\n' "$block" | sed -n "$((hstart + 1)),$((hend - 1))p" > "$outdir/probe_$s.eigs"
        printf '%s\t%s\t%s\t%s\n' "$s" "$outvar" "$pattern" "$outdir/probe_$s.eigs"
    done < "$table"
}

# Run one probe program against the binary, exactly the way the suite does
# (cwd src/, stderr folded in), and apply the suite's own predicate.
# Returns 0 = capability PRESENT, 1 = ABSENT.
probe_present() {
    local prog="$1" pattern="$2" out
    out=$(cd "$SP_ROOT/src" && "$SP_BIN_ABS" "$prog" 2>&1)
    if printf '%s\n' "$out" | grep -q "$pattern"; then return 1; fi
    return 0
}

# The plan must be derived from the binary the SUITE WILL RUN, not from a
# same-named one sitting elsewhere. run_all_tests.sh runs ./eigenscript from
# src/, so that is the artifact probed here; when build/<variant>/eigenscript
# also exists it is cross-checked by INODE (src/eigenscript is a hard link to
# the last `make` goal, #740). A mismatch means the alias points at some other
# variant, and deriving a plan from the variant build while the suite executes
# the alias is the exact shape of "the gate and the work resolved to different
# artifacts" (mechanical-gates §32) — so it is a hard error, not a NOTE.
resolve_binary() {
    local variant="$1"
    if [ -n "$BINARY" ]; then
        SP_BIN_ABS=$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")
        SP_BIN_LABEL="$BINARY (explicit --binary)"
        [ -x "$SP_BIN_ABS" ] || die "probe binary is not executable: $SP_BIN_ABS"
        return 0
    fi
    [ -x "$SP_ROOT/src/eigenscript" ] || die "src/eigenscript is missing — build the variant first"
    SP_BIN_ABS="$SP_ROOT/src/eigenscript"
    SP_BIN_LABEL="src/eigenscript"
    local vb="$SP_ROOT/build/$variant/eigenscript"
    if [ -x "$vb" ]; then
        local a b
        a=$(stat -c %i "$SP_BIN_ABS" 2>/dev/null || stat -f %i "$SP_BIN_ABS" 2>/dev/null)
        b=$(stat -c %i "$vb" 2>/dev/null || stat -f %i "$vb" 2>/dev/null)
        if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
            die "src/eigenscript is NOT the '$variant' build (inode $a vs build/$variant/eigenscript inode $b) — the suite would run one binary while this plan was derived from another; run 'make $variant' first"
        fi
        SP_BIN_LABEL="src/eigenscript (hard-linked to build/$variant/eigenscript)"
    fi
}

# ---------------------------------------------------------------------------
# The plan. Sets SP_SELECTED (chunk start lines, newline separated) and the
# counters; prints the human-readable table when VERBOSE=1.

# The probe/marker population invariant, in BOTH directions (§2) — shared by
# the plan and by `--probes`, so the public mode cannot drift into checking
# something weaker (or, as in round 2, into reading a constant that no longer
# exists). There is no standalone "probe count floor": the number of probe
# providers is not an independent fact, it is "every marked capability has one".
#   forward  every probe-idiom chunk carries a marker — otherwise the probe
#            exists and nothing can use it;
#   reverse  every capability a marker declares has at least one provider —
#            otherwise the plan cannot decide whether a binary has it.
# Sets SP_CAPS_DECLARED and SP_PROVIDERS.
verify_probe_coverage() {
    local markers="$1" probes="$2"
    local ps pcap cap found
    while IFS=$'\t' read -r ps _pout _ppat _pprog; do
        [ -n "$ps" ] || continue
        pcap=$(awk -F'\t' -v s="$ps" '$1==s {print $2}' "$markers")
        [ -n "$pcap" ] || die "the probe-gated chunk at line $ps has no 'EIGS-CAP-GATE: <cap>' marker — add one naming the capability it gates on"
    done < "$probes"
    SP_PROVIDERS=$(grep -c '[0-9]' "$probes")
    SP_CAPS_DECLARED=0
    for cap in $(cut -f2 "$markers" | sort -u); do
        SP_CAPS_DECLARED=$((SP_CAPS_DECLARED + 1))
        found=0
        while IFS=$'\t' read -r ps _pout _ppat _pprog; do
            [ -n "$ps" ] || continue
            [ "$(awk -F'\t' -v s="$ps" '$1==s {print $2}' "$markers")" = "$cap" ] && found=1
        done < "$probes"
        [ "$found" = "1" ] || die "capability '$cap' is declared by a marker but no chunk provides a probe for it — the plan cannot decide whether this binary has it"
    done
}

# Headers a chunk will ACTUALLY PRINT when its capability is present. A
# probe-gated chunk carries its own else-branch twin ("… SKIPPED (binary built
# without …)"), which never executes on a binary that HAS the capability — so
# counting both branches over-reported (the http plan said 18 and the run
# printed 16). The twin phrasing is not invented here: it is the same rule
# tools/suite_label_check.sh already uses to allow one label to appear twice.
chunk_executed_headers() {
    local s="$1" e="$2"
    sed -n "${s},${e}p" "$RUNNER" \
        | grep -oE 'echo "\[[^]]*\][^"]*' \
        | grep -cvE 'SKIPPED \(|skipped — |stub check|minimal build'
}

build_plan() {
    local variant="$1"
    local caps_floor chunks_floor
    caps_floor=$(variant_caps_floor "$variant")
    chunks_floor=$(variant_chunks_floor "$variant")
    [ -n "$caps_floor" ] || die "unknown variant '$variant' (known: release core http full db zlib net gfx asan-http asan-gfx)"

    SP_WORK="${SP_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/eigs_section_plan.XXXXXX")}"
    derive_chunks "$RUNNER" > "$SP_WORK/chunks"
    verify_partition "$RUNNER" "$SP_WORK/chunks"
    derive_markers "$RUNNER" "$SP_WORK/chunks" > "$SP_WORK/markers"
    derive_probes "$RUNNER" "$SP_WORK/chunks" "$SP_WORK" > "$SP_WORK/probes"

    SP_CHUNK_TOTAL=$(grep -c '[0-9]' "$SP_WORK/chunks")
    SP_SECTION_TOTAL=$(grep -coE 'echo "\[[^]]*\]' "$RUNNER")
    SP_PROBE_SITES=$(grep -c '[0-9]' "$SP_WORK/probes")
    SP_MARKERS=$(grep -c '[0-9]' "$SP_WORK/markers")

    [ "$SP_MARKERS" -ge "$CAP_MARKER_FLOOR" ] || \
        die "EIGS-CAP-GATE markers derived=$SP_MARKERS < floor=$CAP_MARKER_FLOOR — a capability gate lost its marker and its sections would silently leave every variant plan"

    # The pin: the marker population against the independent enumeration.
    gate_audit "$RUNNER" "$SP_WORK/chunks" "$SP_WORK/markers" "$SP_WORK"

    verify_probe_coverage "$SP_WORK/markers" "$SP_WORK/probes"

    resolve_binary "$variant"

    note "plan=$variant  binary=$SP_BIN_LABEL"
    note "runner=tests/run_all_tests.sh  lines=$SP_TOTAL_LINES  preamble=1-$SP_PREAMBLE_END  epilogue=$SP_EPILOGUE_START-$SP_TOTAL_LINES"
    note "chunks=$SP_CHUNK_TOTAL  section-headers=$SP_SECTION_TOTAL"
    note "cap-gate markers=$SP_MARKERS (floor $CAP_MARKER_FLOOR)  probe providers=$SP_PROBE_SITES"
    note "gate audit: $SP_GATE_HITS enumerated gate lines over the runner + $SP_CHILD_COUNT dispatched children; all accounted for ($SP_WAIVERS_USED waiver(s) used)"
    note ""

    # --- capability presence, one decision per capability -----------------
    # Every probe provider for a capability is RUN and they must AGREE. gfx has
    # five providers; a disagreement means one probe is measuring something
    # else, and silently taking the first would hide it.
    note "capabilities (each probe is the suite's OWN gate, run against this binary):"
    : > "$SP_WORK/caps"
    local caps_all cap verdict agree ppat pprog pout
    caps_all=$(cut -f2 "$SP_WORK/markers" | sort -u)
    for cap in $caps_all; do
        verdict=""; agree=1
        while IFS=$'\t' read -r ps _pout ppat pprog; do
            [ -n "$ps" ] || continue
            pcap=$(awk -F'\t' -v s="$ps" '$1==s {print $2}' "$SP_WORK/markers")
            [ "$pcap" = "$cap" ] || continue
            if probe_present "$pprog" "$ppat"; then pout=present; else pout=absent; fi
            if [ -z "$verdict" ]; then verdict="$pout"
            elif [ "$verdict" != "$pout" ]; then agree=0; fi
        done < "$SP_WORK/probes"
        [ -n "$verdict" ] || die "capability '$cap' is declared by a marker but no chunk provides a probe for it — the plan cannot decide whether this binary has it"
        [ "$agree" = "1" ] || die "the probes for capability '$cap' DISAGREE on this binary — one of them is measuring something else"
        printf '%s\t%s\n' "$cap" "$verdict" >> "$SP_WORK/caps"
        note "  $verdict  $cap"
    done
    note ""

    : > "$SP_WORK/selected"

    # --- core smoke -------------------------------------------------------
    note "core smoke (fixed; each entry states why, and an entry matching no chunk is a hard failure):"
    local id matched s e ids
    local IFS_SAVE="$IFS"
    IFS='|'
    for id in $CORE_SMOKE_IDS; do
        IFS="$IFS_SAVE"
        matched=""
        while read -r s e ids; do
            [ -n "$s" ] || continue
            case " $ids " in
                *" $id "*) matched="$s"; break ;;
            esac
        done < "$SP_WORK/chunks"
        [ -n "$matched" ] || die "core-smoke entry '$id' matches no chunk in the runner — the section was renamed or removed; re-review the smoke list"
        echo "$matched" >> "$SP_WORK/selected"
        note "  $id  (chunk @$matched)  — $(core_smoke_reason "$id")"
        IFS='|'
    done
    IFS="$IFS_SAVE"
    note ""

    # --- marker-derived variant sections ----------------------------------
    note "capability-gated sections (every chunk carrying an EIGS-CAP-GATE marker):"
    SP_PRESENT=0
    SP_ABSENT=0
    local ms mc mv
    while IFS=$'\t' read -r ms mc; do
        [ -n "$ms" ] || continue
        ids=$(awk -v s="$ms" '$1==s {$1="";$2="";print}' "$SP_WORK/chunks" | sed 's/^  *//')
        mv=$(awk -F'\t' -v c="$mc" '$1==c {print $2}' "$SP_WORK/caps")
        if [ "$mv" = "present" ]; then
            SP_PRESENT=$((SP_PRESENT + 1))
            echo "$ms" >> "$SP_WORK/selected"
            note "  IN   chunk @$ms  cap=$mc  sections: $ids"
        else
            SP_ABSENT=$((SP_ABSENT + 1))
            note "  out  chunk @$ms  cap=$mc  sections: $ids"
        fi
    done < "$SP_WORK/markers"
    note ""

    sort -n -u "$SP_WORK/selected" > "$SP_WORK/selected.sorted"
    mv "$SP_WORK/selected.sorted" "$SP_WORK/selected"

    SP_SEL_CHUNKS=$(grep -c '[0-9]' "$SP_WORK/selected")
    SP_SEL_SECTIONS=0
    while read -r s; do
        [ -n "$s" ] || continue
        e=$(awk -v ss="$s" '$1==ss {print $2}' "$SP_WORK/chunks")
        n=$(chunk_executed_headers "$s" "$e")
        SP_SEL_SECTIONS=$((SP_SEL_SECTIONS + n))
    done < "$SP_WORK/selected"

    SP_CAPS_PRESENT=$(awk -F'\t' '$2=="present"' "$SP_WORK/caps" | grep -c . || true)

    # --- floors and vacuity ----------------------------------------------
    if [ "$SP_CAPS_PRESENT" -lt "$caps_floor" ]; then
        echo "PLAN: sections=$SP_SEL_SECTIONS (of $SP_SECTION_TOTAL) chunks=$SP_SEL_CHUNKS plan=$variant capabilities=$SP_CAPS_PRESENT"
        die "variant '$variant' presents $SP_CAPS_PRESENT capability(ies), floor is $caps_floor — this binary is not the variant it claims (a broken registration collapses the plan to the core smoke and would otherwise go GREEN)"
    fi
    if [ "$SP_PRESENT" -lt "$chunks_floor" ]; then
        echo "PLAN: sections=$SP_SEL_SECTIONS (of $SP_SECTION_TOTAL) chunks=$SP_SEL_CHUNKS plan=$variant capabilities=$SP_CAPS_PRESENT"
        die "variant '$variant' selected $SP_PRESENT capability-gated chunk(s), floor is $chunks_floor — a marker was lost, or a gated section left the runner"
    fi
    if [ "$SP_SEL_SECTIONS" -le 0 ]; then
        die "plan for '$variant' selected ZERO sections — a job that measures nothing must not be green"
    fi

    echo "PLAN: sections=$SP_SEL_SECTIONS (of $SP_SECTION_TOTAL) chunks=$SP_SEL_CHUNKS plan=$variant capabilities=$SP_CAPS_PRESENT (floor $caps_floor) gated-chunks=$SP_PRESENT (floor $chunks_floor)"
}


# ---------------------------------------------------------------------------
# Emit the filtered runner.
emit_plan() {
    local variant="$1" out="$2"
    VERBOSE=${EMIT_VERBOSE:-1}
    SP_WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_section_plan.XXXXXX")
    build_plan "$variant" > "$SP_WORK/plan.line"
    local planline; planline=$(cat "$SP_WORK/plan.line")

    {
        echo "#!/bin/bash"
        echo "# GENERATED by tools/section_plan.sh — DO NOT EDIT, DO NOT COMMIT (#1160)."
        echo "# $planline"
        echo "# Source: tests/run_all_tests.sh   variant: $variant   binary: $SP_BIN_LABEL"
        echo "EIGS_PLAN_ACTIVE=1; export EIGS_PLAN_ACTIVE"
        echo "EIGS_PLAN_TESTS_DIR='$SP_ROOT/tests'; export EIGS_PLAN_TESTS_DIR"
        echo "EIGS_PLAN_LABEL='$planline'; export EIGS_PLAN_LABEL"
        sed -n "1,${SP_PREAMBLE_END}p" "$RUNNER"
        echo "echo \"  SECTION PLAN: $planline\""
        echo "echo \"\""
        local s e
        while read -r s; do
            [ -n "$s" ] || continue
            e=$(awk -v ss="$s" '$1==ss {print $2}' "$SP_WORK/chunks")
            sed -n "${s},${e}p" "$RUNNER"
        done < "$SP_WORK/selected"
        echo "echo \"  SECTION PLAN: $planline\""
        sed -n "${SP_EPILOGUE_START},\$p" "$RUNNER"
    } > "$out"

    bash -n "$out" || die "the emitted runner $out is not syntactically valid — the chunk boundaries are wrong"
    echo "$planline"
}

# ---------------------------------------------------------------------------
# Selftest. Every fault is planted in a COPY (mechanical-gates §22: a gate must
# not mutate what it checks), and every case names the check it must turn red.
selftest() {
    local rc=0 pass=0 fail=0 dir out
    dir=$(mktemp -d "${TMPDIR:-/tmp}/eigs_section_plan_selftest.XXXXXX")
    trap 'rm -rf "$dir"' RETURN

    expect_ok() {   # <label> <command...>
        local label="$1"; shift
        if out=$("$@" 2>&1); then
            echo "  PASS: $label"; pass=$((pass + 1))
        else
            echo "  FAIL: $label (expected exit 0, got $?)"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
        fi
    }
    expect_red() {  # <label> <must-match> <command...>
        local label="$1" want="$2"; shift 2
        if out=$("$@" 2>&1); then
            echo "  FAIL: $label — the planted fault did NOT turn the check red"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
        elif printf '%s\n' "$out" | grep -qF "$want"; then
            echo "  PASS: $label"; pass=$((pass + 1))
        else
            echo "  FAIL: $label — it went red for the WRONG reason (no '$want' in the output)"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
        fi
    }

    echo "section_plan selftest (faults are planted in copies; the tree is never touched)"

    # Control: the real runner derives cleanly. Both halves of a control
    # (mechanical-gates §15): a clean input MUST pass.
    expect_ok "control: the real runner partitions and parses" \
        "$0" --chunks --quiet

    # 1. Epilogue anchor lost -> must fail loudly, not guess.
    cp "$RUNNER" "$dir/no_anchor.sh"
    sed -i 's/^# Final guard (#681)/# Final guard/' "$dir/no_anchor.sh"
    expect_red "planted: epilogue anchor removed -> derive_chunks" \
        "epilogue anchor" "$0" --chunks --quiet --runner "$dir/no_anchor.sh"

    # 2. Epilogue anchor duplicated -> must fail (unique or stop).
    cp "$RUNNER" "$dir/dup_anchor.sh"
    printf '# Final guard (#681)\n' >> "$dir/dup_anchor.sh"
    expect_red "planted: epilogue anchor duplicated -> derive_chunks" \
        "epilogue anchor" "$0" --chunks --quiet --runner "$dir/dup_anchor.sh"

    # 3. Probe idiom mangled (the capture line renamed) -> the derivation must
    #    refuse, not silently return one probe fewer.
    cp "$RUNNER" "$dir/bad_probe.sh"
    sed -i 's/^ZLIB_PROBE_OUT=\$(\.\/eigenscript "\$ZLIB_PROBE_FILE" 2>&1)$/ZLIB_PROBE_OUT=$(.\/eigenscript "$ZLIB_PROBE_FILE" 2>\&1 )/' "$dir/bad_probe.sh"
    expect_red "planted: a probe capture line reshaped -> derive_probes refuses" \
        "probe idiom changed" "$0" --probes --quiet --runner "$dir/bad_probe.sh"

    # 4. Probe guard removed -> must fail.
    cp "$RUNNER" "$dir/no_guard.sh"
    sed -i 's/^if ! echo "\$NET_PROBE_OUT" | grep -q "ndefined variable"; then$/if true; then/' "$dir/no_guard.sh"
    expect_red "planted: a probe guard removed -> derive_probes refuses" \
        "no 'if ! echo" "$0" --probes --quiet --runner "$dir/no_guard.sh"

    # 5. A core-smoke section renamed -> the waiver must fail, not pass quietly.
    cp "$RUNNER" "$dir/no_smoke.sh"
    sed -i 's/^echo "\[19\/19\] String & Math Builtins (75 checks)"$/echo "[19\/19x] String \& Math Builtins (75 checks)"/' "$dir/no_smoke.sh"
    expect_red "planted: a core-smoke section renamed -> the fixed smoke list fails" \
        "matches no chunk" "$0" --print-section-plan core --quiet --runner "$dir/no_smoke.sh"

    # --- capability stubs -------------------------------------------------
    # ROUND 2 (#1160): these replace a case that probed src/eigenscript and so
    # depended on which variant was last built — it was a FALSE RED right after
    # `make http`, which is exactly what docs/CI.md tells a contributor to run.
    # A stub answers the probes the way a binary would, and nothing in the tree
    # can change its answer.
    # The no-capabilities stub must answer EVERY gate's pattern, not just the
    # common one: the zlib gate is inverted (present iff the stub message is
    # ABSENT), so a stub that printed only "undefined variable" reported zlib
    # PRESENT — the first version of this control did exactly that.
    printf '#!/bin/sh\necho "undefined variable"\necho "deflate: compiled without zlib support"\nexit 1\n' > "$dir/nocaps"
    printf '#!/bin/sh\nexit 0\n' > "$dir/allcaps"
    chmod +x "$dir/nocaps" "$dir/allcaps"

    # 6. A capability-less binary presented as `http` -> the variant floor must
    #    fire. This is the planted variant-only regression in miniature: a
    #    broken http_route registration produces exactly this binary.
    expect_red "planted: a capability-less binary labelled 'http' -> the caps floor fires" \
        "floor is 2" "$0" --print-section-plan http --quiet --binary "$dir/nocaps"

    # 6b. THE ROUND-1 REGRESSION, as a control. The gfx-gated sections spelled
    #     outside the probe idiom — [97] (inline EX_HAS_GFX), [138] and [139]
    #     (children that self-skip) — were dropped from every gfx plan. A blind
    #     critic proved it: an undefined builtin planted in examples/ui_dock.eigs
    #     left `EIGS_SUITE_SECTIONS=gfx` 173/173 GREEN. They must now be IN.
    if out=$("$0" --print-section-plan gfx --binary "$dir/allcaps" 2>&1); then
        missing=""
        for want in "[97]" "[138]" "[139]" "[62]" "[132]"; do
            printf '%s\n' "$out" | grep -q -- "IN .*sections:.*$want" || missing="$missing $want"
        done
        if [ -z "$missing" ]; then
            echo "  PASS: control: a gfx-capable binary puts [97] [138] [139] [62] [132] IN the plan"; pass=$((pass + 1))
        else
            echo "  FAIL: control: the gfx plan is missing$missing — the round-1 blind spot is back"; fail=$((fail + 1))
        fi
    else
        echo "  FAIL: control: the gfx plan could not be derived from the all-capabilities stub"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
    fi

    # 6c. The other half of that control: with NO capabilities, those same
    #     sections must be OUT. A check satisfied by "always in" is not a check.
    if out=$("$0" --print-section-plan core --binary "$dir/nocaps" 2>&1); then
        if printf '%s\n' "$out" | grep -q -- "IN .*sections:"; then
            echo "  FAIL: control: a capability-less binary still selected a gated chunk"; fail=$((fail + 1))
        else
            echo "  PASS: control: a capability-less binary selects NO gated chunk"; pass=$((pass + 1))
        fi
    else
        echo "  FAIL: control: the core plan could not be derived from the no-capabilities stub"; fail=$((fail + 1))
    fi

    # 6d. A gate that loses its marker must be a HARD FAILURE, not a silent
    #     shrink — this is the pin that round 1 did not have.
    #     The marker is MOVED, not deleted, so the marker COUNT stays at 15 and
    #     the floor cannot answer on the audit's behalf (mechanical-gates §41:
    #     a negative case must fail for its own reason, not a neighbour's).
    cp "$RUNNER" "$dir/no_marker.sh"
    sed -i 's/^# EIGS-CAP-GATE: gfx — \[97\]/# (marker moved away by the selftest) [97]/' "$dir/no_marker.sh"
    sed -i 's|^echo "\[0\] Opcode ABI Guard"$|echo "[0] Opcode ABI Guard"\n# EIGS-CAP-GATE: gfx — a marker parked where no gate is|' "$dir/no_marker.sh"
    expect_red "planted: the [97] gate loses its marker -> the gate audit refuses" \
        "no EIGS-CAP-GATE marker and no waiver accounts for" \
        "$0" --gate-audit --quiet --runner "$dir/no_marker.sh"

    # 6e. A NEW gate spelling entering the tree must be a hard failure too —
    #     "a new spelling is a hard failure, not a silent shrink".
    cp "$RUNNER" "$dir/new_spelling.sh"
    sed -i 's|^echo "\[0\] Opcode ABI Guard"$|if ./eigenscript /dev/null 2>\&1 \| grep -q "built without EIGENSCRIPT_EXT_ZZZ"; then :; fi\necho "[0] Opcode ABI Guard"|' "$dir/new_spelling.sh"
    expect_red "planted: a NEW capability-gate spelling -> the gate audit refuses" \
        "no EIGS-CAP-GATE marker and no waiver accounts for" \
        "$0" --gate-audit --quiet --runner "$dir/new_spelling.sh"

    # 6f. The run-level vacuity hole (round 2, G4): preamble + epilogue with no
    #     sections at all used to print "RESULTS: 0/0 passed, 0 failed" and exit
    #     0. Built here directly, because no legal plan can produce it.
    # Boundaries come from the tool, never from a hardcoded line number.
    local pre_end
    pre_end=$("$0" --chunks --quiet --runner "$RUNNER" | sed -n 's/.*preamble=1-\([0-9][0-9]*\).*/\1/p')
    {
        printf 'EIGS_PLAN_ACTIVE=1; export EIGS_PLAN_ACTIVE\n'
        printf "EIGS_PLAN_TESTS_DIR='%s/tests'; export EIGS_PLAN_TESTS_DIR\n" "$SP_ROOT"
        awk -v n="$pre_end" 'NR<=n' "$RUNNER"
        awk '/^# Final guard \(#681\)/,0' "$RUNNER"
    } > "$dir/empty_run.sh"
    expect_red "planted: a run with zero assertions -> the epilogue refuses to report it" \
        "executed ZERO assertions" bash "$dir/empty_run.sh"

    # 6g. The COUNT itself (round 2, G5). Round 1 counted both branches of a
    #     probe gate's if/else, so the http plan promised 18 for a run that
    #     printed 16. The twin ("… SKIPPED (binary built without …)") never
    #     executes on a binary that HAS the capability. Pinned on the http
    #     chunk, which carries six header echoes of which exactly one is a twin.
    local http_chunk http_end raw exec_n
    http_chunk=$("$0" --markers --quiet --runner "$RUNNER" >/dev/null 2>&1; true)
    W2=$(mktemp -d "${TMPDIR:-/tmp}/eigs_sp_count.XXXXXX")
    derive_chunks "$RUNNER" > "$W2/chunks"
    http_chunk=$(awk '$0 ~ /\[44-45\/47\]/ {print $1; exit}' "$W2/chunks")
    http_end=$(awk -v s="$http_chunk" '$1==s {print $2}' "$W2/chunks")
    raw=$(sed -n "${http_chunk},${http_end}p" "$RUNNER" | grep -cE 'echo "\[[^]]*\]')
    exec_n=$(chunk_executed_headers "$http_chunk" "$http_end")
    rm -rf "$W2"
    if [ "$raw" = "6" ] && [ "$exec_n" = "5" ]; then
        echo "  PASS: header counting excludes the skip TWIN (http chunk: 6 echoes, 5 executed)"; pass=$((pass + 1))
    else
        echo "  FAIL: header counting is wrong (http chunk: $raw echoes, $exec_n counted as executed; expected 6 and 5)"; fail=$((fail + 1))
    fi

    # 6h. ROUND 3, G2 (Astra, executed): a waiver used to be a SUBSTRING, so a
    #     real capability gate planted into an already-waived FILE inherited a
    #     reason that is false for it and the audit printed unaccounted=0.
    #     Waivers are content-pinned now; this plants Astra's exact line into a
    #     symlink farm so the real tree is never touched.
    mkdir -p "$dir/root/tests" "$dir/root/tools"
    ln -s "$SP_ROOT"/tests/* "$dir/root/tests/" 2>/dev/null
    ln -s "$SP_ROOT"/tools/* "$dir/root/tools/" 2>/dev/null
    if [ -e "$dir/root/tests/run_all_tests.sh" ] && [ -e "$dir/root/tests/test_lint.sh" ]; then
        rm -f "$dir/root/tests/test_lint.sh"
        {
            head -1 "$SP_ROOT/tests/test_lint.sh"
            printf 'if ./eigenscript "$P" 2>&1 | grep -q "undefined variable"; then echo "SKIP: planted no gfx build"; exit 0; fi\n'
            tail -n +2 "$SP_ROOT/tests/test_lint.sh"
        } > "$dir/root/tests/test_lint.sh"
        # Control half: the farm with NO plant must still audit clean, or the
        # red below would be the farm failing rather than the plant landing.
        mkdir -p "$dir/clean/tests" "$dir/clean/tools"
        ln -s "$SP_ROOT"/tests/* "$dir/clean/tests/" 2>/dev/null
        ln -s "$SP_ROOT"/tools/* "$dir/clean/tools/" 2>/dev/null
        expect_ok "control: the symlink farm with no plant audits clean" \
            "$0" --gate-audit --quiet --root "$dir/clean"
        expect_red "planted: a REAL gate added to an already-waived file -> the audit refuses" \
            "no EIGS-CAP-GATE marker and no waiver accounts for" \
            "$0" --gate-audit --quiet --root "$dir/root"
    else
        echo "  FAIL: could not build the symlink farm for the waiver-pin control"; fail=$((fail + 1))
    fi

    # 6i. ROUND 3, G1: every public mode a WORKFLOW or docs/CI.md names must be
    #     invocable. `--probes` died on an unbound variable while --selftest
    #     passed 14/14, and ci.yml's gate-selftests job calls it, so every code
    #     PR would have gone red. The mode list is DERIVED from those two files,
    #     so a mode added to a workflow is covered without editing this test.
    local modes m modefile mode_n=0 mode_bad=0
    modefile="$dir/modes"
    { grep -ohE 'section_plan\.sh --[a-z-]+' "$SP_ROOT/.github/workflows/"*.yml 2>/dev/null
      grep -ohE 'section_plan\.sh --[a-z-]+' "$SP_ROOT/docs/CI.md" 2>/dev/null
      grep -ohE 'run_all_tests\.sh --[a-z-]+' "$SP_ROOT/docs/CI.md" 2>/dev/null
    } | sed 's/.*--/--/' | sort -u > "$modefile"
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        mode_n=$((mode_n + 1))
        case "$m" in
            --emit)                out=$("$0" --emit core "$dir/mode_emit.sh" 2>&1) || mode_bad="$mode_bad $m" ;;
            --print-section-plan)  out=$("$0" --print-section-plan core --quiet 2>&1) || mode_bad="$mode_bad $m" ;;
            --selftest)            : ;;   # we are inside it
            *)                     out=$("$0" "$m" --quiet 2>&1) || mode_bad="$mode_bad $m" ;;
        esac
    done < "$modefile"
    if [ "$mode_n" -lt 3 ]; then
        echo "  FAIL: only $mode_n public mode(s) enumerated from the workflows and docs (floor 3) — the enumeration is vacuous"; fail=$((fail + 1))
    elif [ "$mode_bad" = "0" ]; then
        echo "  PASS: every public mode named by a workflow or docs/CI.md runs clean ($mode_n: $(tr '\n' ' ' < "$modefile"))"; pass=$((pass + 1))
    else
        echo "  FAIL: public mode(s) a workflow or docs calls exit nonzero:${mode_bad#0}"; printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
    fi

    # 7. The emitted runner for a real variant must parse.
    expect_ok "control: the emitted core runner is syntactically valid" \
        "$0" --emit core "$dir/emitted.sh"

    echo "section_plan selftest: checks=$((pass + fail)) failures=$fail"
    [ "$fail" -eq 0 ] || rc=1
    return $rc
}

# ---------------------------------------------------------------------------
MODE=""
ARG1=""
ARG2=""
SP_ROOT_RUNNER_SET=0
case " $* " in *" --runner "*) SP_ROOT_RUNNER_SET=1 ;; esac
while [ "$#" -gt 0 ]; do
    case "$1" in
        --runner) RUNNER="$2"; shift 2 ;;
        # --root re-points the tree the audit reads (the runner and the child
        # scripts it dispatches). The selftest uses it to plant a fault into a
        # CHILD without touching the real tree (mechanical-gates §22).
        --root) SP_ROOT=$(cd "$2" && pwd); [ "$SP_ROOT_RUNNER_SET" = "1" ] || RUNNER="$SP_ROOT/tests/run_all_tests.sh"; shift 2 ;;
        --binary) BINARY="$2"; shift 2 ;;
        --quiet)  VERBOSE=0; shift ;;
        --chunks|--probes|--markers|--gate-audit|--selftest) MODE="$1"; shift ;;
        --print-waivers) SP_PRINT_WAIVERS=1; export SP_PRINT_WAIVERS; shift ;;
        --print-section-plan) MODE="$1"; ARG1="$2"; shift 2 ;;
        --emit) MODE="$1"; ARG1="$2"; ARG2="$3"; shift 3 ;;
        *) die "unknown argument '$1'" ;;
    esac
done
[ -n "$MODE" ] || die "no mode given (see the header for usage)"
[ -f "$RUNNER" ] || die "runner not found: $RUNNER"

case "$MODE" in
    --chunks)
        W=$(mktemp -d "${TMPDIR:-/tmp}/eigs_section_plan.XXXXXX")
        derive_chunks "$RUNNER" > "$W/chunks"
        verify_partition "$RUNNER" "$W/chunks"
        n=$(grep -c '[0-9]' "$W/chunks")
        [ "$VERBOSE" = "1" ] && cat "$W/chunks"
        echo "CHUNKS: $n  preamble=1-$SP_PREAMBLE_END  epilogue=$SP_EPILOGUE_START-$SP_TOTAL_LINES  partition=verified"
        rm -rf "$W"
        ;;
    --markers|--gate-audit)
        W=$(mktemp -d "${TMPDIR:-/tmp}/eigs_section_plan.XXXXXX")
        derive_chunks "$RUNNER" > "$W/chunks"
        verify_partition "$RUNNER" "$W/chunks"
        derive_markers "$RUNNER" "$W/chunks" > "$W/markers"
        n=$(grep -c '[0-9]' "$W/markers")
        if [ "$VERBOSE" = "1" ]; then
            while IFS=$'\t' read -r ms mc; do
                [ -n "$ms" ] || continue
                me=$(awk -v s="$ms" '$1==s {print $2}' "$W/chunks")
                ids=$(awk -v s="$ms" '$1==s {$1="";$2="";print}' "$W/chunks" | sed 's/^  *//')
                echo "marker  cap=$mc  chunk @$ms-$me  sections: $ids"
            done < "$W/markers"
        fi
        [ "$n" -ge "$CAP_MARKER_FLOOR" ] || { rm -rf "$W"; die "EIGS-CAP-GATE markers=$n < floor=$CAP_MARKER_FLOOR"; }
        if [ "$MODE" = "--gate-audit" ]; then
            gate_audit "$RUNNER" "$W/chunks" "$W/markers" "$W"
            echo "GATE AUDIT: markers=$n (floor $CAP_MARKER_FLOOR)  enumerated gate lines=$SP_GATE_HITS (floor $GATE_HIT_FLOOR) over the runner + $SP_CHILD_COUNT dispatched children  waivers used=$SP_WAIVERS_USED  unaccounted=0"
        else
            echo "MARKERS: $n (floor $CAP_MARKER_FLOOR)"
        fi
        rm -rf "$W"
        ;;
    --probes)
        W=$(mktemp -d "${TMPDIR:-/tmp}/eigs_section_plan.XXXXXX")
        derive_chunks "$RUNNER" > "$W/chunks"
        verify_partition "$RUNNER" "$W/chunks"
        derive_probes "$RUNNER" "$W/chunks" "$W" > "$W/probes"
        n=$(grep -c '[0-9]' "$W/probes")
        if [ "$VERBOSE" = "1" ]; then
            while IFS=$'\t' read -r ps pout ppat _pprog; do
                [ -n "$ps" ] || continue
                ids=$(awk -v s="$ps" '$1==s {$1="";$2="";print}' "$W/chunks" | sed 's/^  *//')
                echo "chunk @$ps  probe=$pout  guard=\"$ppat\"  sections: $ids"
            done < "$W/probes"
        fi
        derive_markers "$RUNNER" "$W/chunks" > "$W/markers"
        m=$(grep -c '[0-9]' "$W/markers")
        [ "$m" -ge "$CAP_MARKER_FLOOR" ] || { rm -rf "$W"; die "EIGS-CAP-GATE markers=$m < floor=$CAP_MARKER_FLOOR"; }
        verify_probe_coverage "$W/markers" "$W/probes"
        echo "PROBES: $n provider(s) for $SP_CAPS_DECLARED declared capability(ies); every probe chunk carries a marker and every capability has a provider (markers=$m, floor $CAP_MARKER_FLOOR)"
        rm -rf "$W"
        ;;
    --print-section-plan)
        build_plan "$ARG1"
        rm -rf "$SP_WORK"
        ;;
    --emit)
        emit_plan "$ARG1" "$ARG2"
        rm -rf "$SP_WORK"
        ;;
    --selftest)
        selftest
        ;;
esac
