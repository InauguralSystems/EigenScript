#!/bin/bash
# Observer-reader sync gate (#915 / #972).
#
# THE RULE THAT LIVES IN TWO HOMES
#
# "Which opcodes read observer state" is one rule with two implementations:
#
#   1. src/vm.h        — the /*obs:READS*/ markers. The AUTHORITATIVE home:
#                        every opcode carries a hand-reviewed verdict, and
#                        tools/obs_marker_check.sh proves every opcode has one.
#   2. src/chunk.c     — the `case OP_...:` arms of chunk_reads_observer(),
#                        the CONSUMER: the compile-time scan that decides
#                        whether a program may skip observer bookkeeping.
#
# Nothing tied them together, and they had ALREADY diverged when this gate was
# written: the C switch carries OP_INTERROGATE, which #1024's hand-reading
# marked obs:NONE. That divergence is harmless in its direction (extra readers
# cost gates, not answers) — but the OPPOSITE divergence is catastrophic and
# silent. A marker says READS, the switch does not list it, and a program using
# only that opcode gates itself off, reads slots nobody updated, and answers
# `equilibrium` forever with no crash and nothing to fail on.
#
# mechanical-gates §26: when one rule must live in two homes, GATE the sync —
# never hand-sync. This is that gate. It reads BOTH homes and asserts the
# relationship between them, rather than asserting either against a third list
# (§1: a list validated by a sibling list measures the list, not the tree).
#
# THE RELATIONSHIP IS AN IMPLICATION, NOT AN EQUALITY (§39)
#
#     marker says READS  =>  the C switch must list it        [hard, silent-wrong]
#     C switch lists it  =>  marker says READS *or* it is a PINNED exemption
#
# The second direction is not equality because the switch is deliberately
# allowed to be MORE conservative. Each such entry is a waiver (§3): named,
# reasoned, and required to still be present — an exemption that stops firing
# must go red, not quiet, because it means the thing it waived changed shape.
#
# WHAT THIS GATE DOES NOT DO
#
#   * It does not check that a marker's verdict is CORRECT. That rests on the
#     handler having been read; obs_marker_check.sh owns "was a verdict
#     recorded", and the reading for the initial 94 is on #972.
#   * It does not see readers reached through the CONSTANT POOL (an aliased
#     `local r is report` emits no reader opcode at all). That population is
#     OBS_BUILTINS in the same function and is checked by suite section [99n]
#     check 4, behaviourally.
#   * The stronger design is to GENERATE the C set from the markers, the way
#     tools/gen_lsp_builtin_index.sh generates its header — then the rule has
#     one home and this gate is unnecessary. Filed rather than implied.
#
# Usage: tools/obs_reader_sync_check.sh [--selftest]
# Exit 0 = the two homes agree modulo the pinned exemptions.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

CHUNK_SRC="${CHUNK_SRC:-src/chunk.c}"
MARKER_TOOL="${MARKER_TOOL:-tools/obs_marker_check.sh}"

# Floors, not exact counts (§5/§43). A DERIVED population can shrink silently;
# `-z` is an emptiness test and only catches losing ALL of them. These move only
# when coverage is REMOVED, which is always a review event.
READS_FLOOR="${READS_FLOOR:-15}"
SWITCH_FLOOR="${SWITCH_FLOOR:-17}"

# The pinned exemptions: opcodes the C switch treats as readers although the
# markers do not. Each must be PRESENT in the switch and ABSENT from the marker
# READS set — if either stops holding, this gate fails and the entry is re-read.
#
#   OP_INTERROGATE  marked obs:NONE by #1024: the bare `when/where/why/how` on a
#                   VALUE operand returns the literal constants 0,0,0,1, because
#                   since #262 Step E observer state is binding-keyed and a bare
#                   value has no binding. Kept in the switch anyway: it costs a
#                   program its gate and being wrong in that direction is safe.
#   OP_IMPORT       not an observer reader at all. It is in the switch because
#                   it compiles a NEW unit at runtime whose own scan arrives too
#                   late to have observed this unit's earlier assignments — the
#                   ordering hazard, not a read. Its literal-target sibling
#                   `load_file` is handled by chunk_scan_static_loads instead;
#                   import's resolution is project-first-then-stdlib against a
#                   per-module dir and replicating it would be a second resolver
#                   free to drift (#737), so it stays conservative.
EXEMPT="OP_INTERROGATE OP_IMPORT"

# ---- extraction -------------------------------------------------------------
#
# awk portability (§63): no dynamic regex, no 3-argument match(), no gensub().
# A dialect that silently fails a dynamic regex still prints a plausible count
# and turns every comparison false, which looks exactly like a clean pass.
#
# Block comments are stripped with real state (§54/§57), not a per-line regex:
# this switch's own comments discuss OP_LOOP_CAP_CHECK and OP_CALL by name, and
# a scanner that reads prose ABOUT its subject as its subject is the failure
# that gets worse the better the code is documented.
switch_reader_ops() {
    awk -v fn="int chunk_reads_observer(" '
        index($0, fn) > 0 { infn = 1 }
        infn == 0 { next }
        {
            line = $0; out = ""; i = 1; n = length(line)
            while (i <= n) {
                c = substr(line, i, 2)
                if (incomment) {
                    if (c == "*/") { incomment = 0; i += 2 } else { i += 1 }
                    continue
                }
                if (c == "/*") { incomment = 1; i += 2; continue }
                if (c == "//") { break }
                out = out substr(line, i, 1); i += 1
            }
            # Trim leading whitespace off the surviving CODE.
            sub(/^[ \t]+/, "", out)
            if (index(out, "case OP_") == 1) {
                rest = substr(out, 6)              # drop "case "
                p = index(rest, ":")
                if (p > 0) print substr(rest, 1, p - 1)
            }
            # The switch ends at the function-closing brace column 0.
            if (index($0, "^}") == 1) infn = 0
        }
        /^}/ { if (infn) infn = 0 }
    ' "$CHUNK_SRC" | sort -u
}

FAILED=0
CHECKS=0
note_fail() { FAILED=$((FAILED + 1)); echo "FAIL: $*"; }
ck() { CHECKS=$((CHECKS + 1)); }

# Space-separated, deliberately: the membership tests below are `case` globs of
# the form *" $op "*, which need a SPACE on both sides. Leaving these
# newline-separated makes every membership test false — and the symptom is every
# opcode failing BOTH directions at once, which is the harness-bug signature
# (§66), not a divergence. That is exactly how this gate first ran.
MARKER_READS=" $($MARKER_TOOL --reads 2>/dev/null | sort -u | tr '\n' ' ')"
SWITCH_OPS=" $(switch_reader_ops | tr '\n' ' ')"

MARKER_N=$(printf '%s' "$MARKER_READS" | tr ' ' '\n' | grep -c '^OP_' || true)
SWITCH_N=$(printf '%s' "$SWITCH_OPS" | tr ' ' '\n' | grep -c '^OP_' || true)

# 1. Non-vacuity. A derivation that silently returns nothing is the failure this
#    whole gate exists to prevent, one level up: an empty marker set classifies
#    every program as observer-free.
ck
if [ "$MARKER_N" -lt "$READS_FLOOR" ]; then
    note_fail "marker READS set is $MARKER_N, floor is $READS_FLOOR"
fi
ck
if [ "$SWITCH_N" -lt "$SWITCH_FLOOR" ]; then
    note_fail "chunk_reads_observer lists $SWITCH_N reader opcodes, floor is $SWITCH_FLOOR"
fi

# 2. THE HARD DIRECTION. A marker-declared reader missing from the switch is the
#    silent-wrong case: gated off, then reading slots nobody updated.
ck
for op in $MARKER_READS; do
    case " $SWITCH_OPS " in
        *" $op "*) ;;
        *) note_fail "opcode $op is marked obs:READS in src/vm.h but is NOT listed in chunk_reads_observer" ;;
    esac
done

# 3. THE SOFT DIRECTION, modulo pinned exemptions.
ck
for op in $SWITCH_OPS; do
    case " $MARKER_READS " in *" $op "*) continue ;; esac
    case " $EXEMPT " in
        *" $op "*) ;;
        *) note_fail "chunk_reads_observer lists $op, which is not obs:READS and is not a pinned exemption" ;;
    esac
done

# 4. Every exemption must still FIRE (§3). An unused waiver means the thing it
#    waived changed shape — exactly when a stale waiver starts covering
#    something nobody agreed to.
for op in $EXEMPT; do
    ck
    case " $SWITCH_OPS " in
        *" $op "*) ;;
        *) note_fail "pinned exemption $op is no longer listed in chunk_reads_observer — remove the exemption" ;;
    esac
    ck
    case " $MARKER_READS " in
        *" $op "*) note_fail "pinned exemption $op is now marked obs:READS — the exemption is spent, remove it" ;;
        *) ;;
    esac
done

# 5. Pin the assertion count (§37): deleting a whole check must not quietly
#    shrink this gate while it keeps printing OK.
EXPECTED_CHECKS=$((4 + 2 * $(printf '%s\n' $EXEMPT | grep -c .)))
if [ "$CHECKS" -ne "$EXPECTED_CHECKS" ]; then
    echo "FAIL: ran $CHECKS assertions, expected $EXPECTED_CHECKS (a check was added or deleted)"
    FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL — the observer-reader rule has diverged between its two homes"
    exit 1
fi
echo "RESULT: PASS — $MARKER_N marker readers, $SWITCH_N switch entries, $(printf '%s\n' $EXEMPT | grep -c .) pinned exemptions, $CHECKS assertions"
