/*
 * EigenScript linter — AST-walking static analysis.
 * Reports style warnings and likely bugs.
 */

#include "eigenscript.h"
#include "ext_names.h"

/* ---- Lint warning storage ---- */

typedef struct {
    int line;
    int col;          /* 0-based column of the offending token (0 = unknown) */
    int len;          /* token length (0 = unknown -> whole-line LSP range) */
    char level[16];   /* "warning" or "error" */
    char code[8];     /* stable diagnostic code, e.g. "W001" */
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

/* Escape a string for embedding in a JSON string literal (into a caller
 * buffer). Handles the quote/backslash/control set; lint messages are ASCII. */
static void json_escape(const char *s, char *out, size_t outsz) {
    size_t o = 0;
    for (size_t i = 0; s[i] && o + 2 < outsz; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') { out[o++] = '\\'; out[o++] = (char)c; }
        else if (c == '\n') { out[o++] = '\\'; out[o++] = 'n'; }
        else if (c == '\t') { out[o++] = '\\'; out[o++] = 't'; }
        else if (c >= 0x20) { out[o++] = (char)c; }
        /* other control chars are dropped */
    }
    out[o] = '\0';
}

static void lint_vdiag(LintContext *ctx, int line, int col, int len,
                       const char *level,
                       const char *code, const char *fmt, va_list ap) {
    if (ctx->warning_count >= MAX_LINT_WARNINGS) return;
    LintWarning *w = &ctx->warnings[ctx->warning_count++];
    w->line = line;
    w->col  = col;
    w->len  = len;
    snprintf(w->level, sizeof(w->level), "%s", level);
    snprintf(w->code, sizeof(w->code), "%s", code);
    vsnprintf(w->message, sizeof(w->message), fmt, ap);
}

static void lint_warn(LintContext *ctx, int line, const char *code,
                      const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    lint_vdiag(ctx, line, 0, 0, "warning", code, fmt, ap);
    va_end(ap);
}

/* Error-severity diagnostic (fails --lint even at --lint-level error)
 * carrying a token position (#407 residual): the LSP publishes
 * col..col+len as the squiggle range; pass col=0,len=0 when unknown. */
static void lint_error_at(LintContext *ctx, int line, int col, int len,
                          const char *code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    lint_vdiag(ctx, line, col, len, "error", code, fmt, ap);
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


/* Known builtin names — the registry itself, never a hand list (#459: the
 * old hand-copied BUILTINS[] array drifted ~120 names behind the binary, so
 * `define dispatch` shadowed a live builtin with no W012/W013). Same
 * derivation as E003's binding base: register_builtins() on a scratch Env,
 * plus the extension names (ext_names.h — the surface of the LANGUAGE, not
 * of this binary's build flags) and the compiler-resolved special forms no
 * registrar binds. Built once per process; still-reachable by design. */
#if !EIGENSCRIPT_FREESTANDING
static Env *g_builtin_name_env = NULL;

/* Freed at the end of every eigenscript_lint run: LeakSanitizer cannot trace
 * through the env's tagged EigsSlot pointers, so a kept-for-the-process env
 * reads as a direct leak and fails the detect_leaks=1 gate. */
static void builtin_name_env_free(void) {
    if (g_builtin_name_env) {
        env_decref(g_builtin_name_env);
        g_builtin_name_env = NULL;
    }
}

static int is_builtin_name(const char *name) {
    if (!g_builtin_name_env) {
        Env *e = env_new(NULL);
        register_builtins(e);
        register_store_builtins(e);
#define X(nm, fn) if (!env_get(e, #nm)) env_set_local_owned(e, #nm, make_null());
        EIGS_GFX_BUILTINS(X)
        EIGS_HTTP_BUILTINS(X)
        EIGS_HTTP_REQUEST_BUILTINS(X)
        EIGS_DB_BUILTINS(X)
        EIGS_MODEL_BUILTINS(X)
#undef X
        if (!env_get(e, "report_value"))
            env_set_local_owned(e, "report_value", make_null());
        if (!env_get(e, "trajectory"))   /* #421 special form, like report_value */
            env_set_local_owned(e, "trajectory", make_null());
        g_builtin_name_env = e;
    }
    return env_get(g_builtin_name_env, name) != NULL;
}
#else
/* Freestanding lint is a stub (eigenscript_lint returns early), but the
 * checks still compile — a minimal fallback keeps them self-contained. */
static int is_builtin_name(const char *name) {
    (void)name;
    return 0;
}
static void builtin_name_env_free(void) {}
#endif

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
        case AST_UNOBSERVED:   /* F-DYN-4: same block shape; refs inside
                                * `unobserved:` count as uses */
            for (int i = 0; i < node->data.block.count; i++)
                collect_refs(node->data.block.stmts[i], ctx);
            break;
        case AST_LIST_PATTERN_ASSIGN:
            collect_refs(node->data.list_pattern_assign.expr, ctx);
            break;
        case AST_SLICE:
            collect_refs(node->data.slice.target, ctx);
            collect_refs(node->data.slice.start, ctx);
            collect_refs(node->data.slice.end, ctx);
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
            if (node->data.interrogate.at_expr)
                collect_refs(node->data.interrogate.at_expr, ctx);
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
        case AST_UNOBSERVED:
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
            lint_warn(ctx, stmts[i + 1]->line, "W003", "unreachable code after return");
            break; /* Only warn once per block */
        }
    }
}

/* ---- Check: bare predicate in a multi-observe loop condition ---- */

/* True if the condition contains a BARE predicate (`converged`, …) with no
 * named subject. The named form `<pred> of <ident>` — RELATION(PREDICATE,
 * IDENT) — is explicit and excluded. */
static int cond_has_bare_predicate(const ASTNode *n) {
    if (!n) return 0;
    switch (n->type) {
        case AST_PREDICATE: return 1;
        case AST_UNARY:     return cond_has_bare_predicate(n->data.unary.operand);
        case AST_BINOP:     return cond_has_bare_predicate(n->data.binop.left) ||
                                   cond_has_bare_predicate(n->data.binop.right);
        case AST_RELATION:
            if (n->data.relation.left && n->data.relation.left->type == AST_PREDICATE &&
                n->data.relation.right && n->data.relation.right->type == AST_IDENT)
                return 0;   /* the named form — not bare */
            return cond_has_bare_predicate(n->data.relation.left) ||
                   cond_has_bare_predicate(n->data.relation.right);
        default: return 0;
    }
}

/* Collect distinct assignment-target names directly in a loop body (and its
 * if/block branches), into `seen`. Unobserved blocks are skipped — those
 * assignments don't move the observer. Used to decide whether a bare predicate
 * condition is ambiguous about which binding it reads. */
static void collect_loop_assign_names(ASTNode *n, const char *seen[], int cap, int *count) {
    if (!n || *count >= cap) return;
    switch (n->type) {
        case AST_ASSIGN: {
            const char *nm = n->data.assign.name;
            if (!nm) break;
            for (int i = 0; i < *count; i++) if (strcmp(seen[i], nm) == 0) return;
            seen[(*count)++] = nm;
            break;
        }
        case AST_IF:
            for (int i = 0; i < n->data.cond.if_count; i++)
                collect_loop_assign_names(n->data.cond.if_body[i], seen, cap, count);
            for (int i = 0; i < n->data.cond.else_count; i++)
                collect_loop_assign_names(n->data.cond.else_body[i], seen, cap, count);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++)
                collect_loop_assign_names(n->data.block.stmts[i], seen, cap, count);
            break;
        default: break;
    }
}

/* ---- Check: empty blocks ---- */

static void check_empty_blocks(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    switch (node->type) {
        case AST_IF:
            if (node->data.cond.if_count == 0)
                lint_warn(ctx, node->line, "W004", "empty if block");
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
            if (node->data.loop.body_count == 0) {
                lint_warn(ctx, node->line, "W005", "empty loop block");
            } else if (cond_has_bare_predicate(node->data.loop.cond)) {
                /* A bare predicate reads the last-observed binding. When the body
                 * assigns more than one binding, which one that is becomes
                 * order-dependent (a trailing counter hijacks it). Steer to the
                 * unambiguous named form. */
                const char *seen[4]; int cnt = 0;
                for (int i = 0; i < node->data.loop.body_count; i++)
                    collect_loop_assign_names(node->data.loop.body[i], seen, 4, &cnt);
                if (cnt >= 2)
                    lint_warn(ctx, node->line, "W014",
                        "bare predicate in loop condition reads the last-observed "
                        "binding, not necessarily the intended one (%d bindings are "
                        "assigned in the body); name it: '<predicate> of <var>'", cnt);
            }
            for (int i = 0; i < node->data.loop.body_count; i++)
                check_empty_blocks(node->data.loop.body[i], ctx);
            break;
        case AST_FOR:
            if (node->data.forloop.body_count == 0)
                lint_warn(ctx, node->line, "W006", "empty for block");
            for (int i = 0; i < node->data.forloop.body_count; i++)
                check_empty_blocks(node->data.forloop.body[i], ctx);
            break;
        case AST_FUNC:
            if (node->data.func.body_count == 0)
                lint_warn(ctx, node->line, "W007", "empty function body '%s'", node->data.func.name);
            for (int i = 0; i < node->data.func.body_count; i++)
                check_empty_blocks(node->data.func.body[i], ctx);
            break;
        case AST_TRY:
            if (node->data.trycatch.try_count == 0)
                lint_warn(ctx, node->line, "W008", "empty try block");
            if (node->data.trycatch.catch_count == 0)
                lint_warn(ctx, node->line, "W009", "empty catch block");
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
                    lint_warn(ctx, kj->line, "W010", "duplicate dict key '%s'", ki->data.str);
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
        lint_warn(ctx, cond->line, "W011",
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
        lint_warn(ctx, node->line, "W012", "'%s' is a builtin — assignment shadows it",
                  node->data.assign.name);
    }
    if (node->type == AST_FUNC && is_builtin_name(node->data.func.name)) {
        lint_warn(ctx, node->line, "W013", "'%s' is a builtin — function definition shadows it",
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
                lint_warn(ctx, node->line, "W002", "unused parameter '%s' in function '%s'",
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

/* Run every lint check on a parsed AST, filling ctx->warnings (sorted by
 * line). Frees the transient assign/ref tracking it allocates; the caller
 * owns ctx and reads ctx->warnings. Shared by the CLI and lint_collect. */
/* ---- W015: a function assignment clobbers a module-level function ---- */

/* A top-level function that assigns — without `local` — to a name that is a
 * module-level FUNCTION silently reassigns (destroys) that function via the
 * `is`-mutates-outward scope model: later `<fn> of ...` calls then fail. This
 * is almost always a name collision, not intent; the fix is `local` or a
 * rename. Mirrors the runtime's resolution exactly (a bare `x is ...` binds
 * outward iff `x` exists in an enclosing scope), so it is not an approximation.
 *
 * SCOPED DELIBERATELY to function-name clobbering. The broader "any outer
 * mutation" reading is refuted by the corpus: under mutate-outward, reusing a
 * generic module VARIABLE name (`total`, `status`, `result`) inside a function
 * is pervasive and almost always benign — 155 such firings across working
 * examples — so flagging it is noise, not a fence. `_`-prefixed names are the
 * convention for intentional module-private state (as W001 already honors) and
 * are skipped. The general local-discipline lint belongs to the scope-aware
 * name-resolution pass (#404), which can do the dataflow to tell benign reuse
 * from a real clobber; #396 tracks that. Params and `local`-declared names are
 * excluded; nested functions are not analysed (enclosing scope isn't module). */

#define W015_MAX_NAMES 512

static int name_present(const char *name, char *const set[], int n) {
    for (int i = 0; i < n; i++) if (strcmp(set[i], name) == 0) return 1;
    return 0;
}
static void name_add(const char *name, char *set[], int *n) {
    if (!name || *n >= W015_MAX_NAMES) return;
    if (name_present(name, set, *n)) return;
    set[(*n)++] = (char *)name;   /* borrowed pointer into the AST; not freed */
}

/* Over-collect every name that is function-local within `n` — `local x`, params
 * (added by the caller), loop/for/catch/list-pattern binders. Recurses through
 * ALL body-bearing nodes (including match and nested funcs' *bodies* only for
 * binder discovery) so a real local is never mistaken for an outer binding.
 * Over-collecting is safe (at worst it suppresses a warning); under-collecting
 * would be a false positive, which is the cardinal sin. */
static void w015_collect_locals(ASTNode *n, char *locals[], int *count) {
    if (!n) return;
    switch (n->type) {
        case AST_ASSIGN:
            if (n->data.assign.local_only) name_add(n->data.assign.name, locals, count);
            break;
        case AST_LIST_PATTERN_ASSIGN:
            for (int i = 0; i < n->data.list_pattern_assign.name_count; i++)
                name_add(n->data.list_pattern_assign.names[i], locals, count);
            break;
        case AST_IF:
            for (int i = 0; i < n->data.cond.if_count; i++)   w015_collect_locals(n->data.cond.if_body[i], locals, count);
            for (int i = 0; i < n->data.cond.else_count; i++) w015_collect_locals(n->data.cond.else_body[i], locals, count);
            break;
        case AST_LOOP:
            for (int i = 0; i < n->data.loop.body_count; i++) w015_collect_locals(n->data.loop.body[i], locals, count);
            break;
        case AST_FOR:
            name_add(n->data.forloop.var, locals, count);
            for (int i = 0; i < n->data.forloop.body_count; i++) w015_collect_locals(n->data.forloop.body[i], locals, count);
            break;
        case AST_TRY:
            name_add(n->data.trycatch.err_name, locals, count);
            for (int i = 0; i < n->data.trycatch.try_count; i++)   w015_collect_locals(n->data.trycatch.try_body[i], locals, count);
            for (int i = 0; i < n->data.trycatch.catch_count; i++) w015_collect_locals(n->data.trycatch.catch_body[i], locals, count);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++) w015_collect_locals(n->data.block.stmts[i], locals, count);
            break;
        case AST_MATCH:
            for (int c = 0; c < n->data.match.case_count; c++)
                for (int k = 0; k < n->data.match.body_counts[c]; k++)
                    w015_collect_locals(n->data.match.bodies[c][k], locals, count);
            break;
        default: break;
    }
}

/* Flag each outward assignment. Recurses the common body-bearing nodes; does
 * NOT descend into nested AST_FUNC (a different scope). Under-covering a node
 * only misses a warning (safe); it never invents one. */
static void w015_flag(ASTNode *n, char *const module[], int module_n,
                      char *const locals[], int locals_n, LintContext *ctx) {
    if (!n) return;
    switch (n->type) {
        case AST_ASSIGN:
            if (!n->data.assign.local_only && n->data.assign.name &&
                n->data.assign.name[0] != '_' &&
                name_present(n->data.assign.name, module, module_n) &&
                !name_present(n->data.assign.name, locals, locals_n)) {
                lint_warn(ctx, n->line, "W015",
                    "'%s' is a module-level function; assigning it without "
                    "'local' clobbers it (later '%s of ...' calls will fail) — "
                    "add 'local' or rename",
                    n->data.assign.name, n->data.assign.name);
            }
            break;
        case AST_IF:
            for (int i = 0; i < n->data.cond.if_count; i++)   w015_flag(n->data.cond.if_body[i], module, module_n, locals, locals_n, ctx);
            for (int i = 0; i < n->data.cond.else_count; i++) w015_flag(n->data.cond.else_body[i], module, module_n, locals, locals_n, ctx);
            break;
        case AST_LOOP:
            for (int i = 0; i < n->data.loop.body_count; i++) w015_flag(n->data.loop.body[i], module, module_n, locals, locals_n, ctx);
            break;
        case AST_FOR:
            for (int i = 0; i < n->data.forloop.body_count; i++) w015_flag(n->data.forloop.body[i], module, module_n, locals, locals_n, ctx);
            break;
        case AST_TRY:
            for (int i = 0; i < n->data.trycatch.try_count; i++)   w015_flag(n->data.trycatch.try_body[i], module, module_n, locals, locals_n, ctx);
            for (int i = 0; i < n->data.trycatch.catch_count; i++) w015_flag(n->data.trycatch.catch_body[i], module, module_n, locals, locals_n, ctx);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++) w015_flag(n->data.block.stmts[i], module, module_n, locals, locals_n, ctx);
            break;
        default: break;
    }
}

static void check_outer_mutation(ASTNode *ast, LintContext *ctx) {
    if (!ast || ast->type != AST_PROGRAM) return;

    /* Module scope of interest = top-level FUNCTION names only (see the rule
     * comment: clobbering a function is the unambiguous-bug core; variable
     * name-reuse is benign under mutate-outward and belongs to #404). */
    char *module[W015_MAX_NAMES]; int module_n = 0;
    for (int i = 0; i < ast->data.program.count; i++) {
        ASTNode *s = ast->data.program.stmts[i];
        if (s && s->type == AST_FUNC) name_add(s->data.func.name, module, &module_n);
    }
    if (module_n == 0) return;

    /* Analyse each top-level function against module scope. */
    for (int i = 0; i < ast->data.program.count; i++) {
        ASTNode *fn = ast->data.program.stmts[i];
        if (!fn || fn->type != AST_FUNC) continue;
        char *locals[W015_MAX_NAMES]; int locals_n = 0;
        for (int p = 0; p < fn->data.func.param_count; p++)
            name_add(fn->data.func.params[p], locals, &locals_n);
        for (int b = 0; b < fn->data.func.body_count; b++)
            w015_collect_locals(fn->data.func.body[b], locals, &locals_n);
        for (int b = 0; b < fn->data.func.body_count; b++)
            w015_flag(fn->data.func.body[b], module, module_n, locals, locals_n, ctx);
    }
}

/* ---- W016: bare trajectory predicate outside a loop condition ---- */

/* A bare predicate (`stable`, `converged`, ...) reads the LAST-OBSERVED
 * binding — which binding that is depends on whatever assignment ran most
 * recently, an invisible alias (the #247/#262 family). One position is a
 * documented, well-defined idiom and stays exempt: a LOOP condition, where
 * W014 already fences the ambiguous multi-assign case and the single-assign
 * `loop while not converged` form is the canonical tutorial pattern. Anywhere
 * else — `if` conditions, assignment RHS, `return`, arguments — the subject
 * is genuinely hidden state; steer to the explicit `<predicate> of <var>`.
 * The named form exempts ANY explicit subject (`stable of (x + 0.0)` is the
 * #262 aliasing workaround, not a bare read). Sites that mean the bare read
 * deliberately carry `# lint: allow W016` (#399). */

static const char *W016_PREDICATE_NAMES[] = {
    "converged", "stable", "improving", "oscillating", "diverging", "equilibrium"
};

static void w016_scan(ASTNode *n, LintContext *ctx) {
    if (!n) return;
    switch (n->type) {
        case AST_PREDICATE: {
            int k = n->data.predicate.kind;
            const char *nm = (k >= 0 && k < 6) ? W016_PREDICATE_NAMES[k] : "predicate";
            lint_warn(ctx, n->line, "W016",
                "bare '%s' reads the last-observed binding (an invisible "
                "alias) — write '%s of <var>'", nm, nm);
            break;
        }
        case AST_RELATION:
            /* `<pred> of <subject>` — explicit subject, not a bare read.
             * Skip the predicate, still scan the subject expression. */
            if (n->data.relation.left && n->data.relation.left->type == AST_PREDICATE) {
                w016_scan(n->data.relation.right, ctx);
                break;
            }
            w016_scan(n->data.relation.left, ctx);
            w016_scan(n->data.relation.right, ctx);
            break;
        case AST_LOOP:
            /* Condition is W014's territory (the documented idiom lives
             * there); the body is scanned like any other code. */
            for (int i = 0; i < n->data.loop.body_count; i++)
                w016_scan(n->data.loop.body[i], ctx);
            break;
        case AST_BINOP:
            w016_scan(n->data.binop.left, ctx);
            w016_scan(n->data.binop.right, ctx);
            break;
        case AST_UNARY:
            w016_scan(n->data.unary.operand, ctx);
            break;
        case AST_ASSIGN:
            w016_scan(n->data.assign.expr, ctx);
            break;
        case AST_IF:
            w016_scan(n->data.cond.cond, ctx);
            for (int i = 0; i < n->data.cond.if_count; i++)
                w016_scan(n->data.cond.if_body[i], ctx);
            for (int i = 0; i < n->data.cond.else_count; i++)
                w016_scan(n->data.cond.else_body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < n->data.func.body_count; i++)
                w016_scan(n->data.func.body[i], ctx);
            break;
        case AST_RETURN:
            w016_scan(n->data.ret.expr, ctx);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++)
                w016_scan(n->data.block.stmts[i], ctx);
            break;
        case AST_LIST_PATTERN_ASSIGN:
            w016_scan(n->data.list_pattern_assign.expr, ctx);
            break;
        case AST_SLICE:
            w016_scan(n->data.slice.target, ctx);
            w016_scan(n->data.slice.start, ctx);
            w016_scan(n->data.slice.end, ctx);
            break;
        case AST_LIST:
            for (int i = 0; i < n->data.list.count; i++)
                w016_scan(n->data.list.elems[i], ctx);
            break;
        case AST_INDEX:
            w016_scan(n->data.index.target, ctx);
            w016_scan(n->data.index.index, ctx);
            break;
        case AST_LISTCOMP:
            w016_scan(n->data.listcomp.expr, ctx);
            w016_scan(n->data.listcomp.iter, ctx);
            if (n->data.listcomp.filter)
                w016_scan(n->data.listcomp.filter, ctx);
            break;
        case AST_FOR:
            w016_scan(n->data.forloop.iter, ctx);
            for (int i = 0; i < n->data.forloop.body_count; i++)
                w016_scan(n->data.forloop.body[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < n->data.program.count; i++)
                w016_scan(n->data.program.stmts[i], ctx);
            break;
        case AST_TRY:
            for (int i = 0; i < n->data.trycatch.try_count; i++)
                w016_scan(n->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < n->data.trycatch.catch_count; i++)
                w016_scan(n->data.trycatch.catch_body[i], ctx);
            break;
        case AST_DICT:
            for (int i = 0; i < n->data.dict.count; i++) {
                w016_scan(n->data.dict.keys[i], ctx);
                w016_scan(n->data.dict.vals[i], ctx);
            }
            break;
        case AST_DOT:
            w016_scan(n->data.dot.target, ctx);
            break;
        case AST_DOT_ASSIGN:
            w016_scan(n->data.dot_assign.target, ctx);
            w016_scan(n->data.dot_assign.expr, ctx);
            break;
        case AST_INDEX_ASSIGN:
            w016_scan(n->data.index_assign.target, ctx);
            w016_scan(n->data.index_assign.index, ctx);
            w016_scan(n->data.index_assign.expr, ctx);
            break;
        case AST_MATCH:
            w016_scan(n->data.match.expr, ctx);
            for (int i = 0; i < n->data.match.case_count; i++) {
                w016_scan(n->data.match.patterns[i], ctx);
                for (int j = 0; j < n->data.match.body_counts[i]; j++)
                    w016_scan(n->data.match.bodies[i][j], ctx);
            }
            break;
        case AST_LAMBDA:
            w016_scan(n->data.lambda.body, ctx);
            break;
        case AST_INTERROGATE:
            w016_scan(n->data.interrogate.expr, ctx);
            if (n->data.interrogate.at_expr)
                w016_scan(n->data.interrogate.at_expr, ctx);
            break;
        default: break;
    }
}

static void check_bare_predicate_alias(ASTNode *ast, LintContext *ctx) {
    w016_scan(ast, ctx);
}

/* ---- W017 (#405): bare 1-element literal arg list ---- */

/* Under the #405 call rule a bare literal list after `of` is ALWAYS an
 * argument list, so `f of [x]` passes ONE argument — x itself, not a
 * 1-element list. The form still reads ambiguously (and under the pre-#405
 * rule it meant the opposite), so steer to the two unambiguous spellings:
 * `f of x` for one argument, `f of ([x])` (#355) to pass the list whole.
 * This doubles as the migration audit: run --lint over a consumer repo and
 * every behavior-changed call site surfaces as a W017. */

static void w017_check_relation(ASTNode *n, LintContext *ctx) {
    ASTNode *fn = n->data.relation.left;
    ASTNode *arg = n->data.relation.right;
    if (!arg || arg->type != AST_LIST || arg->parenthesized ||
        arg->data.list.count != 1)
        return;
    /* `<pred> of [x]` is not a call; the predicate path ignores lists. */
    if (fn && fn->type == AST_PREDICATE) return;
    const char *name = (fn && fn->type == AST_IDENT) ? fn->data.ident.name
                                                     : "<fn>";
    lint_warn(ctx, arg->line, "W017",
        "'%s of [<expr>]' passes one argument (the element, not the list) "
        "— write '%s of <expr>', or '%s of ([<expr>])' to pass a 1-element "
        "list", name, name, name);
}

static void w017_scan(ASTNode *n, LintContext *ctx) {
    if (!n) return;
    switch (n->type) {
        case AST_RELATION:
            w017_check_relation(n, ctx);
            w017_scan(n->data.relation.left, ctx);
            w017_scan(n->data.relation.right, ctx);
            break;
        case AST_LOOP:
            w017_scan(n->data.loop.cond, ctx);
            for (int i = 0; i < n->data.loop.body_count; i++)
                w017_scan(n->data.loop.body[i], ctx);
            break;
        case AST_BINOP:
            w017_scan(n->data.binop.left, ctx);
            w017_scan(n->data.binop.right, ctx);
            break;
        case AST_UNARY:
            w017_scan(n->data.unary.operand, ctx);
            break;
        case AST_ASSIGN:
            w017_scan(n->data.assign.expr, ctx);
            break;
        case AST_IF:
            w017_scan(n->data.cond.cond, ctx);
            for (int i = 0; i < n->data.cond.if_count; i++)
                w017_scan(n->data.cond.if_body[i], ctx);
            for (int i = 0; i < n->data.cond.else_count; i++)
                w017_scan(n->data.cond.else_body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < n->data.func.body_count; i++)
                w017_scan(n->data.func.body[i], ctx);
            break;
        case AST_RETURN:
            w017_scan(n->data.ret.expr, ctx);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++)
                w017_scan(n->data.block.stmts[i], ctx);
            break;
        case AST_LIST_PATTERN_ASSIGN:
            w017_scan(n->data.list_pattern_assign.expr, ctx);
            break;
        case AST_SLICE:
            w017_scan(n->data.slice.target, ctx);
            w017_scan(n->data.slice.start, ctx);
            w017_scan(n->data.slice.end, ctx);
            break;
        case AST_LIST:
            for (int i = 0; i < n->data.list.count; i++)
                w017_scan(n->data.list.elems[i], ctx);
            break;
        case AST_INDEX:
            w017_scan(n->data.index.target, ctx);
            w017_scan(n->data.index.index, ctx);
            break;
        case AST_LISTCOMP:
            w017_scan(n->data.listcomp.expr, ctx);
            w017_scan(n->data.listcomp.iter, ctx);
            if (n->data.listcomp.filter)
                w017_scan(n->data.listcomp.filter, ctx);
            break;
        case AST_FOR:
            w017_scan(n->data.forloop.iter, ctx);
            for (int i = 0; i < n->data.forloop.body_count; i++)
                w017_scan(n->data.forloop.body[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < n->data.program.count; i++)
                w017_scan(n->data.program.stmts[i], ctx);
            break;
        case AST_TRY:
            for (int i = 0; i < n->data.trycatch.try_count; i++)
                w017_scan(n->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < n->data.trycatch.catch_count; i++)
                w017_scan(n->data.trycatch.catch_body[i], ctx);
            break;
        case AST_DICT:
            for (int i = 0; i < n->data.dict.count; i++) {
                w017_scan(n->data.dict.keys[i], ctx);
                w017_scan(n->data.dict.vals[i], ctx);
            }
            break;
        case AST_DOT:
            w017_scan(n->data.dot.target, ctx);
            break;
        case AST_DOT_ASSIGN:
            w017_scan(n->data.dot_assign.target, ctx);
            w017_scan(n->data.dot_assign.expr, ctx);
            break;
        case AST_INDEX_ASSIGN:
            w017_scan(n->data.index_assign.target, ctx);
            w017_scan(n->data.index_assign.index, ctx);
            w017_scan(n->data.index_assign.expr, ctx);
            break;
        case AST_MATCH:
            w017_scan(n->data.match.expr, ctx);
            for (int i = 0; i < n->data.match.case_count; i++) {
                w017_scan(n->data.match.patterns[i], ctx);
                for (int j = 0; j < n->data.match.body_counts[i]; j++)
                    w017_scan(n->data.match.bodies[i][j], ctx);
            }
            break;
        case AST_LAMBDA:
            w017_scan(n->data.lambda.body, ctx);
            break;
        case AST_INTERROGATE:
            w017_scan(n->data.interrogate.expr, ctx);
            if (n->data.interrogate.at_expr)
                w017_scan(n->data.interrogate.at_expr, ctx);
            break;
        default: break;
    }
}

static void check_one_element_arg_list(ASTNode *ast, LintContext *ctx) {
    w017_scan(ast, ctx);
}

/* ---- W018 (#469): e.kind compared against an out-of-set error kind ---- */

/* The error-kind vocabulary is CLOSED (err_kind_name / the EK_* enum). A catch
 * handler comparing a caught error's `.kind` against a string that is a
 * near-miss of a real kind — a case variant, a single-character typo, or a
 * kind renamed out from under the handler — is dead code that silently never
 * fires (the silent-tolerance class the lint train fences).
 *
 * Zero-false-positive contract, three gates: (1) the `.kind` must be read off a
 * **catch-bound** variable, so `.kind` on an unrelated user dict never fires;
 * (2) an exactly-valid kind is silent; (3) we warn ONLY on a near-miss (case
 * variant or edit distance 1) — a genuinely custom `throw {kind: "..."}` kind,
 * many edits from every builtin, stays silent. The closed set is derived from
 * err_kind_name at run time (no hand list to drift when a kind is added). */

#define W018_MAX_CATCH_VARS 64
typedef struct { const char *names[W018_MAX_CATCH_VARS]; int count; } W018Scope;

static int w018_valid_kind(const char *s) {
    for (int k = EK_INTERNAL; k <= EK_USER; k++)
        if (strcmp(s, err_kind_name((ErrKind)k)) == 0) return 1;
    return 0;
}

/* Levenshtein bounded by cap; returns min(distance, cap+1). Kind names and
 * literals are short, so the O(la*lb) DP over two rows is trivial. */
static int w018_edit_distance(const char *a, const char *b, int cap) {
    int la = (int)strlen(a), lb = (int)strlen(b);
    int diff = la - lb; if (diff < 0) diff = -diff;
    if (diff > cap) return cap + 1;
    if (lb >= 64) return cap + 1;
    int prev[64], cur[64];
    for (int j = 0; j <= lb; j++) prev[j] = j;
    for (int i = 1; i <= la; i++) {
        cur[0] = i;
        int rowmin = cur[0];
        for (int j = 1; j <= lb; j++) {
            int cost = (a[i-1] == b[j-1]) ? 0 : 1;
            int del = prev[j] + 1, ins = cur[j-1] + 1, sub = prev[j-1] + cost;
            int m = del < ins ? del : ins; if (sub < m) m = sub;
            cur[j] = m; if (m < rowmin) rowmin = m;
        }
        if (rowmin > cap) return cap + 1;   /* whole row already exceeds cap */
        for (int j = 0; j <= lb; j++) prev[j] = cur[j];
    }
    return prev[lb];
}

/* If `s` (assumed NOT an exact valid kind) is a case variant or an
 * edit-distance-1 typo of a closed kind, return that canonical kind; else
 * NULL. Case fold is ASCII-only — every kind name is lowercase ASCII. */
static const char *w018_near_miss(const char *s) {
    char low[128];
    size_t n = strlen(s);
    if (n && n < sizeof(low)) {
        int folded = 0;
        for (size_t i = 0; i < n; i++) {
            char c = s[i];
            if (c >= 'A' && c <= 'Z') { c = (char)(c - 'A' + 'a'); folded = 1; }
            low[i] = c;
        }
        low[n] = '\0';
        if (folded && w018_valid_kind(low)) {
            for (int k = EK_INTERNAL; k <= EK_USER; k++)
                if (strcmp(low, err_kind_name((ErrKind)k)) == 0)
                    return err_kind_name((ErrKind)k);
        }
    }
    for (int k = EK_INTERNAL; k <= EK_USER; k++) {
        const char *m = err_kind_name((ErrKind)k);
        if (w018_edit_distance(s, m, 1) <= 1) return m;
    }
    return NULL;
}

static int w018_scope_has(W018Scope *sc, const char *name) {
    for (int i = 0; i < sc->count; i++)
        if (strcmp(sc->names[i], name) == 0) return 1;
    return 0;
}

static void w018_check_binop(ASTNode *n, LintContext *ctx, W018Scope *sc) {
    const char *op = n->data.binop.op;
    if (strcmp(op, "=") != 0 && strcmp(op, "!=") != 0) return;   /* == or != */
    ASTNode *l = n->data.binop.left, *r = n->data.binop.right;
    ASTNode *dot = NULL, *str = NULL;
    if (l && l->type == AST_DOT && r && r->type == AST_STR) { dot = l; str = r; }
    else if (r && r->type == AST_DOT && l && l->type == AST_STR) { dot = r; str = l; }
    if (!dot || !str) return;
    if (!dot->data.dot.key || strcmp(dot->data.dot.key, "kind") != 0) return;
    ASTNode *obj = dot->data.dot.target;
    if (!obj || obj->type != AST_IDENT || !obj->data.ident.name) return;
    if (!w018_scope_has(sc, obj->data.ident.name)) return;
    const char *lit = str->data.str;
    if (!lit || w018_valid_kind(lit)) return;       /* valid kind → silent */
    const char *sugg = w018_near_miss(lit);
    if (!sugg) return;                              /* far off → custom kind */
    lint_warn(ctx, n->line, "W018",
        "'%s.kind %s \"%s\"' compares against an unknown error kind — did you "
        "mean \"%s\"? error kinds are a closed set (docs/DIAGNOSTICS.md)",
        obj->data.ident.name, (op[0] == '=' ? "==" : op), lit, sugg);
}

static void w018_scan(ASTNode *n, LintContext *ctx, W018Scope *sc) {
    if (!n) return;
    switch (n->type) {
        case AST_BINOP:
            w018_check_binop(n, ctx, sc);
            w018_scan(n->data.binop.left, ctx, sc);
            w018_scan(n->data.binop.right, ctx, sc);
            break;
        case AST_TRY: {
            for (int i = 0; i < n->data.trycatch.try_count; i++)
                w018_scan(n->data.trycatch.try_body[i], ctx, sc);
            const char *en = n->data.trycatch.err_name;
            int pushed = 0;
            if (en && sc->count < W018_MAX_CATCH_VARS) {
                sc->names[sc->count++] = en; pushed = 1;
            }
            for (int i = 0; i < n->data.trycatch.catch_count; i++)
                w018_scan(n->data.trycatch.catch_body[i], ctx, sc);
            if (pushed) sc->count--;
            break;
        }
        case AST_RELATION:
            w018_scan(n->data.relation.left, ctx, sc);
            w018_scan(n->data.relation.right, ctx, sc);
            break;
        case AST_UNARY:
            w018_scan(n->data.unary.operand, ctx, sc);
            break;
        case AST_ASSIGN:
            w018_scan(n->data.assign.expr, ctx, sc);
            break;
        case AST_IF:
            w018_scan(n->data.cond.cond, ctx, sc);
            for (int i = 0; i < n->data.cond.if_count; i++)
                w018_scan(n->data.cond.if_body[i], ctx, sc);
            for (int i = 0; i < n->data.cond.else_count; i++)
                w018_scan(n->data.cond.else_body[i], ctx, sc);
            break;
        case AST_LOOP:
            w018_scan(n->data.loop.cond, ctx, sc);
            for (int i = 0; i < n->data.loop.body_count; i++)
                w018_scan(n->data.loop.body[i], ctx, sc);
            break;
        case AST_FUNC:
            for (int i = 0; i < n->data.func.body_count; i++)
                w018_scan(n->data.func.body[i], ctx, sc);
            break;
        case AST_RETURN:
            w018_scan(n->data.ret.expr, ctx, sc);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++)
                w018_scan(n->data.block.stmts[i], ctx, sc);
            break;
        case AST_LIST_PATTERN_ASSIGN:
            w018_scan(n->data.list_pattern_assign.expr, ctx, sc);
            break;
        case AST_SLICE:
            w018_scan(n->data.slice.target, ctx, sc);
            w018_scan(n->data.slice.start, ctx, sc);
            w018_scan(n->data.slice.end, ctx, sc);
            break;
        case AST_LIST:
            for (int i = 0; i < n->data.list.count; i++)
                w018_scan(n->data.list.elems[i], ctx, sc);
            break;
        case AST_INDEX:
            w018_scan(n->data.index.target, ctx, sc);
            w018_scan(n->data.index.index, ctx, sc);
            break;
        case AST_LISTCOMP:
            w018_scan(n->data.listcomp.expr, ctx, sc);
            w018_scan(n->data.listcomp.iter, ctx, sc);
            if (n->data.listcomp.filter)
                w018_scan(n->data.listcomp.filter, ctx, sc);
            break;
        case AST_FOR:
            w018_scan(n->data.forloop.iter, ctx, sc);
            for (int i = 0; i < n->data.forloop.body_count; i++)
                w018_scan(n->data.forloop.body[i], ctx, sc);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < n->data.program.count; i++)
                w018_scan(n->data.program.stmts[i], ctx, sc);
            break;
        case AST_DICT:
            for (int i = 0; i < n->data.dict.count; i++) {
                w018_scan(n->data.dict.keys[i], ctx, sc);
                w018_scan(n->data.dict.vals[i], ctx, sc);
            }
            break;
        case AST_DOT:
            w018_scan(n->data.dot.target, ctx, sc);
            break;
        case AST_DOT_ASSIGN:
            w018_scan(n->data.dot_assign.target, ctx, sc);
            w018_scan(n->data.dot_assign.expr, ctx, sc);
            break;
        case AST_INDEX_ASSIGN:
            w018_scan(n->data.index_assign.target, ctx, sc);
            w018_scan(n->data.index_assign.index, ctx, sc);
            w018_scan(n->data.index_assign.expr, ctx, sc);
            break;
        case AST_MATCH:
            w018_scan(n->data.match.expr, ctx, sc);
            for (int i = 0; i < n->data.match.case_count; i++) {
                w018_scan(n->data.match.patterns[i], ctx, sc);
                for (int j = 0; j < n->data.match.body_counts[i]; j++)
                    w018_scan(n->data.match.bodies[i][j], ctx, sc);
            }
            break;
        case AST_LAMBDA:
            w018_scan(n->data.lambda.body, ctx, sc);
            break;
        case AST_INTERROGATE:
            w018_scan(n->data.interrogate.expr, ctx, sc);
            if (n->data.interrogate.at_expr)
                w018_scan(n->data.interrogate.at_expr, ctx, sc);
            break;
        default: break;
    }
}

static void check_error_kind_typo(ASTNode *ast, LintContext *ctx) {
    W018Scope sc = {0};
    w018_scan(ast, ctx, &sc);
}

/* ---- E003 (#404): undefined name — no binding on any path ---- */

/* Increment one of the scope-aware name-resolution pass: a name that is READ
 * somewhere but BOUND nowhere — not by any assignment in any scope, not a
 * param/binder, not a builtin of this binary, not a top-level name of a file
 * pulled in by a literal `load_file` — cannot resolve on any execution path.
 * The runtime raises "undefined variable" the moment that path runs; this
 * surfaces it before then, including on cold branches (the classic
 * dynamic-language typo bug).
 *
 * Direction of approximation (increment two): the binding sets are
 * SCOPE-precise but path-insensitive, modeling the runtime's actual rules
 * (each empirically pinned against the interpreter):
 *   - a fresh-name `is` (or `local`) inside a function binds
 *     FUNCTION-LOCAL — invisible to siblings and to module code;
 *   - closures read enclosing function scopes (lexical chain);
 *   - module-level names are order-insensitive (a function body may read
 *     a module name bound after the definition);
 *   - a nested `define` binds its name in the ENCLOSING function only;
 *   - a module-level `for` LOOP-SCOPES its variable (reading it after
 *     the loop is a runtime error) — a function-level `for` does not;
 *   - listcomp vars and catch vars bind in the containing scope.
 * Within a scope the binder set is still an over-approximation across
 * paths ("bound on some path" suppresses — the sibling-branch
 * first-assignment case). Over-collecting can only silence a true
 * positive, never invent a false one (a false positive breaks consumer
 * CI, which runs --lint nonzero-on-warning). Path-precise "unbound on
 * THIS path" analysis is #404's remaining increment.
 *
 * External contributions (load_file targets, `# lint: loaded-by`
 * composers) stay a FLAT over-approximation collected into the base
 * env: the runtime executes those files into the caller's scope, and
 * scope-narrowing someone else's file buys precision nobody asked for
 * at real false-positive risk.
 *
 * The binding base comes from register_builtins() itself — the runtime's own
 * registry on a scratch Env — never a hand-copied list, so it cannot drift
 * from the binary (lint.c's old BUILTINS list was ~120 names behind).
 *
 * Dynamic escape (documented in docs/DIAGNOSTICS.md): `eval` appearing
 * anywhere, or a `load_file` whose argument is not a string literal, can bind
 * names invisible to static analysis — the pass disables itself for the
 * file. A literal `load_file of "path"` is resolved with the runtime's own
 * resolve_eigenscript_file_from() chain (anchored at the linted file's
 * directory, the runtime's g_script_dir for a directly-run script) and the
 * loaded file's binders are collected transitively. Any resolution, read, or
 * parse failure fails open (pass disabled), matching what the runtime could
 * not execute either. `import` binds only the module NAME (the module dict);
 * member access is a dot-key the identifier walk never touches. */

#if !EIGENSCRIPT_FREESTANDING

#define E003_MAX_VISITED 64
#define E003_MAX_DEPTH   16
#define E003_MAX_SCOPES  4096

typedef struct {
    Env *bind;                      /* base: builtins + flat external binders */
    Env *module_scope;              /* the linted file's top-level scope */
    Env *scope;                     /* current scope (chains to bind via parents) */
    /* Scope registry: COLLECT creates one Env per scope-introducing node
     * (function, lambda, module-level for) in walk order; FLAG re-enters
     * the same Envs by replaying the counter. Both walks visit the same
     * nodes in the same order, so the indices agree by construction. */
    Env *scopes[E003_MAX_SCOPES];
    int scope_count;                /* total created (COLLECT) */
    int scope_idx;                  /* replay cursor (FLAG) */
    int external;                   /* 1 → collecting a loaded file: bind flat */
    int dynamic;                    /* 1 → eval/computed-load_file: pass off */
    char base_dir[4096];            /* dir of the linted file */
    char *visited[E003_MAX_VISITED];/* realpath'd load_file targets */
    int visited_n;
    int depth;
} E003;

enum { E003_COLLECT, E003_FLAG };

static void e003_bind_in(Env *env, const char *name) {
    if (!name || !name[0]) return;
    if (!env_get(env, name))
        env_set_local_owned(env, name, make_null());
}

/* Bind in the CURRENT scope — external (loaded-file) collection routes
 * flat to the base env instead. */
static void e003_bind_name(E003 *e, const char *name) {
    e003_bind_in(e->external ? e->bind : e->scope, name);
}

/* Enter the next scope: COLLECT creates it as a child of the current
 * scope; FLAG replays the registry. Returns the previous scope for the
 * caller to restore. During external collection scopes are not pushed
 * (flat by design). */
static Env *e003_scope_push(E003 *e, int mode) {
    if (e->external) return e->scope;
    Env *prev = e->scope;
    if (mode == E003_COLLECT) {
        if (e->scope_count >= E003_MAX_SCOPES) { e->dynamic = 1; return prev; }
        Env *s = env_new(e->scope);
        e->scopes[e->scope_count++] = s;
        e->scope = s;
    } else {
        if (e->scope_idx >= e->scope_count) { e->dynamic = 1; return prev; }
        e->scope = e->scopes[e->scope_idx++];
    }
    return prev;
}

/* Edit-distance-1 near-miss against every name visible from `scope`
 * (walking the parent chain). Returns the first hit or NULL. Distance 1
 * only — one substitution, insertion, or deletion — so a suggestion is
 * near-certain to be the intended name and the message stays quiet
 * otherwise. */
static int e003_dist1(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    if (la == lb) {                       /* one substitution */
        int diff = 0;
        for (size_t i = 0; i < la; i++)
            if (a[i] != b[i] && ++diff > 1) return 0;
        return diff == 1;
    }
    if (la + 1 == lb) { const char *t = a; a = b; b = t; la = lb; lb = la - 1; }
    else if (la != lb + 1) return 0;
    /* a is longer by one: one deletion from a yields b */
    size_t i = 0, j = 0; int skipped = 0;
    while (i < la && j < lb) {
        if (a[i] == b[j]) { i++; j++; continue; }
        if (skipped) return 0;
        skipped = 1; i++;
    }
    return 1;
}

static const char *e003_suggest(Env *scope, const char *name) {
    if (strlen(name) < 3) return NULL;   /* 1-2 char typos suggest noise */
    for (Env *s = scope; s; s = s->parent)
        for (int i = 0; i < s->count; i++)
            if (s->names[i] && e003_dist1(name, s->names[i]))
                return s->names[i];
    return NULL;
}

static void e003_walk(ASTNode *n, E003 *e, LintContext *ctx, int mode);

/* Pull the top-level binders of a literally-named load_file target into the
 * binding set, transitively (the runtime executes the file into the global
 * env). Fails open: anything the runtime couldn't load either → pass off. */
static void e003_load(E003 *e, const char *relpath) {
    if (e->dynamic) return;
    if (e->depth >= E003_MAX_DEPTH || e->visited_n >= E003_MAX_VISITED) {
        e->dynamic = 1;
        return;
    }
    char resolved[8192], real[8192];
    if (!resolve_eigenscript_file_from(e->base_dir, relpath,
                                       resolved, sizeof(resolved))) {
        e->dynamic = 1;
        return;
    }
    if (!realpath(resolved, real))
        snprintf(real, sizeof(real), "%s", resolved);
    for (int i = 0; i < e->visited_n; i++)
        if (strcmp(e->visited[i], real) == 0) return;
    e->visited[e->visited_n++] = xstrdup(real);

    long size = 0;
    char *src = read_file_util(real, &size);
    if (!src) { e->dynamic = 1; return; }
    int saved_errors = g_parse_errors;
    g_parse_errors = 0;
    TokenList tl = tokenize(src);
    ASTNode *ast = parse(&tl);
    if (g_parse_errors > 0 || !ast) {
        e->dynamic = 1;
    } else {
        int saved_external = e->external;
        e->external = 1;   /* flat collection into the base env */
        e->depth++;
        e003_walk(ast, e, NULL, E003_COLLECT);
        e->depth--;
        e->external = saved_external;
    }
    g_parse_errors = saved_errors;
    free_ast(ast);
    free_tokenlist(&tl);
    free(src);
}

/* One walker, two modes. COLLECT gathers every binder (assign targets incl.
 * `local`, function names/params, lambda params, for/listcomp vars, catch
 * vars, list-pattern names, import module names) and spots the dynamic
 * sites; FLAG reports each AST_IDENT with no binding. Binder-name positions
 * are char* fields, never AST_IDENT children, so FLAG can flag every ident
 * it reaches. */
static void e003_walk(ASTNode *n, E003 *e, LintContext *ctx, int mode) {
    if (!n || e->dynamic) return;
    switch (n->type) {
        case AST_IDENT:
            if (mode == E003_COLLECT) {
                /* A bare (non-call-position) `eval` or `load_file` can be
                 * aliased and invoked with anything — dynamic. Call
                 * positions are intercepted at AST_RELATION below. */
                if (strcmp(n->data.ident.name, "eval") == 0 ||
                    strcmp(n->data.ident.name, "load_file") == 0)
                    e->dynamic = 1;
            } else if (!env_get(e->scope, n->data.ident.name)) {
                const char *near = e003_suggest(e->scope, n->data.ident.name);
                int nlen = (int)strlen(n->data.ident.name);
                if (near)
                    lint_error_at(ctx, n->line, n->col, nlen, "E003",
                               "undefined name '%s' — no binding on any path (did you mean '%s'?)",
                               n->data.ident.name, near);
                else
                    lint_error_at(ctx, n->line, n->col, nlen, "E003",
                               "undefined name '%s' — no binding on any path",
                               n->data.ident.name);
            }
            break;
        case AST_RELATION: {
            ASTNode *l = n->data.relation.left, *r = n->data.relation.right;
            if (mode == E003_COLLECT && l && l->type == AST_IDENT) {
                if (strcmp(l->data.ident.name, "eval") == 0) {
                    e->dynamic = 1;
                    return;
                }
                if (strcmp(l->data.ident.name, "load_file") == 0) {
                    if (r && r->type == AST_STR) e003_load(e, r->data.str);
                    else e->dynamic = 1;
                    return;
                }
            }
            e003_walk(l, e, ctx, mode);
            e003_walk(r, e, ctx, mode);
            break;
        }
        case AST_ASSIGN:
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.assign.name);
            e003_walk(n->data.assign.expr, e, ctx, mode);
            break;
        case AST_LIST_PATTERN_ASSIGN:
            if (mode == E003_COLLECT)
                for (int i = 0; i < n->data.list_pattern_assign.name_count; i++)
                    e003_bind_name(e, n->data.list_pattern_assign.names[i]);
            e003_walk(n->data.list_pattern_assign.expr, e, ctx, mode);
            break;
        case AST_FUNC: {
            /* The function NAME binds in the enclosing scope (a nested
             * define is enclosing-local — module code cannot call it);
             * params and body binders live in the function's own scope. */
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.func.name);
            Env *prev = e003_scope_push(e, mode);
            if (mode == E003_COLLECT)
                for (int i = 0; i < n->data.func.param_count; i++)
                    e003_bind_name(e, n->data.func.params[i]);
            if (n->data.func.param_defaults)
                for (int i = 0; i < n->data.func.param_count; i++)
                    e003_walk(n->data.func.param_defaults[i], e, ctx, mode);
            for (int i = 0; i < n->data.func.body_count; i++)
                e003_walk(n->data.func.body[i], e, ctx, mode);
            e->scope = prev;
            break;
        }
        case AST_LAMBDA: {
            Env *prev = e003_scope_push(e, mode);
            if (mode == E003_COLLECT)
                for (int i = 0; i < n->data.lambda.param_count; i++)
                    e003_bind_name(e, n->data.lambda.params[i]);
            e003_walk(n->data.lambda.body, e, ctx, mode);
            e->scope = prev;
            break;
        }
        case AST_FOR: {
            /* Module-level `for` LOOP-SCOPES its variable (the VM drops
             * it at loop exit — reading it after the loop is a runtime
             * error); a function-level `for` var is an ordinary local.
             * The iterable is evaluated before the var exists, so it
             * walks in the outer scope. */
            e003_walk(n->data.forloop.iter, e, ctx, mode);
            int module_level = (!e->external && e->scope == e->module_scope);
            Env *prev = e->scope;
            if (module_level) prev = e003_scope_push(e, mode);
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.forloop.var);
            for (int i = 0; i < n->data.forloop.body_count; i++)
                e003_walk(n->data.forloop.body[i], e, ctx, mode);
            e->scope = prev;
            break;
        }
        case AST_LISTCOMP:
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.listcomp.var);
            e003_walk(n->data.listcomp.expr, e, ctx, mode);
            e003_walk(n->data.listcomp.iter, e, ctx, mode);
            e003_walk(n->data.listcomp.filter, e, ctx, mode);
            break;
        case AST_TRY:
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.trycatch.err_name);
            for (int i = 0; i < n->data.trycatch.try_count; i++)
                e003_walk(n->data.trycatch.try_body[i], e, ctx, mode);
            for (int i = 0; i < n->data.trycatch.catch_count; i++)
                e003_walk(n->data.trycatch.catch_body[i], e, ctx, mode);
            break;
        case AST_IMPORT:
            if (mode == E003_COLLECT)
                e003_bind_name(e, n->data.import.module_name);
            break;
        case AST_BINOP:
            e003_walk(n->data.binop.left, e, ctx, mode);
            e003_walk(n->data.binop.right, e, ctx, mode);
            break;
        case AST_UNARY:
            e003_walk(n->data.unary.operand, e, ctx, mode);
            break;
        case AST_IF:
            e003_walk(n->data.cond.cond, e, ctx, mode);
            for (int i = 0; i < n->data.cond.if_count; i++)
                e003_walk(n->data.cond.if_body[i], e, ctx, mode);
            for (int i = 0; i < n->data.cond.else_count; i++)
                e003_walk(n->data.cond.else_body[i], e, ctx, mode);
            break;
        case AST_LOOP:
            e003_walk(n->data.loop.cond, e, ctx, mode);
            for (int i = 0; i < n->data.loop.body_count; i++)
                e003_walk(n->data.loop.body[i], e, ctx, mode);
            break;
        case AST_RETURN:
            e003_walk(n->data.ret.expr, e, ctx, mode);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++)
                e003_walk(n->data.block.stmts[i], e, ctx, mode);
            break;
        case AST_LIST:
            for (int i = 0; i < n->data.list.count; i++)
                e003_walk(n->data.list.elems[i], e, ctx, mode);
            break;
        case AST_INDEX:
            e003_walk(n->data.index.target, e, ctx, mode);
            e003_walk(n->data.index.index, e, ctx, mode);
            break;
        case AST_SLICE:
            e003_walk(n->data.slice.target, e, ctx, mode);
            e003_walk(n->data.slice.start, e, ctx, mode);
            e003_walk(n->data.slice.end, e, ctx, mode);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < n->data.program.count; i++)
                e003_walk(n->data.program.stmts[i], e, ctx, mode);
            break;
        case AST_DICT:
            for (int i = 0; i < n->data.dict.count; i++) {
                e003_walk(n->data.dict.keys[i], e, ctx, mode);
                e003_walk(n->data.dict.vals[i], e, ctx, mode);
            }
            break;
        case AST_DOT:
            /* target only — the key is a field name, not an identifier
             * (module-qualified names stay silent by construction) */
            e003_walk(n->data.dot.target, e, ctx, mode);
            break;
        case AST_DOT_ASSIGN:
            e003_walk(n->data.dot_assign.target, e, ctx, mode);
            e003_walk(n->data.dot_assign.expr, e, ctx, mode);
            break;
        case AST_INDEX_ASSIGN:
            e003_walk(n->data.index_assign.target, e, ctx, mode);
            e003_walk(n->data.index_assign.index, e, ctx, mode);
            e003_walk(n->data.index_assign.expr, e, ctx, mode);
            break;
        case AST_MATCH:
            /* patterns are compared expressions (reads), not binders */
            e003_walk(n->data.match.expr, e, ctx, mode);
            for (int i = 0; i < n->data.match.case_count; i++) {
                e003_walk(n->data.match.patterns[i], e, ctx, mode);
                for (int j = 0; j < n->data.match.body_counts[i]; j++)
                    e003_walk(n->data.match.bodies[i][j], e, ctx, mode);
            }
            break;
        case AST_INTERROGATE:
            e003_walk(n->data.interrogate.expr, e, ctx, mode);
            e003_walk(n->data.interrogate.at_expr, e, ctx, mode);
            break;
        default:
            break;
    }
}

static void check_undefined_names(ASTNode *ast, const char *path,
                                  const char *source, LintContext *ctx) {
    E003 e;
    memset(&e, 0, sizeof(e));
    e.bind = env_new(NULL);
    e.module_scope = env_new(e.bind);
    e.scope = e.module_scope;
    register_builtins(e.bind);
    register_store_builtins(e.bind);
    /* Extension builtins bind by NAME regardless of this binary's build
     * flags (ext_names.h, the same lists their registrars expand): the lint
     * describes the language surface, not the build — a consumer linting
     * gfx code with a default binary must not see phantom E003s. */
#define X(name, fn) e003_bind_name(&e, #name);
    EIGS_GFX_BUILTINS(X)
    EIGS_HTTP_BUILTINS(X)
    EIGS_HTTP_REQUEST_BUILTINS(X)
    EIGS_DB_BUILTINS(X)
    EIGS_MODEL_BUILTINS(X)
#undef X
    /* Names the compiler resolves itself, so no registrar ever binds them:
     * `report_value of x` is a special form (#294), `trajectory of x` is one
     * too (#421), and the observed-loop machinery injects __loop_exit__ /
     * __loop_iterations__ bindings. */
    e003_bind_name(&e, "report_value");
    e003_bind_name(&e, "trajectory");
    e003_bind_name(&e, "__loop_exit__");
    e003_bind_name(&e, "__loop_iterations__");
    /* load_file resolution anchors at the linted file's directory —
     * mirrors main.c's g_script_dir extraction for a directly-run script */
    e.base_dir[0] = '.';
    e.base_dir[1] = '\0';
    if (path) {
        const char *slash = strrchr(path, '/');
        if (slash && slash != path) {
            size_t d = (size_t)(slash - path);
            if (d >= sizeof(e.base_dir)) d = sizeof(e.base_dir) - 1;
            memcpy(e.base_dir, path, d);
            e.base_dir[d] = '\0';
        }
    }
    /* #460: `# lint: loaded-by <relpath>` — this file is a library FRAGMENT
     * composed by the named file: a load_file loader (DMG's dmg.eigs), or a
     * sibling in out-of-language composition (EigenMiniSat's ROM-bundle
     * concat — the context file need not load the fragment; its binders are
     * collected either way, transitively). The named file's binding set
     * becomes the lint context, then THIS file is flagged against it — so
     * unlike `# lint: allow-file E003`, a genuine typo in the fragment
     * still fires. Path resolves like a load_file target from the
     * fragment's directory. Repeatable. Fail-open like every E003 edge: an
     * unresolvable or malformed context disables the pass for the file. */
    if (source) {
        static const char MARKER[] = "# lint: loaded-by";
        const size_t MLEN = sizeof(MARKER) - 1;
        for (const char *q = source; (q = strstr(q, MARKER)) != NULL; ) {
            q += MLEN;
            while (*q == ' ' || *q == '\t') q++;
            const char *tk = q;
            while (*q && *q != ' ' && *q != '\t' && *q != '\n' && *q != '\r') q++;
            if (q > tk && (size_t)(q - tk) < 4096) {
                char rel[4096];
                memcpy(rel, tk, (size_t)(q - tk));
                rel[q - tk] = '\0';
                e003_load(&e, rel);
            } else {
                e.dynamic = 1;
            }
        }
    }
    e003_walk(ast, &e, NULL, E003_COLLECT);
    if (!e.dynamic) {
        e.scope = e.module_scope;   /* replay from the top */
        e.scope_idx = 0;
        e003_walk(ast, &e, ctx, E003_FLAG);
    }
    for (int i = 0; i < e.visited_n; i++) free(e.visited[i]);
    /* Children first: each scope holds a counted ref on its parent. */
    for (int i = e.scope_count - 1; i >= 0; i--) env_decref(e.scopes[i]);
    env_decref(e.module_scope);
    env_decref(e.bind);
}

#endif /* !EIGENSCRIPT_FREESTANDING */

static void lint_run_checks(ASTNode *ast, const char *path,
                            const char *source, LintContext *ctx) {
    check_outer_mutation(ast, ctx);
    check_bare_predicate_alias(ast, ctx);
    check_one_element_arg_list(ast, ctx);
    check_error_kind_typo(ast, ctx);
#if !EIGENSCRIPT_FREESTANDING
    check_undefined_names(ast, path, source, ctx);
#else
    (void)path; (void)source;
#endif
    check_empty_blocks(ast, ctx);
    check_dup_keys(ast, ctx);
    check_builtin_shadow(ast, ctx);
    check_func_unreachable(ast, ctx);
    check_is_conditions(ast, ctx);
    check_unused_params(ast, ctx);

    /* Collect assigns and refs for the unused-variable check. */
    collect_assigns(ast, ctx);
    collect_refs(ast, ctx);

    /* Unused variables (top-level, conservative). Function-defined names
     * are intentional exports — never flagged. */
    int func_name_count = 0;
    char *func_names[MAX_VARS];
    if (ast && ast->type == AST_PROGRAM) {
        for (int i = 0; i < ast->data.program.count; i++) {
            ASTNode *s = ast->data.program.stmts[i];
            if (s && s->type == AST_FUNC)
                func_names[func_name_count++] = s->data.func.name;
        }
    }
    for (int i = 0; i < ctx->assign_count; i++) {
        const char *name = ctx->assigns[i];
        if (name[0] == '_') continue;
        if (is_builtin_name(name)) continue;
        int is_func = 0;
        for (int j = 0; j < func_name_count; j++) {
            if (strcmp(func_names[j], name) == 0) { is_func = 1; break; }
        }
        if (is_func) continue;
        if (!is_ref(ctx, name)) {
            lint_warn(ctx, ctx->assign_lines[i], "W001", "unused variable '%s'", name);
        }
    }

    /* Sort warnings by line number */
    for (int i = 0; i < ctx->warning_count - 1; i++) {
        for (int j = i + 1; j < ctx->warning_count; j++) {
            if (ctx->warnings[j].line < ctx->warnings[i].line) {
                LintWarning tmp = ctx->warnings[i];
                ctx->warnings[i] = ctx->warnings[j];
                ctx->warnings[j] = tmp;
            }
        }
    }

    /* Free the transient assign/ref tracking (warnings are kept). */
    for (int i = 0; i < ctx->assign_count; i++) free(ctx->assigns[i]);
    for (int i = 0; i < ctx->ref_count; i++) free(ctx->refs[i]);
    ctx->assign_count = 0;
    ctx->ref_count = 0;
}

/* Public structured-lint entry: run checks on an AST, copy diagnostics out.
 * `path` is the source file's filesystem path (NULL if unknown) — it anchors
 * E003's literal-load_file resolution; all other checks ignore it. */
int lint_collect(ASTNode *ast, const char *path, const char *source,
                 LintDiag *out, int max) {
    if (!ast || !out || max <= 0) return 0;
    LintContext ctx = {0};
    lint_run_checks(ast, path, source, &ctx);
    int n = ctx.warning_count < max ? ctx.warning_count : max;
    for (int i = 0; i < n; i++) {
        out[i].line = ctx.warnings[i].line;
        out[i].col  = ctx.warnings[i].col;
        out[i].len  = ctx.warnings[i].len;
        snprintf(out[i].code, sizeof(out[i].code), "%s", ctx.warnings[i].code);
        snprintf(out[i].severity, sizeof(out[i].severity), "%s", ctx.warnings[i].level);
        snprintf(out[i].message, sizeof(out[i].message), "%s", ctx.warnings[i].message);
    }
    builtin_name_env_free();
    return n;
}

/* ---- Main lint entry ---- */

/* Inline suppression (#399). Does a `# lint: allow <CODE>...` comment on source
 * line `warn_line` (a trailing comment) or `warn_line - 1` (a comment on the
 * line above) silence `code`? `all` silences every code. Comments are stripped
 * before the AST, so this scans the raw source. */
static int comment_allows(const char *after_marker, const char *code) {
    const char *p = after_marker;
    size_t clen = strlen(code);
    while (*p && *p != '\n') {
        while (*p == ' ' || *p == '\t' || *p == ',') p++;
        if (!*p || *p == '\n') break;
        const char *tk = p;
        while (*p && *p != ' ' && *p != '\t' && *p != ',' && *p != '\n') p++;
        size_t len = (size_t)(p - tk);
        if (len == 3 && strncmp(tk, "all", 3) == 0) return 1;
        if (len == clen && strncmp(tk, code, clen) == 0) return 1;
    }
    return 0;
}
/* File-level suppression (#404): `# lint: allow-file <CODE>...` anywhere in
 * the source (conventionally the file header) drops that code file-wide, in
 * both --lint and the LSP. The escape for module FRAGMENTS — files a loader
 * load_files into scope it provides (lib/ui_w_*.eigs expect lib/ui.eigs to
 * have bound _theme/_ui already), where per-line allows would drown the
 * file. `all` drops every code. */
int lint_file_allows(const char *source, const char *code) {
    static const char MARKER[] = "# lint: allow-file";
    const size_t MLEN = sizeof(MARKER) - 1;
    if (!source) return 0;
    for (const char *q = source; (q = strstr(q, MARKER)) != NULL; q += MLEN)
        if (comment_allows(q + MLEN, code)) return 1;
    return 0;
}

#if !EIGENSCRIPT_FREESTANDING
/* #455: per-file lint allow-list in eigs.json (residual of #399). Walk up from
 * the linted file's directory to the project root (the dir containing
 * eigs.json — the same root the module resolver's walk stops at), read its
 *   { "lint": { "allow": { "<root-relative path>": ["W003", ...] } } }
 * map, and return the newly-owned VAL_LIST of codes allowed for `path`
 * file-wide (or NULL). Caller val_decrefs. A code listed here is filtered
 * exactly like a `# lint: allow-file <code>` in the file — the escape for
 * generated/vendored files a project can't sprinkle comments into. */
static Value *eigs_json_lint_allow_for(const char *path) {
    char real[4096];
    if (!realpath(path, real)) return NULL;

    /* Walk dirname(real) upward for eigs.json; the containing dir is root. */
    char dir[4096];
    snprintf(dir, sizeof(dir), "%s", real);
    char *slash = strrchr(dir, '/');
    if (!slash) return NULL;
    *slash = '\0';

    char root[4096] = {0};
    char jsonpath[4200] = {0};
    for (int i = 0; i < 64; i++) {
        char probe[4200];
        snprintf(probe, sizeof(probe), "%.4000s/eigs.json", dir);
        if (access(probe, F_OK) == 0) {
            snprintf(root, sizeof(root), "%s", dir);
            snprintf(jsonpath, sizeof(jsonpath), "%s", probe);
            break;
        }
        char *s = strrchr(dir, '/');
        if (!s || s == dir) return NULL;
        *s = '\0';
    }
    if (!root[0]) return NULL;

    long sz = 0;
    char *js = read_file_util(jsonpath, &sz);
    if (!js) return NULL;
    int pos = 0;
    Value *j = eigs_json_parse_value(js, &pos);
    free(js);
    if (!j) return NULL;

    Value *result = NULL;
    if (j->type == VAL_DICT) {
        Value *lint = dict_get(j, "lint");
        if (lint && lint->type == VAL_DICT) {
            Value *allow = dict_get(lint, "allow");
            if (allow && allow->type == VAL_DICT) {
                /* real, relative to root ("<root>/lib/x.eigs" → "lib/x.eigs"). */
                size_t rl = strlen(root);
                const char *rel = real;
                if (strncmp(real, root, rl) == 0 && real[rl] == '/')
                    rel = real + rl + 1;
                Value *codes = dict_get(allow, rel);
                if (codes && codes->type == VAL_LIST) {
                    val_incref(codes);
                    result = codes;
                }
            }
        }
    }
    val_decref(j);
    return result;
}

/* Is `code` (or "all") in the eigs.json allow-list `codes` (may be NULL)? */
static int eigs_json_allows(Value *codes, const char *code) {
    if (!codes || codes->type != VAL_LIST) return 0;
    for (int i = 0; i < codes->data.list.count; i++) {
        Value *c = codes->data.list.items[i];
        if (c && c->type == VAL_STR &&
            (strcmp(c->data.str, code) == 0 || strcmp(c->data.str, "all") == 0))
            return 1;
    }
    return 0;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

static int lint_suppressed(const char *source, int warn_line, const char *code) {
    static const char MARKER[] = "# lint: allow";
    const size_t MLEN = sizeof(MARKER) - 1;
    int line = 1;
    for (const char *p = source; *p; ) {
        const char *nl = strchr(p, '\n');
        const char *end = nl ? nl : p + strlen(p);
        if (warn_line == line || warn_line == line + 1) {
            for (const char *q = p; q + MLEN <= end; q++) {
                if (strncmp(q, MARKER, MLEN) == 0 && comment_allows(q + MLEN, code))
                    return 1;
            }
        }
        if (!nl) break;
        p = nl + 1;
        line++;
    }
    return 0;
}

int eigenscript_lint(const char *path, int json_mode, int fail_on_warning) {
#if EIGENSCRIPT_FREESTANDING
    (void)path; (void)json_mode; (void)fail_on_warning;
    return 1;   /* lint is a host-CLI tool; no filesystem here */
#else
    long src_size = 0;
    char *source = read_file_util(path, &src_size);
    if (!source) {
        if (json_mode) {
            char esc[256], pesc[1024];
            json_escape("cannot read file", esc, sizeof(esc));
            json_escape(path, pesc, sizeof(pesc));
            printf("[{\"code\":\"E000\",\"severity\":\"error\",\"line\":0,"
                   "\"file\":\"%s\",\"message\":\"%s '%s'\"}]\n", pesc, esc, pesc);
        } else {
            fprintf(stderr, "Error: cannot read file '%s'\n", path);
        }
        return 1;
    }

    g_parse_errors = 0;
    g_first_error_line = 0;
    g_first_error_msg[0] = '\0';
    TokenList tl = tokenize(source);
    parser_set_caret_source(source);   /* #407: excerpt+caret on col errors */
    ASTNode *ast = parse(&tl);
    parser_set_caret_source(NULL);
    if (g_parse_errors > 0) {
        /* A file that doesn't parse can't be linted. Emit the first
         * structured error (the same one the LSP surfaces) as E002. */
        if (json_mode) {
            char esc[512], pesc[1024];
            json_escape(g_first_error_msg[0] ? g_first_error_msg : "parse error",
                        esc, sizeof(esc));
            json_escape(path, pesc, sizeof(pesc));
            printf("[{\"code\":\"E002\",\"severity\":\"error\",\"line\":%d,"
                   "\"column\":%d,\"file\":\"%s\",\"message\":\"%s\"}]\n",
                   g_first_error_line, g_first_error_col + 1, pesc, esc);
        } else {
            fprintf(stderr, "%s: %d parse error(s) [E002] — cannot lint\n",
                    path, g_parse_errors);
        }
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);
        return 1;
    }

    LintContext ctx = {0};
    lint_run_checks(ast, path, source, &ctx);

    /* #399 inline suppression: drop warnings silenced by a `# lint: allow`
     * comment on their line (or the line above), a `# lint: allow-file`, or
     * the #455 per-file eigs.json allow-list. Compact in place so suppressed
     * diagnostics vanish from both human and JSON output. */
    {
        Value *ej_allow = eigs_json_lint_allow_for(path);
        int kept = 0;
        for (int w = 0; w < ctx.warning_count; w++) {
            if (!lint_file_allows(source, ctx.warnings[w].code) &&
                !eigs_json_allows(ej_allow, ctx.warnings[w].code) &&
                !lint_suppressed(source, ctx.warnings[w].line, ctx.warnings[w].code))
                ctx.warnings[kept++] = ctx.warnings[w];
        }
        ctx.warning_count = kept;
        if (ej_allow) val_decref(ej_allow);
    }

    /* Emit. JSON goes to stdout (machine-consumable, even when clean →
     * "[]"); human text goes to stderr as before, now with the [CODE]. */
    if (json_mode) {
        char pesc[1024], mesc[512];
        json_escape(path, pesc, sizeof(pesc));
        printf("[");
        for (int i = 0; i < ctx.warning_count; i++) {
            json_escape(ctx.warnings[i].message, mesc, sizeof(mesc));
            printf("%s{\"code\":\"%s\",\"severity\":\"%s\",\"line\":%d,"
                   "\"file\":\"%s\",\"message\":\"%s\"}",
                   i ? "," : "", ctx.warnings[i].code, ctx.warnings[i].level,
                   ctx.warnings[i].line, pesc, mesc);
        }
        printf("]\n");
    } else {
        for (int i = 0; i < ctx.warning_count; i++) {
            fprintf(stderr, "%s:%d: %s[%s]: %s\n", path,
                    ctx.warnings[i].line, ctx.warnings[i].level,
                    ctx.warnings[i].code, ctx.warnings[i].message);
        }
        if (ctx.warning_count == 0) {
            fprintf(stderr, "%s: no issues found\n", path);
        }
    }

    free_ast(ast);
    free_tokenlist(&tl);
    free(source);
    builtin_name_env_free();

    /* Exit code (#399): --lint-level warning (default) fails on any surviving
     * warning; --lint-level error makes warnings advisory (exit 0) and fails
     * only on error-severity diagnostics — so a consumer can wire
     * `--lint --json` into CI for diagnostics without warnings-as-errors.
     * (Parse/read errors are E-codes that already returned 1 above.) */
    if (!fail_on_warning) {
        int errors = 0;
        for (int i = 0; i < ctx.warning_count; i++)
            if (strcmp(ctx.warnings[i].level, "error") == 0) errors++;
        return errors > 0 ? 1 : 0;
    }
    return ctx.warning_count > 0 ? 1 : 0;
#endif /* !EIGENSCRIPT_FREESTANDING */
}
