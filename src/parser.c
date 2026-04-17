/*
 * EigenScript parser. Recursive-descent AST construction from
 * the token stream produced by the lexer.
 */

#include "eigenscript.h"

/* Parse-error counter owned by eigenscript.c. */
extern int g_parse_errors;
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
        g_parse_errors++;
    }
    p_advance(p);
}

static void p_skip_newlines(Parser *p) {
    while (p_cur(p)->type == TOK_NEWLINE) p_advance(p);
}

ASTNode* make_node(ASTType type, int line) {
    ASTNode *n = xcalloc(1, sizeof(ASTNode));
    n->type = type;
    n->line = line;
    return n;
}

/* Recursively free an AST tree. */
/* Currently unreferenced: the tree-walker keeps AST nodes alive for the
 * lifetime of any function defined in them. Retained for future use and
 * because freeing ASTs with partial parses has edge cases. */
__attribute__((unused))
static void free_ast(ASTNode *node) {
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
            /* Don't free body — it's shared with the return wrapper created at eval time */
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
        case AST_BLOCK:
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
            break;
        default:
            /* AST_NUM, AST_NULL, AST_PREDICATE — no owned memory */
            break;
    }
    free(node);
}

static ASTNode* parse_expression(Parser *p);
static ASTNode* parse_statement(Parser *p);

static ASTNode** parse_block(Parser *p, int *count) {
    ASTNode **stmts = xmalloc_array(MAX_STMTS, sizeof(ASTNode*));
    *count = 0;

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

    return stmts;
}

static ASTNode* parse_primary(Parser *p) {
    Token *t = p_cur(p);

    if (t->type >= TOK_WHAT && t->type <= TOK_HOW) {
        int kind = t->type - TOK_WHAT;
        p_advance(p);
        if (p_cur(p)->type == TOK_IS) {
            p_advance(p);
            ASTNode *expr = parse_expression(p);
            ASTNode *n = make_node(AST_INTERROGATE, p_cur(p)->line);
            n->data.interrogate.kind = kind;
            n->data.interrogate.expr = expr;
            return n;
        }
        ASTNode *n = make_node(AST_IDENT, p_cur(p)->line);
        n->data.ident.name = xstrdup(t->str_val);
        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX, p_cur(p)->line);
            index_node->data.index.target = n;
            index_node->data.index.index = idx;
            n = index_node;
        }
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
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX, p_cur(p)->line);
            index_node->data.index.target = n;
            index_node->data.index.index = idx;
            n = index_node;
        }
        return n;
    }

    if (t->type == TOK_STR) {
        p_advance(p);
        ASTNode *n = make_node(AST_STR, p_cur(p)->line);
        n->data.str = xstrdup(t->str_val);
        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX, p_cur(p)->line);
            index_node->data.index.target = n;
            index_node->data.index.index = idx;
            n = index_node;
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
        while (p_cur(p)->type == TOK_LBRACKET || p_cur(p)->type == TOK_DOT) {
            if (p_cur(p)->type == TOK_DOT) {
                p_advance(p);
                Token *key_tok = p_cur(p);
                p_expect(p, TOK_IDENT);
                ASTNode *dot = make_node(AST_DOT, p_cur(p)->line);
                dot->data.dot.target = n;
                dot->data.dot.key = xstrdup(key_tok->str_val);
                n = dot;
            } else {
                p_advance(p);
                ASTNode *idx = parse_expression(p);
                p_expect(p, TOK_RBRACKET);
                ASTNode *index_node = make_node(AST_INDEX, p_cur(p)->line);
                index_node->data.index.target = n;
                index_node->data.index.index = idx;
                n = index_node;
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
            while (p->tl->tokens[scan].type == TOK_IDENT || p->tl->tokens[scan].type == TOK_COMMA)
                scan++;
            if (p->tl->tokens[scan].type == TOK_RPAREN && p->tl->tokens[scan+1].type == TOK_ARROW)
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
        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX, p_cur(p)->line);
            index_node->data.index.target = expr;
            index_node->data.index.index = idx;
            expr = index_node;
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
            elems[count++] = parse_expression(p);
        }
        p_expect(p, TOK_RBRACKET);

        ASTNode *n = make_node(AST_LIST, p_cur(p)->line);
        n->data.list.elems = elems;
        n->data.list.count = count;

        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX, p_cur(p)->line);
            index_node->data.index.target = n;
            index_node->data.index.index = idx;
            n = index_node;
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
                n = dot;
            } else {
                p_advance(p);
                ASTNode *idx = parse_expression(p);
                p_expect(p, TOK_RBRACKET);
                ASTNode *index_node = make_node(AST_INDEX, p_cur(p)->line);
                index_node->data.index.target = n;
                index_node->data.index.index = idx;
                n = index_node;
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

static ASTNode* parse_addition(Parser *p);

static ASTNode* parse_relation(Parser *p) {
    ASTNode *left = parse_primary(p);

    if (p_cur(p)->type == TOK_OF) {
        p_advance(p);
        ASTNode *right = parse_addition(p);
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

static ASTNode* parse_comparison(Parser *p) {
    ASTNode *left = parse_addition(p);
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
        ASTNode *right = parse_addition(p);
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
    return parse_pipe(p);
}

static ASTNode* parse_statement(Parser *p) {
    p_skip_newlines(p);
    Token *t = p_cur(p);

    if (t->type == TOK_EOF || t->type == TOK_DEDENT) return NULL;

    if (t->type == TOK_DEFINE) {
        p_advance(p);
        Token *name_tok = p_cur(p);
        p_expect(p, TOK_IDENT);

        /* Parse optional named parameters: define add(a, b) as: */
        char **params = NULL;
        int param_count = 0;
        if (p_cur(p)->type == TOK_LPAREN) {
            p_advance(p); /* skip ( */
            params = xmalloc_array(16, sizeof(char*));
            while (p_cur(p)->type == TOK_IDENT && param_count < 16) {
                params[param_count++] = xstrdup(p_cur(p)->str_val);
                p_advance(p);
                if (p_cur(p)->type == TOK_COMMA) p_advance(p);
            }
            p_expect(p, TOK_RPAREN);
        }
        if (param_count == 0) {
            /* No explicit params: default to single param "n" */
            params = xmalloc(sizeof(char*));
            params[0] = xstrdup("n");
            param_count = 1;
        }

        if (p_cur(p)->type == TOK_AS) p_advance(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int body_count;
        ASTNode **body = parse_block(p, &body_count);
        ASTNode *n = make_node(AST_FUNC, p_cur(p)->line);
        n->data.func.name = xstrdup((name_tok && name_tok->str_val) ? name_tok->str_val : "");
        n->data.func.params = params;
        n->data.func.param_count = param_count;
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

    /* Dot-assignment: config.name is "value" */
    if (t->type == TOK_IDENT && p_peek(p, 1)->type == TOK_DOT) {
        /* Look ahead to see if this ends in IS (assignment) */
        int saved = p->pos;
        ASTNode *target = parse_primary(p);
        if (target->type == AST_DOT && p_cur(p)->type == TOK_IS) {
            p_advance(p); /* skip IS */
            ASTNode *expr = parse_expression(p);
            ASTNode *n = make_node(AST_DOT_ASSIGN, t->line);
            n->data.dot_assign.target = target->data.dot.target;
            n->data.dot_assign.key = xstrdup(target->data.dot.key);
            n->data.dot_assign.expr = expr;
            return n;
        }
        /* Not a dot-assignment — restore and fall through */
        p->pos = saved;
    }

    if (t->type == TOK_IDENT && p_peek(p, 1)->type == TOK_IS) {
        Token *name_tok = p_advance(p);
        p_advance(p);
        ASTNode *expr = parse_expression(p);
        p_match(p, TOK_NEWLINE);
        ASTNode *n = make_node(AST_ASSIGN, p_cur(p)->line);
        n->data.assign.name = xstrdup((name_tok && name_tok->str_val) ? name_tok->str_val : "");
        n->data.assign.expr = expr;
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
