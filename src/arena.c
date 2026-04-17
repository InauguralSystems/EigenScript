/*
 * EigenScript Arena Allocator
 * Bump allocation with mark/reset for bounded computation.
 * Also provides free_weight_val for safe heap reclamation
 * of make_num_permanent Values during training.
 */

#include "eigenscript.h"

Arena g_arena = {0};

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
    return p;
}

void* xcalloc(size_t nmemb, size_t size) {
    void *p = calloc(nmemb, size);
    if (!p) x_oom(safe_size_mul(nmemb, size));
    return p;
}

void* xrealloc(void *p, size_t size) {
    void *q = realloc(p, size);
    if (!q && size) x_oom(size);
    return q;
}

char* xstrdup(const char *s) {
    if (!s) s = "";
    char *r = strdup(s);
    if (!r) x_oom(strlen(s) + 1);
    return r;
}

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
}

void* arena_alloc(size_t size) {
    size = (size + 7) & ~(size_t)7;

    if (g_arena.offset + size > ARENA_BLOCK_SIZE) {
        g_arena.current_block++;
        if (g_arena.current_block >= g_arena.block_count) {
            if (g_arena.block_count >= ARENA_MAX_BLOCKS) {
                return xcalloc(1, size);
            }
            g_arena.blocks[g_arena.block_count] = xmalloc(ARENA_BLOCK_SIZE);
            g_arena.block_count++;
        }
        g_arena.offset = 0;
    }

    void *ptr = g_arena.blocks[g_arena.current_block] + g_arena.offset;
    memset(ptr, 0, size);
    g_arena.offset += size;
    g_arena.total_allocated += size;
    return ptr;
}

void arena_track_string(char *s) {
    if (g_arena.string_count >= g_arena.string_capacity) {
        int new_cap = g_arena.string_capacity < 1024 ? 1024 : g_arena.string_capacity * 2;
        g_arena.strings = xrealloc(g_arena.strings, new_cap * sizeof(char*));
        g_arena.string_capacity = new_cap;
    }
    g_arena.strings[g_arena.string_count++] = s;
}

void arena_mark_pos(void) {
    g_arena.mark_block = g_arena.current_block;
    g_arena.mark_offset = g_arena.offset;
    g_arena.mark_string_count = g_arena.string_count;
    g_arena.active = 1;
}

void arena_reset_to_mark(void) {
    for (int i = g_arena.mark_string_count; i < g_arena.string_count; i++)
        free(g_arena.strings[i]);
    g_arena.string_count = g_arena.mark_string_count;

    g_arena.current_block = g_arena.mark_block;
    g_arena.offset = g_arena.mark_offset;

    g_arena.active = 0;
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
