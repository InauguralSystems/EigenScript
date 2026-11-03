/* R23-1: public error text is insufficient. The C writer must return NULL
 * after a non-finite scalar appears anywhere in its recursive encoding.
 * Link the actual runtime objects, not copied encoders or faulted readers. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "eigs_embed.h"
#include "eigenscript.h"

static unsigned checks, failures, refused_cases, finite_cases;

static void writer_check(int ok, const char *label, const char *shape,
                         const char *number) {
    checks++;
    if (!ok) {
        failures++;
        printf("writer-json: FAIL %s shape=%s number=%s\n", label, shape, number);
    }
}

/* Every shape owns the supplied value; the list/dict have a finite prefix,
 * so refusal must also discard a partially constructed JSON string. */
static Value *writer_shape(Value *value, int shape) {
    if (shape == 0) return value;
    if (shape >= 3) {
        Value *buffer = eigs_value_new_buffer(1);
        /* A raw stored payload is the writer's input, not a scalar reader. */
        buffer->data.buffer.data[0] = VAL_F64_RAW(value);
        val_decref(value);
        if (shape == 3) return buffer;
        value = buffer;
        shape = 1;
    }
    if (shape == 1) {
        Value *list = make_list_heap(2);
        list_append_owned(list, make_int(7));
        list_append_owned(list, value);
        return list;
    }
    Value *dict = make_dict(2);
    dict_set_owned(dict, "finite", make_int(7));
    dict_set_owned(dict, "value", value);
    return dict;
}

static void refused(double number, const char *name, int shape) {
    static const char *shapes[] = {"scalar", "list", "dict", "buffer", "nested-buffer"};
    eigs_clear_error();
    Value *root = writer_shape(make_float(number), shape);
    int refs = root->refcount;
    char *text = eigs_json_encode(root);
    refused_cases++;
    writer_check(text == NULL, "failure return", shapes[shape], name);
    writer_check(g_has_error && g_error_kind == EK_VALUE,
                 "value error", shapes[shape], name);
    writer_check(g_has_error && strstr(g_error_raw, "deeper than") == NULL,
                 "numeric diagnostic retained", shapes[shape], name);
    writer_check(root->refcount == refs, "borrowed ownership", shapes[shape], name);
    free(text);
    val_decref(root);
    eigs_clear_error();
}

static void finite_control(int shape) {
    static const char *shapes[] = {"scalar", "list", "dict", "buffer", "nested-buffer"};
    static const char *expected[] = {
        "1.25", "[7,1.25]", "{\"finite\":7,\"value\":1.25}", "null", "[7,null]"
    };
    eigs_clear_error();
    Value *root = writer_shape(make_float(1.25), shape);
    int refs = root->refcount;
    char *text = eigs_json_encode(root);
    finite_cases++;
    writer_check(text && strcmp(text, expected[shape]) == 0,
                 "finite encoding", shapes[shape], "1.25");
    writer_check(!g_has_error, "finite no error", shapes[shape], "1.25");
    writer_check(root->refcount == refs, "borrowed ownership", shapes[shape], "1.25");
    free(text);
    val_decref(root);
    eigs_clear_error();
}

int main(void) {
    EigsState *state = eigs_open();
    if (!state) return 2;
    eigs_state_set_strict(state, 0);
    for (int shape = 0; shape < 5; shape++) {
        refused(NAN, "nan", shape);
        refused(INFINITY, "inf", shape);
        refused(-INFINITY, "negative-inf", shape);
        finite_control(shape);
    }
    eigs_clear_error();
    Value *integer = make_int(INT64_C(9007199254740993));
    int refs = integer->refcount;
    char *text = eigs_json_encode(integer);
    writer_check(text && strcmp(text, "9007199254740993") == 0,
                 "exact int encoding", "scalar", "two53-plus-one");
    writer_check(!g_has_error, "integer no error", "scalar", "two53-plus-one");
    writer_check(integer->refcount == refs, "borrowed ownership", "scalar", "two53-plus-one");
    free(text);
    val_decref(integer);
    eigs_close(state);
    printf("writer-json: refused=%u finite=%u checks=%u failures=%u\n",
           refused_cases, finite_cases, checks, failures);
    return failures ? 1 : 0;
}
