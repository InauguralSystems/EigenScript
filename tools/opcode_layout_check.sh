#!/bin/bash
# Opcode layout-table drift gate (#737).
#
# Adding one opcode requires editing several hand-maintained metadata sites,
# and three of them had ALREADY drifted when #737 was filed: op_verify_operands
# (the untrusted-chunk sandbox gate) was missing OP_TRAJECTORY_SLOT, op_name
# printed 4 opcodes as "???", and the disassembler's operand-width table was
# missing 16 opcodes. The compile-time leg of the fix types the three layout
# switches as OpCode with no default arm so -Werror=switch (Makefile:9)
# makes a missing case a build error — but that covers only the switch-based
# tables, and only under a compiler that honors it. op_name is a lookup TABLE
# (a switch cannot enforce a designated-initializer array), so this grep gate
# is the table-agnostic backstop: every opcode in the OpCode enum must be
# named in ALL FOUR metadata sites:
#
#   1. op_name()               — src/chunk.c   (disassembler names)
#   2. op_u16_operand_count()  — src/chunk.c   (disassembler operand widths)
#   3. op_verify_operands()    — src/chunk.c   (untrusted-chunk verifier)
#   4. op_stack_effect()       — src/compiler.c (stack-depth accounting)
#
# Usage: tools/opcode_layout_check.sh [--selftest]
#   --selftest : inject a fake opcode and confirm the gate flags it (proves
#                the checker isn't vacuously green).
# Exit 0 = all four tables cover every opcode; 1 = drift (or selftest failure).

set -u
cd "$(dirname "$0")/.."

# --- every opcode in the OpCode enum (src/vm.h), minus the OP_COUNT sentinel ---
enum_opcodes() {
    awk '/^typedef enum \{/,/^\} OpCode;/' src/vm.h \
        | grep -oE '^[[:space:]]+OP_[A-Z_0-9]+' | tr -d ' ' \
        | grep -v '^OP_COUNT$' | sort -u
}

# --- OP_ tokens mentioned inside one function body (col-0 start to col-0 }) ---
function_opcodes() {  # args: file, function-start-regex
    awk "/$2/,/^\\}/" "$1" | grep -oE 'OP_[A-Z_0-9]+' | grep -v '^OP_COUNT$' | sort -u
}

check_table() {  # args: label, file, function-start-regex, required-set
    local label="$1" file="$2" fnre="$3" required="$4"
    local have missing
    have=$(function_opcodes "$file" "$fnre")
    missing=$(comm -23 <(printf '%s\n' "$required") <(printf '%s\n' "$have"))
    if [ -n "$missing" ]; then
        echo "OPCODE TABLE DRIFT in $label ($file): opcode(s) absent from the table:"
        echo "$missing" | sed 's/^/  - /'
        return 1
    fi
    return 0
}

check_all() {  # arg: optional extra (fake) opcode for selftest
    local extra="${1:-}" required rc=0
    required=$(enum_opcodes)
    [ -n "$extra" ] && required=$(printf '%s\n%s\n' "$required" "$extra" | sort -u)
    check_table "op_name"              src/chunk.c    '^const char \*op_name'          "$required" || rc=1
    check_table "op_u16_operand_count" src/chunk.c    '^static int op_u16_operand_count' "$required" || rc=1
    check_table "op_verify_operands"   src/chunk.c    '^static int op_verify_operands'   "$required" || rc=1
    check_table "op_stack_effect"      src/compiler.c '^static int op_stack_effect'      "$required" || rc=1
    return $rc
}

# --- selftest: the gate MUST catch a deliberately-injected fake opcode ---
if [ "${1:-}" = "--selftest" ]; then
    if check_all "OP_ZZ_SELFTEST_PROBE" >/dev/null 2>&1; then
        echo "SELFTEST FAILED: gate did not flag an injected fake opcode"
        exit 1
    fi
    echo "SELFTEST OK: gate flags an injected fake opcode"
    exit 0
fi

if check_all; then
    echo "opcode layout OK: $(enum_opcodes | wc -l | tr -d ' ') opcodes covered by all 4 metadata tables"
    exit 0
fi
exit 1
