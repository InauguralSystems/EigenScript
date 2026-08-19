/* #964: sandbox-only dictionary keys must not pin the thread intern table. */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "eigs_embed.h"
#include "eigenscript.h"
#include "state.h"
#include "vm.h"

/* The builtin is intentionally exercised directly so the test can inspect
 * the owning EigsThread without adding a public/debug ABI hook. */
extern Value *builtin_sandbox_run(Value *arg);

static void append_num(Value *list, double n) {
    list_append_owned(list, make_num(n));
}

static size_t intern_count(void) {
    size_t count = 0;
    for (int i = 0; i < ENV_NAME_INTERN_BUCKETS; i++) {
        for (EnvNameIntern *it = eigs_current->env_name_interns[i]; it;
             it = it->next)
            count++;
    }
    return count;
}

static size_t sandbox_only_intern_count(void) {
    static const char prefix[] = "sandbox-only-key-";
    size_t count = 0;
    for (int i = 0; i < ENV_NAME_INTERN_BUCKETS; i++) {
        for (EnvNameIntern *it = eigs_current->env_name_interns[i]; it;
             it = it->next) {
            if (strncmp(it->name, prefix, sizeof(prefix) - 1) == 0)
                count++;
        }
    }
    return count;
}

static Value *sandbox_descriptor(int key_number) {
    Value *code = make_list(20);
    append_num(code, OP_CONST);
    append_num(code, 2);
    append_num(code, 0);
    append_num(code, OP_GET_NAME);
    append_num(code, 0);
    append_num(code, 0);
    append_num(code, OP_CONST);
    append_num(code, 1);
    append_num(code, 0);
    append_num(code, OP_CALL);
    append_num(code, 1);
    append_num(code, 0);
    append_num(code, OP_ADD);
    append_num(code, OP_CONST);
    append_num(code, 3);
    append_num(code, 0);
    append_num(code, OP_DICT);
    append_num(code, 1);
    append_num(code, 0);
    append_num(code, OP_RETURN);

    Value *constants = make_list(4);
    list_append_owned(constants, make_str("str"));
    append_num(constants, key_number);
    list_append_owned(constants, make_str("sandbox-only-key-"));
    append_num(constants, 1);

    Value *descriptor = make_list(3);
    append_num(descriptor, 1); /* EIGS_BYTECODE_ABI */
    list_append_owned(descriptor, code);
    list_append_owned(descriptor, constants);
    return descriptor;
}

static Value *sandbox_call(int key_number) {
    Value *arg = make_list(2);
    list_append_owned(arg, sandbox_descriptor(key_number));
    append_num(arg, 100000);
    Value *out = builtin_sandbox_run(arg);
    val_decref(arg);
    return out;
}

int main(void) {
    EigsState *state = eigs_open();
    assert(state != NULL);

    const size_t baseline = intern_count();
    const size_t sandbox_baseline = sandbox_only_intern_count();
    Value *escaped = NULL;
    char key[64];

    for (int i = 0; i < 128; i++) {
        snprintf(key, sizeof key, "sandbox-only-key-%d", i);
        Value *out = sandbox_call(i);
        assert(out != NULL);
        Value *ok = dict_get(out, "ok");
        assert(ok && ok->type == VAL_NUM && ok->data.num == 1.0);
        Value *result = dict_get(out, "result");
        assert(result && result->type == VAL_DICT);
        if (i == 0) {
            val_incref(result);
            escaped = result;
        }
        val_decref(out);
    }

    const size_t retained = intern_count() - baseline;
    const size_t sandbox_retained =
        sandbox_only_intern_count() - sandbox_baseline;
    snprintf(key, sizeof key, "sandbox-only-key-%d", 0);
    /* Check the escaped-result control before the retention assertion: a
     * mutant that restores the leak must still demonstrate that the returned
     * key remains readable through the run boundary. */
    Value *escaped_value = dict_get(escaped, key);
    if (!escaped_value) {
        char *diagnostic = value_to_string(escaped);
        fprintf(stderr, "escaped result=%s expected-key=%s\n", diagnostic, key);
        free(diagnostic);
    }
    assert(escaped_value && escaped_value->type == VAL_NUM &&
           escaped_value->data.num == 1.0);
    fprintf(stderr,
            "sandbox intern growth: baseline=%zu retained=%zu sandbox_only=%zu\n",
            baseline, retained, sandbox_retained);
    assert(sandbox_retained <= 8);

    val_decref(escaped);
    eigs_close(state);
    return 0;
}
