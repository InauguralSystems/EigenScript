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


# ---- --selftest -------------------------------------------------------------
#
# WHY THIS EXISTS. The first version of this file advertised --selftest in its
# Usage block and had no such branch; `--selftest` was silently ignored and the
# gate printed PASS. The "5-mutation train, all caught" behind it was a one-off
# run banked nowhere, so nothing re-ran it — and a blind critic then showed that
# EVERY substantive assertion could be gutted while the gate stayed green on a
# tree carrying the exact fault that assertion exists to catch. The count pin
# could not see it, because gutting a body leaves the number of loops unchanged
# (§45). A gate nobody mutation-tests is a gate nobody has shown to work (§19).
#
# TWO TRAINS, because they answer different questions:
#
#   FAULTS  — plant a real divergence in COPIES of the two homes and require the
#             gate to go red. Proves the gate can fail at all.
#   WITNESS — plant the same fault AND gut one assertion's body in a copy of the
#             gate. The mutant must go GREEN, which proves that assertion is the
#             SOLE witness for that fault. If it stays red, some neighbouring
#             guard is covering for it (§21) and the assertion is untested.
#
# §66: the mutants run with ABSOLUTE CHUNK_SRC / MARKER_TOOL, so this file's
# opening `cd` is inert and a copy placed anywhere still resolves its inputs.
# The uniform-failure signature (every fixture failing identically) means the
# harness broke, not the artifact.
run_selftest() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    local pass=0 fail=0
    local real_vm="$PWD/src/vm.h" real_chunk="$PWD/$CHUNK_SRC" real_gate="$PWD/${BASH_SOURCE[0]#./}"
    [ -f "$real_gate" ] || real_gate="$PWD/tools/obs_reader_sync_check.sh"

    # A marker tool bound to a MUTABLE copy of vm.h.
    mk_marker() {
        printf '#!/bin/bash\nVM_HEADER=%s exec %s/tools/obs_marker_check.sh "$@"\n' "$1" "$PWD" > "$tmp/marker.sh"
        chmod +x "$tmp/marker.sh"
    }
    # run_gate <gate> <chunk> <vmh> -> prints rc
    run_gate() {
        mk_marker "$3"
        CHUNK_SRC="$2" MARKER_TOOL="$tmp/marker.sh" bash "$1" >/dev/null 2>&1
        echo $?
    }
    say() { # name expected got
        if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1 (rc=$3)"
        else fail=$((fail+1)); echo "  MISS $1 — expected rc=$2, got rc=$3"; fi
    }

    # Fault fixtures, each in its own pair of copies.
    plant() { # name -> writes $tmp/<name>.chunk.c and $tmp/<name>.vm.h
        cp "$real_chunk" "$tmp/$1.chunk.c"; cp "$real_vm" "$tmp/$1.vm.h"
        case "$1" in
          clean) ;;
          E) sed -i '/^            case OP_TRAJECTORY_SLOT:$/d' "$tmp/$1.chunk.c" ;;      # reader dropped from switch
          B) sed -i 's/^            case OP_PREDICATE:$/            case OP_ADD:\n            case OP_PREDICATE:/' "$tmp/$1.chunk.c" ;;  # stray opcode
          D) sed -i '/^            case OP_IMPORT:$/d' "$tmp/$1.chunk.c" ;;               # exemption dropped
          F) sed -i 's|OP_INTERROGATE,     /\*obs:NONE\*/|OP_INTERROGATE,     /*obs:READS*/|' "$tmp/$1.vm.h" ;;  # exemption spent
        esac
    }
    # Assertion gutters, keyed to the fault each one is the sole witness for.
    gut() { # name -> writes $tmp/<name>.gate.sh
        cp "$real_gate" "$tmp/$1.gate.sh"
        case "$1" in
          E) sed -i 's|\*) note_fail "opcode \$op is marked obs:READS.*|*) : ;;|' "$tmp/$1.gate.sh" ;;
          B) sed -i 's|\*) note_fail "chunk_reads_observer lists \$op, which is not.*|*) : ;;|' "$tmp/$1.gate.sh" ;;
          D) sed -i 's|\*) note_fail "pinned exemption \$op is no longer listed.*|*) : ;;|' "$tmp/$1.gate.sh" ;;
          F) sed -i 's|\*" \$op "\*) note_fail "pinned exemption \$op is now marked.*|*" $op "*) : ;;|' "$tmp/$1.gate.sh" ;;
        esac
        # The count pin would catch a gutted body only by accident; neutralise it
        # so this train measures the ASSERTION, not the pin (§21: know which
        # check fired). The pin is exercised by its own row below.
        sed -i 's|^if \[ "\$CHECKS" -ne "\$EXPECTED_CHECKS" \]; then|if false; then|' "$tmp/$1.gate.sh"
        # Floors are genuinely redundant with the direction checks for some
        # faults; neutralise them too so a survivor means "no witness", not
        # "a floor covered for it".
        sed -i 's|^READS_FLOOR=.*|READS_FLOOR=0|; s|^SWITCH_FLOOR=.*|SWITCH_FLOOR=0|' "$tmp/$1.gate.sh"
    }

    echo "== control: unmutated copies must PASS =="
    plant clean; say "clean copies" 0 "$(run_gate "$real_gate" "$tmp/clean.chunk.c" "$tmp/clean.vm.h")"

    echo "== FAULTS: the real gate must go red on each =="
    for f in E B D F; do
        plant "$f"
        say "fault $f caught by the real gate" 1 "$(run_gate "$real_gate" "$tmp/$f.chunk.c" "$tmp/$f.vm.h")"
    done

    echo "== WITNESS: gutting the sole witness must let its fault SURVIVE =="
    for f in E B D F; do
        gut "$f"
        say "assertion $f is the sole witness" 0 "$(run_gate "$tmp/$f.gate.sh" "$tmp/$f.chunk.c" "$tmp/$f.vm.h")"
    done

    echo "== the count pin catches a DELETED check =="
    cp "$real_gate" "$tmp/pin.gate.sh"
    sed -i 's|^    ck$||' "$tmp/pin.gate.sh"
    plant clean
    say "deleting a ck() trips the comparison pin" 1 "$(run_gate "$tmp/pin.gate.sh" "$tmp/clean.chunk.c" "$tmp/clean.vm.h")"

    echo "SELFTEST: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] || return 1
    return 0
}

if [ "${1:-}" = "--selftest" ]; then
    run_selftest
    exit $?
fi

FAILED=0
CHECKS=0
# CHECKS counts COMPARISONS PERFORMED, not loops entered. Counting per-loop is
# invariant under the mutation that matters — gutting a loop's body leaves the
# count untouched while the gate stops checking anything (mechanical-gates §45:
# ask what change keeps the number constant while destroying what it counts).
# The count pin is still not sufficient on its own; --selftest is what proves
# each assertion body is load-bearing.
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
for op in $MARKER_READS; do
    ck
    case " $SWITCH_OPS " in
        *" $op "*) ;;
        *) note_fail "opcode $op is marked obs:READS in src/vm.h but is NOT listed in chunk_reads_observer" ;;
    esac
done

# 3. THE SOFT DIRECTION, modulo pinned exemptions.
for op in $SWITCH_OPS; do
    ck
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

# 5. Floor the comparisons actually performed (§37/§43). Every marker reader is
#    compared once, every switch entry once, plus two rows per exemption and the
#    two non-vacuity checks. A gate that examined fewer items than that has
#    stopped checking something, whatever it prints.
EXPECTED_CHECKS=$((2 + MARKER_N + SWITCH_N + 2 * $(printf '%s\n' $EXEMPT | grep -c .)))
if [ "$CHECKS" -ne "$EXPECTED_CHECKS" ]; then
    echo "FAIL: performed $CHECKS comparisons, expected $EXPECTED_CHECKS (a check was added, deleted or gutted)"
    FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL — the observer-reader rule has diverged between its two homes"
    exit 1
fi
echo "RESULT: PASS — $MARKER_N marker readers, $SWITCH_N switch entries, $(printf '%s\n' $EXEMPT | grep -c .) pinned exemptions, $CHECKS assertions"
