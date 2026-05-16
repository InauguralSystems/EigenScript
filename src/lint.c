/*
 * EigenScript linter — AST-walking static analysis.
 * Reports style warnings and likely bugs.
 */

#include "eigenscript.h"

/* ---- Lint warning storage ---- */

typedef struct {
    int line;
    char level[16];   /* "warning" or "error" */
    char message[256];
} LintWarning;

#define MAX_LINT_WARNINGS 256

typedef struct {
    LintWarning warnings[MAX_LINT_WARNINGS];
    int warning_count;
    /* Variable tracking */
    char *assigns[MAX_VARS];
    int assign_lines[MAX_VARS];
    int assign_count;
    char *refs[MAX_VARS];
    int ref_count;
    /* Parameter tracking for current function */
    char *params[64];
    int param_count;
    /* Known builtins */
    const char **builtins;
    int builtin_count;
} LintContext;

static void lint_warn(LintContext *ctx, int line, const char *fmt, ...) {
    if (ctx->warning_count >= MAX_LINT_WARNINGS) return;
    LintWarning *w = &ctx->warnings[ctx->warning_count++];
    w->line = line;
    memcpy(w->level, "warning", 8);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(w->message, sizeof(w->message), fmt, ap);
    va_end(ap);
}

static void add_assign(LintContext *ctx, const char *name, int line) {
    if (ctx->assign_count >= MAX_VARS) return;
    /* Don't add duplicates */
    for (int i = 0; i < ctx->assign_count; i++) {
        if (strcmp(ctx->assigns[i], name) == 0) return;
    }
    ctx->assigns[ctx->assign_count] = xstrdup(name);
    ctx->assign_lines[ctx->assign_count] = line;
    ctx->assign_count++;
}

static void add_ref(LintContext *ctx, const char *name) {
    if (ctx->ref_count >= MAX_VARS) return;
    /* Don't add duplicates */
    for (int i = 0; i < ctx->ref_count; i++) {
        if (strcmp(ctx->refs[i], name) == 0) return;
    }
    ctx->refs[ctx->ref_count] = xstrdup(name);
    ctx->ref_count++;
}

static int is_ref(LintContext *ctx, const char *name) {
    for (int i = 0; i < ctx->ref_count; i++) {
        if (strcmp(ctx->refs[i], name) == 0) return 1;
    }
    return 0;
}


/* Known builtin names */
static const char *BUILTINS[] = {
    "print", "len", "str", "num", "type", "append", "keys", "values",
    "has_key", "dict_set", "set_at", "remove_at", "range", "abs",
    "floor", "ceil", "round", "sqrt", "pow", "min", "max", "sum",
    "sort", "reverse", "join", "split", "scan_ints", "trim", "upper", "lower",
    "contains", "starts_with", "ends_with", "replace", "index_of",
    "slice", "read_text", "write_text", "append_text", "file_exists",
    "delete_file", "list_dir", "make_dir", "env_get", "env_set",
    "time_now", "sleep", "shell", "json_parse", "json_encode",
    "input", "exit", "assert", "rand", "regex_match", "regex_find",
    "regex_replace", "hash_sha256", "hash_md5", "hash_sha512",
    "base64_encode", "base64_decode", "store_open", "store_close",
    "store_put", "store_get", "store_delete", "store_query",
    "store_count", "store_update", "store_collections", "store_drop",
    "load_file", "error", "copy",
    NULL
};

static int is_builtin_name(const char *name) {
    for (int i = 0; BUILTINS[i]; i++) {
        if (strcmp(BUILTINS[i], name) == 0) return 1;
    }
    return 0;
}

/* ---- AST walkers ---- */

static void collect_refs(ASTNode *node, LintContext *ctx);
static void collect_assigns(ASTNode *node, LintContext *ctx);

/* Collect all identifier references in an AST subtree */
static void collect_refs(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    switch (node->type) {
        case AST_IDENT:
            add_ref(ctx, node->data.ident.name);
            break;
        case AST_BINOP:
            collect_refs(node->data.binop.left, ctx);
            collect_refs(node->data.binop.right, ctx);
            break;
        case AST_UNARY:
            collect_refs(node->data.unary.operand, ctx);
            break;
        case AST_ASSIGN:
            /* The RHS is a reference, the LHS is an assignment */
            collect_refs(node->data.assign.expr, ctx);
            break;
        case AST_RELATION:
            collect_refs(node->data.relation.left, ctx);
            collect_refs(node->data.relation.right, ctx);
            break;
        case AST_IF:
            collect_refs(node->data.cond.cond, ctx);
            for (int i = 0; i < node->data.cond.if_count; i++)
                collect_refs(node->data.cond.if_body[i], ctx);
            for (int i = 0; i < node->data.cond.else_count; i++)
                collect_refs(node->data.cond.else_body[i], ctx);
            break;
        case AST_LOOP:
            collect_refs(node->data.loop.cond, ctx);
            for (int i = 0; i < node->data.loop.body_count; i++)
                collect_refs(node->data.loop.body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < node->data.func.body_count; i++)
                collect_refs(node->data.func.body[i], ctx);
            break;
        case AST_RETURN:
            collect_refs(node->data.ret.expr, ctx);
            break;
        case AST_BLOCK:
            for (int i = 0; i < node->data.block.count; i++)
                collect_refs(node->data.block.stmts[i], ctx);
            break;
        case AST_LIST:
            for (int i = 0; i < node->data.list.count; i++)
                collect_refs(node->data.list.elems[i], ctx);
            break;
        case AST_INDEX:
            collect_refs(node->data.index.target, ctx);
            collect_refs(node->data.index.index, ctx);
            break;
        case AST_LISTCOMP:
            collect_refs(node->data.listcomp.expr, ctx);
            collect_refs(node->data.listcomp.iter, ctx);
            if (node->data.listcomp.filter)
                collect_refs(node->data.listcomp.filter, ctx);
            break;
        case AST_FOR:
            add_ref(ctx, node->data.forloop.var); /* loop var is both assign and ref */
            collect_refs(node->data.forloop.iter, ctx);
            for (int i = 0; i < node->data.forloop.body_count; i++)
                collect_refs(node->data.forloop.body[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                collect_refs(node->data.program.stmts[i], ctx);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                collect_refs(node->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                collect_refs(node->data.trycatch.catch_body[i], ctx);
            break;
        case AST_DICT:
            for (int i = 0; i < node->data.dict.count; i++) {
                collect_refs(node->data.dict.keys[i], ctx);
                collect_refs(node->data.dict.vals[i], ctx);
            }
            break;
        case AST_DOT:
            collect_refs(node->data.dot.target, ctx);
            break;
        case AST_DOT_ASSIGN:
            collect_refs(node->data.dot_assign.target, ctx);
            collect_refs(node->data.dot_assign.expr, ctx);
            break;
        case AST_INDEX_ASSIGN:
            collect_refs(node->data.index_assign.target, ctx);
            collect_refs(node->data.index_assign.index, ctx);
            collect_refs(node->data.index_assign.expr, ctx);
            break;
        case AST_MATCH:
            collect_refs(node->data.match.expr, ctx);
            for (int i = 0; i < node->data.match.case_count; i++) {
                collect_refs(node->data.match.patterns[i], ctx);
                for (int j = 0; j < node->data.match.body_counts[i]; j++)
                    collect_refs(node->data.match.bodies[i][j], ctx);
            }
            break;
        case AST_LAMBDA:
            collect_refs(node->data.lambda.body, ctx);
            break;
        case AST_INTERROGATE:
            collect_refs(node->data.interrogate.expr, ctx);
            break;
        case AST_IMPORT:
            /* import names become available */
            break;
        default:
            break;
    }
}

/* Collect all assignment targets in an AST subtree */
static void collect_assigns(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    switch (node->type) {
        case AST_ASSIGN:
            add_assign(ctx, node->data.assign.name, node->line);
            collect_assigns(node->data.assign.expr, ctx);
            break;
        case AST_FUNC:
            add_assign(ctx, node->data.func.name, node->line);
            break;
        case AST_FOR:
            add_assign(ctx, node->data.forloop.var, node->line);
            for (int i = 0; i < node->data.forloop.body_count; i++)
                collect_assigns(node->data.forloop.body[i], ctx);
            break;
        case AST_IF:
            for (int i = 0; i < node->data.cond.if_count; i++)
                collect_assigns(node->data.cond.if_body[i], ctx);
            for (int i = 0; i < node->data.cond.else_count; i++)
                collect_assigns(node->data.cond.else_body[i], ctx);
            break;
        case AST_LOOP:
            for (int i = 0; i < node->data.loop.body_count; i++)
                collect_assigns(node->data.loop.body[i], ctx);
            break;
        case AST_BLOCK:
            for (int i = 0; i < node->data.block.count; i++)
                collect_assigns(node->data.block.stmts[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                collect_assigns(node->data.program.stmts[i], ctx);
            break;
        case AST_TRY:
            if (node->data.trycatch.err_name)
                add_assign(ctx, node->data.trycatch.err_name, node->line);
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                collect_assigns(node->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                collect_assigns(node->data.trycatch.catch_body[i], ctx);
            break;
        case AST_IMPORT:
            add_assign(ctx, node->data.import.module_name, node->line);
            break;
        default:
            break;
    }
}

/* ---- Check: unreachable code after return ---- */

static void check_unreachable(ASTNode **stmts, int count, LintContext *ctx) {
    for (int i = 0; i < count - 1; i++) {
        if (stmts[i]->type == AST_RETURN) {
            lint_warn(ctx, stmts[i + 1]->line, "unreachable code after return");
            break; /* Only warn once per block */
        }
    }
}

/* ---- Check: empty blocks ---- */

static void check_empty_blocks(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    switch (node->type) {
        case AST_IF:
            if (node->data.cond.if_count == 0)
                lint_warn(ctx, node->line, "empty if block");
            if (node->data.cond.else_count == 0 && node->data.cond.if_count > 0) {
                /* else block is optional, only warn if there IS an else but it's empty.
                 * We can't easily distinguish "no else" from "empty else" at AST level
                 * without extra info. Skip this for now. */
            }
            for (int i = 0; i < node->data.cond.if_count; i++)
                check_empty_blocks(node->data.cond.if_body[i], ctx);
            for (int i = 0; i < node->data.cond.else_count; i++)
                check_empty_blocks(node->data.cond.else_body[i], ctx);
            break;
        case AST_LOOP:
            if (node->data.loop.body_count == 0)
                lint_warn(ctx, node->line, "empty loop block");
            for (int i = 0; i < node->data.loop.body_count; i++)
                check_empty_blocks(node->data.loop.body[i], ctx);
            break;
        case AST_FOR:
            if (node->data.forloop.body_count == 0)
                lint_warn(ctx, node->line, "empty for block");
            for (int i = 0; i < node->data.forloop.body_count; i++)
                check_empty_blocks(node->data.forloop.body[i], ctx);
            break;
        case AST_FUNC:
            if (node->data.func.body_count == 0)
                lint_warn(ctx, node->line, "empty function body '%s'", node->data.func.name);
            for (int i = 0; i < node->data.func.body_count; i++)
                check_empty_blocks(node->data.func.body[i], ctx);
            break;
        case AST_TRY:
            if (node->data.trycatch.try_count == 0)
                lint_warn(ctx, node->line, "empty try block");
            if (node->data.trycatch.catch_count == 0)
                lint_warn(ctx, node->line, "empty catch block");
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                check_empty_blocks(node->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                check_empty_blocks(node->data.trycatch.catch_body[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                check_empty_blocks(node->data.program.stmts[i], ctx);
            break;
        default:
            break;
    }
}

/* ---- Check: duplicate dict keys ---- */

static void check_dup_keys(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    if (node->type == AST_DICT) {
        for (int i = 0; i < node->data.dict.count; i++) {
            ASTNode *ki = node->data.dict.keys[i];
            if (ki->type != AST_STR) continue;
            for (int j = i + 1; j < node->data.dict.count; j++) {
                ASTNode *kj = node->data.dict.keys[j];
                if (kj->type != AST_STR) continue;
                if (strcmp(ki->data.str, kj->data.str) == 0) {
                    lint_warn(ctx, kj->line, "duplicate dict key '%s'", ki->data.str);
                }
            }
        }
    }

    /* Recurse */
    switch (node->type) {
        case AST_BINOP:
            check_dup_keys(node->data.binop.left, ctx);
            check_dup_keys(node->data.binop.right, ctx);
            break;
        case AST_ASSIGN:
            check_dup_keys(node->data.assign.expr, ctx);
            break;
        case AST_IF:
            check_dup_keys(node->data.cond.cond, ctx);
            for (int i = 0; i < node->data.cond.if_count; i++)
                check_dup_keys(node->data.cond.if_body[i], ctx);
            for (int i = 0; i < node->data.cond.else_count; i++)
                check_dup_keys(node->data.cond.else_body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < node->data.func.body_count; i++)
                check_dup_keys(node->data.func.body[i], ctx);
            break;
        case AST_RETURN:
            check_dup_keys(node->data.ret.expr, ctx);
            break;
        case AST_FOR:
            for (int i = 0; i < node->data.forloop.body_count; i++)
                check_dup_keys(node->data.forloop.body[i], ctx);
            break;
        case AST_LOOP:
            for (int i = 0; i < node->data.loop.body_count; i++)
                check_dup_keys(node->data.loop.body[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                check_dup_keys(node->data.program.stmts[i], ctx);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                check_dup_keys(node->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                check_dup_keys(node->data.trycatch.catch_body[i], ctx);
            break;
        case AST_LIST:
            for (int i = 0; i < node->data.list.count; i++)
                check_dup_keys(node->data.list.elems[i], ctx);
            break;
        default:
            break;
    }
}

/* ---- Check: comparison with 'is' in conditions ---- */

static void check_is_in_condition(ASTNode *cond, LintContext *ctx) {
    if (!cond) return;
    /* An AST_ASSIGN inside a condition means 'is' was used for comparison */
    if (cond->type == AST_ASSIGN) {
        lint_warn(ctx, cond->line,
                  "'%s is ...' in condition — did you mean '=='?",
                  cond->data.assign.name);
    }
    /* Check nested binops (and/or) */
    if (cond->type == AST_BINOP) {
        if (strcmp(cond->data.binop.op, "&&") == 0 ||
            strcmp(cond->data.binop.op, "||") == 0) {
            check_is_in_condition(cond->data.binop.left, ctx);
            check_is_in_condition(cond->data.binop.right, ctx);
        }
    }
}

/* ---- Check: builtin shadowing ---- */

static void check_builtin_shadow(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    if (node->type == AST_ASSIGN && is_builtin_name(node->data.assign.name)) {
        lint_warn(ctx, node->line, "'%s' is a builtin — assignment shadows it",
                  node->data.assign.name);
    }
    if (node->type == AST_FUNC && is_builtin_name(node->data.func.name)) {
        lint_warn(ctx, node->line, "'%s' is a builtin — function definition shadows it",
                  node->data.func.name);
    }

    /* Recurse into children */
    switch (node->type) {
        case AST_IF:
            for (int i = 0; i < node->data.cond.if_count; i++)
                check_builtin_shadow(node->data.cond.if_body[i], ctx);
            for (int i = 0; i < node->data.cond.else_count; i++)
                check_builtin_shadow(node->data.cond.else_body[i], ctx);
            break;
        case AST_LOOP:
            for (int i = 0; i < node->data.loop.body_count; i++)
                check_builtin_shadow(node->data.loop.body[i], ctx);
            break;
        case AST_FOR:
            for (int i = 0; i < node->data.forloop.body_count; i++)
                check_builtin_shadow(node->data.forloop.body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < node->data.func.body_count; i++)
                check_builtin_shadow(node->data.func.body[i], ctx);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                check_builtin_shadow(node->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                check_builtin_shadow(node->data.trycatch.catch_body[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                check_builtin_shadow(node->data.program.stmts[i], ctx);
            break;
        default:
            break;
    }
}

/* ---- Check: unreachable code in function bodies ---- */

static void check_func_unreachable(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    if (node->type == AST_FUNC) {
        check_unreachable(node->data.func.body, node->data.func.body_count, ctx);
    }

    switch (node->type) {
        case AST_IF:
            for (int i = 0; i < node->data.cond.if_count; i++)
                check_func_unreachable(node->data.cond.if_body[i], ctx);
            for (int i = 0; i < node->data.cond.else_count; i++)
                check_func_unreachable(node->data.cond.else_body[i], ctx);
            break;
        case AST_LOOP:
            for (int i = 0; i < node->data.loop.body_count; i++)
                check_func_unreachable(node->data.loop.body[i], ctx);
            break;
        case AST_FOR:
            for (int i = 0; i < node->data.forloop.body_count; i++)
                check_func_unreachable(node->data.forloop.body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < node->data.func.body_count; i++)
                check_func_unreachable(node->data.func.body[i], ctx);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                check_func_unreachable(node->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                check_func_unreachable(node->data.trycatch.catch_body[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                check_func_unreachable(node->data.program.stmts[i], ctx);
            break;
        default:
            break;
    }
}

/* ---- Check: 'is' in if conditions ---- */

static void check_is_conditions(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    if (node->type == AST_IF) {
        check_is_in_condition(node->data.cond.cond, ctx);
    }

    switch (node->type) {
        case AST_IF:
            for (int i = 0; i < node->data.cond.if_count; i++)
                check_is_conditions(node->data.cond.if_body[i], ctx);
            for (int i = 0; i < node->data.cond.else_count; i++)
                check_is_conditions(node->data.cond.else_body[i], ctx);
            break;
        case AST_LOOP:
            for (int i = 0; i < node->data.loop.body_count; i++)
                check_is_conditions(node->data.loop.body[i], ctx);
            break;
        case AST_FOR:
            for (int i = 0; i < node->data.forloop.body_count; i++)
                check_is_conditions(node->data.forloop.body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < node->data.func.body_count; i++)
                check_is_conditions(node->data.func.body[i], ctx);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                check_is_conditions(node->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                check_is_conditions(node->data.trycatch.catch_body[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                check_is_conditions(node->data.program.stmts[i], ctx);
            break;
        default:
            break;
    }
}

/* ---- Check: unused function parameters ---- */

static void check_unused_params(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    if (node->type == AST_FUNC) {
        /* For each param, check if it's referenced in the function body */
        for (int p = 0; p < node->data.func.param_count; p++) {
            const char *param = node->data.func.params[p];
            /* Skip _-prefixed params and auto-bound 'n' */
            if (param[0] == '_') continue;
            if (strcmp(param, "n") == 0) continue;

            /* Build a temporary ref context for this function body */
            LintContext body_ctx = {0};
            for (int i = 0; i < node->data.func.body_count; i++)
                collect_refs(node->data.func.body[i], &body_ctx);

            int found = 0;
            for (int r = 0; r < body_ctx.ref_count; r++) {
                if (strcmp(body_ctx.refs[r], param) == 0) { found = 1; break; }
            }
            /* Also check assignments that reference the param on the RHS */
            if (!found) {
                for (int r = 0; r < body_ctx.ref_count; r++) {
                    free(body_ctx.refs[r]);
                }
                for (int r = 0; r < body_ctx.assign_count; r++) {
                    free(body_ctx.assigns[r]);
                }
                lint_warn(ctx, node->line, "unused parameter '%s' in function '%s'",
                          param, node->data.func.name);
                continue;
            }
            for (int r = 0; r < body_ctx.ref_count; r++) free(body_ctx.refs[r]);
            for (int r = 0; r < body_ctx.assign_count; r++) free(body_ctx.assigns[r]);
        }
    }

    /* Recurse */
    switch (node->type) {
        case AST_IF:
            for (int i = 0; i < node->data.cond.if_count; i++)
                check_unused_params(node->data.cond.if_body[i], ctx);
            for (int i = 0; i < node->data.cond.else_count; i++)
                check_unused_params(node->data.cond.else_body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < node->data.func.body_count; i++)
                check_unused_params(node->data.func.body[i], ctx);
            break;
        case AST_FOR:
            for (int i = 0; i < node->data.forloop.body_count; i++)
                check_unused_params(node->data.forloop.body[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                check_unused_params(node->data.program.stmts[i], ctx);
            break;
        default:
            break;
    }
}

/* ---- Main lint entry ---- */

int eigenscript_lint(const char *path) {
    long src_size = 0;
    char *source = read_file_util(path, &src_size);
    if (!source) {
        fprintf(stderr, "Error: cannot read file '%s'\n", path);
        return 1;
    }

    g_parse_errors = 0;
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    if (g_parse_errors > 0) {
        fprintf(stderr, "%s: %d parse error(s) — cannot lint\n", path, g_parse_errors);
        free_tokenlist(&tl);
        free(source);
        return 1;
    }

    LintContext ctx = {0};

    /* Run all checks */
    check_empty_blocks(ast, &ctx);
    check_dup_keys(ast, &ctx);
    check_builtin_shadow(ast, &ctx);
    check_func_unreachable(ast, &ctx);
    check_is_conditions(ast, &ctx);
    check_unused_params(ast, &ctx);

    /* Collect assigns and refs for unused-variable check */
    collect_assigns(ast, &ctx);
    collect_refs(ast, &ctx);

    /* Check unused variables (top-level only — conservative) */
    /* Build set of function-defined names (these are intentional exports) */
    int func_name_count = 0;
    char *func_names[MAX_VARS];
    if (ast && ast->type == AST_PROGRAM) {
        for (int i = 0; i < ast->data.program.count; i++) {
            ASTNode *s = ast->data.program.stmts[i];
            if (s && s->type == AST_FUNC)
                func_names[func_name_count++] = s->data.func.name;
        }
    }
    for (int i = 0; i < ctx.assign_count; i++) {
        const char *name = ctx.assigns[i];
        /* Skip _ prefixed */
        if (name[0] == '_') continue;
        /* Skip builtins (already warned about shadow) */
        if (is_builtin_name(name)) continue;
        /* Skip function definitions — always intentional */
        int is_func = 0;
        for (int j = 0; j < func_name_count; j++) {
            if (strcmp(func_names[j], name) == 0) { is_func = 1; break; }
        }
        if (is_func) continue;
        if (!is_ref(&ctx, name)) {
            lint_warn(&ctx, ctx.assign_lines[i], "unused variable '%s'", name);
        }
    }

    /* Sort warnings by line number */
    for (int i = 0; i < ctx.warning_count - 1; i++) {
        for (int j = i + 1; j < ctx.warning_count; j++) {
            if (ctx.warnings[j].line < ctx.warnings[i].line) {
                LintWarning tmp = ctx.warnings[i];
                ctx.warnings[i] = ctx.warnings[j];
                ctx.warnings[j] = tmp;
            }
        }
    }

    /* Print warnings */
    for (int i = 0; i < ctx.warning_count; i++) {
        fprintf(stderr, "%s:%d: %s: %s\n", path,
                ctx.warnings[i].line, ctx.warnings[i].level,
                ctx.warnings[i].message);
    }

    if (ctx.warning_count == 0) {
        fprintf(stderr, "%s: no issues found\n", path);
    }

    /* Cleanup */
    for (int i = 0; i < ctx.assign_count; i++) free(ctx.assigns[i]);
    for (int i = 0; i < ctx.ref_count; i++) free(ctx.refs[i]);

    free_ast(ast);
    free_tokenlist(&tl);
    free(source);

    return ctx.warning_count > 0 ? 1 : 0;
}
