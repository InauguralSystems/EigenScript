/*
 * Filesystem utilities — the leaf TU (#744).
 *
 * Reading a source file and resolving a module request are needed by the VM
 * (OP_IMPORT), the compiler (the #915 observer gate's load pre-pass), main.c,
 * fmt.c, lint_host.c and the embedding API. They used to live inside the
 * builtins layer, so every one of those consumers reached DOWNWARD into a
 * builtins TU and nothing could link file reading without it — which is the
 * measured reason the LSP and fuzz link lists gave up on hand-picked subsets.
 * They are not builtins: no `Value`, no `Env`, no registration.
 *
 * Whole-TU freestanding gate, the ext_store.c / builtins_host.c pattern: with
 * no filesystem the resolvers are linkable stubs that resolve nothing, and
 * read_file_util does not exist at all (callers guard on
 * EIGENSCRIPT_FREESTANDING — see compiler.c's load pre-pass).
 */

#include "eigenscript.h"
#include "fsutil.h"

#if EIGENSCRIPT_FREESTANDING

/* Linkable no-op surface: nothing resolves without a filesystem. */
int resolve_eigenscript_file_from(const char *base, const char *path,
                                   char *resolved, size_t resolved_cap) {
    (void)base; (void)path; (void)resolved; (void)resolved_cap;
    return 0;   /* nothing resolves without a filesystem */
}

int resolve_eigenscript_file_from_ex(const char *base, const char *path,
                                      char *resolved, size_t resolved_cap,
                                      int *origin) {
    (void)base; (void)path; (void)resolved; (void)resolved_cap;
    if (origin) *origin = EIGS_RESOLVE_PROJECT;
    return 0;
}

int eigs_import_resolve(const char *base, const char *name,
                        char *resolved, size_t resolved_cap,
                        char *shadowed, size_t shadowed_cap) {
    (void)base; (void)name; (void)resolved; (void)resolved_cap;
    if (shadowed && shadowed_cap) shadowed[0] = '\0';
    return 0;   /* nothing resolves without a filesystem */
}

#else /* host profile */

#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

/* Resolve once at state/CLI startup. In particular dyld's answer may contain
 * a symlink or relative components, so it must be canonicalized before chdir.
 * No state bridge macros here: embedders call this before thread attachment. */
char *eigs_executable_path(const char *argv0) {
#if defined(__APPLE__)
    uint32_t capacity = 0;
    (void)_NSGetExecutablePath(NULL, &capacity);
    if (capacity) {
        char *path = xmalloc(capacity);
        int rc = _NSGetExecutablePath(path, &capacity);
        char *absolute = rc == 0 ? realpath(path, NULL) : NULL;
        free(path);
        if (absolute) return absolute;
    }
#elif defined(__linux__)
    char path[4096];
    ssize_t n = readlink("/proc/self/exe", path, sizeof(path));
    /* A full buffer is truncated, not a usable executable path. */
    if (n > 0 && n < (ssize_t)sizeof(path) && path[0] == '/') {
        path[n] = '\0';
        return xstrdup(path);
    }
#endif
    if (!argv0 || !*argv0) return NULL;
    if (strchr(argv0, '/')) return realpath(argv0, NULL);

    /* A bare argv[0] names a PATH lookup, not a file in the startup cwd.
     * Empty/relative entries are interpreted now, while that cwd is intact. */
    const char *entry = getenv("PATH");
    if (!entry) entry = "/bin:/usr/bin";
    size_t name_len = strlen(argv0);
    for (;;) {
        const char *colon = strchr(entry, ':');
        size_t dir_len = colon ? (size_t)(colon - entry) : strlen(entry);
        char *candidate = xmalloc(dir_len + name_len + 2);
        memcpy(candidate, entry, dir_len);
        size_t offset = dir_len;
        if (dir_len) candidate[offset++] = '/';
        memcpy(candidate + offset, argv0, name_len + 1);
        struct stat st;
        char *absolute = NULL;
        if (access(candidate, X_OK) == 0 && stat(candidate, &st) == 0 && S_ISREG(st.st_mode))
            absolute = realpath(candidate, NULL);
        free(candidate);
        if (absolute) return absolute;
        if (!colon) return NULL;
        entry = colon + 1;
    }
}

/* File I/O helper — used by load_file and main() */
char* read_file_util(const char *path, long *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    /* #314: fopen succeeds on a directory, and ftell then reports LONG_MAX —
     * which sailed straight into xmalloc's fatal-OOM abort. Reject
     * directories here so callers hit their existing clean error paths. */
    struct stat st;
    if (fstat(fileno(f), &st) == 0 && !S_ISREG(st.st_mode)) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    if (size < 0 || size == LONG_MAX) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_SET);
    char *buf = xmalloc(size + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, size, f);
    fclose(f);
    if ((long)got != size) { free(buf); return NULL; }
    buf[size] = '\0';
    if (out_size) *out_size = size;
    return buf;
}

static int try_resolve_path(const char *candidate, char *resolved, size_t resolved_cap) {
    if (!candidate || access(candidate, F_OK) != 0) return 0;
    snprintf(resolved, resolved_cap, "%s", candidate);
    return 1;
}

/* Canonical file provenance: symlink entry points and nested loads agree with
 * import. Heap-owned because this helper also runs on compiler paths. */
char *eigs_file_directory(const char *path) {
    char *dir = realpath(path, NULL);
    if (!dir) dir = xstrdup(path);
    char *slash = strrchr(dir, '/');
    if (slash == dir) dir[1] = '\0';
    else if (slash) *slash = '\0';
    else { free(dir); dir = xstrdup("."); }
    return dir;
}

static int parent_directory(char *dir) {
    char *slash = strrchr(dir, '/');
    if (!slash || strcmp(dir, "/") == 0) return 0;
    if (slash == dir) dir[1] = '\0';
    else *slash = '\0';
    return 1;
}

/* The nearest eigs.json is the project boundary, for both package lookup
 * and root-relative paths. No cwd or one-parent fallback participates. */
static char *project_directory(const char *base) {
    char *dir = realpath(base, NULL);
    if (!dir) return NULL;
    char *marker = xmalloc(strlen(dir) + sizeof("/eigs.json"));
    do {
        size_t dir_len = strlen(dir);
        memcpy(marker, dir, dir_len);
        memcpy(marker + dir_len, "/eigs.json", sizeof("/eigs.json"));
        if (access(marker, F_OK) == 0) { free(marker); return dir; }
    } while (parent_directory(dir));
    free(marker);
    free(dir);
    return NULL;
}

void eigs_file_resolve_error(const char *operation, const char *base,
                            const char *path, int line) {
    char *project = project_directory(base);
    const char *home = getenv("HOME");
    rt_error(EK_IO, line,
        "%s: cannot read '%s' (not found or unreadable); tried containing directory '%s', "
        "eigs_modules walk, %s%s; stdlib roots '%s/../<path>', "
        "'%s/../lib/eigenscript', '%s/.local/lib/eigenscript' "
        "(also stripping lib/; absolute paths are used as-is)",
        operation, path, base, project ? "project root " : "no eigs.json above ",
        project ? project : base, g_exe_dir, g_exe_dir,
        home ? home : "<HOME unset>");
    free(project);
}

/* Phase 0c: walk from `base` upward looking for
 *   <dir>/eigs_modules/<name>/<name>.eigs
 * at each level. Stop at the project root (a directory containing
 * eigs.json) — its eigs_modules/ is checked once, then we don't go
 * higher. Only fires for bare `<name>.eigs` requests (no slashes); the
 * resolver's existing chain still handles paths with directory
 * components. Bounded to 64 levels for safety. */
static int try_eigs_modules_walk(const char *base, const char *path,
                                  char *resolved, size_t resolved_cap) {
    if (!base || !base[0] || !path) return 0;
    if (strchr(path, '/')) return 0;
    size_t plen = strlen(path);
    if (plen < 6 || strcmp(path + plen - 5, ".eigs") != 0) return 0;
    if (plen - 5 >= 512) return 0;

    char name[512];
    memcpy(name, path, plen - 5);
    name[plen - 5] = '\0';

    char cur[4096];
    snprintf(cur, sizeof(cur), "%s", base);

    for (int i = 0; i < 64; i++) {
        char candidate[8192];
        snprintf(candidate, sizeof(candidate),
                 "%.3000s/eigs_modules/%.500s/%.500s.eigs",
                 cur, name, name);
        if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

        char marker[4400];
        snprintf(marker, sizeof(marker), "%.4000s/eigs.json", cur);
        if (access(marker, F_OK) == 0) return 0;

        if (!parent_directory(cur)) return 0;
    }
    return 0;
}

int resolve_eigenscript_file_from_ex(const char *base, const char *path,
                                      char *resolved, size_t resolved_cap,
                                      int *origin) {
    char candidate[8192];

    /* #904: report which half of the chain answered. The tail steps below
     * are the *installed stdlib roots* (`<prefix>/lib/eigenscript/`, from
     * `make install`), and they answer a bare `<name>.eigs` request just as
     * readily as `lib/<name>.eigs` — so a hit there is the stdlib wearing a
     * project-shaped request, not a project file. Callers that must tell
     * the two apart (import's collision diagnostic) pass `origin`. */
#define RESOLVED(step)                                                       \
    do { if (origin) *origin = (step); return 1; } while (0)

    if (origin) *origin = EIGS_RESOLVE_PROJECT;
    if (!path || !resolved || resolved_cap == 0) return 0;
    if (!base || !base[0]) base = eigs_current_file_dir();

    if (path[0] == '/') {
        return try_resolve_path(path, resolved, resolved_cap);
    }

    snprintf(candidate, sizeof(candidate), "%.4000s/%.4000s", base, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

    if (try_eigs_modules_walk(base, path, resolved, resolved_cap)) return 1;

    char *project = project_directory(base);
    if (project) {
        snprintf(candidate, sizeof(candidate), "%.4000s/%.4000s", project, path);
        free(project);
        if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;
    }

    snprintf(candidate, sizeof(candidate), "%.4000s/../%.4000s", g_exe_dir, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

    snprintf(candidate, sizeof(candidate), "%.4000s/../lib/eigenscript/%.4000s", g_exe_dir, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) RESOLVED(EIGS_RESOLVE_STDLIB_ROOT);

    if (strncmp(path, "lib/", 4) == 0) {
        snprintf(candidate, sizeof(candidate), "%.4000s/../lib/eigenscript/%.4000s", g_exe_dir, path + 4);
        if (try_resolve_path(candidate, resolved, resolved_cap)) RESOLVED(EIGS_RESOLVE_STDLIB_ROOT);
    }

    const char *home = getenv("HOME");
    if (home) {
        snprintf(candidate, sizeof(candidate), "%.2000s/.local/lib/eigenscript/%.4000s", home, path);
        if (try_resolve_path(candidate, resolved, resolved_cap)) RESOLVED(EIGS_RESOLVE_STDLIB_ROOT);

        if (strncmp(path, "lib/", 4) == 0) {
            snprintf(candidate, sizeof(candidate), "%.2000s/.local/lib/eigenscript/%.4000s", home, path + 4);
            if (try_resolve_path(candidate, resolved, resolved_cap)) RESOLVED(EIGS_RESOLVE_STDLIB_ROOT);
        }
    }

    return 0;
#undef RESOLVED
}

int resolve_eigenscript_file_from(const char *base, const char *path,
                                   char *resolved, size_t resolved_cap) {
    return resolve_eigenscript_file_from_ex(base, path, resolved, resolved_cap, NULL);
}

/* #1046: THE import resolver. `import NAME` used to be resolved INLINE in the
 * OP_IMPORT handler (vm.c), which is why #915 shipped with the import half of
 * the observer gate open: the gate's compile-time pass needed to find the
 * module an import will run, and a second copy of that logic would have been
 * a resolver free to drift from the first (#737). Now both callers ask this
 * one function, so the file the gate inspects is the file the import runs.
 *
 * The chain (#821/#904/#1056): the PROJECT request `<name>.eigs` and the
 * STDLIB request `lib/<name>.eigs` are both probed through
 * resolve_eigenscript_file_from_ex; a project hit that came from an installed
 * stdlib root is the stdlib wearing a project-shaped request and is demoted;
 * project wins over stdlib. Returns 1 with `resolved` filled. `shadowed`
 * (optional) receives the realpath of a stdlib module that a GENUINELY
 * distinct project file shadows, else "" -- the caller decides whether to
 * warn (the VM does, once per name; the gate's pass never does). */
int eigs_import_resolve(const char *base, const char *name,
                        char *resolved, size_t resolved_cap,
                        char *shadowed, size_t shadowed_cap) {
    /* HEAP, not stack. This runs inside vm_execute's OP_IMPORT handler, and
     * vm_execute recurses on nested imports; ~28 KiB of path scratch per
     * level is the shape .claude/rules/c-runtime-memory.md's C-stack rule
     * (and tools/embed_stack_soak.sh's 64 KiB rlimit) exists to catch. */
    struct { char request[4096]; char stdlib_buf[8192]; char ureal[8192]; char sreal[8192]; } *b;
    int user_origin = EIGS_RESOLVE_PROJECT;
    int rc = 0;
    if (shadowed && shadowed_cap) shadowed[0] = '\0';
    if (!name || !resolved || resolved_cap == 0) return 0;
    b = malloc(sizeof *b);
    if (!b) return 0;   /* unresolvable is the conservative answer everywhere this is asked */

    snprintf(b->request, sizeof(b->request), "%.1024s.eigs", name);
    int user_hit = resolve_eigenscript_file_from_ex(base, b->request, resolved, resolved_cap,
                                                     &user_origin);
    snprintf(b->request, sizeof(b->request), "lib/%.1024s.eigs", name);
    int stdlib_hit = resolve_eigenscript_file_from_ex(base, b->request, b->stdlib_buf,
                                                       sizeof(b->stdlib_buf), NULL);
    if (user_hit && stdlib_hit && user_origin == EIGS_RESOLVE_STDLIB_ROOT)
        user_hit = 0;
    if (!user_hit && !stdlib_hit) goto done;
    rc = 1;
    if (!user_hit) {
        snprintf(resolved, resolved_cap, "%s", b->stdlib_buf);
        goto done;
    }
    if (stdlib_hit && shadowed && shadowed_cap) {
        /* Same-file double hit is possible (a chain step that resolves both
         * request shapes to one path after symlinks) -- only a genuinely
         * forked resolution is a collision. */
        if (!realpath(resolved, b->ureal)) snprintf(b->ureal, sizeof(b->ureal), "%s", resolved);
        if (!realpath(b->stdlib_buf, b->sreal)) snprintf(b->sreal, sizeof(b->sreal), "%s", b->stdlib_buf);
        if (strcmp(b->ureal, b->sreal) != 0) snprintf(shadowed, shadowed_cap, "%s", b->sreal);
    }
done:
    free(b);
    return rc;
}

#endif /* EIGENSCRIPT_FREESTANDING */

/* Base-relative wrapper, in BOTH profiles: it forwards to
 * resolve_eigenscript_file_from, which exists in both (the freestanding arm
 * resolves nothing). Lived in builtins.c only because the chain did. */
int resolve_eigenscript_file(const char *path, char *resolved, size_t resolved_cap) {
    return resolve_eigenscript_file_from(eigs_current_file_dir(), path, resolved, resolved_cap);
}
