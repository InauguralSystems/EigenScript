/*
 * EigenScript fuzz harness, stdin driver.
 *
 * Feeds ONE input from stdin to the libFuzzer target's own entry points
 * (LLVMFuzzerInitialize and LLVMFuzzerTestOneInput in fuzz/fuzz_eigenscript.c),
 * so the CI fuzz smoke (fuzz/run_fuzz.sh) checks the per-input contract the
 * fuzzer runs: the LeakSanitizer-ignored init, the loop budget, the per-input
 * teardown and the invariant check. This file used to repeat the pipeline with
 * none of those. Its init was not LSan-ignored and it tore nothing down, so
 * under leak detection every input reported the builtin table, while a leak
 * the per-input teardown misses was never examined at all (#1734).
 *
 * Build: make fuzz          (gcc, ASan + UBSan; libFuzzer is not needed)
 * Run:   echo 'x is 1 / 0' | ./fuzz/fuzz_stdin
 * AFL:   afl-fuzz -i fuzz/corpus -o fuzz/findings -- ./fuzz/fuzz_stdin
 */

#include <stdint.h>
#include <stdio.h>

int LLVMFuzzerInitialize(int *argc, char ***argv);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
    /* The target takes at most 64 KiB, so stdin is read up to that. */
    static uint8_t buf[65536];
    size_t total = 0, n;
    while (total < sizeof buf &&
           (n = fread(buf + total, 1, sizeof buf - total, stdin)) > 0)
        total += n;
    LLVMFuzzerInitialize(&argc, &argv);
    LLVMFuzzerTestOneInput(buf, total);
    return 0;
}
