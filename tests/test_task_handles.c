/* #2481: the scheduler handle seam is integer typed, including its callers. */
#include "eigenscript.h"
#include "vm.h"
#include <assert.h>

_Static_assert(_Generic(&task_handle_pack,
    int64_t (*)(int, uint32_t): 1, default: 0), "task_handle_pack must return int64_t");
_Static_assert(_Generic(&task_handle_unpack,
    int (*)(int64_t, int *, uint32_t *): 1, default: 0), "task_handle_unpack must take int64_t");
_Static_assert(_Generic(&task_current_id,
    int64_t (*)(void): 1, default: 0), "task_current_id must return int64_t");

int main(void) {
    int id;
    uint32_t gen;
    assert(task_handle_pack(0, UINT32_MAX) == 0);
    assert(task_handle_pack(1, 1) == 257);
    for (int slot = 1; slot < HANDLE_TABLE_SIZE; slot++) {
        int64_t packed = task_handle_pack(slot, UINT32_MAX);
        assert(task_handle_unpack(packed, &id, &gen));
        assert(id == slot && gen == UINT32_MAX);
        assert(task_handle_unpack(packed, NULL, NULL));
    }
    assert(!task_handle_unpack(INT64_MIN, &id, &gen));
    assert(!task_handle_unpack(-1, &id, &gen));
    assert(!task_handle_unpack(0, &id, &gen));
    assert(!task_handle_unpack(1, &id, &gen));
    assert(!task_handle_unpack(HANDLE_TABLE_SIZE, &id, &gen));
    assert(!task_handle_unpack(((int64_t)UINT32_MAX + 1) * HANDLE_TABLE_SIZE + 1, &id, &gen));
    assert(!task_handle_unpack(INT64_MAX, &id, &gen));
    puts("PASS: integer task handle types, generation boundaries and invalid ids");
    return 0;
}
