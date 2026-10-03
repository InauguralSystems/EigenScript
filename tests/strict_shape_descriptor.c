/* Ordinary shape-control input: serialize only normal compiler output for a
 * constant return. No handwritten bytecode, sandbox execution, or fault input. */
#include <stdio.h>
#include <stdlib.h>
#include "eigs_embed.h"
#include "eigenscript.h"
#include "vm.h"

int main(void) {
    const char *source = "return 42\n";
    EigsState *state = eigs_open();
    if (!state) return 1;
    TokenList tokens = tokenize(source);
    ASTNode *ast = NULL;
    EigsChunk *chunk = NULL;
    Value *descriptor = NULL;
    char *json = NULL;
    int rc = 1;
    if (g_parse_errors || eigs_has_error()) goto done;
    ast = parse(&tokens);
    if (!ast || g_parse_errors || eigs_has_error()) goto done;
    chunk = compile_ast(ast, g_global_env, source);
    if (!chunk || g_parse_errors || eigs_has_error()) goto done;
    if (chunk->code_len <= 0 || chunk->code_len > 64 ||
        chunk->fn_count || chunk->local_count || chunk->param_count ||
        chunk->const_count != 1 || !chunk->constants[0] ||
        chunk->constants[0]->type != VAL_NUM ||
        chunk->constants[0]->data.num != 42) goto done;

    descriptor = make_list(3);
    Value *code = make_list(chunk->code_len);
    Value *constants = make_list(chunk->const_count);
    for (int i = 0; i < chunk->code_len; i++)
        list_append_owned(code, make_num(chunk->code[i]));
    /* list_append takes its own reference before chunk_free releases its copy. */
    list_append(constants, chunk->constants[0]);
    list_append_owned(descriptor, make_num(EIGS_BYTECODE_ABI));
    list_append_owned(descriptor, code);
    list_append_owned(descriptor, constants);
    json = eigs_json_encode(descriptor);
    if (!json || eigs_has_error()) goto done;
    if (puts(json) == EOF) goto done;
    rc = 0;
done:
    if (rc) fputs("FAIL: constant-42 descriptor preparation\n", stderr);
    free(json);
    val_decref(descriptor);
    chunk_free(chunk);
    free_ast(ast);
    free_tokenlist(&tokens);
    eigs_close(state);
    return rc;
}
