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
char g_error_msg[4096] = "";
int g_has_error = 0;
int g_breaking = 0;
int g_continuing = 0;

/* Set runtime error — captured by try/catch, or printed to stderr.
 * Inside try blocks, the error is silently captured.
 * Outside try blocks, it also prints to stderr. */
int g_try_depth = 0;

void runtime_error(int line, const char *fmt, ...) {
    char tmp[3900];
    va_list args;
    va_start(args, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, args);
    va_end(args);
    snprintf(g_error_msg, sizeof(g_error_msg), "Error line %d: %s", line, tmp);
    g_has_error = 1;
    if (g_try_depth == 0) {
        fprintf(stderr, "%s\n", g_error_msg);
    }
}

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
        case TOK_LBRACE: return "'{'";
        case TOK_RBRACE: return "'}'";
        case TOK_NEWLINE: return "newline";
        case TOK_INDENT: return "indent";
        case TOK_DEDENT: return "dedent";
        case TOK_EOF: return "end of file";
        case TOK_TRY: return "'try'";
        case TOK_CATCH: return "'catch'";
        case TOK_BREAK: return "'break'";
        case TOK_CONTINUE: return "'continue'";
        case TOK_IMPORT: return "'import'";
        case TOK_MATCH: return "'match'";
        case TOK_CASE: return "'case'";
        case TOK_PIPE: return "'|>'";
        case TOK_ARROW: return "'=>'";
        default: return "?";
    }
}

const char* val_type_name(ValType t) {
    switch (t) {
        case VAL_NUM: return "num";
        case VAL_STR: return "str";
        case VAL_LIST: return "list";
        case VAL_FN: return "fn";
        case VAL_BUILTIN: return "builtin";
        case VAL_NULL: return "null";
        case VAL_JSON_RAW: return "json_raw";
        case VAL_DICT: return "dict";
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
    Value *v = g_arena.active ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_NUM;
    v->data.num = n;
    return v;
}

/* Heap-only make_num — for values that must outlive arena reset
 * (e.g. updated model weights written in-place by sgd_update). */
Value* make_num_permanent(double n) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_NUM;
    v->data.num = n;
    return v;
}

Value* make_str(const char *s) {
    Value *v = g_arena.active ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_STR;
    v->data.str = xstrdup(s);
    if (g_arena.active) arena_track_string(v->data.str);
    return v;
}

Value* make_null(void) {
    Value *v = g_arena.active ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_NULL;
    return v;
}

Value* make_list(int capacity) {
    Value *v = g_arena.active ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_LIST;
    v->data.list.capacity = capacity < 8 ? 8 : capacity;
    if (g_arena.active)
        v->data.list.items = arena_alloc(v->data.list.capacity * sizeof(Value*));
    else
        v->data.list.items = xcalloc(v->data.list.capacity, sizeof(Value*));
    v->data.list.count = 0;
    return v;
}

Value* make_fn(const char *name, char **params, int param_count, ASTNode **body, int body_count, Env *closure) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_FN;
    v->data.fn.name = xstrdup(name);
    v->data.fn.params = xmalloc(param_count * sizeof(char*));
    v->data.fn.param_count = param_count;
    for (int i = 0; i < param_count; i++)
        v->data.fn.params[i] = xstrdup(params[i]);
    v->data.fn.body = body;
    v->data.fn.body_count = body_count;
    v->data.fn.closure = closure;
    return v;
}

Value* make_builtin(BuiltinFn fn) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUILTIN;
    v->data.builtin = fn;
    return v;
}

Value* make_dict(int capacity) {
    if (capacity < 8) capacity = 8;
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_DICT;
    v->data.dict.keys = xcalloc(capacity, sizeof(char*));
    v->data.dict.vals = xcalloc(capacity, sizeof(Value*));
    v->data.dict.count = 0;
    v->data.dict.capacity = capacity;
    return v;
}

void dict_set(Value *dict, const char *key, Value *val) {
    if (!dict || dict->type != VAL_DICT) return;
    /* Check if key exists */
    for (int i = 0; i < dict->data.dict.count; i++) {
        if (strcmp(dict->data.dict.keys[i], key) == 0) {
            dict->data.dict.vals[i] = val;
            return;
        }
    }
    /* Grow if needed */
    if (dict->data.dict.count >= dict->data.dict.capacity) {
        int new_cap = dict->data.dict.capacity * 2;
        dict->data.dict.keys = realloc(dict->data.dict.keys, new_cap * sizeof(char*));
        dict->data.dict.vals = realloc(dict->data.dict.vals, new_cap * sizeof(Value*));
        dict->data.dict.capacity = new_cap;
    }
    dict->data.dict.keys[dict->data.dict.count] = strdup(key);
    dict->data.dict.vals[dict->data.dict.count] = val;
    dict->data.dict.count++;
}

Value* dict_get(Value *dict, const char *key) {
    if (!dict || dict->type != VAL_DICT) return NULL;
    for (int i = 0; i < dict->data.dict.count; i++) {
        if (strcmp(dict->data.dict.keys[i], key) == 0)
            return dict->data.dict.vals[i];
    }
    return NULL;
}

int dict_has(Value *dict, const char *key) {
    return dict_get(dict, key) != NULL;
}

void dict_remove(Value *dict, const char *key) {
    if (!dict || dict->type != VAL_DICT) return;
    for (int i = 0; i < dict->data.dict.count; i++) {
        if (strcmp(dict->data.dict.keys[i], key) == 0) {
            free(dict->data.dict.keys[i]);
            /* Shift remaining */
            for (int j = i; j < dict->data.dict.count - 1; j++) {
                dict->data.dict.keys[j] = dict->data.dict.keys[j+1];
                dict->data.dict.vals[j] = dict->data.dict.vals[j+1];
            }
            dict->data.dict.count--;
            return;
        }
    }
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
        case VAL_DICT:
            for (int i = 0; i < v->data.dict.count; i++) {
                free(v->data.dict.keys[i]);
                value_free(v->data.dict.vals[i]);
            }
            free(v->data.dict.keys);
            free(v->data.dict.vals);
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
        case VAL_DICT: return v->data.dict.count > 0;
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
        case VAL_DICT: {
            char *result = malloc(MAX_STR);
            int pos = 0;
            int remaining;
            remaining = MAX_STR - pos; if (remaining < 1) remaining = 1;
            pos += snprintf(result + pos, remaining, "{");
            if (pos >= MAX_STR) pos = MAX_STR - 1;
            for (int i = 0; i < v->data.dict.count; i++) {
                if (i > 0) {
                    remaining = MAX_STR - pos; if (remaining < 1) remaining = 1;
                    pos += snprintf(result + pos, remaining, ", ");
                    if (pos >= MAX_STR) pos = MAX_STR - 1;
                }
                remaining = MAX_STR - pos; if (remaining < 1) remaining = 1;
                pos += snprintf(result + pos, remaining, "\"%s\": ", v->data.dict.keys[i]);
                if (pos >= MAX_STR) pos = MAX_STR - 1;
                char *vs = value_to_string(v->data.dict.vals[i]);
                remaining = MAX_STR - pos; if (remaining < 1) remaining = 1;
                if (v->data.dict.vals[i] && v->data.dict.vals[i]->type == VAL_STR)
                    pos += snprintf(result + pos, remaining, "\"%s\"", vs);
                else
                    pos += snprintf(result + pos, remaining, "%s", vs);
                if (pos >= MAX_STR) pos = MAX_STR - 1;
                free(vs);
            }
            remaining = MAX_STR - pos; if (remaining < 1) remaining = 1;
            pos += snprintf(result + pos, remaining, "}");
            if (pos >= MAX_STR) pos = MAX_STR - 1;
            return result;
        }
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
    if (strcmp(word, "try") == 0) return TOK_TRY;
    if (strcmp(word, "catch") == 0) return TOK_CATCH;
    if (strcmp(word, "break") == 0) return TOK_BREAK;
    if (strcmp(word, "continue") == 0) return TOK_CONTINUE;
    if (strcmp(word, "import") == 0) return TOK_IMPORT;
    if (strcmp(word, "match") == 0) return TOK_MATCH;
    if (strcmp(word, "case") == 0) return TOK_CASE;
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
    int bracket_depth = 0;  /* inside [], {}, () — suppress newlines/indent */

    while (*p) {
        if (at_line_start && bracket_depth == 0) {
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
            if (bracket_depth == 0) {
                if (tl.count > 0 && tl.tokens[tl.count-1].type != TOK_NEWLINE
                    && tl.tokens[tl.count-1].type != TOK_INDENT
                    && tl.tokens[tl.count-1].type != TOK_DEDENT) {
                    tok_add(&tl, TOK_NEWLINE, 0, NULL, line);
                }
                at_line_start = 1;
            }
            p++; line++;
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
            case '(': tok_add(&tl, TOK_LPAREN, 0, NULL, line); p++; bracket_depth++; break;
            case ')': tok_add(&tl, TOK_RPAREN, 0, NULL, line); p++; if (bracket_depth > 0) bracket_depth--; break;
            case '[': tok_add(&tl, TOK_LBRACKET, 0, NULL, line); p++; bracket_depth++; break;
            case ']': tok_add(&tl, TOK_RBRACKET, 0, NULL, line); p++; if (bracket_depth > 0) bracket_depth--; break;
            case '{': tok_add(&tl, TOK_LBRACE, 0, NULL, line); p++; bracket_depth++; break;
            case '}': tok_add(&tl, TOK_RBRACE, 0, NULL, line); p++; if (bracket_depth > 0) bracket_depth--; break;
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
                else if (*(p+1) == '>') { tok_add(&tl, TOK_ARROW, 0, NULL, line); p += 2; }
                else { tok_add(&tl, TOK_ASSIGN, 0, NULL, line); p++; }
                break;
            case '|':
                if (*(p+1) == '>') { tok_add(&tl, TOK_PIPE, 0, NULL, line); p += 2; }
                else { p++; } /* bare | not used */
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
        while (p_cur(p)->type == TOK_LBRACKET || p_cur(p)->type == TOK_DOT) {
            if (p_cur(p)->type == TOK_DOT) {
                p_advance(p);
                Token *key_tok = p_cur(p);
                p_expect(p, TOK_IDENT);
                ASTNode *dot = make_node(AST_DOT, p_cur(p)->line);
                dot->data.dot.target = n;
                dot->data.dot.key = strdup(key_tok->str_val);
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
            char **params = malloc(16 * sizeof(char*));
            int param_count = 0;
            while (p_cur(p)->type == TOK_IDENT && param_count < 16) {
                params[param_count++] = strdup(p_cur(p)->str_val);
                p_advance(p);
                if (p_cur(p)->type == TOK_COMMA) p_advance(p);
            }
            if (param_count == 0) {
                params[0] = strdup("n");
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

    /* Dict literal: {"key": value, ...} */
    if (t->type == TOK_LBRACE) {
        p_advance(p);
        ASTNode **keys = malloc(MAX_LIST * sizeof(ASTNode*));
        ASTNode **vals = malloc(MAX_LIST * sizeof(ASTNode*));
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
                dot->data.dot.key = strdup(key_tok->str_val);
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
        n->data.trycatch.err_name = strdup(err_name);
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
        ASTNode **patterns = malloc(64 * sizeof(ASTNode*));
        ASTNode ***bodies = malloc(64 * sizeof(ASTNode**));
        int *body_counts = malloc(64 * sizeof(int));
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

    if (t->type == TOK_IMPORT) {
        p_advance(p);
        Token *name_tok = p_cur(p);
        p_expect(p, TOK_IDENT);
        ASTNode *n = make_node(AST_IMPORT, t->line);
        n->data.import.module_name = strdup(name_tok->str_val);
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
            n->data.dot_assign.key = strdup(target->data.dot.key);
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
            runtime_error(node->line, "undefined variable '%s'", node->data.ident.name);
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

        runtime_error(node->line, "cannot apply '%s' to %s and %s",
                op, val_type_name(left->type), val_type_name(right->type));
        return make_null();
    }

    case AST_UNARY: {
        Value *operand = eval_node(node->data.unary.operand, env);
        if (strcmp(node->data.unary.op, "-") == 0) {
            if (operand->type == VAL_NUM)
                return make_num(-operand->data.num);
            runtime_error(node->line, "cannot negate %s", val_type_name(operand->type));
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
            } else {
                /* Single param: bind to param name (default "n" for classic style) */
                env_set_local(call_env, left_val->data.fn.params[0], right_val);
            }

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

        runtime_error(node->line, "cannot call %s (not a function)",
                val_type_name(left_val->type));
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
            if (g_breaking) { g_breaking = 0; break; }
            if (g_continuing) { g_continuing = 0; }
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
            runtime_error(node->line, "'for' requires a list, got %s",
                    iter ? val_type_name(iter->type) : "null");
            return make_null();
        }
        Value *result = make_null();
        for (int i = 0; i < iter->data.list.count; i++) {
            Env *loop_env = env_new(env);
            env_set_local(loop_env, node->data.forloop.var, iter->data.list.items[i]);
            result = eval_block(node->data.forloop.body, node->data.forloop.body_count, loop_env);
            if (g_returning) { env_free(loop_env); return result; }
            if (g_breaking) { g_breaking = 0; env_free(loop_env); break; }
            if (g_continuing) { g_continuing = 0; }
            env_free(loop_env);
        }
        return result;
    }

    case AST_LAMBDA: {
        /* Create a return-wrapping AST node for the body expression */
        ASTNode *ret = make_node(AST_RETURN, node->line);
        ret->data.ret.expr = node->data.lambda.body;
        ASTNode **body = malloc(sizeof(ASTNode*));
        body[0] = ret;
        Value *fn = make_fn("", node->data.lambda.params,
                           node->data.lambda.param_count, body, 1, env);
        env->captured = 1;
        return fn;
    }

    case AST_MATCH: {
        Value *val = eval_node(node->data.match.expr, env);
        for (int i = 0; i < node->data.match.case_count; i++) {
            ASTNode *pattern = node->data.match.patterns[i];
            if (!pattern) {
                /* Wildcard _ — always matches */
                return eval_block(node->data.match.bodies[i], node->data.match.body_counts[i], env);
            }
            Value *pat_val = eval_node(pattern, env);
            /* Compare: numbers, strings, or null */
            int matches = 0;
            if (val->type == VAL_NUM && pat_val->type == VAL_NUM)
                matches = (val->data.num == pat_val->data.num);
            else if (val->type == VAL_STR && pat_val->type == VAL_STR)
                matches = (strcmp(val->data.str, pat_val->data.str) == 0);
            else if (val->type == VAL_NULL && pat_val->type == VAL_NULL)
                matches = 1;
            else if (val->type == pat_val->type)
                matches = (val == pat_val); /* identity for other types */
            if (matches) {
                return eval_block(node->data.match.bodies[i], node->data.match.body_counts[i], env);
            }
        }
        return make_null(); /* no match */
    }

    case AST_DOT_ASSIGN: {
        Value *target = eval_node(node->data.dot_assign.target, env);
        Value *val = eval_node(node->data.dot_assign.expr, env);
        if (target->type == VAL_DICT) {
            dict_set(target, node->data.dot_assign.key, val);
            return val;
        }
        runtime_error(node->line, "cannot assign .%s on %s", node->data.dot_assign.key, val_type_name(target->type));
        return make_null();
    }

    case AST_IMPORT: {
        /* import math → loads lib/math.eigs into a dict namespace */
        const char *name = node->data.import.module_name;
        char path[4096];

        /* Try: lib/NAME.eigs relative to cwd, then script dir */
        snprintf(path, sizeof(path), "lib/%s.eigs", name);
        if (access(path, F_OK) != 0) {
            snprintf(path, sizeof(path), "%s/lib/%s.eigs", g_script_dir, name);
            if (access(path, F_OK) != 0) {
                snprintf(path, sizeof(path), "%s/../lib/%s.eigs", g_script_dir, name);
                if (access(path, F_OK) != 0) {
                    runtime_error(node->line, "import: module '%s' not found", name);
                    return make_null();
                }
            }
        }

        /* Load and execute in an isolated env (parent = global for builtins) */
        long src_size = 0;
        char *source = read_file_util(path, &src_size);
        if (!source) {
            runtime_error(node->line, "import: cannot read '%s'", path);
            return make_null();
        }

        Env *mod_env = env_new(g_global_env);
        int saved_errors = g_parse_errors;
        g_parse_errors = 0;
        TokenList tl = tokenize(source);
        ASTNode *ast = parse(&tl);
        if (g_parse_errors > 0) {
            runtime_error(node->line, "import: parse errors in '%s'", name);
            g_parse_errors = saved_errors;
            free_tokenlist(&tl);
            free(source);
            return make_null();
        }
        g_parse_errors = saved_errors;
        eval_node(ast, mod_env);
        free_tokenlist(&tl);
        free(source);

        /* Collect module's own bindings into a dict.
         * mod_env is a child of env, so mod_env->names[] contains only
         * names that were set in the module (not inherited lookups). */
        Value *mod_dict = make_dict(mod_env->count);
        for (int i = 0; i < mod_env->count; i++) {
            if (mod_env->names[i][0] == '_') continue; /* skip private */
            dict_set(mod_dict, mod_env->names[i], mod_env->values[i]);
        }

        env_set(env, name, mod_dict);
        return mod_dict;
    }

    case AST_BREAK:
        g_breaking = 1;
        return make_null();

    case AST_CONTINUE:
        g_continuing = 1;
        return make_null();

    case AST_FUNC: {
        Value *fn = make_fn(node->data.func.name, node->data.func.params,
                           node->data.func.param_count,
                           node->data.func.body, node->data.func.body_count, env);
        env->captured = 1;  /* This env is now a closure — do not free */
        env_set_local(env, node->data.func.name, fn);
        return fn;
    }

    case AST_RETURN: {
        Value *val = eval_node(node->data.ret.expr, env);
        g_returning = 1;
        g_return_val = val;
        return val;
    }

    case AST_TRY: {
        /* Clear error state and run try body */
        g_has_error = 0;
        g_error_msg[0] = '\0';
        g_try_depth++;
        Value *result = make_null();
        for (int i = 0; i < node->data.trycatch.try_count; i++) {
            result = eval_node(node->data.trycatch.try_body[i], env);
            if (g_returning) { g_try_depth--; return result; }
            if (g_has_error) break;
        }
        g_try_depth--;
        if (g_has_error) {
            /* Error occurred — run catch body with error bound */
            g_has_error = 0;
            Env *catch_env = env_new(env);
            env_set_local(catch_env, node->data.trycatch.err_name, make_str(g_error_msg));
            g_error_msg[0] = '\0';
            result = make_null();
            for (int i = 0; i < node->data.trycatch.catch_count; i++) {
                result = eval_node(node->data.trycatch.catch_body[i], catch_env);
                if (g_returning) { env_free(catch_env); return result; }
            }
            env_free(catch_env);
        }
        return result;
    }

    case AST_LIST: {
        Value *list = make_list(node->data.list.count);
        for (int i = 0; i < node->data.list.count; i++) {
            list_append(list, eval_node(node->data.list.elems[i], env));
        }
        return list;
    }

    case AST_DICT: {
        Value *d = make_dict(node->data.dict.count);
        for (int i = 0; i < node->data.dict.count; i++) {
            Value *key = eval_node(node->data.dict.keys[i], env);
            Value *val = eval_node(node->data.dict.vals[i], env);
            char *key_str = value_to_string(key);
            dict_set(d, key_str, val);
            free(key_str);
        }
        return d;
    }

    case AST_DOT: {
        Value *target = eval_node(node->data.dot.target, env);
        if (target->type == VAL_DICT) {
            Value *val = dict_get(target, node->data.dot.key);
            return val ? val : make_null();
        }
        runtime_error(node->line, "cannot access .%s on %s", node->data.dot.key, val_type_name(target->type));
        return make_null();
    }

    case AST_INDEX: {
        Value *target = eval_node(node->data.index.target, env);
        Value *idx = eval_node(node->data.index.index, env);
        /* Dict indexing: d["key"] */
        if (target->type == VAL_DICT && idx->type == VAL_STR) {
            Value *val = dict_get(target, idx->data.str);
            return val ? val : make_null();
        }
        if (target->type == VAL_LIST && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            if (i >= 0 && i < target->data.list.count)
                return target->data.list.items[i];
            runtime_error(node->line, "index %d out of range (length %d)", i, target->data.list.count);
            return make_null();
        }
        if (target->type == VAL_STR && idx->type == VAL_NUM) {
            int i = (int)idx->data.num;
            int len = strlen(target->data.str);
            if (i >= 0 && i < len) {
                char buf[2] = {target->data.str[i], '\0'};
                return make_str(buf);
            }
            runtime_error(node->line, "index %d out of range (length %d)", i, len);
            return make_null();
        }
        runtime_error(node->line, "cannot index %s", val_type_name(target->type));
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
        if (g_returning || g_breaking || g_continuing) return result;
    }
    return result;
}

