/* N14/R2.5: JSON decimal overflow refuses inside both owning decoders.
 * Include the store's production translation unit to exercise its static
 * record decoder, as the slot-layer fixture does; do not duplicate a parser. */
#include "eigs_embed.h"
#include "ext_store.c"
#include <stdio.h>

/* Core builtin entry points are normally private to builtins.c's registry. */
Value *builtin_json_decode(Value *arg);
Value *builtin_json_path(Value *arg);

static int checks, failures;
static void check(int ok, const char *name, int mode, const char *input) {
    checks++;
    if (!ok) { failures++; printf("FAIL %s strict=%d input=%s\n", name, mode, input); }
}

/* Use the production page writer to place JSON the public writer now refuses
 * into an otherwise valid file. This also reaches store_open's error wrapper. */
static int catalog_fixture(char *path, const char *json) {
    int fd = mkstemp(path);
    if (fd < 0) return 0;
    FILE *fp = fdopen(fd, "w+b");
    if (!fp) { close(fd); return 0; }
    Store store = {0};
    store.fp = fp;
    store.page_count = 1;
    Page page = {0};
    page.type = PAGE_CATALOG;
    page.count = (uint16_t)strlen(json);
    memcpy(page.data, json, page.count);
    int ok = store_write_header(&store) == 0 && store_write_page(&store, 0, &page) == 0;
    if (fclose(fp) != 0) ok = 0;
    return ok;
}

static void catalog_callers(int mode) {
    const char *inputs[] = {"{\"c\":{\"root\":1e400,\"next_id\":1}}", "{broken}"};
    for (size_t i = 0; i < sizeof inputs / sizeof inputs[0]; i++) {
        char path[] = "/tmp/eigs-overflow-catalog-XXXXXX";
        int ready = catalog_fixture(path, inputs[i]);
        check(ready, "catalog fixture created", mode, inputs[i]);
        if (ready) {
            eigs_clear_error();
            Value *arg = make_str(path);
            Value *v = builtin_store_open(arg);
            check(v && v->type == VAL_NULL && g_has_error &&
                  g_error_kind == (i == 0 ? EK_VALUE : EK_IO),
                  "catalog caller preserves decoder error", mode, inputs[i]);
            val_decref(v);
            val_decref(arg);
        }
        unlink(path);
    }
}

static void query_caller(int mode) {
    char path[] = "/tmp/eigs-overflow-query-XXXXXX";
    int ready = catalog_fixture(path, "{}");
    check(ready, "query fixture created", mode, "{}");
    if (!ready) { unlink(path); return; }
    eigs_clear_error();
    Value *path_arg = make_str(path);
    Value *handle = builtin_store_open(path_arg);
    val_decref(path_arg);
    Store *store = handle && handle->type == VAL_DICT ? store_arg(handle, "overflow fixture") : NULL;
    check(store && !g_has_error, "query fixture opened", mode, "{}");
    if (!store) { val_decref(handle); unlink(path); return; }

    const char *records[] = {"{\"v\":1}", "{\"v\":[1e400]}", "{\"v\":3}"};
    const char *keys[] = {"1", "2", "3"};
    for (size_t i = 0; i < sizeof records / sizeof records[0]; i++) {
        Value *record = make_dict(0);
        /* This lower-level production seam owns the supplied serialized text;
         * injecting it models a legacy or externally corrupted record. */
        Value *v = store_put_encoded(store, "c", record, keys[i], xstrdup(records[i]), 0);
        check(v && v->type == VAL_STR && !g_has_error,
              "query record injected", mode, records[i]);
        val_decref(v);
        val_decref(record);
    }
    Value *arg = make_list(2);
    list_append(arg, handle);
    list_append_owned(arg, make_str("c"));
    eigs_clear_error();
    Value *v = builtin_store_query(arg);
    check(v && v->type == VAL_NULL && g_has_error && g_error_kind == EK_VALUE,
          "query caller discards partial results", mode, records[1]);
    val_decref(v);

    /* The single-record caller must retain the same value error. */
    list_append_owned(arg, make_str("2"));
    eigs_clear_error();
    v = builtin_store_get(arg);
    check(g_has_error && g_error_kind == EK_VALUE,
          "get caller preserves decoder error", mode, records[1]);
    val_decref(v);
    val_decref(arg);
    eigs_clear_error();
    v = builtin_store_close(handle);
    check(v && !g_has_error, "query fixture closed", mode, "{}");
    val_decref(v);
    val_decref(handle);
    unlink(path);
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) return 2;
    const char *bad[] = {"1e400", "-1e400", "[1,1e400,2]", "{\"v\":-1e400}"};
    for (int mode = 0; mode < 2; mode++) {
        g_strict = mode;
        for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
            eigs_clear_error();
            int pos = 0;
            Value *v = eigs_json_parse_root(bad[i], &pos);
            check(g_has_error && g_error_kind == EK_VALUE,
                  "shared JSON decoder refuses", mode, bad[i]);
            val_decref(v);
            eigs_clear_error();
            v = store_json_decode(bad[i]);
            check(!v && g_has_error && g_error_kind == EK_VALUE,
                  "store decoder refuses", mode, bad[i]);
            val_decref(v);
            eigs_clear_error();
            Value *arg = make_str(bad[i]);
            v = builtin_json_decode(arg);
            check(v && v->type == VAL_NULL && g_has_error && g_error_kind == EK_VALUE,
                  "json_decode caller refuses", mode, bad[i]);
            val_decref(v);
            val_decref(arg);
        }
        const char *good[] = {"1e308", "-1e308", "1.7e308", "1e-400", "9223372036854775807"};
        for (size_t i = 0; i < sizeof good / sizeof good[0]; i++) {
            eigs_clear_error();
            int pos = 0;
            Value *v = eigs_json_parse_root(good[i], &pos);
            check(v && !g_has_error, "finite JSON control", mode, good[i]);
            val_decref(v);
            eigs_clear_error();
            v = store_json_decode(good[i]);
            check(v && !g_has_error, "finite store control", mode, good[i]);
            val_decref(v);
        }
        eigs_clear_error();
        Value *arg = make_list(2);
        list_append_owned(arg, make_str("{\"keep\":7,\"bad\":[1e400]}"));
        list_append_owned(arg, make_str("keep"));
        Value *v = builtin_json_path(arg);
        check(v && v->type == VAL_NULL && g_has_error && g_error_kind == EK_VALUE,
              "json_path refuses before walking partial document", mode, "keep");
        val_decref(v);
        val_decref(arg);
        catalog_callers(mode);
        query_caller(mode);
    }
    eigs_clear_error();
    eigs_close(st);
    printf("decoder-overflow: checks=%d failures=%d\n", checks, failures);
    return failures ? 1 : 0;
}
