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
ABI_ASSERT(OP_GET_NAME, 25);
ABI_ASSERT(OP_SET_NAME_LOCAL, 27);
ABI_ASSERT(OP_JUMP_BACK, 30);
ABI_ASSERT(OP_JUMP_IF_FALSE, 31);
ABI_ASSERT(OP_POP, 35);
ABI_ASSERT(OP_CLOSURE, 38);
ABI_ASSERT(OP_CALL, 39);
ABI_ASSERT(OP_RETURN, 40);
ABI_ASSERT(OP_RETURN_NULL, 41);
ABI_ASSERT(OP_LOOP_CAP_CHECK, 63);

int main(void) {
    return 0;
}
