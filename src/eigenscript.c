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
/* First syntax/parse error of the current tokenize+parse pass, captured
 * for consumers that can't see the parser's stderr (the LSP, which turns
 * it into a publishDiagnostics squiggle). Reset at the top of tokenize().
 * g_first_error_line is 1-based and 0 when no error has been recorded. */
__thread int g_first_error_line = 0;
__thread char g_first_error_msg[256] = "";

void eigs_record_first_error(int line, const char *msg) {
    if (g_first_error_line) return;   /* keep only the first */
    g_first_error_line = line;
    snprintf(g_first_error_msg, sizeof(g_first_error_msg), "%s", msg ? msg : "syntax error");
}
__thread int g_has_error = 0;
__thread int g_breaking = 0;
__thread int g_continuing = 0;

/* Multi-thread mode flag. Set to 1 by builtin_spawn before pthread_create
 * (and never reset). When 0, refcount sites use plain ++/-- instead of
 * __atomic_*_fetch — saves ~20 cycles per LOCK-prefixed RMW on x86.
 * Most workloads (DMG, MiniSat, Tidepool, REPL) never spawn. */
int g_vm_multithreaded = 0;

/* Set runtime error — captured by try/catch, or printed to stderr.
 * Inside try blocks, the error is silently captured.
 * Outside try blocks, it also prints to stderr. */
__thread int g_try_depth = 0;

/* Structured error payload: set by `throw` so catch can bind the thrown
 * value (dict/list/...) instead of a stringified copy. NULL for plain
 * runtime errors. Owned ref; consumed by vm_take_error_value, cleared
 * by eigs_clear_error_value on the uncaught path. */
__thread Value *g_error_value = NULL;

void eigs_clear_error_value(void) {
    if (g_error_value) {
        val_decref(g_error_value);
        g_error_value = NULL;
    }
}

/* Defined in vm.c; prints the live call stack for uncaught errors.
 * Safe to call when no VM is active (it no-ops). */
void vm_print_stack_trace(FILE *out);

void runtime_error(int line, const char *fmt, ...) {
    char tmp[3900];
    va_list args;
    va_start(args, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, args);
    va_end(args);
    /* Tolerate a trailing newline in the format (some call sites carried one
     * over from fprintf): the "Error line N:" frame and the stderr write add
     * their own, and a trailing \n would also leak into a caught error's text. */
    size_t _tl = strlen(tmp);
    if (_tl > 0 && tmp[_tl - 1] == '\n') tmp[_tl - 1] = '\0';
    snprintf(g_error_msg, sizeof(g_error_msg), "Error line %d: %s", line, tmp);
    g_has_error = 1;
    eigs_clear_error_value();   /* a new error supersedes any thrown value */
    if (g_try_depth == 0) {
        fprintf(stderr, "%s\n", g_error_msg);
        vm_print_stack_trace(stderr);
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
        case TOK_LOCAL: return "'local'";
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
        case TOK_AMP: return "'&'";
        case TOK_BITOR: return "'|'";
        case TOK_CARET: return "'^'";
        case TOK_SHL: return "'<<'";
        case TOK_SHR: return "'>>'";
        case TOK_TILDE: return "'~'";
        case TOK_PLUS_EQ: return "'+='";
        case TOK_MINUS_EQ: return "'-='";
        case TOK_STAR_EQ: return "'*='";
        case TOK_SLASH_EQ: return "'/='";
        case TOK_PERCENT_EQ: return "'%='";
        case TOK_AMP_EQ: return "'&='";
        case TOK_BITOR_EQ: return "'|='";
        case TOK_CARET_EQ: return "'^='";
        case TOK_SHL_EQ: return "'<<='";
        case TOK_SHR_EQ: return "'>>='";
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
        case VAL_TEXT_BUILDER: return "text_builder";
        default: return "?";
    }
}
/* g_global_env defined in main.c */

/* Arena allocator and free_weight_val are in arena.c */

/* Forward declarations for hash helpers (used by dict and env). */
uint32_t env_hash_name(const char *name);
static void env_hash_init(EnvHash *ht, int cap);
void env_hash_insert(EnvHash *ht, uint32_t h, int idx);
static void env_hash_rebuild(EnvHash *ht, char **names, int count);
static int env_hash_find(const EnvHash *ht, const char *name, uint32_t h, char **names);

/* ================================================================
 * VALUE CONSTRUCTORS
 * ================================================================ */

/* Recursively free a heap-allocated Value tree.
 * Skips arena-allocated values (v->arena flag). */
#define NUM_FREELIST_CAP 4096
static __thread Value *g_num_freelist = NULL;
static __thread int g_num_freelist_count = 0;

#define ENV_FREELIST_CAP 1024
#define ENV_FREELIST_MAX_BINDINGS 64
static __thread Env *g_env_freelist = NULL;
static __thread int g_env_freelist_count = 0;

#define ENV_NAME_INTERN_BUCKETS 4096
typedef struct EnvNameIntern {
    char *name;
    uint32_t hash;
    struct EnvNameIntern *next;
} EnvNameIntern;
static __thread EnvNameIntern *g_env_name_interns[ENV_NAME_INTERN_BUCKETS];

/* (debug counters removed) */

/* Refcount-aware teardown. Called by val_decref when refcount hits 0.
 * Children are val_decref'd (not recursively freed), so shared values
 * tracked by refcount elsewhere stay alive. Arena-owned memory is
 * skipped — it gets reclaimed by arena_reset. */
/* ---- Observer system (moved from eval.c) ---- */

static double compute_entropy_impl(Value *v, int depth) {
    if (!v || depth > 64) return 0.0;
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
            for (const char *c = v->data.str; *c; c++) { freq[(unsigned char)*c]++; len++; }
            if (len == 0) return 0.0;
            double h = 0.0;
            for (int i = 0; i < 256; i++) {
                if (freq[i] > 0) { double p = (double)freq[i] / len; h -= p * log2(p); }
            }
            return h;
        }
        case VAL_LIST: {
            if (v->data.list.count == 0) return 0.0;
            double sum = 0.0;
            for (int i = 0; i < v->data.list.count; i++)
                sum += compute_entropy_impl(v->data.list.items[i], depth + 1);
            return sum / v->data.list.count + log2(v->data.list.count + 1);
        }
        case VAL_DICT: {
            if (v->data.dict.count == 0) return 0.0;
            double sum = 0.0;
            for (int i = 0; i < v->data.dict.count; i++)
                sum += compute_entropy_impl(v->data.dict.vals[i], depth + 1);
            return sum / v->data.dict.count + log2(v->data.dict.count + 1);
        }
        case VAL_FN: return 1.0;
        case VAL_BUILTIN: return 0.0;
        case VAL_JSON_RAW: return 0.0;
        case VAL_BUFFER: return log2(v->data.buffer.count + 1);
        case VAL_TEXT_BUILDER: return log2((double)v->data.text_builder.len + 1.0);
    }
    return 0.0;
}

double compute_entropy(Value *v) { return compute_entropy_impl(v, 0); }

void update_observer(Value *v) {
    if (!v) return;
    double new_entropy = compute_entropy(v);
    v->prev_dH = v->dH;
    if (v->obs_age == 0) {
        /* First observation — no delta yet */
        v->dH = 0;
    } else {
        v->dH = new_entropy - v->last_entropy;
    }
    v->entropy = new_entropy;
    v->last_entropy = new_entropy;
    v->obs_age++;
    v->dirty = 0;
}

void observer_ensure_fresh(Value *v) {
    if (v && v->dirty) update_observer(v);
}

/* ---- Thread-local globals (moved from eval.c) ---- */
__thread Value *g_last_observer = NULL;
__thread Env *g_builtin_call_env = NULL;
__thread int g_unobserved_depth = 0;
__thread double g_obs_dh_zero  = 0.001;
__thread double g_obs_dh_small = 0.01;
__thread double g_obs_h_low    = 0.1;

void free_value(Value *v) {
    if (!v || v->arena) return;
    /* The observer holds a borrowed alias, not a ref. Freeing the value
     * it points at (e.g. `b is buffer of N` then `b is null` — the
     * rebind drops the last ref) left a dangling pointer that the next
     * loop-stall check / predicate / interrogative dereferenced; for
     * freelisted NUMs it silently read recycled data instead. */
    if (v == g_last_observer) g_last_observer = NULL;
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
            if (v->data.str) free(v->data.str);
            break;
        case VAL_LIST:
            for (int i = 0; i < v->data.list.count; i++)
                val_decref(v->data.list.items[i]);
            if (v->data.list.items)
                free(v->data.list.items);
            break;
        case VAL_DICT:
            for (int i = 0; i < v->data.dict.count; i++) {
                /* keys are interned (env_intern_name) — do not free */
                val_decref(v->data.dict.vals[i]);
            }
            free(v->data.dict.keys);
            free(v->data.dict.vals);
            free(v->data.dict.hash.hashes);
            free(v->data.dict.hash.indices);
            free(v->data.dict.hash.generations);
            break;
        case VAL_FN:
            free(v->data.fn.name);
            /* params[i] are interned (lifetime owned by intern map); only free the array. */
            free(v->data.fn.params);
            free(v->data.fn.param_hashes);
            if (v->data.fn.body_count != -1) {
                /* AST-based function — free body nodes */
                for (int i = 0; i < v->data.fn.body_count; i++)
                    free_ast(v->data.fn.body[i]);
                free(v->data.fn.body);
            }
            /* body_count == -1 means bytecode fn: body is a chunk ptr;
             * this fn holds a ref on it (taken in OP_CLOSURE). */
            if (v->data.fn.body_count == -1)
                chunk_decref((struct EigsChunk *)v->data.fn.body);
            {
                Env *clo = v->data.fn.closure;
                v->data.fn.closure = NULL;  /* break cycle before decrement */
                if (clo) {
                    int newrc;
                    if (__builtin_expect(g_vm_multithreaded, 0))
                        newrc = __atomic_sub_fetch(&clo->env_refcount, 1, __ATOMIC_ACQ_REL);
                    else
                        newrc = --clo->env_refcount;
                    if (newrc <= 0 && clo->captured) {
                        clo->captured = 0;
                        env_free(clo);
                    }
                }
            }
            break;
        case VAL_BUFFER:
            free(v->data.buffer.data);
            break;
        case VAL_TEXT_BUILDER:
            free(v->data.text_builder.data);
            break;
        default:
            break;
    }
    free(v);
}

Value* make_num(double n) {
    n = num_guard(n);
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
    n = num_guard(n);
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_NUM;
    v->data.num = n;
    v->refcount = 1;
    v->arena = 0;
    return v;
}

/* Forward decl of the VAL_NULL singleton — defined below near make_null. */
static Value g_null_singleton;

/* ---- NaN-boxing boundary shims ----
 *
 * make_tracked_num: heap-allocated VAL_NUM that survives arena reset.
 * Used when a previously-immediate slot must be promoted because the
 * binding becomes observer-tracked.
 */
Value* make_tracked_num(double n) {
    n = num_guard(n);
    Value *v;
    if (g_num_freelist) {
        v = g_num_freelist;
        memcpy(&g_num_freelist, &v->data, sizeof(Value *));
        g_num_freelist_count--;
        memset(v, 0, sizeof(Value));
    } else {
        v = xcalloc(1, sizeof(Value));
    }
    v->type = VAL_NUM;
    v->data.num = n;
    v->refcount = 1;
    v->arena = 0;
    return v;
}

/* slot_from_value: takes ownership of the input ref.
 *   - NULL or VAL_NULL singleton -> immediate null (input is borrowed)
 *   - VAL_NUM with no observer state -> immediate; input released
 *   - VAL_NUM with observer state -> TAG_TRACKED; ref transferred
 *   - any other type -> TAG_HEAP; ref transferred
 *
 * Arena-allocated VAL_NUM cannot be tracked (it would die at arena
 * reset). For Phase A's safety, an arena VAL_NUM with observer state
 * is promoted to heap via make_tracked_num.
 */
EigsSlot slot_from_value(Value *v) {
    if (!v || v->type == VAL_NULL) {
        if (v && !v->arena && v != &g_null_singleton) val_decref(v);
        return slot_null();
    }
    if (v->type == VAL_NUM) {
        if (v->obs_age == 0 && !v->dirty
            && v->entropy == 0.0 && v->dH == 0.0
            && v->last_entropy == 0.0 && v->prev_dH == 0.0) {
            double n = v->data.num;
            val_decref(v);
            return slot_from_num(n);
        }
        /* Observer-tracked number: must be heap so it survives arena reset. */
        if (v->arena) {
            Value *h = make_tracked_num(v->data.num);
            h->entropy = v->entropy;
            h->dH = v->dH;
            h->last_entropy = v->last_entropy;
            h->prev_dH = v->prev_dH;
            h->obs_age = v->obs_age;
            h->dirty = v->dirty;
            /* arena copy: nothing to decref */
            return slot_from_tracked(h);
        }
        return slot_from_tracked(v);
    }
    return slot_from_heap(v);
}

/* slot_to_value: produces a Value* the caller owns a ref to.
 *   - immediate number/bool -> make_num
 *   - immediate null -> g_null_singleton
 *   - heap/tracked pointer -> incref and return
 */
Value* slot_to_value(EigsSlot s) {
    if (slot_is_num(s)) return make_num(s.d);
    if (slot_is_null(s)) return &g_null_singleton;
    if (slot_is_bool(s)) return make_num(slot_as_bool(s) ? 1.0 : 0.0);
    if (slot_is_heap(s) || slot_is_tracked(s)) {
        Value *v = slot_as_ptr(s);
        val_incref(v);
        return v;
    }
    /* unknown tag: fall back to null */
    return &g_null_singleton;
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

Value* make_str_owned(char *s) {
    int from_arena = g_arena.active;
    Value *v = from_arena ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_STR;
    v->data.str = s;
    if (from_arena) arena_track_string(s);
    v->refcount = 1;
    v->arena = from_arena;
    return v;
}

static Value g_null_singleton = { .type = VAL_NULL, .refcount = 1000000, .arena = 1 };
/* forward decl resolved here */

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

Value* make_text_builder(void) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_TEXT_BUILDER;
    v->data.text_builder.cap = 256;
    v->data.text_builder.data = xmalloc(v->data.text_builder.cap);
    v->data.text_builder.data[0] = '\0';
    v->data.text_builder.len = 0;
    v->data.text_builder.parts = 0;
    v->refcount = 1;
    v->arena = 0;
    return v;
}

Value* make_fn(const char *name, char **params, int param_count, Env *closure) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_FN;
    v->data.fn.name = xstrdup(name);
    v->data.fn.params = xmalloc_array(param_count, sizeof(char*));
    v->data.fn.param_hashes = xmalloc_array(param_count, sizeof(uint32_t));
    v->data.fn.param_count = param_count;
    for (int i = 0; i < param_count; i++) {
        v->data.fn.params[i] = env_intern_name(params[i]);
        v->data.fn.param_hashes[i] = env_hash_name(params[i]);
    }
    /* AST bodies died with the tree-walking evaluator. OP_CLOSURE
     * overwrites body with the compiled chunk ptr and body_count with
     * the -1 bytecode sentinel right after this returns. */
    v->data.fn.body = NULL;
    v->data.fn.body_count = 0;
    v->data.fn.closure = closure;
    if (closure) {
        if (__builtin_expect(g_vm_multithreaded, 0))
            __atomic_add_fetch(&closure->env_refcount, 1, __ATOMIC_RELAXED);
        else
            closure->env_refcount++;
    }
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
    env_hash_init(&v->data.dict.hash, ENV_HASH_INIT_CAP);
    v->refcount = 1;
    v->arena = 0;
    return v;
}

void dict_set_hashed(Value *dict, const char *key, uint32_t h, Value *val) {
    if (!dict || dict->type != VAL_DICT) return;
    if (h == 0) h = env_hash_name(key);
    int idx = env_hash_find(&dict->data.dict.hash, key, h, dict->data.dict.keys);
    if (idx >= 0) {
        Value *promoted = promote_if_arena(val);
        if (promoted != val) {
            val_decref(dict->data.dict.vals[idx]);
            dict->data.dict.vals[idx] = promoted;
        } else {
            val_incref(val);
            val_decref(dict->data.dict.vals[idx]);
            dict->data.dict.vals[idx] = val;
        }
        return;
    }
    /* Grow if needed */
    if (dict->data.dict.count >= dict->data.dict.capacity) {
        int new_cap = dict->data.dict.capacity * 2;
        dict->data.dict.keys = xrealloc_array(dict->data.dict.keys, new_cap, sizeof(char*));
        dict->data.dict.vals = xrealloc_array(dict->data.dict.vals, new_cap, sizeof(Value*));
        dict->data.dict.capacity = new_cap;
    }
    dict->data.dict.keys[dict->data.dict.count] = env_intern_name(key);
    Value *promoted = promote_if_arena(val);
    dict->data.dict.vals[dict->data.dict.count] = promoted;
    if (promoted == val) val_incref(val);
    dict->data.dict.count++;
    if (dict->data.dict.count * 10 > (dict->data.dict.hash.mask + 1) * 7)
        env_hash_rebuild(&dict->data.dict.hash, dict->data.dict.keys, dict->data.dict.count);
    else
        env_hash_insert(&dict->data.dict.hash, h, dict->data.dict.count - 1);
}

void dict_set(Value *dict, const char *key, Value *val) {
    dict_set_hashed(dict, key, env_hash_name(key), val);
}

/* Adopting setter: dict_set increfs internally, so passing a freshly
 * made value directly strands its birth ref (one leaked Value per
 * call). This consumes the birth ref — use it whenever the caller
 * does not keep its own pointer to the value. */
void dict_set_owned(Value *dict, const char *key, Value *val) {
    dict_set(dict, key, val);
    val_decref(val);
}

Value* dict_get_hashed(Value *dict, const char *key, uint32_t h) {
    if (!dict || dict->type != VAL_DICT) return NULL;
    if (h == 0) h = env_hash_name(key);
    int idx = env_hash_find(&dict->data.dict.hash, key, h, dict->data.dict.keys);
    return (idx >= 0) ? dict->data.dict.vals[idx] : NULL;
}

Value* dict_get(Value *dict, const char *key) {
    return dict_get_hashed(dict, key, env_hash_name(key));
}

int env_hash_find_dict(Value *dict, const char *key, uint32_t h) {
    if (!dict || dict->type != VAL_DICT) return -1;
    return env_hash_find(&dict->data.dict.hash, key, h, dict->data.dict.keys);
}

int dict_has(Value *dict, const char *key) {
    return dict_get(dict, key) != NULL;
}

void dict_remove(Value *dict, const char *key) {
    if (!dict || dict->type != VAL_DICT) return;
    uint32_t h = env_hash_name(key);
    int idx = env_hash_find(&dict->data.dict.hash, key, h, dict->data.dict.keys);
    if (idx < 0) return;
    /* keys are interned — do not free */
    val_decref(dict->data.dict.vals[idx]);
    /* Shift remaining */
    for (int j = idx; j < dict->data.dict.count - 1; j++) {
        dict->data.dict.keys[j] = dict->data.dict.keys[j+1];
        dict->data.dict.vals[j] = dict->data.dict.vals[j+1];
    }
    dict->data.dict.count--;
    env_hash_rebuild(&dict->data.dict.hash, dict->data.dict.keys, dict->data.dict.count);
}

void list_append(Value *list, Value *item) {
    if (!list || list->type != VAL_LIST) return;
    if (list->data.list.count >= list->data.list.capacity) {
        int new_cap = list->data.list.capacity * 2;
        if (list->arena) {
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

/* Adopting append: list_append increfs internally, so appending a
 * freshly made value directly strands its birth ref (one leaked Value
 * per element). This consumes the birth ref — use it whenever the
 * caller does not keep its own pointer to the item. */
void list_append_owned(Value *list, Value *item) {
    list_append(list, item);
    val_decref(item);
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
        case VAL_TEXT_BUILDER: return v->data.text_builder.len > 0;
    }
    return 0;
}

/* Structural equality for `==` / `!=`.
 * Scalars compare by value (numbers, strings, null); collections compare
 * recursively by structure (lists element-wise, dicts by key/value
 * order-independently, buffers/text-builders by contents). Functions,
 * builtins, and raw-JSON compare by identity. Mixed types are never equal
 * (no coercion — consistent with the comparison operators). The depth
 * guard prevents runaway recursion on self-referential containers; beyond
 * it we fall back to identity. */
static int values_equal_impl(Value *a, Value *b, int depth) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    if (a->type != b->type) return 0;
    if (depth > 64) return a == b;
    switch (a->type) {
        case VAL_NUM:  return a->data.num == b->data.num;
        case VAL_STR:  return strcmp(a->data.str, b->data.str) == 0;
        case VAL_NULL: return 1;
        case VAL_LIST: {
            if (a->data.list.count != b->data.list.count) return 0;
            for (int i = 0; i < a->data.list.count; i++)
                if (!values_equal_impl(a->data.list.items[i],
                                       b->data.list.items[i], depth + 1))
                    return 0;
            return 1;
        }
        case VAL_DICT: {
            if (a->data.dict.count != b->data.dict.count) return 0;
            for (int i = 0; i < a->data.dict.count; i++) {
                Value *bv = dict_get(b, a->data.dict.keys[i]);
                if (!bv) return 0;
                if (!values_equal_impl(a->data.dict.vals[i], bv, depth + 1))
                    return 0;
            }
            return 1;
        }
        case VAL_BUFFER: {
            if (a->data.buffer.count != b->data.buffer.count) return 0;
            for (int i = 0; i < a->data.buffer.count; i++)
                if (a->data.buffer.data[i] != b->data.buffer.data[i]) return 0;
            return 1;
        }
        case VAL_TEXT_BUILDER:
            return a->data.text_builder.len == b->data.text_builder.len &&
                   memcmp(a->data.text_builder.data, b->data.text_builder.data,
                          a->data.text_builder.len) == 0;
        default: /* VAL_FN, VAL_BUILTIN, VAL_JSON_RAW — identity */
            return a == b;
    }
}

int values_equal(Value *a, Value *b) { return values_equal_impl(a, b, 0); }

static __thread int g_vts_depth = 0;

char* value_to_string(Value *v) {
    if (!v) return xstrdup("null");
    if (g_vts_depth > 64) return xstrdup("[...]");
    char buf[256];
    switch (v->type) {
        case VAL_NULL: return xstrdup("null");
        case VAL_NUM: {
            double n = v->data.num;
            /* Exact integers up to 2^53 (the largest integer all doubles
             * represent exactly) print without a decimal point or exponent. */
            if (n == (long long)n && fabs(n) < 9007199254740992.0) {
                snprintf(buf, sizeof(buf), "%lld", (long long)n);
            } else {
                /* Shortest representation that round-trips: try 15..17
                 * significant digits and stop at the first that parses back
                 * to the same double. %.6g (the old default) silently
                 * truncated every float to 6 figures — lossy for the
                 * numerical/STEM workloads this language targets. */
                for (int prec = 15; prec <= 17; prec++) {
                    snprintf(buf, sizeof(buf), "%.*g", prec, n);
                    if (strtod(buf, NULL) == n) break;
                }
            }
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
        case VAL_TEXT_BUILDER:
            return xstrdup(v->data.text_builder.data ? v->data.text_builder.data : "");
    }
    return xstrdup("?");
}

/* ================================================================
 * ENVIRONMENT
 * ================================================================ */

/* FNV-1a hash — fast, good distribution for short identifier strings.
 * Returns non-zero (zero is reserved as "empty slot" sentinel). */
uint32_t env_hash_name(const char *name) {
    uint32_t h = 2166136261u;
    for (const char *p = name; *p; p++)
        h = (h ^ (uint8_t)*p) * 16777619u;
    return h | 1;  /* ensure non-zero */
}

uint32_t env_name_hash(const char *name) {
    return env_hash_name(name);
}

static void env_hash_init(EnvHash *ht, int cap) {
    ht->mask = cap - 1;
    ht->hashes      = xmalloc_array(cap, sizeof(uint32_t));
    ht->indices     = xmalloc_array(cap, sizeof(int));
    ht->generations = xcalloc(cap, sizeof(uint32_t));  /* zero => empty (current gen starts at 1) */
    ht->generation  = 1;
    for (int i = 0; i < cap; i++) ht->indices[i] = -1;
}

void env_hash_insert(EnvHash *ht, uint32_t h, int idx) {
    int slot = h & ht->mask;
    uint32_t gen = ht->generation;
    while (ht->generations[slot] == gen) {
        slot = (slot + 1) & ht->mask;
    }
    ht->hashes[slot] = h;
    ht->indices[slot] = idx;
    ht->generations[slot] = gen;
}

static void env_hash_rebuild(EnvHash *ht, char **names, int count) {
    int new_cap = (ht->mask + 1) * 2;
    if (new_cap < ENV_HASH_INIT_CAP) new_cap = ENV_HASH_INIT_CAP;
    free(ht->hashes);
    free(ht->indices);
    free(ht->generations);
    env_hash_init(ht, new_cap);
    for (int i = 0; i < count; i++) {
        /* Skip slot-only entries (names[i] == NULL). Function envs interleave
         * compiler-assigned local slots (addressed by index, never in the
         * hash) with later SET_NAME_LOCAL appends (named, in the hash). The
         * rebuild must reinsert only the named entries — feeding env_hash_name
         * a NULL pointer crashes in strlen. */
        if (names[i]) env_hash_insert(ht, env_hash_name(names[i]), i);
    }
}

/* Lookup name in hash table. Returns index into names/values or -1.
 * Slot is "occupied" iff its generation matches the table's current gen.
 *
 * Fast path: when both the lookup name and stored name come from the
 * intern pool (env_intern_name), they're pointer-equal on match — no
 * strcmp needed. Falls back to strcmp for callers (e.g. dict.keys)
 * whose keys aren't routed through the intern pool. */
static int env_hash_find(const EnvHash *ht, const char *name, uint32_t h, char **names) {
    if (!ht->generations) return -1;
    int slot = h & ht->mask;
    uint32_t gen = ht->generation;
    while (ht->generations[slot] == gen) {
        if (ht->hashes[slot] == h) {
            const char *stored = names[ht->indices[slot]];
            if (stored == name || strcmp(stored, name) == 0)
                return ht->indices[slot];
        }
        slot = (slot + 1) & ht->mask;
    }
    return -1;
}

char *env_intern_name(const char *name) {
    uint32_t h = env_hash_name(name);
    int bucket = h & (ENV_NAME_INTERN_BUCKETS - 1);
    for (EnvNameIntern *it = g_env_name_interns[bucket]; it; it = it->next) {
        if (it->hash == h && strcmp(it->name, name) == 0)
            return it->name;
    }
    EnvNameIntern *it = xcalloc(1, sizeof(EnvNameIntern));
    it->name = xstrdup(name);
    it->hash = h;
    it->next = g_env_name_interns[bucket];
    g_env_name_interns[bucket] = it;
    return it->name;
}

Env* env_new(Env *parent) {
    Env *e = NULL;
    if (g_env_freelist) {
        e = g_env_freelist;
        g_env_freelist = e->parent;
        g_env_freelist_count--;
        e->count = 0;
        /* Generation already bumped in env_free's freelist branch.
         * Hash slots from the prior occupant are dormant by virtue of
         * generations[i] != current generation. */
    } else {
        e = xcalloc(1, sizeof(Env));
        e->capacity = ENV_INIT_CAP;
        e->names  = xcalloc(ENV_INIT_CAP, sizeof(char *));
        e->values = xcalloc(ENV_INIT_CAP, sizeof(EigsSlot));
        e->assign_counts = xcalloc(ENV_INIT_CAP, sizeof(int));
        env_hash_init(&e->hash, ENV_HASH_INIT_CAP);
    }
    e->parent = parent;
    e->heap_allocated = 1;
    e->captured = 0;
    e->env_refcount = 0;
    return e;
}

void env_set_hashed(Env *env, const char *name, uint32_t h, Value *val) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            Value *promoted = promote_if_arena(val);
            if (promoted == val) val_incref(promoted);
            EigsSlot new_s = slot_from_value(promoted);
            slot_decref(e->values[idx]);
            e->values[idx] = new_s;
            if (e->assign_counts && g_unobserved_depth == 0)
                e->assign_counts[idx]++;
            return;
        }
        e = e->parent;
    }
    env_set_local_hashed(env, name, h, val);
}

void env_set(Env *env, const char *name, Value *val) {
    env_set_hashed(env, name, env_hash_name(name), val);
}

void env_set_local_hashed(Env *env, const char *name, uint32_t h, Value *val) {
    if (h == 0) h = env_hash_name(name);
    int idx = env_hash_find(&env->hash, name, h, env->names);
    if (idx >= 0) {
        Value *promoted = promote_if_arena(val);
        if (promoted == val) val_incref(promoted);
        EigsSlot new_s = slot_from_value(promoted);
        slot_decref(env->values[idx]);
        env->values[idx] = new_s;
        if (env->assign_counts && g_unobserved_depth == 0)
            env->assign_counts[idx]++;
        return;
    }
    if (env->count >= env->capacity) {
        int new_cap = env->capacity * 2;
        size_t nsz = new_cap * sizeof(char *);
        size_t vsz = new_cap * sizeof(EigsSlot);
        if (!env->heap_allocated) {
            char **nn  = arena_alloc(nsz);
            EigsSlot *nv = arena_alloc(vsz);
            memcpy(nn, env->names, env->count * sizeof(char *));
            memcpy(nv, env->values, env->count * sizeof(EigsSlot));
            env->names  = nn;
            env->values = nv;
        } else {
            env->names  = realloc(env->names, nsz);
            env->values = realloc(env->values, vsz);
            env->assign_counts = realloc(env->assign_counts, new_cap * sizeof(int));
            if (!env->names || !env->values) {
                fprintf(stderr, "Out of memory growing env\n");
                exit(1);
            }
        }
        env->capacity = new_cap;
    }
    env->names[env->count] = env_intern_name(name);
    Value *promoted = promote_if_arena(val);
    if (promoted == val) val_incref(promoted);
    env->values[env->count] = slot_from_value(promoted);
    if (env->assign_counts)
        env->assign_counts[env->count] = (g_unobserved_depth == 0) ? 1 : 0;
    env->count++;
    env->binding_version++;

    /* Insert into hash; rebuild if load factor > 70% */
    if (env->count * 10 > (env->hash.mask + 1) * 7)
        env_hash_rebuild(&env->hash, env->names, env->count);
    else
        env_hash_insert(&env->hash, h, env->count - 1);
}

/* ---- Slot-flavored env helpers (Phase B-5 hot path) ----
 * env borrows the input slot and slot_incref's internally to take a ref.
 * Promotion: an arena-tracked pointer slot is materialized to heap via
 * slot_to_value + promote_if_arena to preserve the existing arena-safety
 * contract that env never holds arena Values across arena reset. */
void env_store_slot(Env *env, int idx, EigsSlot s) {
    if (slot_is_ptr(s)) {
        Value *v = slot_as_ptr(s);
        if (v && v->arena) {
            Value *promoted = promote_if_arena(v);
            if (promoted && promoted != v) {
                /* promoted is fresh (refcount=1); env takes it. */
                EigsSlot new_s = slot_from_value(promoted);
                slot_decref(env->values[idx]);
                env->values[idx] = new_s;
                return;
            }
        }
    }
    slot_incref(s);
    slot_decref(env->values[idx]);
    env->values[idx] = s;
}

void env_set_hashed_slot(Env *env, const char *name, uint32_t h, EigsSlot s) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            env_store_slot(e, idx, s);
            if (e->assign_counts && g_unobserved_depth == 0)
                e->assign_counts[idx]++;
            return;
        }
        e = e->parent;
    }
    env_set_local_hashed_slot(env, name, h, s);
}

/* Core local-set implementation: caller has already interned `name`. */
void env_set_local_pre_interned_slot(Env *env, const char *interned,
                                     uint32_t h, EigsSlot s) {
    int idx = env_hash_find(&env->hash, interned, h, env->names);
    if (idx >= 0) {
        env_store_slot(env, idx, s);
        if (env->assign_counts && g_unobserved_depth == 0)
            env->assign_counts[idx]++;
        return;
    }
    if (env->count >= env->capacity) {
        int new_cap = env->capacity * 2;
        size_t nsz = new_cap * sizeof(char *);
        size_t vsz = new_cap * sizeof(EigsSlot);
        if (!env->heap_allocated) {
            char **nn = arena_alloc(nsz);
            EigsSlot *nv = arena_alloc(vsz);
            memcpy(nn, env->names, env->count * sizeof(char *));
            memcpy(nv, env->values, env->count * sizeof(EigsSlot));
            env->names = nn;
            env->values = nv;
        } else {
            env->names = realloc(env->names, nsz);
            env->values = realloc(env->values, vsz);
            env->assign_counts = realloc(env->assign_counts, new_cap * sizeof(int));
            if (!env->names || !env->values) {
                fprintf(stderr, "Out of memory growing env\n");
                exit(1);
            }
        }
        env->capacity = new_cap;
    }
    env->names[env->count] = (char*)interned;
    EigsSlot stored = s;
    if (slot_is_ptr(s)) {
        Value *v = slot_as_ptr(s);
        if (v && v->arena) {
            Value *promoted = promote_if_arena(v);
            if (promoted && promoted != v) {
                stored = slot_from_value(promoted);
                goto store;
            }
        }
    }
    slot_incref(s);
store:
    env->values[env->count] = stored;
    if (env->assign_counts)
        env->assign_counts[env->count] = (g_unobserved_depth == 0) ? 1 : 0;
    env->count++;
    env->binding_version++;
    if (env->count * 10 > (env->hash.mask + 1) * 7)
        env_hash_rebuild(&env->hash, env->names, env->count);
    else
        env_hash_insert(&env->hash, h, env->count - 1);
}

void env_set_local_hashed_slot(Env *env, const char *name, uint32_t h, EigsSlot s) {
    if (h == 0) h = env_hash_name(name);
    env_set_local_pre_interned_slot(env, env_intern_name(name), h, s);
}

/* Bind a parameter into a freshly-created call env. Caller guarantees:
 *   - env was just returned by env_new (heap_allocated=1, count=N with N<param)
 *   - `interned` came from env_intern_name (or VAL_FN.params, now interned)
 *   - the param name does not collide with any earlier param in this env
 *     (compiler rejects duplicate params)
 * Skips env_hash_find. */
void env_bind_fresh_param_slot(Env *env, const char *interned,
                               uint32_t h, EigsSlot s) {
    if (env->count >= env->capacity) {
        int new_cap = env->capacity * 2;
        size_t nsz = new_cap * sizeof(char *);
        size_t vsz = new_cap * sizeof(EigsSlot);
        env->names = realloc(env->names, nsz);
        env->values = realloc(env->values, vsz);
        env->assign_counts = realloc(env->assign_counts, new_cap * sizeof(int));
        if (!env->names || !env->values) {
            fprintf(stderr, "Out of memory growing env\n");
            exit(1);
        }
        env->capacity = new_cap;
    }
    env->names[env->count] = (char*)interned;
    EigsSlot stored = s;
    if (slot_is_ptr(s)) {
        Value *v = slot_as_ptr(s);
        if (v && v->arena) {
            Value *promoted = promote_if_arena(v);
            if (promoted && promoted != v) {
                stored = slot_from_value(promoted);
                goto store;
            }
        }
    }
    slot_incref(s);
store:
    env->values[env->count] = stored;
    if (env->assign_counts) env->assign_counts[env->count] = 1;
    env->count++;
    env->binding_version++;
    if (env->count * 10 > (env->hash.mask + 1) * 7)
        env_hash_rebuild(&env->hash, env->names, env->count);
    else
        env_hash_insert(&env->hash, h, env->count - 1);
}

/* Walk the env chain for `name`. On hit, returns target env, slot index in
 * that env, and depth (0 = starting env, 1 = parent, ...). On miss, returns
 * NULL. Used by VM IC populate path so we don't re-walk to discover depth. */
Env *env_resolve_chain(Env *start, const char *name, uint32_t h,
                       int *out_slot, int *out_depth) {
    if (h == 0) h = env_hash_name(name);
    Env *e = start;
    int depth = 0;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            if (out_slot)  *out_slot  = idx;
            if (out_depth) *out_depth = depth;
            return e;
        }
        e = e->parent;
        depth++;
    }
    return NULL;
}

EigsSlot env_get_hashed_slot(Env *env, const char *name, uint32_t h, int *found) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            if (found) *found = 1;
            return e->values[idx];
        }
        e = e->parent;
    }
    if (found) *found = 0;
    return slot_null();
}

int env_get_assign_count(Env *env, const char *name, uint32_t h) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) return e->assign_counts ? e->assign_counts[idx] : 0;
        e = e->parent;
    }
    return 0;
}

void env_set_local(Env *env, const char *name, Value *val) {
    env_set_local_hashed(env, name, env_hash_name(name), val);
}

/* Adopting setter for registration code. env_set_local increfs the
 * value internally, so passing a freshly made value directly strands
 * its birth ref — every builtin used to sit at refcount 2 with a
 * single owner, unfreeable by any teardown. This consumes the birth
 * ref so the env holds the only reference. */
void env_set_local_owned(Env *env, const char *name, Value *val) {
    env_set_local(env, name, val);
    val_decref(val);
}

void env_free(Env *env) {
    if (!env || !env->heap_allocated) return;
    if (env->captured) {
        int rc = __builtin_expect(g_vm_multithreaded, 0)
            ? __atomic_load_n(&env->env_refcount, __ATOMIC_ACQUIRE)
            : env->env_refcount;
        if (rc > 0) return;
    }
    for (int i = 0; i < env->count; i++) {
        slot_decref(env->values[i]);
    }
    if (env->capacity <= ENV_FREELIST_MAX_BINDINGS &&
        g_env_freelist_count < ENV_FREELIST_CAP) {
        env->count = 0;
        env->captured = 0;
        env->env_refcount = 0;
        env->binding_version++; /* invalidate VM inline caches */
        /* O(1) invalidation: bump generation. On wrap, fall back to a
         * full reset (every ~4 billion env reuses on this thread). */
        if (++env->hash.generation == 0) {
            memset(env->hash.generations, 0,
                   (env->hash.mask + 1) * sizeof(uint32_t));
            env->hash.generation = 1;
        }
        env->parent = g_env_freelist;
        g_env_freelist = env;
        g_env_freelist_count++;
        return;
    }
    free(env->names);
    free(env->values);
    free(env->assign_counts);
    free(env->hash.hashes);
    free(env->hash.indices);
    free(env->hash.generations);
    free(env);
}

/* Shutdown-only teardown for the global env.
 *
 * env_free is refcount-honest: it no-ops while closures still hold the
 * env (env_refcount > 0). At process exit that politeness leaks the
 * whole global scope whenever a script defined a function, because the
 * fn value lives *in* the env that it captures — a cycle nothing else
 * breaks. Force the issue: detach the slot array first so reentrant
 * env_free calls (a dying closure decrementing env_refcount mid-loop)
 * see an empty env, pin env_refcount high so those calls cannot free
 * the struct under us, then decref every binding and free the arrays
 * unconditionally. Only call this when nothing will touch the env
 * again — i.e. immediately before exit, after trace_shutdown has
 * dropped its own value refs. */
void env_destroy_final(Env *env) {
    if (!env || !env->heap_allocated) return;
    EigsSlot *vals = env->values;
    int count = env->count;
    env->values = NULL;
    env->count = 0;
    env->captured = 1;
    env->env_refcount = 1 << 30;
    for (int i = 0; i < count; i++)
        slot_decref(vals[i]);
    free(vals);
    free(env->names);
    free(env->assign_counts);
    free(env->hash.hashes);
    free(env->hash.indices);
    free(env->hash.generations);
    free(env);
}

void env_reserve_slots(Env *env, int total) {
    if (!env || total <= env->count) return;
    /* Grow capacity if needed. Mirrors env_set_local_hashed's grow path
     * for heap_allocated envs. Call-time envs are always heap-allocated
     * (env_new sets heap_allocated=1). */
    if (total > env->capacity) {
        int new_cap = env->capacity ? env->capacity : ENV_INIT_CAP;
        while (new_cap < total) new_cap *= 2;
        size_t nsz = new_cap * sizeof(char *);
        size_t vsz = new_cap * sizeof(EigsSlot);
        if (env->heap_allocated) {
            env->names  = realloc(env->names,  nsz);
            env->values = realloc(env->values, vsz);
            env->assign_counts = realloc(env->assign_counts, new_cap * sizeof(int));
            if (!env->names || !env->values || !env->assign_counts) {
                fprintf(stderr, "Out of memory growing env\n");
                exit(1);
            }
        } else {
            char **nn  = arena_alloc(nsz);
            EigsSlot *nv = arena_alloc(vsz);
            memcpy(nn, env->names,  env->count * sizeof(char *));
            memcpy(nv, env->values, env->count * sizeof(EigsSlot));
            env->names  = nn;
            env->values = nv;
        }
        env->capacity = new_cap;
    }
    /* Zero new slots: names NULL, values immediate-null, assign_counts 0.
     * Non-captured local slots aren't hash-inserted — they're addressed
     * purely by slot index via OP_GET_LOCAL/OP_SET_LOCAL. */
    for (int i = env->count; i < total; i++) {
        env->names[i]  = NULL;
        env->values[i] = slot_null();
        if (env->assign_counts) env->assign_counts[i] = 0;
    }
    env->count = total;
}

void env_clear(Env *env) {
    if (!env) return;
    for (int i = 0; i < env->count; i++) {
        slot_decref(env->values[i]);
    }
    env->count = 0;
    env->binding_version++;
    if (++env->hash.generation == 0) {
        memset(env->hash.generations, 0,
               (env->hash.mask + 1) * sizeof(uint32_t));
        env->hash.generation = 1;
    }
}

Value* env_get_hashed(Env *env, const char *name, uint32_t h) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            EigsSlot s = e->values[idx];
            if (slot_is_ptr(s)) return slot_as_ptr(s);
            /* immediate — materialize a borrowed Value* in the env slot
             * itself so the returned pointer's lifetime matches the slot.
             * This mirrors the legacy semantics where env owned the ref. */
            Value *v = slot_to_value(s);
            slot_decref(e->values[idx]);  /* drop immediate (no-op) */
            e->values[idx] = slot_from_heap(v);  /* env now owns v */
            return v;
        }
        e = e->parent;
    }
    return NULL;
}

Value* env_get_local_hashed(Env *env, const char *name, uint32_t h) {
    if (!env) return NULL;
    if (h == 0) h = env_hash_name(name);
    int idx = env_hash_find(&env->hash, name, h, env->names);
    if (idx >= 0) {
        EigsSlot s = env->values[idx];
        if (slot_is_ptr(s)) return slot_as_ptr(s);
        Value *v = slot_to_value(s);
        slot_decref(env->values[idx]);
        env->values[idx] = slot_from_heap(v);
        return v;
    }
    return NULL;
}

Value* env_get(Env *env, const char *name) {
    return env_get_hashed(env, name, env_hash_name(name));
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
