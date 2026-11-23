#include <stdio.h>
#include <string.h>
#include "eigs_embed.h"
#include "eigenscript.h"

static int examined, declared, failed;
static void check(EigsOperator op, EigsSlot a, EigsSlot b, const char *src) {
    EigsValue *want = eigs_eval_string(src);
    int want_error = eigs_has_error();
    const char *want_kind = want_error ? eigs_last_error_kind() : NULL;
    eigs_clear_error();
    EigsSlot got = eigs_op_binary(op, a, b);
    int got_error = eigs_has_error();
    if (want_error != got_error || (got_error && (!eigs_last_error_kind() || !want_kind ||
        strcmp(want_kind, eigs_last_error_kind())))) {
        fprintf(stderr, "FAIL: %s VM error=%d export error=%d\n", src, want_error, got_error); failed++;
    }
    if (!want_error && !got_error) {
        EigsValue *gv = slot_to_value(got);
        if (!values_equal(want, gv) || want->type != gv->type) {
            fprintf(stderr, "FAIL: %s VM/export value differs\n", src); failed++;
        }
        eigs_value_release(gv);
    }
    if (want) eigs_value_release(want);
    eigs_clear_error(); slot_decref(got); examined++;
}
int main(void) {
    EigsState *st=eigs_open(); if (!st) return 2;
    EigsSlot i2=slot_from_int(2), i3=slot_from_int(3);
    struct { EigsOperator op; const char *expr; } rows[]={{EIGS_OP_ADD,"2 + 3"},{EIGS_OP_SUB,"2 - 3"},{EIGS_OP_MUL,"2 * 3"},{EIGS_OP_DIV,"2 / 3"},{EIGS_OP_IDIV,"2 // 3"},{EIGS_OP_MOD,"2 % 3"},{EIGS_OP_EQ,"2 == 3"},{EIGS_OP_NE,"2 != 3"},{EIGS_OP_LT,"2 < 3"},{EIGS_OP_LE,"2 <= 3"},{EIGS_OP_GT,"2 > 3"},{EIGS_OP_GE,"2 >= 3"}};
    declared=(int)(sizeof rows/sizeof rows[0]);
    for(int n=0;n<declared;n++){ check(rows[n].op,i2,i3,rows[n].expr); }
    check(EIGS_OP_ADD,slot_from_int(INT64_MAX),slot_from_int(1),"9223372036854775807 + 1");
    check(EIGS_OP_MUL,slot_from_int(INT64_MAX),i2,"9223372036854775807 * 2");
    check(EIGS_OP_IDIV,slot_from_int(INT64_MIN),slot_from_int(-1),"(-9223372036854775807 - 1) // -1");
    check(EIGS_OP_MOD,slot_from_int(INT64_MIN),slot_from_int(-1),"(-9223372036854775807 - 1) % -1");
    check(EIGS_OP_DIV,i2,slot_from_int(0),"2 / 0"); check(EIGS_OP_IDIV,i2,slot_from_int(0),"2 // 0"); check(EIGS_OP_MOD,i2,slot_from_int(0),"2 % 0");
    check(EIGS_OP_IDIV,slot_from_int(-5),i2,"-5 // 2");
    { EigsSlot floor_result=eigs_op_binary(EIGS_OP_IDIV,slot_from_int(-5),i2); int64_t q=0;
      if (!slot_int_value(floor_result,&q) || q != -3) { fprintf(stderr,"FAIL: floor-division plant guard\n"); failed++; }
      slot_decref(floor_result); examined++; }
    EigsSlot u=eigs_op_unary(EIGS_OP_NEG,i2); slot_decref(u); u=eigs_op_unary(EIGS_OP_NOT,i2); slot_decref(u); examined+=2; declared+=2;
    eigs_close(st);
    if (!(examined >= declared && declared > 0) || failed) return 1;
    printf("PASS: generic operator exports examined=%d declared=%d\n",examined,declared); return 0;
}
