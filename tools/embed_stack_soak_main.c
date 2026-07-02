/* embed_stack_soak_main.c — hosted twin of the EigenOS boot-to-REPL session,
 * run by tools/embed_stack_soak.sh under a 64 KiB stack rlimit (the EigenOS
 * boot-stack size).
 *
 * One eigs_open, then a long sequence of eigs_eval_string calls on the SAME
 * state — the accumulation pattern the test suite never exercises (every
 * suite test is one script per process through main.c). This is the pattern
 * that exposed the compile_node_inner stack-frame bug: the compiler carried
 * ~12.7 KiB of C stack PER AST LEVEL (a by-value Compiler with an inline
 * Local[MAX_LOCALS] array in every nested-function frame), so a 5-deep AST
 * overflowed an embedded 64 KiB stack. Hosted, the guard page makes that an
 * instant SIGSEGV — which is exactly what this gate watches for. On bare
 * metal there is no guard page: the overflow silently trampled the .bss
 * neighbors below the stack and detonated evals later as a layout-dependent
 * wild VM dispatch (the EigenOS mn-repl "#UD heisenbug").
 */
#include <stdio.h>
#include <string.h>
#include "../src/eigs_embed.h"

static int step_no = 0;
static int errors  = 0;

static void eval_line(const char *src) {
    step_no++;
    EigsValue *v = eigs_eval_string(src);
    if (eigs_has_error()) {
        fprintf(stderr, "step %d unexpected error: %s\n",
                step_no, eigs_last_error_message());
        eigs_clear_error();
        errors++;
    }
    if (v) eigs_value_release(v);
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) { fprintf(stderr, "eigs_open failed\n"); return 2; }

    /* --- the EigenOS M5 demo pair --- */
    eval_line("6 * 7");
    eval_line("n is 10\n"
              "sum is 0\n"
              "for i in range of n:\n"
              "    sum is sum + i\n"
              "print of (\"sum 0..9 = \" + (str of sum))\n");

    /* --- the documented bare-metal tripwires: third eval, define,
     *     observer loop, nested define, lambda --- */
    eval_line("1 + 1");
    eval_line("define square(k) as:\n    return k * k\n");
    eval_line("square of 12");
    eval_line("define outer(a) as:\n"
              "    define inner(b) as:\n"
              "        return b * 2\n"
              "    return inner of a\n"
              "outer of 21");
    eval_line("dbl is (x) => x * 2\ndbl of 4");
    eval_line("e is 5\n"
              "loop while not converged:\n"
              "    e is e * 0.5\n"
              "e");
    eval_line("xs is [1, 2, 3]\n"
              "append of [xs, 4]\n"
              "len of xs");
    eval_line("s is \"hello\"\n"
              "t is s + \" world\"\n"
              "len of t");

    /* --- REPL-style accumulation: many small line evals on one state --- */
    for (int i = 0; i < 40; i++) {
        char buf[256];
        snprintf(buf, sizeof buf, "v%d is %d * 3", i, i);
        eval_line(buf);
        snprintf(buf, sizeof buf, "v%d + 1", i);
        eval_line(buf);
        if (i % 5 == 0) {
            snprintf(buf, sizeof buf,
                     "define f%d(k) as:\n    return k + %d\nf%d of %d",
                     i, i, i, i);
            eval_line(buf);
        }
        if (i % 7 == 0) {
            snprintf(buf, sizeof buf,
                     "w%d is 100.0\n"
                     "loop while not converged:\n"
                     "    w%d is (w%d + 2.0 / w%d) / 2.0\n"
                     "w%d", i, i, i, i, i);
            eval_line(buf);
        }
    }

    eigs_close(st);
    if (errors) {
        fprintf(stderr, "embed_stack_soak: %d unexpected error(s)\n", errors);
        return 1;
    }
    printf("embed_stack_soak: OK (%d steps)\n", step_no);
    return 0;
}
