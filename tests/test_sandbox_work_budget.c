#include "eigenscript.h"
#include "eigs_embed.h"
#include "vm.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define REQUIRE(c, m) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", (m)); return 1; } assertions++; } while (0)

extern Value *builtin_sandbox_run(Value *arg);

/* Serialize the normal compiler's tiny constant-return output, as in the
 * ordinary strict-shape producer. No hand-written instructions or fault input. */
static Value *ordinary_descriptor(void) {
    const char *source = "return 42\n";
    TokenList tokens = tokenize(source);
    ASTNode *ast = parse(&tokens);
    EigsChunk *chunk = ast ? compile_ast(ast, g_global_env, source) : NULL;
    Value *descriptor = NULL;
    if (chunk && !g_has_error && !g_parse_errors && chunk->code_len > 0 &&
        chunk->code_len <= 64 && !chunk->fn_count && !chunk->local_count &&
        !chunk->param_count && chunk->const_count == 1 &&
        chunk->constants[0]->type == VAL_NUM && VAL_NUM_RAW(chunk->constants[0]) == 42) {
        Value *code = make_list(chunk->code_len);
        Value *constants = make_list(1);
        for (int i = 0; i < chunk->code_len; i++)
            list_append_owned(code, make_num(chunk->code[i]));
        list_append(constants, chunk->constants[0]);
        descriptor = make_list(3);
        list_append_owned(descriptor, make_num(EIGS_BYTECODE_ABI));
        list_append_owned(descriptor, code);
        list_append_owned(descriptor, constants);
    }
    chunk_free(chunk);
    free_ast(ast);
    free_tokenlist(&tokens);
    return descriptor;
}

int main(void) {
    int assertions = 0;

    /* Utilities can reach the helper before any thread state exists. */
    REQUIRE(vm_sandbox_work_charge(UINT64_MAX), "no-current-thread control");

    EigsState *state = eigs_open();
    REQUIRE(state != NULL, "state open");
    REQUIRE(vm_sandbox_work_charge(UINT64_MAX), "inactive control");

    Value *descriptor = ordinary_descriptor();
    REQUIRE(descriptor != NULL, "normal compiler descriptor");
    g_sandbox_work_used = 13;
    g_sandbox_work_max = 77;
    for (int run = 0; run < 2; run++) {
        Value *args = make_list(4);
        list_append(args, descriptor);
        list_append_owned(args, make_num(100));
        list_append_owned(args, make_num(1048576));
        list_append_owned(args, make_num(10000));
        Value *out = builtin_sandbox_run(args);
        Value *ok = out ? dict_get(out, "ok") : NULL;
        Value *result = out ? dict_get(out, "result") : NULL;
        REQUIRE(ok && ok->type == VAL_BOOL && ok->data.boolean == 1 &&
                result && result->type == VAL_NUM && VAL_NUM_RAW(result) == 42,
                "ordinary sandbox result");
        REQUIRE(!g_sandbox_active && g_sandbox_work_used == 13 &&
                g_sandbox_work_max == 77, "sandbox restores caller accounting");
        val_decref(out);
        val_decref(args);
        Value *host = eigs_eval_string("return 7\n");
        REQUIRE(host && host->type == VAL_NUM && VAL_NUM_RAW(host) == 7,
                "host work between sandbox calls");
        val_decref(host);
        REQUIRE(g_sandbox_work_used == 13 && g_sandbox_work_max == 77,
                "ordinary host work remains uncharged");
    }
    val_decref(descriptor);

    g_sandbox_active = 1;
    /* Tiny terminating source programs prove normal VM dispatch charges
     * the same account across separate entries and ordinary function calls.
     * This is compatibility/accounting coverage, not a security workload. */
    g_sandbox_work_max = 10000;
    g_sandbox_work_used = 0;
    Value *ordinary = eigs_eval_string("return 42\n");
    REQUIRE(ordinary && ordinary->type == VAL_NUM && VAL_NUM_RAW(ordinary) == 42,
            "ordinary arithmetic result");
    val_decref(ordinary);
    REQUIRE(g_sandbox_work_used > 0, "ordinary dispatch charges shared account");
    uint64_t previous_work = g_sandbox_work_used;
    ordinary = eigs_eval_string("define work_identity(x) as:\n    return x\nreturn work_identity of 42\n");
    REQUIRE(ordinary && ordinary->type == VAL_NUM && VAL_NUM_RAW(ordinary) == 42,
            "ordinary function result");
    val_decref(ordinary);
    REQUIRE(g_sandbox_work_used > previous_work, "re-entry preserves accounting");

    g_sandbox_work_max = 3;
    g_sandbox_work_used = 0;
    REQUIRE(vm_sandbox_work_charge(2), "small charge");
    REQUIRE(g_sandbox_work_used == 2, "small charge accounting");
    REQUIRE(vm_sandbox_work_charge(1), "exact-limit charge");
    REQUIRE(g_sandbox_work_used == 3, "exact limit accounting");
    REQUIRE(!vm_sandbox_work_charge(1), "one-step-over refusal");
    REQUIRE(g_sandbox_refusal, "sticky refusal");
    REQUIRE(g_sandbox_refusal_kind == EK_SANDBOX, "structured refusal kind");
    REQUIRE(strstr(g_sandbox_refusal_msg, "max_work=3") != NULL,
            "structured refusal message");

    g_has_error = 0;
    eigs_clear_error_value();
    g_sandbox_refusal = 0;
    g_sandbox_error_latched = 0;
    g_sandbox_work_max = UINT64_MAX;
    g_sandbox_work_used = UINT64_MAX - 1;
    REQUIRE(!vm_sandbox_work_charge(2), "overflow-safe refusal");
    REQUIRE(g_sandbox_work_used == UINT64_MAX, "overflow clamps at limit");

    g_has_error = 0;
    eigs_clear_error_value();
    g_sandbox_active = 0;
    eigs_close(state);
    printf("PASS: sandbox work budget (%d assertions)\n", assertions);
    return 0;
}
