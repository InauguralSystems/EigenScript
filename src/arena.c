/*
 * EigenScript Arena Allocator
 * Bump allocation with mark/reset for bounded computation.
 * Also provides free_weight_val for safe heap reclamation
 * of make_num_permanent Values during training.
 */

#include "eigenscript.h"

#if defined(EIGS_POISON) && defined(__GLIBC__)
#include <malloc.h>   /* malloc_usable_size, for xrealloc tail poisoning */
#endif

/* g_arena is now a per-OS-thread Arena* set up by eigs_thread_attach.
 * The TLS definition lives in state.c. */

/* #298 follow-up: make the arena's INTERIOR visible to Valgrind. The arena is a
 * bump allocator over a few big malloc'd blocks, so Valgrind otherwise sees one
 * defined block and can't catch use-after-reset — an arena value that escapes
 * its mark/reset scope and is read after the region is reused (ASan can't see
 * it either: the block was never free()'d). We mark released arena space
 * NOACCESS so such a read is flagged, and DEFINED on each alloc (the bytes are
 * memset to 0 → DEFINED, not UNDEFINED: the allocator zero-inits, so there's no
 * uninitialized-read class here to detect). Gated behind EIGS_VALGRIND (set by
 * `make valgrind`); a no-op with zero cost in normal/release builds. */
#ifdef EIGS_VALGRIND
#include <valgrind/memcheck.h>
#define ARENA_VG_NOACCESS(p, n) VALGRIND_MAKE_MEM_NOACCESS((p), (n))
#define ARENA_VG_DEFINED(p, n)  VALGRIND_MAKE_MEM_DEFINED((p), (n))
#else
#define ARENA_VG_NOACCESS(p, n) ((void)0)
#define ARENA_VG_DEFINED(p, n)  ((void)0)
#endif

static void x_oom(size_t size) {
    fprintf(stderr, "eigenscript: out of memory (requested %zu bytes)\n", size);
    abort();
}

size_t safe_size_mul(size_t a, size_t b) {
    if (a == 0 || b == 0) return 0;
    if (a > SIZE_MAX / b) return SIZE_MAX;
    return a * b;
}

void* xmalloc(size_t size) {
    void *p = malloc(size);
    if (!p) x_oom(size);
    EIGS_POISON_MEM(p, size);
    return p;
}

void* xcalloc(size_t nmemb, size_t size) {
    void *p = calloc(nmemb, size);
    if (!p) x_oom(safe_size_mul(nmemb, size));
    return p;
}

void* xrealloc(void *p, size_t size) {
#if defined(EIGS_POISON) && defined(__GLIBC__)
    size_t old_usable = p ? malloc_usable_size(p) : 0;
#endif
    void *q = realloc(p, size);
    if (!q && size) x_oom(size);
#if defined(EIGS_POISON) && defined(__GLIBC__)
    /* Poison only the grown tail — the copied prefix is live data. */
    if (q && size > old_usable)
        memset((char *)q + old_usable, EIGS_POISON_BYTE, size - old_usable);
#endif
    return q;
}

char* xstrdup(const char *s) {
    if (!s) s = "";
    char *r = strdup(s);
    if (!r) x_oom(strlen(s) + 1);
    return r;
}

#if !EIGENSCRIPT_FREESTANDING
FILE* xfopen_write(const char *path, const char *mode) {
    /* Bare fopen("w"/"a") creates files with mode 0666 & ~umask; a permissive
     * umask leaves the file world-writable (CodeQL cpp/world-writable-file-creation).
     * Use explicit POSIX open + fdopen so the on-disk mode is pinned to 0644. */
    if (!path || !mode) return NULL;
    int has_w = 0, has_a = 0, plus = 0;
    for (const char *p = mode; *p; p++) {
        if (*p == 'w') has_w = 1;
        else if (*p == 'a') has_a = 1;
        else if (*p == '+') plus = 1;
        /* 'b' is a POSIX no-op; other chars ignored */
    }
    int flags;
    if (has_w) flags = (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC;
    else if (has_a) flags = (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND;
    else return fopen(path, mode);  /* read-only or unknown — defer */
    int fd = open(path, flags, 0644);
    if (fd < 0) return NULL;
    FILE *fp = fdopen(fd, mode);
    if (!fp) { close(fd); return NULL; }
    return fp;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

void* xmalloc_array(size_t nmemb, size_t size) {
    size_t total = safe_size_mul(nmemb, size);
    if (total == SIZE_MAX) x_oom(SIZE_MAX);
    return xmalloc(total);
}

void* xcalloc_array(size_t nmemb, size_t size) {
    if (safe_size_mul(nmemb, size) == SIZE_MAX) x_oom(SIZE_MAX);
    return xcalloc(nmemb, size);
}

void* xrealloc_array(void *p, size_t nmemb, size_t size) {
    size_t total = safe_size_mul(nmemb, size);
    if (total == SIZE_MAX) x_oom(SIZE_MAX);
    return xrealloc(p, total);
}

void arena_init(void) {
    g_arena.blocks[0] = xmalloc(ARENA_BLOCK_SIZE);
    ARENA_VG_NOACCESS(g_arena.blocks[0], ARENA_BLOCK_SIZE);  /* nothing allocated yet */
    g_arena.block_count = 1;
    g_arena.current_block = 0;
    g_arena.offset = 0;
    g_arena.mark_block = 0;
    g_arena.mark_offset = 0;
    g_arena.active = 0;
    g_arena.total_allocated = 0;
    g_arena.strings = NULL;
    g_arena.string_count = 0;
    g_arena.string_capacity = 0;
    g_arena.mark_string_count = 0;
    g_arena.fallbacks = NULL;
    g_arena.fallback_count = 0;
    g_arena.fallback_capacity = 0;
    g_arena.mark_fallback_count = 0;
}

void* arena_alloc(size_t size) {
    size = (size + 7) & ~(size_t)7;

    if (g_arena.offset + size > ARENA_BLOCK_SIZE) {
        g_arena.current_block++;
        if (g_arena.current_block >= g_arena.block_count) {
            if (g_arena.block_count >= ARENA_MAX_BLOCKS) {
                void *p = xcalloc(1, size);
                /* Track overflow alloc so arena_reset can free it */
                if (g_arena.fallback_count >= g_arena.fallback_capacity) {
                    int new_cap = g_arena.fallback_capacity < 64 ? 64 : g_arena.fallback_capacity * 2;
                    g_arena.fallbacks = xrealloc_array(g_arena.fallbacks, new_cap, sizeof(char*));
                    g_arena.fallback_capacity = new_cap;
                }
                g_arena.fallbacks[g_arena.fallback_count++] = p;
                return p;
            }
            g_arena.blocks[g_arena.block_count] = xmalloc(ARENA_BLOCK_SIZE);
            ARENA_VG_NOACCESS(g_arena.blocks[g_arena.block_count], ARENA_BLOCK_SIZE);
            g_arena.block_count++;
        }
        g_arena.offset = 0;
    }

    void *ptr = g_arena.blocks[g_arena.current_block] + g_arena.offset;
    memset(ptr, 0, size);
    ARENA_VG_DEFINED(ptr, size);  /* now addressable + defined (zeroed) */
    g_arena.offset += size;
    g_arena.total_allocated += size;
    return ptr;
}

void arena_track_string(char *s) {
    if (g_arena.string_count >= g_arena.string_capacity) {
        int new_cap = g_arena.string_capacity < 1024 ? 1024 : g_arena.string_capacity * 2;
        g_arena.strings = xrealloc_array(g_arena.strings, new_cap, sizeof(char*));
        g_arena.string_capacity = new_cap;
    }
    g_arena.strings[g_arena.string_count++] = s;
}

void arena_mark_pos(void) {
    g_arena.mark_block = g_arena.current_block;
    g_arena.mark_offset = g_arena.offset;
    g_arena.mark_string_count = g_arena.string_count;
    g_arena.mark_fallback_count = g_arena.fallback_count;
    g_arena.active = 1;
}

void arena_reset_to_mark(void) {
    for (int i = g_arena.mark_string_count; i < g_arena.string_count; i++)
        free(g_arena.strings[i]);
    g_arena.string_count = g_arena.mark_string_count;

    for (int i = g_arena.mark_fallback_count; i < g_arena.fallback_count; i++)
        free(g_arena.fallbacks[i]);
    g_arena.fallback_count = g_arena.mark_fallback_count;

    /* Poison everything allocated since the mark as NOACCESS so a read of an
     * arena value that escaped this scope is caught (re-marked DEFINED when the
     * region is next handed out by arena_alloc). Capture the high-water first. */
    int    hi_block  = g_arena.current_block;
    size_t hi_offset = g_arena.offset;

    g_arena.current_block = g_arena.mark_block;
    g_arena.offset = g_arena.mark_offset;

#ifdef EIGS_VALGRIND
    for (int b = g_arena.mark_block; b <= hi_block && b < g_arena.block_count; b++) {
        size_t from = (b == g_arena.mark_block) ? g_arena.mark_offset : 0;
        size_t to   = (b == hi_block) ? hi_offset : ARENA_BLOCK_SIZE;
        if (to > from) ARENA_VG_NOACCESS(g_arena.blocks[b] + from, to - from);
    }
#else
    (void)hi_block; (void)hi_offset;
#endif

    g_arena.active = 0;
}

void arena_destroy(void) {
    for (int i = 0; i < g_arena.string_count; i++)
        free(g_arena.strings[i]);
    free(g_arena.strings);
    for (int i = 0; i < g_arena.fallback_count; i++)
        free(g_arena.fallbacks[i]);
    free(g_arena.fallbacks);
    for (int i = 0; i < g_arena.block_count; i++)
        free(g_arena.blocks[i]);
    memset(&g_arena, 0, sizeof(g_arena));
}

void free_weight_val(Value *v) {
    if (!v || v->type != VAL_NUM) return;
    for (int i = 0; i < g_arena.block_count; i++) {
        char *block_start = g_arena.blocks[i];
        char *block_end = block_start + ARENA_BLOCK_SIZE;
        if ((char*)v >= block_start && (char*)v < block_end) return;
    }
    free(v);
}
