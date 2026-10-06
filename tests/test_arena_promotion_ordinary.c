/* Ordinary acyclic promotion only. Source arena remains live throughout every
 * source inspection; heap child has an independent test ref through cleanup.
 * No sandbox refusal, cycle, worker, fault plant, or historical reproduction. */
#include "eigenscript.h"
#include "state.h"
#include "eigs_embed.h"
#include <stdio.h>
#include <string.h>
static int passed, failed, examined;
#define CHECK(label, condition) do { ++examined; if (condition) { ++passed; printf("PASS: %s\n",label); } else { ++failed; printf("FAIL: %s\n",label); } } while (0)
int main(void) {
    EigsState *state = eigs_open();
    if (!state) { fputs("SETUP FAIL: state\n",stderr); return 2; }
    int old_gc = g_gc_enabled;
    g_gc_enabled = 0; /* Cleanup accounting stays deterministic, no collector. */
    Value *heap = make_list_heap(1); /* Independent test owner throughout. */
    list_append_owned(heap, make_num_permanent(7));
    arena_mark_pos();
    Value *number = make_num(3);
    Value *text = make_str("tiny");
    Value *child = make_list(2), *source = make_list(3);
    /* Source edges borrow ordinary live inputs; no arena-held heap incref. */
    child->data.list.items[0] = number; child->data.list.items[1] = text;
    child->data.list.count = 2;
    source->data.list.items[0] = child; source->data.list.items[1] = child;
    source->data.list.items[2] = heap; source->data.list.count = 3;
    Value **source_items = source->data.list.items, **child_items = child->data.list.items;
    int source_cap = source->data.list.capacity, child_cap = child->data.list.capacity;
    Value *copy_num = promote_if_arena(number), *copy_text = promote_if_arena(text);
    CHECK("number is a distinct heap copy", copy_num != number && !copy_num->arena && copy_num->type == VAL_NUM);
    CHECK("number retains finite value", VAL_NUM_RAW(copy_num) == 3);
    CHECK("string is a distinct heap copy", copy_text != text && !copy_text->arena && copy_text->type == VAL_STR);
    CHECK("string retains exact bytes and length", val_str_len(copy_text) == 4 && !memcmp(copy_text->data.str,"tiny",4));
    Value *copy = promote_if_arena(source);
    CHECK("root is a distinct heap list", copy != source && !copy->arena && copy->type == VAL_LIST);
    CHECK("root population retained", copy->data.list.count == 3);
    Value *inner = copy->data.list.items[0];
    CHECK("repeated child keeps one copied identity", inner == copy->data.list.items[1] && inner != child);
    CHECK("child is a heap list", !inner->arena && inner->type == VAL_LIST && inner->data.list.count == 2);
    CHECK("copied child owns two root edges", inner->refcount == 2);
    CHECK("nested number retains value", inner->data.list.items[0]->type == VAL_NUM && VAL_NUM_RAW(inner->data.list.items[0]) == 3);
    CHECK("nested string retains bytes", val_str_len(inner->data.list.items[1]) == 4 && !memcmp(inner->data.list.items[1]->data.str,"tiny",4));
    CHECK("heap child preserves identity", copy->data.list.items[2] == heap);
    CHECK("heap child acquires one copied edge", heap->refcount == 2);
    CHECK("root source fields restored", source->data.list.items == source_items && source->data.list.count == 3 && source->data.list.capacity == source_cap);
    CHECK("child source fields restored", child->data.list.items == child_items && child->data.list.count == 2 && child->data.list.capacity == child_cap);
    /* Acyclic live root with explicit test ownership: exercise registration
     * and normal drain, not the unexecuted worker/concurrent registration path. */
    g_gc_enabled = 1;
    int before = state->gc_val_count;
    gc_note_possible_root_deferred(copy);
    CHECK("registration adds one live candidate pin", copy->gc_buffered && copy->refcount == 2 && state->gc_val_count == before + 1);
    gc_note_possible_root_deferred(copy);
    CHECK("registration deduplicates live pin", copy->refcount == 2 && state->gc_val_count == before + 1);
    gc_collect_value_candidates();
    CHECK("normal drain releases candidate pin", !copy->gc_buffered && copy->refcount == 1 && state->gc_val_count == 0);
    g_gc_enabled = 0;
    val_decref(copy_num); val_decref(copy_text); val_decref(copy);
    CHECK("copied graph releases heap edge", heap->refcount == 1);
    CHECK("independently owned heap child remains valid", heap->data.list.count == 1 && VAL_NUM_RAW(heap->data.list.items[0]) == 7);
    val_decref(heap);
    arena_reset_to_mark(); /* No arena pointer is inspected afterward. */
    g_gc_enabled = old_gc;
    eigs_close(state);
    printf("ordinary arena promotion: %d passed, %d failed (20 declared)\n",passed,failed);
    return failed || examined != 20 || passed != 20;
}
