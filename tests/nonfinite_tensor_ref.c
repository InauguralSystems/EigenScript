/* Independent IEEE/libm reference for #2444 step two (a).
 * Input: name ar ac br bc, followed by the row-major operands.
 * Build with -ffp-contract=off: the matrix products round before the sum.
 * Output: one tab-separated row, each result's signed binary64 bits (NaNs
 * are the word nan), then the flags derived solely from result elements. */
#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { CAPACITY = 16, TILE = 32 };

static int read_operand(double *values, int count) {
    char word[64];
    for (int i = 0; i < count; ++i) {
        if (scanf("%63s", word) != 1) return 0;
        char *end;
        values[i] = strtod(word, &end);
        if (*end != '\0') return 0;
    }
    return 1;
}

int main(void) {
    char name[32];
    int ar, ac, br, bc;
    while (scanf("%31s %d %d %d %d", name, &ar, &ac, &br, &bc) == 5) {
        if (ar < 1 || ac < 1 || ar * ac > CAPACITY || br < 0 || bc < 0 ||
            br * bc > CAPACITY) return 2;
        double a[CAPACITY], b[CAPACITY], out[CAPACITY] = {0};
        if (!read_operand(a, ar * ac) || !read_operand(b, br * bc)) return 2;
        int count = ar * ac;
        if (strcmp(name, "softmax") == 0 || strcmp(name, "log_softmax") == 0) {
            for (int row = 0; row < ar; ++row) {
                int start = row * ac;
                double maximum = a[start];
                for (int j = 1; j < ac; ++j)
                    if (a[start + j] > maximum) maximum = a[start + j];
                double sum = 0.0;
                for (int j = 0; j < ac; ++j) {
                    out[start + j] = exp(a[start + j] - maximum);
                    sum += out[start + j];
                }
                if (strcmp(name, "softmax") == 0) {
                    for (int j = 0; j < ac; ++j) out[start + j] /= sum;
                } else {
                    double log_sum = log(sum);
                    for (int j = 0; j < ac; ++j)
                        out[start + j] = (a[start + j] - maximum) - log_sum;
                }
            }
        } else if (strcmp(name, "relu") == 0 || strcmp(name, "leaky_relu") == 0) {
            for (int i = 0; i < count; ++i) {
                if (strcmp(name, "relu") == 0) out[i] = a[i] < 0.0 ? 0.0 : a[i];
                else out[i] = a[i] < 0.0 ? 0.01 * a[i] : a[i];
            }
        } else {
            int at = strcmp(name, "matmul_at") == 0;
            int bt = strcmp(name, "matmul_bt") == 0;
            if (!at && !bt && strcmp(name, "matmul") != 0) return 2;
            int m = at ? ac : ar, k = at ? ar : ac, n = bt ? br : bc;
            if (k != (bt ? bc : br) || m * n > CAPACITY) return 2;
            count = m * n;
            /* The runtime's i-k-j tiled order, independent operand indexing. */
            for (int i0 = 0; i0 < m; i0 += TILE) {
                for (int j0 = 0; j0 < n; j0 += TILE) {
                    for (int k0 = 0; k0 < k; k0 += TILE) {
                        int ie = i0 + TILE < m ? i0 + TILE : m;
                        int je = j0 + TILE < n ? j0 + TILE : n;
                        int ke = k0 + TILE < k ? k0 + TILE : k;
                        for (int i = i0; i < ie; ++i) {
                            for (int kk = k0; kk < ke; ++kk) {
                                double av = at ? a[kk * ac + i] : a[i * ac + kk];
                                for (int j = j0; j < je; ++j) {
                                    double bv = bt ? b[j * bc + kk] : b[kk * bc + j];
                                    out[i * n + j] += av * bv;
                                }
                            }
                        }
                    }
                }
            }
        }
        int overflow = 0, invalid = 0;
        const char *first = "finite";
        printf("%d", count);
        for (int i = 0; i < count; ++i) {
            printf("\t");
            if (isnan(out[i])) {
                printf("nan");
                invalid = 1;
                if (strcmp(first, "finite") == 0) first = "nan";
            } else {
                int64_t bits;
                memcpy(&bits, &out[i], sizeof(bits));
                printf("%" PRId64, bits);
                if (isinf(out[i])) {
                    overflow = 1;
                    if (strcmp(first, "finite") == 0) first = "infinity";
                }
            }
        }
        printf("\t%d\t%d\t0\t%s\n", overflow, invalid, first);
    }
    return ferror(stdin) ? 1 : 0;
}
