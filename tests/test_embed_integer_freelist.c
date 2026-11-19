/* #2433 B2: construct before the first program and release after the last. */
#include "eigs_embed.h"
#include <stdint.h>
#include <stdio.h>
int main(void) {
    EigsState *state = eigs_open();
    if (!state) return 2;
    EigsValue *boxed = eigs_value_new_int(INT64_C(281474976710663));
    if (!boxed || !eigs_value_is_int(boxed)) return 2;
    EigsValue *result = eigs_eval_string("1 + 1");
    if (!result || eigs_has_error()) return 2;
    eigs_value_release(result);
    eigs_value_release(boxed);
    puts("PASS: boxed integer embedding lifecycle");
    eigs_close(state);
    return 0;
}
