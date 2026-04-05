/* Microbenchmark: find the matrix size where packed ternary matmul beats
 * unpacked ternary float matmul.
 *
 * Build:
 *   gcc -O2 -o /tmp/bench_crossover tests/bench_packed_crossover.c -lm
 * Run:
 *   /tmp/bench_crossover
 *
 * Sweeps square matrix sizes from 16 to 2048. For each size:
 *   - Build a random ternary matrix (values in {-1, 0, +1})
 *   - Pack it to 2-bit format
 *   - Time 10 matmuls: x @ W_tern (unpacked) and x @ W_packed (packed)
 *   - Report ns per element, and the packed/unpacked ratio
 *
 * Crossover = the smallest N where packed time < unpacked time.
 * That's the scale where bandwidth savings start beating bit-unpacking overhead.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include <time.h>

#define NE_TILE_SIZE 32

static void ne_matmul_buf_f(
    float* a, int64_t m, int64_t k,
    float* b, int64_t n, float* out
) {
    memset(out, 0, m * n * sizeof(float));
    for (int64_t i0 = 0; i0 < m; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < k; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < m ? i0 + NE_TILE_SIZE : m;
                int64_t j_end = j0 + NE_TILE_SIZE < n ? j0 + NE_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TILE_SIZE < k ? k0 + NE_TILE_SIZE : k;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        float a_ik = a[i * k + kk];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * n + j] += a_ik * b[kk * n + j];
                        }
                    }
                }
            }
        }
    }
}

static void ne_matmul_buf_packed_f(
    float *x, int64_t m, int64_t k,
    uint8_t *w_packed, float alpha, int64_t n, float *out
) {
    memset(out, 0, m * n * sizeof(float));
    int8_t *w_row = calloc(n, 1);
    for (int64_t kk = 0; kk < k; kk++) {
        int64_t row_base = kk * n;
        for (int64_t j = 0; j < n; j++) {
            int64_t idx = row_base + j;
            uint8_t code = (w_packed[idx >> 2] >> ((idx & 3) << 1)) & 3;
            w_row[j] = (code == 1) ? 1 : (code == 3) ? -1 : 0;
        }
        for (int64_t i = 0; i < m; i++) {
            float a_ik = x[i * k + kk];
            if (a_ik == 0.0f) continue;
            float *out_row = out + i * n;
            for (int64_t j = 0; j < n; j++) {
                out_row[j] += a_ik * (float)w_row[j];
            }
        }
    }
    free(w_row);
    if (alpha != 1.0f) {
        int64_t total = m * n;
        for (int64_t i = 0; i < total; i++) out[i] *= alpha;
    }
}

static void pack_ternary(uint8_t *dst, float *src, float alpha, int64_t n) {
    int64_t bytes = (n + 3) / 4;
    memset(dst, 0, bytes);
    float threshold = alpha * 0.5f;
    for (int64_t i = 0; i < n; i++) {
        float w = src[i];
        uint8_t code = 0;
        if (w > threshold) code = 1;
        else if (w < -threshold) code = 3;
        dst[i / 4] |= code << ((i % 4) * 2);
    }
}

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int main(void) {
    srand(42);
    int sizes[] = {16, 32, 64, 128, 256, 512, 1024, 2048};
    int n_sizes = sizeof(sizes) / sizeof(sizes[0]);
    int n_iters = 10;
    float alpha = 0.3f;

    printf("Size   Unpacked(ms)  Packed(ms)   Ratio    Weight_KB  Fits_L1\n");
    printf("----   ------------  -----------  ------   ---------  -------\n");

    for (int si = 0; si < n_sizes; si++) {
        int N = sizes[si];
        /* Square matmul: m=k=n=N, x is [N x N], W is [N x N] */

        float *x = calloc(N * N, sizeof(float));
        float *w_tern = calloc(N * N, sizeof(float));
        uint8_t *w_packed = calloc((N * N + 3) / 4, 1);
        float *out1 = calloc(N * N, sizeof(float));
        float *out2 = calloc(N * N, sizeof(float));

        /* Random x and ternary W */
        for (int i = 0; i < N * N; i++) {
            x[i] = ((float)rand() / RAND_MAX) * 2.0f - 1.0f;
            int r = rand() % 3;
            w_tern[i] = (r == 0) ? alpha : (r == 1) ? 0.0f : -alpha;
        }
        pack_ternary(w_packed, w_tern, alpha, N * N);

        /* Warmup */
        ne_matmul_buf_f(x, N, N, w_tern, N, out1);
        ne_matmul_buf_packed_f(x, N, N, w_packed, alpha, N, out2);

        /* Time unpacked */
        double t0 = now_sec();
        for (int i = 0; i < n_iters; i++) {
            ne_matmul_buf_f(x, N, N, w_tern, N, out1);
        }
        double t_unpacked = (now_sec() - t0) / n_iters * 1000.0;

        /* Time packed */
        t0 = now_sec();
        for (int i = 0; i < n_iters; i++) {
            ne_matmul_buf_packed_f(x, N, N, w_packed, alpha, N, out2);
        }
        double t_packed = (now_sec() - t0) / n_iters * 1000.0;

        double ratio = t_packed / t_unpacked;
        double weight_kb = (double)(N * N * sizeof(float)) / 1024.0;
        const char *fits = weight_kb < 32.0 ? "L1"
                         : weight_kb < 256.0 ? "L2"
                         : weight_kb < 8192.0 ? "L3" : "DRAM";

        printf("%4d   %12.3f  %11.3f  %5.2fx   %9.1f  %s\n",
               N, t_unpacked, t_packed, ratio, weight_kb, fits);

        free(x); free(w_tern); free(w_packed); free(out1); free(out2);
    }

    return 0;
}
