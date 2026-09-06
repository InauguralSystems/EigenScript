/* #1056: exercise file provenance through the real embedding API. */
#include "eigs_embed.h"
#include "eigenscript.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int checks, failures, scope_checks;

static EigsValue *scope_clean(EigsValue *arg) {
    scope_checks++;
    checks++;
    if (g_import_resolve_dir[0]) {
        failures++;
        printf("embed_roads: FAIL: execution override at %s: %s\n",
               eigs_value_as_string(arg), g_import_resolve_dir);
    }
    return eigs_value_new_null();
}

static EigsValue *host_file(EigsValue *path) {
    /* Internal provenance stress probe, not a general API reentrancy promise. */
    return eigs_eval_file(eigs_value_as_string(path));
}

static void pair(const char *label, EigsValue *value) {
    const char *actual[2] = {"<invalid>", "<invalid>"};
    EigsValue *items[2] = {NULL, NULL};
    if (value && eigs_value_type(value) == EIGS_TYPE_LIST &&
        eigs_value_list_len(value) == 2) {
        for (int i = 0; i < 2; i++) {
            items[i] = eigs_value_list_get(value, i);
            if (items[i] && eigs_value_type(items[i]) == EIGS_TYPE_STR)
                actual[i] = eigs_value_as_string(items[i]);
        }
    }
    printf("embed_roads: %s: %s / %s\n", label, actual[0], actual[1]);
    checks++;
    if (eigs_has_error() || strcmp(actual[0], "HELPER") || strcmp(actual[1], "HELPER")) {
        failures++;
        printf("embed_roads: FAIL: %s expected HELPER / HELPER\n", label);
    }
    for (int i = 0; i < 2; i++) eigs_value_release(items[i]);
    eigs_value_release(value);
}

static void string_peer(const char *label) {
    EigsValue *v = eigs_eval_string("eval of \"load_file of \\\"peer.eigs\\\"\"");
    checks++;
    if (eigs_has_error() || !v || eigs_value_type(v) != EIGS_TYPE_STR ||
        strcmp(eigs_value_as_string(v), "STRING")) {
        failures++;
        printf("embed_roads: FAIL: %s expected STRING\n", label);
    }
    eigs_value_release(v);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *root = realpath(argv[1], NULL);
    if (!root) { puts("embed_roads: FAIL: missing fixture tree"); return 1; }
    char *entry = malloc(strlen(root) + 32);
    if (!entry) return 2;
    sprintf(entry, "%s/nofile", root);
    if (chdir(entry)) return 2;
    EigsState *state = eigs_open();
    if (!state) return 2;
    eigs_register_function("host_scope_clean", scope_clean);
    eigs_register_function("host_file", host_file);
    string_peer("no-file string before file eval");
    sprintf(entry, "%s/entry.eigs", root);
    pair("eval_file", eigs_eval_file(entry));
    pair("eval_string deferred functions", eigs_eval_string("[go of [], direct of []]"));
    /* The host passes the absolute name as a value, not quoted source text. */
    EigsValue *path = eigs_value_new_string(entry);
    eigs_set_global("entry_path", path);
    eigs_value_release(path);
    pair("eval_file from helper callback", eigs_eval_string("call_file of entry_path"));
    pair("eval_string load", eigs_eval_string("load_file of entry_path"));
    sprintf(entry, "%s/import_entry.eigs", root);
    pair("eval_file import", eigs_eval_file(entry));
    path = eigs_value_new_string(entry);
    eigs_set_global("entry_path", path);
    eigs_value_release(path);
    pair("eval_string import", eigs_eval_string("load_file of entry_path"));
    string_peer("no-file string after file eval");
    sprintf(entry, "%s/missing.eigs", root);
    EigsValue *missing = eigs_eval_file(entry);
    checks++;
    if (missing) { failures++; puts("embed_roads: FAIL: missing file accepted"); }
    eigs_value_release(missing);
    string_peer("no-file string after missing file");
    checks++;
    if (scope_checks < 12) { failures++; puts("embed_roads: FAIL: too few execution scope probes"); }
    eigs_close(state);
    free(entry);
    free(root);
    printf("embed_roads: checks=%d scope_checks=%d failures=%d\n", checks, scope_checks, failures);
    return failures != 0;
}
