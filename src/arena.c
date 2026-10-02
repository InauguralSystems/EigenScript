/*
 * EigenScript Arena Allocator
 * Bump allocation with mark/reset for bounded computation.
 * Also provides free_weight_val for safe heap reclamation
 * of make_num_permanent Values during training.
 */

#include "eigenscript.h"
#include <inttypes.h>

/* The public header routes runtime frees through the measurement hook.  Keep
 * that macro active: in the generated amalgamation it must also cover source
 * files emitted after this one.  The two allocator-internal libc releases use
 * (free)(p), which deliberately avoids expansion of the function-like macro. */

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
    /* #915: the observer gate's eager pass may have stderr muted; a fatal
     * message must not be discarded because a module was loaded by one spelling
     * rather than another. No-op when nothing is muted. */
    eigs_obs_unmute_for_fatal();
    fprintf(stderr, "eigenscript: out of memory (requested %zu bytes)\n", size);
    abort();
}

/* #1319 measurement phase: requested-byte accounting, deliberately without a
 * cap.  It is opt-in so the normal allocator path pays one predictable branch.
 * A private open-addressed table records requested sizes without changing the
 * layout of allocations (important while the model is still being measured).
 * Table storage itself uses libc calloc/free and is therefore explicitly not
 * included in the reported numbers. */
typedef struct {
    void *ptr;
    size_t size;
} AllocStatSlot;

static pthread_once_t g_alloc_stats_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_alloc_stats_lock = PTHREAD_MUTEX_INITIALIZER;
/* -1 until pthread_once reads the environment, then 0/1.  The overwhelmingly
 * common disabled path is one relaxed load and branch, not a pthread_once call
 * at every allocation and release. */
int eigs_alloc_stats_enabled = -1;
static AllocStatSlot *g_alloc_stats_tab;
static size_t g_alloc_stats_cap;
static size_t g_alloc_stats_count;
/* Includes tombstones.  Growing on occupied slots, rather than only live
 * entries, guarantees every unsuccessful probe eventually reaches NULL. */
static size_t g_alloc_stats_occupied;
static uint64_t g_alloc_stats_cumulative;
static uint64_t g_alloc_stats_live;
static uint64_t g_alloc_stats_peak;
static char g_alloc_stats_tombstone;
#define ALLOC_STATS_TOMB ((void *)&g_alloc_stats_tombstone)

static size_t alloc_stats_hash(void *ptr) {
    uintptr_t x = (uintptr_t)ptr;
    x >>= 3;
    x ^= x >> 17;
    x *= UINT64_C(0x9e3779b97f4a7c15);
    return (size_t)x;
}

static void alloc_stats_report(void) {
    pthread_mutex_lock(&g_alloc_stats_lock);
    fprintf(stderr,
            "eigs-alloc-stats: cumulative=%" PRIu64 " live=%" PRIu64
            " peak=%" PRIu64 " tracked=%zu\n",
            g_alloc_stats_cumulative, g_alloc_stats_live,
            g_alloc_stats_peak, g_alloc_stats_count);
    pthread_mutex_unlock(&g_alloc_stats_lock);
}

static void alloc_stats_init(void) {
    const char *v = getenv("EIGS_ALLOC_STATS");
    int enabled = v && *v && strcmp(v, "0") != 0;
    if (enabled) {
        g_alloc_stats_cap = 4096;
        g_alloc_stats_tab = calloc(g_alloc_stats_cap, sizeof(*g_alloc_stats_tab));
        if (!g_alloc_stats_tab) x_oom(g_alloc_stats_cap * sizeof(*g_alloc_stats_tab));
        atexit(alloc_stats_report);
    }
    __atomic_store_n(&eigs_alloc_stats_enabled, enabled, __ATOMIC_RELEASE);
}

static size_t alloc_stats_find(void *ptr, int *found) {
    size_t mask = g_alloc_stats_cap - 1;
    size_t pos = alloc_stats_hash(ptr) & mask;
    size_t tomb = SIZE_MAX;
    for (size_t probes = 0; probes < g_alloc_stats_cap; probes++) {
        void *key = g_alloc_stats_tab[pos].ptr;
        if (!key) {
            *found = 0;
            return tomb == SIZE_MAX ? pos : tomb;
        }
        if (key == ptr) {
            *found = 1;
            return pos;
        }
        if (key == ALLOC_STATS_TOMB && tomb == SIZE_MAX) tomb = pos;
        pos = (pos + 1) & mask;
    }
    /* A table containing only live entries and tombstones has no empty
     * sentinel.  Insertions reuse the first tombstone; absent removals merely
     * report not found.  The occupied-load growth check normally prevents
     * this fallback, but keeping the probe bounded makes the invariant local. */
    *found = 0;
    return tomb;
}

static void alloc_stats_grow(void) {
    size_t old_cap = g_alloc_stats_cap;
    AllocStatSlot *old = g_alloc_stats_tab;
    g_alloc_stats_cap *= 2;
    g_alloc_stats_tab = calloc(g_alloc_stats_cap, sizeof(*g_alloc_stats_tab));
    if (!g_alloc_stats_tab) x_oom(g_alloc_stats_cap * sizeof(*g_alloc_stats_tab));
    for (size_t i = 0; i < old_cap; i++) {
        if (old[i].ptr && old[i].ptr != ALLOC_STATS_TOMB) {
            int found;
            size_t pos = alloc_stats_find(old[i].ptr, &found);
            g_alloc_stats_tab[pos] = old[i];
        }
    }
    g_alloc_stats_occupied = g_alloc_stats_count;
    (free)(old);
}

static void alloc_stats_add_enabled(void *ptr, size_t size, size_t cumulative) {
    /* Always rendezvous with initialization on this slow path.  A caller can
     * observe -1 just before another thread publishes disabled (0); reloading
     * 0 here and skipping pthread_once used to enter an uninitialized table. */
    pthread_once(&g_alloc_stats_once, alloc_stats_init);
    if (!__atomic_load_n(&eigs_alloc_stats_enabled, __ATOMIC_ACQUIRE)) return;
    pthread_mutex_lock(&g_alloc_stats_lock);
    if ((g_alloc_stats_occupied + 1) * 10 >= g_alloc_stats_cap * 7)
        alloc_stats_grow();
    int found;
    size_t pos = alloc_stats_find(ptr, &found);
    if (found) g_alloc_stats_live -= g_alloc_stats_tab[pos].size;
    else {
        if (!g_alloc_stats_tab[pos].ptr) g_alloc_stats_occupied++;
        g_alloc_stats_count++;
    }
    g_alloc_stats_tab[pos].ptr = ptr;
    g_alloc_stats_tab[pos].size = size;
    g_alloc_stats_live += size;
    g_alloc_stats_cumulative += cumulative;
    if (g_alloc_stats_live > g_alloc_stats_peak)
        g_alloc_stats_peak = g_alloc_stats_live;
    pthread_mutex_unlock(&g_alloc_stats_lock);
}

static inline __attribute__((always_inline))
void alloc_stats_add(void *ptr, size_t size, size_t cumulative) {
    int enabled = __atomic_load_n(&eigs_alloc_stats_enabled, __ATOMIC_RELAXED);
    if (__builtin_expect(enabled == 0, 1) || !ptr) return;
    alloc_stats_add_enabled(ptr, size, cumulative);
}

static size_t alloc_stats_remove_enabled(void *ptr) {
    pthread_once(&g_alloc_stats_once, alloc_stats_init);
    if (!__atomic_load_n(&eigs_alloc_stats_enabled, __ATOMIC_ACQUIRE)) return 0;
    pthread_mutex_lock(&g_alloc_stats_lock);
    int found;
    size_t pos = alloc_stats_find(ptr, &found);
    size_t old_size = 0;
    if (found) {
        old_size = g_alloc_stats_tab[pos].size;
        g_alloc_stats_live -= old_size;
        g_alloc_stats_count--;
        g_alloc_stats_tab[pos].ptr = ALLOC_STATS_TOMB;
        g_alloc_stats_tab[pos].size = 0;
    }
    pthread_mutex_unlock(&g_alloc_stats_lock);
    return old_size;
}

static inline __attribute__((always_inline)) size_t alloc_stats_remove(void *ptr) {
    int enabled = __atomic_load_n(&eigs_alloc_stats_enabled, __ATOMIC_RELAXED);
    if (__builtin_expect(enabled == 0, 1) || !ptr) return 0;
    return alloc_stats_remove_enabled(ptr);
}

size_t safe_size_mul(size_t a, size_t b) {
    if (a == 0 || b == 0) return 0;
    if (a > SIZE_MAX / b) return SIZE_MAX;
    return a * b;
}

void* xmalloc(size_t size) {
    void *p = malloc(size);
    if (!p) x_oom(size);
    alloc_stats_add(p, size, size);
    EIGS_POISON_MEM(p, size);
    return p;
}

void* xcalloc(size_t nmemb, size_t size) {
    void *p = calloc(nmemb, size);
    size_t total = safe_size_mul(nmemb, size);
    if (!p) x_oom(total);
    alloc_stats_add(p, total, total);
    return p;
}

void* xrealloc(void *p, size_t size) {
#if defined(EIGS_POISON) && defined(__GLIBC__)
    size_t old_usable = p ? malloc_usable_size(p) : 0;
#endif
    size_t old_size = alloc_stats_remove(p);
    void *q = realloc(p, size);
    if (!q && size) x_oom(size);
    alloc_stats_add(q, size, size > old_size ? size - old_size : 0);
#if defined(EIGS_POISON) && defined(__GLIBC__)
    /* Poison only the grown tail — the copied prefix is live data. */
    if (q && size > old_usable)
        memset((char *)q + old_usable, EIGS_POISON_BYTE, size - old_usable);
#endif
    return q;
}

char* xstrdup(const char *s) {
    if (!s) s = "";
    size_t n = strlen(s) + 1;
    char *r = xmalloc(n);
    memcpy(r, s, n);
    return r;
}

void eigs_alloc_stats_free(void *p) {
    alloc_stats_remove(p);
    (free)(p);
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
    /* Un-poison BEFORE the write: the block is NOACCESS (arena_init / growth /
     * arena_reset_to_mark), so a memset first is itself the "Invalid write"
     * memcheck exists to report — the nightly full corpus found exactly that
     * (5 of 229 programs red on its first run). */
    ARENA_VG_DEFINED(ptr, size);  /* addressable; the memset below makes it defined (zeroed) */
    memset(ptr, 0, size);
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
        eigs_alloc_stats_free(g_arena.strings[i]);
    g_arena.string_count = g_arena.mark_string_count;

    for (int i = g_arena.mark_fallback_count; i < g_arena.fallback_count; i++)
        eigs_alloc_stats_free(g_arena.fallbacks[i]);
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
        eigs_alloc_stats_free(g_arena.strings[i]);
    eigs_alloc_stats_free(g_arena.strings);
    for (int i = 0; i < g_arena.fallback_count; i++)
        eigs_alloc_stats_free(g_arena.fallbacks[i]);
    eigs_alloc_stats_free(g_arena.fallbacks);
    for (int i = 0; i < g_arena.block_count; i++)
        eigs_alloc_stats_free(g_arena.blocks[i]);
    memset(&g_arena, 0, sizeof(g_arena));
}

void free_weight_val(Value *v) {
    if (!v || v->type != VAL_NUM) return;
    for (int i = 0; i < g_arena.block_count; i++) {
        char *block_start = g_arena.blocks[i];
        char *block_end = block_start + ARENA_BLOCK_SIZE;
        if ((char*)v >= block_start && (char*)v < block_end) return;
    }
    eigs_alloc_stats_free(v);
}
