/* R2.5 discriminating companion to base-green N6/T1 MAP invariants.
 * The public rows contain no N returns. Exercise the actual host writer,
 * strict replay reader and shared step/DAP numeric parser. Raw buffer cells
 * are valid N12 data, not induced faults: their signed bits must round-trip. */
#include "eigenscript.h"
#include "eigs_embed.h"
#include "trace.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static char journal[16384];
static size_t used;
static int overflow, checks, failures;
static void check(int ok, const char *name) {
    checks++;
    if (!ok) { failures++; printf("FAIL: %s\n", name); }
}
static void sink(const char *s, size_t n, void *ctx) {
    (void)ctx;
    if (n >= sizeof journal - used) { overflow = 1; return; }
    memcpy(journal + used, s, n); used += n; journal[used] = 0;
}
static uint64_t bits(double d) {
    uint64_t u; memcpy(&u, &d, sizeof u); return u;
}
static double from_bits(uint64_t u) {
    double d; memcpy(&d, &u, sizeof d); return d;
}
static int same_value(Value *a, Value *b) {
    if (!a || !b || a->type != b->type) return 0;
    if (val_is_number(a)) {
        EigsNum x, y;
        if (!eigs_number_read(a, &x, "tape fixture") ||
            !eigs_number_read(b, &y, "tape fixture")) return 0;
        return x.is_int ? x.value.i64 == y.value.i64 : bits(x.value.f64) == bits(y.value.f64);
    }
    if (a->type == VAL_BOOL) return a->data.boolean == b->data.boolean;
    if (a->type == VAL_NULL) return 1;
    if (a->type == VAL_STR) return val_str_len(a) == val_str_len(b) &&
        !memcmp(a->data.str, b->data.str, val_str_len(a));
    if (a->type == VAL_BUFFER) return a->data.buffer.count == b->data.buffer.count &&
        !memcmp(a->data.buffer.data, b->data.buffer.data,
                (size_t)a->data.buffer.count * sizeof(double));
    if (a->type == VAL_LIST) {
        if (a->data.list.count != b->data.list.count) return 0;
        for (int i = 0; i < a->data.list.count; i++) {
            Value *x = eigs_value_list_get(a, i), *y = eigs_value_list_get(b, i);
            int equal = same_value(x, y);
            eigs_value_release(x); eigs_value_release(y);
            if (!equal) return 0;
        }
        return 1;
    }
    if (a->type == VAL_DICT) {
        if (a->data.dict.count != b->data.dict.count) return 0;
        DICT_FOR_EACH(a, i) {
            Value *x = eigs_value_dict_get(a, a->data.dict.keys[i]);
            Value *y = eigs_value_dict_get(b, a->data.dict.keys[i]);
            int equal = same_value(x, y);
            eigs_value_release(x); eigs_value_release(y);
            if (!equal) return 0;
        }
        return 1;
    }
    return 0;
}

/* Malformed ordinary values must exit 3, never fall back to a live source.
 * The same pipe also proves the actual diagnostic retains the rejected token. */
static int child_verdict(const char *name, const char *token, int wanted_rc,
                         const char *diagnostic) {
    char tape[1024];
    int n = snprintf(tape, sizeof tape, "V %d %s\nB 0 1 1 0 root -\nN 0 %s=%s\n",
                     TRACE_FORMAT_VERSION, EIGENSCRIPT_VERSION, name, token);
    if (n < 0 || (size_t)n >= sizeof tape) return 0;
    int fds[2];
    if (pipe(fds)) return 0;
    fflush(stdout); fflush(stderr);
    pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); return 0; }
    if (!pid) {
        if (dup2(fds[1], STDERR_FILENO) < 0) _exit(5);
        close(fds[0]); close(fds[1]);
        if (!eigs_set_replay_tape(tape, (size_t)n, 1)) _exit(4);
        EigsValue *v = NULL;
        int served = eigs_replay_take(name, &v);
        eigs_value_release(v);
        _exit(served ? 0 : 6);
    }
    close(fds[1]);
    char error[2048]; size_t at = 0; ssize_t got;
    while ((got = read(fds[0], error + at, sizeof error - 1 - at)) > 0) {
        at += (size_t)got;
        if (at == sizeof error - 1) break;
    }
    error[at] = 0; close(fds[0]);
    int status;
    if (waitpid(pid, &status, 0) != pid) return 0;
    return WIFEXITED(status) && WEXITSTATUS(status) == wanted_rc &&
           (!diagnostic || (strstr(error, diagnostic) && strstr(error, token)));
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) return 2;
    unsigned kinds = EIGS_KIND(EIGS_TYPE_NUM) | EIGS_KIND(EIGS_TYPE_LIST) |
                     EIGS_KIND(EIGS_TYPE_DICT) | EIGS_KIND(EIGS_TYPE_BUFFER);
    check(eigs_trace_declare_kind("r25_sensor", kinds), "declare host return shapes");
    check(eigs_trace_declare_kind("r25_bool", EIGS_KIND(EIGS_TYPE_BOOL)), "declare kind-refusal host");
    const uint64_t scalars[] = {
        UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000),
        UINT64_C(0x7ff8000000000000), UINT64_C(0x8000000000000000),
        UINT64_C(0x0000000000000001), UINT64_C(0x3ff8000000000000)
    };
    const uint64_t cells[] = {
        UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000),
        UINT64_C(0x7ff8000000000000), UINT64_C(0x7ff0000000000001),
        UINT64_C(0x7fffffffffffffff), UINT64_C(0xfff0000000000001),
        UINT64_C(0xfff8000000000000), UINT64_C(0xfff9000000000001),
        UINT64_C(0xfffa000000000005), UINT64_C(0xfffb000000001000),
        UINT64_C(0xffff000000000000), UINT64_C(0x8000000000000000),
        UINT64_C(0x0000000000000001), UINT64_C(0x3ff8000000000000)
    };
    enum { NSCALARS = sizeof scalars / sizeof scalars[0], NVALUES = NSCALARS + 4 };
    Value *values[NVALUES];
    Value *list = eigs_value_new_list(NSCALARS + 4);
    Value *dict = eigs_value_new_dict(NSCALARS);
    for (int i = 0; i < NSCALARS; i++) {
        values[i] = eigs_value_new_num(from_bits(scalars[i]));
        eigs_value_list_append(list, values[i]);
        char key[24]; snprintf(key, sizeof key, "n%d", i);
        eigs_value_dict_set(dict, key, values[i]);
    }
    Value *controls[] = {eigs_value_new_int(INT64_MAX), eigs_value_new_bool(1),
                        eigs_value_new_null(), eigs_value_new_string("nan is text")};
    for (size_t i = 0; i < sizeof controls / sizeof controls[0]; i++) {
        eigs_value_list_append(list, controls[i]); eigs_value_release(controls[i]);
    }
    Value *buffer = eigs_value_new_buffer((int)(sizeof cells / sizeof cells[0]));
    memcpy(buffer->data.buffer.data, cells, sizeof cells);
    Value *nested = eigs_value_new_list(3);
    eigs_value_list_append(nested, list);
    eigs_value_list_append(nested, dict);
    eigs_value_list_append(nested, buffer);
    values[NSCALARS] = list; values[NSCALARS + 1] = dict;
    values[NSCALARS + 2] = buffer; values[NSCALARS + 3] = nested;

    char first[sizeof journal]; size_t first_used = 0;
    for (int pass = 0; pass < 2; pass++) {
        used = 0; journal[0] = 0;
        eigs_set_trace_sink(sink, NULL);
        for (int i = 0; i < NVALUES; i++) eigs_trace_record_nondet("r25_sensor", values[i]);
        eigs_set_trace_sink(NULL, NULL);
        check(!overflow, "recording fits fixture sink");
        if (!pass) { memcpy(first, journal, used); first_used = used; }
        else check(used == first_used && !memcmp(first, journal, used), "two recordings byte-identical");
    }
    check(strstr(journal, " r25_sensor=inf\n") && strstr(journal, " r25_sensor=-inf\n") &&
          strstr(journal, " r25_sensor=nan\n"), "canonical scalar IEEE tokens");
    check(strstr(journal, "bits(9218868437227405313)") && strstr(journal, "bits(-1"),
          "raw buffer NaN payload tokens");
    check(eigs_set_replay_tape(journal, used, 1), "strict current-format journal installs");
    for (int i = 0; i < NVALUES; i++) {
        EigsValue *v = NULL;
        int served = eigs_replay_take("r25_sensor", &v);
        check(served && !eigs_has_error() && same_value(values[i], v), "N shape and every stored bit replay exactly");
        eigs_value_release(v);
    }
    check(eigs_set_replay_tape(NULL, 0, 0), "replay source releases");
    for (int i = 0; i < NVALUES; i++) eigs_value_release(values[i]);

    const char *invalid[] = {
        "Infinity", "-Infinity", "+inf", "INF", "NAN", "nan(1)", "-nan", "infjunk",
        "1e400", "-1e400", "0x1p0", "+1.0", "b[Infinity]", "b[1e400]",
        "bits(9218868437227405313)", "b[bits(9221120237041090560)]", "b[bits(0)]",
        "b[bits(-9223372036854775809)]", "b[bits(9218868437227405313)x]"
    };
    for (size_t i = 0; i < sizeof invalid / sizeof invalid[0]; i++)
        check(child_verdict("r25_sensor", invalid[i], 3, "malformed"), "malformed nonfinite token refuses with token diagnostic");
    check(child_verdict("r25_sensor", "inf", 0, NULL), "unfaulted positive child control");
    check(child_verdict("r25_bool", "nan", 3, "returns a bool"), "kind mismatch names nan token");
#if TRACE_FORMAT_VERSION >= 10
    const char *tokens[] = {"inf", "-inf", "nan", "-0.0", "5e-324", "1.5"};
    for (int i = 0; i < NSCALARS; i++) {
        const char *p = tokens[i]; double d = 0.0;
        check(trace_parse_float_token(&p, &d) && !*p && bits(d) == scalars[i], "step/DAP float parser retains canonical IEEE bits");
    }
#endif
    /* RULING R25-1: the grammar accepts IEEE words, but these live
     * consumers cannot return non-finite numbers. Derived by reviewing the
     * core N-kind table: 14 scalar domains and 6 numeric container domains.
     * The three reader size arms retain their own exact-int diagnostics. */
    static const struct { const char *name, *prefix, *suffix; } finite[] = {
        {"random", "", ""}, {"random_int", "", ""},
        {"monotonic_ns", "", ""}, {"monotonic_ms", "", ""},
        {"clock_unix", "", ""}, {"gfx_ticks", "", ""},
        {"audio_capture_open", "", ""}, {"audio_stream_queued", "", ""},
        {"net_listen", "", ""}, {"net_accept", "", ""},
        {"net_dial", "", ""}, {"net_port", "", ""},
        {"net_send", "", ""}, {"write_bytes", "", ""},
        {"read_bytes", "[", "]"}, {"read_bytes_buf", "b[", "]"},
        {"net_recv", "b[", "]"}, {"gfx_read", "[", "]"},
        {"audio_capture_read", "b[", "]"}, {"audio_noise", "[", "]"}
    };
    const char *nonfinite[] = {"nan", "inf", "-inf"};
    for (size_t i = 0; i < sizeof finite / sizeof finite[0]; i++) {
        char token[128], diagnostic[160], label[192];
        snprintf(diagnostic, sizeof diagnostic,
                 "trace: %s: non-finite replay value", finite[i].name);
        for (size_t j = 0; j < sizeof nonfinite / sizeof nonfinite[0]; j++) {
            snprintf(token, sizeof token, "%s%s%s", finite[i].prefix, nonfinite[j], finite[i].suffix);
            snprintf(label, sizeof label, "R25-1 %s refuses %s by name", finite[i].name, token);
            check(child_verdict(finite[i].name, token, 3, diagnostic), label);
        }
        snprintf(token, sizeof token, "%s0%s", finite[i].prefix, finite[i].suffix);
        snprintf(label, sizeof label, "R25-1 %s finite control", finite[i].name);
        check(child_verdict(finite[i].name, token, 0, NULL), label);
    }
    check(child_verdict("random_normal", "[inf,-inf]", 0, NULL),
          "R25-1 normal samples may overflow finite scale to infinity");
    check(child_verdict("random_normal", "[nan]", 3, "trace: random_normal: non-finite replay value"),
          "R25-1 normal samples cannot produce NaN from finite scale");
    check(child_verdict("random_normal", "[[nan]]", 3, "trace: random_normal: non-finite replay value"),
          "R25-1 matrix normal samples cannot produce NaN from finite scale");
    check(child_verdict("net_recv", "b[bits(-1)]", 3, "trace: net_recv: non-finite replay value"),
          "R25-1 raw buffer NaN bits cannot bypass a byte domain");
    char old[128];
    int old_n = snprintf(old, sizeof old, "V 9 %s\n", EIGENSCRIPT_VERSION);
    check(old_n > 0 && (size_t)old_n < sizeof old && !eigs_set_replay_tape(old, (size_t)old_n, 1),
          "old v9 tape refused before parsing");
    check(!eigs_has_error(), "encoding and decoding leave no arithmetic error");
    eigs_close(st);
    printf("nonfinite-tape: values=%d raw_buffer_cells=%zu malformed=%zu recordings=2 checks=%d failures=%d\n",
           NVALUES, sizeof cells / sizeof cells[0], sizeof invalid / sizeof invalid[0], checks, failures);
    return failures ? 1 : 0;
}
