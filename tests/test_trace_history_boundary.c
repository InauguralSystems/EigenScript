/* #1575: ordinary direct-producer checks for the shared-history boundary.
 * Include the actual implementation, as test_lsp_arming.c does, to inspect
 * metadata without production test hooks. Count calls to real retention
 * helpers; all values are immediate numbers and all names remain live.
 * No descriptors, eval, resource workloads, concurrent producers or faults. */
#include "eigenscript.h"
#include "state.h"
#include "trace.h"
#include "vm.h"
#include <unistd.h>

static unsigned retain_calls, incref_calls;
static void counted_retain(const char *name) {
    retain_calls++;
    env_intern_scope_retain(name);
}
static void counted_incref(EigsSlot value) {
    incref_calls++;
    slot_incref(value);
}
#define env_intern_scope_retain counted_retain
#define slot_incref counted_incref
#include "../src/trace.c"
#undef slot_incref
#undef env_intern_scope_retain

static int passed, failed;
static void check(int ok, const char *name) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    if (ok) passed++; else failed++;
}
static int number(EigsSlot value, double want) {
    return slot_is_num(value) && value.d == want;
}
static int host_values(const PrevEntry *e) {
    return e->has_current && number(e->current, 22) &&
           e->has_prev && number(e->prev, 11);
}
static int host_lines(const PrevEntry *e) {
    return e->hist_count == 2 && e->history &&
           e->history[0].line == 10 && number(e->history[0].value, 11) &&
           e->history[1].line == 20 && number(e->history[1].value, 22);
}
static int host_counts(const PrevEntry *e) {
    return e->lc_count == 2 && e->lc && e->lc[0].line == 10 &&
           e->lc[0].count == 1 && e->lc[1].line == 20 && e->lc[1].count == 1;
}
static int host_occurrences(const PrevEntry *e) {
    return e->occ_total == 2 && e->occ_count == 2 && e->occ &&
           number(e->occ[0].value, 11) && number(e->occ[1].value, 22);
}
static int host_observers(const PrevEntry *e) {
    return e->hist_count == 2 && e->history &&
           e->history[1].obs_valid && e->history[1].entropy == .5 &&
           e->history[1].dH == .25 && e->history[1].last_entropy == .125;
}
static int host_occ_observers(const PrevEntry *e) {
    return e->occ_count == 2 && e->occ && e->occ[1].obs_valid &&
           e->occ[1].entropy == .5 && e->occ[1].dH == .25 &&
           e->occ[1].last_entropy == .125;
}
typedef struct {
    char bytes[4096];
    size_t used;
    int assignments, overflow;
} Tape;
static void capture(const char *bytes, size_t len, void *userdata) {
    Tape *t = userdata;
    if (len >= 2 && bytes[0] == 'A' && bytes[1] == ' ') t->assignments++;
    if (len >= sizeof(t->bytes) - t->used) { t->overflow = 1; return; }
    memcpy(t->bytes + t->used, bytes, len);
    t->used += len;
    t->bytes[t->used] = '\0';
}

int main(void) {
    alarm(10);
    EigsState *state = eigs_state_new();
    if (!state) return 2;
    if (!eigs_thread_attach(state)) { eigs_state_destroy(state); return 2; }
    const char *fresh = env_intern_name("boundary_fresh");
    const char *host = env_intern_name("boundary_host");
    const char *unarmed = env_intern_name("boundary_unarmed");
    Tape tape = {{0}, 0, 0, 0};

    /* No history table exists yet. All four public assignment routes must
     * return before metadata or retention calls when the branch is active. */
    g_sandbox_active = 1;
    trace_assign(fresh, slot_from_num(1));
    trace_assign_filtered(fresh, slot_from_num(2));
    trace_assign_at_line(fresh, slot_from_num(3), 10);
    trace_assign_filtered_at_line(fresh, slot_from_num(4), 20);
    trace_record_obs(fresh, .5, .25, .125);
    g_sandbox_active = 0;
    check(!g_prev_tab && g_prev_count == 0 && g_prev_cap == 0,
          "active boundary creates no history table or name entry");
    check(retain_calls == 0, "active boundary does not retain names");
    check(incref_calls == 0, "active boundary does not enter slot retention");

    /* Trusted unarmed producers still record; the ordinary filtered twin
     * still narrows. End this small control table before the host scenario. */
    trace_assign_at_line(fresh, slot_from_num(11), 10);
    EigsSlot direct = slot_null();
    int direct_found = trace_query_at(0, fresh, 10, &direct);
    check(direct_found && number(direct, 11),
          "trusted unarmed producer records outside boundary");
    if (direct_found) slot_decref(direct);
    trace_assign_filtered_at_line(unarmed, slot_from_num(22), 20);
    EigsSlot filtered = slot_null();
    int filtered_found = trace_query_at(0, unarmed, 20, &filtered);
    check(!filtered_found, "ordinary filtered producer still omits unarmed values");
    if (filtered_found) slot_decref(filtered);
    trace_thread_release();

    trace_arm_occurrences_name(host);
    trace_assign_at_line(host, slot_from_num(11), 10);
    trace_record_obs(host, .25, .125, .0625);
    trace_assign_filtered_at_line(host, slot_from_num(22), 20);
    trace_record_obs(host, .5, .25, .125);
    check(g_prev_tab && g_prev_count == 1, "host producer creates one entry");
    if (!g_prev_tab) goto done;
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, host);
    check(e->name == host, "host name has the expected pointer identity");
    if (!e->name) goto done;
    check(host_values(e), "host current and previous values record");
    check(host_lines(e), "host explicit line history records");
    check(host_counts(e), "host line counts record");
    check(host_occurrences(e), "host occurrence ring records");
    check(host_observers(e), "host history observer metadata records");
    check(host_occ_observers(e), "host occurrence observer metadata records");
    check(retain_calls > 0 && incref_calls > 0,
          "host control reaches real name and slot retention helpers");

    int count = g_prev_count, capacity = g_prev_cap;
    PrevEntry *table = g_prev_tab;
    unsigned retained = retain_calls, incremented = incref_calls;
    g_sandbox_active = 1;
    trace_assign(host, slot_from_num(33));
    trace_assign_filtered_at_line(host, slot_from_num(44), 30);
    trace_record_obs(host, 9, 8, 7);
    g_sandbox_active = 0;
    check(g_prev_tab == table && g_prev_count == count && g_prev_cap == capacity,
          "active boundary preserves existing table metadata");
    check(host_values(e), "active boundary preserves host current and previous");
    check(host_lines(e), "active boundary preserves host line history");
    check(host_counts(e), "active boundary preserves host assignment counts");
    check(host_occurrences(e), "active boundary preserves host occurrence ring");
    check(host_observers(e), "active boundary preserves host observer snapshot");
    check(host_occ_observers(e), "active boundary preserves occurrence snapshot");
    check(retain_calls == retained, "existing-name boundary retains no names");
    check(incref_calls == incremented, "existing-name boundary retains no slots");

    /* Opening a sink deliberately widens arming. That must affect the tape,
     * not override the history boundary. The same fixed name remains live. */
    trace_set_sink(capture, &tape);
    g_sandbox_active = 1;
    trace_assign(fresh, slot_from_num(5));
    trace_assign_filtered(fresh, slot_from_num(6));
    trace_assign_at_line(fresh, slot_from_num(7), 30);
    trace_assign_filtered_at_line(fresh, slot_from_num(8), 40);
    trace_record_obs(host, 9, 8, 7);
    g_sandbox_active = 0;
    check(!tape.overflow && tape.assignments == 4 &&
          strstr(tape.bytes, "A 0 boundary_fresh=5\n") &&
          strstr(tape.bytes, "A 0 boundary_fresh=6\n") &&
          strstr(tape.bytes, "A 0 boundary_fresh=7\n") &&
          strstr(tape.bytes, "A 0 boundary_fresh=8\n"),
          "all assignment routes retain exact ordinary tape records");
    check(g_arm_all && g_prev_tab == table && g_prev_count == count &&
          g_prev_cap == capacity,
          "wildcard recording does not create a history name entry");
    check(retain_calls == retained && incref_calls == incremented,
          "wildcard recording does not enter history retention helpers");
    check(host_observers(e) && host_occ_observers(e),
          "wildcard recording preserves both host observer snapshots");

    trace_assign_at_line(host, slot_from_num(33), 30);
    trace_record_obs(host, .75, .5, .25);
    check(number(e->current, 33) && number(e->prev, 22),
          "host producer resumes after boundary ends");
    EigsSlot answer = slot_null();
    int found = trace_query_at(0, host, 20, &answer);
    check(found && number(answer, 22), "earlier explicit-line answer survives");
    if (found) slot_decref(answer);
    check(e->hist_count == 3 && e->history[2].obs_valid &&
          e->history[2].entropy == .75 && e->history[2].dH == .5,
          "host history observer recording resumes");
    check(e->occ_total == 3 && e->occ_count == 3 && e->occ[2].obs_valid &&
          e->occ[2].entropy == .75 && e->occ[2].dH == .5,
          "host occurrence observer recording resumes");
    trace_assign_tape_only(fresh, slot_from_num(9));
    check(tape.assignments == 6 && strstr(tape.bytes, "A 0 boundary_fresh=9\n") &&
          g_prev_count == count,
          "explicit tape-only producer remains tape-only outside boundary");

done:
    g_sandbox_active = 0;
    trace_set_sink(NULL, NULL);
    trace_shutdown();
    eigs_thread_detach();
    eigs_state_destroy(state);
    printf("history boundary: %d passed, %d failed (32 declared)\n", passed, failed);
    return passed == 32 && failed == 0 ? 0 : 1;
}
