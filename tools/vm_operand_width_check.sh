#!/bin/bash
# VM operand-width comment drift gate (#958).
#
# The enum comments in src/vm.h are an ABI-facing description of the bytecode
# stream.  This gate derives the truth for every `kind` operand from the VM's
# uintN_t/read_uN/advance decoder sites and checks that each opcode is also present in
# chunk.c's shared VR_RAW verifier table.  It therefore does not keep a second
# hand-written width list that could drift with the production code.
#
# Usage: tools/vm_operand_width_check.sh [--selftest]
#   --selftest : plant a third kind-width mismatch in a temporary vm.h and
#                require the same assertion to catch it.
# Exit 0 = all decoder/verifier kind widths match vm.h comments.

set -u
cd "$(dirname "$0")/.." || exit 1

# Coverage floor. The population below is derived by matching decoder sites in
# vm.c, so it can SHRINK without anything failing: reformat a decoder site so
# the match no longer applies AND tidy its [kind:N] comment away in the same
# pass, and both sides of the cross-check lose the opcode together. Measured on
# the tree that introduced this gate: doing exactly that took it from 7 operands
# to 6 and it still printed PASS with exit 0. A `-z` emptiness test is not a
# floor — it only catches losing ALL of them.
#
# Bump this deliberately when a kind operand is genuinely added or removed; a
# DECREASE is a review event, not a number to adjust.
KIND_OPERAND_FLOOR="${KIND_OPERAND_FLOOR:-7}"

VM_HEADER="${VM_HEADER:-src/vm.h}"
VM_SOURCE="${VM_SOURCE:-src/vm.c}"
CHUNK_SOURCE="${CHUNK_SOURCE:-src/chunk.c}"

# Emit `OP_NAME type_bits read_bits advance_bytes` for every CASE whose handler
# reads a kind.  All three widths come from the production decoder expression.
decoder_kind_widths() {
    awk '
        /CASE\([A-Z0-9_]+\)/ {
            op = $0
            sub(/^.*CASE\(/, "", op)
            sub(/\).*/, "", op)
        }
        /uint[0-9]+_t[[:space:]]+kind[[:space:]]*=[[:space:]]*read_u[0-9]+[[:space:]]*\(ip\)/ {
            type = $0; sub(/^.*uint/, "", type); sub(/_t.*/, "", type)
            read = $0; sub(/^.*read_u/, "", read); sub(/\(.*/, "", read)
            advance = $0; sub(/^.*ip[[:space:]]*\+=[[:space:]]*/, "", advance); sub(/[^0-9].*/, "", advance)
            if (op != "") print "OP_" op, type, read, advance
        }
    ' "$VM_SOURCE"
}

# Emit every opcode whose first operand is VR_RAW from the production verifier
# table.  Case arms are accumulated across lines until roles[0] is assigned.
verifier_raw_ops() {
    sed -n '/static int op_verify_operands/,/\/\* ---- Stack-height model/p' "$CHUNK_SOURCE" \
    | awk '
        {
            line = $0
            while (match(line, /case OP_[A-Z0-9_]+/)) {
                op = substr(line, RSTART + 5, RLENGTH - 5)
                pending[++n] = op
                line = substr(line, RSTART + RLENGTH)
            }
            if ($0 ~ /roles\[0\][[:space:]]*=[[:space:]]*VR_RAW/) {
                for (i = 1; i <= n; i++) print pending[i]
                n = 0
            } else if ($0 ~ /return[[:space:]]+[0-9]+;/) {
                n = 0
            }
        }
    ' | sort -u
}

# Emit `OP_NAME bits` for vm.h's first [kind:bits] annotation on each opcode.
header_kind_widths() {
    sed -nE 's/^[[:space:]]*(OP_[A-Z0-9_]+),.*\/\* \[kind:([0-9]+)\].*/\1 \2/p' "$VM_HEADER"
}

check_tree() {
    local decoder raw comments missing width op bits expected got drift verifier_stride decoder_count
    drift=0
    decoder=$(decoder_kind_widths)
    raw=$(verifier_raw_ops)
    comments=$(header_kind_widths)
    verifier_stride=$(sed -nE 's/^[[:space:]]*int end = i[[:space:]]*\+[[:space:]]*1[[:space:]]*\+[[:space:]]*([0-9]+)[[:space:]]*\*[[:space:]]*nops.*/\1/p' "$CHUNK_SOURCE" | awk 'NF { print; exit }')

    if [ -z "$decoder" ]; then
        echo "GATE ERROR: no uintN_t/read_uN kind decoder evidence found in $VM_SOURCE"
        return 1
    fi
    decoder_count=$(printf '%s\n' "$decoder" | awk 'NF { n++ } END { print n + 0 }')
    if [ "$decoder_count" -lt "$KIND_OPERAND_FLOOR" ]; then
        echo "GATE ERROR: only $decoder_count kind operand(s) found in $VM_SOURCE, floor is $KIND_OPERAND_FLOOR"
        echo "  the matcher stopped seeing a decoder site, or a kind operand was removed;"
        echo "  either way this gate is now checking less than it was built to check."
        return 1
    fi
    if [ -z "$raw" ] || [ -z "$verifier_stride" ] || ! sed -n '/void chunk_disassemble/,/\/\* ---- Bytecode verifier/p' "$CHUNK_SOURCE" | grep -qE 'i[[:space:]]*\+= 2'; then
        echo "GATE ERROR: no VR_RAW/u16-stride verifier evidence found in $CHUNK_SOURCE"
        return 1
    fi
    if [ -z "$comments" ]; then
        echo "GATE ERROR: no [kind:bits] comments found in $VM_HEADER"
        return 1
    fi

    missing=$(comm -23 \
        <(printf '%s\n' "$decoder" | awk '{print $1}' | sort -u) \
        <(printf '%s\n' "$raw" | sort -u))
    if [ -n "$missing" ]; then
        echo "GATE ERROR: decoder kind opcode(s) missing from chunk.c VR_RAW verifier table:"
        printf '%s\n' "$missing" | sed 's/^/  - /'
        return 1
    fi

    while read -r op bits; do
        [ -n "$op" ] || continue
        expected=""
        while read -r decoded_op decoded_bits decoded_read decoded_advance; do
            if [ "$decoded_op" = "$op" ]; then
                expected="$decoded_bits"
                break
            fi
        done <<EOF
$decoder
EOF
        if [ -z "$expected" ]; then
            echo "GATE ERROR: $op has a [kind:$bits] comment but no production decoder evidence"
            drift=1
            continue
        fi
        if [ "$bits" != "$expected" ]; then
            echo "ASSERTION FAILED: $op declares [kind:$bits], but vm.c decoder evidence is u$expected and chunk.c verifier evidence marks its kind operand VR_RAW"
            drift=1
        fi
    done <<EOF
$comments
EOF

    while read -r op expected read_bits advance_bytes; do
        [ -n "$op" ] || continue
        if [ "$expected" != "$read_bits" ] || [ "$read_bits" != "$((advance_bytes * 8))" ] || [ "$advance_bytes" != "$verifier_stride" ]; then
            echo "ASSERTION FAILED: $op decoder shape disagrees: uint${expected}_t/read_u${read_bits}/ip advance ${advance_bytes} bytes, verifier stride ${verifier_stride} bytes"
            drift=1
        fi
        got=""
        while read -r comment_op comment_bits; do
            if [ "$comment_op" = "$op" ]; then
                got="$comment_bits"
                break
            fi
        done <<EOF
$comments
EOF
        if [ -z "$got" ]; then
            echo "ASSERTION FAILED: $op has production u$expected kind evidence but no [kind:$expected] vm.h comment"
            drift=1
            continue
        fi
        if [ "$got" != "$expected" ]; then
            echo "ASSERTION FAILED: $op declares [kind:$got], but vm.c decoder evidence is u$expected and chunk.c verifier evidence marks its kind operand VR_RAW"
            drift=1
        fi
    done <<EOF
$decoder
EOF

    if [ "$drift" -ne 0 ]; then
        return 1
    fi
    echo "PASS: $(printf '%s\n' "$decoder" | awk 'NF { n++ } END { print n + 0 }') VM kind operands match decoder/verifier widths"
    return 0
}

if [ "${1:-}" = "--selftest" ]; then
    st_fail=0
    work=$(mktemp -d /tmp/eigs_vm_operand_width_XXXXXX)
    trap 'rm -rf -- "$work"' EXIT

    if ! check_tree >/dev/null 2>&1; then
        echo "SELFTEST FAILED: the real tree does not pass its own width check"
        st_fail=1
    fi

    # Plant a third mismatch that is not one of the issue's two reported lines.
    awk '
        /OP_INTERROGATE_NAMED,.*\[kind:16\]/ && !done {
            sub(/\[kind:16\]/, "[kind:8]")
            done = 1
        }
        { print }
        END { if (!done) exit 2 }
    ' "$VM_HEADER" > "$work/vm.h"
    if [ ! -s "$work/vm.h" ]; then
        echo "SELFTEST FAILED: could not plant OP_INTERROGATE_NAMED width mismatch"
        st_fail=1
    elif out=$(VM_HEADER="$work/vm.h" check_tree 2>&1); then
        echo "SELFTEST FAILED: planted OP_INTERROGATE_NAMED mismatch was not caught"
        st_fail=1
    elif ! printf '%s\n' "$out" | grep -qF \
        "ASSERTION FAILED: OP_INTERROGATE_NAMED declares [kind:8], but vm.c decoder evidence is u16"; then
        echo "SELFTEST FAILED: planted mismatch did not fail at the expected assertion"
        printf '%s\n' "$out"
        st_fail=1
    else
        echo "SELFTEST OK: planted OP_INTERROGATE_NAMED mismatch is caught at assertion level"
    fi

    # Plant a decoder-shape mismatch while leaving the uint16_t declaration
    # and vm.h comment untouched.  A width gate that reads only the destination
    # type would miss this production drift.
    awk '
        /CASE\(INTERROGATE_NAMED\)/ { armed = 1 }
        armed && /uint16_t kind = read_u16\(ip\); ip \+= 2;/ && !done {
            sub(/read_u16/, "read_u8")
            sub(/ip \+= 2/, "ip += 1")
            done = 1
        }
        { print }
        END { if (!done) exit 2 }
    ' "$VM_SOURCE" > "$work/vm.c"
    awk '{ sub(/uint16_t kind = read_u8/, "uint8_t kind = read_u8"); print }' "$work/vm.c" > "$work/vm_stride.c"
    if [ ! -s "$work/vm.c" ]; then
        echo "SELFTEST FAILED: could not plant OP_INTERROGATE_NAMED decoder-shape mismatch"
        st_fail=1
    elif out=$(VM_SOURCE="$work/vm.c" check_tree 2>&1); then
        echo "SELFTEST FAILED: planted OP_INTERROGATE_NAMED decoder-shape mismatch was not caught"
        st_fail=1
    elif ! printf '%s\n' "$out" | grep -qF \
        "ASSERTION FAILED: OP_INTERROGATE_NAMED decoder shape"; then
        echo "SELFTEST FAILED: planted decoder-shape mismatch did not fail at assertion level"
        printf '%s\n' "$out"
        st_fail=1
    else
        if out=$(VM_HEADER="$work/vm.h" VM_SOURCE="$work/vm_stride.c" check_tree 2>&1); then echo "SELFTEST FAILED: verifier-stride mutation was not caught"; st_fail=1; elif printf '%s\n' "$out" | grep -qF "ASSERTION FAILED: OP_INTERROGATE_NAMED decoder shape disagrees: uint8_t/read_u8/ip advance 1 bytes, verifier stride 2 bytes"; then echo "SELFTEST OK: planted OP_INTERROGATE_NAMED verifier-stride mismatch is caught at assertion level"; else echo "SELFTEST FAILED: verifier-stride mutation did not fail at assertion level"; printf '%s\n' "$out"; st_fail=1; fi
    fi

    # Plant a SIMULTANEOUS loss on both sides: reformat a decoder site so the
    # matcher misses it AND remove the matching [kind:N] comment. Individually
    # either one is caught by the opposite direction of the cross-check; losing
    # both together is what silently shrinks the population, and only the floor
    # catches it.
    awk '
        /uint16_t kind = read_u16\(ip\); ip \+= 2;/ && !done {
            sub(/uint16_t kind = read_u16\(ip\); ip \+= 2;/,
                "uint16_t kind =\n            read_u16(ip); ip += 2;")
            done = 1
        }
        { print }
        END { if (!done) exit 2 }
    ' "$VM_SOURCE" > "$work/vm_shrunk.c" || st_fail=1
    # `.*` between the comma and the comment opener, not `[[:space:]]*`: the
    # enum line carries an /*obs:...*/ observer-classification marker between
    # the two (#972), and anchoring on whitespace alone made this mutation a
    # no-op — the selftest then failed with "could not remove the comment"
    # rather than silently passing, which is the only reason it was noticed.
    sed -E 's@^([[:space:]]*OP_INTERROGATE,.*\/\* )\[kind:16\] @\1@' \
        "$VM_HEADER" > "$work/vm_shrunk.h"
    if cmp -s "$work/vm_shrunk.h" "$VM_HEADER"; then
        echo "SELFTEST FAILED: could not remove the OP_INTERROGATE [kind:16] comment"
        st_fail=1
    elif out=$(VM_HEADER="$work/vm_shrunk.h" VM_SOURCE="$work/vm_shrunk.c" check_tree 2>&1); then
        echo "SELFTEST FAILED: population shrank to 6 and the gate still passed"
        st_fail=1
    elif ! printf '%s\n' "$out" | grep -qF "GATE ERROR: only 6 kind operand(s) found"; then
        echo "SELFTEST FAILED: shrunken population did not trip the coverage floor"
        printf '%s\n' "$out"
        st_fail=1
    else
        echo "SELFTEST OK: a silently shrinking kind-operand population trips the floor"
    fi

    if [ "$st_fail" -eq 0 ]; then
        echo "SELFTEST PASS: decoder/verifier width gate is non-vacuous"
    fi
    exit "$st_fail"
fi

check_tree
