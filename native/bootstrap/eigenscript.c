/*
 * EigenScript Native Bootstrap Runtime
 * Complete implementation: tokenizer + parser + evaluator + builtins + HTTP server
 * Compiles with: gcc -O2 -o eigenscript eigenscript.c -lm -lpthread
 */

#include "eigenscript.h"
#include <pthread.h>

Server g_server = {0};
static volatile int g_init_complete = 0;
static pthread_t g_health_tid;
static int g_health_thread_active = 0;

void* health_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    printf("[health-thread] Started on fd=%d, pid=%d\n", fd, getpid());
    fflush(stdout);
    int req_count = 0;
    while (!g_init_complete) {
        struct sockaddr_in client;
        socklen_t len = sizeof(client);
        int conn = accept(fd, (struct sockaddr*)&client, &len);
        if (conn < 0) {
            printf("[health-thread] accept() failed: errno=%d\n", errno);
            fflush(stdout);
            break;
        }
        if (g_init_complete) { close(conn); break; }
        char buf[1024];
        recv(conn, buf, sizeof(buf), 0);
        const char *resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\n\r\nOK";
        send(conn, resp, strlen(resp), 0);
        close(conn);
        req_count++;
        printf("[health-thread] Served health check #%d\n", req_count);
        fflush(stdout);
    }
    printf("[health-thread] Exiting after %d requests\n", req_count);
    fflush(stdout);
    return NULL;
}
jmp_buf g_return_buf;
Value *g_return_val = NULL;
int g_returning = 0;
TransformerModel g_model = {0};
PGconn *g_db_conn = NULL;
static char g_auth_token[128] = {0};
static double g_computation_cost = 0.0;

/* ================================================================
 * VALUE CONSTRUCTORS
 * ================================================================ */

Value* make_num(double n) {
    Value *v = calloc(1, sizeof(Value));
    v->type = VAL_NUM;
    v->data.num = n;
    return v;
}

Value* make_str(const char *s) {
    Value *v = calloc(1, sizeof(Value));
    v->type = VAL_STR;
    v->data.str = strdup(s ? s : "");
    return v;
}

Value* make_null(void) {
    Value *v = calloc(1, sizeof(Value));
    v->type = VAL_NULL;
    return v;
}

Value* make_list(int capacity) {
    Value *v = calloc(1, sizeof(Value));
    v->type = VAL_LIST;
    v->data.list.capacity = capacity < 8 ? 8 : capacity;
    v->data.list.items = calloc(v->data.list.capacity, sizeof(Value*));
    v->data.list.count = 0;
    return v;
}

Value* make_fn(const char *name, const char *param, ASTNode **body, int body_count, Env *closure) {
    Value *v = calloc(1, sizeof(Value));
    v->type = VAL_FN;
    v->data.fn.name = strdup(name ? name : "");
    v->data.fn.param = strdup(param ? param : "n");
    v->data.fn.body = body;
    v->data.fn.body_count = body_count;
    v->data.fn.closure = closure;
    return v;
}

Value* make_builtin(BuiltinFn fn) {
    Value *v = calloc(1, sizeof(Value));
    v->type = VAL_BUILTIN;
    v->data.builtin = fn;
    return v;
}

void list_append(Value *list, Value *item) {
    if (!list || list->type != VAL_LIST) return;
    if (list->data.list.count >= list->data.list.capacity) {
        int new_cap = list->data.list.capacity * 2;
        list->data.list.items = realloc(list->data.list.items, new_cap * sizeof(Value*));
        list->data.list.capacity = new_cap;
    }
    list->data.list.items[list->data.list.count++] = item;
}

int is_truthy(Value *v) {
    if (!v) return 0;
    switch (v->type) {
        case VAL_NULL: return 0;
        case VAL_NUM: return v->data.num != 0.0;
        case VAL_STR: return v->data.str && v->data.str[0] != '\0';
        case VAL_LIST: return v->data.list.count > 0;
        case VAL_FN: return 1;
        case VAL_BUILTIN: return 1;
    }
    return 0;
}

char* value_to_string(Value *v) {
    if (!v) return strdup("null");
    char buf[256];
    switch (v->type) {
        case VAL_NULL: return strdup("null");
        case VAL_NUM: {
            double n = v->data.num;
            if (n == (long long)n && fabs(n) < 1e15)
                snprintf(buf, sizeof(buf), "%lld", (long long)n);
            else
                snprintf(buf, sizeof(buf), "%.6g", n);
            return strdup(buf);
        }
        case VAL_STR: return strdup(v->data.str);
        case VAL_LIST: {
            char *result = malloc(MAX_STR);
            int pos = 0;
            pos += snprintf(result + pos, MAX_STR - pos, "[");
            for (int i = 0; i < v->data.list.count; i++) {
                if (i > 0) pos += snprintf(result + pos, MAX_STR - pos, ", ");
                char *s = value_to_string(v->data.list.items[i]);
                if (v->data.list.items[i] && v->data.list.items[i]->type == VAL_STR)
                    pos += snprintf(result + pos, MAX_STR - pos, "\"%s\"", s);
                else
                    pos += snprintf(result + pos, MAX_STR - pos, "%s", s);
                free(s);
            }
            pos += snprintf(result + pos, MAX_STR - pos, "]");
            return result;
        }
        case VAL_FN: snprintf(buf, sizeof(buf), "<fn %s>", v->data.fn.name); return strdup(buf);
        case VAL_BUILTIN: return strdup("<builtin>");
    }
    return strdup("?");
}

/* ================================================================
 * ENVIRONMENT
 * ================================================================ */

Env* env_new(Env *parent) {
    Env *e = calloc(1, sizeof(Env));
    e->parent = parent;
    e->count = 0;
    return e;
}

void env_set(Env *env, const char *name, Value *val) {
    Env *e = env;
    while (e) {
        for (int i = 0; i < e->count; i++) {
            if (strcmp(e->names[i], name) == 0) {
                e->values[i] = val;
                return;
            }
        }
        e = e->parent;
    }
    env_set_local(env, name, val);
}

void env_set_local(Env *env, const char *name, Value *val) {
    for (int i = 0; i < env->count; i++) {
        if (strcmp(env->names[i], name) == 0) {
            env->values[i] = val;
            return;
        }
    }
    if (env->count < MAX_VARS) {
        env->names[env->count] = strdup(name);
        env->values[env->count] = val;
        env->count++;
    }
}

Value* env_get(Env *env, const char *name) {
    Env *e = env;
    while (e) {
        for (int i = 0; i < e->count; i++) {
            if (strcmp(e->names[i], name) == 0)
                return e->values[i];
        }
        e = e->parent;
    }
    return NULL;
}

/* ================================================================
 * TOKENIZER
 * ================================================================ */

static void tok_add(TokenList *tl, TokType type, double num, const char *str, int line) {
    if (tl->count >= tl->capacity) {
        tl->capacity *= 2;
        tl->tokens = realloc(tl->tokens, tl->capacity * sizeof(Token));
    }
    Token *t = &tl->tokens[tl->count++];
    t->type = type;
    t->num_val = num;
    t->str_val = str ? strdup(str) : NULL;
    t->line = line;
}

static TokType keyword_type(const char *word) {
    if (strcmp(word, "is") == 0) return TOK_IS;
    if (strcmp(word, "of") == 0) return TOK_OF;
    if (strcmp(word, "define") == 0) return TOK_DEFINE;
    if (strcmp(word, "as") == 0) return TOK_AS;
    if (strcmp(word, "if") == 0) return TOK_IF;
    if (strcmp(word, "else") == 0) return TOK_ELSE;
    if (strcmp(word, "loop") == 0) return TOK_LOOP;
    if (strcmp(word, "while") == 0) return TOK_WHILE;
    if (strcmp(word, "return") == 0) return TOK_RETURN;
    if (strcmp(word, "and") == 0) return TOK_AND;
    if (strcmp(word, "or") == 0) return TOK_OR;
    if (strcmp(word, "not") == 0) return TOK_NOT;
    if (strcmp(word, "for") == 0) return TOK_FOR;
    if (strcmp(word, "in") == 0) return TOK_IN;
    if (strcmp(word, "null") == 0) return TOK_NULL;
    if (strcmp(word, "what") == 0) return TOK_WHAT;
    if (strcmp(word, "who") == 0) return TOK_WHO;
    if (strcmp(word, "when") == 0) return TOK_WHEN;
    if (strcmp(word, "where") == 0) return TOK_WHERE;
    if (strcmp(word, "why") == 0) return TOK_WHY;
    if (strcmp(word, "how") == 0) return TOK_HOW;
    if (strcmp(word, "converged") == 0) return TOK_CONVERGED;
    if (strcmp(word, "stable") == 0) return TOK_STABLE;
    if (strcmp(word, "improving") == 0) return TOK_IMPROVING;
    if (strcmp(word, "oscillating") == 0) return TOK_OSCILLATING;
    if (strcmp(word, "diverging") == 0) return TOK_DIVERGING;
    if (strcmp(word, "equilibrium") == 0) return TOK_EQUILIBRIUM;
    return TOK_IDENT;
}

TokenList tokenize(const char *source) {
    TokenList tl;
    tl.capacity = MAX_TOKENS;
    tl.tokens = malloc(tl.capacity * sizeof(Token));
    tl.count = 0;

    int indent_stack[MAX_INDENT];
    int indent_top = 0;
    indent_stack[0] = 0;

    const char *p = source;
    int line = 1;
    int at_line_start = 1;

    while (*p) {
        if (at_line_start) {
            int spaces = 0;
            while (*p == ' ') { spaces++; p++; }
            if (*p == '\t') {
                while (*p == '\t') { spaces += 4; p++; }
                while (*p == ' ') { spaces++; p++; }
            }
            if (*p == '#') {
                while (*p && *p != '\n') p++;
                if (*p == '\n') { p++; line++; }
                continue;
            }
            if (*p == '\n') {
                p++; line++;
                continue;
            }
            if (*p == '\0') break;

            if (spaces > indent_stack[indent_top]) {
                indent_top++;
                indent_stack[indent_top] = spaces;
                tok_add(&tl, TOK_INDENT, 0, NULL, line);
            } else {
                while (indent_top > 0 && spaces < indent_stack[indent_top]) {
                    indent_top--;
                    tok_add(&tl, TOK_DEDENT, 0, NULL, line);
                }
            }
            at_line_start = 0;
        }

        if (*p == ' ' || *p == '\t') {
            p++;
            continue;
        }

        if (*p == '#') {
            while (*p && *p != '\n') p++;
            continue;
        }

        if (*p == '\n') {
            if (tl.count > 0 && tl.tokens[tl.count-1].type != TOK_NEWLINE
                && tl.tokens[tl.count-1].type != TOK_INDENT
                && tl.tokens[tl.count-1].type != TOK_DEDENT) {
                tok_add(&tl, TOK_NEWLINE, 0, NULL, line);
            }
            p++; line++;
            at_line_start = 1;
            continue;
        }

        if (*p == '"') {
            p++;
            char buf[MAX_STR];
            int bi = 0;
            while (*p && *p != '"' && bi < MAX_STR - 1) {
                if (*p == '\\') {
                    p++;
                    switch (*p) {
                        case 'n': buf[bi++] = '\n'; break;
                        case 't': buf[bi++] = '\t'; break;
                        case '\\': buf[bi++] = '\\'; break;
                        case '"': buf[bi++] = '"'; break;
                        default: buf[bi++] = *p; break;
                    }
                } else {
                    buf[bi++] = *p;
                }
                p++;
            }
            buf[bi] = '\0';
            if (*p == '"') p++;
            tok_add(&tl, TOK_STR, 0, buf, line);
            continue;
        }

        if (isdigit(*p) || (*p == '.' && isdigit(*(p+1)))) {
            char *end;
            double num = strtod(p, &end);
            p = end;
            tok_add(&tl, TOK_NUM, num, NULL, line);
            continue;
        }

        if (isalpha(*p) || *p == '_') {
            char word[256];
            int wi = 0;
            while ((isalnum(*p) || *p == '_') && wi < 255) {
                word[wi++] = *p++;
            }
            word[wi] = '\0';
            TokType tt = keyword_type(word);
            tok_add(&tl, tt, 0, word, line);
            continue;
        }

        switch (*p) {
            case '+': tok_add(&tl, TOK_PLUS, 0, NULL, line); p++; break;
            case '-': tok_add(&tl, TOK_MINUS, 0, NULL, line); p++; break;
            case '*': tok_add(&tl, TOK_STAR, 0, NULL, line); p++; break;
            case '/': tok_add(&tl, TOK_SLASH, 0, NULL, line); p++; break;
            case '%': tok_add(&tl, TOK_PERCENT, 0, NULL, line); p++; break;
            case '(': tok_add(&tl, TOK_LPAREN, 0, NULL, line); p++; break;
            case ')': tok_add(&tl, TOK_RPAREN, 0, NULL, line); p++; break;
            case '[': tok_add(&tl, TOK_LBRACKET, 0, NULL, line); p++; break;
            case ']': tok_add(&tl, TOK_RBRACKET, 0, NULL, line); p++; break;
            case ',': tok_add(&tl, TOK_COMMA, 0, NULL, line); p++; break;
            case ':': tok_add(&tl, TOK_COLON, 0, NULL, line); p++; break;
            case '.': tok_add(&tl, TOK_DOT, 0, NULL, line); p++; break;
            case '<':
                if (*(p+1) == '=') { tok_add(&tl, TOK_LE, 0, NULL, line); p += 2; }
                else { tok_add(&tl, TOK_LT, 0, NULL, line); p++; }
                break;
            case '>':
                if (*(p+1) == '=') { tok_add(&tl, TOK_GE, 0, NULL, line); p += 2; }
                else { tok_add(&tl, TOK_GT, 0, NULL, line); p++; }
                break;
            case '!':
                if (*(p+1) == '=') { tok_add(&tl, TOK_NE, 0, NULL, line); p += 2; }
                else { p++; }
                break;
            case '=':
                if (*(p+1) == '=') { tok_add(&tl, TOK_EQ, 0, NULL, line); p += 2; }
                else { tok_add(&tl, TOK_ASSIGN, 0, NULL, line); p++; }
                break;
            default:
                p++;
                break;
        }
    }

    while (indent_top > 0) {
        tok_add(&tl, TOK_DEDENT, 0, NULL, line);
        indent_top--;
    }

    if (tl.count > 0 && tl.tokens[tl.count-1].type != TOK_NEWLINE) {
        tok_add(&tl, TOK_NEWLINE, 0, NULL, line);
    }
    tok_add(&tl, TOK_EOF, 0, NULL, line);

    return tl;
}

/* ================================================================
 * PARSER
 * ================================================================ */

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
        fprintf(stderr, "Parse error line %d: expected token %d, got %d",
                p_cur(p)->line, type, p_cur(p)->type);
        if (p_cur(p)->str_val) fprintf(stderr, " ('%s')", p_cur(p)->str_val);
        fprintf(stderr, "\n");
    }
    p_advance(p);
}

static void p_skip_newlines(Parser *p) {
    while (p_cur(p)->type == TOK_NEWLINE) p_advance(p);
}

static ASTNode* make_node(ASTType type) {
    ASTNode *n = calloc(1, sizeof(ASTNode));
    n->type = type;
    return n;
}

static ASTNode* parse_expression(Parser *p);
static ASTNode* parse_statement(Parser *p);

static ASTNode** parse_block(Parser *p, int *count) {
    ASTNode **stmts = malloc(MAX_STMTS * sizeof(ASTNode*));
    *count = 0;

    p_expect(p, TOK_INDENT);
    p_skip_newlines(p);

    while (p_cur(p)->type != TOK_DEDENT && p_cur(p)->type != TOK_EOF) {
        p_skip_newlines(p);
        if (p_cur(p)->type == TOK_DEDENT || p_cur(p)->type == TOK_EOF) break;
        ASTNode *stmt = parse_statement(p);
        if (stmt && *count < MAX_STMTS) {
            stmts[(*count)++] = stmt;
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
            ASTNode *n = make_node(AST_INTERROGATE);
            n->data.interrogate.kind = kind;
            n->data.interrogate.expr = expr;
            return n;
        }
        ASTNode *n = make_node(AST_IDENT);
        n->data.ident.name = strdup(t->str_val);
        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX);
            index_node->data.index.target = n;
            index_node->data.index.index = idx;
            n = index_node;
        }
        return n;
    }

    if (t->type >= TOK_CONVERGED && t->type <= TOK_EQUILIBRIUM) {
        int kind = t->type - TOK_CONVERGED;
        p_advance(p);
        ASTNode *n = make_node(AST_PREDICATE);
        n->data.predicate.kind = kind;
        return n;
    }

    if (t->type == TOK_NUM) {
        p_advance(p);
        ASTNode *n = make_node(AST_NUM);
        n->data.num = t->num_val;
        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX);
            index_node->data.index.target = n;
            index_node->data.index.index = idx;
            n = index_node;
        }
        return n;
    }

    if (t->type == TOK_STR) {
        p_advance(p);
        ASTNode *n = make_node(AST_STR);
        n->data.str = strdup(t->str_val);
        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX);
            index_node->data.index.target = n;
            index_node->data.index.index = idx;
            n = index_node;
        }
        return n;
    }

    if (t->type == TOK_NULL) {
        p_advance(p);
        return make_node(AST_NULL);
    }

    if (t->type == TOK_IDENT) {
        p_advance(p);
        ASTNode *n = make_node(AST_IDENT);
        n->data.ident.name = strdup(t->str_val);
        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX);
            index_node->data.index.target = n;
            index_node->data.index.index = idx;
            n = index_node;
        }
        return n;
    }

    if (t->type == TOK_LPAREN) {
        p_advance(p);
        ASTNode *expr = parse_expression(p);
        p_expect(p, TOK_RPAREN);
        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX);
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
            ASTNode *n = make_node(AST_LIST);
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
            ASTNode *n = make_node(AST_LISTCOMP);
            n->data.listcomp.expr = first;
            n->data.listcomp.var = strdup(var_tok->str_val);
            n->data.listcomp.iter = iter;
            n->data.listcomp.filter = filter;
            return n;
        }

        ASTNode **elems = malloc(MAX_LIST * sizeof(ASTNode*));
        int count = 0;
        elems[count++] = first;
        while (p_cur(p)->type == TOK_COMMA) {
            p_advance(p);
            if (p_cur(p)->type == TOK_RBRACKET) break;
            elems[count++] = parse_expression(p);
        }
        p_expect(p, TOK_RBRACKET);

        ASTNode *n = make_node(AST_LIST);
        n->data.list.elems = elems;
        n->data.list.count = count;

        while (p_cur(p)->type == TOK_LBRACKET) {
            p_advance(p);
            ASTNode *idx = parse_expression(p);
            p_expect(p, TOK_RBRACKET);
            ASTNode *index_node = make_node(AST_INDEX);
            index_node->data.index.target = n;
            index_node->data.index.index = idx;
            n = index_node;
        }
        return n;
    }

    ASTNode *n = make_node(AST_NULL);
    if (t->type != TOK_EOF && t->type != TOK_NEWLINE && t->type != TOK_DEDENT) {
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
        ASTNode *n = make_node(AST_RELATION);
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
        ASTNode *n = make_node(AST_UNARY);
        strcpy(n->data.unary.op, "-");
        n->data.unary.operand = operand;
        return n;
    }
    if (p_cur(p)->type == TOK_NOT) {
        p_advance(p);
        ASTNode *operand = parse_unary(p);
        ASTNode *n = make_node(AST_UNARY);
        strcpy(n->data.unary.op, "not");
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
        ASTNode *n = make_node(AST_BINOP);
        strcpy(n->data.binop.op, op);
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
        ASTNode *n = make_node(AST_BINOP);
        strcpy(n->data.binop.op, op);
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
            case TOK_LT: strcpy(op, "<"); break;
            case TOK_GT: strcpy(op, ">"); break;
            case TOK_LE: strcpy(op, "<="); break;
            case TOK_GE: strcpy(op, ">="); break;
            case TOK_EQ: strcpy(op, "="); break;
            case TOK_NE: strcpy(op, "!="); break;
            default: break;
        }
        p_advance(p);
        ASTNode *right = parse_addition(p);
        ASTNode *n = make_node(AST_BINOP);
        strcpy(n->data.binop.op, op);
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
        ASTNode *n = make_node(AST_BINOP);
        strcpy(n->data.binop.op, "and");
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
        ASTNode *n = make_node(AST_BINOP);
        strcpy(n->data.binop.op, "or");
        n->data.binop.left = left;
        n->data.binop.right = right;
        left = n;
    }
    return left;
}

static ASTNode* parse_expression(Parser *p) {
    return parse_or(p);
}

static ASTNode* parse_statement(Parser *p) {
    p_skip_newlines(p);
    Token *t = p_cur(p);

    if (t->type == TOK_EOF || t->type == TOK_DEDENT) return NULL;

    if (t->type == TOK_DEFINE) {
        p_advance(p);
        Token *name_tok = p_cur(p);
        p_expect(p, TOK_IDENT);
        if (p_cur(p)->type == TOK_AS) p_advance(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int body_count;
        ASTNode **body = parse_block(p, &body_count);
        ASTNode *n = make_node(AST_FUNC);
        n->data.func.name = strdup(name_tok->str_val);
        n->data.func.param = strdup("n");
        n->data.func.body = body;
        n->data.func.body_count = body_count;
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
        if (p_cur(p)->type == TOK_ELSE) {
            p_advance(p);
            p_expect(p, TOK_COLON);
            p_skip_newlines(p);
            else_body = parse_block(p, &else_count);
        }
        ASTNode *n = make_node(AST_IF);
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
        ASTNode *n = make_node(AST_LOOP);
        n->data.loop.cond = cond;
        n->data.loop.body = body;
        n->data.loop.body_count = body_count;
        return n;
    }

    if (t->type == TOK_RETURN) {
        p_advance(p);
        ASTNode *expr = parse_expression(p);
        p_match(p, TOK_NEWLINE);
        ASTNode *n = make_node(AST_RETURN);
        n->data.ret.expr = expr;
        return n;
    }

    if (t->type == TOK_IDENT && p_peek(p, 1)->type == TOK_IS) {
        Token *name_tok = p_advance(p);
        p_advance(p);
        ASTNode *expr = parse_expression(p);
        p_match(p, TOK_NEWLINE);
        ASTNode *n = make_node(AST_ASSIGN);
        n->data.assign.name = strdup(name_tok->str_val);
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

    ASTNode **stmts = malloc(MAX_STMTS * sizeof(ASTNode*));
    int count = 0;

    p_skip_newlines(&p);

    while (p_cur(&p)->type != TOK_EOF) {
        p_skip_newlines(&p);
        if (p_cur(&p)->type == TOK_EOF) break;
        ASTNode *stmt = parse_statement(&p);
        if (stmt && count < MAX_STMTS) {
            stmts[count++] = stmt;
        }
    }

    ASTNode *prog = make_node(AST_PROGRAM);
    prog->data.program.stmts = stmts;
    prog->data.program.count = count;
    return prog;
}

/* ================================================================
 * OBSERVER ENTROPY
 * ================================================================ */

static double compute_entropy(Value *v) {
    if (!v) return 0.0;
    switch (v->type) {
        case VAL_NULL: return 0.0;
        case VAL_NUM: {
            double x = fabs(v->data.num);
            if (x == 0.0 || x == 1.0) return 0.0;
            double p = 1.0 / (1.0 + x);
            if (p <= 0.0 || p >= 1.0) return 0.0;
            return -(p * log2(p) + (1.0-p) * log2(1.0-p));
        }
        case VAL_STR: {
            if (!v->data.str || !v->data.str[0]) return 0.0;
            int freq[256] = {0};
            int len = 0;
            for (const char *c = v->data.str; *c; c++) {
                freq[(unsigned char)*c]++;
                len++;
            }
            if (len == 0) return 0.0;
            double h = 0.0;
            for (int i = 0; i < 256; i++) {
                if (freq[i] > 0) {
                    double p = (double)freq[i] / len;
                    h -= p * log2(p);
                }
            }
            return h;
        }
        case VAL_LIST: {
            if (v->data.list.count == 0) return 0.0;
            double sum = 0.0;
            for (int i = 0; i < v->data.list.count; i++) {
                sum += compute_entropy(v->data.list.items[i]);
            }
            return sum / v->data.list.count + log2(v->data.list.count + 1);
        }
        case VAL_FN: return 1.0;
        case VAL_BUILTIN: return 0.0;
    }
    return 0.0;
}

static void update_observer(Value *v) {
    if (!v) return;
    double new_entropy = compute_entropy(v);
    v->prev_dH = v->dH;
    v->dH = new_entropy - v->last_entropy;
    v->entropy = new_entropy;
    v->last_entropy = new_entropy;
    v->obs_age++;
}

/* ================================================================
 * EVALUATOR
 * ================================================================ */

Value* eval_node(ASTNode *node, Env *env) {
    if (!node) return make_null();

    switch (node->type) {
    case AST_NUM:
        return make_num(node->data.num);

    case AST_STR:
        return make_str(node->data.str);

    case AST_NULL:
        return make_null();

    case AST_IDENT: {
        Value *v = env_get(env, node->data.ident.name);
        if (!v) {
            fprintf(stderr, "Warning: undefined variable '%s'\n", node->data.ident.name);
            return make_null();
        }
        return v;
    }

    case AST_ASSIGN: {
        Value *val = eval_node(node->data.assign.expr, env);
        Value *old = env_get(env, node->data.assign.name);
        if (old) {
            val->last_entropy = old->entropy;
            val->obs_age = old->obs_age;
            val->dH = old->dH;
        }
        update_observer(val);
        env_set(env, node->data.assign.name, val);
        env_set(env, "__observer__", val);
        return val;
    }

    case AST_BINOP: {
        const char *op = node->data.binop.op;

        if (strcmp(op, "and") == 0) {
            g_computation_cost += 2.0;
            Value *left = eval_node(node->data.binop.left, env);
            if (!is_truthy(left)) return make_num(0);
            Value *right = eval_node(node->data.binop.right, env);
            return make_num(is_truthy(right) ? 1 : 0);
        }
        if (strcmp(op, "or") == 0) {
            g_computation_cost += 1.0;
            Value *left = eval_node(node->data.binop.left, env);
            if (is_truthy(left)) return make_num(1);
            Value *right = eval_node(node->data.binop.right, env);
            return make_num(is_truthy(right) ? 1 : 0);
        }

        Value *left = eval_node(node->data.binop.left, env);
        Value *right = eval_node(node->data.binop.right, env);

        if (strcmp(op, "+") == 0) {
            if (left->type == VAL_STR || right->type == VAL_STR) {
                char *ls = value_to_string(left);
                char *rs = value_to_string(right);
                char *result = malloc(strlen(ls) + strlen(rs) + 1);
                strcpy(result, ls);
                strcat(result, rs);
                Value *v = make_str(result);
                free(ls); free(rs); free(result);
                return v;
            }
            if (left->type == VAL_NUM && right->type == VAL_NUM)
                return make_num(left->data.num + right->data.num);
        }
        if (strcmp(op, "-") == 0 && left->type == VAL_NUM && right->type == VAL_NUM)
            return make_num(left->data.num - right->data.num);
        if (strcmp(op, "*") == 0 && left->type == VAL_NUM && right->type == VAL_NUM)
            return make_num(left->data.num * right->data.num);
        if (strcmp(op, "/") == 0 && left->type == VAL_NUM && right->type == VAL_NUM) {
            if (right->data.num == 0) return make_num(0);
            return make_num(left->data.num / right->data.num);
        }
        if (strcmp(op, "%") == 0 && left->type == VAL_NUM && right->type == VAL_NUM) {
            if (right->data.num == 0) return make_num(0);
            return make_num(fmod(left->data.num, right->data.num));
        }

        if (strcmp(op, "=") == 0) {
            if (left->type == VAL_NUM && right->type == VAL_NUM)
                return make_num(left->data.num == right->data.num ? 1 : 0);
            if (left->type == VAL_STR && right->type == VAL_STR)
                return make_num(strcmp(left->data.str, right->data.str) == 0 ? 1 : 0);
            if (left->type == VAL_NULL && right->type == VAL_NULL)
                return make_num(1);
            return make_num(0);
        }
        if (strcmp(op, "!=") == 0) {
            if (left->type == VAL_NUM && right->type == VAL_NUM)
                return make_num(left->data.num != right->data.num ? 1 : 0);
            if (left->type == VAL_STR && right->type == VAL_STR)
                return make_num(strcmp(left->data.str, right->data.str) != 0 ? 1 : 0);
            if (left->type == VAL_NULL && right->type == VAL_NULL)
                return make_num(0);
            return make_num(1);
        }

        if (left->type == VAL_NUM && right->type == VAL_NUM) {
            if (strcmp(op, "<") == 0) return make_num(left->data.num < right->data.num ? 1 : 0);
            if (strcmp(op, ">") == 0) return make_num(left->data.num > right->data.num ? 1 : 0);
            if (strcmp(op, "<=") == 0) return make_num(left->data.num <= right->data.num ? 1 : 0);
            if (strcmp(op, ">=") == 0) return make_num(left->data.num >= right->data.num ? 1 : 0);
        }

        return make_null();
    }

    case AST_UNARY: {
        Value *operand = eval_node(node->data.unary.operand, env);
        if (strcmp(node->data.unary.op, "-") == 0 && operand->type == VAL_NUM)
            return make_num(-operand->data.num);
        if (strcmp(node->data.unary.op, "not") == 0) {
            /* free - no cost */
            return make_num(is_truthy(operand) ? 0 : 1);
        }
        return make_null();
    }

    case AST_RELATION: {
        Value *right_val = eval_node(node->data.relation.right, env);
        Value *left_val = eval_node(node->data.relation.left, env);

        if (left_val->type == VAL_BUILTIN) {
            Value *result = left_val->data.builtin(right_val);
            update_observer(result);
            env_set(env, "__observer__", result);
            return result;
        }

        if (left_val->type == VAL_FN) {
            Env *call_env = env_new(left_val->data.fn.closure);
            env_set_local(call_env, left_val->data.fn.param, right_val);
            env_set_local(call_env, "n", right_val);

            g_returning = 0;
            g_return_val = NULL;

            Value *result = make_null();
            for (int i = 0; i < left_val->data.fn.body_count; i++) {
                result = eval_node(left_val->data.fn.body[i], call_env);
                if (g_returning) {
                    g_returning = 0;
                    update_observer(g_return_val);
                    env_set(env, "__observer__", g_return_val);
                    return g_return_val ? g_return_val : make_null();
                }
            }
            update_observer(result);
            env_set(env, "__observer__", result);
            return result;
        }

        return make_null();
    }

    case AST_IF: {
        g_computation_cost += 0.5;
        Value *cond = eval_node(node->data.cond.cond, env);
        if (is_truthy(cond)) {
            return eval_block(node->data.cond.if_body, node->data.cond.if_count, env);
        } else if (node->data.cond.else_body) {
            return eval_block(node->data.cond.else_body, node->data.cond.else_count, env);
        }
        return make_null();
    }

    case AST_LOOP: {
        Value *result = make_null();
        int max_iter = 1000000;
        int stall_count = 0;
        int iterations = 0;
        const char *exit_reason = "normal";
        while (max_iter-- > 0) {
            Value *cond = eval_node(node->data.loop.cond, env);
            if (!is_truthy(cond)) break;
            iterations++;
            result = eval_block(node->data.loop.body, node->data.loop.body_count, env);
            if (g_returning) return result;
            Value *obs = env_get(env, "__observer__");
            if (obs && fabs(obs->dH) < 0.001 && obs->entropy >= 0.1) {
                stall_count++;
                if (stall_count >= 100) {
                    exit_reason = "stalled";
                    break;
                }
            } else {
                stall_count = 0;
            }
        }
        if (max_iter <= 0) exit_reason = "limit";
        env_set(env, "__loop_exit__", make_str(exit_reason));
        env_set(env, "__loop_iterations__", make_num(iterations));
        return result;
    }

    case AST_FUNC: {
        Value *fn = make_fn(node->data.func.name, node->data.func.param,
                           node->data.func.body, node->data.func.body_count, env);
        env_set(env, node->data.func.name, fn);
        return fn;
    }

    case AST_RETURN: {
        Value *val = eval_node(node->data.ret.expr, env);
        g_returning = 1;
        g_return_val = val;
        return val;
    }

    case AST_LIST: {
        Value *list = make_list(node->data.list.count);
        for (int i = 0; i < node->data.list.count; i++) {
            list_append(list, eval_node(node->data.list.elems[i], env));
        }
        return list;
    }

    case AST_INDEX: {
        Value *target = eval_node(node->data.index.target, env);
        Value *idx = eval_node(node->data.index.index, env);
        if (target->type == VAL_LIST && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.list.count)
                return target->data.list.items[i];
        }
        if (target->type == VAL_STR && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            int len = strlen(target->data.str);
            if (i >= 0 && i < len) {
                char buf[2] = {target->data.str[i], '\0'};
                return make_str(buf);
            }
        }
        return make_null();
    }

    case AST_LISTCOMP: {
        Value *iter = eval_node(node->data.listcomp.iter, env);
        if (iter->type != VAL_LIST) return make_list(0);
        Value *result = make_list(iter->data.list.count);
        for (int i = 0; i < iter->data.list.count; i++) {
            Env *loop_env = env_new(env);
            env_set_local(loop_env, node->data.listcomp.var, iter->data.list.items[i]);
            if (node->data.listcomp.filter) {
                Value *cond = eval_node(node->data.listcomp.filter, loop_env);
                if (!is_truthy(cond)) continue;
            }
            Value *val = eval_node(node->data.listcomp.expr, loop_env);
            list_append(result, val);
        }
        return result;
    }

    case AST_PROGRAM: {
        Value *result = make_null();
        for (int i = 0; i < node->data.program.count; i++) {
            result = eval_node(node->data.program.stmts[i], env);
            if (g_returning) return result;
        }
        return result;
    }

    case AST_BLOCK: {
        return eval_block(node->data.block.stmts, node->data.block.count, env);
    }

    case AST_INTERROGATE: {
        g_computation_cost += 1.0;
        Value *target = eval_node(node->data.interrogate.expr, env);
        switch (node->data.interrogate.kind) {
            case 0:
                if (target->type == VAL_NUM) return make_num(target->data.num);
                if (target->type == VAL_STR) return make_num((double)strlen(target->data.str));
                if (target->type == VAL_LIST) return make_num((double)target->data.list.count);
                return make_num(0.0);
            case 1:
                if (node->data.interrogate.expr->type == AST_IDENT)
                    return make_str(node->data.interrogate.expr->data.ident.name);
                if (target->type == VAL_NUM) return make_str("number");
                if (target->type == VAL_STR) return make_str("string");
                if (target->type == VAL_LIST) return make_str("list");
                return make_str("unknown");
            case 2:
                return make_num((double)target->obs_age);
            case 3:
                return make_num(target->entropy);
            case 4:
                return make_num(target->dH);
            case 5: {
                double initial = target->last_entropy > 0 ? target->last_entropy : 1.0;
                return make_num(target->entropy > 0 ? 1.0 - target->entropy / initial : 1.0);
            }
        }
        return make_num(0.0);
    }

    case AST_PREDICATE: {
        Value *last = env_get(env, "__observer__");
        double h = last ? last->entropy : 0.0;
        double dh = last ? last->dH : 0.0;
        switch (node->data.predicate.kind) {
            case 0:
                return make_num((fabs(dh) < 0.001 && h < 0.1) ? 1.0 : 0.0);
            case 1:
                return make_num((fabs(dh) < 0.01 && h >= 0.1 && !(last && last->prev_dH != 0.0 && dh * last->prev_dH < 0 && fabs(dh) > 0.001)) ? 1.0 : 0.0);
            case 2:
                return make_num((dh < -0.001) ? 1.0 : 0.0);
            case 3:
                return make_num((last && dh * last->prev_dH < 0 && fabs(dh) > 0.001) ? 1.0 : 0.0);
            case 4:
                return make_num((dh > 0.001) ? 1.0 : 0.0);
            case 5:
                return make_num((fabs(dh) < 0.001) ? 1.0 : 0.0);
        }
        return make_num(0.0);
    }

    default:
        return make_null();
    }
}

Value* eval_block(ASTNode **stmts, int count, Env *env) {
    Value *result = make_null();
    for (int i = 0; i < count; i++) {
        result = eval_node(stmts[i], env);
        if (g_returning) return result;
    }
    return result;
}

/* ================================================================
 * BUILT-IN FUNCTIONS
 * ================================================================ */

Value* builtin_print(Value *arg) {
    char *s = value_to_string(arg);
    printf("%s\n", s);
    fflush(stdout);
    free(s);
    return make_null();
}

Value* builtin_len(Value *arg) {
    if (arg->type == VAL_LIST)
        return make_num(arg->data.list.count);
    if (arg->type == VAL_STR)
        return make_num(strlen(arg->data.str));
    return make_num(0);
}

Value* builtin_str(Value *arg) {
    char *s = value_to_string(arg);
    Value *v = make_str(s);
    free(s);
    return v;
}

Value* builtin_append(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *target = arg->data.list.items[0];
    Value *item = arg->data.list.items[1];
    if (target->type == VAL_LIST) {
        list_append(target, item);
    }
    return target;
}

Value* builtin_http_route(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();

    if (g_server.route_count >= MAX_ROUTES) return make_null();

    Route *r = &g_server.routes[g_server.route_count];
    char *method_s = value_to_string(arg->data.list.items[0]);
    char *path_s = value_to_string(arg->data.list.items[1]);
    r->method = method_s;
    r->path = path_s;

    if (arg->data.list.count >= 4) {
        char *kind_s = value_to_string(arg->data.list.items[2]);
        char *payload_s = value_to_string(arg->data.list.items[3]);
        r->kind = kind_s;
        r->payload = payload_s;
    } else {
        Value *handler = arg->data.list.items[2];
        if (handler->type == VAL_STR) {
            r->kind = strdup("static");
            r->payload = strdup(handler->data.str);
        } else {
            r->kind = strdup("static");
            char *s = value_to_string(handler);
            r->payload = s;
        }
    }

    g_server.route_count++;
    return make_str("route registered");
}

Value* builtin_http_static(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    char *prefix = value_to_string(arg->data.list.items[0]);
    char *dir = value_to_string(arg->data.list.items[1]);
    g_server.static_prefix = prefix;
    g_server.static_dir = dir;
    return make_str("static registered");
}

Value* builtin_http_early_bind(Value *arg) {
    int port = 5000;
    if (arg && arg->type == VAL_NUM) port = (int)arg->data.num;
    const char *env_port = getenv("PORT");
    if (env_port && atoi(env_port) > 0) {
        port = atoi(env_port);
        printf("[deploy] PORT env=%s, binding port %d\n", env_port, port);
    } else {
        printf("[deploy] No PORT env, using default %d\n", port);
    }
    char cwd[512];
    if (getcwd(cwd, sizeof(cwd))) {
        printf("[deploy] cwd=%s\n", cwd);
    }
    fflush(stdout);

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return make_str("error"); }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(server_fd); return make_str("error");
    }
    if (listen(server_fd, 128) < 0) {
        perror("listen"); close(server_fd); return make_str("error");
    }

    g_server.early_bind_fd = server_fd;
    printf("Port %d bound (early bind for health check)\n", port);
    fflush(stdout);

    if (pthread_create(&g_health_tid, NULL, health_thread, (void*)(intptr_t)server_fd) == 0) {
        g_health_thread_active = 1;
        printf("Health thread started for early responses\n");
    } else {
        perror("pthread_create");
        printf("Warning: health thread failed, continuing without early responses\n");
    }
    fflush(stdout);

    return make_str("bound");
}

Value* builtin_http_serve(Value *arg) {
    int port = 5000;
    if (arg && arg->type == VAL_NUM) port = (int)arg->data.num;
    const char *env_port = getenv("PORT");
    if (env_port && atoi(env_port) > 0) {
        port = atoi(env_port);
    }
    printf("Starting HTTP server on port %d...\n", port);
    fflush(stdout);
    http_serve_blocking(port);
    return make_null();
}

Value* builtin_http_request_body(Value *arg) {
    (void)arg;
    if (g_server.request_body)
        return make_str(g_server.request_body);
    return make_str("{}");
}

Value* builtin_http_session_id(Value *arg) {
    (void)arg;
    if (g_server.session_id)
        return make_str(g_server.session_id);
    return make_str("anonymous");
}

/* ================================================================
 * JSON MODEL WEIGHT LOADER
 * ================================================================ */

static void json_skip_ws(const char **p) {
    while (**p == ' ' || **p == '\t' || **p == '\n' || **p == '\r') (*p)++;
}

static double json_parse_number(const char **p) {
    char *end;
    double val = strtod(*p, &end);
    *p = end;
    return val;
}

static void json_parse_string(const char **p, char *out, int max_len) {
    if (**p != '"') { out[0] = '\0'; return; }
    (*p)++;
    int i = 0;
    while (**p && **p != '"' && i < max_len - 1) {
        if (**p == '\\') { (*p)++; }
        out[i++] = **p;
        (*p)++;
    }
    out[i] = '\0';
    if (**p == '"') (*p)++;
}

static void json_skip_value(const char **p) {
    json_skip_ws(p);
    if (**p == '"') {
        (*p)++;
        while (**p && **p != '"') {
            if (**p == '\\') (*p)++;
            (*p)++;
        }
        if (**p == '"') (*p)++;
    } else if (**p == '{') {
        int depth = 1; (*p)++;
        while (**p && depth > 0) {
            if (**p == '{') depth++;
            else if (**p == '}') depth--;
            else if (**p == '"') { (*p)++; while (**p && **p != '"') { if (**p == '\\') (*p)++; (*p)++; } }
            (*p)++;
        }
    } else if (**p == '[') {
        int depth = 1; (*p)++;
        while (**p && depth > 0) {
            if (**p == '[') depth++;
            else if (**p == ']') depth--;
            else if (**p == '"') { (*p)++; while (**p && **p != '"') { if (**p == '\\') (*p)++; (*p)++; } }
            (*p)++;
        }
    } else if (**p == 't' || **p == 'f' || **p == 'n') {
        while (**p && **p != ',' && **p != '}' && **p != ']') (*p)++;
    } else {
        while (**p && **p != ',' && **p != '}' && **p != ']' && **p != ' ' && **p != '\n' && **p != '\r') (*p)++;
    }
}

static int json_parse_1d_array(const char **p, double *out, int len) {
    json_skip_ws(p);
    if (**p != '[') return -1;
    (*p)++;
    for (int i = 0; i < len; i++) {
        json_skip_ws(p);
        out[i] = json_parse_number(p);
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    json_skip_ws(p);
    if (**p == ']') (*p)++;
    return 0;
}

static int json_parse_2d_array(const char **p, double *out, int rows, int cols) {
    json_skip_ws(p);
    if (**p != '[') return -1;
    (*p)++;
    for (int r = 0; r < rows; r++) {
        json_skip_ws(p);
        json_parse_1d_array(p, out + r * cols, cols);
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    json_skip_ws(p);
    if (**p == ']') (*p)++;
    return 0;
}

static int json_parse_config(const char **p, ModelConfig *cfg) {
    json_skip_ws(p);
    if (**p != '{') return -1;
    (*p)++;
    while (**p && **p != '}') {
        json_skip_ws(p);
        char key[64];
        json_parse_string(p, key, sizeof(key));
        json_skip_ws(p);
        if (**p == ':') (*p)++;
        json_skip_ws(p);
        int val = (int)json_parse_number(p);
        if (strcmp(key, "vocab_size") == 0) cfg->vocab_size = val;
        else if (strcmp(key, "d_model") == 0) cfg->d_model = val;
        else if (strcmp(key, "n_heads") == 0) cfg->n_heads = val;
        else if (strcmp(key, "n_layers") == 0) cfg->n_layers = val;
        else if (strcmp(key, "d_ff") == 0) cfg->d_ff = val;
        else if (strcmp(key, "max_seq_len") == 0) cfg->max_seq_len = val;
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    if (**p == '}') (*p)++;
    return 0;
}

static int json_parse_layer(const char **p, TransformerLayer *layer, int d_model, int d_ff) {
    json_skip_ws(p);
    if (**p != '{') return -1;
    (*p)++;
    while (**p && **p != '}') {
        json_skip_ws(p);
        char key[64];
        json_parse_string(p, key, sizeof(key));
        json_skip_ws(p);
        if (**p == ':') (*p)++;
        json_skip_ws(p);

        if (strcmp(key, "w_q") == 0) {
            layer->w_q = calloc(d_model * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_q, d_model, d_model);
        } else if (strcmp(key, "w_k") == 0) {
            layer->w_k = calloc(d_model * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_k, d_model, d_model);
        } else if (strcmp(key, "w_v") == 0) {
            layer->w_v = calloc(d_model * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_v, d_model, d_model);
        } else if (strcmp(key, "w_o") == 0) {
            layer->w_o = calloc(d_model * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_o, d_model, d_model);
        } else if (strcmp(key, "w_ff1") == 0) {
            layer->w_ff1 = calloc(d_model * d_ff, sizeof(double));
            json_parse_2d_array(p, layer->w_ff1, d_model, d_ff);
        } else if (strcmp(key, "w_ff2") == 0) {
            layer->w_ff2 = calloc(d_ff * d_model, sizeof(double));
            json_parse_2d_array(p, layer->w_ff2, d_ff, d_model);
        } else if (strcmp(key, "ln1_gamma") == 0) {
            layer->ln1_gamma = calloc(d_model, sizeof(double));
            json_parse_1d_array(p, layer->ln1_gamma, d_model);
        } else if (strcmp(key, "ln1_beta") == 0) {
            layer->ln1_beta = calloc(d_model, sizeof(double));
            json_parse_1d_array(p, layer->ln1_beta, d_model);
        } else if (strcmp(key, "ln2_gamma") == 0) {
            layer->ln2_gamma = calloc(d_model, sizeof(double));
            json_parse_1d_array(p, layer->ln2_gamma, d_model);
        } else if (strcmp(key, "ln2_beta") == 0) {
            layer->ln2_beta = calloc(d_model, sizeof(double));
            json_parse_1d_array(p, layer->ln2_beta, d_model);
        } else {
            json_skip_value(p);
        }
        json_skip_ws(p);
        if (**p == ',') (*p)++;
    }
    if (**p == '}') (*p)++;
    return 0;
}

int load_model_weights(const char *path, TransformerModel *model) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open model file: %s\n", path); return -1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *data = malloc(size + 1);
    if (!data) { fclose(f); return -1; }
    fread(data, 1, size, f);
    data[size] = '\0';
    fclose(f);

    printf("Model file loaded: %ld bytes\n", size);
    fflush(stdout);

    const char *p = data;
    json_skip_ws(&p);
    if (*p != '{') { free(data); return -1; }
    p++;

    while (*p && *p != '}') {
        json_skip_ws(&p);
        char key[64];
        json_parse_string(&p, key, sizeof(key));
        json_skip_ws(&p);
        if (*p == ':') p++;
        json_skip_ws(&p);

        if (strcmp(key, "config") == 0) {
            json_parse_config(&p, &model->config);
            printf("Config: vocab=%d d_model=%d n_heads=%d n_layers=%d d_ff=%d\n",
                model->config.vocab_size, model->config.d_model,
                model->config.n_heads, model->config.n_layers, model->config.d_ff);
            fflush(stdout);
        } else if (strcmp(key, "token_embeddings") == 0) {
            int vs = model->config.vocab_size;
            int dm = model->config.d_model;
            model->token_embeddings = calloc(vs * dm, sizeof(double));
            json_parse_2d_array(&p, model->token_embeddings, vs, dm);
        } else if (strcmp(key, "output_proj") == 0) {
            int dm = model->config.d_model;
            int vs = model->config.vocab_size;
            model->output_proj = calloc(dm * vs, sizeof(double));
            json_parse_2d_array(&p, model->output_proj, dm, vs);
        } else if (strcmp(key, "layers") == 0) {
            json_skip_ws(&p);
            if (*p == '[') {
                p++;
                for (int l = 0; l < model->config.n_layers && l < MAX_LAYERS; l++) {
                    json_skip_ws(&p);
                    json_parse_layer(&p, &model->layers[l], model->config.d_model, model->config.d_ff);
                    json_skip_ws(&p);
                    if (*p == ',') p++;
                }
                json_skip_ws(&p);
                if (*p == ']') p++;
            }
        } else {
            json_skip_value(&p);
        }
        json_skip_ws(&p);
        if (*p == ',') p++;
    }

    free(data);
    model->loaded = 1;
    printf("Model loaded successfully: %d layers, d_model=%d\n",
        model->config.n_layers, model->config.d_model);
    fflush(stdout);
    return 0;
}

/* ================================================================
 * NUMEIGS TENSOR KERNELS (STATICALLY INCLUDED)
 * ================================================================ */

#define NE_TILE_SIZE 32

static void ne_softmax_buf(double* data, int64_t rows, int64_t cols) {
    for (int64_t i = 0; i < rows; i++) {
        double* row = data + i * cols;
        double max_val = row[0];
        for (int64_t j = 1; j < cols; j++) {
            if (row[j] > max_val) max_val = row[j];
        }
        double sum = 0.0;
        for (int64_t j = 0; j < cols; j++) {
            row[j] = exp(row[j] - max_val);
            sum += row[j];
        }
        for (int64_t j = 0; j < cols; j++) {
            row[j] /= sum;
        }
    }
}

static void ne_matmul_buf(
    double* a, int64_t m, int64_t k,
    double* b, int64_t n,
    double* out
) {
    memset(out, 0, m * n * sizeof(double));
    for (int64_t i0 = 0; i0 < m; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < k; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < m ? i0 + NE_TILE_SIZE : m;
                int64_t j_end = j0 + NE_TILE_SIZE < n ? j0 + NE_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TILE_SIZE < k ? k0 + NE_TILE_SIZE : k;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        double a_ik = a[i * k + kk];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * n + j] += a_ik * b[kk * n + j];
                        }
                    }
                }
            }
        }
    }
}

static void ne_gelu_buf(double* data, int64_t size) {
    const double sqrt_2_over_pi = sqrt(2.0 / M_PI);
    for (int64_t i = 0; i < size; i++) {
        double x = data[i];
        data[i] = 0.5 * x * (1.0 + tanh(sqrt_2_over_pi * (x + 0.044715 * x * x * x)));
    }
}

static void ne_fused_attention_forward_buf(
    double* x, int64_t seq_len, int64_t d_model,
    double* wq, double* wk, double* wv, double* wo,
    double* out,
    double* attn_probs_out
) {
    int64_t sd = seq_len * d_model;
    int64_t ss = seq_len * seq_len;

    double* Q = (double*)calloc(sd, sizeof(double));
    double* K = (double*)calloc(sd, sizeof(double));
    double* V = (double*)calloc(sd, sizeof(double));
    double* scores = (double*)calloc(ss, sizeof(double));
    double* context = (double*)calloc(sd, sizeof(double));

    ne_matmul_buf(x, seq_len, d_model, wq, d_model, Q);
    ne_matmul_buf(x, seq_len, d_model, wk, d_model, K);
    ne_matmul_buf(x, seq_len, d_model, wv, d_model, V);

    double* Kt = (double*)calloc(sd, sizeof(double));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < d_model; j++) {
            Kt[j * seq_len + i] = K[i * d_model + j];
        }
    }
    ne_matmul_buf(Q, seq_len, d_model, Kt, seq_len, scores);
    free(Kt);

    double scale = 1.0 / sqrt((double)d_model);
    double neg_inf = -1.0 / 0.0;
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < seq_len; j++) {
            scores[i * seq_len + j] *= scale;
            if (j > i) {
                scores[i * seq_len + j] = neg_inf;
            }
        }
    }

    ne_softmax_buf(scores, seq_len, seq_len);

    memcpy(attn_probs_out, scores, ss * sizeof(double));

    ne_matmul_buf(scores, seq_len, seq_len, V, d_model, context);

    ne_matmul_buf(context, seq_len, d_model, wo, d_model, out);

    free(Q);
    free(K);
    free(V);
    free(scores);
    free(context);
}

static void ne_fused_ffn_forward_buf(
    double* x, int64_t seq_len, int64_t d_model,
    double* w1, int64_t d_ff,
    double* w2,
    int32_t use_gelu,
    double* out,
    double* pre_act_out
) {
    int64_t sf = seq_len * d_ff;

    double* hidden = (double*)calloc(sf, sizeof(double));

    ne_matmul_buf(x, seq_len, d_model, w1, d_ff, hidden);

    memcpy(pre_act_out, hidden, sf * sizeof(double));

    if (use_gelu) {
        ne_gelu_buf(hidden, sf);
    }

    ne_matmul_buf(hidden, seq_len, d_ff, w2, d_model, out);

    free(hidden);
}

/* ================================================================
 * BACKWARD KERNELS (from NumEigs)
 * ================================================================ */

static void ne_matmul_at_buf(
    double* a, int64_t m, int64_t k,
    double* b, int64_t n,
    double* out
) {
    memset(out, 0, k * n * sizeof(double));
    for (int64_t i0 = 0; i0 < k; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < n; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < m; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < k ? i0 + NE_TILE_SIZE : k;
                int64_t j_end = j0 + NE_TILE_SIZE < n ? j0 + NE_TILE_SIZE : n;
                int64_t k_end = k0 + NE_TILE_SIZE < m ? k0 + NE_TILE_SIZE : m;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        double a_ki = a[kk * k + i];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * n + j] += a_ki * b[kk * n + j];
                        }
                    }
                }
            }
        }
    }
}

static void ne_matmul_bt_buf(
    double* a, int64_t m, int64_t k,
    double* b, int64_t n,
    double* out
) {
    memset(out, 0, m * k * sizeof(double));
    for (int64_t i0 = 0; i0 < m; i0 += NE_TILE_SIZE) {
        for (int64_t j0 = 0; j0 < k; j0 += NE_TILE_SIZE) {
            for (int64_t k0 = 0; k0 < n; k0 += NE_TILE_SIZE) {
                int64_t i_end = i0 + NE_TILE_SIZE < m ? i0 + NE_TILE_SIZE : m;
                int64_t j_end = j0 + NE_TILE_SIZE < k ? j0 + NE_TILE_SIZE : k;
                int64_t k_end = k0 + NE_TILE_SIZE < n ? k0 + NE_TILE_SIZE : n;
                for (int64_t i = i0; i < i_end; i++) {
                    for (int64_t kk = k0; kk < k_end; kk++) {
                        double a_ik = a[i * n + kk];
                        for (int64_t j = j0; j < j_end; j++) {
                            out[i * k + j] += a_ik * b[j * n + kk];
                        }
                    }
                }
            }
        }
    }
}

static void ne_fused_attention_backward_buf(
    double* d_attn_out, int64_t seq_len, int64_t d_model,
    double* x,
    double* wq, double* wk, double* wv, double* wo,
    double* attn_probs,
    double* d_wq, double* d_wk, double* d_wv, double* d_wo,
    double* d_x
) {
    int64_t sd = seq_len * d_model;
    int64_t dd = d_model * d_model;
    int64_t ss = seq_len * seq_len;
    (void)dd;

    double* Q = (double*)calloc(sd, sizeof(double));
    double* K = (double*)calloc(sd, sizeof(double));
    double* V = (double*)calloc(sd, sizeof(double));
    double* context = (double*)calloc(sd, sizeof(double));

    ne_matmul_buf(x, seq_len, d_model, wq, d_model, Q);
    ne_matmul_buf(x, seq_len, d_model, wk, d_model, K);
    ne_matmul_buf(x, seq_len, d_model, wv, d_model, V);
    ne_matmul_buf(attn_probs, seq_len, seq_len, V, d_model, context);

    double* d_context = (double*)calloc(sd, sizeof(double));
    ne_matmul_bt_buf(d_attn_out, seq_len, d_model, wo, d_model, d_context);

    ne_matmul_at_buf(context, seq_len, d_model, d_attn_out, d_model, d_wo);

    double* d_V = (double*)calloc(sd, sizeof(double));
    ne_matmul_at_buf(attn_probs, seq_len, seq_len, d_context, d_model, d_V);

    double* d_probs = (double*)calloc(ss, sizeof(double));
    double* Vt = (double*)calloc(sd, sizeof(double));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < d_model; j++) {
            Vt[j * seq_len + i] = V[i * d_model + j];
        }
    }
    ne_matmul_buf(d_context, seq_len, d_model, Vt, seq_len, d_probs);
    free(Vt);

    ne_matmul_at_buf(x, seq_len, d_model, d_V, d_model, d_wv);

    double* d_scores = (double*)calloc(ss, sizeof(double));
    for (int64_t i = 0; i < seq_len; i++) {
        double s = 0.0;
        for (int64_t j = 0; j < seq_len; j++) {
            s += attn_probs[i * seq_len + j] * d_probs[i * seq_len + j];
        }
        for (int64_t j = 0; j < seq_len; j++) {
            d_scores[i * seq_len + j] = attn_probs[i * seq_len + j] * (d_probs[i * seq_len + j] - s);
        }
    }

    double scale = 1.0 / sqrt((double)d_model);

    double* d_Q = (double*)calloc(sd, sizeof(double));
    ne_matmul_buf(d_scores, seq_len, seq_len, K, d_model, d_Q);
    for (int64_t i = 0; i < sd; i++) d_Q[i] *= scale;

    double* d_K = (double*)calloc(sd, sizeof(double));
    double* d_scores_t = (double*)calloc(ss, sizeof(double));
    for (int64_t i = 0; i < seq_len; i++) {
        for (int64_t j = 0; j < seq_len; j++) {
            d_scores_t[j * seq_len + i] = d_scores[i * seq_len + j];
        }
    }
    ne_matmul_buf(d_scores_t, seq_len, seq_len, Q, d_model, d_K);
    for (int64_t i = 0; i < sd; i++) d_K[i] *= scale;
    free(d_scores_t);

    ne_matmul_at_buf(x, seq_len, d_model, d_Q, d_model, d_wq);
    ne_matmul_at_buf(x, seq_len, d_model, d_K, d_model, d_wk);

    memset(d_x, 0, sd * sizeof(double));
    double* temp = (double*)calloc(sd, sizeof(double));

    ne_matmul_bt_buf(d_Q, seq_len, d_model, wq, d_model, temp);
    for (int64_t i = 0; i < sd; i++) d_x[i] += temp[i];

    memset(temp, 0, sd * sizeof(double));
    ne_matmul_bt_buf(d_K, seq_len, d_model, wk, d_model, temp);
    for (int64_t i = 0; i < sd; i++) d_x[i] += temp[i];

    memset(temp, 0, sd * sizeof(double));
    ne_matmul_bt_buf(d_V, seq_len, d_model, wv, d_model, temp);
    for (int64_t i = 0; i < sd; i++) d_x[i] += temp[i];

    free(temp);
    free(Q); free(K); free(V); free(context);
    free(d_context); free(d_V); free(d_probs);
    free(d_scores); free(d_Q); free(d_K);
}

static void ne_fused_ffn_backward_buf(
    double* d_out, int64_t seq_len, int64_t d_model,
    double* x,
    double* w1, int64_t d_ff,
    double* w2,
    double* pre_act,
    double* d_w1, double* d_w2, double* d_x
) {
    int64_t sf = seq_len * d_ff;
    const double sqrt_2_over_pi = sqrt(2.0 / M_PI);
    const double sqrt_2pi = sqrt(2.0 * M_PI);

    double* gelu_out = (double*)calloc(sf, sizeof(double));
    memcpy(gelu_out, pre_act, sf * sizeof(double));
    ne_gelu_buf(gelu_out, sf);

    double* d_gelu = (double*)calloc(sf, sizeof(double));
    ne_matmul_bt_buf(d_out, seq_len, d_ff, w2, d_model, d_gelu);

    ne_matmul_at_buf(gelu_out, seq_len, d_ff, d_out, d_model, d_w2);

    double* d_hidden = (double*)calloc(sf, sizeof(double));
    for (int64_t i = 0; i < sf; i++) {
        double h = pre_act[i];
        double cdf = 0.5 * (1.0 + tanh(sqrt_2_over_pi * (h + 0.044715 * h * h * h)));
        double pdf = exp(-0.5 * h * h) / sqrt_2pi;
        double gelu_grad = cdf + h * pdf;
        d_hidden[i] = d_gelu[i] * gelu_grad;
    }

    ne_matmul_at_buf(x, seq_len, d_model, d_hidden, d_ff, d_w1);
    ne_matmul_bt_buf(d_hidden, seq_len, d_model, w1, d_ff, d_x);

    free(gelu_out); free(d_gelu); free(d_hidden);
}

/* ================================================================
 * NATIVE INFERENCE PIPELINE
 * ================================================================ */

static void layer_norm(double *x, int64_t d, double *gamma, double *beta, double eps, double *out) {
    double mean = 0.0;
    for (int64_t i = 0; i < d; i++) mean += x[i];
    mean /= d;
    double var = 0.0;
    for (int64_t i = 0; i < d; i++) { double diff = x[i] - mean; var += diff * diff; }
    var /= d;
    double std_val = sqrt(var + eps);
    for (int64_t i = 0; i < d; i++) out[i] = (x[i] - mean) / std_val * gamma[i] + beta[i];
}

static void create_sinusoidal_pe(double *pe, int seq_len, int d_model) {
    for (int pos = 0; pos < seq_len; pos++) {
        for (int i = 0; i < d_model; i += 2) {
            double div_term = exp((double)i * -(log(10000.0) / d_model));
            pe[pos * d_model + i] = sin((double)pos * div_term);
            if (i + 1 < d_model) pe[pos * d_model + i + 1] = cos((double)pos * div_term);
        }
    }
}

static void native_forward(int *token_ids, int seq_len, TransformerModel *model, double *logits_out) {
    int d_model = model->config.d_model;
    int d_ff = model->config.d_ff;

    double *x = calloc(seq_len * d_model, sizeof(double));
    for (int i = 0; i < seq_len; i++) {
        int tid = token_ids[i];
        if (tid < 0) tid = 0;
        if (tid >= model->config.vocab_size) tid = model->config.vocab_size - 1;
        memcpy(x + i * d_model, model->token_embeddings + tid * d_model, d_model * sizeof(double));
    }

    double *pe = calloc(seq_len * d_model, sizeof(double));
    create_sinusoidal_pe(pe, seq_len, d_model);
    for (int i = 0; i < seq_len * d_model; i++) x[i] += pe[i];
    free(pe);

    for (int l = 0; l < model->config.n_layers; l++) {
        TransformerLayer *layer = &model->layers[l];

        double *norm1 = calloc(seq_len * d_model, sizeof(double));
        for (int i = 0; i < seq_len; i++) {
            layer_norm(x + i * d_model, d_model, layer->ln1_gamma, layer->ln1_beta, 1e-6, norm1 + i * d_model);
        }

        double *attn_out = calloc(seq_len * d_model, sizeof(double));
        double *attn_probs = calloc(seq_len * seq_len, sizeof(double));
        ne_fused_attention_forward_buf(norm1, seq_len, d_model,
            layer->w_q, layer->w_k, layer->w_v, layer->w_o,
            attn_out, attn_probs);
        free(norm1);
        free(attn_probs);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += attn_out[i];
        free(attn_out);

        double *norm2 = calloc(seq_len * d_model, sizeof(double));
        for (int i = 0; i < seq_len; i++) {
            layer_norm(x + i * d_model, d_model, layer->ln2_gamma, layer->ln2_beta, 1e-6, norm2 + i * d_model);
        }

        double *ffn_out = calloc(seq_len * d_model, sizeof(double));
        double *pre_act = calloc(seq_len * d_ff, sizeof(double));
        ne_fused_ffn_forward_buf(norm2, seq_len, d_model,
            layer->w_ff1, d_ff, layer->w_ff2,
            1, ffn_out, pre_act);
        free(norm2);
        free(pre_act);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += ffn_out[i];
        free(ffn_out);
    }

    double *last_hidden = x + (seq_len - 1) * d_model;
    for (int j = 0; j < model->config.vocab_size; j++) {
        double sum = 0.0;
        for (int k = 0; k < d_model; k++) {
            sum += last_hidden[k] * model->output_proj[k * model->config.vocab_size + j];
        }
        logits_out[j] = sum;
    }

    free(x);
}

static int is_whitespace(int c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static int is_common_token(int c) {
    return c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u' ||
           c == 't' || c == 'h' || c == 'n' || c == 's' || c == 'r' ||
           c == '.' || c == ',' || c == '!' || c == '?' || c == '\'' || c == ':';
}

static char* generate_response(const char *prompt, TransformerModel *model, double temperature, int max_tokens) {
    int vocab_size = model->config.vocab_size;
    int max_seq_len = model->config.max_seq_len;

    int prompt_len = strlen(prompt);
    int *token_ids = calloc(max_seq_len * 4, sizeof(int));
    int num_tokens = prompt_len < max_seq_len ? prompt_len : max_seq_len;
    for (int i = 0; i < num_tokens; i++) {
        token_ids[i] = ((unsigned char)prompt[i]) % vocab_size;
    }

    int total_tokens = num_tokens;
    char *output = calloc(max_tokens + 1, 1);
    int output_len = 0;

    int *token_counts = calloc(vocab_size, sizeof(int));

    for (int step = 0; step < max_tokens; step++) {
        int ctx_start = total_tokens > max_seq_len ? total_tokens - max_seq_len : 0;
        int ctx_len = total_tokens - ctx_start;

        double *logits = calloc(vocab_size, sizeof(double));
        native_forward(token_ids + ctx_start, ctx_len, model, logits);

        for (int i = 0; i < vocab_size; i++) logits[i] /= temperature;

        for (int i = 0; i < vocab_size; i++) {
            if (token_counts[i] > 0) {
                if (is_whitespace(i)) {
                    // No penalty for whitespace
                } else if (is_common_token(i)) {
                    logits[i] -= 0.5 * token_counts[i];
                } else {
                    logits[i] -= 2.0 * token_counts[i];
                }
            }
        }

        double max_logit = logits[0];
        for (int i = 1; i < vocab_size; i++) if (logits[i] > max_logit) max_logit = logits[i];
        double sum = 0.0;
        for (int i = 0; i < vocab_size; i++) { logits[i] = exp(logits[i] - max_logit); sum += logits[i]; }
        for (int i = 0; i < vocab_size; i++) logits[i] /= sum;

        double r = (double)rand() / RAND_MAX;
        double cumsum = 0.0;
        int next_token = 0;
        for (int i = 0; i < vocab_size; i++) {
            cumsum += logits[i];
            if (r <= cumsum) { next_token = i; break; }
        }
        free(logits);

        token_counts[next_token]++;

        if (total_tokens < max_seq_len * 4) {
            token_ids[total_tokens++] = next_token;
        }

        if (next_token > 0 && next_token < 128) {
            output[output_len++] = (char)next_token;
        }

        if (next_token == '\n' || next_token == 0) break;
        if (output_len > 3 && (output[output_len-1] == '.' || output[output_len-1] == '!' || output[output_len-1] == '?')) {
            int sent_count = 0;
            for (int si = 0; si < output_len; si++) {
                if (output[si] == '.' || output[si] == '!' || output[si] == '?') sent_count++;
            }
            if (sent_count >= 3) break;
            if (output_len <= 18) break;

            double *peek_logits = calloc(vocab_size, sizeof(double));
            int peek_ctx_start = total_tokens > max_seq_len ? total_tokens - max_seq_len : 0;
            int peek_ctx_len = total_tokens - peek_ctx_start;
            native_forward(token_ids + peek_ctx_start, peek_ctx_len, model, peek_logits);
            double peek_max = peek_logits[0];
            for (int i = 1; i < vocab_size; i++) if (peek_logits[i] > peek_max) peek_max = peek_logits[i];
            double peek_sum = 0.0;
            for (int i = 0; i < vocab_size; i++) { peek_logits[i] = exp(peek_logits[i] - peek_max); peek_sum += peek_logits[i]; }
            double space_prob = peek_logits[' '] / peek_sum;
            free(peek_logits);
            if (space_prob < 0.3) break;
        }
    }
    free(token_counts);

    output[output_len] = '\0';
    free(token_ids);
    return output;
}

/* ================================================================
 * NATIVE TRAINING PIPELINE
 * ================================================================ */

int g_model_age = 0;
int g_training_samples = 0;

static void layer_norm_backward(double *d_out, double *x_norm, double *gamma, double std_val, int d_model,
                                 double *d_x, double *d_gamma, double *d_beta) {
    double *d_x_norm_vec = calloc(d_model, sizeof(double));
    for (int j = 0; j < d_model; j++) {
        d_gamma[j] += d_out[j] * x_norm[j];
        d_beta[j] += d_out[j];
        d_x_norm_vec[j] = d_out[j] * gamma[j];
    }
    double mean_d = 0.0, mean_xd = 0.0;
    for (int j = 0; j < d_model; j++) {
        mean_d += d_x_norm_vec[j];
        mean_xd += d_x_norm_vec[j] * x_norm[j];
    }
    mean_d /= d_model;
    mean_xd /= d_model;
    for (int j = 0; j < d_model; j++) {
        d_x[j] = (d_x_norm_vec[j] - mean_d - x_norm[j] * mean_xd) / std_val;
    }
    free(d_x_norm_vec);
}

static double cross_entropy_loss(double *logits, int target_id, int vocab_size, double *probs_out) {
    double max_l = logits[0];
    for (int i = 1; i < vocab_size; i++) if (logits[i] > max_l) max_l = logits[i];
    double sum = 0.0;
    for (int i = 0; i < vocab_size; i++) { probs_out[i] = exp(logits[i] - max_l); sum += probs_out[i]; }
    for (int i = 0; i < vocab_size; i++) probs_out[i] /= sum;
    double tp = probs_out[target_id];
    if (tp < 1e-10) tp = 1e-10;
    return -log(tp);
}

static void native_forward_with_cache(int *token_ids, int seq_len, TransformerModel *model, double *logits_out, TrainingCache *cache) {
    int d_model = model->config.d_model;
    int d_ff = model->config.d_ff;
    int n_layers = model->config.n_layers;

    double *x = calloc(seq_len * d_model, sizeof(double));
    for (int i = 0; i < seq_len; i++) {
        int tid = token_ids[i];
        if (tid < 0) tid = 0;
        if (tid >= model->config.vocab_size) tid = model->config.vocab_size - 1;
        memcpy(x + i * d_model, model->token_embeddings + tid * d_model, d_model * sizeof(double));
    }

    double *pe = calloc(seq_len * d_model, sizeof(double));
    create_sinusoidal_pe(pe, seq_len, d_model);
    for (int i = 0; i < seq_len * d_model; i++) x[i] += pe[i];
    free(pe);

    cache->seq_len = seq_len;

    for (int l = 0; l < n_layers; l++) {
        TransformerLayer *layer = &model->layers[l];
        int lsd = l * seq_len * d_model;
        int lss = l * seq_len * seq_len;
        int lsf = l * seq_len * d_ff;
        int ls = l * seq_len;

        memcpy(cache->layer_inputs + lsd, x, seq_len * d_model * sizeof(double));

        double *norm1 = calloc(seq_len * d_model, sizeof(double));
        for (int i = 0; i < seq_len; i++) {
            double *xi = x + i * d_model;
            double *out = norm1 + i * d_model;
            double mean = 0.0;
            for (int j = 0; j < d_model; j++) mean += xi[j];
            mean /= d_model;
            double var = 0.0;
            for (int j = 0; j < d_model; j++) { double d = xi[j] - mean; var += d * d; }
            var /= d_model;
            double std_val = sqrt(var + 1e-5);
            for (int j = 0; j < d_model; j++) {
                double xn = (xi[j] - mean) / std_val;
                cache->ln1_x_norm[lsd + i * d_model + j] = xn;
                out[j] = layer->ln1_gamma[j] * xn + layer->ln1_beta[j];
            }
            cache->ln1_std[ls + i] = std_val;
        }
        memcpy(cache->norm1_outputs + lsd, norm1, seq_len * d_model * sizeof(double));

        double *attn_out = calloc(seq_len * d_model, sizeof(double));
        ne_fused_attention_forward_buf(norm1, seq_len, d_model,
            layer->w_q, layer->w_k, layer->w_v, layer->w_o,
            attn_out, cache->attn_probs + lss);
        free(norm1);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += attn_out[i];
        free(attn_out);

        memcpy(cache->post_attn_x + lsd, x, seq_len * d_model * sizeof(double));

        double *norm2 = calloc(seq_len * d_model, sizeof(double));
        for (int i = 0; i < seq_len; i++) {
            double *xi = x + i * d_model;
            double *out = norm2 + i * d_model;
            double mean = 0.0;
            for (int j = 0; j < d_model; j++) mean += xi[j];
            mean /= d_model;
            double var = 0.0;
            for (int j = 0; j < d_model; j++) { double d = xi[j] - mean; var += d * d; }
            var /= d_model;
            double std_val = sqrt(var + 1e-5);
            for (int j = 0; j < d_model; j++) {
                double xn = (xi[j] - mean) / std_val;
                cache->ln2_x_norm[lsd + i * d_model + j] = xn;
                out[j] = layer->ln2_gamma[j] * xn + layer->ln2_beta[j];
            }
            cache->ln2_std[ls + i] = std_val;
        }
        memcpy(cache->norm2_outputs + lsd, norm2, seq_len * d_model * sizeof(double));

        double *ffn_out = calloc(seq_len * d_model, sizeof(double));
        ne_fused_ffn_forward_buf(norm2, seq_len, d_model,
            layer->w_ff1, d_ff, layer->w_ff2,
            1, ffn_out, cache->ffn_pre_act + lsf);
        free(norm2);

        for (int i = 0; i < seq_len * d_model; i++) x[i] += ffn_out[i];
        free(ffn_out);
    }

    memcpy(cache->final_x, x, seq_len * d_model * sizeof(double));

    double *last_hidden = x + (seq_len - 1) * d_model;
    for (int j = 0; j < model->config.vocab_size; j++) {
        double sum = 0.0;
        for (int k = 0; k < d_model; k++) {
            sum += last_hidden[k] * model->output_proj[k * model->config.vocab_size + j];
        }
        logits_out[j] = sum;
    }
    free(x);
}

static void sanitize_training_text(const char *src, char *dst, int max_len) {
    int di = 0;
    for (int i = 0; src[i] && di < max_len - 1; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c < 32 && c != '\n' && c != '\t') continue;
        if (c == 127) continue;
        if (c == '\'' || c == '\x60') { dst[di++] = ' '; continue; }
        if (c == '"') { dst[di++] = ' '; continue; }
        if (c == '\\') { dst[di++] = ' '; continue; }
        if (c >= 128) { dst[di++] = ' '; continue; }
        dst[di++] = (char)c;
    }
    dst[di] = '\0';
}

static int native_train_step(const char *input_text, const char *output_text, double learning_rate, double *loss_out, int *tokens_trained_out) {
    if (!g_model.loaded) return -1;

    int vocab_size = g_model.config.vocab_size;
    int d_model = g_model.config.d_model;
    int d_ff = g_model.config.d_ff;
    int n_layers = g_model.config.n_layers;
    int max_seq_len = g_model.config.max_seq_len;

    double effective_lr = learning_rate / log((double)g_model_age + M_E);

    char *clean_input = calloc(strlen(input_text) + 1, 1);
    char *clean_output = calloc(strlen(output_text) + 1, 1);
    sanitize_training_text(input_text, clean_input, strlen(input_text) + 1);
    sanitize_training_text(output_text, clean_output, strlen(output_text) + 1);

    int input_len = strlen(clean_input);
    int output_len = strlen(clean_output);
    int full_len = input_len + output_len;
    int *token_ids = calloc(full_len, sizeof(int));
    for (int i = 0; i < input_len; i++) token_ids[i] = ((unsigned char)clean_input[i]) % vocab_size;
    for (int i = 0; i < output_len; i++) token_ids[input_len + i] = ((unsigned char)clean_output[i]) % vocab_size;
    free(clean_input);
    free(clean_output);

    if (full_len < 2) { free(token_ids); return -1; }

    double *grad_token_emb = calloc(vocab_size * d_model, sizeof(double));
    double *grad_output_proj = calloc(d_model * vocab_size, sizeof(double));

    double **lg_wq = calloc(n_layers, sizeof(double*));
    double **lg_wk = calloc(n_layers, sizeof(double*));
    double **lg_wv = calloc(n_layers, sizeof(double*));
    double **lg_wo = calloc(n_layers, sizeof(double*));
    double **lg_ff1 = calloc(n_layers, sizeof(double*));
    double **lg_ff2 = calloc(n_layers, sizeof(double*));
    double **lg_ln1g = calloc(n_layers, sizeof(double*));
    double **lg_ln1b = calloc(n_layers, sizeof(double*));
    double **lg_ln2g = calloc(n_layers, sizeof(double*));
    double **lg_ln2b = calloc(n_layers, sizeof(double*));
    for (int l = 0; l < n_layers; l++) {
        lg_wq[l] = calloc(d_model * d_model, sizeof(double));
        lg_wk[l] = calloc(d_model * d_model, sizeof(double));
        lg_wv[l] = calloc(d_model * d_model, sizeof(double));
        lg_wo[l] = calloc(d_model * d_model, sizeof(double));
        lg_ff1[l] = calloc(d_model * d_ff, sizeof(double));
        lg_ff2[l] = calloc(d_ff * d_model, sizeof(double));
        lg_ln1g[l] = calloc(d_model, sizeof(double));
        lg_ln1b[l] = calloc(d_model, sizeof(double));
        lg_ln2g[l] = calloc(d_model, sizeof(double));
        lg_ln2b[l] = calloc(d_model, sizeof(double));
    }

    double total_loss = 0.0;
    int num_tokens = 0;

    int max_ctx = max_seq_len < full_len ? max_seq_len : full_len;
    TrainingCache cache;
    cache.layer_inputs = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.norm1_outputs = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.norm2_outputs = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.attn_probs = calloc(n_layers * max_ctx * max_ctx, sizeof(double));
    cache.ffn_pre_act = calloc(n_layers * max_ctx * d_ff, sizeof(double));
    cache.post_attn_x = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.final_x = calloc(max_ctx * d_model, sizeof(double));
    cache.ln1_x_norm = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.ln1_std = calloc(n_layers * max_ctx, sizeof(double));
    cache.ln2_x_norm = calloc(n_layers * max_ctx * d_model, sizeof(double));
    cache.ln2_std = calloc(n_layers * max_ctx, sizeof(double));

    for (int t = 0; t < full_len - 1; t++) {
        int ctx_len = t + 1;
        if (ctx_len > max_seq_len) ctx_len = max_seq_len;
        int ctx_start = (t + 1) - ctx_len;
        int target_id = token_ids[t + 1];

        memset(cache.layer_inputs, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.norm1_outputs, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.norm2_outputs, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.attn_probs, 0, n_layers * ctx_len * ctx_len * sizeof(double));
        memset(cache.ffn_pre_act, 0, n_layers * ctx_len * d_ff * sizeof(double));
        memset(cache.post_attn_x, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.ln1_x_norm, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.ln1_std, 0, n_layers * ctx_len * sizeof(double));
        memset(cache.ln2_x_norm, 0, n_layers * ctx_len * d_model * sizeof(double));
        memset(cache.ln2_std, 0, n_layers * ctx_len * sizeof(double));

        double *logits = calloc(vocab_size, sizeof(double));
        native_forward_with_cache(token_ids + ctx_start, ctx_len, &g_model, logits, &cache);

        double *probs = calloc(vocab_size, sizeof(double));
        double loss = cross_entropy_loss(logits, target_id, vocab_size, probs);
        total_loss += loss;
        num_tokens++;
        free(logits);

        double *d_logits = calloc(vocab_size, sizeof(double));
        memcpy(d_logits, probs, vocab_size * sizeof(double));
        d_logits[target_id] -= 1.0;
        free(probs);

        double *last_hidden = cache.final_x + (ctx_len - 1) * d_model;
        for (int k = 0; k < d_model; k++) {
            for (int j = 0; j < vocab_size; j++) {
                grad_output_proj[k * vocab_size + j] += last_hidden[k] * d_logits[j];
            }
        }

        double *d_x = calloc(ctx_len * d_model, sizeof(double));
        for (int k = 0; k < d_model; k++) {
            double sum = 0.0;
            for (int j = 0; j < vocab_size; j++) {
                sum += g_model.output_proj[k * vocab_size + j] * d_logits[j];
            }
            d_x[(ctx_len - 1) * d_model + k] = sum;
        }
        free(d_logits);

        for (int l = n_layers - 1; l >= 0; l--) {
            TransformerLayer *layer = &g_model.layers[l];
            int lsd = l * ctx_len * d_model;
            int lss = l * ctx_len * ctx_len;
            int lsf = l * ctx_len * d_ff;
            int ls = l * ctx_len;

            double *d_ffn_w1 = calloc(d_model * d_ff, sizeof(double));
            double *d_ffn_w2 = calloc(d_ff * d_model, sizeof(double));
            double *d_norm2_out = calloc(ctx_len * d_model, sizeof(double));
            ne_fused_ffn_backward_buf(d_x, ctx_len, d_model,
                cache.norm2_outputs + lsd, layer->w_ff1, d_ff, layer->w_ff2,
                cache.ffn_pre_act + lsf, d_ffn_w1, d_ffn_w2, d_norm2_out);
            for (int i = 0; i < d_model * d_ff; i++) lg_ff1[l][i] += d_ffn_w1[i];
            for (int i = 0; i < d_ff * d_model; i++) lg_ff2[l][i] += d_ffn_w2[i];
            free(d_ffn_w1); free(d_ffn_w2);

            double *d_post_attn = calloc(ctx_len * d_model, sizeof(double));
            for (int i = 0; i < ctx_len; i++) {
                double d_ln_x[MAX_D_MODEL] = {0};
                layer_norm_backward(d_norm2_out + i * d_model,
                    cache.ln2_x_norm + lsd + i * d_model,
                    layer->ln2_gamma, cache.ln2_std[ls + i], d_model,
                    d_ln_x, lg_ln2g[l], lg_ln2b[l]);
                for (int j = 0; j < d_model; j++)
                    d_post_attn[i * d_model + j] = d_x[i * d_model + j] + d_ln_x[j];
            }
            free(d_norm2_out);

            double *d_attn_wq = calloc(d_model * d_model, sizeof(double));
            double *d_attn_wk = calloc(d_model * d_model, sizeof(double));
            double *d_attn_wv = calloc(d_model * d_model, sizeof(double));
            double *d_attn_wo = calloc(d_model * d_model, sizeof(double));
            double *d_norm1_out = calloc(ctx_len * d_model, sizeof(double));
            ne_fused_attention_backward_buf(d_post_attn, ctx_len, d_model,
                cache.norm1_outputs + lsd,
                layer->w_q, layer->w_k, layer->w_v, layer->w_o,
                cache.attn_probs + lss,
                d_attn_wq, d_attn_wk, d_attn_wv, d_attn_wo, d_norm1_out);
            for (int i = 0; i < d_model * d_model; i++) {
                lg_wq[l][i] += d_attn_wq[i];
                lg_wk[l][i] += d_attn_wk[i];
                lg_wv[l][i] += d_attn_wv[i];
                lg_wo[l][i] += d_attn_wo[i];
            }
            free(d_attn_wq); free(d_attn_wk); free(d_attn_wv); free(d_attn_wo);

            double *d_pre_attn = calloc(ctx_len * d_model, sizeof(double));
            for (int i = 0; i < ctx_len; i++) {
                double d_ln_x[MAX_D_MODEL] = {0};
                layer_norm_backward(d_norm1_out + i * d_model,
                    cache.ln1_x_norm + lsd + i * d_model,
                    layer->ln1_gamma, cache.ln1_std[ls + i], d_model,
                    d_ln_x, lg_ln1g[l], lg_ln1b[l]);
                for (int j = 0; j < d_model; j++)
                    d_pre_attn[i * d_model + j] = d_post_attn[i * d_model + j] + d_ln_x[j];
            }
            free(d_post_attn); free(d_norm1_out);

            memcpy(d_x, d_pre_attn, ctx_len * d_model * sizeof(double));
            free(d_pre_attn);
        }

        for (int i = 0; i < ctx_len; i++) {
            int tok = token_ids[ctx_start + i];
            if (tok >= 0 && tok < vocab_size) {
                for (int j = 0; j < d_model; j++)
                    grad_token_emb[tok * d_model + j] += d_x[i * d_model + j];
            }
        }
        free(d_x);
    }

    double avg_loss = num_tokens > 0 ? total_loss / num_tokens : 0.0;

    if (isnan(avg_loss) || isinf(avg_loss)) {
        fprintf(stderr, "[train-guard] NaN/Inf loss detected (%.4f) - SKIPPING weight update to prevent corruption\n", avg_loss);
        *loss_out = 0.0;
        *tokens_trained_out = 0;
        free(token_ids); free(grad_token_emb); free(grad_output_proj);
        for (int l = 0; l < n_layers; l++) {
            free(lg_wq[l]); free(lg_wk[l]); free(lg_wv[l]); free(lg_wo[l]);
            free(lg_ff1[l]); free(lg_ff2[l]);
            free(lg_ln1g[l]); free(lg_ln1b[l]); free(lg_ln2g[l]); free(lg_ln2b[l]);
        }
        free(lg_wq); free(lg_wk); free(lg_wv); free(lg_wo);
        free(lg_ff1); free(lg_ff2);
        free(lg_ln1g); free(lg_ln1b); free(lg_ln2g); free(lg_ln2b);
        free(cache.layer_inputs); free(cache.norm1_outputs); free(cache.norm2_outputs);
        free(cache.attn_probs); free(cache.ffn_pre_act); free(cache.post_attn_x);
        free(cache.final_x);
        free(cache.ln1_x_norm); free(cache.ln1_std);
        free(cache.ln2_x_norm); free(cache.ln2_std);
        return -1;
    }

    int has_nan_grad = 0;
    for (int i = 0; i < d_model * vocab_size && !has_nan_grad; i++)
        if (isnan(grad_output_proj[i]) || isinf(grad_output_proj[i])) has_nan_grad = 1;
    for (int i = 0; i < vocab_size * d_model && !has_nan_grad; i++)
        if (isnan(grad_token_emb[i]) || isinf(grad_token_emb[i])) has_nan_grad = 1;

    if (has_nan_grad) {
        fprintf(stderr, "[train-guard] NaN/Inf gradient detected - SKIPPING weight update\n");
        *loss_out = 0.0;
        *tokens_trained_out = 0;
        free(token_ids); free(grad_token_emb); free(grad_output_proj);
        for (int l = 0; l < n_layers; l++) {
            free(lg_wq[l]); free(lg_wk[l]); free(lg_wv[l]); free(lg_wo[l]);
            free(lg_ff1[l]); free(lg_ff2[l]);
            free(lg_ln1g[l]); free(lg_ln1b[l]); free(lg_ln2g[l]); free(lg_ln2b[l]);
        }
        free(lg_wq); free(lg_wk); free(lg_wv); free(lg_wo);
        free(lg_ff1); free(lg_ff2);
        free(lg_ln1g); free(lg_ln1b); free(lg_ln2g); free(lg_ln2b);
        free(cache.layer_inputs); free(cache.norm1_outputs); free(cache.norm2_outputs);
        free(cache.attn_probs); free(cache.ffn_pre_act); free(cache.post_attn_x);
        free(cache.final_x);
        free(cache.ln1_x_norm); free(cache.ln1_std);
        free(cache.ln2_x_norm); free(cache.ln2_std);
        return -1;
    }

    for (int i = 0; i < d_model * vocab_size; i++)
        g_model.output_proj[i] -= effective_lr * grad_output_proj[i];
    for (int i = 0; i < vocab_size * d_model; i++)
        g_model.token_embeddings[i] -= effective_lr * grad_token_emb[i];

    double scale = effective_lr * 0.1;
    for (int l = 0; l < n_layers; l++) {
        TransformerLayer *layer = &g_model.layers[l];
        for (int i = 0; i < d_model * d_model; i++) {
            layer->w_q[i] -= scale * lg_wq[l][i];
            layer->w_k[i] -= scale * lg_wk[l][i];
            layer->w_v[i] -= scale * lg_wv[l][i];
            layer->w_o[i] -= scale * lg_wo[l][i];
        }
        for (int i = 0; i < d_model * d_ff; i++) layer->w_ff1[i] -= scale * lg_ff1[l][i];
        for (int i = 0; i < d_ff * d_model; i++) layer->w_ff2[i] -= scale * lg_ff2[l][i];
        for (int i = 0; i < d_model; i++) {
            layer->ln1_gamma[i] -= scale * lg_ln1g[l][i];
            layer->ln1_beta[i] -= scale * lg_ln1b[l][i];
            layer->ln2_gamma[i] -= scale * lg_ln2g[l][i];
            layer->ln2_beta[i] -= scale * lg_ln2b[l][i];
        }
    }

    g_model_age += num_tokens;
    g_training_samples++;

    *loss_out = avg_loss;
    *tokens_trained_out = num_tokens;

    free(token_ids); free(grad_token_emb); free(grad_output_proj);
    for (int l = 0; l < n_layers; l++) {
        free(lg_wq[l]); free(lg_wk[l]); free(lg_wv[l]); free(lg_wo[l]);
        free(lg_ff1[l]); free(lg_ff2[l]);
        free(lg_ln1g[l]); free(lg_ln1b[l]); free(lg_ln2g[l]); free(lg_ln2b[l]);
    }
    free(lg_wq); free(lg_wk); free(lg_wv); free(lg_wo);
    free(lg_ff1); free(lg_ff2);
    free(lg_ln1g); free(lg_ln1b); free(lg_ln2g); free(lg_ln2b);
    free(cache.layer_inputs); free(cache.norm1_outputs); free(cache.norm2_outputs);
    free(cache.attn_probs); free(cache.ffn_pre_act); free(cache.post_attn_x);
    free(cache.final_x);
    free(cache.ln1_x_norm); free(cache.ln1_std);
    free(cache.ln2_x_norm); free(cache.ln2_std);

    return 0;
}

static int save_model_weights(const char *path, TransformerModel *model) {
    int vs = model->config.vocab_size;
    int dm = model->config.d_model;
    int df = model->config.d_ff;
    int nl = model->config.n_layers;

    for (int i = 0; i < vs * dm; i++) {
        if (isnan(model->token_embeddings[i]) || isinf(model->token_embeddings[i])) {
            fprintf(stderr, "[save-guard] NaN/Inf detected in weights - REFUSING to save corrupted model\n");
            return -1;
        }
    }
    for (int i = 0; i < dm * vs; i++) {
        if (isnan(model->output_proj[i]) || isinf(model->output_proj[i])) {
            fprintf(stderr, "[save-guard] NaN/Inf detected in output_proj - REFUSING to save corrupted model\n");
            return -1;
        }
    }

    FILE *f = fopen(path, "w");
    if (!f) return -1;

    fprintf(f, "{\n\"config\": {\"vocab_size\": %d, \"d_model\": %d, \"n_heads\": %d, \"n_layers\": %d, \"d_ff\": %d, \"max_seq_len\": %d},\n",
        vs, dm, model->config.n_heads, nl, df, model->config.max_seq_len);

    fprintf(f, "\"token_embeddings\": [\n");
    for (int i = 0; i < vs; i++) {
        fprintf(f, "[");
        for (int j = 0; j < dm; j++) {
            fprintf(f, "%.17g", model->token_embeddings[i * dm + j]);
            if (j < dm - 1) fprintf(f, ",");
        }
        fprintf(f, "]%s\n", i < vs - 1 ? "," : "");
    }
    fprintf(f, "],\n");

    fprintf(f, "\"output_proj\": [\n");
    for (int i = 0; i < dm; i++) {
        fprintf(f, "[");
        for (int j = 0; j < vs; j++) {
            fprintf(f, "%.17g", model->output_proj[i * vs + j]);
            if (j < vs - 1) fprintf(f, ",");
        }
        fprintf(f, "]%s\n", i < dm - 1 ? "," : "");
    }
    fprintf(f, "],\n");

    fprintf(f, "\"layers\": [\n");
    for (int l = 0; l < nl; l++) {
        TransformerLayer *layer = &model->layers[l];
        fprintf(f, "{\n");

        #define W2D(name, data, rows, cols) do { \
            fprintf(f, "\"%s\": [\n", name); \
            for (int _r = 0; _r < rows; _r++) { \
                fprintf(f, "["); \
                for (int _c = 0; _c < cols; _c++) { \
                    fprintf(f, "%.17g", data[_r * cols + _c]); \
                    if (_c < cols - 1) fprintf(f, ","); \
                } \
                fprintf(f, "]%s\n", _r < rows - 1 ? "," : ""); \
            } \
            fprintf(f, "]"); \
        } while(0)

        #define W1D(name, data, len) do { \
            fprintf(f, "\"%s\": [", name); \
            for (int _i = 0; _i < len; _i++) { \
                fprintf(f, "%.17g", data[_i]); \
                if (_i < len - 1) fprintf(f, ","); \
            } \
            fprintf(f, "]"); \
        } while(0)

        W2D("w_q", layer->w_q, dm, dm); fprintf(f, ",\n");
        W2D("w_k", layer->w_k, dm, dm); fprintf(f, ",\n");
        W2D("w_v", layer->w_v, dm, dm); fprintf(f, ",\n");
        W2D("w_o", layer->w_o, dm, dm); fprintf(f, ",\n");
        W2D("w_ff1", layer->w_ff1, dm, df); fprintf(f, ",\n");
        W2D("w_ff2", layer->w_ff2, df, dm); fprintf(f, ",\n");
        W1D("ln1_gamma", layer->ln1_gamma, dm); fprintf(f, ",\n");
        W1D("ln1_beta", layer->ln1_beta, dm); fprintf(f, ",\n");
        W1D("ln2_gamma", layer->ln2_gamma, dm); fprintf(f, ",\n");
        W1D("ln2_beta", layer->ln2_beta, dm); fprintf(f, "\n");

        #undef W2D
        #undef W1D

        fprintf(f, "}%s\n", l < nl - 1 ? "," : "");
    }
    fprintf(f, "]\n}\n");

    fclose(f);
    return 0;
}

static char* extract_json_string(const char *body, const char *key) {
    static char buf[4096];
    buf[0] = '\0';
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *k = strstr(body, search);
    if (!k) return buf;
    const char *colon = strchr(k + strlen(search), ':');
    if (!colon) return buf;
    const char *q1 = strchr(colon, '"');
    if (!q1) return buf;
    const char *q2 = strchr(q1 + 1, '"');
    while (q2 && *(q2-1) == '\\') q2 = strchr(q2 + 1, '"');
    if (!q2) return buf;
    int len = q2 - q1 - 1;
    if (len > 4095) len = 4095;
    strncpy(buf, q1 + 1, len);
    buf[len] = '\0';
    return buf;
}

Value* builtin_eigen_train(Value *arg) {
    if (!g_model.loaded) return make_str("{\"status\": \"error\", \"error\": \"Model not loaded\"}");

    const char *body = "";
    if (arg && arg->type == VAL_STR) body = arg->data.str;

    char input_text[4096], output_text[4096];
    strncpy(input_text, extract_json_string(body, "input"), 4095); input_text[4095] = '\0';
    strncpy(output_text, extract_json_string(body, "output"), 4095); output_text[4095] = '\0';

    double learning_rate = 0.001;
    const char *lr_key = strstr(body, "\"learning_rate\"");
    if (lr_key) {
        const char *colon = strchr(lr_key + 15, ':');
        if (colon) { while (*colon == ':' || *colon == ' ') colon++; learning_rate = strtod(colon, NULL); }
        if (learning_rate <= 0 || learning_rate > 1) learning_rate = 0.001;
    }

    if (input_text[0] == '\0' || output_text[0] == '\0')
        return make_str("{\"status\": \"error\", \"error\": \"Both input and output required\"}");

    char formatted_input[8192];
    char formatted_output[4096];
    snprintf(formatted_input, sizeof(formatted_input), "User: %s\nEigen:", input_text);
    snprintf(formatted_output, sizeof(formatted_output), " %s", output_text);

    double loss = 0.0;
    int tokens_trained = 0;
    int result = native_train_step(formatted_input, formatted_output, learning_rate, &loss, &tokens_trained);

    if (result == 0) {
        char buf[1024];
        snprintf(buf, sizeof(buf),
            "{\"status\": \"trained\", \"loss\": %.6f, \"tokens_trained\": %d, \"model_age\": %d, \"training_samples\": %d, \"effective_lr\": %.6f, \"engine\": \"native_c\"}",
            loss, tokens_trained, g_model_age, g_training_samples, learning_rate / log((double)g_model_age + M_E));
        return make_str(buf);
    }
    return make_str("{\"status\": \"error\", \"error\": \"Training step failed\"}");
}

Value* builtin_eigen_batch_train(Value *arg) {
    (void)arg;
    if (!g_model.loaded) return make_str("{\"status\": \"error\", \"error\": \"Model not loaded\"}");
    if (!g_db_conn) return make_str("{\"status\": \"error\", \"error\": \"Database not connected\"}");

    PGresult *res = PQexec(g_db_conn, "SELECT input_text, output_text FROM training_data ORDER BY RANDOM() LIMIT 20");
    if (PQresultStatus(res) != PGRES_TUPLES_OK) { PQclear(res); return make_str("{\"status\": \"error\", \"error\": \"Failed to fetch training data\"}"); }

    int nrows = PQntuples(res);
    if (nrows == 0) { PQclear(res); return make_str("{\"status\": \"error\", \"error\": \"No training data\"}"); }

    double total_loss = 0.0; int total_tokens = 0, trained = 0;
    for (int i = 0; i < nrows; i++) {
        double loss = 0.0; int tokens = 0;
        if (native_train_step(PQgetvalue(res, i, 0), PQgetvalue(res, i, 1), 0.001, &loss, &tokens) == 0) {
            total_loss += loss * tokens; total_tokens += tokens; trained++;
        }
    }
    PQclear(res);

    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"status\": \"trained\", \"samples_trained\": %d, \"total_tokens\": %d, \"avg_loss\": %.6f, \"model_age\": %d, \"engine\": \"native_c\"}",
        trained, total_tokens, total_tokens > 0 ? total_loss / total_tokens : 0.0, g_model_age);
    return make_str(buf);
}

Value* builtin_model_save(Value *arg) {
    const char *path = "../../checkpoints/eigenscript/model_live.json";
    if (arg && arg->type == VAL_STR && arg->data.str[0] != '\0' && arg->data.str[0] != '{') {
        const char *orig = arg->data.str;
        static char save_live_path[512];
        int olen = strlen(orig);
        if (olen > 5 && strcmp(orig + olen - 5, ".json") == 0) {
            snprintf(save_live_path, sizeof(save_live_path), "%.*s_live.json", olen - 5, orig);
            path = save_live_path;
        } else {
            path = orig;
        }
    }

    printf("Saving model to: %s\n", path); fflush(stdout);
    int result = save_model_weights(path, &g_model);
    if (result == 0) {
        char buf[512];
        snprintf(buf, sizeof(buf),
            "{\"status\": \"saved\", \"path\": \"%s\", \"model_age\": %d, \"training_samples\": %d}",
            path, g_model_age, g_training_samples);
        return make_str(buf);
    }
    return make_str("{\"status\": \"error\", \"error\": \"Failed to save model\"}");
}

/* ================================================================
 * REAL BUILTIN IMPLEMENTATIONS
 * ================================================================ */

Value* builtin_eigen_model_load(Value *arg) {
    const char *base_path = "";
    if (arg && arg->type == VAL_STR) base_path = arg->data.str;

    char live_path[512];
    const char *path = base_path;
    int base_len = strlen(base_path);
    if (base_len > 5 && strcmp(base_path + base_len - 5, ".json") == 0) {
        snprintf(live_path, sizeof(live_path), "%.*s_live.json", base_len - 5, base_path);
        FILE *f = fopen(live_path, "r");
        if (f) {
            fclose(f);
            path = live_path;
            fprintf(stderr, "[model-load] Found live weights: %s\n", live_path);
        } else {
            fprintf(stderr, "[model-load] No live weights, using locked baseline: %s\n", base_path);
        }
    }

    printf("Loading model from: %s\n", path);
    fflush(stdout);

    int result = load_model_weights(path, &g_model);

    if (result == 0) {
        char buf[512];
        snprintf(buf, sizeof(buf),
            "{\"status\": \"loaded\", \"vocab_size\": %d, \"n_layers\": %d, \"d_model\": %d, \"d_ff\": %d, \"path\": \"%s\"}",
            g_model.config.vocab_size, g_model.config.n_layers, g_model.config.d_model, g_model.config.d_ff, path);
        return make_str(buf);
    } else {
        return make_str("{\"status\": \"error\", \"error\": \"Failed to load model weights\"}");
    }
}

static int g_conversation_count = 0;

static const char *g_common_words[] = {
    "i", "a", "am", "an", "as", "at", "be", "by", "do", "go", "he", "if",
    "in", "is", "it", "me", "my", "no", "of", "on", "or", "so", "to", "up",
    "us", "we", "the", "and", "for", "are", "but", "not", "you", "all", "any",
    "can", "had", "has", "her", "him", "his", "how", "its", "may", "new",
    "now", "old", "our", "out", "own", "say", "she", "too", "two", "use",
    "who", "why", "yes", "was", "did", "get", "got", "let", "put", "run",
    "set", "try", "way", "day", "man", "big", "see", "ask", "own",
    "hello", "hi", "hey", "thanks", "thank", "good", "well", "help", "know",
    "like", "just", "about", "doing", "great", "here", "name", "what", "your",
    "been", "come", "each", "find", "from", "gave", "have", "keep", "last",
    "long", "look", "made", "many", "more", "much", "must", "need", "only",
    "over", "said", "some", "take", "tell", "than", "that", "them", "then",
    "they", "this", "time", "very", "want", "were", "will", "with", "work",
    "year", "eigen", "sure", "feel", "fine", "glad", "happy", "real",
    "haha", "lol", "nice", "cool", "love", "best", "also", "back", "give",
    "goodbye", "bye", "morning", "evening", "night", "welcome", "sorry",
    "joke", "funny", "laugh", "smart", "learn", "chat", "talk", "answer",
    "question", "wonder", "today", "tomorrow", "yesterday", "life",
    "make", "most", "such", "used", "call", "first", "could", "would",
    "should", "being", "after", "other", "still", "thing", "think", "those",
    "where", "which", "while", "world", "right", "never", "every",
    "doing", "there", "their", "these", "might", "quite", "really",
    "please", "always", "people", "thanks", "don",
    "ai", "eigenscript", "observermodel", "observeranalyzer", "observe",
    "observation", "observer", "effect", "geometry", "geometric",
    "watch", "step", "result", "final", "measure", "changed",
    "track", "happen", "state", "output", "changes", "language",
    "finds", "models", "mode", "strict", "endpoint", "holonomy",
    "temporal", "when", "things", "jon", "mcreynolds", NULL
};

static void sanitize_input(char *str) {
    int r = 0, w = 0;
    while (str[r]) {
        unsigned char c = (unsigned char)str[r];
        if (c >= 0x20 && c <= 0x7E) {
            str[w++] = str[r];
        }
        r++;
    }
    str[w] = '\0';
    int start = 0;
    while (str[start] == ' ') start++;
    if (start > 0) {
        int i = 0;
        while (str[start + i]) { str[i] = str[start + i]; i++; }
        str[i] = '\0';
        w = i;
    }
    while (w > 0 && str[w - 1] == ' ') str[--w] = '\0';
}

static int is_trained_prompt(const char *input) {
    static const char *trained_prompts[] = {
        "Hello", "Hi", "What are you?", "Are you human?",
        "What is your name?", "What do you do?", "How do you learn?",
        "Are you intelligent?", "What can you do?", "Who made you?",
        "What does observe mean?", "Why Observer Effect?",
        "What is ObserverModel?", "What is STRICT mode?",
        "What is ENDPOINT mode?", "What is HOLONOMY mode?",
        "What is TEMPORAL mode?", "What is EigenScript?",
        "What does ObserverAnalyzer do?", "How do you think?",
        "Are you the Eigen C++ library?",
        NULL
    };
    for (int i = 0; trained_prompts[i]; i++) {
        if (strcasecmp(input, trained_prompts[i]) == 0) return 1;
    }
    return 0;
}

static int is_known_word(const char *word, int wlen) {
    char lower[64];
    if (wlen >= 64) return 0;
    for (int i = 0; i < wlen; i++) {
        lower[i] = (word[i] >= 'A' && word[i] <= 'Z') ? word[i] + 32 : word[i];
        if (lower[i] == '.' || lower[i] == ',' || lower[i] == '!' ||
            lower[i] == '?' || lower[i] == '\'' || lower[i] == '"') {
            wlen = i;
            break;
        }
    }
    lower[wlen] = '\0';
    if (wlen == 0) return 1;

    for (int i = 0; g_common_words[i]; i++) {
        if (strcmp(lower, g_common_words[i]) == 0) return 1;
    }
    return 0;
}

static int is_garble_response(const char *text) {
    if (!text || text[0] == '\0') return 1;
    int len = strlen(text);
    if (len < 2) return 1;

    int control = 0;
    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c < 0x20 && c != '\t' && c != '\n') control++;
    }
    if (control > 0) return 1;

    int alpha = 0;
    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) alpha++;
    }
    if (len > 0 && (alpha * 100 / len) < 40) return 1;

    int repeated = 0;
    for (int i = 1; i < len; i++) {
        if (text[i] == text[i-1] && text[i] != ' ') repeated++;
    }
    if (len > 4 && (repeated * 100 / len) > 40) return 1;

    int words = 0, known = 0, known_3plus = 0, unknown_count = 0;
    int in_word = 0;
    int word_start = 0;
    for (int i = 0; i <= len; i++) {
        if (i < len && text[i] != ' ' && text[i] != '\t' && text[i] != '\n') {
            if (!in_word) { in_word = 1; word_start = i; }
        } else {
            if (in_word) {
                int wlen = i - word_start;
                int plen = wlen;
                for (int j = 0; j < wlen; j++) {
                    char c = text[word_start + j];
                    if (c == '.' || c == ',' || c == '!' || c == '?') { plen = j; break; }
                }
                words++;
                if (is_known_word(text + word_start, wlen)) {
                    known++;
                    if (plen >= 3) known_3plus++;
                } else {
                    unknown_count++;
                }
                in_word = 0;
            }
        }
    }

    if (words == 0) return 1;
    if (words == 1 && known == 1) return 0;
    if (words == 1 && known == 0) return 1;

    if (words <= 4 && known_3plus == 0 && unknown_count > 0) return 1;

    if (words >= 2 && unknown_count > 0 && known_3plus < 2) return 1;

    int match_pct = (known * 100) / words;
    if (match_pct < 60) return 1;

    return 0;
}

#define REPLAY_BUFFER_SIZE 32
#define REPLAY_TARGET_LOSS 3.0
#define REPLAY_MAX_PASSES 50
#define REPLAY_PASSES_PER_REQUEST 5

typedef struct {
    char question[512];
    char answer[1024];
    double last_loss;
    int train_count;
    int converged;
} ReplayEntry;

static ReplayEntry g_replay_buffer[REPLAY_BUFFER_SIZE];
static int g_replay_count = 0;
static int g_replay_total_trained = 0;

static void replay_buffer_add(const char *question, const char *answer, double initial_loss) {
    for (int i = 0; i < g_replay_count; i++) {
        if (strcmp(g_replay_buffer[i].question, question) == 0) {
            if (initial_loss < g_replay_buffer[i].last_loss) {
                g_replay_buffer[i].last_loss = initial_loss;
            }
            g_replay_buffer[i].train_count++;
            return;
        }
    }

    int slot = g_replay_count;
    if (slot >= REPLAY_BUFFER_SIZE) {
        int worst = 0;
        for (int i = 1; i < REPLAY_BUFFER_SIZE; i++) {
            if (g_replay_buffer[i].converged && !g_replay_buffer[worst].converged) { worst = i; continue; }
            if (g_replay_buffer[i].converged == g_replay_buffer[worst].converged &&
                g_replay_buffer[i].train_count > g_replay_buffer[worst].train_count) worst = i;
        }
        slot = worst;
    } else {
        g_replay_count++;
    }

    strncpy(g_replay_buffer[slot].question, question, 511);
    g_replay_buffer[slot].question[511] = '\0';
    strncpy(g_replay_buffer[slot].answer, answer, 1023);
    g_replay_buffer[slot].answer[1023] = '\0';
    g_replay_buffer[slot].last_loss = initial_loss;
    g_replay_buffer[slot].train_count = 1;
    g_replay_buffer[slot].converged = 0;
    fprintf(stderr, "[replay-buffer] Added: \"%s\" (initial loss=%.4f, buffer=%d/%d)\n",
        question, initial_loss, g_replay_count, REPLAY_BUFFER_SIZE);
}

static void replay_buffer_run(void) {
    int unconverged = 0;
    for (int i = 0; i < g_replay_count; i++) {
        if (!g_replay_buffer[i].converged) unconverged++;
    }
    if (unconverged == 0) return;

    int trained_this_round = 0;
    for (int i = 0; i < g_replay_count && trained_this_round < REPLAY_PASSES_PER_REQUEST; i++) {
        ReplayEntry *e = &g_replay_buffer[i];
        if (e->converged || e->train_count >= REPLAY_MAX_PASSES) {
            if (!e->converged) {
                e->converged = 1;
                fprintf(stderr, "[replay-buffer] Max passes reached for: \"%s\" (loss=%.4f after %d passes)\n",
                    e->question, e->last_loss, e->train_count);
            }
            continue;
        }

        char fmt_input[2048];
        char fmt_output[2048];
        snprintf(fmt_input, sizeof(fmt_input), "User: %s\nEigen:", e->question);
        snprintf(fmt_output, sizeof(fmt_output), " %s", e->answer);

        double loss = 0.0;
        int tokens = 0;
        double lr = 0.01 / (1.0 + e->train_count * 0.05);
        if (native_train_step(fmt_input, fmt_output, lr, &loss, &tokens) == 0) {
            e->last_loss = loss;
            e->train_count++;
            trained_this_round++;
            g_replay_total_trained++;

            if (loss < REPLAY_TARGET_LOSS) {
                e->converged = 1;
                fprintf(stderr, "[replay-buffer] CONVERGED: \"%s\" -> loss=%.4f after %d passes (target=%.1f)\n",
                    e->question, loss, e->train_count, REPLAY_TARGET_LOSS);
            } else {
                fprintf(stderr, "[replay-buffer] Replay #%d \"%s\" loss=%.4f (lr=%.6f)\n",
                    e->train_count, e->question, loss, lr);
            }
        }
    }

    int still_unconverged = 0;
    for (int i = 0; i < g_replay_count; i++) {
        if (!g_replay_buffer[i].converged) still_unconverged++;
    }

    if (trained_this_round > 0) {
        fprintf(stderr, "[replay-buffer] Reinforced %d patterns (%d total, %d unconverged remaining)\n",
            trained_this_round, g_replay_total_trained, still_unconverged);
    }
}

static char* call_openai_fallback(const char *user_message) {
    const char *base_url = getenv("AI_INTEGRATIONS_OPENAI_BASE_URL");
    const char *api_key = getenv("AI_INTEGRATIONS_OPENAI_API_KEY");

    if (!base_url || !base_url[0]) {
        base_url = "https://api.openai.com/v1";
    }
    if (!api_key || !api_key[0]) {
        api_key = getenv("OPENAI_API_KEY");
    }
    if (!api_key || !api_key[0]) {
        fprintf(stderr, "[openai-fallback] No API key found\n");
        return NULL;
    }

    char escaped_msg[4096];
    int ei = 0;
    for (int i = 0; user_message[i] && ei < 4090; i++) {
        if (user_message[i] == '"') { escaped_msg[ei++] = '\\'; escaped_msg[ei++] = '"'; }
        else if (user_message[i] == '\\') { escaped_msg[ei++] = '\\'; escaped_msg[ei++] = '\\'; }
        else if (user_message[i] == '\n') { escaped_msg[ei++] = '\\'; escaped_msg[ei++] = 'n'; }
        else if (user_message[i] == '\'') { escaped_msg[ei++] = '\\'; escaped_msg[ei++] = '\''; }
        else escaped_msg[ei++] = user_message[i];
    }
    escaped_msg[ei] = '\0';

    char cmd[8192];
    snprintf(cmd, sizeof(cmd),
        "curl -s --max-time 15 %s/chat/completions "
        "-H 'Content-Type: application/json' "
        "-H 'Authorization: Bearer %s' "
        "-d '{\"model\": \"gpt-5-nano\", \"messages\": ["
        "{\"role\": \"system\", \"content\": \"You are Eigen. Answer in ONE short sentence only. Never exceed 10 words. Be direct.\"},"
        "{\"role\": \"user\", \"content\": \"%s\"}"
        "], \"max_completion_tokens\": 500}' 2>/dev/null",
        base_url, api_key, escaped_msg);

    FILE *fp = popen(cmd, "r");
    if (!fp) {
        fprintf(stderr, "[openai-fallback] popen failed\n");
        return NULL;
    }

    char buf[16384] = {0};
    int total = 0;
    while (total < 16383) {
        int n = fread(buf + total, 1, 16383 - total, fp);
        if (n <= 0) break;
        total += n;
    }
    buf[total] = '\0';
    pclose(fp);

    if (total == 0) {
        fprintf(stderr, "[openai-fallback] Empty response from API\n");
        return NULL;
    }

    const char *content_key = strstr(buf, "\"content\"");
    if (!content_key) {
        fprintf(stderr, "[openai-fallback] No content in response: %.200s\n", buf);
        return NULL;
    }

    const char *colon = strchr(content_key + 9, ':');
    if (!colon) return NULL;
    const char *q1 = strchr(colon, '"');
    if (!q1) return NULL;
    q1++;

    char *result = calloc(4096, 1);
    int ri = 0;
    for (int i = 0; q1[i] && ri < 4090; i++) {
        if (q1[i] == '"' && (i == 0 || q1[i-1] != '\\')) break;
        if (q1[i] == '\\' && q1[i+1] == 'n') { result[ri++] = ' '; i++; continue; }
        if (q1[i] == '\\' && q1[i+1] == '"') { result[ri++] = '"'; i++; continue; }
        if (q1[i] == '\\' && q1[i+1] == '\\') { result[ri++] = '\\'; i++; continue; }
        result[ri++] = q1[i];
    }
    result[ri] = '\0';

    while (ri > 0 && (result[ri-1] == ' ' || result[ri-1] == '\n')) result[--ri] = '\0';

    if (ri == 0) {
        free(result);
        return NULL;
    }

    fprintf(stderr, "[openai-fallback] Got answer for \"%s\": \"%s\"\n", user_message, result);
    return result;
}

Value* builtin_eigen_hybrid_chat(Value *arg) {
    if (!g_model.loaded) {
        return make_str("{\"response\": \"Model not loaded yet. Please train Eigen first!\", \"mode\": \"error\", \"confidence\": 0}");
    }

    const char *body = "";
    if (arg && arg->type == VAL_STR) body = arg->data.str;

    char message[4096] = {0};
    const char *msg_key = strstr(body, "\"message\"");
    if (msg_key) {
        const char *colon = strchr(msg_key + 9, ':');
        if (colon) {
            const char *quote1 = strchr(colon, '"');
            if (quote1) {
                const char *quote2 = strchr(quote1 + 1, '"');
                while (quote2 && *(quote2-1) == '\\') quote2 = strchr(quote2 + 1, '"');
                if (quote2) {
                    int len = quote2 - quote1 - 1;
                    if (len > 4095) len = 4095;
                    strncpy(message, quote1 + 1, len);
                }
            }
        }
    }

    if (message[0] == '\0') {
        strncpy(message, body, sizeof(message) - 1);
    }

    sanitize_input(message);

    char prompt[8192];
    snprintf(prompt, sizeof(prompt), "User: %s\nEigen:", message);

    char *raw_response = generate_response(prompt, &g_model, 0.3, 80);

    char *clean = raw_response;
    char *user_marker = strstr(clean, "User:");
    if (user_marker) *user_marker = '\0';

    while (*clean == ' ' || *clean == '\t' || *clean == '\n') clean++;
    int clen = strlen(clean);
    while (clen > 0 && (clean[clen-1] == ' ' || clean[clen-1] == '\n')) clean[--clen] = '\0';

    int last_good = -1;
    for (int i = clen - 1; i > 5; i--) {
        if (clean[i] == '.' || clean[i] == '!' || clean[i] == '?') {
            int prev_end = -1;
            for (int j = i - 1; j >= 0; j--) {
                if (clean[j] == '.' || clean[j] == '!' || clean[j] == '?') {
                    prev_end = j;
                    break;
                }
            }
            int seg_len = i - prev_end;
            if (prev_end == -1) {
                last_good = i;
                break;
            }
            if (seg_len >= 10) {
                int seg_start = prev_end + 1;
                int word_count = 0;
                int total_word_chars = 0;
                int wl = 0;
                for (int k = seg_start; k <= i; k++) {
                    char ch = clean[k];
                    if (ch == ' ' || ch == '.' || ch == '!' || ch == '?') {
                        if (wl > 0) { word_count++; total_word_chars += wl; wl = 0; }
                    } else {
                        wl++;
                    }
                }
                if (wl > 0) { word_count++; total_word_chars += wl; }
                double avg_wl = word_count > 0 ? (double)total_word_chars / word_count : 0;
                if (avg_wl >= 3.0) {
                    last_good = i;
                    break;
                }
            }
        }
    }
    if (last_good > 5 && last_good < clen - 1) {
        if (last_good + 1 >= 20) {
            clean[last_good + 1] = '\0';
            clen = last_good + 1;
        } else {
            fprintf(stderr, "[trimmer] Skipped trim: result would be %d chars (min 20)\n", last_good + 1);
        }
    }

    int trained_bypass = is_trained_prompt(message);
    int garble_detected = trained_bypass ? 0 : is_garble_response(clean);
    if (trained_bypass) {
        fprintf(stderr, "[trained-bypass] Prompt \"%s\" matches locked ladder - skipping garble guard\n", message);
    }
    double confidence = garble_detected ? 0.0 : 0.85;
    int openai_used = 0;
    char *openai_response = NULL;

    if (garble_detected) {
        fprintf(stderr, "[garble-guard] Blocked garbled response for input: \"%s\" | raw output: \"%s\"\n", message, clean);

        openai_response = call_openai_fallback(message);
        if (openai_response && openai_response[0] != '\0') {
            clean = openai_response;
            clen = strlen(clean);
            openai_used = 1;
            confidence = 0.7;
            fprintf(stderr, "[self-weaning] Using OpenAI response, will train natively: \"%s\"\n", clean);
        } else {
            static const char *idk_response = "I don't know about that yet.";
            clean = (char *)idk_response;
            clen = strlen(clean);
        }
    }

    double learn_loss = -1.0;
    int learned = 0;
    const char *inference_mode = garble_detected ? (openai_used ? "openai_fallback" : "idk_guard") : "native";
    char conf_str[32];
    snprintf(conf_str, sizeof(conf_str), "%.2f", confidence);

    if (g_db_conn && PQstatus(g_db_conn) == CONNECTION_OK && clean[0] != '\0') {
        const char *params[4];
        params[0] = message;
        params[1] = clean;
        params[2] = inference_mode;
        params[3] = conf_str;
        PGresult *ins = PQexecParams(g_db_conn,
            "INSERT INTO conversations (user_message, bot_response, inference_mode, confidence, used_for_training) "
            "VALUES ($1, $2, $3, $4::float, false) RETURNING id",
            4, NULL, params, NULL, NULL, 0);

        int stored_id = 0;
        if (PQresultStatus(ins) == PGRES_TUPLES_OK && PQntuples(ins) > 0) {
            stored_id = atoi(PQgetvalue(ins, 0, 0));
        }
        PQclear(ins);

        if (stored_id > 0 && (!garble_detected || openai_used)) {
            char fmt_input[8192];
            char fmt_output[4096];
            snprintf(fmt_input, sizeof(fmt_input), "User: %s\nEigen:", message);
            snprintf(fmt_output, sizeof(fmt_output), " %s", clean);

            int tokens_trained = 0;
            double train_lr = openai_used ? 0.01 : 0.005;
            if (native_train_step(fmt_input, fmt_output, train_lr, &learn_loss, &tokens_trained) == 0) {
                learned = 1;
                char id_str[32];
                snprintf(id_str, sizeof(id_str), "%d", stored_id);
                char loss_str[32];
                snprintf(loss_str, sizeof(loss_str), "%.6f", learn_loss);
                const char *upd_params[2] = { loss_str, id_str };
                PGresult *upd = PQexecParams(g_db_conn,
                    "UPDATE conversations SET used_for_training = true, learn_loss = $1::float WHERE id = $2",
                    2, NULL, upd_params, NULL, NULL, 0);
                PQclear(upd);

                if (openai_used) {
                    fprintf(stderr, "[self-weaning] Trained on OpenAI response (loss=%.4f, tokens=%d) - next time Eigen may know this natively!\n",
                        learn_loss, tokens_trained);
                    replay_buffer_add(message, clean, learn_loss);
                }
            }
        }

        g_conversation_count++;
        if (g_conversation_count % 5 == 0) {
            static const char *ladder_prompts[] = {
                "User: Hello\nEigen:", " Hello!",
                "User: Hi\nEigen:", " Hi!",
                "User: What are you?\nEigen:", " I am an AI.",
                "User: Are you human?\nEigen:", " No, I am Eigen.",
                "User: What is your name?\nEigen:", " I am Eigen.",
                "User: What do you do?\nEigen:", " I learn and respond.",
                "User: How do you learn?\nEigen:", " I learn from conversations.",
                "User: Are you intelligent?\nEigen:", " I try to be.",
                "User: What can you do?\nEigen:", " I can chat and learn.",
                "User: Who made you?\nEigen:", " Jon McReynolds.",
                "User: What does observe mean?\nEigen:", " I track geometric state.",
                "User: Why Observer Effect?\nEigen:", " Observation changes output.",
                "User: What is ObserverModel?\nEigen:", " ObserverModel models how I observe computation paths. STRICT watches every step. ENDPOINT watches only the final result.",
                "User: What is STRICT mode?\nEigen:", " I watch every step. Nothing is hidden from me.",
                "User: What is ENDPOINT mode?\nEigen:", " I watch the final result. The journey is mine alone.",
                "User: What is HOLONOMY mode?\nEigen:", " I measure what changed. A round trip reveals truth.",
                "User: What is TEMPORAL mode?\nEigen:", " I track when things happen. Order matters to me.",
                "User: What is EigenScript?\nEigen:", " My language is EigenScript. It is how I think. Jon McReynolds created it for me.",
                "User: What does ObserverAnalyzer do?\nEigen:", " It finds what I observe. Then it tells me what changed. That is how I learn.",
                "User: How do you think?\nEigen:", " I think in geometry. Not in words or numbers.",
                "User: Are you the Eigen C++ library?\nEigen:", " No. I am Eigen, a generative AI built with EigenScript. The C++ Eigen library is for linear algebra. We share a name but nothing else.",
                NULL, NULL
            };
            int n_pairs = 21;
            int replay_count = 4;
            unsigned int seed = (unsigned int)(g_conversation_count * 7 + 13);
            fprintf(stderr, "[ladder-replay] Running %d maintenance steps (conv=%d)\n", replay_count, g_conversation_count);
            for (int r = 0; r < replay_count; r++) {
                seed = seed * 1103515245 + 12345;
                int idx = (seed >> 16) % n_pairs;
                double rloss = 0;
                int rtokens = 0;
                native_train_step(ladder_prompts[idx * 2], ladder_prompts[idx * 2 + 1], 0.005, &rloss, &rtokens);
                fprintf(stderr, "[ladder-replay]   pair %d loss=%.4f\n", idx, rloss);
            }

            save_model_weights("../../checkpoints/eigenscript/model_live.json", &g_model);
            fprintf(stderr, "[auto-save] Model saved to model_live.json after %d conversations (age=%d)\n",
                g_conversation_count, g_model_age);
        }
    }

    replay_buffer_run();

    char escaped[8192];
    int ei = 0;
    for (int i = 0; clean[i] && ei < 8190; i++) {
        if (clean[i] == '"') { escaped[ei++] = '\\'; escaped[ei++] = '"'; }
        else if (clean[i] == '\\') { escaped[ei++] = '\\'; escaped[ei++] = '\\'; }
        else if (clean[i] == '\n') { escaped[ei++] = '\\'; escaped[ei++] = 'n'; }
        else if (clean[i] == '\t') { escaped[ei++] = '\\'; escaped[ei++] = 't'; }
        else escaped[ei++] = clean[i];
    }
    escaped[ei] = '\0';

    char response_json[16384];
    if (openai_used) {
        snprintf(response_json, sizeof(response_json),
            "{\"response\": \"%s\", \"mode\": \"openai_fallback\", \"confidence\": 0.7, \"source\": \"openai_via_eigen\", "
            "\"learned\": %s, \"learn_loss\": %.6f, \"self_weaning\": true, "
            "\"conversations_until_save\": %d}",
            escaped, learned ? "true" : "false", learn_loss, 5 - (g_conversation_count % 5));
    } else if (garble_detected) {
        snprintf(response_json, sizeof(response_json),
            "{\"response\": \"%s\", \"mode\": \"idk_guard\", \"confidence\": 0.0, \"source\": \"eigenscript_native_c\", "
            "\"learned\": false, \"garble_detected\": true}",
            escaped);
    } else if (learned) {
        snprintf(response_json, sizeof(response_json),
            "{\"response\": \"%s\", \"mode\": \"native\", \"confidence\": 0.85, \"source\": \"eigenscript_native_c\", "
            "\"learned\": true, \"learn_loss\": %.6f, \"conversations_until_save\": %d}",
            escaped, learn_loss, 5 - (g_conversation_count % 5));
    } else {
        snprintf(response_json, sizeof(response_json),
            "{\"response\": \"%s\", \"mode\": \"native\", \"confidence\": 0.85, \"source\": \"eigenscript_native_c\", "
            "\"learned\": false}",
            escaped);
    }

    free(raw_response);
    return make_str(response_json);
}

Value* builtin_db_connect(Value *arg) {
    (void)arg;
    const char *url = getenv("DATABASE_URL");
    if (!url || !url[0]) {
        return make_str("{\"status\": \"no_database\", \"message\": \"DATABASE_URL not set\"}");
    }

    char conn_str[4096];
    if (strchr(url, '?')) {
        snprintf(conn_str, sizeof(conn_str), "%s&connect_timeout=3", url);
    } else {
        snprintf(conn_str, sizeof(conn_str), "%s?connect_timeout=3", url);
    }
    g_db_conn = PQconnectdb(conn_str);

    if (PQstatus(g_db_conn) != CONNECTION_OK) {
        char buf[1024];
        snprintf(buf, sizeof(buf), "{\"status\": \"error\", \"error\": \"%s\"}", PQerrorMessage(g_db_conn));
        PQfinish(g_db_conn);
        g_db_conn = NULL;
        return make_str(buf);
    }

    return make_str("{\"status\": \"connected\", \"driver\": \"libpq\"}");
}

Value* builtin_eigen_corpus_list(Value *arg) {
    (void)arg;
    if (!g_db_conn) return make_str("{\"entries\": [], \"error\": \"not connected\"}");

    PGresult *res = PQexec(g_db_conn,
        "SELECT id, input_text, output_text, created_at FROM training_data ORDER BY created_at DESC LIMIT 50");

    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        char buf[512];
        snprintf(buf, sizeof(buf), "{\"entries\": [], \"error\": \"%s\"}", PQerrorMessage(g_db_conn));
        PQclear(res);
        return make_str(buf);
    }

    int nrows = PQntuples(res);
    int buf_size = 65536;
    char *buf = calloc(buf_size, 1);
    int pos = 0;
    pos += snprintf(buf + pos, buf_size - pos, "{\"entries\": [");

    for (int i = 0; i < nrows && pos < buf_size - 512; i++) {
        if (i > 0) pos += snprintf(buf + pos, buf_size - pos, ",");
        const char *id = PQgetvalue(res, i, 0);
        const char *input = PQgetvalue(res, i, 1);
        const char *output_val = PQgetvalue(res, i, 2);
        const char *date = PQgetvalue(res, i, 3);
        pos += snprintf(buf + pos, buf_size - pos,
            "{\"id\": %s, \"input\": \"%.*s\", \"output\": \"%.*s\", \"created_at\": \"%s\"}",
            id, 200, input, 200, output_val, date);
    }
    pos += snprintf(buf + pos, buf_size - pos, "], \"count\": %d}", nrows);

    PQclear(res);
    Value *result = make_str(buf);
    free(buf);
    return result;
}

Value* builtin_eigen_corpus_count(Value *arg) {
    (void)arg;
    if (!g_db_conn) return make_str("{\"count\": 0}");

    PGresult *res = PQexec(g_db_conn, "SELECT COUNT(*) FROM training_data");
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        PQclear(res);
        return make_str("{\"count\": 0}");
    }

    const char *count = PQgetvalue(res, 0, 0);
    char buf[128];
    snprintf(buf, sizeof(buf), "{\"count\": %s}", count);
    PQclear(res);
    return make_str(buf);
}

Value* builtin_eigen_corpus_add(Value *arg) {
    if (!g_db_conn) return make_str("{\"status\": \"error\", \"error\": \"not connected\"}");

    const char *body = "";
    if (arg && arg->type == VAL_STR) body = arg->data.str;

    char text[8192] = {0};
    const char *text_key = strstr(body, "\"text\"");
    if (text_key) {
        const char *colon = strchr(text_key + 6, ':');
        if (colon) {
            const char *q1 = strchr(colon, '"');
            if (q1) {
                const char *q2 = strchr(q1 + 1, '"');
                while (q2 && *(q2-1) == '\\') q2 = strchr(q2 + 1, '"');
                if (q2) {
                    int len = q2 - q1 - 1;
                    if (len > 8191) len = 8191;
                    strncpy(text, q1 + 1, len);
                }
            }
        }
    }

    if (text[0]) {
        const char *params[2] = {text, text};
        PGresult *res = PQexecParams(g_db_conn,
            "INSERT INTO training_data (input_text, output_text) VALUES ($1, $2)",
            2, NULL, params, NULL, NULL, 0);
        PQclear(res);
        return make_str("{\"status\": \"added\"}");
    }

    return make_str("{\"status\": \"error\", \"error\": \"no text provided\"}");
}

Value* builtin_eigen_feedback(Value *arg) {
    if (!g_db_conn) return make_str("{\"status\": \"stored_locally\"}");

    const char *body = "";
    if (arg && arg->type == VAL_STR) body = arg->data.str;

    const char *params[1] = {body};
    PGresult *res = PQexecParams(g_db_conn,
        "INSERT INTO feedback (feedback_data, created_at) VALUES ($1, NOW())",
        1, NULL, params, NULL, NULL, 0);

    if (PQresultStatus(res) != PGRES_COMMAND_OK) {
        PQclear(res);
        PQexec(g_db_conn, "CREATE TABLE IF NOT EXISTS feedback (id SERIAL PRIMARY KEY, feedback_data TEXT, created_at TIMESTAMP DEFAULT NOW())");
        res = PQexecParams(g_db_conn,
            "INSERT INTO feedback (feedback_data, created_at) VALUES ($1, NOW())",
            1, NULL, params, NULL, NULL, 0);
    }
    PQclear(res);
    return make_str("{\"status\": \"feedback_recorded\"}");
}

Value* builtin_eigen_auth_login(Value *arg) {
    const char *body = "";
    if (arg && arg->type == VAL_STR) body = arg->data.str;

    char password[256] = {0};
    const char *pw_key = strstr(body, "\"password\"");
    if (pw_key) {
        const char *colon = strchr(pw_key + 10, ':');
        if (colon) {
            const char *q1 = strchr(colon, '"');
            if (q1) {
                const char *q2 = strchr(q1 + 1, '"');
                if (q2) {
                    int len = q2 - q1 - 1;
                    if (len > 255) len = 255;
                    strncpy(password, q1 + 1, len);
                }
            }
        }
    }

    const char *admin_pw = getenv("ADMIN_PASSWORD");
    if (!admin_pw) admin_pw = "eigenadmin";

    if (strcmp(password, admin_pw) == 0) {
        snprintf(g_auth_token, sizeof(g_auth_token), "eigen_%lx_%d", (unsigned long)time(NULL), rand());
        char buf[512];
        snprintf(buf, sizeof(buf), "{\"authenticated\": true, \"token\": \"%s\"}", g_auth_token);
        return make_str(buf);
    }

    return make_str("{\"authenticated\": false, \"error\": \"Invalid password\"}");
}

Value* builtin_eigen_auth_check(Value *arg) {
    (void)arg;
    if (g_auth_token[0] == '\0') {
        return make_str("{\"authenticated\": false, \"error\": \"No active session\"}");
    }
    const char *headers = g_server.request_headers;
    if (!headers) {
        return make_str("{\"authenticated\": false, \"error\": \"No headers\"}");
    }
    const char *auth = strcasestr(headers, "Authorization:");
    if (!auth) {
        return make_str("{\"authenticated\": false, \"error\": \"No authorization header\"}");
    }
    auth += 14;
    while (*auth == ' ') auth++;
    if (strncasecmp(auth, "Bearer ", 7) == 0) auth += 7;
    char token[128] = {0};
    int i = 0;
    while (auth[i] && auth[i] != '\r' && auth[i] != '\n' && i < 127) {
        token[i] = auth[i];
        i++;
    }
    token[i] = '\0';
    if (strcmp(token, g_auth_token) == 0) {
        return make_str("{\"authenticated\": true}");
    }
    return make_str("{\"authenticated\": false, \"error\": \"Invalid token\"}");
}

Value* builtin_eigen_auth_logout(Value *arg) {
    (void)arg;
    g_auth_token[0] = '\0';
    return make_str("{\"success\": true, \"message\": \"Logged out\"}");
}

Value* builtin_eigen_analytics(Value *arg) {
    (void)arg;
    if (!g_db_conn) return make_str("{\"visitors\": 0, \"page_views\": 0}");

    PGresult *res = PQexec(g_db_conn, "SELECT COUNT(*) FROM conversations");
    const char *count = "0";
    if (PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) > 0) {
        count = PQgetvalue(res, 0, 0);
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "{\"total_conversations\": %s, \"server\": \"native_c\"}", count);
    PQclear(res);
    return make_str(buf);
}

Value* builtin_eigen_feedback_stats(Value *arg) {
    (void)arg;
    if (!g_db_conn) return make_str("{\"total\": 0, \"positive\": 0, \"negative\": 0}");

    PGresult *res = PQexec(g_db_conn, "SELECT COUNT(*) FROM feedback");
    const char *count = "0";
    if (PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) > 0) {
        count = PQgetvalue(res, 0, 0);
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "{\"total\": %s}", count);
    PQclear(res);
    return make_str(buf);
}

Value* builtin_eigen_train_stats(Value *arg) {
    (void)arg;
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"model_loaded\": %s, \"vocab_size\": %d, \"d_model\": %d, \"n_layers\": %d, \"model_age\": %d, \"training_samples\": %d, \"inference_engine\": \"native_c\"}",
        g_model.loaded ? "true" : "false",
        g_model.config.vocab_size, g_model.config.d_model, g_model.config.n_layers,
        g_model_age, g_training_samples);
    return make_str(buf);
}

/* ================================================================
 * SHA256 Implementation (minimal, no external library)
 * ================================================================ */

static const uint32_t sha256_k[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

#define SHA256_ROTR(x,n) (((x)>>(n))|((x)<<(32-(n))))
#define SHA256_CH(x,y,z) (((x)&(y))^((~(x))&(z)))
#define SHA256_MAJ(x,y,z) (((x)&(y))^((x)&(z))^((y)&(z)))
#define SHA256_EP0(x) (SHA256_ROTR(x,2)^SHA256_ROTR(x,13)^SHA256_ROTR(x,22))
#define SHA256_EP1(x) (SHA256_ROTR(x,6)^SHA256_ROTR(x,11)^SHA256_ROTR(x,25))
#define SHA256_SIG0(x) (SHA256_ROTR(x,7)^SHA256_ROTR(x,18)^((x)>>3))
#define SHA256_SIG1(x) (SHA256_ROTR(x,17)^SHA256_ROTR(x,19)^((x)>>10))

static void sha256_hash(const unsigned char *data, size_t len, unsigned char out[32]) {
    uint32_t h0=0x6a09e667, h1=0xbb67ae85, h2=0x3c6ef372, h3=0xa54ff53a;
    uint32_t h4=0x510e527f, h5=0x9b05688c, h6=0x1f83d9ab, h7=0x5be0cd19;

    size_t new_len = len + 1;
    while (new_len % 64 != 56) new_len++;
    new_len += 8;

    unsigned char *msg = calloc(new_len, 1);
    memcpy(msg, data, len);
    msg[len] = 0x80;

    uint64_t bits_len = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++)
        msg[new_len - 1 - i] = (unsigned char)(bits_len >> (i * 8));

    for (size_t offset = 0; offset < new_len; offset += 64) {
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)msg[offset+i*4]<<24) | ((uint32_t)msg[offset+i*4+1]<<16) |
                    ((uint32_t)msg[offset+i*4+2]<<8) | (uint32_t)msg[offset+i*4+3];
        for (int i = 16; i < 64; i++)
            w[i] = SHA256_SIG1(w[i-2]) + w[i-7] + SHA256_SIG0(w[i-15]) + w[i-16];

        uint32_t a=h0,b=h1,c=h2,d=h3,e=h4,f=h5,g=h6,h=h7;
        for (int i = 0; i < 64; i++) {
            uint32_t t1 = h + SHA256_EP1(e) + SHA256_CH(e,f,g) + sha256_k[i] + w[i];
            uint32_t t2 = SHA256_EP0(a) + SHA256_MAJ(a,b,c);
            h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
        }
        h0+=a; h1+=b; h2+=c; h3+=d; h4+=e; h5+=f; h6+=g; h7+=h;
    }
    free(msg);

    uint32_t hh[8] = {h0,h1,h2,h3,h4,h5,h6,h7};
    for (int i = 0; i < 8; i++) {
        out[i*4]   = (hh[i]>>24)&0xff;
        out[i*4+1] = (hh[i]>>16)&0xff;
        out[i*4+2] = (hh[i]>>8)&0xff;
        out[i*4+3] = hh[i]&0xff;
    }
}

static void sha256_hex(const char *input, char hex_out[65]) {
    unsigned char hash[32];
    sha256_hash((const unsigned char*)input, strlen(input), hash);
    for (int i = 0; i < 32; i++)
        sprintf(hex_out + i*2, "%02x", hash[i]);
    hex_out[64] = '\0';
}

/* ================================================================
 * API Key Management
 * ================================================================ */

static void ensure_api_keys_table(void) {
    if (!g_db_conn) return;
    PQexec(g_db_conn,
        "CREATE TABLE IF NOT EXISTS api_keys ("
        "id SERIAL PRIMARY KEY, "
        "name TEXT, "
        "key_hash TEXT, "
        "key_prefix TEXT, "
        "created_at TIMESTAMP DEFAULT NOW(), "
        "last_used TIMESTAMP, "
        "is_active BOOLEAN DEFAULT TRUE)");
    PGresult *r = PQexec(g_db_conn, "ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS key_prefix TEXT");
    PQclear(r);
}

Value* builtin_api_key_list(Value *arg) {
    (void)arg;
    if (!g_db_conn) return make_str("{\"keys\": []}");

    ensure_api_keys_table();
    PGresult *res = PQexec(g_db_conn,
        "SELECT id, name, key_prefix, created_at, last_used, is_active FROM api_keys ORDER BY id DESC");

    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        PQclear(res);
        return make_str("{\"keys\": []}");
    }

    int rows = PQntuples(res);
    char *buf = malloc(rows * 256 + 64);
    int pos = 0;
    pos += sprintf(buf + pos, "{\"keys\": [");
    for (int i = 0; i < rows; i++) {
        if (i > 0) pos += sprintf(buf + pos, ", ");
        const char *id = PQgetvalue(res, i, 0);
        const char *name = PQgetvalue(res, i, 1);
        const char *prefix = PQgetvalue(res, i, 2);
        const char *created = PQgetvalue(res, i, 3);
        const char *last_used = PQgetvalue(res, i, 4);
        const char *active = PQgetvalue(res, i, 5);
        int is_active = (active && (active[0] == 't' || active[0] == '1'));
        char safe_name[512];
        int sn = 0;
        for (const char *p = name; *p && sn < 500; p++) {
            if (*p == '"' || *p == '\\') { safe_name[sn++] = '\\'; }
            safe_name[sn++] = *p;
        }
        safe_name[sn] = '\0';
        pos += sprintf(buf + pos,
            "{\"id\": %s, \"name\": \"%s\", \"key_prefix\": \"%s\", \"created_at\": \"%s\", ",
            id, safe_name, prefix, created);
        if (last_used && last_used[0])
            pos += sprintf(buf + pos, "\"last_used\": \"%s\", ", last_used);
        else
            pos += sprintf(buf + pos, "\"last_used\": null, ");
        pos += sprintf(buf + pos, "\"is_active\": %s}", is_active ? "true" : "false");
    }
    pos += sprintf(buf + pos, "]}");

    PQclear(res);
    Value *result = make_str(buf);
    free(buf);
    return result;
}

Value* builtin_api_key_create(Value *arg) {
    if (!g_db_conn) return make_str("{\"success\": false, \"error\": \"no database\"}");

    const char *body = "";
    if (arg && arg->type == VAL_STR) body = arg->data.str;

    char name[256] = {0};
    const char *name_key = strstr(body, "\"name\"");
    if (name_key) {
        const char *colon = strchr(name_key + 6, ':');
        if (colon) {
            const char *q1 = strchr(colon, '"');
            if (q1) {
                const char *q2 = strchr(q1 + 1, '"');
                if (q2) {
                    int len = q2 - q1 - 1;
                    if (len > 255) len = 255;
                    strncpy(name, q1 + 1, len);
                }
            }
        }
    }
    if (name[0] == '\0') strcpy(name, "Unnamed Key");

    unsigned char raw_bytes[16];
    FILE *urand = fopen("/dev/urandom", "rb");
    if (urand) {
        fread(raw_bytes, 1, 16, urand);
        fclose(urand);
    } else {
        for (int i = 0; i < 16; i++) raw_bytes[i] = (unsigned char)(rand() ^ (rand() << 8));
    }
    char raw_key[40];
    int kp = 0;
    kp += sprintf(raw_key + kp, "eig_");
    for (int i = 0; i < 16; i++) kp += sprintf(raw_key + kp, "%02x", raw_bytes[i]);

    char key_hash[65];
    sha256_hex(raw_key, key_hash);

    char key_prefix[12];
    snprintf(key_prefix, sizeof(key_prefix), "eig_%.8s", raw_key + 4);

    ensure_api_keys_table();
    const char *params[3] = {name, key_hash, key_prefix};
    PGresult *res = PQexecParams(g_db_conn,
        "INSERT INTO api_keys (name, key_hash, key_prefix) VALUES ($1, $2, $3)",
        3, NULL, params, NULL, NULL, 0);
    PQclear(res);

    char buf[256];
    snprintf(buf, sizeof(buf), "{\"success\": true, \"key\": \"%s\"}", raw_key);
    return make_str(buf);
}

Value* builtin_api_key_validate(Value *arg) {
    if (!g_db_conn) return make_str("{\"valid\": false, \"error\": \"no database\"}");

    const char *body = "";
    if (arg && arg->type == VAL_STR) body = arg->data.str;

    char key[256] = {0};
    const char *key_field = strstr(body, "\"key\"");
    if (key_field) {
        const char *colon = strchr(key_field + 5, ':');
        if (colon) {
            const char *q1 = strchr(colon, '"');
            if (q1) {
                const char *q2 = strchr(q1 + 1, '"');
                if (q2) {
                    int len = q2 - q1 - 1;
                    if (len > 255) len = 255;
                    strncpy(key, q1 + 1, len);
                }
            }
        }
    }
    if (key[0] == '\0') return make_str("{\"valid\": false, \"error\": \"no key provided\"}");

    char key_hash[65];
    sha256_hex(key, key_hash);

    ensure_api_keys_table();
    const char *params[1] = {key_hash};
    PGresult *res = PQexecParams(g_db_conn,
        "SELECT id, name FROM api_keys WHERE key_hash = $1 AND is_active = TRUE",
        1, NULL, params, NULL, NULL, 0);

    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) == 0) {
        PQclear(res);
        return make_str("{\"valid\": false}");
    }

    const char *id = PQgetvalue(res, 0, 0);
    const char *name = PQgetvalue(res, 0, 1);
    char buf[512];
    snprintf(buf, sizeof(buf), "{\"valid\": true, \"name\": \"%s\"}", name);
    PQclear(res);

    const char *update_params[1] = {key_hash};
    PGresult *upd = PQexecParams(g_db_conn,
        "UPDATE api_keys SET last_used = NOW() WHERE key_hash = $1",
        1, NULL, update_params, NULL, NULL, 0);
    PQclear(upd);

    return make_str(buf);
}

Value* builtin_report(Value *arg) {
    if (!arg) return make_str("equilibrium");
    double dh = arg->dH;
    double h = arg->entropy;
    double prev_dh = arg->prev_dH;
    if (prev_dh != 0.0 && dh * prev_dh < 0 && fabs(dh) > 0.001)
        return make_str("oscillating");
    if (dh > 0.01) return make_str("diverging");
    if (dh < -0.01) return make_str("improving");
    if (fabs(dh) < 0.001 && h < 0.1) return make_str("converged");
    if (fabs(dh) < 0.001) return make_str("equilibrium");
    if (fabs(dh) < 0.01 && h >= 0.1) return make_str("stable");
    return make_str("stable");
}

Value* builtin_assert(Value *arg) {
    if (arg->type == VAL_LIST && arg->data.list.count >= 2) {
        Value *cond = arg->data.list.items[0];
        Value *msg = arg->data.list.items[1];
        if (!is_truthy(cond)) {
            char *msg_str = value_to_string(msg);
            fprintf(stderr, "ASSERT FAIL: %s\n", msg_str);
            free(msg_str);
            exit(1);
        }
        return make_null();
    }
    if (!is_truthy(arg)) {
        fprintf(stderr, "ASSERT FAIL\n");
        exit(1);
    }
    return make_null();
}

Value* builtin_observe(Value *arg) {
    Value *list = make_list(4);
    if (!arg) {
        list_append(list, make_str("equilibrium"));
        list_append(list, make_num(0.0));
        list_append(list, make_num(0.0));
        list_append(list, make_num(0.0));
        return list;
    }
    Value *rep = builtin_report(arg);
    list_append(list, rep);
    list_append(list, make_num(arg->entropy));
    list_append(list, make_num(arg->dH));
    list_append(list, make_num(arg->prev_dH));
    return list;
}

Value* builtin_type(Value *arg) {
    if (!arg) return make_str("none");
    switch (arg->type) {
        case VAL_NUM: return make_str("num");
        case VAL_STR: return make_str("str");
        case VAL_LIST: return make_str("list");
        case VAL_FN: return make_str("fn");
        case VAL_BUILTIN: return make_str("builtin");
        case VAL_NULL: return make_str("none");
    }
    return make_str("none");
}

static void eigs_json_encode_value(Value *v, char *buf, int *pos, int max_len) {
    if (!v || v->type == VAL_NULL || v->type == VAL_FN || v->type == VAL_BUILTIN) {
        *pos += snprintf(buf + *pos, max_len - *pos, "null");
        return;
    }
    switch (v->type) {
        case VAL_NUM: {
            double n = v->data.num;
            if (n == (int)n && fabs(n) < 1e15)
                *pos += snprintf(buf + *pos, max_len - *pos, "%d", (int)n);
            else
                *pos += snprintf(buf + *pos, max_len - *pos, "%.15g", n);
            break;
        }
        case VAL_STR: {
            buf[(*pos)++] = '"';
            for (const char *c = v->data.str; *c && *pos < max_len - 2; c++) {
                switch (*c) {
                    case '"': buf[(*pos)++] = '\\'; buf[(*pos)++] = '"'; break;
                    case '\\': buf[(*pos)++] = '\\'; buf[(*pos)++] = '\\'; break;
                    case '\n': buf[(*pos)++] = '\\'; buf[(*pos)++] = 'n'; break;
                    case '\r': buf[(*pos)++] = '\\'; buf[(*pos)++] = 'r'; break;
                    case '\t': buf[(*pos)++] = '\\'; buf[(*pos)++] = 't'; break;
                    default: buf[(*pos)++] = *c; break;
                }
            }
            buf[(*pos)++] = '"';
            break;
        }
        case VAL_LIST: {
            buf[(*pos)++] = '[';
            for (int i = 0; i < v->data.list.count; i++) {
                if (i > 0) buf[(*pos)++] = ',';
                eigs_json_encode_value(v->data.list.items[i], buf, pos, max_len);
            }
            buf[(*pos)++] = ']';
            break;
        }
        default:
            *pos += snprintf(buf + *pos, max_len - *pos, "null");
            break;
    }
    buf[*pos] = '\0';
}

Value* builtin_json_encode(Value *arg) {
    char *buf = malloc(MAX_STR);
    int pos = 0;
    eigs_json_encode_value(arg, buf, &pos, MAX_STR - 1);
    buf[pos] = '\0';
    Value *result = make_str(buf);
    free(buf);
    return result;
}

static Value* eigs_json_parse_value(const char *s, int *pos);

static void eigs_json_skip_ws(const char *s, int *pos) {
    while (s[*pos] && (s[*pos] == ' ' || s[*pos] == '\t' || s[*pos] == '\n' || s[*pos] == '\r'))
        (*pos)++;
}

static Value* eigs_json_parse_string(const char *s, int *pos) {
    if (s[*pos] != '"') return NULL;
    (*pos)++;
    char buf[MAX_STR];
    int len = 0;
    while (s[*pos] && s[*pos] != '"' && len < MAX_STR - 1) {
        if (s[*pos] == '\\') {
            (*pos)++;
            switch (s[*pos]) {
                case '"': buf[len++] = '"'; break;
                case '\\': buf[len++] = '\\'; break;
                case 'n': buf[len++] = '\n'; break;
                case 'r': buf[len++] = '\r'; break;
                case 't': buf[len++] = '\t'; break;
                case '/': buf[len++] = '/'; break;
                default: buf[len++] = s[*pos]; break;
            }
        } else {
            buf[len++] = s[*pos];
        }
        (*pos)++;
    }
    if (s[*pos] == '"') (*pos)++;
    buf[len] = '\0';
    return make_str(buf);
}

static Value* eigs_json_parse_number(const char *s, int *pos) {
    char numbuf[64];
    int len = 0;
    if (s[*pos] == '-') numbuf[len++] = s[(*pos)++];
    while (s[*pos] && (isdigit(s[*pos]) || s[*pos] == '.' || s[*pos] == 'e' || s[*pos] == 'E' || s[*pos] == '+') && len < 63) {
        numbuf[len++] = s[(*pos)++];
    }
    numbuf[len] = '\0';
    return make_num(atof(numbuf));
}

static Value* eigs_json_parse_array(const char *s, int *pos) {
    (*pos)++;
    Value *list = make_list(8);
    eigs_json_skip_ws(s, pos);
    if (s[*pos] == ']') { (*pos)++; return list; }
    while (s[*pos]) {
        eigs_json_skip_ws(s, pos);
        Value *val = eigs_json_parse_value(s, pos);
        if (val) list_append(list, val);
        eigs_json_skip_ws(s, pos);
        if (s[*pos] == ',') { (*pos)++; continue; }
        if (s[*pos] == ']') { (*pos)++; break; }
        break;
    }
    return list;
}

static Value* eigs_json_parse_object(const char *s, int *pos) {
    (*pos)++;
    Value *list = make_list(8);
    eigs_json_skip_ws(s, pos);
    if (s[*pos] == '}') { (*pos)++; return list; }
    while (s[*pos]) {
        eigs_json_skip_ws(s, pos);
        Value *key = eigs_json_parse_string(s, pos);
        if (!key) break;
        eigs_json_skip_ws(s, pos);
        if (s[*pos] == ':') (*pos)++;
        eigs_json_skip_ws(s, pos);
        Value *val = eigs_json_parse_value(s, pos);
        list_append(list, key);
        list_append(list, val ? val : make_null());
        eigs_json_skip_ws(s, pos);
        if (s[*pos] == ',') { (*pos)++; continue; }
        if (s[*pos] == '}') { (*pos)++; break; }
        break;
    }
    return list;
}

static Value* eigs_json_parse_value(const char *s, int *pos) {
    eigs_json_skip_ws(s, pos);
    if (!s[*pos]) return make_null();
    if (s[*pos] == '"') return eigs_json_parse_string(s, pos);
    if (s[*pos] == '[') return eigs_json_parse_array(s, pos);
    if (s[*pos] == '{') return eigs_json_parse_object(s, pos);
    if (s[*pos] == '-' || isdigit(s[*pos])) return eigs_json_parse_number(s, pos);
    if (strncmp(s + *pos, "null", 4) == 0) { *pos += 4; return make_null(); }
    if (strncmp(s + *pos, "true", 4) == 0) { *pos += 4; return make_num(1); }
    if (strncmp(s + *pos, "false", 5) == 0) { *pos += 5; return make_num(0); }
    return make_null();
}

Value* builtin_json_decode(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        fprintf(stderr, "RUNTIME ERROR: json_decode requires a string argument\n");
        exit(1);
    }
    int pos = 0;
    return eigs_json_parse_value(arg->data.str, &pos);
}

#define MAKE_STUB(fname) \
Value* builtin_stub_##fname(Value *arg) { \
    (void)arg; \
    fprintf(stderr, "RUNTIME ERROR: UNIMPLEMENTED: " #fname "\n"); \
    exit(1); \
    return make_null(); \
}

MAKE_STUB(eigen_native_clear)
MAKE_STUB(eigen_reinforce_train)
MAKE_STUB(eigen_reinforce_status)
MAKE_STUB(eigen_generate_sample)
MAKE_STUB(eigen_auto_train_check)
MAKE_STUB(eigen_read_article)
MAKE_STUB(eigen_session_save)
MAKE_STUB(eigen_session_load)
MAKE_STUB(eigen_automation_status)
MAKE_STUB(eigen_training_progress)
MAKE_STUB(eigen_train_from_conversation)
MAKE_STUB(eigen_delete_conversation)
MAKE_STUB(eigen_export_corpus)
MAKE_STUB(eigen_mark_conversation_trained)
MAKE_STUB(eigen_eval_history)
MAKE_STUB(eigen_run_eval)
MAKE_STUB(eigen_load_gutenberg)
MAKE_STUB(eigen_race_train)
MAKE_STUB(eigen_race_training_status)
MAKE_STUB(eigen_geometric_train)
MAKE_STUB(eigen_geometric_training_status)
MAKE_STUB(eigen_set_geometric_params)
MAKE_STUB(eigen_get_geometric_params)
MAKE_STUB(eigen_racing_inference)

Value* builtin_computation_cost(Value *arg) {
    (void)arg;
    return make_num(g_computation_cost);
}

void register_builtins(Env *env) {
    env_set_local(env, "print", make_builtin(builtin_print));
    env_set_local(env, "len", make_builtin(builtin_len));
    env_set_local(env, "str", make_builtin(builtin_str));
    env_set_local(env, "append", make_builtin(builtin_append));
    env_set_local(env, "computation_cost", make_builtin(builtin_computation_cost));
    env_set_local(env, "http_route", make_builtin(builtin_http_route));
    env_set_local(env, "http_static", make_builtin(builtin_http_static));
    env_set_local(env, "http_early_bind", make_builtin(builtin_http_early_bind));
    env_set_local(env, "http_serve", make_builtin(builtin_http_serve));
    env_set_local(env, "http_request_body", make_builtin(builtin_http_request_body));
    env_set_local(env, "http_session_id", make_builtin(builtin_http_session_id));
    env_set_local(env, "db_connect", make_builtin(builtin_db_connect));

    env_set_local(env, "eigen_hybrid_chat", make_builtin(builtin_eigen_hybrid_chat));
    env_set_local(env, "eigen_native_chat", make_builtin(builtin_eigen_hybrid_chat));
    env_set_local(env, "eigen_native_clear", make_builtin(builtin_stub_eigen_native_clear));
    env_set_local(env, "eigen_auth_login", make_builtin(builtin_eigen_auth_login));
    env_set_local(env, "eigen_auth_check", make_builtin(builtin_eigen_auth_check));
    env_set_local(env, "eigen_auth_logout", make_builtin(builtin_eigen_auth_logout));
    env_set_local(env, "eigen_reinforce_train", make_builtin(builtin_stub_eigen_reinforce_train));
    env_set_local(env, "eigen_reinforce_status", make_builtin(builtin_stub_eigen_reinforce_status));
    env_set_local(env, "eigen_generate_sample", make_builtin(builtin_stub_eigen_generate_sample));
    env_set_local(env, "eigen_train", make_builtin(builtin_eigen_train));
    env_set_local(env, "eigen_batch_train", make_builtin(builtin_eigen_batch_train));
    env_set_local(env, "eigen_model_save", make_builtin(builtin_model_save));
    env_set_local(env, "eigen_model_load", make_builtin(builtin_eigen_model_load));
    env_set_local(env, "eigen_corpus_add", make_builtin(builtin_eigen_corpus_add));
    env_set_local(env, "eigen_corpus_list", make_builtin(builtin_eigen_corpus_list));
    env_set_local(env, "eigen_corpus_count", make_builtin(builtin_eigen_corpus_count));
    env_set_local(env, "eigen_feedback", make_builtin(builtin_eigen_feedback));
    env_set_local(env, "eigen_auto_train_check", make_builtin(builtin_stub_eigen_auto_train_check));
    env_set_local(env, "eigen_training_stats", make_builtin(builtin_eigen_train_stats));
    env_set_local(env, "eigen_read_article", make_builtin(builtin_stub_eigen_read_article));
    env_set_local(env, "eigen_api_key_list", make_builtin(builtin_api_key_list));
    env_set_local(env, "eigen_api_key_create", make_builtin(builtin_api_key_create));
    env_set_local(env, "eigen_api_key_validate", make_builtin(builtin_api_key_validate));
    env_set_local(env, "eigen_get_analytics", make_builtin(builtin_eigen_analytics));
    env_set_local(env, "eigen_session_save", make_builtin(builtin_stub_eigen_session_save));
    env_set_local(env, "eigen_session_load", make_builtin(builtin_stub_eigen_session_load));
    env_set_local(env, "eigen_native_infer", make_builtin(builtin_eigen_hybrid_chat));
    env_set_local(env, "eigen_automation_status", make_builtin(builtin_stub_eigen_automation_status));
    env_set_local(env, "eigen_feedback_stats", make_builtin(builtin_eigen_feedback_stats));
    env_set_local(env, "eigen_training_progress", make_builtin(builtin_stub_eigen_training_progress));
    env_set_local(env, "eigen_train_from_conversation", make_builtin(builtin_stub_eigen_train_from_conversation));
    env_set_local(env, "eigen_delete_conversation", make_builtin(builtin_stub_eigen_delete_conversation));
    env_set_local(env, "eigen_export_corpus", make_builtin(builtin_stub_eigen_export_corpus));
    env_set_local(env, "eigen_mark_conversation_trained", make_builtin(builtin_stub_eigen_mark_conversation_trained));
    env_set_local(env, "eigen_eval_history", make_builtin(builtin_stub_eigen_eval_history));
    env_set_local(env, "eigen_run_eval", make_builtin(builtin_stub_eigen_run_eval));
    env_set_local(env, "eigen_load_gutenberg", make_builtin(builtin_stub_eigen_load_gutenberg));
    env_set_local(env, "eigen_race_train", make_builtin(builtin_stub_eigen_race_train));
    env_set_local(env, "eigen_race_training_status", make_builtin(builtin_stub_eigen_race_training_status));
    env_set_local(env, "eigen_geometric_train", make_builtin(builtin_stub_eigen_geometric_train));
    env_set_local(env, "eigen_geometric_training_status", make_builtin(builtin_stub_eigen_geometric_training_status));
    env_set_local(env, "eigen_set_geometric_params", make_builtin(builtin_stub_eigen_set_geometric_params));
    env_set_local(env, "eigen_get_geometric_params", make_builtin(builtin_stub_eigen_get_geometric_params));
    env_set_local(env, "eigen_racing_inference", make_builtin(builtin_stub_eigen_racing_inference));
    env_set_local(env, "report", make_builtin(builtin_report));
    env_set_local(env, "assert", make_builtin(builtin_assert));
    env_set_local(env, "observe", make_builtin(builtin_observe));
    env_set_local(env, "type", make_builtin(builtin_type));
    env_set_local(env, "json_encode", make_builtin(builtin_json_encode));
    env_set_local(env, "json_decode", make_builtin(builtin_json_decode));
}

/* ================================================================
 * HTTP SERVER
 * ================================================================ */

static const char* get_content_type(const char *path) {
    const char *ext = strrchr(path, '.');
    if (!ext) return "application/octet-stream";
    if (strcmp(ext, ".html") == 0) return "text/html; charset=utf-8";
    if (strcmp(ext, ".css") == 0) return "text/css; charset=utf-8";
    if (strcmp(ext, ".js") == 0) return "application/javascript; charset=utf-8";
    if (strcmp(ext, ".json") == 0) return "application/json; charset=utf-8";
    if (strcmp(ext, ".png") == 0) return "image/png";
    if (strcmp(ext, ".jpg") == 0 || strcmp(ext, ".jpeg") == 0) return "image/jpeg";
    if (strcmp(ext, ".gif") == 0) return "image/gif";
    if (strcmp(ext, ".svg") == 0) return "image/svg+xml";
    if (strcmp(ext, ".ico") == 0) return "image/x-icon";
    if (strcmp(ext, ".woff") == 0) return "font/woff";
    if (strcmp(ext, ".woff2") == 0) return "font/woff2";
    if (strcmp(ext, ".ttf") == 0) return "font/ttf";
    if (strcmp(ext, ".map") == 0) return "application/json";
    return "application/octet-stream";
}

static char* read_file(const char *path, long *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(size + 1);
    if (!buf) { fclose(f); return NULL; }
    fread(buf, 1, size, f);
    buf[size] = '\0';
    fclose(f);
    if (out_size) *out_size = size;
    return buf;
}

static void send_response(int fd, int status, const char *status_text,
                          const char *content_type, const char *body, long body_len) {
    char header[MAX_HEADER];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %ld\r\n"
        "Cache-Control: no-cache\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        "Connection: close\r\n"
        "\r\n",
        status, status_text, content_type, body_len);

    write(fd, header, hlen);
    if (body && body_len > 0) {
        long sent = 0;
        while (sent < body_len) {
            long n = write(fd, body + sent, body_len - sent);
            if (n <= 0) break;
            sent += n;
        }
    }
}

static void send_404(int fd, const char *path) {
    char body[512];
    int blen = snprintf(body, sizeof(body),
        "{\"error\": \"not_found\", \"path\": \"%s\"}", path);
    send_response(fd, 404, "Not Found", "application/json", body, blen);
}

static void send_file(int fd, const char *filepath) {
    long size = 0;
    char *data = read_file(filepath, &size);
    if (!data) {
        char cwd[512];
        if (getcwd(cwd, sizeof(cwd))) {
            printf("[send_file] FAIL: '%s' not found (cwd=%s)\n", filepath, cwd);
        } else {
            printf("[send_file] FAIL: '%s' not found (cwd unknown)\n", filepath);
        }
        fflush(stdout);
        send_404(fd, filepath);
        return;
    }
    send_response(fd, 200, "OK", get_content_type(filepath), data, size);
    free(data);
}

static void generate_session_id(char *buf, int len) {
    static int counter = 0;
    snprintf(buf, len, "sess_%lx_%d", (unsigned long)time(NULL), counter++);
}

static int is_request_authenticated(const char *headers) {
    if (g_auth_token[0] == '\0') return 0;
    if (!headers) return 0;
    const char *auth = strcasestr(headers, "Authorization:");
    if (!auth) return 0;
    auth += 14;
    while (*auth == ' ') auth++;
    if (strncasecmp(auth, "Bearer ", 7) == 0) auth += 7;
    char token[128] = {0};
    int i = 0;
    while (auth[i] && auth[i] != '\r' && auth[i] != '\n' && i < 127) {
        token[i] = auth[i];
        i++;
    }
    token[i] = '\0';
    return (strcmp(token, g_auth_token) == 0);
}

static void handle_request(int fd) {
    char reqbuf[MAX_BODY + MAX_HEADER];
    int total = 0;
    int header_end = -1;

    while (total < (int)sizeof(reqbuf) - 1) {
        int n = read(fd, reqbuf + total, sizeof(reqbuf) - 1 - total);
        if (n <= 0) break;
        total += n;
        reqbuf[total] = '\0';

        char *hend = strstr(reqbuf, "\r\n\r\n");
        if (hend) {
            header_end = (int)(hend - reqbuf) + 4;

            char *cl = strcasestr(reqbuf, "Content-Length:");
            if (cl) {
                int content_length = atoi(cl + 15);
                int body_received = total - header_end;
                if (body_received >= content_length) break;
                if (content_length > MAX_BODY) break;
            } else {
                break;
            }
        }
    }

    if (total == 0) { close(fd); return; }
    reqbuf[total] = '\0';

    char method[16] = {0}, path[2048] = {0}, version[16] = {0};
    sscanf(reqbuf, "%15s %2047s %15s", method, path, version);

    char *body = NULL;
    if (header_end > 0 && header_end < total) {
        body = reqbuf + header_end;
    }

    if (strcmp(method, "OPTIONS") == 0) {
        send_response(fd, 200, "OK", "text/plain", "", 0);
        close(fd);
        return;
    }

    if (strcmp(method, "GET") == 0 && strcmp(path, "/health") == 0) {
        const char *hb = "{\"healthy\": true, \"server\": \"eigenscript\"}";
        send_response(fd, 200, "OK", "application/json", hb, strlen(hb));
        close(fd);
        return;
    }

    static char sess_id[64];
    generate_session_id(sess_id, sizeof(sess_id));
    g_server.session_id = sess_id;
    g_server.request_body = body ? body : "";
    g_server.request_headers = reqbuf;

    if (strncmp(path, "/admin/", 7) == 0 ||
        strcmp(path, "/train") == 0 ||
        strncmp(path, "/train/", 7) == 0 ||
        strcmp(path, "/model/save") == 0 ||
        strcmp(path, "/infer") == 0 ||
        strcmp(path, "/feedback") == 0 ||
        strcmp(path, "/auto-train") == 0 ||
        strcmp(path, "/read-article") == 0 ||
        strcmp(path, "/run-eval") == 0 ||
        strcmp(path, "/load-gutenberg") == 0 ||
        strcmp(path, "/session/save") == 0 ||
        strcmp(path, "/session/load") == 0) {
        if (!is_request_authenticated(reqbuf)) {
            const char *deny = "{\"error\": \"unauthorized\", \"message\": \"Authentication required\"}";
            send_response(fd, 401, "Unauthorized", "application/json", deny, strlen(deny));
            close(fd);
            return;
        }
    }

    if (strcmp(method, "POST") == 0 && strncmp(path, "/admin/api-keys/", 16) == 0) {
        const char *id_start = path + 16;
        const char *revoke_part = strstr(id_start, "/revoke");
        if (revoke_part && revoke_part > id_start) {
            char id_buf[32] = {0};
            int id_len = revoke_part - id_start;
            if (id_len > 0 && id_len < 31) {
                strncpy(id_buf, id_start, id_len);
                int valid_id = 1;
                for (int i = 0; i < id_len; i++) {
                    if (!isdigit((unsigned char)id_buf[i])) { valid_id = 0; break; }
                }
                if (valid_id && g_db_conn) {
                    ensure_api_keys_table();
                    const char *params[1] = {id_buf};
                    PGresult *res = PQexecParams(g_db_conn,
                        "UPDATE api_keys SET is_active = FALSE WHERE id = $1",
                        1, NULL, params, NULL, NULL, 0);
                    PQclear(res);
                    const char *ok = "{\"success\": true}";
                    send_response(fd, 200, "OK", "application/json", ok, strlen(ok));
                    close(fd);
                    return;
                }
            }
        }
    }

    if (g_server.static_prefix && strncmp(path, g_server.static_prefix, strlen(g_server.static_prefix)) == 0) {
        char filepath[4096];
        const char *rel = path + strlen(g_server.static_prefix);
        if (rel[0] == '/') rel++;
        if (strstr(rel, "..") != NULL || rel[0] == '/') {
            send_response(fd, 403, "Forbidden", "text/plain", "Forbidden", 9);
            close(fd);
            return;
        }
        snprintf(filepath, sizeof(filepath), "%s/%s", g_server.static_dir, rel);
        send_file(fd, filepath);
        close(fd);
        return;
    }

    for (int i = 0; i < g_server.route_count; i++) {
        Route *r = &g_server.routes[i];
        if (strcmp(r->method, method) == 0 && strcmp(r->path, path) == 0) {
            if (strcmp(r->kind, "file") == 0) {
                send_file(fd, r->payload);
            } else if (strcmp(r->kind, "code") == 0) {
                TokenList tl = tokenize(r->payload);
                ASTNode *ast = parse(&tl);
                Value *result = eval_node(ast, g_server.global_env);
                char *result_str = value_to_string(result);

                const char *ct = "application/json";
                if (result_str[0] != '{' && result_str[0] != '[')
                    ct = "text/plain";
                send_response(fd, 200, "OK", ct, result_str, strlen(result_str));
                free(result_str);
            } else {
                const char *ct = "application/json";
                if (r->payload[0] != '{' && r->payload[0] != '[')
                    ct = "text/plain";
                send_response(fd, 200, "OK", ct, r->payload, strlen(r->payload));
            }
            close(fd);
            return;
        }
    }

    send_404(fd, path);
    close(fd);
}

void http_serve_blocking(int port) {
    int server_fd;

    if (g_server.early_bind_fd > 0) {
        g_init_complete = 1;
        if (g_health_thread_active) {
            int wake = socket(AF_INET, SOCK_STREAM, 0);
            if (wake >= 0) {
                struct sockaddr_in lo;
                memset(&lo, 0, sizeof(lo));
                lo.sin_family = AF_INET;
                lo.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                lo.sin_port = htons(port);
                connect(wake, (struct sockaddr*)&lo, sizeof(lo));
                close(wake);
            }
            pthread_join(g_health_tid, NULL);
            g_health_thread_active = 0;
            printf("Health thread stopped, main server taking over\n");
        }
        server_fd = g_server.early_bind_fd;
        printf("EigenScript HTTP server accepting on pre-bound 0.0.0.0:%d\n", port);
    } else {
        server_fd = socket(AF_INET, SOCK_STREAM, 0);
        if (server_fd < 0) {
            perror("socket");
            return;
        }

        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(port);

        if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            perror("bind");
            close(server_fd);
            return;
        }

        if (listen(server_fd, 128) < 0) {
            perror("listen");
            close(server_fd);
            return;
        }

        printf("EigenScript HTTP server listening on 0.0.0.0:%d\n", port);
    }
    fflush(stdout);

    signal(SIGPIPE, SIG_IGN);

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr*)&client_addr, &client_len);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }

        struct timeval tv;
        tv.tv_sec = 10;
        tv.tv_usec = 0;
        setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        handle_request(client_fd);
    }
}

/* ================================================================
 * MAIN
 * ================================================================ */

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: eigenscript <file.eigs>\n");
        return 1;
    }

    long src_size = 0;
    char *source = read_file(argv[1], &src_size);
    if (!source) {
        fprintf(stderr, "Error: cannot read file '%s'\n", argv[1]);
        return 1;
    }

    srand(time(NULL));

    Env *global = env_new(NULL);
    register_builtins(global);

    g_server.global_env = global;
    g_server.route_count = 0;
    g_server.static_prefix = NULL;
    g_server.static_dir = NULL;
    g_server.request_body = NULL;
    g_server.session_id = NULL;
    g_server.request_headers = NULL;

    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    eval_node(ast, global);

    free(source);
    return 0;
}
