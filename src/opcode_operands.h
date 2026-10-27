#ifndef EIGENSCRIPT_OPCODE_OPERANDS_H
#define EIGENSCRIPT_OPCODE_OPERANDS_H

/* Shared bytecode operand layout. Include this after the header that defines
 * OpCode and OP_COUNT. Keeping the table header-only lets standalone walkers
 * (notably the JIT smoke builds) use the canonical layout without chunk.c. */

typedef enum {
    VR_RAW = 0,   /* count / kind / line / runtime-guarded slot — no bound */
    VR_CONST,     /* constant-pool index — any value type (OP_CONST push) */
    VR_NAME,      /* constant-pool index that must be an interned string */
    VR_FN,        /* index into nested functions[] */
    VR_JFWD,      /* forward jump: target = end_of_instruction + offset */
    VR_JBACK      /* backward jump: target = end_of_instruction - offset */
} VerifyRole;

/* Fill roles[] for op; return its u16 operand count (0..3). This exhaustive
 * switch is the single operand-role table used by every bytecode walker. */
static inline int op_verify_operands(uint8_t op8, VerifyRole roles[3]) {
    switch ((OpCode)op8) {
    case OP_CONST:
        roles[0] = VR_CONST; return 1;
    case OP_GET_NAME: case OP_SET_NAME: case OP_SET_NAME_LOCAL:
    case OP_SET_FN_NAME_LOCAL: case OP_DOT_GET: case OP_DOT_SET:
    case OP_REPORT_NAME: case OP_OBSERVE_VALUE_NAME: case OP_OBSERVE_NAME_POST:
    case OP_REPORT_VALUE_NAME: case OP_TRAJECTORY_NAME:
    case OP_IMPORT:
        roles[0] = VR_NAME; return 1;
    case OP_CLOSURE:
        roles[0] = VR_FN; return 1;
    case OP_JUMP: case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE:
    case OP_JUMP_IF_FALSE_PEEK: case OP_JUMP_IF_TRUE_PEEK:
    case OP_ITER_NEXT: case OP_TRY_BEGIN:
        roles[0] = VR_JFWD; return 1;
    case OP_LOOP_STALL_NAMED: case OP_LOOP_CAP_NAMED:
        roles[0] = VR_JFWD; roles[1] = VR_RAW; return 2;
    case OP_LOOP_STALL_CHECK: case OP_LOOP_CAP_CHECK:
        roles[0] = VR_JFWD; return 1;
    case OP_JUMP_BACK:
        roles[0] = VR_JBACK; return 1;
    case OP_GET_LOCAL: case OP_SET_LOCAL: case OP_SET_LOCAL_INTERNAL: case OP_CALL:
    case OP_LIST: case OP_DICT:
    case OP_OBSERVE_ASSIGN: case OP_OBSERVE_ASSIGN_LOCAL:
    case OP_REPORT_SLOT: case OP_OBSERVE_VALUE_SLOT:
    case OP_REPORT_VALUE_SLOT: case OP_TRAJECTORY_SLOT:
    case OP_INTERROGATE: case OP_PREDICATE:
    case OP_MATCH: case OP_DESTRUCTURE_UNPACK: case OP_LOOP_ENTER_NAMED:
    case OP_LOOP_EXIT_NAMED:
        roles[0] = VR_RAW; return 1;
    case OP_LOCAL_DOT_GET: case OP_LOCAL_DOT_SET:
        roles[0] = VR_RAW; roles[1] = VR_NAME; return 2;
    case OP_LOCAL_IDX_GET:
        roles[0] = VR_RAW; roles[1] = VR_RAW; return 2;
    case OP_INTERROGATE_NAMED: case OP_INTERROGATE_NAMED_AT:
    case OP_INTERROGATE_NAMED_WHEN:
        roles[0] = VR_RAW; roles[1] = VR_NAME; return 2;
    case OP_PREDICATE_SLOT:
        roles[0] = VR_RAW; roles[1] = VR_RAW; return 2;
    case OP_PREDICATE_NAME:
        roles[0] = VR_RAW; roles[1] = VR_NAME; return 2;
    case OP_DEFAULT_PARAM:
        roles[0] = VR_RAW; roles[1] = VR_JFWD; return 2;
    case OP_LOCAL_IDX_DOT_GET: case OP_LOCAL_IDX_DOT_SET:
        roles[0] = VR_RAW; roles[1] = VR_RAW; roles[2] = VR_NAME; return 3;
    case OP_NULL: case OP_NUM_ZERO: case OP_NUM_ONE: case OP_TRUE: case OP_FALSE:
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_MOD:
    case OP_BAND: case OP_BOR: case OP_BXOR: case OP_SHL: case OP_SHR:
    case OP_NEG: case OP_NOT: case OP_BNOT:
    case OP_EQ: case OP_NE: case OP_LT: case OP_GT: case OP_LE: case OP_GE:
    case OP_POP: case OP_DUP: case OP_DUP2:
    case OP_RETURN: case OP_RETURN_NULL:
    case OP_INDEX_GET: case OP_INDEX_SET: case OP_ITER_SETUP:
    case OP_LOOP_ENV_FRESH: case OP_LOOP_ENV_END: case OP_LOOP_ENV_CLEAR:
    case OP_BREAK: case OP_CONTINUE: case OP_TRY_END:
    case OP_UNOBSERVED_BEGIN: case OP_UNOBSERVED_END:
    case OP_LISTCOMP_BEGIN: case OP_LISTCOMP_APPEND:
    case OP_WIDE: case OP_DISPATCH: case OP_SLICE_GET: case OP_LOOP_ENTER:
    case OP_LINE: case OP_BINARY_LINE: case OP_BINARY_LINE_END: case OP_COUNT:
        return 0;
    }
    return 0;
}

static inline int opcode_operand_bytes(uint8_t op) {
    if (op >= OP_COUNT) return -1;
    if (op == OP_LINE || op == OP_BINARY_LINE) return 4;
    VerifyRole roles[3];
    return 2 * op_verify_operands(op, roles);
}

#endif
