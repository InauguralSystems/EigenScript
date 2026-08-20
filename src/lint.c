/*
 * EigenScript linter — AST-walking static analysis.
 * Reports style warnings and likely bugs.
 */

#include "eigenscript.h"
#include "lint_internal.h"

/* ---- Lint warning storage ---- */

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

/* Hint-severity diagnostic (#591): an advisory nudge. Hints print (and
 * appear in --json / LSP, severity Hint) but never fail --lint under either
 * --lint-level; the same inline / allow-file / eigs.json suppression
 * machinery applies as for every other code. */
void lint_hint(LintContext *ctx, int line, const char *code,
               const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    lint_vdiag(ctx, line, 0, 0, "hint", code, fmt, ap);
    va_end(ap);
}

/* Error-severity diagnostic (fails --lint even at --lint-level error)
 * carrying a token position (#407 residual): the LSP publishes
 * col..col+len as the squiggle range; pass col=0,len=0 when unknown. */
void lint_error_at(LintContext *ctx, int line, int col, int len,
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
            if (node->data.interrogate.when_expr)          /* #868 */
                collect_refs(node->data.interrogate.when_expr, ctx);
            break;
        case AST_IMPORT:
            /* import names become available */
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_NULL:
        case AST_PREDICATE:
        case AST_BREAK:
        case AST_CONTINUE:
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
        case AST_MATCH:
            for (int i = 0; i < node->data.match.case_count; i++)
                for (int j = 0; j < node->data.match.body_counts[i]; j++)
                    collect_assigns(node->data.match.bodies[i][j], ctx);
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
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_RELATION:
        case AST_RETURN:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
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
        /* These take the fallback the deleted `default:` supplied. Enumerated
         * rather than covered by a `default:` so that -Werror=switch (Makefile
         * CFLAGS) makes a new ASTType a build error here. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_ASSIGN:
        case AST_IF:
        case AST_LOOP:
        case AST_FUNC:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_FOR:
        case AST_PROGRAM:
        case AST_INTERROGATE:
        case AST_TRY:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_UNOBSERVED:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
            break;
    }
    return 0;
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
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_RELATION:
        case AST_LOOP:
        case AST_FUNC:
        case AST_RETURN:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_FOR:
        case AST_PROGRAM:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_TRY:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
            break;
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
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_UNOBSERVED:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
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
        case AST_MATCH:
            check_dup_keys(node->data.match.expr, ctx);
            for (int i = 0; i < node->data.match.case_count; i++) {
                check_dup_keys(node->data.match.patterns[i], ctx);
                for (int j = 0; j < node->data.match.body_counts[i]; j++)
                    check_dup_keys(node->data.match.bodies[i][j], ctx);
            }
            break;
        case AST_UNOBSERVED:
            for (int i = 0; i < node->data.block.count; i++)
                check_dup_keys(node->data.block.stmts[i], ctx);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_UNARY:
        case AST_RELATION:
        case AST_BLOCK:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
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
        case AST_MATCH:
            for (int i = 0; i < node->data.match.case_count; i++)
                for (int j = 0; j < node->data.match.body_counts[i]; j++)
                    check_builtin_shadow(node->data.match.bodies[i][j], ctx);
            break;
        case AST_UNOBSERVED:
            for (int i = 0; i < node->data.block.count; i++)
                check_builtin_shadow(node->data.block.stmts[i], ctx);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
            break;
    }
}

/* ---- Check: statement-level interrogative (result discarded) ---- */

/* #583: `why is "..."` where `why` is a question word parses as the
 * INTERROGATIVE form (an expression), not an assignment — as a bare
 * statement its result is always discarded, a silent no-op. When a
 * same-named binding exists in scope this is almost certainly a mistaken
 * assignment (the real downstream hit: Tidepool's catch handler). The
 * discarded form is dead code either way, so every statement-level
 * AST_INTERROGATE is flagged. `check_disc_interrog` is called only on
 * nodes sitting directly in a statement list, so an interrogative used
 * inside an expression (`print of (why is x)`) is never reached. */

#define interrog_word(kind) eigs_interrogative_word(kind)   /* #869: one table */

/* #736: the same silent no-op through the other door. `report of x` /
 * `observe of x` / `report_value of x` / `trajectory of x` over an IDENT are
 * compiler-resolved special forms (REPORT_SLOT/NAME &c) — pure queries with no
 * side effect, so at statement level they evaluate and throw the answer away,
 * printing nothing and raising nothing. That is the worst affordance the
 * observer has: silence is indistinguishable from "nothing to say", and the
 * bare form is what issue bodies and READMEs reach for. Zero false positives by
 * construction: over an ident these names never reach a user function even when
 * one shadows them (#459, see W013), and a non-ident argument (`report of (x +
 * 0.0)`) is an ordinary call this check never sees. */
static const char *disc_observer_query(ASTNode *node) {
    static const char *names[] = {"report", "report_value", "observe",
                                  "trajectory"};
    if (!node || node->type != AST_RELATION) return NULL;
    ASTNode *l = node->data.relation.left, *r = node->data.relation.right;
    if (!l || l->type != AST_IDENT || !r || r->type != AST_IDENT) return NULL;
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        if (strcmp(l->data.ident.name, names[i]) == 0) return names[i];
    return NULL;
}

static void check_disc_interrog(ASTNode *node, LintContext *ctx) {
    if (!node) return;
    const char *q = disc_observer_query(node);
    if (q) {
        lint_warn(ctx, node->line, "W019",
            "'%s of ...' is an observer query; as a statement its result is "
            "discarded and nothing is printed — wrap it in "
            "'print of (%s of ...)'", q, q);
        return;
    }
    if (node->type == AST_INTERROGATE) {
        int k = node->data.interrogate.kind;
        if (k >= 0 && k <= 5)
            lint_warn(ctx, node->line, "W019",
                "'%s is ...' is an interrogative (question words cannot be "
                "assigned with 'is'); as a statement its result is discarded — "
                "rename the variable, or use the interrogative inside an expression",
                interrog_word(k));
        else
            lint_warn(ctx, node->line, "W019",
                "interrogative 'prev of ...' as a bare statement discards its result");
        return;
    }
    switch (node->type) {
        case AST_IF:
            for (int i = 0; i < node->data.cond.if_count; i++)
                check_disc_interrog(node->data.cond.if_body[i], ctx);
            for (int i = 0; i < node->data.cond.else_count; i++)
                check_disc_interrog(node->data.cond.else_body[i], ctx);
            break;
        case AST_LOOP:
            for (int i = 0; i < node->data.loop.body_count; i++)
                check_disc_interrog(node->data.loop.body[i], ctx);
            break;
        case AST_FOR:
            for (int i = 0; i < node->data.forloop.body_count; i++)
                check_disc_interrog(node->data.forloop.body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < node->data.func.body_count; i++)
                check_disc_interrog(node->data.func.body[i], ctx);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                check_disc_interrog(node->data.trycatch.try_body[i], ctx);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                check_disc_interrog(node->data.trycatch.catch_body[i], ctx);
            break;
        case AST_MATCH:
            for (int c = 0; c < node->data.match.case_count; c++)
                for (int k2 = 0; k2 < node->data.match.body_counts[c]; k2++)
                    check_disc_interrog(node->data.match.bodies[c][k2], ctx);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < node->data.block.count; i++)
                check_disc_interrog(node->data.block.stmts[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                check_disc_interrog(node->data.program.stmts[i], ctx);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_RETURN:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
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
        case AST_MATCH:
            for (int i = 0; i < node->data.match.case_count; i++)
                for (int j = 0; j < node->data.match.body_counts[i]; j++)
                    check_func_unreachable(node->data.match.bodies[i][j], ctx);
            break;
        case AST_UNOBSERVED:
            for (int i = 0; i < node->data.block.count; i++)
                check_func_unreachable(node->data.block.stmts[i], ctx);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
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
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_UNOBSERVED:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
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

            /* Build a temporary ref context for this function body. On the
             * HEAP, not the stack: LintContext is ~85 KiB (warnings[256] plus
             * four 512-entry arrays) and check_unused_params recurses into
             * nested AST_FUNCs below, so a by-value local here costs that much
             * C stack per nesting level — exactly the pattern the CLAUDE.md
             * "no big by-value structs in recursive functions" rule names
             * (PR #361). A hosted 8 MiB stack hides it; EigenOS boots on
             * 64 KiB, which is how #361 surfaced in the first place. */
            LintContext *body_ctx = xcalloc(1, sizeof *body_ctx);
            for (int i = 0; i < node->data.func.body_count; i++)
                collect_refs(node->data.func.body[i], body_ctx);

            int found = 0;
            for (int r = 0; r < body_ctx->ref_count; r++) {
                if (strcmp(body_ctx->refs[r], param) == 0) { found = 1; break; }
            }
            /* Also check assignments that reference the param on the RHS */
            if (!found) {
                lint_warn(ctx, node->line, "W002", "unused parameter '%s' in function '%s'",
                          param, node->data.func.name);
            }
            for (int r = 0; r < body_ctx->ref_count; r++) free(body_ctx->refs[r]);
            for (int r = 0; r < body_ctx->assign_count; r++) free(body_ctx->assigns[r]);
            free(body_ctx);
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
        case AST_MATCH:
            for (int i = 0; i < node->data.match.case_count; i++)
                for (int j = 0; j < node->data.match.body_counts[i]; j++)
                    check_unused_params(node->data.match.bodies[i][j], ctx);
            break;
        case AST_UNOBSERVED:
            for (int i = 0; i < node->data.block.count; i++)
                check_unused_params(node->data.block.stmts[i], ctx);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_LOOP:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_TRY:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
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
 * name-resolution pass (#404) landed as E003; #870 tracks the still-open
 * general local-discipline fence. Params and `local`-declared names are
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
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_RELATION:
        case AST_FUNC:
        case AST_RETURN:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_PROGRAM:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_SLICE:
            break;
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
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_RELATION:
        case AST_FUNC:
        case AST_RETURN:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_PROGRAM:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
            break;
    }
}

static void check_outer_mutation(ASTNode *ast, LintContext *ctx) {
    if (!ast || ast->type != AST_PROGRAM) return;

    /* Module scope of interest = top-level FUNCTION names only (see the rule
     * comment: clobbering a function is the unambiguous-bug core; variable
     * name-reuse is benign under mutate-outward and belongs to #870). */
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

/* ---- W023 (#870): inverted sibling-branch outer-mutation fence ---- */
/* Prove only the dangerous direction: SET_NAME walks one step to the nearest
 * environment binding.  Model that runtime walk with dominating binders and
 * fail safe to silence; an enclosing binder (including catch) is a deliberate false negative. */
#define W023_MAX_FUNCTION_DEPTH 64
enum { W023_MODULE, W023_SPECIAL, W023_FUNCTIONS, W023_NAME_SCAN };
enum { W023_CAPTURED = 1, W023_INTERROGATED = 2, W023_ENV_BOUND = 4, W023_DEFINE = 8 };
typedef struct { char **names; int count, capacity, unknown; } W023Names;
static int w023_name_present(const W023Names *set, const char *name) {
    for (int i = 0; i < set->count; i++) if (strcmp(set->names[i], name) == 0) return 1;
    return 0;
}
static void w023_names_unknown(W023Names *set) {
    free(set->names);
    *set = (W023Names){ .unknown = 1 };
}
static void w023_name_add(const char *name, W023Names *set) {
    if (!name) { w023_names_unknown(set); return; }
    if (set->unknown || w023_name_present(set, name)) return;
    if (set->count == INT_MAX || (size_t)(set->count + 1) > SIZE_MAX / sizeof(*set->names)) { w023_names_unknown(set); return; }
    if (set->count == set->capacity) {
        int capacity = set->capacity ? set->capacity : 8;
        if (capacity > INT_MAX / 2 || (size_t)capacity > SIZE_MAX / sizeof(*set->names)) { w023_names_unknown(set); return; }
        while (capacity <= set->count) {
            if (capacity > INT_MAX / 2) { w023_names_unknown(set); return; }
            capacity *= 2;
        }
        char **names = realloc(set->names, (size_t)capacity * sizeof(*set->names));
        if (!names) { w023_names_unknown(set); return; }
        set->names = names;
        set->capacity = capacity;
    }
    set->names[set->count++] = (char *)name;
}
static int w023_names_copy(W023Names *dst, const W023Names *src) {
    *dst = (W023Names){ .unknown = src->unknown };
    if (src->unknown || !src->count) return 0;
    if ((size_t)src->count > SIZE_MAX / sizeof(*dst->names)) { dst->unknown = 1; return -1; }
    dst->names = malloc((size_t)src->count * sizeof(*dst->names));
    if (!dst->names) { dst->unknown = 1; return -1; }
    memcpy(dst->names, src->names, (size_t)src->count * sizeof(*dst->names));
    dst->count = dst->capacity = src->count;
    return 0;
}
static void w023_names_free(W023Names *set) { free(set->names); set->names = NULL; set->count = set->capacity = 0; }
static void w023_analyse_function(ASTNode *, ASTNode **, int, W023Names *, LintContext *);
static void w023_scan_sequence(ASTNode **, int, W023Names *, ASTNode *, ASTNode **, int, W023Names *, LintContext *);

static int w023_body_has_name(ASTNode **body, int count, const char *name);

/* This one exhaustive walk mirrors compiler module-name collection, closure
 * probes, and nested-function discovery.  New AST kinds must be listed. */
static void w023_walk(ASTNode *n, int mode, const char *name, int *flags,
                      W023Names *module, ASTNode **ancestors, int depth,
                      LintContext *ctx) {
    if (!n) return;
#define W(x) w023_walk((x), mode, name, flags, module, ancestors, depth, ctx)
#define N(x) do { const char *w023_name = (x); if (mode == W023_NAME_SCAN && w023_name && name && strcmp(w023_name, name) == 0) *flags = 1; } while (0)
    switch (n->type) {
    case AST_ASSIGN:
        if (mode == W023_MODULE) w023_name_add(n->data.assign.name, module);
        else { N(n->data.assign.name); W(n->data.assign.expr); }
        break;
    case AST_FUNC:
        if (mode == W023_MODULE) w023_name_add(n->data.func.name, module);
        else if (mode == W023_SPECIAL) {
            if (name && strcmp(n->data.func.name, name) == 0) *flags |= W023_DEFINE;
            if (name && w023_body_has_name(n->data.func.body, n->data.func.body_count, name)) *flags |= W023_CAPTURED;
        } else if (mode == W023_NAME_SCAN) {
            N(n->data.func.name);
            for (int i = 0; i < n->data.func.body_count; i++) W(n->data.func.body[i]);
        } else if (depth < W023_MAX_FUNCTION_DEPTH) {
            w023_analyse_function(n, ancestors, depth, module, ctx); ancestors[depth] = n;
            for (int i = 0; i < n->data.func.body_count; i++) w023_walk(n->data.func.body[i], mode, name, flags, module, ancestors, depth + 1, ctx);
        }
        break;
    case AST_IF:
        if (mode != W023_MODULE) W(n->data.cond.cond);
        for (int i = 0; i < n->data.cond.if_count; i++) W(n->data.cond.if_body[i]);
        for (int i = 0; i < n->data.cond.else_count; i++) W(n->data.cond.else_body[i]); break;
    case AST_LOOP:
        if (mode != W023_MODULE) W(n->data.loop.cond); for (int i = 0; i < n->data.loop.body_count; i++) W(n->data.loop.body[i]); break;
    case AST_BLOCK: case AST_UNOBSERVED:
        for (int i = 0; i < n->data.block.count; i++) W(n->data.block.stmts[i]); break;
    case AST_FOR:
        if (mode == W023_SPECIAL && name && strcmp(n->data.forloop.var, name) == 0) *flags |= W023_ENV_BOUND;
        N(n->data.forloop.var);
        if (mode != W023_MODULE) W(n->data.forloop.iter); for (int i = 0; i < n->data.forloop.body_count; i++) W(n->data.forloop.body[i]); break;
    case AST_TRY:
        for (int i = 0; i < n->data.trycatch.try_count; i++) W(n->data.trycatch.try_body[i]);
        if (mode == W023_MODULE) w023_name_add(n->data.trycatch.err_name, module);
        else if (mode == W023_SPECIAL && name && strcmp(n->data.trycatch.err_name, name) == 0) *flags |= W023_ENV_BOUND;
        else N(n->data.trycatch.err_name);
        for (int i = 0; i < n->data.trycatch.catch_count; i++) W(n->data.trycatch.catch_body[i]); break;
    case AST_MATCH:
        if (mode != W023_MODULE) W(n->data.match.expr);
        for (int i = 0; i < n->data.match.case_count; i++) {
            if (mode != W023_MODULE) W(n->data.match.patterns[i]);
            for (int j = 0; j < n->data.match.body_counts[i]; j++) W(n->data.match.bodies[i][j]);
        }
        break;
    case AST_LIST_PATTERN_ASSIGN:
        if (mode == W023_MODULE) {
            for (int i = 0; i < n->data.list_pattern_assign.name_count; i++)
                w023_name_add(n->data.list_pattern_assign.names[i], module);
        } else {
            for (int i = 0; i < n->data.list_pattern_assign.name_count; i++) N(n->data.list_pattern_assign.names[i]);
            W(n->data.list_pattern_assign.expr);
        }
        break;
    case AST_INTERROGATE:
        if (mode == W023_SPECIAL && name && n->data.interrogate.expr &&
            n->data.interrogate.expr->type == AST_IDENT &&
            strcmp(n->data.interrogate.expr->data.ident.name, name) == 0) *flags |= W023_INTERROGATED;
        if (mode != W023_MODULE) {
            W(n->data.interrogate.expr); W(n->data.interrogate.at_expr); W(n->data.interrogate.when_expr);
        }
        break;
    case AST_LISTCOMP:
        if (mode == W023_SPECIAL && name && strcmp(n->data.listcomp.var, name) == 0) *flags |= W023_ENV_BOUND;
        N(n->data.listcomp.var);
        if (mode != W023_MODULE) {
            W(n->data.listcomp.expr); W(n->data.listcomp.iter); W(n->data.listcomp.filter);
        }
        break;
    case AST_BINOP: W(n->data.binop.left); W(n->data.binop.right); break;
    case AST_UNARY: W(n->data.unary.operand); break;
    case AST_RELATION: W(n->data.relation.left); W(n->data.relation.right); break;
    case AST_RETURN: W(n->data.ret.expr); break;
    case AST_LIST: for (int i = 0; i < n->data.list.count; i++) W(n->data.list.elems[i]); break;
    case AST_INDEX: W(n->data.index.target); W(n->data.index.index); break;
    case AST_DICT: for (int i = 0; i < n->data.dict.count; i++) { W(n->data.dict.keys[i]); W(n->data.dict.vals[i]); } break;
    case AST_DOT: W(n->data.dot.target); break;
    case AST_DOT_ASSIGN: W(n->data.dot_assign.target); W(n->data.dot_assign.expr); break;
    case AST_INDEX_ASSIGN: W(n->data.index_assign.target); W(n->data.index_assign.index); W(n->data.index_assign.expr); break;
    case AST_SLICE: W(n->data.slice.target); W(n->data.slice.start); W(n->data.slice.end); break;
    case AST_LAMBDA:
        if (mode == W023_SPECIAL && name && w023_body_has_name(&n->data.lambda.body, 1, name)) *flags |= W023_CAPTURED;
        else if (mode == W023_FUNCTIONS || mode == W023_NAME_SCAN) W(n->data.lambda.body);
        break;
    case AST_PROGRAM:
        for (int i = 0; i < n->data.program.count; i++) W(n->data.program.stmts[i]);
        break;
    case AST_IDENT: N(n->data.ident.name); break;
    case AST_IMPORT: N(n->data.import.module_name); break;
    case AST_NUM: case AST_STR: case AST_NULL: case AST_PREDICATE: case AST_BREAK: case AST_CONTINUE: break;
    }
#undef N
#undef W
}

static int w023_body_has_name(ASTNode **body, int count, const char *name) {
    int found = 0;
    for (int i = 0; i < count && !found; i++) w023_walk(body[i], W023_NAME_SCAN, name, &found, NULL, NULL, 0, NULL);
    return found;
}

static int w023_special_flags(ASTNode **body, int count, const char *name) {
    int flags = 0;
    for (int i = 0; i < count; i++) w023_walk(body[i], W023_SPECIAL, name, &flags, NULL, NULL, 0, NULL); return flags;
}
static void w023_collect_binders(ASTNode *n, W023Names *locals) {
    if (!n || locals->unknown) return;
    switch (n->type) {
    case AST_ASSIGN:
        if (n->data.assign.local_only) w023_name_add(n->data.assign.name, locals);
        break;
    case AST_LIST_PATTERN_ASSIGN:
        for (int i = 0; i < n->data.list_pattern_assign.name_count; i++)
            w023_name_add(n->data.list_pattern_assign.names[i], locals);
        break;
    case AST_IF:
        for (int i = 0; i < n->data.cond.if_count; i++) w023_collect_binders(n->data.cond.if_body[i], locals);
        for (int i = 0; i < n->data.cond.else_count; i++) w023_collect_binders(n->data.cond.else_body[i], locals);
        break;
    case AST_LOOP:
        for (int i = 0; i < n->data.loop.body_count; i++) w023_collect_binders(n->data.loop.body[i], locals);
        break;
    case AST_FOR:
        w023_name_add(n->data.forloop.var, locals);
        for (int i = 0; i < n->data.forloop.body_count; i++) w023_collect_binders(n->data.forloop.body[i], locals);
        break;
    case AST_TRY:
        w023_name_add(n->data.trycatch.err_name, locals);
        for (int i = 0; i < n->data.trycatch.try_count; i++) w023_collect_binders(n->data.trycatch.try_body[i], locals);
        for (int i = 0; i < n->data.trycatch.catch_count; i++) w023_collect_binders(n->data.trycatch.catch_body[i], locals);
        break;
    case AST_BLOCK:
    case AST_UNOBSERVED:
        for (int i = 0; i < n->data.block.count; i++) w023_collect_binders(n->data.block.stmts[i], locals);
        break;
    case AST_MATCH:
        for (int i = 0; i < n->data.match.case_count; i++)
            for (int j = 0; j < n->data.match.body_counts[i]; j++) w023_collect_binders(n->data.match.bodies[i][j], locals);
        break;
    case AST_NUM:
    case AST_STR:
    case AST_IDENT:
    case AST_NULL:
    case AST_BINOP:
    case AST_UNARY:
    case AST_RELATION:
    case AST_FUNC:
    case AST_RETURN:
    case AST_LIST:
    case AST_INDEX:
    case AST_LISTCOMP:
    case AST_PROGRAM:
    case AST_INTERROGATE:
    case AST_PREDICATE:
    case AST_DICT:
    case AST_DOT:
    case AST_BREAK:
    case AST_CONTINUE:
    case AST_DOT_ASSIGN:
    case AST_IMPORT:
    case AST_LAMBDA:
    case AST_INDEX_ASSIGN:
    case AST_SLICE:
        break;
    }
}
static int w023_prefix_binds(ASTNode **stmts, int limit, const char *name) {
    W023Names locals = {0};
    for (int i = 0; i < limit; i++) {
        w023_collect_binders(stmts[i], &locals);
        if (locals.unknown) { w023_names_free(&locals); return -1; }
        if (w023_special_flags(&stmts[i], 1, name) & (W023_ENV_BOUND | W023_DEFINE)) { w023_names_free(&locals); return 1; }
    }
    int result = w023_name_present(&locals, name);
    w023_names_free(&locals);
    return result;
}
static int w023_enclosing_binds(const char *name, ASTNode **ancestors, int count) {
    for (int a = 0; a < count; a++) {
        ASTNode *fn = ancestors[a];
        for (int p = 0; p < fn->data.func.param_count; p++)
            if (strcmp(fn->data.func.params[p], name) == 0) return 1;
        W023Names locals = {0};
        for (int b = 0; b < fn->data.func.body_count; b++) w023_collect_binders(fn->data.func.body[b], &locals);
        if (locals.unknown) { w023_names_free(&locals); return -1; }
        if (w023_name_present(&locals, name) ||
            (w023_special_flags(fn->data.func.body, fn->data.func.body_count, name) &
             (W023_CAPTURED | W023_INTERROGATED | W023_ENV_BOUND | W023_DEFINE))) { w023_names_free(&locals); return 1; }
        w023_names_free(&locals);
    }
    return 0;
}
static int w023_can_fire(ASTNode *fn, const char *name, W023Names *bound,
                         ASTNode **ancestors, int depth, W023Names *module) {
    if (module->unknown || bound->unknown || !w023_name_present(module, name)) return 0;
    for (int p = 0; p < fn->data.func.param_count; p++) if (strcmp(fn->data.func.params[p], name) == 0) return 0;
    if (w023_special_flags(fn->data.func.body, fn->data.func.body_count, name) &
        (W023_CAPTURED | W023_INTERROGATED | W023_ENV_BOUND)) return 0;
    int enclosing = w023_enclosing_binds(name, ancestors, depth);
    if (enclosing < 0) { w023_names_unknown(module); return 0; }
    return !w023_name_present(bound, name) && !enclosing;
}

static int w023_grow_branch_vectors(ASTNode ****branches, int **counts, size_t *capacity) {
    size_t next = *capacity ? *capacity * 2 : 8;
    if (next < *capacity || next > SIZE_MAX / sizeof(**branches) || next > SIZE_MAX / sizeof(**counts)) return 0;
    ASTNode ***grown_branches = realloc(*branches, next * sizeof(**branches));
    if (!grown_branches) return 0;
    *branches = grown_branches;
    int *grown_counts = realloc(*counts, next * sizeof(**counts));
    if (!grown_counts) return 0;
    *counts = grown_counts;
    *capacity = next;
    return 1;
}
static void w023_proof_failure(W023Names *module, ASTNode ***branches, int **counts) {
    w023_names_unknown(module);
    free(*branches); *branches = NULL;
    free(*counts); *counts = NULL;
}

static void w023_check_if(ASTNode *if_node, ASTNode *fn, W023Names *bound,
                          ASTNode **ancestors, int depth, W023Names *module,
                          LintContext *ctx) {
    ASTNode ***branches = NULL; int *counts = NULL; size_t capacity = 0, nb = 0; ASTNode *cur = if_node;
    while (cur) {
        if (nb == capacity && !w023_grow_branch_vectors(&branches, &counts, &capacity)) {
            w023_proof_failure(module, &branches, &counts); return;
        }
        branches[nb] = cur->data.cond.if_body; counts[nb++] = cur->data.cond.if_count;
        if (cur->data.cond.else_count == 1 && cur->data.cond.else_body[0] && cur->data.cond.else_body[0]->type == AST_IF) cur = cur->data.cond.else_body[0];
        else { if (cur->data.cond.else_count) {
                if (nb == capacity && !w023_grow_branch_vectors(&branches, &counts, &capacity)) {
                    w023_proof_failure(module, &branches, &counts); return;
                }
                branches[nb] = cur->data.cond.else_body; counts[nb++] = cur->data.cond.else_count;
            } cur = NULL; }
    }
    for (size_t i = 0; i < nb; i++) for (int j = 0; j < counts[i]; j++) { ASTNode *bare = branches[i][j];
        if (!bare || bare->type != AST_ASSIGN || bare->data.assign.local_only || !bare->data.assign.name) continue; int sibling = 0;
        for (size_t k = 0; k < nb && !sibling; k++) if (k != i) for (int l = 0; l < counts[k]; l++) { ASTNode *local = branches[k][l]; if (local && local->type == AST_ASSIGN && local->data.assign.local_only && local->data.assign.name && strcmp(local->data.assign.name, bare->data.assign.name) == 0) { sibling = 1; break; } }
        int prefix = sibling ? w023_prefix_binds(branches[i], j, bare->data.assign.name) : 0;
        if (prefix < 0) { w023_proof_failure(module, &branches, &counts); return; }
        if (sibling && !prefix &&
            w023_can_fire(fn, bare->data.assign.name, bound, ancestors, depth, module))
            lint_warn(ctx, bare->line, "W023", "'%s' is assigned in sibling branches with and without 'local' and may mutate an outer binding — add 'local'", bare->data.assign.name);
    }
    free(branches); free(counts);
}
static void w023_scan_sequence(ASTNode **stmts, int count, W023Names *bound,
                               ASTNode *fn, ASTNode **ancestors, int depth,
                               W023Names *module, LintContext *ctx) {
    for (int i = 0; i < count; i++) { ASTNode *n = stmts[i]; if (!n) continue;
        if (module->unknown || bound->unknown) return;
        switch (n->type) {
        case AST_ASSIGN: if (n->data.assign.local_only) w023_name_add(n->data.assign.name, bound); break;
        case AST_FUNC: w023_name_add(n->data.func.name, bound); break;
        case AST_FOR: w023_name_add(n->data.forloop.var, bound); w023_scan_sequence(n->data.forloop.body, n->data.forloop.body_count, bound, fn, ancestors, depth, module, ctx); break;
        case AST_LIST_PATTERN_ASSIGN: for (int j = 0; j < n->data.list_pattern_assign.name_count; j++) w023_name_add(n->data.list_pattern_assign.names[j], bound); break;
        case AST_BLOCK: case AST_UNOBSERVED:
            w023_scan_sequence(n->data.block.stmts, n->data.block.count, bound, fn, ancestors, depth, module, ctx); break;
        case AST_TRY:
            w023_scan_sequence(n->data.trycatch.try_body, n->data.trycatch.try_count, bound, fn, ancestors, depth, module, ctx);
            w023_name_add(n->data.trycatch.err_name, bound);
            w023_scan_sequence(n->data.trycatch.catch_body, n->data.trycatch.catch_count, bound, fn, ancestors, depth, module, ctx); break;
        case AST_IF: {
            W023Names branch;
            w023_check_if(n, fn, bound, ancestors, depth, module, ctx);
            if (module->unknown || w023_names_copy(&branch, bound) < 0) { w023_names_unknown(module); return; }
            w023_scan_sequence(n->data.cond.if_body, n->data.cond.if_count, &branch, fn, ancestors, depth, module, ctx);
            w023_names_free(&branch);
            if (module->unknown || w023_names_copy(&branch, bound) < 0) { w023_names_unknown(module); return; }
            w023_scan_sequence(n->data.cond.else_body, n->data.cond.else_count, &branch, fn, ancestors, depth, module, ctx);
            w023_names_free(&branch);
        } break;
        case AST_LOOP: {
            W023Names body;
            if (w023_names_copy(&body, bound) < 0) { w023_names_unknown(module); return; }
            w023_scan_sequence(n->data.loop.body, n->data.loop.body_count, &body, fn, ancestors, depth, module, ctx);
            w023_names_free(&body);
        } break;
        case AST_MATCH:
            for (int c = 0; c < n->data.match.case_count; c++) {
                W023Names body;
                if (w023_names_copy(&body, bound) < 0) { w023_names_unknown(module); return; }
                w023_scan_sequence(n->data.match.bodies[c], n->data.match.body_counts[c], &body, fn, ancestors, depth, module, ctx);
                w023_names_free(&body);
                if (module->unknown) return;
            }
            break;
        case AST_NUM: case AST_STR: case AST_IDENT: case AST_NULL: case AST_BINOP: case AST_UNARY: case AST_RELATION: case AST_RETURN: case AST_LIST: case AST_INDEX: case AST_LISTCOMP: case AST_PROGRAM: case AST_INTERROGATE: case AST_PREDICATE: case AST_DICT: case AST_DOT: case AST_BREAK: case AST_CONTINUE: case AST_DOT_ASSIGN: case AST_IMPORT: case AST_LAMBDA: case AST_INDEX_ASSIGN: case AST_SLICE: break;
        }
    }
}
static void w023_analyse_function(ASTNode *fn, ASTNode **ancestors, int depth, W023Names *module, LintContext *ctx) {
    W023Names bound = {0}; w023_scan_sequence(fn->data.func.body, fn->data.func.body_count, &bound, fn, ancestors, depth, module, ctx); w023_names_free(&bound);
}
static void check_sibling_outer_mutation(ASTNode *ast, LintContext *ctx) {
    if (!ast || ast->type != AST_PROGRAM) return; W023Names module = {0}; w023_walk(ast, W023_MODULE, NULL, NULL, &module, NULL, 0, NULL); if (!module.count || module.unknown) { w023_names_free(&module); return; }
    ASTNode *ancestors[W023_MAX_FUNCTION_DEPTH] = {0}; w023_walk(ast, W023_FUNCTIONS, NULL, NULL, &module, ancestors, 0, ctx); w023_names_free(&module);
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


static void w016_scan(ASTNode *n, LintContext *ctx) {
    if (!n) return;
    switch (n->type) {
        case AST_PREDICATE: {
            int k = n->data.predicate.kind;
            const char *nm = (k >= 0) ? eigs_predicate_name((unsigned)k) : "predicate";
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
            if (n->data.interrogate.when_expr)             /* #868 */
                w016_scan(n->data.interrogate.when_expr, ctx);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_IMPORT:
            break;
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
            if (n->data.interrogate.when_expr)             /* #868 */
                w017_scan(n->data.interrogate.when_expr, ctx);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_PREDICATE:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_IMPORT:
            break;
    }
}

static void check_one_element_arg_list(ASTNode *ast, LintContext *ctx) {
    w017_scan(ast, ctx);
}

/* ---- W022 (#733): literal arg list longer than the callee's params ---- */

/* Generic direct-child iterator: expands STMT once per non-NULL child of
 * n, with `childvar` bound to it. The switch has NO default arm on
 * purpose — -Werror=switch then forces a new ASTType to be added here,
 * instead of silently pruning that subtree from every walk using this. */
#define LINT_FOR_EACH_CHILD(n, childvar, STMT) do {                          \
    ASTNode *childvar;                                                       \
    int _lfe_i, _lfe_j;                                                      \
    (void)_lfe_i; (void)_lfe_j;                                              \
    switch ((n)->type) {                                                     \
    case AST_NUM: case AST_STR: case AST_IDENT: case AST_NULL:               \
    case AST_PREDICATE: case AST_BREAK: case AST_CONTINUE: case AST_IMPORT:  \
        break;                                                               \
    case AST_BINOP:                                                          \
        if ((childvar = (n)->data.binop.left))  { STMT; }                    \
        if ((childvar = (n)->data.binop.right)) { STMT; }                    \
        break;                                                               \
    case AST_UNARY:                                                          \
        if ((childvar = (n)->data.unary.operand)) { STMT; }                  \
        break;                                                               \
    case AST_ASSIGN:                                                         \
        if ((childvar = (n)->data.assign.expr)) { STMT; }                    \
        break;                                                               \
    case AST_RELATION:                                                       \
        if ((childvar = (n)->data.relation.left))  { STMT; }                 \
        if ((childvar = (n)->data.relation.right)) { STMT; }                 \
        break;                                                               \
    case AST_IF:                                                             \
        if ((childvar = (n)->data.cond.cond)) { STMT; }                      \
        for (_lfe_i = 0; _lfe_i < (n)->data.cond.if_count; _lfe_i++)         \
            if ((childvar = (n)->data.cond.if_body[_lfe_i])) { STMT; }       \
        for (_lfe_i = 0; _lfe_i < (n)->data.cond.else_count; _lfe_i++)       \
            if ((childvar = (n)->data.cond.else_body[_lfe_i])) { STMT; }     \
        break;                                                               \
    case AST_LOOP:                                                           \
        if ((childvar = (n)->data.loop.cond)) { STMT; }                      \
        for (_lfe_i = 0; _lfe_i < (n)->data.loop.body_count; _lfe_i++)       \
            if ((childvar = (n)->data.loop.body[_lfe_i])) { STMT; }          \
        break;                                                               \
    case AST_FUNC:                                                           \
        if ((n)->data.func.param_defaults)                                   \
            for (_lfe_i = 0; _lfe_i < (n)->data.func.param_count; _lfe_i++)  \
                if ((childvar = (n)->data.func.param_defaults[_lfe_i]))      \
                    { STMT; }                                                \
        for (_lfe_i = 0; _lfe_i < (n)->data.func.body_count; _lfe_i++)       \
            if ((childvar = (n)->data.func.body[_lfe_i])) { STMT; }          \
        break;                                                               \
    case AST_RETURN:                                                         \
        if ((childvar = (n)->data.ret.expr)) { STMT; }                       \
        break;                                                               \
    case AST_BLOCK: case AST_UNOBSERVED:                                     \
        for (_lfe_i = 0; _lfe_i < (n)->data.block.count; _lfe_i++)           \
            if ((childvar = (n)->data.block.stmts[_lfe_i])) { STMT; }        \
        break;                                                               \
    case AST_LIST:                                                           \
        for (_lfe_i = 0; _lfe_i < (n)->data.list.count; _lfe_i++)            \
            if ((childvar = (n)->data.list.elems[_lfe_i])) { STMT; }         \
        break;                                                               \
    case AST_INDEX:                                                          \
        if ((childvar = (n)->data.index.target)) { STMT; }                   \
        if ((childvar = (n)->data.index.index))  { STMT; }                   \
        break;                                                               \
    case AST_LISTCOMP:                                                       \
        if ((childvar = (n)->data.listcomp.expr))   { STMT; }                \
        if ((childvar = (n)->data.listcomp.iter))   { STMT; }                \
        if ((childvar = (n)->data.listcomp.filter)) { STMT; }                \
        break;                                                               \
    case AST_FOR:                                                            \
        if ((childvar = (n)->data.forloop.iter)) { STMT; }                   \
        for (_lfe_i = 0; _lfe_i < (n)->data.forloop.body_count; _lfe_i++)    \
            if ((childvar = (n)->data.forloop.body[_lfe_i])) { STMT; }       \
        break;                                                               \
    case AST_PROGRAM:                                                        \
        for (_lfe_i = 0; _lfe_i < (n)->data.program.count; _lfe_i++)         \
            if ((childvar = (n)->data.program.stmts[_lfe_i])) { STMT; }      \
        break;                                                               \
    case AST_INTERROGATE:                                                    \
        if ((childvar = (n)->data.interrogate.expr))    { STMT; }            \
        if ((childvar = (n)->data.interrogate.at_expr)) { STMT; }            \
        if ((childvar = (n)->data.interrogate.when_expr)) { STMT; }          \
        break;                                                               \
    case AST_TRY:                                                            \
        for (_lfe_i = 0; _lfe_i < (n)->data.trycatch.try_count; _lfe_i++)    \
            if ((childvar = (n)->data.trycatch.try_body[_lfe_i])) { STMT; }  \
        for (_lfe_i = 0; _lfe_i < (n)->data.trycatch.catch_count; _lfe_i++)  \
            if ((childvar = (n)->data.trycatch.catch_body[_lfe_i])) { STMT; }\
        break;                                                               \
    case AST_DICT:                                                           \
        for (_lfe_i = 0; _lfe_i < (n)->data.dict.count; _lfe_i++) {          \
            if ((childvar = (n)->data.dict.keys[_lfe_i])) { STMT; }          \
            if ((childvar = (n)->data.dict.vals[_lfe_i])) { STMT; }          \
        }                                                                    \
        break;                                                               \
    case AST_DOT:                                                            \
        if ((childvar = (n)->data.dot.target)) { STMT; }                     \
        break;                                                               \
    case AST_DOT_ASSIGN:                                                     \
        if ((childvar = (n)->data.dot_assign.target)) { STMT; }              \
        if ((childvar = (n)->data.dot_assign.expr))   { STMT; }              \
        break;                                                               \
    case AST_INDEX_ASSIGN:                                                   \
        if ((childvar = (n)->data.index_assign.target)) { STMT; }            \
        if ((childvar = (n)->data.index_assign.index))  { STMT; }            \
        if ((childvar = (n)->data.index_assign.expr))   { STMT; }            \
        break;                                                               \
    case AST_MATCH:                                                          \
        if ((childvar = (n)->data.match.expr)) { STMT; }                     \
        for (_lfe_i = 0; _lfe_i < (n)->data.match.case_count; _lfe_i++) {    \
            if ((childvar = (n)->data.match.patterns[_lfe_i])) { STMT; }     \
            for (_lfe_j = 0; _lfe_j < (n)->data.match.body_counts[_lfe_i];   \
                 _lfe_j++)                                                   \
                if ((childvar = (n)->data.match.bodies[_lfe_i][_lfe_j]))     \
                    { STMT; }                                                \
        }                                                                    \
        break;                                                               \
    case AST_LAMBDA:                                                         \
        if ((childvar = (n)->data.lambda.body)) { STMT; }                    \
        break;                                                               \
    case AST_LIST_PATTERN_ASSIGN:                                            \
        if ((childvar = (n)->data.list_pattern_assign.expr)) { STMT; }       \
        break;                                                               \
    case AST_SLICE:                                                          \
        if ((childvar = (n)->data.slice.target)) { STMT; }                   \
        if ((childvar = (n)->data.slice.start))  { STMT; }                   \
        if ((childvar = (n)->data.slice.end))    { STMT; }                   \
        break;                                                               \
    }                                                                        \
} while (0)

/* Over-arity is silent at runtime: `two of [1, 2, 99]` binds a=1, b=2 and
 * DISCARDS 99 — rc=0, no diagnostic at any stage (under-arity at least
 * null-fills, which tends to fail later; over-arity returns a plausible
 * answer). This is the silent-wrong-answer class, so it gets a lint.
 *
 * Conservative by construction — the warning fires only when the callee
 * name provably has one meaning in this file: exactly one `define` of the
 * name anywhere, and NO other binding of it (assignment, param, lambda
 * param, loop/comprehension var, catch name, list-pattern name, import,
 * or an identifier inside a match pattern). Anything else drops the name
 * from the table (false negatives are fine for a lint; a false positive
 * is not). One-parameter callees are exempt by the #405 semantics
 * themselves: a 2+-element bare list binds WHOLE to a single param —
 * nothing is dropped, and that shape is the deliberate variadic idiom
 * (`reverse of [1, 2, 3]`). */

typedef struct { char *name; int param_count; int defs; int poisoned; } W022Fn;
typedef struct { W022Fn *fns; int count; int cap; } W022Table;

static W022Fn* w022_find(W022Table *t, const char *name) {
    for (int i = 0; i < t->count; i++)
        if (strcmp(t->fns[i].name, name) == 0) return &t->fns[i];
    return NULL;
}

static void w022_poison(W022Table *t, const char *name) {
    W022Fn *f = name ? w022_find(t, name) : NULL;
    if (f) f->poisoned = 1;
}

static void w022_collect_defines(ASTNode *n, W022Table *t) {
    if (!n) return;
    if (n->type == AST_FUNC && n->data.func.name) {
        W022Fn *f = w022_find(t, n->data.func.name);
        if (f) {
            f->defs++;
        } else {
            if (t->count == t->cap) {
                t->cap = t->cap ? t->cap * 2 : 16;
                t->fns = realloc(t->fns, (size_t)t->cap * sizeof(W022Fn));
            }
            t->fns[t->count].name = strdup(n->data.func.name);
            t->fns[t->count].param_count = n->data.func.param_count;
            t->fns[t->count].defs = 1;
            t->fns[t->count].poisoned = 0;
            t->count++;
        }
    }
    LINT_FOR_EACH_CHILD(n, child, w022_collect_defines(child, t));
}

/* Poison every NON-define binding of a collected name. Match patterns are
 * walked as opaque expressions: any identifier inside one poisons (a
 * pattern ident may bind depending on shape — conservative either way). */
static void w022_poison_idents(ASTNode *n, W022Table *t) {
    if (!n) return;
    if (n->type == AST_IDENT) w022_poison(t, n->data.ident.name);
    LINT_FOR_EACH_CHILD(n, child, w022_poison_idents(child, t));
}

static void w022_collect_bindings(ASTNode *n, W022Table *t) {
    if (!n) return;
    switch (n->type) {
        case AST_ASSIGN:
            w022_poison(t, n->data.assign.name);
            break;
        case AST_LIST_PATTERN_ASSIGN:
            for (int i = 0; i < n->data.list_pattern_assign.name_count; i++)
                w022_poison(t, n->data.list_pattern_assign.names[i]);
            break;
        case AST_FUNC:
            for (int i = 0; i < n->data.func.param_count; i++)
                w022_poison(t, n->data.func.params[i]);
            break;
        case AST_LAMBDA:
            for (int i = 0; i < n->data.lambda.param_count; i++)
                w022_poison(t, n->data.lambda.params[i]);
            break;
        case AST_FOR:
            w022_poison(t, n->data.forloop.var);
            break;
        case AST_LISTCOMP:
            w022_poison(t, n->data.listcomp.var);
            break;
        case AST_TRY:
            w022_poison(t, n->data.trycatch.err_name);
            break;
        case AST_IMPORT:
            w022_poison(t, n->data.import.module_name);
            break;
        case AST_MATCH:
            for (int c = 0; c < n->data.match.case_count; c++)
                w022_poison_idents(n->data.match.patterns[c], t);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_RELATION:
        case AST_IF:
        case AST_LOOP:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_PROGRAM:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_UNOBSERVED:
        case AST_INDEX_ASSIGN:
        case AST_SLICE:
            break;
    }
    LINT_FOR_EACH_CHILD(n, child, w022_collect_bindings(child, t));
}

static void w022_scan(ASTNode *n, W022Table *t, LintContext *ctx) {
    if (!n) return;
    if (n->type == AST_RELATION) {
        ASTNode *fn = n->data.relation.left;
        ASTNode *arg = n->data.relation.right;
        if (fn && fn->type == AST_IDENT &&
            arg && arg->type == AST_LIST && !arg->parenthesized) {
            W022Fn *f = w022_find(t, fn->data.ident.name);
            if (f && f->defs == 1 && !f->poisoned &&
                f->param_count != 1 &&
                arg->data.list.count > f->param_count) {
                lint_warn(ctx, arg->line, "W022",
                    "'%s of [...]' passes %d arguments but '%s' takes %d — "
                    "the extras are silently dropped (write '%s of ([...])' "
                    "to pass the list whole)",
                    f->name, arg->data.list.count, f->name,
                    f->param_count, f->name);
            }
        }
    }
    LINT_FOR_EACH_CHILD(n, child, w022_scan(child, t, ctx));
}

static void check_over_arity(ASTNode *ast, LintContext *ctx) {
    W022Table t = {NULL, 0, 0};
    w022_collect_defines(ast, &t);
    w022_collect_bindings(ast, &t);
    w022_scan(ast, &t, ctx);
    for (int i = 0; i < t.count; i++) free(t.fns[i].name);
    free(t.fns);
}

/* ---- W020 (#655): unobserved: block that provably does nothing ---- */

/* `unobserved:` skips observer bookkeeping, which is gated on the NAMED env
 * path (assign_counts in eigenscript.c). A dict field or list element is never
 * observed in the first place — vm.c calls it "untracked" — so a block whose
 * only assignments are `d.k is ...` / `xs[i] is ...` has nothing to skip.
 *
 * It also does not buy in-place mutation, which is the trap: it USED to. The
 * tree-walking eval.c gated the dict fast path on g_unobserved_depth, so the
 * block was a real optimisation when the idiom was written. NaN-boxing B-3a
 * then made that mutation unconditional for the DMG register-write path
 * (dict_set_cached_immediate), the gate went away, and every block of this
 * shape silently became a no-op. Nothing regressed and nothing warned — which
 * is exactly why this needs a lint and not a doc fix. Our own README shipped
 * the dead form as the headline example for two months (#655).
 *
 * Conservative by construction: g_unobserved_depth is a GLOBAL, so a callee
 * runs at depth > 0 too and its named assignments ARE skipped (verified:
 * `when is y` inside a function reads 3 normally, 0 when called from inside a
 * block). A block containing a call therefore may be doing real work through
 * the callee and must not be flagged. Same for anything that binds a name —
 * a for/listcomp variable, a catch name, a match binding. Only a block that is
 * provably inert warns. */

typedef struct {
    int inert;   /* dict/index assignment — nothing for the block to skip */
    int live;    /* named binding or a call — may be doing real work */
} W020Facts;

static void w020_facts(ASTNode *n, W020Facts *f) {
    if (!n) return;
    switch (n->type) {
        /* Targets the block cannot help: never observed, and mutated in
         * place with or without it. */
        case AST_DOT_ASSIGN:
            f->inert = 1;
            w020_facts(n->data.dot_assign.target, f);
            w020_facts(n->data.dot_assign.expr, f);
            return;
        case AST_INDEX_ASSIGN:
            f->inert = 1;
            w020_facts(n->data.index_assign.target, f);
            w020_facts(n->data.index_assign.index, f);
            w020_facts(n->data.index_assign.expr, f);
            return;
        /* A named assignment is the whole point of the block. */
        case AST_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        /* A call inherits the depth, so the callee's named assignments are
         * skipped — the block is load-bearing from here even if every target
         * in view is a dict field. */
        case AST_RELATION:
        case AST_LAMBDA:
        /* Name-binding forms: the bound variable takes the named path. */
        case AST_FOR:
        case AST_LISTCOMP:
        case AST_TRY:
        case AST_MATCH:
        case AST_IMPORT:
        case AST_FUNC:
            f->live = 1;
            return;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_IF:
        case AST_LOOP:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_PROGRAM:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_UNOBSERVED:
        case AST_SLICE:
            break;
    }
    /* Structural nodes: recurse. Anything not enumerated above cannot make a
     * block live on its own, so walking children is enough. */
    switch (n->type) {
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++)
                w020_facts(n->data.block.stmts[i], f);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < n->data.program.count; i++)
                w020_facts(n->data.program.stmts[i], f);
            break;
        case AST_IF:
            w020_facts(n->data.cond.cond, f);
            for (int i = 0; i < n->data.cond.if_count; i++)
                w020_facts(n->data.cond.if_body[i], f);
            for (int i = 0; i < n->data.cond.else_count; i++)
                w020_facts(n->data.cond.else_body[i], f);
            break;
        case AST_LOOP:
            w020_facts(n->data.loop.cond, f);
            for (int i = 0; i < n->data.loop.body_count; i++)
                w020_facts(n->data.loop.body[i], f);
            break;
        case AST_BINOP:
            w020_facts(n->data.binop.left, f);
            w020_facts(n->data.binop.right, f);
            break;
        case AST_UNARY:
            w020_facts(n->data.unary.operand, f);
            break;
        case AST_RETURN:
            w020_facts(n->data.ret.expr, f);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_FUNC:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_FOR:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_TRY:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
            break;
    }
}

static void w020_scan(ASTNode *n, LintContext *ctx) {
    if (!n) return;
    if (n->type == AST_UNOBSERVED) {
        W020Facts f = {0, 0};
        for (int i = 0; i < n->data.block.count; i++)
            w020_facts(n->data.block.stmts[i], &f);
        if (f.inert && !f.live)
            lint_warn(ctx, n->line, "W020",
                "'unobserved:' block has no effect — every assignment targets "
                "a dict field or list element, which is never observed and is "
                "already mutated in place; the block only helps plain "
                "variables ('x is ...')");
        /* Fall through and keep walking: nested blocks still get checked. */
    }
    switch (n->type) {
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++)
                w020_scan(n->data.block.stmts[i], ctx);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < n->data.program.count; i++)
                w020_scan(n->data.program.stmts[i], ctx);
            break;
        case AST_IF:
            for (int i = 0; i < n->data.cond.if_count; i++)
                w020_scan(n->data.cond.if_body[i], ctx);
            for (int i = 0; i < n->data.cond.else_count; i++)
                w020_scan(n->data.cond.else_body[i], ctx);
            break;
        case AST_LOOP:
            for (int i = 0; i < n->data.loop.body_count; i++)
                w020_scan(n->data.loop.body[i], ctx);
            break;
        case AST_FOR:
            for (int i = 0; i < n->data.forloop.body_count; i++)
                w020_scan(n->data.forloop.body[i], ctx);
            break;
        case AST_FUNC:
            for (int i = 0; i < n->data.func.body_count; i++)
                w020_scan(n->data.func.body[i], ctx);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_RETURN:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_TRY:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
            break;
    }
}

static void check_dead_unobserved(ASTNode *ast, LintContext *ctx) {
    w020_scan(ast, ctx);
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
            if (n->data.interrogate.when_expr)             /* #868 */
                w018_scan(n->data.interrogate.when_expr, ctx, sc);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_PREDICATE:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_IMPORT:
            break;
    }
}

static void check_error_kind_typo(ASTNode *ast, LintContext *ctx) {
    W018Scope sc = {0};
    w018_scan(ast, ctx, &sc);
}

void lint_run_checks(ASTNode *ast, const char *path,
                     const char *source, LintContext *ctx) {
    check_outer_mutation(ast, ctx);
    check_sibling_outer_mutation(ast, ctx);
    check_bare_predicate_alias(ast, ctx);
    check_one_element_arg_list(ast, ctx);
    check_over_arity(ast, ctx);
    check_dead_unobserved(ast, ctx);
    check_error_kind_typo(ast, ctx);
    check_undefined_names(ast, path, source, ctx);
    check_stdlib_shadow(ast, path, ctx);
    check_empty_blocks(ast, ctx);
    check_dup_keys(ast, ctx);
    check_builtin_shadow(ast, ctx);
    check_disc_interrog(ast, ctx);
    check_func_unreachable(ast, ctx);
    check_is_conditions(ast, ctx);
    check_unused_params(ast, ctx);

    /* Collect assigns and refs for the unused-variable check. */
    collect_assigns(ast, ctx);
    collect_refs(ast, ctx);

    /* Unused variables (top-level, conservative). Function-defined names
     * are intentional exports — never flagged. */
    int func_name_count = 0;
    char **func_names = NULL;
    if (ast && ast->type == AST_PROGRAM && ast->data.program.count > 0) {
        /* Sized to the statement count, not a fixed MAX_VARS: program.count
         * has been unbounded since #327 removed the fixed statement caps, so
         * a 512-entry stack array was a stack-buffer-overflow driven purely
         * by input length — reachable via `--lint` and via the LSP's
         * lint_collect, on exactly the machine-generated shape (#397's
         * `make lib` amalgamation, iLambdaAi's output) that gets big. */
        func_names = xcalloc((size_t)ast->data.program.count, sizeof(char *));
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
    free(func_names);

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


int lint_suppressed(const char *source, int warn_line, const char *code) {
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
