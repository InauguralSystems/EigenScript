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

const char* tok_type_name(TokType t) {
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
    v->data.fn.params = xmalloc_array(param_count, sizeof(char*));
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
        dict->data.dict.keys = xrealloc_array(dict->data.dict.keys, new_cap, sizeof(char*));
        dict->data.dict.vals = xrealloc_array(dict->data.dict.vals, new_cap, sizeof(Value*));
        dict->data.dict.capacity = new_cap;
    }
    dict->data.dict.keys[dict->data.dict.count] = xstrdup(key);
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
            Value **new_items = arena_alloc(safe_size_mul(new_cap, sizeof(Value*)));
            memcpy(new_items, list->data.list.items, list->data.list.count * sizeof(Value*));
            list->data.list.items = new_items;
        } else {
            list->data.list.items = xrealloc_array(list->data.list.items, new_cap, sizeof(Value*));
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
    if (!v) return xstrdup("null");
    char buf[256];
    switch (v->type) {
        case VAL_NULL: return xstrdup("null");
        case VAL_NUM: {
            double n = v->data.num;
            if (n == (long long)n && fabs(n) < 1e15)
                snprintf(buf, sizeof(buf), "%lld", (long long)n);
            else
                snprintf(buf, sizeof(buf), "%.6g", n);
            return xstrdup(buf);
        }
        case VAL_STR: return xstrdup(v->data.str);
        case VAL_LIST: {
            strbuf out;
            strbuf_init(&out);
            strbuf_append_char(&out, '[');
            for (int i = 0; i < v->data.list.count; i++) {
                if (i > 0) strbuf_append_n(&out, ", ", 2);
                char *s = value_to_string(v->data.list.items[i]);
                if (v->data.list.items[i] && v->data.list.items[i]->type == VAL_STR)
                    strbuf_append_fmt(&out, "\"%s\"", s);
                else
                    strbuf_append(&out, s);
                free(s);
            }
            strbuf_append_char(&out, ']');
            return strbuf_finish(&out);
        }
        case VAL_FN: snprintf(buf, sizeof(buf), "<fn %s>", v->data.fn.name); return xstrdup(buf);
        case VAL_DICT: {
            strbuf out;
            strbuf_init(&out);
            strbuf_append_char(&out, '{');
            for (int i = 0; i < v->data.dict.count; i++) {
                if (i > 0) strbuf_append_n(&out, ", ", 2);
                strbuf_append_fmt(&out, "\"%s\": ", v->data.dict.keys[i]);
                char *vs = value_to_string(v->data.dict.vals[i]);
                if (v->data.dict.vals[i] && v->data.dict.vals[i]->type == VAL_STR)
                    strbuf_append_fmt(&out, "\"%s\"", vs);
                else
                    strbuf_append(&out, vs);
                free(vs);
            }
            strbuf_append_char(&out, '}');
            return strbuf_finish(&out);
        }
        case VAL_BUILTIN: return xstrdup("<builtin>");
        case VAL_JSON_RAW: return xstrdup(v->data.str);
    }
    return xstrdup("?");
}

/* ================================================================
 * ENVIRONMENT
 * ================================================================ */

Env* env_new(Env *parent) {
    Env *e = g_arena.active ? arena_alloc(sizeof(Env)) : xcalloc(1, sizeof(Env));
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
        char *name_copy = xstrdup(name);
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

