/*
 * Opcode numeric ABI guard.
 *
 * vm_run_bytecode / sandbox_run accept bytecode assembled as data from
 * EigenScript, so opcode enum values are part of the self-hosting bridge ABI.
 * These assertions cover the numeric opcodes currently hardcoded by
 * tests/test_vm_run_bytecode.eigs and catch accidental mid-enum insertions.
 */

#include "eigenscript.h"
#include "vm.h"

#define ABI_ASSERT(op, value) _Static_assert((op) == (value), #op " ABI value changed")

ABI_ASSERT(OP_CONST, 0);
ABI_ASSERT(OP_NUM_ONE, 3);
ABI_ASSERT(OP_ADD, 4);
ABI_ASSERT(OP_GT, 20);
ABI_ASSERT(OP_GET_LOCAL, 23);
ABI_ASSERT(OP_SET_LOCAL, 24);
ABI_ASSERT(OP_GET_NAME, 25);
ABI_ASSERT(OP_SET_NAME_LOCAL, 27);
ABI_ASSERT(OP_JUMP_BACK, 30);
ABI_ASSERT(OP_JUMP_IF_FALSE, 31);
ABI_ASSERT(OP_POP, 35);
ABI_ASSERT(OP_CLOSURE, 38);
ABI_ASSERT(OP_CALL, 39);
ABI_ASSERT(OP_RETURN, 40);
ABI_ASSERT(OP_RETURN_NULL, 41);
ABI_ASSERT(OP_DICT, 43);
ABI_ASSERT(OP_LOOP_CAP_CHECK, 63);
ABI_ASSERT(OP_LINE, 68);

/* #704: the revision the ABI-stamped descriptors in tests/*.eigs declare. Those
 * files carry `ABI is 1` as a literal (as an external producer must), so a bump
 * in vm.h that forgets them would otherwise surface as a pile of runtime
 * failures instead of one build error naming the cause. Bump both together. */
/* ASCII only in the message: gcc escapes non-ASCII bytes octally in a failed
 * static-assertion diagnostic, which turns punctuation into line noise. */
_Static_assert(EIGS_BYTECODE_ABI == 1,
               "EIGS_BYTECODE_ABI changed - bump `ABI is N` in "
               "tests/test_vm_run_bytecode.eigs, tests/test_sandbox_allow.eigs, "
               "tests/test_sandbox_budget.eigs, and re-stamp every external "
               "producer (ouroboros, iLambdaAi) with its EIGS_REF bump");

int main(void) {
    return 0;
}
