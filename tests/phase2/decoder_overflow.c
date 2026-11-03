/* N14/R2.5: JSON decimal overflow refuses inside both owning decoders.
 * Include the store's production translation unit to exercise its static
 * record decoder, as the slot-layer fixture does; do not duplicate a parser. */
#include "eigs_embed.h"
#include "ext_store.c"
#include <stdio.h>
static int checks, failures;
static void check(int ok, const char *name, int mode, const char *input) {
    checks++;
    if (!ok) { failures++; printf("FAIL %s strict=%d input=%s\n", name, mode, input); }
}
int main(void) {
    EigsState *st = eigs_open();
    if (!st) return 2;
    const char *bad[] = {"1e400", "-1e400", "[1,1e400,2]", "{\"v\":-1e400}"};
    for (int mode = 0; mode < 2; mode++) {
        g_strict = mode;
        for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
            eigs_clear_error();
            int pos = 0;
            Value *v = eigs_json_parse_root(bad[i], &pos);
            check(g_has_error && g_error_kind == EK_VALUE,
                  "shared JSON decoder refuses", mode, bad[i]);
            val_decref(v);
            eigs_clear_error();
            v = store_json_decode(bad[i]);
            check(!v && g_has_error && g_error_kind == EK_VALUE,
                  "store decoder refuses", mode, bad[i]);
            val_decref(v);
        }
        const char *good[] = {"1e308", "-1e308", "1e-400", "9223372036854775807"};
        for (size_t i = 0; i < sizeof good / sizeof good[0]; i++) {
            eigs_clear_error();
            int pos = 0;
            Value *v = eigs_json_parse_root(good[i], &pos);
            check(v && !g_has_error, "finite JSON control", mode, good[i]);
            val_decref(v);
            v = store_json_decode(good[i]);
            check(v && !g_has_error, "finite store control", mode, good[i]);
            val_decref(v);
        }
    }
    eigs_clear_error();
    eigs_close(st);
    printf("decoder-overflow: checks=%d failures=%d\n", checks, failures);
    return failures ? 1 : 0;
}
