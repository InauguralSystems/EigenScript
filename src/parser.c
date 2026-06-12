/*
 * EigenScript parser. Recursive-descent AST construction from
 * the token stream produced by the lexer.
 */

#include "eigenscript.h"

/* Parse-error counter owned by eigenscript.c. */
extern __thread int g_parse_errors;
const char* tok_type_name(TokType t);


typedef struct {
    TokenList *tl;
    int pos;
} Parser;

static Token* p_cur(Parser *p) {
    if (p->pos >= p->tl->count) return &p->tl->tokens[p->tl->count - 1];
    return &p->tl->tokens[p->pos];
}

static Token* p_peek(Parser *p, int offset) {
    int idx = p->pos + offset;
    if (idx >= p->tl->count) return &p->tl->tokens[p->tl->count - 1];
    return &p->tl->tokens[idx];
}

static Token* p_advance(Parser *p) {
    Token *t = p_cur(p);
    if (p->pos < p->tl->count) p->pos++;
    return t;
}

static int p_match(Parser *p, TokType type) {
    if (p_cur(p)->type == type) {
        p_advance(p);
        return 1;
    }
    return 0;
}

static void p_expect(Parser *p, TokType type) {
    if (p_cur(p)->type != type) {
        fprintf(stderr, "Parse error line %d: expected %s, got %s",
                p_cur(p)->line, tok_type_name(type), tok_type_name(p_cur(p)->type));
        if (p_cur(p)->str_val) fprintf(stderr, " ('%s')", p_cur(p)->str_val);
        fprintf(stderr, "\n");
        {
            char m[160];
            snprintf(m, sizeof(m), "expected %s, got %s",
                     tok_type_name(type), tok_type_name(p_cur(p)->type));
            eigs_record_first_error(p_cur(p)->line, m);
        }
        g_parse_errors++;
    }
    p_advance(p);
}

static void p_skip_newlines(Parser *p) {
    while (p_cur(p)->type == TOK_NEWLINE) p_advance(p);
}

ASTNode* make_node_col(ASTType type, int line, int col) {
    ASTNode *n = xcalloc(1, sizeof(ASTNode));
    n->type = type;
    n->line = line;
    n->col = col;
    return n;
}

ASTNode* make_node(ASTType type, int line) {
    return make_node_col(type, line, 0);
}

static void set_name_hash(ASTNode *node, const char *name) {
    if (node)
        node->name_hash = env_name_hash(name ? name : "");
}

/* Recursively free an AST tree. */
void free_ast(ASTNode *node) {
    if (!node) return;
    switch (node->type) {
        case AST_STR:
            if (node->data.str) free(node->data.str);
            break;
        case AST_IDENT:
            if (node->data.ident.name) free(node->data.ident.name);
            break;
        case AST_BINOP:
            free_ast(node->data.binop.left);
            free_ast(node->data.binop.right);
            break;
        case AST_UNARY:
            free_ast(node->data.unary.operand);
            break;
        case AST_ASSIGN:
            if (node->data.assign.name) free(node->data.assign.name);
            free_ast(node->data.assign.expr);
            break;
        case AST_RELATION:
            free_ast(node->data.relation.left);
            free_ast(node->data.relation.right);
            break;
        case AST_IF:
            free_ast(node->data.cond.cond);
            for (int i = 0; i < node->data.cond.if_count; i++) free_ast(node->data.cond.if_body[i]);
            if (node->data.cond.if_body) free(node->data.cond.if_body);
            for (int i = 0; i < node->data.cond.else_count; i++) free_ast(node->data.cond.else_body[i]);
            if (node->data.cond.else_body) free(node->data.cond.else_body);
            break;
        case AST_LOOP:
            free_ast(node->data.loop.cond);
            for (int i = 0; i < node->data.loop.body_count; i++) free_ast(node->data.loop.body[i]);
            if (node->data.loop.body) free(node->data.loop.body);
            break;
        case AST_FUNC:
            if (node->data.func.name) free(node->data.func.name);
            for (int i = 0; i < node->data.func.param_count; i++)
                free(node->data.func.params[i]);
            free(node->data.func.params);
            if (node->data.func.param_defaults) {
                for (int i = 0; i < node->data.func.param_count; i++)
                    if (node->data.func.param_defaults[i])
                        free_ast(node->data.func.param_defaults[i]);
                free(node->data.func.param_defaults);
            }
            for (int i = 0; i < node->data.func.body_count; i++) free_ast(node->data.func.body[i]);
            if (node->data.func.body) free(node->data.func.body);
            break;
        case AST_RETURN:
            free_ast(node->data.ret.expr);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++) free_ast(node->data.trycatch.try_body[i]);
            free(node->data.trycatch.try_body);
            for (int i = 0; i < node->data.trycatch.catch_count; i++) free_ast(node->data.trycatch.catch_body[i]);
            free(node->data.trycatch.catch_body);
            free(node->data.trycatch.err_name);
            break;
        case AST_LAMBDA:
            for (int i = 0; i < node->data.lambda.param_count; i++)
                free(node->data.lambda.params[i]);
            free(node->data.lambda.params);
            free_ast(node->data.lambda.body);
            break;
        case AST_MATCH:
            free_ast(node->data.match.expr);
            for (int i = 0; i < node->data.match.case_count; i++) {
                if (node->data.match.patterns[i]) free_ast(node->data.match.patterns[i]);
                for (int j = 0; j < node->data.match.body_counts[i]; j++)
                    free_ast(node->data.match.bodies[i][j]);
                free(node->data.match.bodies[i]);
            }
            free(node->data.match.patterns);
            free(node->data.match.bodies);
            free(node->data.match.body_counts);
            break;
        case AST_DICT:
            for (int i = 0; i < node->data.dict.count; i++) {
                free_ast(node->data.dict.keys[i]);
                free_ast(node->data.dict.vals[i]);
            }
            free(node->data.dict.keys);
            free(node->data.dict.vals);
            break;
        case AST_DOT:
            free_ast(node->data.dot.target);
            free(node->data.dot.key);
            break;
        case AST_DOT_ASSIGN:
            free_ast(node->data.dot_assign.target);
            free(node->data.dot_assign.key);
            free_ast(node->data.dot_assign.expr);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < node->data.block.count; i++) free_ast(node->data.block.stmts[i]);
            if (node->data.block.stmts) free(node->data.block.stmts);
            break;
        case AST_LIST:
            for (int i = 0; i < node->data.list.count; i++) free_ast(node->data.list.elems[i]);
            if (node->data.list.elems) free(node->data.list.elems);
            break;
        case AST_INDEX:
            free_ast(node->data.index.target);
            free_ast(node->data.index.index);
            break;
        case AST_INDEX_ASSIGN:
            free_ast(node->data.index_assign.target);
            free_ast(node->data.index_assign.index);
            free_ast(node->data.index_assign.expr);
            break;
        case AST_LIST_PATTERN_ASSIGN:
            for (int i = 0; i < node->data.list_pattern_assign.name_count; i++)
                free(node->data.list_pattern_assign.names[i]);
            free(node->data.list_pattern_assign.names);
            free(node->data.list_pattern_assign.name_hashes);
            free_ast(node->data.list_pattern_assign.expr);
            break;
        case AST_SLICE:
            free_ast(node->data.slice.target);
            free_ast(node->data.slice.start);
            free_ast(node->data.slice.end);
            break;
        case AST_LISTCOMP:
            free_ast(node->data.listcomp.expr);
            if (node->data.listcomp.var) free(node->data.listcomp.var);
            free_ast(node->data.listcomp.iter);
            free_ast(node->data.listcomp.filter);
            break;
        case AST_FOR:
            if (node->data.forloop.var) free(node->data.forloop.var);
            free_ast(node->data.forloop.iter);
            for (int i = 0; i < node->data.forloop.body_count; i++) free_ast(node->data.forloop.body[i]);
            if (node->data.forloop.body) free(node->data.forloop.body);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++) free_ast(node->data.program.stmts[i]);
            if (node->data.program.stmts) free(node->data.program.stmts);
            break;
        case AST_INTERROGATE:
            free_ast(node->data.interrogate.expr);
            free_ast(node->data.interrogate.at_expr);
            break;
        case AST_IMPORT:
            free(node->data.import.module_name);
            break;
        default:
            /* AST_NUM, AST_NULL, AST_PREDICATE, AST_BREAK, AST_CONTINUE — no owned memory */
            break;
    }
    free(node);
}

/* clone_ast's only remaining caller is the compound dot-assign
 * desugaring below (obj.f += e → obj.f is obj.f + e), which clones the
 * dot target subtree for the read side. It was exported while the
 * tree-walking evaluator's make_fn cloned function bodies; that path
 * is gone, so these are parser-internal now. */
static ASTNode *clone_ast(ASTNode *node);

static char **clone_string_array(char **items, int count) {
    if (!items || count <= 0) return NULL;
    char **copy = xcalloc_array(count, sizeof(char *));
    for (int i = 0; i < count; i++)
        copy[i] = xstrdup(items[i] ? items[i] : "");
    return copy;
}

static ASTNode **clone_ast_array(ASTNode **nodes, int count) {
    if (!nodes || count <= 0) return NULL;
    ASTNode **copy = xcalloc_array(count, sizeof(ASTNode *));
    for (int i = 0; i < count; i++)
        copy[i] = clone_ast(nodes[i]);
    return copy;
}

static ASTNode *clone_ast(ASTNode *node) {
    if (!node) return NULL;
    ASTNode *n = make_node_col(node->type, node->line, node->col);
    n->name_hash = node->name_hash;
    switch (node->type) {
        case AST_NUM:
            n->data.num = node->data.num;
            break;
        case AST_STR:
            n->data.str = xstrdup(node->data.str ? node->data.str : "");
            break;
        case AST_IDENT:
            n->data.ident.name = xstrdup(node->data.ident.name ? node->data.ident.name : "");
            break;
        case AST_BINOP:
            memcpy(n->data.binop.op, node->data.binop.op, sizeof(n->data.binop.op));
            n->data.binop.left = clone_ast(node->data.binop.left);
            n->data.binop.right = clone_ast(node->data.binop.right);
            break;
        case AST_UNARY:
            memcpy(n->data.unary.op, node->data.unary.op, sizeof(n->data.unary.op));
            n->data.unary.operand = clone_ast(node->data.unary.operand);
            break;
        case AST_ASSIGN:
            n->data.assign.name = xstrdup(node->data.assign.name ? node->data.assign.name : "");
            n->data.assign.expr = clone_ast(node->data.assign.expr);
            n->data.assign.local_only = node->data.assign.local_only;
            break;
        case AST_RELATION:
            n->data.relation.left = clone_ast(node->data.relation.left);
            n->data.relation.right = clone_ast(node->data.relation.right);
            break;
        case AST_IF:
            n->data.cond.cond = clone_ast(node->data.cond.cond);
            n->data.cond.if_body = clone_ast_array(node->data.cond.if_body, node->data.cond.if_count);
            n->data.cond.if_count = node->data.cond.if_count;
            n->data.cond.else_body = clone_ast_array(node->data.cond.else_body, node->data.cond.else_count);
            n->data.cond.else_count = node->data.cond.else_count;
            break;
        case AST_LOOP:
            n->data.loop.cond = clone_ast(node->data.loop.cond);
            n->data.loop.body = clone_ast_array(node->data.loop.body, node->data.loop.body_count);
            n->data.loop.body_count = node->data.loop.body_count;
            break;
        case AST_FUNC:
            n->data.func.name = xstrdup(node->data.func.name ? node->data.func.name : "");
            n->data.func.params = clone_string_array(node->data.func.params, node->data.func.param_count);
            n->data.func.param_count = node->data.func.param_count;
            n->data.func.first_default = node->data.func.first_default;
            if (node->data.func.param_defaults) {
                n->data.func.param_defaults = xcalloc(node->data.func.param_count, sizeof(ASTNode*));
                for (int i = 0; i < node->data.func.param_count; i++)
                    if (node->data.func.param_defaults[i])
                        n->data.func.param_defaults[i] = clone_ast(node->data.func.param_defaults[i]);
            }
            n->data.func.body = clone_ast_array(node->data.func.body, node->data.func.body_count);
            n->data.func.body_count = node->data.func.body_count;
            break;
        case AST_RETURN:
            n->data.ret.expr = clone_ast(node->data.ret.expr);
            break;
        case AST_TRY:
            n->data.trycatch.try_body = clone_ast_array(node->data.trycatch.try_body, node->data.trycatch.try_count);
            n->data.trycatch.try_count = node->data.trycatch.try_count;
            n->data.trycatch.err_name = xstrdup(node->data.trycatch.err_name ? node->data.trycatch.err_name : "");
            n->data.trycatch.catch_body = clone_ast_array(node->data.trycatch.catch_body, node->data.trycatch.catch_count);
            n->data.trycatch.catch_count = node->data.trycatch.catch_count;
            break;
        case AST_LAMBDA:
            n->data.lambda.params = clone_string_array(node->data.lambda.params, node->data.lambda.param_count);
            n->data.lambda.param_count = node->data.lambda.param_count;
            n->data.lambda.body = clone_ast(node->data.lambda.body);
            break;
        case AST_MATCH:
            n->data.match.expr = clone_ast(node->data.match.expr);
            n->data.match.case_count = node->data.match.case_count;
            if (n->data.match.case_count > 0) {
                n->data.match.patterns = xcalloc_array(n->data.match.case_count, sizeof(ASTNode *));
                n->data.match.bodies = xcalloc_array(n->data.match.case_count, sizeof(ASTNode **));
                n->data.match.body_counts = xcalloc_array(n->data.match.case_count, sizeof(int));
                for (int i = 0; i < n->data.match.case_count; i++) {
                    n->data.match.patterns[i] = clone_ast(node->data.match.patterns[i]);
                    n->data.match.body_counts[i] = node->data.match.body_counts[i];
                    n->data.match.bodies[i] = clone_ast_array(node->data.match.bodies[i],
                                                              node->data.match.body_counts[i]);
                }
            }
            break;
        case AST_DICT:
            n->data.dict.count = node->data.dict.count;
            n->data.dict.keys = clone_ast_array(node->data.dict.keys, node->data.dict.count);
            n->data.dict.vals = clone_ast_array(node->data.dict.vals, node->data.dict.count);
            break;
        case AST_DOT:
            n->data.dot.target = clone_ast(node->data.dot.target);
            n->data.dot.key = xstrdup(node->data.dot.key ? node->data.dot.key : "");
            break;
        case AST_DOT_ASSIGN:
            n->data.dot_assign.target = clone_ast(node->data.dot_assign.target);
            n->data.dot_assign.key = xstrdup(node->data.dot_assign.key ? node->data.dot_assign.key : "");
            n->data.dot_assign.expr = clone_ast(node->data.dot_assign.expr);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            n->data.block.stmts = clone_ast_array(node->data.block.stmts, node->data.block.count);
            n->data.block.count = node->data.block.count;
            break;
        case AST_LIST:
            n->data.list.elems = clone_ast_array(node->data.list.elems, node->data.list.count);
            n->data.list.count = node->data.list.count;
            break;
        case AST_INDEX:
            n->data.index.target = clone_ast(node->data.index.target);
            n->data.index.index = clone_ast(node->data.index.index);
            break;
        case AST_INDEX_ASSIGN:
            n->data.index_assign.target = clone_ast(node->data.index_assign.target);
            n->data.index_assign.index = clone_ast(node->data.index_assign.index);
            n->data.index_assign.expr = clone_ast(node->data.index_assign.expr);
            break;
        case AST_LIST_PATTERN_ASSIGN: {
            int nc = node->data.list_pattern_assign.name_count;
            n->data.list_pattern_assign.name_count = nc;
            n->data.list_pattern_assign.names = xmalloc_array(nc, sizeof(char*));
            n->data.list_pattern_assign.name_hashes = xmalloc_array(nc, sizeof(uint32_t));
            for (int i = 0; i < nc; i++) {
                n->data.list_pattern_assign.names[i] = xstrdup(node->data.list_pattern_assign.names[i]);
                n->data.list_pattern_assign.name_hashes[i] = node->data.list_pattern_assign.name_hashes[i];
            }
            n->data.list_pattern_assign.expr = clone_ast(node->data.list_pattern_assign.expr);
            break;
        }
        case AST_SLICE:
            n->data.slice.target = clone_ast(node->data.slice.target);
            n->data.slice.start  = clone_ast(node->data.slice.start);
            n->data.slice.end    = clone_ast(node->data.slice.end);
            break;
        case AST_LISTCOMP:
            n->data.listcomp.expr = clone_ast(node->data.listcomp.expr);
            n->data.listcomp.var = xstrdup(node->data.listcomp.var ? node->data.listcomp.var : "");
            n->data.listcomp.iter = clone_ast(node->data.listcomp.iter);
            n->data.listcomp.filter = clone_ast(node->data.listcomp.filter);
            break;
        case AST_FOR:
            n->data.forloop.var = xstrdup(node->data.forloop.var ? node->data.forloop.var : "");
            n->data.forloop.iter = clone_ast(node->data.forloop.iter);
            n->data.forloop.body = clone_ast_array(node->data.forloop.body, node->data.forloop.body_count);
            n->data.forloop.body_count = node->data.forloop.body_count;
            break;
        case AST_PROGRAM:
            n->data.program.stmts = clone_ast_array(node->data.program.stmts, node->data.program.count);
            n->data.program.count = node->data.program.count;
            break;
        case AST_INTERROGATE:
            n->data.interrogate.kind = node->data.interrogate.kind;
            n->data.interrogate.expr = clone_ast(node->data.interrogate.expr);
            n->data.interrogate.at_expr = clone_ast(node->data.interrogate.at_expr);
            break;
        case AST_PREDICATE:
            n->data.predicate.kind = node->data.predicate.kind;
            break;
        case AST_IMPORT:
            n->data.import.module_name = xstrdup(node->data.import.module_name ? node->data.import.module_name : "");
            break;
        case AST_NULL:
        case AST_BREAK:
        case AST_CONTINUE:
            break;
    }
    return n;
}

static int is_compound_assign(TokType t) {
    return t >= TOK_PLUS_EQ && t <= TOK_SHR_EQ;
}

static void compound_to_op(TokType t, char op[4]) {
    memset(op, 0, 4);
    switch (t) {
        case TOK_PLUS_EQ:    op[0] = '+'; break;
        case TOK_MINUS_EQ:   op[0] = '-'; break;
        case TOK_STAR_EQ:    op[0] = '*'; break;
        case TOK_SLASH_EQ:   op[0] = '/'; break;
        case TOK_PERCENT_EQ: op[0] = '%'; break;
        case TOK_AMP_EQ:     op[0] = '&'; break;
        case TOK_BITOR_EQ:   op[0] = '|'; break;
        case TOK_CARET_EQ:   op[0] = '^'; break;
        case TOK_SHL_EQ:     op[0] = '<'; op[1] = '<'; break;
        case TOK_SHR_EQ:     op[0] = '>'; op[1] = '>'; break;
        default: break;
    }
}

static ASTNode* parse_expression(Parser *p);
static ASTNode* parse_statement(Parser *p);

/* Recursion-depth guard for the recursive-descent parser. Nested expressions
 * (parens, lists, dicts, call args) and nested blocks each add a C-recursion
 * level; without a bound, deeply nested source — e.g. via `eval` of untrusted
 * input — would exhaust the C stack and crash. 256 levels is far beyond any
 * human-written program. */
#define PARSE_MAX_DEPTH 256
static __thread int g_parse_depth = 0;

static ASTNode** parse_block(Parser *p, int *count) {
    ASTNode **stmts = xmalloc_array(MAX_STMTS, sizeof(ASTNode*));
    *count = 0;

    /* Nested blocks recurse (parse_block -> parse_statement -> parse_block);
     * bound the depth to keep deeply nested source from exhausting the C
     * stack. Shares the counter with parse_expression. */
    if (g_parse_depth >= PARSE_MAX_DEPTH) {
        fprintf(stderr, "Parse error line %d: block nesting too deep\n",
                p_cur(p)->line);
        g_parse_errors++;
        return stmts;
    }
    g_parse_depth++;

    p_expect(p, TOK_INDENT);
    p_skip_newlines(p);

    while (p_cur(p)->type != TOK_DEDENT && p_cur(p)->type != TOK_EOF) {
        p_skip_newlines(p);
        if (p_cur(p)->type == TOK_DEDENT || p_cur(p)->type == TOK_EOF) break;
        int before = p->pos;
        ASTNode *stmt = parse_statement(p);
        if (stmt && *count < MAX_STMTS) {
            stmts[(*count)++] = stmt;
        }
        if (p->pos == before) {
            g_parse_errors++;
            p_advance(p);
        }
    }

    if (p_cur(p)->type == TOK_DEDENT) p_advance(p);

    g_parse_depth--;
    return stmts;
}

/* Consume a single `[ ... ]` postfix and return either AST_INDEX or
 * AST_SLICE wrapping `target`. Caller has already confirmed the current
 * token is TOK_LBRACKET. Slice forms: [:], [:end], [start:], [start:end].
 * The bare [expr] form remains AST_INDEX. */
static ASTNode* parse_subscript_suffix(Parser *p, ASTNode *target) {
    int line = p_cur(p)->line;
    p_advance(p); /* skip '[' */

    ASTNode *start = NULL, *end = NULL;
    int is_slice = 0;

    if (p_cur(p)->type == TOK_COLON) {
        is_slice = 1;
        p_advance(p); /* skip ':' */
        if (p_cur(p)->type != TOK_RBRACKET) end = parse_expression(p);
    } else {
        start = parse_expression(p);
        if (p_cur(p)->type == TOK_COLON) {
            is_slice = 1;
            p_advance(p);
            if (p_cur(p)->type != TOK_RBRACKET) end = parse_expression(p);
        }
    }
    p_expect(p, TOK_RBRACKET);

    if (is_slice) {
        ASTNode *n = make_node(AST_SLICE, line);
        n->data.slice.target = target;
        n->data.slice.start  = start;
        n->data.slice.end    = end;
        return n;
    }
    ASTNode *n = make_node(AST_INDEX, line);
    n->data.index.target = target;
    n->data.index.index  = start;
    return n;
}

static ASTNode* parse_primary(Parser *p) {
    Token *t = p_cur(p);

    if (t->type >= TOK_WHAT && t->type <= TOK_HOW) {
        int kind = t->type - TOK_WHAT;
        p_advance(p);
        if (p_cur(p)->type == TOK_IS) {
            p_advance(p);
            ASTNode *expr = parse_expression(p);
            ASTNode *at_expr = NULL;
            if (p_cur(p)->type == TOK_AT) {
                p_advance(p);
                at_expr = parse_expression(p);
            }
            ASTNode *n = make_node(AST_INTERROGATE, p_cur(p)->line);
            n->data.interrogate.kind = kind;
            n->data.interrogate.expr = expr;
            n->data.interrogate.at_expr = at_expr;
            return n;
        }
        ASTNode *n = make_node(AST_IDENT, p_cur(p)->line);
        n->data.ident.name = xstrdup(t->str_val);
        set_name_hash(n, n->data.ident.name);
        while (p_cur(p)->type == TOK_LBRACKET) {
            n = parse_subscript_suffix(p, n);
        }
        return n;
    }

    /* `prev of x` — the value bound to x just before its most recent
     * assignment. Always uses the named form: prev requires a binding
     * to look back through, so only IDENT operands are meaningful.
     * Optional `at <expr>` suffix queries past-line state. */
    if (t->type == TOK_PREV) {
        p_advance(p);
        if (p_cur(p)->type == TOK_OF) {
            p_advance(p);
            ASTNode *expr = parse_expression(p);
            ASTNode *at_expr = NULL;
            if (p_cur(p)->type == TOK_AT) {
                p_advance(p);
                at_expr = parse_expression(p);
            }
            ASTNode *n = make_node(AST_INTERROGATE, p_cur(p)->line);
            n->data.interrogate.kind = 6;
            n->data.interrogate.expr = expr;
            n->data.interrogate.at_expr = at_expr;
            return n;
        }
        ASTNode *n = make_node(AST_IDENT, p_cur(p)->line);
        n->data.ident.name = xstrdup(t->str_val);
        set_name_hash(n, n->data.ident.name);
        return n;
    }

    /* Bare `at` outside an interrogative falls back to IDENT, like
     * the question-word soft-keyword path. */
    if (t->type == TOK_AT) {
        p_advance(p);
        ASTNode *n = make_node(AST_IDENT, p_cur(p)->line);
        n->data.ident.name = xstrdup(t->str_val);
        set_name_hash(n, n->data.ident.name);
        return n;
    }

    if (t->type >= TOK_CONVERGED && t->type <= TOK_EQUILIBRIUM) {
        int kind = t->type - TOK_CONVERGED;
        p_advance(p);
        ASTNode *n = make_node(AST_PREDICATE, p_cur(p)->line);
        n->data.predicate.kind = kind;
        return n;
    }

    if (t->type == TOK_NUM) {
        p_advance(p);
        ASTNode *n = make_node(AST_NUM, p_cur(p)->line);
        n->data.num = t->num_val;
        while (p_cur(p)->type == TOK_LBRACKET) {
            n = parse_subscript_suffix(p, n);
        }
        return n;
    }

    if (t->type == TOK_STR) {
        p_advance(p);
        ASTNode *n = make_node(AST_STR, p_cur(p)->line);
        n->data.str = xstrdup(t->str_val);
        while (p_cur(p)->type == TOK_LBRACKET) {
            n = parse_subscript_suffix(p, n);
        }
        return n;
    }

    if (t->type == TOK_NULL) {
        p_advance(p);
        return make_node(AST_NULL, p_cur(p)->line);
    }

    if (t->type == TOK_IDENT) {
        p_advance(p);
        ASTNode *n = make_node(AST_IDENT, p_cur(p)->line);
        n->data.ident.name = xstrdup(t->str_val);
        set_name_hash(n, n->data.ident.name);
        while (p_cur(p)->type == TOK_LBRACKET || p_cur(p)->type == TOK_DOT) {
            if (p_cur(p)->type == TOK_DOT) {
                p_advance(p);
                Token *key_tok = p_cur(p);
                p_expect(p, TOK_IDENT);
                ASTNode *dot = make_node(AST_DOT, p_cur(p)->line);
                dot->data.dot.target = n;
                dot->data.dot.key = xstrdup(key_tok->str_val);
                set_name_hash(dot, dot->data.dot.key);
                n = dot;
            } else {
                n = parse_subscript_suffix(p, n);
            }
        }
        return n;
    }

    if (t->type == TOK_LPAREN) {
        /* Check if this is a lambda: (params) => expr */
        int saved = p->pos;
        int is_lambda = 0;
        p_advance(p); /* skip ( */
        /* Scan forward: if we see IDENT [, IDENT]* ) => then it's a lambda */
        if (p_cur(p)->type == TOK_IDENT || p_cur(p)->type == TOK_RPAREN) {
            int scan = p->pos;
            while (scan < p->tl->count &&
                   (p->tl->tokens[scan].type == TOK_IDENT || p->tl->tokens[scan].type == TOK_COMMA))
                scan++;
            if (scan + 1 < p->tl->count &&
                p->tl->tokens[scan].type == TOK_RPAREN && p->tl->tokens[scan+1].type == TOK_ARROW)
                is_lambda = 1;
        }
        p->pos = saved;

        if (is_lambda) {
            p_advance(p); /* skip ( */
            char **params = xmalloc_array(16, sizeof(char*));
            int param_count = 0;
            while (p_cur(p)->type == TOK_IDENT && param_count < 16) {
                params[param_count++] = xstrdup(p_cur(p)->str_val);
                p_advance(p);
                if (p_cur(p)->type == TOK_COMMA) p_advance(p);
            }
            if (param_count == 0) {
                params[0] = xstrdup("n");
                param_count = 1;
            }
            p_expect(p, TOK_RPAREN);
            p_expect(p, TOK_ARROW); /* => */
            ASTNode *body = parse_expression(p);
            ASTNode *n = make_node(AST_LAMBDA, t->line);
            n->data.lambda.params = params;
            n->data.lambda.param_count = param_count;
            n->data.lambda.body = body;
            return n;
        }

        /* Regular grouping */
        p_advance(p);
        ASTNode *expr = parse_expression(p);
        p_expect(p, TOK_RPAREN);
        while (p_cur(p)->type == TOK_LBRACKET || p_cur(p)->type == TOK_DOT) {
            if (p_cur(p)->type == TOK_DOT) {
                p_advance(p);
                Token *key_tok = p_cur(p);
                p_expect(p, TOK_IDENT);
                ASTNode *dot = make_node(AST_DOT, key_tok->line);
                dot->data.dot.target = expr;
                dot->data.dot.key = xstrdup(key_tok->str_val);
                set_name_hash(dot, dot->data.dot.key);
                expr = dot;
            } else {
                expr = parse_subscript_suffix(p, expr);
            }
        }
        return expr;
    }

    if (t->type == TOK_LBRACKET) {
        p_advance(p);
        if (p_cur(p)->type == TOK_RBRACKET) {
            p_advance(p);
            ASTNode *n = make_node(AST_LIST, p_cur(p)->line);
            n->data.list.elems = NULL;
            n->data.list.count = 0;
            return n;
        }

        ASTNode *first = parse_expression(p);

        if (p_cur(p)->type == TOK_FOR) {
            p_advance(p);
            Token *var_tok = p_cur(p);
            p_expect(p, TOK_IDENT);
            p_expect(p, TOK_IN);
            ASTNode *iter = parse_expression(p);
            ASTNode *filter = NULL;
            if (p_cur(p)->type == TOK_IF) {
                p_advance(p);
                filter = parse_expression(p);
            }
            p_expect(p, TOK_RBRACKET);
            ASTNode *n = make_node(AST_LISTCOMP, p_cur(p)->line);
            n->data.listcomp.expr = first;
            n->data.listcomp.var = xstrdup(var_tok->str_val);
            set_name_hash(n, n->data.listcomp.var);
            n->data.listcomp.iter = iter;
            n->data.listcomp.filter = filter;
            return n;
        }

        ASTNode **elems = xmalloc_array(MAX_LIST, sizeof(ASTNode*));
        int count = 0;
        elems[count++] = first;
        while (p_cur(p)->type == TOK_COMMA) {
            p_advance(p);
            if (p_cur(p)->type == TOK_RBRACKET) break;
            if (count >= MAX_LIST) {
                fprintf(stderr, "Parse error line %d: list literal exceeds %d elements\n", p_cur(p)->line, MAX_LIST);
                g_parse_errors++;
                break;
            }
            elems[count++] = parse_expression(p);
        }
        p_expect(p, TOK_RBRACKET);

        ASTNode *n = make_node(AST_LIST, p_cur(p)->line);
        n->data.list.elems = elems;
        n->data.list.count = count;

        while (p_cur(p)->type == TOK_LBRACKET) {
            n = parse_subscript_suffix(p, n);
        }
        return n;
    }

    /* Dict literal: {"key": value, ...} */
    if (t->type == TOK_LBRACE) {
        p_advance(p);
        ASTNode **keys = xmalloc_array(MAX_LIST, sizeof(ASTNode*));
        ASTNode **vals = xmalloc_array(MAX_LIST, sizeof(ASTNode*));
        int count = 0;
        if (p_cur(p)->type != TOK_RBRACE) {
            keys[count] = parse_expression(p);
            p_expect(p, TOK_COLON);
            vals[count] = parse_expression(p);
            count++;
            while (p_cur(p)->type == TOK_COMMA) {
                p_advance(p);
                if (p_cur(p)->type == TOK_RBRACE) break;
                if (count >= MAX_LIST) {
                    fprintf(stderr, "Parse error line %d: dict literal exceeds %d entries\n", p_cur(p)->line, MAX_LIST);
                    g_parse_errors++;
                    break;
                }
                keys[count] = parse_expression(p);
                p_expect(p, TOK_COLON);
                vals[count] = parse_expression(p);
                count++;
            }
        }
        p_expect(p, TOK_RBRACE);
        ASTNode *n = make_node(AST_DICT, p_cur(p)->line);
        n->data.dict.keys = keys;
        n->data.dict.vals = vals;
        n->data.dict.count = count;
        /* Handle postfix .key and [idx] */
        while (p_cur(p)->type == TOK_DOT || p_cur(p)->type == TOK_LBRACKET) {
            if (p_cur(p)->type == TOK_DOT) {
                p_advance(p);
                Token *key_tok = p_cur(p);
                p_expect(p, TOK_IDENT);
                ASTNode *dot = make_node(AST_DOT, p_cur(p)->line);
                dot->data.dot.target = n;
                dot->data.dot.key = xstrdup(key_tok->str_val);
                set_name_hash(dot, dot->data.dot.key);
                n = dot;
            } else {
                n = parse_subscript_suffix(p, n);
            }
        }
        return n;
    }

    ASTNode *n = make_node(AST_NULL, p_cur(p)->line);
    if (t->type != TOK_EOF && t->type != TOK_NEWLINE && t->type != TOK_DEDENT) {
        g_parse_errors++;
        p_advance(p);
    }
    return n;
}

static ASTNode* parse_unary(Parser *p);

static ASTNode* parse_relation(Parser *p) {
    ASTNode *left = parse_primary(p);

    if (p_cur(p)->type == TOK_OF) {
        p_advance(p);
        /* RHS is a single unary-or-tighter expression. This preserves
         * `f of -x` (unary minus) and right-associative `f of g of x`
         * (unary falls through to relation), but stops `of` from
         * absorbing trailing infix arithmetic: `len of xs - 1` now
         * parses as `(len of xs) - 1`, not `len of (xs - 1)`. */
        ASTNode *right = parse_unary(p);
        ASTNode *n = make_node(AST_RELATION, p_cur(p)->line);
        n->data.relation.left = left;
        n->data.relation.right = right;
        return n;
    }

    return left;
}

static ASTNode* parse_unary(Parser *p) {
    if (p_cur(p)->type == TOK_MINUS) {
        p_advance(p);
        ASTNode *operand = parse_unary(p);
        ASTNode *n = make_node(AST_UNARY, p_cur(p)->line);
        snprintf(n->data.unary.op, sizeof(n->data.unary.op), "-");
        n->data.unary.operand = operand;
        return n;
    }
    if (p_cur(p)->type == TOK_NOT) {
        p_advance(p);
        ASTNode *operand = parse_unary(p);
        ASTNode *n = make_node(AST_UNARY, p_cur(p)->line);
        snprintf(n->data.unary.op, sizeof(n->data.unary.op), "not");
        n->data.unary.operand = operand;
        return n;
    }
    if (p_cur(p)->type == TOK_TILDE) {
        p_advance(p);
        ASTNode *operand = parse_unary(p);
        ASTNode *n = make_node(AST_UNARY, p_cur(p)->line);
        snprintf(n->data.unary.op, sizeof(n->data.unary.op), "~");
        n->data.unary.operand = operand;
        return n;
    }
    return parse_relation(p);
}

static ASTNode* parse_multiply(Parser *p) {
    ASTNode *left = parse_unary(p);
    while (p_cur(p)->type == TOK_STAR || p_cur(p)->type == TOK_SLASH || p_cur(p)->type == TOK_PERCENT) {
        char op[4] = {0};
        if (p_cur(p)->type == TOK_STAR) op[0] = '*';
        else if (p_cur(p)->type == TOK_SLASH) op[0] = '/';
        else op[0] = '%';
        p_advance(p);
        ASTNode *right = parse_unary(p);
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
        snprintf(n->data.binop.op, sizeof(n->data.binop.op), "%s", op);
        n->data.binop.left = left;
        n->data.binop.right = right;
        left = n;
    }
    return left;
}

static ASTNode* parse_addition(Parser *p) {
    ASTNode *left = parse_multiply(p);
    while (p_cur(p)->type == TOK_PLUS || p_cur(p)->type == TOK_MINUS) {
        char op[4] = {0};
        op[0] = (p_cur(p)->type == TOK_PLUS) ? '+' : '-';
        p_advance(p);
        ASTNode *right = parse_multiply(p);
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
        snprintf(n->data.binop.op, sizeof(n->data.binop.op), "%s", op);
        n->data.binop.left = left;
        n->data.binop.right = right;
        left = n;
    }
    return left;
}

static ASTNode* parse_shift(Parser *p) {
    ASTNode *left = parse_addition(p);
    while (p_cur(p)->type == TOK_SHL || p_cur(p)->type == TOK_SHR) {
        char op[4] = {0};
        if (p_cur(p)->type == TOK_SHL) { op[0] = '<'; op[1] = '<'; }
        else { op[0] = '>'; op[1] = '>'; }
        p_advance(p);
        ASTNode *right = parse_addition(p);
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
        snprintf(n->data.binop.op, sizeof(n->data.binop.op), "%s", op);
        n->data.binop.left = left;
        n->data.binop.right = right;
        left = n;
    }
    return left;
}

static ASTNode* parse_bitand(Parser *p) {
    ASTNode *left = parse_shift(p);
    while (p_cur(p)->type == TOK_AMP) {
        p_advance(p);
        ASTNode *right = parse_shift(p);
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
        snprintf(n->data.binop.op, sizeof(n->data.binop.op), "&");
        n->data.binop.left = left;
        n->data.binop.right = right;
        left = n;
    }
    return left;
}

static ASTNode* parse_bitxor(Parser *p) {
    ASTNode *left = parse_bitand(p);
    while (p_cur(p)->type == TOK_CARET) {
        p_advance(p);
        ASTNode *right = parse_bitand(p);
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
        snprintf(n->data.binop.op, sizeof(n->data.binop.op), "^");
        n->data.binop.left = left;
        n->data.binop.right = right;
        left = n;
    }
    return left;
}

static ASTNode* parse_bitor(Parser *p) {
    ASTNode *left = parse_bitxor(p);
    while (p_cur(p)->type == TOK_BITOR) {
        p_advance(p);
        ASTNode *right = parse_bitxor(p);
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
        snprintf(n->data.binop.op, sizeof(n->data.binop.op), "|");
        n->data.binop.left = left;
        n->data.binop.right = right;
        left = n;
    }
    return left;
}

static ASTNode* parse_comparison(Parser *p) {
    ASTNode *left = parse_bitor(p);
    TokType tt = p_cur(p)->type;
    if (tt == TOK_LT || tt == TOK_GT || tt == TOK_LE || tt == TOK_GE || tt == TOK_EQ || tt == TOK_NE) {
        char op[4] = {0};
        switch (tt) {
            case TOK_LT: snprintf(op, sizeof(op), "<"); break;
            case TOK_GT: snprintf(op, sizeof(op), ">"); break;
            case TOK_LE: snprintf(op, sizeof(op), "<="); break;
            case TOK_GE: snprintf(op, sizeof(op), ">="); break;
            case TOK_EQ: snprintf(op, sizeof(op), "="); break;
            case TOK_NE: snprintf(op, sizeof(op), "!="); break;
            default: break;
        }
        p_advance(p);
        ASTNode *right = parse_bitor(p);
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
        snprintf(n->data.binop.op, sizeof(n->data.binop.op), "%s", op);
        n->data.binop.left = left;
        n->data.binop.right = right;
        return n;
    }
    return left;
}

static ASTNode* parse_and(Parser *p) {
    ASTNode *left = parse_comparison(p);
    while (p_cur(p)->type == TOK_AND) {
        p_advance(p);
        ASTNode *right = parse_comparison(p);
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
        snprintf(n->data.binop.op, sizeof(n->data.binop.op), "and");
        n->data.binop.left = left;
        n->data.binop.right = right;
        left = n;
    }
    return left;
}

static ASTNode* parse_or(Parser *p) {
    ASTNode *left = parse_and(p);
    while (p_cur(p)->type == TOK_OR) {
        p_advance(p);
        ASTNode *right = parse_and(p);
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
        snprintf(n->data.binop.op, sizeof(n->data.binop.op), "or");
        n->data.binop.left = left;
        n->data.binop.right = right;
        left = n;
    }
    return left;
}

static ASTNode* parse_pipe(Parser *p) {
    ASTNode *left = parse_or(p);
    while (p_cur(p)->type == TOK_PIPE) {
        p_advance(p);
        ASTNode *fn = parse_or(p);
        /* a |> b desugars to b of a */
        ASTNode *n = make_node(AST_RELATION, p_cur(p)->line);
        n->data.relation.left = fn;
        n->data.relation.right = left;
        left = n;
    }
    return left;
}

static ASTNode* parse_expression(Parser *p) {
    if (g_parse_depth >= PARSE_MAX_DEPTH) {
        fprintf(stderr, "Parse error line %d: expression nesting too deep\n",
                p_cur(p)->line);
        g_parse_errors++;
        return make_node(AST_NULL, p_cur(p)->line);
    }
    g_parse_depth++;
    ASTNode *r = parse_pipe(p);
    g_parse_depth--;
    return r;
}

static ASTNode* parse_statement(Parser *p) {
    p_skip_newlines(p);
    Token *t = p_cur(p);

    if (t->type == TOK_EOF || t->type == TOK_DEDENT) return NULL;

    if (t->type == TOK_DEFINE) {
        p_advance(p);
        Token *name_tok = p_cur(p);
        p_expect(p, TOK_IDENT);

        /* Parse optional named parameters: define add(a, b) as:
         * Each param may carry a default: define f(a, b is 10): */
        char **params = NULL;
        ASTNode **defaults = NULL;
        int param_count = 0;
        int first_default = -1;
        if (p_cur(p)->type == TOK_LPAREN) {
            p_advance(p); /* skip ( */
            params = xmalloc_array(16, sizeof(char*));
            defaults = xcalloc(16, sizeof(ASTNode*));
            while (p_cur(p)->type == TOK_IDENT && param_count < 16) {
                int slot = param_count;
                params[param_count++] = xstrdup(p_cur(p)->str_val);
                p_advance(p);
                if (p_cur(p)->type == TOK_IS) {
                    p_advance(p);
                    defaults[slot] = parse_expression(p);
                    if (first_default < 0) first_default = slot;
                } else if (first_default >= 0) {
                    fprintf(stderr,
                        "Parse error line %d: required parameter '%s' cannot follow a parameter with a default\n",
                        p_cur(p)->line, params[slot]);
                    g_parse_errors++;
                }
                if (p_cur(p)->type == TOK_COMMA) p_advance(p);
            }
            p_expect(p, TOK_RPAREN);
        }
        if (param_count == 0) {
            /* No explicit params: default to single param "n" */
            free(params);
            free(defaults);
            params = xmalloc(sizeof(char*));
            params[0] = xstrdup("n");
            defaults = xcalloc(1, sizeof(ASTNode*));
            param_count = 1;
        }
        if (first_default < 0) first_default = param_count;

        if (p_cur(p)->type == TOK_AS) p_advance(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int body_count;
        ASTNode **body = parse_block(p, &body_count);
        ASTNode *n = make_node(AST_FUNC, p_cur(p)->line);
        n->data.func.name = xstrdup((name_tok && name_tok->str_val) ? name_tok->str_val : "");
        set_name_hash(n, n->data.func.name);
        n->data.func.params = params;
        n->data.func.param_defaults = defaults;
        n->data.func.param_count = param_count;
        n->data.func.first_default = first_default;
        n->data.func.body = body;
        n->data.func.body_count = body_count;
        return n;
    }

    if (t->type == TOK_TRY) {
        p_advance(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int try_count;
        ASTNode **try_body = parse_block(p, &try_count);
        p_skip_newlines(p);
        /* Expect: catch err_name: */
        p_expect(p, TOK_CATCH);
        Token *err_tok = p_cur(p);
        char *err_name = "err";
        if (err_tok->type == TOK_IDENT) {
            err_name = err_tok->str_val;
            p_advance(p);
        }
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int catch_count;
        ASTNode **catch_body = parse_block(p, &catch_count);
        ASTNode *n = make_node(AST_TRY, t->line);
        n->data.trycatch.try_body = try_body;
        n->data.trycatch.try_count = try_count;
        n->data.trycatch.err_name = xstrdup(err_name);
        set_name_hash(n, n->data.trycatch.err_name);
        n->data.trycatch.catch_body = catch_body;
        n->data.trycatch.catch_count = catch_count;
        return n;
    }

    if (t->type == TOK_MATCH) {
        p_advance(p);
        ASTNode *expr = parse_expression(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        p_expect(p, TOK_INDENT);
        p_skip_newlines(p);

        /* Parse case branches */
        ASTNode **patterns = xmalloc_array(64, sizeof(ASTNode*));
        ASTNode ***bodies = xmalloc_array(64, sizeof(ASTNode**));
        int *body_counts = xmalloc_array(64, sizeof(int));
        int case_count = 0;

        while (p_cur(p)->type == TOK_CASE && case_count < 64) {
            p_advance(p); /* skip 'case' */
            /* Parse pattern — _ is wildcard (null pattern) */
            ASTNode *pattern = NULL;
            if (p_cur(p)->type == TOK_IDENT && p_cur(p)->str_val &&
                strcmp(p_cur(p)->str_val, "_") == 0) {
                p_advance(p); /* wildcard */
            } else {
                pattern = parse_expression(p);
            }
            p_expect(p, TOK_COLON);
            p_skip_newlines(p);

            int bc;
            ASTNode **body = parse_block(p, &bc);

            patterns[case_count] = pattern;
            bodies[case_count] = body;
            body_counts[case_count] = bc;
            case_count++;
            p_skip_newlines(p);
        }

        if (p_cur(p)->type == TOK_DEDENT) p_advance(p);

        ASTNode *n = make_node(AST_MATCH, t->line);
        n->data.match.expr = expr;
        n->data.match.patterns = patterns;
        n->data.match.bodies = bodies;
        n->data.match.body_counts = body_counts;
        n->data.match.case_count = case_count;
        return n;
    }

    if (t->type == TOK_IF) {
        p_advance(p);
        ASTNode *cond = parse_expression(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int if_count;
        ASTNode **if_body = parse_block(p, &if_count);
        ASTNode **else_body = NULL;
        int else_count = 0;
        p_skip_newlines(p);
        if (p_cur(p)->type == TOK_ELIF) {
            /* Treat elif as: else { if ... } — rewrite token and recurse */
            p_cur(p)->type = TOK_IF;
            else_body = xmalloc(sizeof(ASTNode*));
            else_body[0] = parse_statement(p);
            else_count = 1;
        } else if (p_cur(p)->type == TOK_ELSE) {
            p_advance(p);
            p_expect(p, TOK_COLON);
            p_skip_newlines(p);
            else_body = parse_block(p, &else_count);
        }
        ASTNode *n = make_node(AST_IF, p_cur(p)->line);
        n->data.cond.cond = cond;
        n->data.cond.if_body = if_body;
        n->data.cond.if_count = if_count;
        n->data.cond.else_body = else_body;
        n->data.cond.else_count = else_count;
        return n;
    }

    if (t->type == TOK_LOOP) {
        p_advance(p);
        if (p_cur(p)->type == TOK_WHILE) p_advance(p);
        ASTNode *cond = parse_expression(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int body_count;
        ASTNode **body = parse_block(p, &body_count);
        ASTNode *n = make_node(AST_LOOP, p_cur(p)->line);
        n->data.loop.cond = cond;
        n->data.loop.body = body;
        n->data.loop.body_count = body_count;
        return n;
    }

    if (t->type == TOK_UNOBSERVED) {
        p_advance(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int body_count;
        ASTNode **body = parse_block(p, &body_count);
        ASTNode *n = make_node(AST_UNOBSERVED, t->line);
        n->data.block.stmts = body;
        n->data.block.count = body_count;
        return n;
    }

    if (t->type == TOK_FOR) {
        p_advance(p);
        Token *var_tok = p_cur(p);
        p_expect(p, TOK_IDENT);
        p_expect(p, TOK_IN);
        ASTNode *iter = parse_expression(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int body_count;
        ASTNode **body = parse_block(p, &body_count);
        ASTNode *n = make_node(AST_FOR, p_cur(p)->line);
        n->data.forloop.var = xstrdup((var_tok && var_tok->str_val) ? var_tok->str_val : "");
        set_name_hash(n, n->data.forloop.var);
        n->data.forloop.iter = iter;
        n->data.forloop.body = body;
        n->data.forloop.body_count = body_count;
        return n;
    }

    if (t->type == TOK_RETURN) {
        p_advance(p);
        ASTNode *expr = parse_expression(p);
        p_match(p, TOK_NEWLINE);
        ASTNode *n = make_node(AST_RETURN, p_cur(p)->line);
        n->data.ret.expr = expr;
        return n;
    }

    if (t->type == TOK_IMPORT) {
        p_advance(p);
        Token *name_tok = p_cur(p);
        p_expect(p, TOK_IDENT);
        ASTNode *n = make_node(AST_IMPORT, t->line);
        n->data.import.module_name = xstrdup(name_tok->str_val);
        set_name_hash(n, n->data.import.module_name);
        return n;
    }

    if (t->type == TOK_BREAK) {
        p_advance(p);
        return make_node(AST_BREAK, t->line);
    }

    if (t->type == TOK_CONTINUE) {
        p_advance(p);
        return make_node(AST_CONTINUE, t->line);
    }

    /* Destructuring assignment: [a, b, c] is rhs (0.13.0).
     * Lookahead: bracket-count to find the matching ']' and check if the
     * next token is 'is'. If so, we're committed to a destructure pattern
     * and emit destructure-specific errors instead of falling through to
     * list-literal expression parsing (issue #157). */
    if (t->type == TOK_LBRACKET) {
        int is_destructure = 0;
        {
            int i = p->pos + 1;
            int depth = 0;
            while (i < p->tl->count) {
                TokType tt = p->tl->tokens[i].type;
                if (tt == TOK_LBRACKET) depth++;
                else if (tt == TOK_RBRACKET) {
                    if (depth == 0) {
                        if (i + 1 < p->tl->count &&
                            p->tl->tokens[i+1].type == TOK_IS)
                            is_destructure = 1;
                        break;
                    }
                    depth--;
                } else if (tt == TOK_EOF) {
                    break;
                }
                i++;
            }
        }
        if (is_destructure) {
            int line = t->line;
            p_advance(p); /* skip '[' */
            int n = 0;
            char *names_tmp[64];
            for (;;) {
                if (p_cur(p)->type != TOK_IDENT) {
                    fprintf(stderr,
                        "Parse error line %d: destructuring pattern requires "
                        "identifiers (index/field targets like a[0] or a.x "
                        "are not supported)\n", p_cur(p)->line);
                    g_parse_errors++;
                    for (int k = 0; k < n; k++) free(names_tmp[k]);
                    while (p_cur(p)->type != TOK_NEWLINE &&
                           p_cur(p)->type != TOK_EOF) p_advance(p);
                    return make_node(AST_NULL, line);
                }
                if (n >= 64) {
                    fprintf(stderr,
                        "Parse error line %d: destructuring pattern exceeds "
                        "64 names\n", p_cur(p)->line);
                    g_parse_errors++;
                    for (int k = 0; k < n; k++) free(names_tmp[k]);
                    while (p_cur(p)->type != TOK_NEWLINE &&
                           p_cur(p)->type != TOK_EOF) p_advance(p);
                    return make_node(AST_NULL, line);
                }
                names_tmp[n++] = xstrdup(p_cur(p)->str_val);
                p_advance(p);
                if (p_cur(p)->type == TOK_RBRACKET) break;
                if (p_cur(p)->type == TOK_COMMA) {
                    p_advance(p);
                    if (p_cur(p)->type == TOK_RBRACKET) {
                        fprintf(stderr,
                            "Parse error line %d: trailing comma in "
                            "destructuring pattern\n", p_cur(p)->line);
                        g_parse_errors++;
                        for (int k = 0; k < n; k++) free(names_tmp[k]);
                        while (p_cur(p)->type != TOK_NEWLINE &&
                               p_cur(p)->type != TOK_EOF) p_advance(p);
                        return make_node(AST_NULL, line);
                    }
                    continue;
                }
                if (p_cur(p)->type == TOK_LBRACKET ||
                    p_cur(p)->type == TOK_DOT) {
                    fprintf(stderr,
                        "Parse error line %d: destructuring pattern "
                        "requires identifiers (index/field targets like "
                        "a[0] or a.x are not supported)\n",
                        p_cur(p)->line);
                } else {
                    fprintf(stderr,
                        "Parse error line %d: expected ',' or ']' in "
                        "destructuring pattern, got %s\n",
                        p_cur(p)->line, tok_type_name(p_cur(p)->type));
                }
                g_parse_errors++;
                for (int k = 0; k < n; k++) free(names_tmp[k]);
                while (p_cur(p)->type != TOK_NEWLINE &&
                       p_cur(p)->type != TOK_EOF) p_advance(p);
                return make_node(AST_NULL, line);
            }
            p_advance(p); /* skip ']' */
            p_advance(p); /* skip 'is' (scan verified) */
            ASTNode *rhs = parse_expression(p);
            p_match(p, TOK_NEWLINE);
            ASTNode *node = make_node(AST_LIST_PATTERN_ASSIGN, line);
            node->data.list_pattern_assign.name_count = n;
            node->data.list_pattern_assign.names = xmalloc_array(n, sizeof(char*));
            node->data.list_pattern_assign.name_hashes = xmalloc_array(n, sizeof(uint32_t));
            for (int k = 0; k < n; k++) {
                node->data.list_pattern_assign.names[k] = names_tmp[k];
                node->data.list_pattern_assign.name_hashes[k] = env_name_hash(names_tmp[k]);
            }
            node->data.list_pattern_assign.expr = rhs;
            return node;
        }
    }

    /* Dot-assignment: config.name is "value", items[0].name is "value" */
    if (t->type == TOK_IDENT && (p_peek(p, 1)->type == TOK_DOT || p_peek(p, 1)->type == TOK_LBRACKET)) {
        /* Look ahead to see if this ends in IS (assignment) */
        int saved = p->pos;
        ASTNode *target = parse_primary(p);
        if (target->type == AST_DOT && (p_cur(p)->type == TOK_IS || is_compound_assign(p_cur(p)->type))) {
            int compound = is_compound_assign(p_cur(p)->type);
            char cop[4];
            if (compound) compound_to_op(p_cur(p)->type, cop);
            p_advance(p); /* skip IS or compound op */
            ASTNode *rhs = parse_expression(p);
            if (compound) {
                /* Desugar obj.f += expr → obj.f is obj.f + expr */
                ASTNode *read = make_node(AST_DOT, t->line);
                read->data.dot.target = clone_ast(target->data.dot.target);
                read->data.dot.key = xstrdup(target->data.dot.key);
                read->name_hash = target->name_hash;
                ASTNode *binop = make_node(AST_BINOP, t->line);
                memcpy(binop->data.binop.op, cop, 4);
                binop->data.binop.left = read;
                binop->data.binop.right = rhs;
                rhs = binop;
            }
            ASTNode *n = make_node(AST_DOT_ASSIGN, t->line);
            n->data.dot_assign.target = target->data.dot.target;
            n->data.dot_assign.key = xstrdup(target->data.dot.key);
            n->name_hash = target->name_hash;
            n->data.dot_assign.expr = rhs;
            free(target->data.dot.key);
            free(target);
            return n;
        }
        /* Index-assignment: grid[0][1] is value, items[i] is value */
        if (target->type == AST_INDEX && (p_cur(p)->type == TOK_IS || is_compound_assign(p_cur(p)->type))) {
            int compound = is_compound_assign(p_cur(p)->type);
            char cop[4] = {0};
            if (compound) compound_to_op(p_cur(p)->type, cop);
            p_advance(p); /* skip IS or compound op */
            ASTNode *rhs = parse_expression(p);
            ASTNode *n = make_node(AST_INDEX_ASSIGN, t->line);
            n->data.index_assign.target = target->data.index.target;
            n->data.index_assign.index = target->data.index.index;
            n->data.index_assign.expr = rhs;
            memcpy(n->data.index_assign.compound_op, cop, 4);
            free(target);
            return n;
        }
        /* Not a dot-assignment — restore and fall through */
        free_ast(target);
        p->pos = saved;
    }

    if (t->type == TOK_IDENT && (p_peek(p, 1)->type == TOK_IS || is_compound_assign(p_peek(p, 1)->type))) {
        Token *name_tok = p_advance(p);
        int compound = is_compound_assign(p_cur(p)->type);
        char cop[4];
        if (compound) compound_to_op(p_cur(p)->type, cop);
        p_advance(p);
        ASTNode *expr = parse_expression(p);
        if (compound) {
            /* Desugar x += expr → x is x + expr */
            ASTNode *ident = make_node(AST_IDENT, t->line);
            ident->data.ident.name = xstrdup(name_tok->str_val);
            set_name_hash(ident, ident->data.ident.name);
            ASTNode *binop = make_node(AST_BINOP, t->line);
            memcpy(binop->data.binop.op, cop, 4);
            binop->data.binop.left = ident;
            binop->data.binop.right = expr;
            expr = binop;
        }
        p_match(p, TOK_NEWLINE);
        ASTNode *n = make_node(AST_ASSIGN, p_cur(p)->line);
        n->data.assign.name = xstrdup((name_tok && name_tok->str_val) ? name_tok->str_val : "");
        set_name_hash(n, n->data.assign.name);
        n->data.assign.expr = expr;
        return n;
    }

    if (t->type == TOK_LOCAL) {
        Token *local_tok = p_advance(p);
        Token *name_tok = p_cur(p);
        p_expect(p, TOK_IDENT);
        p_expect(p, TOK_IS);
        ASTNode *expr = parse_expression(p);
        p_match(p, TOK_NEWLINE);

        ASTNode *n = make_node_col(AST_ASSIGN, local_tok->line, local_tok->col);
        n->data.assign.name = xstrdup((name_tok && name_tok->str_val) ? name_tok->str_val : "");
        n->data.assign.expr = expr;
        n->data.assign.local_only = 1;
        set_name_hash(n, n->data.assign.name);
        return n;
    }

    ASTNode *expr = parse_expression(p);
    p_match(p, TOK_NEWLINE);
    return expr;
}

ASTNode* parse(TokenList *tl) {
    Parser p;
    p.tl = tl;
    p.pos = 0;
    g_parse_depth = 0;  /* reset depth guard for this parse */

    ASTNode **stmts = xmalloc_array(MAX_STMTS, sizeof(ASTNode*));
    int count = 0;

    p_skip_newlines(&p);

    while (p_cur(&p)->type != TOK_EOF) {
        p_skip_newlines(&p);
        if (p_cur(&p)->type == TOK_EOF) break;
        int before = p.pos;
        ASTNode *stmt = parse_statement(&p);
        if (stmt && count < MAX_STMTS) {
            stmts[count++] = stmt;
        }
        if (p.pos == before) {
            g_parse_errors++;
            p_advance(&p);
        }
    }

    ASTNode *prog = make_node(AST_PROGRAM, p_cur(&p)->line);
    prog->data.program.stmts = stmts;
    prog->data.program.count = count;
    return prog;
}
