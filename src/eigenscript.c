/*
 * EigenScript Native Bootstrap Runtime
 * Core: tokenizer + parser + evaluator + builtins
 * Compiles with: gcc -O2 -o eigenscript eigenscript.c -lm -lpthread
 */

#include "eigenscript.h"
#include <pthread.h>
#if EIGENSCRIPT_EXT_HTTP
#include "ext_http_internal.h"
#endif
#if EIGENSCRIPT_EXT_DB
#include "ext_db_internal.h"
#endif
#if EIGENSCRIPT_EXT_MODEL
#include "model_internal.h"
#endif

/* HTTP server globals and health thread are in ext_http.c */
jmp_buf g_return_buf;
Value *g_return_val = NULL;
int g_returning = 0;
int g_parse_errors = 0;

static const char* tok_type_name(TokType t) {
    switch (t) {
        case TOK_NUM: return "number";
        case TOK_STR: return "string";
        case TOK_IDENT: return "identifier";
        case TOK_IS: return "'is'";
        case TOK_OF: return "'of'";
        case TOK_DEFINE: return "'define'";
        case TOK_AS: return "'as'";
        case TOK_IF: return "'if'";
        case TOK_ELSE: return "'else'";
        case TOK_ELIF: return "'elif'";
        case TOK_LOOP: return "'loop'";
        case TOK_WHILE: return "'while'";
        case TOK_RETURN: return "'return'";
        case TOK_AND: return "'and'";
        case TOK_OR: return "'or'";
        case TOK_NOT: return "'not'";
        case TOK_FOR: return "'for'";
        case TOK_IN: return "'in'";
        case TOK_NULL: return "'null'";
        case TOK_PLUS: return "'+'";
        case TOK_MINUS: return "'-'";
        case TOK_STAR: return "'*'";
        case TOK_SLASH: return "'/'";
        case TOK_PERCENT: return "'%'";
        case TOK_LT: return "'<'";
        case TOK_GT: return "'>'";
        case TOK_LE: return "'<='";
        case TOK_GE: return "'>='";
        case TOK_EQ: return "'=='";
        case TOK_NE: return "'!='";
        case TOK_ASSIGN: return "'='";
        case TOK_LPAREN: return "'('";
        case TOK_RPAREN: return "')'";
        case TOK_LBRACKET: return "'['";
        case TOK_RBRACKET: return "']'";
        case TOK_COMMA: return "','";
        case TOK_COLON: return "':'";
        case TOK_DOT: return "'.'";
        case TOK_NEWLINE: return "newline";
        case TOK_INDENT: return "indent";
        case TOK_DEDENT: return "dedent";
        case TOK_EOF: return "end of file";
        default: return "?";
    }
}

static const char* val_type_name(ValType t) {
    switch (t) {
        case VAL_NUM: return "num";
        case VAL_STR: return "str";
        case VAL_LIST: return "list";
        case VAL_FN: return "fn";
        case VAL_BUILTIN: return "builtin";
        case VAL_NULL: return "null";
        case VAL_JSON_RAW: return "json_raw";
        default: return "?";
    }
}
/* g_global_env defined in main.c */

/* Arena allocator and free_weight_val are in arena.c */

/* ================================================================
 * VALUE CONSTRUCTORS
 * ================================================================ */

/* Recursively free a heap-allocated Value tree.
 * Only safe when arena is NOT active (values are individually calloc'd).
 * Skips arena-allocated values. */
static int is_arena_ptr(void *ptr) {
    for (int i = 0; i < g_arena.block_count; i++) {
        char *start = g_arena.blocks[i];
        if ((char*)ptr >= start && (char*)ptr < start + ARENA_BLOCK_SIZE) return 1;
    }
    return 0;
}

void free_value(Value *v) {
    if (!v || is_arena_ptr(v)) return;
    if (v->type == VAL_STR) {
        if (v->data.str && !is_arena_ptr(v->data.str)) free(v->data.str);
    } else if (v->type == VAL_LIST) {
        for (int i = 0; i < v->data.list.count; i++) {
            free_value(v->data.list.items[i]);
        }
        if (v->data.list.items && !is_arena_ptr(v->data.list.items))
            free(v->data.list.items);
    } else if (v->type == VAL_JSON_RAW) {
        if (v->data.str && !is_arena_ptr(v->data.str)) free(v->data.str);
    }
    free(v);
}

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

Value* make_fn(const char *name, char **params, int param_count, ASTNode **body, int body_count, Env *closure) {
    Value *v = calloc(1, sizeof(Value));
    v->type = VAL_FN;
    v->data.fn.name = strdup(name ? name : "");
    v->data.fn.params = malloc(param_count * sizeof(char*));
    v->data.fn.param_count = param_count;
    for (int i = 0; i < param_count; i++)
        v->data.fn.params[i] = strdup(params[i]);
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
            for (int i = 0; i < v->data.fn.param_count; i++)
                free(v->data.fn.params[i]);
            free(v->data.fn.params);
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
            int remaining;
            remaining = MAX_STR - pos; if (remaining < 1) remaining = 1;
            pos += snprintf(result + pos, remaining, "[");
            if (pos >= MAX_STR) pos = MAX_STR - 1;
            for (int i = 0; i < v->data.list.count; i++) {
                if (i > 0) {
                    remaining = MAX_STR - pos; if (remaining < 1) remaining = 1;
                    pos += snprintf(result + pos, remaining, ", ");
                    if (pos >= MAX_STR) pos = MAX_STR - 1;
                }
                char *s = value_to_string(v->data.list.items[i]);
                remaining = MAX_STR - pos; if (remaining < 1) remaining = 1;
                if (v->data.list.items[i] && v->data.list.items[i]->type == VAL_STR)
                    pos += snprintf(result + pos, remaining, "\"%s\"", s);
                else
                    pos += snprintf(result + pos, remaining, "%s", s);
                if (pos >= MAX_STR) pos = MAX_STR - 1;
                free(s);
            }
            remaining = MAX_STR - pos; if (remaining < 1) remaining = 1;
            pos += snprintf(result + pos, remaining, "]");
            if (pos >= MAX_STR) pos = MAX_STR - 1;
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

        /* f-string: f"hello {expr}" expands to ("hello " + (str of (expr))) */
        if (*p == 'f' && *(p+1) == '"') {
            p += 2; /* skip f" */
            char buf[MAX_STR];
            int bi = 0;
            int has_segments = 0;

            while (*p && *p != '"') {
                if (*p == '\\' && (*(p+1) == '{' || *(p+1) == '}')) {
                    buf[bi++] = *(p+1);
                    p += 2;
                    continue;
                }
                if (*p == '\\') {
                    p++;
                    switch (*p) {
                        case 'n': buf[bi++] = '\n'; break;
                        case 't': buf[bi++] = '\t'; break;
                        case '\\': buf[bi++] = '\\'; break;
                        case '"': buf[bi++] = '"'; break;
                        default: buf[bi++] = *p; break;
                    }
                    p++;
                    continue;
                }
                if (*p == '{') {
                    /* Emit accumulated literal and + operator */
                    buf[bi] = '\0';
                    if (bi > 0 || !has_segments) {
                        if (has_segments) tok_add(&tl, TOK_PLUS, 0, NULL, line);
                        tok_add(&tl, TOK_STR, 0, buf, line);
                        has_segments = 1;
                    }
                    bi = 0;
                    p++; /* skip { */

                    /* Emit: + (str of (expr)) */
                    if (has_segments) tok_add(&tl, TOK_PLUS, 0, NULL, line);
                    else has_segments = 1;
                    tok_add(&tl, TOK_LPAREN, 0, NULL, line);
                    tok_add(&tl, TOK_IDENT, 0, "str", line);
                    tok_add(&tl, TOK_OF, 0, NULL, line);
                    tok_add(&tl, TOK_LPAREN, 0, NULL, line);

                    /* Tokenize the expression inside braces */
                    int depth = 1;
                    char expr_buf[MAX_STR];
                    int ei = 0;
                    while (*p && depth > 0 && ei < MAX_STR - 1) {
                        if (*p == '{') depth++;
                        else if (*p == '}') { depth--; if (depth == 0) break; }
                        expr_buf[ei++] = *p++;
                    }
                    expr_buf[ei] = '\0';
                    if (*p == '}') p++;
                    else {
                        fprintf(stderr, "Syntax error line %d: unterminated f-string expression\n", line);
                        g_parse_errors++;
                    }

                    /* Tokenize the inner expression and splice tokens in */
                    TokenList inner = tokenize(expr_buf);
                    for (int ti = 0; ti < inner.count; ti++) {
                        if (inner.tokens[ti].type == TOK_EOF) break;
                        if (inner.tokens[ti].type == TOK_NEWLINE) continue;
                        Token *it = &inner.tokens[ti];
                        tok_add(&tl, it->type, it->num_val, it->str_val, line);
                    }
                    free_tokenlist(&inner);

                    tok_add(&tl, TOK_RPAREN, 0, NULL, line);
                    tok_add(&tl, TOK_RPAREN, 0, NULL, line);
                    continue;
                }
                buf[bi++] = *p++;
            }
            /* Emit trailing literal */
            buf[bi] = '\0';
            if (bi > 0) {
                if (has_segments) tok_add(&tl, TOK_PLUS, 0, NULL, line);
                tok_add(&tl, TOK_STR, 0, buf, line);
            } else if (!has_segments) {
                /* empty f-string: f"" */
                tok_add(&tl, TOK_STR, 0, "", line);
            }
            if (*p == '"') p++;
            else {
                fprintf(stderr, "Syntax error line %d: unterminated f-string\n", line);
                g_parse_errors++;
            }
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
            else {
                fprintf(stderr, "Syntax error line %d: unterminated string\n", line);
                g_parse_errors++;
            }
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
                else {
                    fprintf(stderr, "Syntax error line %d: expected '!=' after '!'\n", line);
                    g_parse_errors++; p++;
                }
                break;
            case '=':
                if (*(p+1) == '=') { tok_add(&tl, TOK_EQ, 0, NULL, line); p += 2; }
                else { tok_add(&tl, TOK_ASSIGN, 0, NULL, line); p++; }
                break;
            default:
                fprintf(stderr, "Syntax error line %d: unexpected character '%c'\n", line, *p);
                g_parse_errors++;
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

static ASTNode* make_node(ASTType type, int line) {
    ASTNode *n = calloc(1, sizeof(ASTNode));
    n->type = type;
    n->line = line;
    return n;
}

/* Recursively free an AST tree. */
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
    ASTNode **stmts = malloc(MAX_STMTS * sizeof(ASTNode*));
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
        n->data.ident.name = strdup(t->str_val);
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
        n->data.str = strdup(t->str_val);
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
        n->data.ident.name = strdup(t->str_val);
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

    if (t->type == TOK_LPAREN) {
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
        strcpy(n->data.unary.op, "-");
        n->data.unary.operand = operand;
        return n;
    }
    if (p_cur(p)->type == TOK_NOT) {
        p_advance(p);
        ASTNode *operand = parse_unary(p);
        ASTNode *n = make_node(AST_UNARY, p_cur(p)->line);
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
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
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
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
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
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
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
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
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
        ASTNode *n = make_node(AST_BINOP, p_cur(p)->line);
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

        /* Parse optional named parameters: define add(a, b) as: */
        char **params = NULL;
        int param_count = 0;
        if (p_cur(p)->type == TOK_LPAREN) {
            p_advance(p); /* skip ( */
            params = malloc(16 * sizeof(char*));
            while (p_cur(p)->type == TOK_IDENT && param_count < 16) {
                params[param_count++] = strdup(p_cur(p)->str_val);
                p_advance(p);
                if (p_cur(p)->type == TOK_COMMA) p_advance(p);
            }
            p_expect(p, TOK_RPAREN);
        }
        if (param_count == 0) {
            /* No explicit params: default to single param "n" */
            params = malloc(sizeof(char*));
            params[0] = strdup("n");
            param_count = 1;
        }

        if (p_cur(p)->type == TOK_AS) p_advance(p);
        p_expect(p, TOK_COLON);
        p_skip_newlines(p);
        int body_count;
        ASTNode **body = parse_block(p, &body_count);
        ASTNode *n = make_node(AST_FUNC, p_cur(p)->line);
        n->data.func.name = strdup((name_tok && name_tok->str_val) ? name_tok->str_val : "");
        n->data.func.params = params;
        n->data.func.param_count = param_count;
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
        n->data.forloop.var = strdup((var_tok && var_tok->str_val) ? var_tok->str_val : "");
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

    if (t->type == TOK_IDENT && p_peek(p, 1)->type == TOK_IS) {
        Token *name_tok = p_advance(p);
        p_advance(p);
        ASTNode *expr = parse_expression(p);
        p_match(p, TOK_NEWLINE);
        ASTNode *n = make_node(AST_ASSIGN, p_cur(p)->line);
        n->data.assign.name = strdup((name_tok && name_tok->str_val) ? name_tok->str_val : "");
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
            fprintf(stderr, "Error line %d: undefined variable '%s'\n", node->line, node->data.ident.name);
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
            Value *left = eval_node(node->data.binop.left, env);
            if (!is_truthy(left)) return make_num(0);
            Value *right = eval_node(node->data.binop.right, env);
            return make_num(is_truthy(right) ? 1 : 0);
        }
        if (strcmp(op, "or") == 0) {
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
            if (right->data.num == 0) {
                fprintf(stderr, "Warning line %d: division by zero\n", node->line);
                return make_num(0);
            }
            return make_num(left->data.num / right->data.num);
        }
        if (strcmp(op, "%") == 0 && left->type == VAL_NUM && right->type == VAL_NUM) {
            if (right->data.num == 0) {
                fprintf(stderr, "Warning line %d: division by zero\n", node->line);
                return make_num(0);
            }
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

        fprintf(stderr, "Error line %d: cannot apply '%s' to %s and %s\n",
                node->line, op, val_type_name(left->type), val_type_name(right->type));
        return make_null();
    }

    case AST_UNARY: {
        Value *operand = eval_node(node->data.unary.operand, env);
        if (strcmp(node->data.unary.op, "-") == 0) {
            if (operand->type == VAL_NUM)
                return make_num(-operand->data.num);
            fprintf(stderr, "Error line %d: cannot negate %s\n", node->line, val_type_name(operand->type));
            return make_null();
        }
        if (strcmp(node->data.unary.op, "not") == 0) {
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
            if (left_val->data.fn.param_count > 1 && right_val && right_val->type == VAL_LIST) {
                /* Multi-param: unpack list into named params */
                for (int pi = 0; pi < left_val->data.fn.param_count && pi < right_val->data.list.count; pi++)
                    env_set_local(call_env, left_val->data.fn.params[pi], right_val->data.list.items[pi]);
            } else if (left_val->data.fn.param_count == 1) {
                /* Single param: bind to param name */
                env_set_local(call_env, left_val->data.fn.params[0], right_val);
            }
            /* Always bind "n" for backward compatibility */
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

        fprintf(stderr, "Error line %d: cannot call %s (not a function)\n",
                node->line, val_type_name(left_val->type));
        return make_null();
    }

    case AST_IF: {
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
        if (!iter || iter->type != VAL_LIST) {
            fprintf(stderr, "Error line %d: 'for' requires a list, got %s\n",
                    node->line, iter ? val_type_name(iter->type) : "null");
            return make_null();
        }
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
        Value *fn = make_fn(node->data.func.name, node->data.func.params,
                           node->data.func.param_count,
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
            fprintf(stderr, "Error line %d: index %d out of range (length %d)\n", node->line,
                    i, target->data.list.count);
            return make_null();
        }
        if (target->type == VAL_STR && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            int len = strlen(target->data.str);
            if (i >= 0 && i < len) {
                char buf[2] = {target->data.str[i], '\0'};
                return make_str(buf);
            }
            fprintf(stderr, "Error line %d: index %d out of range (length %d)\n", node->line, i, len);
            return make_null();
        }
        fprintf(stderr, "Error line %d: cannot index %s\n", node->line, val_type_name(target->type));
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
        fprintf(stderr, "Type error: json_decode requires a string, got %s\n",
                arg ? val_type_name(arg->type) : "null");
        return make_null();
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

/* ==== BUILTIN: str_upper ==== */
Value* builtin_str_upper(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    char *s = strdup(arg->data.str);
    for (int i = 0; s[i]; i++) s[i] = toupper((unsigned char)s[i]);
    Value *r = make_str(s);
    free(s);
    return r;
}

/* ==== BUILTIN: char_at ==== */
/* char_at of [string, index] → single character as string, or "" if out of range */
Value* builtin_char_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_str("");
    Value *str_val = arg->data.list.items[0];
    Value *idx_val = arg->data.list.items[1];
    if (!str_val || str_val->type != VAL_STR || !idx_val || idx_val->type != VAL_NUM)
        return make_str("");
    int idx = (int)idx_val->data.num;
    int len = strlen(str_val->data.str);
    if (idx < 0 || idx >= len) return make_str("");
    char buf[2] = { str_val->data.str[idx], '\0' };
    return make_str(buf);
}

/* ==== BUILTIN: ends_with ==== */
Value* builtin_ends_with(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    const char *str = "", *suffix = "";
    if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) suffix = arg->data.list.items[1]->data.str;
    int slen = strlen(str), xlen = strlen(suffix);
    if (xlen > slen) return make_num(0);
    return make_num(strcmp(str + slen - xlen, suffix) == 0 ? 1 : 0);
}

/* ==== BUILTIN: substr ==== */
/* substr of [string, start, length] → substring */
Value* builtin_substr(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_str("");
    Value *str_val = arg->data.list.items[0];
    Value *start_val = arg->data.list.items[1];
    Value *len_val = arg->data.list.items[2];
    if (!str_val || str_val->type != VAL_STR) return make_str("");
    if (!start_val || start_val->type != VAL_NUM) return make_str("");
    if (!len_val || len_val->type != VAL_NUM) return make_str("");
    int slen = strlen(str_val->data.str);
    int start = (int)start_val->data.num;
    int rlen = (int)len_val->data.num;
    if (start < 0) start = 0;
    if (start >= slen) return make_str("");
    if (rlen < 0) rlen = 0;
    if (start + rlen > slen) rlen = slen - start;
    char *buf = malloc(rlen + 1);
    memcpy(buf, str_val->data.str + start, rlen);
    buf[rlen] = '\0';
    Value *r = make_str(buf);
    free(buf);
    return r;
}

/* ==== BUILTIN: index_of ==== */
/* index_of of [haystack, needle] → first index, or -1 */
Value* builtin_index_of(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(-1);
    const char *haystack = "", *needle = "";
    if (arg->data.list.items[0]->type == VAL_STR) haystack = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) needle = arg->data.list.items[1]->data.str;
    const char *p = strstr(haystack, needle);
    if (!p) return make_num(-1);
    return make_num((double)(p - haystack));
}

/* ================================================================
 * MATH BUILTINS — trig, rounding, abs
 * ================================================================ */

Value* builtin_sin(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(sin(arg->data.num));
}

Value* builtin_cos(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(cos(arg->data.num));
}

Value* builtin_tan(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(tan(arg->data.num));
}

Value* builtin_asin(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(asin(arg->data.num));
}

Value* builtin_acos(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(acos(arg->data.num));
}

Value* builtin_atan(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(atan(arg->data.num));
}

Value* builtin_atan2(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *y = arg->data.list.items[0];
    Value *x = arg->data.list.items[1];
    if (!y || y->type != VAL_NUM || !x || x->type != VAL_NUM) return make_num(0);
    return make_num(atan2(y->data.num, x->data.num));
}

Value* builtin_floor(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(floor(arg->data.num));
}

Value* builtin_ceil(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(ceil(arg->data.num));
}

Value* builtin_round(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(round(arg->data.num));
}

Value* builtin_abs(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(fabs(arg->data.num));
}

Value* builtin_min(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_NUM || !b || b->type != VAL_NUM) return make_num(0);
    return make_num(a->data.num < b->data.num ? a->data.num : b->data.num);
}

Value* builtin_max(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_NUM || !b || b->type != VAL_NUM) return make_num(0);
    return make_num(a->data.num > b->data.num ? a->data.num : b->data.num);
}

Value* builtin_pi(Value *arg) {
    (void)arg;
    return make_num(3.14159265358979323846);
}

/* ================================================================
 * SYSTEM BUILTINS — random, args, paths, filesystem
 * ================================================================ */

static int g_random_seeded = 0;

static void ensure_random_seeded(void) {
    if (!g_random_seeded) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        srand48(ts.tv_sec ^ ts.tv_nsec ^ getpid());
        g_random_seeded = 1;
    }
}

/* random of null → float in [0, 1) */
Value* builtin_random(Value *arg) {
    (void)arg;
    ensure_random_seeded();
    return make_num(drand48());
}

/* random_int of [lo, hi] → integer in [lo, hi] inclusive */
Value* builtin_random_int(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *lo = arg->data.list.items[0];
    Value *hi = arg->data.list.items[1];
    if (!lo || lo->type != VAL_NUM || !hi || hi->type != VAL_NUM)
        return make_num(0);
    ensure_random_seeded();
    int lo_i = (int)lo->data.num;
    int hi_i = (int)hi->data.num;
    if (hi_i < lo_i) return make_num(lo_i);
    return make_num(lo_i + (lrand48() % (hi_i - lo_i + 1)));
}

/* seed_random of n → seeds the RNG, returns 1 */
Value* builtin_seed_random(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    srand48((long)arg->data.num);
    g_random_seeded = 1;
    return make_num(1);
}

/* ================================================================
 * STREAMING BINARY WRITER — write tensor-format data incrementally
 * ================================================================
 * stream_open of ["path", count]  → opens file, writes header with count, returns 1
 * stream_write of value           → writes one float64, returns 1
 * stream_close of null            → closes the stream file, returns 1
 *
 * Format: [uint32 ndim=1][uint32 rows=1][uint32 cols=count][uint32 flags=0]
 *         then count × float64 values (written one at a time via stream_write)
 */

static FILE *g_stream_file = NULL;

Value* builtin_stream_open(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *count_val = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR || !count_val || count_val->type != VAL_NUM)
        return make_num(0);
    if (g_stream_file) { fclose(g_stream_file); g_stream_file = NULL; }
    g_stream_file = fopen(path_val->data.str, "wb");
    if (!g_stream_file) return make_num(0);
    uint32_t count = (uint32_t)count_val->data.num;
    uint32_t header[4] = { 1, 1, count, 0 }; /* ndim=1, rows=1, cols=count, flags=0 */
    fwrite(header, sizeof(uint32_t), 4, g_stream_file);
    return make_num(1);
}

Value* builtin_stream_write(Value *arg) {
    if (!g_stream_file || !arg || arg->type != VAL_NUM) return make_num(0);
    double val = arg->data.num;
    fwrite(&val, sizeof(double), 1, g_stream_file);
    return make_num(1);
}

Value* builtin_stream_close(Value *arg) {
    (void)arg;
    if (!g_stream_file) return make_num(0);
    int ok = (fclose(g_stream_file) == 0);
    g_stream_file = NULL;
    return make_num(ok ? 1 : 0);
}

/* ---- Command-line arguments ---- */
static int g_argc = 0;
static char **g_argv = NULL;

void eigenscript_set_args(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
}

/* args of null → list of command-line arguments (after the script name) */
Value* builtin_args(Value *arg) {
    (void)arg;
    Value *list = make_list(g_argc > 2 ? g_argc - 2 : 0);
    /* g_argv[0] = eigenscript, g_argv[1] = script.eigs, g_argv[2..] = user args */
    for (int i = 2; i < g_argc; i++) {
        list_append(list, make_str(g_argv[i]));
    }
    return list;
}

/* ---- Path manipulation ---- */

/* path_join of [a, b] → "a/b" */
Value* builtin_path_join(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_str("");
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_STR || !b || b->type != VAL_STR)
        return make_str("");
    int alen = strlen(a->data.str);
    int blen = strlen(b->data.str);
    /* Skip trailing slash on a, skip leading slash on b */
    int strip_a = (alen > 0 && a->data.str[alen-1] == '/') ? 1 : 0;
    int skip_b = (blen > 0 && b->data.str[0] == '/') ? 1 : 0;
    int rlen = (alen - strip_a) + 1 + (blen - skip_b);
    char *buf = malloc(rlen + 1);
    memcpy(buf, a->data.str, alen - strip_a);
    buf[alen - strip_a] = '/';
    memcpy(buf + alen - strip_a + 1, b->data.str + skip_b, blen - skip_b);
    buf[rlen] = '\0';
    Value *r = make_str(buf);
    free(buf);
    return r;
}

/* path_dir of "a/b/c.txt" → "a/b" */
Value* builtin_path_dir(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *s = arg->data.str;
    const char *last = strrchr(s, '/');
    if (!last) return make_str(".");
    if (last == s) return make_str("/");
    int len = last - s;
    char *buf = malloc(len + 1);
    memcpy(buf, s, len);
    buf[len] = '\0';
    Value *r = make_str(buf);
    free(buf);
    return r;
}

/* path_base of "a/b/c.txt" → "c.txt" */
Value* builtin_path_base(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *s = arg->data.str;
    const char *last = strrchr(s, '/');
    return make_str(last ? last + 1 : s);
}

/* path_ext of "a/b/c.txt" → ".txt" */
Value* builtin_path_ext(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *base = strrchr(arg->data.str, '/');
    const char *s = base ? base + 1 : arg->data.str;
    const char *dot = strrchr(s, '.');
    return make_str(dot ? dot : "");
}

/* ---- Filesystem ---- */

/* mkdir of "path" → 1 on success, 0 on failure. Creates parents. */
Value* builtin_mkdir(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    /* Simple recursive mkdir */
    char *path = strdup(arg->data.str);
    int len = strlen(path);
    for (int i = 1; i <= len; i++) {
        if (path[i] == '/' || path[i] == '\0') {
            char saved = path[i];
            path[i] = '\0';
            mkdir(path, 0755); /* ignore errors on intermediate dirs */
            path[i] = saved;
        }
    }
    free(path);
    struct stat st;
    return make_num(stat(arg->data.str, &st) == 0 && S_ISDIR(st.st_mode) ? 1 : 0);
}

/* ls of "path" → list of filenames in directory, or [] on failure */
Value* builtin_ls(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_list(0);
    Value *list = make_list(0);
    /* Use opendir/readdir */
    /* Note: dirent.h is POSIX, available on Linux */
    char cmd[4200];
    snprintf(cmd, sizeof(cmd), "ls -1 '%s' 2>/dev/null", arg->data.str);
    FILE *f = popen(cmd, "r");
    if (!f) return list;
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        int l = strlen(line);
        if (l > 0 && line[l-1] == '\n') line[l-1] = '\0';
        if (line[0]) list_append(list, make_str(line));
    }
    pclose(f);
    return list;
}

/* getcwd of null → current working directory as string */
Value* builtin_getcwd(Value *arg) {
    (void)arg;
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) return make_str(buf);
    return make_str("");
}

/* chdir of "path" → 1 on success, 0 on failure */
Value* builtin_chdir(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(chdir(arg->data.str) == 0 ? 1 : 0);
}

/* mktemp of null → path to a new temporary file */
Value* builtin_mktemp(Value *arg) {
    (void)arg;
    char tmpl[] = "/tmp/eigen_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return make_str("");
    close(fd);
    return make_str(tmpl);
}

/* free_val of value → frees a heap-allocated Value tree. Returns null.
 * Use this to release large temporary results (e.g. tokenize_with_names output)
 * when the arena is not active. No-op on arena-allocated values. */
Value* builtin_free_val(Value *arg) {
    if (arg && !g_arena.active) free_value(arg);
    return make_null();
}

/* rm of "path" → 1 on success, 0 on failure */
Value* builtin_rm(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(unlink(arg->data.str) == 0 ? 1 : 0);
}

/* ================================================================
 * BUILTIN: build_corpus — 3-pass corpus builder in C
 * ================================================================
 * build_corpus of [file_list, top_n, stream_path, vocab_path]
 *
 * file_list:    list of strings (paths to .eigs files)
 * top_n:        number of identifier tokens to promote (e.g. 64)
 * stream_path:  output path for binary token stream
 * vocab_path:   output path for identifier vocab JSON
 *
 * Returns: [stream_length, distinct_identifiers, files_found]
 */

/* Identifier frequency entry */
typedef struct {
    char *name;
    int count;
} IdentEntry;

Value* builtin_build_corpus(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4)
        return make_null();

    Value *file_list = arg->data.list.items[0];
    Value *topn_val = arg->data.list.items[1];
    Value *stream_path_val = arg->data.list.items[2];
    Value *vocab_path_val = arg->data.list.items[3];

    if (!file_list || file_list->type != VAL_LIST) return make_null();
    if (!topn_val || topn_val->type != VAL_NUM) return make_null();
    if (!stream_path_val || stream_path_val->type != VAL_STR) return make_null();
    if (!vocab_path_val || vocab_path_val->type != VAL_STR) return make_null();

    int top_n = (int)topn_val->data.num;
    int n_files = file_list->data.list.count;
    const int FIRST_IDENT = 54;
    const int BASE_VOCAB = 54;

    /* ---- Pass 1: tokenize all files, count identifier frequencies ---- */
    IdentEntry *idents = NULL;
    int n_idents = 0;
    int idents_cap = 0;

    int *file_tok_counts = calloc(n_files, sizeof(int));
    int total_tokens = 0;
    int files_found = 0;

    for (int fi = 0; fi < n_files; fi++) {
        Value *path_val = file_list->data.list.items[fi];
        if (!path_val || path_val->type != VAL_STR) { file_tok_counts[fi] = 0; continue; }
        const char *path = path_val->data.str;

        /* Read file */
        long fsize = 0;
        char *source = read_file_util(path, &fsize);
        if (!source) {
            fprintf(stderr, "  skip: %s\n", path);
            file_tok_counts[fi] = 0;
            continue;
        }

        /* Tokenize */
        TokenList tl = tokenize(source);
        file_tok_counts[fi] = tl.count;
        total_tokens += tl.count;
        files_found++;

        /* Count identifiers */
        for (int i = 0; i < tl.count; i++) {
            if (tl.tokens[i].type == TOK_IDENT && tl.tokens[i].str_val && tl.tokens[i].str_val[0]) {
                const char *name = tl.tokens[i].str_val;
                /* Linear scan for existing entry */
                int found = -1;
                for (int j = 0; j < n_idents; j++) {
                    if (strcmp(idents[j].name, name) == 0) { found = j; break; }
                }
                if (found >= 0) {
                    idents[found].count++;
                } else {
                    if (n_idents >= idents_cap) {
                        idents_cap = idents_cap < 256 ? 256 : idents_cap * 2;
                        idents = realloc(idents, idents_cap * sizeof(IdentEntry));
                    }
                    idents[n_idents].name = strdup(name);
                    idents[n_idents].count = 1;
                    n_idents++;
                }
            }
        }

        fprintf(stderr, "  %s: %d tokens\n", path, tl.count);
        free_tokenlist(&tl);
        free(source);
    }

    fprintf(stderr, "\nFiles: %d/%d\n", files_found, n_files);
    fprintf(stderr, "Distinct identifiers: %d\n", n_idents);

    /* ---- Pass 2: pick top-N identifiers ---- */
    int actual_top = top_n < n_idents ? top_n : n_idents;
    if (actual_top <= 0) actual_top = 0;
    char **top_names = calloc(actual_top > 0 ? actual_top : 1, sizeof(char*));
    int *top_ids = calloc(actual_top > 0 ? actual_top : 1, sizeof(int));

    /* Work on a copy of counts */
    int *work_counts = malloc(n_idents * sizeof(int));
    for (int i = 0; i < n_idents; i++) work_counts[i] = idents[i].count;

    for (int t = 0; t < actual_top; t++) {
        int best_idx = -1, best_val = -1;
        for (int j = 0; j < n_idents; j++) {
            if (work_counts[j] > best_val) { best_val = work_counts[j]; best_idx = j; }
        }
        if (best_idx < 0) break;
        top_names[t] = idents[best_idx].name;
        top_ids[t] = FIRST_IDENT + t;
        work_counts[best_idx] = -1;
    }
    free(work_counts);

    fprintf(stderr, "\nTop %d identifiers:\n", actual_top);
    for (int i = 0; i < 10 && i < actual_top; i++) {
        fprintf(stderr, "  %3d  %-20s  %d uses\n", top_ids[i], top_names[i],
                idents[top_ids[i] - FIRST_IDENT].count);
    }

    /* ---- Pass 3: re-tokenize and write binary stream ---- */
    int stream_size = total_tokens + files_found * 2; /* +2 EOF per file */

    FILE *stream_file = fopen(stream_path_val->data.str, "wb");
    if (!stream_file) {
        fprintf(stderr, "Error: cannot open %s\n", stream_path_val->data.str);
        free(file_tok_counts); free(top_names); free(top_ids);
        for (int i = 0; i < n_idents; i++) free(idents[i].name);
        free(idents);
        return make_null();
    }

    /* Write header: ndim=1, rows=1, cols=stream_size, flags=0 */
    uint32_t header[4] = { 1, 1, (uint32_t)stream_size, 0 };
    fwrite(header, sizeof(uint32_t), 4, stream_file);
    int stream_pos = 0;

    for (int fi = 0; fi < n_files; fi++) {
        if (file_tok_counts[fi] <= 0) continue;

        Value *path_val = file_list->data.list.items[fi];
        long fsize = 0;
        char *source = read_file_util(path_val->data.str, &fsize);
        if (!source) continue;

        /* Write double-EOF separator */
        double eof_val = (double)TOK_EOF;
        fwrite(&eof_val, sizeof(double), 1, stream_file);
        fwrite(&eof_val, sizeof(double), 1, stream_file);
        stream_pos += 2;

        TokenList tl = tokenize(source);

        for (int i = 0; i < tl.count; i++) {
            int tid = tl.tokens[i].type;
            /* Replace known identifiers with extended IDs */
            if (tid == TOK_IDENT && tl.tokens[i].str_val && tl.tokens[i].str_val[0]) {
                for (int j = 0; j < actual_top; j++) {
                    if (strcmp(top_names[j], tl.tokens[i].str_val) == 0) {
                        tid = top_ids[j];
                        break;
                    }
                }
            }
            double d = (double)tid;
            fwrite(&d, sizeof(double), 1, stream_file);
            stream_pos++;
        }

        free_tokenlist(&tl);
        free(source);
    }

    fclose(stream_file);
    fprintf(stderr, "\nWritten: %s (%d tokens)\n", stream_path_val->data.str, stream_pos);

    /* ---- Write identifier vocab JSON ---- */
    FILE *vocab_file = fopen(vocab_path_val->data.str, "w");
    if (vocab_file) {
        fprintf(vocab_file, "{\"first_ident_id\": %d, \"ext_vocab_size\": %d, \"top_n\": %d, \"names\": [",
                FIRST_IDENT, BASE_VOCAB + top_n, top_n);
        for (int i = 0; i < actual_top; i++) {
            if (i > 0) fprintf(vocab_file, ", ");
            fprintf(vocab_file, "\"%s\"", top_names[i]);
        }
        fprintf(vocab_file, "]}");
        fclose(vocab_file);
        fprintf(stderr, "Written: %s\n", vocab_path_val->data.str);
    }

    /* ---- Cleanup ---- */
    free(file_tok_counts);
    free(top_names);
    free(top_ids);
    for (int i = 0; i < n_idents; i++) free(idents[i].name);
    free(idents);

    /* Return [stream_length, distinct_identifiers, files_found] */
    Value *result = make_list(3);
    list_append(result, make_num(stream_pos));
    list_append(result, make_num(n_idents));
    list_append(result, make_num(files_found));
    return result;
}

/* ================================================================
 * GENERIC HTTP CLIENT — language-level, no product logic
 * ================================================================ */


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
    const char *path = arg->data.str;
    long size = 0;
    char *source = read_file_util(path, &size);

    /* Fallback: try relative to script directory, then its parent */
    char resolved[8192];
    if (!source && path[0] != '/') {
        snprintf(resolved, sizeof(resolved), "%s/%s", g_script_dir, path);
        source = read_file_util(resolved, &size);
        if (source) path = resolved;
    }
    if (!source && path[0] != '/') {
        snprintf(resolved, sizeof(resolved), "%s/../%s", g_script_dir, path);
        source = read_file_util(resolved, &size);
        if (source) path = resolved;
    }

    if (!source) {
        fprintf(stderr, "load_file: cannot read '%s'\n", arg->data.str);
        return make_null();
    }
    fprintf(stderr, "[load_file] Loading %s (%ld bytes)\n", path, size);
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    Value *result = eval_node(ast, g_global_env);
    free(source);
    free_tokenlist(&tl);
    return result ? result : make_null();
}

/* ================================================================
 * THIN BUILTINS — individual capabilities for .eigs orchestration
 * ================================================================ */


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

/* ==== BUILTIN: read_text ==== */
/* read_text of "path" → file contents as string, or "" on failure. */
Value* builtin_read_text(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    FILE *f = fopen(arg->data.str, "r");
    if (!f) return make_str("");
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0 || len > 10 * 1024 * 1024) { /* 10 MB cap */
        fclose(f);
        return make_str("");
    }
    char *buf = malloc(len + 1);
    if (!buf) { fclose(f); return make_str(""); }
    size_t read = fread(buf, 1, len, f);
    fclose(f);
    buf[read] = '\0';
    Value *result = make_str(buf);
    free(buf);
    return result;
}

/* ==== BUILTIN: write_text ==== */
/* write_text of ["path", text] → 1 on success, 0 on failure. */
Value* builtin_write_text(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *text_val = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR ||
        !text_val || text_val->type != VAL_STR)
        return make_num(0);
    FILE *f = fopen(path_val->data.str, "w");
    if (!f) return make_num(0);
    size_t len = strlen(text_val->data.str);
    size_t written = fwrite(text_val->data.str, 1, len, f);
    int close_ok = (fclose(f) == 0);
    return make_num(written == len && close_ok ? 1 : 0);
}

/* ==== BUILTIN: exec_capture ==== */
/* exec_capture of ["cmd", "arg1", ...]               → [exit_code, stdout_text]
 * exec_capture of [["cmd", "arg1", ...], timeout_sec] → same, with timeout
 *
 * Runs a subprocess with fork/exec, captures stdout. No shell.
 * Child stdin is /dev/null. 10 MB output cap.
 *
 * Timeout form: pass a 2-element list where the first element is the
 * command list and the second is the timeout in seconds.
 * On timeout the child is killed and the return is [-2, partial_stdout].
 *
 * Always returns a 2-item list. Returns [-1, ""] on failure. */

static Value* exec_capture_result(int code, const char *text) {
    Value *result = make_list(2);
    result->data.list.items[0] = make_num(code);
    result->data.list.items[1] = make_str(text);
    result->data.list.count = 2;
    return result;
}

Value* builtin_exec_capture(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 1)
        return exec_capture_result(-1, "");

    /* Detect timeout form: [["cmd", ...], timeout_num] */
    double timeout_sec = -1;
    Value *cmd_list = arg;
    if (arg->data.list.count == 2
        && arg->data.list.items[0] && arg->data.list.items[0]->type == VAL_LIST
        && arg->data.list.items[1] && arg->data.list.items[1]->type == VAL_NUM) {
        cmd_list = arg->data.list.items[0];
        timeout_sec = arg->data.list.items[1]->data.num;
        if (cmd_list->data.list.count < 1)
            return exec_capture_result(-1, "");
    }

    int total = cmd_list->data.list.count;

    /* Build argv array */
    char **argv = malloc((total + 1) * sizeof(char*));
    if (!argv) return exec_capture_result(-1, "");
    for (int i = 0; i < total; i++) {
        Value *v = cmd_list->data.list.items[i];
        if (!v || v->type != VAL_STR) {
            free(argv);
            return exec_capture_result(-1, "");
        }
        argv[i] = v->data.str;
    }
    argv[total] = NULL;

    /* Create pipe for stdout capture */
    int pipefd[2];
    if (pipe(pipefd) != 0) { free(argv); return exec_capture_result(-1, ""); }

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return exec_capture_result(-1, "");
    }

    if (pid == 0) {
        /* Child: redirect stdout to pipe, stdin to /dev/null */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
        execvp(argv[0], argv);
        _exit(127); /* exec failed */
    }

    /* Parent: read from pipe, close write end */
    close(pipefd[1]);
    free(argv);

    /* Compute deadline */
    struct timespec deadline;
    int has_timeout = (timeout_sec >= 0);
    if (has_timeout) {
        clock_gettime(CLOCK_MONOTONIC, &deadline);
        deadline.tv_sec += (time_t)timeout_sec;
        deadline.tv_nsec += (long)((timeout_sec - (time_t)timeout_sec) * 1e9);
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec++;
            deadline.tv_nsec -= 1000000000L;
        }
    }

    size_t cap = 4096, len = 0;
    char *buf = malloc(cap + 1);
    if (!buf) {
        close(pipefd[0]);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return exec_capture_result(-1, "");
    }

    int timed_out = 0;

    /* Read loop with optional timeout via poll() */
    for (;;) {
        int poll_ms = -1; /* infinite */
        if (has_timeout) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long remaining_ms = (deadline.tv_sec - now.tv_sec) * 1000
                              + (deadline.tv_nsec - now.tv_nsec) / 1000000;
            if (remaining_ms <= 0) { timed_out = 1; break; }
            poll_ms = (int)remaining_ms;
        }

        struct pollfd pfd = { .fd = pipefd[0], .events = POLLIN };
        int pr = poll(&pfd, 1, poll_ms);
        if (pr == 0) { timed_out = 1; break; }       /* timeout */
        if (pr < 0) { if (errno == EINTR) continue; break; } /* error */

        ssize_t n = read(pipefd[0], buf + len, cap - len);
        if (n <= 0) break; /* EOF or error */
        len += n;
        if (len >= cap) {
            if (cap >= 10 * 1024 * 1024) break;
            size_t newcap = cap * 2;
            if (newcap > 10 * 1024 * 1024) newcap = 10 * 1024 * 1024;
            char *newbuf = realloc(buf, newcap + 1);
            if (!newbuf) break;
            buf = newbuf;
            cap = newcap;
        }
    }
    close(pipefd[0]);
    buf[len] = '\0';

    int exit_code;
    if (timed_out) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        exit_code = -2;
    } else {
        int status = 0;
        waitpid(pid, &status, 0);
        exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }

    Value *result = exec_capture_result(exit_code, buf);
    free(buf);
    return result;
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
    if (fn->data.fn.param_count > 1 && arg && arg->type == VAL_LIST) {
        for (int pi = 0; pi < fn->data.fn.param_count && pi < arg->data.list.count; pi++)
            env_set_local(call_env, fn->data.fn.params[pi], arg->data.list.items[pi]);
    } else if (fn->data.fn.param_count == 1) {
        env_set_local(call_env, fn->data.fn.params[0], arg);
    }
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

/* Free a TokenList's malloc'd storage (token array and str_vals) */
void free_tokenlist(TokenList *tl) {
    if (!tl->tokens) return;
    for (int i = 0; i < tl->count; i++) {
        if (tl->tokens[i].str_val) {
            free(tl->tokens[i].str_val);
            tl->tokens[i].str_val = NULL;
        }
    }
    free(tl->tokens);
    tl->tokens = NULL;
    tl->count = 0;
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
    free_tokenlist(&tl);
    return result;
}

/* ==== BUILTIN: tokenize_with_names ==== */
/* tokenize_with_names of string → list of [type_id, name_str] pairs.
 * Like tokenize_ids, but preserves the identifier name (for IDENT), the
 * string content (for STR), and the number as a string (for NUM). Other
 * token types get an empty string. Used by corpus builders that need
 * per-identifier information for vocabulary enrichment. */
Value* builtin_tokenize_with_names(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_list(0);
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_list(0);

    TokenList tl = tokenize(src);
    Value *result = make_list(tl.count);
    char numbuf[64];
    for (int i = 0; i < tl.count; i++) {
        Value *pair = make_list(2);
        list_append(pair, make_num((double)tl.tokens[i].type));
        const char *name = "";
        if (tl.tokens[i].type == TOK_IDENT && tl.tokens[i].str_val) {
            name = tl.tokens[i].str_val;
        } else if (tl.tokens[i].type == TOK_STR && tl.tokens[i].str_val) {
            name = tl.tokens[i].str_val;
        } else if (tl.tokens[i].type == TOK_NUM) {
            double d = tl.tokens[i].num_val;
            if (d == (double)(long)d) {
                snprintf(numbuf, sizeof(numbuf), "%ld", (long)d);
            } else {
                snprintf(numbuf, sizeof(numbuf), "%g", d);
            }
            name = numbuf;
        }
        list_append(pair, make_str(name)); /* make_str copies the string */
        list_append(result, pair);
    }
    free_tokenlist(&tl);
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
    free_tokenlist(&tl);
    /* AST intentionally leaked — try_parse called rarely enough that this
     * is acceptable, and free_ast has edge cases with partial parses. */
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
    env_set_local(env, "str_upper", make_builtin(builtin_str_upper));
    env_set_local(env, "char_at", make_builtin(builtin_char_at));
    env_set_local(env, "ends_with", make_builtin(builtin_ends_with));
    env_set_local(env, "substr", make_builtin(builtin_substr));
    env_set_local(env, "index_of", make_builtin(builtin_index_of));
    env_set_local(env, "sin", make_builtin(builtin_sin));
    env_set_local(env, "cos", make_builtin(builtin_cos));
    env_set_local(env, "tan", make_builtin(builtin_tan));
    env_set_local(env, "asin", make_builtin(builtin_asin));
    env_set_local(env, "acos", make_builtin(builtin_acos));
    env_set_local(env, "atan", make_builtin(builtin_atan));
    env_set_local(env, "atan2", make_builtin(builtin_atan2));
    env_set_local(env, "floor", make_builtin(builtin_floor));
    env_set_local(env, "ceil", make_builtin(builtin_ceil));
    env_set_local(env, "round", make_builtin(builtin_round));
    env_set_local(env, "abs", make_builtin(builtin_abs));
    env_set_local(env, "min", make_builtin(builtin_min));
    env_set_local(env, "max", make_builtin(builtin_max));
    env_set_local(env, "pi", make_builtin(builtin_pi));
    env_set_local(env, "random", make_builtin(builtin_random));
    env_set_local(env, "random_int", make_builtin(builtin_random_int));
    env_set_local(env, "seed_random", make_builtin(builtin_seed_random));
    env_set_local(env, "args", make_builtin(builtin_args));
    env_set_local(env, "path_join", make_builtin(builtin_path_join));
    env_set_local(env, "path_dir", make_builtin(builtin_path_dir));
    env_set_local(env, "path_base", make_builtin(builtin_path_base));
    env_set_local(env, "path_ext", make_builtin(builtin_path_ext));
    env_set_local(env, "mkdir", make_builtin(builtin_mkdir));
    env_set_local(env, "ls", make_builtin(builtin_ls));
    env_set_local(env, "getcwd", make_builtin(builtin_getcwd));
    env_set_local(env, "chdir", make_builtin(builtin_chdir));
    env_set_local(env, "mktemp", make_builtin(builtin_mktemp));
    env_set_local(env, "rm", make_builtin(builtin_rm));
    env_set_local(env, "free_val", make_builtin(builtin_free_val));
    env_set_local(env, "stream_open", make_builtin(builtin_stream_open));
    env_set_local(env, "stream_write", make_builtin(builtin_stream_write));
    env_set_local(env, "stream_close", make_builtin(builtin_stream_close));
    env_set_local(env, "build_corpus", make_builtin(builtin_build_corpus));
    env_set_local(env, "contains", make_builtin(builtin_contains));
    env_set_local(env, "starts_with", make_builtin(builtin_starts_with));
    env_set_local(env, "split", make_builtin(builtin_split));
    env_set_local(env, "trim", make_builtin(builtin_trim));
    env_set_local(env, "str_replace", make_builtin(builtin_str_replace));
    env_set_local(env, "load_file", make_builtin(builtin_load_file));
    env_set_local(env, "file_exists", make_builtin(builtin_file_exists));
    env_set_local(env, "env_get", make_builtin(builtin_env_get));
    env_set_local(env, "read_text", make_builtin(builtin_read_text));
    env_set_local(env, "write_text", make_builtin(builtin_write_text));
    env_set_local(env, "exec_capture", make_builtin(builtin_exec_capture));

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
    env_set_local(env, "tokenize_with_names", make_builtin(builtin_tokenize_with_names));
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

#if EIGENSCRIPT_EXT_DB
    register_db_builtins(env);
#endif

#if EIGENSCRIPT_EXT_MODEL
    register_model_builtins(env);
#endif


}


