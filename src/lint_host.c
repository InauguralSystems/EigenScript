/*
 * EigenScript host-only lint subsystems (#813).
 *
 * The filesystem-backed API index, stdlib shadow check, scope-aware undefined
 * name check, and CLI file driver live in this whole-TU-gated file. Keeping
 * the host surface together makes a new host dependency visible to the
 * freestanding symbol gate by the name of the moved entry point.
 */

#include "eigenscript.h"
#include "ext_names.h"
#include "lint_internal.h"
#include "vm.h"   /* #927: lint compiles the unit and discards the chunk */

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

#if !EIGENSCRIPT_FREESTANDING

/* Escape a string for embedding in a JSON string literal (into a caller
 * buffer). This helper is host-only now that every JSON-producing lint path
 * lives in this TU; keeping it static prevents a generic host symbol leak. */
static void lint_json_escape(const char *s, char *out, size_t outsz) {
    size_t o = 0;
    for (size_t i = 0; s[i] && o + 2 < outsz; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') { out[o++] = '\\'; out[o++] = (char)c; }
        else if (c == '\n') { out[o++] = '\\'; out[o++] = 'n'; }
        else if (c == '\t') { out[o++] = '\\'; out[o++] = 't'; }
        else if (c >= 0x20) { out[o++] = (char)c; }
        /* other control chars are dropped */
    }
    out[o] = '\0';
}

/* Known builtin names — the registry itself, never a hand list (#459: the
 * old hand-copied BUILTINS[] array drifted ~120 names behind the binary, so
 * `define dispatch` shadowed a live builtin with no W012/W013). Same
 * derivation as E003's binding base: register_builtins() on a scratch Env,
 * plus the extension names (ext_names.h — the surface of the LANGUAGE, not
 * of this binary's build flags) and the compiler-resolved special forms no
 * registrar binds. Built once per process; still-reachable by design. */
static Env *g_builtin_name_env = NULL;

/* Freed at the end of every eigenscript_lint run: LeakSanitizer cannot trace
 * through the env's tagged EigsSlot pointers, so a kept-for-the-process env
 * reads as a direct leak and fails the detect_leaks=1 gate. */
void builtin_name_env_free(void) {
    if (g_builtin_name_env) {
        env_decref(g_builtin_name_env);
        g_builtin_name_env = NULL;
    }
}

int is_builtin_name(const char *name) {
    if (!g_builtin_name_env) {
        Env *e = env_new(NULL);
        register_builtins(e);   /* store/gfx-when-built ride inside (#742) */
#define X(nm, fn) if (!env_get(e, #nm)) env_set_local_owned(e, #nm, make_null());
        EIGS_GFX_BUILTINS(X)
        EIGS_HTTP_BUILTINS(X)
        EIGS_HTTP_REQUEST_BUILTINS(X)
        EIGS_DB_BUILTINS(X)
        EIGS_MODEL_BUILTINS(X)
        EIGS_NET_BUILTINS(X)
#undef X
        if (!env_get(e, "report_value"))
            env_set_local_owned(e, "report_value", make_null());
        if (!env_get(e, "trajectory"))   /* #421 special form, like report_value */
            env_set_local_owned(e, "trajectory", make_null());
        g_builtin_name_env = e;
    }
    return env_get(g_builtin_name_env, name) != NULL;
}


/* ---- Check: stdlib shadowing (W021, #591) ----
 *
 * Sibling of W013 (a define shadowing a compiled-in builtin) for the stdlib
 * LIBRARY layer: the common discoverability failure is hand-rolling a
 * function a stdlib module already ships (lib/stats.eigs's median/mean; hex4/pad2
 * hand-rolled twice downstream) — the name is no builtin and the module was
 * never imported, so nothing else connects the two. Name-only matching has
 * false positives (a deliberately-different local `mean`), so W021 is a
 * HINT: advisory, never fails --lint, suppressible like every other code. */
typedef struct {
    char *module;   /* module name ("stats") */
    char *path;     /* realpath of the module file — the self-lint guard */
} W021Module;

typedef struct {
    char *func;     /* public function name */
    int mod;        /* index into g_w021_mods */
} W021Func;

/* The name table: public (non-'_'-prefixed) top-level defines of every
 * stdlib module, scraped from the same directories the import resolver
 * would find them in. (The shared #590 signature scrape does not exist in
 * the tree yet; this is the focused scan the issue calls for. The scrape is
 * line-based — top-level defines sit at column 0 by the STDLIB.md header
 * convention — so a lib file that doesn't parse still contributes.) Built
 * once per linted-file base dir and cached for the process: the LSP
 * re-lints the same document on every publish and ~75 modules is far too
 * much to re-read per keystroke. Plain malloc'd strings reachable through
 * these globals, so LeakSanitizer traces them (unlike the tagged-slot
 * builtin env, which needs the explicit free). */
static W021Module *g_w021_mods = NULL;
static int g_w021_mod_count = 0, g_w021_mod_cap = 0;
static W021Func *g_w021_funcs = NULL;
static int g_w021_func_count = 0, g_w021_func_cap = 0;
static char g_w021_base[4096] = "";
static int g_w021_built = 0;

static void w021_free_table(void) {
    for (int i = 0; i < g_w021_mod_count; i++) {
        free(g_w021_mods[i].module);
        free(g_w021_mods[i].path);
    }
    for (int i = 0; i < g_w021_func_count; i++) free(g_w021_funcs[i].func);
    free(g_w021_mods);
    g_w021_mods = NULL; g_w021_mod_count = 0; g_w021_mod_cap = 0;
    free(g_w021_funcs);
    g_w021_funcs = NULL; g_w021_func_count = 0; g_w021_func_cap = 0;
}

static int w021_mod_find(const char *module) {
    for (int i = 0; i < g_w021_mod_count; i++)
        if (strcmp(g_w021_mods[i].module, module) == 0) return i;
    return -1;
}

static int w021_func_find(const char *func) {
    for (int i = 0; i < g_w021_func_count; i++)
        if (strcmp(g_w021_funcs[i].func, func) == 0) return i;
    return -1;
}

static int w021_ident_char(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

/* Scrape one module file's public defines into the table. */
static void w021_scan_file(const char *dirpath, const char *filename) {
    size_t nl = strlen(filename);
    if (nl <= 5 || nl - 5 >= 512) return;
    char module[512];
    memcpy(module, filename, nl - 5);   /* strip ".eigs" */
    module[nl - 5] = '\0';
    if (w021_mod_find(module) >= 0) return;   /* resolved higher in the chain */

    char full[8192];
    snprintf(full, sizeof(full), "%.4000s/%.500s", dirpath, filename);
    FILE *f = fopen(full, "r");
    if (!f) return;

    if (g_w021_mod_count >= g_w021_mod_cap) {
        g_w021_mod_cap = g_w021_mod_cap ? g_w021_mod_cap * 2 : 64;
        g_w021_mods = xrealloc(g_w021_mods,
                               (size_t)g_w021_mod_cap * sizeof(*g_w021_mods));
    }
    int mi = g_w021_mod_count++;
    char real[4096];
    if (!realpath(full, real)) snprintf(real, sizeof(real), "%s", full);
    g_w021_mods[mi].module = xstrdup(module);
    g_w021_mods[mi].path = xstrdup(real);

    char line[2048];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "define ", 7) != 0) continue;
        const char *p = line + 7;
        char name[256];
        size_t o = 0;
        while (w021_ident_char(*p) && o + 1 < sizeof(name)) name[o++] = *p++;
        name[o] = '\0';
        if (o == 0 || name[0] == '_') continue;   /* private by convention */
        if (w021_func_find(name) >= 0) continue;  /* first module wins */
        if (g_w021_func_count >= g_w021_func_cap) {
            g_w021_func_cap = g_w021_func_cap ? g_w021_func_cap * 2 : 256;
            g_w021_funcs = xrealloc(g_w021_funcs,
                                    (size_t)g_w021_func_cap * sizeof(*g_w021_funcs));
        }
        g_w021_funcs[g_w021_func_count].func = xstrdup(name);
        g_w021_funcs[g_w021_func_count].mod = mi;
        g_w021_func_count++;
    }
    fclose(f);
}

static void w021_scan_dir(const char *dirpath) {
    struct dirent **ents = NULL;
    int n = scandir(dirpath, &ents, NULL, alphasort);
    if (n < 0) return;
    for (int i = 0; i < n; i++) {
        const char *nm = ents[i]->d_name;
        size_t l = strlen(nm);
        if (l > 5 && strcmp(nm + l - 5, ".eigs") == 0)
            w021_scan_file(dirpath, nm);
        free(ents[i]);
    }
    free(ents);
}

/* Candidate lib dirs, mirroring the import resolver's priority order for
 * "lib/<mod>.eigs" (resolve_eigenscript_file_from): CWD first, then the
 * base file's dir and its parent, the exe's install root, the user
 * install. Realpath-deduplicated; first module found wins, as at runtime.
 * Shared by W021 and the --api index (#734). Returns the number of
 * resolved dirs written into `out` (each 4096 bytes). */
static int lib_candidate_dirs(const char *base, char (*out)[4096], int max) {
    char cand[6][4096];
    int nc = 0;
    snprintf(cand[nc++], 4096, "lib");
    if (base && base[0]) {
        snprintf(cand[nc++], 4096, "%.4000s/lib", base);
        snprintf(cand[nc++], 4096, "%.4000s/../lib", base);
    }
    if (g_exe_dir[0]) {
        snprintf(cand[nc++], 4096, "%.4000s/../lib", g_exe_dir);
        snprintf(cand[nc++], 4096, "%.4000s/../lib/eigenscript", g_exe_dir);
    }
    const char *home = getenv("HOME");
    if (home)
        snprintf(cand[nc++], 4096, "%.2000s/.local/lib/eigenscript", home);

    int ns = 0;
    for (int i = 0; i < nc && ns < max; i++) {
        char real[4096];
        if (!realpath(cand[i], real)) continue;
        int dup = 0;
        for (int j = 0; j < ns; j++)
            if (strcmp(out[j], real) == 0) { dup = 1; break; }
        if (dup) continue;
        snprintf(out[ns++], 4096, "%s", real);
    }
    return ns;
}

/* Build (or reuse) the name table for the linted file's base dir. */
static void w021_build(const char *base) {
    if (g_w021_built && strcmp(g_w021_base, base) == 0) return;
    w021_free_table();
    snprintf(g_w021_base, sizeof(g_w021_base), "%s", base);
    g_w021_built = 1;

    char dirs[6][4096];
    int nd = lib_candidate_dirs(base, dirs, 6);
    for (int i = 0; i < nd; i++)
        w021_scan_dir(dirs[i]);
}

/* ---- #734: --api — the machine-readable surface index ---- */

/* One call answers "does X exist, and is it builtin, extension, or lib":
 *   - "builtins": the compiled-in core registry, enumerated from a scratch
 *     register_builtins env — never a hand list (#459: the old hand-copied
 *     array drifted ~120 names behind the binary);
 *   - "extensions": the ext_names.h surface BY GROUP (gfx/http/db/model/
 *     net) — the surface of the LANGUAGE, independent of this binary's
 *     build flags (a name here may need `make http`/`make gfx`);
 *   - "lib": every public top-level define of each stdlib module WITH its
 *     parameter list as written (defaults included), scraped from the same
 *     directories the import resolver searches, first module wins.
 * Name resolution only — calling conventions live in docs/BUILTINS.md
 * (builtins/extensions) and docs/STDLIB.md (lib). */

typedef struct { char *module; char *name; char *params; } ApiLibFn;

static int api_mod_seen(char **mods, int count, const char *m) {
    for (int i = 0; i < count; i++)
        if (strcmp(mods[i], m) == 0) return 1;
    return 0;
}

static void api_scan_file(const char *dirpath, const char *filename,
                          ApiLibFn **fns, int *fc, int *fcap,
                          char ***mods, int *mc, int *mcap) {
    size_t nl = strlen(filename);
    if (nl <= 5 || nl - 5 >= 512) return;
    char module[512];
    memcpy(module, filename, nl - 5);
    module[nl - 5] = '\0';
    if (api_mod_seen(*mods, *mc, module)) return;  /* higher dir won */

    char full[8192];
    snprintf(full, sizeof(full), "%.4000s/%.500s", dirpath, filename);
    FILE *f = fopen(full, "r");
    if (!f) return;
    if (*mc == *mcap) {
        *mcap = *mcap ? *mcap * 2 : 64;
        *mods = xrealloc(*mods, (size_t)*mcap * sizeof(char *));
    }
    (*mods)[(*mc)++] = xstrdup(module);

    char line[2048];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "define ", 7) != 0) continue;
        const char *p = line + 7;
        char name[256];
        size_t o = 0;
        while (w021_ident_char(*p) && o + 1 < sizeof(name)) name[o++] = *p++;
        name[o] = '\0';
        if (o == 0 || name[0] == '_') continue;   /* private by convention */
        /* Parameter list as written; a define with no paren list carries
         * the implicit single parameter `n` (parser.c) — say so. */
        char params[1024];
        if (*p == '(') {
            p++;
            size_t q = 0;
            while (*p && *p != ')' && q + 1 < sizeof(params)) params[q++] = *p++;
            params[q] = '\0';
        } else {
            snprintf(params, sizeof(params), "n");
        }
        int dup = 0;   /* within-module redefine: first wins */
        for (int i = 0; i < *fc; i++)
            if (strcmp((*fns)[i].module, module) == 0 &&
                strcmp((*fns)[i].name, name) == 0) { dup = 1; break; }
        if (dup) continue;
        if (*fc == *fcap) {
            *fcap = *fcap ? *fcap * 2 : 256;
            *fns = xrealloc(*fns, (size_t)*fcap * sizeof(ApiLibFn));
        }
        (*fns)[*fc].module = xstrdup(module);
        (*fns)[*fc].name = xstrdup(name);
        (*fns)[*fc].params = xstrdup(params);
        (*fc)++;
    }
    fclose(f);
}

/* Emit one params string as a JSON array of trimmed comma-split entries. */
static void api_emit_params_json(FILE *out, const char *params) {
    fprintf(out, "[");
    const char *p = params;
    int first = 1;
    while (*p) {
        while (*p == ' ' || *p == '\t') p++;
        const char *start = p;
        while (*p && *p != ',') p++;
        const char *end = p;
        while (end > start && (end[-1] == ' ' || end[-1] == '\t')) end--;
        if (end > start) {
            char raw[512], esc[1100];
            size_t l = (size_t)(end - start);
            if (l >= sizeof(raw)) l = sizeof(raw) - 1;
            memcpy(raw, start, l);
            raw[l] = '\0';
            lint_json_escape(raw, esc, sizeof(esc));
            fprintf(out, "%s\"%s\"", first ? "" : ", ", esc);
            first = 0;
        }
        if (*p == ',') p++;
    }
    fprintf(out, "]");
}

/* Is `nm` an extension-surface name (any ext_names.h group)? Used to keep
 * the builtins list build-INDEPENDENT: in a build that compiled an
 * extension in (e.g. make net registers net_dial), that name is in the
 * core env too, but --api must still report it as an extension, not a
 * plain builtin — the ext groups are the LANGUAGE surface, not this
 * binary's flags, so the same name lands in the same section every build. */
static int api_is_ext_name(const char *nm) {
#define API_ISX(n, fn) if (strcmp(nm, #n) == 0) return 1;
    EIGS_GFX_BUILTINS(API_ISX)
    EIGS_HTTP_BUILTINS(API_ISX)
    EIGS_HTTP_REQUEST_BUILTINS(API_ISX)
    EIGS_DB_BUILTINS(API_ISX)
    EIGS_MODEL_BUILTINS(API_ISX)
    EIGS_NET_BUILTINS(API_ISX)
#undef API_ISX
    return 0;
}

int eigs_api_dump(FILE *out, int json) {
    /* Core registry on a scratch env (#459: never a hand list). */
    Env *core = env_new(NULL);
    register_builtins(core);   /* store/gfx-when-built ride inside (#742) */

    /* Lib scan over the resolver's candidate dirs. */
    ApiLibFn *fns = NULL;
    int fc = 0, fcap = 0;
    char **mods = NULL;
    int mc = 0, mcap = 0;
    char dirs[6][4096];
    int nd = lib_candidate_dirs(".", dirs, 6);
    for (int d = 0; d < nd; d++) {
        struct dirent **ents = NULL;
        int n = scandir(dirs[d], &ents, NULL, alphasort);
        if (n < 0) continue;
        for (int i = 0; i < n; i++) {
            const char *nm = ents[i]->d_name;
            size_t l = strlen(nm);
            if (l > 5 && strcmp(nm + l - 5, ".eigs") == 0)
                api_scan_file(dirs[d], nm, &fns, &fc, &fcap,
                              &mods, &mc, &mcap);
            free(ents[i]);
        }
        free(ents);
    }

    if (json) {
        fprintf(out, "{\"version\": \"%s\",\n \"builtins\": [",
                EIGENSCRIPT_VERSION);
        int b_first = 1;
        for (int i = 0; i < core->count; i++) {
            char esc[600];
            if (!core->names[i] || api_is_ext_name(core->names[i])) continue;
            lint_json_escape(core->names[i], esc, sizeof(esc));
            fprintf(out, "%s\"%s\"", b_first ? "" : ", ", esc);
            b_first = 0;
        }
        fprintf(out, "],\n \"extensions\": {");
        int g_first = 1;
#define API_GROUP(label, LIST) do {                                          \
        fprintf(out, "%s\"%s\": [", g_first ? "" : ", ", label);             \
        g_first = 0;                                                         \
        int e_first = 1;                                                     \
        LIST(API_X)                                                          \
        fprintf(out, "]");                                                   \
    } while (0)
#define API_X(nm, fn) do {                                                   \
        fprintf(out, "%s\"%s\"", e_first ? "" : ", ", #nm);                  \
        e_first = 0;                                                         \
    } while (0);
        API_GROUP("gfx",   EIGS_GFX_BUILTINS);
        API_GROUP("http",  EIGS_HTTP_BUILTINS);
        API_GROUP("http_request", EIGS_HTTP_REQUEST_BUILTINS);
        API_GROUP("db",    EIGS_DB_BUILTINS);
        API_GROUP("model", EIGS_MODEL_BUILTINS);
        API_GROUP("net",   EIGS_NET_BUILTINS);
#undef API_X
#undef API_GROUP
        fprintf(out, "},\n \"lib\": [");
        for (int i = 0; i < fc; i++) {
            char me[600], ne[600];
            lint_json_escape(fns[i].module, me, sizeof(me));
            lint_json_escape(fns[i].name, ne, sizeof(ne));
            fprintf(out, "%s\n  {\"module\": \"%s\", \"name\": \"%s\", "
                         "\"params\": ", i ? "," : "", me, ne);
            api_emit_params_json(out, fns[i].params);
            fprintf(out, "}");
        }
        fprintf(out, "\n]}\n");
    } else {
        for (int i = 0; i < core->count; i++)
            if (core->names[i] && !api_is_ext_name(core->names[i]))
                fprintf(out, "builtin %s\n", core->names[i]);
#define API_X(nm, fn) \
        fprintf(out, "extension %s %s\n", api_group_label, #nm);
#define API_GROUP(label, LIST) do {                                          \
        const char *api_group_label = label;                                 \
        (void)api_group_label;                                               \
        LIST(API_X)                                                          \
    } while (0)
        API_GROUP("gfx",   EIGS_GFX_BUILTINS);
        API_GROUP("http",  EIGS_HTTP_BUILTINS);
        API_GROUP("http_request", EIGS_HTTP_REQUEST_BUILTINS);
        API_GROUP("db",    EIGS_DB_BUILTINS);
        API_GROUP("model", EIGS_MODEL_BUILTINS);
        API_GROUP("net",   EIGS_NET_BUILTINS);
#undef API_GROUP
#undef API_X
        for (int i = 0; i < fc; i++)
            fprintf(out, "lib %s.%s(%s)\n",
                    fns[i].module, fns[i].name, fns[i].params);
    }

    for (int i = 0; i < fc; i++) {
        free(fns[i].module); free(fns[i].name); free(fns[i].params);
    }
    free(fns);
    for (int i = 0; i < mc; i++) free(mods[i]);
    free(mods);
    /* LeakSanitizer cannot trace the env's tagged slots — free explicitly
     * (same rule as builtin_name_env_free above). */
    env_decref(core);
    return 0;
}

/* Module names the linted file imported (AST-owned strings). */
#define W021_MAX_IMPORTS 128
typedef struct {
    const char *mods[W021_MAX_IMPORTS];
    int count;
} W021Imports;

static void w021_collect_imports(ASTNode *n, W021Imports *im) {
    if (!n || im->count >= W021_MAX_IMPORTS) return;
    switch (n->type) {
        case AST_IMPORT:
            im->mods[im->count++] = n->data.import.module_name;
            break;
        case AST_IF:
            for (int i = 0; i < n->data.cond.if_count; i++)
                w021_collect_imports(n->data.cond.if_body[i], im);
            for (int i = 0; i < n->data.cond.else_count; i++)
                w021_collect_imports(n->data.cond.else_body[i], im);
            break;
        case AST_LOOP:
            for (int i = 0; i < n->data.loop.body_count; i++)
                w021_collect_imports(n->data.loop.body[i], im);
            break;
        case AST_FOR:
            for (int i = 0; i < n->data.forloop.body_count; i++)
                w021_collect_imports(n->data.forloop.body[i], im);
            break;
        case AST_FUNC:
            for (int i = 0; i < n->data.func.body_count; i++)
                w021_collect_imports(n->data.func.body[i], im);
            break;
        case AST_TRY:
            for (int i = 0; i < n->data.trycatch.try_count; i++)
                w021_collect_imports(n->data.trycatch.try_body[i], im);
            for (int i = 0; i < n->data.trycatch.catch_count; i++)
                w021_collect_imports(n->data.trycatch.catch_body[i], im);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++)
                w021_collect_imports(n->data.block.stmts[i], im);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < n->data.program.count; i++)
                w021_collect_imports(n->data.program.stmts[i], im);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_RETURN:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
            break;
    }
}

static int w021_imported(const W021Imports *im, const char *module) {
    for (int i = 0; i < im->count; i++)
        if (strcmp(im->mods[i], module) == 0) return 1;
    return 0;
}

static void w021_walk(ASTNode *node, LintContext *ctx, const W021Imports *im,
                      const char *self_real) {
    if (!node) return;
    if (node->type == AST_FUNC) {
        const char *name = node->data.func.name;
        int fi = w021_func_find(name);
        /* W012/W013 own the builtin overlap (e.g. `mean`, `sum` are both a
         * builtin and a lib/stats.eigs public) — never double-report. */
        if (fi >= 0 && !is_builtin_name(name)) {
            W021Module *m = &g_w021_mods[g_w021_funcs[fi].mod];
            /* Not when the module is imported (then it's deliberate), and
             * not when the linted file IS the module that ships the name. */
            if (!w021_imported(im, m->module) &&
                (!self_real[0] || strcmp(self_real, m->path) != 0)) {
                lint_hint(ctx, node->line, "W021",
                          "define '%s' shadows lib/%s.eigs '%s' "
                          "(import %s to use it)",
                          name, m->module, name, m->module);
            }
        }
    }

    /* Recurse into children (same shape as check_builtin_shadow). */
    switch (node->type) {
        case AST_IF:
            for (int i = 0; i < node->data.cond.if_count; i++)
                w021_walk(node->data.cond.if_body[i], ctx, im, self_real);
            for (int i = 0; i < node->data.cond.else_count; i++)
                w021_walk(node->data.cond.else_body[i], ctx, im, self_real);
            break;
        case AST_LOOP:
            for (int i = 0; i < node->data.loop.body_count; i++)
                w021_walk(node->data.loop.body[i], ctx, im, self_real);
            break;
        case AST_FOR:
            for (int i = 0; i < node->data.forloop.body_count; i++)
                w021_walk(node->data.forloop.body[i], ctx, im, self_real);
            break;
        case AST_FUNC:
            for (int i = 0; i < node->data.func.body_count; i++)
                w021_walk(node->data.func.body[i], ctx, im, self_real);
            break;
        case AST_TRY:
            for (int i = 0; i < node->data.trycatch.try_count; i++)
                w021_walk(node->data.trycatch.try_body[i], ctx, im, self_real);
            for (int i = 0; i < node->data.trycatch.catch_count; i++)
                w021_walk(node->data.trycatch.catch_body[i], ctx, im, self_real);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < node->data.program.count; i++)
                w021_walk(node->data.program.stmts[i], ctx, im, self_real);
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_BINOP:
        case AST_UNARY:
        case AST_ASSIGN:
        case AST_RELATION:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_INTERROGATE:
        case AST_PREDICATE:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_UNOBSERVED:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
            break;
    }
}

void check_stdlib_shadow(ASTNode *ast, const char *path,
                         LintContext *ctx) {
    /* Anchor the lib-dir search at the linted file's directory — the same
     * base E003 gives load_file resolution. */
    char base[4096] = ".";
    if (path) {
        const char *slash = strrchr(path, '/');
        if (slash && slash != path) {
            size_t d = (size_t)(slash - path);
            if (d >= sizeof(base)) d = sizeof(base) - 1;
            memcpy(base, path, d);
            base[d] = '\0';
        }
    }
    w021_build(base);
    if (g_w021_func_count == 0) return;   /* no stdlib found — fail open */
    W021Imports im;
    im.count = 0;
    w021_collect_imports(ast, &im);
    char self_real[4096] = "";
    if (path && !realpath(path, self_real)) self_real[0] = '\0';
    w021_walk(ast, ctx, &im, self_real);
}

/* ---- E003 (#404): undefined name — no binding on any path ---- */

/* Increment one of the scope-aware name-resolution pass: a name that is READ
 * somewhere but BOUND nowhere — not by any assignment in any scope, not a
 * param/binder, not a builtin of this binary, not a top-level name of a file
 * pulled in by a literal `load_file` — cannot resolve on any execution path.
 * The runtime raises "undefined variable" the moment that path runs; this
 * surfaces it before then, including on cold branches (the classic
 * dynamic-language typo bug).
 *
 * Direction of approximation (increment two): the binding sets are
 * SCOPE-precise but path-insensitive, modeling the runtime's actual rules
 * (each empirically pinned against the interpreter):
 *   - a fresh-name `is` (or `local`) inside a function binds
 *     FUNCTION-LOCAL — invisible to siblings and to module code;
 *   - closures read enclosing function scopes (lexical chain);
 *   - module-level names are order-insensitive (a function body may read
 *     a module name bound after the definition);
 *   - a nested `define` binds its name in the ENCLOSING function only;
 *   - a module-level `for` LOOP-SCOPES its variable (reading it after
 *     the loop is a runtime error) — a function-level `for` does not;
 *   - listcomp vars and catch vars bind in the containing scope.
 * Within a scope the binder set is still an over-approximation across
 * paths ("bound on some path" suppresses — the sibling-branch
 * first-assignment case). Over-collecting can only silence a true
 * positive, never invent a false one (a false positive breaks consumer
 * CI, which runs --lint nonzero-on-warning). Path-precise "unbound on
 * THIS path" analysis is #404's remaining increment.
 *
 * External contributions (load_file targets, `# lint: loaded-by`
 * composers) stay a FLAT over-approximation collected into the base
 * env: the runtime executes those files into the caller's scope, and
 * scope-narrowing someone else's file buys precision nobody asked for
 * at real false-positive risk.
 *
 * The binding base comes from register_builtins() itself — the runtime's own
 * registry on a scratch Env — never a hand-copied list, so it cannot drift
 * from the binary (lint.c's old BUILTINS list was ~120 names behind).
 *
 * Dynamic escape (documented in docs/DIAGNOSTICS.md): `eval` appearing
 * anywhere, or a `load_file` whose argument is not a string literal, can bind
 * names invisible to static analysis — the pass disables itself for the
 * file. A literal `load_file of "path"` is resolved with the runtime's own
 * resolve_eigenscript_file_from() chain (anchored at the linted file's
 * directory, the runtime's g_script_dir for a directly-run script) and the
 * loaded file's binders are collected transitively. Any resolution, read, or
 * parse failure fails open (pass disabled), matching what the runtime could
 * not execute either. `import` binds only the module NAME (the module dict);
 * member access is a dot-key the identifier walk never touches. */

#define E003_MAX_VISITED 64
#define E003_MAX_DEPTH   16
#define E003_MAX_SCOPES  4096

typedef struct {
    Env *bind;                      /* base: builtins + flat external binders */
    Env *module_scope;              /* the linted file's top-level scope */
    Env *scope;                     /* current scope (chains to bind via parents) */
    /* Scope registry: COLLECT creates one Env per scope-introducing node
     * (function, lambda, module-level for) in walk order; FLAG re-enters
     * the same Envs by replaying the counter. Both walks visit the same
     * nodes in the same order, so the indices agree by construction. */
    Env *scopes[E003_MAX_SCOPES];
    int scope_count;                /* total created (COLLECT) */
    int scope_idx;                  /* replay cursor (FLAG) */
    int external;                   /* 1 → collecting a loaded file: bind flat */
    int dynamic;                    /* 1 → eval/computed-load_file: pass off */
    char base_dir[4096];            /* dir of the linted file */
    char *visited[E003_MAX_VISITED];/* realpath'd load_file targets */
    int visited_n;
    int depth;
} E003;

enum { E003_COLLECT, E003_FLAG };

static void e003_bind_in(Env *env, const char *name) {
    if (!name || !name[0]) return;
    if (!env_get(env, name))
        env_set_local_owned(env, name, make_null());
}

/* Bind in the CURRENT scope — external (loaded-file) collection routes
 * flat to the base env instead. */
static void e003_bind_name(E003 *e, const char *name) {
    e003_bind_in(e->external ? e->bind : e->scope, name);
}

/* Enter the next scope: COLLECT creates it as a child of the current
 * scope; FLAG replays the registry. Returns the previous scope for the
 * caller to restore. During external collection scopes are not pushed
 * (flat by design). */
static Env *e003_scope_push(E003 *e, int mode) {
    if (e->external) return e->scope;
    Env *prev = e->scope;
    if (mode == E003_COLLECT) {
        if (e->scope_count >= E003_MAX_SCOPES) { e->dynamic = 1; return prev; }
        Env *s = env_new(e->scope);
        e->scopes[e->scope_count++] = s;
        e->scope = s;
    } else {
        if (e->scope_idx >= e->scope_count) { e->dynamic = 1; return prev; }
        e->scope = e->scopes[e->scope_idx++];
    }
    return prev;
}

/* Edit-distance-1 near-miss against every name visible from `scope`
 * (walking the parent chain). Returns the first hit or NULL. Distance 1
 * only — one substitution, insertion, or deletion — so a suggestion is
 * near-certain to be the intended name and the message stays quiet
 * otherwise. */
static int e003_dist1(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    if (la == lb) {                       /* one substitution */
        int diff = 0;
        for (size_t i = 0; i < la; i++)
            if (a[i] != b[i] && ++diff > 1) return 0;
        return diff == 1;
    }
    if (la + 1 == lb) { const char *t = a; a = b; b = t; la = lb; lb = la - 1; }
    else if (la != lb + 1) return 0;
    /* a is longer by one: one deletion from a yields b */
    size_t i = 0, j = 0; int skipped = 0;
    while (i < la && j < lb) {
        if (a[i] == b[j]) { i++; j++; continue; }
        if (skipped) return 0;
        skipped = 1; i++;
    }
    return 1;
}

static const char *e003_suggest(Env *scope, const char *name) {
    if (strlen(name) < 3) return NULL;   /* 1-2 char typos suggest noise */
    for (Env *s = scope; s; s = s->parent)
        for (int i = 0; i < s->count; i++)
            if (s->names[i] && e003_dist1(name, s->names[i]))
                return s->names[i];
    return NULL;
}

static void e003_walk(ASTNode *n, E003 *e, LintContext *ctx, int mode);

/* Pull the top-level binders of a literally-named load_file target into the
 * binding set, transitively (the runtime executes the file into the global
 * env). Fails open: anything the runtime couldn't load either → pass off. */
static void e003_load(E003 *e, const char *relpath) {
    if (e->dynamic) return;
    if (e->depth >= E003_MAX_DEPTH || e->visited_n >= E003_MAX_VISITED) {
        e->dynamic = 1;
        return;
    }
    char resolved[8192], real[8192];
    if (!resolve_eigenscript_file_from(e->base_dir, relpath,
                                       resolved, sizeof(resolved))) {
        e->dynamic = 1;
        return;
    }
    if (!realpath(resolved, real))
        snprintf(real, sizeof(real), "%s", resolved);
    for (int i = 0; i < e->visited_n; i++)
        if (strcmp(e->visited[i], real) == 0) return;
    e->visited[e->visited_n++] = xstrdup(real);

    long size = 0;
    char *src = read_file_util(real, &size);
    if (!src) { e->dynamic = 1; return; }
    int saved_errors = g_parse_errors;
    g_parse_errors = 0;
    TokenList tl = tokenize(src);
    ASTNode *ast = parse(&tl);
    if (g_parse_errors > 0 || !ast) {
        e->dynamic = 1;
    } else {
        int saved_external = e->external;
        e->external = 1;   /* flat collection into the base env */
        e->depth++;
        e003_walk(ast, e, NULL, E003_COLLECT);
        e->depth--;
        e->external = saved_external;
    }
    g_parse_errors = saved_errors;
    free_ast(ast);
    free_tokenlist(&tl);
    free(src);
}

/* One walker, two modes. COLLECT gathers every binder (assign targets incl.
 * `local`, function names/params, lambda params, for/listcomp vars, catch
 * vars, list-pattern names, import module names) and spots the dynamic
 * sites; FLAG reports each AST_IDENT with no binding. Binder-name positions
 * are char* fields, never AST_IDENT children, so FLAG can flag every ident
 * it reaches. */
static void e003_walk(ASTNode *n, E003 *e, LintContext *ctx, int mode) {
    if (!n || e->dynamic) return;
    switch (n->type) {
        case AST_IDENT:
            if (mode == E003_COLLECT) {
                /* A bare (non-call-position) `eval` or `load_file` can be
                 * aliased and invoked with anything — dynamic. Call
                 * positions are intercepted at AST_RELATION below. */
                if (strcmp(n->data.ident.name, "eval") == 0 ||
                    strcmp(n->data.ident.name, "load_file") == 0)
                    e->dynamic = 1;
            } else if (!env_get(e->scope, n->data.ident.name)) {
                const char *near = e003_suggest(e->scope, n->data.ident.name);
                int nlen = (int)strlen(n->data.ident.name);
                if (near)
                    lint_error_at(ctx, n->line, n->col, nlen, "E003",
                               "undefined name '%s' — no binding on any path (did you mean '%s'?)",
                               n->data.ident.name, near);
                else
                    lint_error_at(ctx, n->line, n->col, nlen, "E003",
                               "undefined name '%s' — no binding on any path",
                               n->data.ident.name);
            }
            break;
        case AST_RELATION: {
            ASTNode *l = n->data.relation.left, *r = n->data.relation.right;
            if (mode == E003_COLLECT && l && l->type == AST_IDENT) {
                if (strcmp(l->data.ident.name, "eval") == 0) {
                    e->dynamic = 1;
                    return;
                }
                if (strcmp(l->data.ident.name, "load_file") == 0) {
                    if (r && r->type == AST_STR) e003_load(e, r->data.str);
                    else e->dynamic = 1;
                    return;
                }
            }
            e003_walk(l, e, ctx, mode);
            e003_walk(r, e, ctx, mode);
            break;
        }
        case AST_ASSIGN:
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.assign.name);
            e003_walk(n->data.assign.expr, e, ctx, mode);
            break;
        case AST_LIST_PATTERN_ASSIGN:
            if (mode == E003_COLLECT)
                for (int i = 0; i < n->data.list_pattern_assign.name_count; i++)
                    e003_bind_name(e, n->data.list_pattern_assign.names[i]);
            e003_walk(n->data.list_pattern_assign.expr, e, ctx, mode);
            break;
        case AST_FUNC: {
            /* The function NAME binds in the enclosing scope (a nested
             * define is enclosing-local — module code cannot call it);
             * params and body binders live in the function's own scope. */
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.func.name);
            Env *prev = e003_scope_push(e, mode);
            if (mode == E003_COLLECT)
                for (int i = 0; i < n->data.func.param_count; i++)
                    e003_bind_name(e, n->data.func.params[i]);
            if (n->data.func.param_defaults)
                for (int i = 0; i < n->data.func.param_count; i++)
                    e003_walk(n->data.func.param_defaults[i], e, ctx, mode);
            for (int i = 0; i < n->data.func.body_count; i++)
                e003_walk(n->data.func.body[i], e, ctx, mode);
            e->scope = prev;
            break;
        }
        case AST_LAMBDA: {
            Env *prev = e003_scope_push(e, mode);
            if (mode == E003_COLLECT)
                for (int i = 0; i < n->data.lambda.param_count; i++)
                    e003_bind_name(e, n->data.lambda.params[i]);
            e003_walk(n->data.lambda.body, e, ctx, mode);
            e->scope = prev;
            break;
        }
        case AST_FOR: {
            /* Module-level `for` LOOP-SCOPES its variable (the VM drops
             * it at loop exit — reading it after the loop is a runtime
             * error); a function-level `for` var is an ordinary local.
             * The iterable is evaluated before the var exists, so it
             * walks in the outer scope. */
            e003_walk(n->data.forloop.iter, e, ctx, mode);
            int module_level = (!e->external && e->scope == e->module_scope);
            Env *prev = e->scope;
            if (module_level) prev = e003_scope_push(e, mode);
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.forloop.var);
            for (int i = 0; i < n->data.forloop.body_count; i++)
                e003_walk(n->data.forloop.body[i], e, ctx, mode);
            e->scope = prev;
            break;
        }
        case AST_LISTCOMP:
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.listcomp.var);
            e003_walk(n->data.listcomp.expr, e, ctx, mode);
            e003_walk(n->data.listcomp.iter, e, ctx, mode);
            e003_walk(n->data.listcomp.filter, e, ctx, mode);
            break;
        case AST_TRY:
            if (mode == E003_COLLECT) e003_bind_name(e, n->data.trycatch.err_name);
            for (int i = 0; i < n->data.trycatch.try_count; i++)
                e003_walk(n->data.trycatch.try_body[i], e, ctx, mode);
            for (int i = 0; i < n->data.trycatch.catch_count; i++)
                e003_walk(n->data.trycatch.catch_body[i], e, ctx, mode);
            break;
        case AST_IMPORT:
            if (mode == E003_COLLECT)
                e003_bind_name(e, n->data.import.module_name);
            break;
        case AST_BINOP:
            e003_walk(n->data.binop.left, e, ctx, mode);
            e003_walk(n->data.binop.right, e, ctx, mode);
            break;
        case AST_UNARY:
            e003_walk(n->data.unary.operand, e, ctx, mode);
            break;
        case AST_IF:
            e003_walk(n->data.cond.cond, e, ctx, mode);
            for (int i = 0; i < n->data.cond.if_count; i++)
                e003_walk(n->data.cond.if_body[i], e, ctx, mode);
            for (int i = 0; i < n->data.cond.else_count; i++)
                e003_walk(n->data.cond.else_body[i], e, ctx, mode);
            break;
        case AST_LOOP:
            e003_walk(n->data.loop.cond, e, ctx, mode);
            for (int i = 0; i < n->data.loop.body_count; i++)
                e003_walk(n->data.loop.body[i], e, ctx, mode);
            break;
        case AST_RETURN:
            e003_walk(n->data.ret.expr, e, ctx, mode);
            break;
        case AST_BLOCK:
        case AST_UNOBSERVED:
            for (int i = 0; i < n->data.block.count; i++)
                e003_walk(n->data.block.stmts[i], e, ctx, mode);
            break;
        case AST_LIST:
            for (int i = 0; i < n->data.list.count; i++)
                e003_walk(n->data.list.elems[i], e, ctx, mode);
            break;
        case AST_INDEX:
            e003_walk(n->data.index.target, e, ctx, mode);
            e003_walk(n->data.index.index, e, ctx, mode);
            break;
        case AST_SLICE:
            e003_walk(n->data.slice.target, e, ctx, mode);
            e003_walk(n->data.slice.start, e, ctx, mode);
            e003_walk(n->data.slice.end, e, ctx, mode);
            break;
        case AST_PROGRAM:
            for (int i = 0; i < n->data.program.count; i++)
                e003_walk(n->data.program.stmts[i], e, ctx, mode);
            break;
        case AST_DICT:
            for (int i = 0; i < n->data.dict.count; i++) {
                e003_walk(n->data.dict.keys[i], e, ctx, mode);
                e003_walk(n->data.dict.vals[i], e, ctx, mode);
            }
            break;
        case AST_DOT:
            /* target only — the key is a field name, not an identifier
             * (module-qualified names stay silent by construction) */
            e003_walk(n->data.dot.target, e, ctx, mode);
            break;
        case AST_DOT_ASSIGN:
            e003_walk(n->data.dot_assign.target, e, ctx, mode);
            e003_walk(n->data.dot_assign.expr, e, ctx, mode);
            break;
        case AST_INDEX_ASSIGN:
            e003_walk(n->data.index_assign.target, e, ctx, mode);
            e003_walk(n->data.index_assign.index, e, ctx, mode);
            e003_walk(n->data.index_assign.expr, e, ctx, mode);
            break;
        case AST_MATCH:
            /* patterns are compared expressions (reads), not binders */
            e003_walk(n->data.match.expr, e, ctx, mode);
            for (int i = 0; i < n->data.match.case_count; i++) {
                e003_walk(n->data.match.patterns[i], e, ctx, mode);
                for (int j = 0; j < n->data.match.body_counts[i]; j++)
                    e003_walk(n->data.match.bodies[i][j], e, ctx, mode);
            }
            break;
        case AST_INTERROGATE:
            e003_walk(n->data.interrogate.expr, e, ctx, mode);
            e003_walk(n->data.interrogate.at_expr, e, ctx, mode);
            e003_walk(n->data.interrogate.when_expr, e, ctx, mode);  /* #868 */
            break;
        /* Nothing to do for these. Enumerated rather than covered by a `default:`
         * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
         * error here instead of a silent no-op. */
        case AST_NUM:
        case AST_STR:
        case AST_NULL:
        case AST_PREDICATE:
        case AST_BREAK:
        case AST_CONTINUE:
            break;
    }
}

void check_undefined_names(ASTNode *ast, const char *path,
                           const char *source, LintContext *ctx) {
    E003 e;
    memset(&e, 0, sizeof(e));
    e.bind = env_new(NULL);
    e.module_scope = env_new(e.bind);
    e.scope = e.module_scope;
    register_builtins(e.bind);   /* store/gfx-when-built ride inside (#742) */
    /* Extension builtins bind by NAME regardless of this binary's build
     * flags (ext_names.h, the same lists their registrars expand): the lint
     * describes the language surface, not the build — a consumer linting
     * gfx code with a default binary must not see phantom E003s. */
#define X(name, fn) e003_bind_name(&e, #name);
    EIGS_GFX_BUILTINS(X)
    EIGS_HTTP_BUILTINS(X)
    EIGS_HTTP_REQUEST_BUILTINS(X)
    EIGS_DB_BUILTINS(X)
    EIGS_MODEL_BUILTINS(X)
    EIGS_NET_BUILTINS(X)
#undef X
    /* Names the compiler resolves itself, so no registrar ever binds them:
     * `report_value of x` is a special form (#294), `trajectory of x` is one
     * too (#421), and the observed-loop machinery injects __loop_exit__ /
     * __loop_iterations__ bindings. */
    e003_bind_name(&e, "report_value");
    e003_bind_name(&e, "trajectory");
    e003_bind_name(&e, "__loop_exit__");
    e003_bind_name(&e, "__loop_iterations__");
    /* load_file resolution anchors at the linted file's directory —
     * mirrors main.c's g_script_dir extraction for a directly-run script */
    e.base_dir[0] = '.';
    e.base_dir[1] = '\0';
    if (path) {
        const char *slash = strrchr(path, '/');
        if (slash && slash != path) {
            size_t d = (size_t)(slash - path);
            if (d >= sizeof(e.base_dir)) d = sizeof(e.base_dir) - 1;
            memcpy(e.base_dir, path, d);
            e.base_dir[d] = '\0';
        }
    }
    /* #460: `# lint: loaded-by <relpath>` — this file is a library FRAGMENT
     * composed by the named file: a load_file loader (DMG's dmg.eigs), or a
     * sibling in out-of-language composition (EigenMiniSat's ROM-bundle
     * concat — the context file need not load the fragment; its binders are
     * collected either way, transitively). The named file's binding set
     * becomes the lint context, then THIS file is flagged against it — so
     * unlike `# lint: allow-file E003`, a genuine typo in the fragment
     * still fires. Path resolves like a load_file target from the
     * fragment's directory. Repeatable. Fail-open like every E003 edge: an
     * unresolvable or malformed context disables the pass for the file. */
    if (source) {
        static const char MARKER[] = "# lint: loaded-by";
        const size_t MLEN = sizeof(MARKER) - 1;
        for (const char *q = source; (q = strstr(q, MARKER)) != NULL; ) {
            q += MLEN;
            while (*q == ' ' || *q == '\t') q++;
            const char *tk = q;
            while (*q && *q != ' ' && *q != '\t' && *q != '\n' && *q != '\r') q++;
            if (q > tk && (size_t)(q - tk) < 4096) {
                char rel[4096];
                memcpy(rel, tk, (size_t)(q - tk));
                rel[q - tk] = '\0';
                e003_load(&e, rel);
            } else {
                e.dynamic = 1;
            }
        }
    }
    e003_walk(ast, &e, NULL, E003_COLLECT);
    if (!e.dynamic) {
        e.scope = e.module_scope;   /* replay from the top */
        e.scope_idx = 0;
        e003_walk(ast, &e, ctx, E003_FLAG);
    }
    for (int i = 0; i < e.visited_n; i++) free(e.visited[i]);
    /* Children first: each scope holds a counted ref on its parent. */
    for (int i = e.scope_count - 1; i >= 0; i--) env_decref(e.scopes[i]);
    env_decref(e.module_scope);
    env_decref(e.bind);
}


/* #455: per-file lint allow-list in eigs.json (residual of #399). Walk up from
 * the linted file's directory to the project root (the dir containing
 * eigs.json — the same root the module resolver's walk stops at), read its
 *   { "lint": { "allow": { "<root-relative path>": ["W003", ...] } } }
 * map, and return the newly-owned VAL_LIST of codes allowed for `path`
 * file-wide (or NULL). Caller val_decrefs. A code listed here is filtered
 * exactly like a `# lint: allow-file <code>` in the file — the escape for
 * generated/vendored files a project can't sprinkle comments into. */
static Value *eigs_json_lint_allow_for(const char *path) {
    char real[4096];
    if (!realpath(path, real)) return NULL;

    /* Walk dirname(real) upward for eigs.json; the containing dir is root. */
    char dir[4096];
    snprintf(dir, sizeof(dir), "%s", real);
    char *slash = strrchr(dir, '/');
    if (!slash) return NULL;
    *slash = '\0';

    char root[4096] = {0};
    char jsonpath[4200] = {0};
    for (int i = 0; i < 64; i++) {
        char probe[4200];
        snprintf(probe, sizeof(probe), "%.4000s/eigs.json", dir);
        if (access(probe, F_OK) == 0) {
            snprintf(root, sizeof(root), "%s", dir);
            snprintf(jsonpath, sizeof(jsonpath), "%s", probe);
            break;
        }
        char *s = strrchr(dir, '/');
        if (!s || s == dir) return NULL;
        *s = '\0';
    }
    if (!root[0]) return NULL;

    long sz = 0;
    char *js = read_file_util(jsonpath, &sz);
    if (!js) return NULL;
    int pos = 0;
    /* #797: through the fresh-parse root, never the raw parser — a stale
     * g_json_parse_err from an unrelated earlier parse in this thread made
     * this well-formed document decode empty, silently dropping every
     * allow-list entry (the seventh root missed by #777's sweep of six). */
    Value *j = eigs_json_parse_root(js, &pos);
    free(js);
    if (!j) return NULL;

    Value *result = NULL;
    if (j->type == VAL_DICT) {
        Value *lint = dict_get(j, "lint");
        if (lint && lint->type == VAL_DICT) {
            Value *allow = dict_get(lint, "allow");
            if (allow && allow->type == VAL_DICT) {
                /* real, relative to root ("<root>/lib/x.eigs" → "lib/x.eigs"). */
                size_t rl = strlen(root);
                const char *rel = real;
                if (strncmp(real, root, rl) == 0 && real[rl] == '/')
                    rel = real + rl + 1;
                Value *codes = dict_get(allow, rel);
                if (codes && codes->type == VAL_LIST) {
                    val_incref(codes);
                    result = codes;
                }
            }
        }
    }
    val_decref(j);
    return result;
}

/* Is `code` (or "all") in the eigs.json allow-list `codes` (may be NULL)? */
static int eigs_json_allows(Value *codes, const char *code) {
    if (!codes || codes->type != VAL_LIST) return 0;
    for (int i = 0; i < codes->data.list.count; i++) {
        Value *c = codes->data.list.items[i];
        if (c && c->type == VAL_STR &&
            (strcmp(c->data.str, code) == 0 || strcmp(c->data.str, "all") == 0))
            return 1;
    }
    return 0;
}

int eigenscript_lint(const char *path, int json_mode, int fail_on_warning) {
    long src_size = 0;
    char *source = read_file_util(path, &src_size);
    if (!source) {
        if (json_mode) {
            char esc[256], pesc[1024];
            lint_json_escape("cannot read file", esc, sizeof(esc));
            lint_json_escape(path, pesc, sizeof(pesc));
            printf("[{\"code\":\"E000\",\"severity\":\"error\",\"line\":0,"
                   "\"file\":\"%s\",\"message\":\"%s '%s'\"}]\n", pesc, esc, pesc);
        } else {
            fprintf(stderr, "Error: cannot read file '%s'\n", path);
        }
        return 1;
    }

    g_parse_errors = 0;
    g_first_error_line = 0;
    g_first_error_msg[0] = '\0';
    TokenList tl = tokenize(source);
    parser_set_caret_source(source);   /* #407: excerpt+caret on col errors */
    ASTNode *ast = parse(&tl);
    parser_set_caret_source(NULL);
    if (g_parse_errors > 0) {
        /* A file that doesn't parse can't be linted. Emit the first
         * structured error (the same one the LSP surfaces) as E002. */
        if (json_mode) {
            char esc[512], pesc[1024];
            lint_json_escape(g_first_error_msg[0] ? g_first_error_msg : "parse error",
                        esc, sizeof(esc));
            lint_json_escape(path, pesc, sizeof(pesc));
            printf("[{\"code\":\"E002\",\"severity\":\"error\",\"line\":%d,"
                   "\"column\":%d,\"file\":\"%s\",\"message\":\"%s\"}]\n",
                   g_first_error_line, g_first_error_col + 1, pesc, esc);
        } else {
            fprintf(stderr, "%s: %d parse error(s) [E002] — cannot lint\n",
                    path, g_parse_errors);
        }
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);
        return 1;
    }

    LintContext ctx = {0};
    lint_run_checks(ast, path, source, &ctx);

    /* #399 inline suppression: drop warnings silenced by a `# lint: allow`
     * comment on their line (or the line above), a `# lint: allow-file`, or
     * the #455 per-file eigs.json allow-list. Compact in place so suppressed
     * diagnostics vanish from both human and JSON output. */
    {
        Value *ej_allow = eigs_json_lint_allow_for(path);
        int kept = 0;
        for (int w = 0; w < ctx.warning_count; w++) {
            if (!lint_file_allows(source, ctx.warnings[w].code) &&
                !eigs_json_allows(ej_allow, ctx.warnings[w].code) &&
                !lint_suppressed(source, ctx.warnings[w].line, ctx.warnings[w].code))
                ctx.warnings[kept++] = ctx.warnings[w];
        }
        ctx.warning_count = kept;
        if (ej_allow) val_decref(ej_allow);
    }

    /* #927: a file the compiler REFUSES must not lint clean. Lint stopped at
     * the parser, so every compile-stage diagnostic — nesting too deep
     * (#912), `break` outside a loop, an un-encodable jump, a constant pool
     * past 65536 — was invisible here, and `--lint` answered "no issues
     * found" with exit 0 for a file `eigenscript` refuses to run. That is the
     * CI-facing surface: a consumer gates on the exit code, and the weakest
     * thing it can mean is "this builds".
     *
     * So compile the unit and throw the chunk away. Compiling is not running:
     * `import` and `load_file` are executed by the VM, not resolved here, so
     * lint still touches nothing but the file in front of it. Every
     * compile-stage error lands in g_parse_errors exactly the way a parse
     * error does, and the env mirrors main.c's — the registrar's bindings are
     * what a real compile of this file sees. */
    int compile_errors = 0;
    {
        g_first_error_line = 0;      /* the recorder keeps only the FIRST, and */
        g_first_error_msg[0] = '\0'; /* the parse pass may have left one behind */
        Env *cenv = env_new(NULL);
        register_builtins(cenv);     /* store/gfx-when-built ride inside (#742) */
        g_compile_module_slots = 1;
        EigsChunk *chunk = compile_ast(ast, cenv, source);
        g_compile_module_slots = 0;
        compile_errors = g_parse_errors;
        chunk_free(chunk);
        env_decref(cenv);
    }

    /* Emit. JSON goes to stdout (machine-consumable, even when clean →
     * "[]"); human text goes to stderr as before, now with the [CODE]. */
    if (json_mode) {
        char pesc[1024], mesc[512];
        lint_json_escape(path, pesc, sizeof(pesc));
        printf("[");
        for (int i = 0; i < ctx.warning_count; i++) {
            lint_json_escape(ctx.warnings[i].message, mesc, sizeof(mesc));
            printf("%s{\"code\":\"%s\",\"severity\":\"%s\",\"line\":%d,"
                   "\"file\":\"%s\",\"message\":\"%s\"}",
                   i ? "," : "", ctx.warnings[i].code, ctx.warnings[i].level,
                   ctx.warnings[i].line, pesc, mesc);
        }
        if (compile_errors > 0) {
            lint_json_escape(g_first_error_msg[0] ? g_first_error_msg
                                                  : "compile error",
                             mesc, sizeof(mesc));
            printf("%s{\"code\":\"E004\",\"severity\":\"error\",\"line\":%d,"
                   "\"file\":\"%s\",\"message\":\"%s\"}",
                   ctx.warning_count ? "," : "", g_first_error_line, pesc, mesc);
        }
        printf("]\n");
    } else {
        for (int i = 0; i < ctx.warning_count; i++) {
            fprintf(stderr, "%s:%d: %s[%s]: %s\n", path,
                    ctx.warnings[i].line, ctx.warnings[i].level,
                    ctx.warnings[i].code, ctx.warnings[i].message);
        }
        if (compile_errors > 0) {
            /* The compiler printed each diagnostic itself; this is the
             * summary line, shaped like the parse-error one above. */
            fprintf(stderr, "%s: %d compile error(s) [E004]\n",
                    path, compile_errors);
        } else if (ctx.warning_count == 0) {
            fprintf(stderr, "%s: no issues found\n", path);
        }
    }

    free_ast(ast);
    free_tokenlist(&tl);
    free(source);
    builtin_name_env_free();

    /* Exit code (#399): --lint-level warning (default) fails on any surviving
     * warning; --lint-level error makes warnings advisory (exit 0) and fails
     * only on error-severity diagnostics — so a consumer can wire
     * `--lint --json` into CI for diagnostics without warnings-as-errors.
     * Hint-severity diagnostics (#591) are pure nudges: they print but never
     * fail either level. (Parse/read errors are E-codes that already
     * returned 1 above.) */
    if (compile_errors > 0) return 1;   /* E004 is error-severity: fails at either level */
    if (!fail_on_warning) {
        int errors = 0;
        for (int i = 0; i < ctx.warning_count; i++)
            if (strcmp(ctx.warnings[i].level, "error") == 0) errors++;
        return errors > 0 ? 1 : 0;
    }
    int failing = 0;
    for (int i = 0; i < ctx.warning_count; i++)
        if (strcmp(ctx.warnings[i].level, "hint") != 0) failing++;
    return failing > 0 ? 1 : 0;
}

#else /* EIGENSCRIPT_FREESTANDING */

int is_builtin_name(const char *name) {
    (void)name;
    return 0;
}

void builtin_name_env_free(void) {}

void check_undefined_names(ASTNode *ast, const char *path,
                           const char *source, LintContext *ctx) {
    (void)ast; (void)path; (void)source; (void)ctx;
}

void check_stdlib_shadow(ASTNode *ast, const char *path, LintContext *ctx) {
    (void)ast; (void)path; (void)ctx;
}

int eigenscript_lint(const char *path, int json_mode, int fail_on_warning) {
    (void)path; (void)json_mode; (void)fail_on_warning;
    return 1;   /* lint is a host-CLI tool; no filesystem here */
}

#endif /* !EIGENSCRIPT_FREESTANDING */
