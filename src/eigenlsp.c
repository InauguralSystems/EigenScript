/*
 * EigenScript Language Server Protocol (LSP) server.
 * Single-file implementation: JSON-RPC transport, document cache,
 * symbol table, and LSP method handlers.
 *
 * Reads JSON-RPC on stdin, writes responses on stdout, logs to stderr.
 * Reuses the existing lexer.c / parser.c for tokenization and parsing.
 */

#include "eigenscript.h"
#include "state.h"
#include <pthread.h>

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "0.9.0"
#endif

/* ---- Forward declarations for functions in other compilation units ---- */
extern const char* tok_type_name(TokType t);
extern void free_tokenlist(TokenList *tl);

/* ================================================================
 * BUILTIN DOCUMENTATION TABLE
 * ================================================================ */

static const char *builtin_docs[][2] = {
    {"print", "print of value -- write value to stdout"},
    {"len", "len of value -- length of string, list, or dict"},
    {"append", "append of [list, value] -- add element to end of list"},
    {"type", "type of value -- returns type name (\"num\", \"str\", \"list\", \"dict\", \"fn\", \"null\")"},
    {"range", "range of n -- list [0, 1, ..., n-1]; range of [start, end] or [start, end, step]"},
    {"str", "str of value -- convert to string"},
    {"num", "num of value -- convert to number"},
    {"keys", "keys of dict -- list of key names"},
    {"values", "values of dict -- list of values"},
    {"has_key", "has_key of [dict, key] -- 1 if key exists, 0 otherwise"},
    {"dict_set", "dict_set of [dict, key, value] -- set key in dict"},
    {"floor", "floor of n -- round down"},
    {"ceil", "ceil of n -- round up"},
    {"round", "round of n -- round to nearest integer"},
    {"abs", "abs of n -- absolute value"},
    {"min", "min of [a, b] -- smaller value"},
    {"max", "max of [a, b] -- larger value"},
    {"sqrt", "sqrt of n -- square root"},
    {"sin", "sin of n -- sine"},
    {"cos", "cos of n -- cosine"},
    {"split", "split of [string, delimiter] -- split string into list"},
    {"scan_ints", "scan_ints of text or [text, comment_marker] -- scan whitespace-delimited signed integers"},
    {"scan_tokens", "scan_tokens of text or [text, comment_marker] -- scan whitespace-delimited token spans"},
    {"scan_int_tokens", "scan_int_tokens of text or [text, comment_marker] -- token spans with integer classification"},
    {"join", "join of [list, separator] -- join list into string"},
    {"text_builder_new", "text_builder_new of null -- create a native growable text builder"},
    {"text_builder_append", "text_builder_append of [builder, value] -- append value as text"},
    {"text_builder_append_line", "text_builder_append_line of [builder, value] -- append value and newline"},
    {"text_builder_extend", "text_builder_extend of [builder, values] -- append each list item as text"},
    {"text_builder_part_count", "text_builder_part_count of builder -- number of appended parts"},
    {"text_builder_clear", "text_builder_clear of builder -- clear builder contents"},
    {"text_builder_to_string", "text_builder_to_string of builder -- render builder text"},
    {"trim", "trim of string -- strip whitespace"},
    {"contains", "contains of [string, substring] -- 1 if found"},
    {"substr", "substr of [string, start, length] -- extract substring"},
    {"index_of", "index_of of [string, substring] -- first index or -1"},
    {"str_replace", "str_replace of [string, old, new] -- replace all occurrences"},
    {"read_text", "read_text of path -- read file as string"},
    {"write_text", "write_text of [path, text] -- write string to file"},
    {"file_exists", "file_exists of path -- 1 if file exists"},
    {"json_encode", "json_encode of value -- encode as JSON string"},
    {"json_decode", "json_decode of string -- parse JSON to value"},
    {"spawn", "spawn of fn -- create thread running function, returns handle"},
    {"thread_join", "thread_join of handle -- block until thread completes, returns result"},
    {"channel", "channel of null -- create bounded message channel"},
    {"send", "send of [channel, value] -- send value into channel"},
    {"recv", "recv of channel -- receive value from channel"},
    {"store_open", "store_open of path -- open/create EigenStore database"},
    {"store_put", "store_put of [db, collection, record] -- insert record, returns key"},
    {"store_get", "store_get of [db, collection, key] -- get record by key"},
    {"store_query", "store_query of [db, collection] -- get all records"},
    {"store_close", "store_close of db -- close database"},
    {"assert", "assert of value -- abort if value is falsy"},
    {"observe", "observe of var -- snapshot entropy report"},
    {"report", "report of var -- return entropy state as string"},
    {"sort", "sort of list -- sort list in ascending order"},
    {"reverse", "reverse of list -- reverse list"},
    {"map", "map of [fn, list] -- apply fn to each element"},
    {"filter", "filter of [fn, list] -- keep elements where fn returns truthy"},
    {"reduce", "reduce of [fn, initial, list] -- fold list with fn"},
    {"exec", "exec of command -- run shell command, return stdout"},
    {"exit", "exit of code -- exit process with code"},
    {"time", "time of null -- seconds since epoch"},
    {"sleep", "sleep of seconds -- pause execution"},
    {"random", "random of null -- random float in [0,1)"},
    {"input", "input of prompt -- read line from stdin"},
    {"eval", "eval of string -- evaluate EigenScript code string"},
    {NULL, NULL}
};

/* ---- Keyword descriptions for hover ---- */
static const char *keyword_docs[][2] = {
    {"is", "Assignment operator: name is value"},
    {"of", "Function application: fn of arg"},
    {"define", "Function definition: define name(params) as:"},
    {"as", "Part of function definition syntax"},
    {"if", "Conditional: if condition:"},
    {"else", "Else branch: else:"},
    {"elif", "Else-if branch: elif condition:"},
    {"loop", "Loop: loop while condition:"},
    {"while", "Loop modifier: loop while condition:"},
    {"for", "For loop: for var in iterable:"},
    {"in", "Membership / iteration: for x in list"},
    {"return", "Return value from function"},
    {"and", "Logical AND"},
    {"or", "Logical OR"},
    {"not", "Logical NOT"},
    {"null", "Null value"},
    {"try", "Exception handling: try:"},
    {"catch", "Exception handler: catch err:"},
    {"break", "Exit loop"},
    {"continue", "Skip to next iteration"},
    {"import", "Import module: import name"},
    {"match", "Pattern matching: match expr:"},
    {"case", "Match case: case pattern:"},
    {"unobserved", "Unobserved block (suppresses entropy tracking)"},
    {"true", "Boolean true (1)"},
    {"false", "Boolean false (0)"},
    {NULL, NULL}
};

/* ================================================================
 * SYMBOL TABLE
 * ================================================================ */

typedef enum { SYM_VAR, SYM_FUNC, SYM_PARAM, SYM_IMPORT } SymKind;

typedef struct {
    char name[256];
    SymKind kind;
    int line, col;
    char params[16][64];
    int param_count;
    int scope_depth;
} Symbol;

#define MAX_SYMBOLS 2048

/* ================================================================
 * DOCUMENT CACHE
 * ================================================================ */

typedef struct {
    char uri[4096];
    char *text;
    int text_len;
    TokenList tokens;
    ASTNode *ast;
    Symbol symbols[MAX_SYMBOLS];
    int symbol_count;
} Document;

#define MAX_DOCS 64
static Document g_docs[MAX_DOCS];
static int g_doc_count = 0;
static int g_shutdown = 0;

/* ================================================================
 * JSON HELPERS (minimal, for LSP message parsing/generation)
 * ================================================================ */

/* Extract a string value for a given key from a JSON object.
 * Returns a malloc'd string, or NULL if not found. */
static char* json_get_string(const char *json, const char *key) {
    char pattern[512];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    while (*p == ' ' || *p == ':' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != '"') return NULL;
    p++;
    strbuf sb;
    strbuf_init(&sb);
    while (*p && *p != '"') {
        if (*p == '\\' && *(p+1)) {
            p++;
            switch (*p) {
                case 'n': strbuf_append_char(&sb, '\n'); break;
                case 't': strbuf_append_char(&sb, '\t'); break;
                case '\\': strbuf_append_char(&sb, '\\'); break;
                case '"': strbuf_append_char(&sb, '"'); break;
                case '/': strbuf_append_char(&sb, '/'); break;
                default: strbuf_append_char(&sb, '\\'); strbuf_append_char(&sb, *p); break;
            }
        } else {
            strbuf_append_char(&sb, *p);
        }
        p++;
    }
    return strbuf_finish(&sb);
}

/* Extract an integer value for a given key. Returns -1 if not found. */
static int json_get_int(const char *json, const char *key) {
    char pattern[512];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return -1;
    p += strlen(pattern);
    while (*p == ' ' || *p == ':' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p == '-' || isdigit((unsigned char)*p)) return atoi(p);
    return -1;
}

/* Extract a JSON sub-object for a given key. Returns malloc'd string. */
static char* json_get_object(const char *json, const char *key) {
    char pattern[512];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    const char *p = strstr(json, pattern);
    if (!p) return NULL;
    p += strlen(pattern);
    while (*p == ' ' || *p == ':' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != '{') return NULL;
    int depth = 0;
    const char *start = p;
    while (*p) {
        if (*p == '{') depth++;
        else if (*p == '}') { depth--; if (depth == 0) { p++; break; } }
        else if (*p == '"') { p++; while (*p && *p != '"') { if (*p == '\\') p++; p++; } }
        p++;
    }
    int len = (int)(p - start);
    char *result = xmalloc(len + 1);
    memcpy(result, start, len);
    result[len] = '\0';
    return result;
}

/* Escape a string for JSON output */
static void json_escape_to(strbuf *sb, const char *s) {
    strbuf_append_char(sb, '"');
    while (*s) {
        switch (*s) {
            case '"': strbuf_append(sb, "\\\""); break;
            case '\\': strbuf_append(sb, "\\\\"); break;
            case '\n': strbuf_append(sb, "\\n"); break;
            case '\r': strbuf_append(sb, "\\r"); break;
            case '\t': strbuf_append(sb, "\\t"); break;
            default:
                if ((unsigned char)*s < 0x20) {
                    char esc[8];
                    snprintf(esc, sizeof(esc), "\\u%04x", (unsigned char)*s);
                    strbuf_append(sb, esc);
                } else {
                    strbuf_append_char(sb, *s);
                }
                break;
        }
        s++;
    }
    strbuf_append_char(sb, '"');
}

/* ================================================================
 * LSP TRANSPORT
 * ================================================================ */

/* Send a raw JSON string with Content-Length header to stdout */
static void lsp_send(const char *json) {
    int len = (int)strlen(json);
    fprintf(stdout, "Content-Length: %d\r\n\r\n%s", len, json);
    fflush(stdout);
    fprintf(stderr, "[LSP] >>> %.*s\n", len > 200 ? 200 : len, json);
}

/* Send a JSON-RPC response */
static void lsp_response(int id, const char *result_json) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_fmt(&sb, "{\"jsonrpc\":\"2.0\",\"id\":%d,\"result\":%s}", id, result_json);
    lsp_send(sb.data);
    strbuf_free(&sb);
}

/* Send a JSON-RPC notification */
static void lsp_notification(const char *method, const char *params_json) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"jsonrpc\":\"2.0\",\"method\":\"");
    strbuf_append(&sb, method);
    strbuf_append(&sb, "\",\"params\":");
    strbuf_append(&sb, params_json);
    strbuf_append_char(&sb, '}');
    lsp_send(sb.data);
    strbuf_free(&sb);
}

/* Send a JSON-RPC error response */
static void lsp_error(int id, int code, const char *message) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_fmt(&sb,
        "{\"jsonrpc\":\"2.0\",\"id\":%d,\"error\":{\"code\":%d,\"message\":\"%s\"}}",
        id, code, message);
    lsp_send(sb.data);
    strbuf_free(&sb);
}

/* Send a null result */
static void lsp_response_null(int id) {
    lsp_response(id, "null");
}

/* Read a full LSP message from stdin. Returns malloc'd JSON, or NULL on EOF. */
static char* lsp_read_message(void) {
    /* Read headers until \r\n\r\n */
    int content_length = -1;
    char header_line[1024];

    while (1) {
        if (!fgets(header_line, sizeof(header_line), stdin)) return NULL;
        /* Blank line (just \r\n) signals end of headers */
        if (strcmp(header_line, "\r\n") == 0 || strcmp(header_line, "\n") == 0) break;
        if (strncmp(header_line, "Content-Length:", 15) == 0) {
            content_length = atoi(header_line + 15);
        }
    }

    if (content_length <= 0) return NULL;

    char *body = xmalloc(content_length + 1);
    int total_read = 0;
    while (total_read < content_length) {
        int n = (int)fread(body + total_read, 1, content_length - total_read, stdin);
        if (n <= 0) { free(body); return NULL; }
        total_read += n;
    }
    body[content_length] = '\0';
    fprintf(stderr, "[LSP] <<< %.*s\n", content_length > 200 ? 200 : content_length, body);
    return body;
}

/* ================================================================
 * DOCUMENT MANAGEMENT
 * ================================================================ */

static Document* doc_find(const char *uri) {
    for (int i = 0; i < g_doc_count; i++) {
        if (strcmp(g_docs[i].uri, uri) == 0) return &g_docs[i];
    }
    return NULL;
}

static Document* doc_create(const char *uri) {
    if (g_doc_count >= MAX_DOCS) {
        fprintf(stderr, "[LSP] too many open documents\n");
        return NULL;
    }
    Document *doc = &g_docs[g_doc_count++];
    memset(doc, 0, sizeof(Document));
    snprintf(doc->uri, sizeof(doc->uri), "%s", uri);
    return doc;
}

static void doc_remove(const char *uri) {
    for (int i = 0; i < g_doc_count; i++) {
        if (strcmp(g_docs[i].uri, uri) == 0) {
            if (g_docs[i].text) free(g_docs[i].text);
            if (g_docs[i].tokens.tokens) free_tokenlist(&g_docs[i].tokens);
            if (g_docs[i].ast) free_ast(g_docs[i].ast);
            /* Shift remaining */
            for (int j = i; j < g_doc_count - 1; j++) {
                g_docs[j] = g_docs[j + 1];
            }
            g_doc_count--;
            return;
        }
    }
}

/* ---- AST Walking: Build symbol table ---- */

static void walk_ast_symbols(ASTNode *node, Symbol *symbols, int *count, int depth) {
    if (!node || *count >= MAX_SYMBOLS) return;

    switch (node->type) {
        case AST_FUNC: {
            Symbol *s = &symbols[(*count)++];
            snprintf(s->name, sizeof(s->name), "%s", node->data.func.name ? node->data.func.name : "");
            s->kind = SYM_FUNC;
            s->line = node->line;
            s->col = node->col;
            s->param_count = node->data.func.param_count;
            for (int i = 0; i < node->data.func.param_count && i < 16; i++) {
                snprintf(s->params[i], sizeof(s->params[i]), "%s",
                         node->data.func.params[i] ? node->data.func.params[i] : "");
            }
            s->scope_depth = depth;
            /* Add params as symbols */
            for (int i = 0; i < node->data.func.param_count && *count < MAX_SYMBOLS; i++) {
                Symbol *ps = &symbols[(*count)++];
                snprintf(ps->name, sizeof(ps->name), "%s",
                         node->data.func.params[i] ? node->data.func.params[i] : "");
                ps->kind = SYM_PARAM;
                ps->line = node->line;
                ps->col = node->col;
                ps->param_count = 0;
                ps->scope_depth = depth + 1;
            }
            /* Walk body */
            for (int i = 0; i < node->data.func.body_count; i++) {
                walk_ast_symbols(node->data.func.body[i], symbols, count, depth + 1);
            }
            break;
        }
        case AST_ASSIGN: {
            Symbol *s = &symbols[(*count)++];
            snprintf(s->name, sizeof(s->name), "%s", node->data.assign.name ? node->data.assign.name : "");
            s->kind = SYM_VAR;
            s->line = node->line;
            s->col = node->col;
            s->param_count = 0;
            s->scope_depth = depth;
            if (node->data.assign.expr)
                walk_ast_symbols(node->data.assign.expr, symbols, count, depth);
            break;
        }
        case AST_IMPORT: {
            Symbol *s = &symbols[(*count)++];
            snprintf(s->name, sizeof(s->name), "%s", node->data.import.module_name ? node->data.import.module_name : "");
            s->kind = SYM_IMPORT;
            s->line = node->line;
            s->col = node->col;
            s->param_count = 0;
            s->scope_depth = depth;
            break;
        }
        case AST_FOR: {
            Symbol *s = &symbols[(*count)++];
            snprintf(s->name, sizeof(s->name), "%s", node->data.forloop.var ? node->data.forloop.var : "");
            s->kind = SYM_VAR;
            s->line = node->line;
            s->col = node->col;
            s->param_count = 0;
            s->scope_depth = depth + 1;
            if (node->data.forloop.iter)
                walk_ast_symbols(node->data.forloop.iter, symbols, count, depth);
            for (int i = 0; i < node->data.forloop.body_count; i++) {
                walk_ast_symbols(node->data.forloop.body[i], symbols, count, depth + 1);
            }
            break;
        }
        case AST_IF:
            walk_ast_symbols(node->data.cond.cond, symbols, count, depth);
            for (int i = 0; i < node->data.cond.if_count; i++)
                walk_ast_symbols(node->data.cond.if_body[i], symbols, count, depth + 1);
            for (int i = 0; i < node->data.cond.else_count; i++)
                walk_ast_symbols(node->data.cond.else_body[i], symbols, count, depth + 1);
            break;
        case AST_LOOP:
            walk_ast_symbols(node->data.loop.cond, symbols, count, depth);
            for (int i = 0; i < node->data.loop.body_count; i++)
                walk_ast_symbols(node->data.loop.body[i], symbols, count, depth + 1);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                walk_ast_symbols(node->data.trycatch.try_body[i], symbols, count, depth + 1);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                walk_ast_symbols(node->data.trycatch.catch_body[i], symbols, count, depth + 1);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < node->data.block.count; i++)
                walk_ast_symbols(node->data.block.stmts[i], symbols, count, depth);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                walk_ast_symbols(node->data.program.stmts[i], symbols, count, depth);
            break;
        case AST_MATCH:
            walk_ast_symbols(node->data.match.expr, symbols, count, depth);
            for (int i = 0; i < node->data.match.case_count; i++) {
                if (node->data.match.patterns[i])
                    walk_ast_symbols(node->data.match.patterns[i], symbols, count, depth + 1);
                for (int j = 0; j < node->data.match.body_counts[i]; j++)
                    walk_ast_symbols(node->data.match.bodies[i][j], symbols, count, depth + 1);
            }
            break;
        case AST_BINOP:
            walk_ast_symbols(node->data.binop.left, symbols, count, depth);
            walk_ast_symbols(node->data.binop.right, symbols, count, depth);
            break;
        case AST_UNARY:
            walk_ast_symbols(node->data.unary.operand, symbols, count, depth);
            break;
        case AST_RELATION:
            walk_ast_symbols(node->data.relation.left, symbols, count, depth);
            walk_ast_symbols(node->data.relation.right, symbols, count, depth);
            break;
        case AST_RETURN:
            walk_ast_symbols(node->data.ret.expr, symbols, count, depth);
            break;
        case AST_INDEX:
            walk_ast_symbols(node->data.index.target, symbols, count, depth);
            walk_ast_symbols(node->data.index.index, symbols, count, depth);
            break;
        case AST_LIST:
            for (int i = 0; i < node->data.list.count; i++)
                walk_ast_symbols(node->data.list.elems[i], symbols, count, depth);
            break;
        case AST_DICT:
            for (int i = 0; i < node->data.dict.count; i++) {
                walk_ast_symbols(node->data.dict.keys[i], symbols, count, depth);
                walk_ast_symbols(node->data.dict.vals[i], symbols, count, depth);
            }
            break;
        case AST_DOT:
            walk_ast_symbols(node->data.dot.target, symbols, count, depth);
            break;
        default:
            break;
    }
}

/* ---- Collect identifier references from AST ---- */

typedef struct {
    int line;
    int col;
} Location;

static void collect_references(ASTNode *node, const char *name, Location *locs, int *count, int max) {
    if (!node || *count >= max) return;

    if (node->type == AST_IDENT && node->data.ident.name && strcmp(node->data.ident.name, name) == 0) {
        locs[*count].line = node->line;
        locs[*count].col = node->col;
        (*count)++;
    }

    /* Recurse into children */
    switch (node->type) {
        case AST_BINOP:
            collect_references(node->data.binop.left, name, locs, count, max);
            collect_references(node->data.binop.right, name, locs, count, max);
            break;
        case AST_UNARY:
            collect_references(node->data.unary.operand, name, locs, count, max);
            break;
        case AST_ASSIGN:
            collect_references(node->data.assign.expr, name, locs, count, max);
            break;
        case AST_RELATION:
            collect_references(node->data.relation.left, name, locs, count, max);
            collect_references(node->data.relation.right, name, locs, count, max);
            break;
        case AST_IF:
            collect_references(node->data.cond.cond, name, locs, count, max);
            for (int i = 0; i < node->data.cond.if_count; i++)
                collect_references(node->data.cond.if_body[i], name, locs, count, max);
            for (int i = 0; i < node->data.cond.else_count; i++)
                collect_references(node->data.cond.else_body[i], name, locs, count, max);
            break;
        case AST_LOOP:
            collect_references(node->data.loop.cond, name, locs, count, max);
            for (int i = 0; i < node->data.loop.body_count; i++)
                collect_references(node->data.loop.body[i], name, locs, count, max);
            break;
        case AST_FUNC:
            for (int i = 0; i < node->data.func.body_count; i++)
                collect_references(node->data.func.body[i], name, locs, count, max);
            break;
        case AST_RETURN:
            collect_references(node->data.ret.expr, name, locs, count, max);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < node->data.block.count; i++)
                collect_references(node->data.block.stmts[i], name, locs, count, max);
            break;
        case AST_LIST:
            for (int i = 0; i < node->data.list.count; i++)
                collect_references(node->data.list.elems[i], name, locs, count, max);
            break;
        case AST_INDEX:
            collect_references(node->data.index.target, name, locs, count, max);
            collect_references(node->data.index.index, name, locs, count, max);
            break;
        case AST_FOR:
            collect_references(node->data.forloop.iter, name, locs, count, max);
            for (int i = 0; i < node->data.forloop.body_count; i++)
                collect_references(node->data.forloop.body[i], name, locs, count, max);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                collect_references(node->data.program.stmts[i], name, locs, count, max);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                collect_references(node->data.trycatch.try_body[i], name, locs, count, max);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                collect_references(node->data.trycatch.catch_body[i], name, locs, count, max);
            break;
        case AST_DICT:
            for (int i = 0; i < node->data.dict.count; i++) {
                collect_references(node->data.dict.keys[i], name, locs, count, max);
                collect_references(node->data.dict.vals[i], name, locs, count, max);
            }
            break;
        case AST_DOT:
            collect_references(node->data.dot.target, name, locs, count, max);
            break;
        case AST_MATCH:
            collect_references(node->data.match.expr, name, locs, count, max);
            for (int i = 0; i < node->data.match.case_count; i++) {
                if (node->data.match.patterns[i])
                    collect_references(node->data.match.patterns[i], name, locs, count, max);
                for (int j = 0; j < node->data.match.body_counts[i]; j++)
                    collect_references(node->data.match.bodies[i][j], name, locs, count, max);
            }
            break;
        case AST_LAMBDA:
            collect_references(node->data.lambda.body, name, locs, count, max);
            break;
        case AST_LISTCOMP:
            collect_references(node->data.listcomp.expr, name, locs, count, max);
            collect_references(node->data.listcomp.iter, name, locs, count, max);
            if (node->data.listcomp.filter)
                collect_references(node->data.listcomp.filter, name, locs, count, max);
            break;
        case AST_DOT_ASSIGN:
            collect_references(node->data.dot_assign.target, name, locs, count, max);
            collect_references(node->data.dot_assign.expr, name, locs, count, max);
            break;
        case AST_INDEX_ASSIGN:
            collect_references(node->data.index_assign.target, name, locs, count, max);
            collect_references(node->data.index_assign.index, name, locs, count, max);
            collect_references(node->data.index_assign.expr, name, locs, count, max);
            break;
        default:
            break;
    }
}

/* ---- Re-analyze document: tokenize, parse, build symbols ---- */

static void doc_analyze(Document *doc) {
    /* Clear old state */
    if (doc->tokens.tokens) {
        free_tokenlist(&doc->tokens);
        memset(&doc->tokens, 0, sizeof(TokenList));
    }
    /* Free the previous parse before re-analyzing — otherwise every
     * didChange leaks an AST. AST nodes own their strings (xstrdup'd), so
     * this is independent of the token list freed just above. */
    if (doc->ast) { free_ast(doc->ast); doc->ast = NULL; }
    doc->symbol_count = 0;

    if (!doc->text) return;

    /* Tokenize */
    g_parse_errors = 0;
    g_has_error = 0;
    g_error_msg[0] = '\0';
    doc->tokens = tokenize(doc->text);

    /* Parse */
    doc->ast = parse(&doc->tokens);

    /* Build symbol table */
    if (doc->ast) {
        walk_ast_symbols(doc->ast, doc->symbols, &doc->symbol_count, 0);
    }
}

/* ---- Find token at a given line:col ---- */

static Token* find_token_at(Document *doc, int line, int col) {
    /* LSP lines are 0-based, our tokens use 1-based lines */
    int target_line = line + 1;
    Token *best = NULL;       /* closest token, as a fallback */
    Token *contains = NULL;   /* token whose span strictly contains col */
    for (int i = 0; i < doc->tokens.count; i++) {
        Token *t = &doc->tokens.tokens[i];
        if (t->type == TOK_EOF || t->type == TOK_NEWLINE ||
            t->type == TOK_INDENT || t->type == TOK_DEDENT) continue;
        if (t->line != target_line) continue;
        int tok_len = t->len > 0 ? t->len : 1;  /* accurate lexeme span */
        /* Strict containment [col, col+len): each column belongs to exactly
         * one token, so an adjacent token (e.g. '(' before a param) can't
         * steal the cursor position. */
        if (col >= t->col && col < t->col + tok_len) contains = t;
        if (!best || abs(t->col - col) < abs(best->col - col)) best = t;
    }
    /* Prefer the containing token; fall back to the closest one (handles a
     * cursor resting just past an identifier). */
    return contains ? contains : best;
}

/* ================================================================
 * LSP HANDLERS
 * ================================================================ */

static void handle_initialize(int id) {
    lsp_response(id,
        "{"
            "\"capabilities\":{"
                "\"textDocumentSync\":1,"
                "\"completionProvider\":{\"triggerCharacters\":[\".\",\" \"]},"
                "\"hoverProvider\":true,"
                "\"definitionProvider\":true,"
                "\"referencesProvider\":true,"
                "\"documentSymbolProvider\":true,"
                "\"workspaceSymbolProvider\":true,"
                "\"documentFormattingProvider\":true,"
                "\"renameProvider\":true,"
                "\"codeActionProvider\":true,"
                "\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":"
                    "[\"keyword\",\"function\",\"variable\",\"parameter\",\"number\",\"string\",\"namespace\"],"
                    "\"tokenModifiers\":[]},\"full\":true}"
            "},"
            "\"serverInfo\":{\"name\":\"eigenlsp\",\"version\":\"" EIGENSCRIPT_VERSION "\"}"
        "}"
    );
}

static void send_diagnostics(Document *doc) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"uri\":");
    json_escape_to(&sb, doc->uri);
    strbuf_append(&sb, ",\"diagnostics\":[");

    /* Surface the first syntax error of the analyze pass as a squiggle.
     * The parser/lexer only print to stderr (invisible to the editor);
     * eigs_record_first_error captures the line + message for us. The
     * old code keyed off g_error_msg, which the parser never sets on a
     * syntax error, so diagnostics never appeared. */
    if (g_parse_errors > 0 && g_first_error_line > 0) {
        int err_line = g_first_error_line - 1;  /* 1-based → 0-based */
        char full[320];
        snprintf(full, sizeof(full), "syntax error: %s",
                 g_first_error_msg[0] ? g_first_error_msg : "invalid syntax");

        strbuf_append(&sb, "{\"range\":{\"start\":{\"line\":");
        strbuf_append_fmt(&sb, "%d", err_line);
        strbuf_append(&sb, ",\"character\":0},\"end\":{\"line\":");
        strbuf_append_fmt(&sb, "%d", err_line);
        strbuf_append(&sb, ",\"character\":1000}},\"severity\":1,\"code\":\"E002\","
                            "\"source\":\"eigenscript\",\"message\":");
        json_escape_to(&sb, full);
        strbuf_append_char(&sb, '}');
    } else if (doc->ast) {
        /* Parse OK → run the linter and publish each warning as a
         * yellow squiggle carrying its stable code (#3 taxonomy), so the
         * editor shows the same diagnostics as `--lint`. */
        LintDiag diags[256];
        int n = lint_collect(doc->ast, diags, 256);
        for (int i = 0; i < n; i++) {
            int ln = diags[i].line - 1;
            if (ln < 0) ln = 0;
            if (i > 0) strbuf_append_char(&sb, ',');
            strbuf_append_fmt(&sb,
                "{\"range\":{\"start\":{\"line\":%d,\"character\":0},"
                "\"end\":{\"line\":%d,\"character\":1000}},\"severity\":2,\"code\":\"%s\","
                "\"source\":\"eigenscript\",\"message\":", ln, ln, diags[i].code);
            json_escape_to(&sb, diags[i].message);
            strbuf_append_char(&sb, '}');
        }
    }

    strbuf_append(&sb, "]}");
    lsp_notification("textDocument/publishDiagnostics", sb.data);
    strbuf_free(&sb);
}

static void handle_did_open(const char *params) {
    char *td = json_get_object(params, "textDocument");
    if (!td) return;
    char *uri = json_get_string(td, "uri");
    char *text = json_get_string(td, "text");
    free(td);
    if (!uri) { if (text) free(text); return; }

    Document *doc = doc_find(uri);
    if (!doc) doc = doc_create(uri);
    if (!doc) { free(uri); if (text) free(text); return; }

    if (doc->text) free(doc->text);
    doc->text = text;
    doc->text_len = text ? (int)strlen(text) : 0;

    doc_analyze(doc);
    send_diagnostics(doc);
    free(uri);
}

static void handle_did_change(const char *params) {
    char *td = json_get_object(params, "textDocument");
    if (!td) return;
    char *uri = json_get_string(td, "uri");
    free(td);
    if (!uri) return;

    Document *doc = doc_find(uri);
    if (!doc) { free(uri); return; }

    /* Extract contentChanges[0].text (full sync) */
    const char *cc = strstr(params, "contentChanges");
    if (cc) {
        /* Find the "text" field inside the first change object */
        const char *bracket = strchr(cc, '[');
        if (bracket) {
            char *new_text = json_get_string(bracket, "text");
            if (new_text) {
                if (doc->text) free(doc->text);
                doc->text = new_text;
                doc->text_len = (int)strlen(new_text);
            }
        }
    }

    doc_analyze(doc);
    send_diagnostics(doc);
    free(uri);
}

static void handle_did_close(const char *params) {
    char *td = json_get_object(params, "textDocument");
    if (!td) return;
    char *uri = json_get_string(td, "uri");
    free(td);
    if (!uri) return;

    /* Send empty diagnostics to clear */
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"uri\":");
    json_escape_to(&sb, uri);
    strbuf_append(&sb, ",\"diagnostics\":[]}");
    lsp_notification("textDocument/publishDiagnostics", sb.data);
    strbuf_free(&sb);

    doc_remove(uri);
    free(uri);
}

static void handle_completion(int id, const char *params) {
    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"isIncomplete\":false,\"items\":[");

    int first = 1;

    /* Add keywords */
    static const char *keywords[] = {
        "is", "of", "define", "as", "if", "else", "elif", "loop", "while",
        "for", "in", "return", "and", "or", "not", "null", "try", "catch",
        "break", "continue", "import", "match", "case", "unobserved",
        "true", "false", NULL
    };
    for (int i = 0; keywords[i]; i++) {
        if (!first) strbuf_append_char(&sb, ',');
        first = 0;
        strbuf_append(&sb, "{\"label\":\"");
        strbuf_append(&sb, keywords[i]);
        strbuf_append(&sb, "\",\"kind\":14}");  /* 14 = Keyword */
    }

    /* Add builtins */
    for (int i = 0; builtin_docs[i][0]; i++) {
        if (!first) strbuf_append_char(&sb, ',');
        first = 0;
        strbuf_append(&sb, "{\"label\":\"");
        strbuf_append(&sb, builtin_docs[i][0]);
        strbuf_append(&sb, "\",\"kind\":3,\"detail\":");  /* 3 = Function */
        json_escape_to(&sb, builtin_docs[i][1]);
        strbuf_append_char(&sb, '}');
    }

    /* Add document symbols */
    char *td = json_get_object(params, "textDocument");
    if (td) {
        char *uri = json_get_string(td, "uri");
        free(td);
        if (uri) {
            Document *doc = doc_find(uri);
            if (doc) {
                for (int i = 0; i < doc->symbol_count; i++) {
                    Symbol *s = &doc->symbols[i];
                    if (!first) strbuf_append_char(&sb, ',');
                    first = 0;
                    strbuf_append(&sb, "{\"label\":\"");
                    strbuf_append(&sb, s->name);
                    strbuf_append(&sb, "\",\"kind\":");
                    switch (s->kind) {
                        case SYM_FUNC: strbuf_append(&sb, "3"); break;   /* Function */
                        case SYM_VAR: strbuf_append(&sb, "6"); break;    /* Variable */
                        case SYM_PARAM: strbuf_append(&sb, "6"); break;  /* Variable */
                        case SYM_IMPORT: strbuf_append(&sb, "9"); break; /* Module */
                    }
                    if (s->kind == SYM_FUNC && s->param_count > 0) {
                        strbuf_append(&sb, ",\"detail\":\"define ");
                        strbuf_append(&sb, s->name);
                        strbuf_append_char(&sb, '(');
                        for (int j = 0; j < s->param_count; j++) {
                            if (j > 0) strbuf_append(&sb, ", ");
                            strbuf_append(&sb, s->params[j]);
                        }
                        strbuf_append(&sb, ") as:\"");
                    }
                    strbuf_append_char(&sb, '}');
                }
            }
            free(uri);
        }
    }

    /* Check if cursor is after "import " — offer module names */
    {
        char *pos_obj = json_get_object(params, "position");
        char *td2 = json_get_object(params, "textDocument");
        if (pos_obj && td2) {
            int ln = json_get_int(pos_obj, "line");
            char *uri = json_get_string(td2, "uri");
            if (uri && ln >= 0) {
                Document *doc = doc_find(uri);
                if (doc && doc->text) {
                    /* Find the line */
                    const char *lp = doc->text;
                    for (int i = 0; i < ln && *lp; i++) {
                        while (*lp && *lp != '\n') lp++;
                        if (*lp == '\n') lp++;
                    }
                    /* Check if line starts with "import " */
                    while (*lp == ' ' || *lp == '\t') lp++;
                    if (strncmp(lp, "import ", 7) == 0) {
                        /* List available modules */
                        static const char *modules[] = {
                            "args", "auth", "concurrent", "config", "data", "datetime",
                            "eigen", "format", "functional", "http", "io", "json",
                            "list", "log", "map", "math", "observer", "queue",
                            "sanitize", "set", "sort", "state", "stats", "store",
                            "string", "template", "tensor", "test", "ui",
                            "ui_anim", "ui_draw", "ui_layout", "ui_theme", "validate",
                            NULL
                        };
                        for (int i = 0; modules[i]; i++) {
                            if (!first) strbuf_append_char(&sb, ',');
                            first = 0;
                            strbuf_append(&sb, "{\"label\":\"");
                            strbuf_append(&sb, modules[i]);
                            strbuf_append(&sb, "\",\"kind\":9}");  /* 9 = Module */
                        }
                    }
                }
            }
            if (uri) free(uri);
        }
        if (pos_obj) free(pos_obj);
        if (td2) free(td2);
    }

    strbuf_append(&sb, "]}");
    lsp_response(id, sb.data);
    strbuf_free(&sb);
}

static void handle_hover(int id, const char *params) {
    char *td = json_get_object(params, "textDocument");
    char *pos_obj = json_get_object(params, "position");
    if (!td || !pos_obj) {
        lsp_response_null(id);
        if (td) free(td);
        if (pos_obj) free(pos_obj);
        return;
    }

    char *uri = json_get_string(td, "uri");
    int line = json_get_int(pos_obj, "line");
    int col = json_get_int(pos_obj, "character");
    free(td);
    free(pos_obj);

    if (!uri) { lsp_response_null(id); return; }

    Document *doc = doc_find(uri);
    free(uri);
    if (!doc) { lsp_response_null(id); return; }

    Token *tok = find_token_at(doc, line, col);
    if (!tok || !tok->str_val) { lsp_response_null(id); return; }

    const char *hover_text = NULL;
    char hover_buf[1024];

    /* Check builtins */
    for (int i = 0; builtin_docs[i][0]; i++) {
        if (strcmp(tok->str_val, builtin_docs[i][0]) == 0) {
            hover_text = builtin_docs[i][1];
            break;
        }
    }

    /* Check keywords */
    if (!hover_text) {
        for (int i = 0; keyword_docs[i][0]; i++) {
            if (strcmp(tok->str_val, keyword_docs[i][0]) == 0) {
                hover_text = keyword_docs[i][1];
                break;
            }
        }
    }

    /* Check document symbols */
    if (!hover_text) {
        for (int i = 0; i < doc->symbol_count; i++) {
            Symbol *s = &doc->symbols[i];
            if (strcmp(tok->str_val, s->name) == 0) {
                if (s->kind == SYM_FUNC) {
                    strbuf hb;
                    strbuf_init(&hb);
                    strbuf_append(&hb, "define ");
                    strbuf_append(&hb, s->name);
                    strbuf_append_char(&hb, '(');
                    for (int j = 0; j < s->param_count; j++) {
                        if (j > 0) strbuf_append(&hb, ", ");
                        strbuf_append(&hb, s->params[j]);
                    }
                    strbuf_append_fmt(&hb, ") as:  [line %d]", s->line);
                    snprintf(hover_buf, sizeof(hover_buf), "%s", hb.data);
                    strbuf_free(&hb);
                    hover_text = hover_buf;
                } else if (s->kind == SYM_VAR || s->kind == SYM_PARAM) {
                    snprintf(hover_buf, sizeof(hover_buf), "%s %s — defined at line %d",
                             s->kind == SYM_PARAM ? "parameter" : "variable",
                             s->name, s->line);
                    hover_text = hover_buf;
                } else if (s->kind == SYM_IMPORT) {
                    snprintf(hover_buf, sizeof(hover_buf), "import %s", s->name);
                    hover_text = hover_buf;
                }
                break;
            }
        }
    }

    if (!hover_text) { lsp_response_null(id); return; }

    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
    /* Wrap in code block */
    strbuf code;
    strbuf_init(&code);
    strbuf_append(&code, "```eigenscript\\n");
    strbuf_append(&code, hover_text);
    strbuf_append(&code, "\\n```");
    json_escape_to(&sb, code.data);
    strbuf_free(&code);
    strbuf_append(&sb, "}}");
    lsp_response(id, sb.data);
    strbuf_free(&sb);
}

static void handle_definition(int id, const char *params) {
    char *td = json_get_object(params, "textDocument");
    char *pos_obj = json_get_object(params, "position");
    if (!td || !pos_obj) {
        lsp_response_null(id);
        if (td) free(td);
        if (pos_obj) free(pos_obj);
        return;
    }

    char *uri = json_get_string(td, "uri");
    int line = json_get_int(pos_obj, "line");
    int col = json_get_int(pos_obj, "character");
    free(td);
    free(pos_obj);

    if (!uri) { lsp_response_null(id); return; }

    Document *doc = doc_find(uri);
    if (!doc) { free(uri); lsp_response_null(id); return; }

    Token *tok = find_token_at(doc, line, col);
    if (!tok || !tok->str_val) { free(uri); lsp_response_null(id); return; }

    /* Find in symbol table */
    for (int i = 0; i < doc->symbol_count; i++) {
        Symbol *s = &doc->symbols[i];
        if (strcmp(tok->str_val, s->name) == 0 && (s->kind == SYM_FUNC || s->kind == SYM_VAR || s->kind == SYM_IMPORT)) {
            strbuf sb;
            strbuf_init(&sb);
            strbuf_append(&sb, "{\"uri\":");
            json_escape_to(&sb, doc->uri);
            strbuf_append_fmt(&sb, ",\"range\":{\"start\":{\"line\":%d,\"character\":%d},\"end\":{\"line\":%d,\"character\":%d}}}",
                s->line - 1, s->col, s->line - 1, s->col + (int)strlen(s->name));
            lsp_response(id, sb.data);
            strbuf_free(&sb);
            free(uri);
            return;
        }
    }

    free(uri);
    lsp_response_null(id);
}

static void handle_references(int id, const char *params) {
    char *td = json_get_object(params, "textDocument");
    char *pos_obj = json_get_object(params, "position");
    if (!td || !pos_obj) {
        lsp_response(id, "[]");
        if (td) free(td);
        if (pos_obj) free(pos_obj);
        return;
    }

    char *uri = json_get_string(td, "uri");
    int line = json_get_int(pos_obj, "line");
    int col = json_get_int(pos_obj, "character");
    free(td);
    free(pos_obj);

    if (!uri) { lsp_response(id, "[]"); return; }

    Document *doc = doc_find(uri);
    if (!doc || !doc->ast) { free(uri); lsp_response(id, "[]"); return; }

    Token *tok = find_token_at(doc, line, col);
    if (!tok || !tok->str_val) { free(uri); lsp_response(id, "[]"); return; }

    /* Collect all references */
    Location locs[512];
    int loc_count = 0;
    collect_references(doc->ast, tok->str_val, locs, &loc_count, 512);

    /* Also add definition locations from symbol table */
    for (int i = 0; i < doc->symbol_count; i++) {
        Symbol *s = &doc->symbols[i];
        if (strcmp(tok->str_val, s->name) == 0 && loc_count < 512) {
            /* Check if already in list */
            int found = 0;
            for (int j = 0; j < loc_count; j++) {
                if (locs[j].line == s->line && locs[j].col == s->col) { found = 1; break; }
            }
            if (!found) {
                locs[loc_count].line = s->line;
                locs[loc_count].col = s->col;
                loc_count++;
            }
        }
    }

    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_char(&sb, '[');
    for (int i = 0; i < loc_count; i++) {
        if (i > 0) strbuf_append_char(&sb, ',');
        strbuf_append(&sb, "{\"uri\":");
        json_escape_to(&sb, doc->uri);
        strbuf_append_fmt(&sb, ",\"range\":{\"start\":{\"line\":%d,\"character\":%d},\"end\":{\"line\":%d,\"character\":%d}}}",
            locs[i].line - 1, locs[i].col, locs[i].line - 1, locs[i].col + (int)strlen(tok->str_val));
    }
    strbuf_append_char(&sb, ']');
    lsp_response(id, sb.data);
    strbuf_free(&sb);
    free(uri);
}

/* LSP SymbolKind for a document symbol (distinct enum from CompletionItemKind). */
static int sym_to_lsp_kind(SymKind k) {
    switch (k) {
        case SYM_FUNC:   return 12;  /* Function */
        case SYM_IMPORT: return 2;   /* Module */
        case SYM_VAR:    return 13;  /* Variable */
        case SYM_PARAM:  return 13;  /* Variable */
    }
    return 13;
}

/* Append a {"line":L,"character":C} position (symbol lines are 1-based). */
static void append_range(strbuf *sb, int line1, int col, int len) {
    strbuf_append_fmt(sb,
        "{\"start\":{\"line\":%d,\"character\":%d},\"end\":{\"line\":%d,\"character\":%d}}",
        line1 - 1, col, line1 - 1, col + len);
}

/* ---- textDocument/documentSymbol: outline of top-level defs/vars/imports ---- */
static void handle_document_symbol(int id, const char *params) {
    char *td = json_get_object(params, "textDocument");
    if (!td) { lsp_response(id, "[]"); return; }
    char *uri = json_get_string(td, "uri");
    free(td);
    if (!uri) { lsp_response(id, "[]"); return; }
    Document *doc = doc_find(uri);
    free(uri);
    if (!doc) { lsp_response(id, "[]"); return; }

    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_char(&sb, '[');
    int first = 1;
    char seen[MAX_SYMBOLS][256];
    int seen_count = 0;
    for (int i = 0; i < doc->symbol_count; i++) {
        Symbol *s = &doc->symbols[i];
        /* Outline carries functions, imports, and top-level variables —
         * not params or nested locals (they'd swamp the outline). */
        int include = (s->kind == SYM_FUNC || s->kind == SYM_IMPORT ||
                       (s->kind == SYM_VAR && s->scope_depth == 0));
        if (!include || s->name[0] == '\0') continue;
        /* Dedupe by name (a re-assigned var appears once). */
        int dup = 0;
        for (int j = 0; j < seen_count; j++)
            if (strcmp(seen[j], s->name) == 0) { dup = 1; break; }
        if (dup) continue;
        if (seen_count < MAX_SYMBOLS) snprintf(seen[seen_count++], 256, "%s", s->name);

        if (!first) strbuf_append_char(&sb, ',');
        first = 0;
        strbuf_append(&sb, "{\"name\":");
        json_escape_to(&sb, s->name);
        strbuf_append_fmt(&sb, ",\"kind\":%d", sym_to_lsp_kind(s->kind));
        int nlen = (int)strlen(s->name);
        strbuf_append(&sb, ",\"range\":");
        append_range(&sb, s->line, s->col, nlen);
        strbuf_append(&sb, ",\"selectionRange\":");
        append_range(&sb, s->line, s->col, nlen);
        strbuf_append_char(&sb, '}');
    }
    strbuf_append_char(&sb, ']');
    lsp_response(id, sb.data);
    strbuf_free(&sb);
}

/* ---- textDocument/formatting: reuse the CLI formatter (whole-doc edit) ---- */
static void handle_formatting(int id, const char *params) {
    char *td = json_get_object(params, "textDocument");
    if (!td) { lsp_response(id, "null"); return; }
    char *uri = json_get_string(td, "uri");
    free(td);
    if (!uri) { lsp_response(id, "null"); return; }
    Document *doc = doc_find(uri);
    free(uri);
    if (!doc || !doc->text) { lsp_response(id, "null"); return; }

    char *formatted = format_source_string(doc->text);
    if (!formatted) { lsp_response(id, "null"); return; }

    /* One TextEdit replacing the whole document. End at one past the last
     * line, character 0 — covers any trailing content the client holds. */
    int line_count = 0;
    for (const char *p = doc->text; *p; p++) if (*p == '\n') line_count++;
    line_count++;  /* a doc with N newlines spans N+1 lines */

    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_fmt(&sb,
        "[{\"range\":{\"start\":{\"line\":0,\"character\":0},"
        "\"end\":{\"line\":%d,\"character\":0}},\"newText\":", line_count);
    json_escape_to(&sb, formatted);
    strbuf_append(&sb, "}]");
    lsp_response(id, sb.data);
    strbuf_free(&sb);
    free(formatted);
}

/* ---- Function scopes, for scope-aware rename ----
 * EigenScript scoping: a function parameter (or a `local` declaration)
 * introduces a binding local to that function; a plain `name is expr`
 * otherwise mutates the nearest OUTER binding. So an occurrence of `x`
 * resolves to the innermost enclosing function that binds `x` as a
 * param/local, or to the global binding if none does. Rename only the
 * occurrences that resolve to the SAME binding as the cursor — so renaming
 * a global `x` leaves a shadowing `define f(x)` untouched, and vice-versa. */
#define MAX_FN_SCOPES 256
#define MAX_SCOPE_BINDS 32

typedef struct {
    int tok_start;   /* index of the `define` token */
    int tok_end;     /* one past the function's last body token */
    char binds[MAX_SCOPE_BINDS][48];  /* params + `local` names */
    int bind_count;
} FnScope;

static void scope_add_bind(FnScope *s, const char *name) {
    if (!name || s->bind_count >= MAX_SCOPE_BINDS) return;
    for (int i = 0; i < s->bind_count; i++)
        if (strcmp(s->binds[i], name) == 0) return;
    snprintf(s->binds[s->bind_count++], 48, "%s", name);
}

static int scope_binds(const FnScope *s, const char *name) {
    for (int i = 0; i < s->bind_count; i++)
        if (strcmp(s->binds[i], name) == 0) return 1;
    return 0;
}

/* Build a scope per `define` from the token stream. Nested functions each
 * get their own scope; ranges nest naturally. */
static int build_fn_scopes(Document *doc, FnScope *out, int max) {
    Token *tk = doc->tokens.tokens;
    int count = doc->tokens.count, n = 0;
    for (int i = 0; i < count && n < max; i++) {
        if (tk[i].type != TOK_DEFINE) continue;
        FnScope *s = &out[n];
        s->tok_start = i;
        s->bind_count = 0;
        /* Params: IDENTs between the function name's '(' and ')'. */
        int j = i + 1;
        if (j < count && tk[j].type == TOK_IDENT) j++;   /* function name */
        if (j < count && tk[j].type == TOK_LPAREN) {
            j++;
            while (j < count && tk[j].type != TOK_RPAREN && tk[j].type != TOK_NEWLINE) {
                if (tk[j].type == TOK_IDENT) scope_add_bind(s, tk[j].str_val);
                j++;
            }
        }
        /* Body span: the first INDENT after `define`, to its matching DEDENT. */
        int k = i, end = count;
        while (k < count && tk[k].type != TOK_INDENT) k++;
        if (k < count && tk[k].type == TOK_INDENT) {
            int depth = 0;
            for (; k < count; k++) {
                if (tk[k].type == TOK_INDENT) depth++;
                else if (tk[k].type == TOK_DEDENT) { depth--; if (depth == 0) { k++; break; } }
            }
            end = k;
        }
        s->tok_end = end;
        /* `local <ident>` declarations also bind locally. */
        for (int m = s->tok_start; m + 1 < s->tok_end; m++)
            if (tk[m].type == TOK_LOCAL && tk[m + 1].type == TOK_IDENT)
                scope_add_bind(s, tk[m + 1].str_val);
        n++;
    }
    return n;
}

/* Innermost scope that contains token `idx` and binds `name`, or -1 (global). */
static int resolve_binding(FnScope *scopes, int n, int idx, const char *name) {
    int best = -1;
    for (int s = 0; s < n; s++) {
        if (idx >= scopes[s].tok_start && idx < scopes[s].tok_end &&
            scope_binds(&scopes[s], name)) {
            if (best < 0 || scopes[s].tok_start > scopes[best].tok_start) best = s;
        }
    }
    return best;
}

/* ---- textDocument/rename: scope-aware WorkspaceEdit over exact token spans ---- */
static void handle_rename(int id, const char *params) {
    char *td = json_get_object(params, "textDocument");
    char *pos_obj = json_get_object(params, "position");
    char *new_name = json_get_string(params, "newName");
    if (!td || !pos_obj || !new_name) {
        lsp_response_null(id);
        if (td) free(td);
        if (pos_obj) free(pos_obj);
        if (new_name) free(new_name);
        return;
    }
    char *uri = json_get_string(td, "uri");
    int line = json_get_int(pos_obj, "line");
    int col = json_get_int(pos_obj, "character");
    free(td); free(pos_obj);
    if (!uri) { free(new_name); lsp_response_null(id); return; }

    Document *doc = doc_find(uri);
    if (!doc || !doc->ast) { free(uri); free(new_name); lsp_response_null(id); return; }

    Token *tok = find_token_at(doc, line, col);
    if (!tok || tok->type != TOK_IDENT || !tok->str_val) {
        free(uri); free(new_name); lsp_response_null(id); return;
    }

    /* Don't rename language keywords or builtins — only user symbols. */
    int is_user_symbol = 0;
    for (int i = 0; i < doc->symbol_count; i++)
        if (strcmp(tok->str_val, doc->symbols[i].name) == 0) { is_user_symbol = 1; break; }
    if (!is_user_symbol) { free(uri); free(new_name); lsp_response_null(id); return; }

    /* Build edits from the TOKEN stream, never the AST node columns (which
     * are unreliable for many node types and would mis-place — even corrupt —
     * the edit). Every identifier token with this name is renamed, except a
     * dot-member access (`obj.name`), which is a distinct binding. Token
     * spans (line/col/len) are exact, so each edit lands precisely on the
     * identifier. */
    const char *name = tok->str_val;
    /* Resolve the cursor's binding, then rename only occurrences that resolve
     * to the SAME binding — so a shadowing parameter (or global) is left
     * alone. Positions still come from the token stream (exact spans). */
    static FnScope scopes[MAX_FN_SCOPES];
    int nscopes = build_fn_scopes(doc, scopes, MAX_FN_SCOPES);
    int cursor_idx = (int)(tok - doc->tokens.tokens);
    int cursor_bind = resolve_binding(scopes, nscopes, cursor_idx, name);

    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"changes\":{");
    json_escape_to(&sb, doc->uri);
    strbuf_append(&sb, ":[");
    int emitted = 0;
    for (int i = 0; i < doc->tokens.count; i++) {
        Token *t = &doc->tokens.tokens[i];
        if (t->type != TOK_IDENT || !t->str_val || strcmp(t->str_val, name) != 0) continue;
        if (i > 0 && doc->tokens.tokens[i - 1].type == TOK_DOT) continue;  /* member access */
        if (resolve_binding(scopes, nscopes, i, name) != cursor_bind) continue;  /* other binding */
        if (emitted) strbuf_append_char(&sb, ',');
        emitted++;
        strbuf_append(&sb, "{\"range\":");
        append_range(&sb, t->line, t->col, t->len > 0 ? t->len : (int)strlen(name));
        strbuf_append(&sb, ",\"newText\":");
        json_escape_to(&sb, new_name);
        strbuf_append_char(&sb, '}');
    }
    strbuf_append(&sb, "]}}");
    lsp_response(id, sb.data);
    strbuf_free(&sb);
    free(uri);
    free(new_name);
}

/* ---- workspace/symbol: symbols across all open documents, filtered ---- */
static void handle_workspace_symbol(int id, const char *params) {
    char *query = json_get_string(params, "query");  /* may be "" */

    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_char(&sb, '[');
    int first = 1;
    for (int d = 0; d < g_doc_count; d++) {
        Document *doc = &g_docs[d];
        for (int i = 0; i < doc->symbol_count; i++) {
            Symbol *s = &doc->symbols[i];
            int include = (s->kind == SYM_FUNC || s->kind == SYM_IMPORT ||
                           (s->kind == SYM_VAR && s->scope_depth == 0));
            if (!include || s->name[0] == '\0') continue;
            /* Case-insensitive substring filter (empty query matches all). */
            if (query && query[0]) {
                int match = 0;
                for (const char *h = s->name; *h && !match; h++) {
                    const char *a = h, *b = query;
                    while (*a && *b && tolower((unsigned char)*a) == tolower((unsigned char)*b)) { a++; b++; }
                    if (!*b) match = 1;
                }
                if (!match) continue;
            }
            if (!first) strbuf_append_char(&sb, ',');
            first = 0;
            strbuf_append(&sb, "{\"name\":");
            json_escape_to(&sb, s->name);
            strbuf_append_fmt(&sb, ",\"kind\":%d,\"location\":{\"uri\":", sym_to_lsp_kind(s->kind));
            json_escape_to(&sb, doc->uri);
            strbuf_append(&sb, ",\"range\":");
            append_range(&sb, s->line, s->col, (int)strlen(s->name));
            strbuf_append(&sb, "}}");
        }
    }
    strbuf_append_char(&sb, ']');
    lsp_response(id, sb.data);
    strbuf_free(&sb);
    if (query) free(query);
}

/* ---- textDocument/codeAction: quickfixes keyed on lint codes ---- */
static void handle_code_action(int id, const char *params) {
    char *td = json_get_object(params, "textDocument");
    char *range = json_get_object(params, "range");
    if (!td || !range) {
        lsp_response(id, "[]");
        if (td) free(td);
        if (range) free(range);
        return;
    }
    char *uri = json_get_string(td, "uri");
    free(td);
    int start_line = -1, end_line = -1;
    {
        char *start = json_get_object(range, "start");
        char *end = json_get_object(range, "end");
        if (start) { start_line = json_get_int(start, "line"); free(start); }
        if (end)   { end_line   = json_get_int(end, "line");   free(end); }
        free(range);
    }
    if (end_line < start_line) end_line = start_line;
    if (!uri) { lsp_response(id, "[]"); return; }
    Document *doc = doc_find(uri);
    if (!doc || !doc->ast) { free(uri); lsp_response(id, "[]"); return; }

    /* Recompute diagnostics from the AST rather than parsing the client's
     * context.diagnostics array — more robust, and the codes are ours. */
    LintDiag diags[256];
    int n = lint_collect(doc->ast, diags, 256);

    strbuf sb;
    strbuf_init(&sb);
    strbuf_append_char(&sb, '[');
    int first = 1;
    for (int i = 0; i < n; i++) {
        int ln = diags[i].line - 1;
        if (ln < 0) ln = 0;
        if (ln < start_line || ln > end_line) continue;
        /* W001 unused variable → offer to delete the line. (Other codes
         * can be added here as their fixes are designed.) */
        if (strcmp(diags[i].code, "W001") != 0) continue;

        char vname[128] = "";
        const char *q1 = strchr(diags[i].message, '\'');
        if (q1) {
            const char *q2 = strchr(q1 + 1, '\'');
            if (q2) {
                int L = (int)(q2 - q1 - 1);
                if (L > 0 && L < (int)sizeof(vname)) { memcpy(vname, q1 + 1, L); vname[L] = '\0'; }
            }
        }
        char title[200];
        if (vname[0]) snprintf(title, sizeof(title), "Remove unused variable '%s'", vname);
        else snprintf(title, sizeof(title), "Remove unused variable");

        if (!first) strbuf_append_char(&sb, ',');
        first = 0;
        strbuf_append(&sb, "{\"title\":");
        json_escape_to(&sb, title);
        strbuf_append(&sb, ",\"kind\":\"quickfix\",\"edit\":{\"changes\":{");
        json_escape_to(&sb, doc->uri);
        /* Delete the whole line: [ln,0]..[ln+1,0] → "" */
        strbuf_append_fmt(&sb,
            ":[{\"range\":{\"start\":{\"line\":%d,\"character\":0},"
            "\"end\":{\"line\":%d,\"character\":0}},\"newText\":\"\"}]}}}",
            ln, ln + 1);
    }
    strbuf_append_char(&sb, ']');
    lsp_response(id, sb.data);
    strbuf_free(&sb);
    free(uri);
}

/* ---- textDocument/semanticTokens/full ----
 * Legend (index → type): 0 keyword, 1 function, 2 variable, 3 parameter,
 * 4 number, 5 string, 6 namespace. The value is in classifying identifiers
 * as function/variable/parameter/namespace (which a TextMate grammar
 * cannot) via the symbol table; keywords/numbers/strings round it out. */
static int semantic_type_for(Document *doc, Token *t) {
    switch (t->type) {
        case TOK_NUM: return 4;
        case TOK_STR: return 5;
        case TOK_NEWLINE: case TOK_INDENT: case TOK_DEDENT: case TOK_EOF:
            return -1;
        default: break;
    }
    if (t->type == TOK_IDENT && t->str_val) {
        for (int i = 0; builtin_docs[i][0]; i++)
            if (strcmp(t->str_val, builtin_docs[i][0]) == 0) return 1;  /* builtin → function */
        for (int i = 0; i < doc->symbol_count; i++) {
            if (strcmp(t->str_val, doc->symbols[i].name) == 0) {
                switch (doc->symbols[i].kind) {
                    case SYM_FUNC:   return 1;
                    case SYM_PARAM:  return 3;
                    case SYM_IMPORT: return 6;
                    case SYM_VAR:    return 2;
                }
            }
        }
        return 2;  /* unknown identifier → variable */
    }
    if (t->str_val) return 0;  /* remaining str-valued tokens are keywords */
    return -1;                 /* operators / punctuation: left to the grammar */
}

static void handle_semantic_tokens(int id, const char *params) {
    char *td = json_get_object(params, "textDocument");
    if (!td) { lsp_response(id, "{\"data\":[]}"); return; }
    char *uri = json_get_string(td, "uri");
    free(td);
    if (!uri) { lsp_response(id, "{\"data\":[]}"); return; }
    Document *doc = doc_find(uri);
    free(uri);
    if (!doc) { lsp_response(id, "{\"data\":[]}"); return; }

    strbuf sb;
    strbuf_init(&sb);
    strbuf_append(&sb, "{\"data\":[");
    int prev_line = 0, prev_col = 0, first = 1;
    for (int i = 0; i < doc->tokens.count; i++) {
        Token *t = &doc->tokens.tokens[i];
        int stype = semantic_type_for(doc, t);
        if (stype < 0) continue;
        int line0 = t->line - 1;
        if (line0 < 0) continue;
        int col = t->col;
        int dline = line0 - prev_line;
        int dchar = (dline == 0) ? col - prev_col : col;
        /* Skip any out-of-order synthesized token (e.g. f-string desugar):
         * the LSP delta encoding requires non-decreasing positions. */
        if (dline < 0 || (dline == 0 && dchar < 0)) continue;
        int len = t->len > 0 ? t->len : 1;
        if (!first) strbuf_append_char(&sb, ',');
        first = 0;
        strbuf_append_fmt(&sb, "%d,%d,%d,%d,0", dline, dchar, len, stype);
        prev_line = line0;
        prev_col = col;
    }
    strbuf_append(&sb, "]}");
    lsp_response(id, sb.data);
    strbuf_free(&sb);
}

/* ================================================================
 * MESSAGE DISPATCH
 * ================================================================ */

static void handle_message(const char *json) {
    char *method = json_get_string(json, "method");
    int id = json_get_int(json, "id");
    char *params_str = json_get_object(json, "params");

    if (!method) {
        /* Response or unknown — ignore */
        if (params_str) free(params_str);
        return;
    }

    fprintf(stderr, "[LSP] method=%s id=%d\n", method, id);

    if (strcmp(method, "initialize") == 0) {
        handle_initialize(id);
    } else if (strcmp(method, "initialized") == 0) {
        /* no-op */
    } else if (strcmp(method, "shutdown") == 0) {
        g_shutdown = 1;
        lsp_response_null(id);
    } else if (strcmp(method, "exit") == 0) {
        free(method);
        if (params_str) free(params_str);
        exit(g_shutdown ? 0 : 1);
    } else if (strcmp(method, "textDocument/didOpen") == 0) {
        if (params_str) handle_did_open(params_str);
    } else if (strcmp(method, "textDocument/didChange") == 0) {
        if (params_str) handle_did_change(params_str);
    } else if (strcmp(method, "textDocument/didClose") == 0) {
        if (params_str) handle_did_close(params_str);
    } else if (strcmp(method, "textDocument/completion") == 0) {
        handle_completion(id, params_str ? params_str : json);
    } else if (strcmp(method, "textDocument/hover") == 0) {
        handle_hover(id, params_str ? params_str : json);
    } else if (strcmp(method, "textDocument/definition") == 0) {
        handle_definition(id, params_str ? params_str : json);
    } else if (strcmp(method, "textDocument/references") == 0) {
        handle_references(id, params_str ? params_str : json);
    } else if (strcmp(method, "textDocument/documentSymbol") == 0) {
        handle_document_symbol(id, params_str ? params_str : json);
    } else if (strcmp(method, "workspace/symbol") == 0) {
        handle_workspace_symbol(id, params_str ? params_str : json);
    } else if (strcmp(method, "textDocument/formatting") == 0) {
        handle_formatting(id, params_str ? params_str : json);
    } else if (strcmp(method, "textDocument/rename") == 0) {
        handle_rename(id, params_str ? params_str : json);
    } else if (strcmp(method, "textDocument/codeAction") == 0) {
        handle_code_action(id, params_str ? params_str : json);
    } else if (strcmp(method, "textDocument/semanticTokens/full") == 0) {
        handle_semantic_tokens(id, params_str ? params_str : json);
    } else {
        /* Unknown method */
        if (id >= 0) {
            lsp_error(id, -32601, "Method not found");
        }
    }

    free(method);
    if (params_str) free(params_str);
}

/* ================================================================
 * MAIN
 * ================================================================ */

int main(void) {
    fprintf(stderr, "[LSP] EigenScript Language Server %s starting\n", EIGENSCRIPT_VERSION);
    EigsState *eigs_st = eigs_state_new();
    eigs_thread_attach(eigs_st);

    while (1) {
        char *msg = lsp_read_message();
        if (!msg) break;
        handle_message(msg);
        free(msg);
    }

    fprintf(stderr, "[LSP] stdin closed, exiting\n");
    eigs_thread_detach();
    eigs_state_destroy(eigs_st);
    return 0;
}
