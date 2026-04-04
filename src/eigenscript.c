/*
 * EigenScript Native Bootstrap Runtime
 * Complete implementation: tokenizer + parser + evaluator + builtins + HTTP server
 * Compiles with: gcc -O2 -o eigenscript eigenscript.c -lm -lpthread
 */

#include "eigenscript.h"
#include <pthread.h>

/* HTTP server globals and health thread are in ext_http.c */
jmp_buf g_return_buf;
Value *g_return_val = NULL;
int g_returning = 0;
static int g_parse_errors = 0;
static Env *g_global_env = NULL;
#if EIGENSCRIPT_EXT_MODEL
TransformerModel g_model = {0};
#endif
#if EIGENSCRIPT_EXT_DB
PGconn *g_db_conn = NULL;
#endif
/* Auth state moved to lib/auth.eigs — no C global needed */
static double g_computation_cost = 0.0;

/* Arena allocator and free_weight_val are in arena.c */

/* ================================================================
 * VALUE CONSTRUCTORS
 * ================================================================ */

Value* make_num(double n) {
    Value *v = g_arena.active ? arena_alloc(sizeof(Value)) : calloc(1, sizeof(Value));
    v->type = VAL_NUM;
    v->data.num = n;
    return v;
}

/* Heap-only make_num — for values that must outlive arena reset
 * (e.g. updated model weights written in-place by sgd_update). */
static Value* make_num_permanent(double n) {
    Value *v = calloc(1, sizeof(Value));
    v->type = VAL_NUM;
    v->data.num = n;
    return v;
}

Value* make_str(const char *s) {
    Value *v = g_arena.active ? arena_alloc(sizeof(Value)) : calloc(1, sizeof(Value));
    v->type = VAL_STR;
    v->data.str = strdup(s ? s : "");
    if (g_arena.active) arena_track_string(v->data.str);
    return v;
}

Value* make_null(void) {
    Value *v = g_arena.active ? arena_alloc(sizeof(Value)) : calloc(1, sizeof(Value));
    v->type = VAL_NULL;
    return v;
}

Value* make_list(int capacity) {
    Value *v = g_arena.active ? arena_alloc(sizeof(Value)) : calloc(1, sizeof(Value));
    v->type = VAL_LIST;
    v->data.list.capacity = capacity < 8 ? 8 : capacity;
    if (g_arena.active)
        v->data.list.items = arena_alloc(v->data.list.capacity * sizeof(Value*));
    else
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

void value_free(Value *v) {
    if (!v) return;
    switch (v->type) {
        case VAL_STR:
            free(v->data.str);
            break;
        case VAL_LIST:
            for (int i = 0; i < v->data.list.count; i++)
                value_free(v->data.list.items[i]);
            free(v->data.list.items);
            break;
        case VAL_FN:
            free(v->data.fn.name);
            free(v->data.fn.param);
            break;
        default:
            break;
    }
    free(v);
}

void list_append(Value *list, Value *item) {
    if (!list || list->type != VAL_LIST) return;
    if (list->data.list.count >= list->data.list.capacity) {
        int new_cap = list->data.list.capacity * 2;
        if (g_arena.active) {
            /* Cannot realloc arena memory — allocate new array and copy */
            Value **new_items = arena_alloc(new_cap * sizeof(Value*));
            memcpy(new_items, list->data.list.items, list->data.list.count * sizeof(Value*));
            list->data.list.items = new_items;
        } else {
            list->data.list.items = realloc(list->data.list.items, new_cap * sizeof(Value*));
        }
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
        case VAL_JSON_RAW: return v->data.str && v->data.str[0] != '\0';
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
        case VAL_JSON_RAW: return strdup(v->data.str);
    }
    return strdup("?");
}

/* ================================================================
 * ENVIRONMENT
 * ================================================================ */

Env* env_new(Env *parent) {
    Env *e = g_arena.active ? arena_alloc(sizeof(Env)) : calloc(1, sizeof(Env));
    e->parent = parent;
    e->count = 0;
    e->heap_allocated = !g_arena.active;
    e->captured = 0;
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
        char *name_copy = strdup(name);
        /* Only arena-track the string if the env is arena-allocated.
         * Heap env strings must survive arena_reset — they are freed
         * by env_free when the env's scope ends. */
        if (g_arena.active && !env->heap_allocated) arena_track_string(name_copy);
        env->names[env->count] = name_copy;
        env->values[env->count] = val;
        env->count++;
    }
}

void env_free(Env *env) {
    if (!env || !env->heap_allocated || env->captured) return;
    /* Free name strings. Heap env strings are never arena-tracked
     * (env_set_local only tracks strings for arena-allocated envs),
     * so these are always safe to free here. */
    for (int i = 0; i < env->count; i++)
        free(env->names[i]);
    free(env);
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
    if (strcmp(word, "elif") == 0) return TOK_ELIF;
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
            else g_parse_errors++; /* unterminated string */
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
                else { g_parse_errors++; p++; }
                break;
            case '=':
                if (*(p+1) == '=') { tok_add(&tl, TOK_EQ, 0, NULL, line); p += 2; }
                else { tok_add(&tl, TOK_ASSIGN, 0, NULL, line); p++; }
                break;
            default:
                g_parse_errors++; /* unknown character */
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
        g_parse_errors++;
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
        if (p_cur(p)->type == TOK_ELIF) {
            /* Treat elif as: else { if ... } — rewrite token and recurse */
            p_cur(p)->type = TOK_IF;
            else_body = malloc(sizeof(ASTNode*));
            else_body[0] = parse_statement(p);
            else_count = 1;
        } else if (p_cur(p)->type == TOK_ELSE) {
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
        ASTNode *n = make_node(AST_FOR);
        n->data.forloop.var = strdup(var_tok->str_val);
        n->data.forloop.iter = iter;
        n->data.forloop.body = body;
        n->data.forloop.body_count = body_count;
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
        case VAL_JSON_RAW: return 0.0;
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
                    env_free(call_env);
                    return g_return_val ? g_return_val : make_null();
                }
            }
            update_observer(result);
            env_set(env, "__observer__", result);
            env_free(call_env);
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

    case AST_FOR: {
        Value *iter = eval_node(node->data.forloop.iter, env);
        if (!iter || iter->type != VAL_LIST) return make_null();
        Value *result = make_null();
        for (int i = 0; i < iter->data.list.count; i++) {
            Env *loop_env = env_new(env);
            env_set_local(loop_env, node->data.forloop.var, iter->data.list.items[i]);
            result = eval_block(node->data.forloop.body, node->data.forloop.body_count, loop_env);
            if (g_returning) {
                env_free(loop_env);
                return result;
            }
            env_free(loop_env);
        }
        return result;
    }

    case AST_FUNC: {
        Value *fn = make_fn(node->data.func.name, node->data.func.param,
                           node->data.func.body, node->data.func.body_count, env);
        env->captured = 1;  /* This env is now a closure — do not free */
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
                if (!is_truthy(cond)) {
                    env_free(loop_env);
                    continue;
                }
            }
            Value *val = eval_node(node->data.listcomp.expr, loop_env);
            list_append(result, val);
            env_free(loop_env);
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

Value* builtin_num(Value *arg) {
    if (!arg) return make_num(0);
    if (arg->type == VAL_NUM) return arg;
    if (arg->type == VAL_STR) return make_num(strtod(arg->data.str, NULL));
    if (arg->type == VAL_NULL) return make_num(0);
    return make_num(0);
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

/* HTTP builtins moved to ext_http.c */


#if EIGENSCRIPT_EXT_MODEL
/* ================================================================
 * MODEL EXTENSION — weight loader, inference, training kernels
 * ================================================================ */

/* ---- JSON MODEL WEIGHT LOADER ---- */

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
    size_t got = fread(data, 1, size, f);
    fclose(f);
    if ((long)got != size) { fprintf(stderr, "Short read on model file: got %zu of %ld bytes\n", got, size); free(data); return -1; }
    data[size] = '\0';

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
    /* temperature controls sampling: < 0.01 = greedy argmax, otherwise top-k sampling */
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

        for (int i = 0; i < vocab_size; i++) {
            if (token_counts[i] > 0) {
                if (is_whitespace(i)) {
                } else if (is_common_token(i)) {
                    logits[i] -= 0.1 * token_counts[i];
                } else {
                    logits[i] -= 0.3 * token_counts[i];
                }
            }
        }

        int next_token;
        if (temperature < 0.01) {
            /* Greedy argmax — preserves original behavior */
            next_token = 0;
            double best = logits[0];
            for (int i = 1; i < vocab_size; i++) {
                if (logits[i] > best) { best = logits[i]; next_token = i; }
            }
        } else {
            /* Temperature-scaled top-k sampling.
             * rand() seeded via srand(time(NULL)) in main — adequate for
             * generation diversity, not cryptographic quality. */

            /* Scale logits by temperature */
            for (int i = 0; i < vocab_size; i++)
                logits[i] /= temperature;

            /* Stable softmax */
            double max_l = logits[0];
            for (int i = 1; i < vocab_size; i++)
                if (logits[i] > max_l) max_l = logits[i];
            double sum = 0.0;
            for (int i = 0; i < vocab_size; i++) {
                logits[i] = exp(logits[i] - max_l);
                sum += logits[i];
            }
            for (int i = 0; i < vocab_size; i++)
                logits[i] /= sum;

            /* Top-k filter (k=40).
             * probs_sorted is sized to VOCAB_SIZE (256) which equals byte-vocab.
             * If vocab_size ever becomes dynamic/larger, this must be heap-allocated. */
            int top_k = 40;
            if (top_k > vocab_size) top_k = vocab_size;
            double probs_sorted[VOCAB_SIZE];
            memcpy(probs_sorted, logits, (size_t)vocab_size * sizeof(double));
            /* Partial sort: move top_k largest to front */
            for (int j = 0; j < top_k; j++) {
                int max_idx = j;
                for (int i = j + 1; i < vocab_size; i++)
                    if (probs_sorted[i] > probs_sorted[max_idx]) max_idx = i;
                double tmp = probs_sorted[j];
                probs_sorted[j] = probs_sorted[max_idx];
                probs_sorted[max_idx] = tmp;
            }
            double threshold = probs_sorted[top_k - 1];
            double filtered_sum = 0.0;
            for (int i = 0; i < vocab_size; i++) {
                if (logits[i] < threshold) logits[i] = 0.0;
                filtered_sum += logits[i];
            }
            if (filtered_sum > 0.0) {
                for (int i = 0; i < vocab_size; i++)
                    logits[i] /= filtered_sum;
            }

            /* Weighted random sample */
            double r = (double)rand() / (double)RAND_MAX;
            double cumsum = 0.0;
            next_token = vocab_size - 1; /* fallback to last token */
            for (int i = 0; i < vocab_size; i++) {
                cumsum += logits[i];
                if (cumsum >= r) { next_token = i; break; }
            }
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

/* Dead extract_json_string removed — replaced by json_path builtin */
/* Dead builtin_eigen_train removed — now in training.eigs via native_train_step_builtin */

#if EIGENSCRIPT_EXT_DB
/* These builtins need both MODEL and DB (training data comes from Postgres) */
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

#endif /* EIGENSCRIPT_EXT_DB — batch_train needs both MODEL and DB */

/* Dead builtin_model_save removed — now in training.eigs via model_save_weights */

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
        char buf[1024];
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
    "observation", "observations", "observer", "effect", "geometry", "geometric",
    "watch", "step", "result", "final", "measure", "changed",
    "track", "happen", "state", "output", "changes", "language",
    "finds", "models", "model", "mode", "strict", "endpoint", "holonomy",
    "temporal", "when", "things", "jon", "mcreynolds",
    "maker", "creator", "trained", "knowledge", "settled", "stable",
    "converged", "diverges", "drift", "identity", "native", "persist",
    "remain", "repetition", "self-observation", "myself", "nothing",
    "something", "else", "exist", "holds", "does", "change",
    "alexa", "siri", "chatgpt", NULL
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

/* is_trained_prompt — extracted to prompts.eigs */

/* Deflection guard (check_deflection, is_self_prompt, is_content_prompt,
 * is_identity_token) — extracted to guards.eigs */

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

/* Dead replay buffer removed — training now orchestrated by .eigs modules */

Value* eigs_json_parse_value(const char *s, int *pos);

static Value* json_obj_get(Value *obj, const char *key) {
    if (!obj || obj->type != VAL_LIST) return NULL;
    for (int i = 0; i + 1 < obj->data.list.count; i += 2) {
        Value *k = obj->data.list.items[i];
        if (k && k->type == VAL_STR && strcmp(k->data.str, key) == 0) {
            return obj->data.list.items[i + 1];
        }
    }
    return NULL;
}

/* call_openai_fallback — extracted to chat.eigs (uses http_post + json_path) */

/* Dead monolithic eigen_hybrid_chat removed (264 lines) — now in chat.eigs */

#endif /* EIGENSCRIPT_EXT_MODEL — model_load and sanitization */

#if EIGENSCRIPT_EXT_DB
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

/* Dead corpus/feedback/auth/analytics/stats builtins removed —
   now in corpus.eigs, admin.eigs, auth.eigs via thin DB builtins */

#endif /* EIGENSCRIPT_EXT_DB */

#if EIGENSCRIPT_EXT_MODEL
Value* builtin_eigen_check_openai(Value *arg) {
    (void)arg;
    const char *key = getenv("AI_INTEGRATIONS_OPENAI_API_KEY");
    if (!key || !key[0]) key = getenv("OPENAI_API_KEY");
    if (key && key[0]) {
        fprintf(stderr, "OpenAI fallback: ENABLED (API key found)\n");
        return make_str("{\"available\": true}");
    }
    fprintf(stderr, "WARNING: OpenAI fallback DISABLED - no API key configured (set AI_INTEGRATIONS_OPENAI_API_KEY or OPENAI_API_KEY)\n");
    return make_str("{\"available\": false}");
}

/* Dead community_stats builtin removed — now in admin.eigs */

#endif /* EIGENSCRIPT_EXT_MODEL — check_openai */

#if EIGENSCRIPT_EXT_MODEL && EIGENSCRIPT_EXT_DB
Value* builtin_eigen_export_corpus(Value *arg) {
    (void)arg;
    if (!g_db_conn) return make_str("{\"status\": \"error\", \"error\": \"Database not connected\"}");

    PGresult *res = PQexec(g_db_conn,
        "SELECT user_message, bot_response, inference_mode FROM conversations "
        "WHERE used_for_training = false AND bot_response != '' AND bot_response != 'I don''t know about that yet.' "
        "ORDER BY id ASC");

    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        char buf[512];
        snprintf(buf, sizeof(buf), "{\"status\": \"error\", \"error\": \"%s\"}", PQerrorMessage(g_db_conn));
        PQclear(res);
        return make_str(buf);
    }

    int nrows = PQntuples(res);
    if (nrows == 0) {
        PQclear(res);
        return make_str("{\"status\": \"ok\", \"exported\": 0, \"message\": \"No new conversations to export\"}");
    }

    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char filename[256];
    snprintf(filename, sizeof(filename), "../../corpus/community/export_%04d%02d%02d_%02d%02d%02d.json",
        t->tm_year + 1900, t->tm_mon + 1, t->tm_mday, t->tm_hour, t->tm_min, t->tm_sec);

    int buf_size = nrows * 1024 + 4096;
    if (buf_size < 65536) buf_size = 65536;
    char *json_buf = calloc(buf_size, 1);
    int pos = 0;
    pos += snprintf(json_buf + pos, buf_size - pos, "[\n");

    int native_count = 0, fallback_count = 0, exported = 0, skipped = 0;
    for (int i = 0; i < nrows; i++) {
        if (pos >= buf_size - 2048) { skipped = nrows - i; break; }
        const char *msg = PQgetvalue(res, i, 0);
        const char *resp = PQgetvalue(res, i, 1);
        const char *mode = PQgetvalue(res, i, 2);

        if (!msg || !resp || msg[0] == '\0' || resp[0] == '\0') continue;
        if (strlen(msg) < 2 || strlen(resp) < 2) continue;

        if (exported > 0) pos += snprintf(json_buf + pos, buf_size - pos, ",\n");

        char esc_msg[2048] = {0};
        int em = 0;
        for (int j = 0; msg[j] && em < 2040; j++) {
            if (msg[j] == '"') { esc_msg[em++] = '\\'; esc_msg[em++] = '"'; }
            else if (msg[j] == '\\') { esc_msg[em++] = '\\'; esc_msg[em++] = '\\'; }
            else if (msg[j] == '\n') { esc_msg[em++] = '\\'; esc_msg[em++] = 'n'; }
            else if (msg[j] == '\t') { esc_msg[em++] = '\\'; esc_msg[em++] = 't'; }
            else if ((unsigned char)msg[j] >= 0x20) esc_msg[em++] = msg[j];
        }

        char esc_resp[4096] = {0};
        int er = 0;
        for (int j = 0; resp[j] && er < 4088; j++) {
            if (resp[j] == '"') { esc_resp[er++] = '\\'; esc_resp[er++] = '"'; }
            else if (resp[j] == '\\') { esc_resp[er++] = '\\'; esc_resp[er++] = '\\'; }
            else if (resp[j] == '\n') { esc_resp[er++] = '\\'; esc_resp[er++] = 'n'; }
            else if (resp[j] == '\t') { esc_resp[er++] = '\\'; esc_resp[er++] = 't'; }
            else if ((unsigned char)resp[j] >= 0x20) esc_resp[er++] = resp[j];
        }

        pos += snprintf(json_buf + pos, buf_size - pos,
            "  {\"input\": \"%s\", \"target\": \"%s\", \"source\": \"%s\"}",
            esc_msg, esc_resp, mode);

        if (strcmp(mode, "native") == 0) native_count++;
        else fallback_count++;
        exported++;
    }
    pos += snprintf(json_buf + pos, buf_size - pos, "\n]\n");

    FILE *f = fopen(filename, "w");
    if (!f) {
        free(json_buf);
        PQclear(res);
        return make_str("{\"status\": \"error\", \"error\": \"Could not write export file\"}");
    }
    fputs(json_buf, f);
    fclose(f);
    free(json_buf);

    PGresult *upd = PQexec(g_db_conn,
        "UPDATE conversations SET used_for_training = true "
        "WHERE used_for_training = false AND bot_response != '' AND bot_response != 'I don''t know about that yet.'");
    if (upd) PQclear(upd);

    PQclear(res);

    const char *short_name = strrchr(filename, '/');
    if (short_name) short_name++; else short_name = filename;

    char result[1024];
    snprintf(result, sizeof(result),
        "{\"status\": \"ok\", \"exported\": %d, \"native\": %d, \"openai_fallback\": %d, \"skipped\": %d, \"filename\": \"%s\"}",
        exported, native_count, fallback_count, skipped, short_name);
    return make_str(result);
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

/* Dead monolithic API key builtins removed — now in admin.eigs */
#endif /* EIGENSCRIPT_EXT_MODEL && EIGENSCRIPT_EXT_DB — export_corpus */

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
        case VAL_JSON_RAW: return make_str("json_raw");
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

Value* eigs_json_parse_value(const char *s, int *pos);

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

Value* eigs_json_parse_value(const char *s, int *pos) {
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

Value* builtin_coalesce(Value *arg) {
    /* coalesce of [value, default] — returns value unless empty/null */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return arg ? arg : make_null();
    Value *val = arg->data.list.items[0];
    Value *def = arg->data.list.items[1];
    if (!val || val->type == VAL_NULL) return def;
    if (val->type == VAL_STR && val->data.str[0] == '\0') return def;
    return val;
}

Value* builtin_json_build(Value *arg) {
    /* json_build of [key1, val1, key2, val2, ...] — properly escaped JSON object */
    if (!arg || arg->type != VAL_LIST) return make_str("{}");
    int count = arg->data.list.count;
    int buf_size = count * 256 + 64;
    if (buf_size < 1024) buf_size = 1024;
    char *buf = calloc(buf_size, 1);
    int pos = 0;
    pos += snprintf(buf + pos, buf_size - pos, "{");
    for (int i = 0; i + 1 < count && pos < buf_size - 64; i += 2) {
        if (i > 0) pos += snprintf(buf + pos, buf_size - pos, ", ");
        char *key = value_to_string(arg->data.list.items[i]);
        Value *val = arg->data.list.items[i + 1];
        pos += snprintf(buf + pos, buf_size - pos, "\"%s\": ", key);
        free(key);
        if (val->type == VAL_STR) {
            char *vs = val->data.str;
            buf[pos++] = '"';
            for (int j = 0; vs[j] && pos < buf_size - 10; j++) {
                if (vs[j] == '"') { buf[pos++] = '\\'; buf[pos++] = '"'; }
                else if (vs[j] == '\\') { buf[pos++] = '\\'; buf[pos++] = '\\'; }
                else if (vs[j] == '\n') { buf[pos++] = '\\'; buf[pos++] = 'n'; }
                else if (vs[j] == '\t') { buf[pos++] = '\\'; buf[pos++] = 't'; }
                else buf[pos++] = vs[j];
            }
            buf[pos++] = '"';
        } else if (val->type == VAL_NUM) {
            double d = val->data.num;
            if (d == (double)(int)d && d >= -1e9 && d <= 1e9)
                pos += snprintf(buf + pos, buf_size - pos, "%d", (int)d);
            else
                pos += snprintf(buf + pos, buf_size - pos, "%.6f", d);
        } else if (val->type == VAL_NULL) {
            pos += snprintf(buf + pos, buf_size - pos, "null");
        } else if (val->type == VAL_JSON_RAW) {
            pos += snprintf(buf + pos, buf_size - pos, "%s", val->data.str);
        } else {
            char *vs = value_to_string(val);
            pos += snprintf(buf + pos, buf_size - pos, "\"%s\"", vs);
            free(vs);
        }
    }
    pos += snprintf(buf + pos, buf_size - pos, "}");
    Value *result = make_str(buf);
    free(buf);
    return result;
}

Value* builtin_json_raw(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();
    Value *v = malloc(sizeof(Value));
    memset(v, 0, sizeof(Value));
    v->type = VAL_JSON_RAW;
    v->data.str = strdup(arg->data.str);
    return v;
}

/* ================================================================
 * GENERIC STRING PRIMITIVES — language-level, no product logic
 * ================================================================ */

Value* builtin_str_lower(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    char *s = strdup(arg->data.str);
    for (int i = 0; s[i]; i++) s[i] = tolower((unsigned char)s[i]);
    Value *r = make_str(s);
    free(s);
    return r;
}

Value* builtin_contains(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    const char *haystack = "", *needle = "";
    if (arg->data.list.items[0]->type == VAL_STR) haystack = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) needle = arg->data.list.items[1]->data.str;
    return make_num(strstr(haystack, needle) != NULL ? 1 : 0);
}

Value* builtin_starts_with(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    const char *str = "", *prefix = "";
    if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) prefix = arg->data.list.items[1]->data.str;
    return make_num(strncmp(str, prefix, strlen(prefix)) == 0 ? 1 : 0);
}

Value* builtin_split(Value *arg) {
    const char *str = "", *delim = " ";
    if (arg && arg->type == VAL_STR) {
        str = arg->data.str;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
        if (arg->data.list.count >= 2 && arg->data.list.items[1]->type == VAL_STR)
            delim = arg->data.list.items[1]->data.str;
    }
    Value *list = make_list(0);
    char *copy = strdup(str);
    char *saveptr;
    char *token = strtok_r(copy, delim, &saveptr);
    while (token) {
        list_append(list, make_str(token));
        token = strtok_r(NULL, delim, &saveptr);
    }
    free(copy);
    return list;
}

Value* builtin_trim(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *s = arg->data.str;
    while (*s && (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r')) s++;
    int len = strlen(s);
    while (len > 0 && (s[len-1] == ' ' || s[len-1] == '\t' || s[len-1] == '\n' || s[len-1] == '\r')) len--;
    char *r = malloc(len + 1);
    memcpy(r, s, len);
    r[len] = '\0';
    Value *result = make_str(r);
    free(r);
    return result;
}

Value* builtin_str_replace(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_str("");
    const char *str = "", *old_s = "", *new_s = "";
    if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) old_s = arg->data.list.items[1]->data.str;
    if (arg->data.list.items[2]->type == VAL_STR) new_s = arg->data.list.items[2]->data.str;
    int old_len = strlen(old_s), new_len = strlen(new_s), str_len = strlen(str);
    if (old_len == 0) return make_str(str);
    /* Count occurrences to size buffer */
    int count = 0;
    const char *p = str;
    while ((p = strstr(p, old_s)) != NULL) { count++; p += old_len; }
    int result_len = str_len + count * (new_len - old_len);
    char *result = malloc(result_len + 1);
    char *dst = result;
    p = str;
    while (*p) {
        if (strncmp(p, old_s, old_len) == 0) {
            memcpy(dst, new_s, new_len);
            dst += new_len;
            p += old_len;
        } else {
            *dst++ = *p++;
        }
    }
    *dst = '\0';
    Value *r = make_str(result);
    free(result);
    return r;
}

/* ================================================================
 * GENERIC HTTP CLIENT — language-level, no product logic
 * ================================================================ */

/* builtin_http_post moved to ext_http.c */

/* ================================================================
 * JSON PATH — dot-notation extraction from nested JSON
 * ================================================================ */

/* json_obj_get: needed by json_path, defined here if model extension is disabled */
#if !(EIGENSCRIPT_EXT_MODEL)
static Value* json_obj_get(Value *obj, const char *key) {
    if (!obj || obj->type != VAL_LIST) return NULL;
    for (int i = 0; i + 1 < obj->data.list.count; i += 2) {
        Value *k = obj->data.list.items[i];
        if (k && k->type == VAL_STR && strcmp(k->data.str, key) == 0)
            return obj->data.list.items[i + 1];
    }
    return NULL;
}
#endif

Value* builtin_json_path(Value *arg) {
    /* json_path of [json_string, "dot.path"] -> value as string, or "" */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_str("");
    const char *json_str = "", *path = "";
    if (arg->data.list.items[0]->type == VAL_STR) json_str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) path = arg->data.list.items[1]->data.str;

    int pos = 0;
    Value *current = eigs_json_parse_value(json_str, &pos);
    if (!current) return make_str("");

    char path_copy[1024];
    strncpy(path_copy, path, sizeof(path_copy) - 1);
    path_copy[sizeof(path_copy) - 1] = '\0';
    char *saveptr;
    char *segment = strtok_r(path_copy, ".", &saveptr);

    while (segment && current) {
        if (current->type == VAL_LIST) {
            /* Could be an object (key-value pairs) or array */
            /* Try numeric index first */
            char *endp;
            long idx = strtol(segment, &endp, 10);
            if (*endp == '\0') {
                /* Numeric: treat as array index */
                /* Arrays from json_decode are VAL_LIST with sequential elements */
                if (idx >= 0 && idx < current->data.list.count) {
                    current = current->data.list.items[idx];
                } else {
                    return make_str("");
                }
            } else {
                /* String key: treat as object lookup */
                current = json_obj_get(current, segment);
                if (!current) return make_str("");
            }
        } else {
            return make_str("");
        }
        segment = strtok_r(NULL, ".", &saveptr);
    }

    if (!current) return make_str("");
    if (current->type == VAL_STR) return make_str(current->data.str);
    if (current->type == VAL_NUM) {
        char buf[64];
        double d = current->data.num;
        if (d == (double)(int)d && fabs(d) < 1e9)
            snprintf(buf, sizeof(buf), "%d", (int)d);
        else
            snprintf(buf, sizeof(buf), "%.6f", d);
        return make_str(buf);
    }
    if (current->type == VAL_NULL) return make_str("");
    /* For complex types, json_encode them */
    char *encoded = malloc(MAX_STR);
    int epos = 0;
    eigs_json_encode_value(current, encoded, &epos, MAX_STR - 1);
    encoded[epos] = '\0';
    Value *r = make_str(encoded);
    free(encoded);
    return r;
}

/* Stubs removed — dead routes eliminated from eigen_server.eigs,
 * live routes now handled by .eigs modules (admin_ops.eigs etc.) */

Value* builtin_computation_cost(Value *arg) {
    (void)arg;
    return make_num(g_computation_cost);
}

/* ================================================================
 * LOAD_FILE — include mechanism for .eigs modules
 * ================================================================ */

/* File I/O helper — used by load_file and main() */
char* read_file_util(const char *path, long *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(size + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, size, f);
    fclose(f);
    if ((long)got != size) { free(buf); return NULL; }
    buf[size] = '\0';
    if (out_size) *out_size = size;
    return buf;
}

Value* builtin_load_file(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        fprintf(stderr, "load_file: requires a string path argument\n");
        return make_null();
    }
    long size = 0;
    char *source = read_file_util(arg->data.str, &size);
    if (!source) {
        fprintf(stderr, "load_file: cannot read '%s'\n", arg->data.str);
        return make_null();
    }
    fprintf(stderr, "[load_file] Loading %s (%ld bytes)\n", arg->data.str, size);
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    Value *result = eval_node(ast, g_global_env);
    free(source);
    return result ? result : make_null();
}

/* ================================================================
 * THIN BUILTINS — individual capabilities for .eigs orchestration
 * ================================================================ */

#if EIGENSCRIPT_EXT_MODEL
Value* builtin_eigen_model_loaded(Value *arg) {
    (void)arg;
    return make_num(g_model.loaded ? 1 : 0);
}

Value* builtin_eigen_generate(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        fprintf(stderr, "eigen_generate: requires [prompt, temperature, max_tokens]\n");
        return make_str("");
    }
    const char *prompt = "";
    double temperature = 0.1;
    int max_tokens = 80;

    if (arg->data.list.items[0]->type == VAL_STR) prompt = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_NUM) temperature = arg->data.list.items[1]->data.num;
    if (arg->data.list.items[2]->type == VAL_NUM) max_tokens = (int)arg->data.list.items[2]->data.num;

    if (!g_model.loaded) return make_str("");

    char *response = generate_response(prompt, &g_model, temperature, max_tokens);
    Value *result = make_str(response ? response : "");
    free(response);
    return result;
}

Value* builtin_eigen_sanitize(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    char *buf = strdup(arg->data.str);
    sanitize_input(buf);
    Value *result = make_str(buf);
    free(buf);
    return result;
}

Value* builtin_eigen_clean_response(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");

    char *clean = strdup(arg->data.str);
    int clen = strlen(clean);

    /* Trim at "User:" marker */
    char *user_marker = strstr(clean, "User:");
    if (user_marker) { *user_marker = '\0'; clen = strlen(clean); }

    /* Trim leading whitespace */
    char *start = clean;
    while (*start == ' ' || *start == '\t' || *start == '\n') start++;

    /* Trim trailing whitespace */
    clen = strlen(start);
    while (clen > 0 && (start[clen-1] == ' ' || start[clen-1] == '\n')) start[--clen] = '\0';

    /* Find last good sentence boundary (same logic as builtin_eigen_hybrid_chat lines 3636-3678) */
    int last_good = -1;
    for (int i = clen - 1; i > 5; i--) {
        if (start[i] == '.' || start[i] == '!' || start[i] == '?') {
            int prev_end = -1;
            for (int j = i - 1; j >= 0; j--) {
                if (start[j] == '.' || start[j] == '!' || start[j] == '?') { prev_end = j; break; }
            }
            int seg_len = i - prev_end;
            if (prev_end == -1) { last_good = i; break; }
            if (seg_len >= 10) {
                int seg_start = prev_end + 1;
                int word_count = 0, total_word_chars = 0, wl = 0;
                for (int k = seg_start; k <= i; k++) {
                    char ch = start[k];
                    if (ch == ' ' || ch == '.' || ch == '!' || ch == '?') {
                        if (wl > 0) { word_count++; total_word_chars += wl; wl = 0; }
                    } else { wl++; }
                }
                if (wl > 0) { word_count++; total_word_chars += wl; }
                double avg_wl = word_count > 0 ? (double)total_word_chars / word_count : 0;
                if (avg_wl >= 3.0) { last_good = i; break; }
            }
        }
    }
    if (last_good > 5 && last_good < clen - 1) {
        if (last_good + 1 >= 20) {
            start[last_good + 1] = '\0';
        }
    }

    Value *result = make_str(start);
    free(clean);
    return result;
}

Value* builtin_eigen_is_garble(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(1);
    return make_num(is_garble_response(arg->data.str) ? 1 : 0);
}

/* eigen_is_trained_prompt — extracted to prompts.eigs */

/* eigen_check_deflection_v2 — extracted to guards.eigs */

/* eigen_check_identity — extracted to guards.eigs */

/* eigen_openai_chat — extracted to chat.eigs (uses http_post + json_path) */

/* eigen_db_insert_conversation — extracted to chat.eigs (uses db_execute) */

Value* builtin_eigen_conversation_count(Value *arg) {
    (void)arg;
    return make_num(g_conversation_count);
}

/* eigen_extract_message — replaced by json_path in .eigs */
/* eigen_build_chat_response — extracted to chat.eigs */
/* eigen_extract_json_field — replaced by json_path in .eigs */

/* ================================================================
 * THIN TRAINING/MODEL BUILTINS — core platform capabilities
 * ================================================================ */

Value* builtin_native_train_step(Value *arg) {
    /* Thin wrapper around native_train_step().
     * Input: [input_text, output_text, learning_rate]
     * Output: JSON string with status, loss, tokens, model_age, training_samples */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        return make_str("{\"status\": \"error\", \"error\": \"requires [input, output, lr]\"}");
    }
    if (!g_model.loaded) {
        return make_str("{\"status\": \"error\", \"error\": \"Model not loaded\"}");
    }

    const char *input = "";
    const char *output = "";
    double lr = 0.001;

    if (arg->data.list.items[0]->type == VAL_STR) input = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) output = arg->data.list.items[1]->data.str;
    if (arg->data.list.items[2]->type == VAL_NUM) lr = arg->data.list.items[2]->data.num;
    else if (arg->data.list.items[2]->type == VAL_STR) lr = strtod(arg->data.list.items[2]->data.str, NULL);

    if (lr <= 0 || lr > 1) lr = 0.001;

    double loss = 0.0;
    int tokens_trained = 0;
    int result = native_train_step(input, output, lr, &loss, &tokens_trained);

    char buf[512];
    if (result == 0) {
        double effective_lr = lr / log((double)g_model_age + M_E);
        snprintf(buf, sizeof(buf),
            "{\"status\": \"trained\", \"loss\": %.6f, \"tokens_trained\": %d, "
            "\"model_age\": %d, \"training_samples\": %d, \"effective_lr\": %.6f, \"engine\": \"eigenscript\"}",
            loss, tokens_trained, g_model_age, g_training_samples, effective_lr);
    } else {
        snprintf(buf, sizeof(buf), "{\"status\": \"error\", \"error\": \"Training step failed\"}");
    }
    return make_str(buf);
}

Value* builtin_model_save_weights(Value *arg) {
    /* Thin wrapper around save_model_weights().
     * Input: path (string)
     * Output: JSON status */
    if (!arg || arg->type != VAL_STR || arg->data.str[0] == '\0') {
        return make_str("{\"status\": \"error\", \"error\": \"requires path string\"}");
    }
    const char *path = arg->data.str;
    fprintf(stderr, "[model-save] Saving to: %s\n", path);

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

Value* builtin_model_load_weights(Value *arg) {
    /* Thin wrapper around load_model_weights().
     * Input: path (string) — checks for _live.json variant automatically
     * Output: JSON status with model config */
    if (!arg || arg->type != VAL_STR || arg->data.str[0] == '\0') {
        return make_str("{\"status\": \"error\", \"error\": \"requires path string\"}");
    }
    const char *base_path = arg->data.str;
    char live_path[512];
    const char *path = base_path;

    /* Check for _live.json variant */
    int base_len = strlen(base_path);
    if (base_len > 5 && strcmp(base_path + base_len - 5, ".json") == 0) {
        snprintf(live_path, sizeof(live_path), "%.*s_live.json", base_len - 5, base_path);
        FILE *f = fopen(live_path, "r");
        if (f) {
            fclose(f);
            path = live_path;
            fprintf(stderr, "[model-load] Found live weights: %s\n", live_path);
        } else {
            fprintf(stderr, "[model-load] No live weights, using: %s\n", base_path);
        }
    }

    fprintf(stderr, "[model-load] Loading from: %s\n", path);
    int result = load_model_weights(path, &g_model);
    if (result == 0) {
        char buf[1024];
        snprintf(buf, sizeof(buf),
            "{\"status\": \"loaded\", \"vocab_size\": %d, \"n_layers\": %d, \"d_model\": %d, \"d_ff\": %d, \"path\": \"%s\"}",
            g_model.config.vocab_size, g_model.config.n_layers, g_model.config.d_model, g_model.config.d_ff, path);
        return make_str(buf);
    }
    return make_str("{\"status\": \"error\", \"error\": \"Failed to load model weights\"}");
}

/* builtin_file_exists moved to core section (always available) */

/* ================================================================
 * THIN PLATFORM BUILTINS — model info
 * ================================================================ */

Value* builtin_eigen_model_info(Value *arg) {
    (void)arg;
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"model_loaded\": %s, \"vocab_size\": %d, \"d_model\": %d, \"n_layers\": %d, "
        "\"model_age\": %d, \"training_samples\": %d, \"inference_engine\": \"eigenscript\"}",
        g_model.loaded ? "true" : "false",
        g_model.config.vocab_size, g_model.config.d_model, g_model.config.n_layers,
        g_model_age, g_training_samples);
    return make_str(buf);
}

/* builtin_env_get moved to core section (always available) */

#endif /* EIGENSCRIPT_EXT_MODEL */

#if EIGENSCRIPT_EXT_DB
/* ================================================================
 * THIN DB BUILTINS — general-purpose database capabilities
 * ================================================================ */

Value* builtin_db_query_value(Value *arg) {
    /* Run a SQL query and return the value from row 0 col 0 as a string.
     * Usage: db_query_value of "SELECT COUNT(*) FROM table"
     * Returns "" if no DB, query fails, or no rows. */
    if (!arg || arg->type != VAL_STR) return make_str("");
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("");
    PGresult *res = PQexec(g_db_conn, arg->data.str);
    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) == 0) {
        PQclear(res);
        return make_str("");
    }
    const char *val = PQgetvalue(res, 0, 0);
    Value *result = make_str(val ? val : "");
    PQclear(res);
    return result;
}

Value* builtin_db_execute(Value *arg) {
    /* Run a SQL command with optional params. Returns "ok" or "error".
     * Usage: db_execute of "INSERT INTO ..." (no params)
     *    or: db_execute of ["INSERT INTO t (a) VALUES ($1)", param1] */
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("no_db");
    PGresult *res = NULL;

    if (arg && arg->type == VAL_STR) {
        res = PQexec(g_db_conn, arg->data.str);
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        const char *sql = "";
        if (arg->data.list.items[0]->type == VAL_STR) sql = arg->data.list.items[0]->data.str;
        int nparams = arg->data.list.count - 1;
        if (nparams == 0) {
            res = PQexec(g_db_conn, sql);
        } else {
            const char *params[16];
            char numbuf[16][64];
            if (nparams > 16) nparams = 16;
            for (int i = 0; i < nparams; i++) {
                Value *v = arg->data.list.items[i + 1];
                if (v->type == VAL_STR) {
                    params[i] = v->data.str;
                } else if (v->type == VAL_NUM) {
                    snprintf(numbuf[i], sizeof(numbuf[i]), "%g", v->data.num);
                    params[i] = numbuf[i];
                } else {
                    params[i] = "";
                }
            }
            res = PQexecParams(g_db_conn, sql, nparams, NULL, params, NULL, NULL, 0);
        }
    } else {
        return make_str("error");
    }

    int ok = (PQresultStatus(res) == PGRES_COMMAND_OK || PQresultStatus(res) == PGRES_TUPLES_OK);
    PQclear(res);
    return make_str(ok ? "ok" : "error");
}

Value* builtin_db_query_json(Value *arg) {
    /* Run SQL and return all rows as a JSON array of objects.
     * Usage: db_query_json of "SELECT id, name FROM table"
     * Returns "[]" if no DB, error, or no rows. */
    if (!arg || arg->type != VAL_STR) return make_str("[]");
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) return make_str("[]");
    PGresult *res = PQexec(g_db_conn, arg->data.str);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        PQclear(res);
        return make_str("[]");
    }
    int nrows = PQntuples(res);
    int ncols = PQnfields(res);
    if (nrows == 0 || ncols == 0) { PQclear(res); return make_str("[]"); }

    int buf_size = nrows * ncols * 256 + 256;
    if (buf_size > 1048576) buf_size = 1048576;
    char *buf = calloc(buf_size, 1);
    int pos = 0;
    pos += snprintf(buf + pos, buf_size - pos, "[");
    for (int r = 0; r < nrows && pos < buf_size - 512; r++) {
        if (r > 0) pos += snprintf(buf + pos, buf_size - pos, ", ");
        pos += snprintf(buf + pos, buf_size - pos, "{");
        for (int c = 0; c < ncols && pos < buf_size - 256; c++) {
            if (c > 0) pos += snprintf(buf + pos, buf_size - pos, ", ");
            const char *colname = PQfname(res, c);
            const char *val = PQgetvalue(res, r, c);
            /* Escape value for JSON */
            char escaped[512];
            int ei = 0;
            for (int i = 0; val[i] && ei < 500; i++) {
                if (val[i] == '"') { escaped[ei++] = '\\'; escaped[ei++] = '"'; }
                else if (val[i] == '\\') { escaped[ei++] = '\\'; escaped[ei++] = '\\'; }
                else if (val[i] == '\n') { escaped[ei++] = '\\'; escaped[ei++] = 'n'; }
                else escaped[ei++] = val[i];
            }
            escaped[ei] = '\0';
            pos += snprintf(buf + pos, buf_size - pos, "\"%s\": \"%s\"", colname, escaped);
        }
        pos += snprintf(buf + pos, buf_size - pos, "}");
    }
    pos += snprintf(buf + pos, buf_size - pos, "]");

    PQclear(res);
    Value *result = make_str(buf);
    free(buf);
    return result;
}

/* Generate API key — needs /dev/urandom and SHA256, must stay in C */
Value* builtin_generate_api_key(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("{}");
    const char *name = arg->data.str;

    unsigned char raw_bytes[16];
    FILE *urand = fopen("/dev/urandom", "rb");
    if (urand) {
        if (fread(raw_bytes, 1, 16, urand) != 16) {
            fclose(urand);
            return make_str("{\"error\": \"Failed to read random bytes\"}");
        }
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

    char key_prefix[16];
    snprintf(key_prefix, sizeof(key_prefix), "eig_%.8s", raw_key + 4);

    /* Store in DB if available */
    if (g_db_conn && PQstatus(g_db_conn) == CONNECTION_OK) {
        ensure_api_keys_table();
        const char *params[3] = {name, key_hash, key_prefix};
        PGresult *res = PQexecParams(g_db_conn,
            "INSERT INTO api_keys (name, key_hash, key_prefix) VALUES ($1, $2, $3)",
            3, NULL, params, NULL, NULL, 0);
        PQclear(res);
    }

    char buf[256];
    snprintf(buf, sizeof(buf), "{\"success\": true, \"key\": \"%s\"}", raw_key);
    return make_str(buf);
}

/* Validate API key — needs SHA256, must stay in C */
Value* builtin_validate_api_key(Value *arg) {
    if (!arg || arg->type != VAL_STR || arg->data.str[0] == '\0') {
        return make_str("{\"valid\": false, \"error\": \"no key provided\"}");
    }
    if (!g_db_conn || PQstatus(g_db_conn) != CONNECTION_OK) {
        return make_str("{\"valid\": false, \"error\": \"no database\"}");
    }

    char key_hash[65];
    sha256_hex(arg->data.str, key_hash);

    ensure_api_keys_table();
    const char *params[1] = {key_hash};
    PGresult *res = PQexecParams(g_db_conn,
        "SELECT id, name FROM api_keys WHERE key_hash = $1 AND is_active = TRUE",
        1, NULL, params, NULL, NULL, 0);

    if (PQresultStatus(res) != PGRES_TUPLES_OK || PQntuples(res) == 0) {
        PQclear(res);
        return make_str("{\"valid\": false}");
    }

    const char *name = PQgetvalue(res, 0, 1);
    char buf[512];
    snprintf(buf, sizeof(buf), "{\"valid\": true, \"name\": \"%s\"}", name);
    PQclear(res);

    /* Update last_used */
    const char *update_params[1] = {key_hash};
    PGresult *upd = PQexecParams(g_db_conn,
        "UPDATE api_keys SET last_used = NOW() WHERE key_hash = $1",
        1, NULL, update_params, NULL, NULL, 0);
    PQclear(upd);

    return make_str(buf);
}

#endif /* EIGENSCRIPT_EXT_DB */

/* Auth builtins removed — now in lib/auth.eigs using random_hex + env_get.
 * The EIGENSCRIPT_EXT_AUTH flag is no longer needed for builtins.
 * Auth state is an EigenScript variable, not a C global. */

/* ================================================================
 * CORE PLATFORM BUILTINS (always available)
 * ================================================================ */

Value* builtin_file_exists(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    FILE *f = fopen(arg->data.str, "r");
    if (f) { fclose(f); return make_num(1); }
    return make_num(0);
}

Value* builtin_env_get(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *val = getenv(arg->data.str);
    return make_str(val ? val : "");
}

/* ================================================================
 * CORE MATH KERNELS (always available)
 * Used by tensor builtins (matmul, softmax). Also used by model
 * extension when enabled, but needed for the language stdlib too.
 * ================================================================ */

#if !(EIGENSCRIPT_EXT_MODEL)
/* These are defined in the model section when MODEL is enabled.
 * When MODEL is disabled, we need standalone definitions. */
static void ne_softmax_buf(double* data, int64_t rows, int64_t cols) {
    for (int64_t r = 0; r < rows; r++) {
        double *row = data + r * cols;
        double max_val = row[0];
        for (int64_t c = 1; c < cols; c++)
            if (row[c] > max_val) max_val = row[c];
        double sum = 0.0;
        for (int64_t c = 0; c < cols; c++) {
            row[c] = exp(row[c] - max_val);
            sum += row[c];
        }
        for (int64_t c = 0; c < cols; c++)
            row[c] /= sum;
    }
}

static void ne_matmul_buf(
    double *a, int64_t a_rows, int64_t a_cols,
    double *b, int64_t b_cols, double *out
) {
    memset(out, 0, a_rows * b_cols * sizeof(double));
    for (int64_t i = 0; i < a_rows; i++)
        for (int64_t k = 0; k < a_cols; k++)
            for (int64_t j = 0; j < b_cols; j++)
                out[i * b_cols + j] += a[i * a_cols + k] * b[k * b_cols + j];
}
#endif

/* json_obj_get moved to before json_path (see below) */

/* ====================================================================
 * TENSOR SUBSTRATE BUILTINS
 * Expose tensor operations so the .eigs standard library can run natively.
 * Tensors are represented as nested VAL_LIST of VAL_NUM (1D or 2D).
 * ==================================================================== */

/* --- Tensor helper: detect dimensions --- */
static int tensor_dims(Value *v, int *rows, int *cols) {
    if (!v || v->type != VAL_LIST || v->data.list.count == 0) return 0;
    Value *first = v->data.list.items[0];
    if (first->type == VAL_NUM) {
        /* 1D tensor */
        *rows = 1;
        *cols = v->data.list.count;
        return 1;
    }
    if (first->type == VAL_LIST) {
        /* 2D tensor */
        *rows = v->data.list.count;
        *cols = first->data.list.count;
        return 2;
    }
    return 0;
}

/* --- Tensor helper: flatten nested list to double* (caller must free) --- */
static double* tensor_to_flat(Value *v, int *rows, int *cols) {
    int ndim = tensor_dims(v, rows, cols);
    if (ndim == 0) return NULL;
    int total = (*rows) * (*cols);
    double *out = calloc(total, sizeof(double));
    if (ndim == 1) {
        for (int i = 0; i < *cols; i++)
            out[i] = (v->data.list.items[i]->type == VAL_NUM) ? v->data.list.items[i]->data.num : 0.0;
    } else {
        for (int r = 0; r < *rows; r++) {
            Value *row = v->data.list.items[r];
            int rc = (row->type == VAL_LIST) ? row->data.list.count : 0;
            for (int c = 0; c < *cols && c < rc; c++)
                out[r * (*cols) + c] = (row->data.list.items[c]->type == VAL_NUM) ? row->data.list.items[c]->data.num : 0.0;
        }
    }
    return out;
}

/* --- Tensor helper: flat double* to 2D nested list --- */
static Value* flat_to_tensor_2d(double *data, int rows, int cols) {
    Value *outer = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *row = make_list(cols);
        for (int c = 0; c < cols; c++)
            list_append(row, make_num(data[r * cols + c]));
        list_append(outer, row);
    }
    return outer;
}

/* --- Tensor helper: flat double* to 1D list --- */
static Value* flat_to_tensor_1d(double *data, int len) {
    Value *out = make_list(len);
    for (int i = 0; i < len; i++)
        list_append(out, make_num(data[i]));
    return out;
}

/* --- Tensor helper: count total elements recursively --- */
static int tensor_total(Value *v) {
    if (!v) return 0;
    if (v->type == VAL_NUM) return 1;
    if (v->type != VAL_LIST) return 0;
    int total = 0;
    for (int i = 0; i < v->data.list.count; i++)
        total += tensor_total(v->data.list.items[i]);
    return total;
}

/* --- Tensor helper: flatten any depth to flat array --- */
static void tensor_flatten_recursive(Value *v, double *out, int *idx) {
    if (!v) return;
    if (v->type == VAL_NUM) { out[(*idx)++] = v->data.num; return; }
    if (v->type != VAL_LIST) return;
    for (int i = 0; i < v->data.list.count; i++)
        tensor_flatten_recursive(v->data.list.items[i], out, idx);
}

/* ---- Element-wise binary op on two tensors (or scalar broadcast) ---- */
typedef double (*BinOpFn)(double, double);
static double op_add(double a, double b) { return a + b; }
static double op_sub(double a, double b) { return a - b; }
static double op_mul(double a, double b) { return a * b; }
static double op_div(double a, double b) { return (b == 0.0) ? 0.0 : a / b; }
static double op_pow(double a, double b) { return pow(a, b); }

static Value* tensor_elementwise(Value *a, Value *b, BinOpFn fn) {
    /* scalar op scalar */
    if (a->type == VAL_NUM && b->type == VAL_NUM)
        return make_num(fn(a->data.num, b->data.num));

    /* scalar broadcast to list */
    if (a->type == VAL_NUM && b->type == VAL_LIST) {
        Value *out = make_list(b->data.list.count);
        for (int i = 0; i < b->data.list.count; i++)
            list_append(out, tensor_elementwise(a, b->data.list.items[i], fn));
        return out;
    }
    if (a->type == VAL_LIST && b->type == VAL_NUM) {
        Value *out = make_list(a->data.list.count);
        for (int i = 0; i < a->data.list.count; i++)
            list_append(out, tensor_elementwise(a->data.list.items[i], b, fn));
        return out;
    }

    /* list op list (element-wise, matching shapes) */
    if (a->type == VAL_LIST && b->type == VAL_LIST) {
        int n = a->data.list.count < b->data.list.count ? a->data.list.count : b->data.list.count;
        Value *out = make_list(n);
        for (int i = 0; i < n; i++)
            list_append(out, tensor_elementwise(a->data.list.items[i], b->data.list.items[i], fn));
        return out;
    }
    return make_num(0.0);
}

/* ==== BUILTIN: add ==== */
Value* builtin_tensor_add(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_add);
}

/* ==== BUILTIN: subtract ==== */
Value* builtin_tensor_subtract(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_sub);
}

/* ==== BUILTIN: multiply ==== */
Value* builtin_tensor_multiply(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_mul);
}

/* ==== BUILTIN: divide ==== */
Value* builtin_tensor_divide(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_div);
}

/* ==== BUILTIN: pow ==== */
Value* builtin_tensor_pow(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    return tensor_elementwise(arg->data.list.items[0], arg->data.list.items[1], op_pow);
}

/* ---- Element-wise unary op ---- */
typedef double (*UnaryOpFn)(double);
static Value* tensor_unary(Value *v, UnaryOpFn fn) {
    if (v->type == VAL_NUM) return make_num(fn(v->data.num));
    if (v->type == VAL_LIST) {
        Value *out = make_list(v->data.list.count);
        for (int i = 0; i < v->data.list.count; i++)
            list_append(out, tensor_unary(v->data.list.items[i], fn));
        return out;
    }
    return make_num(0.0);
}

static double op_sqrt(double x) { return sqrt(x); }
static double op_exp(double x) { return exp(x); }
static double op_log_safe(double x) { return log(x > 1e-10 ? x : 1e-10); }
static double op_neg(double x) { return -x; }

/* ==== BUILTIN: sqrt ==== */
Value* builtin_tensor_sqrt(Value *arg) { return tensor_unary(arg, op_sqrt); }

/* ==== BUILTIN: exp ==== */
Value* builtin_tensor_exp(Value *arg) { return tensor_unary(arg, op_exp); }

/* ==== BUILTIN: log ==== */
Value* builtin_tensor_log(Value *arg) { return tensor_unary(arg, op_log_safe); }

/* ==== BUILTIN: negative ==== */
Value* builtin_tensor_negative(Value *arg) { return tensor_unary(arg, op_neg); }

/* ==== BUILTIN: matmul ==== */
Value* builtin_tensor_matmul(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    int ar, ac, br, bc;
    double *af = tensor_to_flat(a, &ar, &ac);
    double *bf = tensor_to_flat(b, &br, &bc);
    if (!af || !bf || ac != br) { free(af); free(bf); return make_null(); }
    double *out = calloc(ar * bc, sizeof(double));
    ne_matmul_buf(af, ar, ac, bf, bc, out);
    Value *result;
    if (ar == 1)
        result = flat_to_tensor_1d(out, bc);
    else
        result = flat_to_tensor_2d(out, ar, bc);
    free(af); free(bf); free(out);
    return result;
}

/* ==== BUILTIN: softmax ==== */
Value* builtin_tensor_softmax(Value *arg) {
    int rows, cols;
    double *flat = tensor_to_flat(arg, &rows, &cols);
    if (!flat) return make_null();
    ne_softmax_buf(flat, rows, cols);
    Value *result;
    if (rows == 1)
        result = flat_to_tensor_1d(flat, cols);
    else
        result = flat_to_tensor_2d(flat, rows, cols);
    free(flat);
    return result;
}

/* ==== BUILTIN: log_softmax ==== */
Value* builtin_tensor_log_softmax(Value *arg) {
    /* Accept: log_softmax of tensor  OR  log_softmax of [tensor, dim] */
    Value *tensor = arg;
    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        Value *first = arg->data.list.items[0];
        if (first->type == VAL_LIST) tensor = first; /* [tensor, dim] form */
    }
    int rows, cols;
    double *flat = tensor_to_flat(tensor, &rows, &cols);
    if (!flat) return make_null();
    ne_softmax_buf(flat, rows, cols);
    for (int i = 0; i < rows * cols; i++)
        flat[i] = log(flat[i] > 1e-10 ? flat[i] : 1e-10);
    Value *result;
    if (rows == 1)
        result = flat_to_tensor_1d(flat, cols);
    else
        result = flat_to_tensor_2d(flat, rows, cols);
    free(flat);
    return result;
}

/* ==== BUILTIN: relu ==== */
/* relu of tensor → element-wise max(0, x). Works on 1D or 2D. */
Value* builtin_tensor_relu(Value *arg) {
    int rows, cols;
    double *flat = tensor_to_flat(arg, &rows, &cols);
    if (!flat) return make_null();
    for (int i = 0; i < rows * cols; i++)
        if (flat[i] < 0.0) flat[i] = 0.0;
    Value *result;
    if (rows == 1)
        result = flat_to_tensor_1d(flat, cols);
    else
        result = flat_to_tensor_2d(flat, rows, cols);
    free(flat);
    return result;
}

/* ==== BUILTIN: leaky_relu ==== */
/* leaky_relu of tensor → element-wise max(0.01*x, x). Works on 1D or 2D. */
Value* builtin_tensor_leaky_relu(Value *arg) {
    int rows, cols;
    double *flat = tensor_to_flat(arg, &rows, &cols);
    if (!flat) return make_null();
    for (int i = 0; i < rows * cols; i++)
        if (flat[i] < 0.0) flat[i] *= 0.01;
    Value *result;
    if (rows == 1)
        result = flat_to_tensor_1d(flat, cols);
    else
        result = flat_to_tensor_2d(flat, rows, cols);
    free(flat);
    return result;
}

/* ==== BUILTIN: mean ==== */
Value* builtin_tensor_mean(Value *arg) {
    int total = tensor_total(arg);
    if (total == 0) return make_num(0.0);
    double *flat = calloc(total, sizeof(double));
    int idx = 0;
    tensor_flatten_recursive(arg, flat, &idx);
    double sum = 0.0;
    for (int i = 0; i < total; i++) sum += flat[i];
    free(flat);
    return make_num(sum / total);
}

/* ==== BUILTIN: sum ==== */
Value* builtin_tensor_sum(Value *arg) {
    int total = tensor_total(arg);
    if (total == 0) return make_num(0.0);
    double *flat = calloc(total, sizeof(double));
    int idx = 0;
    tensor_flatten_recursive(arg, flat, &idx);
    double sum = 0.0;
    for (int i = 0; i < total; i++) sum += flat[i];
    free(flat);
    return make_num(sum);
}

/* ==== BUILTIN: zeros ==== */
Value* builtin_tensor_zeros(Value *arg) {
    if (!arg) return make_null();
    /* zeros of n → 1D list of n zeros */
    if (arg->type == VAL_NUM) {
        int n = (int)arg->data.num;
        Value *out = make_list(n);
        for (int i = 0; i < n; i++) list_append(out, make_num(0.0));
        return out;
    }
    /* zeros of [rows, cols] → 2D */
    if (arg->type == VAL_LIST && arg->data.list.count >= 2
        && arg->data.list.items[0]->type == VAL_NUM
        && arg->data.list.items[1]->type == VAL_NUM) {
        int rows = (int)arg->data.list.items[0]->data.num;
        int cols = (int)arg->data.list.items[1]->data.num;
        Value *outer = make_list(rows);
        for (int r = 0; r < rows; r++) {
            Value *row = make_list(cols);
            for (int c = 0; c < cols; c++) list_append(row, make_num(0.0));
            list_append(outer, row);
        }
        return outer;
    }
    return make_null();
}

/* ==== BUILTIN: zeros_like ==== */
Value* builtin_tensor_zeros_like(Value *arg) {
    if (!arg) return make_null();
    if (arg->type == VAL_NUM) return make_num(0.0);
    if (arg->type == VAL_LIST) {
        Value *out = make_list(arg->data.list.count);
        for (int i = 0; i < arg->data.list.count; i++)
            list_append(out, builtin_tensor_zeros_like(arg->data.list.items[i]));
        return out;
    }
    return make_num(0.0);
}

/* ==== BUILTIN: gather ==== */
/* gather of [tensor, indices, dim] → select elements at indices along last dim */
Value* builtin_tensor_gather(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *tensor = arg->data.list.items[0];
    Value *indices = arg->data.list.items[1];
    /* Simple case: 2D tensor, 1D indices → select one element per row */
    if (tensor->type == VAL_LIST && indices->type == VAL_LIST) {
        int n = tensor->data.list.count < indices->data.list.count
              ? tensor->data.list.count : indices->data.list.count;
        Value *out = make_list(n);
        for (int i = 0; i < n; i++) {
            Value *row = tensor->data.list.items[i];
            int idx = 0;
            if (indices->data.list.items[i]->type == VAL_NUM)
                idx = (int)indices->data.list.items[i]->data.num;
            if (row->type == VAL_LIST && idx >= 0 && idx < row->data.list.count)
                list_append(out, make_num(row->data.list.items[idx]->type == VAL_NUM
                    ? row->data.list.items[idx]->data.num : 0.0));
            else
                list_append(out, make_num(0.0));
        }
        return out;
    }
    /* 1D tensor, scalar index */
    if (tensor->type == VAL_LIST && indices->type == VAL_NUM) {
        int idx = (int)indices->data.num;
        if (idx >= 0 && idx < tensor->data.list.count)
            return make_num(tensor->data.list.items[idx]->type == VAL_NUM
                ? tensor->data.list.items[idx]->data.num : 0.0);
    }
    return make_num(0.0);
}

/* ==== Helper: call a user-defined EigenScript function from C ==== */
static Value* call_eigs_fn(Value *fn, Value *arg) {
    if (fn->type == VAL_BUILTIN) return fn->data.builtin(arg);
    if (fn->type != VAL_FN) return make_null();
    Env *call_env = env_new(fn->data.fn.closure);
    env_set_local(call_env, fn->data.fn.param, arg);
    env_set_local(call_env, "n", arg);
    g_returning = 0;
    g_return_val = NULL;
    Value *result = make_null();
    for (int i = 0; i < fn->data.fn.body_count; i++) {
        result = eval_node(fn->data.fn.body[i], call_env);
        if (g_returning) {
            g_returning = 0;
            env_free(call_env);
            return g_return_val ? g_return_val : make_null();
        }
    }
    env_free(call_env);
    return result;
}

/* ==== BUILTIN: random_normal ==== */
/* random_normal of [rows, cols, scale] → 2D, or random_normal of [len, scale] → 1D */
Value* builtin_random_normal(Value *arg) {
    if (!arg || arg->type != VAL_LIST) return make_null();
    int argc = arg->data.list.count;
    if (argc == 3) {
        /* 2D: [rows, cols, scale] */
        int rows = (int)arg->data.list.items[0]->data.num;
        int cols = (int)arg->data.list.items[1]->data.num;
        double scale = arg->data.list.items[2]->data.num;
        Value *outer = make_list(rows);
        for (int r = 0; r < rows; r++) {
            Value *row = make_list(cols);
            for (int c = 0; c < cols; c++) {
                /* Box-Muller transform for normal distribution */
                double u1 = ((double)rand() + 1.0) / ((double)RAND_MAX + 1.0);
                double u2 = ((double)rand() + 1.0) / ((double)RAND_MAX + 1.0);
                double z = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
                list_append(row, make_num(z * scale));
            }
            list_append(outer, row);
        }
        return outer;
    }
    if (argc == 2) {
        /* 1D: [len, scale] */
        int len = (int)arg->data.list.items[0]->data.num;
        double scale = arg->data.list.items[1]->data.num;
        Value *out = make_list(len);
        for (int i = 0; i < len; i++) {
            double u1 = ((double)rand() + 1.0) / ((double)RAND_MAX + 1.0);
            double u2 = ((double)rand() + 1.0) / ((double)RAND_MAX + 1.0);
            double z = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
            list_append(out, make_num(z * scale));
        }
        return out;
    }
    return make_null();
}

/* ==== BUILTIN: shape ==== */
/* shape of tensor → [rows, cols] for 2D, [len] for 1D */
Value* builtin_tensor_shape(Value *arg) {
    if (!arg) return make_null();
    if (arg->type == VAL_NUM) {
        Value *out = make_list(0);
        return out; /* scalar: empty shape */
    }
    if (arg->type != VAL_LIST) return make_null();
    if (arg->data.list.count == 0) {
        Value *out = make_list(1);
        list_append(out, make_num(0));
        return out;
    }
    Value *first = arg->data.list.items[0];
    if (first->type == VAL_LIST) {
        /* 2D */
        Value *out = make_list(2);
        list_append(out, make_num(arg->data.list.count));
        list_append(out, make_num(first->data.list.count));
        return out;
    }
    /* 1D */
    Value *out = make_list(1);
    list_append(out, make_num(arg->data.list.count));
    return out;
}

/* ==== BUILTIN: numerical_grad ==== */
/* numerical_grad of [loss_fn, param, eps]
 * Computes central finite-difference gradient for every element of param.
 * loss_fn is a VAL_FN that takes null and returns a scalar loss.
 * param is a 1D or 2D tensor (VAL_LIST).
 * Returns gradient tensor matching param shape. */
Value* builtin_numerical_grad(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *loss_fn = arg->data.list.items[0];
    Value *param = arg->data.list.items[1];
    double eps = (arg->data.list.items[2]->type == VAL_NUM) ? arg->data.list.items[2]->data.num : 0.001;
    if (eps <= 0) eps = 0.001;

    if (param->type != VAL_LIST) return make_null();

    /* Check if 1D or 2D */
    int is_2d = (param->data.list.count > 0 && param->data.list.items[0]->type == VAL_LIST);

    if (!is_2d) {
        /* 1D param */
        int len = param->data.list.count;
        Value *grad = make_list(len);
        for (int i = 0; i < len; i++) {
            Value *orig = param->data.list.items[i];
            double old_val = (orig->type == VAL_NUM) ? orig->data.num : 0.0;
            /* Perturb +eps */
            Value *pp = make_num_permanent(old_val + eps);
            param->data.list.items[i] = pp;
            Value *loss_plus = call_eigs_fn(loss_fn, make_null());
            double lp = (loss_plus && loss_plus->type == VAL_NUM) ? loss_plus->data.num : 0.0;
            /* Perturb -eps */
            Value *pm = make_num_permanent(old_val - eps);
            param->data.list.items[i] = pm;
            Value *loss_minus = call_eigs_fn(loss_fn, make_null());
            double lm = (loss_minus && loss_minus->type == VAL_NUM) ? loss_minus->data.num : 0.0;
            /* Restore original Value pointer (preserves observer state) */
            param->data.list.items[i] = orig;
            free(pp);
            free(pm);
            /* Central difference */
            list_append(grad, make_num((lp - lm) / (2.0 * eps)));
        }
        return grad;
    }

    /* 2D param */
    int rows = param->data.list.count;
    Value *grad = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *row = param->data.list.items[r];
        if (!row || row->type != VAL_LIST) { list_append(grad, make_list(0)); continue; }
        int cols = row->data.list.count;
        Value *grad_row = make_list(cols);
        for (int c = 0; c < cols; c++) {
            Value *orig = row->data.list.items[c];
            double old_val = (orig->type == VAL_NUM) ? orig->data.num : 0.0;
            /* Perturb +eps */
            Value *pp = make_num_permanent(old_val + eps);
            row->data.list.items[c] = pp;
            Value *loss_plus = call_eigs_fn(loss_fn, make_null());
            double lp = (loss_plus && loss_plus->type == VAL_NUM) ? loss_plus->data.num : 0.0;
            /* Perturb -eps */
            Value *pm = make_num_permanent(old_val - eps);
            row->data.list.items[c] = pm;
            Value *loss_minus = call_eigs_fn(loss_fn, make_null());
            double lm = (loss_minus && loss_minus->type == VAL_NUM) ? loss_minus->data.num : 0.0;
            /* Restore original Value pointer (preserves observer state) */
            row->data.list.items[c] = orig;
            free(pp);
            free(pm);
            list_append(grad_row, make_num((lp - lm) / (2.0 * eps)));
        }
        list_append(grad, grad_row);
    }
    return grad;
}

/* ==== BUILTIN: sgd_update ==== */
/* sgd_update of [param, grad, lr] — in-place param = param - lr * grad */
Value* builtin_sgd_update(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *param = arg->data.list.items[0];
    Value *grad = arg->data.list.items[1];
    double lr = (arg->data.list.items[2]->type == VAL_NUM) ? arg->data.list.items[2]->data.num : 0.01;

    if (param->type != VAL_LIST || grad->type != VAL_LIST) return param;

    int is_2d = (param->data.list.count > 0 && param->data.list.items[0]->type == VAL_LIST);

    if (!is_2d) {
        /* 1D */
        int len = param->data.list.count < grad->data.list.count
                ? param->data.list.count : grad->data.list.count;
        for (int i = 0; i < len; i++) {
            Value *old = param->data.list.items[i];
            double pv = (old->type == VAL_NUM) ? old->data.num : 0.0;
            double gv = (grad->data.list.items[i]->type == VAL_NUM) ? grad->data.list.items[i]->data.num : 0.0;
            param->data.list.items[i] = make_num_permanent(pv - lr * gv);
            free_weight_val(old);
        }
    } else {
        /* 2D */
        int rows = param->data.list.count < grad->data.list.count
                 ? param->data.list.count : grad->data.list.count;
        for (int r = 0; r < rows; r++) {
            Value *pr = param->data.list.items[r];
            Value *gr = grad->data.list.items[r];
            if (!pr || pr->type != VAL_LIST || !gr || gr->type != VAL_LIST) continue;
            int cols = pr->data.list.count < gr->data.list.count
                     ? pr->data.list.count : gr->data.list.count;
            for (int c = 0; c < cols; c++) {
                Value *old = pr->data.list.items[c];
                double pv = (old->type == VAL_NUM) ? old->data.num : 0.0;
                double gv = (gr->data.list.items[c]->type == VAL_NUM) ? gr->data.list.items[c]->data.num : 0.0;
                pr->data.list.items[c] = make_num_permanent(pv - lr * gv);
                free_weight_val(old);
            }
        }
    }
    return param;
}

/* ==== BUILTIN: numerical_grad_rows ==== */
/* numerical_grad_rows of [loss_fn, matrix, row_indices, eps]
 * Computes numerical gradient only for the specified rows of a 2D matrix.
 * row_indices is a 1D list of integer row indices (pre-deduplicated by caller).
 * Returns a gradient matrix of the same shape, with zero rows for untouched rows. */
Value* builtin_numerical_grad_rows(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *loss_fn = arg->data.list.items[0];
    Value *matrix = arg->data.list.items[1];
    Value *row_indices = arg->data.list.items[2];
    double eps = (arg->data.list.items[3]->type == VAL_NUM) ? arg->data.list.items[3]->data.num : 0.001;
    if (eps <= 0) eps = 0.001;

    if (matrix->type != VAL_LIST || row_indices->type != VAL_LIST) return make_null();

    int rows = matrix->data.list.count;
    if (rows == 0 || matrix->data.list.items[0]->type != VAL_LIST) return make_null();
    int cols = matrix->data.list.items[0]->data.list.count;

    /* Build zero gradient matrix */
    Value *grad = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *grow = make_list(cols);
        for (int c = 0; c < cols; c++)
            list_append(grow, make_num(0.0));
        list_append(grad, grow);
    }

    /* Only compute gradients for specified rows */
    for (int ri = 0; ri < row_indices->data.list.count; ri++) {
        int r = (row_indices->data.list.items[ri]->type == VAL_NUM)
              ? (int)row_indices->data.list.items[ri]->data.num : -1;
        if (r < 0 || r >= rows) continue;

        Value *row = matrix->data.list.items[r];
        if (!row || row->type != VAL_LIST) continue;
        Value *grad_row = grad->data.list.items[r];

        for (int c = 0; c < cols && c < row->data.list.count; c++) {
            Value *orig = row->data.list.items[c];
            double old_val = (orig->type == VAL_NUM) ? orig->data.num : 0.0;
            /* +eps */
            Value *perturb_plus = make_num_permanent(old_val + eps);
            row->data.list.items[c] = perturb_plus;
            Value *lp = call_eigs_fn(loss_fn, make_null());
            double loss_plus = (lp && lp->type == VAL_NUM) ? lp->data.num : 0.0;
            /* -eps */
            Value *perturb_minus = make_num_permanent(old_val - eps);
            row->data.list.items[c] = perturb_minus;
            Value *lm = call_eigs_fn(loss_fn, make_null());
            double loss_minus = (lm && lm->type == VAL_NUM) ? lm->data.num : 0.0;
            /* restore original Value pointer (preserves observer state) */
            row->data.list.items[c] = orig;
            free(perturb_plus);
            free(perturb_minus);
            /* gradient */
            grad_row->data.list.items[c] = make_num((loss_plus - loss_minus) / (2.0 * eps));
        }
    }
    return grad;
}

/* ==== BUILTIN: sgd_update_rows ==== */
/* sgd_update_rows of [matrix, grad, row_indices, lr]
 * Updates only the specified rows of matrix in-place: row -= lr * grad_row */
Value* builtin_sgd_update_rows(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *matrix = arg->data.list.items[0];
    Value *grad = arg->data.list.items[1];
    Value *row_indices = arg->data.list.items[2];
    double lr = (arg->data.list.items[3]->type == VAL_NUM) ? arg->data.list.items[3]->data.num : 0.01;

    if (matrix->type != VAL_LIST || grad->type != VAL_LIST || row_indices->type != VAL_LIST)
        return matrix;

    for (int ri = 0; ri < row_indices->data.list.count; ri++) {
        int r = (row_indices->data.list.items[ri]->type == VAL_NUM)
              ? (int)row_indices->data.list.items[ri]->data.num : -1;
        if (r < 0 || r >= matrix->data.list.count || r >= grad->data.list.count) continue;

        Value *mrow = matrix->data.list.items[r];
        Value *grow = grad->data.list.items[r];
        if (!mrow || mrow->type != VAL_LIST || !grow || grow->type != VAL_LIST) continue;

        int cols = mrow->data.list.count < grow->data.list.count
                 ? mrow->data.list.count : grow->data.list.count;
        for (int c = 0; c < cols; c++) {
            Value *old = mrow->data.list.items[c];
            double pv = (old->type == VAL_NUM) ? old->data.num : 0.0;
            double gv = (grow->data.list.items[c]->type == VAL_NUM) ? grow->data.list.items[c]->data.num : 0.0;
            mrow->data.list.items[c] = make_num_permanent(pv - lr * gv);
            free_weight_val(old);
        }
    }
    return matrix;
}

/* ==== BUILTIN: numerical_grad_cols ==== */
/* numerical_grad_cols of [loss_fn, matrix, col_indices, eps]
 * Computes numerical gradient only for the specified columns of a 2D matrix.
 * col_indices is a 1D list of integer column indices.
 * Returns a gradient matrix of the same shape, with zero columns for untouched cols. */
Value* builtin_numerical_grad_cols(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *loss_fn = arg->data.list.items[0];
    Value *matrix = arg->data.list.items[1];
    Value *col_indices = arg->data.list.items[2];
    double eps = (arg->data.list.items[3]->type == VAL_NUM) ? arg->data.list.items[3]->data.num : 0.001;
    if (eps <= 0) eps = 0.001;

    if (matrix->type != VAL_LIST || col_indices->type != VAL_LIST) return make_null();

    int rows = matrix->data.list.count;
    if (rows == 0 || matrix->data.list.items[0]->type != VAL_LIST) return make_null();
    int cols = matrix->data.list.items[0]->data.list.count;

    /* Build zero gradient matrix */
    Value *grad = make_list(rows);
    for (int r = 0; r < rows; r++) {
        Value *grow = make_list(cols);
        for (int c = 0; c < cols; c++)
            list_append(grow, make_num(0.0));
        list_append(grad, grow);
    }

    /* Only compute gradients for specified columns, across all rows */
    for (int ci = 0; ci < col_indices->data.list.count; ci++) {
        int col = (col_indices->data.list.items[ci]->type == VAL_NUM)
                ? (int)col_indices->data.list.items[ci]->data.num : -1;
        if (col < 0 || col >= cols) continue;

        for (int r = 0; r < rows; r++) {
            Value *row = matrix->data.list.items[r];
            if (!row || row->type != VAL_LIST || col >= row->data.list.count) continue;

            Value *orig = row->data.list.items[col];
            double old_val = (orig->type == VAL_NUM) ? orig->data.num : 0.0;
            /* +eps */
            Value *perturb_plus = make_num_permanent(old_val + eps);
            row->data.list.items[col] = perturb_plus;
            Value *lp = call_eigs_fn(loss_fn, make_null());
            double loss_plus = (lp && lp->type == VAL_NUM) ? lp->data.num : 0.0;
            /* -eps */
            Value *perturb_minus = make_num_permanent(old_val - eps);
            row->data.list.items[col] = perturb_minus;
            Value *lm = call_eigs_fn(loss_fn, make_null());
            double loss_minus = (lm && lm->type == VAL_NUM) ? lm->data.num : 0.0;
            /* restore original Value pointer (preserves observer state) */
            row->data.list.items[col] = orig;
            free(perturb_plus);
            free(perturb_minus);
            /* gradient */
            grad->data.list.items[r]->data.list.items[col] = make_num((loss_plus - loss_minus) / (2.0 * eps));
        }
    }
    return grad;
}

/* ==== BUILTIN: sgd_update_cols ==== */
/* sgd_update_cols of [matrix, grad, col_indices, lr]
 * Updates only the specified columns of matrix in-place: elem -= lr * grad_elem */
Value* builtin_sgd_update_cols(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    Value *matrix = arg->data.list.items[0];
    Value *grad = arg->data.list.items[1];
    Value *col_indices = arg->data.list.items[2];
    double lr = (arg->data.list.items[3]->type == VAL_NUM) ? arg->data.list.items[3]->data.num : 0.01;

    if (matrix->type != VAL_LIST || grad->type != VAL_LIST || col_indices->type != VAL_LIST)
        return matrix;

    int rows = matrix->data.list.count < grad->data.list.count
             ? matrix->data.list.count : grad->data.list.count;

    for (int ci = 0; ci < col_indices->data.list.count; ci++) {
        int col = (col_indices->data.list.items[ci]->type == VAL_NUM)
                ? (int)col_indices->data.list.items[ci]->data.num : -1;
        if (col < 0) continue;

        for (int r = 0; r < rows; r++) {
            Value *mrow = matrix->data.list.items[r];
            Value *grow = grad->data.list.items[r];
            if (!mrow || mrow->type != VAL_LIST || col >= mrow->data.list.count) continue;
            if (!grow || grow->type != VAL_LIST || col >= grow->data.list.count) continue;

            Value *old = mrow->data.list.items[col];
            double pv = (old->type == VAL_NUM) ? old->data.num : 0.0;
            double gv = (grow->data.list.items[col]->type == VAL_NUM) ? grow->data.list.items[col]->data.num : 0.0;
            mrow->data.list.items[col] = make_num_permanent(pv - lr * gv);
            free_weight_val(old);
        }
    }
    return matrix;
}

/* ==== BUILTIN: arena_mark ==== */
/* arena_mark of null — saves current arena position. All Values allocated
 * after this point will be reclaimed on arena_reset. Call before a training step. */
Value* builtin_arena_mark(Value *arg) {
    (void)arg;
    arena_mark_pos();
    return make_null();
}

/* ==== BUILTIN: arena_reset ==== */
/* arena_reset of null — reclaims all Values allocated since the last arena_mark.
 * Call after a training step, when gradient tensors and intermediates are no longer needed. */
Value* builtin_arena_reset(Value *arg) {
    (void)arg;
    arena_reset_to_mark();
    return make_null();
}

/* ==== BUILTIN: arena_stats ==== */
/* arena_stats of null — returns total bytes allocated through the arena. */
Value* builtin_arena_stats(Value *arg) {
    (void)arg;
    return make_num((double)g_arena.total_allocated);
}

/* ==== BUILTIN: tokenize_ids ==== */
/* tokenize_ids of string → list of token type IDs (integers).
 * Exposes the runtime's own tokenizer to .eigs code.
 * The learner sees its world the way the runtime does. */
Value* builtin_tokenize_ids(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_list(0);
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_list(0);

    TokenList tl = tokenize(src);
    Value *result = make_list(tl.count);
    for (int i = 0; i < tl.count; i++) {
        list_append(result, make_num((double)tl.tokens[i].type));
    }
    return result;
}

/* ==== BUILTIN: token_name ==== */
/* token_name of id → string name of token type (for display) */
Value* builtin_token_name(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_str("?");
    int id = (int)arg->data.num;
    static const char *names[] = {
        "NUM", "STR", "IDENT",
        "IS", "OF", "DEFINE", "AS",
        "IF", "ELSE", "ELIF", "LOOP", "WHILE",
        "RETURN", "AND", "OR", "NOT",
        "FOR", "IN", "NULL",
        "WHAT", "WHO", "WHEN", "WHERE", "WHY", "HOW",
        "CONVERGED", "STABLE", "IMPROVING", "OSCILLATING", "DIVERGING", "EQUILIBRIUM",
        "+", "-", "*", "/", "%",
        "<", ">", "<=", ">=", "==", "!=", "=",
        "(", ")", "[", "]",
        ",", ":", ".",
        "NEWLINE", "INDENT", "DEDENT",
        "EOF"
    };
    if (id >= 0 && id < 54) return make_str(names[id]);
    return make_str("?");
}

/* ==== BUILTIN: random_hex ==== */
/* random_hex of n → string of n random hex characters from /dev/urandom.
 * Capability builtin: provides randomness so .eigs libraries can generate tokens. */
Value* builtin_random_hex(Value *arg) {
    int n = (arg && arg->type == VAL_NUM) ? (int)arg->data.num : 0;
    if (n <= 0 || n > 256) return make_str("");
    int bytes_needed = (n + 1) / 2;
    unsigned char raw[128];
    FILE *urand = fopen("/dev/urandom", "rb");
    if (!urand) return make_str("");
    size_t got = fread(raw, 1, bytes_needed, urand);
    fclose(urand);
    if ((int)got < bytes_needed) return make_str("");
    char hex[257];
    for (int i = 0; i < bytes_needed && i * 2 < n; i++)
        sprintf(hex + i * 2, "%02x", raw[i]);
    hex[n] = '\0';
    return make_str(hex);
}

/* ==== BUILTIN: http_request_headers ==== */
/* http_request_headers of null → raw request headers as string.
 * Only meaningful during HTTP request handling. */
/* http_request_headers moved to ext_http.c */

/* ==== BUILTIN: chr ==== */
/* chr of n → single-character string from ASCII code */
Value* builtin_chr(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_str("");
    int code = (int)arg->data.num;
    if (code < 0 || code > 127) return make_str("");
    char buf[2] = { (char)code, '\0' };
    return make_str(buf);
}

/* ==== BUILTIN: try_parse ==== */
/* try_parse of string → 1 if valid EigenScript syntax, 0 if not.
 * Tokenizes and parses without executing. Suppresses stderr. */
Value* builtin_try_parse(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_num(0);

    /* Suppress stderr during parse attempt */
    int saved_stderr = dup(STDERR_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }

    /* Reset parse error counter before parsing */
    int saved_errors = g_parse_errors;
    g_parse_errors = 0;

    TokenList tl = tokenize(src);
    ASTNode *ast = parse(&tl);

    int errors = g_parse_errors;
    g_parse_errors = saved_errors; /* restore for caller */

    /* Restore stderr */
    if (saved_stderr >= 0) { dup2(saved_stderr, STDERR_FILENO); close(saved_stderr); }

    /* Valid only if: non-null AST, at least one statement, AND no parse errors */
    int valid = (ast != NULL && ast->type == AST_PROGRAM
                 && ast->data.program.count > 0 && errors == 0) ? 1 : 0;
    return make_num(valid);
}

/* ==== BUILTIN: tensor_save ==== */
/* tensor_save of [tensor, path] — save 1D or 2D list to binary file.
 * Format: [uint32 ndim][uint32 rows][uint32 cols][uint32 flags]
 *         [float64 × N: data]
 *         [float64 × N × 5: observer state (entropy, dH, last_entropy, obs_age, prev_dH)]
 * flags bit 0 = has observer state */
Value* builtin_tensor_save(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *tensor = arg->data.list.items[0];
    Value *path_val = arg->data.list.items[1];
    if (!tensor || tensor->type != VAL_LIST || !path_val || path_val->type != VAL_STR)
        return make_num(0);

    int rows, cols;
    int ndim = tensor_dims(tensor, &rows, &cols);
    if (ndim == 0) return make_num(0);

    FILE *f = fopen(path_val->data.str, "wb");
    if (!f) return make_num(0);

    uint32_t header[4] = { (uint32_t)ndim, (uint32_t)rows, (uint32_t)cols, 1 /* flags: has observer */ };
    fwrite(header, sizeof(uint32_t), 4, f);

    int total = rows * cols;

    /* Write numeric data */
    double *flat = tensor_to_flat(tensor, &rows, &cols);
    if (flat) {
        fwrite(flat, sizeof(double), total, f);
        free(flat);
    }

    /* Write observer state for each element.
     * Save last_entropy offset so that the first observation after load
     * reproduces the correct dH. update_observer computes:
     *   dH = new_entropy - last_entropy
     * After load, the first observation recomputes entropy (same value).
     * To get the saved dH back: set last_entropy = entropy - dH. */
    if (ndim == 1) {
        for (int i = 0; i < cols; i++) {
            Value *v = tensor->data.list.items[i];
            double obs[5] = { v->entropy, v->dH, v->entropy - v->dH, (double)v->obs_age, v->prev_dH };
            fwrite(obs, sizeof(double), 5, f);
        }
    } else {
        for (int r = 0; r < rows; r++) {
            Value *row = tensor->data.list.items[r];
            int rc = (row && row->type == VAL_LIST) ? row->data.list.count : 0;
            for (int c = 0; c < cols; c++) {
                if (c < rc) {
                    Value *v = row->data.list.items[c];
                    double obs[5] = { v->entropy, v->dH, v->entropy - v->dH, (double)v->obs_age, v->prev_dH };
                    fwrite(obs, sizeof(double), 5, f);
                } else {
                    double obs[5] = {0, 0, 0, 0, 0};
                    fwrite(obs, sizeof(double), 5, f);
                }
            }
        }
    }

    fclose(f);
    return make_num(1);
}

/* Helper: restore observer state on a flat list of Values */
static void restore_observer_1d(Value *list, double *obs_data, int count) {
    for (int i = 0; i < count && i < list->data.list.count; i++) {
        Value *v = list->data.list.items[i];
        v->entropy = obs_data[i * 5 + 0];
        v->dH = obs_data[i * 5 + 1];
        v->last_entropy = obs_data[i * 5 + 2];
        v->obs_age = (int)obs_data[i * 5 + 3];
        v->prev_dH = obs_data[i * 5 + 4];
    }
}

static void restore_observer_2d(Value *tensor, double *obs_data, int rows, int cols) {
    for (int r = 0; r < rows && r < tensor->data.list.count; r++) {
        Value *row = tensor->data.list.items[r];
        if (!row || row->type != VAL_LIST) continue;
        for (int c = 0; c < cols && c < row->data.list.count; c++) {
            int idx = r * cols + c;
            Value *v = row->data.list.items[c];
            v->entropy = obs_data[idx * 5 + 0];
            v->dH = obs_data[idx * 5 + 1];
            v->last_entropy = obs_data[idx * 5 + 2];
            v->obs_age = (int)obs_data[idx * 5 + 3];
            v->prev_dH = obs_data[idx * 5 + 4];
        }
    }
}

/* ==== BUILTIN: tensor_load ==== */
/* tensor_load of path — load 1D or 2D tensor from binary file.
 * Restores observer state if present in the file. */
Value* builtin_tensor_load(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();

    FILE *f = fopen(arg->data.str, "rb");
    if (!f) return make_null();

    /* Try new format (4-word header with flags) */
    uint32_t header[4];
    if (fread(header, sizeof(uint32_t), 4, f) != 4) { fclose(f); return make_null(); }

    int ndim = (int)header[0];
    int rows = (int)header[1];
    int cols = (int)header[2];
    uint32_t flags = header[3];

    /* Detect old format: flags would be a huge number if it's actually data */
    int has_observer = 0;
    if (flags <= 1) {
        has_observer = (flags & 1);
    } else {
        /* Old 3-word header — rewind and re-read */
        fseek(f, 0, SEEK_SET);
        uint32_t old_header[3];
        if (fread(old_header, sizeof(uint32_t), 3, f) != 3) { fclose(f); return make_null(); }
        ndim = (int)old_header[0];
        rows = (int)old_header[1];
        cols = (int)old_header[2];
        has_observer = 0;
    }

    if (rows <= 0 || cols <= 0 || rows > 100000 || cols > 100000) { fclose(f); return make_null(); }

    int total = rows * cols;

    /* Read numeric data */
    double *data = malloc(total * sizeof(double));
    if (!data) { fclose(f); return make_null(); }
    if ((int)fread(data, sizeof(double), total, f) != total) { free(data); fclose(f); return make_null(); }

    /* Read observer state if present */
    double *obs_data = NULL;
    if (has_observer) {
        obs_data = malloc(total * 5 * sizeof(double));
        if (obs_data) {
            if ((int)fread(obs_data, sizeof(double), total * 5, f) != total * 5) {
                free(obs_data);
                obs_data = NULL;
            }
        }
    }

    fclose(f);

    /* Build tensor */
    Value *result;
    if (ndim == 1)
        result = flat_to_tensor_1d(data, cols);
    else
        result = flat_to_tensor_2d(data, rows, cols);
    free(data);

    /* Restore observer state */
    if (obs_data && result) {
        if (ndim == 1)
            restore_observer_1d(result, obs_data, total);
        else
            restore_observer_2d(result, obs_data, rows, cols);
        free(obs_data);
    }

    return result;
}

/* ==== BUILTIN: copy_into ==== */
/* copy_into of [dest, dest_offset, src]
 * Copies elements from src into dest starting at dest_offset.
 * Both must be 1D lists. Mutates dest in-place, returns dest. */
Value* builtin_copy_into(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *dest = arg->data.list.items[0];
    int offset = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
    Value *src = arg->data.list.items[2];
    if (!dest || dest->type != VAL_LIST || !src || src->type != VAL_LIST) return make_null();
    for (int i = 0; i < src->data.list.count && offset + i < dest->data.list.count; i++)
        dest->data.list.items[offset + i] = src->data.list.items[i];
    return dest;
}

/* ==== BUILTIN: num_copy ==== */
/* num_copy of val → fresh heap-allocated copy of a numeric Value.
 * Use to extract a scalar from arena before arena_reset. */
Value* builtin_num_copy(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_null();
    return make_num_permanent(arg->data.num);
}

/* ==== BUILTIN: concat ==== */
/* concat of [list_a, list_b] → new 1D list with a's elements then b's */
Value* builtin_concat(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_LIST || !b || b->type != VAL_LIST) return make_null();
    int total = a->data.list.count + b->data.list.count;
    Value *result = make_list(total);
    for (int i = 0; i < a->data.list.count; i++)
        list_append(result, a->data.list.items[i]);
    for (int i = 0; i < b->data.list.count; i++)
        list_append(result, b->data.list.items[i]);
    return result;
}

/* ==== BUILTIN: range ==== */
/* range of n → [0, 1, ..., n-1]
 * range of [start, end] → [start, start+1, ..., end-1]
 * range of [start, end, step] → [start, start+step, ...] while < end (or > end if step < 0) */
Value* builtin_range(Value *arg) {
    int start = 0, end = 0, step = 1;

    if (!arg) return make_list(0);

    if (arg->type == VAL_NUM) {
        /* range of n */
        end = (int)arg->data.num;
    } else if (arg->type == VAL_LIST) {
        int argc = arg->data.list.count;
        if (argc >= 1 && arg->data.list.items[0]->type == VAL_NUM)
            start = (int)arg->data.list.items[0]->data.num;
        if (argc >= 2 && arg->data.list.items[1]->type == VAL_NUM)
            end = (int)arg->data.list.items[1]->data.num;
        else
            { end = start; start = 0; } /* single-element list: treat as range of n */
        if (argc >= 3 && arg->data.list.items[2]->type == VAL_NUM) {
            step = (int)arg->data.list.items[2]->data.num;
            if (step == 0) step = 1;
        }
    } else {
        return make_list(0);
    }

    /* Cap at 1M elements to prevent accidental OOM */
    int count = (step > 0) ? ((end - start + step - 1) / step)
                           : ((start - end - step - 1) / (-step));
    if (count < 0) count = 0;
    if (count > 1000000) count = 1000000;

    Value *result = make_list(count);
    if (step > 0) {
        for (int i = start; i < end; i += step)
            list_append(result, make_num((double)i));
    } else {
        for (int i = start; i > end; i += step)
            list_append(result, make_num((double)i));
    }
    return result;
}

/* ==== BUILTIN: set_at — mutate a list element in place ==== */
/* set_at of [list, index, value] — sets list[index] = value, returns list */
/* set_at of [list, row, col, value] — sets list[row][col] = value for 2D */
Value* builtin_set_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST) return make_null();
    int argc = arg->data.list.count;
    if (argc == 3) {
        /* 1D: set_at of [list, index, value] */
        Value *list = arg->data.list.items[0];
        int idx = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
        Value *val = arg->data.list.items[2];
        if (list->type == VAL_LIST && idx >= 0 && idx < list->data.list.count)
            list->data.list.items[idx] = val;
        return list;
    }
    if (argc == 4) {
        /* 2D: set_at of [list, row, col, value] */
        Value *list = arg->data.list.items[0];
        int row = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
        int col = (arg->data.list.items[2]->type == VAL_NUM) ? (int)arg->data.list.items[2]->data.num : 0;
        Value *val = arg->data.list.items[3];
        if (list->type == VAL_LIST && row >= 0 && row < list->data.list.count) {
            Value *rowv = list->data.list.items[row];
            if (rowv->type == VAL_LIST && col >= 0 && col < rowv->data.list.count)
                rowv->data.list.items[col] = val;
        }
        return list;
    }
    return make_null();
}

/* ==== BUILTIN: get_at — read a list element ==== */
/* get_at of [list, index] or get_at of [list, row, col] */
Value* builtin_get_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST) return make_null();
    int argc = arg->data.list.count;
    if (argc == 2) {
        Value *list = arg->data.list.items[0];
        int idx = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
        if (list->type == VAL_LIST && idx >= 0 && idx < list->data.list.count)
            return list->data.list.items[idx];
        return make_num(0.0);
    }
    if (argc == 3) {
        Value *list = arg->data.list.items[0];
        int row = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
        int col = (arg->data.list.items[2]->type == VAL_NUM) ? (int)arg->data.list.items[2]->data.num : 0;
        if (list->type == VAL_LIST && row >= 0 && row < list->data.list.count) {
            Value *rowv = list->data.list.items[row];
            if (rowv->type == VAL_LIST && col >= 0 && col < rowv->data.list.count)
                return rowv->data.list.items[col];
        }
        return make_num(0.0);
    }
    return make_null();
}

void register_builtins(Env *env) {
    /* ---- Core language builtins (always available) ---- */
    env_set_local(env, "print", make_builtin(builtin_print));
    env_set_local(env, "len", make_builtin(builtin_len));
    env_set_local(env, "str", make_builtin(builtin_str));
    env_set_local(env, "num", make_builtin(builtin_num));
    env_set_local(env, "append", make_builtin(builtin_append));
    env_set_local(env, "computation_cost", make_builtin(builtin_computation_cost));
    env_set_local(env, "report", make_builtin(builtin_report));
    env_set_local(env, "assert", make_builtin(builtin_assert));
    env_set_local(env, "observe", make_builtin(builtin_observe));
    env_set_local(env, "type", make_builtin(builtin_type));
    env_set_local(env, "json_encode", make_builtin(builtin_json_encode));
    env_set_local(env, "json_decode", make_builtin(builtin_json_decode));
    env_set_local(env, "coalesce", make_builtin(builtin_coalesce));
    env_set_local(env, "json_build", make_builtin(builtin_json_build));
    env_set_local(env, "json_raw", make_builtin(builtin_json_raw));
    env_set_local(env, "json_path", make_builtin(builtin_json_path));
    env_set_local(env, "str_lower", make_builtin(builtin_str_lower));
    env_set_local(env, "contains", make_builtin(builtin_contains));
    env_set_local(env, "starts_with", make_builtin(builtin_starts_with));
    env_set_local(env, "split", make_builtin(builtin_split));
    env_set_local(env, "trim", make_builtin(builtin_trim));
    env_set_local(env, "str_replace", make_builtin(builtin_str_replace));
    env_set_local(env, "load_file", make_builtin(builtin_load_file));
    env_set_local(env, "file_exists", make_builtin(builtin_file_exists));
    env_set_local(env, "env_get", make_builtin(builtin_env_get));

    /* ---- Tensor / math stdlib (always available) ---- */
    env_set_local(env, "matmul", make_builtin(builtin_tensor_matmul));
    env_set_local(env, "add", make_builtin(builtin_tensor_add));
    env_set_local(env, "subtract", make_builtin(builtin_tensor_subtract));
    env_set_local(env, "multiply", make_builtin(builtin_tensor_multiply));
    env_set_local(env, "divide", make_builtin(builtin_tensor_divide));
    env_set_local(env, "pow", make_builtin(builtin_tensor_pow));
    env_set_local(env, "sqrt", make_builtin(builtin_tensor_sqrt));
    env_set_local(env, "exp", make_builtin(builtin_tensor_exp));
    env_set_local(env, "log", make_builtin(builtin_tensor_log));
    env_set_local(env, "negative", make_builtin(builtin_tensor_negative));
    env_set_local(env, "softmax", make_builtin(builtin_tensor_softmax));
    env_set_local(env, "log_softmax", make_builtin(builtin_tensor_log_softmax));
    env_set_local(env, "relu", make_builtin(builtin_tensor_relu));
    env_set_local(env, "leaky_relu", make_builtin(builtin_tensor_leaky_relu));
    env_set_local(env, "mean", make_builtin(builtin_tensor_mean));
    env_set_local(env, "sum", make_builtin(builtin_tensor_sum));
    env_set_local(env, "zeros", make_builtin(builtin_tensor_zeros));
    env_set_local(env, "zeros_like", make_builtin(builtin_tensor_zeros_like));
    env_set_local(env, "gather", make_builtin(builtin_tensor_gather));
    env_set_local(env, "set_at", make_builtin(builtin_set_at));
    env_set_local(env, "get_at", make_builtin(builtin_get_at));
    env_set_local(env, "random_normal", make_builtin(builtin_random_normal));
    env_set_local(env, "shape", make_builtin(builtin_tensor_shape));
    env_set_local(env, "numerical_grad", make_builtin(builtin_numerical_grad));
    env_set_local(env, "numerical_grad_rows", make_builtin(builtin_numerical_grad_rows));
    env_set_local(env, "sgd_update", make_builtin(builtin_sgd_update));
    env_set_local(env, "sgd_update_rows", make_builtin(builtin_sgd_update_rows));
    env_set_local(env, "numerical_grad_cols", make_builtin(builtin_numerical_grad_cols));
    env_set_local(env, "sgd_update_cols", make_builtin(builtin_sgd_update_cols));
    env_set_local(env, "tokenize_ids", make_builtin(builtin_tokenize_ids));
    env_set_local(env, "token_name", make_builtin(builtin_token_name));
    env_set_local(env, "chr", make_builtin(builtin_chr));
    env_set_local(env, "random_hex", make_builtin(builtin_random_hex));
    env_set_local(env, "try_parse", make_builtin(builtin_try_parse));
    env_set_local(env, "tensor_save", make_builtin(builtin_tensor_save));
    env_set_local(env, "tensor_load", make_builtin(builtin_tensor_load));
    env_set_local(env, "copy_into", make_builtin(builtin_copy_into));
    env_set_local(env, "num_copy", make_builtin(builtin_num_copy));
    env_set_local(env, "concat", make_builtin(builtin_concat));
    env_set_local(env, "range", make_builtin(builtin_range));
    env_set_local(env, "arena_mark", make_builtin(builtin_arena_mark));
    env_set_local(env, "arena_reset", make_builtin(builtin_arena_reset));
    env_set_local(env, "arena_stats", make_builtin(builtin_arena_stats));

#if EIGENSCRIPT_EXT_HTTP
    register_http_builtins(env);
#endif

#if EIGENSCRIPT_EXT_MODEL
    /* ---- Model/inference extension ---- */
    env_set_local(env, "eigen_model_loaded", make_builtin(builtin_eigen_model_loaded));
    env_set_local(env, "eigen_generate", make_builtin(builtin_eigen_generate));
    env_set_local(env, "eigen_sanitize", make_builtin(builtin_eigen_sanitize));
    env_set_local(env, "eigen_clean_response", make_builtin(builtin_eigen_clean_response));
    env_set_local(env, "eigen_is_garble", make_builtin(builtin_eigen_is_garble));
    env_set_local(env, "eigen_conversation_count", make_builtin(builtin_eigen_conversation_count));
    env_set_local(env, "eigen_model_info", make_builtin(builtin_eigen_model_info));
    env_set_local(env, "native_train_step_builtin", make_builtin(builtin_native_train_step));
    env_set_local(env, "model_save_weights", make_builtin(builtin_model_save_weights));
    env_set_local(env, "model_load_weights", make_builtin(builtin_model_load_weights));
    env_set_local(env, "eigen_model_load", make_builtin(builtin_eigen_model_load));
    env_set_local(env, "eigen_check_openai", make_builtin(builtin_eigen_check_openai));
#if EIGENSCRIPT_EXT_DB
    env_set_local(env, "eigen_batch_train", make_builtin(builtin_eigen_batch_train));
    env_set_local(env, "eigen_export_corpus", make_builtin(builtin_eigen_export_corpus));
#endif
#endif

#if EIGENSCRIPT_EXT_DB
    /* ---- Database extension (requires libpq) ---- */
    env_set_local(env, "db_connect", make_builtin(builtin_db_connect));
    env_set_local(env, "db_query_value", make_builtin(builtin_db_query_value));
    env_set_local(env, "db_execute", make_builtin(builtin_db_execute));
    env_set_local(env, "db_query_json", make_builtin(builtin_db_query_json));
    env_set_local(env, "generate_api_key", make_builtin(builtin_generate_api_key));
    env_set_local(env, "validate_api_key", make_builtin(builtin_validate_api_key));
#endif

    /* Auth builtins removed — now in lib/auth.eigs */
}

/* HTTP server moved to ext_http.c */


/* ================================================================
 * MAIN
 * ================================================================ */

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "0.5.0"
#endif

int main(int argc, char **argv) {
    if (argc >= 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0)) {
        printf("%s\n", EIGENSCRIPT_VERSION);
        return 0;
    }
    if (argc < 2) {
        fprintf(stderr, "Usage: eigenscript <file.eigs>\n");
        fprintf(stderr, "       eigenscript --version\n");
        return 1;
    }

    long src_size = 0;
    char *source = read_file_util(argv[1], &src_size);
    if (!source) {
        fprintf(stderr, "Error: cannot read file '%s'\n", argv[1]);
        return 1;
    }

    srand(time(NULL));
    arena_init();

    Env *global = env_new(NULL);
    register_builtins(global);
    g_global_env = global;

#if EIGENSCRIPT_EXT_HTTP
    g_server.global_env = global;
    g_server.route_count = 0;
    g_server.static_prefix = NULL;
    g_server.static_dir = NULL;
    g_server.request_body = NULL;
    g_server.session_id = NULL;
    g_server.request_headers = NULL;
#endif

    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    eval_node(ast, global);

    free(source);
    return 0;
}
