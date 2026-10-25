/* R1.7-D4: exercise the constant pool itself, not NUM_ZERO/NEG. */
#include "eigenscript_all.c"
static int checks, failures;
static void check(int ok, const char *label) {
    ++checks;
    if (!ok) { ++failures; printf("phase2-const-dedup-test: FAIL %s\n", label); }
}
int main(void) {
    EigsState *st = eigs_open();
    if (!st) return 1;
    EigsChunk *c = chunk_new("signed-zero");
    double pos = 0.0, neg = -0.0;
    Value *p = make_float(pos), *n = make_float(neg);
    int pi = chunk_add_constant(c, p), ni = chunk_add_constant(c, n);
    check(pi != ni, "signed zeros have distinct indices");
    check(c->const_count == 2, "two bit patterns stored");
    check(c->constants[pi]->type == VAL_FLOAT, "positive kind");
    check(c->constants[ni]->type == VAL_FLOAT, "negative kind");
    double ps = VAL_F64_RAW(c->constants[pi]), ns = VAL_F64_RAW(c->constants[ni]);
    check(memcmp(&ps, &pos, sizeof pos) == 0, "positive bits exact");
    check(memcmp(&ns, &neg, sizeof neg) == 0, "negative bits exact");
    check(chunk_add_constant(c, p) == pi, "same positive bits deduplicate");
    check(chunk_add_constant(c, n) == ni, "same negative bits deduplicate");
    val_decref(p); val_decref(n); chunk_free(c);
    eigs_close(st);
    printf("phase2-const-dedup-test: %s checks=%d failures=%d\n", failures ? "FAIL" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
