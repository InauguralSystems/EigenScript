/* Inspect the actual diagnostic compile boundary with tiny ordinary inputs.
 * Including the real implementation exposes its private arming state without
 * adding production test hooks or duplicating the suppression mechanism. */
#include "eigenscript.h"
#include "state.h"
#include "trace.h"
#include "vm.h"
#include "../src/trace.c"

static EigsChunk *diagnostic_compile(ASTNode *, Env *, const char *);
#define compile_ast diagnostic_compile
#define main unused_lsp_main
#include "../src/eigenlsp.c"
#undef main
#undef compile_ast

static int passed, failed, calls;
typedef struct {
    int hist, obs, all, occ_all, names, occ_names;
    unsigned depth;
} ArmState;
static ArmState saved;

static ArmState arm_state(void) {
    ArmState s = {g_trace_hist, g_trace_obs_hist, g_arm_all, g_occ_all,
                  g_arm_count, g_occ_count, g_arm_suppress_depth};
    return s;
}
static int same_state(ArmState a, ArmState b) {
    return a.hist == b.hist && a.obs == b.obs && a.all == b.all &&
           a.occ_all == b.occ_all && a.names == b.names &&
           a.occ_names == b.occ_names && a.depth == b.depth;
}
static void check(int ok, const char *name) {
    fprintf(stderr, "%s: %s\n", ok ? "PASS" : "FAIL", name);
    if (ok) passed++; else failed++;
}
static EigsChunk *diagnostic_compile(ASTNode *ast, Env *env, const char *src) {
    calls++;
    ArmState at_entry = saved;
    at_entry.depth++;
    check(same_state(arm_state(), at_entry),
          "diagnostic entry preserves state and enters suppression");
    check(g_obs_gate_scan_enabled == 0, "diagnostic entry disables eager scan");
    /* These ordinary requests would each arm a distinct channel if the
     * suppression scope were missing. No workload-size/timing oracle. */
    trace_arm_history_name("boundary_history");
    trace_arm_occurrences_name("boundary_occurrence");
    trace_arm_history_all();
    trace_arm_occurrences_all();
    trace_arm_observer_history();
    check(same_state(arm_state(), at_entry),
          "all diagnostic arming requests are inert");
    EigsChunk *chunk = compile_ast(ast, env, src);
    check(same_state(arm_state(), at_entry),
          "real diagnostic compilation leaves arming state unchanged");
    return chunk;
}

static void document_case(const char *src, int error, int scan) {
    Document *doc = doc_create("file:///bounded-arming.eigs");
    doc->text = xstrdup(src);
    doc->text_len = (int)strlen(src);
    doc_analyze(doc);
    check(doc->ast && g_parse_errors == 0, "tiny document parses");
    saved = arm_state();
    g_obs_gate_scan_enabled = scan;
    int before_calls = calls;
    send_diagnostics(doc);
    check(calls == before_calls + 1, "actual diagnostic compiler called once");
    check(same_state(arm_state(), saved), "diagnostics preserves host arming state");
    check(g_obs_gate_scan_enabled == scan, "diagnostics restores eager-scan state");
    check((g_parse_errors > 0) == error, "compile success/error verdict retained");
    doc_remove(doc->uri);
}

int main(void) {
    EigsState *st = eigs_state_new();
    if (!st || !eigs_thread_attach(st)) return 1;
    const char *valid = "x is 1\nq is what is x when 1\nprint of q\n";
    const char *error = "x is 1\nq is what is x when 1\nbreak\n";
    for (int armed = 0; armed < 2; armed++) {
        trace_flag_store(g_trace_hist_storage, armed);
        trace_flag_store(g_trace_obs_hist_storage, armed);
        document_case(valid, 0, armed);
        document_case(error, 1, !armed);
    }
    /* Nontrivial existing name sets and nested suppression must survive. */
    trace_arm_occurrences_name("host_retained");
    trace_arm_suppress_begin();
    document_case(valid, 0, 1);
    document_case(error, 1, 0);
    trace_arm_suppress_end();
    check(g_arm_suppress_depth == 0, "outer suppression ends normally");
    int names = g_arm_count, occurrences = g_occ_count;
    Document *doc = doc_create("file:///normal-compile.eigs");
    doc->text = xstrdup("later is 1\nq is what is later when 1\nprint of q\n");
    doc_analyze(doc);
    Env *env = env_new(NULL);
    register_builtins(env);
    EigsChunk *chunk = compile_ast(doc->ast, env, doc->text);
    check(chunk && g_parse_errors == 0, "subsequent ordinary compile succeeds");
    check(g_arm_count == names + 1 && g_occ_count == occurrences + 1,
          "subsequent ordinary compilation arms both name sets");
    check(g_arm_count > 0 && g_occ_count > 0 &&
          strcmp(g_arm_names[0], "host_retained") == 0 &&
          strcmp(g_occ_names[0], "host_retained") == 0,
          "existing host registrations survive diagnostics");
    chunk_free(chunk);
    env_decref(env);
    doc_remove(doc->uri);
    trace_shutdown();
    eigs_thread_detach();
    eigs_state_destroy(st);
    fprintf(stderr, "lsp arming: %d passed, %d failed\n", passed, failed);
    return failed ? 1 : 0;
}
