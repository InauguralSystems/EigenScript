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
__thread jmp_buf g_return_buf;
__thread Value *g_return_val = NULL;
__thread int g_returning = 0;
__thread int g_parse_errors = 0;
__thread char g_error_msg[4096] = "";
__thread int g_has_error = 0;
__thread int g_breaking = 0;
__thread int g_continuing = 0;

/* Set runtime error — captured by try/catch, or printed to stderr.
 * Inside try blocks, the error is silently captured.
 * Outside try blocks, it also prints to stderr. */
__thread int g_try_depth = 0;

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
        case TOK_UNOBSERVED: return "'unobserved'";
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
        case VAL_BUFFER: return "buffer";
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

#define NUM_FREELIST_CAP 4096
static __thread Value *g_num_freelist = NULL;
static __thread int g_num_freelist_count = 0;

/* (debug counters removed) */

/* Refcount-aware teardown. Called by val_decref when refcount hits 0.
 * Children are val_decref'd (not recursively freed), so shared values
 * tracked by refcount elsewhere stay alive. Arena-owned memory is
 * skipped — it gets reclaimed by arena_reset. */
void free_value(Value *v) {
    if (!v || v->arena || is_arena_ptr(v)) return;
    if (v->type == VAL_NUM) {
        /* Route freed NUMs to freelist for reuse by make_num */
        if (g_num_freelist_count < NUM_FREELIST_CAP) {
            memcpy(&v->data, &g_num_freelist, sizeof(Value *));
            g_num_freelist = v;
            g_num_freelist_count++;
            return;
        }
        free(v);
        return;
    }
    switch (v->type) {
        case VAL_STR:
        case VAL_JSON_RAW:
            if (v->data.str && !is_arena_ptr(v->data.str)) free(v->data.str);
            break;
        case VAL_LIST:
            for (int i = 0; i < v->data.list.count; i++)
                val_decref(v->data.list.items[i]);
            if (v->data.list.items && !is_arena_ptr(v->data.list.items))
                free(v->data.list.items);
            break;
        case VAL_DICT:
            for (int i = 0; i < v->data.dict.count; i++) {
                free(v->data.dict.keys[i]);
                val_decref(v->data.dict.vals[i]);
            }
            free(v->data.dict.keys);
            free(v->data.dict.vals);
            break;
        case VAL_FN:
            free(v->data.fn.name);
            for (int i = 0; i < v->data.fn.param_count; i++)
                free(v->data.fn.params[i]);
            free(v->data.fn.params);
            break;
        case VAL_BUFFER:
            free(v->data.buffer.data);
            break;
        default:
            break;
    }
    free(v);
}

Value* make_num(double n) {
    int from_arena = g_arena.active;
    Value *v;
    if (!from_arena && g_num_freelist) {
        v = g_num_freelist;
        memcpy(&g_num_freelist, &v->data, sizeof(Value *));
        g_num_freelist_count--;
        memset(v, 0, sizeof(Value));
    } else {
        v = from_arena ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    }
    v->type = VAL_NUM;
    v->data.num = n;
    v->refcount = 1;
    v->arena = from_arena;
    return v;
}

void recycle_intermediate(Value *v) {
    if (!v || v->type != VAL_NUM || v->arena || v->refcount > 1) return;
    if (g_num_freelist_count >= NUM_FREELIST_CAP) {
        free(v);
        return;
    }
    memcpy(&v->data, &g_num_freelist, sizeof(Value *));
    g_num_freelist = v;
    g_num_freelist_count++;
}

/* Heap-only make_num — for values that must outlive arena reset */
Value* make_num_permanent(double n) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_NUM;
    v->data.num = n;
    v->refcount = 1;
    v->arena = 0;
    return v;
}

Value* promote_if_arena(Value *v) {
    if (!v || !v->arena) return v;
    if (v->type == VAL_NUM) {
        Value *h = make_num_permanent(v->data.num);
        h->entropy = v->entropy;
        h->dH = v->dH;
        h->last_entropy = v->last_entropy;
        h->obs_age = v->obs_age;
        h->prev_dH = v->prev_dH;
        return h;
    }
    if (v->type == VAL_STR || v->type == VAL_JSON_RAW) {
        Value *h = xcalloc(1, sizeof(Value));
        h->type = v->type;
        h->data.str = xstrdup(v->data.str);
        h->refcount = 1;
        return h;
    }
    if (v->type == VAL_NULL) {
        Value *h = xcalloc(1, sizeof(Value));
        h->type = VAL_NULL;
        h->refcount = 1;
        return h;
    }
    /* Lists, dicts, functions: leave as-is (complex deep copy).
     * Callers should avoid storing arena-allocated complex types. */
    return v;
}

Value* make_str(const char *s) {
    int from_arena = g_arena.active;
    Value *v = from_arena ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_STR;
    v->data.str = xstrdup(s);
    if (from_arena) arena_track_string(v->data.str);
    v->refcount = 1;
    v->arena = from_arena;
    return v;
}

static Value g_null_singleton = { .type = VAL_NULL, .refcount = 1000000, .arena = 1 };

Value* make_null(void) {
    return &g_null_singleton;
}

Value* make_list(int capacity) {
    int from_arena = g_arena.active;
    Value *v = from_arena ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_LIST;
    v->data.list.capacity = capacity < 8 ? 8 : capacity;
    if (from_arena)
        v->data.list.items = arena_alloc(v->data.list.capacity * sizeof(Value*));
    else
        v->data.list.items = xcalloc(v->data.list.capacity, sizeof(Value*));
    v->data.list.count = 0;
    v->refcount = 1;
    v->arena = from_arena;
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
    v->refcount = 1;
    v->arena = 0;
    return v;
}

Value* make_builtin(BuiltinFn fn) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUILTIN;
    v->data.builtin = fn;
    v->refcount = 1;
    v->arena = 0;
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
    v->refcount = 1;
    v->arena = 0;
    return v;
}

void dict_set(Value *dict, const char *key, Value *val) {
    if (!dict || dict->type != VAL_DICT) return;
    /* Check if key exists */
    for (int i = 0; i < dict->data.dict.count; i++) {
        if (strcmp(dict->data.dict.keys[i], key) == 0) {
            Value *promoted = promote_if_arena(val);
            if (promoted != val) {
                val_decref(dict->data.dict.vals[i]);
                dict->data.dict.vals[i] = promoted;
            } else {
                val_incref(val);
                val_decref(dict->data.dict.vals[i]);
                dict->data.dict.vals[i] = val;
            }
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
    Value *promoted = promote_if_arena(val);
    dict->data.dict.vals[dict->data.dict.count] = promoted;
    if (promoted == val) val_incref(val);
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
            val_decref(dict->data.dict.vals[i]);
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
    val_incref(item);
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
        case VAL_BUFFER: return v->data.buffer.count > 0;
    }
    return 0;
}

static __thread int g_vts_depth = 0;

char* value_to_string(Value *v) {
    if (!v) return xstrdup("null");
    if (g_vts_depth > 64) return xstrdup("[...]");
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
            g_vts_depth++;
            for (int i = 0; i < v->data.list.count; i++) {
                if (i > 0) strbuf_append_n(&out, ", ", 2);
                char *s = value_to_string(v->data.list.items[i]);
                if (v->data.list.items[i] && v->data.list.items[i]->type == VAL_STR)
                    eigs_json_escape_string(&out, s);
                else
                    strbuf_append(&out, s);
                free(s);
            }
            g_vts_depth--;
            strbuf_append_char(&out, ']');
            return strbuf_finish(&out);
        }
        case VAL_FN: snprintf(buf, sizeof(buf), "<fn %s>", v->data.fn.name); return xstrdup(buf);
        case VAL_DICT: {
            strbuf out;
            strbuf_init(&out);
            strbuf_append_char(&out, '{');
            g_vts_depth++;
            for (int i = 0; i < v->data.dict.count; i++) {
                if (i > 0) strbuf_append_n(&out, ", ", 2);
                eigs_json_escape_string(&out, v->data.dict.keys[i]);
                strbuf_append_n(&out, ": ", 2);
                char *vs = value_to_string(v->data.dict.vals[i]);
                if (v->data.dict.vals[i] && v->data.dict.vals[i]->type == VAL_STR)
                    eigs_json_escape_string(&out, vs);
                else
                    strbuf_append(&out, vs);
                free(vs);
            }
            g_vts_depth--;
            strbuf_append_char(&out, '}');
            return strbuf_finish(&out);
        }
        case VAL_BUILTIN: return xstrdup("<builtin>");
        case VAL_JSON_RAW: return xstrdup(v->data.str);
        case VAL_BUFFER:
            snprintf(buf, sizeof(buf), "<buffer:%d>", v->data.buffer.count);
            return xstrdup(buf);
    }
    return xstrdup("?");
}

/* ================================================================
 * ENVIRONMENT
 * ================================================================ */

Env* env_new(Env *parent) {
    Env *e = xcalloc(1, sizeof(Env));
    e->parent = parent;
    e->count = 0;
    e->capacity = ENV_INIT_CAP;
    e->heap_allocated = 1;
    e->captured = 0;
    e->names  = xcalloc(ENV_INIT_CAP, sizeof(char *));
    e->values = xcalloc(ENV_INIT_CAP, sizeof(Value *));
    return e;
}

void env_set(Env *env, const char *name, Value *val) {
    Env *e = env;
    while (e) {
        for (int i = 0; i < e->count; i++) {
            if (strcmp(e->names[i], name) == 0) {
                Value *promoted = promote_if_arena(val);
                if (promoted != val) {
                    /* Arena value promoted to heap — env takes ownership */
                    val_decref(e->values[i]);
                    e->values[i] = promoted;
                } else {
                    val_incref(val);
                    val_decref(e->values[i]);
                    e->values[i] = val;
                }
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
            Value *promoted = promote_if_arena(val);
            if (promoted != val) {
                val_decref(env->values[i]);
                env->values[i] = promoted;
            } else {
                val_incref(val);
                val_decref(env->values[i]);
                env->values[i] = val;
            }
            return;
        }
    }
    if (env->count >= env->capacity) {
        int new_cap = env->capacity * 2;
        size_t nsz = new_cap * sizeof(char *);
        size_t vsz = new_cap * sizeof(Value *);
        if (g_arena.active && !env->heap_allocated) {
            char **nn  = arena_alloc(nsz);
            Value **nv = arena_alloc(vsz);
            memcpy(nn, env->names, env->count * sizeof(char *));
            memcpy(nv, env->values, env->count * sizeof(Value *));
            env->names  = nn;
            env->values = nv;
        } else {
            env->names  = realloc(env->names, nsz);
            env->values = realloc(env->values, vsz);
            if (!env->names || !env->values) {
                fprintf(stderr, "Out of memory growing env\n");
                exit(1);
            }
        }
        env->capacity = new_cap;
    }
    char *name_copy = xstrdup(name);
    if (g_arena.active && !env->heap_allocated) arena_track_string(name_copy);
    env->names[env->count] = name_copy;
    Value *promoted = promote_if_arena(val);
    env->values[env->count] = promoted;
    if (promoted == val) val_incref(val);
    /* promoted values start at refcount 1 — env takes ownership */
    env->count++;
}

void env_free(Env *env) {
    if (!env || !env->heap_allocated || env->captured) return;
    for (int i = 0; i < env->count; i++) {
        free(env->names[i]);
        if (env->values[i] && !env->values[i]->arena)
            val_decref(env->values[i]);
    }
    free(env->names);
    free(env->values);
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
 * HANDLE TABLE — opaque pointer indirection for Store/Thread/Channel
 * ================================================================ */

#include <pthread.h>

static struct {
    void      *ptr;
    HandleType type;
} g_handle_table[HANDLE_TABLE_SIZE];

static pthread_mutex_t g_handle_mutex = PTHREAD_MUTEX_INITIALIZER;
static int g_handle_next = 1; /* 0 reserved as invalid */

int handle_register(void *ptr, HandleType type) {
    pthread_mutex_lock(&g_handle_mutex);
    for (int i = 0; i < HANDLE_TABLE_SIZE; i++) {
        int idx = (g_handle_next + i) % HANDLE_TABLE_SIZE;
        if (idx == 0) continue;
        if (g_handle_table[idx].ptr == NULL) {
            g_handle_table[idx].ptr = ptr;
            g_handle_table[idx].type = type;
            g_handle_next = (idx + 1) % HANDLE_TABLE_SIZE;
            pthread_mutex_unlock(&g_handle_mutex);
            return idx;
        }
    }
    pthread_mutex_unlock(&g_handle_mutex);
    fprintf(stderr, "Error: handle table full\n");
    return -1;
}

void* handle_lookup(int id, HandleType type) {
    if (id <= 0 || id >= HANDLE_TABLE_SIZE) return NULL;
    pthread_mutex_lock(&g_handle_mutex);
    void *ptr = NULL;
    if (g_handle_table[id].ptr != NULL && g_handle_table[id].type == type)
        ptr = g_handle_table[id].ptr;
    pthread_mutex_unlock(&g_handle_mutex);
    return ptr;
}

void handle_release(int id) {
    if (id <= 0 || id >= HANDLE_TABLE_SIZE) return;
    pthread_mutex_lock(&g_handle_mutex);
    g_handle_table[id].ptr = NULL;
    pthread_mutex_unlock(&g_handle_mutex);
}

