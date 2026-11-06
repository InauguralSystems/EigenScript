/* R1.7 N6: Python repr oracle pins for the shared float text writer.
 * --bits reads binary64 words from stdin for an external Python oracle. */
#include "eigenscript_all.c"

typedef struct { uint64_t bits; const char *text; } NumTextCase;
static const NumTextCase num_text_cases[] = {
    {UINT64_C(0x0000000000000000), "0.0"},
    {UINT64_C(0x4008000000000000), "3.0"},
    {UINT64_C(0x408f400000000000), "1000.0"},
    {UINT64_C(0x3fd3333333333334), "0.30000000000000004"},
    {UINT64_C(0x430c6bf526340000), "1000000000000000.0"},
    {UINT64_C(0x4341c37937e08000), "1e+16"},
    {UINT64_C(0x3ee4f8b588e368f1), "1e-05"},
    {UINT64_C(0x3f1a36e2eb1c432d), "0.0001"},
    {UINT64_C(0x44b52d02c7e14af6), "1e+23"},
    {UINT64_C(0x3f1a36e2eb1c432c), "9.999999999999999e-05"},
    {UINT64_C(0x4341c37937e07fff), "9999999999999998.0"},
    {UINT64_C(0x4341c37937e08001), "1.0000000000000002e+16"},
    /* Exact decimal halfway values choose an even last digit. */
    {UINT64_C(0x430c6bf526340002), "1000000000000000.2"},
    {UINT64_C(0x430c6bf526340006), "1000000000000000.8"},
    {UINT64_C(0x42d6bcc41e900008), "100000000000000.12"},
    {UINT64_C(0x42d6bcc41e900018), "100000000000000.38"},
    /* The nearest rounded decimal misses the shorter round-trip interval. */
    {UINT64_C(0x3e70000000000000), "5.960464477539063e-08"},
    {UINT64_C(0x3d30000000000000), "5.684341886080802e-14"},
    {UINT64_C(0x4580000000000000), "6.189700196426902e+26"},
    {UINT64_C(0x5120000000000000), "6.070840288205404e+82"},
    {UINT64_C(0x7fefffffffffffff), "1.7976931348623157e+308"},
    {UINT64_C(0x0010000000000000), "2.2250738585072014e-308"},
    {UINT64_C(0x000fffffffffffff), "2.225073858507201e-308"},
    {UINT64_C(0x0000000000000001), "5e-324"},
    {UINT64_C(0x0000000000000002), "1e-323"}
};
static int num_text_checks, num_text_failures;

static void num_text_check(int ok, const char *label, uint64_t bits, size_t cap) {
    num_text_checks++;
    if (!ok) {
        num_text_failures++;
        printf("phase2-num-text-test: FAIL %s bits=%016llx cap=%zu\n",
               label, (unsigned long long)bits, cap);
    }
}

static void num_text_test(uint64_t bits, const char *want, int finite) {
    double value;
    memcpy(&value, &bits, sizeof value);
    char got[32];
    eigs_num_text(got, sizeof got, value);
    num_text_check(strcmp(got, want) == 0, "Python repr", bits, sizeof got);
    if (finite) {
        double parsed = strtod(got, NULL);
        uint64_t parsed_bits;
        memcpy(&parsed_bits, &parsed, sizeof parsed_bits);
        num_text_check(parsed_bits == bits, "bit-exact round trip", bits, sizeof got);
    }
    size_t len = strlen(want);
    for (size_t cap = 0; cap <= len + 2; cap++) {
        unsigned char bounded[40];
        memset(bounded, 0xa5, sizeof bounded);
        eigs_num_text((char *)bounded + 1, cap, value);
        size_t copied = cap == 0 ? 0 : len < cap ? len : cap - 1;
        int ok = bounded[0] == 0xa5 &&
                 memcmp(bounded + 1, want, copied) == 0;
        if (cap > 0) ok = ok && bounded[copied + 1] == 0;
        size_t untouched = cap == 0 ? 1 : copied + 2;
        for (size_t i = untouched; i < sizeof bounded; i++)
            if (bounded[i] != 0xa5) ok = 0;
        num_text_check(ok, "bounded output", bits, cap);
    }
}

static int num_text_bits(void) {
    char line[32];
    size_t count = 0;
    while (fgets(line, sizeof line, stdin)) {
        size_t len = strlen(line);
        if (len == 17 && line[16] == '\n') len--;
        if (len != 16) return 2;
        uint64_t bits = 0;
        for (size_t i = 0; i < len; i++) {
            int digit = line[i] >= '0' && line[i] <= '9' ? line[i] - '0' :
                        line[i] >= 'a' && line[i] <= 'f' ? line[i] - 'a' + 10 :
                        line[i] >= 'A' && line[i] <= 'F' ? line[i] - 'A' + 10 : -1;
            if (digit < 0) return 2;
            bits = (bits << 4) | (unsigned)digit;
        }
        double value;
        char text[32];
        memcpy(&value, &bits, sizeof value);
        eigs_num_text(text, sizeof text, value);
        puts(text);
        count++;
    }
    return ferror(stdin) || count == 0 ? 2 : 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--bits") == 0) return num_text_bits();
    if (argc != 1) return 2;
    for (size_t i = 0; i < sizeof num_text_cases / sizeof num_text_cases[0]; i++) {
        const NumTextCase *c = &num_text_cases[i];
        num_text_test(c->bits, c->text, 1);
        char negative[32];
        snprintf(negative, sizeof negative, "-%s", c->text);
        num_text_test(c->bits | UINT64_C(0x8000000000000000), negative, 1);
    }
    num_text_test(UINT64_C(0x7ff0000000000000), "inf", 0);
    num_text_test(UINT64_C(0xfff0000000000000), "-inf", 0);
    num_text_test(UINT64_C(0x7ff8000000000000), "nan", 0);
    num_text_test(UINT64_C(0xfff8000000000000), "nan", 0);
    /* A zero capacity also permits a null destination. */
    eigs_num_text(NULL, 0, 1.25);
    printf("phase2-num-text-test: %s cases=%zu checks=%d failures=%d\n",
           num_text_failures ? "FAIL" : "PASS",
           2 * (sizeof num_text_cases / sizeof num_text_cases[0]) + 4,
           num_text_checks, num_text_failures);
    return num_text_failures ? 1 : 0;
}
