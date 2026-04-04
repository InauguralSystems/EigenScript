/*
 * EigenScript Arena Allocator
 * Bump allocation with mark/reset for bounded computation.
 * Also provides free_weight_val for safe heap reclamation
 * of make_num_permanent Values during training.
 */

#include "eigenscript.h"

Arena g_arena = {0};

void arena_init(void) {
    g_arena.blocks[0] = malloc(ARENA_BLOCK_SIZE);
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
                return calloc(1, size);
            }
            g_arena.blocks[g_arena.block_count] = malloc(ARENA_BLOCK_SIZE);
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
        g_arena.strings = realloc(g_arena.strings, new_cap * sizeof(char*));
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
